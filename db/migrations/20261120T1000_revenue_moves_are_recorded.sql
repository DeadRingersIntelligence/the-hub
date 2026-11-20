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
-- recorded as actor_kind 'system', label 'Outside the app'.
--
-- ON THE APP SIDE — a conclusion, not something this file proves: the case
-- Timeline (hellophone src/components/CaseDetail.tsx, HistoryLine) renders
-- every change_history row with entity 'case' by its summary, whatever its
-- detail, so it shows this row like any other. Read in the code on 20 Nov;
-- none of the checks below exercise the app.
--
-- managers_notified EXCLUDES whoever made the change, as the notification
-- does. So a firm whose only manager marks a case lost records 0, which is
-- true and is NOT "nobody knows" — the person who did it knows. A report
-- must word 0 as "no other manager was told", not "nobody was told".
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
-- REVIEWED 20 Nov (planning session) on commit 39bfead. Changed in answer:
-- section 1b — the writers clear hub.case_change_reason after their UPDATE,
-- after a stale reason was reproduced (verification 6); the Timeline claim
-- is marked as a conclusion read from the app's code; managers_notified's
-- exclusion of the actor is stated for whoever writes the report.
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

  -- The three writers whose reason handling section 1b corrects.
  SELECT string_agg(e.sig || ' is ' || COALESCE(md5(p.prosrc), 'MISSING'), '; ') INTO v
    FROM (VALUES ('set_case_status(uuid,uuid,text)',      '85a68778620663755927e2efb6a3bc07'),
                 ('set_case_served(uuid,date,text)',      'fdf0093badeda31b9e50e656ad4cebf3'),
                 ('set_case_booked_date(uuid,date,text)', 'a5020b1f29616aa9c32ffacf2efea1f1')) e(sig, want)
    LEFT JOIN pg_proc p ON p.oid = to_regprocedure(e.sig)
   WHERE md5(p.prosrc) IS DISTINCT FROM e.want;
  IF v IS NOT NULL THEN
    RAISE EXCEPTION 'not 20261119T1510''s reviewed writers: %; stop and compare', v;
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

-- -----------------------------------------------------------------------------
-- 1b. The writers clear the reason once they have used it
--
-- FOUND IN REVIEW, and reproduced on the scratch rebuild before fixing: the
-- reason travels to the trigger in hub.case_change_reason, which is
-- transaction-local, and nothing cleared it. So in one transaction —
-- set_case_lost on one case with a reason, then a direct UPDATE of another
-- case's served date — the second move's permanent row read "Reason: <the
-- first case's reason>", attributed and confident. A table whose purpose is
-- explaining past months must not say something false.
--
-- Each writer now clears the setting right after its own UPDATE, so the
-- reason covers exactly the row it was given for. NOT in the trigger: it
-- fires per row, and clearing there would blank the reason for every row
-- after the first of a multi-row UPDATE. Each body is 20261119T1510's, taken
-- with pg_get_functiondef, with only that statement added. Signatures are
-- unchanged, so grants and comments stay.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_case_status(p_case uuid, p_status uuid, p_reason text DEFAULT NULL::text)
 RETURNS cases
 LANGUAGE plpgsql
AS $function$
DECLARE
  a record; r cases;
  v_org uuid; v_was case_status; v_was_item uuid; v_was_label text;
  v_outcome case_status; v_label text; v_served date; v_booked date;
  v_reason text;
BEGIN
  SELECT * INTO a FROM hand_link_actor();

  SELECT organization_id, status, status_item_id, served_on, booked_service_date
    INTO v_org, v_was, v_was_item, v_served, v_booked
    FROM cases WHERE id = p_case FOR UPDATE;
  IF v_org IS NULL THEN RAISE EXCEPTION 'no such case'; END IF;

  SELECT i.case_outcome, i.label INTO v_outcome, v_label
    FROM picklist_items i
   WHERE i.id = p_status
     AND i.picklist = 'case_status'
     AND i.organization_id = v_org;

  IF v_outcome IS NULL THEN
    RAISE EXCEPTION 'that status doesn''t belong to this firm'
      USING HINT = 'Case statuses are each firm''s own — choose one from this firm''s list.';
  END IF;

  v_reason := NULLIF(btrim(COALESCE(p_reason, '')), '');

  -- A case that counts as revenue can be lost — the family disputed, the
  -- firm comped the service — or put on hold, most likely because it is
  -- unpaid. Either takes money out of a month that may be closed, so it needs
  -- a reason, and the managers are told. Doing either to a case that was
  -- never revenue needs neither; reinstating, or taking a case off hold,
  -- needs none either, and is still told to the managers.
  IF v_reason IS NULL
     AND case_change_needs_reason(v_was, v_served, v_booked, v_outcome, v_served, v_booked) THEN
    RAISE EXCEPTION 'this case counts as revenue on %, so %',
      to_char(case_revenue_date_for(v_was, v_served, v_booked), 'FMMonth FMDD, YYYY'),
      CASE WHEN v_outcome = 'on_hold' THEN 'putting it on hold needs a reason'
           ELSE 'marking it lost needs a reason' END
      USING ERRCODE = 'RV001',
            HINT = CASE WHEN v_outcome = 'on_hold'
                        THEN 'Say why — for example, the bill hasn''t been paid. It goes on the case''s history and to your managers.'
                        ELSE 'Say why — for example, the family disputed the bill and the services were comped. It goes on the case''s history and to your managers.' END;
  END IF;

  PERFORM set_config('hub.case_change_reason', COALESCE(v_reason, ''), true);

  SELECT label INTO v_was_label FROM picklist_items WHERE id = v_was_item;

  UPDATE cases
     SET status = v_outcome, status_item_id = p_status, updated_at = now()
   WHERE id = p_case
  RETURNING * INTO r;

  -- Done with the reason: clear it, so a later change in this transaction —
  -- a direct UPDATE, another case — cannot inherit it and put a false reason
  -- on the permanent record (review of 20261120T1000). Cleared here, not in
  -- the trigger: the trigger fires per row, and clearing there would blank
  -- the reason for every row after the first of a multi-row UPDATE.
  PERFORM set_config('hub.case_change_reason', '', true);

  IF v_was_item IS DISTINCT FROM p_status OR v_was IS DISTINCT FROM v_outcome THEN
    PERFORM record_change(
      v_org, 'case', p_case, 'updated', 'user', a.v_name,
      format('%s set the case to %s', a.v_name, v_label)
        || COALESCE(': ' || v_reason, ''),
      a.v_user,
      jsonb_build_object('field', 'status',
                         'from', v_was, 'to', v_outcome,
                         'from_label', v_was_label, 'to_label', v_label,
                         'status_item_id', p_status,
                         'reason', v_reason));
  END IF;

  RETURN r;
END $function$;

CREATE OR REPLACE FUNCTION public.set_case_served(p_case uuid, p_served_on date DEFAULT CURRENT_DATE, p_reason text DEFAULT NULL::text)
 RETURNS cases
 LANGUAGE plpgsql
AS $function$
DECLARE
  a record; r cases; v_org uuid; v_was date; v_reason text;
  v_status case_status; v_booked date;
BEGIN
  SELECT * INTO a FROM hand_link_actor();

  SELECT organization_id, served_on, status, booked_service_date
    INTO v_org, v_was, v_status, v_booked
    FROM cases WHERE id = p_case FOR UPDATE;
  IF v_org IS NULL THEN RAISE EXCEPTION 'no such case'; END IF;

  IF p_served_on > current_date THEN
    RAISE EXCEPTION 'a service date can''t be in the future'
      USING HINT = 'This is the date the service took place. For a service that hasn''t happened yet, set the booked date instead.';
  END IF;

  v_reason := NULLIF(btrim(COALESCE(p_reason, '')), '');

  -- Changing or removing a recorded date can move revenue between months, so
  -- it needs a reason. Nobody needs to be a manager: the managers are told.
  IF v_reason IS NULL
     AND case_change_needs_reason(v_status, v_was, v_booked, v_status, p_served_on, v_booked) THEN
    RAISE EXCEPTION '%',
      CASE WHEN p_served_on IS NULL THEN 'removing a service date needs a reason'
           ELSE 'changing a service date needs a reason' END
      USING ERRCODE = 'RV001',
            HINT = 'Say why — for example, recorded on the wrong case. It goes on the case''s history and to your managers.';
  END IF;

  PERFORM set_config('hub.case_change_reason', COALESCE(v_reason, ''), true);

  UPDATE cases SET served_on = p_served_on, updated_at = now()
   WHERE id = p_case
  RETURNING * INTO r;

  -- Done with the reason: clear it, so a later change in this transaction —
  -- a direct UPDATE, another case — cannot inherit it and put a false reason
  -- on the permanent record (review of 20261120T1000). Cleared here, not in
  -- the trigger: the trigger fires per row, and clearing there would blank
  -- the reason for every row after the first of a multi-row UPDATE.
  PERFORM set_config('hub.case_change_reason', '', true);

  IF v_was IS DISTINCT FROM p_served_on THEN
    PERFORM record_change(
      v_org, 'case', p_case, 'updated', 'user', a.v_name,
      CASE WHEN p_served_on IS NULL
             THEN format('%s removed the service date (%s): %s', a.v_name,
                         to_char(v_was, 'FMMonth FMDD, YYYY'), v_reason)
           WHEN v_was IS NULL
             THEN format('%s recorded the family as served on %s',
                         a.v_name, to_char(p_served_on, 'FMMonth FMDD, YYYY'))
           ELSE format('%s changed the service date from %s to %s: %s', a.v_name,
                       to_char(v_was, 'FMMonth FMDD, YYYY'),
                       to_char(p_served_on, 'FMMonth FMDD, YYYY'), v_reason) END,
      a.v_user,
      jsonb_build_object('field', 'served_on', 'from', v_was, 'to', p_served_on,
                         'reason', v_reason));
  END IF;

  RETURN r;
END $function$;

CREATE OR REPLACE FUNCTION public.set_case_booked_date(p_case uuid, p_date date, p_reason text DEFAULT NULL::text)
 RETURNS cases
 LANGUAGE plpgsql
AS $function$
DECLARE
  a record; r cases; v_org uuid; v_was date; v_status case_status; v_served date;
  v_reason text;
BEGIN
  SELECT * INTO a FROM hand_link_actor();

  SELECT organization_id, booked_service_date, status, served_on
    INTO v_org, v_was, v_status, v_served
    FROM cases WHERE id = p_case FOR UPDATE;
  IF v_org IS NULL THEN RAISE EXCEPTION 'no such case'; END IF;

  v_reason := NULLIF(btrim(COALESCE(p_reason, '')), '');
  IF v_reason IS NULL
     AND case_change_needs_reason(v_status, v_served, v_was, v_status, v_served, p_date) THEN
    RAISE EXCEPTION 'the booked date has passed, so this case counts as revenue on %; moving it needs a reason',
      to_char(v_was, 'FMMonth FMDD, YYYY')
      USING ERRCODE = 'RV001',
            HINT = 'Say why — for example, the service was postponed. It goes on the case''s history and to your managers. Or confirm the date the service actually took place instead.';
  END IF;

  PERFORM set_config('hub.case_change_reason', COALESCE(v_reason, ''), true);

  UPDATE cases SET booked_service_date = p_date, updated_at = now()
   WHERE id = p_case
  RETURNING * INTO r;

  -- Done with the reason: clear it, so a later change in this transaction —
  -- a direct UPDATE, another case — cannot inherit it and put a false reason
  -- on the permanent record (review of 20261120T1000). Cleared here, not in
  -- the trigger: the trigger fires per row, and clearing there would blank
  -- the reason for every row after the first of a multi-row UPDATE.
  PERFORM set_config('hub.case_change_reason', '', true);

  IF v_was IS DISTINCT FROM p_date THEN
    PERFORM record_change(
      v_org, 'case', p_case, 'updated', 'user', a.v_name,
      CASE WHEN p_date IS NULL
             THEN format('%s cleared the booked service date (%s)', a.v_name,
                         to_char(v_was, 'FMMonth FMDD, YYYY'))
           WHEN v_was IS NULL
             THEN format('%s booked the service for %s', a.v_name,
                         to_char(p_date, 'FMMonth FMDD, YYYY'))
           ELSE format('%s moved the booked service from %s to %s', a.v_name,
                       to_char(v_was, 'FMMonth FMDD, YYYY'),
                       to_char(p_date, 'FMMonth FMDD, YYYY')) END
        || COALESCE(': ' || v_reason, ''),
      a.v_user,
      jsonb_build_object('field', 'booked_service_date', 'from', v_was, 'to', p_date,
                         'reason', v_reason));
  END IF;

  RETURN r;
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
-- 2. And they are the bodies that were reviewed
-- -----------------------------------------------------------------------------
DO $$
DECLARE bad text;
BEGIN
  SELECT string_agg(e.sig || ' is ' || COALESCE(md5(p.prosrc), 'MISSING'), '; ') INTO bad
    FROM (VALUES
    ('case_revenue_moved_notify()', 'fc1e7e84bf1c45cb2f9c9e56a8ace22c'),
    ('set_case_booked_date(uuid,date,text)', 'd5e58c56a838ae97b71ecea487023ad2'),
    ('set_case_served(uuid,date,text)', '3e4d9dc05d9ed33d4f9cbea1b1962f5c'),
    ('set_case_status(uuid,uuid,text)', 'd15039ba9789ae96bdd3841eaf02133c')
         ) AS e(sig, want)
    LEFT JOIN pg_proc p ON p.oid = to_regprocedure(e.sig)
   WHERE md5(p.prosrc) IS DISTINCT FROM e.want;
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'not the reviewed bodies: %. Nothing has been kept.', bad;
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
    'moved, and why. The three writers clear hub.case_change_reason after '
    'their UPDATE, so a later change cannot inherit a reason.');
END $rec$;

COMMIT;

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- Fixture: a director and a manager at the first firm with a lost status; a
-- second firm whose only user is a professional. Line 2 reads the row back AS
-- the director, so a row hidden by row-level security reads as NONE.
--
-- Line 6 is the review's: a reason must not outlive its change. Before
-- section 1b it read "ZZZ the first case's reason" — reproduced, then fixed.
--
-- RUN ON A SCRATCH REBUILD, 20 Nov — every migration on main, in order, with
-- this file, after the review's change: every line matched, and
-- 20261119T1510's own verification block, re-run against the three
-- rewritten writers, matched in full. NOT YET RUN ON STAGING.
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
--   -- 6. Review: a reason must not outlive the change it was given for. In this
--   --    one transaction: a loss with a reason on one case, then a direct UPDATE
--   --    of another — which gave no reason and must not be recorded with one.
--   PERFORM set_config('request.jwt.claims', json_build_object('sub', a_dir::text)::text, true);
--   PERFORM set_config('role', 'authenticated', true);
--   PERFORM set_case_lost(c_lost, true, 'ZZZ the first case''s reason');
--   PERFORM set_config('role', 'postgres', true);
--   UPDATE cases SET served_on = t - 3 WHERE id = c_direct;
--   SELECT * INTO row_ FROM change_history WHERE entity = 'case' AND entity_id = c_direct
--      AND detail->>'field' = 'revenue_date' AND detail->>'to' = (t - 3)::text;
--   r := r || '6. a later direct change in the same transaction — its reason: '
--          || COALESCE(row_.detail->>'reason', 'null')
--          || ', sentence ends: ' || COALESCE(right(row_.summary, 20), 'NONE (BAD)')
--          || '   (expect null, ". No reason recorded" — NOT "ZZZ the first case''s reason")' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261120T1000_revenue_moves_are_recorded (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
