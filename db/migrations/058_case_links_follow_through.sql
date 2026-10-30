-- =============================================================================
-- 058_case_links_follow_through.sql
-- The Hub — migration 58: case links that spread when confirmed later, say
-- so when they spread, and one record of which call converted.
--
-- Run on dead-ringers-hub and hellophone-production, 30 Oct 2026; the
-- verification block passed on dead-ringers-hub.
--
-- WHY. Three gaps 057 left, named in its STILL TO DO:
--
--   1. set_call_case() (050) never calls propagate_case_links(). Linking the
--      daughter's call to her father's case by hand, after the fact, didn't
--      bring along the calls linked to hers. The rule that settled the
--      design only worked at the moment a case was created.
--   2. propagate_case_links() wrote no history. A call that joined a case
--      because a linked call was on it showed up there with no record of
--      how. History can't be backfilled later; it has to start now.
--   3. cases.converting_interaction_id and interactions.is_converting say the
--      same thing twice. On staging they already disagree: two imported calls
--      are flagged converting and no case points back at either.
--
-- THIS MIGRATION
--   1. Keeps cases.converting_interaction_id and drops interactions.is_converting.
--      The case is what converted; one case has one converting call, and the
--      reference is a foreign key, so it can't point at nothing. Before the
--      drop, any flagged call on a case with no pointer becomes that case's
--      pointer (two on staging, none on production). A unique index states
--      that one call converts at most one case.
--   2. countable_calls keeps its is_converting column, now derived from the
--      case's pointer. Same name, type and position, so nothing reading the
--      view changes. Nothing in the app reads either (checked 30 Oct).
--   3. propagate_case_links() records each call it joins: 'linked', actor
--      system ('HelloPhone', the label the Hub's other system rows use), link
--      method inferred, and which call on the case it came through.
--   4. set_call_case() runs propagate_case_links() after a hand link, so a
--      call confirmed later spreads the case one hop like any other confirmed
--      call. Confirming an inferred call makes it a source (057's rule 5).
--   5. set_call_case() and clear_call_case(), when they take a case's
--      converting call off that case, clear the case's pointer: it no longer
--      converted anything. clear_call_case() also clears case_link_method,
--      which it left behind on an unlinked call.
--   6. create_case_for_call() and delete_case() stop writing is_converting.
--      Otherwise unchanged.
--
-- NOT HERE
--   * Moving a call to another case leaves calls that were inferred through
--     it on the old case. Whether they should follow is a ruling, not a fix.
--   * 056 (save_wrap_up). Independent of this; nothing here touches it.
--
-- Live definitions checked 30 Oct 2026: every function this replaces, and
-- the view, are identical on hellophone-production and dead-ringers-hub.
--
-- Requires: 001 to 055, 057. Not 056.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Drift check: everything replaced here is as 050 and 057 left it.
-- -----------------------------------------------------------------------------
DO $$
DECLARE r record; v_bad text := '';
BEGIN
  FOR r IN
    SELECT x.name, x.want, md5(p.prosrc) AS got
      FROM (VALUES ('set_call_case',        'ff7d46cc3f629baaa64be6f5d54b5be8'),
                   ('clear_call_case',      '30031f251d355f971a4b8f21a62b7139'),
                   ('propagate_case_links', '5c9cf508e94d93d01f214946fab12d29'),
                   ('create_case_for_call', '54b049efe8691eb7c1811de530a0b84d'),
                   ('delete_case',          '1f916feda883980067a5ca0cf8c99bfb')) x(name, want)
      LEFT JOIN pg_proc p ON p.proname = x.name
                         AND p.pronamespace = 'public'::regnamespace
  LOOP
    IF r.got IS DISTINCT FROM r.want THEN
      v_bad := v_bad || format('%s is %s, expected %s; ', r.name, coalesce(r.got, 'missing'), r.want);
    END IF;
  END LOOP;

  IF md5(pg_get_viewdef('countable_calls'::regclass, true)) <> '3f96e84ffd8aef4d57759d04bf15b690' THEN
    v_bad := v_bad || 'countable_calls has changed; ';
  END IF;

  IF v_bad <> '' THEN
    RAISE EXCEPTION 'Not as 050/057 left it — stop and look: %', v_bad;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 1. One record of the converting call: the case's pointer
-- -----------------------------------------------------------------------------

-- Carry any flag across first. Only where the case has exactly one flagged
-- call and no pointer yet; anything else is reported, not guessed.
UPDATE cases c
   SET converting_interaction_id = i.id
  FROM interactions i
 WHERE i.is_converting
   AND i.case_id = c.id
   AND c.converting_interaction_id IS NULL
   AND (SELECT count(*) FROM interactions j
         WHERE j.is_converting AND j.case_id = c.id) = 1;

DO $$
DECLARE n integer;
BEGIN
  SELECT count(*) INTO n FROM interactions i
   WHERE i.is_converting
     AND NOT EXISTS (SELECT 1 FROM cases c WHERE c.converting_interaction_id = i.id);
  IF n > 0 THEN
    RAISE EXCEPTION '% call(s) flagged converting couldn''t be carried to a case (no case, or more than one flagged per case). Stop and look.', n;
  END IF;
END $$;

CREATE UNIQUE INDEX cases_converting_interaction_uq
  ON cases (converting_interaction_id)
  WHERE converting_interaction_id IS NOT NULL;

COMMENT ON COLUMN cases.converting_interaction_id IS
  'The call this case was created from: the one record of which call '
  'converted. Cleared if that call is taken off the case. countable_calls '
  'derives is_converting from it; interactions has no flag of its own (058).';

-- The view first, so the column can go. Same columns, same order, same
-- types; is_converting is now read from the case.
CREATE OR REPLACE VIEW countable_calls WITH (security_invoker = true) AS
SELECT i.id,
       i.organization_id,
       i.account_id,
       i.location_id,
       i.source,
       i.channel,
       i.direction,
       i.service_line,
       i.phone_number_id,
       i.from_e164,
       i.to_e164,
       i.seat_id,
       i.handler_person_id,
       i.handler_type,
       i.attribution_method,
       i.attribution_confidence,
       i.original_handler_person_id,
       i.reattributed_by,
       i.reattributed_at,
       i.occurred_at,
       i.ended_at,
       i.duration_seconds,
       i.disposition,
       i.telemetry_status,
       i.ring_count,
       i.answer_seconds,
       i.hold_seconds,
       i.transfer_count,
       i.qualified,
       i.unqualified_reason,
       i.contact_id,
       i.case_id,
       EXISTS (SELECT 1 FROM cases c WHERE c.converting_interaction_id = i.id) AS is_converting,
       i.recording_url,
       i.transcript,
       i.summary,
       i.external_ref,
       i.created_at,
       i.updated_at,
       i.next_step_item_id,
       i.next_step_note,
       i.answering_service_id,
       i.external_call_ref,
       i.started_at,
       i.answered_at,
       i.connected_at,
       i.carrier,
       i.last_activity_at,
       i.recording_seconds,
       i.consultation_of
  FROM interactions i
 WHERE i.channel = 'call'::interaction_channel
   AND i.consultation_of IS NULL;

ALTER TABLE interactions DROP COLUMN is_converting;

-- -----------------------------------------------------------------------------
-- 2. Inferred links write history
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION propagate_case_links(p_case uuid)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE v_org uuid; r record; n integer := 0;
BEGIN
  SELECT organization_id INTO v_org FROM cases WHERE id = p_case;
  IF v_org IS NULL THEN RETURN 0; END IF;

  -- One hop from each confirmed call on the case, along same_case links.
  -- Each joining call is recorded with the call it came through (the first,
  -- if several reach it).
  FOR r IN
    SELECT DISTINCT ON (x.target) x.target, x.via
      FROM (SELECT CASE WHEN l.from_interaction_id = s.id
                        THEN l.to_interaction_id ELSE l.from_interaction_id END AS target,
                   s.id AS via
              FROM interaction_links l
              JOIN interactions s
                ON s.id IN (l.from_interaction_id, l.to_interaction_id)
             WHERE l.link_type = 'same_case'
               AND l.organization_id = v_org
               AND l.to_interaction_id IS NOT NULL
               AND s.case_id = p_case
               AND s.case_link_method = 'confirmed') x
     ORDER BY x.target, x.via
  LOOP
    UPDATE interactions
       SET case_id = p_case, case_link_method = 'inferred', updated_at = now()
     WHERE id = r.target AND organization_id = v_org AND case_id IS NULL;

    IF FOUND THEN
      PERFORM record_change(
        v_org, 'interaction', r.target, 'linked', 'system', 'HelloPhone',
        'Joined a case through a linked call already on it', NULL,
        jsonb_build_object('field', 'case_id', 'case_id', p_case,
                           'via_interaction_id', r.via, 'link_type', 'same_case'),
        'inferred');
      n := n + 1;
    END IF;
  END LOOP;

  RETURN n;
END $$;

COMMENT ON FUNCTION propagate_case_links(uuid) IS
  'Puts a case on calls linked same_case to a confirmed call on it, one hop, '
  'marked inferred; an inferred call never spreads further. Each call it '
  'joins is recorded in change_history (system, inferred, via which call). '
  'Run by create_case_for_call() and set_call_case(). Returns calls joined.';

-- -----------------------------------------------------------------------------
-- 3. A hand link spreads; moving the converting call clears the pointer
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_call_case(p_interaction uuid, p_case uuid)
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

  -- Moved off the case it converted: that case no longer has a converting call.
  IF v_old IS DISTINCT FROM p_case THEN
    UPDATE cases SET converting_interaction_id = NULL, updated_at = now()
     WHERE id = v_old AND converting_interaction_id = p_interaction;
  END IF;

  PERFORM record_change(
    v_org, 'interaction', p_interaction, 'linked', 'user', a.v_name,
    format('%s linked this call to a case', a.v_name),
    a.v_user,
    jsonb_build_object('field', 'case_id', 'case_id', p_case,
                       'previous_case_id', v_old, 'previous_method', v_old_method),
    'confirmed');

  -- Confirmed now, so it is a source: its linked calls join, one hop.
  PERFORM propagate_case_links(p_case);
END $$;

CREATE OR REPLACE FUNCTION clear_call_case(p_interaction uuid)
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

  UPDATE interactions
     SET case_id = NULL, case_link_method = NULL, updated_at = now()
   WHERE id = p_interaction;

  UPDATE cases SET converting_interaction_id = NULL, updated_at = now()
   WHERE id = v_old AND converting_interaction_id = p_interaction;

  PERFORM record_change(
    v_org, 'interaction', p_interaction, 'unlinked', 'user', a.v_name,
    format('%s took this call off a case', a.v_name),
    a.v_user,
    jsonb_build_object('field', 'case_id', 'case_id', v_old, 'previous_method', v_old_method));
END $$;

-- -----------------------------------------------------------------------------
-- 4. create_case_for_call() and delete_case() without is_converting
--    Otherwise exactly as 057 left them.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_case_for_call(p_interaction uuid, p_need_type case_need_type, p_decedent_status decedent_status, p_decedent_last text DEFAULT NULL::text, p_decedent_first text DEFAULT NULL::text, p_date_of_death date DEFAULT NULL::date, p_decedent_id uuid DEFAULT NULL::uuid, p_role text DEFAULT NULL::text, p_also uuid[] DEFAULT '{}'::uuid[])
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
DECLARE
  a record;
  v_org uuid; v_loc uuid; v_contact uuid; v_case uuid; v_decedent uuid;
  v_status decedent_status; v_existing uuid; v_other uuid; v_joined uuid[] := '{}';
BEGIN
  IF current_user_id() IS NULL THEN
    RAISE EXCEPTION 'your sign-in isn''t linked to a Hub user, so a case can''t be created';
  END IF;
  SELECT * INTO a FROM hand_link_actor();

  SELECT organization_id, location_id, contact_id, case_id
    INTO v_org, v_loc, v_contact, v_existing
    FROM interactions WHERE id = p_interaction FOR UPDATE;

  IF v_org IS NULL THEN
    RAISE EXCEPTION 'that call couldn''t be found' USING ERRCODE = 'P0002';
  END IF;
  IF v_existing IS NOT NULL THEN
    RAISE EXCEPTION 'this call is already on a case — unlink it first, or link it to another';
  END IF;

  IF v_contact IS NULL THEN
    RAISE EXCEPTION 'save the caller as a contact first';
  END IF;

  IF p_decedent_id IS NOT NULL THEN
    SELECT COALESCE(d.merged_into, d.id) INTO v_decedent
      FROM decedents d WHERE d.id = p_decedent_id AND d.organization_id = v_org;
    IF v_decedent IS NULL THEN
      RAISE EXCEPTION 'choose a decedent at this firm';
    END IF;
    SELECT status INTO v_status FROM decedents WHERE id = v_decedent;
  ELSE
    IF NULLIF(btrim(COALESCE(p_decedent_last, '')), '') IS NULL THEN
      RAISE EXCEPTION 'the case needs the deceased person''s last name'
        USING HINT = 'Ask while the family is on the phone — a first name alone can''t be matched later.';
    END IF;

    IF p_decedent_status IN ('pre_need_subject', 'imminent') AND p_date_of_death IS NOT NULL THEN
      RAISE EXCEPTION 'a date of death can''t be recorded for someone living';
    END IF;

    INSERT INTO decedents (organization_id, first_name, last_name, status, date_of_death)
    VALUES (v_org,
            NULLIF(btrim(COALESCE(p_decedent_first, '')), ''),
            btrim(p_decedent_last),
            p_decedent_status,
            p_date_of_death)
    RETURNING id INTO v_decedent;
    v_status := p_decedent_status;
  END IF;

  IF (p_need_type = 'pre_need'  AND v_status <> 'pre_need_subject')
  OR (p_need_type = 'imminent'  AND v_status <> 'imminent')
  OR (p_need_type = 'at_need'   AND v_status NOT IN ('at_need', 'deceased')) THEN
    RAISE EXCEPTION 'a % case doesn''t go with a decedent recorded as %', p_need_type, v_status;
  END IF;

  INSERT INTO cases (organization_id, location_id, need_type,
                     converting_interaction_id, opened_on, status)
  VALUES (v_org, v_loc, p_need_type, p_interaction, current_date, 'active')
  RETURNING id INTO v_case;

  INSERT INTO case_decedents (case_id, decedent_id)
  VALUES (v_case, v_decedent) ON CONFLICT DO NOTHING;

  INSERT INTO case_contacts (case_id, contact_id, role, is_primary)
  VALUES (v_case, v_contact, NULLIF(btrim(COALESCE(p_role, '')), ''), true)
  ON CONFLICT DO NOTHING;

  UPDATE interactions
     SET case_id = v_case, case_link_method = 'confirmed', updated_at = now()
   WHERE id = p_interaction;

  INSERT INTO interaction_decedents (interaction_id, decedent_id, link_method, linked_by)
  VALUES (p_interaction, v_decedent, 'confirmed', a.v_name)
  ON CONFLICT DO NOTHING;

  FOREACH v_other IN ARRAY COALESCE(p_also, '{}') LOOP
    CONTINUE WHEN v_other = p_interaction;
    UPDATE interactions
       SET case_id = v_case, case_link_method = 'confirmed', updated_at = now()
     WHERE id = v_other AND organization_id = v_org AND case_id IS NULL;
    IF FOUND THEN v_joined := v_joined || v_other; END IF;
  END LOOP;

  PERFORM propagate_case_links(v_case);

  UPDATE leads
     SET case_id = v_case, status = 'converted', updated_at = now()
   WHERE organization_id = v_org
     AND contact_id = v_contact
     AND status IN ('open', 'contacted');

  PERFORM record_change(
    v_org, 'case', v_case, 'created', 'user', a.v_name,
    format('%s created this case from a call', a.v_name), a.v_user,
    jsonb_build_object('converting_interaction_id', p_interaction,
                       'decedent_id', v_decedent, 'need_type', p_need_type));

  PERFORM record_change(
    v_org, 'interaction', p_interaction, 'linked', 'user', a.v_name,
    format('%s created a case from this call', a.v_name), a.v_user,
    jsonb_build_object('field', 'case_id', 'case_id', v_case, 'converting', true),
    'confirmed');

  FOREACH v_other IN ARRAY v_joined LOOP
    PERFORM record_change(
      v_org, 'interaction', v_other, 'linked', 'user', a.v_name,
      format('%s linked this call to a case', a.v_name), a.v_user,
      jsonb_build_object('field', 'case_id', 'case_id', v_case), 'confirmed');
  END LOOP;

  RETURN v_case;
END $function$;

CREATE OR REPLACE FUNCTION public.delete_case(p_case uuid)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
DECLARE
  a record;
  v_org uuid; v_conv uuid; v_contact uuid; v_held text := ''; n integer;
  v_decedents uuid[]; v_d uuid;
BEGIN
  SELECT * INTO a FROM hand_link_actor();

  SELECT organization_id, converting_interaction_id INTO v_org, v_conv
    FROM cases WHERE id = p_case FOR UPDATE;
  IF v_org IS NULL THEN RAISE EXCEPTION 'no such case'; END IF;

  SELECT contact_id INTO v_contact FROM interactions WHERE id = v_conv;

  SELECT count(*) INTO n FROM interactions
   WHERE case_id = p_case AND id IS DISTINCT FROM v_conv;
  IF n > 0 THEN v_held := v_held || format('%s other call(s); ', n); END IF;

  SELECT count(*) INTO n FROM case_contacts
   WHERE case_id = p_case AND contact_id IS DISTINCT FROM v_contact;
  IF n > 0 THEN v_held := v_held || format('%s other contact(s); ', n); END IF;

  SELECT count(*) INTO n FROM threads WHERE case_id = p_case;
  IF n > 0 THEN v_held := v_held || format('%s chat thread(s); ', n); END IF;

  SELECT count(*) INTO n FROM reminders WHERE case_id = p_case;
  IF n > 0 THEN v_held := v_held || format('%s reminder(s); ', n); END IF;

  IF v_held <> '' THEN
    RAISE EXCEPTION 'this case has been worked on (%) — unlink the call instead, '
                    'or mark the case lost if the family didn''t proceed',
                    btrim(v_held, '; ');
  END IF;

  SELECT COALESCE(array_agg(decedent_id), '{}') INTO v_decedents
    FROM case_decedents WHERE case_id = p_case;

  UPDATE interactions
     SET case_id = NULL, case_link_method = NULL, updated_at = now()
   WHERE case_id = p_case;

  UPDATE leads SET case_id = NULL, status = 'open', updated_at = now()
   WHERE case_id = p_case;

  DELETE FROM case_decedents WHERE case_id = p_case;
  DELETE FROM case_contacts  WHERE case_id = p_case;

  FOREACH v_d IN ARRAY v_decedents LOOP
    DELETE FROM interaction_decedents
     WHERE interaction_id = v_conv AND decedent_id = v_d;
    IF NOT EXISTS (SELECT 1 FROM case_decedents WHERE decedent_id = v_d)
       AND NOT EXISTS (SELECT 1 FROM interaction_decedents WHERE decedent_id = v_d)
       AND NOT EXISTS (SELECT 1 FROM decedents WHERE merged_into = v_d) THEN
      DELETE FROM decedents WHERE id = v_d;
    END IF;
  END LOOP;

  IF v_conv IS NOT NULL THEN
    PERFORM record_change(
      v_org, 'interaction', v_conv, 'unlinked', 'user', a.v_name,
      format('%s undid a case created from this call by mistake', a.v_name), a.v_user,
      jsonb_build_object('field', 'case_id', 'previous_case_id', p_case,
                         'reason', 'created by mistake', 'case_deleted', true));
  END IF;

  DELETE FROM cases WHERE id = p_case;
  RETURN true;
END $function$;

COMMIT;

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
-- Run after the migration. Needs three calls at the DR firm with a contact and
-- no case; it says so if there aren't three.
--
-- DO $$
-- DECLARE r text := ''; v_org uuid; v_a uuid; v_b uuid; v_c uuid; v_case uuid;
--         v_case2 uuid; n integer;
-- BEGIN
--   SELECT id INTO v_org FROM organizations WHERE code = 'DR';
--   PERFORM set_config('app.user_id', (SELECT id::text FROM users WHERE is_internal LIMIT 1), true);
--
--   SELECT id INTO v_a FROM interactions WHERE organization_id = v_org AND contact_id IS NOT NULL
--      AND case_id IS NULL ORDER BY occurred_at DESC LIMIT 1;
--   SELECT id INTO v_b FROM interactions WHERE organization_id = v_org AND case_id IS NULL
--      AND id <> v_a ORDER BY occurred_at DESC LIMIT 1;
--   SELECT id INTO v_c FROM interactions WHERE organization_id = v_org AND case_id IS NULL
--      AND id NOT IN (v_a, v_b) ORDER BY occurred_at DESC LIMIT 1;
--   IF v_c IS NULL THEN RAISE EXCEPTION 'VERIFY 058: need three calls without a case'; END IF;
--
--   r := r || 'is_converting column gone: '
--          || (NOT EXISTS (SELECT 1 FROM information_schema.columns
--                          WHERE table_name = 'interactions' AND column_name = 'is_converting'))
--          || ', view still has it: '
--          || EXISTS (SELECT 1 FROM information_schema.columns
--                      WHERE table_name = 'countable_calls' AND column_name = 'is_converting')
--          || '   (expect true, true)' || chr(10);
--
--   -- The father-and-daughter case: B is linked to C, B is put on a case by
--   -- hand later, and C should follow.
--   v_case := create_case_for_call(v_a, 'at_need', 'at_need', 'Verify', 'Father');
--   r := r || 'converting call read from the case: '
--          || (SELECT is_converting FROM countable_calls WHERE id = v_a)
--          || '   (expect true, if A is a countable call)' || chr(10);
--
--   INSERT INTO interaction_links (organization_id, from_interaction_id, to_interaction_id,
--                                  link_type, link_method, linked_by)
--   VALUES (v_org, v_b, v_c, 'same_case', 'agent_linked', 'verify 058');
--
--   PERFORM set_call_case(v_b, v_case);
--   r := r || 'hand link spread: C is on the case as '
--          || coalesce((SELECT case_link_method::text FROM interactions
--                        WHERE id = v_c AND case_id = v_case), 'NOT ON IT')
--          || '   (expect inferred)' || chr(10);
--   r := r || 'inferred link recorded: '
--          || (SELECT count(*) FROM change_history
--               WHERE entity_id = v_c AND action = 'linked' AND link_method = 'inferred'
--                 AND actor_kind = 'system' AND detail->>'via_interaction_id' = v_b::text)
--          || '   (expect 1)' || chr(10);
--
--   -- An inferred call is still a sink
--   r := r || 'second hop: ' || propagate_case_links(v_case) || '   (expect 0)' || chr(10);
--
--   -- Taking the converting call off clears the pointer, and method too
--   PERFORM clear_call_case(v_a);
--   r := r || 'after unlinking A: pointer '
--          || coalesce((SELECT converting_interaction_id::text FROM cases WHERE id = v_case), 'null')
--          || ', A method '
--          || coalesce((SELECT case_link_method::text FROM interactions WHERE id = v_a), 'null')
--          || '   (expect null, null)' || chr(10);
--
--   -- One call converts at most one case
--   v_case2 := create_case_for_call(v_a, 'pre_need', 'pre_need_subject', 'Verify', 'Other');
--   BEGIN
--     UPDATE cases SET converting_interaction_id = v_a WHERE id = v_case;
--     r := r || 'two cases converted by one call: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN unique_violation THEN r := r || 'two cases converted by one call refused' || chr(10); END;
--
--   -- Undo still works on a fresh case
--   PERFORM delete_case(v_case2);
--   r := r || 'undo: case gone ' || (NOT EXISTS (SELECT 1 FROM cases WHERE id = v_case2))
--          || ', A unlinked ' || (SELECT case_id IS NULL FROM interactions WHERE id = v_a)
--          || '   (expect true, true)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 058 (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
