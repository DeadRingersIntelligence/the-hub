-- =============================================================================
-- 026_auth_identity.sql
-- The Hub — migration 26: link a login to a Hub identity, and let a browser
-- query through RLS without a trusted backend in front of it.
--
-- Two problems, in order of severity.
--
-- ONE — nothing links Supabase auth to `users`. The ids came from migration, so
-- they do not match auth uids, and the only shared field is email. Matching on
-- email fails the way everything else has failed in this build: an address
-- changes, the Hub identity detaches, nothing errors, the query returns zero
-- rows, and the cause is nowhere near the symptom.
--
-- TWO — the RLS helpers assume a trusted backend. They read `app.user_id` and
-- `app.is_internal`, set per request with SET LOCAL on a pooled connection.
-- A browser talking to PostgREST sets neither, both resolve null, and every
-- policy denies. Correct behaviour from a safe default, and useless to an app.
--
-- WHAT IS DELIBERATELY NOT CHANGED
--
-- `is_internal()` never falls back to auth. A browser session that could
-- resolve itself as internal would read cost events, rate cards and margin —
-- the tables whose only protection is that policy. It reads the session
-- variable, which no browser can set, then a column on the user's own row.
-- Nothing client-supplied reaches it.
--
-- Requires: 001 to 025
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- The link
--
-- A column rather than reassigning users.id, because the ids are referenced by
-- foreign keys across the schema and rewriting them is a migration with a blast
-- radius. Nullable: a person can exist in the Hub before they ever sign in, and
-- most people in `users` never will.
-- -----------------------------------------------------------------------------
ALTER TABLE users ADD COLUMN auth_user_id uuid;

CREATE UNIQUE INDEX users_auth_user_id_uq
  ON users (auth_user_id) WHERE auth_user_id IS NOT NULL;

COMMENT ON COLUMN users.auth_user_id IS
  'The Supabase auth uid for this person, once they have signed in. Null until '
  'then. This is the only link between a login and a Hub identity — never '
  'match on email, which detaches silently when an address changes.';

-- Staff flag. What makes a session internal, replacing the guess that a session
-- variable was set by someone entitled to set it.
ALTER TABLE users ADD COLUMN is_staff boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN users.is_staff IS
  'Dead Ringers staff. Grants internal access — cost, pricing, cross-tenant '
  'reads. Set deliberately, never from anything a client supplies.';

-- -----------------------------------------------------------------------------
-- Identity
--
-- Session variable first, so a backend holding a pooled connection keeps
-- working exactly as it does. Then auth.uid(), so a browser works too.
--
-- SECURITY DEFINER because the lookup reads `users`, which is itself protected
-- by a policy that calls this function. Without it the two deadlock into
-- infinite recursion.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION current_user_id()
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v uuid;
BEGIN
  v := NULLIF(current_setting('app.user_id', true), '')::uuid;
  IF v IS NOT NULL THEN RETURN v; END IF;

  BEGIN
    SELECT u.id INTO v FROM users u WHERE u.auth_user_id = auth.uid();
  EXCEPTION WHEN undefined_function THEN
    RETURN NULL;          -- no auth schema: a plain Postgres connection
  END;
  RETURN v;
END $$;

-- -----------------------------------------------------------------------------
-- Internal
--
-- The session variable, which no browser can set. Then the staff flag on the
-- person's own row. Nothing else, and in particular nothing the client sends.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION is_internal()
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v boolean;
BEGIN
  IF COALESCE(current_setting('app.is_internal', true), 'off') = 'on' THEN
    RETURN true;
  END IF;

  BEGIN
    SELECT u.is_staff INTO v FROM users u WHERE u.auth_user_id = auth.uid();
  EXCEPTION WHEN undefined_function THEN
    RETURN false;
  END;
  RETURN COALESCE(v, false);
END $$;

-- -----------------------------------------------------------------------------
-- The active organization
--
-- A user can hold scopes on several organizations — partners, and everyone at
-- Dead Ringers. auth.uid() alone therefore has no single answer, and a helper
-- that picked one would quietly show the wrong firm's data.
--
-- So the app names the organization, and the database verifies the claim. The
-- setter is the only way to set it, and it refuses an organization the user has
-- no scope on. Setting a variable directly is not a path into someone else's
-- data, because the reader checks the scope again on every call.
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
  RETURN p_org;
END $$;

-- The organization this session reads. Checks the scope every time rather than
-- trusting that whatever set the variable was entitled to.
CREATE OR REPLACE FUNCTION current_organization_id()
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_org uuid; v_user uuid;
BEGIN
  v_org := NULLIF(current_setting('app.organization_id', true), '')::uuid;
  v_user := current_user_id();

  -- A backend session with no signed-in user is the migration and service case:
  -- the variable is the answer, as it has always been.
  IF v_user IS NULL THEN RETURN v_org; END IF;

  IF v_org IS NOT NULL THEN
    IF is_internal() THEN RETURN v_org; END IF;
    IF EXISTS (SELECT 1 FROM user_scopes s
               WHERE s.user_id = v_user AND s.organization_id = v_org)
    THEN RETURN v_org;
    ELSE RETURN NULL;      -- claimed an organization they have no scope on
    END IF;
  END IF;

  -- Nothing named: fall back to their only organization, if they have exactly
  -- one. Several, and the app must choose — guessing would show the wrong firm.
  SELECT s.organization_id INTO v_org
  FROM user_scopes s WHERE s.user_id = v_user
  GROUP BY s.organization_id
  HAVING COUNT(*) OVER () = 1
  LIMIT 1;

  RETURN v_org;
END $$;

-- What a signed-in person may switch between.
CREATE OR REPLACE FUNCTION my_organizations()
RETURNS TABLE (organization_id uuid, code text, name text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT o.id, o.code, o.name
  FROM organizations o
  WHERE is_internal()
     OR EXISTS (SELECT 1 FROM user_scopes s
                WHERE s.user_id = current_user_id()
                  AND s.organization_id = o.id)
  ORDER BY o.name
$$;

-- -----------------------------------------------------------------------------
-- Claiming an identity at first sign-in
--
-- Matches on email once, then never again. After this the link is the uid, so
-- an email change is just an email change.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION claim_hub_identity()
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_auth uuid; v_email text; v_user uuid;
BEGIN
  v_auth := auth.uid();
  IF v_auth IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  SELECT id INTO v_user FROM users WHERE auth_user_id = v_auth;
  IF v_user IS NOT NULL THEN RETURN v_user; END IF;

  SELECT email INTO v_email FROM auth.users WHERE id = v_auth;
  IF v_email IS NULL THEN RAISE EXCEPTION 'no email on the auth user'; END IF;

  UPDATE users SET auth_user_id = v_auth, updated_at = now()
   WHERE lower(email) = lower(v_email) AND auth_user_id IS NULL
  RETURNING id INTO v_user;

  IF v_user IS NULL THEN
    RAISE EXCEPTION 'no unclaimed Hub user matches %', v_email;
  END IF;
  RETURN v_user;
END $$;

GRANT EXECUTE ON FUNCTION claim_hub_identity()            TO authenticated;
GRANT EXECUTE ON FUNCTION set_active_organization(uuid)   TO authenticated;
GRANT EXECUTE ON FUNCTION my_organizations()              TO authenticated;

COMMIT;

-- =============================================================================
-- Verification
--
-- 1. The helpers still work the old way for a backend session
--
--   SET app.is_internal = 'on';
--   SELECT is_internal();                       -- true
--   SELECT count(*) FROM organizations;         -- all of them
--
-- 2. A browser session resolves nothing until an identity is claimed
--
--   BEGIN;
--     SELECT set_config('app.is_internal', 'off', true);
--     SELECT set_config('app.user_id', '', true);
--     SET LOCAL ROLE authenticated;
--     SELECT current_user_id(), is_internal();  -- null, false
--   ROLLBACK;
--
-- 3. is_internal() cannot be reached from a client session
--
--   Confirm by reading the function: it consults the session variable, which
--   PostgREST cannot set, then users.is_staff. There is no third path.
--
-- 4. After the app signs in and calls claim_hub_identity(), a multi-org user
--    must name their organization:
--
--   SELECT * FROM my_organizations();
--   SELECT set_active_organization('<uuid from that list>');
--
--   And an organization they hold no scope on is refused:
--   SELECT set_active_organization(
--     (SELECT id FROM organizations WHERE code='DPX'));   -- expect: no access
--
-- 5. Re-run db/rls_isolation_test.sql. All six blocks should behave as before —
--    this migration adds a second way to resolve identity, it does not loosen
--    any policy.
-- =============================================================================
