-- =============================================================================
-- 20261030T1930_case_converted_notification.sql
-- The Hub — managers hear about a conversion they didn't gate.
--
-- WHY. Conversion is ungated: anyone may create a case, because a director on
-- the call knows it is converting and shouldn't wait for someone else to click
-- (057, and the ruling it carries). The thing given up in exchange was managers
-- having control, and what they were promised instead was visibility. Nothing
-- delivers that today, so the gate was given up for nothing.
--
-- WHAT 019 LEFT OUT. It has what a person WANTS (notification_preferences) and
-- what was SENT (notification_log, whose comment is "Josh says he never got the
-- assignment alert"). There is no row for the thing in between: something
-- happened that someone should hear about. That gap is why no sender exists —
-- there has never been anything for one to drain. Both databases confirm it:
-- notification_log has 0 rows, nothing references either table, and there is no
-- pg_cron, pg_net or http extension anywhere.
--
-- This adds that middle row, and desktop then needs no sender at all: the app
-- reads the table. Email and SMS still need a dispatcher and still have none,
-- which is why this seeds desktop only.
--
-- TWO TRANSACTIONS, deliberately. ALTER TYPE ... ADD VALUE cannot be used in
-- the transaction that adds it — Postgres refuses with "unsafe use of new value
-- of enum type". Everything referring to 'case_converted' therefore follows in
-- a second block. The file's record of what ran is both bodies, not one.
--
-- Requires, by what it actually uses:
--   004  case_need_type
--   016  history_entity, which already includes 'case'
--   019  notification_event, notification_preferences, notification_log
--   057  cases, case_decedents, create_case_for_call
--   plus users.active / is_internal and user_scopes.view_profile (003)
--
-- Safe to run twice: the enum add is IF NOT EXISTS, the table and trigger are
-- guarded, and the preference seed is ON CONFLICT DO NOTHING.
--
-- STAGING, 2 Nov 2026: BLOCK 1 APPLIED, BLOCK 2 FAILED AND ROLLED BACK. So
-- 'case_converted' is already a notification_event value on staging while
-- none of the table, functions or triggers exist — which is what the two
-- blocks being separate transactions means, and why block 1 is written to be
-- re-runnable rather than skipped.
--
-- Section 5's seed raised "column event is of type notification_event but
-- expression is of type text". DISTINCT forces an unknown literal to resolve
-- before the insert's coercion to the target column applies, so a SELECT with
-- DISTINCT needs an explicit cast where a plain VALUES list does not. Every
-- insert of an enum literal in this file now casts, including the one in the
-- trigger, which is the one that would take case creation down with it.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Block 1 — the enum value, alone, because it must commit before it is used
-- -----------------------------------------------------------------------------
ALTER TYPE notification_event ADD VALUE IF NOT EXISTS 'case_converted';

-- -----------------------------------------------------------------------------
-- Block 2 — everything that refers to it
-- -----------------------------------------------------------------------------
BEGIN;

-- -----------------------------------------------------------------------------
-- 1. A notification: something happened that someone should hear about
--
-- One row per recipient, fanned out at write, which is the shape
-- notification_log already uses. A notification is not a send: nothing here
-- claims anything was delivered. When a dispatcher exists it drains this for
-- the email and sms channels and writes notification_log as it goes; the
-- desktop channel is this table read directly, which is why desktop works the
-- day this runs and the others don't.
--
-- read_at rather than a boolean: when it was read is worth more than that it
-- was, and null is unread.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,

  event notification_event NOT NULL,

  -- What it is about, in change_history's vocabulary so a notification and a
  -- history row point at the same thing the same way.
  subject_entity history_entity,
  subject_id uuid,

  body text NOT NULL,

  created_at timestamptz NOT NULL DEFAULT now(),
  read_at timestamptz
);

CREATE INDEX IF NOT EXISTS notifications_unread_idx
  ON notifications (user_id, created_at DESC) WHERE read_at IS NULL;
CREATE INDEX IF NOT EXISTS notifications_subject_idx
  ON notifications (subject_entity, subject_id);

COMMENT ON TABLE notifications IS
  'Something happened that someone should hear about — the row 019 had no '
  'place for, between a preference (what a person wants) and a log entry '
  '(what was sent). One row per recipient. Nothing here asserts delivery: '
  'the desktop channel is this table read by the app, and email and sms wait '
  'on a dispatcher that does not exist yet.';

COMMENT ON COLUMN notifications.read_at IS
  'When the person read it; null is unread. Only the recipient may set it.';

-- -----------------------------------------------------------------------------
-- 2. Row-level security
--
-- Reading is self-only, like notification_preferences and notification_log: a
-- manager's notifications are nobody else's business.
--
-- THERE IS NO INSERT POLICY, deliberately. An earlier draft had one scoped to
-- the organization, on the reasoning that a notification is written for
-- someone else by definition so a self-only WITH CHECK could not work. Both
-- halves of that were wrong. It would have let any signed-in user put a
-- notification with any text they liked into a colleague's bell straight
-- through the API — a message that looks like it came from the Hub. And it
-- would not have worked anyway: section 4's writer is SECURITY DEFINER, so it
-- is not subject to these policies at all.
--
-- With no INSERT policy, nobody inserts here except that function. That is the
-- whole intent: the bell says what happened, not what someone typed.
-- -----------------------------------------------------------------------------
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS notifications_self ON notifications;
CREATE POLICY notifications_self ON notifications
  FOR SELECT USING (is_internal() OR user_id = current_user_id());

DROP POLICY IF EXISTS notifications_own_read_state ON notifications;
CREATE POLICY notifications_own_read_state ON notifications
  FOR UPDATE USING (is_internal() OR user_id = current_user_id())
         WITH CHECK (is_internal() OR user_id = current_user_id());

-- Removes the org-wide INSERT policy if an earlier draft of this file ever
-- reached a database.
DROP POLICY IF EXISTS notifications_write_in_org ON notifications;

-- -----------------------------------------------------------------------------
-- 2b. An absent preference row means off, and so does a careless one
--
-- 019 gave notification_preferences.enabled a default of true, which disagrees
-- with how the app reads the table: no row means off. So a row written without
-- saying anything turns a notification ON, while no row at all leaves it off —
-- the quiet case and the quieter case landing on opposite answers.
--
-- Set to false rather than dropped: dropping it would make any existing insert
-- that omits the column fail outright, and this file cannot see every caller.
-- Drop it instead if you would rather that failure be loud; every insert in
-- this file names the value explicitly either way.
-- -----------------------------------------------------------------------------
ALTER TABLE notification_preferences ALTER COLUMN enabled SET DEFAULT false;

COMMENT ON COLUMN notification_preferences.enabled IS
  'Whether this person wants this event on this channel. Defaults to false, '
  'matching the app''s reading that an absent row is off — a row written '
  'without an opinion should not turn something on.';

-- -----------------------------------------------------------------------------
-- 3. Who hears about it
--
-- The same people can_manage_settings() admits (038: current_view_profile() in
-- internal, owner, manager), expressed as a set for one organization rather
-- than as a test of the current user. Internal staff are excluded: Dead Ringers
-- does not want every client's conversions.
--
-- A user may hold more than one scope row, so the set is DISTINCT — otherwise
-- a manager who is also an owner is notified twice.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION case_notification_recipients(p_org uuid)
RETURNS TABLE (user_id uuid) LANGUAGE sql STABLE AS $$
  SELECT DISTINCT u.id
    FROM user_scopes s
    JOIN users u ON u.id = s.user_id
   WHERE s.organization_id = p_org
     AND s.revoked_on IS NULL
     AND s.view_profile IN ('owner', 'manager')
     AND u.active
     AND NOT u.is_internal
$$;

COMMENT ON FUNCTION case_notification_recipients(uuid) IS
  'The managers and owners of one firm, for notifications about its cases. '
  'The same people can_manage_settings() admits, minus Dead Ringers'' own '
  'staff: internal users administer the platform and do not want every '
  'client''s conversions. DISTINCT because a user may hold several scopes.';

-- -----------------------------------------------------------------------------
-- 4. The trigger, on case_decedents rather than on cases
--
-- WHY NOT ON cases. create_case_for_call() (057) inserts the case first and
-- case_decedents after it, so a trigger on cases fires before the decedent
-- exists and cannot name the family — which is the one thing a manager reads
-- the notification for. The decedent link is the moment the case becomes
-- describable.
--
-- WHY NOT INSIDE create_case_for_call(). It would sit naturally beside the
-- record_change() calls, but it would mean replacing a function body that 058
-- has already rewritten, for a change that has nothing to do with what the
-- function does. A trigger leaves it alone and also catches a case created any
-- other way.
--
-- FIRST DECEDENT ONLY. A second decedent added to an existing case is not a
-- conversion, and one case must not notify twice.
--
-- The caller is read through cases.converting_interaction_id, not through
-- case_contacts, which create_case_for_call() has not inserted yet at this
-- point. Same ordering trap, one row further on.
--
-- Absence of a preference row means off — that is how the app reads it — so
-- the EXISTS below is what makes section 5's seed load-bearing rather than
-- cosmetic.
-- -----------------------------------------------------------------------------
-- WHY THIS IS SECURITY DEFINER, which 037 otherwise keeps scarce.
--
-- create_case_for_call() (057) runs with invoker rights — deliberately, so
-- that anyone who may write the rows may create a case. This trigger
-- therefore runs as the person converting.
--
-- The blocker this file can prove: notification_preferences_self is
-- FOR ALL USING (is_internal() OR user_id = current_user_id()), so the EXISTS
-- below, asked as an ordinary user, sees nobody's preference row but their
-- own. Every recipient fails that test, every conversion writes zero
-- notifications, and nothing says so. That alone is enough.
--
-- What this file does NOT establish is whether the recipients are visible at
-- all. On staging user_scopes_read is
--   USING (is_internal() OR user_id = current_user_id()
--          OR organization_id = current_organization_id())
-- which is org-wide, and users_read is USING (can_see_user(id)), whose answer
-- for a colleague is not something this migration checks. So the recipient
-- set may be visible or may not; the preference check fails either way.
--
-- (An earlier draft of this comment cited users_self and user_scopes_self
-- from 003. Those are not the live policies — they were replaced since, and
-- the comment was describing the repository rather than the database.)
--
-- WHY THE WORK IS IN THE TRIGGER FUNCTION ITSELF, and not a helper. A helper
-- would need EXECUTE for the converter to call it, and granting that gives
-- any signed-in user the ability to fire notifications about any case id they
-- can name. Revoking it instead makes the PERFORM raise permission denied,
-- which aborts create_case_for_call() — the notification feature would stop
-- anyone creating a case at all. A function returning trigger cannot be
-- called through PostgREST or plain SQL, so putting the work here is private
-- by construction and needs no grant in either direction.
--
-- current_user_id() reads app.user_id, which SECURITY DEFINER does not
-- change, so "not the person who did it" still means the converter. The
-- verification's "to the converter: 0" line is what proves that.
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
  -- Cast, as in sections 5 and 6. Without DISTINCT this INSERT ... SELECT
  -- would resolve the literals against the target columns on its own — but
  -- this one runs on every conversion, and a type error here aborts
  -- create_case_for_call(). It is not a place to rely on an implicit step.
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
  'rather than a helper so that there is no grantable entry point to it.';

-- An earlier draft put the work in a helper. Removed: it had to be granted to
-- be callable and revoked to be safe, and those are the same function.
DROP FUNCTION IF EXISTS notify_case_converted(uuid);

DROP TRIGGER IF EXISTS case_converted_notify_t ON case_decedents;
CREATE TRIGGER case_converted_notify_t AFTER INSERT ON case_decedents
  FOR EACH ROW EXECUTE FUNCTION case_converted_notify();

-- -----------------------------------------------------------------------------
-- 5. On by default, for the managers who exist today
--
-- On, because the ruling gave up the gate on conversion in exchange for this.
-- If it defaults off, the substitute does not exist until somebody finds the
-- setting, and the trade was for nothing.
--
-- Desktop only. Email by default is how a person switches every notification
-- off, and 019's reachability trigger would refuse an enabled email or sms row
-- outright for a user with no notify_email or notify_sms_e164 — the seed would
-- fail rather than degrade.
-- -----------------------------------------------------------------------------
-- Cast explicitly. In an INSERT ... SELECT the bare literals are resolved as
-- text before the target column's type is considered — with DISTINCT forcing
-- that resolution early — and the insert fails with "column event is of type
-- notification_event but expression is of type text". A plain VALUES list
-- happens to survive this; a SELECT does not.
INSERT INTO notification_preferences (user_id, event, channel, enabled)
SELECT DISTINCT u.id,
       'case_converted'::notification_event,
       'desktop'::notification_channel,
       true
  FROM user_scopes s
  JOIN users u ON u.id = s.user_id
 WHERE s.revoked_on IS NULL
   AND s.view_profile IN ('owner', 'manager')
   AND u.active
   AND NOT u.is_internal
ON CONFLICT (user_id, event, channel) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 6. And for the managers who arrive later
--
-- Without this, the default applies only to people who were managers on
-- 30 Oct 2026. Everybody promoted afterwards gets no row, an absent row is
-- off, and the feature quietly stops reaching new managers — the kind of
-- half-working nobody reports, because nothing is broken on screen.
--
-- Cut this section if the seed should be a one-off; the rest stands without it.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION user_scope_default_notifications() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.revoked_on IS NOT NULL OR NEW.view_profile NOT IN ('owner', 'manager') THEN
    RETURN NULL;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM users WHERE id = NEW.user_id
                  AND active AND NOT is_internal) THEN
    RETURN NULL;
  END IF;

  -- Cast for the same reason as section 5, though a VALUES list would resolve
  -- these against the target columns on its own. Written the same way so the
  -- two inserts do not differ in a way that invites someone to "simplify" the
  -- one that needs it.
  INSERT INTO notification_preferences (user_id, event, channel, enabled)
  VALUES (NEW.user_id,
          'case_converted'::notification_event,
          'desktop'::notification_channel,
          true)
  ON CONFLICT (user_id, event, channel) DO NOTHING;

  RETURN NULL;
END $$;

COMMENT ON FUNCTION user_scope_default_notifications() IS
  'Gives a newly promoted manager the same default a manager on 30 Oct 2026 '
  'got. Without it the seed in section 5 applies only to people who already '
  'held the role, and an absent preference row is off — so the feature would '
  'silently stop reaching anyone hired after it shipped.';

DROP TRIGGER IF EXISTS user_scope_default_notifications_t ON user_scopes;
CREATE TRIGGER user_scope_default_notifications_t
  AFTER INSERT OR UPDATE OF view_profile, revoked_on ON user_scopes
  FOR EACH ROW EXECUTE FUNCTION user_scope_default_notifications();

REVOKE ALL ON FUNCTION case_notification_recipients(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION case_notification_recipients(uuid) TO authenticated;

COMMIT;

-- =============================================================================
-- STILL TO DO, named so they aren't folded in and skipped
--
-- * THIS FEATURE IS DORMANT THE DAY IT RUNS. Neither database has an active,
--   non-internal owner or manager in any firm, so section 5 seeds no rows and
--   case_notification_recipients() returns nobody: every conversion will
--   notify no one. That is correct behaviour, not a defect — but it means the
--   migration cannot be confirmed working by using the product, and the
--   verification block's zero counts are the expected result rather than a
--   failure. It starts working the day real firm manager logins exist, and
--   section 6's trigger is what makes that automatic. Until then the only
--   evidence it works is the verification block, which creates a manager of
--   its own.
-- * No dispatcher exists. Email and sms preferences for this event can be set
--   and will never fire. Either the Settings screen offers desktop alone for
--   this event, or a dispatcher is built; leaving both channels selectable
--   with nothing behind them is the "preference that silently never fires"
--   019's reachability trigger was written to prevent.
-- * notification_log is still unwritten by anything. When a dispatcher drains
--   this table it should write that log as it goes; until then "Josh never got
--   it" has no answer for this event either.
-- * The app's events list is hardcoded in settings/page.tsx and needs
--   'case_converted' with a label.
-- * Nothing marks a notification read. The app needs that write; the UPDATE
--   policy above already allows only the recipient to do it.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
-- Set-up failures are reported rather than raised, so a collision costs one
-- line and not the whole report.
--
-- DO $$
-- DECLARE
--   r text := ''; v_org uuid; v_mgr uuid; v_actor uuid; v_call uuid;
--   v_case uuid; v_n int;
-- BEGIN
--   SELECT id INTO v_org FROM organizations WHERE code = 'DR';
--
--   r := r || 'enum has case_converted: '
--          || EXISTS (SELECT 1 FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
--                      WHERE t.typname = 'notification_event'
--                        AND e.enumlabel = 'case_converted')
--          || '   (expect true)' || chr(10);
--
--   SELECT count(*) INTO v_n FROM case_notification_recipients(v_org);
--   r := r || 'managers at this firm: ' || v_n || chr(10);
--
--   SELECT count(*) INTO v_n FROM notification_preferences
--    WHERE event = 'case_converted' AND channel = 'desktop' AND enabled;
--   r := r || 'seeded desktop preferences: ' || v_n
--          || '   (one per manager — EXPECT 0 TODAY: neither database has an '
--          || 'active non-internal manager, so section 5 seeds nothing and '
--          || 'the managers count above is 0 too. Dormant, not broken.)' || chr(10);
--
--   -- A manager is CREATED here, not looked up. Neither database has an
--   -- active, non-internal owner or manager in any firm today, so a lookup
--   -- finds nobody and every test below reports SKIPPED — which is also why
--   -- the counts above read 0 rather than failing. Rolled back with the rest.
--   BEGIN
--     INSERT INTO users (email, full_name, is_internal, active)
--     VALUES ('verify.manager@example.invalid', 'Verify Manager', false, true)
--     RETURNING id INTO v_mgr;
--     INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id)
--     VALUES (v_mgr, 'organization', 'manager', v_org);
--
--     r := r || 'created manager is a recipient: '
--            || EXISTS (SELECT 1 FROM case_notification_recipients(v_org)
--                        WHERE user_id = v_mgr)
--            || '   (expect true)' || chr(10);
--
--     -- Section 6's trigger should have given them the default on the spot.
--     r := r || 'promotion seeded a preference: '
--            || EXISTS (SELECT 1 FROM notification_preferences
--                        WHERE user_id = v_mgr AND event = 'case_converted'
--                          AND channel = 'desktop' AND enabled)
--            || '   (expect true)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'manager creation NOT RUN: ' || SQLERRM || chr(10); END;
--
--   -- A real conversion, as the app does it.
--   --
--   -- The converter is a NON-manager, created here. Two reasons, both of
--   -- which the earlier draft of this block got wrong. If the converter is
--   -- the only manager, "expect managers minus one" is 0 whether the feature
--   -- works or not, so the test cannot fail. And running as the superuser
--   -- with app.is_internal on skips RLS entirely, which is the one thing
--   -- that breaks this: as an ordinary user, users, user_scopes and
--   -- notification_preferences are all self-only.
--   BEGIN
--     INSERT INTO users (email, full_name, is_internal, active)
--     VALUES ('verify.converter@example.invalid', 'Verify Converter', false, true)
--     RETURNING id INTO v_actor;
--     INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id)
--     VALUES (v_actor, 'organization', 'professional', v_org);
--
--     SELECT i.id INTO v_call FROM interactions i
--      WHERE i.organization_id = v_org AND i.contact_id IS NOT NULL AND i.case_id IS NULL
--      ORDER BY i.occurred_at DESC LIMIT 1;
--
--     -- Become that person, for real: RLS does not apply to the table owner.
--     PERFORM set_config('app.is_internal', 'off', true);
--     PERFORM set_config('app.organization_id', v_org::text, true);
--     PERFORM set_config('app.user_id', v_actor::text, true);
--     PERFORM set_config('role', 'authenticated', true);
--
--     -- What the converter can see for themselves, which is what the trigger
--     -- would have had to work with if it ran as them. The recipient count is
--     -- reported without an expectation: user_scopes_read is org-wide and
--     -- users_read goes through can_see_user(), so it may be non-zero. The
--     -- preference count is the one that is certain, and it is the reason the
--     -- function is SECURITY DEFINER.
--     r := r || 'as the converter — recipients visible: '
--            || (SELECT count(*) FROM case_notification_recipients(v_org))
--            || ' (policy-dependent, no expectation), other people''s '
--            || 'preference rows visible: '
--            || (SELECT count(*) FROM notification_preferences
--                 WHERE user_id IS DISTINCT FROM v_actor)
--            || '   (expect 0 — notification_preferences_self)' || chr(10);
--
--     v_case := create_case_for_call(v_call, 'at_need', 'at_need', 'Verify', 'Helen',
--                                    current_date, NULL, NULL, '{}');
--
--     -- Counted with RLS lifted again: the converter cannot read a
--     -- notification written for someone else, which is itself the proof
--     -- that notifications_self is doing its job.
--     PERFORM set_config('role', 'postgres', true);
--     PERFORM set_config('app.is_internal', 'on', true);
--
--     r := r || 'notifications written: '
--            || (SELECT count(*) FROM notifications
--                 WHERE subject_entity = 'case' AND subject_id = v_case)
--            || '   (expect 1 — the created manager, who is not the converter)'
--            || chr(10);
--     r := r || 'to the manager: '
--            || EXISTS (SELECT 1 FROM notifications
--                        WHERE subject_id = v_case AND user_id = v_mgr)
--            || ', to the converter: '
--            || (SELECT count(*) FROM notifications
--                 WHERE subject_id = v_case AND user_id = v_actor)
--            || '   (expect true, 0)' || chr(10);
--     r := r || 'body: '
--            || COALESCE((SELECT body FROM notifications
--                          WHERE subject_id = v_case LIMIT 1), 'NONE') || chr(10);
--
--     -- A second decedent on the same case must not notify again.
--     SELECT count(*) INTO v_n FROM notifications WHERE subject_id = v_case;
--     INSERT INTO decedents (organization_id, last_name, status)
--     VALUES (v_org, 'Second', 'at_need');
--     INSERT INTO case_decedents (case_id, decedent_id)
--     SELECT v_case, id FROM decedents WHERE last_name = 'Second' AND organization_id = v_org;
--     r := r || 'second decedent notified again: '
--            || ((SELECT count(*) FROM notifications WHERE subject_id = v_case) <> v_n)
--            || '   (expect false)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'conversion test NOT RUN: ' || SQLERRM || chr(10); END;
--
--   RAISE EXCEPTION 'VERIFY 20261030T1930_case_converted_notification (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
