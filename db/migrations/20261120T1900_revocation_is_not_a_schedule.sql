-- =============================================================================
-- 20261120T1900_revocation_is_not_a_schedule.sql
-- The Hub — partner_access.revoked_on can't be in the future.
--
-- APPLIED to staging (17:35 UTC) and production (17:36 UTC), 20 Nov 2026,
-- from commit 4cc76a7, sha256 91dc09cf…87895cdc, loaded whole. ran_md5
-- 14cf04cb560c3510bdbf90e0904ccb82 (8025 characters) on both, as predicted.
-- All 7 verification lines matched on both. The baseline moved con to 50552
-- and com to 11226, each to the character, and nothing else moved. This note
-- was added afterwards.
--
-- CORRECTION, from review after the run. The "WHOSE TODAY" paragraph below
-- covers only the half that works. West of UTC is fine. East of UTC is the
-- opposite: at 10am on the 21st in New Zealand it's 21:00 on the 20th in UTC,
-- so a date worked out in the firm's zone (as the app does for reports) is
-- refused as being in the future. Its last sentence ("never refuses a
-- revocation someone means to take effect now") isn't true as written. The
-- paragraph is left as it ran; this note corrects it.
--
-- THE CONSTRAINT STAYS. Allowing current_date + 1 would put back the
-- divergence this file closes. The rule belongs in the app: REVOKING NOW
-- MEANS NOT SENDING A DATE. revoked_on has no default, and PostgREST can't
-- send current_date, so "revoke now" needs a Hub function that sets
-- revoked_on = current_date itself, to be built with the grant/revoke screen.
-- A date the app supplies is then only ever a revocation that already
-- happened, which is in the past and always passes. Theoretical while every
-- client is in the US, but the symptom, a refusal with no apparent cause,
-- would be hard to trace back here. Recorded in db/README.md.
--
-- WHAT IS WRONG. partner_access is a dated grant: granted_on NOT NULL, and
-- revoked_on. in_force() (20261120T1510) is the one statement of when a dated
-- grant applies, but partners_read reads revoked_on IS NULL. Those two
-- disagree only when revoked_on is in the future: in_force() would still
-- grant until that day, and partners_read refuses at once. So the column
-- invites a scheduled revocation ("end this consultancy on the 31st") that
-- the policy then ignores. That makes partner_access the one exception to "a
-- rule is stated once".
--
-- THE RULING (review of 20261120T1800 and Mandie, 20 November): a CHECK.
-- revoked_on is today or earlier, or null. Then revoked_on IS NULL and
-- in_force(granted_on, revoked_on, current_date) agree on every value the
-- column can hold. Nobody's access changes, the column stops promising a
-- schedule, and the divergence stops existing without touching partners_read.
-- The other option, ruling revoked_on a schedule, was a new feature nobody
-- asked for, and it loosened a consent rule to get there. If a firm ever wants
-- "end this consultancy on the 31st", that's a deliberate change with its own
-- review.
--
-- current_date IN A CHECK. Postgres's documentation warns against
-- non-immutable functions in a CHECK, because the constraint is checked only
-- when a row is written and could stop being true later. Here it can't: a
-- date that was today or earlier when written stays earlier. A dump and
-- restore re-checks every row and passes for the same reason. Confirmed on
-- scratch (Postgres 16): it's accepted, it refuses tomorrow, and it allows
-- today. No trigger is needed, so this shows up in con, not trg.
--
-- WHOSE "TODAY". current_date is the session's date, UTC on Supabase. A
-- manager in the Americas revoking late in the evening is on UTC's next day,
-- which is still "today or earlier". The constraint never refuses a
-- revocation someone means to take effect now.
--
-- Requires: 003 (partner_access), 20261120T1800, 20261103T1200
--           (record_migration).
-- NOT SAFE TO RUN TWICE: section 1 refuses if the constraint exists.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Preconditions. Above all: no revocation already scheduled. If there
--    is one, someone meant it as a schedule, and that needs a ruling, not
--    this file.
-- -----------------------------------------------------------------------------
DO $$
DECLARE n int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM schema_migrations
                  WHERE filename = '20261120T1800_managers_decide.sql') THEN
    RAISE EXCEPTION '20261120T1800 has not run here; run it first';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint
              WHERE conrelid = 'public.partner_access'::regclass
                AND conname = 'partner_access_revoked_not_future_ck') THEN
    RAISE EXCEPTION 'partner_access_revoked_not_future_ck already exists; this file has run'
      USING HINT = 'Not safe to run twice. Stop and read the ledger.';
  END IF;
  SELECT count(*) INTO n FROM partner_access WHERE revoked_on > current_date;
  IF n > 0 THEN
    RAISE EXCEPTION '% partner_access row(s) already carry a revoked_on in the future; stop', n
      USING HINT = 'Someone meant those as a schedule. That needs a ruling before this file can run.';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. The constraint
-- -----------------------------------------------------------------------------
ALTER TABLE partner_access
  ADD CONSTRAINT partner_access_revoked_not_future_ck
  CHECK (revoked_on IS NULL OR revoked_on <= current_date);

COMMENT ON CONSTRAINT partner_access_revoked_not_future_ck ON partner_access IS
  'A revocation takes effect when it''s recorded; it isn''t a schedule. With '
  'this, partners_read''s revoked_on IS NULL and in_force(granted_on, '
  'revoked_on, current_date) agree on every value the column can hold. '
  'current_date is safe here because a date that was today or earlier stays '
  'earlier. Scheduled revocation would be a new, reviewed feature '
  '(20261120T1900).';

-- -----------------------------------------------------------------------------
-- 3. Record it
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261120T1900_revocation_is_not_a_schedule.sql',
    NULL,
    'partner_access.revoked_on can''t be in the future (CHECK). partners_read''s '
    'revoked_on IS NULL and in_force() now agree on every permitted value. No '
    'access changes.');
END $rec$;

COMMIT;

-- =============================================================================
-- Verification — run AFTER the file, as its own statement. One block,
-- everything rolled back by the closing RAISE. Written as Dead Ringers, who
-- can write any grant, so a refusal here is the constraint and not the
-- policy. A manager is held to it by the same constraint.
--
-- DO $$
-- DECLARE r text := ''; v_org uuid; v_p uuid; v_pa uuid; res text; d date := current_date;
-- BEGIN
--   r := r || '1. the constraint: '
--          || COALESCE((SELECT pg_get_constraintdef(oid) FROM pg_constraint
--                        WHERE conname = 'partner_access_revoked_not_future_ck'), 'MISSING')
--          || '   (expect CHECK (((revoked_on IS NULL) OR (revoked_on <= CURRENT_DATE))))' || chr(10);
--   r := r || '2. existing grants: ' || (SELECT count(*) FROM partner_access)
--          || ', revoked: ' || (SELECT count(*) FROM partner_access WHERE revoked_on IS NOT NULL)
--          || ', revoked in the future: ' || (SELECT count(*) FROM partner_access WHERE revoked_on > d)
--          || '   (expect any, any, 0)' || chr(10);
--
--   PERFORM set_config('app.is_internal', 'on', true);
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ verify 1900', 'funeral_home') RETURNING id INTO v_org;
--   INSERT INTO partners (name, partner_type) VALUES ('ZZZ Partner 1900', 'consultancy') RETURNING id INTO v_p;
--   INSERT INTO partner_access (partner_id, organization_id) VALUES (v_p, v_org) RETURNING id INTO v_pa;
--
--   BEGIN UPDATE partner_access SET revoked_on = d + 1 WHERE id = v_pa; res := 'ALLOWED';
--   EXCEPTION WHEN check_violation THEN res := SQLSTATE; END;
--   r := r || '3. revoke from tomorrow: ' || res || '   (expect 23514)' || chr(10);
--   BEGIN UPDATE partner_access SET revoked_on = d WHERE id = v_pa; res := 'allowed';
--   EXCEPTION WHEN check_violation THEN res := SQLSTATE; END;
--   r := r || '4. revoke from today: ' || res || '   (expect allowed)' || chr(10);
--   BEGIN UPDATE partner_access SET revoked_on = d - 30 WHERE id = v_pa; res := 'allowed';
--   EXCEPTION WHEN check_violation THEN res := SQLSTATE; END;
--   r := r || '5. record a revocation from last month: ' || res || '   (expect allowed)' || chr(10);
--   BEGIN UPDATE partner_access SET revoked_on = NULL WHERE id = v_pa; res := 'allowed';
--   EXCEPTION WHEN check_violation THEN res := SQLSTATE; END;
--   r := r || '6. reinstate (revoked_on cleared): ' || res || '   (expect allowed)' || chr(10);
--   r := r || '7. the two readings agree on every row: '
--          || (NOT EXISTS (SELECT 1 FROM partner_access
--                           WHERE (revoked_on IS NULL) IS DISTINCT FROM in_force(granted_on, revoked_on, d)
--                             AND granted_on <= d))::text
--          || '   (expect true: revoked_on IS NULL and in_force() give the same answer)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261120T1900_revocation_is_not_a_schedule (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
