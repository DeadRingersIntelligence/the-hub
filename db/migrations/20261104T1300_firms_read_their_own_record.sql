-- =============================================================================
-- 20261104T1300_firms_read_their_own_record.sql
-- The Hub — a firm can see its own record. Only Dead Ringers changes it.
--
-- WHAT IS WRONG. Two policies, both written as reads and both doing write duty:
--
--   CREATE POLICY organizations_tenant ON organizations
--     USING (is_internal() OR id = current_organization_id());
--
--   CREATE POLICY partners_visible ON partners
--     USING (is_internal()
--         OR id IN (SELECT partner_id FROM users WHERE id = current_user_id())
--         OR id IN (SELECT partner_id FROM partner_access
--                   WHERE organization_id = current_organization_id()
--                     AND revoked_on IS NULL));
--
-- No FOR clause means FOR ALL; no WITH CHECK means the read expression governs
-- writes too. So:
--
--   ANY member of a firm can UPDATE or DELETE that firm's own organizations
--   row. Not an owner, not a manager — any signed-in user with a scope there.
--   There is no can_manage_settings() check, which is how every other settings
--   surface in this schema is gated.
--
--   ANY firm holding an unrevoked partner_access row can write the PARTNER's
--   record — rename the consultancy, or delete it — rather than merely seeing
--   which consultancy can reach its data, which is what 003's comment says the
--   policy was for.
--
-- This is the third and fourth instance of one mistake. 20261103T1000 fixed
-- six reference tables whose policies were USING (true); 20261104T1200 fixed
-- data_sharing_agreements, whose policy was correctly scoped and still FOR
-- ALL. These two are that same shape. The tell is in the source every time:
-- "visible", "may see", "readable" — read words over a policy that governs
-- writes.
--
-- THE RULING, from the user: Dead Ringers staff may update and delete; firms
-- keep read access exactly as they have it.
--
-- WHY THE GRANTS STAY, where 20261104T1200 revoked them. Internal staff sign
-- in as `authenticated` like everyone else — there is no separate role for
-- them — so revoking INSERT, UPDATE and DELETE from `authenticated` would stop
-- Dead Ringers too. The privilege therefore stays and the POLICY carries the
-- rule: is_internal() for writes. That is the opposite trade from 1200, where
-- nobody writes at all and the revoke is the lock, and the two files differ
-- for that reason alone.
--
-- IT REMOVES NO WORKING FEATURE. Searched across all thirteen hellophone
-- branches on 4 November: no quoted reference to `organizations` or `partners`
-- anywhere, while the same search finds 22 for `interactions` on main, so it
-- is not blind. Nothing in the application writes either table today. Anything
-- that does so through a SECURITY DEFINER function runs as postgres and is
-- unaffected either way.
--
-- HOW THE READ IS PRESERVED. As in 1200, the existing expressions are read out
-- of the catalogue and the new SELECT policies are built from them, rather
-- than retyped. partners_visible in particular is three clauses deep and
-- nothing is gained by my copying it by eye.
--
-- Requires: 001 (organizations_tenant), 003 (partners_visible), 024,
--           20261103T1200 (record_migration).
-- Safe to run twice.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Both policies are the ones this file expects
--
-- Three states per table, counted together: 001 and 003's single FOR ALL
-- policies, this file's pairs, or anything else — which stops. Both tables
-- must be in the same state, because a file that found one converted and one
-- not has been interrupted and should be read rather than resumed.
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_old int; v_new int; v_total int;
BEGIN
  SELECT count(*) FILTER (WHERE polname IN ('organizations_tenant', 'partners_visible')
                            AND polcmd = '*'),
         count(*) FILTER (WHERE polname IN ('organizations_read', 'organizations_write',
                                            'partners_read', 'partners_write')),
         count(*)
    INTO v_old, v_new, v_total
    FROM pg_policy
   WHERE polrelid IN ('public.organizations'::regclass, 'public.partners'::regclass);

  IF v_new = 4 AND v_total = 4 THEN
    RAISE EXCEPTION 'already converted; nothing to do here'
      USING HINT = 'This migration has run on this database. Not an error to fix — stop.';
  ELSIF NOT (v_old = 2 AND v_total = 2) THEN
    RAISE EXCEPTION
      'organizations and partners carry % policies between them, not 001 and 003''s two; stop and read them', v_total
      USING HINT = 'Expected organizations_tenant and partners_visible, both FOR ALL, and nothing else.';
  END IF;

  IF (SELECT count(*) FROM pg_class
       WHERE oid IN ('public.organizations'::regclass, 'public.partners'::regclass)
         AND relrowsecurity) <> 2 THEN
    RAISE EXCEPTION 'row-level security is not enabled on both tables; stop and look';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. Read as before, write only if internal
--
-- The read expression is carried across from the existing policy in each case.
-- The write policy is the same shape 20261103T1000 installed on the six
-- reference tables, and for the same reason: the grants are what stop a client
-- today, and the policy is what stops a future stray GRANT from reopening it.
--
-- TO authenticated on the read, so anon matches no SELECT policy at all. The
-- write policy is TO public — evaluated for every role — and admits only
-- is_internal(), which is false for every client session.
-- -----------------------------------------------------------------------------
DO $$
DECLARE t text; v_qual text;
BEGIN
  FOREACH t IN ARRAY ARRAY['organizations', 'partners'] LOOP
    SELECT pg_get_expr(polqual, polrelid) INTO v_qual
      FROM pg_policy
     WHERE polrelid = format('public.%I', t)::regclass
       AND polcmd = '*';

    EXECUTE format('DROP POLICY %I ON public.%I',
                   CASE t WHEN 'organizations' THEN 'organizations_tenant'
                          ELSE 'partners_visible' END, t);

    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (%s)',
      t || '_read', t, v_qual);

    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR ALL USING (is_internal()) WITH CHECK (is_internal())',
      t || '_write', t);
  END LOOP;
END $$;

COMMENT ON POLICY organizations_read ON organizations IS
  'A firm sees its own record and Dead Ringers sees them all — 001''s '
  'expression, carried across unchanged. It is now FOR SELECT. Written with no '
  'FOR clause it was FOR ALL, so any member of a firm, at any seniority, could '
  'rename or delete that firm''s row with no can_manage_settings() check.';
COMMENT ON POLICY organizations_write ON organizations IS
  'Only Dead Ringers changes a firm''s record. The revoked privileges are not '
  'the lock here — internal staff sign in as authenticated like everyone else, '
  'so the grants have to stay and this policy carries the rule.';
COMMENT ON POLICY partners_read ON partners IS
  'A partner sees itself, a firm sees the consultancies that can reach its '
  'data, Dead Ringers sees all — 003''s expression, carried across unchanged '
  'and now FOR SELECT. Written as FOR ALL it let any firm with an unrevoked '
  'partner_access row rewrite or delete the partner''s record.';
COMMENT ON POLICY partners_write ON partners IS
  'Only Dead Ringers changes a partner record. Same reasoning as '
  'organizations_write.';

-- -----------------------------------------------------------------------------
-- 3. Record it
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM record_migration(
    '20261104T1300_firms_read_their_own_record.sql',
    NULL,
    'organizations_tenant and partners_visible were FOR ALL with read '
    'expressions. Split into _read (FOR SELECT, same expression) and _write '
    '(is_internal()). Grants unchanged, because internal staff are '
    'authenticated too.');
END $$;

COMMIT;

-- =============================================================================
-- STILL TO DO
--
-- * FOUR FILES HAVE NOW FIXED NINE POLICIES OF ONE SHAPE, and nothing stops
--   the tenth being written tomorrow. The reviewable rule, which belongs in
--   db/README.md: a CREATE POLICY with no FOR clause is FOR ALL, and with no
--   WITH CHECK its read expression governs writes. Write FOR SELECT when a
--   policy is a read policy. A policy whose name or comment says see, visible
--   or readable and whose polcmd is '*' is wrong until somebody says otherwise.
--
-- * THE CATALOGUE CANNOT FIND THE REST OF THEM. polcmd = '*' is correct for a
--   great many policies that properly govern writes — 76 of 133 at the last
--   count — so a scan for it is noise. What found these nine was reading them,
--   and the write-policy audit of 4 November did not, because it asked whether
--   each policy was scoped and all 112 were. A list of tables the application
--   never writes, checked against the policies that allow writes, is the scan
--   that would work, and it needs the application rather than the database.
--
-- * NOBODY CAN CREATE AN ORGANIZATION OR A PARTNER THROUGH THE API EITHER, now
--   that INSERT is governed by is_internal(). That follows from the ruling and
--   is almost certainly right — firms are onboarded by Dead Ringers — but it
--   was not asked about explicitly, and it is the kind of thing worth knowing
--   before somebody builds a self-serve sign-up.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- The fixture is the point, for the reason 20261104T1200's first version
-- missed: a write test against a table the caller cannot see, or with no
-- signed-in user, reports zero whatever the policy says. This one creates a
-- user scoped to a real firm and tries to rename that firm.
--
-- DO $$
-- DECLARE
--   r text := ''; n int;
--   v_org uuid; v_user uuid; v_auth uuid := gen_random_uuid(); v_name text;
-- BEGIN
--   r := r || 'policies now:' || chr(10);
--   r := r || COALESCE((
--          SELECT string_agg('    ' || rpad(c.relname, 16) || p.polname
--                            || '(' || p.polcmd::text || ')', chr(10)
--                            ORDER BY c.relname, p.polname)
--            FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
--           WHERE p.polrelid IN ('public.organizations'::regclass,
--                                'public.partners'::regclass)), '    NONE')
--          || chr(10)
--          || '   (expect organizations_read(r), organizations_write(*), '
--          || 'partners_read(r), partners_write(*))' || chr(10);
--
--   r := r || 'authenticated still holds U/D on organizations: '
--          || has_table_privilege('authenticated', 'public.organizations', 'UPDATE')::text
--          || '/'
--          || has_table_privilege('authenticated', 'public.organizations', 'DELETE')::text
--          || '   (expect true/true — the grants deliberately stay, because '
--          || 'internal staff are authenticated too. The policy is the lock)'
--          || chr(10);
--   r := r || 'anon SELECT on organizations / partners: '
--          || has_table_privilege('anon', 'public.organizations', 'SELECT')::text || ' / '
--          || has_table_privilege('anon', 'public.partners', 'SELECT')::text
--          || '   (expect false / false, from 20261103T1600)' || chr(10);
--
--   -- ---- the fixture -------------------------------------------------------
--   -- app.is_internal is on only while the user is created, because
--   -- users_guard_privileged refuses a new user who already has an
--   -- auth_user_id.
--   PERFORM set_config('app.is_internal', 'on', true);
--   SELECT id, name INTO v_org, v_name FROM organizations ORDER BY created_at LIMIT 1;
--
--   IF v_org IS NULL THEN
--     r := r || 'no organizations — FIXTURE NOT RUN' || chr(10);
--   ELSE
--     INSERT INTO users (email, full_name, auth_user_id)
--     VALUES ('zzz-verify-1300@example.invalid', 'ZZZ Verification', v_auth)
--     RETURNING id INTO v_user;
--     INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id)
--     VALUES (v_user, 'organization', 'manager', v_org);
--     PERFORM set_config('app.is_internal', 'off', true);
--
--     -- Internal first, while still the owner is irrelevant: postgres bypasses
--     -- RLS, so the only honest test of the write policy is as a client role.
--     PERFORM set_config('request.jwt.claims',
--                        json_build_object('sub', v_auth::text)::text, true);
--     PERFORM set_config('role', 'authenticated', true);
--
--     SELECT count(*) INTO n FROM organizations WHERE id = v_org;
--     r := r || 'a firm member can still READ their firm: ' || n
--            || '   (expect 1 — this must not have changed)' || chr(10);
--
--     UPDATE organizations SET name = 'ZZZ renamed' WHERE id = v_org;
--     GET DIAGNOSTICS n = ROW_COUNT;
--     r := r || 'a firm member can RENAME their firm: ' || n || ' rows'
--            || '   (expect 0. Under 001''s FOR ALL policy this was 1, and no '
--            || 'can_manage_settings() check stood in the way)' || chr(10);
--
--     DELETE FROM organizations WHERE id = v_org;
--     GET DIAGNOSTICS n = ROW_COUNT;
--     r := r || 'a firm member can DELETE their firm: ' || n || ' rows'
--            || '   (expect 0. A foreign key would have stopped most of these '
--            || 'in practice; the policy should stop all of them)' || chr(10);
--
--     r := r || 'the name is unchanged: '
--            || (SELECT (name = v_name)::text FROM organizations WHERE id = v_org)
--            || '   (expect true)' || chr(10);
--   END IF;
--
--   RAISE EXCEPTION 'VERIFY 20261104T1300_firms_read_their_own_record (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
