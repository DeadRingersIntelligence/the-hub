-- =============================================================================
-- 040_call_ingestion.sql
-- The Hub — migration 40: receiving a real call.
--
-- Every row in the database arrived by seed. A real call today rings the
-- softphone and leaves no trace. This is the path between the two.
--
-- THE SHAPE OF THE PROBLEM
--
-- A call is not one webhook. It is six to ten — incoming, ringing once per
-- user, answered, transfer, end, then recording and transcription minutes
-- later. They arrive out of order, they retry on any non-2xx, and the first one
-- arrives before the Hub has ever heard of the call.
--
-- So ingestion cannot be "insert an interaction." It has to be: find the
-- interaction this event belongs to or create it, record the event, and move
-- the interaction's own state forward if this event says something new about
-- it. Every one of those steps has to be safe to run twice, because it will be.
--
-- WHAT IS NOT HERE. Signature verification stays in the app, where the raw
-- body and the headers are. By the time SQL sees a payload it has been parsed,
-- and a signature checked after parsing is not checked. The app verifies, then
-- calls this.
--
-- CHECKED AGAINST THE LIVE SCHEMA BEFORE RUNNING; CHANGED FROM THE DRAFT
--   * contact_for_number() is not redefined. It already exists (015) with a
--     parameter named `raw`, so CREATE OR REPLACE under a new name is an error
--     that would have failed the whole migration — and the existing one is the
--     better function: it follows merged_into to the surviving contact.
--   * interaction_participants has no unique key, so the draft's
--     ON CONFLICT DO NOTHING never fired: every retried call.answered would
--     have added another handler row. The insert now checks first.
--   * The transfer count no longer reads currval() of the event sequence. On
--     a retry the event insert does nothing, and currval is then either
--     undefined (an error, so the webhook fails and retries forever) or a
--     previous call's id. The function now notes whether the event row was
--     new, and only a new transfer event counts.
--   * p_occurred_at is required. The draft fell back to now(), which makes
--     every retry a different timestamp — and the dedupe index includes the
--     timestamp, so a retried event would be stored twice.
--   * An event type the Hub doesn't know is refused by name, before the cast
--     fails with a bare enum error. The app should drop unknown types and
--     answer 2xx, or Dial Stack retries them indefinitely.
--   * telemetry_status is 'from_events', the value migration 025 added for
--     exactly this: a call whose figures come from its event trace.
--   * A late call.incoming (or call.initiated) moves the call's start earlier
--     if an event for it got here first, and answer time is recomputed from it.
--   * The old non-unique index on the same columns is dropped: the unique one
--     covers every query it served.
--   * A transfer counts from zero. transfer_count has no default, so on an
--     ingested call it starts null and `transfer_count + 1` stayed null —
--     found by the verification run, not by reading.
--   * The service role is granted EXECUTE explicitly. Staging's default
--     privileges give it new functions; production's don't, and the first
--     run there left the webhook handler unable to call this.
--   * organization_for_call() and ingest_call_event() are revoked from the
--     client roles. organization_for_call reads every firm's numbers when the
--     definer calls it; nothing in a browser has reason to.
--
-- THE DEFINER EXCEPTION. db/README.md asks every SECURITY DEFINER function for
-- a tenancy check. ingest_call_event has none on purpose: it is never callable
-- by a client role (anon and authenticated are revoked below; only the
-- service role and the owner can run it), and the "tenant" is derived from
-- the number the call arrived on, not trusted from the caller.
--
-- Requires: 001 to 039
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. One call, one interaction
--
-- external_call_ref had an index and no uniqueness, so ten events for one
-- call could make ten interactions. Partial, because seeded and shop rows
-- carry no ref. Checked before writing: no existing duplicates.
-- -----------------------------------------------------------------------------
CREATE UNIQUE INDEX interactions_external_call_ref_uq
  ON interactions (organization_id, external_call_ref)
  WHERE external_call_ref IS NOT NULL;

DROP INDEX IF EXISTS interactions_external_call_ref_idx;

-- -----------------------------------------------------------------------------
-- 2. Which firm a call belongs to
--
-- The number it arrived on, or was placed from. A call has two numbers and
-- either could be ours, so try the one the direction implies first. Nothing
-- comes back for numbers we don't hold — a webhook for someone else's number
-- is not ours to store, and guessing would put one firm's call in another's
-- feed.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION organization_for_call(
  p_from text, p_to text, p_direction text DEFAULT NULL)
RETURNS TABLE (organization_id uuid, phone_number_id uuid, account_id uuid,
               location_id uuid, matched_e164 text)
LANGUAGE plpgsql STABLE AS $$
DECLARE v_first text; v_second text;
BEGIN
  -- On an inbound call the number dialled is ours; on outbound, the caller.
  IF p_direction = 'outbound' THEN
    v_first := p_from; v_second := p_to;
  ELSE
    v_first := p_to;   v_second := p_from;
  END IF;

  RETURN QUERY
    SELECT n.organization_id, n.id, n.account_id, n.location_id, n.e164
    FROM phone_numbers n
    WHERE n.e164 = normalize_e164(v_first) AND n.active
    LIMIT 1;
  IF FOUND THEN RETURN; END IF;

  RETURN QUERY
    SELECT n.organization_id, n.id, n.account_id, n.location_id, n.e164
    FROM phone_numbers n
    WHERE n.e164 = normalize_e164(v_second) AND n.active
    LIMIT 1;
END $$;

REVOKE ALL ON FUNCTION organization_for_call(text, text, text) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 3. Ingesting one event
--
-- The whole path, in one idempotent call: the event has a dedupe index behind
-- it (025: organization, call, type, user, time), the interaction is found by
-- its call ref, and the state updates only move forward.
--
-- Returns the interaction so the app can emit a realtime notification without
-- a second query, or null for a number this platform doesn't hold.
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
    p_status, p_payload->>'transferred_to', p_payload->>'related_call',
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

COMMENT ON FUNCTION ingest_call_event IS
  'The whole inbound webhook path, idempotent. Finds or creates the interaction '
  'by carrier call id, records the event, moves the interaction forward. Safe '
  'to replay — webhooks retry. Returns the interaction, or null for a number '
  'this platform does not hold. Signature verification happens in the app, '
  'before this is called. Service role only.';

-- No client role: this is called by the webhook handler with the service key,
-- never from a browser. A signed-in user able to fabricate call events could
-- invent a call history. The service role's grant is explicit: production's
-- default privileges don't hand new functions to it, staging's do, and a
-- migration that works on one and not the other has a bug in it.
REVOKE ALL ON FUNCTION ingest_call_event(text, text, timestamptz, text, text, text, text, text, integer, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION ingest_call_event(text, text, timestamptz, text, text, text, text, text, integer, jsonb)
  TO service_role;

COMMIT;

-- =============================================================================
-- Verification. One block, run as postgres after the migration. It ends by
-- raising its own report, so the test call and its events roll back. Uses the
-- staging Dead Ringers line (+15135550100) and the one seat with a Dial Stack
-- user ref. Expect no line saying (BAD).
--
--   DO $$
--   DECLARE r text := ''; s text; n int; v_i uuid; v_x uuid; v_user text; t0 timestamptz := now();
--   BEGIN
--     SELECT external_ref INTO v_user FROM seats WHERE external_ref IS NOT NULL LIMIT 1;
--     r := r || 'seat user ref: ' || coalesce(v_user, 'NONE') || chr(10);
--
--     -- A whole call, out of order: ringing reaches us before incoming.
--     v_i := ingest_call_event('call_live_001', 'call.ringing', t0 + interval '2 s', 'inbound', '+15135559999', '+15135550100', v_user);
--     PERFORM ingest_call_event('call_live_001', 'call.incoming', t0, 'inbound', '+15135559999', '+15135550100');
--     PERFORM ingest_call_event('call_live_001', 'call.answered', t0 + interval '7 s', 'inbound', '+15135559999', '+15135550100', v_user);
--     PERFORM ingest_call_event('call_live_001', 'call.transfer', t0 + interval '40 s', 'inbound', '+15135559999', '+15135550100', v_user);
--     PERFORM ingest_call_event('call_live_001', 'call.end', t0 + interval '95 s', 'inbound', '+15135559999', '+15135550100', NULL, 'completed', 95);
--
--     SELECT format('%s %s, %s s long, answered in %s s, transfers %s, handler %s, telemetry %s, started at t0: %s',
--                   direction, disposition, duration_seconds, answer_seconds, transfer_count,
--                   coalesce((SELECT full_name FROM people WHERE id = handler_person_id), 'none'),
--                   telemetry_status, started_at = t0)
--       INTO s FROM interactions WHERE id = v_i;
--     r := r || 'call: ' || coalesce(s, 'NULL') || chr(10);
--
--     -- Replay every event: nothing should change.
--     PERFORM ingest_call_event('call_live_001', 'call.ringing', t0 + interval '2 s', 'inbound', '+15135559999', '+15135550100', v_user);
--     PERFORM ingest_call_event('call_live_001', 'call.incoming', t0, 'inbound', '+15135559999', '+15135550100');
--     PERFORM ingest_call_event('call_live_001', 'call.answered', t0 + interval '7 s', 'inbound', '+15135559999', '+15135550100', v_user);
--     PERFORM ingest_call_event('call_live_001', 'call.transfer', t0 + interval '40 s', 'inbound', '+15135559999', '+15135550100', v_user);
--     PERFORM ingest_call_event('call_live_001', 'call.end', t0 + interval '95 s', 'inbound', '+15135559999', '+15135550100', NULL, 'completed', 95);
--     SELECT count(*) INTO n FROM interactions WHERE external_call_ref = 'call_live_001';
--     r := r || 'after replay — interactions: ' || n;
--     SELECT count(*) INTO n FROM interaction_events WHERE external_call_ref = 'call_live_001';
--     r := r || ', events: ' || n;
--     SELECT count(*) INTO n FROM interaction_participants WHERE interaction_id = v_i AND role = 'handler';
--     r := r || ', handler rows: ' || n;
--     SELECT transfer_count INTO n FROM interactions WHERE id = v_i;
--     r := r || ', transfers: ' || coalesce(n::text, 'NULL') || '   (expect 1, 5, 1, 1)' || chr(10);
--
--     SELECT string_agg(step, ' → ' ORDER BY at) INTO s FROM call_flow(v_i);
--     r := r || 'call flow: ' || coalesce(s, '(none)') || chr(10);
--
--     -- A number we don't hold is ignored, not stored.
--     v_x := ingest_call_event('call_live_002', 'call.incoming', t0, 'inbound', '+12125550000', '+12125551111');
--     SELECT count(*) INTO n FROM interaction_events WHERE external_call_ref = 'call_live_002';
--     r := r || 'foreign number: returned ' || coalesce(v_x::text, 'null') || ', events stored ' || n || chr(10);
--
--     -- Bad input is refused by name.
--     BEGIN PERFORM ingest_call_event('call_live_003', 'call.bogus', t0, 'inbound', '+15135559999', '+15135550100');
--       r := r || 'unknown type: ALLOWED (BAD)' || chr(10);
--     EXCEPTION WHEN OTHERS THEN r := r || 'unknown type refused: ' || SQLERRM || chr(10); END;
--     BEGIN PERFORM ingest_call_event('call_live_003', 'call.incoming', NULL, 'inbound', '+15135559999', '+15135550100');
--       r := r || 'no timestamp: ALLOWED (BAD)' || chr(10);
--     EXCEPTION WHEN OTHERS THEN r := r || 'no timestamp refused: ' || SQLERRM || chr(10); END;
--
--     -- Who may call it.
--     r := r || 'execute — service_role: ' || has_function_privilege('service_role', 'ingest_call_event(text,text,timestamptz,text,text,text,text,text,integer,jsonb)', 'EXECUTE')
--            || ', authenticated: ' || has_function_privilege('authenticated', 'ingest_call_event(text,text,timestamptz,text,text,text,text,text,integer,jsonb)', 'EXECUTE')
--            || ', anon: ' || has_function_privilege('anon', 'ingest_call_event(text,text,timestamptz,text,text,text,text,text,integer,jsonb)', 'EXECUTE')
--            || '   (expect true, false, false)' || chr(10);
--
--     RAISE EXCEPTION 'VERIFY 040 (all rolled back) %', chr(10) || r;
--   END $$;
-- =============================================================================
