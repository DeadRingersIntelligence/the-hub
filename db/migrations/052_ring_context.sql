-- =============================================================================
-- 052_ring_context.sql
-- The Hub — migration 52: who is calling, while it rings.
--
-- Reviewed in the Hub chat ("Ship 052"). Run before 051, which was still a
-- draft: nothing here depends on 051. With no merge chains stored (0 on both,
-- 22 Oct 2026), 044's one-hop contact_for_number gives the same answers, and
-- ring_context picks up 051's version when it lands.
--
-- WHY. While a call rings, the agent should see who it is and what they last
-- called about, in one round trip and fast enough to matter before the
-- pickup. Nothing returns that today: the app would make three queries (the
-- number's contact, their calls, the case on each), and the second has no
-- index that serves it. interactions_contact_idx (006) is on contact_id alone,
-- so "this contact's last five calls" reads every call they have ever made and
-- sorts them. Fine at four calls; at four hundred the pop just arrives later
-- and later until nobody looks at it.
--
-- THIS MIGRATION
--   1. interactions_contact_recent_idx on (contact_id, occurred_at DESC),
--      partial on contact_id IS NOT NULL, replacing interactions_contact_idx.
--      Every lookup by contact_id = x is served by the new one (contact_id is
--      its leading column, and = x implies the partial predicate); the old one
--      only adds write cost. Most calls with no contact are left out of it.
--   2. ring_context(org, number): one jsonb with the name the Hub gives the
--      number (party_name, 045 — seat, directory, contact), the contact the
--      number belongs to (contact_for_number, so the staff rule of 044 and
--      the merge resolution hold), and that contact's five most recent
--      interactions with the case on each.
--
-- DISPLAY ONLY. It returns cases for the agent to read, and nothing here or
-- in the app pre-selects one. A pre-ticked case would be accepted by default
-- on exactly the call where it's wrong — a family calling about a second
-- death. Linking stays a deliberate act through set_call_case() (050).
--
-- WHAT IT DOESN'T DO
--   * A number with no contact gets its name, if any, and no history. Calls
--     from an unmatched number aren't looked up by from_e164: there is no
--     index for it, and an unmatched number's history is usually one call.
--   * Consultation legs (042) are left out, as the feed leaves them out. Texts
--     are kept: a family that texted yesterday is the same context.
--   * It takes a number, not a call: during the ring the call's row may not
--     have reached the Hub yet. p_exclude leaves out the ringing call itself
--     if it has.
--
-- Requires: 001 to 050 (case_link_method, 050). Not 051; see above.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. The index
-- -----------------------------------------------------------------------------
CREATE INDEX interactions_contact_recent_idx
  ON interactions (contact_id, occurred_at DESC)
  WHERE contact_id IS NOT NULL;

DROP INDEX interactions_contact_idx;

-- -----------------------------------------------------------------------------
-- 2. The pop
--
-- Invoker rights, as party_name is (045): it reads through the caller's RLS,
-- and an empty result is the policies working. Never SECURITY DEFINER.
-- -----------------------------------------------------------------------------
CREATE FUNCTION ring_context(p_org uuid, p_number text, p_exclude uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  WITH who AS (
    SELECT pn.name, pn.source FROM party_name(p_org, p_number) pn
  ),
  c AS (
    SELECT c.id, COALESCE(c.full_name, c.business_name) AS name
      FROM contacts c
     WHERE c.id = contact_for_number(p_org, p_number)
  ),
  recent AS (
    SELECT i.id, i.occurred_at, i.channel, i.direction, i.disposition, i.summary,
           i.case_id, i.case_link_method
      FROM interactions i, c
     WHERE i.contact_id = c.id
       AND i.organization_id = p_org
       AND i.consultation_of IS NULL
       AND i.id IS DISTINCT FROM p_exclude
     ORDER BY i.occurred_at DESC
     LIMIT 5
  )
  SELECT jsonb_build_object(
    'name',   (SELECT name FROM who),
    'source', (SELECT source FROM who),
    'contact', (SELECT jsonb_build_object('id', c.id, 'name', c.name) FROM c),
    'recent', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id', r.id,
               'occurred_at', r.occurred_at,
               'channel', r.channel,
               'direction', r.direction,
               'disposition', r.disposition,
               'summary', r.summary,
               'case', CASE WHEN r.case_id IS NULL THEN NULL ELSE jsonb_build_object(
                 'id', k.id,
                 'need_type', k.need_type,
                 'link_method', r.case_link_method,
                 'decedents', (SELECT jsonb_agg(d.full_name ORDER BY d.last_name, d.first_name)
                                 FROM case_decedents cd JOIN decedents d ON d.id = cd.decedent_id
                                WHERE cd.case_id = k.id))
               END)
             ORDER BY r.occurred_at DESC)
        FROM recent r LEFT JOIN cases k ON k.id = r.case_id), '[]'::jsonb)
  )
$$;

COMMENT ON FUNCTION ring_context(uuid, text, uuid) IS
  'What to show while a call rings: the number''s name (party_name), its '
  'contact (contact_for_number), and that contact''s five latest '
  'interactions with the case on each. Display only — never pre-select a '
  'case from it; linking is set_call_case(). One round trip, served by '
  'interactions_contact_recent_idx. Invoker rights on purpose.';

REVOKE ALL ON FUNCTION ring_context(uuid, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION ring_context(uuid, text, uuid) TO authenticated;

COMMIT;

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- DO $$
-- DECLARE r text := ''; v_org uuid; v_num text; v_ctx jsonb; v_plan text := '';
--         line text;
-- BEGIN
--   SELECT id INTO v_org FROM organizations WHERE code = 'DR';
--
--   r := r || 'old index gone: ' || (NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'interactions_contact_idx'))
--          || ', new index: ' || EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'interactions_contact_recent_idx')
--          || '   (expect true, true)' || chr(10);
--
--   -- The number of the contact with the most calls: the case the index is for.
--   SELECT p.e164 INTO v_num
--     FROM contact_phones p JOIN interactions i ON i.contact_id = p.contact_id
--    WHERE p.organization_id = v_org
--    GROUP BY p.e164 ORDER BY count(*) DESC LIMIT 1;
--   -- No number here means no contact has a call yet: nothing to test, not a
--   -- pass (production had no contacts when this ran, 22 Oct 2026).
--   IF v_num IS NULL THEN r := r || 'no contact with calls: the next three checks have nothing to test' || chr(10); END IF;
--   v_ctx := ring_context(v_org, v_num);
--   r := r || 'busiest contact: ' || coalesce(v_ctx->'contact'->>'name', 'none')
--          || ', recent: ' || jsonb_array_length(v_ctx->'recent')
--          || ', source: ' || coalesce(v_ctx->>'source', 'null')
--          || '   (expect a name, 1 to 5, contact)' || chr(10);
--   r := r || 'newest first: ' || coalesce((
--            SELECT bool_and(a.v->>'occurred_at' >= b.v->>'occurred_at')
--              FROM jsonb_array_elements(v_ctx->'recent') WITH ORDINALITY a(v, n)
--              JOIN jsonb_array_elements(v_ctx->'recent') WITH ORDINALITY b(v, n) ON b.n = a.n + 1)::text, 'n/a')
--          || '   (expect true or n/a)' || chr(10);
--
--   -- A staff number: named from the directory, never a contact.
--   SELECT ring_context(v_org, d.e164) INTO v_ctx FROM directory_entries d
--    WHERE d.organization_id = v_org AND d.active AND d.entry_kind = 'staff' LIMIT 1;
--   r := r || 'staff number: source ' || coalesce(v_ctx->>'source', 'no staff entry')
--          || ', contact ' || coalesce(v_ctx->'contact'->>'name', 'none')
--          || '   (expect directory, none)' || chr(10);
--
--   -- A number nobody has.
--   v_ctx := ring_context(v_org, '+15550000000');
--   r := r || 'unknown number: ' || v_ctx::text || '   (expect nulls and an empty recent)' || chr(10);
--
--   -- The plan uses the new index for the history lookup.
--   FOR line IN EXECUTE format(
--     'EXPLAIN SELECT id FROM interactions WHERE contact_id = %L ORDER BY occurred_at DESC LIMIT 5',
--     contact_for_number(v_org, v_num)) LOOP
--     v_plan := v_plan || line || ' ';
--   END LOOP;
--   r := r || 'plan uses interactions_contact_recent_idx: ' || (v_plan LIKE '%interactions_contact_recent_idx%')
--          || '   (expect true; a tiny table may still seq scan)' || chr(10);
--
--   r := r || 'authenticated can execute: ' || has_function_privilege('authenticated', 'ring_context(uuid, text, uuid)', 'EXECUTE')
--          || ', anon: ' || has_function_privilege('anon', 'ring_context(uuid, text, uuid)', 'EXECUTE')
--          || '   (expect true, false)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 052 (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
