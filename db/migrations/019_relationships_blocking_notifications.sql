-- =============================================================================
-- 019_relationships_blocking_notifications.sql
-- The Hub — Phase 2, migration 19: four small things the interface needs.
--
-- Contact-to-contact relationships, blocked numbers, read state per user, and
-- per-user notification preferences. Independent of each other; grouped here
-- because each is a handful of columns and none warrants its own migration.
--
-- Requires: 001 to 018
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- contact_relationships
--
-- "Daughter of Jim Ellis", "Son of Jim Ellis". Distinct from the contact-to-case
-- link: two siblings are related to each other whether or not a case exists,
-- and they stay related after it closes.
--
-- Stored once, directed, with the inverse label on the same row — so writing
-- "Mary is the daughter of Jim" also answers "who is Jim to Mary" without a
-- second row that can fall out of step with the first.
-- -----------------------------------------------------------------------------
CREATE TABLE contact_relationships (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,

  from_contact_id   uuid NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
  to_contact_id     uuid NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,

  -- How the FROM contact relates to the TO contact, and the reverse.
  relationship      text NOT NULL,             -- 'daughter'
  inverse           text,                      -- 'father'

  created_by        text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (from_contact_id, to_contact_id)
);
CREATE INDEX contact_relationships_from_idx ON contact_relationships (from_contact_id);
CREATE INDEX contact_relationships_to_idx   ON contact_relationships (to_contact_id);

ALTER TABLE contact_relationships ADD CONSTRAINT contact_relationships_not_self_ck
  CHECK (from_contact_id <> to_contact_id);

-- Everyone related to a contact, in either direction, read as one list.
CREATE OR REPLACE FUNCTION related_contacts(p_contact uuid)
RETURNS TABLE (contact_id uuid, full_name text, relationship text)
LANGUAGE sql STABLE AS $$
  SELECT r.to_contact_id, c.full_name, r.relationship
  FROM contact_relationships r JOIN contacts c ON c.id = r.to_contact_id
  WHERE r.from_contact_id = p_contact
  UNION ALL
  SELECT r.from_contact_id, c.full_name, COALESCE(r.inverse, 'related to')
  FROM contact_relationships r JOIN contacts c ON c.id = r.from_contact_id
  WHERE r.to_contact_id = p_contact
$$;

-- -----------------------------------------------------------------------------
-- Blocking
--
-- Blocked at the contact, not the interaction — because a person is blocked,
-- and a contact can hold several numbers. Blocking is reversible and recorded;
-- calls still arrive and are still stored, they are simply hidden from the
-- Activity list. Discarding them outright would mean a firm could never prove
-- a number kept calling.
-- -----------------------------------------------------------------------------
ALTER TABLE contacts ADD COLUMN blocked      boolean NOT NULL DEFAULT false;
ALTER TABLE contacts ADD COLUMN is_spam      boolean NOT NULL DEFAULT false;
ALTER TABLE contacts ADD COLUMN blocked_at   timestamptz;
ALTER TABLE contacts ADD COLUMN blocked_by   text;
ALTER TABLE contacts ADD COLUMN blocked_reason text;

ALTER TABLE contacts ADD CONSTRAINT contacts_blocked_ck
  CHECK (blocked = false OR (blocked_at IS NOT NULL AND blocked_by IS NOT NULL));

CREATE INDEX contacts_blocked_idx ON contacts (organization_id) WHERE blocked;

CREATE OR REPLACE FUNCTION set_contact_blocked(
  p_contact uuid, p_blocked boolean, p_actor text,
  p_reason text DEFAULT NULL, p_spam boolean DEFAULT false)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_org uuid; v_name text;
BEGIN
  SELECT organization_id, full_name INTO v_org, v_name FROM contacts WHERE id = p_contact;
  IF NOT FOUND THEN RAISE EXCEPTION 'contact not found'; END IF;

  UPDATE contacts
     SET blocked = p_blocked,
         is_spam = CASE WHEN p_blocked THEN p_spam ELSE false END,
         blocked_at = CASE WHEN p_blocked THEN now() END,
         blocked_by = CASE WHEN p_blocked THEN p_actor END,
         blocked_reason = CASE WHEN p_blocked THEN p_reason END,
         updated_at = now()
   WHERE id = p_contact;

  PERFORM record_change(
    v_org, 'contact', p_contact,
    CASE WHEN p_blocked THEN 'blocked' ELSE 'unblocked' END::history_action,
    'system', p_actor,
    format('%s %s %s', p_actor,
           CASE WHEN p_blocked THEN 'blocked' ELSE 'unblocked' END,
           COALESCE(v_name, 'this contact')),
    NULL,
    jsonb_build_object('reason', p_reason, 'spam', p_spam));
END $$;

-- -----------------------------------------------------------------------------
-- Read state
--
-- Per user, per interaction. A text conversation Dana has read is still unread
-- for Pat, so this cannot be a flag on the interaction.
--
-- Absence means unread. Only reads are stored, which keeps the table to what
-- people have actually opened rather than a row per user per call.
-- -----------------------------------------------------------------------------
CREATE TABLE interaction_reads (
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  interaction_id    uuid NOT NULL REFERENCES interactions(id) ON DELETE CASCADE,
  user_id           uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  read_at           timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (interaction_id, user_id)
);
CREATE INDEX interaction_reads_user_idx ON interaction_reads (user_id, read_at DESC);

-- -----------------------------------------------------------------------------
-- Notification preferences
--
-- Per user, not per firm — Pat wants a text at 2am and Dana does not. The firm
-- decides which events exist and whether alerts are on at all; the person
-- decides how they hear about them.
-- -----------------------------------------------------------------------------
CREATE TYPE notification_event AS ENUM (
  'missed_call', 'voicemail', 'new_text', 'reminder_due', 'callback_promised_overdue',
  'assigned_to_you', 'mentioned_in_chat', 'alert_raised');

CREATE TYPE notification_channel AS ENUM ('desktop', 'email', 'sms');

CREATE TABLE notification_preferences (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  event             notification_event NOT NULL,
  channel           notification_channel NOT NULL,
  enabled           boolean NOT NULL DEFAULT true,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, event, channel)
);
CREATE INDEX notification_preferences_user_idx ON notification_preferences (user_id);
CREATE TRIGGER notification_preferences_touch BEFORE UPDATE
  ON notification_preferences FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- Where to reach a person outside the app. Separate from users.email, which is
-- a login identity — somebody may sign in as one address and want alerts at
-- another.
ALTER TABLE users ADD COLUMN notify_email text;
ALTER TABLE users ADD COLUMN notify_sms_e164 text;

CREATE OR REPLACE FUNCTION users_normalize_notify() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.notify_sms_e164 := COALESCE(normalize_e164(NEW.notify_sms_e164), NEW.notify_sms_e164);
  RETURN NEW;
END $$;
CREATE TRIGGER users_normalize_notify_t BEFORE INSERT OR UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION users_normalize_notify();

-- A channel with nowhere to send is a preference that silently never fires.
CREATE OR REPLACE FUNCTION notification_preferences_reachable() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_email text; v_sms text;
BEGIN
  IF NOT NEW.enabled THEN RETURN NEW; END IF;
  SELECT COALESCE(notify_email, email), notify_sms_e164 INTO v_email, v_sms
    FROM users WHERE id = NEW.user_id;
  IF NEW.channel = 'email' AND v_email IS NULL THEN
    RAISE EXCEPTION 'this user has no email address to notify'; END IF;
  IF NEW.channel = 'sms' AND v_sms IS NULL THEN
    RAISE EXCEPTION 'this user has no mobile number to notify'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER notification_preferences_reachable_ck BEFORE INSERT OR UPDATE
  ON notification_preferences FOR EACH ROW
  EXECUTE FUNCTION notification_preferences_reachable();

-- What was actually sent. "Josh says he never got the assignment alert" needs
-- an answer.
CREATE TABLE notification_log (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid REFERENCES organizations(id) ON DELETE SET NULL,
  user_id           uuid REFERENCES users(id) ON DELETE SET NULL,
  event             notification_event NOT NULL,
  channel           notification_channel NOT NULL,
  sent_to           text,
  subject_entity    history_entity,
  subject_id        uuid,
  sent_at           timestamptz NOT NULL DEFAULT now(),
  delivered         boolean,
  failure_reason    text
);
CREATE INDEX notification_log_user_idx ON notification_log (user_id, sent_at DESC);

-- -----------------------------------------------------------------------------
-- Row-level security
-- -----------------------------------------------------------------------------
ALTER TABLE contact_relationships     ENABLE ROW LEVEL SECURITY;
ALTER TABLE interaction_reads         ENABLE ROW LEVEL SECURITY;
ALTER TABLE notification_preferences  ENABLE ROW LEVEL SECURITY;
ALTER TABLE notification_log          ENABLE ROW LEVEL SECURITY;

CREATE POLICY contact_relationships_tenant ON contact_relationships
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY interaction_reads_tenant ON interaction_reads
  USING (is_internal() OR organization_id = current_organization_id());

-- A person's own preferences and their own delivery record. Nobody else's.
CREATE POLICY notification_preferences_self ON notification_preferences
  USING (is_internal() OR user_id = current_user_id());
CREATE POLICY notification_log_self ON notification_log
  USING (is_internal() OR user_id = current_user_id());

COMMIT;

-- =============================================================================
-- Verification
--
--   SET app.is_internal = 'on';
--
--   INSERT INTO contact_relationships
--     (organization_id, from_contact_id, to_contact_id, relationship, inverse)
--   SELECT c1.organization_id, c1.id, c2.id, 'daughter', 'father'
--   FROM contacts c1, contacts c2
--   WHERE c1.full_name='Mary Ellis' AND c2.full_name='Tom Ellis';
--
--   SELECT * FROM related_contacts((SELECT id FROM contacts WHERE full_name='Tom Ellis'));
--   -- expect: Mary Ellis, 'father'  (read from Tom's side)
--
--   -- blocking without an actor should be refused
--   UPDATE contacts SET blocked = true WHERE full_name = 'Mary Ellis';
-- =============================================================================
