-- =============================================================================
-- 20261103T1300_backfill_applied_migrations.sql
-- The Hub — the eleven timestamped migrations, recorded after the fact.
--
-- WHAT THIS IS. 20261103T1200 created a ledger that starts empty, because a
-- ledger that guesses is worse than one that starts honest. This file fills in
-- the one window where we are not guessing: the eleven timestamped migrations
-- on main, each applied to both databases between 30 October and 3 November,
-- each with a main-branch sha256 and an object or function body left behind on
-- both databases to show for it.
--
-- WHY IT IS ALL ELEVEN OR NONE. A partial backfill is worse than an empty
-- table. The ledger's comment excuses an absent row only for files older than
-- today — so a reader finding 2200 present and 1800 absent, both from the same
-- week, would conclude 1800 never ran. Four of eleven was the shape first
-- proposed and it is the shape that would have done the damage.
--
-- 050_hand_links.sql and 20261030T1730 are deliberately absent. 050 was
-- annotated in this window, not run; T1730 never reached main.
--
-- WHAT THESE ROWS DO NOT CLAIM, which is as much as what they do.
--
--   ran_md5 and ran_len are NULL. Nothing recorded the submitted text at the
--   time, and inventing one now would make a backfilled row indistinguishable
--   from a self-recorded one — defeating the only check the column is for.
--
--   first_applied_at and applied_at are NULL. We know each file ran in this
--   window; we do not know when, and the ledger did not exist to watch. A
--   plausible timestamp is still a made-up timestamp.
--
--   sha256 IS MAIN'S FILE, NOT WHAT RAN. Seven of the eleven were annotated
--   after they ran — header notes recording the apply, a corrected comment —
--   which changes the file hash and not a byte of what the database did. For
--   those, sha256 identifies the file in the repository and nothing more. This
--   is exactly the case the ledger's ran_md5 comment warns about, arriving in
--   its first eleven rows.
--
-- So every one of these rows says: this file is on main, it ran on both
-- databases in this window, here is the evidence, and here is what we cannot
-- tell you. A row with four NULLs is the table's own way of saying it was
-- written by someone looking backwards.
--
-- Requires: 20261103T1200 (schema_migrations, record_migration, nullable
--           timestamps). Refuses to run without it rather than creating rows
--           in a table of the wrong shape.
-- Safe to run twice: ON CONFLICT DO NOTHING, so a file that has since recorded
--           itself for real keeps its own row and is not overwritten by this
--           weaker one.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. The ledger is there, and is the shape this file needs
--
-- The nullable check is the one that matters: against the first form of
-- 20261103T1200, first_applied_at was NOT NULL and every insert below would
-- fail — or worse, would have been "fixed" by filling in now(), which is the
-- made-up timestamp this file exists to avoid.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('public.schema_migrations') IS NULL THEN
    RAISE EXCEPTION 'schema_migrations does not exist; run 20261103T1200 first';
  END IF;
  IF (SELECT count(*) FROM pg_attribute
       WHERE attrelid = 'public.schema_migrations'::regclass
         AND attname IN ('first_applied_at', 'applied_at')
         AND NOT attnotnull) <> 2 THEN
    RAISE EXCEPTION
      'first_applied_at and applied_at are not both nullable; this database has '
      'the first form of 20261103T1200. Apply the current one before this file.'
      USING HINT = 'A backfilled row must be able to say it does not know when.';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. The eleven
--
-- Written as one INSERT rather than eleven record_migration() calls on
-- purpose: record_migration always stamps the run columns with the current
-- submission, which is the correct behaviour for a file recording itself and
-- the wrong one here. These rows must carry nothing about a run.
--
-- The evidence in each note is what today's catalogue snapshots found on BOTH
-- databases — the object or function body that file left behind. It is the
-- reason the row exists, kept beside the row rather than in a commit message.
-- -----------------------------------------------------------------------------
INSERT INTO schema_migrations
       (filename, sha256, first_applied_at, applied_at, applied_by,
        ran_md5, ran_len, note)
VALUES
  ('20261030T1500_one_number_rule.sql',
   '96a583389198a3b352b23b0a544421ba0e34be6896bd5e8a3bde5660e535a861',
   NULL, NULL, 'postgres', NULL, NULL,
   'Backfilled 2026-11-03. Ran on BOTH databases; evidence: is_e164 and '
   'require_e164 present on both. Annotated after running, so sha256 is '
   'main''s file and not the text that was submitted.'),

  ('20261030T1930_case_converted_notification.sql',
   '7a50f2de4c9cdcd364971a05a91d738c33d3a84800848780f866b0e6216f3792',
   NULL, NULL, 'postgres', NULL, NULL,
   'Backfilled 2026-11-03. Ran on BOTH databases; evidence: notifications '
   'table present on both. Its case_converted_notify body has since been '
   'replaced by 20261102T1600, so the body hash no longer identifies it.'),

  ('20261030T2100_case_statuses.sql',
   'dc91429e0a6079ba73927d6c983f54dd98b177495daefc059ea2b9a55a42dc2b',
   NULL, NULL, 'postgres', NULL, NULL,
   'Backfilled 2026-11-03. Ran on BOTH databases; evidence: set_case_status '
   'and cases.served_on present on both.'),

  ('20261102T1500_wrap_up_require_e164.sql',
   '9bc22e802b625fbb3a76bb46607be40ff8e61cb539071f032639acf61ab92eb5',
   NULL, NULL, 'postgres', NULL, NULL,
   'Backfilled 2026-11-03. Ran on BOTH databases; evidence: save_wrap_up body '
   'md5 8b375d22 on both. Annotated after running (an in-place comment fix), '
   'so sha256 is main''s file and not the text that was submitted.'),

  ('20261102T1600_notification_cannot_stop_a_conversion.sql',
   '85ae249fb6ef0534fdab48e18baab8e7070ce4055214ce8f66478ed393e3452b',
   NULL, NULL, 'postgres', NULL, NULL,
   'Backfilled 2026-11-03. Ran on BOTH databases; evidence: '
   'case_converted_notify body md5 1fe7e035 on both. Annotated after running, '
   'so sha256 is main''s file and not the text that was submitted.'),

  ('20261102T1800_ingest_keeps_the_number.sql',
   '952ecb52aba68305bdb544dc60a35590f6ceb3af50ffb1b4bcbf5771e1d6a822',
   NULL, NULL, 'postgres', NULL, NULL,
   'Backfilled 2026-11-03. Ran on BOTH databases; evidence: ingest_call_event '
   'body md5 9b0ed30c on both. Annotated after running (a scoped count '
   'correction), so sha256 is main''s file and not what was submitted.'),

  ('20261102T2000_routing_and_notify_number_checks.sql',
   'f96c6a0062520921a1178ea1f123a8dc0378c13f14ccc3850e9a1335925b15e4',
   NULL, NULL, 'postgres', NULL, NULL,
   'Backfilled 2026-11-03. Ran on BOTH databases; evidence: '
   'routing_schedules_e164_ck and users_notify_sms_e164_ck present on both.'),

  ('20261102T2200_merge_chains.sql',
   'cd4b112eeed2c85984db55e746e082480baad3462acea75a96a1f168caa2b4a3',
   NULL, NULL, 'postgres', NULL, NULL,
   'Backfilled 2026-11-03. Ran on BOTH databases; evidence: '
   'merged_into_points_at_a_survivor body 6beb5711 and merge_contacts body '
   '16177d5f on both. Annotated after running.'),

  ('20261102T2330_notify_sms_confirmation.sql',
   '63cc499b81ae9b19cd8eb3d95ea0959cc89959bf7cf3912b7b10c34a2601f1e5',
   NULL, NULL, 'postgres', NULL, NULL,
   'Backfilled 2026-11-03. Ran on BOTH databases; evidence: '
   'notify_sms_challenges table present on both. Annotated after running.'),

  ('20261102T2345_notify_sms_send_limits.sql',
   '6c08812271c6cf9237ea3259c6f1b7e637a7b7653cfabc5bcedda1a0f37e81f7',
   NULL, NULL, 'postgres', NULL, NULL,
   'Backfilled 2026-11-03. Ran on BOTH databases; evidence: '
   'request_notify_sms_confirmation body 4182e729 and confirm_notify_sms body '
   'a9317184 on both. Annotated after running.'),

  ('20261103T1000_rubric_and_benchmarks_read_only.sql',
   '6792d16557627af6326484fd7b6ef707c4e644946912903bed17267b9a0dd4d5',
   NULL, NULL, 'postgres', NULL, NULL,
   'Backfilled 2026-11-03. Ran on BOTH databases; evidence: <t>_read and '
   '<t>_write policies on all six reference tables, policy digest 6e054bf7 on '
   'both. Annotated after running, so sha256 is main''s file — in this case '
   'the annotation IS the APPLIED note, added after the apply it records.')

ON CONFLICT (filename) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 3. This file records itself, the normal way
--
-- It is the first file to follow the new rule, and unlike its eleven rows it
-- has a real submission to fingerprint.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM record_migration(
    '20261103T1300_backfill_applied_migrations.sql',
    NULL,
    'Backfill of the eleven timestamped migrations applied 30 Oct – 3 Nov. '
    'Their rows carry NULL for every run column; this row does not, because '
    'this file actually ran here. File hash passed by the applier if at all.');
END $$;

COMMIT;

-- =============================================================================
-- STILL TO DO
--
-- * 001–058 ARE STILL ABSENT AND SHOULD STAY ABSENT. For those we have objects
--   and no provenance: which file created a given function, and whether the
--   file on main today is the one that did, is not answerable from the
--   catalogue. The 003 case proves the point — staging's people_org_name_uq
--   shows that an older 003 ran there, and no inference from the objects alone
--   would have told us which.
--
-- * THE ROWS HERE ARE A FLOOR, NOT A CEILING. "Ran on both databases" is what
--   the evidence supports. Whether a file ran once or three times, and whether
--   the text submitted matched the file then on main, these rows cannot say
--   and should never be read as saying.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- DO $$
-- DECLARE
--   r text := ''; n int;
-- BEGIN
--   SELECT count(*) INTO n FROM schema_migrations WHERE ran_md5 IS NULL;
--   r := r || 'backfilled rows (null fingerprint): ' || n || '   (expect 11)' || chr(10);
--
--   SELECT count(*) INTO n FROM schema_migrations
--    WHERE ran_md5 IS NULL
--      AND (first_applied_at IS NOT NULL OR applied_at IS NOT NULL
--           OR ran_len IS NOT NULL);
--   r := r || 'backfilled rows claiming anything about a run: ' || n
--          || '   (expect 0 — a default that fired would show here)' || chr(10);
--
--   SELECT count(*) INTO n FROM schema_migrations WHERE ran_md5 IS NOT NULL;
--   r := r || 'self-recorded rows: ' || n
--          || '   (expect 2 — the ledger and this file)' || chr(10);
--
--   r := r || 'every backfilled row carries a sha256: '
--          || (SELECT (count(*) = 0)::text FROM schema_migrations
--               WHERE ran_md5 IS NULL AND sha256 IS NULL)
--          || '   (expect true)' || chr(10);
--   r := r || 'every backfilled row says where it came from: '
--          || (SELECT (count(*) = 0)::text FROM schema_migrations
--               WHERE ran_md5 IS NULL AND note NOT LIKE 'Backfilled%')
--          || '   (expect true — a row without its provenance is the thing '
--          || 'this file was written to avoid)' || chr(10);
--
--   -- Running it twice must not disturb a row that has since recorded itself.
--   UPDATE schema_migrations
--      SET ran_md5 = 'pretend-self-recorded', ran_len = 999
--    WHERE filename = '20261102T2200_merge_chains.sql';
--   INSERT INTO schema_migrations (filename, sha256, note)
--   VALUES ('20261102T2200_merge_chains.sql', 'zzz', 'second backfill attempt')
--   ON CONFLICT (filename) DO NOTHING;
--   r := r || 'a re-run leaves a self-recorded row alone: '
--          || (SELECT (ran_md5 = 'pretend-self-recorded' AND sha256 <> 'zzz')::text
--                FROM schema_migrations WHERE filename = '20261102T2200_merge_chains.sql')
--          || '   (expect true)' || chr(10);
--
--   r := r || chr(10) || 'the ledger as it now reads:' || chr(10);
--   FOR n IN 1..1 LOOP
--     r := r || COALESCE((
--            SELECT string_agg(
--                     '    ' || rpad(filename, 56)
--                     || CASE WHEN ran_md5 IS NULL THEN 'backfilled'
--                             ELSE 'self-recorded, ran_len ' || ran_len END,
--                     chr(10) ORDER BY filename)
--              FROM schema_migrations), '    NONE') || chr(10);
--   END LOOP;
--
--   RAISE EXCEPTION 'VERIFY 20261103T1300_backfill_applied_migrations (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
