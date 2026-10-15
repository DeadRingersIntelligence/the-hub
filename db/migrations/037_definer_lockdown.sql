-- =============================================================================
-- 037_definer_lockdown.sql
-- The Hub — migration 37: SECURITY DEFINER functions were reachable by anon,
-- and three of them crossed tenants.
--
-- NOTE ON NUMBERING. Written as 036, after a reminder-closing migration
-- written as 035 that collided with 035_definer_tenancy.sql. Staging ran both
-- under those numbers. They are committed as 036_reminder_closing.sql and this
-- file, so a fresh database replays the columns, trigger and views this file
-- rewrites before it rewrites them. Nothing needs re-running on staging.
--
-- WHAT WAS WRONG
--
-- Postgres grants EXECUTE on a new function to PUBLIC by default. Granting it
-- to `authenticated` adds a grant; it does not remove that one. Nine definer
-- functions were therefore callable by `anon`, whose key ships in the browser.
-- A definer function runs as its owner, so anon calling one executes with
-- owner rights — which is the whole point of the attribute and the whole danger
-- of leaving it open.
--
-- Three of them also took an id and never checked whose it was:
-- close_reminder, post_to_thread and find_or_start_thread. Any reminder in any
-- firm could be closed by anyone who knew a uuid.
--
-- THE RULE, WHICH IS NOW IN db/README.md
--
-- Every SECURITY DEFINER function needs two things in the same migration that
-- creates it: a tenancy check inside, and an explicit REVOKE FROM PUBLIC, anon
-- alongside the GRANT. The default is PUBLIC and PUBLIC includes anon.
--
-- Requires: 001 to 036
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Take back the default grant on everything
--
-- Done by scanning rather than by listing, so a function nobody remembered is
-- covered too. That is the point: the ones that bite are the forgotten ones.
-- -----------------------------------------------------------------------------
DO $$
DECLARE f RECORD;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.prosecdef
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.sig);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', f.sig);
  END LOOP;
END $$;

-- Then grant back, deliberately, only what the app actually calls.
GRANT EXECUTE ON FUNCTION claim_hub_identity()                      TO authenticated;
GRANT EXECUTE ON FUNCTION set_active_organization(uuid)             TO authenticated;
GRANT EXECUTE ON FUNCTION my_organizations()                        TO authenticated;
GRANT EXECUTE ON FUNCTION dialstack_identity(uuid)                  TO authenticated;
GRANT EXECUTE ON FUNCTION dialstack_identity_gaps(uuid)             TO authenticated;
GRANT EXECUTE ON FUNCTION find_or_start_thread(thread_scope, uuid, text)
                                                                    TO authenticated;
GRANT EXECUTE ON FUNCTION post_to_thread(thread_scope, uuid, text, uuid)
                                                                    TO authenticated;

-- current_user_id, is_internal and current_organization_id are called by the
-- policies themselves, so they stay reachable — but PUBLIC has been revoked, so
-- anon cannot call them directly to probe.
GRANT EXECUTE ON FUNCTION current_user_id()         TO authenticated;
GRANT EXECUTE ON FUNCTION is_internal()             TO authenticated;
GRANT EXECUTE ON FUNCTION current_organization_id() TO authenticated;

-- dialstack_identity_gaps_all() is an operator's tool, not the app's. No grant.

-- -----------------------------------------------------------------------------
-- 2. close_reminder — tenancy, a live-state guard, and the due date left alone
--
-- The previous version ran a bare UPDATE on an id. Rewritten to:
--   refuse a reminder outside the caller's organization,
--   refuse one that is already closed rather than silently re-closing it,
--   keep due_at as the date it was actually due.
--
-- WHY SNOOZING NO LONGER KEEPS due_at IN SYNC. Overwriting due_at with the
-- wake time destroys when the thing was actually needed by — and that is the
-- fact a late follow-up is measured against. `snoozed_until` says when to
-- resurface; `due_at` says when it mattered. The list orders on
-- COALESCE(snoozed_until, due_at).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION close_reminder(
  p_reminder uuid,
  p_state reminder_state,
  p_snooze_until timestamptz DEFAULT NULL)
RETURNS reminders LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r reminders; v_user uuid;
BEGIN
  v_user := current_user_id();
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'not signed in';
  END IF;

  IF p_state = 'open' THEN
    RAISE EXCEPTION 'close_reminder does not reopen — update the reminder directly';
  END IF;

  IF p_state = 'snoozed' AND p_snooze_until IS NULL THEN
    RAISE EXCEPTION 'snoozing needs a time to wake up';
  END IF;
  IF p_state = 'snoozed' AND p_snooze_until <= now() THEN
    RAISE EXCEPTION 'a snooze has to wake up in the future';
  END IF;

  SELECT * INTO r FROM reminders WHERE id = p_reminder;
  IF r.id IS NULL THEN RAISE EXCEPTION 'no such reminder'; END IF;

  -- The check the old version did not have. A definer function bypasses RLS,
  -- so the policy underneath is not doing this for us.
  IF NOT is_internal()
     AND r.organization_id IS DISTINCT FROM current_organization_id() THEN
    RAISE EXCEPTION 'no access to that reminder';
  END IF;

  -- Only something live can be closed. Without this, closing an already-done
  -- reminder rewrites who closed it and when.
  IF r.state NOT IN ('open', 'snoozed') THEN
    RAISE EXCEPTION 'that reminder is already %', r.state;
  END IF;

  UPDATE reminders
     SET state = p_state,
         snoozed_until = CASE WHEN p_state = 'snoozed' THEN p_snooze_until END,
         updated_at = now()
   WHERE id = p_reminder
  RETURNING * INTO r;

  RETURN r;
END $$;

REVOKE ALL ON FUNCTION close_reminder(uuid, reminder_state, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION close_reminder(uuid, reminder_state, timestamptz) TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. The closer, recorded honestly
--
-- The old trigger filled the closer only when empty and fired on snooze too. So
-- a reminder Tom snoozed and Ruth later completed read "Done by Tom", stamped
-- at the snooze. Theresa's seeded reminder went through exactly that sequence.
--
-- Two changes. It overwrites on every close, because the last person to close
-- it is the one who closed it. And a snooze no longer stamps a closer at all —
-- setting something aside until tomorrow is not closing it, and recording it as
-- one makes a postponement look like a decision.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reminders_stamp_closer() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_user uuid;
BEGIN
  IF NEW.state = OLD.state THEN RETURN NEW; END IF;

  -- Reopening, or going back to snoozed, clears the record rather than leaving
  -- a stale closer on something that is live again.
  IF NEW.state IN ('open', 'snoozed') THEN
    NEW.closed_at := NULL; NEW.closed_by_user_id := NULL;
    NEW.closed_by_label := NULL; NEW.completed_at := NULL;
    RETURN NEW;
  END IF;

  v_user := current_user_id();
  NEW.closed_at         := now();
  NEW.closed_by_user_id := v_user;
  NEW.closed_by_label   := (SELECT full_name FROM users WHERE id = v_user);
  NEW.completed_at      := CASE WHEN NEW.state = 'done' THEN now() END;

  RETURN NEW;
END $$;

-- Anything stamped by the old trigger during a snooze is wrong — it names
-- whoever postponed it as whoever closed it. Clear those; the ones closed since
-- are correct and are left alone.
UPDATE reminders
   SET closed_at = NULL, closed_by_user_id = NULL, closed_by_label = NULL
 WHERE state = 'snoozed' AND closed_at IS NOT NULL;

-- -----------------------------------------------------------------------------
-- 4. Reminders set on a case alone
--
-- The summary resolved a contact from the reminder or from its call, so a
-- reminder set on a case and nothing else reached nobody — and the app could
-- not use the view. A case reaches its contacts through case_contacts, which is
-- where the family already is.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW contact_reminders WITH (security_invoker = true) AS
SELECT r.*, x.contact_id AS resolved_contact_id
FROM reminders r
CROSS JOIN LATERAL (
  -- Set on the contact, or on one of their calls, or on a case they are on.
  SELECT r.contact_id AS contact_id WHERE r.contact_id IS NOT NULL
  UNION
  SELECT i.contact_id FROM interactions i
   WHERE i.id = r.interaction_id AND r.contact_id IS NULL
     AND i.contact_id IS NOT NULL
  UNION
  SELECT cc.contact_id FROM case_contacts cc
   WHERE cc.case_id = r.case_id AND r.contact_id IS NULL
) AS x
WHERE x.contact_id IS NOT NULL;

COMMENT ON VIEW contact_reminders IS
  'Reminders with every contact they concern — set on the contact, on one of '
  'their calls, or on a case they are a party to. A case reminder appears '
  'against each family member on the case, which is what the Contacts list '
  'needs: three siblings should each show that something is outstanding.';

COMMIT;

-- =============================================================================
-- Verification
--
--   SET app.is_internal = 'on';
--   SET app.user_id = '<your users.id>';
--
-- 1. Nothing definer is reachable by anon
--
--   SELECT p.proname
--   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--   WHERE n.nspname = 'public' AND p.prosecdef
--     AND has_function_privilege('anon', p.oid, 'EXECUTE')
--   ORDER BY 1;
--   -- expect: no rows
--
-- 2. Closing something already closed is refused
--
--   SELECT close_reminder(
--     (SELECT id FROM reminders WHERE created_by='staging seed'
--        AND state='done' LIMIT 1), 'done');
--   -- expect: that reminder is already done
--
-- 3. A snooze keeps the original due date and names no closer
--
--   SELECT close_reminder(
--     (SELECT id FROM reminders WHERE created_by='staging seed'
--        AND state='open' ORDER BY due_at LIMIT 1),
--     'snoozed', now() + interval '1 day');
--
--   SELECT state, due_at, snoozed_until, closed_by_label
--   FROM reminders WHERE created_by='staging seed' AND state='snoozed';
--   -- due_at unchanged, snoozed_until tomorrow, closed_by_label null
--
-- 4. A case reminder now reaches every family member on the case
--
--   SELECT c.full_name, s.open_count, s.next_due_at
--   FROM contacts c JOIN contact_reminder_summary s ON s.contact_id = c.id
--   WHERE c.notes = 'staging seed'
--   ORDER BY c.full_name;
--   -- Dana and Paul Novak should both show the case reminder
--
-- 5. Ordering a list: snoozed items resurface, due dates do not move
--
--   SELECT note, due_at, snoozed_until,
--          COALESCE(snoozed_until, due_at) AS shows_at
--   FROM reminders WHERE created_by='staging seed' AND state IN ('open','snoozed')
--   ORDER BY shows_at;
-- =============================================================================
