-- =============================================================================
-- 025_interaction_events.sql
-- The Hub — Phase 2, migration 25: the call-flow trace.
--
-- Every step a call took, in order: what answered it, which menu played, which
-- key the caller pressed, who was rung, who picked up, who it was transferred
-- to, whether it was parked. Built against Dial Stack's actual event surface
-- rather than a guess at it.
--
-- WHY THE RAW PAYLOAD IS KEPT. Dial Stack will add fields and event types; a
-- schema that only stores what today's columns cover silently discards the
-- rest. The payload is stored whole and the columns are extractions from it,
-- so a field that becomes interesting later is a backfill rather than a loss.
--
-- WHY EVENTS ARRIVE BEFORE THE INTERACTION. `call.incoming` fires as the call
-- reaches the account, before the Hub has an interaction row for it. So every
-- event carries the carrier's own call id, and `interaction_id` is filled in
-- once the call record exists. An event is never dropped for arriving early.
--
-- Requires: 001 to 024
-- =============================================================================

-- PREREQUISITE — run these lines as their OWN query first, then this file.
-- A new enum value cannot be used in the transaction that adds it.
--
--   (now executed below, before the transaction)

-- NOTE: in the Supabase SQL editor, run the ALTER TYPE line on its own first,
-- then run from BEGIN; to COMMIT;. The editor wraps a whole submission in one
-- transaction, and Postgres cannot use a new enum value in the transaction
-- that adds it.
ALTER TYPE telemetry_status ADD VALUE IF NOT EXISTS 'from_events';

BEGIN;

-- -----------------------------------------------------------------------------
-- Event types
--
-- Dial Stack's own names, kept verbatim. Translating them into house vocabulary
-- would mean maintaining a mapping and losing the ability to compare a stored
-- row against their documentation.
-- -----------------------------------------------------------------------------
CREATE TYPE call_event_type AS ENUM (
  -- Lifecycle
  'call.initiated', 'call.incoming', 'call.ringing', 'call.mobile_push_wakeup',
  'call.answered', 'call.end', 'call.transfer',
  'call.parked', 'call.unparked', 'call.emergency',
  'call.command_succeeded', 'call.command_failed',
  -- Media and AI, arriving after the call ends
  'recording.available', 'recording.failed',
  'recording.transcription.complete', 'recording.summary.complete',
  'voicemail.new', 'voicemail.transcription.complete', 'voicemail.summary.complete',
  -- Queue
  'queue.call.queued', 'queue.call.dispatched', 'queue.call.answered',
  'queue.call.abandoned', 'queue.call.timed_out', 'queue.call.exited',
  'queue.call.completed', 'queue.call.callback_requested',
  'queue.call.callback_attempted', 'queue.call.callback_failed',
  -- In-call steps not carried by a named event: menu played, key pressed,
  -- queue entered. These come from a Voice App in notify mode, which fires a
  -- webhook as the call passes through a dial-plan node without taking it over.
  'flow.menu_played', 'flow.key_pressed', 'flow.node_entered');

CREATE TABLE interaction_events (
  id                bigserial PRIMARY KEY,
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,

  -- The carrier's call id. Always present; this is what an early event is
  -- keyed on before an interaction exists.
  external_call_ref text NOT NULL,
  interaction_id    uuid REFERENCES interactions(id) ON DELETE CASCADE,

  event_type        call_event_type NOT NULL,
  occurred_at       timestamptz NOT NULL,
  received_at       timestamptz NOT NULL DEFAULT now(),

  -- Extractions. Every one of these also lives in `payload`.
  direction         text,
  from_number       text,
  from_label        text,
  to_number         text,
  user_ref          text,                    -- Dial Stack user id
  person_id         uuid REFERENCES people(id) ON DELETE SET NULL,
  status            text,
  hangup_cause      smallint,
  transferred_to    text,
  related_call_ref  text,
  park_slot         smallint,
  queue_ref         text,

  payload           jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX interaction_events_call_idx
  ON interaction_events (external_call_ref, occurred_at, id);
CREATE INDEX interaction_events_interaction_idx
  ON interaction_events (interaction_id, occurred_at, id);
CREATE INDEX interaction_events_org_type_idx
  ON interaction_events (organization_id, event_type, occurred_at DESC);
CREATE INDEX interaction_events_unmatched_idx
  ON interaction_events (organization_id, external_call_ref)
  WHERE interaction_id IS NULL;

-- Webhooks retry — three attempts with backoff — so the same event arrives
-- more than once. `call.ringing` fires once per (call, user), so the user is
-- part of what makes an event distinct.
CREATE UNIQUE INDEX interaction_events_dedupe_uq
  ON interaction_events (
    organization_id, external_call_ref, event_type,
    COALESCE(user_ref, ''), occurred_at);

-- -----------------------------------------------------------------------------
-- Attaching events to the interaction
--
-- Called once the interaction row exists. Events that arrived first are claimed
-- by it, which is why an early event is stored rather than rejected.
-- -----------------------------------------------------------------------------
ALTER TABLE interactions ADD COLUMN external_call_ref text;
CREATE INDEX interactions_external_call_ref_idx
  ON interactions (organization_id, external_call_ref)
  WHERE external_call_ref IS NOT NULL;

CREATE OR REPLACE FUNCTION attach_events_to_interaction(p_interaction uuid)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE v_org uuid; v_ref text; n integer;
BEGIN
  SELECT organization_id, external_call_ref INTO v_org, v_ref
    FROM interactions WHERE id = p_interaction;
  IF v_ref IS NULL THEN RETURN 0; END IF;

  UPDATE interaction_events
     SET interaction_id = p_interaction
   WHERE organization_id = v_org
     AND external_call_ref = v_ref
     AND interaction_id IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- -----------------------------------------------------------------------------
-- The trace
--
-- What a person reads: one line per step, in order, in plain words.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION call_flow(p_interaction uuid)
RETURNS TABLE (at timestamptz, seconds numeric, step text, detail text)
LANGUAGE sql STABLE AS $$
  WITH e AS (
    SELECT *, MIN(occurred_at) OVER () AS t0
    FROM interaction_events WHERE interaction_id = p_interaction
  )
  SELECT occurred_at,
         round(EXTRACT(EPOCH FROM (occurred_at - t0))::numeric, 1),
         CASE event_type
           WHEN 'call.incoming'      THEN 'Call arrived'
           WHEN 'call.initiated'     THEN 'Call placed'
           WHEN 'flow.menu_played'   THEN 'Menu played'
           WHEN 'flow.key_pressed'   THEN 'Caller pressed a key'
           WHEN 'flow.node_entered'  THEN 'Routed'
           WHEN 'queue.call.queued'  THEN 'Entered the queue'
           WHEN 'queue.call.dispatched' THEN 'Queue rang an agent'
           WHEN 'queue.call.abandoned'  THEN 'Caller hung up in the queue'
           WHEN 'queue.call.timed_out'  THEN 'Queue timed out'
           WHEN 'call.ringing'       THEN 'Rang'
           WHEN 'call.mobile_push_wakeup' THEN 'Woke a mobile app'
           WHEN 'call.answered'      THEN 'Answered'
           WHEN 'call.transfer'      THEN 'Transferred'
           WHEN 'call.parked'        THEN 'Parked'
           WHEN 'call.unparked'      THEN 'Picked back up'
           WHEN 'call.end'           THEN 'Call ended'
           WHEN 'voicemail.new'      THEN 'Voicemail left'
           ELSE replace(event_type::text, '_', ' ')
         END,
         COALESCE(
           (SELECT full_name FROM people WHERE id = e.person_id),
           transferred_to,
           CASE WHEN park_slot IS NOT NULL THEN 'slot ' || park_slot END,
           status,
           payload->>'detail')
  FROM e ORDER BY occurred_at, id
$$;

-- -----------------------------------------------------------------------------
-- Who was rung
--
-- `call.ringing` fires once per call per user, however the call reached them —
-- direct extension, ring group, ring-all, find-me-follow-me, dial plan, or a
-- parked-call ring-back. A user with a desk phone and a mobile app produces one
-- event, not one per device.
--
-- This partly recovers what availability polling loses. It does not say who was
-- READY at 2am, but it does say who the platform actually tried, which answers
-- most of the same question and is a fact rather than a sample.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION who_was_rung(p_interaction uuid)
RETURNS TABLE (person_id uuid, full_name text, rang_at timestamptz, answered boolean)
LANGUAGE sql STABLE AS $$
  SELECT r.person_id, p.full_name, r.occurred_at,
         EXISTS (SELECT 1 FROM interaction_events a
                 WHERE a.interaction_id = p_interaction
                   AND a.event_type = 'call.answered'
                   AND a.user_ref = r.user_ref)
  FROM interaction_events r
  LEFT JOIN people p ON p.id = r.person_id
  WHERE r.interaction_id = p_interaction AND r.event_type = 'call.ringing'
  ORDER BY r.occurred_at
$$;

-- -----------------------------------------------------------------------------
-- Seconds to answer
--
-- started_at → connected_at, NOT started_at → answered_at.
--
-- Dial Stack answers the media path to play a greeting or a menu, and that
-- counts as answered — so on any call with a greeting, answered_at is roughly
-- the same as started_at. connected_at is when the winning leg, a real device
-- or a forwarded number, actually took the call.
--
-- Scoring on answered_at would give every firm with a greeting a perfect
-- speed-to-answer.
-- -----------------------------------------------------------------------------
ALTER TABLE interactions ADD COLUMN started_at   timestamptz;
ALTER TABLE interactions ADD COLUMN answered_at  timestamptz;
ALTER TABLE interactions ADD COLUMN connected_at timestamptz;

COMMENT ON COLUMN interactions.answered_at IS
  'Signalling answer. A greeting or menu counts, so on a call that plays one '
  'this is roughly started_at. Not when a person picked up.';
COMMENT ON COLUMN interactions.connected_at IS
  'When the winning leg — a device or an external number — actually took the '
  'call. This is what speed-to-answer is measured against. Null when the call '
  'never reached anyone: abandoned while ringing, or answered by voicemail.';

CREATE OR REPLACE FUNCTION seconds_to_answer(p_interaction uuid)
RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT round(EXTRACT(EPOCH FROM (connected_at - started_at))::numeric, 1)
  FROM interactions
  WHERE id = p_interaction AND connected_at IS NOT NULL AND started_at IS NOT NULL
$$;

-- -----------------------------------------------------------------------------
-- related_call
--
-- Dial Stack links calls that belong to one conversation — a parked caller
-- picked back up is a new call, and the two name each other. The relation can
-- be many-to-one and does not always round-trip, so it is recorded as a link
-- with its own method rather than as a column pointing one way.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION link_related_calls(p_org uuid)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE n integer := 0;
BEGIN
  INSERT INTO interaction_links (organization_id, from_interaction_id,
                                 to_interaction_id, link_type, link_method)
  SELECT DISTINCT e.organization_id, a.id, b.id, 'same_conversation', 'carrier_reported'
  FROM interaction_events e
  JOIN interactions a ON a.id = e.interaction_id
  JOIN interactions b ON b.organization_id = e.organization_id
                     AND b.external_call_ref = e.related_call_ref
  WHERE e.organization_id = p_org
    AND e.related_call_ref IS NOT NULL
    AND a.id <> b.id
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- -----------------------------------------------------------------------------
-- Row-level security
-- -----------------------------------------------------------------------------
ALTER TABLE interaction_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE interaction_events FORCE ROW LEVEL SECURITY;

CREATE POLICY interaction_events_tenant ON interaction_events
  USING (is_internal() OR organization_id = current_organization_id())
  WITH CHECK (is_internal() OR organization_id = current_organization_id());

GRANT SELECT, INSERT, UPDATE, DELETE ON interaction_events TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE interaction_events_id_seq TO authenticated;

COMMIT;

-- =============================================================================
-- Verification
--
--   SET app.is_internal = 'on';
--
--   -- a small trace, as the events would arrive
--   INSERT INTO interaction_events
--     (organization_id, external_call_ref, event_type, occurred_at, from_number, to_number)
--   SELECT id, 'call_test001', 'call.incoming', '2026-09-30T14:30:00Z',
--          '+13045551234', '+13045559876'
--   FROM organizations WHERE code='ALT';
--
--   INSERT INTO interaction_events
--     (organization_id, external_call_ref, event_type, occurred_at, payload)
--   SELECT id, 'call_test001', 'flow.menu_played', '2026-09-30T14:30:02Z',
--          '{"detail":"Main menu"}'
--   FROM organizations WHERE code='ALT';
--
--   INSERT INTO interaction_events
--     (organization_id, external_call_ref, event_type, occurred_at, payload)
--   SELECT id, 'call_test001', 'flow.key_pressed', '2026-09-30T14:30:09Z',
--          '{"detail":"pressed 2"}'
--   FROM organizations WHERE code='ALT';
--
--   INSERT INTO interaction_events
--     (organization_id, external_call_ref, event_type, occurred_at, user_ref)
--   SELECT id, 'call_test001', 'call.ringing', '2026-09-30T14:30:10Z', 'user_abc'
--   FROM organizations WHERE code='ALT';
--
--   INSERT INTO interaction_events
--     (organization_id, external_call_ref, event_type, occurred_at, user_ref)
--   SELECT id, 'call_test001', 'call.answered', '2026-09-30T14:30:24Z', 'user_abc'
--   FROM organizations WHERE code='ALT';
--
--   -- the duplicate a webhook retry would send: refused
--   INSERT INTO interaction_events
--     (organization_id, external_call_ref, event_type, occurred_at, user_ref)
--   SELECT id, 'call.ringing'::text, 'call.ringing', '2026-09-30T14:30:10Z', 'user_abc'
--   FROM organizations WHERE code='ALT';
--
--   -- attach them to a real interaction, then read the trace
--   UPDATE interactions SET external_call_ref = 'call_test001'
--   WHERE id = (SELECT id FROM interactions
--               WHERE organization_id = (SELECT id FROM organizations WHERE code='ALT')
--               LIMIT 1);
--
--   SELECT attach_events_to_interaction(
--     (SELECT id FROM interactions WHERE external_call_ref='call_test001'));
--
--   SELECT * FROM call_flow(
--     (SELECT id FROM interactions WHERE external_call_ref='call_test001'));
-- =============================================================================
