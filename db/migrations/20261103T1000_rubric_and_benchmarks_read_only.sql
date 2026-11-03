-- =============================================================================
-- 20261103T1000_rubric_and_benchmarks_read_only.sql
-- The Hub — the scoring methodology is not something a client may edit.
--
-- WHAT IS WRONG, on production, today. Six tables carry a single policy that
-- admits every command:
--
--   behavior_answers, behaviors, rubric_sections, rubric_templates,
--   scoring_model_versions, benchmark_snapshots
--
--     CREATE POLICY <t>_readable ON <t> USING (true);
--
-- A policy written with no FOR clause is FOR ALL, and USING (true) with no
-- WITH CHECK means the same expression governs writes. 024's table defaults
-- then gave `authenticated` INSERT, UPDATE and DELETE on every table in
-- public. So any signed-in person at any firm can rewrite or delete the
-- scoring model and the cross-firm benchmark rows — the numbers every client
-- is measured against, and the ones Dead Ringers sells.
--
-- On staging `anon` can as well, and the staging anon key ships in every
-- preview bundle.
--
-- The name is the tell. "readable" is what it was for; FOR ALL is what it
-- says. Nothing in hellophone writes these tables, so nothing has exercised
-- the difference, and nothing would have noticed.
--
-- WHY THESE SIX ARE WORLD-READABLE AND THAT IS CORRECT. None has an
-- organization_id. The rubric is one shared instrument — 018's principle,
-- that a Dead Ringers default means the same thing at every firm, is what
-- lets it carry a benchmark at all — and benchmark_snapshots is the
-- cross-client aggregate clients are meant to compare themselves against,
-- holding counts rather than identities (contributing_orgs is a number). So
-- every signed-in person may read them. Nobody signed in may write them.
--
-- WHY THERE IS A WRITE POLICY AND NOT JUST A SELECT ONE. Not to let the seeds
-- through: postgres and service_role both hold BYPASSRLS on both databases, so
-- policies never constrain them, and 024's FORCE does not change that — FORCE
-- removes the owner's implicit exemption, not the role attribute. The seeds
-- would have run either way.
--
-- It is there as a second lock on the API roles. Revoking the grants is what
-- stops a client user today. The policy is what stops the next stray GRANT
-- from quietly reopening the door that 024's table defaults opened the first
-- time: with is_internal() in the way, a GRANT UPDATE … TO authenticated buys
-- nothing, because every client session evaluates it false. That is the whole
-- of its job. It constrains no server path and no migration.
--
-- Requires, by what it actually uses:
--   007  behaviors, behavior_answers, rubric_sections, rubric_templates
--   010  scoring_model_versions, benchmark_snapshots
--   024  the grants being removed (and the FORCE flag section 1 checks)
--   001  is_internal()
--
-- Safe to run twice: the precondition tells "not yet done" from "already
-- done" from "something else", and refuses the third.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. They are what this file expects
--
-- Three states per table, like a function drift check: the original single
-- <t>_readable policy, the pair this installs, or something else — and
-- something else stops, because a policy nobody has read is not a policy to
-- replace blind.
--
-- FORCE is asserted, but nothing here depends on it: postgres has BYPASSRLS,
-- so the owner skips policies whether a table is forced or not. It is checked
-- only because 024 set it on all six and a table that has lost it has been
-- moved by something this file doesn't know about — the same reason the
-- policy check is three-state. It is a tell, not a load-bearing precondition.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  t text;
  v_tables constant text[] := ARRAY[
    'behavior_answers', 'behaviors', 'rubric_sections', 'rubric_templates',
    'scoring_model_versions', 'benchmark_snapshots'];
  v_done int := 0; v_todo int := 0;
  r record;
BEGIN
  FOREACH t IN ARRAY v_tables LOOP
    SELECT c.relrowsecurity, c.relforcerowsecurity INTO r
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = t;
    IF NOT FOUND THEN
      RAISE EXCEPTION '% does not exist; run 007 and 010 first', t;
    END IF;
    IF NOT r.relrowsecurity OR NOT r.relforcerowsecurity THEN
      RAISE EXCEPTION 'row-level security is not enabled AND forced on %; 024 should have done both, so stop and look', t;
    END IF;

    IF EXISTS (SELECT 1 FROM pg_policy
                WHERE polrelid = format('public.%I', t)::regclass
                  AND polname = t || '_read') THEN
      v_done := v_done + 1;
    ELSIF EXISTS (SELECT 1 FROM pg_policy
                   WHERE polrelid = format('public.%I', t)::regclass
                     AND polname = t || '_readable'
                     AND polcmd = '*'
                     AND pg_get_expr(polqual, polrelid) = 'true') THEN
      v_todo := v_todo + 1;
    ELSE
      RAISE EXCEPTION
        '%''s policies are neither 007/010''s <t>_readable nor this migration''s pair; stop and compare', t
        USING HINT = 'Read pg_policy for that table before replacing anything.';
    END IF;
  END LOOP;

  IF v_done = array_length(v_tables, 1) THEN
    RAISE NOTICE 'all six are already read-only — this migration has run before';
  ELSIF v_todo <> array_length(v_tables, 1) THEN
    RAISE EXCEPTION 'the six are in mixed states (% converted, % not); stop and look', v_done, v_todo;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. Read for everyone signed in, write for nobody but Dead Ringers
--
-- Two policies rather than one, because they answer different questions. The
-- read policy is TO authenticated, so anon matches no SELECT policy at all
-- and is refused by RLS as well as by the revoked grant. The write policy is
-- TO public — meaning it is evaluated for every role — and admits only
-- is_internal(), which is false for every client user and for anon, and true
-- for Dead Ringers staff and for a migration that has said so.
--
-- A client user therefore fails twice on a write: no privilege, and no
-- policy. That is on purpose. The grant is what 024 gave away by default, and
-- the policy is what stops the next default from giving it away again.
--
-- Neither policy touches postgres or service_role, which hold BYPASSRLS. The
-- server and the seeds are unaffected by this section; only the REVOKEs below
-- reach service_role, and only TRUNCATE and the write privileges it never
-- used.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  t text;
  v_tables constant text[] := ARRAY[
    'behavior_answers', 'behaviors', 'rubric_sections', 'rubric_templates',
    'scoring_model_versions', 'benchmark_snapshots'];
BEGIN
  FOREACH t IN ARRAY v_tables LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_readable', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_read', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_write', t);

    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (true)',
      t || '_read', t);
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR ALL USING (is_internal()) WITH CHECK (is_internal())',
      t || '_write', t);

    EXECUTE format(
      'COMMENT ON POLICY %I ON public.%I IS %L',
      t || '_read', t,
      'Everyone signed in may read this: it has no organization_id because it '
      'is one shared instrument, and a rubric that meant something different '
      'at each firm could not carry a benchmark. TO authenticated, so anon '
      'matches no SELECT policy at all.');
    EXECUTE format(
      'COMMENT ON POLICY %I ON public.%I IS %L',
      t || '_write', t,
      'Only Dead Ringers writes the scoring methodology. Replaced a FOR ALL '
      'USING (true) policy that let any signed-in person at any firm rewrite '
      'it. The revoked grants are what stop a client user today; this policy '
      'is the second lock, so that a future stray GRANT to authenticated '
      'cannot quietly reopen what 024''s table defaults opened once already. '
      'It constrains no server path: postgres and service_role hold BYPASSRLS '
      'and never evaluate it.');

    -- The grants 024's defaults handed out. SELECT stays for authenticated
    -- and goes for anon; everything that writes goes for all three.
    EXECUTE format(
      'REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.%I FROM authenticated, anon, service_role', t);
    EXECUTE format('REVOKE SELECT ON public.%I FROM anon', t);
  END LOOP;
END $$;

COMMIT;

-- =============================================================================
-- STILL TO DO, named so they aren't folded in and skipped
--
-- * NOTHING IS NEEDED IN THE SEEDS. An earlier draft of this file said three
--   of them had to start setting app.is_internal, on the assumption that 024's
--   FORCE made the owner subject to these policies. It doesn't: FORCE removes
--   the owner's implicit exemption, and BYPASSRLS, which postgres holds on both
--   databases, sits above both. Written down because the mistake is easy to
--   make again and the symptom would have been a seed run failing for a reason
--   nobody was looking for.
--
-- * IF DEAD RINGERS EVER EDIT THE RUBRIC IN THE APP, this needs a grant as
--   well as the policy: internal staff sign in as `authenticated` like
--   everyone else, so the revoke above stops them too. That is deliberate —
--   nothing in hellophone writes these tables today — but it means "give
--   internal users rubric editing" is a migration, not a UI change.
--
-- * WHETHER ANYONE HAS WRITTEN THESE TABLES THROUGH THE API is not answerable
--   from the schema. Supabase's API logs would show it and their retention is
--   short, so it is worth looking now rather than later if it is worth
--   knowing at all.
--
-- * service_role HOLDS TRUNCATE ON EVERY PRODUCTION TABLE, which bypasses
--   RLS entirely. Removed here for these six; the other 91 are a separate
--   decision, with the rest of the service_role alignment.
--
-- * THE anon SWEEP AND THE DEFAULTS are the next file: anon holds table
--   privileges on 92 staging relations and EXECUTE on 68 functions through
--   PUBLIC on both databases. This file closes the live write path on the six
--   tables that have no business being writable; it does not close that.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- Writes are tested with no-op UPDATEs (SET id = id), so a policy or grant
-- that lets one through changes nothing even before the rollback.
--
-- The two locks are tested separately, because they fail differently: a
-- missing grant raises 42501 and a refusing policy returns 0 rows. The owner
-- tests prove nothing about either — postgres has BYPASSRLS — and are here to
-- show that, since an earlier draft of this file read them the other way.
--
-- DO $$
-- DECLARE
--   r text := ''; t text; n int;
--   v_tables constant text[] := ARRAY[
--     'behavior_answers', 'behaviors', 'rubric_sections', 'rubric_templates',
--     'scoring_model_versions', 'benchmark_snapshots'];
-- BEGIN
--   PERFORM set_config('app.is_internal', 'on', true);
--
--   r := r || 'policies per table:' || chr(10);
--   FOREACH t IN ARRAY v_tables LOOP
--     r := r || '    ' || rpad(t, 24) || COALESCE((
--            SELECT string_agg(polname || '(' || polcmd::text || ')', ', ' ORDER BY polname)
--              FROM pg_policy WHERE polrelid = format('public.%I', t)::regclass), 'NONE')
--          || chr(10);
--   END LOOP;
--   r := r || '   (expect <t>_read(r) and <t>_write(*) on each)' || chr(10);
--
--   r := r || 'anon SELECT / authenticated UPDATE still granted anywhere: '
--          || (SELECT count(*) FROM unnest(v_tables) x
--               WHERE has_table_privilege('anon', 'public.' || x, 'SELECT'))
--          || ' / '
--          || (SELECT count(*) FROM unnest(v_tables) x
--               WHERE has_table_privilege('authenticated', 'public.' || x, 'UPDATE'))
--          || '   (expect 0 / 0)' || chr(10);
--   r := r || 'authenticated SELECT kept: '
--          || (SELECT count(*) FROM unnest(v_tables) x
--               WHERE has_table_privilege('authenticated', 'public.' || x, 'SELECT'))
--          || '   (expect 6)' || chr(10);
--
--   -- The owner writes regardless of the policy, because postgres holds
--   -- BYPASSRLS. Both of these should return every row: the second is NOT a
--   -- test of the write policy, it is the demonstration that the policy never
--   -- reaches the owner, which is why the seeds need no change.
--   UPDATE behaviors SET id = id WHERE true;
--   GET DIAGNOSTICS n = ROW_COUNT;
--   r := r || 'owner update, is_internal on:  ' || n || ' rows   (expect all)' || chr(10);
--   PERFORM set_config('app.is_internal', 'off', true);
--   UPDATE behaviors SET id = id WHERE true;
--   GET DIAGNOSTICS n = ROW_COUNT;
--   r := r || 'owner update, is_internal off: ' || n || ' rows'
--          || '   (expect all — BYPASSRLS, not a policy failure)' || chr(10);
--
--   -- The readers that matter keep working. Four arguments per Code's run;
--   -- substitute the live signature if it has moved.
--   BEGIN
--     PERFORM count(*) FROM behavior_rates(NULL, NULL, NULL, NULL);
--     r := r || 'behavior_rates still runs' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'behavior_rates NOT TESTED (its signature may differ): '
--            || SQLERRM || chr(10); END;
--
--   -- The second lock, tested properly. Hand authenticated the privilege this
--   -- migration just took away — the stray GRANT the policy exists for — and
--   -- see the policy refuse the write anyway. Rolled back with the rest.
--   GRANT UPDATE ON rubric_sections TO authenticated;
--
--   -- ---- as a signed-in user, then as anon -----------------------------------
--   -- Last: the role does not revert inside this block.
--   PERFORM set_config('app.is_internal', 'off', true);
--   PERFORM set_config('role', 'authenticated', true);
--
--   r := r || 'authenticated can read behaviors: ';
--   BEGIN
--     SELECT count(*) INTO n FROM behaviors;
--     r := r || n || ' rows   (expect the rubric)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'REFUSED (BAD): ' || SQLERRM || chr(10); END;
--
--   BEGIN
--     UPDATE behaviors SET id = id WHERE true;
--     GET DIAGNOSTICS n = ROW_COUNT;
--     r := r || 'authenticated no-op update: ALLOWED, ' || n || ' rows (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'authenticated write refused: ' || SQLERRM || chr(10); END;
--
--   BEGIN
--     DELETE FROM benchmark_snapshots WHERE false;
--     r := r || 'authenticated delete on benchmarks: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'authenticated delete on benchmarks refused' || chr(10); END;
--
--   -- rubric_sections, where the grant was handed back above. This one must
--   -- NOT be refused — it must be allowed and change nothing, which is the
--   -- write policy doing the only job it has.
--   BEGIN
--     UPDATE rubric_sections SET id = id WHERE true;
--     GET DIAGNOSTICS n = ROW_COUNT;
--     r := r || 'authenticated update WITH the grant restored: ' || n || ' rows'
--            || '   (expect 0 — the policy, not the grant)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'authenticated update WITH the grant restored: REFUSED (BAD — '
--            || 'the grant should have made this reach the policy): '
--            || SQLERRM || chr(10); END;
--
--   PERFORM set_config('role', 'anon', true);
--   BEGIN
--     SELECT count(*) INTO n FROM behaviors;
--     r := r || 'anon can read behaviors: ' || n || ' rows (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'anon read refused: ' || SQLERRM || chr(10); END;
--
--   RAISE EXCEPTION 'VERIFY 20261103T1000_rubric_and_benchmarks_read_only (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
