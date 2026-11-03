-- =============================================================================
-- 20261103T1700_new_tables_are_read_only.sql
-- The Hub — a new table should not be writable by every signed-in user
-- because nobody said anything.
--
-- WHAT IS WRONG. The default privileges for tables in public grant
-- authenticated arwdxtm — INSERT, SELECT, UPDATE, DELETE, REFERENCES, TRIGGER
-- and MAINTAIN — on both databases. Every table created from now on is
-- writable by every signed-in user at every firm from the moment it exists,
-- and nobody has to do anything for that to happen. Not granting is what
-- causes it.
--
-- THIS IS NOT A HYPOTHETICAL AND IT HAS ALREADY COST SOMETHING. Finding 0 —
-- six reference tables writable by any signed-in person at any firm, including
-- the cross-client benchmark rows — was this default meeting a policy named
-- <t>_readable that was written FOR ALL because its author left the FOR clause
-- off. Two defaults, neither one examined, and the result sat on production for
-- a month. The policy half was fixed in 20261103T1000. This is the other half,
-- and it is the half that would have made the next one.
--
-- WHAT CHANGES. New tables in public created by postgres grant authenticated
-- SELECT and nothing else. A table that needs to be written through the API
-- says so in its own migration, in a GRANT a reviewer can see, next to the
-- policy that decides which rows.
--
-- WHAT DOES NOT CHANGE, and this is most of the schema:
--
--   EXISTING TABLES KEEP EVERY GRANT THEY HAVE. All 91 of them. Default
--   privileges apply at CREATE time and never retroactively, so nothing that
--   works today stops working — this file cannot break a running application,
--   only the next table somebody adds and forgets to grant on. Revisiting the
--   91 is a separate and much larger question, and the policy audit is what
--   makes it survivable in the meantime: 133 policies in public and, since
--   20261103T1000, none that admits anyone unconditionally.
--
--   SEQUENCES ARE LEFT ALONE. authenticated holds rU on production and rwU on
--   staging by default. A client that cannot INSERT has no use for nextval,
--   so the grant is inert rather than wrong, and tightening it belongs with
--   the service_role alignment where the whole sequence picture is in view.
--
--   anon IS ALREADY HANDLED by 20261103T1600 and is not mentioned here.
--
-- WHAT THIS CANNOT REACH, said plainly because the gap is real. ALTER DEFAULT
-- PRIVILEGES is per granting role. public also holds defaults belonging to
-- supabase_admin, which grant anon, authenticated and service_role full
-- access, and postgres is not a member of supabase_admin. A table created BY
-- supabase_admin — which is how some paths through the Supabase UI create
-- one — follows supabase_admin's default and arrives writable by everyone
-- signed in, exactly as before.
--
-- So this file makes the migration path safe by default and leaves the UI
-- path unchanged. That is worth having and is not the same as the problem
-- being closed. A table added through the dashboard still needs its grants
-- read afterwards, and the structural diff is what would show it.
--
-- Requires: 024 (the default being changed), 20261103T1200 (record_migration).
-- Safe to run twice.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. The default is the one this file expects to change
--
-- Three states: authenticated holds write privileges in postgres's table
-- default (not yet done), holds exactly SELECT (done), or holds some third
-- combination nobody here chose — which stops, because a default somebody has
-- already adjusted is one this file should not overwrite from a guess about
-- what they meant.
--
-- supabase_admin's defaults are accepted and named, as in 20261103T1600. Any
-- other granting role stops: a third set of defaults would be a thing nobody
-- has looked at.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_other text;
  v_privs text;
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

  IF to_regrole('supabase_admin') IS NOT NULL
     AND EXISTS (SELECT 1 FROM pg_default_acl d
                   JOIN pg_namespace n ON n.oid = d.defaclnamespace,
                        aclexplode(d.defaclacl) a
                  WHERE n.nspname = 'public'
                    AND d.defaclrole = to_regrole('supabase_admin')
                    AND d.defaclobjtype = 'r'
                    AND a.grantee = 'authenticated'::regrole
                    AND a.privilege_type IN ('INSERT','UPDATE','DELETE')) THEN
    RAISE NOTICE
      'supabase_admin''s table default still grants authenticated write access; out of postgres''s reach, so tables created BY supabase_admin are unaffected by this file';
  END IF;

  SELECT string_agg(DISTINCT a.privilege_type, ',' ORDER BY a.privilege_type)
    INTO v_privs
    FROM pg_default_acl d
    JOIN pg_namespace n ON n.oid = d.defaclnamespace,
         aclexplode(d.defaclacl) a
   WHERE n.nspname = 'public'
     AND d.defaclrole = 'postgres'::regrole
     AND d.defaclobjtype = 'r'
     AND a.grantee = 'authenticated'::regrole;

  IF v_privs IS NULL THEN
    RAISE NOTICE 'postgres''s table default grants authenticated nothing; this file will grant SELECT';
  ELSIF v_privs = 'SELECT' THEN
    RAISE NOTICE 'already SELECT only — this migration has run before';
  ELSIF v_privs = 'DELETE,INSERT,MAINTAIN,REFERENCES,SELECT,TRIGGER,UPDATE' THEN
    RAISE NOTICE 'found 024''s default (arwdxtm), as expected';
  ELSE
    RAISE EXCEPTION
      'postgres''s table default grants authenticated %, which is neither 024''s set nor this file''s; stop and look', v_privs
      USING HINT = 'Somebody has adjusted this default already. Find out what they wanted before replacing it.';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. SELECT and nothing else
--
-- REVOKE ALL then GRANT SELECT, rather than naming the six privileges to
-- remove. Naming them means this file knows the whole privilege list, and the
-- list has grown — MAINTAIN arrived in PostgreSQL 17 and is already in these
-- ACLs. A file that enumerates what to take away quietly keeps whatever gets
-- invented next; one that takes everything and gives back the single privilege
-- it means does not.
--
-- FOR ROLE postgres named explicitly. Without it this applies to whoever is
-- running, which is the same thing today and stops being the same thing the
-- first time somebody runs it as anyone else.
-- -----------------------------------------------------------------------------
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON TABLES FROM authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  GRANT SELECT ON TABLES TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. Record it
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM record_migration(
    '20261103T1700_new_tables_are_read_only.sql',
    NULL,
    'New tables created by postgres in public grant authenticated SELECT only. '
    'Existing tables are untouched; supabase_admin''s default is out of reach.');
END $$;

COMMIT;

-- =============================================================================
-- STILL TO DO
--
-- * A TABLE THAT NEEDS WRITING NOW NEEDS A VISIBLE GRANT. That is the point,
--   and it is also the way this file causes trouble: the next migration that
--   creates a writable table will look correct, pass review, and fail at
--   runtime with "permission denied", in the application rather than in the
--   migration. It belongs in db/README.md next to the record_migration rule —
--   a new table grants SELECT; anything more is written down.
--
-- * THE 91 EXISTING TABLES STILL CARRY 024's GRANTS, including INSERT, UPDATE
--   and DELETE for authenticated on every one of them. What stops that being
--   91 copies of finding 0 is the policies, and the policy audit says they
--   hold: no policy in public admits anyone unconditionally any more. Reducing
--   the grants to match what each table actually needs is worth doing and is a
--   long file with a real chance of breaking something, so it wants the
--   application's write paths enumerated first rather than a sweep.
--
-- * TABLES CREATED THROUGH THE SUPABASE UI are created by supabase_admin and
--   follow its default, not this one. Until that is dealt with, a new table
--   from the dashboard arrives writable by every signed-in user. The
--   structural diff is what would catch it, which is another reason to run
--   that on a schedule rather than on suspicion.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- It creates a table and reads its grants, because that is the only honest
-- test of a default: the catalogue entry says what was configured, and a real
-- CREATE TABLE says what happens.
--
-- DO $$
-- DECLARE r text := '';
-- BEGIN
--   r := r || 'postgres table default now grants authenticated: '
--          || COALESCE((SELECT string_agg(DISTINCT a.privilege_type, ',' ORDER BY a.privilege_type)
--                         FROM pg_default_acl d
--                         JOIN pg_namespace n ON n.oid = d.defaclnamespace,
--                              aclexplode(d.defaclacl) a
--                        WHERE n.nspname = 'public' AND d.defaclrole = 'postgres'::regrole
--                          AND d.defaclobjtype = 'r'
--                          AND a.grantee = 'authenticated'::regrole), 'NOTHING')
--          || '   (expect SELECT)' || chr(10);
--   r := r || 'and grants anon: '
--          || COALESCE((SELECT string_agg(DISTINCT a.privilege_type, ',' ORDER BY a.privilege_type)
--                         FROM pg_default_acl d
--                         JOIN pg_namespace n ON n.oid = d.defaclnamespace,
--                              aclexplode(d.defaclacl) a
--                        WHERE n.nspname = 'public' AND d.defaclrole = 'postgres'::regrole
--                          AND d.defaclobjtype = 'r'
--                          AND a.grantee = 'anon'::regrole), 'NOTHING')
--          || '   (expect NOTHING — 20261103T1600''s doing, checked here '
--          || 'because this file rewrites the same ACL and must not undo it)'
--          || chr(10);
--
--   -- The real test.
--   CREATE TABLE zzz_default_probe (id integer);
--   r := r || 'a brand new table grants authenticated: '
--          || COALESCE((SELECT string_agg(DISTINCT a.privilege_type, ',' ORDER BY a.privilege_type)
--                         FROM pg_class c, aclexplode(c.relacl) a
--                        WHERE c.oid = 'public.zzz_default_probe'::regclass
--                          AND a.grantee = 'authenticated'::regrole), 'NOTHING')
--          || '   (expect SELECT — under 024''s default this read '
--          || 'DELETE,INSERT,MAINTAIN,REFERENCES,SELECT,TRIGGER,UPDATE)' || chr(10);
--   r := r || 'and grants anon / service_role: '
--          || COALESCE((SELECT string_agg(DISTINCT a.privilege_type, ',' ORDER BY a.privilege_type)
--                         FROM pg_class c, aclexplode(c.relacl) a
--                        WHERE c.oid = 'public.zzz_default_probe'::regclass
--                          AND a.grantee = 'anon'::regrole), 'NOTHING')
--          || ' / '
--          || COALESCE((SELECT string_agg(DISTINCT a.privilege_type, ',' ORDER BY a.privilege_type)
--                         FROM pg_class c, aclexplode(c.relacl) a
--                        WHERE c.oid = 'public.zzz_default_probe'::regclass
--                          AND a.grantee = 'service_role'::regrole), 'NOTHING')
--          || '   (expect NOTHING for anon; service_role is untouched by this '
--          || 'file and differs between the databases until it is aligned)'
--          || chr(10);
--   DROP TABLE zzz_default_probe;
--
--   -- Nothing that exists today lost anything.
--   r := r || 'existing tables authenticated can SELECT / UPDATE: '
--          || (SELECT count(*) FROM pg_class c
--                JOIN pg_namespace n ON n.oid = c.relnamespace
--               WHERE n.nspname = 'public' AND c.relkind IN ('r','p')
--                 AND has_table_privilege('authenticated', c.oid, 'SELECT'))
--          || ' / '
--          || (SELECT count(*) FROM pg_class c
--                JOIN pg_namespace n ON n.oid = c.relnamespace
--               WHERE n.nspname = 'public' AND c.relkind IN ('r','p')
--                 AND has_table_privilege('authenticated', c.oid, 'UPDATE'))
--          || '   (expect both unchanged from before this ran — a default is '
--          || 'not retroactive, and if the second number moved, something in '
--          || 'this file did more than it says)' || chr(10);
--   r := r || 'the six reference tables authenticated can UPDATE: '
--          || (SELECT count(*) FROM unnest(ARRAY[
--                'behavior_answers','behaviors','rubric_sections',
--                'rubric_templates','scoring_model_versions','benchmark_snapshots']) t
--               WHERE has_table_privilege('authenticated', 'public.' || t, 'UPDATE'))
--          || '   (expect 0 — still 20261103T1000''s doing)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261103T1700_new_tables_are_read_only (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
