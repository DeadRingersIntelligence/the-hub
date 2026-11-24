-- =============================================================================
-- 20261124T1555_a_case_gains_its_decedent_and_arranger.sql
-- The Hub — a case's decedent and arranging person, set after the case exists.
--
-- WHY (Mandie, 24 November; hellophone findings 3 and 4). A case gets its
-- decedent through case_decedents and its arranger through
-- cases.arranging_person_id, and nothing in the app sets either after the case
-- is made. In a funeral home that is the normal order: the first call comes
-- in, the case is opened, and the decedent's details arrive minutes or hours
-- later. The Ellis case on staging is at-need with nobody on it, though all
-- three of its contacts are linked to James Ellis.
--
-- WHY HUB FUNCTIONS, NOT DIRECT WRITES. create_case_for_call already refuses
-- another firm's decedent, follows merges, and pairs the decedent's status
-- with the case's need type (decedent_status_for_need_type). A direct insert
-- into case_decedents would skip all three: case_decedents has no firm column
-- and its policy checks only the case's firm, so a decedent id from another
-- firm would link (one of the five join tables the 24 November count found).
-- These functions do what create_case_for_call does, for a case that exists:
--   * add_case_decedent(case, decedent | new last/first name, date of death):
--     the decedent must be at the case's firm (merges followed), or is
--     created there with the status the case's need type implies; the
--     pairing is checked either way; a history row says who added whom;
--   * remove_case_decedent(case, decedent): removes, with a history row. NO
--     NEW RULE (Mandie: the pairing rule should answer it). It does: the
--     pairing compares a decedent with the case, and a case with nobody on it
--     has nothing to compare, so removal is always allowed, the last one
--     included. That is the state every case is in before its decedent is
--     known, and the state create-then-add passes through. NOTE: nothing
--     before this file required an at-need case to have a decedent either
--     (the Ellis case is one), so "the pairing refuses an at-need case with
--     nobody" was not a rule that existed; flagged in the PR;
--   * set_case_arranging_person(case, person | NULL): the person must be
--     active at the case's firm, not merged; NULL clears; a history row.
-- A SWAP is two calls, remove then add. Nothing checks the case between
-- them (removal has no rule), so there is no middle state to trip.
--
-- THE CONVERSION NOTIFICATION, ONCE PER CASE (Mandie: fire it on the first
-- decedent, one rule, one place). case_converted_notify fired when the new
-- row was the case's only decedent, so removing everyone and adding one back
-- would notify twice. The case now remembers: cases.conversion_notified, set
-- by the trigger the first time and never cleared. Backfilled true for every
-- case that has a decedent now. Not inferred from notification rows: a firm
-- with nobody subscribed writes none, and "once" would mean "once someone
-- was listening".
--
-- authenticated HOLDS TABLE-LEVEL UPDATE ON cases, so a new column is
-- writable by the app unless something says otherwise. A flag the app could
-- reset would re-send the notification, or suppress it. So a trigger refuses
-- any change to conversion_notified except from inside another trigger
-- (pg_trigger_depth() >= 2, which an API caller can't produce), and refuses
-- turning it back to false at all. The same grant means arranging_person_id
-- stays writable directly, past set_case_arranging_person's firm check; on
-- production, with its single-column key, nothing else stops another firm's
-- person being set. That is family A's to close, not this file's.
--
-- THE APP (db/README.md, "A schema change is done when the app works"):
-- hellophone reads case_decedents and arranging_person_id (case page, contact
-- detail's case card, the + Link picker, caseName). The new functions are
-- called only by the case page's new controls (hellophone, to follow). The
-- conversion notification shows in the bell. The PR lists the pages.
--
-- Requires: 20261119T1900 (create_case_for_call, set_case_need_type,
--           decedent_status_for_need_type), 20261102T1600
--           (case_converted_notify, as pinned), 20261103T1200.
-- NOT SAFE TO RUN TWICE: section 1 refuses once the column exists.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Preconditions: the bodies this depends on, as reviewed
-- -----------------------------------------------------------------------------
DO $$
DECLARE f text; v text;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'cases'::regclass AND attname = 'conversion_notified' AND NOT attisdropped) THEN
    RAISE EXCEPTION 'cases.conversion_notified already exists: this file has run here';
  END IF;
  FOR f, v IN VALUES
      ('case_converted_notify()', '1fe7e035fbeb17ab56302dbb4e4247eb'),
      ('decedent_status_for_need_type(case_need_type, decedent_status)', '76e211e117c22ada1888d9c6f10e6b63'),
      ('create_case_for_call(uuid, case_need_type, decedent_status, text, text, date, uuid, text, uuid[])', 'a7fe724b27a640ae91d0f58a15c5f82d'),
      ('set_case_need_type(uuid, case_need_type, uuid, date)', '4497b842eed7c61e49ba15c482b3a856'),
      ('record_change(uuid, history_entity, uuid, history_action, actor_kind, text, text, uuid, jsonb, link_method)',
       '130654ec3b66364423609c08b9fffdd5') LOOP
    IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure(f)) IS DISTINCT FROM v THEN
      RAISE EXCEPTION '% is not the body this file was reviewed against (md5 %): stop and read it',
        f, COALESCE((SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure(f)), 'missing');
    END IF;
  END LOOP;
  IF to_regprocedure('hand_link_actor()') IS NULL THEN
    RAISE EXCEPTION 'hand_link_actor() is missing';
  END IF;
  IF (SELECT pg_get_triggerdef(oid) FROM pg_trigger WHERE tgrelid = 'case_decedents'::regclass AND tgname = 'case_converted_notify_t')
     NOT LIKE '%AFTER INSERT ON public.case_decedents FOR EACH ROW EXECUTE FUNCTION case_converted_notify()%' THEN
    RAISE EXCEPTION 'case_converted_notify_t is not the AFTER INSERT row trigger this file expects: stop and read it';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. A case remembers that it converted
-- -----------------------------------------------------------------------------
ALTER TABLE cases ADD COLUMN conversion_notified boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN cases.conversion_notified IS
  'The case has had a decedent, so its conversion notification has been sent '
  '(or was due: a firm with nobody subscribed is told no one). Set once by '
  'case_converted_notify, never cleared, never set by hand '
  '(cases_conversion_notified_guard). It keeps the notification to once per '
  'case when decedents are removed and added (20261124T1555).';

-- Every case with a decedent now has converted. cases_touch is held off for
-- the backfill, so no case's updated_at moves for a column it didn't have.
ALTER TABLE cases DISABLE TRIGGER cases_touch;
UPDATE cases c SET conversion_notified = true
 WHERE EXISTS (SELECT 1 FROM case_decedents cd WHERE cd.case_id = c.id);
ALTER TABLE cases ENABLE TRIGGER cases_touch;

CREATE FUNCTION cases_conversion_notified_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.conversion_notified AND NOT NEW.conversion_notified THEN
    RAISE EXCEPTION 'a case that has converted stays converted: conversion_notified is never cleared';
  END IF;
  -- Depth 1 is this trigger fired by a statement someone ran; 2 or more is
  -- this trigger fired by a statement another trigger ran (case_converted_notify).
  IF pg_trigger_depth() < 2
     AND NEW.conversion_notified IS DISTINCT FROM (CASE WHEN TG_OP = 'UPDATE' THEN OLD.conversion_notified ELSE false END) THEN
    RAISE EXCEPTION 'conversion_notified is set by the Hub when a case gets its first decedent, not by hand';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER cases_conversion_notified_guard_t
  BEFORE INSERT OR UPDATE OF conversion_notified ON cases
  FOR EACH ROW EXECUTE FUNCTION cases_conversion_notified_guard();
REVOKE ALL ON FUNCTION cases_conversion_notified_guard() FROM PUBLIC, anon, authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 3. The notification, once per case (the body otherwise as installed)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION case_converted_notify()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_org uuid; v_need case_need_type; v_conv uuid;
  v_last text; v_caller text; v_actor_id uuid; v_actor text; v_body text;
BEGIN
  -- Once per case, not once per "first decedent" (20261124T1555, Mandie):
  -- with a decedent removable, "no other decedent" is true again after every
  -- one is removed, and adding one back would notify a second time. The case
  -- remembers instead. A second decedent added later is still not a
  -- conversion. The flag is set outside the notification block below: it
  -- records that the case converted, whether or not anyone was told.
  IF (SELECT conversion_notified FROM cases WHERE id = NEW.case_id) THEN
    RETURN NULL;
  END IF;
  UPDATE cases SET conversion_notified = true WHERE id = NEW.case_id;

  -- A notification is a courtesy on top of the conversion; it must never be
  -- able to veto one. Anything that goes wrong below becomes a WARNING and
  -- the conversion carries on without a notification.
  --
  -- WHERE THE WARNING GOES, stated plainly rather than implied: the Postgres
  -- log, which on Supabase is Logs -> Postgres. Nothing watches it. This is
  -- better than silence only if somebody looks, and the string
  -- "case_converted_notify" is there so a search finds every instance.
  --
  -- Only the notification work is inside. The first-decedent check above
  -- stays out: it decides whether this is a conversion at all, and a fault
  -- there is a fault in the trigger rather than in notifying.
  BEGIN
    SELECT c.organization_id, c.need_type, c.converting_interaction_id
      INTO v_org, v_need, v_conv
      FROM cases c WHERE c.id = NEW.case_id;
    IF v_org IS NULL THEN RETURN NULL; END IF;

    SELECT d.last_name INTO v_last FROM decedents d WHERE d.id = NEW.decedent_id;

    SELECT COALESCE(ct.full_name, ct.business_name) INTO v_caller
      FROM interactions i
      JOIN contacts ct ON ct.id = i.contact_id
     WHERE i.id = v_conv;

    v_actor_id := current_user_id();
    SELECT full_name INTO v_actor FROM users WHERE id = v_actor_id;

    -- The family's last name first: a manager knows a case as "the Ellis case",
    -- and the caller may be a neighbour. The need-type clause drops when there
    -- is nothing to say rather than rendering "unknown". Nothing here comes
    -- from a caller — the text is composed from the case's own rows, which is
    -- what keeps a definer function this narrow.
    v_body := format('%s started a case for the %s family',
                     COALESCE(v_actor, 'Someone'),
                     COALESCE(v_last, 'unnamed'))
           || COALESCE(' — caller ' || v_caller, '')
           || COALESCE(', ' || replace(v_need::text, '_', '-'), '');

    INSERT INTO notifications
      (organization_id, user_id, event, subject_entity, subject_id, body)
    -- Cast explicitly. The reason has changed with the handler above and the
    -- comment has to change with it: a type error here no longer aborts
    -- create_case_for_call(), it becomes a warning and the notification is
    -- silently not sent. That is a weaker failure, not a safer one — it is
    -- the kind nobody finds. The seed in 20261030T1930 proved this shape can
    -- fail on literal resolution; this is the copy that would fail unseen.
    SELECT v_org, r.user_id,
           'case_converted'::notification_event,
           'case'::history_entity,
           NEW.case_id, v_body
      FROM case_notification_recipients(v_org) r
     WHERE r.user_id IS DISTINCT FROM v_actor_id          -- not the person who did it
       AND EXISTS (SELECT 1 FROM notification_preferences p
                    WHERE p.user_id = r.user_id
                      AND p.event = 'case_converted'
                      AND p.channel = 'desktop'
                      AND p.enabled);
  EXCEPTION WHEN others THEN
    RAISE WARNING 'case_converted_notify: no notification for case %: % (%)',
      NEW.case_id, SQLERRM, SQLSTATE;
  END;

  RETURN NULL;
END $function$;

-- -----------------------------------------------------------------------------
-- 4. Adding a decedent to a case
-- -----------------------------------------------------------------------------
CREATE FUNCTION add_case_decedent(p_case uuid, p_decedent uuid DEFAULT NULL,
                                  p_last text DEFAULT NULL, p_first text DEFAULT NULL,
                                  p_date_of_death date DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE a record; v_org uuid; v_need case_need_type; v_dec uuid; v_status decedent_status;
        v_name text; v_new boolean := false;
BEGIN
  SELECT * INTO a FROM hand_link_actor();
  SELECT organization_id, need_type INTO v_org, v_need FROM cases WHERE id = p_case FOR UPDATE;
  IF v_org IS NULL THEN RAISE EXCEPTION 'no such case'; END IF;

  IF p_decedent IS NOT NULL THEN
    IF NULLIF(btrim(COALESCE(p_last, '')), '') IS NOT NULL OR NULLIF(btrim(COALESCE(p_first, '')), '') IS NOT NULL
       OR p_date_of_death IS NOT NULL THEN
      RAISE EXCEPTION 'choose someone already recorded, or give a new person''s name, not both';
    END IF;
    -- At this firm, merges followed: as create_case_for_call.
    SELECT COALESCE(d.merged_into, d.id) INTO v_dec
      FROM decedents d WHERE d.id = p_decedent AND d.organization_id = v_org;
    IF v_dec IS NULL THEN
      RAISE EXCEPTION 'choose a decedent at this firm';
    END IF;
    SELECT status, full_name INTO v_status, v_name FROM decedents WHERE id = v_dec;
  ELSE
    IF NULLIF(btrim(COALESCE(p_last, '')), '') IS NULL THEN
      RAISE EXCEPTION 'a new person needs a last name';
    END IF;
    -- The status the case's need type implies, as create_case_for_call's
    -- callers choose it: at-need someone who has died, pre-need someone
    -- living, imminent someone close.
    v_status := decedent_status_for_need_type(v_need, NULL);
    IF p_date_of_death IS NOT NULL AND v_status NOT IN ('at_need', 'deceased') THEN
      RAISE EXCEPTION 'a date of death only goes with an at-need case';
    END IF;
    IF p_date_of_death > current_date THEN
      RAISE EXCEPTION 'a date of death can''t be in the future';
    END IF;
    INSERT INTO decedents (organization_id, first_name, last_name, status, date_of_death)
    VALUES (v_org, NULLIF(btrim(COALESCE(p_first, '')), ''), btrim(p_last), v_status, p_date_of_death)
    RETURNING id, full_name INTO v_dec, v_name;
    v_new := true;
    PERFORM record_change(v_org, 'decedent', v_dec, 'created', 'user', a.v_name,
      format('%s recorded %s', a.v_name, COALESCE(v_name, 'a person')), a.v_user,
      jsonb_build_object('status', v_status, 'date_of_death', p_date_of_death, 'via_case', p_case));
  END IF;

  -- The pairing create_case_for_call enforces: this person's status must go
  -- with this case's need type.
  IF decedent_status_for_need_type(v_need, v_status) <> v_status THEN
    RAISE EXCEPTION '% % case doesn''t go with someone recorded as %',
      CASE WHEN v_need = 'at_need' OR v_need::text LIKE 'i%' THEN 'An' ELSE 'A' END,
      replace(v_need::text, '_', '-'), replace(v_status::text, '_', '-')
      USING HINT = 'Change the case''s need type first, or choose someone else.';
  END IF;
  IF EXISTS (SELECT 1 FROM case_decedents WHERE case_id = p_case AND decedent_id = v_dec) THEN
    RAISE EXCEPTION '% is already on this case', COALESCE(v_name, 'That person');
  END IF;

  INSERT INTO case_decedents (case_id, decedent_id) VALUES (p_case, v_dec);
  PERFORM record_change(v_org, 'case', p_case, 'linked', 'user', a.v_name,
    format('%s added %s to the case', a.v_name, COALESCE(v_name, 'a person')), a.v_user,
    jsonb_build_object('field', 'decedent', 'decedent_id', v_dec, 'created', v_new),
    'confirmed');   -- a person chose it: a link made by hand is confirmed (change_history_link_ck)
  RETURN v_dec;
END $$;
COMMENT ON FUNCTION add_case_decedent(uuid, uuid, text, text, date) IS
  'Puts a decedent on an existing case: someone already recorded at the case''s '
  'firm (merges followed), or a new person, created with the status the case''s '
  'need type implies. The need-type pairing is checked either way. A case''s '
  'first decedent sends its conversion notification, once per case '
  '(20261124T1555).';

-- -----------------------------------------------------------------------------
-- 5. Removing one
-- -----------------------------------------------------------------------------
CREATE FUNCTION remove_case_decedent(p_case uuid, p_decedent uuid)
RETURNS void LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE a record; v_org uuid; v_name text;
BEGIN
  SELECT * INTO a FROM hand_link_actor();
  SELECT organization_id INTO v_org FROM cases WHERE id = p_case FOR UPDATE;
  IF v_org IS NULL THEN RAISE EXCEPTION 'no such case'; END IF;
  SELECT d.full_name INTO v_name FROM case_decedents cd JOIN decedents d ON d.id = cd.decedent_id
   WHERE cd.case_id = p_case AND cd.decedent_id = p_decedent;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'that person isn''t on this case';
  END IF;
  -- No rule about who's left: see the header. A case with nobody on it is
  -- what every case is before its decedent is known.
  DELETE FROM case_decedents WHERE case_id = p_case AND decedent_id = p_decedent;
  PERFORM record_change(v_org, 'case', p_case, 'unlinked', 'user', a.v_name,
    format('%s took %s off the case', a.v_name, COALESCE(v_name, 'a person')), a.v_user,
    jsonb_build_object('field', 'decedent', 'decedent_id', p_decedent));
END $$;
COMMENT ON FUNCTION remove_case_decedent(uuid, uuid) IS
  'Takes a decedent off a case, with a history row. Always allowed, the last one '
  'included; the person''s own record is untouched (20261124T1555).';

-- -----------------------------------------------------------------------------
-- 6. The arranging person
-- -----------------------------------------------------------------------------
CREATE FUNCTION set_case_arranging_person(p_case uuid, p_person uuid DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE a record; v_org uuid; v_was uuid; v_was_name text; v_name text;
BEGIN
  SELECT * INTO a FROM hand_link_actor();
  SELECT organization_id, arranging_person_id INTO v_org, v_was FROM cases WHERE id = p_case FOR UPDATE;
  IF v_org IS NULL THEN RAISE EXCEPTION 'no such case'; END IF;
  IF p_person IS NOT NULL THEN
    SELECT full_name INTO v_name FROM people
     WHERE id = p_person AND organization_id = v_org AND status = 'active' AND merged_into IS NULL;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'choose someone active at this firm';
    END IF;
  END IF;
  IF p_person IS NOT DISTINCT FROM v_was THEN
    RETURN;
  END IF;
  SELECT full_name INTO v_was_name FROM people WHERE id = v_was;
  UPDATE cases SET arranging_person_id = p_person WHERE id = p_case;
  PERFORM record_change(v_org, 'case', p_case, 'updated', 'user', a.v_name,
    CASE WHEN p_person IS NULL THEN format('%s cleared who is arranging the case (was %s)', a.v_name, COALESCE(v_was_name, 'someone'))
         WHEN v_was IS NULL THEN format('%s set %s as arranging the case', a.v_name, v_name)
         ELSE format('%s changed who is arranging the case from %s to %s', a.v_name, COALESCE(v_was_name, 'someone'), v_name) END,
    a.v_user,
    jsonb_build_object('field', 'arranging_person_id', 'from', v_was, 'to', p_person));
END $$;
COMMENT ON FUNCTION set_case_arranging_person(uuid, uuid) IS
  'Sets who at the firm is arranging a case: someone active at the case''s firm, '
  'or NULL to clear, with a history row. The column stays writable directly '
  'under authenticated''s table grant; this is the checked way (20261124T1555).';

-- -----------------------------------------------------------------------------
-- 7. Who may call them: as the other case functions
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION add_case_decedent(uuid, uuid, text, text, date) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION remove_case_decedent(uuid, uuid) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION set_case_arranging_person(uuid, uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION add_case_decedent(uuid, uuid, text, text, date) TO authenticated;
GRANT EXECUTE ON FUNCTION remove_case_decedent(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION set_case_arranging_person(uuid, uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- 8. Record it
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261124T1555_a_case_gains_its_decedent_and_arranger.sql',
    NULL,
    'add_case_decedent, remove_case_decedent and set_case_arranging_person, with '
    'the firm, merge and need-type checks create_case_for_call makes; the '
    'conversion notification once per case (cases.conversion_notified, guarded).');
END $rec$;

COMMIT;

-- =============================================================================
-- Verification — run AFTER the file, as its own statement. One block,
-- everything rolled back by the closing RAISE. As authenticated, a manager
-- (Mo) at a fixture firm A, with an owner (Ola) who receives the conversion
-- notification; firm B holds a decedent and a person A must not reach.
--
-- DO $$
-- DECLARE
--   r text := ''; res text; n int; v_a uuid; v_b uuid; u_mo uuid; u_ola uuid; a_mo uuid := gen_random_uuid(); a_ola uuid := gen_random_uuid();
--   d_james uuid; d_liv uuid; d_liv2 uuid; d_bill uuid; d_new uuid; x uuid;
--   p_pat uuid; p_ina uuid; p_bea uuid; k_at uuid; k_pre uuid; k_none uuid; k_none2 uuid;
-- BEGIN
--   PERFORM set_config('app.is_internal', 'on', true);
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ verify cases A', 'funeral_home') RETURNING id INTO v_a;
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ verify cases B', 'funeral_home') RETURNING id INTO v_b;
--   INSERT INTO users (email, full_name, auth_user_id) VALUES ('zzz-mo@example.invalid', 'ZZZ Mo', a_mo) RETURNING id INTO u_mo;
--   INSERT INTO users (email, full_name, auth_user_id) VALUES ('zzz-ola@example.invalid', 'ZZZ Ola', a_ola) RETURNING id INTO u_ola;
--   INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id) VALUES
--     (u_mo, 'organization', 'manager', v_a), (u_ola, 'organization', 'owner', v_a);
--   INSERT INTO decedents (organization_id, first_name, last_name, status) VALUES (v_a, 'James', 'Ellis', 'at_need') RETURNING id INTO d_james;
--   INSERT INTO decedents (organization_id, first_name, last_name, status) VALUES (v_a, 'Liv', 'Lowe', 'pre_need_subject') RETURNING id INTO d_liv;
--   INSERT INTO decedents (organization_id, first_name, last_name, status) VALUES (v_a, 'Liv', 'Lowe (dup)', 'pre_need_subject') RETURNING id INTO d_liv2;
--   UPDATE decedents SET merged_into = d_liv WHERE id = d_liv2;
--   INSERT INTO decedents (organization_id, first_name, last_name, status) VALUES (v_b, 'Bill', 'Bee', 'at_need') RETURNING id INTO d_bill;
--   INSERT INTO people (organization_id, full_name, status) VALUES (v_a, 'ZZZ Pat', 'active') RETURNING id INTO p_pat;
--   INSERT INTO people (organization_id, full_name, status) VALUES (v_a, 'ZZZ Ina', 'inactive') RETURNING id INTO p_ina;
--   INSERT INTO people (organization_id, full_name, status) VALUES (v_b, 'ZZZ Bea', 'active') RETURNING id INTO p_bea;
--   INSERT INTO cases (organization_id, need_type) VALUES (v_a, 'at_need') RETURNING id INTO k_at;
--   INSERT INTO cases (organization_id, need_type) VALUES (v_a, 'pre_need') RETURNING id INTO k_pre;
--   INSERT INTO cases (organization_id, need_type) VALUES (v_a, 'at_need') RETURNING id INTO k_none;
--   INSERT INTO cases (organization_id, need_type) VALUES (v_a, 'at_need') RETURNING id INTO k_none2;
--   PERFORM set_config('app.is_internal', 'off', true);
--   PERFORM set_config('request.jwt.claims', json_build_object('sub', a_mo::text)::text, true);
--   PERFORM set_config('role', 'authenticated', true);
--
--   -- ---- 1. a case's first decedent: added, recorded, the owner told -------
--   -- Notifications are personal (20261120T2300): Mo can't read Ola's, so
--   -- every count of them below steps out of the role to read, and back.
--   x := add_case_decedent(k_at, d_james);
--   PERFORM set_config('role', 'none', true);
--   r := r || '1. James added to the at-need case: ' || (x = d_james)
--          || '; history: ' || (SELECT summary FROM change_history WHERE entity = 'case' AND entity_id = k_at AND action = 'linked')
--          || '; notifications for Ola: ' || (SELECT count(*) FROM notifications WHERE subject_id = k_at AND event = 'case_converted' AND user_id = u_ola)
--          || ', for Mo (who did it): ' || (SELECT count(*) FROM notifications WHERE subject_id = k_at AND event = 'case_converted' AND user_id = u_mo)
--          || '; case converted: ' || (SELECT conversion_notified FROM cases WHERE id = k_at)
--          || chr(10) || '   (expect true; ZZZ Mo added James Ellis to the case; 1, 0; true)' || chr(10);
--   PERFORM set_config('role', 'authenticated', true);
--
--   -- ---- 2. what it refuses -------------------------------------------------
--   res := '';
--   BEGIN PERFORM add_case_decedent(k_at, d_bill); res := res || 'firm B''s decedent: ALLOWED | ';
--   EXCEPTION WHEN OTHERS THEN res := res || 'firm B''s decedent: ' || SQLERRM || ' | '; END;
--   BEGIN PERFORM add_case_decedent(k_at, d_liv); res := res || 'a living person on an at-need case: ALLOWED | ';
--   EXCEPTION WHEN OTHERS THEN res := res || 'a living person on an at-need case: ' || SQLERRM || ' | '; END;
--   BEGIN PERFORM add_case_decedent(k_at, d_james); res := res || 'James again: ALLOWED | ';
--   EXCEPTION WHEN OTHERS THEN res := res || 'James again: ' || SQLERRM || ' | '; END;
--   BEGIN PERFORM add_case_decedent(k_at, d_james, 'Ellis'); res := res || 'an id and a name: ALLOWED | ';
--   EXCEPTION WHEN OTHERS THEN res := res || 'an id and a name: refused | '; END;
--   BEGIN PERFORM add_case_decedent(k_at, NULL, 'Ellis', 'Ann', current_date + 1); res := res || 'a future date of death: ALLOWED | ';
--   EXCEPTION WHEN OTHERS THEN res := res || 'a future date of death: refused | '; END;
--   BEGIN PERFORM add_case_decedent(k_pre, NULL, 'Lowe', 'Lee', current_date - 1); res := res || 'a date of death on a pre-need case: ALLOWED | ';
--   EXCEPTION WHEN OTHERS THEN res := res || 'a date of death on a pre-need case: refused | '; END;
--   BEGIN PERFORM add_case_decedent(k_pre, NULL, '  ', 'Lee'); res := res || 'no last name: ALLOWED';
--   EXCEPTION WHEN OTHERS THEN res := res || 'no last name: refused'; END;
--   r := r || '2. ' || res || chr(10)
--          || '   (expect "choose a decedent at this firm" | "An at-need case doesn''t go with someone recorded as pre-need-subject" | '
--          || '"James Ellis is already on this case" | refused | refused | refused | refused)' || chr(10);
--
--   -- ---- 3. merges followed; a new person; the second decedent is quiet ----
--   x := add_case_decedent(k_pre, d_liv2);
--   PERFORM set_config('role', 'none', true);
--   r := r || '3. Liv''s merged-away duplicate added to the pre-need case: lands on Liv ' || (x = d_liv)
--          || '; notifications for Ola on it: ' || (SELECT count(*) FROM notifications WHERE subject_id = k_pre AND event = 'case_converted');
--   PERFORM set_config('role', 'authenticated', true);
--   d_new := add_case_decedent(k_pre, NULL, 'Lowe', 'Lee');
--   PERFORM set_config('role', 'none', true);
--   r := r || '; a new person, Lee Lowe: at firm A ' || ((SELECT organization_id FROM decedents WHERE id = d_new) = v_a)
--          || ', status ' || (SELECT status::text FROM decedents WHERE id = d_new)
--          || '; notifications on the case now: ' || (SELECT count(*) FROM notifications WHERE subject_id = k_pre AND event = 'case_converted')
--          || chr(10) || '   (expect true; 1; true, pre_need_subject; 1: a second decedent is not a conversion)' || chr(10);
--   PERFORM set_config('role', 'authenticated', true);
--
--   -- ---- 4. remove, the last one too; the notification stays once -----------
--   PERFORM remove_case_decedent(k_at, d_james);
--   r := r || '4. James taken off (the case''s last): on the case ' || EXISTS (SELECT 1 FROM case_decedents WHERE case_id = k_at)
--          || ', history ' || (SELECT summary FROM change_history WHERE entity = 'case' AND entity_id = k_at AND action = 'unlinked');
--   PERFORM add_case_decedent(k_at, d_james);
--   PERFORM set_config('role', 'none', true);
--   r := r || '; added back: notifications for the case ' || (SELECT count(*) FROM notifications WHERE subject_id = k_at AND event = 'case_converted')
--          || ', still converted ' || (SELECT conversion_notified FROM cases WHERE id = k_at);
--   PERFORM set_config('role', 'authenticated', true);
--   BEGIN PERFORM remove_case_decedent(k_at, d_liv); res := 'ALLOWED';
--   EXCEPTION WHEN OTHERS THEN res := SQLERRM; END;
--   r := r || '; removing someone not on it: ' || res
--          || chr(10) || '   (expect false, ZZZ Mo took James Ellis off the case; 1, true: once per case; "that person isn''t on this case")' || chr(10);
--
--   -- ---- 5. the arranging person ----------------------------------------------
--   PERFORM set_case_arranging_person(k_at, p_pat);
--   r := r || '5. Pat set: ' || ((SELECT arranging_person_id FROM cases WHERE id = k_at) = p_pat)
--          || ', history "' || (SELECT summary FROM change_history WHERE entity = 'case' AND entity_id = k_at AND detail ->> 'field' = 'arranging_person_id' ORDER BY occurred_at DESC LIMIT 1) || '"';
--   res := '';
--   BEGIN PERFORM set_case_arranging_person(k_at, p_ina); res := res || 'inactive Ina: ALLOWED | ';
--   EXCEPTION WHEN OTHERS THEN res := res || 'inactive Ina: refused | '; END;
--   BEGIN PERFORM set_case_arranging_person(k_at, p_bea); res := res || 'firm B''s Bea: ALLOWED';
--   EXCEPTION WHEN OTHERS THEN res := res || 'firm B''s Bea: ' || SQLERRM; END;
--   SELECT count(*) INTO n FROM change_history WHERE entity = 'case' AND entity_id = k_at AND detail ->> 'field' = 'arranging_person_id';
--   PERFORM set_case_arranging_person(k_at, p_pat);
--   r := r || '; ' || res || '; Pat again records nothing new: ' || ((SELECT count(*) FROM change_history WHERE entity = 'case' AND entity_id = k_at AND detail ->> 'field' = 'arranging_person_id') = n);
--   PERFORM set_case_arranging_person(k_at, NULL);
--   r := r || '; cleared: ' || ((SELECT arranging_person_id FROM cases WHERE id = k_at) IS NULL)
--          || chr(10) || '   (expect true, "ZZZ Mo set ZZZ Pat as arranging the case"; inactive Ina: refused | firm B''s Bea: '
--          || '"choose someone active at this firm"; true; true)' || chr(10);
--
--   -- ---- 6. nobody sets conversion_notified by hand ---------------------------
--   -- k_none and k_none2 have never had a decedent: not converted.
--   res := '';
--   BEGIN UPDATE cases SET conversion_notified = false WHERE id = k_at; res := res || 'cleared as Mo: ALLOWED | ';
--   EXCEPTION WHEN OTHERS THEN res := res || 'cleared as Mo: refused | '; END;
--   BEGIN UPDATE cases SET conversion_notified = true WHERE id = k_none; res := res || 'set as Mo: ' || CASE WHEN FOUND THEN 'ALLOWED' ELSE 'NO ROW' END || ' | ';
--   EXCEPTION WHEN OTHERS THEN res := res || 'set as Mo: refused | '; END;
--   BEGIN INSERT INTO cases (organization_id, need_type, conversion_notified) VALUES (v_a, 'at_need', true); res := res || 'a new case born converted, as Mo: ALLOWED | ';
--   EXCEPTION WHEN OTHERS THEN res := res || 'a new case born converted, as Mo: refused | '; END;
--   PERFORM set_config('role', 'none', true);
--   BEGIN UPDATE cases SET conversion_notified = true WHERE id = k_none2; res := res || 'set as postgres: ' || CASE WHEN FOUND THEN 'ALLOWED' ELSE 'NO ROW' END;
--   EXCEPTION WHEN OTHERS THEN res := res || 'set as postgres: refused'; END;
--   r := r || '6. ' || res || '; and the Hub still sets it: k_none converts on its first decedent: ';
--   PERFORM set_config('role', 'authenticated', true);
--   PERFORM add_case_decedent(k_none, NULL, 'Ellis', 'Ruth');
--   r := r || (SELECT conversion_notified FROM cases WHERE id = k_none)
--          || chr(10) || '   (expect cleared as Mo: refused | set as Mo: refused | a new case born converted, as Mo: refused | '
--          || 'set as postgres: refused; true)' || chr(10);
--
--   -- ---- 7. who may call them -----------------------------------------------
--   r := r || '7. anon may run them: '
--          || (SELECT count(*) FILTER (WHERE has_function_privilege('anon', f, 'EXECUTE')) FROM unnest(ARRAY[
--               'add_case_decedent(uuid, uuid, text, text, date)', 'remove_case_decedent(uuid, uuid)', 'set_case_arranging_person(uuid, uuid)']) f)
--          || ' of 3; authenticated: '
--          || (SELECT count(*) FILTER (WHERE has_function_privilege('authenticated', f, 'EXECUTE')) FROM unnest(ARRAY[
--               'add_case_decedent(uuid, uuid, text, text, date)', 'remove_case_decedent(uuid, uuid)', 'set_case_arranging_person(uuid, uuid)']) f)
--          || ' of 3   (expect 0 of 3; 3 of 3)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261124T1555_a_case_gains_its_decedent_and_arranger (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
