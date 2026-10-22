-- =============================================================================
-- 050_hand_links.sql
-- The Hub — migration 50: linking a call to a contact or a case by hand.
--
-- The app's + Link picker sets a call's contact or case, and takes a wrong one
-- off. Until now nothing did: contact_id was written by ingestion (matched by
-- number) and by "Save as a contact" (048), and case_id only by seed data.
--
-- WHAT A HAND LINK IS. The call's own contact_id or case_id — not an
-- interaction_links row, which joins one call to another (callback, transfer,
-- same_case). The pills + Link makes are the same columns ingestion fills;
-- the link method says which made them.
--
-- THIS MIGRATION
--   1. interactions.case_link_method, as 047 did for contacts: set exactly when
--      case_id is, cleared with it. Before anything starts setting case_id —
--      conversion above all — so provenance is there from the first one.
--   2. set_call_contact / clear_call_contact and set_call_case /
--      clear_call_case. Each writes the change AND a change_history row in one
--      transaction, so a link always says who made it and when, and an unlink
--      is recorded rather than looking like a call that never matched.
--   3. change_history becomes append-only. Its one policy (016) covered every
--      command, so any signed-in user could edit or delete a history row —
--      including the "unlinked" row that is the only trace of a rejected
--      match. Read and insert for the firm, as before; update and delete for
--      nobody but internal.
--
-- AN UNLINK. Clearing a contact leaves contact_id and contact_link_method null
-- (047's trigger), the same as a call that never matched; the history row is
-- what tells them apart. Nothing re-links a call today: ingestion matches only
-- when it creates a call, a merge only moves an existing contact_id, and the
-- directory trigger only clears. If something ever does re-match existing
-- calls, it must read the 'unlinked' history first. Not a contact_rejected_id
-- column: a rejection is an event, and one column would keep only the latest
-- of several. When a matcher needs them cheaply, derive a view or partial
-- index from the 'unlinked' rows rather than maintaining a copy. (Review.)
--
-- WHAT IT DOESN'T DO
--   * Linking a contact doesn't add the call's number to that contact: people
--     call from other people's phones. That stays "Save as a contact"'s job.
--   * Linking a case doesn't add the caller to case_contacts — a separate
--     decision about the family, which the picker can offer as a second step.
--   * No negative match on the number: per call, by design.
--
-- RIGHTS. Invoker, like save_wrap_up: interactions_tenant already lets the
-- firm's users write these columns, and change_history keeps an insert
-- policy for them. The functions check nothing RLS doesn't, beyond keeping a
-- contact or case to the call's own firm.
--
-- Requires: 001 to 049
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. How a call got its case
-- -----------------------------------------------------------------------------
ALTER TABLE interactions ADD COLUMN case_link_method link_method;

COMMENT ON COLUMN interactions.case_link_method IS
  'How case_id was set: confirmed (a person chose it), writeback or imported. '
  'Null exactly when case_id is. Anything that clears or replaces a case on its '
  'own initiative touches inferred links only.';

-- Everything stored so far came with seeded or loaded data.
UPDATE interactions SET case_link_method = 'imported' WHERE case_id IS NOT NULL;

-- Where someone building a matcher will look. (Asked for in review.)
COMMENT ON COLUMN interactions.contact_link_method IS
  'How contact_id was set: inferred (matched by number at ingestion), '
  'confirmed (a person chose it), imported (seeded or loaded data). Null '
  'exactly when contact_id is. Anything that clears or replaces a contact on '
  'its own initiative touches inferred links only. A null does not mean '
  '"never matched": a person may have taken a wrong contact off '
  '(clear_call_contact). Anything that re-matches existing calls must read '
  'their ''unlinked'' change_history rows first — a rejection is an event, '
  'kept there with who and when, not a state kept here.';

CREATE FUNCTION interactions_case_link_clear() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.case_id IS NULL THEN NEW.case_link_method := NULL; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER interactions_case_link_clear_t
  BEFORE INSERT OR UPDATE OF case_id ON interactions
  FOR EACH ROW EXECUTE FUNCTION interactions_case_link_clear();

ALTER TABLE interactions ADD CONSTRAINT interactions_case_link_method_ck
  CHECK ((case_id IS NULL) = (case_link_method IS NULL));

-- -----------------------------------------------------------------------------
-- 2. History is append-only
--
-- 038's drift check first: stop if the policy isn't what 016 left.
-- -----------------------------------------------------------------------------
DO $$
DECLARE n int; found text;
BEGIN
  SELECT count(*), string_agg(polname::text, ', ') INTO n, found
    FROM pg_policy WHERE polrelid = 'public.change_history'::regclass;
  IF n <> 1 OR found <> 'change_history_tenant' THEN
    RAISE EXCEPTION 'change_history: expected exactly the policy change_history_tenant, found % (%). Stop and look before changing it.',
      coalesce(found, 'none'), n;
  END IF;
END $$;

DROP POLICY change_history_tenant ON change_history;

CREATE POLICY change_history_read ON change_history FOR SELECT
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY change_history_insert ON change_history FOR INSERT
  WITH CHECK (is_internal() OR organization_id = current_organization_id());
-- History isn't edited or removed by the firm. Internal keeps both, for
-- corrections and retention.
CREATE POLICY change_history_update ON change_history FOR UPDATE
  USING (is_internal()) WITH CHECK (is_internal());
CREATE POLICY change_history_delete ON change_history FOR DELETE
  USING (is_internal());

-- -----------------------------------------------------------------------------
-- 3. The four links
-- -----------------------------------------------------------------------------

-- The signed-in person, as every hand link needs one.
CREATE FUNCTION hand_link_actor(OUT v_user uuid, OUT v_name text)
LANGUAGE plpgsql STABLE AS $$
BEGIN
  v_user := current_user_id();
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'your sign-in isn''t linked to a Hub user, so this can''t be saved';
  END IF;
  SELECT full_name INTO v_name FROM users WHERE id = v_user;
  v_name := COALESCE(v_name, 'Unknown');
END $$;

-- Called by the four below, which run as the signed-in user, so it's theirs to
-- run; it only reads the caller's own name.
REVOKE ALL ON FUNCTION hand_link_actor() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION hand_link_actor() TO authenticated;

CREATE FUNCTION set_call_contact(p_interaction uuid, p_contact uuid)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  a record; v_org uuid; v_old uuid; v_old_method link_method;
  v_contact uuid; v_name text;
BEGIN
  SELECT * INTO a FROM hand_link_actor();
  SELECT organization_id, contact_id, contact_link_method INTO v_org, v_old, v_old_method
    FROM interactions WHERE id = p_interaction FOR UPDATE;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'that call couldn''t be found' USING ERRCODE = 'P0002';
  END IF;

  -- A merged-away contact means its survivor — one hop. merge_contacts()
  -- doesn't flatten chains (A into B, then B into C leaves A pointing at B), so
  -- a survivor that is itself merged away is refused rather than half-resolved:
  -- that's a data problem to surface, not to paper over. (Found in review.)
  SELECT COALESCE(c.merged_into, c.id) INTO v_contact
    FROM contacts c WHERE c.id = p_contact AND c.organization_id = v_org;
  IF v_contact IS NULL THEN
    RAISE EXCEPTION 'choose a contact at this call''s firm';
  END IF;
  IF EXISTS (SELECT 1 FROM contacts WHERE id = v_contact AND merged_into IS NOT NULL) THEN
    RAISE EXCEPTION 'that contact was merged into one that has since been merged too; pick the contact it ended up as';
  END IF;
  SELECT COALESCE(full_name, business_name, 'a contact') INTO v_name FROM contacts WHERE id = v_contact;

  -- Already this contact, chosen by a person: nothing to record.
  IF v_old = v_contact AND v_old_method = 'confirmed' THEN RETURN; END IF;

  UPDATE interactions
     SET contact_id = v_contact, contact_link_method = 'confirmed', updated_at = now()
   WHERE id = p_interaction;

  PERFORM record_change(
    v_org, 'interaction', p_interaction, 'linked', 'user', a.v_name,
    format('%s linked this call to %s', a.v_name, v_name),
    a.v_user,
    jsonb_build_object('field', 'contact_id', 'contact_id', v_contact,
                       'previous_contact_id', v_old, 'previous_method', v_old_method),
    'confirmed');
END $$;

CREATE FUNCTION clear_call_contact(p_interaction uuid)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE a record; v_org uuid; v_old uuid; v_old_method link_method; v_name text;
BEGIN
  SELECT * INTO a FROM hand_link_actor();
  SELECT organization_id, contact_id, contact_link_method INTO v_org, v_old, v_old_method
    FROM interactions WHERE id = p_interaction FOR UPDATE;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'that call couldn''t be found' USING ERRCODE = 'P0002';
  END IF;
  IF v_old IS NULL THEN RETURN; END IF;
  SELECT COALESCE(full_name, business_name, 'a contact') INTO v_name FROM contacts WHERE id = v_old;

  -- Null, not back to inferred: a person said the match was wrong.
  UPDATE interactions SET contact_id = NULL, updated_at = now() WHERE id = p_interaction;

  PERFORM record_change(
    v_org, 'interaction', p_interaction, 'unlinked', 'user', a.v_name,
    format('%s took %s off this call', a.v_name, v_name),
    a.v_user,
    jsonb_build_object('field', 'contact_id', 'contact_id', v_old, 'previous_method', v_old_method));
END $$;

CREATE FUNCTION set_call_case(p_interaction uuid, p_case uuid)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE a record; v_org uuid; v_old uuid; v_old_method link_method;
BEGIN
  SELECT * INTO a FROM hand_link_actor();
  SELECT organization_id, case_id, case_link_method INTO v_org, v_old, v_old_method
    FROM interactions WHERE id = p_interaction FOR UPDATE;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'that call couldn''t be found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cases WHERE id = p_case AND organization_id = v_org) THEN
    RAISE EXCEPTION 'choose a case at this call''s firm';
  END IF;
  IF v_old = p_case AND v_old_method = 'confirmed' THEN RETURN; END IF;

  UPDATE interactions
     SET case_id = p_case, case_link_method = 'confirmed', updated_at = now()
   WHERE id = p_interaction;

  PERFORM record_change(
    v_org, 'interaction', p_interaction, 'linked', 'user', a.v_name,
    format('%s linked this call to a case', a.v_name),
    a.v_user,
    jsonb_build_object('field', 'case_id', 'case_id', p_case,
                       'previous_case_id', v_old, 'previous_method', v_old_method),
    'confirmed');
END $$;

CREATE FUNCTION clear_call_case(p_interaction uuid)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE a record; v_org uuid; v_old uuid; v_old_method link_method;
BEGIN
  SELECT * INTO a FROM hand_link_actor();
  SELECT organization_id, case_id, case_link_method INTO v_org, v_old, v_old_method
    FROM interactions WHERE id = p_interaction FOR UPDATE;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'that call couldn''t be found' USING ERRCODE = 'P0002';
  END IF;
  IF v_old IS NULL THEN RETURN; END IF;

  UPDATE interactions SET case_id = NULL, updated_at = now() WHERE id = p_interaction;

  PERFORM record_change(
    v_org, 'interaction', p_interaction, 'unlinked', 'user', a.v_name,
    format('%s took this call off a case', a.v_name),
    a.v_user,
    jsonb_build_object('field', 'case_id', 'case_id', v_old, 'previous_method', v_old_method));
END $$;

COMMENT ON FUNCTION set_call_contact(uuid, uuid) IS
  'Link a call to a contact by hand (contact_link_method confirmed), and record '
  'who did it. A merged-away contact is resolved to its survivor.';
COMMENT ON FUNCTION clear_call_contact(uuid) IS
  'Take a wrong contact off a call: contact_id and its method go null, and an '
  '''unlinked'' history row records the rejection — the only thing that tells '
  'it apart from a call that never matched.';
COMMENT ON FUNCTION set_call_case(uuid, uuid) IS
  'Link a call to a case by hand (case_link_method confirmed), and record who did it.';
COMMENT ON FUNCTION clear_call_case(uuid) IS
  'Take a call off a case, recording it as ''unlinked'' history.';

REVOKE ALL ON FUNCTION set_call_contact(uuid, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION clear_call_contact(uuid)     FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION set_call_case(uuid, uuid)    FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION clear_call_case(uuid)        FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION set_call_contact(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION clear_call_contact(uuid)     TO authenticated;
GRANT EXECUTE ON FUNCTION set_call_case(uuid, uuid)    TO authenticated;
GRANT EXECUTE ON FUNCTION clear_call_case(uuid)        TO authenticated;

COMMIT;

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
-- Made-up numbers only. app.user_id stands in for a signed-in person.
--
-- DO $$
-- DECLARE r text := ''; v_org uuid; v_num text; v_user uuid; v_i uuid; v_c uuid; v_c2 uuid; v_case uuid; n int;
-- BEGIN
--   SELECT id INTO v_org FROM organizations WHERE code = 'DR';
--   SELECT e164 INTO v_num FROM phone_numbers WHERE active AND organization_id = v_org ORDER BY e164 LIMIT 1;
--   SELECT u.id INTO v_user FROM users u LIMIT 1;
--   PERFORM set_config('app.user_id', v_user::text, true);
--
--   r := r || 'contacts merged into a merged-away contact (chains): '
--          || (SELECT count(*) FROM contacts a JOIN contacts b ON b.id = a.merged_into WHERE b.merged_into IS NOT NULL)
--          || chr(10);
--   r := r || 'cases without a method: '
--          || (SELECT count(*) FROM interactions WHERE (case_id IS NULL) <> (case_link_method IS NULL))
--          || '   (expect 0)' || chr(10);
--
--   v_i := ingest_call_event('call_050_a', 'call.incoming', now() - interval '5 min', 'inbound', '+15135552020', v_num);
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'Chosen by hand (test)') RETURNING id INTO v_c;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'Merged away (test)') RETURNING id INTO v_c2;
--   UPDATE contacts SET merged_into = v_c WHERE id = v_c2;
--
--   -- Link a merged-away contact: lands on the survivor, confirmed, recorded.
--   PERFORM set_call_contact(v_i, v_c2);
--   r := r || 'linked: ' || (SELECT contact_id = v_c AND contact_link_method = 'confirmed' FROM interactions WHERE id = v_i)
--          || ', history: ' || (SELECT action::text || '/' || link_method::text || '/' || (actor_user_id = v_user)::text FROM change_history
--                              WHERE entity = 'interaction' AND entity_id = v_i ORDER BY occurred_at DESC LIMIT 1)
--          || '   (expect true, linked/confirmed/true)' || chr(10);
--
--   -- Linking it again changes nothing and records nothing.
--   PERFORM set_call_contact(v_i, v_c);
--   r := r || 'history rows after a repeat: ' || (SELECT count(*) FROM change_history WHERE entity_id = v_i) || '   (expect 1)' || chr(10);
--
--   -- Unlink: null, not inferred, and recorded.
--   PERFORM clear_call_contact(v_i);
--   r := r || 'unlinked: ' || (SELECT contact_id IS NULL AND contact_link_method IS NULL FROM interactions WHERE id = v_i)
--          -- One transaction: now() doesn't move, so "latest" can't be told by time.
--          || ', unlinked row recorded: ' || EXISTS (SELECT 1 FROM change_history WHERE entity_id = v_i AND action = 'unlinked'
--                                                    AND detail->>'contact_id' = v_c::text AND detail->>'previous_method' = 'confirmed')
--          || '   (expect true, true)' || chr(10);
--
--   -- A survivor that is itself merged away is refused, not half-resolved.
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'End of the chain (test)') RETURNING id INTO v_case;
--   UPDATE contacts SET merged_into = v_case WHERE id = v_c;   -- v_c2 -> v_c -> v_case
--   BEGIN
--     PERFORM set_call_contact(v_i, v_c2);
--     r := r || 'two-hop merge: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN raise_exception THEN r := r || 'two-hop merge refused' || chr(10); END;
--   UPDATE contacts SET merged_into = NULL WHERE id = v_c;
--   v_case := NULL;
--
--   -- A contact at another firm is refused.
--   BEGIN
--     PERFORM set_call_contact(v_i, (SELECT id FROM contacts WHERE organization_id <> v_org LIMIT 1));
--     r := r || 'another firm''s contact: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN raise_exception THEN r := r || 'another firm''s contact refused' || chr(10); END;
--
--   -- A case, linked and cleared.
--   SELECT id INTO v_case FROM cases WHERE organization_id = v_org LIMIT 1;
--   IF v_case IS NULL THEN
--     INSERT INTO cases (organization_id, need_type) VALUES (v_org, 'pre_need') RETURNING id INTO v_case;
--   END IF;
--   PERFORM set_call_case(v_i, v_case);
--   r := r || 'case linked: ' || (SELECT case_id = v_case AND case_link_method = 'confirmed' FROM interactions WHERE id = v_i) || '   (expect true)' || chr(10);
--   PERFORM clear_call_case(v_i);
--   r := r || 'case cleared: ' || (SELECT case_id IS NULL AND case_link_method IS NULL FROM interactions WHERE id = v_i) || '   (expect true)' || chr(10);
--
--   -- History is append-only for the firm.
--   SELECT count(*) INTO n FROM pg_policy WHERE polrelid = 'change_history'::regclass;
--   r := r || 'history policies: ' || (SELECT string_agg(polname::text || '=' || polcmd::text, ', ' ORDER BY polname) FROM pg_policy WHERE polrelid = 'change_history'::regclass)
--          || '   (expect delete=d, insert=a, read=r, update=w)' || chr(10);
--   r := r || 'update/delete open to the firm: '
--          || coalesce((SELECT string_agg(polname::text, ', ') FROM pg_policy WHERE polrelid = 'change_history'::regclass AND polcmd IN ('w', 'd')
--                        AND pg_get_expr(polqual, polrelid) LIKE '%current_organization_id%'), 'none')
--          || '   (expect none)' || chr(10);
--
--   r := r || 'authenticated can run the four: '
--          || has_function_privilege('authenticated', 'set_call_contact(uuid, uuid)', 'EXECUTE') || '/'
--          || has_function_privilege('authenticated', 'clear_call_contact(uuid)', 'EXECUTE') || '/'
--          || has_function_privilege('authenticated', 'set_call_case(uuid, uuid)', 'EXECUTE') || '/'
--          || has_function_privilege('authenticated', 'clear_call_case(uuid)', 'EXECUTE')
--          || ', anon: ' || has_function_privilege('anon', 'set_call_contact(uuid, uuid)', 'EXECUTE')
--          || '   (expect true/true/true/true, false)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 050 (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
