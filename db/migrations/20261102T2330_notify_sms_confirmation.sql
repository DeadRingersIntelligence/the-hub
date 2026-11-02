-- =============================================================================
-- 20261102T2330_notify_sms_confirmation.sql
-- The Hub — a number only counts once someone has answered it.
--
-- WHY. 20261102T2000 held users.notify_sms_e164 to is_e164(), and said in its
-- own STILL TO DO what that cannot catch: a number that is well formed and
-- wrong. The constraint accepts it, the preference enables, and the texts —
-- about families, by name — go to a stranger's phone. The person who typed it
-- never hears anything and has no reason to suspect why.
--
-- THE RULE. Saving a number sends one confirmation text and nothing else.
-- Until the code comes back, the number receives no notifications. Changing
-- the number sends it back to unconfirmed.
--
-- WHAT THIS FILE IS AND IS NOT. It is the state and the two moves: ask for a
-- code, answer it. It sends nothing, because nothing in this database can —
-- no pg_net, no pg_cron, no http — and texts on this platform go through
-- Surge (031) from the app, where no send path exists yet either
-- (TEXTING_CONNECTED is false). The first text event will be missed_call,
-- which is what the confirmation text should say it is for.
--
-- THREE THINGS AN EARLIER DRAFT GOT WRONG, kept here because each is a shape
-- rather than a slip.
--
--   THE CODE MUST NOT BE REACHABLE, NOT MERELY UNRETURNED. That draft kept it
--   in users.notify_sms_code and locked the function that issues it to
--   service_role. users has RLS with users_read USING can_see_user(id) and a
--   table-level SELECT for authenticated, so the person could simply read
--   their own code — and a manager could read their staff's. Locking the door
--   while the window is open. The pending code now lives in its own table with
--   RLS on, NO POLICIES, and every privilege revoked: only a definer function
--   can see it.
--
--   A STATE NOBODY MAY SET IS NOT THE SAME AS A FUNCTION NOBODY MAY CALL.
--   users_update lets a person — or their manager — UPDATE users SET
--   notify_sms_confirmed_at = now(). Confirmation that can be written by hand
--   confirms nothing. A trigger now refuses it from the API roles; inside a
--   SECURITY DEFINER function current_user is the owner, so confirm_notify_sms
--   still can, which is why that function had to become definer too.
--
--   RAISING UNDOES THE COUNTING. The draft incremented the attempt count and
--   then raised, which rolls the increment back. Every PostgREST call is its
--   own transaction, so the count stayed at zero and the five-try limit could
--   never fire — a six-digit code with unlimited guesses. confirm_notify_sms
--   now RETURNS A STATUS instead of raising, so the write commits. It raises
--   only for "not signed in", where there is nothing to record.
--
-- WHERE THIS CAN BE EXERCISED. SUPABASE_SERVICE_ROLE_KEY is set on Production
-- only, so no preview deployment can ask for a code, and on staging the whole
-- flow is reachable from SQL alone.
--
-- Requires, by what it actually uses:
--   003  users, current_user_id()
--   019  users.notify_sms_e164, users_normalize_notify,
--        notification_preferences_reachable()
--   20261102T2000  users_notify_sms_e164_ck
--   pgcrypto, in schema extensions
--
-- Safe to run twice: the table, column and constraint are added if absent,
-- functions and triggers are replaced rather than added, and the drift check
-- tells "already applied" from "something else changed it".
--
-- APPLIED to staging and production, 2 Nov 2026, from the file hashed
-- 42a0d54e. The BEGIN … COMMIT body is unchanged since (sha256 46c6f5ce,
-- 15581 bytes, identical on both runs) — what is below is what ran. Both
-- databases hold the same bodies:
--   confirm_notify_sms                  adbf3dd92f244c960bb5f6f40a805b85  definer
--   notification_preferences_reachable  84bb644bf72d9021c598a78e1b95b088
--   request_notify_sms_confirmation     30cd24d29453da0170ec7356ded8e10c  definer
--   users_sms_confirmation_reset        98a6525b33caa5285ce774e20e99307d  definer
--   users_sms_confirmed_guard           a54b4bc023d7f5e58209fc4e95fd5667
-- notify_sms_challenges: RLS on, not forced, no policies, SELECT false for
-- authenticated, service_role and anon. request_notify_sms_confirmation
-- EXECUTE: authenticated false, service_role true. confirm_notify_sms:
-- authenticated true, anon false. Both triggers enabled.
--
-- Production held nothing this could affect: 0 challenges, 0 confirmed users,
-- 0 users with a notify number, 0 enabled sms preferences.
--
-- The verification block ran in full on STAGING, against those same bodies,
-- and not on production: it creates a user. Two of its lines were fixed
-- afterwards, outside the body, per db/README.md — see the block itself for
-- what each was testing and why it was not testing it.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Where a pending code lives
--
-- Its own table, because the code is the one thing in this flow that the
-- person being confirmed must NOT be able to read. On users it is readable by
-- its owner and by anyone can_see_user() admits, and no grant on the issuing
-- function changes that.
--
-- RLS on with no policies, and every privilege revoked from the API roles. A
-- SECURITY DEFINER function runs as the owner, which is not subject to either,
-- so the two functions below reach it and nothing else does. RLS is NOT forced:
-- forcing it would lock out the owner as well and leave no way in at all.
--
-- One row per user: asking again replaces the pending code rather than
-- stacking another beside it.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS notify_sms_challenges (
  user_id   uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  code      text        NOT NULL,
  sent_at   timestamptz NOT NULL DEFAULT now(),
  attempts  smallint    NOT NULL DEFAULT 0
);

ALTER TABLE notify_sms_challenges ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE notify_sms_challenges FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON TABLE notify_sms_challenges IS
  'The confirmation code outstanding for one person''s notify number. Here '
  'rather than on users because the person being confirmed must not be able '
  'to read it: whoever can read the code can confirm a number they do not '
  'hold, which is the mistake confirmation exists to catch. RLS on, no '
  'policies, all privileges revoked — only request_notify_sms_confirmation() '
  'and confirm_notify_sms() touch it, as SECURITY DEFINER. Do not add a '
  'policy or a grant here.';

COMMENT ON COLUMN notify_sms_challenges.attempts IS
  'Wrong codes tried against this one. Five and the row is deleted: a '
  'six-digit code with unlimited tries is not a check.';

-- -----------------------------------------------------------------------------
-- 2. The confirmed state, on users where everything else about them is
-- -----------------------------------------------------------------------------
ALTER TABLE users ADD COLUMN IF NOT EXISTS notify_sms_confirmed_at timestamptz;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.users'::regclass
                    AND conname = 'users_notify_sms_confirmed_ck') THEN
    ALTER TABLE users ADD CONSTRAINT users_notify_sms_confirmed_ck
      CHECK (notify_sms_e164 IS NOT NULL OR notify_sms_confirmed_at IS NULL);
  END IF;
END $$;

COMMENT ON COLUMN users.notify_sms_confirmed_at IS
  'When this person answered the confirmation text. Null means the number has '
  'not been confirmed and MUST NOT BE TEXTED — a well-formed number can still '
  'be the wrong one, and these messages name families. Cleared whenever the '
  'number changes. Writable only by confirm_notify_sms(): '
  'users_sms_confirmed_guard_t refuses it from the API roles, because a '
  'confirmation anyone can set by hand confirms nothing.';

-- -----------------------------------------------------------------------------
-- 3. Changing the number unconfirms it
--
-- Fires AFTER users_normalize_notify_t, which is what makes this correct
-- rather than merely present: triggers of the same timing fire in name order,
-- and users_n... sorts before users_s..., so the comparison is between two
-- normalized values. Without that, retyping the same number in a different
-- shape — (513) 555-0142 for +15135550142 — would read as a change and make
-- someone confirm again for nothing.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION users_sms_confirmation_reset() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.notify_sms_e164 IS NOT DISTINCT FROM OLD.notify_sms_e164 THEN
    RETURN NEW;
  END IF;

  NEW.notify_sms_confirmed_at := NULL;
  DELETE FROM notify_sms_challenges WHERE user_id = NEW.id;
  RETURN NEW;
END $$;

COMMENT ON FUNCTION users_sms_confirmation_reset() IS
  'A changed notify number is an unconfirmed number, and any code outstanding '
  'for the old one is void. Compares normalized values because it fires after '
  'users_normalize_notify_t, so retyping the same number in another shape is '
  'not a change. Also clears on insert, so a row cannot arrive confirmed. '
  'SECURITY DEFINER only to reach notify_sms_challenges, which nothing else '
  'may touch.';

DROP TRIGGER IF EXISTS users_sms_confirmation_t ON users;
CREATE TRIGGER users_sms_confirmation_t
  BEFORE INSERT OR UPDATE OF notify_sms_e164 ON users
  FOR EACH ROW EXECUTE FUNCTION users_sms_confirmation_reset();

-- -----------------------------------------------------------------------------
-- 4. Nobody confirms themselves with an UPDATE
--
-- users_update admits the person and anyone can_manage_settings() plus
-- can_see_user() — so without this, confirmation is a column a manager can
-- type into, and answering the text is optional.
--
-- Keyed on current_user rather than on a Hub identity: inside a SECURITY
-- DEFINER function current_user is the function's owner, so confirm_notify_sms
-- passes and a PostgREST call does not. service_role is refused too — the
-- server sends the text, it does not decide the answer.
--
-- CLEARING STAYS OPEN. Setting it back to null is how someone withdraws a
-- number, and the reset trigger above does exactly that.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION users_sms_confirmed_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.notify_sms_confirmed_at IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE'
     AND NEW.notify_sms_confirmed_at IS NOT DISTINCT FROM OLD.notify_sms_confirmed_at THEN
    RETURN NEW;
  END IF;

  IF current_user IN ('authenticated', 'anon', 'service_role') THEN
    RAISE EXCEPTION 'a mobile number is confirmed by answering the text, not by setting a field'
      USING HINT = 'Call confirm_notify_sms() with the code.';
  END IF;

  RETURN NEW;
END $$;

COMMENT ON FUNCTION users_sms_confirmed_guard() IS
  'Refuses to let notify_sms_confirmed_at be SET from the API roles, so a '
  'person — or their manager, via users_update — cannot confirm a number '
  'without answering its text. confirm_notify_sms() is SECURITY DEFINER, so '
  'current_user there is the owner and it passes. Clearing stays allowed: '
  'that is how a number is withdrawn.';

DROP TRIGGER IF EXISTS users_sms_confirmed_guard_t ON users;
CREATE TRIGGER users_sms_confirmed_guard_t
  BEFORE INSERT OR UPDATE OF notify_sms_confirmed_at ON users
  FOR EACH ROW EXECUTE FUNCTION users_sms_confirmed_guard();

-- -----------------------------------------------------------------------------
-- 5. Asking for a code
--
-- Returns the code to its caller, which is why it is service_role only: the
-- caller is a server-side sender holding the service key, and it returns
-- nothing to the browser but "sent". Asking again replaces the code and
-- resets the attempts — someone who never got the first text should not be
-- locked out by it, which is also what makes a "resend" link in Settings
-- possible without re-entering the number.
--
-- gen_random_bytes rather than random(): random() is seeded per session and
-- predictable, and pgcrypto is already installed. Three bytes, so the value is
-- always positive and no sign handling is needed.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION request_notify_sms_confirmation(p_user uuid)
RETURNS TABLE (e164 text, code text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_e164 text; v_code text;
BEGIN
  SELECT notify_sms_e164 INTO v_e164 FROM users WHERE id = p_user;
  IF v_e164 IS NULL THEN
    RAISE EXCEPTION 'that person has no mobile number to confirm';
  END IF;

  v_code := lpad(((('x' || encode(extensions.gen_random_bytes(3), 'hex'))::bit(24)::int)
                  % 1000000)::text, 6, '0');

  INSERT INTO notify_sms_challenges (user_id, code, sent_at, attempts)
  VALUES (p_user, v_code, now(), 0)
  ON CONFLICT (user_id) DO UPDATE
    SET code = EXCLUDED.code, sent_at = EXCLUDED.sent_at, attempts = 0;

  UPDATE users SET notify_sms_confirmed_at = NULL WHERE id = p_user;

  RETURN QUERY SELECT v_e164, v_code;
END $$;

COMMENT ON FUNCTION request_notify_sms_confirmation(uuid) IS
  'Sets a new confirmation code and hands it back with the number, for a '
  'server-side sender to text through Surge. SECURITY DEFINER and granted to '
  'service_role alone: anyone who can read the code can confirm a number they '
  'do not hold. Asking again replaces the code and resets the attempt count, '
  'which is what a "resend" in Settings calls.';

REVOKE ALL ON FUNCTION request_notify_sms_confirmation(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION request_notify_sms_confirmation(uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 6. Answering it
--
-- RETURNS A STATUS, AND DOES NOT RAISE. Raising would roll back the attempt
-- count written moments earlier, and each PostgREST call is its own
-- transaction — so the count would stay at zero and five tries would never be
-- five. The same applies to deleting an expired or spent code. The only raise
-- left is "not signed in", where there is nothing to record.
--
-- Statuses: confirmed | wrong | used_up | expired | none. The app turns them
-- into sentences; none of them is an error.
--
-- SECURITY DEFINER for two reasons: to reach notify_sms_challenges, and so
-- that current_user is the owner and section 4's guard lets the confirmation
-- through. It still acts only on current_user_id(), which SECURITY DEFINER
-- does not change — nobody confirms anybody else's number.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION confirm_notify_sms(p_code text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_me uuid; v_code text; v_sent timestamptz; v_tries smallint;
BEGIN
  v_me := current_user_id();
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'you''re not signed in to the Hub yet';
  END IF;

  SELECT code, sent_at, attempts INTO v_code, v_sent, v_tries
    FROM notify_sms_challenges WHERE user_id = v_me FOR UPDATE;

  IF NOT FOUND THEN RETURN 'none'; END IF;

  IF v_sent < now() - interval '15 minutes' THEN
    DELETE FROM notify_sms_challenges WHERE user_id = v_me;
    RETURN 'expired';
  END IF;

  IF btrim(COALESCE(p_code, '')) IS DISTINCT FROM v_code THEN
    IF v_tries + 1 >= 5 THEN
      DELETE FROM notify_sms_challenges WHERE user_id = v_me;
      RETURN 'used_up';
    END IF;
    UPDATE notify_sms_challenges SET attempts = v_tries + 1 WHERE user_id = v_me;
    RETURN 'wrong';
  END IF;

  UPDATE users SET notify_sms_confirmed_at = now() WHERE id = v_me;
  DELETE FROM notify_sms_challenges WHERE user_id = v_me;
  RETURN 'confirmed';
END $$;

COMMENT ON FUNCTION confirm_notify_sms(text) IS
  'Answers the confirmation text for the caller''s own number. Returns '
  'confirmed, wrong, used_up, expired or none — a STATUS, not an exception, '
  'because raising would roll back the attempt it just counted and five tries '
  'would never be five. Fifteen minutes, five attempts. SECURITY DEFINER to '
  'reach notify_sms_challenges and to pass users_sms_confirmed_guard_t; it '
  'still acts only on current_user_id().';

REVOKE ALL ON FUNCTION confirm_notify_sms(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION confirm_notify_sms(text) TO authenticated;

-- -----------------------------------------------------------------------------
-- 7. Turning texts on now needs a confirmed number
--
-- 019's reachability trigger refuses an enabled sms preference when there is
-- no number. It is the right place for this too: the moment someone chooses
-- texts is the moment to say the number is not confirmed, rather than letting
-- them choose and then quietly sending nothing.
--
-- Its two existing messages are reproduced EXACTLY. settings.ts matches
-- /no mobile number to notify/i and /no email address to notify/i to turn
-- them into sentences; changing a word here makes that app code stop
-- recognising them, and the person gets the raw database text.
-- -----------------------------------------------------------------------------
DO $$
DECLARE v text;
BEGIN
  SELECT md5(prosrc) INTO v FROM pg_proc
   WHERE oid = 'notification_preferences_reachable()'::regprocedure;

  IF v IS NULL THEN
    RAISE EXCEPTION 'notification_preferences_reachable does not exist; run 019 first';
  ELSIF v = '84bb644bf72d9021c598a78e1b95b088' THEN
    RAISE NOTICE 'notification_preferences_reachable already requires confirmation — this migration has run before';
  ELSIF v <> '34f9c1c5c334bec6a57073ae991b4df9' THEN
    RAISE EXCEPTION 'notification_preferences_reachable is neither 019''s version (%) nor this one; stop and compare before replacing it', v;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION notification_preferences_reachable() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_email text; v_sms text; v_confirmed timestamptz;
BEGIN
  IF NOT NEW.enabled THEN RETURN NEW; END IF;
  SELECT COALESCE(notify_email, email), notify_sms_e164, notify_sms_confirmed_at
    INTO v_email, v_sms, v_confirmed
    FROM users WHERE id = NEW.user_id;
  IF NEW.channel = 'email' AND v_email IS NULL THEN
    RAISE EXCEPTION 'this user has no email address to notify'; END IF;
  IF NEW.channel = 'sms' AND v_sms IS NULL THEN
    RAISE EXCEPTION 'this user has no mobile number to notify'; END IF;
  -- New in 20261102T2330. A well-formed number can still be the wrong one,
  -- and these messages name families.
  IF NEW.channel = 'sms' AND v_confirmed IS NULL THEN
    RAISE EXCEPTION 'this user''s mobile number has not been confirmed'; END IF;
  RETURN NEW;
END $$;

COMMENT ON FUNCTION notification_preferences_reachable() IS
  'A channel with nowhere to send is a preference that silently never fires, '
  'so turning one on is refused when there is nowhere to send it. For sms '
  'that means a number AND a confirmed one: a number that is well formed and '
  'wrong passes users_notify_sms_e164_ck and sends family names to a '
  'stranger. The two older messages are matched by settings.ts to turn them '
  'into sentences — reword them there in the same change or the person sees '
  'the raw text.';

-- -----------------------------------------------------------------------------
-- 8. The comment that has been waiting for a notifications migration
--
-- The default was read as "this feature is off by default", which it is not.
-- -----------------------------------------------------------------------------
COMMENT ON COLUMN notification_preferences.enabled IS
  'Whether this person wants this event on this channel. Defaults to false, '
  'matching the app''s reading that an absent row is off — a row written '
  'without an opinion should not turn something on. THIS DEFAULT IS NOT THE '
  'PRODUCT RULE. Managers get case_converted on: that comes from the seed in '
  '20261030T1930 and from user_scope_default_notifications(), which gives a '
  'newly promoted manager the same row. Read those, not this, to find out '
  'what anyone actually receives.';

COMMIT;

-- =============================================================================
-- STILL TO DO, named so they aren't folded in and skipped
--
-- * NOTHING SENDS THE TEXT. request_notify_sms_confirmation() sets a code and
--   hands it to a server-side sender; no sender exists, and the app has no
--   Surge path at all (TEXTING_CONNECTED is false). Until one exists no
--   number can be confirmed, so section 7 means nobody can turn texts on —
--   the right failure, but a failure. Settings should not offer sms before
--   the sender does.
--
-- * BUILD THE SENDER ONCE. The confirmation text and the dispatcher's
--   notifications are the same act with different words, and two Surge paths
--   would be two places for a number to be formatted, a failure to be
--   swallowed, or a retry to be invented.
--
-- * THE DISPATCHER MUST CHECK CONFIRMATION ITSELF, not only the preference.
--   Section 7 stops sms being turned on while unconfirmed, but a preference
--   enabled first and the number changed afterwards leaves the preference ON
--   and the confirmation cleared — the verification below ends on exactly
--   that state.
--
-- * EMAIL IS PARKED, decided 2 Nov. The first dispatcher is desktop and sms.
--   notification_preferences still accepts an enabled email row, so the
--   schema does not say this; the app does.
--
-- * case_converted IS DESKTOP ONLY, decided 2 Nov, and the first sms event
--   will be missed_call. Nothing in the schema enforces either — the enum
--   allows the rows — so they are the app's rules, and this is where someone
--   looking for them in the database finds out they are not here.
--
-- * A RESEND ON AN ALREADY-CONFIRMED NUMBER UNCONFIRMS IT.
--   request_notify_sms_confirmation() clears notify_sms_confirmed_at before
--   issuing, so a "resend" pressed on a number that is already confirmed
--   takes it back to unconfirmed — and if that text is never answered, the
--   person silently stops getting texts. Which is the exact failure this
--   whole file exists to prevent, reintroduced by the button meant to help.
--
--   THE FIX IS TO REFUSE when the number is already confirmed, rather than to
--   no-op: a no-op returns success with no code, and the app says "sent" when
--   nothing was. Refusing makes the UI mistake visible instead of quietly
--   degrading. There is no legitimate reason to re-confirm an unchanged
--   confirmed number — changing it already unconfirms it.
--
--   NOT DONE HERE: it is a change to that function's body, and this file has
--   run on both databases. Its own migration, with the drift check expecting
--   30cd24d29453da0170ec7356ded8e10c. Until then, Settings must only offer
--   resend while the number is unconfirmed.
--
-- * THE CONFIRMATION TEXT SENDS INLINE, not through the dispatcher's cron.
--   The person is watching their phone for it, and a queue delay produces
--   repeated resends — which, per the item above, is the worst thing this
--   flow can be asked to absorb. The cron is right for notifications, which
--   nobody is waiting on. One sender module, two callers.
--
-- * THIS FLOW CAN ONLY REALLY BE TESTED ON PRODUCTION, because
--   SUPABASE_SERVICE_ROLE_KEY is set there alone, and it needs a real handset
--   to receive a real text. A development path that logs the code instead of
--   sending it reopens precisely the hole section 1 closed, so it is not an
--   option. Plan that test deliberately — whose phone, which number, who
--   clears the rows afterwards — rather than meeting it on the day.
--
-- * case_converted_notify()'s body still says to search the log for
--   "case_converted_notify", when the string that works is "no notification
--   for case". It is in prosrc, so it waits for a replacement of that body
--   for a real reason. 20261102T1600's header already records it.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
-- Made-up numbers only. NPA 555 is not assignable, so these reach nobody.
--
-- The attempt counting is the part worth watching. An earlier draft raised on
-- a wrong code, and a raise rolls back the count it had just written — inside
-- this block each try would also have sat in its own subtransaction, so the
-- total would have read 0 and looked like a broken test rather than a broken
-- limit. Nothing below catches an exception around a wrong code, because
-- there is no longer one to catch.
--
-- DO $$
-- DECLARE
--   r text := ''; v_org uuid; v_user uuid; v_code text; v_e164 text; i int;
--   v_status text; v_rows int;
-- BEGIN
--   SELECT id INTO v_org FROM organizations WHERE code = 'DR';
--   PERFORM set_config('app.is_internal', 'on', true);
--   PERFORM set_config('app.organization_id', v_org::text, true);
--
--   INSERT INTO users (email, full_name, is_internal, active)
--   VALUES ('verify.sms@example.invalid', 'Verify SMS', false, true)
--   RETURNING id INTO v_user;
--   PERFORM set_config('app.user_id', v_user::text, true);
--
--   -- Saving a number leaves it unconfirmed.
--   UPDATE users SET notify_sms_e164 = '(513) 555-0142' WHERE id = v_user;
--   r := r || 'number stored as ' || (SELECT notify_sms_e164 FROM users WHERE id = v_user)
--          || ', confirmed: ' || (SELECT notify_sms_confirmed_at IS NOT NULL FROM users WHERE id = v_user)
--          || '   (expect +15135550142, false)' || chr(10);
--
--   -- Texts cannot be turned on yet.
--   BEGIN
--     INSERT INTO notification_preferences (user_id, event, channel, enabled)
--     VALUES (v_user, 'missed_call'::notification_event, 'sms'::notification_channel, true);
--     r := r || 'sms enabled while unconfirmed: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'sms while unconfirmed refused: ' || SQLERRM || chr(10); END;
--
--   -- A code is issued, and nothing about it is on users.
--   SELECT code, e164 INTO v_code, v_e164 FROM request_notify_sms_confirmation(v_user);
--   r := r || 'code issued for ' || v_e164 || ', six digits: ' || (v_code ~ '^[0-9]{6}$')
--          || ', held in notify_sms_challenges: '
--          || EXISTS (SELECT 1 FROM notify_sms_challenges WHERE user_id = v_user)
--          || '   (expect true, true)' || chr(10);
--
--   -- Wrong codes COUNT, because nothing raises.
--   FOR i IN 1..4 LOOP v_status := confirm_notify_sms('999999'); END LOOP;
--   r := r || 'four wrong tries — last status ' || v_status || ', attempts now '
--          || (SELECT attempts FROM notify_sms_challenges WHERE user_id = v_user)
--          || '   (expect wrong, 4 — this is what raising would have rolled back)'
--          || chr(10);
--   v_status := confirm_notify_sms('999999');
--   r := r || 'fifth try — status ' || v_status || ', challenge gone: '
--          || (NOT EXISTS (SELECT 1 FROM notify_sms_challenges WHERE user_id = v_user))
--          || '   (expect used_up, true)' || chr(10);
--   r := r || 'and with no challenge, status is ' || confirm_notify_sms('999999')
--          || '   (expect none)' || chr(10);
--
--   -- The right code confirms.
--   --
--   -- The call and the reads are SEPARATE STATEMENTS on purpose. An earlier
--   -- draft had confirm_notify_sms() and the two subqueries in one expression,
--   -- and a statement's subqueries cannot see what a function called in that
--   -- same statement wrote — so it reported "confirmed, false, false" and read
--   -- as a broken function rather than a broken test.
--   SELECT code INTO v_code FROM request_notify_sms_confirmation(v_user);
--   v_status := confirm_notify_sms(v_code);
--   r := r || 'right code — status ' || v_status
--          || ', confirmed: ' || (SELECT notify_sms_confirmed_at IS NOT NULL FROM users WHERE id = v_user)
--          || ', challenge cleared: '
--          || (NOT EXISTS (SELECT 1 FROM notify_sms_challenges WHERE user_id = v_user))
--          || '   (expect confirmed, true, true)' || chr(10);
--
--   -- And now texts can be turned on.
--   BEGIN
--     INSERT INTO notification_preferences (user_id, event, channel, enabled)
--     VALUES (v_user, 'missed_call'::notification_event, 'sms'::notification_channel, true);
--     r := r || 'sms enabled once confirmed: true   (expect true)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'sms once confirmed REFUSED (BAD): ' || SQLERRM || chr(10); END;
--
--   -- Retyping the same number in another shape is not a change.
--   UPDATE users SET notify_sms_e164 = '513-555-0142' WHERE id = v_user;
--   r := r || 'same number, different shape — still confirmed: '
--          || (SELECT notify_sms_confirmed_at IS NOT NULL FROM users WHERE id = v_user)
--          || '   (expect true — the reset fires after normalization)' || chr(10);
--
--   -- A different number is not, and the preference stays on.
--   UPDATE users SET notify_sms_e164 = '+15135550199' WHERE id = v_user;
--   r := r || 'different number — confirmation cleared: '
--          || (SELECT notify_sms_confirmed_at IS NULL FROM users WHERE id = v_user)
--          || ', sms preference still on: '
--          || (SELECT enabled FROM notification_preferences
--               WHERE user_id = v_user AND channel = 'sms' LIMIT 1)
--          || '   (expect true, true — which is why the dispatcher must check '
--          || 'confirmation and not only the preference)' || chr(10);
--
--   -- Confirm the NEW number, so the withdrawal below has something to
--   -- withdraw. Without this the number is already unconfirmed and the UPDATE
--   -- changes nothing, which succeeds and proves nothing.
--   SELECT code INTO v_code FROM request_notify_sms_confirmation(v_user);
--   v_status := confirm_notify_sms(v_code);
--   r := r || 'new number confirmed again: ' || v_status || '   (expect confirmed)'
--          || chr(10);
--
--   -- ---- As a signed-in user, with RLS applying -----------------------------
--   -- Last, because the role does not revert inside this block.
--   PERFORM set_config('app.is_internal', 'off', true);
--   PERFORM set_config('role', 'authenticated', true);
--
--   BEGIN
--     r := r || 'authenticated can read a pending code: '
--            || (SELECT count(*) FROM notify_sms_challenges)::text
--            || '   (expect a permission error, not a number)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'authenticated reading codes refused: ' || SQLERRM || chr(10); END;
--
--   BEGIN
--     UPDATE users SET notify_sms_confirmed_at = now() WHERE id = v_user;
--     r := r || 'authenticated confirmed by hand: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'confirming by hand refused: ' || SQLERRM || chr(10); END;
--
--   BEGIN
--     PERFORM request_notify_sms_confirmation(v_user);
--     r := r || 'authenticated asked for a code: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'asking for a code refused' || chr(10); END;
--
--   BEGIN
--     UPDATE users SET notify_sms_confirmed_at = NULL WHERE id = v_user;
--     GET DIAGNOSTICS v_rows = ROW_COUNT;
--     r := r || 'withdrawing a confirmed number — rows changed ' || v_rows
--            || ', now null: '
--            || (SELECT notify_sms_confirmed_at IS NULL FROM users WHERE id = v_user)
--            || '   (expect 1, true — the row count matters: an UPDATE that '
--            || 'changes nothing also succeeds)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'withdrawing REFUSED (BAD): ' || SQLERRM || chr(10); END;
--
--   RAISE EXCEPTION 'VERIFY 20261102T2330_notify_sms_confirmation (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
