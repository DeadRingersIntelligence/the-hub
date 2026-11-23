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
-- TONIGHT'S SEVEN, BACKFILLED WHERE THEY HAPPENED. Production rolled them
-- back; staging did not. The file can't name its database, so it reads the
-- ledger: where none of the seven has a row (production), it records the
-- seven rollbacks; where all seven do (staging), it records nothing; anything
-- in between refuses. The backfill holds only what is known, at the
-- precision it is known:
--   * applied_at: T1810 exact (18:13:26.142448 UTC); the six to the second
--     (the query that read them truncated the fraction, and the rows are
--     gone, so that is permanent), marked applied_at_precision = 'second';
--   * ran_md5 and ran_len: exact, as each ledger row recorded them, which
--     matched the reviewed commits' pasted hashes;
--   * note: exact, the text each file passed to record_migration;
--   * applied_by, first_applied_at, sha256: not captured: NULL;
--   * rolled_back_at: NOT CAPTURED. NULL, never an estimate. What is certain
--     is the order, kept in rolled_back_order: the six-file rollback
--     committed after T1835 was applied (18:57:32) and before the T1810
--     rollback, both on 23 November, in one session.
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
DECLARE n int;
BEGIN
  IF to_regclass('public.schema_rollbacks') IS NOT NULL THEN
    RAISE EXCEPTION 'schema_rollbacks already exists: this file has run here';
  END IF;
  IF to_regprocedure('record_migration(text, text, text, text)') IS NULL THEN
    RAISE EXCEPTION 'record_migration is missing: 20261103T1200 has not run here';
  END IF;
  -- Tonight's seven: all in the ledger (staging) or none (production).
  SELECT count(*) INTO n FROM schema_migrations WHERE filename IN (
    '20261123T1810_contact_phones_same_firm.sql', '20261123T1830_same_firm_interactions.sql',
    '20261123T1831_same_firm_people.sql', '20261123T1832_same_firm_contacts.sql',
    '20261123T1833_same_firm_locations.sql', '20261123T1834_same_firm_accounts_cases_seats.sql',
    '20261123T1835_same_firm_the_rest.sql');
  IF n NOT IN (0, 7) THEN
    RAISE EXCEPTION '% of the seven same-firm files are in this ledger, not 0 (rolled back, as on production) or 7 (applied, as on staging): stop and read it', n;
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
-- removable. (An owner can drop the trigger; that is a migration, reviewed.)
CREATE FUNCTION schema_rollbacks_append_only() RETURNS trigger
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'schema_rollbacks is append-only: a rollback''s record is kept as written';
END $$;
CREATE TRIGGER schema_rollbacks_append_only_t
  BEFORE UPDATE OR DELETE ON schema_rollbacks
  FOR EACH ROW EXECUTE FUNCTION schema_rollbacks_append_only();
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
-- 4. Tonight's seven, where they were rolled back (production)
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM schema_migrations WHERE filename = '20261123T1810_contact_phones_same_firm.sql') THEN
    RETURN;   -- applied here (staging): nothing was rolled back
  END IF;
  INSERT INTO schema_rollbacks (filename, applied_at, applied_at_precision, ran_md5, ran_len, note, ledger_recorded_how,
                                rolled_back_at, rolled_back_order, rolled_back_by, reason, recorded_how)
  SELECT f, a::timestamptz, p, md5, len, nt, 'self', NULL,
         ord, 'Mandie (postgres, SQL editor)', rsn, 'backfill'
    FROM (VALUES
      ('20261123T1830_same_firm_interactions.sql', '2026-11-23 18:47:54+00', 'second', '87f57aa514506d667a05cd096aa0c766', 45648,
       'Same-firm keys, family A: 23 keys onto interactions made composite on organization_id; ON DELETE carried over, SET NULL on the pointer column only.'),
      ('20261123T1831_same_firm_people.sql', '2026-11-23 18:50:31+00', 'second', 'a8693214179d2ee8a447323c8d597b1b', 44408,
       'Same-firm keys, family A: 22 keys onto people made composite on organization_id; ON DELETE carried over, SET NULL on the pointer column only.'),
      ('20261123T1832_same_firm_contacts.sql', '2026-11-23 18:51:48+00', 'second', '6a4840fa00c3b52d8748e6f3224d4ae1', 41966,
       'Same-firm keys, family A: 18 keys onto contacts made composite on organization_id; ON DELETE carried over, SET NULL on the pointer column only.'),
      ('20261123T1833_same_firm_locations.sql', '2026-11-23 18:53:44+00', 'second', '9cbc446e5fee82cc9491263419400eaa', 40002,
       'Same-firm keys, family A: 16 keys onto locations made composite on organization_id; ON DELETE carried over, SET NULL on the pointer column only.'),
      ('20261123T1834_same_firm_accounts_cases_seats.sql', '2026-11-23 18:55:39+00', 'second', '6e44b36d8b8d1ab151eeaca4e45d6fa0', 45167,
       'Same-firm keys, family A: 22 keys onto accounts, cases, seats, campaigns, location_groups made composite on organization_id; ON DELETE carried over, SET NULL on the pointer column only.'),
      ('20261123T1835_same_firm_the_rest.sql', '2026-11-23 18:57:32+00', 'second', 'f00cff40247fb5a6be68b1f2f589fcc6', 51962,
       'Same-firm keys, family A: 20 keys onto answering_services, auto_tag_rules, contact_imports, custom_field_definitions, decedents, evaluations, marketing_vendors, referral_sources, report_definitions, reporting_periods, rubrics, shops, teams, threads, transcript_segments made composite on organization_id; ON DELETE carried over, SET NULL on the pointer column only.'),
      ('20261123T1810_contact_phones_same_firm.sql', '2026-11-23 18:13:26.142448+00', 'exact', '42cfaf2f3175f84284059f0636521f51', 15903,
       'contact_phones -> contacts: both keys composite on organization_id, so a phone record''s contact is at its firm for every role. ON DELETE carried over (CASCADE; SET NULL on the pointer column only). First batch of the same-firm keys.')
    ) AS v(f, a, p, md5, len, nt)
    CROSS JOIN LATERAL (SELECT
      CASE WHEN v.f LIKE '20261123T1810%'
           THEN 'Committed after the six-file rollback (T1830 to T1835), in the same session on 23 November. Wall-clock time not captured.'
           ELSE 'Committed with the other five of T1830 to T1835 in one transaction, after T1835 was applied (18:57:32 UTC) and before the T1810 rollback, on 23 November. Wall-clock time not captured.' END AS ord,
      CASE WHEN v.f LIKE '20261123T1810%'
           THEN 'Broke the app: the Contacts page failed ("Could not find a relationship between ''contacts'' and ''contact_phones''") from 18:13, when it ran, until this rollback, about two hours (an estimate: broken at 18:13, working when checked after). PostgREST resolves a column hint (contact_phones!contact_id) only for a single-column key, and this made it composite.'
           ELSE 'Broke the app: "Could not find a relationship between ''interactions'' and ''contacts''" on the first page loaded after the six ran. PostgREST resolves a column hint (contacts!contact_id) only for a single-column key, and these made them composite.' END AS rsn) w
   ORDER BY v.f;
END $$;

-- -----------------------------------------------------------------------------
-- 5. Record it
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261123T2000_a_rollback_keeps_its_evidence.sql',
    NULL,
    'schema_rollbacks (append-only) and record_rollback(filename, reason), which '
    'copies the ledger row, stamps the time and deletes it in one call. On '
    'production, the seven same-firm rollbacks of 23 November backfilled with what '
    'survived, at its precision; their rollback times were not captured.');
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
--   BEGIN DELETE FROM schema_rollbacks WHERE filename = 'zzz_verify_rollback.sql'; res := res || 'delete: ALLOWED';
--   EXCEPTION WHEN OTHERS THEN res := res || 'delete: refused'; END;
--   r := r || '4. as postgres: ' || res || '   (expect update: refused | delete: refused)' || chr(10);
--
--   -- ---- 5. tonight's seven, on this database ------------------------------
--   SELECT count(*) INTO n FROM schema_rollbacks WHERE recorded_how = 'backfill';
--   r := r || '5. backfilled rollbacks: ' || n
--          || CASE WHEN n = 0 THEN ' (the seven are applied here: '
--                  || (SELECT count(*) FROM schema_migrations WHERE filename LIKE '20261123T18%_same_firm%' OR filename LIKE '20261123T1810%') || ' in the ledger)'
--                  ELSE ': ' || (SELECT string_agg(left(filename, 13) || ' ' || to_char(applied_at AT TIME ZONE 'UTC', CASE applied_at_precision WHEN 'exact' THEN 'HH24:MI:SS.US' ELSE 'HH24:MI:SS' END) || ' ' || applied_at_precision
--                                                  || ' rolled back ' || COALESCE(rolled_back_at::text, 'not captured'), '; ' ORDER BY applied_at)
--                                 FROM schema_rollbacks WHERE recorded_how = 'backfill') END
--          || chr(10) || '   (expect on production 7: T1810 18:13:26.142448 exact, the six 18:47:54 to 18:57:32 second, every rollback '
--          || '"not captured"; on staging 0, with 7 in the ledger)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261123T2000_a_rollback_keeps_its_evidence (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
