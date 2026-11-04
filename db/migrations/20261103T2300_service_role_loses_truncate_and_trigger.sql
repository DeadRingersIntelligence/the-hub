-- =============================================================================
-- 20261103T2300_service_role_loses_truncate_and_trigger.sql
-- The Hub — the server's key stops being able to empty a table or attach
-- code to one.
--
-- APPLIED ON STAGING AND PRODUCTION, 2026-11-03, block md5
-- d298c733cbcf8119a2b4a3f80d4c03f9, identical on both. service_role now holds
-- MAINTAIN and REFERENCES on 95 relations and nothing else; the table default
-- reads service_role=xm on both; the canary is 3.
--
-- THE TRIGGER PROBE IN THE VERIFICATION PROVED NOTHING, and is fixed in place
-- below. It ran the UPDATE as postgres, which owns the probe table — an owner
-- does not need TRIGGER, so the line printed true whether or not the revoke
-- had happened. A net with no hole in it, which is worse than no net: it was
-- the one line in the block that existed to answer the obvious worry about
-- revoking something called TRIGGER, and it answered it with a tautology.
--
-- It now grants the probe to authenticated, switches into that role, updates,
-- and switches back — which is how the staging experiment that established
-- this behaviour was run in the first place. The body is untouched and its
-- md5 is unchanged.
--
-- WHAT IT HOLDS. After 20261103T1800 aligned the two databases, service_role
-- holds no SELECT, INSERT, UPDATE or DELETE anywhere in public, nothing on
-- sequences, and EXECUTE on exactly three functions. What is left on relations
-- is TRUNCATE on 89 of 98, and REFERENCES, TRIGGER and MAINTAIN on 95. This
-- file removes TRUNCATE and TRIGGER and leaves the other two.
--
-- WHY THOSE TWO AND NOT THE OTHER TWO. service_role has BYPASSRLS, so nothing
-- it is granted is moderated by a policy: every grant applies to every row of
-- every firm at once, and grants are the whole of its access control.
--
--   TRUNCATE empties a table instantly, for every client, with no policy
--   consulted, no row-level trace and no undo.
--   TRIGGER lets the role attach a function that runs on every write to a
--   table. That is arguably worse than TRUNCATE, because it is invisible:
--   nothing about a table looks different until somebody reads its triggers.
--   REFERENCES lets another table point a foreign key at this one.
--   MAINTAIN is VACUUM and ANALYZE.
--
-- The last two cannot read or change a row. The first two are how a leaked
-- server key turns into lost or exfiltrated data, and neither is used.
--
-- NOTHING USES THEM, and this was checked in three places rather than assumed:
--
--   No function body in public mentions TRUNCATE, on either database.
--   the-hub has no reset or reload script, and db/seeds/ does not truncate.
--   hellophone, read across all thirteen branches rather than only main,
--   contains no TRUNCATE, no DELETE FROM, no CREATE TRIGGER and no
--   "supabase db reset". It has no supabase/ directory, no CI workflows and
--   no seed or fixture files. The service key appears in exactly one file —
--   src/app/api/webhooks/dialstack/route.ts — which calls ingest_call_event
--   and record_call_content and never touches a table directly. The app's own
--   row deletions go through the user's client as authenticated, with DELETE.
--
-- The all-branches part matters. A reset script is the kind of thing that
-- lives on a branch somebody never merged, and main alone would not have
-- settled it.
--
-- REVERSIBLE WITH ONE GRANT, and it changes nothing about how the product
-- behaves today. If something unknown did depend on either privilege, the
-- failure is a clear "permission denied" naming the table, not corrupted data.
--
-- THE DEFAULT GOES TOO, or the next CREATE TABLE hands both straight back and
-- the sweep below is undone by the first table somebody adds.
--
-- Requires: 024, 20261103T1800 (which left the shape this starts from),
--           20261103T1200 (record_migration).
-- Safe to run twice: everything here is a REVOKE.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. What is about to change, counted before it changes
--
-- No three-state check on the grants, for 20261103T1800's reason: this file
-- only revokes, so there is no state it could overwrite. What it does check is
-- that the three server functions are still callable, because the one way this
-- work can break the product is by taking a grant the webhook needs — and a
-- file that touches service_role should refuse to run if that has already
-- happened, rather than adding to the damage.
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_other text; v_trunc int; v_trig int; v_keep int;
BEGIN
  SELECT string_agg(DISTINCT d.defaclrole::regrole::text, ', ')
    INTO v_other
    FROM pg_default_acl d JOIN pg_namespace n ON n.oid = d.defaclnamespace
   WHERE n.nspname = 'public'
     AND d.defaclrole <> 'postgres'::regrole
     AND d.defaclrole IS DISTINCT FROM to_regrole('supabase_admin');
  IF v_other IS NOT NULL THEN
    RAISE EXCEPTION
      'public has default privileges set for role(s) %, which this file does not handle; stop and look', v_other
      USING HINT = 'ALTER DEFAULT PRIVILEGES is per granting role.';
  END IF;

  SELECT count(*) INTO v_keep
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname IN ('ingest_call_event', 'record_call_content',
                       'request_notify_sms_confirmation')
     AND has_function_privilege('service_role', p.oid, 'EXECUTE');
  IF v_keep <> 3 THEN
    RAISE EXCEPTION
      'service_role can execute % of the three server functions, not 3; stop and look', v_keep
      USING HINT = 'Something has already taken a grant the webhook needs. Fix that before removing more.';
  END IF;

  SELECT count(DISTINCT c.oid) FILTER (WHERE a.privilege_type = 'TRUNCATE'),
         count(DISTINCT c.oid) FILTER (WHERE a.privilege_type = 'TRIGGER')
    INTO v_trunc, v_trig
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace,
         aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) a
   WHERE n.nspname = 'public' AND c.relkind IN ('r','p','v','m','f')
     AND a.grantee = 'service_role'::regrole;

  RAISE NOTICE
    'to change: TRUNCATE on % relations, TRIGGER on %. Expected 89 and 95 on a database this has not run on.',
    v_trunc, v_trig;
END $$;

-- -----------------------------------------------------------------------------
-- 2. The default
--
-- service_role's table default is Dxtm. After this it is xm: REFERENCES and
-- MAINTAIN, which are the two that cannot reach a row.
--
-- Named privileges rather than REVOKE ALL and a re-grant, for the reason
-- 20261103T1800 gives — the re-grant would have to name MAINTAIN, a privilege
-- that did not exist before PostgreSQL 17 — and here the list to remove is the
-- exact pair this file is about, which is as clear as it gets.
-- -----------------------------------------------------------------------------
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE TRUNCATE, TRIGGER ON TABLES FROM service_role;

-- -----------------------------------------------------------------------------
-- 3. And what already exists
--
-- Explicit loop, as in 20261103T1600 and T1800: ALL TABLES is documented as
-- tables, views and foreign tables, and nothing here should depend on whether
-- it reaches materialized views.
--
-- Views and matviews are included in the loop even though TRUNCATE on them is
-- not a thing anybody uses. Revoking a privilege a relation cannot hold is a
-- no-op, and skipping them would mean this file's rule had an exception that
-- somebody would later have to rediscover.
-- -----------------------------------------------------------------------------
DO $$
DECLARE r record; v int := 0;
BEGIN
  FOR r IN
    SELECT n.nspname AS s, c.relname AS o
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relkind IN ('r','p','v','m','f')
       AND NOT EXISTS (SELECT 1 FROM pg_depend d
                        WHERE d.classid = 'pg_class'::regclass
                          AND d.objid = c.oid AND d.deptype = 'e')
  LOOP
    EXECUTE format('REVOKE TRUNCATE, TRIGGER ON TABLE %I.%I FROM service_role', r.s, r.o);
    v := v + 1;
  END LOOP;
  RAISE NOTICE 'swept % relations', v;
END $$;

-- -----------------------------------------------------------------------------
-- 4. Record it
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM record_migration(
    '20261103T2300_service_role_loses_truncate_and_trigger.sql',
    NULL,
    'service_role loses TRUNCATE and TRIGGER on every relation in public, and '
    'on new ones. REFERENCES and MAINTAIN stay. Nothing in the-hub or in any '
    'of hellophone''s thirteen branches used either.');
END $$;

COMMIT;

-- =============================================================================
-- STILL TO DO
--
-- * request_notify_sms_confirmation HAS NO CALLER IN THE APP, on any branch,
--   and keeps its service_role grant. That is expected rather than a loose
--   end: 20261102T2330 made it service_role-only by design, for a server-side
--   send path that does not exist yet — TEXTING_CONNECTED is false and there
--   is no Surge sender. The grant is ahead of its caller on purpose. It is
--   worth re-reading when that sender is built, and not before.
--
-- * SUPABASE IS RETIRING THE LEGACY anon AND service_role KEYS at the end of
--   2026. If production's SUPABASE_SERVICE_ROLE_KEY is still a legacy key, the
--   DialStack webhook stops working when they are switched off, and no
--   migration can see that or fix it. It is a Vercel environment-variable
--   question and it belongs to whoever owns that.
--
-- * THE PUBLIC SWEEP IS NEXT and is unaffected by this file. The three
--   functions service_role calls are not among the 68 and hold their own
--   grants.
--
-- * TABLES CREATED BY supabase_admin still grant service_role everything,
--   through that role's default privileges, which postgres cannot change. Same
--   limit as 1600, 1700, 1800 and 1900.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- DO $$
-- DECLARE r text := '';
-- BEGIN
--   -- THE CANARY FIRST. These three grants are the server's only permission on
--   -- the functions that record calls.
--   r := r || 'service_role EXECUTE on the three server functions: '
--          || (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--               WHERE n.nspname = 'public'
--                 AND p.proname IN ('ingest_call_event','record_call_content',
--                                   'request_notify_sms_confirmation')
--                 AND has_function_privilege('service_role', p.oid, 'EXECUTE'))
--          || '   (expect 3 — this file must not have touched them)' || chr(10);
--
--   r := r || 'relations where service_role holds TRUNCATE / TRIGGER: '
--          || (SELECT count(DISTINCT c.oid) FROM pg_class c
--                JOIN pg_namespace n ON n.oid = c.relnamespace,
--                     aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) a
--               WHERE n.nspname = 'public' AND c.relkind IN ('r','p','v','m','f')
--                 AND a.grantee = 'service_role'::regrole
--                 AND a.privilege_type = 'TRUNCATE')
--          || ' / '
--          || (SELECT count(DISTINCT c.oid) FROM pg_class c
--                JOIN pg_namespace n ON n.oid = c.relnamespace,
--                     aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) a
--               WHERE n.nspname = 'public' AND c.relkind IN ('r','p','v','m','f')
--                 AND a.grantee = 'service_role'::regrole
--                 AND a.privilege_type = 'TRIGGER')
--          || '   (expect 0 / 0. Was 89 / 95)' || chr(10);
--
--   r := r || 'and REFERENCES / MAINTAIN, which stay: '
--          || (SELECT count(DISTINCT c.oid) FROM pg_class c
--                JOIN pg_namespace n ON n.oid = c.relnamespace,
--                     aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) a
--               WHERE n.nspname = 'public' AND c.relkind IN ('r','p','v','m','f')
--                 AND a.grantee = 'service_role'::regrole
--                 AND a.privilege_type = 'REFERENCES')
--          || ' / '
--          || (SELECT count(DISTINCT c.oid) FROM pg_class c
--                JOIN pg_namespace n ON n.oid = c.relnamespace,
--                     aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) a
--               WHERE n.nspname = 'public' AND c.relkind IN ('r','p','v','m','f')
--                 AND a.grantee = 'service_role'::regrole
--                 AND a.privilege_type = 'MAINTAIN')
--          || '   (expect 95 / 95 — unchanged, and if either moved this file '
--          || 'revoked more than it says)' || chr(10);
--
--   r := r || 'service_role holds anything else on a relation: '
--          || (SELECT COALESCE(string_agg(DISTINCT a.privilege_type, ',' ORDER BY a.privilege_type), 'NOTHING')
--                FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace,
--                     aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) a
--               WHERE n.nspname = 'public' AND c.relkind IN ('r','p','v','m','f')
--                 AND a.grantee = 'service_role'::regrole)
--          || '   (expect MAINTAIN,REFERENCES and nothing more)' || chr(10);
--
--   r := r || 'the table default now grants service_role: '
--          || COALESCE((SELECT string_agg(DISTINCT a.privilege_type, ',' ORDER BY a.privilege_type)
--                         FROM pg_default_acl d
--                         JOIN pg_namespace n ON n.oid = d.defaclnamespace,
--                              aclexplode(d.defaclacl) a
--                        WHERE n.nspname = 'public' AND d.defaclrole = 'postgres'::regrole
--                          AND d.defaclobjtype = 'r'
--                          AND a.grantee = 'service_role'::regrole), 'NOTHING')
--          || '   (expect MAINTAIN,REFERENCES)' || chr(10);
--
--   -- The real test of a default: make something and read its grants.
--   CREATE TABLE zzz_truncate_probe (id integer);
--   r := r || 'a brand new table grants service_role: '
--          || COALESCE((SELECT string_agg(DISTINCT a.privilege_type, ',' ORDER BY a.privilege_type)
--                         FROM pg_class c, aclexplode(c.relacl) a
--                        WHERE c.oid = 'public.zzz_truncate_probe'::regclass
--                          AND a.grantee = 'service_role'::regrole), 'NOTHING')
--          || '   (expect MAINTAIN,REFERENCES — without this the sweep above '
--          || 'is undone by the next CREATE TABLE)' || chr(10);
--   r := r || 'and grants authenticated / anon: '
--          || COALESCE((SELECT string_agg(DISTINCT a.privilege_type, ',' ORDER BY a.privilege_type)
--                         FROM pg_class c, aclexplode(c.relacl) a
--                        WHERE c.oid = 'public.zzz_truncate_probe'::regclass
--                          AND a.grantee = 'authenticated'::regrole), 'NOTHING')
--          || ' / '
--          || COALESCE((SELECT string_agg(DISTINCT a.privilege_type, ',' ORDER BY a.privilege_type)
--                         FROM pg_class c, aclexplode(c.relacl) a
--                        WHERE c.oid = 'public.zzz_truncate_probe'::regclass
--                          AND a.grantee = 'anon'::regrole), 'NOTHING')
--          || '   (expect SELECT / NOTHING — 1700 and 1600''s doing, checked '
--          || 'here because this file rewrites the same ACL)' || chr(10);
--   DROP TABLE zzz_truncate_probe;
--
--   -- Triggers still fire for everyone, which is the thing somebody will
--   -- worry about after reading the word TRIGGER being revoked. The privilege
--   -- governs CREATE TRIGGER, not execution: PostgreSQL checks it when a
--   -- trigger is attached, never when one fires.
--   CREATE TABLE zzz_trigger_probe (id integer, updated_at timestamptz);
--   CREATE TRIGGER zzz_touch BEFORE UPDATE ON zzz_trigger_probe
--     FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
--   INSERT INTO zzz_trigger_probe (id) VALUES (1);
--   GRANT SELECT, UPDATE ON zzz_trigger_probe TO authenticated;
--
--   r := r || '    the probe grants authenticated TRIGGER: '
--          || has_table_privilege('authenticated', 'public.zzz_trigger_probe', 'TRIGGER')::text
--          || '   (expect false — nothing granted it, which is the point of '
--          || 'the next line)' || chr(10);
--
--   -- As authenticated, NOT as the owner. Run as postgres this test is a
--   -- tautology: an owner needs no TRIGGER privilege, so it would print true
--   -- however the revoke had gone. SET ROLE NONE is permitted to any role, so
--   -- unlike the role switches elsewhere in these files this one can go in the
--   -- middle of a block rather than at the end.
--   PERFORM set_config('role', 'authenticated', true);
--   UPDATE zzz_trigger_probe SET id = 1;
--   PERFORM set_config('role', 'none', true);
--
--   r := r || 'a trigger fires for a role holding no TRIGGER privilege: '
--          || (SELECT (updated_at IS NOT NULL)::text FROM zzz_trigger_probe WHERE id = 1)
--          || '   (expect true — TRIGGER governs attaching one, not running '
--          || 'one. PostgreSQL checks it at CREATE TRIGGER and never when one '
--          || 'fires, which is why revoking it from service_role costs nothing)'
--          || chr(10);
--   DROP TABLE zzz_trigger_probe;
--
--   RAISE EXCEPTION 'VERIFY 20261103T2300_service_role_loses_truncate_and_trigger (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
