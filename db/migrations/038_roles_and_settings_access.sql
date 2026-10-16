-- =============================================================================
-- 038_roles_and_settings_access.sql
-- The Hub — migration 38: who may change settings, and who may see the team.
--
-- ONE — a firm owner cannot see their own staff. The policies on `users` and
-- `user_scopes` resolve to the caller's own row, which was right while only
-- Dead Ringers staff signed in and is wrong the moment a firm does.
--
-- TWO — settings writes are enforced in the UI and nowhere else. The decision
-- was manager and above. A professional's session can write the tables
-- directly, and nothing underneath would stop it.
--
-- THREE — two holes found while checking the draft against the live schema,
-- both open today on every database:
--   * user_scopes_self lets a user INSERT a scope for themselves — at any
--     organization, with any role. One API call makes a professional an owner
--     at another firm.
--   * users_self lets a user UPDATE their own row, is_internal included. One
--     API call makes anyone Dead Ringers staff.
-- And `authenticated` and `anon` hold TRUNCATE on every public table. TRUNCATE
-- ignores RLS entirely, so the hole is the grant, not any one table.
--
-- HOW THIS DIFFERS FROM THE DRAFT, AND WHY
--   * Existing policies are dropped by their real names, and the migration
--     refuses to run if a table carries any policy it doesn't expect. The draft
--     dropped by pattern (<table>_tenant); tags_visible and
--     picklist_items_visible didn't match, survived, and — policies being
--     OR'd — kept every write open.
--   * One policy per command, not one FOR ALL. DELETE is checked against USING
--     only, so a FOR ALL policy whose USING doesn't test the role lets anyone
--     delete — including a shared default every client depends on.
--   * Each table's read rule is carried over exactly as it is (read from
--     pg_policy), so this changes who may write and nothing about who may read.
--   * notification_preferences is left alone: it has no organization_id, and
--     preferences are each person's own, not a settings action.
--   * rate_cards is left alone: it is internal-only, and adding a firm-readable
--     policy beside that one would have opened it.
--   * Roles ignore revoked scopes. The draft's current_view_profile() counted
--     a revoked owner as an owner.
--   * is_internal and the sign-in link are guarded by a trigger with no
--     exemption by role or definer context; see section 5.
--
-- THE SHAPE: one helper the policies call, can_manage_settings(), not a role
-- check repeated per table.
--
-- Requires: 001 to 037
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. What the caller is, here
--
-- A role is per organization — an owner at their own firm may be a
-- professional elsewhere — so this answers for the organization in scope.
-- SECURITY DEFINER because it reads user_scopes, whose policies call it.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION current_view_profile()
RETURNS view_profile LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public AS $$
DECLARE v view_profile; v_user uuid; v_org uuid;
BEGIN
  IF is_internal() THEN RETURN 'internal'::view_profile; END IF;

  v_user := current_user_id();
  v_org  := current_organization_id();
  IF v_user IS NULL OR v_org IS NULL THEN RETURN NULL; END IF;

  SELECT s.view_profile INTO v
  FROM user_scopes s
  WHERE s.user_id = v_user
    AND s.organization_id = v_org
    AND s.revoked_on IS NULL
  ORDER BY CASE s.view_profile
             WHEN 'owner' THEN 1 WHEN 'manager' THEN 2 ELSE 3 END
  LIMIT 1;

  RETURN v;
END $$;

COMMENT ON FUNCTION current_view_profile() IS
  'The caller''s role in the organization currently in scope, ignoring revoked '
  'scopes. Takes the strongest role when a user holds more than one.';

-- Manager and above: owner, manager, internal.
CREATE OR REPLACE FUNCTION can_manage_settings()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public AS $$
  SELECT COALESCE(current_view_profile() IN ('internal', 'owner', 'manager'), false)
$$;

COMMENT ON FUNCTION can_manage_settings() IS
  'Manager and above. Every settings write policy calls this, so the rule '
  'lives once. Never repeat the role test in a policy.';

-- -----------------------------------------------------------------------------
-- 2. Seeing the team
--
-- A definer function rather than a policy joining user_scopes, because a
-- policy on users that reads user_scopes, whose own policy reads users,
-- recurses.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION can_see_user(p_user uuid)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_me uuid; v_org uuid;
BEGIN
  IF is_internal() THEN RETURN true; END IF;

  v_me := current_user_id();
  IF v_me IS NULL THEN RETURN false; END IF;
  IF v_me = p_user THEN RETURN true; END IF;     -- always your own row

  v_org := current_organization_id();
  IF v_org IS NULL THEN RETURN false; END IF;

  -- Anyone with a live scope at the same organization is a colleague. Not
  -- restricted to managers: a professional needs the directory to transfer a
  -- call, and a team list is not sensitive within a firm.
  RETURN EXISTS (SELECT 1 FROM user_scopes s
                  WHERE s.user_id = p_user
                    AND s.organization_id = v_org
                    AND s.revoked_on IS NULL);
END $$;

REVOKE ALL ON FUNCTION current_view_profile() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION can_manage_settings()  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION can_see_user(uuid)     FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION current_view_profile() TO authenticated;
GRANT EXECUTE ON FUNCTION can_manage_settings()  TO authenticated;
GRANT EXECUTE ON FUNCTION can_see_user(uuid)     TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. Refuse to run on a schema this wasn't written against
--
-- Every table below must carry exactly the one policy named here. A second
-- permissive policy nobody listed would be OR'd with the new ones and quietly
-- reopen the writes — which is precisely how the draft failed.
-- -----------------------------------------------------------------------------
DO $$
DECLARE spec text[]; n int; found text;
BEGIN
  FOREACH spec SLICE 1 IN ARRAY ARRAY[
    ['users',                    'users_self'],
    ['user_scopes',              'user_scopes_self'],
    ['tags',                     'tags_visible'],
    ['picklist_items',           'picklist_items_visible'],
    ['picklist_item_hidden',     'picklist_item_hidden_tenant'],
    ['auto_tag_rules',           'auto_tag_rules_tenant'],
    ['custom_field_definitions', 'custom_field_definitions_tenant'],
    ['response_policies',        'response_policies_tenant'],
    ['routing_schedules',        'routing_schedules_tenant'],
    ['answering_services',       'answering_services_tenant'],
    ['teams',                    'teams_tenant']
  ] LOOP
    SELECT count(*), string_agg(polname::text, ', ') INTO n, found
      FROM pg_policy WHERE polrelid = ('public.' || spec[1])::regclass;
    IF n <> 1 OR found <> spec[2] THEN
      RAISE EXCEPTION '%: expected exactly the policy %, found % (%). Stop and look before changing it.',
        spec[1], spec[2], coalesce(found, 'none'), n;
    END IF;
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- 4. Settings tables: read as today, written by manager and above
--
-- Four policies per table, one per command. A shared default (null
-- organization) can be written only by internal, because the write rule
-- requires the caller's own organization.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  spec text[]; v_using text;
  w constant text :=
    '(is_internal() OR (can_manage_settings() AND organization_id = current_organization_id()))';
BEGIN
  FOREACH spec SLICE 1 IN ARRAY ARRAY[
    ['tags',                     'tags_visible'],
    ['picklist_items',           'picklist_items_visible'],
    ['picklist_item_hidden',     'picklist_item_hidden_tenant'],
    ['auto_tag_rules',           'auto_tag_rules_tenant'],
    ['custom_field_definitions', 'custom_field_definitions_tenant'],
    ['response_policies',        'response_policies_tenant'],
    ['routing_schedules',        'routing_schedules_tenant'],
    ['answering_services',       'answering_services_tenant'],
    ['teams',                    'teams_tenant']
  ] LOOP
    SELECT pg_get_expr(polqual, polrelid) INTO v_using
      FROM pg_policy
     WHERE polrelid = ('public.' || spec[1])::regclass AND polname = spec[2];

    EXECUTE format('DROP POLICY %I ON %I', spec[2], spec[1]);
    EXECUTE format('CREATE POLICY %I ON %I FOR SELECT USING (%s)',
                   spec[1] || '_read', spec[1], v_using);
    EXECUTE format('CREATE POLICY %I ON %I FOR INSERT WITH CHECK %s',
                   spec[1] || '_insert', spec[1], w);
    EXECUTE format('CREATE POLICY %I ON %I FOR UPDATE USING %s WITH CHECK %s',
                   spec[1] || '_update', spec[1], w, w);
    EXECUTE format('CREATE POLICY %I ON %I FOR DELETE USING %s',
                   spec[1] || '_delete', spec[1], w);
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- 5. users
--
-- Read: yourself and your colleagues. Change: your own row, or a colleague's
-- if you manage settings. Create and delete: internal only for now — the
-- invitation flow will decide how a firm adds someone, and it should be
-- written when that is designed rather than guessed at here.
-- -----------------------------------------------------------------------------
DROP POLICY users_self ON users;

CREATE POLICY users_read ON users FOR SELECT
  USING (can_see_user(id));
CREATE POLICY users_insert ON users FOR INSERT
  WITH CHECK (is_internal());
CREATE POLICY users_update ON users FOR UPDATE
  USING      (is_internal() OR id = current_user_id() OR (can_manage_settings() AND can_see_user(id)))
  WITH CHECK (is_internal() OR id = current_user_id() OR (can_manage_settings() AND can_see_user(id)));
CREATE POLICY users_delete ON users FOR DELETE
  USING (is_internal());

-- A policy decides which rows may change, not which columns. These two must
-- not change from a client session at all, so a trigger refuses them by value:
-- a policy can be satisfied by a row that looks ordinary while is_internal
-- flips underneath it.
--
-- No exemption by role or by "inside a definer function": a definer function
-- runs as its owner, so an exemption of that kind would hand every future
-- definer function the right to rewrite these columns for free. Instead:
--
--   is_internal  changes only when the caller is internal — Dead Ringers staff,
--                or a migration or seed that has SET app.is_internal = 'on'.
--   auth_user_id changes only as the one transition claim_hub_identity()
--                makes: an unclaimed row (null link) becoming linked to the
--                signed-in auth user, on the row whose email is that auth
--                user's email, with the email itself unchanged. Whatever path
--                makes exactly that change is making a claim; nothing else may
--                touch the link.
CREATE OR REPLACE FUNCTION users_guard_privileged() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_auth uuid; v_email text;
BEGIN
  IF is_internal() THEN RETURN NEW; END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.is_internal THEN
      RAISE EXCEPTION 'only Dead Ringers can create an internal user';
    END IF;
    IF NEW.auth_user_id IS NOT NULL THEN
      RAISE EXCEPTION 'a new user starts unclaimed; claim_hub_identity() links them';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.is_internal IS DISTINCT FROM OLD.is_internal THEN
    RAISE EXCEPTION 'only Dead Ringers can change who is internal';
  END IF;

  IF NEW.auth_user_id IS DISTINCT FROM OLD.auth_user_id THEN
    v_auth := auth.uid();
    -- The same source claim_hub_identity() matches on. A client session can't
    -- read auth.users, so a direct attempt lands here and is refused below.
    BEGIN
      SELECT email INTO v_email FROM auth.users WHERE id = v_auth;
    EXCEPTION WHEN insufficient_privilege THEN
      v_email := NULL;
    END;

    IF NOT (OLD.auth_user_id IS NULL
            AND v_auth IS NOT NULL
            AND NEW.auth_user_id = v_auth
            AND v_email IS NOT NULL
            AND lower(OLD.email) = lower(v_email)
            AND NEW.email = OLD.email) THEN
      RAISE EXCEPTION 'the sign-in link is set by claim_hub_identity(), not edited';
    END IF;
  END IF;

  RETURN NEW;
END $$;

CREATE TRIGGER users_guard_privileged_t BEFORE INSERT OR UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION users_guard_privileged();

-- -----------------------------------------------------------------------------
-- 6. user_scopes
--
-- Read: your own scopes, and every scope at the organization in scope — not a
-- colleague's scopes at other firms, which are those firms' business.
--
-- Write: internal, or a settings manager acting on the organization in scope.
-- A manager grants organization scopes only, never internal or partner ones,
-- and only roles a firm holds. Only an owner grants or changes an owner, so a
-- manager can neither promote themselves nor demote the owner.
-- -----------------------------------------------------------------------------
DROP POLICY user_scopes_self ON user_scopes;

CREATE POLICY user_scopes_read ON user_scopes FOR SELECT
  USING (is_internal()
         OR user_id = current_user_id()
         OR organization_id = current_organization_id());

CREATE POLICY user_scopes_insert ON user_scopes FOR INSERT
  WITH CHECK (is_internal() OR (
    can_manage_settings()
    AND scope_type = 'organization'
    AND organization_id = current_organization_id()
    AND (view_profile IN ('manager', 'professional')
         OR (view_profile = 'owner' AND current_view_profile() = 'owner'))));

CREATE POLICY user_scopes_update ON user_scopes FOR UPDATE
  USING (is_internal() OR (
    can_manage_settings()
    AND organization_id = current_organization_id()
    AND (view_profile <> 'owner' OR current_view_profile() = 'owner')))
  WITH CHECK (is_internal() OR (
    can_manage_settings()
    AND scope_type = 'organization'
    AND organization_id = current_organization_id()
    AND (view_profile IN ('manager', 'professional')
         OR (view_profile = 'owner' AND current_view_profile() = 'owner'))));

CREATE POLICY user_scopes_delete ON user_scopes FOR DELETE
  USING (is_internal() OR (
    can_manage_settings()
    AND organization_id = current_organization_id()
    AND (view_profile <> 'owner' OR current_view_profile() = 'owner')));

-- -----------------------------------------------------------------------------
-- 7. TRUNCATE
--
-- From every table, not only these: it ignores RLS everywhere. Supabase's
-- default grants hand it to the client roles on each new table, so the default
-- is changed too, for tables postgres creates — which is every migration here.
-- -----------------------------------------------------------------------------
REVOKE TRUNCATE ON ALL TABLES IN SCHEMA public FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE TRUNCATE ON TABLES FROM anon, authenticated;

COMMIT;

-- =============================================================================
-- Verification. Every block that changes anything runs inside a transaction
-- and rolls back.
--
-- 1. Nothing definer is open to anon, and no client role can TRUNCATE
--
--   SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--   WHERE n.nspname = 'public' AND p.prosecdef
--     AND has_function_privilege('anon', p.oid, 'EXECUTE');
--   -- expect: no rows
--
--   SELECT count(*) FROM information_schema.role_table_grants
--   WHERE table_schema = 'public' AND grantee IN ('anon', 'authenticated')
--     AND privilege_type = 'TRUNCATE';
--   -- expect: 0
--
-- 2. Each settings table has its four policies and nothing else
--
--   SELECT c.relname, string_agg(p.polname::text || ':' || p.polcmd::text, ', ' ORDER BY p.polname)
--   FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
--   WHERE c.relname IN ('tags','picklist_items','picklist_item_hidden','auto_tag_rules',
--     'custom_field_definitions','response_policies','routing_schedules',
--     'answering_services','teams','users','user_scopes')
--   GROUP BY 1 ORDER BY 1;
--   -- expect: <t>_delete:d, <t>_insert:a, <t>_read:r, <t>_update:w on each
--
-- 3. A professional reads settings and cannot write them, or grant themselves
--    anything, or make themselves internal
--
--   BEGIN;
--     SELECT set_config('app.is_internal', 'off', true);
--     SELECT set_config('app.user_id', s.user_id::text, true),
--            set_config('app.organization_id', s.organization_id::text, true)
--     FROM user_scopes s
--     WHERE s.scope_type = 'organization' AND s.view_profile = 'professional'
--       AND s.revoked_on IS NULL
--     LIMIT 1;
--     SET LOCAL ROLE authenticated;
--
--     SELECT current_view_profile(), can_manage_settings();  -- professional, false
--     SELECT count(*) FROM tags;                             -- reads: 9 or more
--
--     SAVEPOINT a;
--     INSERT INTO tags (organization_id, code, label, tag_kind)
--     VALUES (current_setting('app.organization_id')::uuid, 'test_tag', 'Test', 'caller_type');
--     -- expect: new row violates row-level security policy
--     ROLLBACK TO a;
--
--     SAVEPOINT b;
--     INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id)
--     SELECT current_user_id(), 'organization', 'owner', id
--     FROM organizations WHERE id <> current_organization_id() LIMIT 1;
--     -- expect: new row violates row-level security policy
--     ROLLBACK TO b;
--
--     SAVEPOINT c;
--     UPDATE users SET is_internal = true WHERE id = current_user_id();
--     -- expect: only Dead Ringers can change who is internal
--     ROLLBACK TO c;
--
--     SAVEPOINT d;
--     DELETE FROM tags WHERE organization_id IS NULL;
--     SELECT count(*) FROM tags WHERE organization_id IS NULL;
--     -- expect: still 9 (the delete matched nothing it may delete)
--     ROLLBACK TO d;
--
--     SAVEPOINT e;
--     UPDATE users SET auth_user_id = gen_random_uuid() WHERE id = current_user_id();
--     -- expect: the sign-in link is set by claim_hub_identity(), not edited
--     ROLLBACK TO e;
--   ROLLBACK;
--
-- 4. An owner sees their colleagues and can manage settings
--
--   BEGIN;
--     UPDATE user_scopes SET view_profile = 'owner'
--     WHERE id = (SELECT id FROM user_scopes WHERE scope_type = 'organization'
--                   AND view_profile = 'professional' AND revoked_on IS NULL LIMIT 1)
--     RETURNING set_config('app.user_id', user_id::text, true),
--               set_config('app.organization_id', organization_id::text, true);
--     SELECT set_config('app.is_internal', 'off', true);
--     SET LOCAL ROLE authenticated;
--
--     SELECT current_view_profile(), can_manage_settings();  -- owner, true
--     SELECT count(*) FROM users;                            -- every colleague, not 1
--   ROLLBACK;
-- =============================================================================
