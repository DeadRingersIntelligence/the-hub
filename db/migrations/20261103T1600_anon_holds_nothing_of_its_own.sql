-- =============================================================================
-- 20261103T1600_anon_holds_nothing_of_its_own.sql
-- The Hub — the key that ships in the browser bundle stops holding grants.
--
-- WHAT anon IS. The Supabase anonymous key is in every hellophone bundle and
-- in every preview build. Anyone who opens the site has it. Everything it can
-- reach is public, whatever the page does with it.
--
-- WHAT IT HOLDS TODAY, and the two databases differ:
--
--   PRODUCTION  tables     REFERENCES, TRIGGER, MAINTAIN on new tables, from
--                          the default ACL. No data access.
--               sequences  nothing.
--               functions  no direct grant on any of them.
--
--   STAGING     tables     INSERT, SELECT, UPDATE, DELETE, REFERENCES,
--                          TRIGGER, MAINTAIN — on new tables by default, and
--                          directly on 92 relations.
--               sequences  SELECT, UPDATE, USAGE.
--               functions  a direct EXECUTE grant on each of the 68.
--
-- Staging is the loose one, which is the wrong way round: it means staging
-- cannot catch a missing REVOKE, because staging grants it anyway. Finding 0
-- was found on production and only then confirmed on staging; it could as
-- easily have gone the other way and been dismissed as a staging quirk.
--
-- WHAT THIS FILE DOES. Two things, and the defaults are the half that lasts:
--
--   1. ALTER DEFAULT PRIVILEGES so that nothing created in public from now on
--      grants anything to anon, on either database.
--   2. Revoke every grant anon already holds in public — every table, view,
--      materialized view, sequence, function and procedure.
--
-- WHAT IT DOES NOT DO, and the title is worded carefully because of it.
-- "anon holds nothing OF ITS OWN" is what this achieves. It is not the same as
-- anon reaching nothing. Sixty-eight functions in public grant EXECUTE to
-- PUBLIC, and PUBLIC includes anon. Revoking a role's own grant does not take
-- away what it holds through PUBLIC — that is the trap this whole sweep
-- started from, when an anon-only revoke on production was going to be
-- reported as a fix and would have changed nothing.
--
-- Those 68 are a separate file and a decision per function, because PUBLIC is
-- the ONLY grant most of them have: on production not one of the 68 carries a
-- direct grant to authenticated, so revoking PUBLIC without granting
-- authenticated in the same statement would take the application down. Nine of
-- them write. They are listed in STILL TO DO.
--
-- WHY THIS IS SAFE TO RUN, stated as an argument rather than a hope. Grants
-- are only half of what a client needs; a policy has to admit it as well.
-- Today's policy audit found 133 policies in public and exactly six that
-- admitted anyone unconditionally — the six 20261103T1000 replaced. After
-- that file, no policy in public admits anon to any row. So anon's remaining
-- table grants reach nothing, and revoking them cannot break a path that
-- works, only a path that was going to start working by accident.
--
-- That argument is about the database. It does not cover an unauthenticated
-- page that reads public before sign-in — see STILL TO DO.
--
-- SOME OF anon's GRANTS ARE OUT OF REACH, and this file cannot fix that or
-- pretend to. ALTER DEFAULT PRIVILEGES is per granting role, and public holds
-- a second set of defaults belonging to supabase_admin, which grants anon,
-- authenticated and service_role full access to whatever it creates. postgres
-- is not a member of supabase_admin, so nothing here touches them.
--
-- That is not hypothetical. btree_gist is installed into public and its 188
-- functions are owned by supabase_admin, each with a direct anon EXECUTE
-- grant, on both databases. The sweep in section 3 skips extension-owned
-- objects on purpose — undoing an extension's grants is not this file's
-- business and the next extension update would put them back — so those 188
-- stay, and the verification counts them separately rather than reporting a
-- failure it cannot act on.
--
-- Section 1 therefore accepts supabase_admin's entries as known and
-- unreachable, and still refuses any OTHER granting role, because a third set
-- of defaults would be something nobody has looked at.
--
-- Requires: 024 (the defaults being changed), 20261103T1000 (the policy
--           audit this leans on), 20261103T1200 (record_migration).
-- Safe to run twice: the precondition tells "not yet" from "already done"
--           from "something else", and refuses the third.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. The defaults are the ones this file expects to change
--
-- Three states, read from pg_default_acl rather than from a hash because the
-- thing being changed is an ACL. Either anon appears in at least one of the
-- three defaults (not yet done), or it appears in none (done), or there are
-- default ACL entries for a role other than postgres — which this file does
-- not touch and must not pretend to have handled.
--
-- aclexplode over defaclacl, not a LIKE on its text: 'anon' as a substring
-- would also match a role named 'anonymous_reader', and an ACL is a structure
-- that happens to print as a string.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_anon int;
  v_sa   int;
  v_other text;
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
      USING HINT = 'ALTER DEFAULT PRIVILEGES is per granting role. Objects made by that role would keep their own defaults.';
  END IF;

  -- supabase_admin's, counted and named rather than silently skipped. They
  -- are real anon grants on real objects; they are simply not ours to revoke.
  SELECT count(*) INTO v_sa
    FROM pg_default_acl d
    JOIN pg_namespace n ON n.oid = d.defaclnamespace,
         aclexplode(d.defaclacl) a
   WHERE n.nspname = 'public'
     AND d.defaclrole = to_regrole('supabase_admin')
     AND a.grantee = 'anon'::regrole;
  IF v_sa > 0 THEN
    RAISE NOTICE
      'supabase_admin holds % default privilege(s) granting anon in public; out of postgres''s reach and left alone', v_sa;
  END IF;

  SELECT count(*) INTO v_anon
    FROM pg_default_acl d
    JOIN pg_namespace n ON n.oid = d.defaclnamespace,
         aclexplode(d.defaclacl) a
   WHERE n.nspname = 'public'
     AND d.defaclrole = 'postgres'::regrole
     AND a.grantee = 'anon'::regrole;

  IF v_anon = 0 THEN
    RAISE NOTICE 'anon is in none of postgres''s default ACLs — this migration has run before';
  ELSE
    RAISE NOTICE 'anon appears in % of postgres''s default ACL entries; removing', v_anon;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. Nothing new ever grants to anon again
--
-- This is the half that matters in a year. The sweep below cleans up what
-- exists; this is what stops the list growing back one CREATE TABLE at a time.
-- Finding 0 was not a mistake anybody made — it was the default doing what it
-- was set to do, on a table whose author never thought about grants at all.
--
-- Named FOR ROLE postgres explicitly rather than relying on the session role.
-- ALTER DEFAULT PRIVILEGES with no FOR ROLE applies to the current user, which
-- is the same thing here and would stop being the same thing the first time
-- this ran as anyone else.
--
-- All three object types, including the two where production already has no
-- anon entry. Running a REVOKE that is already true costs nothing and means
-- the file states the whole intended shape instead of the diff from one
-- database.
-- -----------------------------------------------------------------------------
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON TABLES FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON SEQUENCES FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON FUNCTIONS FROM anon;

-- -----------------------------------------------------------------------------
-- 3. And nothing that already exists holds one
--
-- Explicit loops rather than REVOKE ... ON ALL TABLES IN SCHEMA, for two
-- reasons worth the extra lines. ALL TABLES is documented as tables, views and
-- foreign tables, and whether it reaches materialized views is a question this
-- file should not depend on the answer to. ALL FUNCTIONS excludes procedures
-- since PostgreSQL 11, which is exactly the kind of thing that leaves one
-- object behind and no sign of it.
--
-- Extension-owned objects are skipped. Revoking a grant that an extension
-- installed is not this file's business and would be undone by the next
-- extension update anyway.
-- -----------------------------------------------------------------------------
DO $$
DECLARE r record; v_rel int := 0; v_seq int := 0; v_fn int := 0;
BEGIN
  FOR r IN
    SELECT n.nspname AS s, c.relname AS o, c.relkind AS k
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relkind IN ('r','p','v','m','f','S')
       AND NOT EXISTS (SELECT 1 FROM pg_depend d
                        WHERE d.classid = 'pg_class'::regclass
                          AND d.objid = c.oid AND d.deptype = 'e')
  LOOP
    IF r.k = 'S' THEN
      EXECUTE format('REVOKE ALL ON SEQUENCE %I.%I FROM anon', r.s, r.o);
      v_seq := v_seq + 1;
    ELSE
      EXECUTE format('REVOKE ALL ON TABLE %I.%I FROM anon', r.s, r.o);
      v_rel := v_rel + 1;
    END IF;
  END LOOP;

  FOR r IN
    SELECT p.oid::regprocedure::text AS sig
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.prokind IN ('f','p')
       AND NOT EXISTS (SELECT 1 FROM pg_depend d
                        WHERE d.classid = 'pg_proc'::regclass
                          AND d.objid = p.oid AND d.deptype = 'e')
  LOOP
    EXECUTE format('REVOKE ALL ON ROUTINE %s FROM anon', r.sig);
    v_fn := v_fn + 1;
  END LOOP;

  RAISE NOTICE 'swept % relations, % sequences, % routines', v_rel, v_seq, v_fn;
END $$;

-- -----------------------------------------------------------------------------
-- 4. Record it
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM record_migration(
    '20261103T1600_anon_holds_nothing_of_its_own.sql',
    NULL,
    'anon loses its own grants in public and the defaults stop issuing new '
    'ones. What anon still reaches through PUBLIC is untouched and is the '
    'next file.');
END $$;

COMMIT;

-- =============================================================================
-- STILL TO DO
--
-- * THE 68 PUBLIC-GRANTED FUNCTIONS, which is where anon's real reach is and
--   what the next file has to decide one at a time. The shape of the problem:
--   on production not one of the 68 carries a direct grant to authenticated,
--   so PUBLIC is the only thing making them callable by a signed-in user.
--   Every revoke must be paired with a grant in the same statement or the
--   application stops working.
--
--   KEEP PUBLIC: the trigger functions (touch_updated_at, the *_normalize and
--   *_guard family, users_sms_*), which must be executable by whoever writes
--   the table; and is_e164, deliberately public since 20261030T1500 §1.
--
--   DECIDE, these nine write and should not be reachable by an unauthenticated
--   key under any reading: merge_contacts, record_change, set_contact_blocked,
--   rename_tag, acknowledge_alert, apply_tag_rule, attach_events_to_interaction,
--   link_related_calls, find_or_start_text_thread. Each needs its callers
--   checked before its grant changes.
--
--   Note that RLS does not save these the way it saves the tables. A SECURITY
--   DEFINER function runs as its owner, so for any of the nine that is definer,
--   the EXECUTE grant is the whole of the access control.
--
-- * WHETHER ANY UNAUTHENTICATED PAGE READS public BEFORE SIGN-IN. The argument
--   in the header covers the database — no policy in public admits anon to a
--   row, so the grants reached nothing. It does not cover a page that calls an
--   RPC before sign-in and gets its answer through a definer function, where
--   the EXECUTE grant was doing the work and no policy was ever consulted.
--   That is a hellophone question, not a schema one, and it should be answered
--   before the PUBLIC sweep rather than before this file: this file takes away
--   only grants anon held in its own name, and on production those were
--   REFERENCES, TRIGGER and MAINTAIN on tables, which no page can use.
--
-- * THE TABLE DEFAULT STILL GIVES authenticated INSERT, UPDATE AND DELETE ON
--   EVERY NEW TABLE, on both databases. That is how finding 0 happened: six
--   reference tables became writable by every signed-in user at every firm
--   because nobody granted anything, and the default granted it for them.
--   Aligning anon does not touch it. My recommendation is to take the write
--   privileges out of the table default as well, so that a new table grants
--   SELECT and nothing else until someone says otherwise — but that changes
--   what happens to the next table anybody adds, including through the
--   Supabase UI, and it is a policy decision rather than an alignment. It
--   wants its own file and the user's word.
--
-- * btree_gist IS INSTALLED INTO public, 188 supabase_admin-owned functions
--   each granting anon EXECUTE directly, on both databases. Nothing here
--   changes that, and nothing postgres can run will: they belong to another
--   role's default privileges. The fix is to move the extension to its own
--   schema — Supabase's own guidance is an `extensions` schema — which is a
--   decision about the database's layout rather than about grants, and wants
--   its own file and a check of what references those operators first. None of
--   the 188 reads application data; the exposure is the ability to call a GiST
--   support function, which is noise rather than risk. It is listed because an
--   unexplained 188 in a security check is worse than a known one.
--
-- * service_role IS UNTOUCHED HERE, by the agreed split. It still holds
--   TRUNCATE on every production table, which bypasses RLS entirely.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- The counts it prints are the point: the ones that should be zero, and the
-- one that should not be, so that this file cannot be read as having done more
-- than it did.
--
-- DO $$
-- DECLARE r text := ''; n int;
-- BEGIN
--   r := r || 'postgres default ACL entries naming anon: '
--          || (SELECT count(*) FROM pg_default_acl d
--                JOIN pg_namespace ns ON ns.oid = d.defaclnamespace,
--                     aclexplode(d.defaclacl) a
--               WHERE ns.nspname = 'public' AND a.grantee = 'anon'::regrole
--                 AND d.defaclrole = 'postgres'::regrole)
--          || '   (expect 0)' || chr(10);
--   r := r || 'supabase_admin default ACL entries naming anon: '
--          || (SELECT count(*) FROM pg_default_acl d
--                JOIN pg_namespace ns ON ns.oid = d.defaclnamespace,
--                     aclexplode(d.defaclacl) a
--               WHERE ns.nspname = 'public' AND a.grantee = 'anon'::regrole
--                 AND d.defaclrole = to_regrole('supabase_admin'))
--          || '   (expect 12, and expect it never to reach 0 from here — '
--          || 'postgres is not a member of supabase_admin)' || chr(10);
--   r := r || 'postgres''s three defaults as they now read:' || chr(10);
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
--
--   r := r || 'relations / sequences / routines with a DIRECT anon grant: '
--          || (SELECT count(DISTINCT c.oid) FROM pg_class c
--                JOIN pg_namespace ns ON ns.oid = c.relnamespace,
--                     aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) a
--               WHERE ns.nspname = 'public' AND c.relkind IN ('r','p','v','m','f')
--                 AND a.grantee = 'anon'::regrole)
--          || ' / '
--          || (SELECT count(DISTINCT c.oid) FROM pg_class c
--                JOIN pg_namespace ns ON ns.oid = c.relnamespace,
--                     aclexplode(COALESCE(c.relacl, acldefault('S', c.relowner))) a
--               WHERE ns.nspname = 'public' AND c.relkind = 'S'
--                 AND a.grantee = 'anon'::regrole)
--          || ' / '
--          || (SELECT count(DISTINCT p.oid) FROM pg_proc p
--                JOIN pg_namespace ns ON ns.oid = p.pronamespace,
--                     aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
--               WHERE ns.nspname = 'public' AND p.prokind IN ('f','p')
--                 AND a.grantee = 'anon'::regrole
--                 AND NOT EXISTS (SELECT 1 FROM pg_depend d
--                                  WHERE d.classid = 'pg_proc'::regclass
--                                    AND d.objid = p.oid AND d.deptype = 'e'))
--          || '   (expect 0 / 0 / 0. The routine count EXCLUDES extension '
--          || 'members, because the sweep does: without that it reads 188, '
--          || 'which is btree_gist in public and can never reach 0)' || chr(10);
--   r := r || 'extension routines in public granting anon directly: '
--          || (SELECT count(DISTINCT p.oid) FROM pg_proc p
--                JOIN pg_namespace ns ON ns.oid = p.pronamespace,
--                     aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
--               WHERE ns.nspname = 'public' AND p.prokind IN ('f','p')
--                 AND a.grantee = 'anon'::regrole
--                 AND EXISTS (SELECT 1 FROM pg_depend d
--                              WHERE d.classid = 'pg_proc'::regclass
--                                AND d.objid = p.oid AND d.deptype = 'e'))
--          || '   (expect 188 — btree_gist, owned by supabase_admin. Known, '
--          || 'untouched, and listed in STILL TO DO)' || chr(10);
--
--   -- The number this file deliberately does not change. If it ever reads 0,
--   -- something else swept PUBLIC and the next file has nothing to decide.
--   r := r || 'routines anon can still EXECUTE, through PUBLIC: '
--          || (SELECT count(*) FROM pg_proc p
--                JOIN pg_namespace ns ON ns.oid = p.pronamespace
--               WHERE ns.nspname = 'public' AND p.prokind IN ('f','p')
--                 AND NOT EXISTS (SELECT 1 FROM pg_depend d
--                                  WHERE d.classid = 'pg_proc'::regclass
--                                    AND d.objid = p.oid AND d.deptype = 'e')
--                 AND has_function_privilege('anon', p.oid, 'EXECUTE'))
--          || '   (expect 68 on PRODUCTION and 66 on STAGING — NOT a failure. '
--          || 'Staging is short behavior_detail and section_scores, which came '
--          || 'in 014 and have never run there. This is what the next file is '
--          || 'for, and the reason this one is called "of its own")' || chr(10);
--
--   r := r || 'tables authenticated can still SELECT: '
--          || (SELECT count(*) FROM pg_class c
--                JOIN pg_namespace ns ON ns.oid = c.relnamespace
--               WHERE ns.nspname = 'public' AND c.relkind IN ('r','p')
--                 AND has_table_privilege('authenticated', c.oid, 'SELECT'))
--          || '   (expect unchanged — this file touches no role but anon)' || chr(10);
--
--   -- Asked of the catalogue, not of a query, and asked BEFORE the role
--   -- switch. Running SELECT as anon proves only that something refused:
--   -- organizations has a policy calling current_organization_id(), and the
--   -- refusal came from that function, which would have happened whether or
--   -- not the table grant went. A privilege question deserves a privilege
--   -- answer.
--   r := r || 'anon SELECT privilege on organizations / behaviors / cases: '
--          || has_table_privilege('anon', 'public.organizations', 'SELECT')::text || ' / '
--          || has_table_privilege('anon', 'public.behaviors', 'SELECT')::text || ' / '
--          || has_table_privilege('anon', 'public.cases', 'SELECT')::text
--          || '   (expect false / false / false)' || chr(10);
--
--   -- ---- as anon. Last: the role does not revert. ---------------------------
--   PERFORM set_config('role', 'anon', true);
--
--   BEGIN
--     SELECT count(*) INTO n FROM behaviors;
--     r := r || 'anon can read behaviors: ' || n || ' rows (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'anon read on behaviors refused: ' || SQLERRM || chr(10); END;
--
--   BEGIN
--     PERFORM is_e164('+15555550123');
--     r := r || 'anon can still call is_e164: yes — correct, it is PUBLIC on '
--            || 'purpose, and it is the proof that this file left PUBLIC alone'
--            || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'anon could NOT call is_e164 (BAD — PUBLIC was swept): '
--            || SQLERRM || chr(10); END;
--
--   RAISE EXCEPTION 'VERIFY 20261103T1600_anon_holds_nothing_of_its_own (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
