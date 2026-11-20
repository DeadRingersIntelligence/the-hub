-- =============================================================================
-- 20261120T2100_redaction_by_position.sql
-- The Hub — a redaction names where the text is, never what it says.
--
-- APPLIED to staging (18:09 UTC) and production (18:12 UTC), 20 Nov 2026,
-- loaded whole. ran_md5 072d5079653eae36a5071fced6ff828e (13431 characters)
-- on both, as predicted. All 12 verification lines matched on both. The
-- baseline moved acl to 45741, com to 11682 and fn to 13536, each to the
-- character, and nothing else moved. This note was added afterwards.
--
-- CORRECTION FROM REVIEW AFTER THE RUN. "Dead Ringers already reads the
-- segment to find the span, so nothing sensitive travels in the call" is true
-- of the call, not of the session. Finding the span means reading the
-- transcript, and a read done in the SQL editor puts the text in its query
-- history anyway. The hole moved from the write to the read; it didn't close.
-- THE OPERATING RULE STAYS: whole-segment mode for anything that must not be
-- logged. The real fix is a redaction screen in the app, which shows the
-- segment and sends only the span. This file makes that screen possible; it
-- doesn't replace it. Recorded in db/README.md under the transcript write
-- paths.
--
-- WHAT IS WRONG. redact_transcript_segment() (20261120T2000) has two modes.
-- Whole segment sends no text. Passage mode takes p_passage, the exact string
-- to remove, so the call itself carries it: redacting a card number by
-- passage writes the card number into Supabase's query history, which is less
-- controlled than the table it's being removed from (review of 2000, after
-- the run). The README's interim rule was "redact by whole segment until an
-- offset form exists". This is the offset form.
--
-- WHAT THIS FILE DOES. It replaces the function. The new signature is
--
--   redact_transcript_segment(p_segment, p_requested_by, p_reason,
--                             p_start DEFAULT NULL, p_length DEFAULT NULL)
--
--   no position          the whole segment becomes [redacted], as before
--   p_start, p_length    that span becomes [redacted]
--
-- Dead Ringers already reads the segment to find the span, so nothing
-- sensitive travels in the call: two integers and a reason. The log row is as
-- before, with whole_segment false for a span. It records neither the
-- position nor the length, for the reason 2000 gave: a length can say what
-- was there (sixteen digits is a card).
--
-- PASSAGE MODE IS REMOVED, NOT KEPT BESIDE IT. While it exists it invites the
-- mistake the review found, and nothing calls it: hellophone has no reference
-- to the function on any branch. Changing a function's arguments means
-- DROP and CREATE, so section 1 first pins 2000's reviewed body (md5
-- 81a5dc64…). The grants are re-stated, because a new function starts with
-- the defaults. Calling the old four-argument form with a text fourth
-- argument now fails as "function not found": the call, and so the text,
-- still reaches the log. In SQL with an untyped string literal, Postgres
-- instead resolves to the new form and fails converting the string to an
-- integer (22P02), and that error message repeats the string. Either way the
-- fix is not sending it, which is why the form that invites it is gone.
--
-- POSITIONS ARE CHARACTERS, FROM 1, the way Postgres's overlay() and
-- substr() count, so an accented name doesn't shift the span. A span must lie
-- wholly inside the segment, or the call refuses and changes nothing. EACH
-- CALL REMOVES ONE SPAN, and [redacted] is ten characters, so every later
-- position moves. Redact several spans in one segment from the last one
-- backwards, or read the segment again between calls.
--
-- UNCHANGED: INVOKER, with the is_internal() guard and the Hub-user check,
-- because a redaction says who did it. The four write paths 2000 lists stay
-- four; this is the same path with a safer door.
--
-- Requires: 20261120T2000, 20261103T1200 (record_migration).
-- NOT SAFE TO RUN TWICE: section 1 refuses if the old form is gone.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Preconditions: the old form is 2000's reviewed body, and the new form
--    isn't here yet
-- -----------------------------------------------------------------------------
DO $$
DECLARE v text;
BEGIN
  IF to_regprocedure('redact_transcript_segment(uuid, text, text, integer, integer)') IS NOT NULL THEN
    RAISE EXCEPTION 'already converted; nothing to do here'
      USING HINT = 'This migration has run on this database. Not an error to fix — stop.';
  END IF;
  SELECT md5(prosrc) INTO v FROM pg_proc
   WHERE oid = to_regprocedure('redact_transcript_segment(uuid, text, text, text)');
  IF v IS DISTINCT FROM '81a5dc6418303acfa473abe3de55c657' THEN
    RAISE EXCEPTION 'redact_transcript_segment(uuid, text, text, text) is not 20261120T2000''s body (md5 %); stop and diff it',
      COALESCE(v, 'missing');
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. The passage form goes; the position form arrives
-- -----------------------------------------------------------------------------
DROP FUNCTION redact_transcript_segment(uuid, text, text, text);

CREATE FUNCTION redact_transcript_segment(p_segment uuid, p_requested_by text, p_reason text,
                                          p_start integer DEFAULT NULL, p_length integer DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE s record; v_user uuid := current_user_id();
BEGIN
  IF NOT is_internal() THEN
    RAISE EXCEPTION 'a transcript is redacted by Dead Ringers, at the firm''s request'
      USING ERRCODE = '42501',
            HINT = 'Ask Dead Ringers, saying which call, what to remove and why.';
  END IF;
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'your sign-in isn''t linked to a Hub user, so the redaction can''t say who did it';
  END IF;
  IF NULLIF(btrim(COALESCE(p_requested_by, '')), '') IS NULL
     OR NULLIF(btrim(COALESCE(p_reason, '')), '') IS NULL THEN
    RAISE EXCEPTION 'a redaction needs who asked for it and why';
  END IF;
  IF (p_start IS NULL) <> (p_length IS NULL) THEN
    RAISE EXCEPTION 'give both where the span starts and how long it is, or neither for the whole segment';
  END IF;

  SELECT id, organization_id, interaction_id, body INTO s
    FROM transcript_segments WHERE id = p_segment FOR UPDATE;
  IF s.id IS NULL THEN
    RAISE EXCEPTION 'that transcript segment couldn''t be found' USING ERRCODE = 'P0002';
  END IF;
  IF p_start IS NOT NULL
     AND (p_start < 1 OR p_length < 1 OR p_start + p_length - 1 > char_length(s.body)) THEN
    RAISE EXCEPTION 'that span isn''t inside this segment, which is % characters long; nothing was changed',
      char_length(s.body)
      USING HINT = 'Positions count characters from 1. After a redaction, later positions move: redact from the last span backwards.';
  END IF;

  UPDATE transcript_segments
     SET body = CASE WHEN p_start IS NULL THEN '[redacted]'
                     ELSE overlay(body PLACING '[redacted]' FROM p_start FOR p_length) END
   WHERE id = p_segment;

  INSERT INTO transcript_redactions
    (organization_id, interaction_id, segment_id, whole_segment, requested_by, reason, redacted_by)
  VALUES (s.organization_id, s.interaction_id, s.id, p_start IS NULL,
          btrim(p_requested_by), btrim(p_reason), v_user);
END $$;

COMMENT ON FUNCTION redact_transcript_segment(uuid, text, text, integer, integer) IS
  'Dead Ringers removes text from a transcript at the firm''s request, by '
  'position, never by content, so nothing sensitive travels in the call. With '
  'p_start and p_length (characters, from 1), that span becomes [redacted]; '
  'with neither, the whole segment does. One span per call: later positions '
  'move, so redact from the last span backwards. The row stays, and '
  'transcript_redactions records who asked, who did it, when and why, never '
  'what or how long. INVOKER: transcript_segments_write admits Dead Ringers '
  '(20261120T2000, 20261120T2100).';

REVOKE ALL ON FUNCTION redact_transcript_segment(uuid, text, text, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION redact_transcript_segment(uuid, text, text, integer, integer) TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. Record it
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261120T2100_redaction_by_position.sql',
    NULL,
    'redact_transcript_segment takes a span by position (p_start, p_length, '
    'characters from 1) instead of the passage text, so nothing sensitive '
    'travels in the call. Passage mode removed (DROP and CREATE, drift-checked '
    'against 20261120T2000). Whole-segment mode unchanged.');
END $rec$;

COMMIT;

-- =============================================================================
-- Verification — run AFTER the file, as its own statement. One block,
-- everything rolled back by the closing RAISE. Runs as authenticated with
-- app.is_internal on and a fixture Hub user, because a redaction needs a real
-- Dead Ringers session (20261120T2000).
--
-- DO $$
-- DECLARE
--   r text := ''; res text; v_org uuid; v_user uuid; v_auth uuid := gen_random_uuid(); v_call uuid;
--   s1 uuid; s2 uuid; s3 uuid;
-- BEGIN
--   r := r || '1. the forms: ' || (SELECT string_agg(oid::regprocedure::text, ', ') FROM pg_proc
--                                    WHERE proname = 'redact_transcript_segment')
--          || '   (expect only (uuid,text,text,integer,integer))' || chr(10);
--   r := r || '2. grants: ' || (SELECT string_agg(a.grantee::regrole::text || ':' || a.privilege_type, ', ' ORDER BY 1)
--                                 FROM pg_proc p, aclexplode(p.proacl) a WHERE p.proname = 'redact_transcript_segment')
--          || '   (expect authenticated:EXECUTE, postgres:EXECUTE)' || chr(10);
--
--   PERFORM set_config('app.is_internal', 'on', true);
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ verify 2100', 'funeral_home') RETURNING id INTO v_org;
--   INSERT INTO users (email, full_name, auth_user_id)
--   VALUES ('zzz-verify-2100@example.invalid', 'ZZZ Verification', v_auth) RETURNING id INTO v_user;
--   INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at)
--   VALUES (v_org, 'inbound', now(), now()) RETURNING id INTO v_call;
--   -- "José's card is 4111 1111 1111 1111": the é is one character, so the
--   -- card starts at 16 (characters) though at byte 17.
--   INSERT INTO transcript_segments (organization_id, interaction_id, segment_order, body)
--   VALUES (v_org, v_call, 1, 'José''s card is 4111 1111 1111 1111, ok') RETURNING id INTO s1;
--   INSERT INTO transcript_segments (organization_id, interaction_id, segment_order, body)
--   VALUES (v_org, v_call, 2, 'born 1950, at 12 Elm Road') RETURNING id INTO s2;
--   INSERT INTO transcript_segments (organization_id, interaction_id, segment_order, body)
--   VALUES (v_org, v_call, 3, 'all of this goes') RETURNING id INTO s3;
--   PERFORM set_config('request.jwt.claims', json_build_object('sub', v_auth::text)::text, true);
--   PERFORM set_config('role', 'authenticated', true);
--
--   PERFORM redact_transcript_segment(s1, 'José, by phone', 'card number read aloud', 16, 19);
--   r := r || '3. a span, counted in characters: "' || (SELECT body FROM transcript_segments WHERE id = s1) || '"'
--          || '   (expect "José''s card is [redacted], ok")' || chr(10);
--   -- two spans, last first: "12 Elm Road" (15, 11), then "1950" (6, 4)
--   PERFORM redact_transcript_segment(s2, 'José, by phone', 'address', 15, 11);
--   PERFORM redact_transcript_segment(s2, 'José, by phone', 'date of birth', 6, 4);
--   r := r || '4. two spans, last first: "' || (SELECT body FROM transcript_segments WHERE id = s2) || '"'
--          || '   (expect "born [redacted], at [redacted]")' || chr(10);
--   PERFORM redact_transcript_segment(s3, 'José, by phone', 'whole line');
--   r := r || '5. whole segment: "' || (SELECT body FROM transcript_segments WHERE id = s3) || '"'
--          || '   (expect "[redacted]")' || chr(10);
--
--   BEGIN PERFORM redact_transcript_segment(s3, 'x', 'y', 5, 100); res := 'ALLOWED';
--   EXCEPTION WHEN OTHERS THEN res := SQLERRM; END;
--   r := r || '6. a span past the end: ' || res || '   (expect "that span isn''t inside this segment, which is 10 characters long; nothing was changed")' || chr(10);
--   BEGIN PERFORM redact_transcript_segment(s3, 'x', 'y', 0, 3); res := 'ALLOWED';
--   EXCEPTION WHEN OTHERS THEN res := SQLERRM; END;
--   r := r || '7. a span from 0: ' || res || '   (expect the same refusal)' || chr(10);
--   BEGIN PERFORM redact_transcript_segment(s3, 'x', 'y', 3); res := 'ALLOWED';
--   EXCEPTION WHEN OTHERS THEN res := SQLERRM; END;
--   r := r || '8. a start with no length: ' || res || '   (expect "give both … or neither …")' || chr(10);
--   r := r || '9. the card number anywhere: '
--          || (SELECT count(*) FROM transcript_segments WHERE body LIKE '%4111%')
--          || '   (expect 0)' || chr(10);
--   r := r || '10. the log: ' || (SELECT count(*) FROM transcript_redactions WHERE interaction_id = v_call) || ' rows, '
--          || (SELECT count(*) FROM transcript_redactions WHERE interaction_id = v_call AND NOT whole_segment) || ' of them spans, all by the fixture user: '
--          || (SELECT bool_and(redacted_by = v_user) FROM transcript_redactions WHERE interaction_id = v_call)
--          || '   (expect 4 rows, 3 of them spans, true)' || chr(10);
--   BEGIN PERFORM redact_transcript_segment(s1, 'x', 'y', 'some text'::text); res := 'ALLOWED';
--   EXCEPTION WHEN OTHERS THEN res := SQLSTATE; END;
--   r := r || '11. the old passage form, with text: ' || res || '   (expect 42883: there is no such function now)' || chr(10);
--
--   PERFORM set_config('app.is_internal', 'off', true);
--   BEGIN PERFORM redact_transcript_segment(s1, 'x', 'y', 1, 2); res := 'ALLOWED';
--   EXCEPTION WHEN OTHERS THEN res := SQLSTATE; END;
--   r := r || '12. not Dead Ringers: ' || res || '   (expect 42501)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261120T2100_redaction_by_position (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
