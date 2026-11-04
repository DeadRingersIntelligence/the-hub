-- =============================================================================
-- 20261104T2200_btree_gist_leaves_public.sql
-- The Hub — the one thing left in public that anon can reach.
--
-- WHAT IS WRONG, and it is the smallest finding of the week. btree_gist is
-- installed into public. Its 188 functions are owned by supabase_admin and
-- every one grants EXECUTE to anon directly, on both databases. No migration
-- postgres can run will change that: ALTER DEFAULT PRIVILEGES is per granting
-- role and postgres is not a member of supabase_admin, so 20261103T1600's
-- sweep could not touch them and said so.
--
-- WHAT IT ACTUALLY EXPOSES: the ability to call a GiST support function. None
-- of the 188 reads application data. The honest description is noise rather
-- than risk — and an unexplained 188 in a security check is worse than a known
-- one, which is why it has been carried in three files' STILL TO DO since
-- 3 November.
--
-- THE FIX IS NOT A GRANT, IT IS A SCHEMA. Moving the extension out of public
-- removes the 188 from every public-schema audit at once, permanently, and
-- without fighting a role we cannot change. The extensions schema already
-- exists on both databases and already holds pgcrypto, uuid-ossp and
-- pg_stat_statements, which is where this should have gone in the first place.
--
-- WHY THIS WORKS DESPITE THE OWNERSHIP. btree_gist 1.7 is relocatable
-- (extrelocatable = true), and ALTER EXTENSION … SET SCHEMA is a privilege of
-- the extension's owner OR a superuser-equivalent. Tested on staging in a
-- rolled-back block: postgres can move it, and afterwards 0 of the 188
-- functions remain in public.
--
-- EXACTLY ONE OBJECT USES IT, measured on both databases:
--
--   number_assignments_no_overlap
--     EXCLUDE USING gist (phone_number_id WITH =,
--                         tstzrange(starts_at, COALESCE(ends_at, 'infinity')) WITH &&)
--
-- That constraint is the rule that a phone number cannot be assigned to two
-- things at once, and it is the only reason btree_gist is installed at all.
-- Its definition does not change: an index stores operator and function OIDs,
-- not names, so moving the schema those OIDs live in is invisible to it.
-- Measured on staging — constraint md5 08ed89b5 and index md5 e58f04cc,
-- identical before and after — which is why the con baseline should not move.
--
-- SEARCH PATH. The database default is "$user", public, extensions on both, so
-- a future CREATE INDEX … USING gist resolves its operator class without
-- qualification. One thing to know rather than discover: a function declared
-- SET search_path = public does NOT see extensions, so anything that names a
-- gist operator class by hand inside such a function must qualify it. Nothing
-- does today; the constraint above was created before any such function and is
-- resolved by OID regardless.
--
-- Requires: the extensions schema (present on both), 20261103T1200
--           (record_migration).
-- Safe to run twice: the precondition tells the three states apart.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. It is where this file expects, and it is movable
--
-- Three states: in public (move it), in extensions (done), anywhere else
-- (stop). Plus the two facts the move depends on — that the extension is
-- relocatable, and that the destination exists — because a failure in either
-- is clearer as a sentence here than as a bare error from ALTER EXTENSION.
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_schema text; v_relocatable boolean; v_version text;
BEGIN
  SELECT n.nspname, e.extrelocatable, e.extversion
    INTO v_schema, v_relocatable, v_version
    FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
   WHERE e.extname = 'btree_gist';

  IF v_schema IS NULL THEN
    RAISE EXCEPTION 'btree_gist is not installed; nothing to move'
      USING HINT = 'number_assignments_no_overlap needs it. If it is genuinely absent, that constraint is gone too.';
  ELSIF v_schema = 'extensions' THEN
    RAISE EXCEPTION 'btree_gist is already in extensions; nothing to do here'
      USING HINT = 'This migration has run on this database. Not an error to fix — stop.';
  ELSIF v_schema <> 'public' THEN
    RAISE EXCEPTION
      'btree_gist is in schema %, which is neither public nor extensions; stop and look', v_schema;
  END IF;

  IF NOT v_relocatable THEN
    RAISE EXCEPTION
      'btree_gist %s is not relocatable; it cannot be moved by ALTER EXTENSION', v_version
      USING HINT = 'Version 1.7 is. An older one may not be.';
  END IF;

  IF to_regnamespace('extensions') IS NULL THEN
    RAISE EXCEPTION 'the extensions schema does not exist on this database'
      USING HINT = 'It holds pgcrypto, uuid-ossp and pg_stat_statements on both of ours.';
  END IF;

  RAISE NOTICE 'moving btree_gist % from public to extensions', v_version;
END $$;

-- -----------------------------------------------------------------------------
-- 2. The move
--
-- One statement. Everything the extension owns goes with it: 188 functions,
-- 26 operator classes, 26 operator families, 12 operators and 12 types.
-- -----------------------------------------------------------------------------
ALTER EXTENSION btree_gist SET SCHEMA extensions;

-- -----------------------------------------------------------------------------
-- 3. Record it
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM record_migration(
    '20261104T2200_btree_gist_leaves_public.sql',
    NULL,
    'btree_gist moved from public to extensions, taking 188 anon-executable '
    'functions out of every public-schema audit. The only object using it, '
    'number_assignments_no_overlap, resolves by OID and is unaffected.');
END $$;

COMMIT;

-- =============================================================================
-- STILL TO DO
--
-- * THE BASELINE SHOULD NOT MOVE, which is worth checking rather than
--   assuming. fn and acl both exclude extension members, con hashes a
--   definition that does not change, and nothing else here touches a table,
--   type, trigger or policy. If any of the eight moves, this file did
--   something it does not claim to.
--
-- * TWO README LINES NOW READ WRONG. The "Default privileges" section cites
--   the 188 as the visible consequence of supabase_admin's defaults, and
--   20261103T1600's verification expects 188 extension routines granting anon
--   in public — which is now 0. 1600 is applied and its verification is
--   outside its transaction, so it can be annotated rather than amended.
--
-- * SUPABASE MAY PUT IT BACK. An extension reinstalled or upgraded by the
--   platform can land in whatever schema the platform chooses. The defacl and
--   acl queries would both show it; this is one more reason to run the eight
--   on a schedule rather than on suspicion.
--
-- * THE OTHER THREE EXTENSIONS ARE ALREADY IN extensions. Nothing else in
--   public belongs to an extension after this, so the "exclude extension
--   members" clauses in the audit queries become belt and braces rather than
--   load-bearing. Leave them: they are what makes the queries correct rather
--   than lucky.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- DO $$
-- DECLARE
--   r text := ''; n int;
--   v_pn uuid; v_start timestamptz; v_purpose number_purpose; v_ends timestamptz;
-- BEGIN
--   r := r || 'btree_gist now lives in: '
--          || COALESCE((SELECT n.nspname FROM pg_extension e
--                         JOIN pg_namespace n ON n.oid = e.extnamespace
--                        WHERE e.extname = 'btree_gist'), 'NOT INSTALLED')
--          || '   (expect extensions)' || chr(10);
--
--   r := r || 'its member functions in public / in extensions: '
--          || (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--               WHERE n.nspname = 'public'
--                 AND EXISTS (SELECT 1 FROM pg_depend d
--                              WHERE d.classid = 'pg_proc'::regclass
--                                AND d.objid = p.oid AND d.deptype = 'e'))
--          || ' / '
--          || (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--               WHERE n.nspname = 'extensions'
--                 AND EXISTS (SELECT 1 FROM pg_depend d
--                              WHERE d.classid = 'pg_proc'::regclass
--                                AND d.objid = p.oid AND d.deptype = 'e'))
--          || '   (expect 0 / 188 or more — extensions already holds pgcrypto, '
--          || 'uuid-ossp and pg_stat_statements)' || chr(10);
--
--   r := r || 'routines in public anon can EXECUTE: '
--          || (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--               WHERE n.nspname = 'public' AND p.prokind IN ('f','p')
--                 AND has_function_privilege('anon', p.oid, 'EXECUTE'))
--          || '   (expect 2 — is_e164 and location_type_is_service, the two '
--          || 'kept on purpose. It read 190 before this file)' || chr(10);
--
--   -- The constraint's definition must be byte-identical: an index stores
--   -- OIDs, not schema-qualified names, so the move is invisible to it. This
--   -- is also the line that says whether the con baseline moves.
--   r := r || 'constraint / index definition md5: '
--          || (SELECT left(md5(pg_get_constraintdef(oid)), 8) FROM pg_constraint
--               WHERE conname = 'number_assignments_no_overlap')
--          || ' / '
--          || (SELECT left(md5(indexdef), 8) FROM pg_indexes
--               WHERE indexname = 'number_assignments_no_overlap')
--          || '   (expect 08ed89b5 / e58f04cc, unchanged — if either moved, '
--          || 'the con baseline moves and this file did more than it says)' || chr(10);
--
--   -- ---- the rule still works, both halves -------------------------------
--   -- A check that only proves the constraint REFUSES something would pass on
--   -- a table nobody can insert into at all. The positive half is what shows
--   -- the exclusion operator is still resolving.
--   SELECT phone_number_id, starts_at, ends_at, purpose
--     INTO v_pn, v_start, v_ends, v_purpose
--     FROM number_assignments ORDER BY starts_at LIMIT 1;
--
--   IF v_pn IS NULL THEN
--     r := r || 'no number_assignments rows — FIXTURE NOT RUN, and the two '
--            || 'lines that matter are untested' || chr(10);
--   ELSE
--     BEGIN
--       INSERT INTO number_assignments (phone_number_id, purpose, starts_at, ends_at)
--       VALUES (v_pn, v_purpose, v_start, v_ends);
--       r := r || 'an OVERLAPPING assignment was ACCEPTED (BAD — the rule is '
--              || 'gone)' || chr(10);
--     EXCEPTION WHEN exclusion_violation THEN
--       r := r || 'an overlapping assignment is refused: 23P01, correct' || chr(10);
--     WHEN others THEN
--       r := r || 'overlap insert failed for another reason, so this proves '
--              || 'nothing: ' || SQLERRM || chr(10); END;
--
--     -- The control must sit BEFORE the existing window, not after it. The
--     -- live row has ends_at NULL, which COALESCE turns into 'infinity', so a
--     -- "later" window overlaps it and is refused for the right reason — which
--     -- would read exactly like the constraint working on a test that was
--     -- meant to show it allowing something.
--     BEGIN
--       INSERT INTO number_assignments (phone_number_id, purpose, starts_at, ends_at)
--       VALUES (v_pn, v_purpose, timestamptz '1900-01-01', timestamptz '1900-06-01');
--       r := r || 'a NON-overlapping assignment is accepted: correct, and this '
--              || 'is the half that shows gist is still resolving' || chr(10);
--     EXCEPTION WHEN others THEN
--       r := r || 'a non-overlapping assignment was REFUSED (BAD): ' || SQLERRM
--              || chr(10); END;
--   END IF;
--
--   RAISE EXCEPTION 'VERIFY 20261104T2200_btree_gist_leaves_public (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
