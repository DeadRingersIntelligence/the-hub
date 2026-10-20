-- =============================================================================
-- 042_transfer_links.sql
-- The Hub — migration 42: a warm transfer, linked and named.
--
-- Reviewed by the Hub chat; the structural guards, the self-reference check
-- and the directory lookup are from that review.
--
-- WHAT WAS WRONG
--
-- ingest_call_event() (040) stored interaction_events.transferred_to and
-- related_call_ref from the webhook envelope's top level. Dial Stack puts both
-- inside `data`, so every transfer was stored with both columns null — the
-- values are in the stored payloads, and nowhere else. call_flow() already
-- shows transferred_to as a transfer's detail, which is why "Transferred"
-- reached the screen with nothing after it.
--
-- WHAT A WARM TRANSFER ACTUALLY SENDS (checked on production, 20 Oct 2026)
--
-- Two calls: the original, and a consultation the agent places to the
-- destination. When the transfer completes, both send call.transfer within
-- milliseconds, and each names the other in related_call — the link runs both
-- ways. The caller and the destination carry on over the ORIGINAL call, which
-- sends its own call.end later and holds the whole conversation's recording.
-- The consultation is merged rather than hung up, so it never sends call.end
-- (Dial Stack documents this): its recording covers only the private consult.
--
-- So a transfer group is explicit, not inferred, whenever related_call is
-- present — Dial Stack fills it "whenever the two calls can be linked".
--
-- THIS MIGRATION
--   1. ingest_call_event reads transferred_to and related_call from `data`.
--   2. interactions.consultation_of links a consultation to the call it served,
--      set on call.transfer whichever leg's event arrives first. Its ended_at
--      is the transfer time. No duration is derived: the transfer time is the
--      fact, and a derived duration would invent precision. The 006 trigger
--      that fills a duration from ended_at now skips consultations.
--   3. call_flow names a transfer's destination: a Dial Stack user through
--      their seat, a number through the firm's directory (staff and internal
--      destinations, 021), then through its contacts (the people it serves),
--      otherwise the value as given. The consultation's step reads "Transfer
--      completed". A consultation can't name itself (a check).
--   4. Backfill: both event columns from the stored payloads, then
--      consultation_of and ended_at for every transfer pair already stored.
--
-- WHAT IT DOESN'T DO. The feed still shows each leg as a row; grouping on
-- consultation_of is the app's next step. A transfer to a staff member's cell
-- names them only once the firm's directory holds that number — staff and
-- internal destinations belong in directory_entries, not on seats (a seat is
-- a licensed phone presence, not a destination) and not as contacts (contacts
-- are the families and businesses the firm serves). Filling the directory is
-- a Settings screen, plus a seed for Dead Ringers while testing.
--
-- Requires: 001 to 041
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. The link from a consultation to the call it served
-- -----------------------------------------------------------------------------
ALTER TABLE interactions
  ADD COLUMN consultation_of uuid REFERENCES interactions(id) ON DELETE SET NULL;

COMMENT ON COLUMN interactions.consultation_of IS
  'For the consultation leg of a warm transfer: the call it served — the one '
  'the caller was on, which carries on after the transfer. Null on every '
  'other call. A consultation never sends call.end; its ended_at is the '
  'transfer time and its duration is left null rather than derived.';

-- A malformed related_call naming its own call would otherwise make a row its
-- own consultation.
ALTER TABLE interactions ADD CONSTRAINT interactions_consultation_not_self
  CHECK (consultation_of IS DISTINCT FROM id);

CREATE INDEX interactions_consultation_of_idx
  ON interactions (consultation_of) WHERE consultation_of IS NOT NULL;

-- The interactions trigger from 006 fills duration_seconds from ended_at
-- whenever a call has an end and no duration. For a consultation that would
-- derive exactly the duration this migration declines to: ended_at is the
-- transfer, and the leg was never measured. Found by the verification run,
-- not by reading. As 006 left it, with consultations excluded.
CREATE OR REPLACE FUNCTION interactions_normalize() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.from_e164 := COALESCE(normalize_e164(NEW.from_e164), NEW.from_e164);
  NEW.to_e164   := COALESCE(normalize_e164(NEW.to_e164),   NEW.to_e164);
  IF NEW.ended_at IS NOT NULL AND NEW.duration_seconds IS NULL
     AND NEW.consultation_of IS NULL THEN
    NEW.duration_seconds := EXTRACT(EPOCH FROM (NEW.ended_at - NEW.occurred_at))::int;
  END IF;
  RETURN NEW;
END $$;

-- -----------------------------------------------------------------------------
-- 2. Ingestion reads the transfer fields from where Dial Stack sends them
--
-- The whole function, as 040 left it, with three changes: the two event
-- columns read from `data`, and call.transfer links the consultation. Its
-- grants (service role only) survive CREATE OR REPLACE.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ingest_call_event(
  p_call_ref      text,
  p_event_type    text,
  p_occurred_at   timestamptz,
  p_direction     text    DEFAULT NULL,
  p_from          text    DEFAULT NULL,
  p_to            text    DEFAULT NULL,
  p_user_ref      text    DEFAULT NULL,
  p_status        text    DEFAULT NULL,
  p_duration      integer DEFAULT NULL,
  p_payload       jsonb   DEFAULT '{}'::jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_org uuid; v_number uuid; v_account uuid; v_location uuid; v_matched text;
  v_interaction uuid; v_contact uuid; v_person uuid; v_dir direction;
  v_new_rows integer;
  v_related_ref text; v_related uuid; v_related_start timestamptz; v_own_start timestamptz;
BEGIN
  IF p_call_ref IS NULL OR btrim(p_call_ref) = '' THEN
    RAISE EXCEPTION 'a call event needs the carrier call id';
  END IF;
  -- The event's own time, never ours: it's part of what makes a retry a
  -- duplicate rather than a second event.
  IF p_occurred_at IS NULL THEN
    RAISE EXCEPTION 'a call event needs the time it happened';
  END IF;
  IF NOT p_event_type = ANY (enum_range(NULL::call_event_type)::text[]) THEN
    RAISE EXCEPTION 'unknown call event type %', p_event_type;
  END IF;

  v_dir := CASE WHEN p_direction = 'outbound' THEN 'outbound' ELSE 'inbound' END::direction;

  -- Have we already seen this call?
  SELECT i.id, i.organization_id INTO v_interaction, v_org
  FROM interactions i WHERE i.external_call_ref = p_call_ref LIMIT 1;

  IF v_interaction IS NULL THEN
    SELECT o.organization_id, o.phone_number_id, o.account_id, o.location_id, o.matched_e164
      INTO v_org, v_number, v_account, v_location, v_matched
    FROM organization_for_call(p_from, p_to, p_direction) o;

    -- A number we do not hold. Not an error and not ours to store.
    IF v_org IS NULL THEN RETURN NULL; END IF;

    -- Migration 015's matcher, which follows a merged contact to the survivor.
    v_contact := contact_for_number(v_org, CASE WHEN v_dir = 'inbound' THEN p_from ELSE p_to END);

    INSERT INTO interactions (
      organization_id, account_id, location_id, source, channel, direction,
      phone_number_id, from_e164, to_e164, occurred_at, started_at,
      disposition, telemetry_status, carrier, contact_id,
      handler_type, attribution_method, attribution_confidence,
      external_call_ref, last_activity_at)
    VALUES (
      v_org, v_account, v_location, 'real', 'call', v_dir,
      v_number, normalize_e164(p_from), normalize_e164(p_to),
      p_occurred_at, p_occurred_at,
      -- Nothing has happened yet. "Still ringing" is honest; "connected"
      -- would be a guess that survives if the end event never arrives.
      'no_answer', 'from_events', 'dial_stack', v_contact,
      'unknown', 'unresolved', 'none',
      p_call_ref, p_occurred_at)
    ON CONFLICT (organization_id, external_call_ref)
      WHERE external_call_ref IS NOT NULL
      DO UPDATE SET updated_at = now()
    RETURNING id INTO v_interaction;
  END IF;

  -- Who, if the event names a Dial Stack user we hold a seat for.
  IF p_user_ref IS NOT NULL THEN
    SELECT s.person_id INTO v_person
    FROM seats s WHERE s.external_ref = p_user_ref AND s.organization_id = v_org;
  END IF;

  INSERT INTO interaction_events (
    organization_id, external_call_ref, interaction_id, event_type, occurred_at,
    direction, from_number, to_number, user_ref, person_id, status,
    transferred_to, related_call_ref, payload)
  VALUES (
    v_org, p_call_ref, v_interaction, p_event_type::call_event_type, p_occurred_at,
    v_dir, normalize_e164(p_from), normalize_e164(p_to), p_user_ref, v_person,
    -- DialStack puts these inside the envelope's `data`; 040 read the envelope's
    -- top level and stored nulls. The top level is kept as a fallback only.
    p_status,
    COALESCE(p_payload->'data'->>'transferred_to', p_payload->>'transferred_to'),
    COALESCE(p_payload->'data'->>'related_call',   p_payload->>'related_call'),
    COALESCE(p_payload, '{}'::jsonb))
  ON CONFLICT DO NOTHING;      -- a retry lands here and changes nothing
  GET DIAGNOSTICS v_new_rows = ROW_COUNT;

  -- Move the interaction forward, per event. Each branch is safe to replay.
  CASE p_event_type
    WHEN 'call.incoming', 'call.initiated' THEN
      -- The call's real start. If a later event reached us first, the row was
      -- created at that event's time; pull the start back to this one.
      UPDATE interactions SET
        occurred_at = LEAST(occurred_at, p_occurred_at),
        started_at  = LEAST(started_at, p_occurred_at),
        answer_seconds = CASE WHEN connected_at IS NOT NULL
                              THEN EXTRACT(EPOCH FROM (connected_at - LEAST(started_at, p_occurred_at)))::integer
                              ELSE answer_seconds END,
        updated_at = now()
      WHERE id = v_interaction AND started_at > p_occurred_at;

    WHEN 'call.answered' THEN
      UPDATE interactions SET
        -- The media path answering is not a person answering: a greeting or a
        -- menu fires this too. connected_at is set by whoever actually takes
        -- the call, which is the leg that names a user.
        answered_at = COALESCE(answered_at, p_occurred_at),
        connected_at = CASE WHEN v_person IS NOT NULL
                            THEN COALESCE(connected_at, p_occurred_at)
                            ELSE connected_at END,
        answer_seconds = CASE WHEN v_person IS NOT NULL AND answer_seconds IS NULL
                              THEN EXTRACT(EPOCH FROM (p_occurred_at - started_at))::integer
                              ELSE answer_seconds END,
        disposition = CASE WHEN v_person IS NOT NULL THEN 'connected' ELSE disposition END,
        handler_person_id = COALESCE(handler_person_id, v_person),
        handler_type = CASE WHEN v_person IS NOT NULL THEN 'client_staff' ELSE handler_type END,
        attribution_method = CASE WHEN v_person IS NOT NULL THEN 'named_seat' ELSE attribution_method END,
        attribution_confidence = CASE WHEN v_person IS NOT NULL THEN 'certain' ELSE attribution_confidence END,
        last_activity_at = GREATEST(last_activity_at, p_occurred_at),
        updated_at = now()
      WHERE id = v_interaction;

    WHEN 'call.end' THEN
      UPDATE interactions SET
        ended_at = COALESCE(ended_at, p_occurred_at),
        duration_seconds = COALESCE(duration_seconds, p_duration,
                             EXTRACT(EPOCH FROM (p_occurred_at - started_at))::integer),
        disposition = CASE
          WHEN connected_at IS NOT NULL THEN 'connected'::disposition
          WHEN p_status IN ('voicemail')  THEN 'voicemail'::disposition
          WHEN p_status IN ('busy')       THEN 'busy'::disposition
          WHEN p_status IN ('no-answer','no_answer') THEN 'no_answer'::disposition
          ELSE disposition END,
        last_activity_at = GREATEST(last_activity_at, p_occurred_at),
        updated_at = now()
      WHERE id = v_interaction;

    WHEN 'voicemail.new' THEN
      UPDATE interactions SET disposition = 'voicemail',
             last_activity_at = GREATEST(last_activity_at, p_occurred_at),
             updated_at = now()
      WHERE id = v_interaction AND connected_at IS NULL;

    WHEN 'call.transfer' THEN
      -- Only a transfer event we hadn't stored before counts, so a retry can't
      -- inflate the number. transfer_count has no default and starts null on
      -- a new call, and null + 1 is null — so count from zero.
      IF v_new_rows > 0 THEN
        UPDATE interactions SET transfer_count = COALESCE(transfer_count, 0) + 1, updated_at = now()
        WHERE id = v_interaction;
      END IF;

      -- A warm transfer is two calls, and each leg's call.transfer names the
      -- other in related_call. The consultation is the leg placed later: the
      -- call it served already existed when it was dialled. It is merged into
      -- that call rather than hung up, so it never sends call.end; it ended
      -- at the transfer, and that is the time recorded. No duration is
      -- derived. Both directions are handled here, so it doesn't matter which
      -- leg's event arrives first, and a replay changes nothing.
      v_related_ref := COALESCE(p_payload->'data'->>'related_call', p_payload->>'related_call');
      IF v_related_ref IS NOT NULL THEN
        SELECT i.id, i.started_at INTO v_related, v_related_start
        FROM interactions i
        WHERE i.external_call_ref = v_related_ref AND i.organization_id = v_org;

        SELECT started_at INTO v_own_start FROM interactions WHERE id = v_interaction;

        IF v_related IS NOT NULL AND v_own_start IS NOT NULL AND v_related_start IS NOT NULL THEN
          IF v_own_start > v_related_start THEN
            -- This leg is the consultation.
            UPDATE interactions SET consultation_of = v_related,
                   ended_at = COALESCE(ended_at, p_occurred_at),
                   last_activity_at = GREATEST(last_activity_at, p_occurred_at),
                   updated_at = now()
            WHERE id = v_interaction AND consultation_of IS NULL;
          ELSIF v_related_start > v_own_start THEN
            -- The other leg is.
            UPDATE interactions SET consultation_of = v_interaction,
                   ended_at = COALESCE(ended_at, p_occurred_at),
                   last_activity_at = GREATEST(last_activity_at, p_occurred_at),
                   updated_at = now()
            WHERE id = v_related AND consultation_of IS NULL;
          END IF;
          -- Equal start times: no way to tell which leg is which, so neither
          -- is marked. Never seen in practice; a placed call follows the call.
        END IF;
      END IF;

    ELSE NULL;   -- ringing, recording, queue and flow events: the event row is the record
  END CASE;

  -- A participant row for whoever took it, so the contact's record shows them.
  -- interaction_participants has no unique key, so check rather than rely on
  -- ON CONFLICT, which would never fire.
  IF v_person IS NOT NULL AND p_event_type = 'call.answered' THEN
    INSERT INTO interaction_participants (organization_id, interaction_id, person_id, role)
    SELECT v_org, v_interaction, v_person, 'handler'
    WHERE NOT EXISTS (
      SELECT 1 FROM interaction_participants p
      WHERE p.interaction_id = v_interaction AND p.person_id = v_person AND p.role = 'handler');
  END IF;

  RETURN v_interaction;
END $$;

-- -----------------------------------------------------------------------------
-- 3. The call flow names where a transfer went
--
-- As 032 left it, with the transfer step's label and detail changed.
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

           ELSE COALESCE(
                  (SELECT full_name FROM people WHERE id = e.person_id),
                  CASE WHEN park_slot IS NOT NULL THEN 'slot ' || park_slot END,
                  status,
                  payload->>'detail')
         END
  FROM e ORDER BY occurred_at, id
$$;

-- -----------------------------------------------------------------------------
-- 4. Backfill what 040 stored as null
--
-- Every value comes from the payload already stored with the event; nothing is
-- fetched or guessed. Only nulls are filled, so a run twice changes nothing.
-- -----------------------------------------------------------------------------
UPDATE interaction_events
   SET transferred_to   = COALESCE(transferred_to,   payload->'data'->>'transferred_to'),
       related_call_ref = COALESCE(related_call_ref, payload->'data'->>'related_call')
 WHERE (transferred_to IS NULL   AND payload->'data'->>'transferred_to' IS NOT NULL)
    OR (related_call_ref IS NULL AND payload->'data'->>'related_call'   IS NOT NULL);

-- Then the transfer pairs already stored: the later-placed leg of each is the
-- consultation, ending at its transfer.
UPDATE interactions c
   SET consultation_of = p.id,
       ended_at = COALESCE(c.ended_at, e.occurred_at),
       updated_at = now()
  FROM interaction_events e
  JOIN interactions p
    ON p.external_call_ref = e.related_call_ref
   AND p.organization_id = e.organization_id
 WHERE e.interaction_id = c.id
   AND e.event_type = 'call.transfer'
   AND c.started_at > p.started_at
   AND c.consultation_of IS NULL;

COMMIT;

-- =============================================================================
-- Verification. One block, run as postgres after the migration; it ends by
-- raising its own report, so the test calls roll back. Uses the first active
-- firm number in the database. Expect no line saying (BAD).
--
-- It plays a warm transfer twice: once with the original call's call.transfer
-- arriving first, once with the consultation's first.
--
--   DO $$
--   DECLARE r text := ''; s text; n int; v_num text; t0 timestamptz := now();
--           v_p uuid; v_c uuid; run int; pref text; cref text;
--   BEGIN
--     SELECT e164 INTO v_num FROM phone_numbers WHERE active AND organization_id IS NOT NULL ORDER BY e164 LIMIT 1;
--     -- The destination is a staff cell in the firm's directory.
--     INSERT INTO directory_entries (organization_id, entry_kind, label, e164)
--     SELECT organization_id, 'staff', 'Wendy Ferguson (test)', '+15135558888' FROM phone_numbers WHERE e164 = v_num;
--     FOR run IN 1..2 LOOP
--       pref := 'call_xfer_p' || run; cref := 'call_xfer_c' || run;
--       -- The original: a caller on the firm's line, answered.
--       v_p := ingest_call_event(pref, 'call.incoming', t0, 'inbound', '+15135559999', v_num);
--       PERFORM ingest_call_event(pref, 'call.answered', t0 + interval '3 s', 'inbound', '+15135559999', v_num);
--       -- The consultation: the agent dials the destination.
--       v_c := ingest_call_event(cref, 'call.initiated', t0 + interval '60 s', 'outbound', v_num, '+15135558888');
--       PERFORM ingest_call_event(cref, 'call.answered', t0 + interval '65 s', 'outbound', v_num, '+15135558888');
--       -- Both legs' call.transfer, each naming the other, in either order.
--       IF run = 1 THEN
--         PERFORM ingest_call_event(pref, 'call.transfer', t0 + interval '90 s', 'inbound', '+15135559999', v_num, NULL, NULL, NULL,
--                   jsonb_build_object('data', jsonb_build_object('call_id', pref, 'related_call', cref, 'transferred_to', '+15135558888')));
--         PERFORM ingest_call_event(cref, 'call.transfer', t0 + interval '90 s', 'outbound', v_num, '+15135558888', NULL, NULL, NULL,
--                   jsonb_build_object('data', jsonb_build_object('call_id', cref, 'related_call', pref, 'transferred_to', '+15135559999')));
--       ELSE
--         PERFORM ingest_call_event(cref, 'call.transfer', t0 + interval '90 s', 'outbound', v_num, '+15135558888', NULL, NULL, NULL,
--                   jsonb_build_object('data', jsonb_build_object('call_id', cref, 'related_call', pref, 'transferred_to', '+15135559999')));
--         PERFORM ingest_call_event(pref, 'call.transfer', t0 + interval '90 s', 'inbound', '+15135559999', v_num, NULL, NULL, NULL,
--                   jsonb_build_object('data', jsonb_build_object('call_id', pref, 'related_call', cref, 'transferred_to', '+15135558888')));
--       END IF;
--       -- The original carries on and ends; the consultation sends no call.end.
--       PERFORM ingest_call_event(pref, 'call.end', t0 + interval '240 s', 'inbound', '+15135559999', v_num, NULL, 'completed', 237);
--
--       SELECT format('run %s — event columns: %s; consultation_of points at original: %s; original unmarked: %s; consultation ended at transfer: %s; consultation duration: %s; original duration: %s',
--               run,
--               (SELECT string_agg(right(external_call_ref, 2) || ' to=' || coalesce(transferred_to, 'NULL') || ' rel=' || coalesce(right(related_call_ref, 2), 'NULL'), ', ' ORDER BY external_call_ref)
--                  FROM interaction_events WHERE event_type = 'call.transfer' AND external_call_ref IN (pref, cref)),
--               (SELECT consultation_of = v_p FROM interactions WHERE id = v_c),
--               (SELECT consultation_of IS NULL FROM interactions WHERE id = v_p),
--               (SELECT ended_at = t0 + interval '90 s' FROM interactions WHERE id = v_c),
--               (SELECT coalesce(duration_seconds::text, 'NULL') FROM interactions WHERE id = v_c),
--               (SELECT coalesce(duration_seconds::text, 'NULL') FROM interactions WHERE id = v_p))
--         INTO s;
--       r := r || s || chr(10);
--
--       SELECT string_agg(step || coalesce(' · ' || detail, ''), ' → ' ORDER BY at) INTO s FROM call_flow(v_p);
--       r := r || '  original flow: ' || coalesce(s, 'NULL') || chr(10);
--       SELECT string_agg(step || coalesce(' · ' || detail, ''), ' → ' ORDER BY at) INTO s FROM call_flow(v_c);
--       r := r || '  consultation flow: ' || coalesce(s, 'NULL') || chr(10);
--
--       -- Replaying both transfers changes nothing.
--       PERFORM ingest_call_event(pref, 'call.transfer', t0 + interval '90 s', 'inbound', '+15135559999', v_num, NULL, NULL, NULL,
--                 jsonb_build_object('data', jsonb_build_object('call_id', pref, 'related_call', cref, 'transferred_to', '+15135558888')));
--       PERFORM ingest_call_event(cref, 'call.transfer', t0 + interval '90 s', 'outbound', v_num, '+15135558888', NULL, NULL, NULL,
--                 jsonb_build_object('data', jsonb_build_object('call_id', cref, 'related_call', pref, 'transferred_to', '+15135559999')));
--       SELECT count(*) INTO n FROM interaction_events WHERE external_call_ref IN (pref, cref) AND event_type = 'call.transfer';
--       r := r || '  after replay — transfer events: ' || n || ', transfer counts: '
--              || (SELECT string_agg(coalesce(transfer_count::text, 'NULL'), '/' ORDER BY external_call_ref) FROM interactions WHERE external_call_ref IN (pref, cref))
--              || '   (expect 2, 1/1)' || chr(10);
--     END LOOP;
--
--     -- A call can't be its own consultation.
--     BEGIN UPDATE interactions SET consultation_of = id WHERE id = v_p;
--       r := r || 'self-reference: ALLOWED (BAD)' || chr(10);
--     EXCEPTION WHEN check_violation THEN r := r || 'self-reference refused: ' || SQLERRM || chr(10); END;
--
--     -- A user ref that matches no seat falls through to the ref itself, never
--     -- to a made-up number's contact or directory entry.
--     PERFORM ingest_call_event('call_xfer_u', 'call.incoming', t0, 'inbound', '+15135559999', v_num);
--     PERFORM ingest_call_event('call_xfer_u', 'call.transfer', t0 + interval '30 s', 'inbound', '+15135559999', v_num, NULL, NULL, NULL,
--               jsonb_build_object('data', jsonb_build_object('call_id', 'call_xfer_u', 'transferred_to', 'user_015135558888')));
--     SELECT detail INTO s FROM call_flow((SELECT id FROM interactions WHERE external_call_ref = 'call_xfer_u')) WHERE step = 'Transferred';
--     r := r || 'unknown user ref shows as: ' || coalesce(s, 'NULL') || '   (expect user_015135558888)' || chr(10);
--
--     -- What the backfill did to the real transfers already stored.
--     SELECT coalesce(string_agg(right(c.external_call_ref, 6) || ' is the consultation of ' || right(p.external_call_ref, 6)
--                                || ', ended ' || to_char(c.ended_at AT TIME ZONE 'UTC', 'HH24:MI:SS'), '; '), 'none')
--       INTO s FROM interactions c JOIN interactions p ON p.id = c.consultation_of
--      WHERE c.external_call_ref NOT LIKE 'call_xfer_%';
--     r := r || 'real consultations after backfill: ' || s || chr(10);
--     SELECT count(*) INTO n FROM interaction_events
--      WHERE event_type = 'call.transfer' AND external_call_ref NOT LIKE 'call_xfer_%'
--        AND (transferred_to IS NULL OR related_call_ref IS NULL) AND payload->'data'->>'related_call' IS NOT NULL;
--     r := r || 'real transfer events still missing their columns: ' || n || '   (expect 0)' || chr(10);
--
--     RAISE EXCEPTION 'VERIFY 042 (all rolled back) %', chr(10) || r;
--   END $$;
-- =============================================================================
