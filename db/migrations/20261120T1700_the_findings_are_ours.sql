-- =============================================================================
-- 20261120T1700_the_findings_are_ours.sql
-- The Hub — a firm sees its evaluations. Only Dead Ringers writes them.
--
-- WHAT IS WRONG. Eleven tables of the evaluation product carry one firm-scoped
-- FOR ALL policy each, <t>_tenant, with 024's identical WITH CHECK, and
-- authenticated holds INSERT, UPDATE and DELETE on all of them. So any member
-- of a firm, at any seniority, can rewrite Dead Ringers' findings about that
-- firm: change an observation's points, delete a lost-revenue outcome, add a
-- behaviour to the firm's rubric, or mark a reporting period delivered.
--
-- 010 says why that matters more than tidiness: "at least one client pays
-- staff compensation on these scores." A firm that can edit its own scores
-- can edit its staff's pay.
--
-- THE RULING (planning and Mandie, 20 November):
--
--   * The rubric, the focus behaviours and the scoring are Dead Ringers'
--     and proprietary. Lock them with the other evaluation tables, with no
--     product exception.
--   * Use the organizations shape (20261104T1300, 20261120T1400): FOR SELECT
--     for the firm, exactly as it reads today; FOR ALL with is_internal() for
--     writes. Not can_manage_settings(), since a manager is a member of the
--     firm being evaluated.
--   * custom_field_definitions and custom_field_values stay firm-writable and
--     aren't touched here. They're where a client's own measure belongs.
--   * A client's field is recorded alongside an evaluation and never enters
--     the score. That rule goes where the score is computed: section 3 gives
--     composite_score() and section_scores() their first comments.
--
-- THE ELEVEN:
--
--   007  rubrics, rubric_behaviors, focus_behaviors
--   008  evaluations, observations
--   009  shops, shop_interactions, outcomes
--   010  reporting_periods, report_definitions, reports
--
-- ALREADY LOCKED, checked and left alone:
--
--   behaviors, behavior_answers, rubric_sections, rubric_templates:
--     _read / _write with is_internal() since 20261103T1000.
--   shopper_forms: one FOR ALL policy with is_internal() on both sides since
--     009; the firm never sees a shopper's working notes.
--
-- NOT IN THIS FILE: transcript_segments (Mandie, 20 November). It is locked
-- for a different reason (evidence integrity, not ownership), and locking it
-- would make merge_contacts refuse for any contact who appears in a
-- transcript. That function re-points transcript_segments.contact_id as the
-- caller, and assert_merge_complete then refuses. transcript_segments gets
-- its own file, together with the redaction ruling and a deliberate path for
-- a merge to re-attribute a transcript.
--
-- focus_behaviors: 007 meant focus to be "set by the client or by a coach",
-- and focus_source has a 'client' value. After this file, a client's choice
-- of focus is entered by Dead Ringers on the client's behalf. That follows
-- from the ruling; it's recorded so nobody reads 'client' as "the client
-- wrote this row".
--
-- IT REMOVES NO WORKING FEATURE. hellophone, all 20 branches, 20 November:
-- no reference to any of the eleven. Inside the Hub, the only function that
-- writes any of them is merge_people, which refuses unless is_internal() and
-- so passes the new write policy. Foreign-key cascades and SET NULLs aren't
-- subject to row-level security, so deleting a firm, a call or a person still
-- clears what hangs off it. Writers that run as postgres or service_role hold
-- BYPASSRLS.
--
-- HOW THE READ IS PRESERVED: each table's expression is read out of the
-- catalogue and reused, never retyped. evaluations and observations keep
-- their lifecycle condition: a firm sees only completed evaluations. Section
-- 1 pins every expression by md5 first.
--
-- WHY THE GRANTS STAY: internal staff sign in as authenticated, as in
-- 20261104T1300. The policy is the lock.
--
-- Requires: 007-010, 024 (WITH CHECK), 20261103T1000, 20261120T1400 (the
--           pattern), 20261103T1200 (record_migration).
-- NOT SAFE TO RUN TWICE: section 1 stops on a second run, and says so.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Every policy is the one this file expects, and nothing else is there
--
-- One FOR ALL _tenant policy per table, TO public, WITH CHECK equal to USING,
-- and USING equal (by md5) to the expression read on scratch from the same
-- migrations. A table already converted, partly converted, or carrying any
-- other policy stops the file before it changes anything. RLS must be on and
-- FORCEd: without FORCE the owner walks past the lock this file installs.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  want CONSTANT jsonb := jsonb_build_object(
    'evaluations',        '59e89fff537a8069545ce26a754ca085',
    'observations',       'd2e8db8d16253503444411d251d5cc3c',
    'rubric_behaviors',   '2e3360ea8675f2128085835b6740224c',
    'shop_interactions',  '12470570126ce8ba5d6a9c2a4ec973bd',
    'focus_behaviors',    'e001fae7c6dc9ee510219d97d074882b',
    'outcomes',           'e001fae7c6dc9ee510219d97d074882b',
    'report_definitions', 'e001fae7c6dc9ee510219d97d074882b',
    'reporting_periods',  'e001fae7c6dc9ee510219d97d074882b',
    'reports',            'e001fae7c6dc9ee510219d97d074882b',
    'rubrics',            'e001fae7c6dc9ee510219d97d074882b',
    'shops',              'e001fae7c6dc9ee510219d97d074882b');
  t text; v_n int; v_ok boolean; v_md5 text; v_new int := 0;
BEGIN
  FOR t IN SELECT jsonb_object_keys(want) LOOP
    SELECT count(*),
           bool_and(p.polname = t || '_tenant' AND p.polcmd = '*' AND p.polroles = '{0}'
                    AND pg_get_expr(p.polqual, p.polrelid) = pg_get_expr(p.polwithcheck, p.polrelid)),
           md5(string_agg(pg_get_expr(p.polqual, p.polrelid), ''))
      INTO v_n, v_ok, v_md5
      FROM pg_policy p WHERE p.polrelid = format('public.%I', t)::regclass;

    IF v_n = 2 AND EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = format('public.%I', t)::regclass
                                                     AND polname = t || '_write') THEN
      v_new := v_new + 1;
    ELSIF NOT (v_n = 1 AND v_ok AND v_md5 = want ->> t) THEN
      RAISE EXCEPTION '% carries % policies, not the expected % _tenant (expression md5 %); stop and read them',
        t, v_n, t, v_md5
        USING HINT = 'Expected one FOR ALL policy TO public, WITH CHECK equal to USING, USING md5 ' || (want ->> t) || '.';
    END IF;
  END LOOP;

  IF v_new = 11 THEN
    RAISE EXCEPTION 'already converted; nothing to do here'
      USING HINT = 'This migration has run on this database. Not an error to fix — stop.';
  ELSIF v_new > 0 THEN
    RAISE EXCEPTION '% of the eleven tables are converted and the rest are not; an interrupted run. Stop and read them', v_new;
  END IF;

  IF (SELECT count(*) FROM pg_class
       WHERE relnamespace = 'public'::regnamespace
         AND relname IN (SELECT jsonb_object_keys(want))
         AND relrowsecurity AND relforcerowsecurity) <> 11 THEN
    RAISE EXCEPTION 'row-level security is not enabled and FORCEd on all eleven tables; stop and look';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. Read as before, write only if internal: the organizations shape
-- -----------------------------------------------------------------------------
DO $$
DECLARE t text; v_qual text;
BEGIN
  FOREACH t IN ARRAY ARRAY['rubrics', 'rubric_behaviors', 'focus_behaviors',
                           'evaluations', 'observations',
                           'shops', 'shop_interactions', 'outcomes',
                           'reporting_periods', 'report_definitions', 'reports'] LOOP
    SELECT pg_get_expr(polqual, polrelid) INTO v_qual
      FROM pg_policy
     WHERE polrelid = format('public.%I', t)::regclass AND polname = t || '_tenant';

    EXECUTE format('DROP POLICY %I ON public.%I', t || '_tenant', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (%s)',
                   t || '_read', t, v_qual);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR ALL USING (is_internal()) WITH CHECK (is_internal())',
                   t || '_write', t);
    EXECUTE format('COMMENT ON POLICY %I ON public.%I IS %L', t || '_read', t,
      'The firm reads this as before: the earlier _tenant policy''s expression, '
      'carried across unchanged and now FOR SELECT (20261120T1700).');
    EXECUTE format('COMMENT ON POLICY %I ON public.%I IS %L', t || '_write', t,
      'Only Dead Ringers writes the evaluation product. As FOR ALL, any member of '
      'the firm could rewrite Dead Ringers'' findings about it, and at least one '
      'client pays staff on these scores (010). Grants stay, because internal '
      'staff are authenticated too; this policy is the lock (20261120T1700).');
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- 3. Where the score is computed, the rule about what enters it
-- -----------------------------------------------------------------------------
COMMENT ON FUNCTION composite_score(uuid) IS
  'An evaluation''s score, from Dead Ringers'' observations against Dead '
  'Ringers'' rubric. A client''s own fields (custom_field_values, when they '
  'attach to evaluations) are recorded alongside an evaluation and never enter '
  'this score or any other. That keeps "the client can add a measure" from '
  'colliding with "the scoring is ours" (Mandie, 20 November; 20261120T1700).';

COMMENT ON FUNCTION section_scores(uuid, date, date) IS
  'Section scores for a firm over a period, from Dead Ringers'' observations. '
  'A client''s own fields are recorded alongside an evaluation and never enter '
  'a score, here or in composite_score() (Mandie, 20 November; '
  '20261120T1700).';

-- -----------------------------------------------------------------------------
-- 4. Record it
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261120T1700_the_findings_are_ours.sql',
    NULL,
    'Eleven evaluation-product tables had FOR ALL _tenant policies. Split into '
    '_read (FOR SELECT, same expression) and _write (is_internal()), as '
    '20261104T1300 and 20261120T1400. Grants unchanged. The score functions '
    'state that client fields never enter a score. transcript_segments is left '
    'for its own file.');
END $rec$;

COMMIT;

-- =============================================================================
-- Verification — run AFTER the file, as its own statement. One block,
-- everything rolled back by the closing RAISE.
--
-- A fixture firm gets one row in each of the eleven tables, made by Dead
-- Ringers. Then a professional at the firm, and then a manager
-- (can_manage_settings() true), each in a pass that undoes itself (ZZ001),
-- try every table: read the row, UPDATE it, DELETE it, INSERT a copy. Then the
-- positive half: Dead Ringers, still authenticated, can update every table.
-- Without that, a policy that locked everyone out would pass too. Every write
-- runs as authenticated, because postgres holds BYPASSRLS.
--
-- The evaluation is complete, because a firm reads only completed
-- evaluations and their observations. That condition is carried across
-- unchanged, and line 1 checks it.
--
-- DO $$
-- DECLARE
--   r text := ''; n int; m int; t text; p text; w text; ins text; rd text; up text; de text;
--   v_org uuid; v_user uuid; v_auth uuid := gen_random_uuid(); v_i1 uuid; v_i2 uuid;
--   v_sec uuid; v_beh uuid; v_rub uuid; v_eval uuid; v_shop uuid;
--   k_rb uuid; k_fb uuid; k_ob uuid; k_oc uuid; k_rp uuid; k_rd uuid; k_re uuid;
--   keys jsonb;
-- BEGIN
--   r := r || 'policies now:' || chr(10) || COALESCE((
--          SELECT string_agg('    ' || rpad(c.relname, 20) || string_agg_p, chr(10) ORDER BY c.relname)
--            FROM (SELECT p.polrelid, string_agg(p.polname || '(' || p.polcmd::text || ')', ' ' ORDER BY p.polname) AS string_agg_p
--                    FROM pg_policy p GROUP BY p.polrelid) x
--            JOIN pg_class c ON c.oid = x.polrelid
--           WHERE c.relnamespace = 'public'::regnamespace
--             AND c.relname IN ('rubrics','rubric_behaviors','focus_behaviors','evaluations','observations','shops',
--                               'shop_interactions','outcomes','reporting_periods','report_definitions','reports')), 'NONE')
--        || chr(10) || '   (expect <t>_read(r) <t>_write(*) on each of the eleven, nothing else)' || chr(10);
--   r := r || 'transcript_segments still carries: '
--          || (SELECT string_agg(polname || '(' || polcmd::text || ')', ' ') FROM pg_policy
--               WHERE polrelid = 'public.transcript_segments'::regclass)
--          || '   (expect transcript_segments_tenant(*): not this file''s)' || chr(10);
--   r := r || 'the score functions carry the client-field rule: '
--          || COALESCE(obj_description('composite_score(uuid)'::regprocedure, 'pg_proc') LIKE '%never enter this score%'
--              AND obj_description('section_scores(uuid, date, date)'::regprocedure, 'pg_proc') LIKE '%never enter%', false)
--          || '   (expect true)' || chr(10);
--
--   -- ---- the fixture, as Dead Ringers -------------------------------------
--   PERFORM set_config('app.is_internal', 'on', true);
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ verify 1700', 'funeral_home') RETURNING id INTO v_org;
--   INSERT INTO users (email, full_name, auth_user_id)
--   VALUES ('zzz-verify-1700@example.invalid', 'ZZZ Verification', v_auth) RETURNING id INTO v_user;
--   INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id)
--   VALUES (v_user, 'organization', 'professional', v_org);
--   INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at)
--   VALUES (v_org, 'inbound', now(), now()) RETURNING id INTO v_i1;
--   INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at)
--   VALUES (v_org, 'inbound', now(), now()) RETURNING id INTO v_i2;
--   INSERT INTO rubric_sections (code, label, score_category, display_order)
--   VALUES ('zzz_1700', 'ZZZ', 'objective', 999) RETURNING id INTO v_sec;
--   INSERT INTO behaviors (code, label, section_id, score_category, answered_by)
--   VALUES ('zzz_1700', 'ZZZ', v_sec, 'objective', 'reviewer') RETURNING id INTO v_beh;
--   INSERT INTO rubrics (organization_id, name, version) VALUES (v_org, 'ZZZ', '1') RETURNING id INTO v_rub;
--   INSERT INTO evaluations (organization_id, rubric_id, interaction_id, lifecycle_state, reviewed_by, completed_at)
--   VALUES (v_org, v_rub, v_i1, 'complete', 'ZZZ', now()) RETURNING id INTO v_eval;
--   INSERT INTO shops (organization_id) VALUES (v_org) RETURNING id INTO v_shop;
--   INSERT INTO rubric_behaviors (rubric_id, behavior_id, possible_points, answered_by)
--   VALUES (v_rub, v_beh, 1, 'reviewer') RETURNING id INTO k_rb;
--   INSERT INTO focus_behaviors (organization_id, behavior_id, focus_source)
--   VALUES (v_org, v_beh, 'client') RETURNING id INTO k_fb;
--   INSERT INTO observations (organization_id, evaluation_id, behavior_id, opportunity, source)
--   VALUES (v_org, v_eval, v_beh, true, 'reviewer') RETURNING id INTO k_ob;
--   INSERT INTO shop_interactions (shop_id, interaction_id, attempt_number) VALUES (v_shop, v_i1, 1);
--   INSERT INTO outcomes (organization_id, interaction_id, outcome_type, valuation_method)
--   VALUES (v_org, v_i1, 'unknown', 'unvalued') RETURNING id INTO k_oc;
--   INSERT INTO reporting_periods (organization_id, period_start, period_end)
--   VALUES (v_org, DATE '1999-01-01', DATE '1999-01-31') RETURNING id INTO k_rp;
--   INSERT INTO report_definitions (organization_id, name, audience)
--   VALUES (v_org, 'ZZZ', 'owner') RETURNING id INTO k_rd;
--   INSERT INTO reports (organization_id, audience) VALUES (v_org, 'owner') RETURNING id INTO k_re;
--   -- Each table: the WHERE that finds its one row, and for an INSERT the key
--   -- to change in the copy (id; for shop_interactions, the call).
--   keys := jsonb_build_object(
--     'rubrics',            jsonb_build_object('w', format('id = %L', v_rub)),
--     'rubric_behaviors',   jsonb_build_object('w', format('id = %L', k_rb)),
--     'focus_behaviors',    jsonb_build_object('w', format('id = %L', k_fb)),
--     'evaluations',        jsonb_build_object('w', format('id = %L', v_eval)),
--     'observations',       jsonb_build_object('w', format('id = %L', k_ob)),
--     'shops',              jsonb_build_object('w', format('id = %L', v_shop)),
--     'shop_interactions',  jsonb_build_object('w', format('shop_id = %L AND interaction_id = %L', v_shop, v_i1),
--                                              'k', 'interaction_id', 'v', v_i2),
--     'outcomes',           jsonb_build_object('w', format('id = %L', k_oc)),
--     'reporting_periods',  jsonb_build_object('w', format('id = %L', k_rp)),
--     'report_definitions', jsonb_build_object('w', format('id = %L', k_rd)),
--     'reports',            jsonb_build_object('w', format('id = %L', k_re)));
--   PERFORM set_config('app.is_internal', 'off', true);
--
--   PERFORM set_config('request.jwt.claims', json_build_object('sub', v_auth::text)::text, true);
--   PERFORM set_config('role', 'authenticated', true);
--
--   FOREACH p IN ARRAY ARRAY['professional', 'manager'] LOOP
--    BEGIN
--     IF p = 'manager' THEN
--       PERFORM set_config('role', 'none', true);
--       UPDATE user_scopes SET view_profile = 'manager' WHERE user_id = v_user;
--       PERFORM set_config('role', 'authenticated', true);
--     END IF;
--     r := r || '-- as a ' || p || ' (can_manage_settings ' || can_manage_settings() || ')'
--            || '   table: read / update / delete / insert   (expect 1 / 0 / 0 / 42501 on every line)' || chr(10);
--     FOR t, w IN SELECT key, value ->> 'w' FROM jsonb_each(keys) ORDER BY key LOOP
--       EXECUTE format('SELECT count(*) FROM public.%I WHERE %s', t, w) INTO n; rd := n::text;
--       EXECUTE format('UPDATE public.%I SET %s = %s WHERE %s', t,
--                      COALESCE(keys -> t ->> 'k', 'id'), COALESCE(keys -> t ->> 'k', 'id'), w);
--       GET DIAGNOSTICS n = ROW_COUNT; up := n::text;
--       BEGIN
--         EXECUTE format('INSERT INTO public.%I SELECT (jsonb_populate_record(NULL::public.%I, to_jsonb(x) || %L::jsonb)).* FROM public.%I x WHERE %s',
--                        t, t, jsonb_build_object(COALESCE(keys -> t ->> 'k', 'id'), COALESCE(keys -> t ->> 'v', gen_random_uuid()::text)), t, w);
--         GET DIAGNOSTICS n = ROW_COUNT;
--         ins := CASE WHEN n = 0 THEN 'nothing to copy' ELSE 'ALLOWED' END;
--       EXCEPTION
--         WHEN insufficient_privilege THEN ins := SQLSTATE;
--         WHEN OTHERS THEN ins := 'ALLOWED, then ' || SQLSTATE;   -- the policy let it through
--       END;
--       BEGIN
--         EXECUTE format('DELETE FROM public.%I WHERE %s', t, w);
--         GET DIAGNOSTICS n = ROW_COUNT; de := n::text;
--       EXCEPTION WHEN foreign_key_violation THEN
--         de := 'ALLOWED, then 23503';   -- the policy let it through; a foreign key stopped it
--       END;
--       r := r || '    ' || rpad(t, 19) || rd || ' / ' || up || ' / ' || de || ' / ' || ins || chr(10);
--     END LOOP;
--     RAISE EXCEPTION USING ERRCODE = 'ZZ001';
--    EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
--    END;
--   END LOOP;
--
--   -- ---- the positive half: Dead Ringers, still authenticated -------------
--   PERFORM set_config('app.is_internal', 'on', true);
--   m := 0;
--   FOR t, w IN SELECT key, value ->> 'w' FROM jsonb_each(keys) LOOP
--     EXECUTE format('UPDATE public.%I SET %s = %s WHERE %s', t,
--                    COALESCE(keys -> t ->> 'k', 'id'), COALESCE(keys -> t ->> 'k', 'id'), w);
--     GET DIAGNOSTICS n = ROW_COUNT; m := m + n;
--   END LOOP;
--   r := r || '-- as Dead Ringers (authenticated, app.is_internal on): tables updated '
--          || m || ' of 11   (expect 11)' || chr(10);
--   DELETE FROM reports WHERE organization_id = v_org;
--   GET DIAGNOSTICS n = ROW_COUNT;
--   r := r || '   and can delete a report: ' || n || '   (expect 1)' || chr(10);
--   PERFORM set_config('app.is_internal', 'off', true);
--
--   -- the read condition carried across: an evaluation that isn't complete stays unseen
--   PERFORM set_config('role', 'none', true);
--   UPDATE evaluations SET lifecycle_state = 'final_review', reviewed_by = NULL, completed_at = NULL WHERE id = v_eval;
--   PERFORM set_config('role', 'authenticated', true);
--   SELECT count(*) INTO n FROM evaluations WHERE id = v_eval;
--   SELECT count(*) INTO m FROM observations WHERE evaluation_id = v_eval;
--   r := r || '1. an evaluation in final review, seen by the firm: ' || n || ', its observations: ' || m
--          || '   (expect 0, 0: unchanged from before)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261120T1700_the_findings_are_ours (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
