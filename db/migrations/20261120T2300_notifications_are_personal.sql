-- =============================================================================
-- 20261120T2300_notifications_are_personal.sql
-- The Hub — a notification, a notification preference and a delivery record
-- belong to one person. Only that person reads them; nobody else writes them.
--
-- WHY. The last item on "must land before any firm gets a login" (planning,
-- 20 November). The bell filters notifications to the signed-in user in the
-- app (loadBell and markNotificationRead in hellophone
-- src/app/actions/notifications.ts), but the database lets more through. That's
-- the organization_capabilities defect of 20261120T1400 again: the behaviour
-- is right, with no enforcement under it. Checked from the catalogue on 20
-- November:
--
--   notifications              SELECT and UPDATE policies, both
--                              is_internal() OR user_id = current_user_id().
--                              No INSERT or DELETE policy, but authenticated
--                              still holds both grants, so those are refused
--                              only by the policy's absence. FORCE RLS off.
--   notification_preferences   one FOR ALL, the same expression
--   notification_log           one FOR ALL, the same expression
--
-- So, by the policies, not the app:
--
--   a colleague at the firm    can't read or write anyone else's. Right.
--   a manager                  the same: nothing here is firm-scoped. Right.
--   Dead Ringers               can read every user's notifications,
--                              preferences and delivery log, AND update any
--                              notification's every column: mark someone's
--                              alert read, which silently clears their bell,
--                              or rewrite its text. Also insert, change or
--                              delete anyone's preferences and log rows.
--   the recipient              reads their own (right), but can also rewrite
--                              a notification's body, event and subject, not
--                              just read_at, and can insert, edit or delete
--                              their own delivery records.
--
-- The read by Dead Ringers is a smaller leak than it sounds: is_internal()
-- already reads every firm's cases and calls. What these tables add is
-- per-person data: what each member of staff was told, and when they read it.
-- The writes are the defect.
--
-- THE DESIGN (planning, 20 November): SCOPED BY USER, NOT BY FIRM. A
-- notification, a preference and a delivery record each belong to one
-- person. This is the one family of tables in the Hub where the firm doesn't
-- own the row, so is_internal() and can_manage_settings() give nothing here.
-- No screen on any of hellophone's 21 branches reads across users: no
-- internal view, no admin list, no support screen. So Dead Ringers gets no
-- read. "Support might need it" isn't a screen.
--
--   notifications              read: own. update: own, and only read_at, by
--                              a column grant. INSERT, UPDATE (as a whole
--                              table) and DELETE are revoked from
--                              authenticated, so the catalogue says "nobody
--                              inserts" rather than leaving it to be inferred
--                              from a missing policy. FORCE on.
--   notification_preferences   own, read and write. The app writes only the
--                              signed-in user's own (Settings, Notifications).
--   notification_log           read: own. INSERT, UPDATE and DELETE are
--                              revoked from authenticated: no API write for
--                              anyone. NOTE FOR WHOEVER BUILDS THE DELIVERY
--                              PIPELINE: it will write as service_role, which
--                              holds only REFERENCES here today. It will need
--                              its own grants, INSERT and probably UPDATE (to
--                              record delivered), given to service_role in
--                              that file. It doesn't need these.
--
-- WHAT STILL WRITES, AND WHY IT'S UNAFFECTED:
--
--   case_converted_notify()       SECURITY DEFINER triggers, owned by postgres,
--   case_revenue_moved_notify()   which holds BYPASSRLS: FORCE doesn't apply to
--                                 a role that bypasses row-level security. This
--                                 file proves it, not assumes it: verification
--                                 lines 12 and 13 convert a case and move its
--                                 revenue, and count the rows. It matters more
--                                 for case_converted_notify, which turns any
--                                 failure into a WARNING so a conversion is
--                                 never vetoed. A broken insert there would be
--                                 silent.
--   user_scope_default_notifications()   becomes SECURITY DEFINER, with
--                                 SET search_path = public. Body unchanged,
--                                 drift-checked against 20261030T1930.
--
-- AN ONBOARDING BUG THIS FILE CLOSES, named so it doesn't land as a side
-- effect. user_scope_default_notifications() is a trigger on user_scopes:
-- when an owner or manager scope is created, it inserts that person's default
-- "case_converted" desktop preference. It was INVOKER, so the insert ran as
-- whoever created the scope, for SOMEONE ELSE's user_id. That passed only
-- through is_internal(). So a firm manager creating an owner or manager
-- scope for a colleague, which user_scopes_insert (038) allows, failed on the
-- preference insert and took the scope with it. It never surfaced because
-- nothing in the app creates scopes yet: every scope so far was made by Dead
-- Ringers at onboarding. As DEFINER, the trigger writes the one fixed default
-- row for the new user whoever creates the scope, so removing is_internal()
-- from preferences doesn't break onboarding, and the firm-manager case works.
-- Lines 14 and 15 of the verification show both.
--
-- AND IN THE APP: markNotificationRead's comment in hellophone
-- src/app/actions/notifications.ts says "Only the recipient can
-- (notifications_own_read_state)". It claimed an enforcement that didn't
-- exist. Once this runs, it's true.
--
-- Requires: 019 (the notification tables), 038 (user_scopes policies),
--           20261030T1930, 20261102T1600, 20261120T1000 (the three trigger
--           bodies), 20261103T1200 (record_migration).
-- NOT SAFE TO RUN TWICE: section 1 refuses on a second run.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Preconditions: every policy and body this file depends on is the one
--    that was reviewed, and nothing from this file is here yet
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  own CONSTANT text := 'd491824a3f827cfebebf87fa5a00dfdc';  -- (is_internal() OR (user_id = current_user_id()))
  v text; n int;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'public.notifications'::regclass
                                       AND polname = 'notifications_read') THEN
    RAISE EXCEPTION 'already converted; nothing to do here'
      USING HINT = 'This migration has run on this database. Not an error to fix — stop.';
  END IF;

  -- Exactly these four policies, with these commands and expressions.
  SELECT count(*) INTO n FROM pg_policy
   WHERE polrelid IN ('public.notifications'::regclass, 'public.notification_preferences'::regclass,
                      'public.notification_log'::regclass);
  -- Refuse if any expected policy isn't there exactly as listed.
  IF n <> 4 OR EXISTS (
       SELECT 1 FROM (VALUES
         ('notifications',            'notifications_self',            'r', own, md5('')),
         ('notifications',            'notifications_own_read_state',  'w', own, own),
         ('notification_preferences', 'notification_preferences_self', '*', own, own),
         ('notification_log',         'notification_log_self',         '*', own, own)) w(t, pol, cmd, q, c)
        WHERE NOT EXISTS (
          SELECT 1 FROM pg_policy p
           WHERE p.polrelid = format('public.%I', w.t)::regclass AND p.polname = w.pol
             AND p.polcmd::text = w.cmd AND p.polroles = '{0}'
             AND md5(COALESCE(pg_get_expr(p.polqual, p.polrelid), '')) = w.q
             AND md5(COALESCE(pg_get_expr(p.polwithcheck, p.polrelid), '')) = w.c)) THEN
    RAISE EXCEPTION 'the notification tables'' policies are not the four this file expects (% found); stop and read them', n
      USING HINT = 'Expected notifications_self (SELECT), notifications_own_read_state (UPDATE), '
                   'notification_preferences_self (ALL), notification_log_self (ALL), each '
                   'is_internal() OR user_id = current_user_id().';
  END IF;

  -- The three trigger bodies, as reviewed.
  SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = 'user_scope_default_notifications()'::regprocedure;
  IF v IS DISTINCT FROM '21fc6e2aa1bd48e2636d3280ae180a9c' THEN
    RAISE EXCEPTION 'user_scope_default_notifications is not 20261030T1930''s body (md5 %); stop and diff it', v;
  END IF;
  IF (SELECT prosecdef FROM pg_proc WHERE oid = 'user_scope_default_notifications()'::regprocedure) THEN
    RAISE EXCEPTION 'user_scope_default_notifications is already SECURITY DEFINER; stop and read it';
  END IF;
  SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = 'case_converted_notify()'::regprocedure;
  IF v IS DISTINCT FROM '1fe7e035fbeb17ab56302dbb4e4247eb' THEN
    RAISE EXCEPTION 'case_converted_notify is not 20261102T1600''s body (md5 %); stop and diff it', v;
  END IF;
  SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = 'case_revenue_moved_notify()'::regprocedure;
  IF v IS DISTINCT FROM 'fc1e7e84bf1c45cb2f9c9e56a8ace22c' THEN
    RAISE EXCEPTION 'case_revenue_moved_notify is not 20261120T1000''s body (md5 %); stop and diff it', v;
  END IF;
  -- The writers this file relies on: DEFINER, owned by a role that bypasses RLS.
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_roles o ON o.oid = p.proowner
              WHERE p.oid IN ('case_converted_notify()'::regprocedure, 'case_revenue_moved_notify()'::regprocedure)
                AND NOT (p.prosecdef AND o.rolbypassrls)) THEN
    RAISE EXCEPTION 'a notify trigger is not SECURITY DEFINER under a role with BYPASSRLS; stop: FORCE would stop it inserting';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. notifications: the recipient reads, and marks read. Nobody else, and
--    nothing else.
-- -----------------------------------------------------------------------------
DROP POLICY notifications_self ON notifications;
DROP POLICY notifications_own_read_state ON notifications;

CREATE POLICY notifications_read ON notifications FOR SELECT TO authenticated
  USING (user_id = current_user_id());
CREATE POLICY notifications_mark_read ON notifications FOR UPDATE TO authenticated
  USING (user_id = current_user_id()) WITH CHECK (user_id = current_user_id());

REVOKE INSERT, UPDATE, DELETE ON notifications FROM authenticated;
GRANT UPDATE (read_at) ON notifications TO authenticated;
ALTER TABLE notifications FORCE ROW LEVEL SECURITY;

COMMENT ON POLICY notifications_read ON notifications IS
  'A notification is its recipient''s: no one else reads it, Dead Ringers '
  'included. Scoped by user, not firm (20261120T2300).';
COMMENT ON POLICY notifications_mark_read ON notifications IS
  'The recipient marks their own notification read. Only read_at can change: '
  'UPDATE is granted on that column alone. Notifications are created by the '
  'SECURITY DEFINER notify triggers, never through the API (20261120T2300).';

-- -----------------------------------------------------------------------------
-- 3. notification_preferences: the person's own, read and written by them
-- -----------------------------------------------------------------------------
DROP POLICY notification_preferences_self ON notification_preferences;
CREATE POLICY notification_preferences_own ON notification_preferences FOR ALL TO authenticated
  USING (user_id = current_user_id()) WITH CHECK (user_id = current_user_id());
COMMENT ON POLICY notification_preferences_own ON notification_preferences IS
  'Your notification preferences are yours: read and set by you alone. The '
  'onboarding default is written by user_scope_default_notifications, a '
  'SECURITY DEFINER trigger (20261120T2300).';

ALTER FUNCTION user_scope_default_notifications() SECURITY DEFINER;
ALTER FUNCTION user_scope_default_notifications() SET search_path = public;
REVOKE ALL ON FUNCTION user_scope_default_notifications() FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION user_scope_default_notifications() IS
  'When an owner or manager scope is created, give that person the default '
  '"case_converted" desktop preference. SECURITY DEFINER since 20261120T2300, '
  'because it writes a row for the new user, not for whoever created the scope. '
  'As INVOKER it worked only for Dead Ringers, and a firm manager creating a '
  'manager scope failed on it. It writes one fixed row and nothing from its '
  'caller, which is what keeps a definer this narrow (20261030T1930, '
  '20261120T2300).';

-- -----------------------------------------------------------------------------
-- 4. notification_log: the person reads their own delivery record; nobody
--    writes it through the API
-- -----------------------------------------------------------------------------
DROP POLICY notification_log_self ON notification_log;
CREATE POLICY notification_log_read ON notification_log FOR SELECT TO authenticated
  USING (user_id = current_user_id());
REVOKE INSERT, UPDATE, DELETE ON notification_log FROM authenticated;
COMMENT ON POLICY notification_log_read ON notification_log IS
  'A person reads the record of what was sent to them. No grant or policy lets '
  'anyone write it through the API: a delivery record is evidence. The future '
  'delivery pipeline writes as service_role, which holds only REFERENCES here '
  'today, so that file grants service_role what it needs (20261120T2300).';

-- -----------------------------------------------------------------------------
-- 5. Record it
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261120T2300_notifications_are_personal.sql',
    NULL,
    'notifications, notification_preferences and notification_log scoped to '
    'the person alone: is_internal() removed. notifications: read own, update '
    'read_at only (column grant), INSERT/DELETE revoked, FORCE on. log: read '
    'own, writes revoked. user_scope_default_notifications made SECURITY '
    'DEFINER (search_path pinned), which also fixes a firm manager creating a '
    'manager scope.');
END $rec$;

COMMIT;

-- =============================================================================
-- Verification — run AFTER the file, as its own statement. One block,
-- everything rolled back by the closing RAISE.
--
-- A fixture firm with an owner (Olive), a manager (Mo) and a professional
-- (Cal), and a Dead Ringers user (Dee). Olive has one notification, a
-- preference (from the onboarding trigger) and one delivery-log row. Everyone
-- asks as authenticated, because postgres holds BYPASSRLS; Dee also has
-- app.is_internal on. Counts taken "as the system" switch to role none for
-- one statement, then back.
--
-- DO $$
-- DECLARE
--   r text := ''; n int; res text; who text;
--   v_org uuid; v_case uuid; v_call uuid; v_contact uuid; v_note uuid; v_log uuid;
--   u_olive uuid; u_mo uuid; u_cal uuid; u_dee uuid; u_new1 uuid; u_new2 uuid;
--   a_olive uuid := gen_random_uuid(); a_mo uuid := gen_random_uuid(); a_cal uuid := gen_random_uuid();
--   a_dee uuid := gen_random_uuid(); a_new1 uuid := gen_random_uuid(); a_new2 uuid := gen_random_uuid();
--   who_auth jsonb;
-- BEGIN
--   r := r || '1. policies: ' || (SELECT string_agg(c.relname || '.' || p.polname || '(' || p.polcmd::text || ')', ' ' ORDER BY 1)
--            FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
--           WHERE c.relname IN ('notifications', 'notification_preferences', 'notification_log'))
--          || chr(10) || '   (expect notification_log_read(r), notification_preferences_own(*), notifications_mark_read(w), notifications_read(r))' || chr(10);
--   r := r || '2. authenticated on notifications: INSERT ' || has_table_privilege('authenticated', 'public.notifications', 'INSERT')
--          || ', DELETE ' || has_table_privilege('authenticated', 'public.notifications', 'DELETE')
--          || ', UPDATE(body) ' || has_column_privilege('authenticated', 'public.notifications', 'body', 'UPDATE')
--          || ', UPDATE(read_at) ' || has_column_privilege('authenticated', 'public.notifications', 'read_at', 'UPDATE')
--          || '; on notification_log: INSERT ' || has_table_privilege('authenticated', 'public.notification_log', 'INSERT')
--          || ', DELETE ' || has_table_privilege('authenticated', 'public.notification_log', 'DELETE')
--          || '; notifications FORCE ' || (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'public.notifications'::regclass)
--          || chr(10) || '   (expect INSERT false, DELETE false, UPDATE(body) false, UPDATE(read_at) true; false, false; FORCE true)' || chr(10);
--   r := r || '3. user_scope_default_notifications: DEFINER ' || (SELECT prosecdef FROM pg_proc WHERE proname = 'user_scope_default_notifications')
--          || ', ' || COALESCE((SELECT array_to_string(proconfig, ',') FROM pg_proc WHERE proname = 'user_scope_default_notifications'), 'no search_path')
--          || '   (expect true, search_path=public)' || chr(10);
--
--   -- ---- the fixture, as the system ---------------------------------------
--   PERFORM set_config('app.is_internal', 'on', true);
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ verify 2300', 'funeral_home') RETURNING id INTO v_org;
--   INSERT INTO users (email, full_name, auth_user_id) VALUES ('zzz-2300-o@example.invalid', 'ZZZ Olive', a_olive) RETURNING id INTO u_olive;
--   INSERT INTO users (email, full_name, auth_user_id) VALUES ('zzz-2300-m@example.invalid', 'ZZZ Mo', a_mo) RETURNING id INTO u_mo;
--   INSERT INTO users (email, full_name, auth_user_id) VALUES ('zzz-2300-c@example.invalid', 'ZZZ Cal', a_cal) RETURNING id INTO u_cal;
--   INSERT INTO users (email, full_name, auth_user_id, is_internal) VALUES ('zzz-2300-d@example.invalid', 'ZZZ Dee', a_dee, true) RETURNING id INTO u_dee;
--   INSERT INTO users (email, full_name, auth_user_id) VALUES ('zzz-2300-n1@example.invalid', 'ZZZ New One', a_new1) RETURNING id INTO u_new1;
--   INSERT INTO users (email, full_name, auth_user_id) VALUES ('zzz-2300-n2@example.invalid', 'ZZZ New Two', a_new2) RETURNING id INTO u_new2;
--   INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id) VALUES
--     (u_olive, 'organization', 'owner', v_org), (u_mo, 'organization', 'manager', v_org),
--     (u_cal, 'organization', 'professional', v_org);
--   INSERT INTO notifications (organization_id, user_id, event, subject_entity, subject_id, body)
--   VALUES (v_org, u_olive, 'case_converted', 'case', gen_random_uuid(), 'ZZZ for Olive') RETURNING id INTO v_note;
--   INSERT INTO notification_log (organization_id, user_id, event, channel, sent_to)
--   VALUES (v_org, u_olive, 'case_converted', 'desktop', 'ZZZ') RETURNING id INTO v_log;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'ZZZ Caller') RETURNING id INTO v_contact;
--   INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at, contact_id, contact_link_method)
--   VALUES (v_org, 'inbound', now(), now(), v_contact, 'confirmed') RETURNING id INTO v_call;
--   PERFORM set_config('app.is_internal', 'off', true);
--   PERFORM set_config('role', 'authenticated', true);
--
--   -- ---- 4-7. the matrix: Olive's rows, read by each person ------------------
--   FOR who, who_auth IN SELECT * FROM (VALUES
--       ('4. Olive (the owner)', jsonb_build_object('a', a_olive, 'i', 'off')),
--       ('5. Cal (a colleague)', jsonb_build_object('a', a_cal,   'i', 'off')),
--       ('6. Mo (a manager)',    jsonb_build_object('a', a_mo,    'i', 'off')),
--       ('7. Dee (Dead Ringers)', jsonb_build_object('a', a_dee,  'i', 'on'))) x LOOP
--     PERFORM set_config('request.jwt.claims', json_build_object('sub', who_auth ->> 'a')::text, true);
--     PERFORM set_config('app.is_internal', who_auth ->> 'i', true);
--     r := r || who || ' reads Olive''s notification / preference / delivery log: '
--            || (SELECT count(*) FROM notifications WHERE id = v_note) || ' / '
--            || (SELECT count(*) FROM notification_preferences WHERE user_id = u_olive) || ' / '
--            || (SELECT count(*) FROM notification_log WHERE id = v_log)
--            || CASE WHEN who LIKE '4.%' THEN '   (expect 1 / 1 / 1)' ELSE '   (expect 0 / 0 / 0)' END || chr(10);
--     IF who NOT LIKE '4.%' THEN
--       UPDATE notification_preferences SET enabled = false WHERE user_id = u_olive;
--       GET DIAGNOSTICS n = ROW_COUNT;
--       r := r || '   and turns off Olive''s preference: ' || n || '   (expect 0)' || chr(10);
--     END IF;
--   END LOOP;
--
--   -- ---- 8-11. the writes: the two defects, and what's left ---------------
--   -- still Dee, with app.is_internal on
--   UPDATE notifications SET read_at = now() WHERE id = v_note;
--   GET DIAGNOSTICS n = ROW_COUNT;
--   r := r || '8. Dee marks Olive''s notification read: ' || n || '   (expect 0: her bell isn''t cleared for her)' || chr(10);
--   PERFORM set_config('app.is_internal', 'off', true);
--   PERFORM set_config('request.jwt.claims', json_build_object('sub', a_olive::text)::text, true);
--   BEGIN UPDATE notifications SET body = 'rewritten' WHERE id = v_note; res := 'ALLOWED';
--   EXCEPTION WHEN insufficient_privilege THEN res := SQLSTATE; END;
--   r := r || '9. Olive rewrites her notification''s body: ' || res || '   (expect 42501: only read_at is hers to change)' || chr(10);
--   UPDATE notifications SET read_at = now() WHERE id = v_note;
--   GET DIAGNOSTICS n = ROW_COUNT;
--   r := r || '10. Olive marks it read: ' || n || '   (expect 1)' || chr(10);
--   BEGIN INSERT INTO notifications (organization_id, user_id, event, subject_entity, subject_id, body)
--         VALUES (v_org, u_olive, 'case_converted', 'case', gen_random_uuid(), 'x'); res := 'ALLOWED';
--   EXCEPTION WHEN insufficient_privilege THEN res := SQLSTATE; END;
--   r := r || '11. Olive inserts a notification / ' || res;
--   BEGIN DELETE FROM notifications WHERE id = v_note; res := 'ALLOWED';
--   EXCEPTION WHEN insufficient_privilege THEN res := SQLSTATE; END;
--   r := r || ' deletes it / ' || res;
--   BEGIN INSERT INTO notification_log (organization_id, user_id, event, channel, sent_to)
--         VALUES (v_org, u_olive, 'case_converted', 'desktop', 'x'); res := 'ALLOWED';
--   EXCEPTION WHEN insufficient_privilege THEN res := SQLSTATE; END;
--   r := r || ' writes her delivery log / ' || res;
--   UPDATE notification_preferences SET enabled = enabled WHERE user_id = u_olive;
--   GET DIAGNOSTICS n = ROW_COUNT;
--   r := r || ' sets her own preference: ' || n || '   (expect 42501 / 42501 / 42501 / 1)' || chr(10);
--
--   -- ---- 12-13. the notify triggers still insert, with FORCE on -----------
--   PERFORM set_config('request.jwt.claims', json_build_object('sub', a_cal::text)::text, true);
--   v_case := create_case_for_call(v_call, 'at_need', 'at_need', 'Zzzverify');
--   PERFORM set_config('role', 'none', true);
--   SELECT count(*) INTO n FROM notifications WHERE subject_id = v_case AND event = 'case_converted';
--   PERFORM set_config('role', 'authenticated', true);
--   r := r || '12. Cal starts a case: case_converted notifications written: ' || n
--          || '   (expect 2: Olive and Mo, each with the onboarding preference; not Cal, who did it)' || chr(10);
--   PERFORM set_case_booked_date(v_case, current_date - 1, NULL);
--   PERFORM set_config('role', 'none', true);
--   SELECT count(*) INTO n FROM notifications WHERE subject_id = v_case AND event = 'case_revenue_moved';
--   PERFORM set_config('role', 'authenticated', true);
--   r := r || '13. Cal books it for yesterday, so it counts: case_revenue_moved notifications written: ' || n
--          || '   (expect 2: Olive and Mo)' || chr(10);
--
--   -- ---- 14-15. onboarding: the default preference, by either creator ------
--   PERFORM set_config('request.jwt.claims', json_build_object('sub', a_dee::text)::text, true);
--   PERFORM set_config('app.is_internal', 'on', true);
--   INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id) VALUES (u_new1, 'organization', 'manager', v_org);
--   PERFORM set_config('app.is_internal', 'off', true);
--   PERFORM set_config('role', 'none', true);
--   SELECT count(*) INTO n FROM notification_preferences WHERE user_id = u_new1 AND event = 'case_converted' AND enabled;
--   PERFORM set_config('role', 'authenticated', true);
--   r := r || '14. Dead Ringers gives New One a manager scope: default preference: ' || n || '   (expect 1)' || chr(10);
--   PERFORM set_config('request.jwt.claims', json_build_object('sub', a_mo::text)::text, true);
--   BEGIN INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id) VALUES (u_new2, 'organization', 'manager', v_org);
--     res := 'scope created';
--   EXCEPTION WHEN OTHERS THEN res := 'REFUSED: ' || SQLERRM; END;
--   PERFORM set_config('role', 'none', true);
--   SELECT count(*) INTO n FROM notification_preferences WHERE user_id = u_new2 AND event = 'case_converted' AND enabled;
--   PERFORM set_config('role', 'authenticated', true);
--   r := r || '15. Mo, a firm manager, gives New Two a manager scope: ' || res || ', default preference: ' || n
--          || '   (expect scope created, 1. Before this file: refused by notification_preferences_self)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261120T2300_notifications_are_personal (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
