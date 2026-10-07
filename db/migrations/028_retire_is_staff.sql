-- =============================================================================
-- 028_retire_is_staff.sql
-- The Hub — migration 28: one column for internal access, not two.
--
-- Migration 003 created `users.is_internal`. Migration 026 added
-- `users.is_staff` to do the same job, without checking, and pointed the
-- rewritten `is_internal()` function at the new one.
--
-- So the column that has existed since day one — and that is set on the rows
-- created back then — is ignored, while a column defaulting to false decides
-- who gets internal access. Nothing errors. Reads just return nothing, and the
-- cause is a column name away from the symptom.
--
-- This retires `is_staff`, carries any value it holds back onto `is_internal`,
-- and points the function at the original.
--
-- Safe: `is_staff` is referenced nowhere outside migration 026.
--
-- Requires: 001 to 027
-- =============================================================================

BEGIN;

-- Carry anything set on the newer column back, so nothing is lost if someone
-- has already been granted access through it.
UPDATE users SET is_internal = true WHERE is_staff AND NOT is_internal;

ALTER TABLE users DROP COLUMN is_staff;

COMMENT ON COLUMN users.is_internal IS
  'Dead Ringers staff. Grants internal access — cost, pricing, cross-tenant '
  'reads. The single source for is_internal(); set deliberately, never from '
  'anything a client supplies.';

-- -----------------------------------------------------------------------------
-- Read the original column
--
-- Unchanged in every other respect: the session variable first, which no
-- browser can set, then the flag on the person's own row. Still no third path,
-- and still nothing client-supplied.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION is_internal()
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v boolean;
BEGIN
  IF COALESCE(current_setting('app.is_internal', true), 'off') = 'on' THEN
    RETURN true;
  END IF;

  BEGIN
    SELECT u.is_internal INTO v FROM users u WHERE u.auth_user_id = auth.uid();
  EXCEPTION WHEN undefined_function THEN
    RETURN false;          -- no auth schema: a plain Postgres connection
  END;
  RETURN COALESCE(v, false);
END $$;

COMMIT;

-- =============================================================================
-- Verification
--
--   SET app.is_internal = 'on';
--
--   -- one column, and it is the original
--   SELECT column_name FROM information_schema.columns
--   WHERE table_name = 'users' AND column_name IN ('is_internal','is_staff');
--   -- expect: is_internal only
--
--   -- who holds internal access
--   SELECT email, full_name, is_internal, auth_user_id IS NOT NULL AS has_login
--   FROM users WHERE is_internal;
--
--   -- grant it where it is missing
--   UPDATE users SET is_internal = true
--   WHERE lower(email) = lower('mandie@deadringers.co');
--
--   -- and the link to a login, which is what the function matches on
--   SELECT email, auth_user_id FROM users
--   WHERE lower(email) = lower('mandie@deadringers.co');
--   -- null here means claim_hub_identity() has not been run from the app yet;
--   -- is_internal() cannot find the row without it
-- =============================================================================
