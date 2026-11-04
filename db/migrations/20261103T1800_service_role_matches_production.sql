-- =============================================================================
-- 20261103T1800_service_role_matches_production.sql
-- The Hub — the server's key gets what production already gives it,
-- on both databases.
--
-- APPLIED ON STAGING AND PRODUCTION, 2026-11-03, block md5
-- 1530a9b79f0c79c95017661aade13a29.
--
-- ONE NUMBER IN THE VERIFICATION WAS CORRECTED ON 2026-11-04: it said to
-- expect four routines reachable by service_role after the PUBLIC sweep, and
-- the answer is five. 20261104T0900 kept PUBLIC on location_type_is_service as
-- well as is_e164, because the system calls it from two CHECK constraints and
-- a generated column. The body is untouched.
--
-- WHAT service_role IS. The key the server holds, set as
-- SUPABASE_SERVICE_ROLE_KEY on Production only. It has BYPASSRLS, so every
-- policy in the schema is invisible to it: whatever it is granted, it gets,
-- for every row of every firm. Grants are the entire access control for this
-- role. There is no second lock.
--
-- WHAT THE TWO DATABASES GIVE IT, measured on 3 November 2026 across 98
-- relations in public on each:
--
--                                      PRODUCTION   STAGING
--   SELECT                                  0          95
--   INSERT / UPDATE / DELETE                0          89
--   MAINTAIN / REFERENCES / TRIGGER        95          95
--   TRUNCATE                               89          89
--   sequences                           nothing     SELECT, UPDATE, USAGE
--   direct EXECUTE on routines              3         110
--
-- The relation counts differ from 98 for reasons that each trace to a file,
-- which is worth knowing before treating any of them as odd. Three relations
-- grant service_role nothing at all — notify_sms_challenges, notify_sms_sends
-- and schema_migrations — because each had an explicit REVOKE ALL in its own
-- migration. Six more lack TRUNCATE: the finding-0 tables, where
-- 20261103T1000 revoked the four write privileges and left the rest. Three
-- plus six is the nine, and 98 less nine is the 89.
--
-- PRODUCTION'S SHAPE IS THE INTERESTING ONE, because it is what the running
-- product has proved it needs. The server has reached data for months without
-- a single SELECT, INSERT, UPDATE or DELETE privilege: it goes through
-- SECURITY DEFINER functions, which run as postgres. So this is not a
-- tightening anybody has to be talked into — it is staging being brought down
-- to a bar production already clears.
--
-- THE THREE FUNCTIONS service_role MAY CALL, and this is the part an earlier
-- draft of this file got backwards:
--
--   ingest_call_event              the webhook that records a call
--   record_call_content            recording and transcript content
--   request_notify_sms_confirmation  service_role-only by design, 20261102T2330
--
-- Each has the ACL {postgres=X, service_role=X} on both databases. They are
-- NOT granted to PUBLIC, and service_role's grant on them is the only one it
-- has. That draft claimed the opposite — that service_role reached them
-- through PUBLIC — and its sweep would have removed the sole grant on all
-- three, stopping call ingestion on both databases. The error came from
-- reading a report that anon held no direct grant as though it described
-- service_role: a measured fact about one column taken as a fact about the
-- column beside it, which is the second time that has happened in this work.
--
-- Two consequences, both load-bearing:
--   * ALIGNING FUNCTIONS MEANS REVOKING ALL EXCEPT THOSE THREE, not all.
--     Staging's 110 come down to production's 3.
--   * THE PENDING PUBLIC SWEEP NEEDS NO service_role GRANT. Those three are
--     not among the 68, they hold their own grants, and PUBLIC going away
--     does not touch them.
--
-- WHAT THIS FILE DOES NOT TOUCH. TRUNCATE, REFERENCES, TRIGGER and MAINTAIN
-- stay, on both databases, because production holds them and this file's job
-- is to make staging agree. Whether service_role should hold TRUNCATE and
-- TRIGGER at all is a separate decision, with the user, and a file of its own.
--
-- ON PRODUCTION THIS FILE SHOULD DO NOTHING. Every revoke in it is already
-- true there. The precondition counts what it is about to change, so the dry
-- run says so plainly: if production reports anything other than zeroes, the
-- table above is wrong and the run wants reading rather than waving through.
--
-- Requires: 024, 20261102T2330 (request_notify_sms_confirmation),
--           20261103T1200 (record_migration). Independent of 1600 and 1700,
--           which touched anon and authenticated and not this role.
-- Safe to run twice.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. What is about to change, counted before it changes
--
-- Not a three-state check on the grants, and the reason is worth a line: this
-- file only revokes. Run against an aligned database it changes nothing; run
-- against one tightened further it changes nothing. There is no state it could
-- overwrite. So the precondition has two jobs — refuse a set of default
-- privileges belonging to a role nobody has looked at, and print the size of
-- the change so that a run which should be a no-op can be seen to be one.
--
-- The three server functions are excluded from the count, because they are not
-- part of the change. If they ever appear in it, something has gone wrong in
-- the exclusion list below and the webhook is about to stop working.
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_other text; v_dml int; v_seq int; v_fn int; v_keep int;
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
      USING HINT = 'ingest_call_event, record_call_content, request_notify_sms_confirmation. If one is already missing its grant, calls may not be landing.';
  END IF;

  SELECT count(DISTINCT c.oid) INTO v_dml
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace,
         aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) a
   WHERE n.nspname = 'public' AND c.relkind IN ('r','p','v','m','f')
     AND a.grantee = 'service_role'::regrole
     AND a.privilege_type IN ('SELECT','INSERT','UPDATE','DELETE');

  SELECT count(DISTINCT c.oid) INTO v_seq
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace,
         aclexplode(COALESCE(c.relacl, acldefault('S', c.relowner))) a
   WHERE n.nspname = 'public' AND c.relkind = 'S'
     AND a.grantee = 'service_role'::regrole;

  SELECT count(DISTINCT p.oid) INTO v_fn
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace,
         aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
   WHERE n.nspname = 'public' AND p.prokind IN ('f','p')
     AND a.grantee = 'service_role'::regrole
     AND p.proname NOT IN ('ingest_call_event', 'record_call_content',
                           'request_notify_sms_confirmation')
     AND NOT EXISTS (SELECT 1 FROM pg_depend d
                      WHERE d.classid = 'pg_proc'::regclass
                        AND d.objid = p.oid AND d.deptype = 'e');

  RAISE NOTICE
    'to change: % relations with data privileges, % sequences, % routines outside the three. On production all three should be 0.',
    v_dml, v_seq, v_fn;
END $$;

-- -----------------------------------------------------------------------------
-- 2. The defaults
--
-- Only the four data privileges come off TABLES, which leaves TRUNCATE,
-- REFERENCES, TRIGGER and MAINTAIN as production has them. Written as a list
-- of what to remove rather than REVOKE ALL and a re-grant, because the
-- re-grant would have to name MAINTAIN — a privilege that did not exist before
-- PostgreSQL 17 — and a file that enumerates what to give back ages badly.
-- SELECT, INSERT, UPDATE and DELETE is a list that will not grow.
--
-- Sequences and functions get REVOKE ALL, because production's defaults name
-- service_role in neither. A consequence worth stating: after this, a NEW
-- definer function that the server needs to call requires an explicit GRANT in
-- its own migration. That is how production already works, and it is better
-- than the alternative — the three it can call being three that somebody
-- chose, rather than every function that happened to be created.
-- -----------------------------------------------------------------------------
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON SEQUENCES FROM service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON FUNCTIONS FROM service_role;

-- -----------------------------------------------------------------------------
-- 3. And what already exists
--
-- Explicit loops, for the reasons 20261103T1600 gives: ALL TABLES is
-- documented as tables, views and foreign tables and this should not depend on
-- whether it reaches materialized views, and ALL FUNCTIONS has excluded
-- procedures since PostgreSQL 11.
--
-- THE EXCLUSION LIST IN THE FUNCTION LOOP IS THE WHOLE SAFETY OF THIS FILE.
-- Without it, staging's 110 grants and production's 3 all go, and the server
-- loses the only permission it has on the two functions that record calls. It
-- is matched on proname rather than signature deliberately: an overload of one
-- of these names would also be spared, which is the safe direction to err in,
-- and the verification lists exactly what kept its grant so a spared overload
-- would be visible rather than silent.
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
      EXECUTE format('REVOKE ALL ON SEQUENCE %I.%I FROM service_role', r.s, r.o);
      v_seq := v_seq + 1;
    ELSE
      EXECUTE format(
        'REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLE %I.%I FROM service_role', r.s, r.o);
      v_rel := v_rel + 1;
    END IF;
  END LOOP;

  FOR r IN
    SELECT p.oid::regprocedure::text AS sig
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.prokind IN ('f','p')
       AND p.proname NOT IN ('ingest_call_event', 'record_call_content',
                             'request_notify_sms_confirmation')
       AND NOT EXISTS (SELECT 1 FROM pg_depend d
                        WHERE d.classid = 'pg_proc'::regclass
                          AND d.objid = p.oid AND d.deptype = 'e')
  LOOP
    EXECUTE format('REVOKE ALL ON ROUTINE %s FROM service_role', r.sig);
    v_fn := v_fn + 1;
  END LOOP;

  RAISE NOTICE 'swept % relations, % sequences, % routines (three spared)', v_rel, v_seq, v_fn;
END $$;

-- -----------------------------------------------------------------------------
-- 4. Record it
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM record_migration(
    '20261103T1800_service_role_matches_production.sql',
    NULL,
    'Staging''s service_role brought down to production''s shape: no data '
    'privileges on relations, nothing on sequences, and EXECUTE on only the '
    'three server functions. A no-op on production by design.');
END $$;

COMMIT;

-- =============================================================================
-- STILL TO DO
--
-- * THE PUBLIC SWEEP NEEDS NOTHING FROM service_role. Stated here because the
--   first draft of this file said the opposite loudly and somebody may have
--   read it. ingest_call_event, record_call_content and
--   request_notify_sms_confirmation are not among the 68 PUBLIC-granted
--   functions; they carry {postgres=X, service_role=X} and revoking PUBLIC
--   elsewhere does not touch them.
--
-- * SHOULD service_role HOLD TRUNCATE AND TRIGGER AT ALL? With the user, and a
--   file of its own. The case for removing both: TRUNCATE on a role with
--   BYPASSRLS empties any firm's table with no policy consulted and no
--   row-level trace; TRIGGER lets that role attach code that runs on every
--   write, which is worse because it is invisible until somebody looks. Both
--   are unused — no function body in public mentions TRUNCATE on either
--   database, and the-hub contains no reset or reload script. REFERENCES and
--   MAINTAIN are harmless and should stay. The change is a loop and a REVOKE,
--   reversible with one GRANT, and it changes nothing about how the product
--   behaves today.
--
--   One thing to settle first, and it is the realistic way this bites:
--   whether anything in hellophone, or any staging-reset tooling, truncates
--   using the service key. Searched on 3 November: no function body in public
--   mentions TRUNCATE on either database, and the-hub has no reset or reload
--   script. hellophone itself is the half still to search — TRUNCATE and
--   DELETE FROM, package.json scripts, anything under supabase/, seed and
--   fixture files, and CI workflows.
--
--   IF ONE TURNS UP, THE FIX IS A GUARD INSIDE IT that refuses any target but
--   the staging project. An earlier version of this bullet said to move such a
--   script to the owner connection instead, which is backwards: postgres owns
--   the schema and holds more than service_role does, so that would hand a
--   destructive script MORE privilege, not less. Recorded rather than quietly
--   replaced, because it reads like reasonable advice.
--
-- * THE SEQUENCE DEFAULT STILL DIFFERS, and not for this role. authenticated
--   holds rwU on staging and rU on production, which means a signed-in user on
--   staging can call setval. No file has touched it: 1600 was anon, 1700 was
--   tables, this one is service_role. It is small — UPDATE on a sequence with
--   no INSERT on the table is a way to corrupt an id series rather than to
--   read anything — and it is the last unaligned default left. One line in a
--   file of its own, or folded into whatever next touches the defaults.
--
-- * TABLES CREATED BY supabase_admin still grant service_role everything,
--   through that role's default privileges, which postgres cannot change. Same
--   limit as 20261103T1600 and 20261103T1700, same mitigation: the structural
--   diff is what would show one.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- DO $$
-- DECLARE r text := '';
-- BEGIN
--   -- THE CANARY, first, because it is the line that matters. These three
--   -- grants are the server's only permission on the functions that record
--   -- calls. If any later file takes one away, this is what says so.
--   r := r || 'service_role EXECUTE on the three server functions:' || chr(10);
--   r := r || COALESCE((
--          SELECT string_agg('    ' || rpad(p.proname, 34)
--                            || has_function_privilege('service_role', p.oid, 'EXECUTE')::text
--                            || '   ' || COALESCE(p.proacl::text, 'NULL acl'),
--                            chr(10) ORDER BY p.proname)
--            FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--           WHERE n.nspname = 'public'
--             AND p.proname IN ('ingest_call_event','record_call_content',
--                               'request_notify_sms_confirmation')),
--          '    NONE FOUND (BAD)') || chr(10);
--   r := r || '   (expect three lines, each true, each ACL naming service_role '
--          || 'DIRECTLY and not PUBLIC)' || chr(10);
--
--   r := r || 'every routine service_role can still EXECUTE:' || chr(10);
--   r := r || COALESCE((
--          SELECT string_agg('    ' || p.proname, chr(10) ORDER BY p.proname)
--            FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--           WHERE n.nspname = 'public' AND p.prokind IN ('f','p')
--             AND NOT EXISTS (SELECT 1 FROM pg_depend d
--                              WHERE d.classid = 'pg_proc'::regclass
--                                AND d.objid = p.oid AND d.deptype = 'e')
--             AND has_function_privilege('service_role', p.oid, 'EXECUTE')),
--          '    NONE') || chr(10);
--   r := r || '   (expect 71 on PRODUCTION and 69 on STAGING: the three direct '
--          || 'grants plus the 68 — 66 on staging, which is short 014''s two — '
--          || 'that PUBLIC reaches. NOT three: PUBLIC includes service_role '
--          || 'like every other role, and this file does not touch PUBLIC. '
--          || 'After the PUBLIC sweep expect FIVE: the three plus is_e164 and '
--          || 'location_type_is_service, both of which keep PUBLIC '
--          || 'deliberately. This line said FOUR until 20261104T0900 found a '
--          || 'second function the system calls during writes. An unexpected '
--          || 'NAME at any point means an overload was spared by the proname '
--          || 'match)' || chr(10);
--
--   r := r || 'relations where service_role holds SELECT/INSERT/UPDATE/DELETE: '
--          || (SELECT count(DISTINCT c.oid) FROM pg_class c
--                JOIN pg_namespace n ON n.oid = c.relnamespace,
--                     aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) a
--               WHERE n.nspname = 'public' AND c.relkind IN ('r','p','v','m','f')
--                 AND a.grantee = 'service_role'::regrole
--                 AND a.privilege_type IN ('SELECT','INSERT','UPDATE','DELETE'))
--          || '   (expect 0 on both. Was 95 SELECT and 89 write on staging, 0 '
--          || 'on production)' || chr(10);
--
--   r := r || 'relations still holding TRUNCATE / MAINTAIN+REFERENCES+TRIGGER: '
--          || (SELECT count(DISTINCT c.oid) FROM pg_class c
--                JOIN pg_namespace n ON n.oid = c.relnamespace,
--                     aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) a
--               WHERE n.nspname = 'public'
--                 AND a.grantee = 'service_role'::regrole
--                 AND a.privilege_type = 'TRUNCATE')
--          || ' / '
--          || (SELECT count(DISTINCT c.oid) FROM pg_class c
--                JOIN pg_namespace n ON n.oid = c.relnamespace,
--                     aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) a
--               WHERE n.nspname = 'public'
--                 AND a.grantee = 'service_role'::regrole
--                 AND a.privilege_type = 'TRIGGER')
--          || '   (expect 89 / 95 on both — deliberately kept, and the open '
--          || 'question in STILL TO DO)' || chr(10);
--
--   r := r || 'sequences with a service_role grant: '
--          || (SELECT count(DISTINCT c.oid) FROM pg_class c
--                JOIN pg_namespace n ON n.oid = c.relnamespace,
--                     aclexplode(COALESCE(c.relacl, acldefault('S', c.relowner))) a
--               WHERE n.nspname = 'public' AND c.relkind = 'S'
--                 AND a.grantee = 'service_role'::regrole)
--          || '   (expect 0)' || chr(10);
--
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
--   r := r || '   (TABLES and FUNCTIONS should now print identically on the '
--          || 'two databases. SEQUENCES will not: authenticated still holds '
--          || 'rwU on staging against rU on production, which no file has '
--          || 'touched — see STILL TO DO. Reading "all three match" into this '
--          || 'line is the mistake it is worded to prevent)' || chr(10);
--
--   r := r || 'the three are SECURITY DEFINER: '
--          || (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--               WHERE n.nspname = 'public' AND p.prosecdef
--                 AND p.proname IN ('ingest_call_event','record_call_content',
--                                   'request_notify_sms_confirmation'))
--          || '   (expect 3 — they run as postgres, which is why taking '
--          || 'service_role''s table grants away costs the server nothing)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261103T1800_service_role_matches_production (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
