-- =============================================================================
-- 032_call_flow_direction.sql
-- The Hub — migration 32: an outbound call read as if it came in.
--
-- The trace for an outbound callback read:
--
--   Call placed — Tom Avery
--   Rang        — Tom Avery
--   Answered    — Tom Avery
--
-- Tom placed the call. The ring and the answer are the other end. As worded it
-- says the call rang in to him, which is the opposite of what happened.
--
-- The cause is that the same event means different things by direction. On an
-- inbound call, `call.ringing` names the person being rung and that is who the
-- reader wants. On an outbound call, every event carries whoever placed it, and
-- what the reader wants is who is being reached.
--
-- So the wording and the name both have to turn on direction. Outbound reads
-- against the contact — "Ringing Raymond", "Raymond answered" — because on that
-- call the contact is the one doing something.
--
-- Requires: 001 to 031
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION call_flow(p_interaction uuid)
RETURNS TABLE (at timestamptz, seconds numeric, step text, detail text)
LANGUAGE sql STABLE AS $$
  WITH ctx AS (
    SELECT i.id, i.direction,
           COALESCE(c.full_name, c.business_name, i.to_e164) AS other_party
    FROM interactions i
    LEFT JOIN contacts c ON c.id = i.contact_id
    WHERE i.id = p_interaction
  ),
  e AS (
    SELECT ev.*, MIN(ev.occurred_at) OVER () AS t0,
           ctx.direction AS dir, ctx.other_party
    FROM interaction_events ev, ctx
    WHERE ev.interaction_id = p_interaction
  )
  SELECT occurred_at,
         round(EXTRACT(EPOCH FROM (occurred_at - t0))::numeric, 1),
         CASE
           -- Outbound: the ring and the answer belong to the far end.
           WHEN dir = 'outbound' AND event_type = 'call.ringing'
             THEN 'Ringing ' || COALESCE(other_party, 'the number')
           WHEN dir = 'outbound' AND event_type = 'call.answered'
             THEN COALESCE(other_party, 'The number') || ' answered'
           WHEN dir = 'outbound' AND event_type = 'call.end'
             THEN 'Call ended'

           WHEN event_type = 'call.incoming'      THEN 'Call arrived'
           WHEN event_type = 'call.initiated'     THEN 'Call placed'
           WHEN event_type = 'flow.menu_played'   THEN 'Menu played'
           WHEN event_type = 'flow.key_pressed'   THEN 'Caller pressed a key'
           WHEN event_type = 'flow.node_entered'  THEN 'Routed'
           WHEN event_type = 'queue.call.queued'  THEN 'Entered the queue'
           WHEN event_type = 'queue.call.dispatched' THEN 'Queue rang an agent'
           WHEN event_type = 'queue.call.answered'   THEN 'Answered from the queue'
           WHEN event_type = 'queue.call.abandoned'  THEN 'Caller hung up in the queue'
           WHEN event_type = 'queue.call.timed_out'  THEN 'Queue timed out'
           WHEN event_type = 'queue.call.exited'     THEN 'Caller left the queue'
           WHEN event_type = 'queue.call.callback_requested'
                                                  THEN 'Caller asked for a callback'
           WHEN event_type = 'call.ringing'       THEN 'Rang'
           WHEN event_type = 'call.mobile_push_wakeup' THEN 'Woke a mobile app'
           WHEN event_type = 'call.answered'      THEN 'Answered'
           WHEN event_type = 'call.transfer'      THEN 'Transferred'
           WHEN event_type = 'call.parked'        THEN 'Parked'
           WHEN event_type = 'call.unparked'      THEN 'Picked back up'
           WHEN event_type = 'call.emergency'     THEN 'Emergency call'
           WHEN event_type = 'call.end'           THEN 'Call ended'
           WHEN event_type = 'voicemail.new'      THEN 'Voicemail left'
           WHEN event_type = 'recording.available'              THEN 'Recording ready'
           WHEN event_type = 'recording.failed'                 THEN 'Recording failed'
           WHEN event_type = 'recording.transcription.complete' THEN 'Transcript ready'
           WHEN event_type = 'recording.summary.complete'       THEN 'Summary ready'
           WHEN event_type = 'voicemail.transcription.complete'
                                                  THEN 'Voicemail transcript ready'
           WHEN event_type = 'voicemail.summary.complete'
                                                  THEN 'Voicemail summary ready'
           ELSE replace(event_type::text, '.', ' ')
         END,
         CASE
           -- The far end is already named in the step, so repeating the person
           -- who placed the call as the detail would contradict it.
           WHEN dir = 'outbound'
                AND event_type IN ('call.ringing', 'call.answered')
             THEN NULL

           -- On a transfer the useful fact is where it went, not who sent it.
           WHEN event_type = 'call.transfer'
             THEN COALESCE(transferred_to,
                           (SELECT full_name FROM people WHERE id = e.person_id))

           ELSE COALESCE(
                  (SELECT full_name FROM people WHERE id = e.person_id),
                  CASE WHEN park_slot IS NOT NULL THEN 'slot ' || park_slot END,
                  status,
                  payload->>'detail')
         END
  FROM e ORDER BY occurred_at, id
$$;

COMMIT;

-- =============================================================================
-- Verification
--
--   SET app.is_internal = 'on';
--
--   -- outbound: reads against the person being reached
--   SELECT * FROM call_flow(
--     (SELECT id FROM interactions WHERE external_ref = 'seed_006'));
--   -- expect: Call placed — Tom Avery
--   --         Ringing Dana Novak
--   --         Dana Novak answered
--   --         Call ended — completed
--
--   -- inbound is unchanged
--   SELECT * FROM call_flow(
--     (SELECT id FROM interactions WHERE external_ref = 'seed_001'));
--   -- expect: Call arrived / Rang — Ruth Calder / Answered — Ruth Calder
--
--   -- and the transfer still names where it went
--   SELECT * FROM call_flow(
--     (SELECT id FROM interactions WHERE external_ref = 'seed_018'));
-- =============================================================================
