-- =============================================================================
-- 20261123T2000_a_rollback_keeps_its_evidence.sql
-- The Hub — a rollback writes down what it removed, and when.
--
-- WHAT HAPPENED (23 November). 20261123T1810 and T1830 to T1835 were rolled
-- back on production, and the rollbacks deleted their rows from
-- schema_migrations. The ledger then said the seven had never run, though
-- T1810 had been live for about two hours (an estimate: see below) and broken
-- the Contacts page. Of the fourteen timestamps that mattered (seven applied,
-- seven rolled back), the database kept none: the applied times went with the
-- rows, and the rollback times were never written. track_commit_timestamp is
-- off, so Postgres kept no commit times, and Supabase's Postgres logs hold
-- errors only. What survives is what Mandie read off the ledger before
-- deleting it, the six to the second only.
--
-- WHY A SEPARATE TABLE, NOT A rolled_back_at COLUMN ON schema_migrations.
-- A row in schema_migrations means "applied here, now": six files gate on one
-- ("20261120T2330 has run here"), and ledgers are compared by filename. A kept
-- row marked rolled back would read as applied to every one of them. And
-- record_migration upserts on filename, so re-applying a rolled-back file
-- would overwrite the row that recorded the rollback. So:
--   * schema_rollbacks: append-only, one row per rollback, holding every
--     column of the ledger row it removed, plus when, by whom and why;
--   * record_rollback(filename, reason): copies the ledger row, stamps
--     clock_timestamp() itself (whoever is rolling back is busy and won't
--     think to; Mandie), and deletes the ledger row, in one call. A rollback
--     can't remove the evidence without writing it;
--   * schema_migrations keeps its meaning. No existing check changes, and a
--     re-run leaves the rollback history where it is.
-- rolled_back_at is when record_rollback ran, inside the rollback's
-- transaction: if that transaction aborts, the record goes with it, and if
-- it commits, the commit follows within the same run.
--
-- TONIGHT'S SEVEN ARE NOT IN THIS FILE. They are facts about production
-- alone, and this file is schema every database should have: a fresh build
-- from main runs it with 1810 applied and T1830 to T1835 not (#71 unmerged),
-- and must not stop there (Mandie's review). The backfill is its own file,
-- 20261123T2005, with its own preconditions.
--
-- track_commit_timestamp: worth deciding, not decided here. With it on,
-- Postgres keeps each transaction's commit time (pg_xact_commit_timestamp),
-- so a rollback that forgets record_rollback is still recoverable. It needs
-- a restart and costs a little storage, and on Supabase it may not be
-- settable by us. A judgement call, flagged in the PR.
--
-- THE APP. Nothing in hellophone reads schema_migrations or anything here,
-- and both tables have row-level security on, no policies, and no grant to
-- any API role (the identity's sequence included): PostgREST can't see them. No page to load (db/README.md, "A
-- schema change is done when the app works").
--
-- Requires: 20261103T1200 (schema_migrations, record_migration).
-- NOT SAFE TO RUN TWICE: section 1 refuses once schema_rollbacks exists.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Preconditions
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('public.schema_rollbacks') IS NOT NULL THEN
    RAISE EXCEPTION 'schema_rollbacks already exists: this file has run here';
  END IF;
  IF to_regprocedure('record_migration(text, text, text, text)') IS NULL THEN
    RAISE EXCEPTION 'record_migration is missing: 20261103T1200 has not run here';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. The record of rollbacks
-- -----------------------------------------------------------------------------
CREATE TABLE schema_rollbacks (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  filename               text NOT NULL,
  -- the ledger row as it was, every column
  first_applied_at       timestamptz,
  applied_at             timestamptz,
  applied_at_precision   text NOT NULL,
  applied_by             text,
  sha256                 text,
  ran_md5                text,
  ran_len                integer,
  note                   text,
  ledger_recorded_how    text,
  -- the rollback
  rolled_back_at         timestamptz,
  rolled_back_order      text,
  rolled_back_by         text NOT NULL,
  reason                 text NOT NULL,
  recorded_how           text NOT NULL,
  recorded_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT schema_rollbacks_precision_ck CHECK (applied_at_precision IN ('exact', 'second', 'unknown')),
  CONSTRAINT schema_rollbacks_recorded_how_ck CHECK (
    (recorded_how = 'record_rollback' AND rolled_back_at IS NOT NULL AND applied_at_precision = 'exact')
    OR (recorded_how = 'backfill' AND rolled_back_order IS NOT NULL))
);
CREATE INDEX schema_rollbacks_filename_idx ON schema_rollbacks (filename, id);
COMMENT ON TABLE schema_rollbacks IS
  'Every rollback of a Hub migration on this database: the ledger row it removed '
  'from schema_migrations, every column, and when, by whom and why. Append-only. '
  'Written by record_rollback, which stamps the time itself; recorded_how = '
  '''backfill'' rows were entered afterwards from what survived, at the precision '
  'stated, and a NULL there means not captured, never zero. schema_migrations '
  'still means "applied now" (20261123T2000).';
COMMENT ON COLUMN schema_rollbacks.applied_at_precision IS
  'How much of applied_at is known: exact; second (the fraction was lost); '
  'unknown (applied_at is NULL).';
COMMENT ON COLUMN schema_rollbacks.rolled_back_order IS
  'For a backfilled rollback whose time was not captured: what is certain about '
  'when, in words (after what, before what).';

ALTER TABLE schema_rollbacks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON schema_rollbacks FROM PUBLIC, anon, authenticated, service_role;
-- The identity's sequence too: on Supabase, default privileges grant every
-- new sequence to the API roles.
REVOKE ALL ON SEQUENCE schema_rollbacks_id_seq FROM PUBLIC, anon, authenticated, service_role;

-- Append-only, for its owner too: a record of what was removed is not itself
-- removable, by UPDATE, DELETE or TRUNCATE. (An owner can drop the triggers;
-- that is a migration, reviewed.)
CREATE FUNCTION schema_rollbacks_append_only() RETURNS trigger
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'schema_rollbacks is append-only: a rollback''s record is kept as written';
END $$;
CREATE TRIGGER schema_rollbacks_append_only_t
  BEFORE UPDATE OR DELETE ON schema_rollbacks
  FOR EACH ROW EXECUTE FUNCTION schema_rollbacks_append_only();
-- A row trigger doesn't fire on TRUNCATE, which would empty the table
-- silently (Mandie's review). This one does.
CREATE TRIGGER schema_rollbacks_no_truncate_t
  BEFORE TRUNCATE ON schema_rollbacks
  FOR EACH STATEMENT EXECUTE FUNCTION schema_rollbacks_append_only();
REVOKE ALL ON FUNCTION schema_rollbacks_append_only() FROM PUBLIC, anon, authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 3. record_rollback: the only way a ledger row should leave
-- -----------------------------------------------------------------------------
CREATE FUNCTION record_rollback(p_filename text, p_reason text)
RETURNS void LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE m schema_migrations;
BEGIN
  IF NULLIF(btrim(COALESCE(p_reason, '')), '') IS NULL THEN
    RAISE EXCEPTION 'a rollback needs a reason';
  END IF;
  SELECT * INTO m FROM schema_migrations WHERE filename = p_filename FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '% is not in this database''s ledger: nothing to roll back, or it already was', p_filename;
  END IF;
  INSERT INTO schema_rollbacks (filename, first_applied_at, applied_at, applied_at_precision, applied_by, sha256,
                                ran_md5, ran_len, note, ledger_recorded_how,
                                rolled_back_at, rolled_back_by, reason, recorded_how)
  VALUES (m.filename, m.first_applied_at, m.applied_at, 'exact', m.applied_by, m.sha256,
          m.ran_md5, m.ran_len, m.note, m.recorded_how,
          clock_timestamp(), current_user, p_reason, 'record_rollback');
  DELETE FROM schema_migrations WHERE filename = p_filename;
END $$;
COMMENT ON FUNCTION record_rollback(text, text) IS
  'Roll a migration out of the ledger with its evidence: copies the '
  'schema_migrations row into schema_rollbacks with the time (clock_timestamp, '
  'stamped here, not passed in), who and why, then deletes it. Call it inside '
  'the rollback''s own transaction, once per file (20261123T2000).';
REVOKE ALL ON FUNCTION record_rollback(text, text) FROM PUBLIC, anon, authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 4. Record it
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261123T2000_a_rollback_keeps_its_evidence.sql',
    NULL,
    'schema_rollbacks (append-only) and record_rollback(filename, reason), which '
    'copies the ledger row, stamps the time and deletes it in one call. Schema '
    'only; the 23 November rollbacks are backfilled by 20261123T2005.');
END $rec$;

COMMIT;

-- =============================================================================
-- Verification — run AFTER the file, as its own statement. One block,
-- everything rolled back by the closing RAISE. As postgres, which is who
-- rolls migrations back.
--
-- DO $$
-- DECLARE r text := ''; res text; n int; m int; t0 timestamptz;
-- BEGIN
--   -- ---- 1. nothing reachable through the API ------------------------------
--   SELECT count(*) FILTER (WHERE has_table_privilege(api.rolname, 'schema_rollbacks', p.priv)) INTO n
--     FROM unnest(ARRAY['anon', 'authenticated', 'service_role']) api(rolname),
--          unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) p(priv);
--   SELECT count(*) FILTER (WHERE has_function_privilege(api.rolname, 'record_rollback(text, text)', 'EXECUTE')) INTO m
--     FROM unnest(ARRAY['anon', 'authenticated', 'service_role']) api(rolname);
--   SELECT n + count(*) FILTER (WHERE has_sequence_privilege(api.rolname, 'schema_rollbacks_id_seq', p.priv)) INTO n
--     FROM unnest(ARRAY['anon', 'authenticated', 'service_role']) api(rolname), unnest(ARRAY['USAGE', 'SELECT', 'UPDATE']) p(priv);
--   r := r || '1. API-role privileges on schema_rollbacks and its sequence: ' || n || ' of 24; on record_rollback: ' || m || ' of 3'
--          || '; row-level security on: ' || (SELECT relrowsecurity FROM pg_class WHERE oid = 'schema_rollbacks'::regclass)
--          || '   (expect 0 of 24; 0 of 3; true)' || chr(10);
--
--   -- ---- 2. record_rollback moves a ledger row, with its time --------------
--   INSERT INTO schema_migrations (filename, recorded_how, note) VALUES ('zzz_verify_rollback.sql', 'self', 'zzz note');
--   t0 := clock_timestamp();
--   PERFORM record_rollback('zzz_verify_rollback.sql', 'verifying 20261123T2000');
--   r := r || '2. after record_rollback: still in the ledger ' || EXISTS (SELECT 1 FROM schema_migrations WHERE filename = 'zzz_verify_rollback.sql')
--          || '; recorded ' || (SELECT count(*) FROM schema_rollbacks WHERE filename = 'zzz_verify_rollback.sql')
--          || ', with the ledger''s note ' || (SELECT note = 'zzz note' FROM schema_rollbacks WHERE filename = 'zzz_verify_rollback.sql')
--          || ', time stamped by the function ' || (SELECT rolled_back_at >= t0 AND rolled_back_at <= clock_timestamp() FROM schema_rollbacks WHERE filename = 'zzz_verify_rollback.sql')
--          || ', by ' || (SELECT rolled_back_by FROM schema_rollbacks WHERE filename = 'zzz_verify_rollback.sql')
--          || ', how ' || (SELECT recorded_how || '/' || applied_at_precision FROM schema_rollbacks WHERE filename = 'zzz_verify_rollback.sql')
--          || '   (expect false; 1, true, true, postgres, record_rollback/exact)' || chr(10);
--
--   -- ---- 3. it refuses what it can't record --------------------------------
--   res := '';
--   BEGIN PERFORM record_rollback('zzz_never_ran.sql', 'x'); res := res || 'not in ledger: ALLOWED | ';
--   EXCEPTION WHEN OTHERS THEN res := res || 'not in ledger: refused | '; END;
--   INSERT INTO schema_migrations (filename, recorded_how) VALUES ('zzz_no_reason.sql', 'self');
--   BEGIN PERFORM record_rollback('zzz_no_reason.sql', '  '); res := res || 'no reason: ALLOWED | ';
--   EXCEPTION WHEN OTHERS THEN res := res || 'no reason: refused | '; END;
--   r := r || '3. ' || res || 'the row without a reason still in the ledger: '
--          || EXISTS (SELECT 1 FROM schema_migrations WHERE filename = 'zzz_no_reason.sql')
--          || '   (expect refused | refused | true)' || chr(10);
--
--   -- ---- 4. append-only, for postgres too ----------------------------------
--   res := '';
--   BEGIN UPDATE schema_rollbacks SET reason = 'changed' WHERE filename = 'zzz_verify_rollback.sql'; res := res || 'update: ALLOWED | ';
--   EXCEPTION WHEN OTHERS THEN res := res || 'update: refused | '; END;
--   BEGIN DELETE FROM schema_rollbacks WHERE filename = 'zzz_verify_rollback.sql'; res := res || 'delete: ALLOWED | ';
--   EXCEPTION WHEN OTHERS THEN res := res || 'delete: refused | '; END;
--   BEGIN TRUNCATE schema_rollbacks; res := res || 'truncate: ALLOWED';
--   EXCEPTION WHEN OTHERS THEN res := res || 'truncate: refused'; END;
--   r := r || '4. as postgres: ' || res || '; the row still there: '
--          || EXISTS (SELECT 1 FROM schema_rollbacks WHERE filename = 'zzz_verify_rollback.sql')
--          || '   (expect update: refused | delete: refused | truncate: refused; true)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261123T2000_a_rollback_keeps_its_evidence (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
