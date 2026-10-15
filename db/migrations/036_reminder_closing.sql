-- =============================================================================
-- 036_reminder_closing.sql
-- The Hub — migration 36: who closed a reminder, and reminders per contact.
--
-- ONE — anyone in the firm can close a colleague's reminder, and that is
-- deliberate. Deathcare runs on-call rotations and people are off at short
-- notice; a reminder nobody can clear because its owner is on leave is worse
-- than one a colleague cleared. The policy stays organization-scoped.
--
-- But that makes the next question certain to be asked: who closed it.
-- `completed_at` says when and nothing says who. Permission without a record is
-- how a team ends up arguing about a call that was marked done and never made.
--
-- TWO — the Contacts list was resolving reminders by listing every call id for
-- up to two hundred contacts and querying against that. It works and it will
-- not keep working. One summary row per contact is the right shape, and it has
-- to cover both ways a reminder reaches a contact: set on the contact
-- directly, and set on a call that belongs to them.
--
-- Requires: 001 to 034
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Who closed it
-- -----------------------------------------------------------------------------
ALTER TABLE reminders ADD COLUMN closed_by_user_id uuid REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE reminders ADD COLUMN closed_by_label   text;
ALTER TABLE reminders ADD COLUMN closed_at         timestamptz;

COMMENT ON COLUMN reminders.closed_by_user_id IS
  'Who moved this out of open — done, canceled or snoozed. Anyone in the firm '
  'may, which is deliberate: on-call rotations mean a colleague has to be able '
  'to clear it. This is the record that makes that safe.';
COMMENT ON COLUMN reminders.closed_by_label IS
  'Their name as it was at the time, so the record reads after they leave.';
COMMENT ON COLUMN reminders.closed_at IS
  'When it was closed, whatever it was closed to. Distinct from completed_at, '
  'which means specifically that the work was done.';

-- Stamped automatically on any state change away from open, whichever path
-- makes it — a function, the app, or a hand-written update. A rule that only
-- holds when someone remembers to call the right function is not a rule.
CREATE OR REPLACE FUNCTION reminders_stamp_closer() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_user uuid;
BEGIN
  IF NEW.state <> OLD.state AND NEW.state <> 'open' THEN
    v_user := current_user_id();
    NEW.closed_at         := COALESCE(NEW.closed_at, now());
    NEW.closed_by_user_id := COALESCE(NEW.closed_by_user_id, v_user);
    NEW.closed_by_label   := COALESCE(
      NEW.closed_by_label,
      (SELECT full_name FROM users WHERE id = v_user));

    IF NEW.state = 'done' THEN
      NEW.completed_at := COALESCE(NEW.completed_at, now());
    END IF;
  END IF;

  -- Reopening clears the record rather than leaving a stale closer on an open
  -- reminder.
  IF NEW.state = 'open' AND OLD.state <> 'open' THEN
    NEW.closed_at := NULL; NEW.closed_by_user_id := NULL;
    NEW.closed_by_label := NULL; NEW.completed_at := NULL;
  END IF;

  RETURN NEW;
END $$;
CREATE TRIGGER reminders_stamp_closer_t BEFORE UPDATE ON reminders
  FOR EACH ROW EXECUTE FUNCTION reminders_stamp_closer();

-- -----------------------------------------------------------------------------
-- Closing one
--
-- A single entry point, so the app does not restate the state machine. The
-- trigger above means a direct update is stamped too; this is the convenient
-- path, not the only safe one.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION close_reminder(
  p_reminder uuid,
  p_state reminder_state,
  p_snooze_until timestamptz DEFAULT NULL)
RETURNS reminders LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r reminders;
BEGIN
  IF p_state = 'snoozed' AND p_snooze_until IS NULL THEN
    RAISE EXCEPTION 'snoozing needs a time to wake up';
  END IF;

  UPDATE reminders
     SET state = p_state,
         snoozed_until = CASE WHEN p_state = 'snoozed' THEN p_snooze_until END,
         due_at = CASE WHEN p_state = 'snoozed' THEN p_snooze_until ELSE due_at END,
         updated_at = now()
   WHERE id = p_reminder
  RETURNING * INTO r;

  IF r.id IS NULL THEN RAISE EXCEPTION 'no such reminder'; END IF;
  RETURN r;
END $$;

GRANT EXECUTE ON FUNCTION close_reminder(uuid, reminder_state, timestamptz)
  TO authenticated;

-- -----------------------------------------------------------------------------
-- Reminders per contact
--
-- A reminder reaches a contact two ways: set on them directly, or set on a call
-- that belongs to them. The list needs both, which is why it was expanding call
-- ids in the first place.
--
-- security_invoker so the view is read as the caller rather than as its owner —
-- without it a view is a way around the policies underneath it.
-- -----------------------------------------------------------------------------
CREATE VIEW contact_reminders WITH (security_invoker = true) AS
SELECT r.*, COALESCE(r.contact_id, i.contact_id) AS resolved_contact_id
FROM reminders r
LEFT JOIN interactions i ON i.id = r.interaction_id
WHERE COALESCE(r.contact_id, i.contact_id) IS NOT NULL;

COMMENT ON VIEW contact_reminders IS
  'Reminders with the contact they concern resolved, whether set on the contact '
  'or on one of their calls.';

CREATE VIEW contact_reminder_summary WITH (security_invoker = true) AS
SELECT
  r.organization_id,
  r.resolved_contact_id AS contact_id,
  count(*) FILTER (WHERE r.state = 'open')                      AS open_count,
  count(*) FILTER (WHERE r.state = 'open' AND r.due_at < now()) AS overdue_count,
  count(*) FILTER (WHERE r.state = 'snoozed')                   AS snoozed_count,
  min(r.due_at) FILTER (WHERE r.state = 'open')                 AS next_due_at,
  (array_agg(r.note ORDER BY r.due_at)
     FILTER (WHERE r.state = 'open'))[1]                        AS next_note,
  (array_agg(r.owner_user_id ORDER BY r.due_at)
     FILTER (WHERE r.state = 'open'))[1]                        AS next_owner_user_id
FROM contact_reminders r
WHERE r.state IN ('open', 'snoozed')
GROUP BY r.organization_id, r.resolved_contact_id;

COMMENT ON VIEW contact_reminder_summary IS
  'One row per contact that has an open or snoozed reminder. Join the Contacts '
  'list to this rather than expanding call ids per contact — contacts with '
  'nothing outstanding are simply absent.';

-- Reminders are found by state and date far more than by anything else.
CREATE INDEX IF NOT EXISTS reminders_open_due_idx
  ON reminders (organization_id, due_at) WHERE state = 'open';
-- reminders_contact_idx already exists from migration 020.

COMMIT;

-- =============================================================================
-- Verification
--
--   SET app.is_internal = 'on';
--   SET app.user_id = '<your users.id>';
--
-- 1. The Contacts list query, as one join
--
--   SELECT c.full_name, s.open_count, s.overdue_count, s.next_due_at,
--          left(s.next_note, 50) AS next_note
--   FROM contacts c
--   JOIN contact_reminder_summary s ON s.contact_id = c.id
--   WHERE c.notes = 'staging seed'
--   ORDER BY s.overdue_count DESC, s.next_due_at;
--
-- 2. Closing one records who did it, without being told
--
--   SELECT close_reminder(
--     (SELECT id FROM reminders WHERE created_by = 'staging seed'
--        AND state = 'open' ORDER BY due_at LIMIT 1),
--     'done');
--
--   SELECT u.full_name AS owner, r.state, r.closed_by_label, r.closed_at
--   FROM reminders r JOIN users u ON u.id = r.owner_user_id
--   WHERE r.created_by = 'staging seed' AND r.state = 'done';
--   -- owner may be someone else; closed_by_label is whoever closed it
--
-- 3. Snoozing without a wake time is refused
--
--   SELECT close_reminder(
--     (SELECT id FROM reminders WHERE created_by = 'staging seed'
--        AND state = 'open' LIMIT 1), 'snoozed');
--   -- expect: snoozing needs a time to wake up
--
-- 4. Reopening clears the closer
--
--   UPDATE reminders SET state = 'open'
--    WHERE created_by = 'staging seed' AND state = 'done';
--   SELECT state, closed_by_label, closed_at, completed_at
--   FROM reminders WHERE created_by = 'staging seed' AND state = 'open';
--   -- all three null
-- =============================================================================
