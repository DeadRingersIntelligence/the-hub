-- =============================================================================
-- 030_call_flow_labels.sql
-- The Hub — migration 30: two display faults in call_flow().
--
-- ONE — a transfer named the wrong person. The function preferred the event's
-- own person, and on a transfer that is whoever initiated it, so the trace read
-- "Transferred — Ruth Calder" when what a reader needs is where the call went.
-- The destination was already stored in `transferred_to` and was being
-- overridden by the person who sent it there.
--
-- TWO — recording and transcription events fell through to the raw event name,
-- so a trace ended with `recording.available` and
-- `recording.transcription.complete` sitting under plain-English steps.
--
-- Both are display rather than data: every event was recorded correctly.
--
-- Requires: 001 to 029
-- =============================================================================

BEGIN;

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
           WHEN 'queue.call.answered'   THEN 'Answered from the queue'
           WHEN 'queue.call.abandoned'  THEN 'Caller hung up in the queue'
           WHEN 'queue.call.timed_out'  THEN 'Queue timed out'
           WHEN 'queue.call.exited'     THEN 'Caller left the queue'
           WHEN 'queue.call.callback_requested' THEN 'Caller asked for a callback'
           WHEN 'call.ringing'       THEN 'Rang'
           WHEN 'call.mobile_push_wakeup' THEN 'Woke a mobile app'
           WHEN 'call.answered'      THEN 'Answered'
           WHEN 'call.transfer'      THEN 'Transferred'
           WHEN 'call.parked'        THEN 'Parked'
           WHEN 'call.unparked'      THEN 'Picked back up'
           WHEN 'call.emergency'     THEN 'Emergency call'
           WHEN 'call.end'           THEN 'Call ended'
           WHEN 'voicemail.new'      THEN 'Voicemail left'
           -- These arrive after the call ends, and read as machine names
           -- unless they are given words.
           WHEN 'recording.available'              THEN 'Recording ready'
           WHEN 'recording.failed'                 THEN 'Recording failed'
           WHEN 'recording.transcription.complete' THEN 'Transcript ready'
           WHEN 'recording.summary.complete'       THEN 'Summary ready'
           WHEN 'voicemail.transcription.complete' THEN 'Voicemail transcript ready'
           WHEN 'voicemail.summary.complete'       THEN 'Voicemail summary ready'
           ELSE replace(event_type::text, '.', ' ')
         END,
         -- On a transfer the useful fact is where it went, not who sent it —
         -- so the destination is read first and the person only after.
         CASE WHEN event_type = 'call.transfer'
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
--   SELECT * FROM call_flow(
--     (SELECT id FROM interactions WHERE external_ref = 'seed_018'));
--
--   -- expect at 49s: Transferred — Tom Avery, not Ruth Calder
--   -- expect at the end: Recording ready, Transcript ready
--
-- Counting events, without the double-count
--
-- The obvious summary joins events and participants in one query, which
-- multiplies them: eleven events and two people reads as twenty-two. Count
-- each in its own subquery instead.
--
--   SELECT i.external_ref, i.disposition,
--          (SELECT count(*) FROM interaction_events e WHERE e.interaction_id = i.id) AS events,
--          (SELECT count(*) FROM interaction_participants ip
--            WHERE ip.interaction_id = i.id AND ip.person_id IS NOT NULL) AS people,
--          (SELECT count(*) FROM transcript_segments s WHERE s.interaction_id = i.id) AS segments
--   FROM interactions i
--   WHERE i.external_ref LIKE 'seed_%'
--   ORDER BY events DESC, i.external_ref;
-- =============================================================================
