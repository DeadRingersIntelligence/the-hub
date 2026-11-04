-- =============================================================================
-- 20261104T0900_public_loses_execute.sql
-- The Hub — the last thing the anonymous key can reach.
--
-- APPLIED ON STAGING AND PRODUCTION, 2026-11-04, block md5
-- 8a62534f67450a0da1a7c44a718d83a0, identical on both. is_e164 and
-- location_type_is_service are the only functions still granting PUBLIC; the
-- canary is 3; service_role reaches five routines.
--
-- THE acl COMPARISON NOW MATCHES IN FULL, for the first time:
-- ffefc02753d113a5fe6c5c47e50ca505 on both databases. Every grant on every
-- relation, sequence and routine in public agrees. 20261103T2100's two
-- predicted differences were the last of them.
--
-- CORRECTIONS MADE IN PLACE, all outside the transaction. The body is
-- untouched and its md5 is unchanged.
--
--   THE TRIGGER PROBE PROVED NOTHING, again. All 33 trigger functions also
--   hold a DIRECT authenticated grant from 024's function default, so after
--   the sweep authenticated can still call touch_updated_at by name and the
--   probe printed true whatever had happened. It now revokes that grant too,
--   inside the rolled-back block, which is how the 3 November experiment was
--   run. Second time in two files that a probe ran under privileges that made
--   its own question unaskable.
--
--   "functions authenticated can EXECUTE" DOES NOT DROP, for the same reason:
--   it stays at 107 on staging. The old expectation said the 33 would fall off
--   it. The header's claim that they "lose PUBLIC with nothing granted back"
--   is still true — they simply had a second grant all along.
--
--   anon CAN REACH TWO FUNCTIONS, not one. Said in three places and wrong in
--   all three before this pass.
--
--   SECTION 1'S COMMENT STILL SAYS "written to refuse with a list rather than
--   to proceed with a count", which stopped being the whole truth when the
--   integrity scan changed from refusing to sparing. It is inside the
--   transaction and this file has run, so it stays as it is: an applied
--   migration is annotated, never amended. It refuses on orphans and spares
--   the integrity set, and the paragraph below it says so.
--
-- WHAT IS WRONG. 68 functions in public grant EXECUTE to PUBLIC, and PUBLIC is
-- every role: anon included. The anonymous key ships in every hellophone
-- bundle and every preview build, so anyone who opens the site can call all
-- 68. Nine of them write: merge_contacts, record_change, set_contact_blocked,
-- rename_tag, acknowledge_alert, apply_tag_rule, attach_events_to_interaction,
-- link_related_calls and find_or_start_text_thread.
--
-- 20261103T1600 did not touch this and said so in its title. It removed the
-- grants anon held IN ITS OWN NAME, which on production were none at all on
-- functions — so an anon-only sweep there would have changed nothing and been
-- reported as a fix. Revoking a role's own grant does not take away what it
-- holds through PUBLIC. That is the whole reason this is a separate file.
--
-- WHICH ROLE THIS PROTECTS AGAINST. Production uses the publishable key
-- (sb_publishable_…), which is not a JWT, so an unauthenticated request
-- carries no role claim and the API logs show none. Supabase's documentation
-- is clear that such a request runs as anon, and a request with a session runs
-- as authenticated. That is documented rather than measured here — measuring
-- it would mean issuing a request carrying the key — and it agrees with a
-- week of logs in which no /rest/v1 call of any kind arrived without a
-- signed-in user.
--
-- WHY THIS IS ONE SWEEP AND NOT 68 DECISIONS. Two facts, both measured on
-- 3 November, and an earlier draft of 20261103T1600 asserted the opposite of
-- the first:
--
--   authenticated ALREADY HOLDS A DIRECT EXECUTE ON ALL 68 on production —
--   {=X/postgres, postgres=X/postgres, authenticated=X/postgres} on every one.
--   So revoking PUBLIC leaves every signed-in caller working. Section 1
--   verifies that here rather than trusting it, because staging's 66 have
--   never been counted and a function left with no caller is the one way this
--   file could break the product.
--
--   A TRIGGER FUNCTION NEEDS NO EXECUTE GRANT AT ALL. PostgreSQL checks that
--   privilege at CREATE TRIGGER and never when a trigger fires. Proved on
--   staging: with EXECUTE revoked from PUBLIC, anon and authenticated, an
--   UPDATE run as authenticated still fired touch_updated_at() and still set
--   updated_at. That is 33 of the 68, which simply lose PUBLIC with nothing
--   granted back.
--
-- TWO FUNCTIONS KEEP PUBLIC, for two different reasons.
--
--   is_e164, deliberately, as 20261030T1500 §1 set out: it is the single
--   statement of the E.164 pattern in this schema, and it is public so that
--   nothing has an excuse to write a second one.
--
--   location_type_is_service, because the system calls it during writes.
--   rubrics_service_type_only_ck and benchmark_snapshots_service_type_only_ck
--   name it, and locations.is_service_location is a generated column computed
--   from it.
--
-- THE WHOLE CATEGORY, scanned on 4 November rather than discovered one member
-- at a time, is three functions. is_e164 is named in CHECK constraints on five
-- tables: contact_phones, directory_entries, phone_numbers, routing_schedules
-- and users. location_type_is_service is as above. The third is
-- submitted_text, which supplies the defaults for schema_migrations.ran_md5
-- and ran_len — and which is NOT public, correctly, because the only thing
-- that writes that table is record_migration, a SECURITY DEFINER function
-- running as postgres.
--
-- That third member is the one that defines the category properly. It is "the
-- system calls this during a write", not "this must be PUBLIC". Whether a
-- member needs PUBLIC depends entirely on who writes the table it guards.
--
-- THE REASONING ON THE SECOND ONE, because an earlier draft of this header had
-- it half right and it is worth being exact. A first draft said a constraint's
-- function "is not somewhere to discover a privilege subtlety by experiment",
-- and made that a refusal. Working it through, the subtlety is not there: every
-- role that could evaluate these expressions already holds EXECUTE after this
-- file runs. authenticated keeps a direct grant on all of them, which section 1
-- insists on. anon holds no table privilege at all after 20261103T1600, so it
-- never writes a row and never reaches a constraint. service_role has no DML on
-- tables and BYPASSRLS besides. postgres owns them. Nothing is left that writes
-- and cannot call.
--
-- So sweeping location_type_is_service would very probably be safe. It is kept
-- anyway, and the reason is the trade rather than the risk: it is a pure
-- predicate over an enum value, it exposes nothing about any firm's data, and
-- revoking it therefore buys nothing at all — while being wrong about it breaks
-- writes to rubrics, benchmark_snapshots and locations. An action with no
-- benefit and a non-zero cost is one not to take, however small the cost looks.
--
-- SO THE RULE, which section 1 applies rather than a list of names: a function
-- the SYSTEM calls during a write is SPARED FROM THE SWEEP, and whether it
-- then needs PUBLIC is a separate question answered per function — by who
-- writes the table it guards. submitted_text above is the proof that the two
-- are not the same question. That means CHECK constraints,
-- column defaults and generated columns, and index expressions — the three
-- places a function runs without appearing in anybody's code, where a
-- privilege failure arrives as a refused write rather than as a refused call.
-- Policies are deliberately NOT in that set: a policy is part of the access
-- control design, its functions run on ordinary queries, and the roles that
-- evaluate them hold direct grants by construction. Sweeping them is the point
-- of the file, not an oversight in it.
--
-- service_role NEEDS NOTHING HERE. It reaches ingest_call_event,
-- record_call_content and request_notify_sms_confirmation through its own
-- direct grants, and none of those three is among the 68. An earlier draft of
-- 20261103T1800 claimed it reached them through PUBLIC and would have cut the
-- webhook off; that is corrected in that file's header and repeated here
-- because this is the file where the mistake would have landed.
--
-- WHAT IS LEFT AFTERWARDS. anon can execute exactly two functions in public:
-- is_e164 and location_type_is_service, both kept on purpose and neither able
-- to reveal anything about a firm. It holds nothing else anywhere — no table,
-- no sequence, no other routine.
-- btree_gist's 188 supabase_admin-owned functions still grant it EXECUTE and
-- are still out of postgres's reach; none of them reads application data.
--
-- NOTICES ARE INVISIBLE IN THE SQL EDITOR, so section 1's "keeping PUBLIC on"
-- line is never seen there. The verification's "which is:" line is what
-- actually shows the list, and it is the one to read.
--
-- Requires: 024, 20261103T1600, 20261103T1200 (record_migration).
-- Safe to run twice: the sweep targets functions that still hold a PUBLIC
--           grant, so a second run finds none.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Nothing is about to be left with no caller
--
-- This section is the file. The revoke below is three lines; everything that
-- makes it safe to run is here, and it is written to refuse with a list rather
-- than to proceed with a count.
--
-- A function is safe to take PUBLIC from when either it needs no grant at all
-- (it is a trigger or event-trigger function) or it keeps a DIRECT grant to
-- authenticated. The word direct matters: has_function_privilege('authenticated',
-- …) returns true for anything PUBLIC-granted, so asking it that question
-- before the revoke answers yes for every one of the 68 and proves nothing.
-- The check reads the ACL for an explicit authenticated entry instead.
--
-- The integrity scan spares rather than refuses, and prints what it spared.
-- Refusing was the first design and it was wrong for a scan that is meant to
-- run on every future sweep: a refusal stops the file until somebody edits it,
-- and the correct action for a newly-found integrity function is the one this
-- file already takes for the two it knows about. Printing keeps it visible —
-- a dry run says exactly which functions kept PUBLIC and the list should be
-- read, not skimmed.
--
-- It matches on the function's name followed by an open parenthesis, so it is
-- deliberately over-eager: a name appearing in an unrelated expression spares
-- a function that did not need sparing, which costs a PUBLIC grant on
-- something nobody calls. The other kind of error costs a broken write path.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_total int; v_orphans text; v_constrained text; v_other text;
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

  -- Everything in public that still grants PUBLIC EXECUTE, minus the two
  -- kept deliberately: is_e164 by name, and anything the system calls during
  -- a write.
  CREATE TEMP TABLE zzz_sweep ON COMMIT DROP AS
  SELECT p.oid,
         p.oid::regprocedure::text AS sig,
         p.proname,
         p.prorettype IN ('trigger'::regtype, 'event_trigger'::regtype) AS needs_no_grant,
         EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
                  WHERE a.grantee = 'authenticated'::regrole
                    AND a.privilege_type = 'EXECUTE') AS keeps_authenticated,
         (p.proname = 'is_e164'
          OR EXISTS (SELECT 1 FROM pg_constraint c
                       JOIN pg_class cl ON cl.oid = c.conrelid
                       JOIN pg_namespace cn ON cn.oid = cl.relnamespace
                      WHERE cn.nspname = 'public'
                        AND pg_get_constraintdef(c.oid) LIKE '%' || p.proname || '(%')
          OR EXISTS (SELECT 1 FROM pg_attrdef ad
                       JOIN pg_class cl ON cl.oid = ad.adrelid
                       JOIN pg_namespace cn ON cn.oid = cl.relnamespace
                      WHERE cn.nspname = 'public'
                        AND pg_get_expr(ad.adbin, ad.adrelid) LIKE '%' || p.proname || '(%')
          OR EXISTS (SELECT 1 FROM pg_index i
                       JOIN pg_class cl ON cl.oid = i.indrelid
                       JOIN pg_namespace cn ON cn.oid = cl.relnamespace
                      WHERE cn.nspname = 'public'
                        AND (COALESCE(pg_get_expr(i.indexprs, i.indrelid), '') LIKE '%' || p.proname || '(%'
                          OR COALESCE(pg_get_expr(i.indpred,  i.indrelid), '') LIKE '%' || p.proname || '(%'))
         ) AS keep_public
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.prokind IN ('f','p')
     AND NOT EXISTS (SELECT 1 FROM pg_depend d
                      WHERE d.classid = 'pg_proc'::regclass
                        AND d.objid = p.oid AND d.deptype = 'e')
     AND EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
                  WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE');

  -- Named, every time, so a dry run shows exactly what is being left alone.
  SELECT string_agg(sig, ', ' ORDER BY sig) INTO v_constrained
    FROM zzz_sweep WHERE keep_public;
  RAISE NOTICE 'keeping PUBLIC on: %',
    COALESCE(v_constrained, 'NOTHING — expected at least is_e164, so stop and look');

  DELETE FROM zzz_sweep WHERE keep_public;
  SELECT count(*) INTO v_total FROM zzz_sweep;

  SELECT string_agg(sig, ', ' ORDER BY sig) INTO v_orphans
    FROM zzz_sweep WHERE NOT needs_no_grant AND NOT keeps_authenticated;
  IF v_orphans IS NOT NULL THEN
    RAISE EXCEPTION
      'these would be left callable by nobody: %', v_orphans
      USING HINT = 'Each needs GRANT EXECUTE TO authenticated in this file, or a reason it should be unreachable. Nothing has been revoked.';
  END IF;

  IF v_total = 0 THEN
    RAISE NOTICE 'no function outside is_e164 still grants PUBLIC — this migration has run before';
  ELSE
    RAISE NOTICE
      'revoking PUBLIC from % functions: % need no grant at all (triggers), % keep a direct authenticated grant',
      v_total,
      (SELECT count(*) FROM zzz_sweep WHERE needs_no_grant),
      (SELECT count(*) FROM zzz_sweep WHERE NOT needs_no_grant);
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. The sweep
--
-- Driven from the same temp table section 1 checked, so there is no second
-- query to drift from the first. A function that passed the checks is a
-- function that gets revoked, and the set cannot differ between the two.
-- -----------------------------------------------------------------------------
DO $$
DECLARE r record; v int := 0;
BEGIN
  FOR r IN SELECT sig FROM zzz_sweep ORDER BY sig LOOP
    EXECUTE format('REVOKE EXECUTE ON ROUTINE %s FROM PUBLIC', r.sig);
    v := v + 1;
  END LOOP;
  RAISE NOTICE 'revoked PUBLIC EXECUTE from % routines', v;
END $$;

-- -----------------------------------------------------------------------------
-- 3. Record it
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM record_migration(
    '20261104T0900_public_loses_execute.sql',
    NULL,
    'PUBLIC loses EXECUTE on every function in public except is_e164 and '
    'location_type_is_service, which the system calls during writes. anon can '
    'now reach exactly those two. Nothing was granted back: authenticated '
    'already held direct grants, and trigger functions need none.');
END $$;

COMMIT;

-- =============================================================================
-- STILL TO DO
--
-- * THE acl COMPARISON SHOULD NOW MATCH IN FULL. 20261103T2100 left exactly
--   two differences — PUBLIC on section_scores and behavior_detail, which
--   production had and staging never received. This file removes them from
--   production, so the two databases should agree on every grant on every
--   relation, sequence and routine. That is the first time, and it is worth
--   running the README's acl query on both to confirm rather than assume.
--
-- * btree_gist IS STILL IN public, 188 supabase_admin-owned functions each
--   granting anon EXECUTE directly. Out of reach of any migration postgres can
--   run, and unchanged by this file. None of them reads application data; the
--   exposure is the ability to call a GiST support function. Moving the
--   extension to its own schema is a layout decision and wants a check of what
--   references those operators first.
--
-- * THE LEGACY KEY DEPRECATION is the live risk that no migration can see.
--   Supabase retires the legacy anon and service_role keys in early 2027.
--   CONFIRMED, not suspected: every webhook request on 3 November sent an
--   apikey that is a JWT carrying role service_role, issued 7 October 2026 and
--   expiring ten years on. A secret key is not a JWT and would leave those
--   fields empty, as the publishable key does on browser requests. So Vercel
--   holds the legacy key and the DialStack webhook stops the day those keys
--   are switched off. The fix is a new sb_secret_ key and a Vercel
--   environment change; no migration can see it or do it.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- DO $$
-- DECLARE r text := ''; n int;
-- BEGIN
--   r := r || 'our functions still granting PUBLIC EXECUTE: '
--          || (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--               WHERE n.nspname = 'public' AND p.prokind IN ('f','p')
--                 AND NOT EXISTS (SELECT 1 FROM pg_depend d
--                                  WHERE d.classid = 'pg_proc'::regclass
--                                    AND d.objid = p.oid AND d.deptype = 'e')
--                 AND EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
--                              WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'))
--          || '   (expect 2)' || chr(10);
--   r := r || '    which is: '
--          || COALESCE((SELECT string_agg(p.proname, ', ' ORDER BY p.proname)
--                         FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--                        WHERE n.nspname = 'public' AND p.prokind IN ('f','p')
--                          AND NOT EXISTS (SELECT 1 FROM pg_depend d
--                                           WHERE d.classid = 'pg_proc'::regclass
--                                             AND d.objid = p.oid AND d.deptype = 'e')
--                          AND EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
--                                       WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')), 'NONE')
--          || '   (expect is_e164 and location_type_is_service, and nothing '
--          || 'else. Both are kept on purpose; the header says why each)' || chr(10);
--
--   r := r || 'routines anon can EXECUTE, ours / btree_gist''s: '
--          || (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--               WHERE n.nspname = 'public' AND p.prokind IN ('f','p')
--                 AND NOT EXISTS (SELECT 1 FROM pg_depend d
--                                  WHERE d.classid = 'pg_proc'::regclass
--                                    AND d.objid = p.oid AND d.deptype = 'e')
--                 AND has_function_privilege('anon', p.oid, 'EXECUTE'))
--          || ' / '
--          || (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--               WHERE n.nspname = 'public' AND p.prokind IN ('f','p')
--                 AND EXISTS (SELECT 1 FROM pg_depend d
--                              WHERE d.classid = 'pg_proc'::regclass
--                                AND d.objid = p.oid AND d.deptype = 'e')
--                 AND has_function_privilege('anon', p.oid, 'EXECUTE'))
--          || '   (expect 2 / 188. The 188 are supabase_admin''s and no '
--          || 'migration can reach them)' || chr(10);
--
--   -- The three the webhook needs, which this file must not have touched.
--   r := r || 'service_role EXECUTE on the three server functions: '
--          || (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--               WHERE n.nspname = 'public'
--                 AND p.proname IN ('ingest_call_event','record_call_content',
--                                   'request_notify_sms_confirmation')
--                 AND has_function_privilege('service_role', p.oid, 'EXECUTE'))
--          || '   (expect 3)' || chr(10);
--   r := r || 'every routine service_role can now reach: '
--          || COALESCE((SELECT string_agg(p.proname, ', ' ORDER BY p.proname)
--                         FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--                        WHERE n.nspname = 'public' AND p.prokind IN ('f','p')
--                          AND NOT EXISTS (SELECT 1 FROM pg_depend d
--                                           WHERE d.classid = 'pg_proc'::regclass
--                                             AND d.objid = p.oid AND d.deptype = 'e')
--                          AND has_function_privilege('service_role', p.oid, 'EXECUTE')), 'NONE')
--          || chr(10)
--          || '   (expect those three plus is_e164 and location_type_is_service '
--          || '— five. 20261103T1800''s verification said four, written before '
--          || 'the second exception existed; it has since been corrected to '
--          || 'five, so the two files agree)' || chr(10);
--
--   -- The signed-in path, which is what would break if the premise were wrong.
--   r := r || 'functions authenticated can EXECUTE: '
--          || (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--               WHERE n.nspname = 'public' AND p.prokind IN ('f','p')
--                 AND NOT EXISTS (SELECT 1 FROM pg_depend d
--                                  WHERE d.classid = 'pg_proc'::regclass
--                                    AND d.objid = p.oid AND d.deptype = 'e')
--                 AND has_function_privilege('authenticated', p.oid, 'EXECUTE'))
--          || '   (expect NO CHANGE from before this ran — 107 on staging. '
--          || 'An earlier version of this line predicted the 33 trigger '
--          || 'functions would drop off; they do not, because 024''s function '
--          || 'default gave every one of them a direct authenticated grant as '
--          || 'well as PUBLIC. Nothing should drop off)' || chr(10);
--   r := r || '    the three the logs showed in use: '
--          || (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--               WHERE n.nspname = 'public'
--                 AND p.proname IN ('call_flow','picklist_for','normalize_e164')
--                 AND has_function_privilege('authenticated', p.oid, 'EXECUTE'))
--          || '   (expect 3 — every RPC the week''s logs recorded)' || chr(10);
--
--   -- A trigger still fires for a role that can no longer call its function
--   -- by name. This is the 33's whole justification, tested rather than cited.
--   CREATE TABLE zzz_public_probe (id integer, updated_at timestamptz);
--   CREATE TRIGGER zzz_touch BEFORE UPDATE ON zzz_public_probe
--     FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
--   INSERT INTO zzz_public_probe (id) VALUES (1);
--   GRANT SELECT, UPDATE ON zzz_public_probe TO authenticated;
--
--   -- Revoking PUBLIC is not enough to test this, and the first version of
--   -- this block assumed it was. All 33 trigger functions ALSO hold a direct
--   -- authenticated grant from 024's function default, so after the sweep
--   -- authenticated can still call touch_updated_at by name and the test
--   -- proved nothing — the same tautology as 20261103T2300's first probe.
--   -- Taking the direct grant away too, inside this rolled-back block, is
--   -- what the 3 November experiment did and what makes the next line mean
--   -- something.
--   REVOKE EXECUTE ON FUNCTION touch_updated_at() FROM authenticated;
--   r := r || 'authenticated can call touch_updated_at by name: '
--          || has_function_privilege('authenticated', 'public.touch_updated_at()', 'EXECUTE')::text
--          || '   (expect false — PUBLIC gone from the sweep, the direct grant '
--          || 'gone from the line above, and both undone by the rollback)' || chr(10);
--   PERFORM set_config('role', 'authenticated', true);
--   UPDATE zzz_public_probe SET id = 1;
--   PERFORM set_config('role', 'none', true);
--   r := r || '    and its trigger still fires: '
--          || (SELECT (updated_at IS NOT NULL)::text FROM zzz_public_probe WHERE id = 1)
--          || '   (expect true — the 33 need no grant, which is now shown '
--          || 'rather than asserted)' || chr(10);
--   DROP TABLE zzz_public_probe;
--
--   -- ---- as anon. Last: the role does not need to revert after this. -------
--   PERFORM set_config('role', 'anon', true);
--
--   BEGIN
--     PERFORM is_e164('+15555550123');
--     r := r || 'anon can still call is_e164: yes — correct, and the proof '
--            || 'this file left its two exceptions alone' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'anon could NOT call is_e164 (BAD): ' || SQLERRM || chr(10); END;
--
--   BEGIN
--     PERFORM normalize_e164('5555550123');
--     r := r || 'anon can still call normalize_e164 (BAD)' || chr(10);
--   EXCEPTION
--     WHEN insufficient_privilege THEN
--       r := r || 'anon refused on normalize_e164 — correct' || chr(10);
--     WHEN others THEN
--       r := r || 'anon on normalize_e164 failed for another reason, so this '
--              || 'line proves nothing: ' || SQLERRM || chr(10);
--   END;
--
--   RAISE EXCEPTION 'VERIFY 20261104T0900_public_loses_execute (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
