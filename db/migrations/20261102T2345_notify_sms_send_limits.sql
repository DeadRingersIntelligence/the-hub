-- =============================================================================
-- 20261102T2345_notify_sms_send_limits.sql
-- The Hub — a confirmation code is a text message somebody pays for and a
-- stranger might receive.
--
-- WHY, three things, all in the two functions 20261102T2330 installed and
-- none of them reachable yet, which is the whole reason to do them now: the
-- moment a sender exists, all of this is live the first time anyone saves a
-- number.
--
-- 1. RESEND IS A TEXTING ORACLE. notify_sms_challenges caps GUESSES per code,
--    at five. It caps nothing about CODES. When one is used up you ask for
--    another, and every ask sends a real text to whatever number is on the
--    row. So anyone who can reach the server action — the button is not the
--    only way in — can have the Hub text a number of their choosing, over and
--    over, at Surge's price, to somebody who never asked. The limit has to be
--    in the function, because that is the only thing a caller cannot skip.
--
-- 2. RESEND ON A CONFIRMED NUMBER UNCONFIRMS IT. 20261102T2330's own STILL TO
--    DO named this: request_notify_sms_confirmation() clears
--    notify_sms_confirmed_at before issuing, so a resend pressed on an
--    already-confirmed number takes it back to unconfirmed, and if that text
--    goes unanswered the person silently stops getting texts. Which is the
--    exact failure that file exists to prevent, reintroduced by the button
--    meant to help it. Refused rather than made a no-op: a no-op returns
--    success with no code and the app says "sent" when nothing was.
--
-- 3. "wrong" FIVE TIMES WITH NO WARNING READS AS A FAULT. The person sees
--    wrong, wrong, wrong, wrong, used_up and the last one arrives from
--    nowhere. confirm_notify_sms() now returns how many tries are left.
--    Changing a function's return type is a DROP and CREATE, not a REPLACE,
--    which drops its grants and its comment — both are restated below. The
--    app has not called it yet, so this is the cheap moment and there will
--    not be another.
--
-- THE FIGURES, and why they are not symmetrical.
--
--   THREE CODES PER NUMBER PER HOUR, counted ACROSS USERS. The harm from
--   repeated texts lands on whoever holds the number, not on whoever asked,
--   so the number's limit is not scoped to the asker. Two people mistyping
--   their way onto the same stranger is rarer than one person doing it, and
--   the stranger's hour is the same either way.
--
--   TEN CODES PER USER PER DAY, across every number. A person fixing a typo
--   gets a fresh three-an-hour for each corrected number, which is the
--   legitimate case; ten a day is the ceiling on how much texting one account
--   can cause while never answering anything.
--
--   Both are in the function. A disabled button is a courtesy, not a limit.
--
-- WHY REFUSING IS SAFE HERE, given that 20261102T2330 had to stop raising for
-- exactly this reason. That function counted a failed attempt and then raised,
-- which rolled the count back. These refusals happen BEFORE anything is
-- written — nothing is counted, so nothing is lost by rolling back — and the
-- send they refuse never happened. The rule is not "never raise"; it is
-- "never raise after writing something you need to keep".
--
-- Requires, by what it actually uses:
--   20261102T2330  notify_sms_challenges, request_notify_sms_confirmation(),
--                  confirm_notify_sms(), users.notify_sms_confirmed_at
--
-- Safe to run twice: the table is added if absent, the drift checks tell
-- "already applied" from "something else changed it", and a second run
-- reinstalls the same bodies.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. What was sent, and when
--
-- notify_sms_challenges holds ONE ROW PER USER and is replaced on every
-- request, so it cannot answer "how many texts has this number had". A limit
-- needs a ledger, not a current state.
--
-- Locked down exactly as the challenge table is: RLS on, no policies, every
-- privilege revoked. It records which numbers the platform texted and when,
-- which is both the rate-limit input and the answer to "why did this stranger
-- get five messages from you".
--
-- Rows are kept rather than pruned. The longest window is a day, so the
-- rate-limit queries only ever look at a day — the rest is history, and
-- history is the half that answers the complaint. Pruning is a later
-- question, with its own decision about how long to keep it.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS notify_sms_sends (
  id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id  uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  e164     text NOT NULL,
  sent_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS notify_sms_sends_number_idx ON notify_sms_sends (e164, sent_at DESC);
CREATE INDEX IF NOT EXISTS notify_sms_sends_user_idx   ON notify_sms_sends (user_id, sent_at DESC);

ALTER TABLE notify_sms_sends ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE notify_sms_sends FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON TABLE notify_sms_sends IS
  'One row per confirmation text the platform sent: who asked, which number, '
  'when. The rate-limit ledger for request_notify_sms_confirmation(), which '
  'notify_sms_challenges cannot be because it keeps one row per user and '
  'replaces it on every request. Also the answer to "why did this number get '
  'five messages". KEPT FOR THIRTY DAYS, decided 2 Nov 2026 — these are '
  'strangers'' mistyped numbers, so keeping them for ever is not a neutral '
  'default; request_notify_sms_confirmation() prunes on each call, since '
  'nothing here runs on a schedule. RLS on, no policies, all privileges '
  'revoked — only the definer function writes it. Do not add a policy or a '
  'grant.';

COMMENT ON COLUMN notify_sms_sends.e164 IS
  'The number as it stood when the text was sent. Not a foreign key to the '
  'user''s current number: the limit protects whoever held THIS number at the '
  'time, and the user may have changed theirs since.';

-- -----------------------------------------------------------------------------
-- 2. Asking for a code: refuse before sending
--
-- EVERY REFUSAL CARRIES ITS OWN SQLSTATE, AND THE CODE IS THE CONTRACT — not
-- the sentence. The app matches PostgrestError.code; the wording is then free
-- to change without a migration, which is what these sentences have already
-- cost three rounds of agreeing. The same mistake is live in settings.ts,
-- where friendly() matches database messages by regex.
--
--   NS001  no mobile number to confirm
--   NS002  that number is already confirmed
--   NS003  the hourly per-number limit
--   NS004  the daily per-user limit
--
-- NS for "notify SMS". Five alphanumerics, and the class letters are not
-- free: Postgres reserves A-H for the SQL standard and already uses HV for
-- foreign-data-wrapper errors, so a self-defined class starts with 5-9 or
-- I-Z. An earlier draft used HS, which is inside the standard's range.
-- Nothing beginning PT either, because PostgREST reads PTxyz as an HTTP
-- status, and nothing ending 000, which is the class code itself and matches
-- as a whole class. An unrecognised code comes back as 400 with the code in
-- the body, which is what the app reads.
-- -----------------------------------------------------------------------------
DO $$
DECLARE v text;
BEGIN
  SELECT md5(prosrc) INTO v FROM pg_proc
   WHERE oid = 'request_notify_sms_confirmation(uuid)'::regprocedure;

  IF v IS NULL THEN
    RAISE EXCEPTION 'request_notify_sms_confirmation does not exist; run 20261102T2330 first';
  ELSIF v = '4182e7294014e2dc91938700d747121a' THEN
    RAISE NOTICE 'request_notify_sms_confirmation already enforces its limits — this migration has run before';
  ELSIF v <> '30cd24d29453da0170ec7356ded8e10c' THEN
    RAISE EXCEPTION 'request_notify_sms_confirmation is neither 20261102T2330''s version (%) nor this one; stop and compare before replacing it', v;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION request_notify_sms_confirmation(p_user uuid)
RETURNS TABLE (e164 text, code text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_e164 text; v_code text; v_confirmed timestamptz; v_n int;
BEGIN
  SELECT notify_sms_e164, notify_sms_confirmed_at
    INTO v_e164, v_confirmed
    FROM users WHERE id = p_user;

  IF v_e164 IS NULL THEN
    RAISE EXCEPTION 'that person has no mobile number to confirm'
      USING ERRCODE = 'NS001';
  END IF;

  -- Already confirmed: sending again would unconfirm it, and an unanswered
  -- text would then leave them silently unreachable.
  IF v_confirmed IS NOT NULL THEN
    RAISE EXCEPTION 'that number is already confirmed'
      USING ERRCODE = 'NS002',
            HINT = 'Change the number if it is wrong — that unconfirms it and a new code can be sent.';
  END IF;

  -- Serialize on the number before counting. Without this the count and the
  -- insert are not atomic, so two requests in flight — a double-clicked
  -- resend, which is the ordinary way this happens — can each see two and
  -- both send, putting four texts in the hour the limit exists to cap.
  PERFORM pg_advisory_xact_lock(hashtext(v_e164));

  -- Thirty days of history, decided 2 Nov. These are strangers' mistyped
  -- numbers; keeping them for ever is not a neutral default. Pruned here
  -- because nothing in this database runs on a schedule, and it costs
  -- nothing: the limits below only look back a day, so this never changes
  -- what they count.
  DELETE FROM notify_sms_sends s WHERE s.sent_at < now() - interval '30 days';

  -- Three per number per hour, across users: the harm lands on whoever holds
  -- the number, so the limit is not scoped to who asked.
  --
  -- EVERY COLUMN IS QUALIFIED, and must stay that way. This function
  -- RETURNS TABLE (e164 text, code text), which declares OUT variables of
  -- those names — so an unqualified e164 here is ambiguous, and the function
  -- INSTALLS CLEANLY AND FAILS ON ITS FIRST CALL with 42702. A migration that
  -- reported success would have shipped a function that never worked.
  SELECT count(*) INTO v_n FROM notify_sms_sends s
   WHERE s.e164 = v_e164 AND s.sent_at > now() - interval '1 hour';
  IF v_n >= 3 THEN
    -- SAYS WHEN, AND SAYS NOTHING ABOUT THE NUMBER. "try again later" invites
    -- the immediate retry this exists to stop, and the window is a fixed
    -- hour, so it can be named.
    --
    -- Naming the NUMBER would tell whoever typed a colleague's mobile — by
    -- mistake or not — that somebody else has been asking for codes for it.
    -- One sentence every time, whoever tripped it: a message that changes
    -- depending on who caused it makes the change itself the signal, and a
    -- generic wording that appears only sometimes says as much as the
    -- specific one would.
    RAISE EXCEPTION 'too many codes have been sent recently; try again in an hour'
      USING ERRCODE = 'NS003',
            HINT = 'Three an hour. If the texts are not arriving, check the number rather than resending.';
  END IF;

  -- Ten per user per day, across every number they have tried.
  SELECT count(*) INTO v_n FROM notify_sms_sends s
   WHERE s.user_id = p_user AND s.sent_at > now() - interval '1 day';
  IF v_n >= 10 THEN
    RAISE EXCEPTION 'too many codes requested today; try again tomorrow'
      USING ERRCODE = 'NS004';
  END IF;

  v_code := lpad(((('x' || encode(extensions.gen_random_bytes(3), 'hex'))::bit(24)::int)
                  % 1000000)::text, 6, '0');

  INSERT INTO notify_sms_challenges (user_id, code, sent_at, attempts)
  VALUES (p_user, v_code, now(), 0)
  ON CONFLICT (user_id) DO UPDATE
    SET code = EXCLUDED.code, sent_at = EXCLUDED.sent_at, attempts = 0;

  INSERT INTO notify_sms_sends (user_id, e164) VALUES (p_user, v_e164);

  RETURN QUERY SELECT v_e164, v_code;
END $$;

COMMENT ON FUNCTION request_notify_sms_confirmation(uuid) IS
  'Sets a new confirmation code and hands it back with the number, for a '
  'server-side sender to text through Surge. SECURITY DEFINER, service_role '
  'only: anyone who can read the code can confirm a number they do not hold. '
  'REFUSES rather than sends when the number is already confirmed (resending '
  'would unconfirm it), when that number has had three codes in an hour '
  '(counted across users — the harm is to whoever holds it), or when this '
  'person has asked for ten in a day. EVERY REFUSAL CARRIES ITS OWN SQLSTATE '
  '— NS001 no number, NS002 already confirmed, NS003 the hourly per-number '
  'limit, NS004 the daily per-user limit — and THE CODE IS THE CONTRACT, not '
  'the sentence: the wording is free to change without a migration. The '
  'hourly refusal names neither the '
  'number nor who caused it, and reads the same whoever did: wording that '
  'varied with the cause would itself say that somebody else had been asking '
  'about that number. Every refusal happens before anything '
  'is written, so nothing is lost by it. Takes an advisory lock on the number '
  'first, so two requests in flight cannot each pass the count. Each send is '
  'recorded in notify_sms_sends, and sends older than thirty days are pruned '
  'here, because nothing in this database runs on a schedule. EVERY COLUMN IN '
  'THIS BODY IS QUALIFIED: it RETURNS TABLE (e164, code), so those names are '
  'OUT variables and an unqualified one is ambiguous at call time, not at '
  'install time.';

REVOKE ALL ON FUNCTION request_notify_sms_confirmation(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION request_notify_sms_confirmation(uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 3. Answering it: say how many tries are left
--
-- A DROP and CREATE, because the return type changes and CREATE OR REPLACE
-- cannot do that. DROP takes the grants and the comment with it, so both are
-- restated below — that is the whole hazard of this section, and the reason
-- it is not a one-line change.
--
-- attempts_left is the number of guesses remaining against the code that is
-- still pending: a figure for 'wrong' and 'used_up', and NULL for the three
-- statuses where no code is pending afterwards. Null rather than zero,
-- because "no tries left" and "nothing to try against" are different things
-- and the app shows different sentences for them.
-- -----------------------------------------------------------------------------
DO $$
DECLARE v text;
BEGIN
  SELECT md5(prosrc) INTO v FROM pg_proc
   WHERE oid = 'confirm_notify_sms(text)'::regprocedure;

  IF v IS NULL THEN
    RAISE EXCEPTION 'confirm_notify_sms does not exist; run 20261102T2330 first';
  ELSIF v = 'a93171849eb8453d0b723065ad1d977d' THEN
    RAISE NOTICE 'confirm_notify_sms already returns attempts_left — this migration has run before';
  ELSIF v <> 'adbf3dd92f244c960bb5f6f40a805b85' THEN
    RAISE EXCEPTION 'confirm_notify_sms is neither 20261102T2330''s version (%) nor this one; stop and compare before replacing it', v;
  END IF;
END $$;

DROP FUNCTION IF EXISTS confirm_notify_sms(text);

CREATE FUNCTION confirm_notify_sms(p_code text)
RETURNS TABLE (status text, attempts_left integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_me uuid; v_code text; v_sent timestamptz; v_tries smallint;
BEGIN
  v_me := current_user_id();
  IF v_me IS NULL THEN
    -- The one raise here, coded like the refusals in section 2 so the app
    -- never has to remember which function is the exception.
    RAISE EXCEPTION 'you''re not signed in to the Hub yet'
      USING ERRCODE = 'NS005';
  END IF;

  SELECT c.code, c.sent_at, c.attempts INTO v_code, v_sent, v_tries
    FROM notify_sms_challenges c WHERE c.user_id = v_me FOR UPDATE;

  IF NOT FOUND THEN
    RETURN QUERY SELECT 'none'::text, NULL::integer; RETURN;
  END IF;

  IF v_sent < now() - interval '15 minutes' THEN
    DELETE FROM notify_sms_challenges WHERE user_id = v_me;
    RETURN QUERY SELECT 'expired'::text, NULL::integer; RETURN;
  END IF;

  IF btrim(COALESCE(p_code, '')) IS DISTINCT FROM v_code THEN
    IF v_tries + 1 >= 5 THEN
      DELETE FROM notify_sms_challenges WHERE user_id = v_me;
      RETURN QUERY SELECT 'used_up'::text, 0; RETURN;
    END IF;
    UPDATE notify_sms_challenges SET attempts = v_tries + 1 WHERE user_id = v_me;
    RETURN QUERY SELECT 'wrong'::text, (5 - (v_tries + 1))::integer; RETURN;
  END IF;

  UPDATE users SET notify_sms_confirmed_at = now() WHERE id = v_me;
  DELETE FROM notify_sms_challenges WHERE user_id = v_me;
  RETURN QUERY SELECT 'confirmed'::text, NULL::integer;
END $$;

COMMENT ON FUNCTION confirm_notify_sms(text) IS
  'Answers the confirmation text for the caller''s own number. Returns a '
  'status — confirmed, wrong, used_up, expired or none — and how many tries '
  'remain against the pending code, which is a number for wrong and used_up '
  'and null for the three where no code is left to try. A STATUS rather than '
  'an exception, because raising would roll back the attempt it just counted '
  'and five tries would never be five. Its one raise, for a caller who is not '
  'signed in, is NS005. Fifteen minutes, five attempts. '
  'SECURITY DEFINER to reach notify_sms_challenges and to pass '
  'users_sms_confirmed_guard_t; it still acts only on current_user_id(). '
  'PostgREST returns this as an array of one row.';

REVOKE ALL ON FUNCTION confirm_notify_sms(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION confirm_notify_sms(text) TO authenticated;

COMMIT;

-- =============================================================================
-- STILL TO DO, named so they aren't folded in and skipped
--
-- * THE LIMITS ARE UNTESTED AGAINST A REAL SENDER, because there isn't one.
--   The figures — three an hour per number, ten a day per user — are a guess
--   at what a person fixing a typo needs, not a measurement. Revisit once
--   anyone has actually confirmed a number.
--
-- * notify_sms_sends IS PRUNED TO THIRTY DAYS, decided 2 Nov, inside
--   request_notify_sms_confirmation() because nothing in this database runs
--   on a schedule. That means it is pruned only when somebody asks for a
--   code: a firm that stops confirming numbers keeps its last rows until the
--   next request. Harmless at this size, and worth knowing before anyone
--   reads the table as a reliable thirty-day window.
--
-- * SETTINGS MATCHES ON THE CODE, NEVER ON THE SENTENCE. The table is also
--   in db/README.md under "Error codes the app matches on", which is the copy
--   somebody working on the app will actually find. NS001 no number,
--   NS002 already confirmed, NS003 too many to this number, NS004 too many
--   today, NS005 not signed in. The wording may be reworded freely; the codes
--   may not, and changing one is a migration with a drift check like any
--   other body change. NS002 in particular should not read to the person as
--   an error — it means the thing they wanted is already true.
--
--   settings.ts's friendly() still matches database MESSAGES by regex, for
--   /no mobile number to notify/i and /no email address to notify/i among
--   others. That is the shape this section stops repeating, and those older
--   matches are still live: rewording either message in the database breaks
--   the app silently. Worth coding them the same way when something next
--   replaces those bodies.
--
-- * A FAILED SEND STILL COUNTS TOWARD THE LIMIT, deliberately for now. If
--   Surge rejects the message after the code has been issued, the row in
--   notify_sms_sends stays and the hour is spent. Uncounting is deferred
--   until the sender exists and Surge's failure modes are known — and many
--   of them (a carrier reject, say) arrive long after the request has
--   returned, so they could not be voided inside it anyway. The app's job
--   meanwhile is to say plainly that the text could not be sent, rather than
--   letting the person conclude it is on its way.
--
-- * attempts_left ARRIVES AS AN ARRAY OF ONE ROW through PostgREST, like any
--   RETURNS TABLE. The app has not called confirm_notify_sms yet, so this is
--   the shape it should be written against from the start.
--
-- * case_converted_notify()'s body still says to search the log for
--   "case_converted_notify", when the string that works is "no notification
--   for case". Still waiting for a replacement of that body for a real
--   reason; this migration does not touch it.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
-- Made-up numbers only. NPA 555 is not assignable, so these reach nobody.
--
-- DO $$
-- DECLARE
--   r text := ''; v_org uuid; v_user uuid; v_other uuid;
--   v_code text; v_status text; v_left integer; i int;
-- BEGIN
--   SELECT id INTO v_org FROM organizations WHERE code = 'DR';
--   PERFORM set_config('app.is_internal', 'on', true);
--   PERFORM set_config('app.organization_id', v_org::text, true);
--
--   INSERT INTO users (email, full_name, is_internal, active)
--   VALUES ('verify.limits@example.invalid', 'Verify Limits', false, true)
--   RETURNING id INTO v_user;
--   PERFORM set_config('app.user_id', v_user::text, true);
--   UPDATE users SET notify_sms_e164 = '+15135550142' WHERE id = v_user;
--
--   -- ---- attempts_left counts down ------------------------------------------
--   SELECT code INTO v_code FROM request_notify_sms_confirmation(v_user);
--   FOR i IN 1..4 LOOP
--     SELECT c.status, c.attempts_left INTO v_status, v_left FROM confirm_notify_sms('999999') c;
--     r := r || 'wrong #' || i || ': ' || v_status || ', left ' || COALESCE(v_left::text, 'null')
--            || chr(10);
--   END LOOP;
--   SELECT c.status, c.attempts_left INTO v_status, v_left FROM confirm_notify_sms('999999') c;
--   r := r || 'fifth: ' || v_status || ', left ' || COALESCE(v_left::text, 'null')
--          || '   (expect wrong 4/3/2/1 then used_up 0)' || chr(10);
--   SELECT c.status, c.attempts_left INTO v_status, v_left FROM confirm_notify_sms('999999') c;
--   r := r || 'with nothing pending: ' || v_status || ', left '
--          || COALESCE(v_left::text, 'null') || '   (expect none, null)' || chr(10);
--
--   -- ---- three per number per hour ------------------------------------------
--   -- Only ONE send has happened so far — the single request at the top of
--   -- this block; the five confirm attempts sent nothing. So one more is
--   -- needed here before the arithmetic below reads as it says it does.
--   PERFORM request_notify_sms_confirmation(v_user);
--   r := r || 'sends to this number so far: '
--          || (SELECT count(*) FROM notify_sms_sends WHERE e164 = '+15135550142')
--          || '   (expect 2)' || chr(10);
--   PERFORM request_notify_sms_confirmation(v_user);
--   BEGIN
--     PERFORM request_notify_sms_confirmation(v_user);
--     r := r || 'fourth code to the same number: SENT (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'fourth code refused [' || SQLSTATE || '] ' || SQLERRM
--            || '   (expect NS003)' || chr(10); END;
--
--   -- Counted across users, not per asker: a second person hits the same wall.
--   INSERT INTO users (email, full_name, is_internal, active)
--   VALUES ('verify.limits2@example.invalid', 'Verify Limits Two', false, true)
--   RETURNING id INTO v_other;
--   UPDATE users SET notify_sms_e164 = '+15135550142' WHERE id = v_other;
--   BEGIN
--     PERFORM request_notify_sms_confirmation(v_other);
--     r := r || 'another user, same number: SENT (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'another user, same number refused [' || SQLSTATE || '] ' || SQLERRM
--            || chr(10)
--            || '   (expect NS003, and the two refusals above must match in '
--            || 'BOTH code and wording — either varying with who tripped the '
--            || 'limit leaks that somebody else has been asking about this '
--            || 'number)' || chr(10); END;
--
--   -- A different number is its own hour.
--   UPDATE users SET notify_sms_e164 = '+15135550143' WHERE id = v_other;
--   BEGIN
--     PERFORM request_notify_sms_confirmation(v_other);
--     r := r || 'a different number is allowed: true   (expect true)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'different number REFUSED (BAD): ' || SQLERRM || chr(10); END;
--
--   -- ---- ten per user per day ------------------------------------------------
--   -- Backdated rows, so the per-number hour does not fire first.
--   INSERT INTO notify_sms_sends (user_id, e164, sent_at)
--   SELECT v_other, '+1555000' || lpad(g::text, 4, '0'), now() - interval '2 hours'
--     FROM generate_series(1, 9) g;
--   UPDATE users SET notify_sms_e164 = '+15135550144' WHERE id = v_other;
--   BEGIN
--     PERFORM request_notify_sms_confirmation(v_other);
--     r := r || 'eleventh code today: SENT (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'eleventh code today refused [' || SQLSTATE || '] ' || SQLERRM
--            || '   (expect NS004)' || chr(10); END;
--
--   -- ---- a confirmed number is not resent to ---------------------------------
--   UPDATE users SET notify_sms_e164 = '+15135550145' WHERE id = v_user;
--   SELECT code INTO v_code FROM request_notify_sms_confirmation(v_user);
--   SELECT c.status INTO v_status FROM confirm_notify_sms(v_code) c;
--   r := r || 'confirmed a fresh number: ' || v_status || '   (expect confirmed)' || chr(10);
--   BEGIN
--     PERFORM request_notify_sms_confirmation(v_user);
--     r := r || 'resend on a confirmed number: SENT (BAD — it would unconfirm it)'
--            || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'resend on a confirmed number refused [' || SQLSTATE || '] '
--            || SQLERRM || '   (expect NS002)' || chr(10); END;
--   r := r || 'and it is still confirmed: '
--          || (SELECT notify_sms_confirmed_at IS NOT NULL FROM users WHERE id = v_user)
--          || '   (expect true)' || chr(10);
--
--   -- ---- no number at all ----------------------------------------------------
--   BEGIN
--     UPDATE users SET notify_sms_e164 = NULL WHERE id = v_other;
--     PERFORM request_notify_sms_confirmation(v_other);
--     r := r || 'code for a user with no number: SENT (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'no number refused [' || SQLSTATE || '] ' || SQLERRM
--            || '   (expect NS001)' || chr(10); END;
--
--   -- ---- the ledger is nobody's business -------------------------------------
--   -- Last, because the role does not revert inside this block.
--   PERFORM set_config('app.is_internal', 'off', true);
--   PERFORM set_config('role', 'authenticated', true);
--   BEGIN
--     r := r || 'authenticated can read the send log: '
--            || (SELECT count(*) FROM notify_sms_sends)::text
--            || '   (expect a permission error, not a number)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'authenticated reading the send log refused: ' || SQLERRM || chr(10); END;
--
--   RAISE EXCEPTION 'VERIFY 20261102T2345_notify_sms_send_limits (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
