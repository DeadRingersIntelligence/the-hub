-- =============================================================================
-- 20261119T1500_revenue_moved_event.sql
-- The Hub — a notification event for revenue moving on a case.
--
-- WHY A FILE OF ITS OWN. ALTER TYPE ... ADD VALUE cannot be used in the
-- transaction that adds it, and 20261119T1510 uses the value. The usual answer
-- is two blocks in one file, but schema_migrations keeps one row per filename
-- and each block's record_migration() overwrites the other's ran_md5, so a
-- two-block file records only its last block (db/README.md, "Two hashes").
-- Two files, two rows, each recording exactly what it ran.
--
-- WHAT THE VALUE MEANS. Managers are told when money moves on a case that has
-- already counted as revenue: a case marked lost after its service, or a
-- service date removed or changed. Planning session, 19 Nov: one event rather
-- than two, because to a manager they are the same event — money moved, and
-- here is the reason. The body says which action it was.
--
-- Safe to run twice: IF NOT EXISTS, and the ledger row is refreshed.
--
-- Requires: 019 (notification_event), 20261103T1200 (record_migration).
--
-- APPLIED to staging and production, 19 Nov 2026, from the file hashed
-- a66fb812. ran_md5 8f4f5db9cf5f6dee5f1086328b1c457b (1594 characters) on
-- both — the file's text exactly, less the final newline the editor drops.
-- This note was added afterwards, outside the body (db/README.md).
-- =============================================================================

BEGIN;

ALTER TYPE notification_event ADD VALUE IF NOT EXISTS 'case_revenue_moved';

DO $rec$
BEGIN
  PERFORM record_migration(
    '20261119T1500_revenue_moved_event.sql',
    NULL,
    'notification_event gains case_revenue_moved, for 20261119T1510. Its own '
    'file because ADD VALUE cannot be used in the transaction that adds it.');
END $rec$;

COMMIT;
