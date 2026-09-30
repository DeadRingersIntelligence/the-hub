-- =============================================================================
-- 024_rls_write_policies_and_grants.sql
-- The Hub — migration 24: make row-level security actually work for the app.
--
-- Two defects, both invisible from the SQL Editor.
--
-- ONE — every policy in migrations 001 to 023 was written with USING only.
-- In Postgres, USING decides which rows you can SEE; WITH CHECK decides which
-- rows you can WRITE. A policy with no WITH CHECK denies every insert and
-- update. Nothing caught it because the editor connects as a role with
-- rolbypassrls, which skips policies entirely — so the application would have
-- been able to read everything and write nothing, on day one of building
-- screens.
--
-- TWO — tables created through SQL carry no grants for Supabase's `anon` and
-- `authenticated` roles. RLS filters rows; GRANT decides whether the role may
-- touch the table at all. Without both, the app gets "permission denied".
--
-- Consequence worth stating: every isolation check run in the editor before
-- this migration passed for the wrong reason. The test at the bottom is the
-- first real one.
--
-- Requires: 001 to 023
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Give every existing policy a WITH CHECK matching its USING clause
--
-- Reading and writing are governed by the same rule throughout: you may write
-- a row you would be allowed to see. Done programmatically so no policy is
-- missed, and so a policy added later that already has WITH CHECK is left
-- alone.
-- -----------------------------------------------------------------------------
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT schemaname, tablename, policyname, qual
    FROM pg_policies
    WHERE schemaname = 'public'
      AND with_check IS NULL
      AND qual IS NOT NULL
  LOOP
    EXECUTE format('ALTER POLICY %I ON %I.%I WITH CHECK (%s)',
                   r.policyname, r.schemaname, r.tablename, r.qual);
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- Grants
--
-- RLS decides WHICH ROWS. Grants decide whether the role may touch the table
-- at all. Both are required.
--
-- `authenticated` is a signed-in user of the app. `anon` gets nothing — no
-- part of this data is public, and an unauthenticated reader has no business
-- reaching client call recordings or family information.
-- -----------------------------------------------------------------------------
GRANT USAGE ON SCHEMA public TO authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE
  ON ALL TABLES IN SCHEMA public TO authenticated;

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated;

-- Anything created later inherits the same treatment, so a future migration
-- cannot silently ship a table the app cannot reach.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT EXECUTE ON FUNCTIONS TO authenticated;

-- -----------------------------------------------------------------------------
-- Force RLS on every table
--
-- By default a table's OWNER is exempt from its own policies. The application
-- does not connect as the owner, so this changes nothing for it — but it means
-- a migration or a maintenance session cannot quietly read across tenants
-- while believing the policies are being applied.
-- -----------------------------------------------------------------------------
DO $$
DECLARE t RECORD;
BEGIN
  FOR t IN
    SELECT c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity
  LOOP
    EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY', t.relname);
  END LOOP;
END $$;

COMMIT;

-- =============================================================================
-- The first real isolation test
--
-- SET LOCAL ROLE drops out of the superuser for the duration of a transaction,
-- so policies actually apply. This is the only way to test RLS from the SQL
-- Editor — every check run before this migration passed because the editor
-- role carries rolbypassrls, not because the policies worked.
--
-- Run each block on its own.
--
-- 1. A client session sees only its own rows
--
--   BEGIN;
--     SELECT set_config('app.organization_id',
--       (SELECT id::text FROM organizations WHERE code='ALT'), true);
--     SELECT set_config('app.is_internal', 'off', true);
--     SET LOCAL ROLE authenticated;
--     SELECT
--       (SELECT count(*) FROM organizations) AS orgs,        -- expect 1
--       (SELECT count(*) FROM cost_events)   AS costs,       -- expect 0, internal only
--       (SELECT count(DISTINCT organization_id) FROM interactions) AS orgs_seen; -- expect 1
--   ROLLBACK;
--
-- 2. A session that sets nothing sees nothing
--
--   BEGIN;
--     SELECT set_config('app.organization_id', '', true);
--     SELECT set_config('app.is_internal', 'off', true);
--     SET LOCAL ROLE authenticated;
--     SELECT count(*) FROM interactions;                     -- expect 0
--   ROLLBACK;
--
-- 3. Writing across tenants is refused
--
--   BEGIN;
--     SELECT set_config('app.organization_id',
--       (SELECT id::text FROM organizations WHERE code='ALT'), true);
--     SELECT set_config('app.is_internal', 'off', true);
--     SET LOCAL ROLE authenticated;
--     INSERT INTO contacts (organization_id, full_name)
--     SELECT id, 'Should not land' FROM organizations WHERE code='DPX';
--   ROLLBACK;
--   -- expect: new row violates row-level security policy for table "contacts"
--
-- 4. And a client CAN write its own rows — the WITH CHECK fix
--
--   BEGIN;
--     SELECT set_config('app.organization_id',
--       (SELECT id::text FROM organizations WHERE code='ALT'), true);
--     SELECT set_config('app.is_internal', 'off', true);
--     SET LOCAL ROLE authenticated;
--     INSERT INTO contacts (organization_id, full_name)
--     SELECT id, 'Test Contact' FROM organizations WHERE code='ALT';
--     SELECT count(*) FROM contacts WHERE full_name = 'Test Contact';  -- expect 1
--   ROLLBACK;
-- =============================================================================
