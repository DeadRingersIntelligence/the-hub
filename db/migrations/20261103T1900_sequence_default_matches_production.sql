-- =============================================================================
-- 20261103T1900_sequence_default_matches_production.sql
-- The Hub — the last unaligned default.
--
-- WHAT IS WRONG. postgres's default privileges for sequences in public grant
-- authenticated rwU on staging and rU on production — SELECT, UPDATE and USAGE
-- against SELECT and USAGE. The difference is one letter and it is UPDATE.
--
-- WHAT UPDATE ON A SEQUENCE MEANS, since it is not the obvious thing. It is
-- not permission to read or change any row of any table. USAGE already allows
-- nextval and currval, which is what an INSERT needs; UPDATE adds setval. So
-- a signed-in user on staging can wind a sequence backwards or forwards and
-- make the next insert collide with an existing id, or skip a range. It is a
-- way to corrupt an id series, not a way to see anything.
--
-- WHY FIX IT ANYWAY. Not because the risk is large — it is small, and nothing
-- in the product calls setval. Because it is the last place the two databases
-- disagree about who gets what, and a test environment that differs from the
-- live one in ways nobody has written down is how 014 went missing for a
-- month and how finding 0 sat on production. A difference that is understood
-- and recorded is fine. This one was neither until today.
--
-- WHAT IT TOUCHES. authenticated, and only on sequences, and only UPDATE.
-- SELECT and USAGE stay, because production holds them and an INSERT through
-- PostgREST into a table with an identity column needs USAGE to work. anon was
-- dealt with in 20261103T1600 and service_role in 20261103T1800; neither is
-- mentioned here.
--
-- ON PRODUCTION THIS SHOULD DO NOTHING, like 1800. The precondition counts the
-- change before making it so that can be seen rather than assumed.
--
-- Requires: 024, 20261103T1200 (record_migration).
-- Safe to run twice: it only revokes.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. What is about to change
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_other text; v_def int; v_seq int;
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

  SELECT count(*) INTO v_def
    FROM pg_default_acl d JOIN pg_namespace n ON n.oid = d.defaclnamespace,
         aclexplode(d.defaclacl) a
   WHERE n.nspname = 'public' AND d.defaclrole = 'postgres'::regrole
     AND d.defaclobjtype = 'S'
     AND a.grantee = 'authenticated'::regrole
     AND a.privilege_type = 'UPDATE';

  SELECT count(DISTINCT c.oid) INTO v_seq
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace,
         aclexplode(COALESCE(c.relacl, acldefault('S', c.relowner))) a
   WHERE n.nspname = 'public' AND c.relkind = 'S'
     AND a.grantee = 'authenticated'::regrole
     AND a.privilege_type = 'UPDATE';

  RAISE NOTICE
    'to change: % default entr(y/ies) and % existing sequence(s). On production both should be 0.',
    v_def, v_seq;
END $$;

-- -----------------------------------------------------------------------------
-- 2. The default, and the sequences that already exist
--
-- Only UPDATE. Not REVOKE ALL and a re-grant, for the reason 20261103T1800
-- gives: the privilege being removed is the stable thing to name, and the set
-- to give back is not.
-- -----------------------------------------------------------------------------
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE UPDATE ON SEQUENCES FROM authenticated;

DO $$
DECLARE r record; v int := 0;
BEGIN
  FOR r IN
    SELECT n.nspname AS s, c.relname AS o
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind = 'S'
       AND NOT EXISTS (SELECT 1 FROM pg_depend d
                        WHERE d.classid = 'pg_class'::regclass
                          AND d.objid = c.oid AND d.deptype = 'e')
  LOOP
    EXECUTE format('REVOKE UPDATE ON SEQUENCE %I.%I FROM authenticated', r.s, r.o);
    v := v + 1;
  END LOOP;
  RAISE NOTICE 'swept % sequences', v;
END $$;

-- -----------------------------------------------------------------------------
-- 3. Record it
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM record_migration(
    '20261103T1900_sequence_default_matches_production.sql',
    NULL,
    'authenticated loses UPDATE on sequences, which is setval. SELECT and '
    'USAGE stay. A no-op on production by design, and the last default the '
    'two databases disagreed about.');
END $$;

COMMIT;

-- =============================================================================
-- STILL TO DO
--
-- * THE DEFAULTS ARE NOW ALIGNED, which is a claim worth checking rather than
--   believing: after this file, postgres's three default ACL entries in public
--   should print identically on both databases. That is the first time it has
--   been true, and it is what makes "it worked on staging" mean something
--   about production. The structural diff does not currently cover
--   pg_default_acl — adding it is the way this stays true.
--
-- * supabase_admin's DEFAULTS ARE STILL THERE and still out of reach, on both
--   databases, granting anon, authenticated and service_role everything they
--   create. Aligned is not the same as closed. Same limit as 1600, 1700 and
--   1800.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- DO $$
-- DECLARE r text := '';
-- BEGIN
--   r := r || 'sequence default grants authenticated: '
--          || COALESCE((SELECT string_agg(DISTINCT a.privilege_type, ',' ORDER BY a.privilege_type)
--                         FROM pg_default_acl d
--                         JOIN pg_namespace n ON n.oid = d.defaclnamespace,
--                              aclexplode(d.defaclacl) a
--                        WHERE n.nspname = 'public' AND d.defaclrole = 'postgres'::regrole
--                          AND d.defaclobjtype = 'S'
--                          AND a.grantee = 'authenticated'::regrole), 'NOTHING')
--          || '   (expect SELECT,USAGE — USAGE is what an INSERT needs, and it '
--          || 'must still be there)' || chr(10);
--
--   r := r || 'existing sequences where authenticated holds UPDATE / USAGE: '
--          || (SELECT count(DISTINCT c.oid) FROM pg_class c
--                JOIN pg_namespace n ON n.oid = c.relnamespace,
--                     aclexplode(COALESCE(c.relacl, acldefault('S', c.relowner))) a
--               WHERE n.nspname = 'public' AND c.relkind = 'S'
--                 AND a.grantee = 'authenticated'::regrole
--                 AND a.privilege_type = 'UPDATE')
--          || ' / '
--          || (SELECT count(DISTINCT c.oid) FROM pg_class c
--                JOIN pg_namespace n ON n.oid = c.relnamespace,
--                     aclexplode(COALESCE(c.relacl, acldefault('S', c.relowner))) a
--               WHERE n.nspname = 'public' AND c.relkind = 'S'
--                 AND a.grantee = 'authenticated'::regrole
--                 AND a.privilege_type = 'USAGE')
--          || '   (expect 0 / every sequence)' || chr(10);
--
--   -- A real sequence, because a catalogue entry is a claim about what will
--   -- happen and a CREATE is what settles it.
--   CREATE SEQUENCE zzz_sequence_probe;
--   r := r || 'a brand new sequence grants authenticated: '
--          || COALESCE((SELECT string_agg(DISTINCT a.privilege_type, ',' ORDER BY a.privilege_type)
--                         FROM pg_class c, aclexplode(c.relacl) a
--                        WHERE c.oid = 'public.zzz_sequence_probe'::regclass
--                          AND a.grantee = 'authenticated'::regrole), 'NOTHING')
--          || '   (expect SELECT,USAGE)' || chr(10);
--   r := r || 'and grants anon / service_role: '
--          || COALESCE((SELECT string_agg(DISTINCT a.privilege_type, ',' ORDER BY a.privilege_type)
--                         FROM pg_class c, aclexplode(c.relacl) a
--                        WHERE c.oid = 'public.zzz_sequence_probe'::regclass
--                          AND a.grantee = 'anon'::regrole), 'NOTHING')
--          || ' / '
--          || COALESCE((SELECT string_agg(DISTINCT a.privilege_type, ',' ORDER BY a.privilege_type)
--                         FROM pg_class c, aclexplode(c.relacl) a
--                        WHERE c.oid = 'public.zzz_sequence_probe'::regclass
--                          AND a.grantee = 'service_role'::regrole), 'NOTHING')
--          || '   (expect NOTHING / NOTHING — 1600 and 1800''s doing, checked '
--          || 'here because this file rewrites the same ACL)' || chr(10);
--   DROP SEQUENCE zzz_sequence_probe;
--
--   -- The claim this file makes about the pair of databases.
--   r := r || chr(10) || 'postgres''s three defaults in full:' || chr(10);
--   r := r || COALESCE((
--          SELECT string_agg('    ' || rpad(CASE d.defaclobjtype
--                                             WHEN 'r' THEN 'tables'
--                                             WHEN 'S' THEN 'sequences'
--                                             WHEN 'f' THEN 'functions'
--                                             ELSE d.defaclobjtype::text END, 12)
--                            || d.defaclacl::text, chr(10) ORDER BY d.defaclobjtype)
--            FROM pg_default_acl d JOIN pg_namespace ns ON ns.oid = d.defaclnamespace
--           WHERE ns.nspname = 'public'
--             AND d.defaclrole = 'postgres'::regrole), '    NONE') || chr(10);
--   r := r || '   (ALL THREE should now print identically on staging and '
--          || 'production. Unlike 1800''s version of this line, there is no '
--          || 'exception left)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261103T1900_sequence_default_matches_production (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
