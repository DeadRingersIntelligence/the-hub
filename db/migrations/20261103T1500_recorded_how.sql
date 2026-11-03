-- =============================================================================
-- 20261103T1500_recorded_how.sql
-- The Hub — a ledger row should say how it got there.
--
-- WHAT IS WRONG. Nothing, yet. The ledger distinguishes a row that recorded
-- itself from one written after the fact by the absence of four values:
-- first_applied_at, applied_at, ran_md5, ran_len all NULL means backfilled.
-- It is true today, it is written down in the table comment, and it is held
-- up by nothing at all.
--
-- The first person to improve the backfill breaks it. Filling in a plausible
-- first_applied_at from a merge-commit date was proposed and declined once
-- already, and it is the obvious next idea for anyone who finds eleven rows
-- with no dates on them. The moment one lands, the four-NULL rule is false,
-- nothing says so, and every later reader is told that a backfilled row
-- recorded itself.
--
-- THE FIX. Say it in a column instead of inferring it from gaps, and make the
-- two statements unable to disagree:
--
--     recorded_how text NOT NULL
--     CHECK (recorded_how IN ('self','backfill')
--            AND (recorded_how = 'backfill') = (ran_md5 IS NULL))
--
-- NO DEFAULT, deliberately. A default of 'self' would make a hand-written
-- INSERT claim to be a self-recorded run, which is the one lie this column
-- exists to prevent. Without one, every writer has to state how the row got
-- there, and record_migration states 'self' because it is only ever called by
-- something that is actually running.
--
-- THE SECOND HALF OF THE CHECK IS THE POINT. recorded_how alone would be one
-- more thing to keep in sync by hand. Tied to ran_md5, the column and the
-- fingerprint cannot drift apart: a backfilled row cannot acquire a
-- fingerprint, a self-recorded row cannot lose one, and the improvement that
-- would have broken the old rule now fails loudly at the moment it is tried.
-- Dates may still be filled in later — that no longer destroys the
-- distinction, which was the whole trouble with encoding it in NULLs.
--
-- WHY NOT IN 20261103T1400. Different concern. 1400 is about the trailer
-- regex and has a measured block md5 and a clean staging run behind it;
-- reopening it to add a column would cost both for no reason beyond saving a
-- file.
--
-- Requires: 20261103T1200 (schema_migrations, record_migration).
--           Runs with or without 20261103T1400; it touches neither
--           submitted_text() nor any fingerprint already recorded.
-- Safe to run twice.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Three states, read from the column rather than from a body hash
--
-- The usual drift check hashes the thing being replaced. Here the thing being
-- replaced is a table shape, and the shape answers the question directly: no
-- column means not yet done, column plus its constraint means already done,
-- column without its constraint means somebody has been here and this file
-- should not guess what they meant.
--
-- record_migration is replaced in section 3 without a body hash, which is
-- weaker, and said plainly rather than dressed up: the Hub has no database and
-- md5(prosrc) is not computable from a file. What is checked instead is that
-- the body still has the two features this file depends on — that it goes
-- through submitted_text(), and that it upserts. A rewrite that kept both
-- would survive this check. A hand-edit that dropped either would not.
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_col boolean; v_ck boolean; v_src text;
BEGIN
  IF to_regclass('public.schema_migrations') IS NULL THEN
    RAISE EXCEPTION 'schema_migrations does not exist; run 20261103T1200 first';
  END IF;

  v_col := EXISTS (SELECT 1 FROM pg_attribute
                    WHERE attrelid = 'public.schema_migrations'::regclass
                      AND attname = 'recorded_how' AND NOT attisdropped);
  v_ck  := EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'public.schema_migrations'::regclass
                      AND conname = 'schema_migrations_recorded_how_ck');

  IF v_col AND v_ck THEN
    RAISE NOTICE 'recorded_how is already in place — this migration has run before';
  ELSIF v_col AND NOT v_ck THEN
    RAISE EXCEPTION
      'recorded_how exists without schema_migrations_recorded_how_ck; stop and read it'
      USING HINT = 'The column without the constraint is the half that does not hold.';
  END IF;

  SELECT prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'record_migration' AND p.pronargs = 4;
  IF v_src IS NULL THEN
    RAISE EXCEPTION 'record_migration(text,text,text,text) does not exist; run 20261103T1200 first';
  END IF;
  IF v_src NOT LIKE '%submitted_text()%' OR v_src NOT LIKE '%ON CONFLICT%' THEN
    RAISE EXCEPTION
      'record_migration does not look like 20261103T1200 left it; stop and read it'
      USING HINT = 'Expected a body that fingerprints through submitted_text() and upserts.';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. The column
--
-- Added nullable, filled from the rule it replaces, then made NOT NULL. The
-- fill is the one and only time ran_md5 IS NULL is allowed to decide this —
-- after the constraint exists, the two are held together instead.
-- -----------------------------------------------------------------------------
ALTER TABLE schema_migrations ADD COLUMN IF NOT EXISTS recorded_how text;

UPDATE schema_migrations
   SET recorded_how = CASE WHEN ran_md5 IS NULL THEN 'backfill' ELSE 'self' END
 WHERE recorded_how IS NULL;

ALTER TABLE schema_migrations ALTER COLUMN recorded_how SET NOT NULL;

ALTER TABLE schema_migrations DROP CONSTRAINT IF EXISTS schema_migrations_recorded_how_ck;
ALTER TABLE schema_migrations ADD CONSTRAINT schema_migrations_recorded_how_ck
  CHECK (recorded_how IN ('self', 'backfill')
         AND (recorded_how = 'backfill') = (ran_md5 IS NULL));

COMMENT ON COLUMN schema_migrations.recorded_how IS
  '''self'' if this row was written by the migration as it ran, ''backfill'' '
  'if somebody wrote it afterwards from evidence. It replaces an unenforced '
  'convention — that a backfilled row holds NULL in all four run columns — '
  'which the first person to fill in a plausible date would have broken '
  'silently. The constraint ties it to ran_md5, so the column and the '
  'fingerprint cannot come to disagree. No default: every writer says how.';

-- -----------------------------------------------------------------------------
-- 3. record_migration says 'self', because that is all it can ever mean
--
-- Identical to 20261103T1200's body but for the two added references. The
-- ON CONFLICT branch sets it too: a row that was backfilled and is later run
-- for real stops being a backfilled row, and its fingerprint arrives in the
-- same statement, so the constraint is satisfied at every point.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION record_migration(
  p_filename   text,
  p_sha256     text DEFAULT NULL,
  p_note       text DEFAULT NULL,
  p_applied_by text DEFAULT NULL
) RETURNS void
LANGUAGE sql
SET search_path = public, pg_temp
AS $$
  INSERT INTO schema_migrations AS m
         (filename, sha256, note, applied_by, ran_md5, ran_len, recorded_how)
  VALUES (p_filename, p_sha256, p_note,
          COALESCE(p_applied_by, current_user),
          md5(submitted_text()), length(submitted_text()), 'self')
  ON CONFLICT (filename) DO UPDATE
     SET applied_at       = now(),
         first_applied_at = COALESCE(m.first_applied_at, now()),
         applied_by       = EXCLUDED.applied_by,
         sha256           = COALESCE(EXCLUDED.sha256, m.sha256),
         note             = COALESCE(EXCLUDED.note,   m.note),
         ran_md5          = EXCLUDED.ran_md5,
         ran_len          = EXCLUDED.ran_len,
         recorded_how     = 'self';
$$;

COMMENT ON FUNCTION record_migration(text, text, text, text) IS
  'Last statement inside a migration''s transaction block, so the row and the '
  'work commit or roll back together: a file that fails records nothing. Call '
  'it from a DO block rather than a bare SELECT — the SQL editor appends '
  '" limit 100" to a trailing bare SELECT, which lands in the hashed text. It '
  'always records recorded_how = ''self''; a backfilled row is written by hand '
  'and says so. Invoker, and executable by nobody but the owner.';

-- -----------------------------------------------------------------------------
-- 4. The table comment stops describing a rule that is now a constraint
-- -----------------------------------------------------------------------------
COMMENT ON TABLE schema_migrations IS
  'Which Hub migration ran on this database, and when. STARTS 2026-11-03 AND '
  'IS NOT A HISTORY: no row exists for anything applied before that date, and '
  'the absence of a row for an older file is not evidence that it did not run. '
  'Before this table, the only way to tell was to read the catalogue for the '
  'objects a file creates — which is how staging went a month without 014. '
  'recorded_how says whether a row wrote itself as it ran or was entered '
  'afterwards from evidence; read it rather than inferring from empty columns.';

-- -----------------------------------------------------------------------------
-- 5. Record it
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM record_migration(
    '20261103T1500_recorded_how.sql',
    NULL,
    'Makes "how was this row established" an enforced column instead of a '
    'convention about which fields are empty.');
END $$;

COMMIT;

-- =============================================================================
-- STILL TO DO
--
-- * THE DATES ON THE ELEVEN BACKFILLED ROWS ARE NOW FILLABLE WITHOUT HARM. The
--   reason to leave them NULL was that NULL carried the "backfilled" meaning;
--   the constraint carries it now. If the merge-commit date of each APPLIED PR
--   is worth having as an approximate first_applied_at, it can go in — in its
--   own file, with a note on every row saying it is the merge date and not the
--   apply time. It is not obviously worth having. It is now merely a question
--   of whether an approximate date beats no date, rather than a question of
--   whether the ledger still means anything.
--
-- * NOTHING ENFORCES THAT A MIGRATION CALLS record_migration. Still true, still
--   unenforceable from inside the database: a file that forgets is
--   indistinguishable from a file that never ran. The README is the only place
--   that rule can live.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- DO $$
-- DECLARE r text := ''; n int;
-- BEGIN
--   r := r || 'rows by recorded_how: '
--          || COALESCE((SELECT string_agg(recorded_how || '=' || c, ', ' ORDER BY recorded_how)
--                         FROM (SELECT recorded_how, count(*) c FROM schema_migrations
--                                GROUP BY recorded_how) x), 'NONE')
--          || '   (expect backfill=11, self=4 or more)' || chr(10);
--   r := r || 'recorded_how disagreeing with ran_md5: '
--          || (SELECT count(*) FROM schema_migrations
--               WHERE (recorded_how = 'backfill') <> (ran_md5 IS NULL))
--          || '   (expect 0 — and the constraint should make it impossible)' || chr(10);
--
--   -- The constraint, tested by trying to break it three ways. Each must fail.
--   BEGIN
--     UPDATE schema_migrations SET recorded_how = 'self'
--      WHERE filename = '20261102T2200_merge_chains.sql';
--     r := r || 'a backfilled row could claim to be self-recorded (BAD)' || chr(10);
--   EXCEPTION WHEN check_violation THEN
--     r := r || 'backfilled row refused ''self'': correct' || chr(10); END;
--
--   BEGIN
--     UPDATE schema_migrations SET ran_md5 = NULL
--      WHERE filename = '20261103T1200_schema_migrations_ledger.sql';
--     r := r || 'a self-recorded row could lose its fingerprint (BAD)' || chr(10);
--   EXCEPTION WHEN check_violation THEN
--     r := r || 'self-recorded row refused a null fingerprint: correct' || chr(10); END;
--
--   BEGIN
--     INSERT INTO schema_migrations (filename, recorded_how, ran_md5)
--     VALUES ('ZZZ_nonsense.sql', 'imported', 'abc');
--     r := r || 'an invented recorded_how was accepted (BAD)' || chr(10);
--   EXCEPTION WHEN check_violation THEN
--     r := r || 'invented recorded_how refused: correct' || chr(10); END;
--
--   BEGIN
--     INSERT INTO schema_migrations (filename, sha256) VALUES ('ZZZ_silent.sql', 'abc');
--     r := r || 'a row was written without saying how (BAD)' || chr(10);
--   EXCEPTION WHEN not_null_violation THEN
--     r := r || 'row without recorded_how refused: correct — no default is the '
--            || 'reason, so a hand-written row cannot pass as a run' || chr(10); END;
--
--   -- Dates may now be filled in without destroying the distinction. This is
--   -- the improvement that would have silently broken the old four-NULL rule.
--   UPDATE schema_migrations SET first_applied_at = '2026-11-02'
--    WHERE filename = '20261102T2200_merge_chains.sql';
--   r := r || 'a backfilled row with a date is still backfilled: '
--          || (SELECT recorded_how FROM schema_migrations
--               WHERE filename = '20261102T2200_merge_chains.sql')
--          || '   (expect backfill — under the old rule this row had just '
--          || 'become indistinguishable from a self-recorded one)' || chr(10);
--
--   -- A backfilled file that is later run for real becomes self-recorded.
--   PERFORM record_migration('20261102T2200_merge_chains.sql', NULL, NULL, 'verification');
--   r := r || 'after a real run it reads: '
--          || (SELECT recorded_how || ', ran_len ' || ran_len FROM schema_migrations
--               WHERE filename = '20261102T2200_merge_chains.sql')
--          || '   (expect self, with a real length)' || chr(10);
--
--   r := r || 'this file recorded itself: '
--          || (SELECT recorded_how FROM schema_migrations
--               WHERE filename = '20261103T1500_recorded_how.sql')
--          || '   (expect self)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261103T1500_recorded_how (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
