-- =============================================================================
-- 020_follow_up.sql
-- The Hub — Phase 2, migration 20: consents, response policies, alerts,
-- reminders, callbacks.
--
-- This is the follow-up clock. A researcher waits days; an at-need should never
-- wait at all. The whole cluster exists to answer one question — did anyone
-- follow up, and how fast — and to make the answer actionable while the family
-- is still reachable.
--
-- The clock opens on the originating interaction and closes on ACKNOWLEDGEMENT,
-- not on the alert being sent. An alert nobody acted on has not stopped a clock.
--
-- Requires: 001 to 019
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- consents
--
-- Texting without opt-in is a compliance problem, so it has to be a field that
-- can be produced on demand rather than a checkbox somebody believes was
-- ticked. Captured at the point the caller gave it, tied to the contact.
-- -----------------------------------------------------------------------------
CREATE TYPE consent_kind AS ENUM ('sms', 'email', 'recording', 'marketing');
CREATE TYPE consent_source AS ENUM ('web_form', 'verbal_on_call', 'text_reply', 'written', 'import');

CREATE TABLE consents (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  contact_id        uuid NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,

  consent_kind      consent_kind NOT NULL,
  granted           boolean NOT NULL,
  consent_source    consent_source NOT NULL,

  -- Where it came from, so it can be produced as evidence.
  interaction_id    uuid REFERENCES interactions(id) ON DELETE SET NULL,
  captured_by       text,
  captured_at       timestamptz NOT NULL DEFAULT now(),
  revoked_at        timestamptz,
  notes             text
);
CREATE INDEX consents_contact_idx ON consents (contact_id, consent_kind, captured_at DESC);

-- Does this contact currently permit this. Latest record wins; a revocation
-- always beats a grant.
CREATE OR REPLACE FUNCTION has_consent(p_contact uuid, p_kind consent_kind)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT COALESCE((
    SELECT granted AND revoked_at IS NULL
    FROM consents
    WHERE contact_id = p_contact AND consent_kind = p_kind
    ORDER BY captured_at DESC LIMIT 1), false)
$$;

-- -----------------------------------------------------------------------------
-- response_policies
--
-- Per organization. One firm wants a nudge after 30 minutes, another after 15,
-- another after an hour. Who gets pinged at 9:14pm is a firm's decision, and
-- treating any of it as a constant means building for one client.
-- -----------------------------------------------------------------------------
CREATE TABLE response_policies (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id       uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  location_id           uuid REFERENCES locations(id) ON DELETE CASCADE,

  -- How long before the first nudge, and how often after that.
  first_nudge_minutes   smallint NOT NULL DEFAULT 30,
  repeat_minutes        smallint,
  max_nudges            smallint NOT NULL DEFAULT 3,

  -- Amber, then red. The interface pins red alerts to the top.
  amber_after_minutes   smallint NOT NULL DEFAULT 15,
  red_after_minutes     smallint NOT NULL DEFAULT 60,

  missed_call_alerts    boolean NOT NULL DEFAULT true,
  pin_open_alerts       boolean NOT NULL DEFAULT true,

  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, location_id)
);
CREATE TRIGGER response_policies_touch BEFORE UPDATE ON response_policies
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE response_policies ADD CONSTRAINT response_policies_thresholds_ck
  CHECK (red_after_minutes > amber_after_minutes);

-- -----------------------------------------------------------------------------
-- alerts
--
-- Raised by the system, cleared by a person. The handled state is deliberately
-- separate from anything about the call itself: a missed call stays missed
-- forever, but the alert about it gets resolved once somebody has acted.
--
-- Acknowledgement carries HOW. Click-to-call from the alert is the clean path;
-- an agent who dialled from their cell and marked it called is just as valid,
-- and a pile of manual acknowledgements is itself a signal worth reporting.
-- -----------------------------------------------------------------------------
CREATE TYPE alert_kind AS ENUM (
  'missed_call', 'voicemail', 'abandoned_call', 'web_form_received',
  'callback_promised', 'callback_overdue', 'behavior_flagged');

CREATE TYPE alert_state AS ENUM ('open', 'acknowledged', 'resolved', 'expired');

CREATE TYPE acknowledgement_method AS ENUM (
  'click_to_call', 'marked_called', 'inbound_from_contact', 'auto_resolved', 'dismissed');

CREATE TABLE alerts (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  location_id       uuid REFERENCES locations(id) ON DELETE SET NULL,

  alert_kind        alert_kind NOT NULL,
  interaction_id    uuid REFERENCES interactions(id) ON DELETE CASCADE,
  contact_id        uuid REFERENCES contacts(id) ON DELETE SET NULL,

  state             alert_state NOT NULL DEFAULT 'open',
  raised_at         timestamptz NOT NULL DEFAULT now(),

  -- The clock. Acknowledged closes it; resolved is the work being finished.
  acknowledged_at   timestamptz,
  acknowledged_by   uuid REFERENCES users(id) ON DELETE SET NULL,
  acknowledgement_method acknowledgement_method,

  resolved_at       timestamptz,
  resolved_by       uuid REFERENCES users(id) ON DELETE SET NULL,
  resolution_note   text,

  nudges_sent       smallint NOT NULL DEFAULT 0,
  last_nudge_at     timestamptz
);
CREATE INDEX alerts_open_idx
  ON alerts (organization_id, raised_at DESC) WHERE state = 'open';
CREATE INDEX alerts_interaction_idx ON alerts (interaction_id);

-- An acknowledged alert must say when and how.
ALTER TABLE alerts ADD CONSTRAINT alerts_ack_ck
  CHECK ( state = 'open'
       OR (acknowledged_at IS NOT NULL AND acknowledgement_method IS NOT NULL) );

-- Minutes from raised to acknowledged. Null while still open — which is the
-- point: an unanswered alert has no response time, it has an age.
CREATE OR REPLACE FUNCTION alert_response_minutes(p_alert uuid)
RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT round(EXTRACT(EPOCH FROM (acknowledged_at - raised_at)) / 60.0, 1)
  FROM alerts WHERE id = p_alert AND acknowledged_at IS NOT NULL
$$;

-- Acknowledge. Kept as a function so every path records a method.
CREATE OR REPLACE FUNCTION acknowledge_alert(
  p_alert uuid, p_user uuid, p_method acknowledgement_method)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  UPDATE alerts
     SET state = 'acknowledged', acknowledged_at = now(),
         acknowledged_by = p_user, acknowledgement_method = p_method
   WHERE id = p_alert AND state = 'open';
  IF NOT FOUND THEN RAISE EXCEPTION 'alert not found or already acknowledged'; END IF;
END $$;

-- -----------------------------------------------------------------------------
-- reminders
--
-- Owned per user, not per firm. Pat and Dana can each hold a reminder on the
-- same call, and clearing one does not clear the other.
--
-- Auto-cancel is what stops the nagging: an inbound call from that contact
-- means the follow-up already happened.
-- -----------------------------------------------------------------------------
CREATE TYPE reminder_state AS ENUM ('open', 'done', 'canceled', 'snoozed');

CREATE TABLE reminders (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,

  owner_user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  interaction_id    uuid REFERENCES interactions(id) ON DELETE CASCADE,
  contact_id        uuid REFERENCES contacts(id) ON DELETE CASCADE,
  case_id           uuid REFERENCES cases(id) ON DELETE CASCADE,

  next_step_item_id uuid REFERENCES picklist_items(id) ON DELETE SET NULL,
  note              text,

  due_at            timestamptz NOT NULL,
  state             reminder_state NOT NULL DEFAULT 'open',
  snoozed_until     timestamptz,

  -- An inbound call from this contact closes it automatically.
  cancel_on_inbound boolean NOT NULL DEFAULT true,

  completed_at      timestamptz,
  created_by        text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX reminders_owner_due_idx
  ON reminders (owner_user_id, due_at) WHERE state IN ('open','snoozed');
CREATE INDEX reminders_interaction_idx ON reminders (interaction_id);
CREATE INDEX reminders_contact_idx     ON reminders (contact_id);
CREATE TRIGGER reminders_touch BEFORE UPDATE ON reminders
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE reminders ADD CONSTRAINT reminders_target_ck
  CHECK (num_nonnulls(interaction_id, contact_id, case_id) >= 1);
ALTER TABLE reminders ADD CONSTRAINT reminders_snooze_ck
  CHECK (state <> 'snoozed' OR snoozed_until IS NOT NULL);
ALTER TABLE reminders ADD CONSTRAINT reminders_done_ck
  CHECK (state <> 'done' OR completed_at IS NOT NULL);

-- Called when an inbound interaction lands: anything still open against that
-- contact is closed, because the follow-up has happened.
CREATE OR REPLACE FUNCTION cancel_reminders_on_inbound(p_contact uuid)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
  UPDATE reminders
     SET state = 'canceled', updated_at = now()
   WHERE contact_id = p_contact
     AND cancel_on_inbound
     AND state IN ('open','snoozed');
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- -----------------------------------------------------------------------------
-- callback_requests
--
-- The caller pressed 1 and asked to be called back. Same shape as a reminder,
-- opposite trigger — one measures whether we followed up, the other whether
-- they asked us to.
-- -----------------------------------------------------------------------------
CREATE TABLE callback_requests (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  interaction_id    uuid NOT NULL REFERENCES interactions(id) ON DELETE CASCADE,
  contact_id        uuid REFERENCES contacts(id) ON DELETE SET NULL,

  requested_at      timestamptz NOT NULL DEFAULT now(),
  callback_e164     text,

  fulfilled_at      timestamptz,
  fulfilled_by      uuid REFERENCES users(id) ON DELETE SET NULL,
  fulfilling_interaction_id uuid REFERENCES interactions(id) ON DELETE SET NULL,
  abandoned         boolean NOT NULL DEFAULT false
);
CREATE INDEX callback_requests_open_idx
  ON callback_requests (organization_id, requested_at)
  WHERE fulfilled_at IS NULL AND NOT abandoned;

-- -----------------------------------------------------------------------------
-- Row-level security
-- -----------------------------------------------------------------------------
ALTER TABLE consents          ENABLE ROW LEVEL SECURITY;
ALTER TABLE response_policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE alerts            ENABLE ROW LEVEL SECURITY;
ALTER TABLE reminders         ENABLE ROW LEVEL SECURITY;
ALTER TABLE callback_requests ENABLE ROW LEVEL SECURITY;

CREATE POLICY consents_tenant ON consents
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY response_policies_tenant ON response_policies
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY alerts_tenant ON alerts
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY callback_requests_tenant ON callback_requests
  USING (is_internal() OR organization_id = current_organization_id());

-- A reminder belongs to the person who set it, and is visible to the firm it
-- was set at — a manager needs to see what is outstanding across the team.
CREATE POLICY reminders_tenant ON reminders
  USING (is_internal() OR organization_id = current_organization_id());

COMMIT;

-- =============================================================================
-- Verification
--
--   SET app.is_internal = 'on';
--
--   -- red must sit beyond amber
--   INSERT INTO response_policies (organization_id, amber_after_minutes, red_after_minutes)
--   SELECT id, 60, 15 FROM organizations WHERE code='ALT';
--
--   -- an acknowledged alert with no method is refused
--   INSERT INTO alerts (organization_id, alert_kind, state, acknowledged_at)
--   SELECT id, 'missed_call', 'acknowledged', now() FROM organizations WHERE code='ALT';
--
--   -- consent reads false until granted
--   SELECT has_consent((SELECT id FROM contacts WHERE full_name='Mary Ellis'), 'sms');
-- =============================================================================
