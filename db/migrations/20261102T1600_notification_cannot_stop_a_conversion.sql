-- =============================================================================
-- 20261102T1600_notification_cannot_stop_a_conversion.sql
-- The Hub — a courtesy must not be able to veto the thing it is a courtesy to.
--
-- WHY. case_converted_notify() runs inside create_case_for_call(), on the
-- insert into case_decedents. Anything it raises aborts that transaction, so
-- a fault in notifying a manager becomes a director unable to create a case
-- while a family is on the phone. The notification exists because conversion
-- is ungated; it must not be able to gate it after all.
--
-- Tested on staging rather than argued: with production's state (no managers,
-- no preference rows) and with the converter as the only manager, conversion
-- succeeded and wrote nothing. The paths that exist today are plain zero-row
-- inserts. What this guards is the paths that do not exist yet.
--
-- WHAT A WARNING IS AND IS NOT. It goes to the Postgres log — on Supabase,
-- Logs -> Postgres. Nothing watches it, and nothing in this file makes
-- anything watch it. A warning is better than silence only if somebody looks,
-- and the honest description of this change is that it trades a loud failure
-- in the wrong place for a quiet one in the right place. The string
-- "case_converted_notify" is in the message so that a log search finds every
-- instance.
--
-- The exception handler is NOT a licence to be careless inside it. Everything
-- it now catches is still a defect; it is caught here because the cost of
-- raising lands on someone who has nothing to do with notifications.
--
-- ALSO IN THIS FILE, two comments that have been waiting for a migration that
-- touches notifications rather than earning one of their own:
--   * what notification_preferences.enabled's default does and does not say;
--   * what a future NOT NULL column on notifications would do to the trigger.
--
-- Requires, by what it actually uses:
--   20261030T1930  notifications, case_converted_notify(), the preference
--                  default this file comments on
--
-- Safe to run twice: the drift check tells "already applied" from "something
-- else changed it", and a second run reinstalls the same body.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. It must be the body this was built from
--
-- Three states, because the body this writes is not the body it expects to
-- find: a second run has to read as "already applied" rather than as drift.
--
-- Whole-body md5, because this replaces the whole function — the same reason
-- 053 checked 048's body that way and 20261102T1500 checked 053's.
-- -----------------------------------------------------------------------------
DO $$
DECLARE v text;
BEGIN
  SELECT md5(prosrc) INTO v FROM pg_proc
   WHERE oid = 'case_converted_notify()'::regprocedure;

  IF v IS NULL THEN
    RAISE EXCEPTION 'case_converted_notify does not exist; run 20261030T1930 first';
  ELSIF v = '1fe7e035fbeb17ab56302dbb4e4247eb' THEN
    RAISE NOTICE 'case_converted_notify already warns and continues — this migration has run before; replacing it is a no-op';
  ELSIF v <> '4f9f8cfc31b7d8150eda3b7838cf512b' THEN
    RAISE EXCEPTION 'case_converted_notify is neither 20261030T1930''s version (%) nor this one; stop and compare before replacing it', v;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. The same body, with the notification work inside a handler
--
-- SECURITY DEFINER and search_path are unchanged and still load-bearing:
-- notification_preferences is self-only under RLS, so as the converter this
-- would find no preference but their own and write nothing. The handler
-- changes what happens when something fails, not who this runs as.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION case_converted_notify() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_org uuid; v_need case_need_type; v_conv uuid;
  v_last text; v_caller text; v_actor_id uuid; v_actor text; v_body text;
BEGIN
  -- Only the case's first decedent. A second one added later is not a
  -- conversion, and one case must not notify twice.
  IF EXISTS (SELECT 1 FROM case_decedents
              WHERE case_id = NEW.case_id
                AND decedent_id IS DISTINCT FROM NEW.decedent_id) THEN
    RETURN NULL;
  END IF;

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
END $$;

COMMENT ON FUNCTION case_converted_notify() IS
  'Tells a firm''s managers that a case was created, since creating one is '
  'ungated and visibility is what they were given instead of control. On '
  'case_decedents, not cases: 057 inserts the case first, so a trigger on '
  'cases cannot name the family. Fires for a case''s first decedent only, '
  'skips the person who created it, and respects each manager''s desktop '
  'preference — an absent row is off. SECURITY DEFINER because '
  'notification_preferences is self-only under RLS and the converter would '
  'see no preference but their own; the work sits in the trigger function '
  'rather than a helper so that there is no grantable entry point to it. '
  'WARNS AND CONTINUES: a notification must never be able to stop a case '
  'being created, so anything that fails inside becomes a WARNING in the '
  'Postgres log and the conversion goes through without one. Nothing watches '
  'that log.';

-- -----------------------------------------------------------------------------
-- 3. And it is the body that was reviewed
--
-- In the same transaction, so a mismatch rolls the replacement back rather
-- than leaving something nobody has read installed.
-- -----------------------------------------------------------------------------
DO $$
DECLARE v text;
BEGIN
  SELECT md5(prosrc) INTO v FROM pg_proc
   WHERE oid = 'case_converted_notify()'::regprocedure;

  IF v <> '1fe7e035fbeb17ab56302dbb4e4247eb' THEN
    RAISE EXCEPTION
      'case_converted_notify installed as % — not the reviewed body (1fe7e035fbeb17ab56302dbb4e4247eb). Nothing has been kept.', v;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 4. The two comments that were waiting for this ride
--
-- Neither changes behaviour. Both exist because a reader drew the wrong
-- conclusion from what was there, which is the test for whether a comment is
-- worth writing.
-- -----------------------------------------------------------------------------

-- Read as "this feature is off by default", which it is not. The default is
-- what a careless write gets, not what the product does.
COMMENT ON COLUMN notification_preferences.enabled IS
  'Whether this person wants this event on this channel. Defaults to false, '
  'matching the app''s reading that an absent row is off — a row written '
  'without an opinion should not turn something on. THIS DEFAULT IS NOT THE '
  'PRODUCT RULE. Managers get case_converted on: that comes from the seed in '
  '20261030T1930 and from user_scope_default_notifications(), which gives a '
  'newly promoted manager the same row. Read those, not this, to find out '
  'what anyone actually receives.';

-- The hazard the warn-and-continue handler above turns from fatal to quiet.
COMMENT ON TABLE notifications IS
  'Something happened that someone should hear about — the row 019 had no '
  'place for, between a preference (what a person wants) and a log entry '
  '(what was sent). One row per recipient. Nothing here asserts delivery: '
  'the desktop channel is this table read by the app, and email and sms wait '
  'on a dispatcher that does not exist yet. '
  'ADDING A NOT NULL COLUMN HERE WITHOUT A DEFAULT BREAKS CASE CONVERSION''S '
  'NOTIFICATION. case_converted_notify() inserts a fixed column list, so a '
  'new required column makes that insert fail. Since 20261102T1600 it fails '
  'as a WARNING rather than aborting the conversion — so the symptom is not '
  'an error anyone sees, it is notifications quietly stopping. Give any new '
  'column a default, or update the trigger in the same migration.';

COMMIT;

-- =============================================================================
-- STILL TO DO, named so they aren't folded in and skipped
--
-- * Nothing watches the Postgres log. Until something does, a warning is a
--   record for whoever goes looking after someone says "I never heard about
--   that case" — which is the same question notification_log was created to
--   answer and still cannot.
-- * No dispatcher exists, so email and sms preferences for this event can be
--   set and will never fire. The app offers desktop only for case_converted,
--   which closes it at the interface rather than in the schema.
-- * The feature still notifies nobody on either database: there are no
--   active, non-internal managers. It starts working when firm manager
--   logins exist.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- The point of this block is the forced failure: it breaks the insert the way
-- a future migration might, and asserts that the CONVERSION still succeeds.
-- Everything else here is the normal path, run again afterwards to show the
-- handler did not swallow it permanently.
--
-- DO $$
-- DECLARE
--   r text := ''; v_org uuid; v_mgr uuid; v_actor uuid;
--   v_call uuid; v_case uuid; v_n int;
-- BEGIN
--   SELECT id INTO v_org FROM organizations WHERE code = 'DR';
--   PERFORM set_config('app.is_internal', 'on', true);
--   PERFORM set_config('app.organization_id', v_org::text, true);
--
--   r := r || 'installed body: '
--          || (SELECT md5(prosrc) FROM pg_proc
--               WHERE oid = 'case_converted_notify()'::regprocedure)
--          || '   (expect 1fe7e035fbeb17ab56302dbb4e4247eb)' || chr(10);
--
--   -- A manager to receive, and a non-manager to convert. Created, because
--   -- neither database has an active non-internal manager in any firm.
--   INSERT INTO users (email, full_name, is_internal, active)
--   VALUES ('verify.manager@example.invalid', 'Verify Manager', false, true)
--   RETURNING id INTO v_mgr;
--   INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id)
--   VALUES (v_mgr, 'organization', 'manager', v_org);
--
--   INSERT INTO users (email, full_name, is_internal, active)
--   VALUES ('verify.converter@example.invalid', 'Verify Converter', false, true)
--   RETURNING id INTO v_actor;
--   INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id)
--   VALUES (v_actor, 'organization', 'professional', v_org);
--
--   -- ---- The forced failure -------------------------------------------------
--   -- Exactly the hazard the table comment names: a required column the
--   -- trigger's fixed column list does not supply.
--   ALTER TABLE notifications ADD COLUMN verify_break text NOT NULL;
--
--   BEGIN
--     SELECT i.id INTO v_call FROM interactions i
--      WHERE i.organization_id = v_org AND i.contact_id IS NOT NULL AND i.case_id IS NULL
--      ORDER BY i.occurred_at DESC LIMIT 1;
--
--     PERFORM set_config('app.is_internal', 'off', true);
--     PERFORM set_config('app.user_id', v_actor::text, true);
--     PERFORM set_config('role', 'authenticated', true);
--
--     v_case := create_case_for_call(v_call, 'at_need', 'at_need', 'Broken', 'Helen',
--                                    current_date, NULL, NULL, '{}');
--
--     PERFORM set_config('role', 'postgres', true);
--     PERFORM set_config('app.is_internal', 'on', true);
--
--     r := r || 'with the insert broken — conversion succeeded: '
--            || (v_case IS NOT NULL)
--            || ', notifications written: '
--            || (SELECT count(*) FROM notifications WHERE subject_id = v_case)
--            || '   (expect true, 0 — and a WARNING in the Postgres log)' || chr(10);
--   EXCEPTION WHEN others THEN
--     PERFORM set_config('role', 'postgres', true);
--     PERFORM set_config('app.is_internal', 'on', true);
--     r := r || 'CONVERSION FAILED WITH THE INSERT BROKEN (BAD): ' || SQLERRM || chr(10);
--   END;
--
--   ALTER TABLE notifications DROP COLUMN verify_break;
--
--   -- ---- The normal path, to show nothing was swallowed permanently --------
--   BEGIN
--     SELECT i.id INTO v_call FROM interactions i
--      WHERE i.organization_id = v_org AND i.contact_id IS NOT NULL AND i.case_id IS NULL
--      ORDER BY i.occurred_at DESC LIMIT 1;
--
--     PERFORM set_config('app.is_internal', 'off', true);
--     PERFORM set_config('app.user_id', v_actor::text, true);
--     PERFORM set_config('role', 'authenticated', true);
--
--     v_case := create_case_for_call(v_call, 'at_need', 'at_need', 'Working', 'Helen',
--                                    current_date, NULL, NULL, '{}');
--
--     PERFORM set_config('role', 'postgres', true);
--     PERFORM set_config('app.is_internal', 'on', true);
--
--     r := r || 'with the insert working — conversion succeeded: '
--            || (v_case IS NOT NULL)
--            || ', notifications written: '
--            || (SELECT count(*) FROM notifications WHERE subject_id = v_case)
--            || ', to the manager: '
--            || (EXISTS (SELECT 1 FROM notifications
--                         WHERE subject_id = v_case AND user_id = v_mgr))
--            || ', to the converter: '
--            || (SELECT count(*) FROM notifications
--                 WHERE subject_id = v_case AND user_id = v_actor)
--            || '   (expect true, 1, true, 0)' || chr(10);
--     r := r || 'body: '
--            || COALESCE((SELECT body FROM notifications
--                          WHERE subject_id = v_case LIMIT 1), 'NONE') || chr(10);
--   EXCEPTION WHEN others THEN
--     PERFORM set_config('role', 'postgres', true);
--     PERFORM set_config('app.is_internal', 'on', true);
--     r := r || 'normal path NOT RUN: ' || SQLERRM || chr(10);
--   END;
--
--   RAISE EXCEPTION 'VERIFY 20261102T1600_notification_cannot_stop_a_conversion (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
