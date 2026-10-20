-- =============================================================================
-- 043_transfer_reporting.sql
-- The Hub — migration 43: what a transfer means for anything that counts calls.
--
-- 042 linked a warm transfer's two legs. Two facts about those legs were left
-- in a chat log, which is where things go to be forgotten before Reports is
-- built. This puts them where whoever reads the data will meet them.
--
-- 1. A consultation leg has no duration, by design (042). An average over
--    talk time that counts it as zero, or counts it at all, is a plausible
--    wrong number: it looks fine and nothing on screen shows why it's low.
--    Said on the column, and made the default by a view.
--
-- 2. call.end names the user who first answered, even after they transferred
--    the caller and left (production, 20 Oct 2026: the call that was handed to
--    +15138283541 at 16:39:03 ended at 16:41:28 still naming the agent).
--    The event has no to_user_id, no hangup cause, nothing naming who was on
--    the line at the end. So on a transferred call that user is stale.
--    Anything reading "who ended the call" — the call flow, evaluations,
--    reports — needs to know it. Said on the event columns; the call flow
--    shows "Call ended" with no name on a transferred call.
--
-- THIS MIGRATION
--   1. Comments on interactions.duration_seconds, interaction_events.user_ref
--      and interaction_events.person_id.
--   2. countable_calls: calls as a person would count them. Read-only.
--   3. call_flow: no name on a transferred call's end.
--
-- WHAT IT DOESN'T DO. It doesn't change what's stored: the event keeps the
-- user Dial Stack sent, since that is what Dial Stack said. handler_person_id
-- is untouched — it's set at answer, and the agent did handle the call.
--
-- Requires: 001 to 042
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Where whoever builds Reports will read it
-- -----------------------------------------------------------------------------
COMMENT ON COLUMN interactions.duration_seconds IS
  'Null on a consultation leg (consultation_of is set), which is merged rather '
  'than hung up and never sends call.end; also null on a call that has not '
  'ended. Any average or total over talk time must EXCLUDE rows where '
  'consultation_of IS NOT NULL — treating them as zero drags the average down '
  'and nothing on screen would show why. countable_calls already does.';

COMMENT ON COLUMN interaction_events.user_ref IS
  'The Dial Stack user the event names. STALE ON call.end AFTER A TRANSFER: '
  'call.end names the user who first answered even once they have handed the '
  'caller on and left, and carries nothing naming who was on the line at the '
  'end. Never read a transferred call''s call.end user as who ended it, or as '
  'who was on the call at the end.';

COMMENT ON COLUMN interaction_events.person_id IS
  'The person behind user_ref, through their seat. Inherits user_ref''s '
  'caveat: on call.end after a transfer it is the user who first answered, '
  'not whoever was on the line when the call ended.';

-- -----------------------------------------------------------------------------
-- 2. The right thing as the default
--
-- security_invoker, so interactions' RLS applies to whoever reads it, as with
-- contact_reminders (036). A plain filter over one table is auto-updatable in
-- Postgres, and the default privileges from 024 (and Supabase's for anon)
-- would grant writes on it; a reporting view takes none, so it's SELECT only.
--
-- SELECT * is expanded when the view is created: a column added to
-- interactions later won't appear here until the view is recreated. That rule
-- is in db/README.md, under the migration conventions.
-- -----------------------------------------------------------------------------
CREATE VIEW countable_calls WITH (security_invoker = true) AS
SELECT * FROM interactions
WHERE channel = 'call' AND consultation_of IS NULL;

COMMENT ON VIEW countable_calls IS
  'Calls as a person would count them: one row per caller experience, with '
  'consultation legs of warm transfers excluded. Report from this rather than '
  'from interactions directly. Includes mystery shops (source = ''shop''); '
  'filter on source where a report wants real calls only.';

REVOKE ALL ON countable_calls FROM PUBLIC, anon, authenticated;
GRANT SELECT ON countable_calls TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. A transferred call's end names nobody
--
-- As 042 left it, with the call.end detail changed.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION call_flow(p_interaction uuid)
RETURNS TABLE (at timestamptz, seconds numeric, step text, detail text)
LANGUAGE sql STABLE AS $$
  WITH ctx AS (
    SELECT i.id, i.direction, i.consultation_of,
           COALESCE(c.full_name, c.business_name, i.to_e164) AS other_party
    FROM interactions i
    LEFT JOIN contacts c ON c.id = i.contact_id
    WHERE i.id = p_interaction
  ),
  e AS (
    SELECT ev.*, MIN(ev.occurred_at) OVER () AS t0,
           ctx.direction AS dir, ctx.other_party, ctx.consultation_of,
           -- Whether this call was transferred: its call.end then names a
           -- user who had already left (see interaction_events.user_ref).
           bool_or(ev.event_type = 'call.transfer') OVER () AS transferred,
           -- Who a transfer went to, named the way Rang and Answered name
           -- people. In order:
           --   a Dial Stack user, through their seat;
           --   a number in the firm's directory (021) — staff cells, on-call
           --     lines, liaisons: the firm's own destinations;
           --   a number on one of the firm's contacts — the families and
           --     businesses it serves;
           --   otherwise the number or ref as given.
           -- Directory before contacts: a number that is both a staff member's
           -- and a contact's reads as the staff member.
           --
           -- The number lookups only run on a value that looks like a phone
           -- number. normalize_e164() strips non-digits, so a user ref would
           -- otherwise become a made-up number. A CASE, not an AND beside the
           -- lookup, because SQL doesn't promise to evaluate AND operands in
           -- order: the guard has to be structural to be a guard.
           CASE WHEN ev.event_type = 'call.transfer' AND ev.transferred_to IS NOT NULL THEN
             COALESCE(
               (SELECT p.full_name FROM seats s JOIN people p ON p.id = s.person_id
                 WHERE s.external_ref = ev.transferred_to
                   AND s.organization_id = ev.organization_id LIMIT 1),
               CASE WHEN ev.transferred_to ~ '^\+?[0-9 ().-]+$'
                    THEN (SELECT d.label FROM directory_entries d
                           WHERE d.organization_id = ev.organization_id AND d.active
                             AND d.e164 = normalize_e164(ev.transferred_to)
                           ORDER BY d.sort_order, d.label LIMIT 1)
               END,
               CASE WHEN ev.transferred_to ~ '^\+?[0-9 ().-]+$'
                    THEN (SELECT COALESCE(c.full_name, c.business_name) FROM contacts c
                           WHERE c.id = contact_for_number(ev.organization_id, ev.transferred_to))
               END,
               ev.transferred_to)
           END AS transfer_target
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
           -- The consultation leg's transfer is where it handed over and ended;
           -- the original call's is where the caller was passed on.
           WHEN event_type = 'call.transfer' AND consultation_of IS NOT NULL
                                                  THEN 'Transfer completed'
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

           -- On a transfer the useful fact is where it went, not who sent it. On
           -- the consultation, transferred_to is the caller it was joined to.
           WHEN event_type = 'call.transfer'
             THEN COALESCE(transfer_target,
                           (SELECT full_name FROM people WHERE id = e.person_id))

           -- After a transfer, call.end still names the user who first
           -- answered, though they had handed the caller on. No name is
           -- accurate; theirs isn't. Nothing in the event names who was on
           -- the line at the end. The status isn't stale, so it stays where
           -- it says something — busy, voicemail — and "completed", the
           -- common case, is left off as adding nothing.
           WHEN event_type = 'call.end' AND transferred
             THEN NULLIF(status, 'completed')

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
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- DO $$
-- DECLARE r text := ''; s text; n int; v_num text; v_org uuid; v_user text;
--         v_name text; v_t uuid; v_u uuid; t0 timestamptz := now();
-- BEGIN
--   SELECT e164, organization_id INTO v_num, v_org FROM phone_numbers
--    WHERE active AND organization_id IS NOT NULL ORDER BY e164 LIMIT 1;
--   SELECT s.external_ref, p.full_name INTO v_user, v_name
--     FROM seats s JOIN people p ON p.id = s.person_id
--    WHERE s.organization_id = v_org AND s.external_ref IS NOT NULL LIMIT 1;
--   r := r || 'seat used: ' || coalesce(v_name, 'NONE — checks below are void') || chr(10);
--
--   -- A transferred call: answered by the user, handed on, ended naming them.
--   v_t := ingest_call_event('call_043_t', 'call.incoming', t0, 'inbound', '+15135559999', v_num);
--   PERFORM ingest_call_event('call_043_t', 'call.answered', t0 + interval '3 s', 'inbound', '+15135559999', v_num, v_user);
--   PERFORM ingest_call_event('call_043_t', 'call.transfer', t0 + interval '90 s', 'inbound', '+15135559999', v_num, NULL, NULL, NULL,
--             jsonb_build_object('data', jsonb_build_object('call_id', 'call_043_t', 'transferred_to', '+15135558888')));
--   PERFORM ingest_call_event('call_043_t', 'call.end', t0 + interval '240 s', 'inbound', '+15135559999', v_num, v_user, 'completed', 237);
--   -- The same call, never transferred.
--   v_u := ingest_call_event('call_043_u', 'call.incoming', t0, 'inbound', '+15135559999', v_num);
--   PERFORM ingest_call_event('call_043_u', 'call.answered', t0 + interval '3 s', 'inbound', '+15135559999', v_num, v_user);
--   PERFORM ingest_call_event('call_043_u', 'call.end', t0 + interval '240 s', 'inbound', '+15135559999', v_num, v_user, 'completed', 237);
--
--   SELECT string_agg(step || coalesce(' · ' || detail, ''), ' → ' ORDER BY at) INTO s FROM call_flow(v_t);
--   r := r || 'transferred: ' || s || '   (expect Call ended with no name)' || chr(10);
--   SELECT string_agg(step || coalesce(' · ' || detail, ''), ' → ' ORDER BY at) INTO s FROM call_flow(v_u);
--   r := r || 'not transferred: ' || s || '   (expect Call ended · ' || coalesce(v_name, '?') || ')' || chr(10);
--
--   -- The real one.
--   SELECT string_agg(step || coalesce(' · ' || detail, ''), ' → ' ORDER BY at) INTO s
--     FROM call_flow((SELECT id FROM interactions WHERE external_call_ref LIKE '%cjz1g9'));
--   r := r || 'cjz1g9: ' || coalesce(s, 'NULL') || chr(10);
--
--   -- The view: no consultations, no texts, and every call that isn't one.
--   SELECT count(*) INTO n FROM countable_calls WHERE consultation_of IS NOT NULL OR channel <> 'call';
--   r := r || 'consultations or texts in countable_calls: ' || n || '   (expect 0)' || chr(10);
--   r := r || 'countable_calls ' || (SELECT count(*) FROM countable_calls) || ' = calls '
--          || (SELECT count(*) FROM interactions WHERE channel = 'call') || ' minus consultations '
--          || (SELECT count(*) FROM interactions WHERE consultation_of IS NOT NULL) || chr(10);
--   r := r || 'privileges — authenticated select: ' || has_table_privilege('authenticated', 'countable_calls', 'SELECT')
--          || ', authenticated insert/update/delete: '
--          || has_table_privilege('authenticated', 'countable_calls', 'INSERT,UPDATE,DELETE')
--          || ', anon select: ' || has_table_privilege('anon', 'countable_calls', 'SELECT')
--          || '   (expect true, false, false)' || chr(10);
--
--   -- The comments are there.
--   r := r || 'comments present: '
--          || (col_description('interactions'::regclass,
--                (SELECT attnum FROM pg_attribute WHERE attrelid = 'interactions'::regclass AND attname = 'duration_seconds')) LIKE '%EXCLUDE%')::text || '/'
--          || (col_description('interaction_events'::regclass,
--                (SELECT attnum FROM pg_attribute WHERE attrelid = 'interaction_events'::regclass AND attname = 'user_ref')) LIKE '%STALE%')::text || '/'
--          || (obj_description('countable_calls'::regclass, 'pg_class') IS NOT NULL)::text
--          || '   (expect true/true/true)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 043 (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
