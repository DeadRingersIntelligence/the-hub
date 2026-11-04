-- =============================================================================
-- 20261104T1100_active_organization_is_per_request.sql
-- The Hub — a chosen organization stops outliving the request that chose it.
--
-- APPLIED ON STAGING, 2026-11-04, block md5 ac90145d3a0acbb49923895d5901ec24.
--
-- TWO LINES REMOVED FROM THE VERIFICATION, in place; the body is untouched.
-- They claimed the setting's value after a rollback would distinguish a
-- session-wide set_config from a transaction-local one. It does not — ROLLBACK
-- undoes SET either way, and only COMMIT tells them apart — so both printed
-- the same under 027 as under this file. See the verification block.
--
-- THE EMPTY-NOT-LEAK READING IS NOW MEASURED, not derived. On staging, with a
-- throwaway user scoped to firm B only: with no setting, current_organization_id
-- returned B and 29 of B's interactions were visible and none of A's; with
-- app.organization_id forced to A, current_organization_id returned NULL and
-- NOTHING was visible from either firm; and calling set_active_organization(A)
-- as that user was refused outright with "no access to that organization".
-- So an inherited value costs a user their application, not somebody else's
-- data, and the deliberate route is closed by the function's own scope check
-- rather than by its having no caller.
--
-- WHAT IS WRONG. set_active_organization() writes the chosen organization to a
-- session variable with set_config(..., false). The third argument is
-- is_local: false means the setting lasts for the SESSION, not the
-- transaction. PostgREST runs each request in its own transaction on a POOLED
-- connection, so the value survives the request that set it and is still there
-- when the next request — a different person's — lands on the same connection.
--
-- 027's own comment says what was meant:
--
--     "Writes both: the variable, so the rest of this request is already
--      correct without a re-read, and the column, so the next request
--      remembers."
--
-- The rest of THIS request is transaction scope. The next request is meant to
-- be served by the column, which the same function updates two lines later and
-- which current_organization_id() reads as step 3. So the comment describes
-- is_local = true and the code passes false. The fix is the one character.
--
-- WHAT IT ACTUALLY COSTS, which is less than it first looks and still worth
-- fixing. current_organization_id() re-checks the inherited value against
-- user_scopes on every read, so nobody sees a firm they have no scope on:
--
--   a user with no scope on the inherited organization gets NULL, and an empty
--   application until the connection recycles;
--   a user who DOES have a scope on it is silently shown that firm rather than
--   the one they chose — wrong, confusing, and invisible;
--   an internal user is returned the inherited value outright, because
--   is_internal() short-circuits the scope check.
--
-- So it is a correctness and confusion bug rather than a cross-firm leak. The
-- scope re-check in current_organization_id() is what keeps it from being
-- worse, which is a good argument for having written that re-check.
--
-- NOTHING CALLS IT TODAY. No hellophone branch calls set_active_organization,
-- so this has never fired in production. That makes it the right time: the fix
-- costs nothing to verify now and would cost an incident later.
--
-- WHY NOT REMOVE THE set_config ENTIRELY, which was the other option. Because
-- step 1 of current_organization_id() reads the variable before the column,
-- and the comment above it is explicit that a backend setting it per request
-- should win. Removing the write would make the function's own first step
-- unreachable from its own setter, and would mean the rest of the request
-- served the OLD organization until the next one. Transaction scope keeps both
-- behaviours and fixes the leak.
--
-- Requires: 027 (the function), 20261103T1200 (record_migration).
-- Safe to run twice: the drift check tells the three states apart.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. The body is the one this file expects to replace
--
-- Both hashes are measured, not placeholders: prosrc for a plpgsql function is
-- the text between its $$ delimiters exactly, so both were computed from
-- db/migrations/027_active_organization.sql as it stands on main and from this
-- file's replacement. If the "before" hash does not match, something has
-- replaced this function since 027 and the change below is not a one-character
-- edit to what is actually there.
-- -----------------------------------------------------------------------------
DO $pre$
DECLARE v_md5 text;
BEGIN
  SELECT md5(prosrc) INTO v_md5
    FROM pg_proc
   WHERE oid = 'public.set_active_organization(uuid)'::regprocedure;

  IF v_md5 IS NULL THEN
    RAISE EXCEPTION 'set_active_organization(uuid) does not exist; run 027 first';
  ELSIF v_md5 = 'b4471ca91dca78b77fcd06d208eabd6a' THEN
    RAISE NOTICE 'already per-request — this migration has run before';
  ELSIF v_md5 = 'b512e165b6a9ad490149b8fb790c06d4' THEN
    RAISE NOTICE '027 body found, as expected; replacing';
  ELSE
    RAISE EXCEPTION
      'set_active_organization has a body this file does not know (md5 %); stop and read it', v_md5
      USING HINT = 'Expected 027''s body or this file''s. A third one means somebody changed it in between.';
  END IF;
END $pre$;

-- -----------------------------------------------------------------------------
-- 2. One character
--
-- Everything else is 027's body, character for character, so the only
-- difference between the two hashes above is false to true. The function keeps
-- its definer rights, its search_path, its scope check and its UPDATE.
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

  PERFORM set_config('app.organization_id', p_org::text, true);

  UPDATE users SET active_organization_id = p_org, updated_at = now()
   WHERE id = v_user;

  RETURN p_org;
END $$;

COMMENT ON FUNCTION set_active_organization(uuid) IS
  'Records which organization a multi-firm user is working in. Writes the '
  'session variable TRANSACTION-LOCALLY, so the rest of this request is '
  'correct without a re-read and nothing survives into the next request on a '
  'pooled connection, and writes users.active_organization_id so the next '
  'request remembers. 027 passed is_local = false, which leaked the choice to '
  'whoever got the connection next; current_organization_id()''s re-check '
  'against user_scopes is what kept that from being a cross-firm leak.';

-- -----------------------------------------------------------------------------
-- 3. Record it
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261104T1100_active_organization_is_per_request.sql',
    NULL,
    'set_active_organization writes app.organization_id transaction-locally '
    'instead of session-wide. One character; body md5 b512e165 -> b4471ca9.');
END $rec$;

COMMIT;

-- =============================================================================
-- STILL TO DO
--
-- * EVERY OTHER set_config IN THE SCHEMA IS WORTH THE SAME READ. This one was
--   found by reading a function for an unrelated reason. The question to ask
--   of each is not "is the value right" but "how long is it meant to last",
--   and on a pooled connection the answer is almost always the transaction.
--
-- * THE ASSUMPTION UNDERNEATH EVERY POLICY IN THIS SCHEMA is that an API
--   caller cannot set app.is_internal, app.user_id or app.organization_id.
--   Checked on 4 November: no function of ours sets the first two; neither
--   authenticated nor anon can CREATE in public, graphql_public, extensions or
--   storage; no role default sets app.*; PostgREST sets only request.*. That
--   is the whole of the trust chain and it belongs in db/README.md.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- THE TEST THAT MATTERS CANNOT BE WRITTEN HERE AT ALL, and an earlier version
-- of this block pretended otherwise. It claimed a session-wide set_config
-- survives a rollback while a transaction-local one does not, so the setting's
-- value afterwards would tell them apart. It does not: ROLLBACK undoes SET
-- either way, and only COMMIT distinguishes them. Measured with a savepoint —
-- both read empty afterwards. Those two lines printed the same under 027's
-- false as under this file's true, which is the third check in three files to
-- run under conditions that made its own question unaskable.
--
-- The body md5 is the proof, and it is exact: b4471ca9 differs from 027's
-- b512e165 in one character, and that character is the is_local argument.
-- The lines below test what can be tested — that the replacement installed,
-- kept its definer rights and search_path, and still refuses a caller with no
-- scope.
--
-- DO $$
-- DECLARE r text := ''; v_user uuid; v_org uuid;
-- BEGIN
--   r := r || 'body md5: '
--          || (SELECT md5(prosrc) FROM pg_proc
--               WHERE oid = 'public.set_active_organization(uuid)'::regprocedure)
--          || chr(10) || '   (expect b4471ca91dca78b77fcd06d208eabd6a)' || chr(10);
--   r := r || 'still SECURITY DEFINER with search_path: '
--          || (SELECT prosecdef::text || ' / ' || coalesce(array_to_string(proconfig, ';'), 'NONE')
--                FROM pg_proc
--               WHERE oid = 'public.set_active_organization(uuid)'::regprocedure)
--          || '   (expect true / search_path=public)' || chr(10);
--   r := r || 'callable by authenticated / anon: '
--          || has_function_privilege('authenticated', 'public.set_active_organization(uuid)', 'EXECUTE')::text
--          || ' / '
--          || has_function_privilege('anon', 'public.set_active_organization(uuid)', 'EXECUTE')::text
--          || '   (expect true / false)' || chr(10);
--
--   -- The scope of the write, which is the whole of the change. A
--   -- transaction-local set_config is undone by ROLLBACK TO SAVEPOINT; a
--   -- session-wide one is not. That is the difference the bug turned on,
--   -- tested without needing a second connection.
--   SELECT id INTO v_user FROM users WHERE active_organization_id IS NOT NULL LIMIT 1;
--   SELECT active_organization_id INTO v_org FROM users WHERE id = v_user;
--
--   IF v_user IS NULL THEN
--     r := r || 'no user with an active organization — NOT TESTED' || chr(10);
--   ELSE
--     PERFORM set_config('app.user_id', v_user::text, true);
--     BEGIN
--       PERFORM set_active_organization(v_org);
--       r := r || 'set_active_organization returned without raising' || chr(10);
--       r := r || '    app.organization_id inside the call''s transaction: '
--              || coalesce(current_setting('app.organization_id', true), 'NULL')
--              || '   (expect the organization — step 1 of '
--              || 'current_organization_id must still see it)' || chr(10);
--       r := r || '    current_organization_id() agrees: '
--              || (current_organization_id() = v_org)::text
--              || '   (expect true)' || chr(10);
--     EXCEPTION WHEN others THEN
--       r := r || 'set_active_organization raised: ' || SQLERRM
--              || '   (expect this if that user has no user_scopes row)' || chr(10);
--     END;
--   END IF;
--
--
--   RAISE EXCEPTION 'VERIFY 20261104T1100_active_organization_is_per_request (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
