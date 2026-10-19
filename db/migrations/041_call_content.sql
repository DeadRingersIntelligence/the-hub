-- =============================================================================
-- 041_call_content.sql
-- The Hub — migration 41: recordings and transcripts from a real call.
--
-- TWO THINGS DIAL STACK'S API DECIDES FOR US
--
-- A recording link expires in ten minutes. So nothing durable can be stored —
-- `recording_url` cannot hold a Dial Stack link, and a column holding a value
-- that is wrong within ten minutes is worse than an empty one, because it looks
-- like data. What is storable is that a recording exists and how long it runs;
-- playback fetches a fresh link per request.
--
-- `recording_url` is NOT dropped, because CTM links are durable and the shop
-- seeds use it. It is scoped by comment instead: durable links only.
--
-- A transcript comes back as one block of plain text with no speakers and no
-- timings. `transcript_segments` therefore cannot be filled from a Dial Stack
-- call, and `interactions.transcript` is the right home. The segments table
-- stays — CTM transcripts do carry speakers and timings, and that is where the
-- evaluation work reads from. One carrier can fill it and the other cannot,
-- which is fine as long as it is written down rather than discovered.
--
-- Requires: 001 to 040
-- =============================================================================

BEGIN;

ALTER TABLE interactions ADD COLUMN recording_seconds integer;

COMMENT ON COLUMN interactions.recording_seconds IS
  'How long the recording runs, and by being non-null, that one exists. No URL '
  'is stored for Dial Stack calls: their links expire in ten minutes, so '
  'playback fetches a fresh one per request.';

COMMENT ON COLUMN interactions.recording_url IS
  'DURABLE links only — CTM, and anything else that does not expire. Never a '
  'Dial Stack link: those last ten minutes, and a stale URL in this column '
  'reads as data rather than as absence. For Dial Stack, recording_seconds '
  'says a recording exists and the app fetches the link when asked.';

COMMENT ON TABLE transcript_segments IS
  'Speaker-attributed, timed transcript lines. Fillable from CTM, which returns '
  'them, and NOT from Dial Stack, whose getCallTranscript returns one block of '
  'plain text with no speakers or timings — that goes in interactions.transcript. '
  'A Dial Stack call having no segments is expected, not a gap.';

CREATE INDEX interactions_has_recording_idx
  ON interactions (organization_id, occurred_at DESC)
  WHERE recording_seconds IS NOT NULL;

-- -----------------------------------------------------------------------------
-- Writing what arrives after the call
--
-- Recording, transcript and summary arrive separately and minutes apart, each
-- on its own webhook. So every field is optional and only what is passed is
-- written — a transcript arriving later must not blank the summary that
-- arrived first.
--
-- COALESCE on the parameter, not on the column: passing nothing leaves the
-- column alone, and passing something overwrites. A re-fetch after a correction
-- should win; a replay of the same payload is a no-op either way.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION record_call_content(
  p_call_ref          text,
  p_transcript        text    DEFAULT NULL,
  p_summary           text    DEFAULT NULL,
  p_recording_seconds integer DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid;
BEGIN
  IF p_call_ref IS NULL OR btrim(p_call_ref) = '' THEN
    RAISE EXCEPTION 'a call ref is required';
  END IF;

  -- Nothing to write is not an error — a webhook can fire with an empty body
  -- when a recording failed, and that should not raise.
  IF p_transcript IS NULL AND p_summary IS NULL AND p_recording_seconds IS NULL THEN
    SELECT id INTO v_id FROM interactions WHERE external_call_ref = p_call_ref;
    RETURN v_id;
  END IF;

  UPDATE interactions SET
    transcript = CASE WHEN btrim(COALESCE(p_transcript,'')) <> ''
                      THEN p_transcript ELSE transcript END,
    summary    = CASE WHEN btrim(COALESCE(p_summary,'')) <> ''
                      THEN p_summary ELSE summary END,
    recording_seconds = COALESCE(p_recording_seconds, recording_seconds),
    updated_at = now()
  WHERE external_call_ref = p_call_ref
  RETURNING id INTO v_id;

  -- Null for a call we have never seen. The caller decides whether that means
  -- retry later or drop it — content webhooks can outrun the call events they
  -- belong to, so an unknown call is not necessarily a wrong one.
  RETURN v_id;
END $$;

COMMENT ON FUNCTION record_call_content IS
  'Writes recording length, transcript and summary onto a call found by '
  'external_call_ref. Only what is passed is written, so three webhooks '
  'arriving minutes apart do not blank each other. Returns null for an unknown '
  'call — content can arrive before the call events it belongs to.';

-- -----------------------------------------------------------------------------
-- Grants
--
-- Production does not grant new functions to the service role by default, and
-- the standing rule says the revoke is explicit. Both roles named, so neither
-- depends on a default.
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION record_call_content(text, text, text, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION record_call_content(text, text, text, integer)
  TO service_role;

-- ingest_call_event has the same shape and the same caller. Granted here too,
-- because migration 040 revoked from everyone and named no role — correct for
-- staging, where the SQL editor runs as postgres, and not enough for a handler
-- using the service key.
GRANT EXECUTE ON FUNCTION ingest_call_event(
  text, text, timestamptz, text, text, text, text, text, integer, jsonb)
  TO service_role;

COMMIT;

-- =============================================================================
-- Verification
--
--   SET app.is_internal = 'on';
--
-- 1. A call to write against
--
--   SELECT ingest_call_event('call_content_001', 'call.incoming', now(),
--            'inbound', '+15135559999', '+15134360394');
--   SELECT ingest_call_event('call_content_001', 'call.end',
--            now() + interval '90 seconds', 'inbound',
--            '+15135559999', '+15134360394', NULL, 'completed', 90);
--
-- 2. Three webhooks arriving separately, none blanking the others
--
--   SELECT record_call_content('call_content_001', NULL, NULL, 90);
--   SELECT record_call_content('call_content_001',
--            'Thank you for calling Dead Ringers, this is Mandie...', NULL, NULL);
--   SELECT record_call_content('call_content_001', NULL,
--            'Caller asked about cremation pricing. Appointment set for Thursday.', NULL);
--
--   SELECT recording_seconds, left(transcript, 40) AS transcript,
--          left(summary, 40) AS summary
--   FROM interactions WHERE external_call_ref = 'call_content_001';
--   -- all three present
--
-- 3. An empty webhook does not raise and does not blank anything
--
--   SELECT record_call_content('call_content_001');
--   SELECT recording_seconds, transcript IS NOT NULL, summary IS NOT NULL
--   FROM interactions WHERE external_call_ref = 'call_content_001';
--   -- 90, true, true
--
-- 4. An unknown call returns null rather than raising
--
--   SELECT record_call_content('call_never_seen', 'text');   -- null
--
-- 5. Tidy up
--
--   DELETE FROM interactions WHERE external_call_ref LIKE 'call_content_%';
-- =============================================================================
