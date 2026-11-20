-- =============================================================================
-- 20261120T1800_managers_decide.sql
-- The Hub — a firm's consent and a firm's focus are decided by its managers.
--
-- APPLIED to staging (17:22 UTC) and production (17:23 UTC), 20 Nov 2026,
-- from commit 083db75, sha256 3ef940df…a1166fcb, loaded whole. ran_md5
-- dd99ad454d309fb3c8d82f7e6ade45b2 (17712 characters) on both, as predicted.
-- The verification matched line for line on both. The baseline moved com to
-- 11153 and mig to 17383, each to the character, and nothing else moved.
-- This note was added afterwards.
--
-- RULINGS AT REVIEW, recorded here:
--
--   * REVOKE, DON'T DELETE, NOW HAS A NAME: a consent record is evidence,
--     and the party it concerns doesn't erase it. It's the same principle as
--     the retention lock (20261120T1400) and the transcript lock still to
--     come. db/README.md, "Evidence isn't erased by the party it concerns".
--   * revoked_on NEEDS A DECISION, NOT A FOOTNOTE. partner_access has
--     granted_on NOT NULL and revoked_on: exactly the dated grant in_force()
--     was written for, and now the only one that doesn't ask it.
--     partners_read reads revoked_on IS NULL. The two differ only for a
--     revoked_on in the future. Either a CHECK forbids a future revoked_on
--     (no access changes, and the column stops inviting a schedule it then
--     ignores), or revoked_on is ruled a schedule and partners_read moves to
--     in_force(), with Mandie signing off the loosening. Open; recorded in
--     db/README.md, "Dated grants".
--
-- WHAT IS WRONG. partner_access and focus_behaviors each carry one firm-scoped
-- FOR ALL policy, <t>_tenant, with 024's identical WITH CHECK. authenticated
-- holds INSERT, UPDATE and DELETE on both. So any member of a firm, at any
-- seniority, can:
--
--   partner_access    grant a consultancy access to the firm's data, or
--                     revoke it. partners_read (20261104T1300) turns on this
--                     row, so writing it is what lets a partner in.
--   focus_behaviors   choose which of Dead Ringers' behaviours the firm, a
--                     person or a location works on, and write the row as if
--                     a coach or the system had chosen it (focus_source).
--
-- THE RULING (planning and Mandie, 20 November). Both are the firm's, not
-- Dead Ringers': partner_access is the firm's consent to give, and
-- focus_behaviors is the firm's choice of what to work on (review of #57).
-- Both are gated to managers: the picklist_items shape, one policy per
-- command, writes needing is_internal() OR (can_manage_settings() AND the
-- firm's own row). Reads stay exactly as they are.
--
-- TWO CHOICES BEYOND THE PICKLIST SHAPE, both for review:
--
--   1. partner_access: A MANAGER GRANTS AND REVOKES; ONLY DEAD RINGERS
--      DELETES. Revoking is an UPDATE setting revoked_on, which partners_read
--      already honours. Deleting the row would erase the record that consent
--      was ever given, which is the record a dispute turns on. A grant can be
--      reinstated by clearing revoked_on, because (partner_id,
--      organization_id) is unique.
--   2. focus_behaviors: A FIRM WRITES ONLY ITS OWN CHOICES. focus_source exists
--      to record who chose ("and which one matters, so it is stored", 007). A
--      firm's managers may insert, change or remove rows whose focus_source is
--      'client', and nothing else. A coach's or the system's focus can be read
--      by the firm, but not rewritten or removed by it, and no firm row can
--      claim to be one.
--
-- IT REMOVES NO WORKING FEATURE. hellophone, all 20 branches, 20 November:
-- no reference to either table. In the Hub, only merge_people writes
-- focus_behaviors, and it refuses unless is_internal().
--
-- NOT IN THIS FILE. Granting needs a partner's id, and a firm sees only the
-- partners it has already granted (partners_read). How a manager finds a
-- consultancy to grant is the app's question, for when that screen is built.
-- partners_read checks revoked_on IS NULL rather than in_force() (20261120T1510),
-- so a revocation dated in the future already hides the partner. That errs
-- towards less access; left as it is, and recorded in db/README.md.
--
-- Requires: 003 (partner_access), 007 (focus_behaviors), 024, 038
--           (can_manage_settings), 20261103T1200 (record_migration).
-- NOT SAFE TO RUN TWICE: section 1 stops on a second run, and says so.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Both policies are the ones this file expects, and nothing else is there
-- -----------------------------------------------------------------------------
DO $$
DECLARE t text; v_n int; v_ok boolean; v_md5 text; v_new int := 0;
BEGIN
  FOREACH t IN ARRAY ARRAY['partner_access', 'focus_behaviors'] LOOP
    SELECT count(*),
           bool_and(p.polname = t || '_tenant' AND p.polcmd = '*' AND p.polroles = '{0}'
                    AND pg_get_expr(p.polqual, p.polrelid) = pg_get_expr(p.polwithcheck, p.polrelid)),
           md5(string_agg(pg_get_expr(p.polqual, p.polrelid), ''))
      INTO v_n, v_ok, v_md5
      FROM pg_policy p WHERE p.polrelid = format('public.%I', t)::regclass;

    IF EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = format('public.%I', t)::regclass
                                         AND polname = t || '_read') THEN
      v_new := v_new + 1;
    ELSIF NOT (v_n = 1 AND v_ok AND v_md5 = 'e001fae7c6dc9ee510219d97d074882b') THEN
      RAISE EXCEPTION '% carries % policies, not the expected % _tenant (expression md5 %); stop and read them',
        t, v_n, t, v_md5
        USING HINT = 'Expected one FOR ALL policy TO public, WITH CHECK equal to USING: '
                     '(is_internal() OR organization_id = current_organization_id()).';
    END IF;
  END LOOP;

  IF v_new = 2 THEN
    RAISE EXCEPTION 'already converted; nothing to do here'
      USING HINT = 'This migration has run on this database. Not an error to fix — stop.';
  ELSIF v_new = 1 THEN
    RAISE EXCEPTION 'one of the two tables is converted and the other is not; an interrupted run. Stop and read them';
  END IF;

  IF (SELECT count(*) FROM pg_class
       WHERE oid IN ('public.partner_access'::regclass, 'public.focus_behaviors'::regclass)
         AND relrowsecurity AND relforcerowsecurity) <> 2 THEN
    RAISE EXCEPTION 'row-level security is not enabled and FORCEd on both tables; stop and look';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. One policy per command
--
-- The read is the earlier policy's expression, carried across from the
-- catalogue. The writes are written out here, because each one is a decision.
-- -----------------------------------------------------------------------------
DO $$
DECLARE t text; v_qual text;
BEGIN
  FOREACH t IN ARRAY ARRAY['partner_access', 'focus_behaviors'] LOOP
    SELECT pg_get_expr(polqual, polrelid) INTO v_qual
      FROM pg_policy WHERE polrelid = format('public.%I', t)::regclass AND polname = t || '_tenant';
    EXECUTE format('DROP POLICY %I ON public.%I', t || '_tenant', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (%s)',
                   t || '_read', t, v_qual);
  END LOOP;
END $$;

-- partner_access: managers grant and revoke; only Dead Ringers deletes.
CREATE POLICY partner_access_insert ON partner_access FOR INSERT
  WITH CHECK (is_internal() OR (can_manage_settings() AND organization_id = current_organization_id()));
CREATE POLICY partner_access_update ON partner_access FOR UPDATE
  USING      (is_internal() OR (can_manage_settings() AND organization_id = current_organization_id()))
  WITH CHECK (is_internal() OR (can_manage_settings() AND organization_id = current_organization_id()));
CREATE POLICY partner_access_delete ON partner_access FOR DELETE
  USING (is_internal());

-- focus_behaviors: managers write the firm's own choices, and only those.
CREATE POLICY focus_behaviors_insert ON focus_behaviors FOR INSERT
  WITH CHECK (is_internal() OR (can_manage_settings() AND organization_id = current_organization_id()
                                AND focus_source = 'client'));
CREATE POLICY focus_behaviors_update ON focus_behaviors FOR UPDATE
  USING      (is_internal() OR (can_manage_settings() AND organization_id = current_organization_id()
                                AND focus_source = 'client'))
  WITH CHECK (is_internal() OR (can_manage_settings() AND organization_id = current_organization_id()
                                AND focus_source = 'client'));
CREATE POLICY focus_behaviors_delete ON focus_behaviors FOR DELETE
  USING (is_internal() OR (can_manage_settings() AND organization_id = current_organization_id()
                           AND focus_source = 'client'));

COMMENT ON POLICY partner_access_read ON partner_access IS
  'The firm sees which consultancies can reach its data: 003''s expression, '
  'carried across unchanged and now FOR SELECT (20261120T1800).';
COMMENT ON POLICY partner_access_insert ON partner_access IS
  'Granting a consultancy access is the firm''s consent to give, given by a '
  'manager (can_manage_settings). As FOR ALL, any member of the firm could '
  'let a partner in (20261120T1800).';
COMMENT ON POLICY partner_access_update ON partner_access IS
  'A manager revokes by setting revoked_on, which partners_read honours, or '
  'reinstates by clearing it (20261120T1800).';
COMMENT ON POLICY partner_access_delete ON partner_access IS
  'Only Dead Ringers deletes a grant. Deleting would erase the record that '
  'consent was ever given; a firm revokes instead (20261120T1800).';
COMMENT ON POLICY focus_behaviors_read ON focus_behaviors IS
  'The firm sees every focus on it, whoever chose it: 007''s expression, '
  'carried across unchanged and now FOR SELECT (20261120T1800).';
COMMENT ON POLICY focus_behaviors_insert ON focus_behaviors IS
  'A manager chooses which of Dead Ringers'' behaviours the firm works on, and '
  'the row says so: focus_source = client. A firm row can''t claim a coach or '
  'the system chose it (20261120T1800).';
COMMENT ON POLICY focus_behaviors_update ON focus_behaviors IS
  'A manager changes the firm''s own choices, not a coach''s or the system''s, '
  'and can''t turn one into the other (20261120T1800).';
COMMENT ON POLICY focus_behaviors_delete ON focus_behaviors IS
  'A manager removes the firm''s own choices, not a coach''s or the '
  'system''s (20261120T1800).';

-- -----------------------------------------------------------------------------
-- 3. Record it
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261120T1800_managers_decide.sql',
    NULL,
    'partner_access and focus_behaviors had FOR ALL _tenant policies. Split per '
    'command: the firm reads as before; managers (can_manage_settings) write. '
    'partner_access: managers grant and revoke, only Dead Ringers deletes. '
    'focus_behaviors: managers write focus_source = client rows only.');
END $rec$;

COMMIT;

-- =============================================================================
-- Verification — run AFTER the file, as its own statement. One block,
-- everything rolled back by the closing RAISE.
--
-- A fixture firm with two consultancies, one already granted, and two
-- focuses on it: one the client chose, one a coach chose. A professional,
-- then a manager, each in a pass that undoes itself (ZZ001), try every
-- command on both tables. Then the positive half: Dead Ringers can still do
-- what a manager can't. Every write runs as authenticated, because postgres
-- holds BYPASSRLS.
--
-- DO $$
-- DECLARE
--   r text := ''; n int; p text; res text;
--   v_org uuid; v_other uuid; v_user uuid; v_auth uuid := gen_random_uuid();
--   v_p1 uuid; v_p2 uuid; v_pa uuid; v_sec uuid; v_beh uuid; v_fc uuid; v_fk uuid;
--   d date := current_date;
-- BEGIN
--   r := r || 'policies now:' || chr(10) || (
--          SELECT string_agg('    ' || rpad(c.relname, 17) || x.ps, chr(10) ORDER BY c.relname)
--            FROM (SELECT polrelid, string_agg(polname || '(' || polcmd::text || ')', ' ' ORDER BY polname) AS ps
--                    FROM pg_policy GROUP BY polrelid) x JOIN pg_class c ON c.oid = x.polrelid
--           WHERE c.oid IN ('public.partner_access'::regclass, 'public.focus_behaviors'::regclass))
--        || chr(10) || '   (expect _delete(d) _insert(a) _read(r) _update(w) on each, nothing else)' || chr(10);
--
--   -- ---- the fixture, as Dead Ringers -------------------------------------
--   PERFORM set_config('app.is_internal', 'on', true);
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ verify 1800', 'funeral_home') RETURNING id INTO v_org;
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ verify 1800 other', 'funeral_home') RETURNING id INTO v_other;
--   INSERT INTO users (email, full_name, auth_user_id)
--   VALUES ('zzz-verify-1800@example.invalid', 'ZZZ Verification', v_auth) RETURNING id INTO v_user;
--   INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id)
--   VALUES (v_user, 'organization', 'professional', v_org);
--   INSERT INTO partners (name, partner_type) VALUES ('ZZZ Partner One', 'consultancy') RETURNING id INTO v_p1;
--   INSERT INTO partners (name, partner_type) VALUES ('ZZZ Partner Two', 'consultancy') RETURNING id INTO v_p2;
--   INSERT INTO partner_access (partner_id, organization_id) VALUES (v_p1, v_org) RETURNING id INTO v_pa;
--   INSERT INTO rubric_sections (code, label, score_category, display_order)
--   VALUES ('zzz_1800', 'ZZZ', 'objective', 999) RETURNING id INTO v_sec;
--   INSERT INTO behaviors (code, label, section_id, score_category, answered_by)
--   VALUES ('zzz_1800', 'ZZZ', v_sec, 'objective', 'reviewer') RETURNING id INTO v_beh;
--   INSERT INTO focus_behaviors (organization_id, behavior_id, focus_source, set_by)
--   VALUES (v_org, v_beh, 'client', 'ZZZ') RETURNING id INTO v_fc;
--   INSERT INTO focus_behaviors (organization_id, behavior_id, focus_source, set_by)
--   VALUES (v_org, v_beh, 'coach', 'ZZZ coach') RETURNING id INTO v_fk;
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
--     r := r || '-- as a ' || p || ' (can_manage_settings ' || can_manage_settings() || ')' || chr(10);
--     r := r || '    reads: grants ' || (SELECT count(*) FROM partner_access WHERE organization_id = v_org)
--            || ', focuses ' || (SELECT count(*) FROM focus_behaviors WHERE organization_id = v_org)
--            || '   (expect 1, 2 either way)' || chr(10);
--
--     -- partner_access
--     BEGIN INSERT INTO partner_access (partner_id, organization_id) VALUES (v_p2, v_org); res := 'granted';
--     EXCEPTION WHEN insufficient_privilege THEN res := SQLSTATE; END;
--     r := r || '    grant a second consultancy: ' || res || '   (expect professional 42501, manager granted)' || chr(10);
--     BEGIN INSERT INTO partner_access (partner_id, organization_id) VALUES (v_p2, v_other); res := 'granted';
--     EXCEPTION WHEN insufficient_privilege THEN res := SQLSTATE; END;
--     r := r || '    grant it for another firm: ' || res || '   (expect 42501 either way)' || chr(10);
--     UPDATE partner_access SET revoked_on = d WHERE id = v_pa;
--     GET DIAGNOSTICS n = ROW_COUNT;
--     r := r || '    revoke the first: ' || n || ', and the firm then sees that partner: '
--            || (SELECT count(*) FROM partners WHERE id = v_p1)
--            || '   (expect professional 0 and 1; manager 1 and 0: partners_read honours it)' || chr(10);
--     DELETE FROM partner_access WHERE id = v_pa;
--     GET DIAGNOSTICS n = ROW_COUNT;
--     r := r || '    delete the grant: ' || n || '   (expect 0 either way: revoke, don''t erase)' || chr(10);
--
--     -- focus_behaviors
--     BEGIN INSERT INTO focus_behaviors (organization_id, behavior_id, focus_source) VALUES (v_org, v_beh, 'client'); res := 'added';
--     EXCEPTION WHEN insufficient_privilege THEN res := SQLSTATE; END;
--     r := r || '    add a client focus: ' || res || '   (expect professional 42501, manager added)' || chr(10);
--     BEGIN INSERT INTO focus_behaviors (organization_id, behavior_id, focus_source) VALUES (v_org, v_beh, 'coach'); res := 'added';
--     EXCEPTION WHEN insufficient_privilege THEN res := SQLSTATE; END;
--     r := r || '    add one claiming a coach chose it: ' || res || '   (expect 42501 either way)' || chr(10);
--     UPDATE focus_behaviors SET set_by = 'changed' WHERE id = v_fc;
--     GET DIAGNOSTICS n = ROW_COUNT;
--     r := r || '    change the client''s focus: ' || n || '   (expect professional 0, manager 1)' || chr(10);
--     UPDATE focus_behaviors SET set_by = 'changed' WHERE id = v_fk;
--     GET DIAGNOSTICS n = ROW_COUNT;
--     r := r || '    change the coach''s focus: ' || n || '   (expect 0 either way)' || chr(10);
--     BEGIN UPDATE focus_behaviors SET focus_source = 'coach' WHERE id = v_fc;
--       GET DIAGNOSTICS n = ROW_COUNT; res := n || ' rows';
--     EXCEPTION WHEN insufficient_privilege THEN res := SQLSTATE; END;
--     r := r || '    relabel the client''s focus as a coach''s: ' || res
--            || '   (expect professional 0 rows, manager 42501)' || chr(10);
--     DELETE FROM focus_behaviors WHERE id = v_fk;
--     GET DIAGNOSTICS n = ROW_COUNT;
--     r := r || '    remove the coach''s focus: ' || n || '   (expect 0 either way)' || chr(10);
--     DELETE FROM focus_behaviors WHERE id = v_fc;
--     GET DIAGNOSTICS n = ROW_COUNT;
--     r := r || '    remove the client''s focus: ' || n || '   (expect professional 0, manager 1)' || chr(10);
--     RAISE EXCEPTION USING ERRCODE = 'ZZ001';
--    EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
--    END;
--   END LOOP;
--
--   -- ---- the positive half: Dead Ringers, still authenticated -------------
--   PERFORM set_config('app.is_internal', 'on', true);
--   UPDATE focus_behaviors SET set_by = set_by WHERE id = v_fk;
--   GET DIAGNOSTICS n = ROW_COUNT;
--   r := r || '-- as Dead Ringers: change the coach''s focus: ' || n || '   (expect 1)' || chr(10);
--   DELETE FROM partner_access WHERE id = v_pa;
--   GET DIAGNOSTICS n = ROW_COUNT;
--   r := r || '   delete a grant: ' || n || '   (expect 1)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261120T1800_managers_decide (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
