-- =============================================================================
-- 20261102T2000_routing_and_notify_number_checks.sql
-- The Hub — two more columns held to the one number rule.
--
-- WHY. 20261030T1500 moved the E.164 pattern into is_e164() and pointed
-- contact_phones, directory_entries and phone_numbers at it, in its six
-- sections. (Not 20261030T1730, which was drafted to do the phone_numbers
-- half separately and then declared void when it turned out six sections had
-- already run — it exists nowhere and credited it would be a file that never
-- ran.) Three columns that store a number were left without a check, so a value
-- the normalize trigger kept as typed is stored and then matches nothing,
-- silently — the defect that migration closed for directory_entries. This
-- closes two of them.
--
-- WHAT DECIDED WHICH TWO, because it is not what it first looks like.
--
-- None of the three has a writer today. Nothing in the Hub inserts into
-- routing_schedules or leads — 022's only inserts are commented examples —
-- and no function writes users.notify_sms_e164 except its own normalize
-- trigger. So "is anything writing it" does not separate them, and is not the
-- question.
--
-- The question is whether the column's MEANING is settled:
--
--   routing_schedules.target_e164 — settled, by a constraint that already
--     exists. routing_schedules_target_ck (022) requires it exactly when
--     target = 'forward_number', and teams and people are named through
--     target_team_id and target_person_id. So this column holds a number the
--     platform will dial. An extension or a SIP destination has no place in
--     it, whatever arrives later.
--
--   users.notify_sms_e164 — settled. It is a number a person gave in order to
--     be texted. An unreadable one is a typo that should be refused, which is
--     the same judgement 055 made for every number a person types.
--
--   leads.phone_e164 — NOT settled, and left alone. Its right answer depends
--     on where leads will come from, and that path is not built. See STILL TO
--     DO: if they arrive from web forms or imports it is the ingest argument
--     (evidence, kept), and a check would be wrong; if someone types them in
--     the app it is the form argument (a claim, refused), and a check is
--     right. Nobody has decided, so this file does not decide by default.
--
-- interactions.from_e164 and to_e164 are also left without a check, decided
-- in 20261102T1800 and not revisited here: refusing an ingest is exactly what
-- that migration argues against.
--
-- WHY THE PRECONDITION IS A REFUSAL AND NOT A REPORT. A CHECK is re-evaluated
-- on every UPDATE of a row, not only when the checked column changes. One
-- failing value would therefore not merely fail this migration — it would
-- trap that row for good, so that a later write of any other column on it
-- fails too. For users that means a bad notify_sms_e164 blocking last_seen_at
-- on every login. NOT VALID does not help: it skips existing rows when the
-- constraint is added and still checks them on update, so the trapped row
-- survives it.
--
-- Scanned on both databases on 2 Nov 2026: zero failing values, because both
-- columns are unset everywhere. leads is empty on both. routing_schedules has
-- one row on staging with no target_e164 and no rows at all on production.
-- users has three rows on staging and one on production, none with a notify
-- number. The scan is repeated below rather than trusted, because this file
-- can reach a database that is neither of those two.
--
-- THE CONSTRAINT IS THE BACKSTOP, NOT THE MESSAGE. A violation reads "new row
-- for relation users violates check constraint users_notify_sms_e164_ck",
-- which nobody can act on. When Settings gains a field for the notify number
-- it should pre-check with require_e164, as the Settings directory, Add
-- contact and wrap-up forms already do; this is what stops a bad value if
-- that is ever missed.
--
-- Requires, by what it actually uses:
--   003  users.notify_sms_e164 (added in 019), users
--   019  users_normalize_notify
--   022  routing_schedules, routing_schedules_target_ck
--   20261030T1500  is_e164()
--
-- Safe to run twice: the precondition tolerates the constraints already
-- existing, and neither is added twice.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. is_e164 must exist before anything is pointed at it
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regprocedure('is_e164(text)') IS NULL THEN
    RAISE EXCEPTION
      'is_e164(text) does not exist; run 20261030T1500_one_number_rule.sql first';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. Nothing stored would be trapped by either constraint
--
-- Counted before anything is added, and refused rather than reported: a row
-- that fails one of these is a row no later update can touch. If this stops,
-- the values are the work — not this migration.
-- -----------------------------------------------------------------------------
DO $$
DECLARE n_routing int; n_users int;
BEGIN
  SELECT count(*) INTO n_routing FROM routing_schedules
   WHERE target_e164 IS NOT NULL AND NOT is_e164(target_e164);

  SELECT count(*) INTO n_users FROM users
   WHERE notify_sms_e164 IS NOT NULL AND NOT is_e164(notify_sms_e164);

  IF n_routing > 0 OR n_users > 0 THEN
    RAISE EXCEPTION
      'stored numbers would be trapped: routing_schedules.target_e164 %, users.notify_sms_e164 %',
      n_routing, n_users
      USING HINT = 'A CHECK is re-evaluated on every update of a row, so each of these would become unwritable. Correct the values first; NOT VALID does not avoid this.';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 3. routing_schedules.target_e164
--
-- A forwarding destination, by construction: routing_schedules_target_ck
-- requires this column exactly when target = 'forward_number', and every
-- other target names its party through a different column. Nothing is dialled
-- from here yet; when something is, it will dial whatever this holds.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint
              WHERE conrelid = 'public.routing_schedules'::regclass
                AND conname = 'routing_schedules_e164_ck') THEN
    RAISE NOTICE 'routing_schedules_e164_ck already exists — this migration has run before';
  ELSE
    ALTER TABLE routing_schedules ADD CONSTRAINT routing_schedules_e164_ck
      CHECK (target_e164 IS NULL OR is_e164(target_e164));
  END IF;
END $$;

COMMENT ON CONSTRAINT routing_schedules_e164_ck ON routing_schedules IS
  'A forwarding destination is a number the platform will dial, so it is held '
  'to the same rule as every other stored number — is_e164(), the one place '
  'the pattern is written. routing_schedules_target_ck (022) decides WHEN '
  'this column is required; this decides what it may contain. Null stays '
  'allowed: a schedule that rings a team or a person names them elsewhere.';

-- -----------------------------------------------------------------------------
-- 4. users.notify_sms_e164
--
-- A number a person gave so that the Hub can text them. Nothing reads it but
-- the notification path, and 019's reachability trigger already refuses an
-- enabled sms preference when it is null — it checks for absence, not shape,
-- which is the gap this closes. A number that cannot be read is worse than
-- none: the preference is accepted, the trigger is satisfied, and the texts
-- go nowhere.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint
              WHERE conrelid = 'public.users'::regclass
                AND conname = 'users_notify_sms_e164_ck') THEN
    RAISE NOTICE 'users_notify_sms_e164_ck already exists — this migration has run before';
  ELSE
    ALTER TABLE users ADD CONSTRAINT users_notify_sms_e164_ck
      CHECK (notify_sms_e164 IS NULL OR is_e164(notify_sms_e164));
  END IF;
END $$;

COMMENT ON CONSTRAINT users_notify_sms_e164_ck ON users IS
  'Where to text this person, held to is_e164() like every other stored '
  'number. 019''s notification_preferences_reachable already refuses an '
  'enabled sms preference when this is null; it checks for absence, not '
  'shape, so without this a number nobody can dial satisfies it and the texts '
  'go nowhere. A backstop, not the message: Settings should pre-check with '
  'require_e164 when it gains a field for this.';

COMMIT;

-- =============================================================================
-- STILL TO DO, named so they aren't folded in and skipped
--
-- * leads.phone_e164 HAS NO CHECK, deliberately, because its meaning is not
--   decided. The decision is where leads come from:
--     - web forms, imports, a marketing feed → the number is evidence of an
--       enquiry that happened, nobody is present to correct it, and refusing
--       it discards the lead. Keep it, as ingest_call_event keeps a caller
--       ID (20261102T1800), and add no constraint.
--     - someone typing it into the app → it is a claim, the person is there,
--       and refusing is how they find out. A CHECK here plus a require_e164
--       pre-check in the form, like every other typed number.
--   Nothing writes the column today, so there is no hurry and no default
--   worth taking. Decide when the path is built.
--
--   THE LIKELY ANSWER IS THE FIRST ONE, recorded here so whoever builds leads
--   does not derive it again: a lead's number is typed by a person, but by
--   one who cannot be reached to correct it — the enquiry is over by the time
--   anyone looks. That is the ingest case, not the form case. Keep what was
--   given, let matching return nothing, add no constraint. Written as the
--   expectation rather than the decision, because the path could still turn
--   out to be someone entering leads in the app, and then it flips.
--
-- * Settings has no field for users.notify_sms_e164 yet. When it gains one,
--   it should call require_e164 like the Settings directory, Add contact and
--   wrap-up forms, so the person sees a sentence rather than this
--   constraint's name.
--
-- * A FORMAT CHECK CANNOT CATCH THE WORSE FAILURE on that column: a number
--   that is well-formed and wrong. The constraint accepts it, the preference
--   is enabled, the texts go to a stranger or nowhere, and the person simply
--   never hears anything and has no reason to suspect why. The only thing
--   that catches it is a confirmation text the person has to act on before
--   the number counts as theirs — which needs a sender, so it is a decision
--   for the dispatcher work rather than for this file. Named here because
--   this constraint is the thing most likely to be mistaken for having
--   solved it.
--
-- * interactions.from_e164 and to_e164 stay unconstrained, decided in
--   20261102T1800. Not an oversight, and not to be closed later without
--   reopening that argument.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
-- Made-up numbers only. NPA 555 is not assignable, so these reach nobody.
--
-- DO $$
-- DECLARE
--   r text := ''; v_org uuid; v_sched uuid; v_user uuid;
--   v_bad constant text := '+012345678';   -- leading zero: normalize_e164
--                                          -- passes 8-15 digits through, so
--                                          -- this reaches the constraint as
--                                          -- typed
-- BEGIN
--   SELECT id INTO v_org FROM organizations WHERE code = 'DR';
--   PERFORM set_config('app.is_internal', 'on', true);
--   PERFORM set_config('app.organization_id', v_org::text, true);
--
--   r := r || 'both constraints call is_e164: '
--          || (SELECT count(*) FROM pg_constraint
--               WHERE conname IN ('routing_schedules_e164_ck', 'users_notify_sms_e164_ck')
--                 AND pg_get_constraintdef(oid) LIKE '%is_e164%')
--          || '   (expect 2)' || chr(10);
--
--   r := r || 'nothing stored fails them: routing '
--          || (SELECT count(*) FROM routing_schedules
--               WHERE target_e164 IS NOT NULL AND NOT is_e164(target_e164))
--          || ', users '
--          || (SELECT count(*) FROM users
--               WHERE notify_sms_e164 IS NOT NULL AND NOT is_e164(notify_sms_e164))
--          || '   (expect 0, 0 — and the migration refuses to run otherwise)'
--          || chr(10);
--
--   -- users: an unreadable notify number is refused, a readable one kept,
--   -- and null still allowed.
--   BEGIN
--     SELECT id INTO v_user FROM users ORDER BY created_at LIMIT 1;
--     BEGIN
--       UPDATE users SET notify_sms_e164 = v_bad WHERE id = v_user;
--       r := r || 'unreadable notify number: ALLOWED (BAD)' || chr(10);
--     EXCEPTION
--       WHEN check_violation THEN
--         r := r || 'unreadable notify number refused' || chr(10);
--       WHEN others THEN
--         r := r || 'unreadable notify number NOT TESTED: ' || SQLERRM || chr(10); END;
--
--     UPDATE users SET notify_sms_e164 = '(513) 555-0142' WHERE id = v_user;
--     r := r || 'readable notify number stored as: '
--            || COALESCE((SELECT notify_sms_e164 FROM users WHERE id = v_user), 'NULL')
--            || '   (expect +15135550142 — normalized by users_normalize_notify)'
--            || chr(10);
--
--     UPDATE users SET notify_sms_e164 = NULL WHERE id = v_user;
--     r := r || 'null notify number allowed: '
--            || (SELECT notify_sms_e164 IS NULL FROM users WHERE id = v_user)
--            || '   (expect true)' || chr(10);
--
--     -- The reason the precondition refuses rather than reports: a trapped
--     -- row cannot be updated at all, not even on another column.
--     r := r || 'an unrelated update to that user still works: ';
--     UPDATE users SET last_seen_at = now() WHERE id = v_user;
--     r := r || 'true   (expect true — this is what a failing value would '
--            || 'have blocked)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'users tests NOT RUN: ' || SQLERRM || chr(10); END;
--
--   -- routing_schedules: same, on a row created here. 022 requires name,
--   -- starts_at and ends_at, and routing_schedules_when_ck requires exactly
--   -- one of day_of_week and specific_date — so a minimal insert of just the
--   -- target columns is refused before the constraint under test is reached.
--   BEGIN
--     INSERT INTO routing_schedules
--       (organization_id, name, day_of_week, starts_at, ends_at, target, target_e164)
--     VALUES (v_org, 'Verify forward', 1, '09:00', '17:00',
--             'forward_number', '+15550008001')
--     RETURNING id INTO v_sched;
--     r := r || 'readable forward number stored as: '
--            || COALESCE((SELECT target_e164 FROM routing_schedules WHERE id = v_sched), 'NULL')
--            || '   (expect +15550008001)' || chr(10);
--
--     BEGIN
--       UPDATE routing_schedules SET target_e164 = v_bad WHERE id = v_sched;
--       r := r || 'unreadable forward number: ALLOWED (BAD)' || chr(10);
--     EXCEPTION
--       WHEN check_violation THEN
--         r := r || 'unreadable forward number refused' || chr(10);
--       WHEN others THEN
--         r := r || 'unreadable forward number NOT TESTED: ' || SQLERRM || chr(10); END;
--
--     -- And an unrelated update to the same row still works, as for users.
--     UPDATE routing_schedules SET priority = priority WHERE id = v_sched;
--     r := r || 'an unrelated update to that schedule still works: true'
--            || '   (expect true)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'routing_schedules tests NOT RUN: ' || SQLERRM || chr(10); END;
--
--   -- What still has no check, so the list stays honest.
--   r := r || 'e164 columns still unconstrained: leads.phone_e164, '
--          || 'interactions.from_e164/to_e164   (both deliberate — see '
--          || 'STILL TO DO)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261102T2000_routing_and_notify_number_checks (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
