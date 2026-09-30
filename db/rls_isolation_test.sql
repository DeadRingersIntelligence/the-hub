-- =============================================================================
-- rls_isolation_test.sql
-- Run this after any migration that adds a table or a policy.
--
-- WHY IT LOOKS ODD. Policies cannot be tested from the Supabase SQL Editor
-- directly: that connection carries `rolbypassrls`, so policies are skipped
-- entirely and every check passes whether or not it should. Every isolation
-- check run before 30 September 2026 passed for that reason, not because the
-- policies worked.
--
-- `SET LOCAL ROLE authenticated` drops out of the superuser for the duration
-- of a transaction, which is the only way to exercise the real rules here.
--
-- Run each block separately. Every one ends in ROLLBACK, so nothing is saved.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. A client session sees only its own rows
--    expect: orgs = 1, costs = 0, orgs_seen = 1
-- -----------------------------------------------------------------------------
BEGIN;
  SELECT set_config('app.organization_id',
    (SELECT id::text FROM organizations WHERE code='ALT'), true);
  SELECT set_config('app.is_internal', 'off', true);
  SET LOCAL ROLE authenticated;

  SELECT current_user,
         is_internal()                                             AS internal,
         (SELECT count(*) FROM organizations)                      AS orgs,
         (SELECT count(*) FROM cost_events)                        AS costs,
         (SELECT count(DISTINCT organization_id) FROM interactions) AS orgs_seen;
ROLLBACK;


-- -----------------------------------------------------------------------------
-- 2. A session that sets nothing sees nothing
--    expect: 0
--
--    This is the safe default: a forgotten SET returns an empty result rather
--    than leaking across tenants.
-- -----------------------------------------------------------------------------
BEGIN;
  SELECT set_config('app.organization_id', '', true);
  SELECT set_config('app.is_internal', 'off', true);
  SET LOCAL ROLE authenticated;

  SELECT count(*) AS interactions_visible FROM interactions;
ROLLBACK;


-- -----------------------------------------------------------------------------
-- 3. Writing into another firm is refused
--    expect: ERROR — new row violates row-level security policy for table "contacts"
--
--    The other firm's id is captured BEFORE dropping to `authenticated`. An
--    INSERT … SELECT whose source row is invisible to the session inserts
--    nothing and reports success — which looks like a pass and proves nothing.
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_other uuid;
BEGIN
  SELECT id INTO v_other FROM organizations WHERE code='DPX';

  PERFORM set_config('app.organization_id',
    (SELECT id::text FROM organizations WHERE code='ALT'), true);
  PERFORM set_config('app.is_internal', 'off', true);
  SET LOCAL ROLE authenticated;

  INSERT INTO contacts (organization_id, full_name)
  VALUES (v_other, 'Should not land');
END $$;


-- -----------------------------------------------------------------------------
-- 4. A client CAN write its own rows
--    expect: inserted = 1
--
--    This is what migration 024 fixed. Before it, every policy had USING and
--    no WITH CHECK, so the application could read everything and write nothing.
-- -----------------------------------------------------------------------------
BEGIN;
  SELECT set_config('app.organization_id',
    (SELECT id::text FROM organizations WHERE code='ALT'), true);
  SELECT set_config('app.is_internal', 'off', true);
  SET LOCAL ROLE authenticated;

  INSERT INTO contacts (organization_id, full_name)
  SELECT id, 'RLS test contact' FROM organizations WHERE code='ALT';

  SELECT count(*) AS inserted FROM contacts WHERE full_name = 'RLS test contact';
ROLLBACK;


-- -----------------------------------------------------------------------------
-- 5. Every table with RLS enabled has a policy, and every policy can write
--    expect: no rows
--
--    A table with RLS on and no policy is invisible to the application. A
--    policy with no WITH CHECK denies every insert. Both fail silently in the
--    editor and loudly in production.
-- -----------------------------------------------------------------------------
SELECT c.relname AS table_name,
       CASE WHEN p.polname IS NULL THEN 'RLS on, no policy'
            ELSE 'policy has no WITH CHECK' END AS problem
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_policy p ON p.polrelid = c.oid
WHERE n.nspname = 'public'
  AND c.relkind = 'r'
  AND c.relrowsecurity
  AND (p.polname IS NULL OR p.polwithcheck IS NULL)
ORDER BY 1;


-- -----------------------------------------------------------------------------
-- 6. Every table the app touches is granted to `authenticated`
--    expect: no rows
--
--    RLS decides which rows. GRANT decides whether the role may touch the
--    table at all. Without both, the app gets "permission denied" however
--    correct the policy is.
-- -----------------------------------------------------------------------------
SELECT c.relname AS table_name, 'not granted to authenticated' AS problem
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relkind = 'r'
  AND NOT has_table_privilege('authenticated', c.oid, 'SELECT')
ORDER BY 1;
