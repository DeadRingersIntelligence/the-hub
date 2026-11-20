-- =============================================================================
-- 20261120T1000_revenue_moves_are_recorded.sql
-- The Hub — every revenue move leaves one history row, whoever is told.
--
-- WHY. Reports (backlog item 8) must say when a month changed after it
-- closed, and point at why (planning session, 19 Nov). Nothing records that
-- today. change_history has the field-level rows the writing functions write
-- — "set the case to Lost", "changed the service date" — but not what that
-- did to the REVENUE date: working that out afterwards needs the case's whole
-- state before and after, which history does not keep. The case_revenue_moved
-- notifications carry it in words, but they are one row per manager, none at
-- all for a firm with no managers (the 20261119T1510 review), and are not a
-- record to query.
--
-- Ordered first, ahead of the report functions, because a move that happens
-- before this exists cannot be recorded afterwards. None has yet outside a
-- rolled-back verification block, and production has no cases.
--
-- WHAT. case_revenue_moved_notify() (20261119T1510) already computes the old
-- and new revenue dates, the reason and the sentence, at the one point every
-- change passes through — a direct UPDATE included. It now also writes ONE
-- change_history row on the case, unconditionally:
--
--   entity 'case', action 'updated', the same sentence as the notification,
--   detail {field: 'revenue_date', from, to, reason, managers_notified}
--
-- so a report finds the months a change moved from `from` and `to`, and the
-- reason beside them; managers_notified puts "nobody was told" on the record
-- instead of leaving it to an absence. A change with no Hub user behind it is
-- recorded as actor_kind 'system', label 'Outside the app'. The case's
-- Timeline shows the row as it shows every other.
--
-- It sits beside, not instead of, the field-level row the writing function
-- already wrote: that one says what was done ("set the case to Lost: …"),
-- this one what it did to revenue. A report reads only field = 'revenue_date'.
--
-- NOTHING ELSE CHANGES. The trigger still fires on the same columns, asks the
-- same rule, notifies the same people with the same words. The body is
-- 20261119T1510's, taken with pg_get_functiondef from a scratch rebuild of
-- main, with the sentence built once and the history row added after the
-- notifications.
--
-- NOT SAFE TO RUN TWICE: the precondition refuses if the body already writes
-- the row.
--
-- Requires: 016 (record_change), 20261119T1510 (case_revenue_moved_notify,
-- the body this replaces), 20261103T1200 (record_migration).
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 0. Precondition: the body this replaces is 20261119T1510's reviewed one
-- -----------------------------------------------------------------------------
DO $$
DECLARE v text;
BEGIN
  SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = to_regprocedure('case_revenue_moved_notify()');
  IF v IS NOT NULL AND position('managers_notified' IN (SELECT prosrc FROM pg_proc WHERE oid = to_regprocedure('case_revenue_moved_notify()'))) > 0 THEN
    RAISE EXCEPTION 'case_revenue_moved_notify already writes the revenue_date row — 20261120T1000 has run here'
      USING HINT = 'This file is not safe to run twice. Nothing has been changed.';
  END IF;
  IF v IS DISTINCT FROM 'ab8d167894b42b6688637dbdaa9785a8' THEN
    RAISE EXCEPTION 'case_revenue_moved_notify is not 20261119T1510''s reviewed body (found %); stop and compare', v;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 1. The trigger function, recording as well as notifying
--
-- SECURITY DEFINER and search_path unchanged. CREATE OR REPLACE keeps the
-- trigger, the revoked grants and — replaced below — the comment.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.case_revenue_moved_notify()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_old date; v_new date; v_family text; v_actor_id uuid; v_actor text;
  v_reason text; v_case_words text; v_what text; v_money text; v_why text;
  v_body text; v_told int;
BEGIN
  v_old := case_revenue_date_for(OLD.status, OLD.served_on, OLD.booked_service_date);
  v_new := case_revenue_date_for(NEW.status, NEW.served_on, NEW.booked_service_date);
  IF v_old IS NOT DISTINCT FROM v_new THEN RETURN NULL; END IF;

  SELECT d.last_name INTO v_family
    FROM case_decedents cd JOIN decedents d ON d.id = cd.decedent_id
   WHERE cd.case_id = NEW.id AND d.last_name IS NOT NULL
   ORDER BY d.last_name LIMIT 1;

  v_actor_id := current_user_id();
  SELECT full_name INTO v_actor FROM users WHERE id = v_actor_id;
  v_reason := NULLIF(current_setting('hub.case_change_reason', true), '');

  -- "the Ellis family's case", or "a case with no family name" when no
  -- decedent has a last name yet.
  v_case_words := COALESCE('the ' || v_family || ' family''s case', 'a case with no family name');

  -- What was done. Several columns can change in one UPDATE; the first that
  -- applies names it, and the money clause below says what it did to revenue
  -- whichever it was.
  v_what := CASE
    WHEN NEW.status = 'lost' AND OLD.status IS DISTINCT FROM 'lost'
      THEN format('marked %s lost', v_case_words)
    WHEN NEW.status = 'on_hold' AND OLD.status IS DISTINCT FROM 'on_hold'
      THEN format('put %s on hold', v_case_words)
    WHEN OLD.status = 'lost' AND NEW.status IS DISTINCT FROM 'lost'
      THEN format('reinstated %s', v_case_words)
    WHEN OLD.status = 'on_hold' AND NEW.status IS DISTINCT FROM 'on_hold'
      THEN format('took %s off hold', v_case_words)
    WHEN OLD.served_on IS NULL AND NEW.served_on IS NOT NULL
      THEN format('confirmed %s as served on %s', v_case_words,
                  to_char(NEW.served_on, 'FMMon FMDD, YYYY'))
    WHEN OLD.served_on IS NOT NULL AND NEW.served_on IS NULL
      THEN format('removed the service date (%s) from %s',
                  to_char(OLD.served_on, 'FMMon FMDD, YYYY'), v_case_words)
    WHEN NEW.served_on IS DISTINCT FROM OLD.served_on
      THEN format('changed the service date on %s from %s to %s', v_case_words,
                  to_char(OLD.served_on, 'FMMon FMDD, YYYY'),
                  to_char(NEW.served_on, 'FMMon FMDD, YYYY'))
    WHEN NEW.booked_service_date IS NULL
      THEN format('cleared the booked service date (%s) on %s',
                  to_char(OLD.booked_service_date, 'FMMon FMDD, YYYY'), v_case_words)
    WHEN OLD.booked_service_date IS NULL
      THEN format('booked the service on %s for %s', v_case_words,
                  to_char(NEW.booked_service_date, 'FMMon FMDD, YYYY'))
    ELSE format('moved the booked service on %s from %s to %s', v_case_words,
                to_char(OLD.booked_service_date, 'FMMon FMDD, YYYY'),
                to_char(NEW.booked_service_date, 'FMMon FMDD, YYYY'))
  END;

  v_money := CASE
    WHEN v_new IS NULL THEN format('it no longer counts as revenue (it counted on %s)',
                                   to_char(v_old, 'FMMon FMDD, YYYY'))
    WHEN v_old IS NULL THEN format('it now counts as revenue on %s',
                                   to_char(v_new, 'FMMon FMDD, YYYY'))
    ELSE format('its revenue moved from %s to %s',
                to_char(v_old, 'FMMon FMDD, YYYY'), to_char(v_new, 'FMMon FMDD, YYYY'))
  END;

  v_why := CASE
    WHEN v_reason IS NOT NULL THEN '. Reason: ' || v_reason
    WHEN case_change_needs_reason(OLD.status, OLD.served_on, OLD.booked_service_date,
                                  NEW.status, NEW.served_on, NEW.booked_service_date)
      THEN '. No reason recorded'
    ELSE ''
  END;

  v_body := COALESCE(v_actor, 'Someone') || ' ' || v_what || ' — ' || v_money || v_why;

  INSERT INTO notifications
    (organization_id, user_id, event, subject_entity, subject_id, body)
  SELECT NEW.organization_id, r.user_id,
         'case_revenue_moved'::notification_event,
         'case'::history_entity,
         NEW.id,
         v_body
    FROM case_notification_recipients(NEW.organization_id) r
   WHERE r.user_id IS DISTINCT FROM v_actor_id;
  GET DIAGNOSTICS v_told = ROW_COUNT;

  -- The durable record of the move (20261120T1000), written whether or not
  -- anyone was told: the same sentence, plus the two revenue dates, so a
  -- report can say which months a change moved without reconstructing the
  -- case's state, and managers_notified, so "nobody was told" is on the
  -- record rather than inferred from an absence. A change with no Hub user
  -- behind it went round the app (a direct UPDATE); it is recorded as such.
  PERFORM record_change(
    NEW.organization_id, 'case', NEW.id, 'updated',
    CASE WHEN v_actor_id IS NULL THEN 'system' ELSE 'user' END::actor_kind,
    COALESCE(v_actor, 'Outside the app'),
    v_body,
    v_actor_id,
    jsonb_build_object('field', 'revenue_date', 'from', v_old, 'to', v_new,
                       'reason', v_reason, 'managers_notified', v_told));

  RETURN NULL;
END $function$;

COMMENT ON FUNCTION case_revenue_moved_notify() IS
  'Tells a firm''s managers when a case''s revenue date changes '
  '(case_revenue_date_for, OLD against NEW): lost or put on hold after '
  'counting, reinstated or taken off hold, a served date confirmed in another '
  'month, changed or removed, a passed booked date moved. One '
  'case_revenue_moved notification per manager, not to whoever made the '
  'change, carrying the reason, or "No reason recorded" when one was needed '
  '(case_change_needs_reason) and none came — a change that went round the '
  'functions. AND, since 20261120T1000, ALWAYS one change_history row on the '
  'case with detail.field = ''revenue_date'', from, to, reason and '
  'managers_notified — the durable record of the move, written whether or '
  'not anyone was told; reports read it. Not gated by preferences. No '
  'warn-and-continue, unlike case_converted_notify, deliberately: a failing '
  'insert rolls the change back. SECURITY DEFINER because only the Hub '
  'inserts notifications; a trigger, so there is no grantable entry point.';

-- -----------------------------------------------------------------------------
-- 2. And it is the body that was reviewed
-- -----------------------------------------------------------------------------
DO $$
DECLARE v text;
BEGIN
  SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = 'case_revenue_moved_notify()'::regprocedure;
  IF v IS DISTINCT FROM 'fc1e7e84bf1c45cb2f9c9e56a8ace22c' THEN
    RAISE EXCEPTION 'case_revenue_moved_notify installed as % — not the reviewed body. Nothing has been kept.', v;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 3. The ledger
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261120T1000_revenue_moves_are_recorded.sql',
    NULL,
    'case_revenue_moved_notify also writes one change_history row per revenue '
    'move (detail.field revenue_date, from, to, reason, managers_notified), '
    'whether or not anyone is notified. For reports: which months a change '
    'moved, and why.');
END $rec$;

COMMIT;

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- Fixture: a director and a manager at the first firm with a lost status; a
-- second firm whose only user is a professional. Line 2 reads the row back AS
-- the director, so a row hidden by row-level security reads as NONE.
--
-- RUN ON A SCRATCH REBUILD, 20 Nov — every migration on main, in order, with
-- this file: every line matched. NOT YET RUN ON STAGING.
--
-- DO $$
-- DECLARE
--   r text := ''; t date := current_date;
--   v_org uuid; v_org2 uuid; v_dir uuid; v_mgr uuid; v_solo uuid;
--   a_dir uuid := gen_random_uuid(); a_mgr uuid := gen_random_uuid(); a_solo uuid := gen_random_uuid();
--   c_lost uuid; c_direct uuid; c_quiet uuid; c_none uuid; v_dec uuid;
--   row_ change_history;
-- BEGIN
--   PERFORM set_config('app.is_internal', 'on', true);
--   SELECT id INTO v_org FROM organizations
--    WHERE EXISTS (SELECT 1 FROM picklist_items i WHERE i.organization_id = organizations.id
--                     AND i.picklist = 'case_status' AND i.case_outcome = 'lost')
--    ORDER BY created_at LIMIT 1;
--   IF v_org IS NULL THEN RAISE EXCEPTION 'no organization with a lost status — cannot build the fixture'; END IF;
--
--   INSERT INTO users (email, full_name, auth_user_id, active_organization_id)
--   VALUES ('zzz-a-dir@example.invalid', 'ZZZ Director', a_dir, v_org) RETURNING id INTO v_dir;
--   INSERT INTO users (email, full_name, auth_user_id, active_organization_id)
--   VALUES ('zzz-a-mgr@example.invalid', 'ZZZ Manager', a_mgr, v_org) RETURNING id INTO v_mgr;
--   INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id) VALUES
--     (v_dir, 'organization', 'professional', v_org), (v_mgr, 'organization', 'manager', v_org);
--
--   INSERT INTO decedents (organization_id, first_name, last_name)
--   VALUES (v_org, 'ZZZ', 'Zrecord') RETURNING id INTO v_dec;
--   INSERT INTO cases (organization_id, need_type, created_by, served_on, status_item_id)
--   VALUES (v_org, 'at_need', v_dir, t - 5, case_status_default(v_org, 'active')) RETURNING id INTO c_lost;
--   INSERT INTO case_decedents (case_id, decedent_id) VALUES (c_lost, v_dec);
--   INSERT INTO cases (organization_id, need_type, created_by, served_on, status_item_id)
--   VALUES (v_org, 'at_need', v_dir, t - 5, case_status_default(v_org, 'active')) RETURNING id INTO c_direct;
--   INSERT INTO cases (organization_id, need_type, created_by, status_item_id)
--   VALUES (v_org, 'pre_need', v_dir, case_status_default(v_org, 'active')) RETURNING id INTO c_none;
--
--   -- A firm whose only user is a professional: nobody to notify.
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ No Managers A', 'funeral_home') RETURNING id INTO v_org2;
--   INSERT INTO users (email, full_name, auth_user_id, active_organization_id)
--   VALUES ('zzz-a-solo@example.invalid', 'ZZZ Solo', a_solo, v_org2) RETURNING id INTO v_solo;
--   INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id)
--   VALUES (v_solo, 'organization', 'professional', v_org2);
--   INSERT INTO cases (organization_id, need_type, created_by, served_on, status_item_id)
--   VALUES (v_org2, 'at_need', v_solo, t - 5, case_status_default(v_org2, 'active')) RETURNING id INTO c_quiet;
--
--   -- 1. A change with no Hub user behind it (the owner, here) still records.
--   UPDATE cases SET served_on = t - 4 WHERE id = c_direct;
--   SELECT * INTO row_ FROM change_history WHERE entity = 'case' AND entity_id = c_direct AND detail->>'field' = 'revenue_date';
--   r := r || '1. direct UPDATE — revenue row: ' || COALESCE(row_.actor_kind::text || ' / ' || row_.actor_label
--             || ' / from ' || (row_.detail->>'from') || ' to ' || (row_.detail->>'to')
--             || ' / told ' || (row_.detail->>'managers_notified'), 'NONE (BAD)')
--          || '   (expect system / Outside the app / from ' || (t - 5) || ' to ' || (t - 4) || ' / told 1)' || chr(10)
--          || '   sentence: ' || COALESCE(row_.summary, 'NONE') || chr(10);
--
--   -- ---- as the director ------------------------------------------------------
--   PERFORM set_config('app.is_internal', 'off', true);
--   PERFORM set_config('request.jwt.claims', json_build_object('sub', a_dir::text)::text, true);
--   PERFORM set_config('role', 'authenticated', true);
--
--   -- 2. A loss with a reason.
--   PERFORM set_case_lost(c_lost, true, 'ZZZ family disputed');
--   SELECT * INTO row_ FROM change_history WHERE entity = 'case' AND entity_id = c_lost AND detail->>'field' = 'revenue_date';
--   r := r || '2. lost with a reason, read back as the director — revenue row: '
--          || COALESCE(row_.actor_kind::text || ' / ' || row_.actor_label
--             || ' / from ' || (row_.detail->>'from') || ' to ' || COALESCE(row_.detail->>'to', 'null')
--             || ' / reason ' || COALESCE(row_.detail->>'reason', 'null') || ' / told ' || (row_.detail->>'managers_notified'), 'NONE (BAD — or the director cannot read it)')
--          || '   (expect user / ZZZ Director / from ' || (t - 5) || ' to null / reason ZZZ family disputed / told 1)' || chr(10)
--          || '   sentence: ' || COALESCE(row_.summary, 'NONE') || chr(10)
--          || '   the field-level row is still there too: '
--          || EXISTS (SELECT 1 FROM change_history WHERE entity = 'case' AND entity_id = c_lost AND detail->>'field' = 'status')
--          || '   (expect true — this row sits beside it, not instead of it)' || chr(10);
--
--   -- 3. Reinstating: money coming back, recorded the other way.
--   PERFORM set_case_lost(c_lost, false);
--   r := r || '3. reinstated — revenue rows on the case: '
--          || (SELECT count(*) FROM change_history WHERE entity = 'case' AND entity_id = c_lost AND detail->>'field' = 'revenue_date')
--          || ', the newest from ' || COALESCE((SELECT COALESCE(detail->>'from', 'null') || ' to ' || (detail->>'to') FROM change_history
--                                      WHERE entity = 'case' AND entity_id = c_lost AND detail->>'field' = 'revenue_date'
--                                        AND detail->>'from' IS NULL LIMIT 1), 'NONE (BAD)')
--          || '   (expect 2, the newest from null to ' || (t - 5) || ')' || chr(10);
--
--   -- 4. A change that moves no revenue writes no revenue row.
--   PERFORM set_case_booked_date(c_none, t + 30);
--   r := r || '4. future booking — revenue rows: '
--          || (SELECT count(*) FROM change_history WHERE entity = 'case' AND entity_id = c_none AND detail->>'field' = 'revenue_date')
--          || '   (expect 0)' || chr(10);
--
--   -- 5. Nobody to tell: the row is written all the same.
--   PERFORM set_config('request.jwt.claims', json_build_object('sub', a_solo::text)::text, true);
--   PERFORM set_case_lost(c_quiet, true, 'ZZZ comped, no managers here');
--   PERFORM set_config('role', 'postgres', true);
--   SELECT * INTO row_ FROM change_history WHERE entity = 'case' AND entity_id = c_quiet AND detail->>'field' = 'revenue_date';
--   r := r || '5. a firm with no managers — notifications: '
--          || (SELECT count(*) FROM notifications WHERE subject_id = c_quiet)
--          || ', revenue row: ' || COALESCE('told ' || (row_.detail->>'managers_notified') || ' / reason ' || (row_.detail->>'reason'), 'NONE (BAD)')
--          || '   (expect 0, told 0 / reason ZZZ comped, no managers here)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261120T1000_revenue_moves_are_recorded (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
