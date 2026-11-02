-- =============================================================================
-- 20261102T1800_ingest_keeps_the_number.sql
-- The Hub — a number the carrier sends that we can't read is not no number.
--
-- WHAT IS WRONG. ingest_call_event() stores normalize_e164(p_from) and
-- normalize_e164(p_to) with no fallback (047). normalize_e164() returns null
-- for anything it can't read, so a call whose far end arrives in a shape the
-- pattern doesn't match is stored with from_e164 or to_e164 NULL. The call is
-- recorded; the number it was with is gone. Nothing errors.
--
-- This is the same defect 055 named and 20261102T1500 finished — "nothing was
-- given" and "something was given and can't be read" collapsed into one null —
-- on the one path nobody types into. It runs on every call.
--
-- THE SAME DISTINCTION, THE OPPOSITE RULE. 055 separated "no number was
-- given" from "a number was given and can't be read" for numbers a person
-- types, and 20261102T1500 finished that for the last form path. This is the
-- same distinction on the third path — "no caller ID" versus "caller ID we
-- couldn't read" — and it resolves the other way, which is the thing to
-- understand before applying this autumn's require_e164 pattern here.
--
-- A number someone types is a CLAIM. It can be wrong, the person is present,
-- and refusing it is how they find out — so an unreadable one is refused and
-- they fix it.
--
-- A caller number is EVIDENCE of a call that happened. Nobody is there to
-- correct it, and refusing it does not improve the number; it discards the
-- call. So it is kept, exactly as it arrived, and never refused.
--
-- require_e164 is therefore wrong here, and would be wrong in any later
-- migration that tidies this up to match the others. Raising would abort the
-- whole ingest: a call event that can't be stored is worse than a number that
-- can't be read, because the call itself disappears.
--
-- WHAT FOLLOWS FROM THAT, so nobody treats it as a defect: the resolvers that
-- match these numbers — contact_for_number, firm_only_number, resolve_number,
-- organization_for_call, organization_for_number, party_name — will sometimes
-- find no match, and that is an ORDINARY, CORRECT result. A call with a
-- caller ID nothing matches is a real call from a number the platform cannot
-- parse. It is not a lookup failure and it is not something to fix by making
-- the number fit.
--
-- THE TWO LINES TAKE DIFFERENT FIXES, which is the whole substance here.
--
--   The interactions insert passes p_from and p_to RAW. interactions has a
--   BEFORE INSERT OR UPDATE trigger, interactions_normalize_t, which already
--   writes COALESCE(normalize_e164(x), x) — so raw gives the same answer for
--   a readable number and keeps an unreadable one. Normalizing first actively
--   defeated that trigger: once ingest had turned the value into null,
--   COALESCE(normalize_e164(NULL), NULL) is null and there was nothing left
--   to preserve. The protection existed and was being cancelled one line
--   upstream.
--
--   The interaction_events insert gets an explicit COALESCE. interaction_events has no
--   normalize trigger, so that is the one place in this function where the
--   rule has to be stated.
--
--   Raw-in is already this function's pattern elsewhere: lines 30 and 36 pass
--   p_from and p_to straight into organization_for_call() and
--   contact_for_number(), both of which normalize internally. The two insert
--   lines were the exception, not the rule.
--
-- THE DEPENDENCY IS NAMED IN BOTH DIRECTIONS. The comment at the raw values
-- names interactions_normalize_t, and the verification block asserts that
-- trigger exists and fires on insert. Removing it would stop those two
-- columns being normalized at all, and should fail a test rather than quietly
-- restore this bug.
--
-- NOTHING READS THE STORED VALUES BACK. The body uses p_from and p_to
-- directly for its lookups and returns only the interaction id, so no local
-- variable or re-select depends on what the trigger wrote.
--
-- HASHES. The body was cut from 047 as committed in the-hub, between the $$
-- delimiters: 10955 characters, md5 24a8b48f45c51e3b012e963887910941, which
-- is what both databases hold. After the change, 11932 characters and
-- 9b0ed30cce0722c7636a10bf7a7a562b. The migration checks the first before
-- replacing anything and the second after, in the same transaction, so a run
-- that completes has proved that what is installed is what was reviewed.
--
-- GRANTS ARE NOT RESTATED. CREATE OR REPLACE keeps them. SECURITY DEFINER and
-- search_path are unchanged and are 040's, not this file's business.
--
-- Requires, by what it actually uses:
--   040  ingest_call_event(), interactions_normalize_t
--   047  the version of the body this replaces
--
-- Safe to run twice: the drift check tells "already applied" from "something
-- else changed it", and a second run reinstalls the same body.
--
-- APPLIED to staging and production, 2 Nov 2026, from the file hashed
-- f5b5eb82. The BEGIN … COMMIT body is unchanged since, so ingest_call_event
-- still installs as 9b0ed30c — what is below is what ran. Two comments
-- OUTSIDE it were corrected afterwards, per db/README.md: the count of calls
-- already holding a null number was unscoped, so it included 50 outbound
-- mystery-shop rows that never went through this function and never had a
-- number to lose. Scoped to the ingest path it is 0 on production and 1 on
-- staging. The paragraph it supported — calling for a backfill — was wrong in
-- the same way, and now says production has nothing to recover.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. It must be the body this was cut from
--
-- Three states, because the body this writes is not the one it expects to
-- find: a second run has to read as "already applied" rather than as drift.
-- Whole-body md5, because this replaces the whole function.
--
-- One overload only — confirmed on both databases — so the signature below is
-- the function, not one of several.
-- -----------------------------------------------------------------------------
DO $$
DECLARE v text; n int;
BEGIN
  SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname = 'public' AND p.proname = 'ingest_call_event';
  IF n <> 1 THEN
    RAISE EXCEPTION 'expected one ingest_call_event, found %; stop and look', n;
  END IF;

  SELECT md5(prosrc) INTO v FROM pg_proc
   WHERE oid = 'ingest_call_event(text, text, timestamptz, text, text, text, text, text, integer, jsonb)'::regprocedure;

  IF v IS NULL THEN
    RAISE EXCEPTION 'ingest_call_event does not exist; run 040 to 047 first';
  ELSIF v = '9b0ed30cce0722c7636a10bf7a7a562b' THEN
    RAISE NOTICE 'ingest_call_event already keeps the raw number — this migration has run before; replacing it is a no-op';
  ELSIF v <> '24a8b48f45c51e3b012e963887910941' THEN
    RAISE EXCEPTION 'ingest_call_event is neither 047''s version (%) nor this one; stop and compare before replacing it', v;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. The trigger this now depends on must be there before it is relied on
--
-- Checked here rather than assumed, because after this migration it is the
-- only thing normalizing interactions.from_e164 and to_e164.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
        SELECT 1 FROM pg_trigger t
          JOIN pg_class c ON c.oid = t.tgrelid
          JOIN pg_proc p ON p.oid = t.tgfoid
         WHERE c.relname = 'interactions'
           AND p.proname = 'interactions_normalize'
           AND NOT t.tgisinternal
           AND (t.tgtype & 4) <> 0     -- fires on INSERT
           AND (t.tgtype & 2) <> 0     -- BEFORE
      ) THEN
    RAISE EXCEPTION
      'interactions_normalize is not a BEFORE INSERT trigger on interactions; this migration hands it the normalizing, so stop';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 3. 047's body, with the two insert lines changed
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
  v_call_contact uuid;
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
      external_call_ref, last_activity_at, contact_link_method)
    VALUES (
      v_org, v_account, v_location, 'real', 'call', v_dir,
      -- RAW, on purpose. interactions_normalize_t (a BEFORE INSERT OR UPDATE
      -- trigger running interactions_normalize()) writes
      -- COALESCE(normalize_e164(x), x) into both columns, so passing the raw
      -- values gives the same result for a readable number and KEEPS an
      -- unreadable one instead of storing null. Normalizing here first
      -- defeated that: COALESCE(normalize_e164(NULL), NULL) is null, so the
      -- trigger had nothing left to preserve. IF THAT TRIGGER IS EVER
      -- REMOVED, these two columns stop being normalized at all — the
      -- verification block asserts it exists and fires for that reason.
      v_number, p_from, p_to,
      p_occurred_at, p_occurred_at,
      -- Nothing has happened yet. "Still ringing" is honest; "connected"
      -- would be a guess that survives if the end event never arrives.
      'no_answer', 'from_events', 'dial_stack', v_contact,
      'unknown', 'unresolved', 'none',
      p_call_ref, p_occurred_at,
      -- Matched by number, so derived: 047. A person choosing a contact is
      -- 'confirmed' (save_wrap_up, 048), and only 'inferred' is cleared by
      -- the directory rule (046).
      CASE WHEN v_contact IS NOT NULL THEN 'inferred'::link_method END)
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
    -- interaction_events has NO triggers at all, so the rule is stated here —
    -- the one place in this function it has to be. Not call_events: there is
    -- no such table, and the name is worth getting right in a comment whose
    -- whole job is to say which table does the normalizing and which doesn't.
    v_dir, COALESCE(normalize_e164(p_from), p_from),
           COALESCE(normalize_e164(p_to), p_to), p_user_ref, v_person,
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

      -- They called and reached someone: a reminder to follow up with them
      -- has been overtaken (047). Inbound and answered by a person only — a
      -- missed call from them is a reason to call back, not proof it
      -- happened. Only on the first time this event is stored, so a retry
      -- can't cancel a reminder set after the call was answered.
      IF v_person IS NOT NULL AND v_dir = 'inbound' AND v_new_rows > 0 THEN
        SELECT contact_id INTO v_call_contact FROM interactions WHERE id = v_interaction;
        IF v_call_contact IS NOT NULL THEN
          PERFORM cancel_reminders_on_inbound(v_call_contact, v_interaction);
        END IF;
      END IF;

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
-- 4. And it is the body that was reviewed
-- -----------------------------------------------------------------------------
DO $$
DECLARE v text;
BEGIN
  SELECT md5(prosrc) INTO v FROM pg_proc
   WHERE oid = 'ingest_call_event(text, text, timestamptz, text, text, text, text, text, integer, jsonb)'::regprocedure;

  IF v <> '9b0ed30cce0722c7636a10bf7a7a562b' THEN
    RAISE EXCEPTION
      'ingest_call_event installed as % — not the reviewed body (9b0ed30cce0722c7636a10bf7a7a562b). Nothing has been kept.', v;
  END IF;
END $$;

COMMIT;

-- =============================================================================
-- STILL TO DO, named so they aren't folded in and skipped
--
-- * CALLS ALREADY STORED WITH A NULL NUMBER ARE NOT RECOVERED. This changes
--   what happens from now on. The count has to be SCOPED TO THE INGEST PATH
--   or it answers a different question:
--
--     SELECT count(*) FROM interactions
--      WHERE channel = 'call' AND source = 'real'
--        AND external_call_ref IS NOT NULL
--        AND (from_e164 IS NULL OR to_e164 IS NULL);
--
--   Unscoped it returns 50 on production and 51 on staging, and almost all of
--   that is a different population: outbound source = 'shop' rows with no
--   external_call_ref, which never came through ingest_call_event and never
--   had a number to lose. Scoped, it is 0 on production and 1 on staging —
--   a single real inbound event, probably a test.
--
--   SO THERE IS NOTHING TO RECOVER ON PRODUCTION, and the backfill this
--   paragraph used to call for is one staging row. If it is ever needed,
--   interaction_events.payload holds the envelope DialStack sent, and the
--   decision it turns on is what to do when the payload disagrees with the
--   row.
--
-- * Whether mystery-shop calls should store numbers at all is a separate
--   question and may not be a defect: those 50 rows are created by the shop
--   workflow rather than by ingestion, and nothing here establishes what they
--   ought to hold. Noted so the count above is not read as fifty broken
--   calls by whoever runs it next.
--
-- * FOUR TABLES STILL HAVE NO is_e164 CHECK, so a kept-but-unreadable value
--   is stored and then matches nothing: leads.phone_e164,
--   routing_schedules.target_e164, users.notify_sms_e164, and
--   interactions.from_e164/to_e164 — which this migration makes more likely
--   to hold one, deliberately, because keeping it beats dropping it. A
--   constraint there would need a row scan first and a decision about what to
--   do with what it finds; for interactions in particular, refusing an
--   ingest is exactly what this file says not to do. Its own piece of work.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
-- Made-up numbers only. NPA 555 is not assignable, so these reach nobody.
--
-- DO $$
-- DECLARE
--   r text := ''; v_org uuid; v_num text; v_i uuid; v_ref text;
--   v_bad constant text := 'call 555 ext 12';
-- BEGIN
--   SELECT id INTO v_org FROM organizations WHERE code = 'DR';
--   PERFORM set_config('app.is_internal', 'on', true);
--   PERFORM set_config('app.organization_id', v_org::text, true);
--
--   r := r || 'installed body: '
--          || (SELECT md5(prosrc) FROM pg_proc
--               WHERE oid = 'ingest_call_event(text, text, timestamptz, text, text, text, text, text, integer, jsonb)'::regprocedure)
--          || '   (expect 9b0ed30cce0722c7636a10bf7a7a562b)' || chr(10);
--
--   -- The trigger this now depends on. Asserted, not assumed: after this
--   -- migration it is the only thing normalizing those two columns, so
--   -- removing it should fail here rather than quietly restore the bug.
--   r := r || 'interactions_normalize_t is BEFORE INSERT: '
--          || (EXISTS (SELECT 1 FROM pg_trigger t
--                        JOIN pg_class c ON c.oid = t.tgrelid
--                        JOIN pg_proc p ON p.oid = t.tgfoid
--                       WHERE c.relname = 'interactions'
--                         AND p.proname = 'interactions_normalize'
--                         AND NOT t.tgisinternal
--                         AND (t.tgtype & 4) <> 0 AND (t.tgtype & 2) <> 0))
--          || '   (expect true)' || chr(10);
--
--   SELECT e164 INTO v_num FROM phone_numbers
--    WHERE active AND organization_id = v_org ORDER BY e164 LIMIT 1;
--
--   IF v_num IS NULL THEN
--     r := r || 'ingest tests SKIPPED: no active number at this firm' || chr(10);
--   ELSE
--     -- The defect. Before this migration from_e164 was stored NULL and the
--     -- call kept no record of who rang.
--     BEGIN
--       v_ref := 'verify_ingest_bad_' || substr(md5(random()::text), 1, 8);
--       v_i := ingest_call_event(v_ref, 'call.incoming', now(), 'inbound', v_bad, v_num);
--       r := r || 'unreadable from — kept on the interaction: '
--              || COALESCE((SELECT from_e164 FROM interactions WHERE id = v_i), 'NULL (BAD)')
--              || chr(10)
--              || '                  kept on the call event: '
--              || COALESCE((SELECT from_number FROM interaction_events
--                            WHERE external_call_ref = v_ref ORDER BY occurred_at LIMIT 1), 'NULL (BAD)')
--              || chr(10)
--              || '   (expect the text as sent on both)' || chr(10);
--     EXCEPTION WHEN others THEN
--       r := r || 'unreadable-from test NOT RUN: ' || SQLERRM || chr(10); END;
--
--     -- And a readable one is still normalized, by the trigger rather than
--     -- by this function. This is the half that proves raw-in is equivalent
--     -- rather than merely safer.
--     BEGIN
--       v_ref := 'verify_ingest_ok_' || substr(md5(random()::text), 1, 8);
--       v_i := ingest_call_event(v_ref, 'call.incoming', now(), 'inbound',
--                                '(513) 555-0142', v_num);
--       r := r || 'readable from — normalized on the interaction: '
--              || COALESCE((SELECT from_e164 FROM interactions WHERE id = v_i), 'NULL')
--              || chr(10)
--              || '                normalized on the call event: '
--              || COALESCE((SELECT from_number FROM interaction_events
--                            WHERE external_call_ref = v_ref ORDER BY occurred_at LIMIT 1), 'NULL')
--              || chr(10)
--              || '   (expect +15135550142 on both)' || chr(10);
--     EXCEPTION WHEN others THEN
--       r := r || 'readable-from test NOT RUN: ' || SQLERRM || chr(10); END;
--   END IF;
--
--   -- How many calls already carry the damage this stops — scoped to the
--   -- ingest path, because unscoped this counts outbound shop rows that never
--   -- went through ingest_call_event and never had a number to lose. Both
--   -- numbers are printed so the difference is visible rather than implied.
--   r := r || 'ingested calls with a null number: '
--          || (SELECT count(*) FROM interactions
--               WHERE channel = 'call' AND source = 'real'
--                 AND external_call_ref IS NOT NULL
--                 AND (from_e164 IS NULL OR to_e164 IS NULL))
--          || '   (expect 0 on production, 1 on staging — not fixed here)'
--          || chr(10)
--          || '  all calls with a null number, any source: '
--          || (SELECT count(*) FROM interactions
--               WHERE channel = 'call' AND (from_e164 IS NULL OR to_e164 IS NULL))
--          || '   (the rest are shop rows — a separate question, not this '
--          || 'defect)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261102T1800_ingest_keeps_the_number (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
