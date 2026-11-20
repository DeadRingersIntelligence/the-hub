-- =============================================================================
-- 20261120T1400_what_a_firm_has_bought.sql
-- The Hub — a firm sees what it has bought. Only Dead Ringers changes it.
--
-- WHAT IS WRONG. Three policies, same shape as the four 20261104T1300 fixed:
--
--   organization_capabilities_tenant   (002)
--   retention_policies_tenant          (002)
--   client_entitlements_tenant         (009)
--
--   each  USING (is_internal() OR organization_id = current_organization_id())
--   with no FOR clause, so FOR ALL; 024 copied the same expression into WITH
--   CHECK, and authenticated holds INSERT, UPDATE and DELETE. WITH CHECK
--   stopped a firm writing ANOTHER firm's rows, never its own. ANY signed-in member of a firm — not a manager, any seniority — can
--   switch on a capability the firm has not bought, raise its purchased
--   quantity of evaluations or shops, or change its retention and storage-fee
--   terms. Confirmed live on both databases (planning, 20 November), and on a
--   scratch copy a professional enabled evaluations for their own firm.
--
--   This matters more from tomorrow than today: 20261120T1510 makes
--   organization_capabilities decide whether a firm has cases at all, and the
--   database's refusal is only as good as the row it reads.
--
-- THE RULING (planning, 20 November): copy organizations' shape —
-- 20261104T1300 — rather than inventing one. FOR SELECT for the firm's read,
-- unchanged; FOR ALL with is_internal() for writes. Ask of each table "is this
-- the firm's data, or Dead Ringers' configuration?" and change only the
-- second kind. Not can_manage_settings(): a manager buying themselves shops is
-- the same hole one rung up.
--
-- WHICH TABLES, AND WHY THESE THREE.
--
--   organization_capabilities  what the firm has bought. Named by planning.
--   client_entitlements        how much of it.         Named by planning.
--   retention_policies         how long recordings and transcripts are kept,
--                              and whether the storage fee applies. The fee is
--                              commercial; the months are what the agreement
--                              says. THIS ONE IS MY JUDGMENT, not planning's
--                              — strike it at review if a firm should set its
--                              own retention, and the file still stands on
--                              the other two.
--
-- Of the 59 tables carrying a firm-scoped FOR ALL policy writable by
-- authenticated, the rest were left alone. Most are plainly the firm's own
-- data (cases, contacts, interactions, settings lists), where FOR ALL is the
-- house pattern and correct. Two groups are NOT obviously the firm's and are
-- listed for a ruling rather than changed here:
--
--   * the evaluation product — evaluations, observations, shops,
--     shop_interactions, outcomes, reports, report_definitions,
--     reporting_periods, rubrics, rubric_behaviors, focus_behaviors. Written
--     by Dead Ringers' evaluators about the firm; a firm editing its own
--     scores is the same shape of problem.
--   * partner_access — which consultancies may see the firm's data. Arguably
--     the firm's consent to give, so arguably theirs.
--
-- IT REMOVES NO WORKING FEATURE. hellophone, every branch, 20 November: no
-- reference to any of the three tables. Nothing in the Hub writes them as
-- INVOKER — the only INSERTs in db/migrations are in 002's commented examples.
-- A SECURITY DEFINER writer (20261120T1510's setup default will be one) runs as
-- postgres and is unaffected.
--
-- WHY THE GRANTS STAY: as in 20261104T1300, internal staff sign in as
-- authenticated, so the privilege stays and the policy is the lock.
--
-- HOW THE READ IS PRESERVED: read out of the catalogue and reused, not retyped
-- — and section 1 checks it is exactly the expression this file expects first.
--
-- Requires: 002, 009, 024 (WITH CHECK; is_internal), 20261103T1200 (record_migration).
-- Safe to run twice: a second run stops in section 1 and says so.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. The three policies are the ones this file expects, and nothing else
--
-- All three tables in the same state or stop: one converted and two not means
-- an interrupted run, to be read rather than resumed.
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_old int; v_new int; v_total int;
BEGIN
  SELECT count(*) FILTER (
           WHERE p.polname = c.relname || '_tenant'
             AND p.polcmd = '*'
             AND p.polroles = '{0}'
             AND pg_get_expr(p.polqual, p.polrelid)
                 = '(is_internal() OR (organization_id = current_organization_id()))'
             AND pg_get_expr(p.polwithcheck, p.polrelid)
                 = '(is_internal() OR (organization_id = current_organization_id()))'),
         count(*) FILTER (WHERE p.polname IN (c.relname || '_read', c.relname || '_write')),
         count(*)
    INTO v_old, v_new, v_total
    FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
   WHERE p.polrelid IN ('public.organization_capabilities'::regclass,
                        'public.client_entitlements'::regclass,
                        'public.retention_policies'::regclass);

  IF v_new = 6 AND v_total = 6 THEN
    RAISE EXCEPTION 'already converted; nothing to do here'
      USING HINT = 'This migration has run on this database. Not an error to fix — stop.';
  ELSIF NOT (v_old = 3 AND v_total = 3) THEN
    RAISE EXCEPTION
      'the three tables carry % policies, % of them the expected _tenant shape; stop and read them',
      v_total, v_old
      USING HINT = 'Expected one FOR ALL _tenant policy each, TO public, USING '
                   '(is_internal() OR organization_id = current_organization_id()), '
                   'WITH CHECK the same (024 added it), and nothing else.';
  END IF;

  IF (SELECT count(*) FROM pg_class
       WHERE oid IN ('public.organization_capabilities'::regclass,
                     'public.client_entitlements'::regclass,
                     'public.retention_policies'::regclass)
         AND relrowsecurity) <> 3 THEN
    RAISE EXCEPTION 'row-level security is not enabled on all three tables; stop and look';
  END IF;

  -- FORCE as well: this file makes the policy the lock, and without FORCE the
  -- table's owner walks past it.
  IF (SELECT count(*) FROM pg_class
       WHERE oid IN ('public.organization_capabilities'::regclass,
                     'public.client_entitlements'::regclass,
                     'public.retention_policies'::regclass)
         AND relforcerowsecurity) <> 3 THEN
    RAISE EXCEPTION 'row-level security is not FORCEd on all three tables; stop and look';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. Read as before, write only if internal — 20261104T1300's shape exactly
-- -----------------------------------------------------------------------------
DO $$
DECLARE t text; v_qual text;
BEGIN
  FOREACH t IN ARRAY ARRAY['organization_capabilities', 'client_entitlements',
                           'retention_policies'] LOOP
    SELECT pg_get_expr(polqual, polrelid) INTO v_qual
      FROM pg_policy
     WHERE polrelid = format('public.%I', t)::regclass
       AND polname = t || '_tenant';

    EXECUTE format('DROP POLICY %I ON public.%I', t || '_tenant', t);

    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (%s)',
      t || '_read', t, v_qual);

    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR ALL USING (is_internal()) WITH CHECK (is_internal())',
      t || '_write', t);
  END LOOP;
END $$;

COMMENT ON POLICY organization_capabilities_read ON organization_capabilities IS
  'A firm sees what it has bought; Dead Ringers sees all. 002''s expression, '
  'now FOR SELECT. As FOR ALL it let any member of a firm switch on a '
  'capability the firm had not bought.';
COMMENT ON POLICY organization_capabilities_write ON organization_capabilities IS
  'Only Dead Ringers sets what a firm has. Grants stay because internal staff '
  'are authenticated too; this policy is the lock. Not can_manage_settings(): '
  'a manager is a member of the firm being sold to.';
COMMENT ON POLICY client_entitlements_read ON client_entitlements IS
  'A firm sees how much it has bought; Dead Ringers sees all. 009''s '
  'expression, now FOR SELECT. As FOR ALL any member could raise purchased_qty.';
COMMENT ON POLICY client_entitlements_write ON client_entitlements IS
  'Only Dead Ringers sets a firm''s entitlements. Same reasoning as '
  'organization_capabilities_write.';
COMMENT ON POLICY retention_policies_read ON retention_policies IS
  'A firm sees its retention terms; Dead Ringers sees all. 002''s expression, '
  'now FOR SELECT. As FOR ALL any member could change the months kept or turn '
  'off the storage fee.';
COMMENT ON POLICY retention_policies_write ON retention_policies IS
  'Only Dead Ringers sets retention and the storage fee: they are terms of the '
  'agreement. Same reasoning as organization_capabilities_write.';

-- -----------------------------------------------------------------------------
-- 3. Record it
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM record_migration(
    '20261120T1400_what_a_firm_has_bought.sql',
    NULL,
    'organization_capabilities, client_entitlements and retention_policies had '
    'FOR ALL _tenant policies with read expressions. Split into _read (FOR '
    'SELECT, same expression) and _write (is_internal()), as 20261104T1300. '
    'Grants unchanged.');
END $$;

COMMIT;

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- A user is created scoped to a real firm, first as a professional and then as
-- a manager (can_manage_settings() true), and tries each write on each table.
-- Then the positive half: internal staff, still authenticated, can write.
-- Without it the block passes just as happily if the write policy blocks Dead
-- Ringers too. Every write runs as authenticated: postgres holds BYPASSRLS.
--
-- Fixture rows (one capability, one entitlement, one retention row) are made
-- as internal so the firm has something to read and try to change; a firm
-- that already has a retention row keeps it and the test uses that.
--
-- DO $$
-- DECLARE
--   r text := ''; n int; t text; p text;
--   v_org uuid; v_user uuid; v_auth uuid := gen_random_uuid();
--   v_cap uuid; v_ent uuid; v_ret uuid;
-- BEGIN
--   r := r || 'policies now:' || chr(10) || COALESCE((
--          SELECT string_agg('    ' || rpad(c.relname, 27) || p.polname
--                            || '(' || p.polcmd::text || ')', chr(10)
--                            ORDER BY c.relname, p.polname)
--            FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
--           WHERE p.polrelid IN ('public.organization_capabilities'::regclass,
--                                'public.client_entitlements'::regclass,
--                                'public.retention_policies'::regclass)), '    NONE')
--        || chr(10) || '   (expect _read(r) and _write(*) for each of the three, nothing else)'
--        || chr(10);
--
--   r := r || 'authenticated still holds I/U/D on organization_capabilities: '
--          || has_table_privilege('authenticated', 'public.organization_capabilities', 'INSERT')::text || '/'
--          || has_table_privilege('authenticated', 'public.organization_capabilities', 'UPDATE')::text || '/'
--          || has_table_privilege('authenticated', 'public.organization_capabilities', 'DELETE')::text
--          || '   (expect true/true/true — the policy is the lock)' || chr(10);
--
--   -- ---- the fixture, as internal -------------------------------------------
--   PERFORM set_config('app.is_internal', 'on', true);
--   SELECT id INTO v_org FROM organizations ORDER BY created_at LIMIT 1;
--   IF v_org IS NULL THEN
--     RAISE EXCEPTION 'VERIFY 20261120T1400: no organizations — FIXTURE NOT RUN';
--   END IF;
--
--   INSERT INTO users (email, full_name, auth_user_id)
--   VALUES ('zzz-verify-1400@example.invalid', 'ZZZ Verification', v_auth)
--   RETURNING id INTO v_user;
--   INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id)
--   VALUES (v_user, 'organization', 'professional', v_org);
--
--   DELETE FROM organization_capabilities WHERE organization_id = v_org AND capability IN ('shops', 'coaching');
--   INSERT INTO organization_capabilities (organization_id, capability, notes)
--   VALUES (v_org, 'shops', 'zzz verify 1400') RETURNING id INTO v_cap;
--   INSERT INTO client_entitlements (organization_id, entitlement_kind, period_start, period_end, purchased_qty)
--   VALUES (v_org, 'shops', DATE '1999-01-01', DATE '1999-12-31', 1) RETURNING id INTO v_ent;
--   INSERT INTO retention_policies (organization_id) VALUES (v_org)
--   ON CONFLICT (organization_id) DO NOTHING;
--   SELECT id INTO v_ret FROM retention_policies WHERE organization_id = v_org;
--   PERFORM set_config('app.is_internal', 'off', true);
--
--   PERFORM set_config('request.jwt.claims', json_build_object('sub', v_auth::text)::text, true);
--   PERFORM set_config('role', 'authenticated', true);
--
--   -- Each pass runs in its own subtransaction and undoes itself (ZZ001), so a
--   -- write that wrongly succeeds — a DELETE, say — cannot leave the next pass
--   -- nothing to try. The report text survives: PL/pgSQL variables are not
--   -- rolled back.
--   FOREACH p IN ARRAY ARRAY['professional', 'manager'] LOOP
--    BEGIN
--     IF p = 'manager' THEN
--       PERFORM set_config('role', 'none', true);
--       PERFORM set_config('app.is_internal', 'on', true);
--       UPDATE user_scopes SET view_profile = 'manager' WHERE user_id = v_user;
--       PERFORM set_config('app.is_internal', 'off', true);
--       PERFORM set_config('role', 'authenticated', true);
--     END IF;
--     r := r || '-- as a ' || p || ' of the firm (can_manage_settings: '
--            || can_manage_settings()::text || ', expect '
--            || (p = 'manager')::text || ')' || chr(10);
--
--     SELECT (SELECT count(*) FROM organization_capabilities WHERE id = v_cap)
--          + (SELECT count(*) FROM client_entitlements WHERE id = v_ent)
--          + (SELECT count(*) FROM retention_policies WHERE id = v_ret) INTO n;
--     r := r || '   READ own rows, of 3: ' || n || '   (expect 3 — unchanged)' || chr(10);
--
--     UPDATE organization_capabilities SET disabled_on = NULL, notes = 'x' WHERE id = v_cap;
--     GET DIAGNOSTICS n = ROW_COUNT;
--     r := r || '   UPDATE a capability: ' || n || '   (expect 0)' || chr(10);
--     BEGIN
--       INSERT INTO organization_capabilities (organization_id, capability)
--       VALUES (v_org, 'coaching');
--       r := r || '   INSERT a capability: ALLOWED   (expect refused)' || chr(10);
--     EXCEPTION
--       WHEN insufficient_privilege THEN
--         r := r || '   INSERT a capability: refused, ' || SQLSTATE || '   (expect refused, 42501)' || chr(10);
--       WHEN unique_violation THEN  -- the policy let it through; the earlier pass's row was in the way
--         r := r || '   INSERT a capability: ALLOWED, duplicate of the earlier pass   (expect refused)' || chr(10);
--     END;
--     DELETE FROM organization_capabilities WHERE id = v_cap;
--     GET DIAGNOSTICS n = ROW_COUNT;
--     r := r || '   DELETE a capability: ' || n || '   (expect 0)' || chr(10);
--
--     UPDATE client_entitlements SET purchased_qty = 99 WHERE id = v_ent;
--     GET DIAGNOSTICS n = ROW_COUNT;
--     r := r || '   UPDATE an entitlement: ' || n || '   (expect 0)' || chr(10);
--     BEGIN
--       INSERT INTO client_entitlements (organization_id, entitlement_kind, period_start, period_end, purchased_qty)
--       VALUES (v_org, 'evaluations', DATE '1999-01-01', DATE '1999-12-31', 99);
--       r := r || '   INSERT an entitlement: ALLOWED   (expect refused)' || chr(10);
--     EXCEPTION
--       WHEN insufficient_privilege THEN
--         r := r || '   INSERT an entitlement: refused, ' || SQLSTATE || '   (expect refused, 42501)' || chr(10);
--       WHEN unique_violation THEN  -- the policy let it through; the earlier pass's row was in the way
--         r := r || '   INSERT an entitlement: ALLOWED, duplicate of the earlier pass   (expect refused)' || chr(10);
--     END;
--     DELETE FROM client_entitlements WHERE id = v_ent;
--     GET DIAGNOSTICS n = ROW_COUNT;
--     r := r || '   DELETE an entitlement: ' || n || '   (expect 0)' || chr(10);
--
--     UPDATE retention_policies SET storage_fee_applies = NOT storage_fee_applies WHERE id = v_ret;
--     GET DIAGNOSTICS n = ROW_COUNT;
--     r := r || '   UPDATE retention: ' || n || '   (expect 0)' || chr(10);
--     DELETE FROM retention_policies WHERE id = v_ret;
--     GET DIAGNOSTICS n = ROW_COUNT;
--     r := r || '   DELETE retention: ' || n || '   (expect 0)' || chr(10);
--     RAISE EXCEPTION USING ERRCODE = 'ZZ001';
--    EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
--    END;
--   END LOOP;
--
--   -- ---- THE POSITIVE HALF: internal staff, still authenticated -------------
--   PERFORM set_config('app.is_internal', 'on', true);
--   r := r || '-- as Dead Ringers (authenticated, app.is_internal on)' || chr(10);
--   UPDATE organization_capabilities SET notes = notes WHERE id = v_cap;
--   GET DIAGNOSTICS n = ROW_COUNT;
--   r := r || '   UPDATE a capability: ' || n || '   (expect 1)' || chr(10);
--   UPDATE client_entitlements SET purchased_qty = purchased_qty WHERE id = v_ent;
--   GET DIAGNOSTICS n = ROW_COUNT;
--   r := r || '   UPDATE an entitlement: ' || n || '   (expect 1)' || chr(10);
--   UPDATE retention_policies SET notes = notes WHERE id = v_ret;
--   GET DIAGNOSTICS n = ROW_COUNT;
--   r := r || '   UPDATE retention: ' || n || '   (expect 1)' || chr(10);
--   DELETE FROM client_entitlements WHERE id = v_ent;
--   GET DIAGNOSTICS n = ROW_COUNT;
--   r := r || '   DELETE an entitlement: ' || n || '   (expect 1)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261120T1400_what_a_firm_has_bought (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
