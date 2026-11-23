-- =============================================================================
-- 20261123T2005_production_rollbacks_of_23_november.sql
-- The Hub — production's seven rollbacks of 23 November, recorded from what
-- survived.
--
-- WHY A FILE OF ITS OWN. These are facts about production, not schema. They
-- were in 20261123T2000 until review (Mandie): a database built from main
-- runs 1810 and not T1830 to T1835 (#71 unmerged), and a file that had to
-- guess its database refused it. And not a hand-run on production either: a
-- hand-run leaves no record of itself, which is the failure this record
-- exists to fix.
--
-- WHAT IT DOES, BY DATABASE:
--   * 20261123T1810 IN THE LEDGER (a fresh build from main; staging, which
--     never rolled back): nothing was rolled back here. It records nothing,
--     says so, and records itself, so a replay never stops here;
--   * 1810 AND T1830 TO T1835 ALL ABSENT, 20261123T1700 PRESENT (production,
--     which rolled the seven back), AND THE OPT-IN SET IN THE SAME RUN: it
--     records the seven rollbacks. Without the opt-in it REFUSES and records
--     nothing: it never skips silently on the one database it is for;
--   * anything else (1810 absent but some of the six present): refuses.
--
-- THE OPT-IN, on production only, as the first line of the same Run as this
-- file (the SQL editor may not keep a SET from one Run to the next, so it
-- goes in the same paste):
--     SET hub.backfill_production_rollbacks = 'yes';
-- The ledger's ran_md5 on production is then the md5 of that line, a
-- newline, and this file: the PR gives that hash as well as the file's own.
--
-- WHAT IS RECORDED, AT THE PRECISION IT IS KNOWN (from Mandie's records):
--   * applied_at: T1810 exact (18:13:26.142448 UTC); the six to the second
--     (the query that read them truncated the fraction, and the rows are
--     gone, so that is permanent), marked applied_at_precision = 'second';
--   * ran_md5 and ran_len: exact, as each ledger row recorded them, which
--     matched the reviewed commits' pasted hashes;
--   * note: exact, the text each file passed to record_migration;
--   * applied_by, first_applied_at, sha256: not captured: NULL;
--   * rolled_back_at: NOT CAPTURED. NULL, never an estimate.
--     track_commit_timestamp was off and Supabase's Postgres logs hold errors
--     only. What is certain is the order, kept in rolled_back_order: the
--     six-file rollback committed after T1835 was applied (18:57:32) and
--     before the T1810 rollback, both on 23 November, in one session;
--   * "about two hours" (T1810 live) is an estimate, labelled as one.
--
-- THE APP: nothing in hellophone reads schema_migrations or schema_rollbacks
-- (searched on main, 1f2630b: no match). No page to load.
--
-- Requires: 20261123T2000 (schema_rollbacks), 20261123T1700, 20261103T1200.
-- NOT SAFE TO RUN TWICE: section 1 refuses once these rows exist.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Preconditions, and which database this is
-- -----------------------------------------------------------------------------
DO $$
DECLARE n_six int; has_1810 boolean;
BEGIN
  IF to_regclass('public.schema_rollbacks') IS NULL THEN
    RAISE EXCEPTION '20261123T2000 has not run here (no schema_rollbacks): run it first';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM schema_migrations WHERE filename = '20261123T1700_contact_import_internal_cap.sql') THEN
    RAISE EXCEPTION '20261123T1700 has not run here: this database is not where the 23 November rollbacks happened';
  END IF;
  IF EXISTS (SELECT 1 FROM schema_rollbacks WHERE recorded_how = 'backfill'
              AND filename LIKE '20261123T18%') THEN
    RAISE EXCEPTION 'the 23 November rollbacks are already recorded here: this file has run';
  END IF;
  has_1810 := EXISTS (SELECT 1 FROM schema_migrations WHERE filename = '20261123T1810_contact_phones_same_firm.sql');
  SELECT count(*) INTO n_six FROM schema_migrations WHERE filename IN (
    '20261123T1830_same_firm_interactions.sql', '20261123T1831_same_firm_people.sql',
    '20261123T1832_same_firm_contacts.sql', '20261123T1833_same_firm_locations.sql',
    '20261123T1834_same_firm_accounts_cases_seats.sql', '20261123T1835_same_firm_the_rest.sql');
  IF has_1810 THEN
    RAISE NOTICE '20261123T1810 is in this ledger: nothing was rolled back here, so nothing is recorded';
    PERFORM set_config('hub.backfill_mode', 'none', true);
  ELSIF n_six > 0 THEN
    RAISE EXCEPTION '20261123T1810 is absent but % of T1830 to T1835 are present: not a state any database should be in; stop and read it', n_six;
  ELSIF COALESCE(current_setting('hub.backfill_production_rollbacks', true), '') <> 'yes' THEN
    RAISE EXCEPTION 'this looks like production (the seven same-firm files rolled back): to record their rollbacks, put SET hub.backfill_production_rollbacks = ''yes''; as the first line of this same Run. Nothing recorded';
  ELSE
    PERFORM set_config('hub.backfill_mode', 'production', true);
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. The seven rollbacks, on production
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF current_setting('hub.backfill_mode') <> 'production' THEN
    RETURN;
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
-- 3. Record it
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261123T2005_production_rollbacks_of_23_november.sql',
    NULL,
    CASE current_setting('hub.backfill_mode')
      WHEN 'production' THEN 'Recorded production''s seven same-firm rollbacks of 23 November '
        || '(T1810, T1830 to T1835) from what survived: applied times at their precision, '
        || 'rollback times not captured, their order in words.'
      ELSE 'Nothing recorded: 20261123T1810 is applied here, so nothing was rolled back '
        || '(the 23 November rollbacks were on production).' END);
END $rec$;

COMMIT;

-- =============================================================================
-- Verification — run AFTER the file, as its own statement. One block, rolled
-- back by the closing RAISE. As postgres.
--
-- DO $$
-- DECLARE r text := ''; n int;
-- BEGIN
--   SELECT count(*) INTO n FROM schema_rollbacks WHERE recorded_how = 'backfill' AND filename LIKE '20261123T18%';
--   r := r || '1. 23 November rollbacks recorded here: ' || n
--          || CASE WHEN n = 0 THEN ' (1810 is in this ledger: '
--                  || EXISTS (SELECT 1 FROM schema_migrations WHERE filename LIKE '20261123T1810%') || ')'
--                  ELSE ': ' || (SELECT string_agg(left(filename, 13) || ' '
--                                   || to_char(applied_at AT TIME ZONE 'UTC', CASE applied_at_precision WHEN 'exact' THEN 'HH24:MI:SS.US' ELSE 'HH24:MI:SS' END)
--                                   || ' ' || applied_at_precision || ', ' || ran_len || ' chars, rolled back '
--                                   || COALESCE(rolled_back_at::text, 'not captured'), '; ' ORDER BY applied_at)
--                                FROM schema_rollbacks WHERE recorded_how = 'backfill' AND filename LIKE '20261123T18%') END
--          || chr(10) || '   (expect on production 7: T1810 18:13:26.142448 exact, 15903 chars; the six 18:47:54 to '
--          || '18:57:32 second; every rollback "not captured". On staging, or a build from main: 0, with 1810 in the ledger: true)' || chr(10);
--   r := r || '2. each carries its order and reason: '
--          || COALESCE((SELECT bool_and(rolled_back_order IS NOT NULL AND reason <> '') FROM schema_rollbacks
--                        WHERE recorded_how = 'backfill' AND filename LIKE '20261123T18%')::text, 'none here')
--          || '; any rollback time claimed: '
--          || (SELECT count(*) FROM schema_rollbacks WHERE recorded_how = 'backfill' AND filename LIKE '20261123T18%' AND rolled_back_at IS NOT NULL)
--          || '   (expect true, or none here; 0)' || chr(10);
--   RAISE EXCEPTION 'VERIFY 20261123T2005_production_rollbacks_of_23_november (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
