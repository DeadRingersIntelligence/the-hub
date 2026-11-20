-- =============================================================================
-- 20261120T1500_cases_is_a_capability.sql
-- The Hub — capability gains 'cases'.
--
-- WHY. Planning, 20 November: cases become a per-firm capability. An
-- answering service doesn't run cases in the Hub; its cases, if any, live in
-- its own case-management system. So "does this firm have cases" has to be
-- stored per firm, not assumed. 20261120T1510 builds the rule on this value:
-- creating and linking cases is refused when it's off, the app hides the
-- feature, and existing rows stay readable.
--
-- This file ONLY adds the value. ALTER TYPE … ADD VALUE can't be used in the
-- transaction that adds it, and the ledger keeps one row per filename, so
-- anything that writes or compares 'cases' goes in T1510 (db/README.md, "split
-- such files").
--
-- WHAT ELSE READS capability, checked 20 Nov across both repositories:
--
--   * has_capability(org, cap) (002): compares the value it's given, so it's
--     unaffected. T1510 rewrites it to call the single date predicate.
--   * organization_capabilities.capability: no row says 'cases' until T1510
--     backfills.
--   * hellophone: no reference to capabilities on main.
--   * Nothing iterates over enum_range(NULL::capability).
--
-- Appended last, so nothing that sorts or compares the existing twelve moves.
--
-- NOT A WRITE PATH. Since 20261120T1400, only Dead Ringers writes
-- organization_capabilities. Adding a value gives no firm a way to turn it on.
--
-- Safe to run twice: IF NOT EXISTS, and the ledger row is refreshed.
--
-- Requires: 002 (capability), 20261103T1200 (record_migration),
--           20261120T1400 (only Dead Ringers writes capabilities).
-- =============================================================================

BEGIN;

ALTER TYPE capability ADD VALUE IF NOT EXISTS 'cases';

-- The type had no comment. It gets one here, where a reader of the schema
-- meets it. Naming 'cases' in a comment isn't using it.
COMMENT ON TYPE capability IS
  'What a firm has bought, one organization_capabilities row per capability, '
  'set only by Dead Ringers (20261120T1400). cases: the Hub''s own case '
  'records — creating, linking, the cases screens and Reports '
  '(20261120T1500). Off for an answering service by default, whose cases '
  'live in its own system. When off, existing case rows stay readable; '
  'nothing new is created or linked.';

DO $rec$
BEGIN
  PERFORM record_migration(
    '20261120T1500_cases_is_a_capability.sql',
    NULL,
    'capability gains cases, appended. Its own file: ADD VALUE cannot be used '
    'in the transaction that adds it. 20261120T1510 builds the rule on it. '
    'The type gets its first comment.');
END $rec$;

COMMIT;

-- =============================================================================
-- Verification — run AFTER the file, as its own statement: the new value is
-- usable once the transaction above has committed. Changes nothing; ends in a
-- RAISE so the editor shows its output.
--
-- DO $$
-- DECLARE r text := '';
-- BEGIN
--   r := r || '1. capability, in order: '
--          || (SELECT string_agg(e.enumlabel, ', ' ORDER BY e.enumsortorder)
--                FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
--               WHERE t.typname = 'capability')
--          || chr(10) || '   (expect phone, recording, attribution, texting, '
--          || 'evaluations, ftc_audit, shops, coaching, training, cxpertise, '
--          || 'directory, internal_chat, cases: appended last)' || chr(10);
--   r := r || '2. organization_capabilities rows for cases: '
--          || (SELECT count(*) FROM organization_capabilities WHERE capability = 'cases')
--          || '   (expect 0: the backfill is T1510)' || chr(10);
--   r := r || '3. the type carries its comment: '
--          || (obj_description('capability'::regtype, 'pg_type') LIKE '%cases: the Hub''s own case records%')
--          || '   (expect true)' || chr(10);
--   r := r || '4. the ledger row: '
--          || (SELECT count(*) FROM schema_migrations
--               WHERE filename = '20261120T1500_cases_is_a_capability.sql')
--          || '   (expect 1)' || chr(10);
--   RAISE EXCEPTION 'VERIFY 20261120T1500_cases_is_a_capability %', chr(10) || r;
-- END $$;
-- =============================================================================
