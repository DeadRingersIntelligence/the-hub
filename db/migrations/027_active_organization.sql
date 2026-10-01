-- =============================================================================
-- 027_active_organization.sql
-- The Hub — migration 27: make the active organization survive the pool.
--
-- `set_active_organization()` writes a session variable with set_config, which
-- lives on a connection. That is fine for a backend holding one, and wrong for
-- PostgREST, where the session resets between requests — so a user who picked
-- an organization would be asked again on the next page load.
--
-- WHO THIS ACTUALLY AFFECTS. Nobody today. Single-org users never call the
-- setter, because current_organization_id() falls through to their only
-- organization. Internal users pass through is_internal(). What is left is a
-- non-internal user holding scopes on two or more organizations — a partner, or
-- someone working for two separate firms. Rare now, inevitable later.
--
-- Worth closing early because of how it would present: "the app keeps
-- forgetting which firm I'm looking at" sounds like a front-end bug, and
-- nothing about it points at connection pooling.
--
-- Requires: 001 to 026
-- =============================================================================

BEGIN;

ALTER TABLE users
  ADD COLUMN active_organization_id uuid REFERENCES organizations(id) ON DELETE SET NULL;

COMMENT ON COLUMN users.active_organization_id IS
  'Which organization this user is currently looking at, for users who hold '
  'scopes on more than one. Read only when the session variable is absent, so '
  'a backend that sets the variable per request is unaffected. Null for the '
  'single-org users who never need to choose.';

-- -----------------------------------------------------------------------------
-- Setting it
--
-- Writes both: the variable, so the rest of this request is already correct
-- without a re-read, and the column, so the next request remembers.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_active_organization(p_org uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_user uuid;
BEGIN
  v_user := current_user_id();
  IF v_user IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM user_scopes s
    WHERE s.user_id = v_user AND s.organization_id = p_org)
     AND NOT is_internal()
  THEN RAISE EXCEPTION 'no access to that organization';
  END IF;

  PERFORM set_config('app.organization_id', p_org::text, false);

  UPDATE users SET active_organization_id = p_org, updated_at = now()
   WHERE id = v_user;

  RETURN p_org;
END $$;

-- -----------------------------------------------------------------------------
-- Reading it
--
-- Order matters, and each step earns its place:
--
--   1. the session variable      — a backend setting it per request
--   2. their only organization   — the common case, never asks anyone to choose
--   3. the stored column         — what they last picked, re-verified
--
-- The column is checked against user_scopes on every read, exactly as the
-- variable is, so a scope removed after someone picked an organization stops
-- resolving immediately rather than at their next sign-in.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION current_organization_id()
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_org uuid; v_user uuid; v_count integer;
BEGIN
  v_org := NULLIF(current_setting('app.organization_id', true), '')::uuid;
  v_user := current_user_id();

  -- No signed-in user: a migration or service session. The variable is the
  -- answer, as it always has been.
  IF v_user IS NULL THEN RETURN v_org; END IF;

  -- 1. Named for this request.
  IF v_org IS NOT NULL THEN
    IF is_internal() THEN RETURN v_org; END IF;
    IF EXISTS (SELECT 1 FROM user_scopes s
               WHERE s.user_id = v_user AND s.organization_id = v_org)
    THEN RETURN v_org;
    ELSE RETURN NULL;
    END IF;
  END IF;

  -- 2. Exactly one organization: never make them choose.
  SELECT COUNT(DISTINCT s.organization_id) INTO v_count
    FROM user_scopes s WHERE s.user_id = v_user;

  IF v_count = 1 THEN
    SELECT DISTINCT s.organization_id INTO v_org
      FROM user_scopes s WHERE s.user_id = v_user;
    RETURN v_org;
  END IF;

  -- 3. What they last picked — re-verified, because a scope can be revoked
  --    between choosing and reading.
  SELECT u.active_organization_id INTO v_org FROM users u WHERE u.id = v_user;
  IF v_org IS NULL THEN RETURN NULL; END IF;

  IF is_internal() THEN RETURN v_org; END IF;
  IF EXISTS (SELECT 1 FROM user_scopes s
             WHERE s.user_id = v_user AND s.organization_id = v_org)
  THEN RETURN v_org;
  END IF;

  RETURN NULL;   -- held a scope when they picked it, and no longer does
END $$;

COMMIT;

-- =============================================================================
-- Verification
--
--   SET app.is_internal = 'on';
--
--   -- the column exists and starts empty
--   SELECT count(*) AS users, count(active_organization_id) AS with_active
--   FROM users;
--
--   -- a backend session is unaffected: the variable still wins
--   SELECT set_config('app.organization_id',
--     (SELECT id::text FROM organizations WHERE code='ALT'), false);
--   SELECT current_organization_id() = (SELECT id FROM organizations WHERE code='ALT');
--
--   -- an organization the user holds no scope on is still refused
--   SELECT set_active_organization(
--     (SELECT id FROM organizations WHERE code='DPX'));
--   -- internal sessions pass; test this one as a real client session once the
--   -- app can sign in, where it should raise 'no access to that organization'
--
--   -- and nothing about tenant isolation moved
--   -- re-run db/rls_isolation_test.sql
-- =============================================================================
