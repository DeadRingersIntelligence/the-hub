-- =============================================================================
-- 20261120T1510_cases_capability.sql
-- The Hub — a firm has cases only while the capability is in force.
--
-- THE RULING (planning, 20 November):
--
--   * "Off" means no new case is created and no call is linked to a case.
--   * Refuse in the database, not only in the page.
--   * Existing rows stay untouched and readable. The revenue trigger
--     (case_revenue_moved_notify) and the three report functions
--     (20261120T1100) are not gated.
--   * The capability is stored explicitly. client_type picks the default when
--     a firm is set up, and never again.
--   * Dates, not timestamps: on from enabled_on, off from disabled_on, both
--     inclusive. The date predicate is written once.
--   * An answering service's cases, if any, live in its own case-management
--     system, so cases are off for one by default. Nothing here makes "a
--     call's case reference must point at a Hub case row" harder to change.
--
-- WHAT THIS FILE DOES
--
--   1. in_force(from, until, on): the date rule, stated once. capability_in_
--      force() calls it now, and a future agreement_in_force() will.
--   2. capability_in_force(org, cap, on = today). has_capability() (002) now
--      calls it instead of repeating the rule. Same result: 002 already read
--      disabled_on > current_date.
--   3. Backfill. Every firm that isn't an answering service gets cases, from
--      the day the firm was created. Planning: "backfill non-answering-service
--      firms". That includes client_type 'internal' (Dead Ringers' own
--      record).
--   4. The setup default. A new firm that isn't an answering service gets
--      cases on the day it's created. AFTER INSERT on organizations only:
--      changing client_type later changes nothing.
--   5. The refusals, KP001, as two triggers on the tables rather than checks
--      in the functions. A firm user holds INSERT on cases and UPDATE on
--      interactions directly (cases_tenant and interactions_tenant are the
--      house FOR ALL), so a check inside create_case_for_call and
--      set_call_case would be a check in the page by another name. Every
--      path goes through these two triggers:
--        create_case_for_call   INSERT INTO cases            refused
--        set_call_case          UPDATE interactions.case_id  refused
--        propagate_case_links   the same UPDATE              refused, though
--          it is only ever called by the two above, after their own write
--          has already been refused, so with cases off it never runs
--        a direct INSERT or UPDATE through the API           refused
--      Unlinking (case_id to NULL) is allowed: it creates nothing. So is
--      confirming a link that already exists (same case_id), and so is editing
--      an existing case. The ruling refuses new cases and new links. It
--      doesn't freeze the old ones.
--   6. my_cases_awaiting_confirmation() returns nothing for a case whose firm
--      has cases off. It feeds the bell's prompts, which the app also hides.
--      Body replaced, with a drift check against 20261119T1510's reviewed text.
--   7. Comments. capability gets its 20261120T1500 comment re-issued, with the
--      clauses that describe this file now citing it (review of #54).
--      custom_field_entity gets a line on 'case' (planning, 20 November).
--
-- WHY THE TRIGGERS ARE INVOKER. capability_in_force() reads organization_
-- capabilities as the caller. A firm user can read their own firm's rows, and
-- the case or call being written is their own firm's (the table's WITH CHECK
-- holds them to that). A user writing at a firm they can't see gets refused,
-- either by KP001 or by the row-level-security check that follows. Either way
-- it's a refusal.
--
-- NOT SAFE TO RUN TWICE: section 1 refuses if in_force exists.
--
-- Requires: 002 (organization_capabilities, has_capability), 057 / 058
--           (cases, interactions.case_id), 20261119T1510 (my_cases_awaiting_
--           confirmation), 20261120T1400 (only Dead Ringers writes
--           capabilities), 20261120T1500 (the 'cases' value),
--           20261103T1200 (record_migration).
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Preconditions: the value exists, the two bodies replaced here are the
--    reviewed ones, and nothing from this file is here yet
-- -----------------------------------------------------------------------------
DO $$
DECLARE v text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM schema_migrations
                  WHERE filename = '20261120T1500_cases_is_a_capability.sql') THEN
    RAISE EXCEPTION '20261120T1500 has not run here; run it first';
  END IF;

  IF to_regprocedure('in_force(date, date, date)') IS NOT NULL
     OR to_regprocedure('capability_in_force(uuid, capability, date)') IS NOT NULL THEN
    RAISE EXCEPTION 'in_force or capability_in_force already exists; this file has run, or something else made them'
      USING HINT = 'Not safe to run twice. Stop and read the ledger.';
  END IF;

  IF EXISTS (SELECT 1 FROM organization_capabilities WHERE capability = 'cases') THEN
    RAISE EXCEPTION 'organization_capabilities already has cases rows; stop and read them'
      USING HINT = 'This file backfills them. Rows put there by hand would be overwritten in meaning, if not in fact.';
  END IF;

  SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = 'has_capability(uuid, capability)'::regprocedure;
  IF v IS DISTINCT FROM '92183c0e76450ee86481ddf35cfd2a56' THEN
    RAISE EXCEPTION 'has_capability''s body is not 002''s (md5 %); stop and diff it', v;
  END IF;

  SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = 'my_cases_awaiting_confirmation()'::regprocedure;
  IF v IS DISTINCT FROM '2c6ca6d8a9b2a7e5df786116114826b2' THEN
    RAISE EXCEPTION 'my_cases_awaiting_confirmation''s body is not 20261119T1510''s (md5 %); stop and diff it', v;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. The date rule, once
-- -----------------------------------------------------------------------------
CREATE FUNCTION in_force(p_from date, p_until date, p_on date)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT p_from <= p_on AND (p_until IS NULL OR p_on < p_until)
$$;

COMMENT ON FUNCTION in_force(date, date, date) IS
  'The one statement of when a dated grant applies: on from p_from, off from '
  'p_until, both inclusive. A grant ending on the 20th is out of force all of '
  'the 20th. Dates, not timestamps, so a revocation can''t be said to take '
  'effect at 2pm; and where a date is ambiguous, the rule errs towards less '
  'access, which is right for consent. Every "is this in force" question calls '
  'this: capability_in_force() now, agreement_in_force() when it exists '
  '(20261120T1510; db/README.md, "Dated grants").';

CREATE FUNCTION capability_in_force(p_org uuid, p_cap capability,
                                    p_on date DEFAULT current_date)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM organization_capabilities c
     WHERE c.organization_id = p_org
       AND c.capability = p_cap
       AND in_force(c.enabled_on, c.disabled_on, p_on))
$$;

COMMENT ON FUNCTION capability_in_force(uuid, capability, date) IS
  'Whether a firm has a capability on a date (today by default), by in_force(). '
  'INVOKER: a firm user can ask about their own firm, Dead Ringers about any. '
  'For anyone else the answer is false. The app asks it to decide what to show; '
  'the database asks it to decide what to refuse (20261120T1510).';

CREATE OR REPLACE FUNCTION has_capability(org uuid, cap capability)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT capability_in_force(org, cap, current_date)
$$;

COMMENT ON FUNCTION has_capability(uuid, capability) IS
  '002''s name for capability_in_force(org, cap, today), kept so nothing that '
  'calls it changes. The rule is in in_force() (20261120T1510).';

REVOKE ALL ON FUNCTION in_force(date, date, date) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION capability_in_force(uuid, capability, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION in_force(date, date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION capability_in_force(uuid, capability, date) TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. Backfill: every firm that isn't an answering service has had cases since
--    it was created
--
-- From the firm's creation date rather than today, so capability_in_force(org,
-- 'cases', a past date) says true for the dates its existing cases were made
-- on. LEAST guards a created_at in the future, which the CHECK on
-- organization_capabilities wouldn't otherwise mind but in_force would.
-- -----------------------------------------------------------------------------
INSERT INTO organization_capabilities (organization_id, capability, enabled_on, notes)
SELECT o.id, 'cases', LEAST(o.created_at::date, current_date),
       'Backfilled by 20261120T1510: not an answering service, so cases from the firm''s creation.'
  FROM organizations o
 WHERE o.client_type <> 'answering_service';

-- -----------------------------------------------------------------------------
-- 4. The setup default
-- -----------------------------------------------------------------------------
CREATE FUNCTION organizations_default_capabilities()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.client_type <> 'answering_service' THEN
    INSERT INTO organization_capabilities (organization_id, capability, notes)
    VALUES (NEW.id, 'cases', 'Set up with the firm: not an answering service (20261120T1510).')
    ON CONFLICT (organization_id, capability) DO NOTHING;
  END IF;
  RETURN NULL;
END $$;

COMMENT ON FUNCTION organizations_default_capabilities() IS
  'When a firm is created: cases, unless it is an answering service, whose cases '
  'live in its own system. On INSERT only. client_type picks the default and '
  'nothing more; after that the organization_capabilities row is the truth, '
  'and Dead Ringers changes it there (20261120T1510).';

CREATE TRIGGER organizations_default_capabilities_t
  AFTER INSERT ON organizations
  FOR EACH ROW EXECUTE FUNCTION organizations_default_capabilities();

REVOKE ALL ON FUNCTION organizations_default_capabilities() FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 5. The refusals: KP001 (db/README.md, "KP")
-- -----------------------------------------------------------------------------
CREATE FUNCTION cases_need_capability()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NOT capability_in_force(NEW.organization_id, 'cases') THEN
    RAISE EXCEPTION 'cases aren''t switched on for this firm'
      USING ERRCODE = 'KP001',
            HINT = 'Calls are still recorded. Dead Ringers can switch cases on.';
  END IF;
  RETURN NEW;
END $$;

COMMENT ON FUNCTION cases_need_capability() IS
  'No new case while the firm''s cases capability is not in force: KP001. '
  'Covers create_case_for_call and a direct INSERT alike. Existing cases are '
  'not touched (20261120T1510).';

CREATE TRIGGER cases_need_capability_t
  BEFORE INSERT ON cases
  FOR EACH ROW EXECUTE FUNCTION cases_need_capability();

CREATE FUNCTION interactions_case_link_needs_capability()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.case_id IS NOT NULL
     AND (TG_OP = 'INSERT' OR NEW.case_id IS DISTINCT FROM OLD.case_id)
     AND NOT capability_in_force(NEW.organization_id, 'cases') THEN
    RAISE EXCEPTION 'cases aren''t switched on for this firm, so a call can''t be linked to one'
      USING ERRCODE = 'KP001',
            HINT = 'Calls are still recorded. Dead Ringers can switch cases on.';
  END IF;
  RETURN NEW;
END $$;

COMMENT ON FUNCTION interactions_case_link_needs_capability() IS
  'No call gains a case while the firm''s cases capability is not in force: '
  'KP001. Covers set_call_case, propagate_case_links and a direct UPDATE. '
  'Unlinking (to NULL) and an unchanged case_id pass, because neither creates '
  'a link (20261120T1510).';

CREATE TRIGGER interactions_case_link_needs_capability_t
  BEFORE INSERT OR UPDATE OF case_id ON interactions
  FOR EACH ROW EXECUTE FUNCTION interactions_case_link_needs_capability();

REVOKE ALL ON FUNCTION cases_need_capability() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION interactions_case_link_needs_capability() FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 6. The bell asks nothing about a firm without cases
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION my_cases_awaiting_confirmation()
RETURNS TABLE (case_id uuid, family_name text, booked_service_date date)
LANGUAGE sql STABLE AS $$
  SELECT c.id,
         (SELECT d.last_name FROM case_decedents cd
            JOIN decedents d ON d.id = cd.decedent_id
           WHERE cd.case_id = c.id AND d.last_name IS NOT NULL
           ORDER BY d.last_name LIMIT 1),
         c.booked_service_date
    FROM cases c
   WHERE case_awaiting_confirmation_for(c.status, c.served_on, c.booked_service_date)
     AND current_user_id() IN (SELECT case_responsible_users(c.id))
     AND capability_in_force(c.organization_id, 'cases')
   ORDER BY c.booked_service_date, c.id
$$;

COMMENT ON FUNCTION my_cases_awaiting_confirmation() IS
  'The signed-in user''s cases whose booked date has passed unconfirmed: case '
  'id, the family''s last name (null when no decedent has one), and the booked '
  'date, oldest first. The bell shows these above its stored notifications. '
  'Empty for a session with no Hub user, and for a firm whose cases capability '
  'is not in force (20261120T1510). INVOKER, so a firm user sees only their '
  'firm''s cases.';

-- -----------------------------------------------------------------------------
-- 7. Comments
-- -----------------------------------------------------------------------------
COMMENT ON TYPE capability IS
  'What a firm has bought, one organization_capabilities row per capability, '
  'set only by Dead Ringers (20261120T1400), in force by capability_in_force(). '
  'cases: the Hub''s own case records — creating, linking, the cases screens '
  'and Reports (20261120T1500). Off by default for an answering service, '
  'whose cases live in its own system; when off, existing case rows stay '
  'readable and nothing new is created or linked (20261120T1510).';

COMMENT ON TYPE custom_field_entity IS
  'What a custom field attaches to. ''case'' stays available when a firm has '
  'cases switched off. Such a firm''s case custom fields point at a feature it '
  'doesn''t have, which is harmless and not a bug: the values stay with the '
  'existing cases, readable like them (20261120T1510).';

-- -----------------------------------------------------------------------------
-- 8. Record it
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261120T1510_cases_capability.sql',
    NULL,
    'Cases become a capability. in_force() states the date rule once; '
    'capability_in_force() and has_capability() use it. Firms that are not '
    'answering services backfilled from creation and defaulted on setup. '
    'KP001 refuses a new case or a new link by trigger. The bell''s prompts '
    'are empty when off. Revenue trigger and report functions not gated.');
END $rec$;

COMMIT;

-- =============================================================================
-- Verification — run AFTER the file, as its own statement. One block,
-- everything rolled back by the closing RAISE.
--
-- Part A reads the real data: the backfill. Part B builds its own two firms,
-- one funeral home and one answering service, so the setup default is tested
-- by the same inserts that make the fixture, and no real firm's capability is
-- switched off, not even inside a rollback. A professional at the funeral home
-- makes a case and links a call with cases on. Then Dead Ringers sets
-- disabled_on to today and every path is tried again, followed by what must
-- still work. Then the positive half: switched back on, linking works again.
-- Every write runs as authenticated, because postgres holds BYPASSRLS.
--
-- DO $$
-- DECLARE
--   r text := ''; n int; v_case uuid; v_c2 uuid;
--   v_a uuid; v_b uuid; v_user uuid; v_auth uuid := gen_random_uuid();
--   v_contact uuid; v_i1 uuid; v_i2 uuid;
--   d date := current_date;
-- BEGIN
--   -- ---- A. the backfill, on the real data -------------------------------------
--   r := r || 'A1. firms by client_type: with cases / without' || chr(10) || COALESCE((
--          SELECT string_agg('    ' || rpad(t, 18) || w || ' / ' || wo, chr(10) ORDER BY t)
--            FROM (SELECT o.client_type::text AS t, count(c.id) AS w,
--                         count(*) FILTER (WHERE c.id IS NULL) AS wo
--                    FROM organizations o
--                    LEFT JOIN organization_capabilities c
--                      ON c.organization_id = o.id AND c.capability = 'cases'
--                   GROUP BY o.client_type) g), '    no firms') || chr(10)
--        || '   (expect answering_service 0 / all; every other type all / 0)'
--        || chr(10);
--   r := r || 'A2. backfilled rows whose enabled_on is not the firm''s creation date: '
--          || (SELECT count(*) FROM organization_capabilities c JOIN organizations o ON o.id = c.organization_id
--               WHERE c.capability = 'cases' AND c.enabled_on <> LEAST(o.created_at::date, d))
--          || '   (expect 0)' || chr(10);
--   r := r || 'A3. answering-service firms that already have Hub cases: '
--          || (SELECT count(DISTINCT k.organization_id) FROM cases k JOIN organizations o ON o.id = k.organization_id
--               WHERE o.client_type = 'answering_service')
--          || '   (any number is fine: their rows stay readable and untouched. Recorded so it is known)' || chr(10);
--   r := r || 'A4. existing cases at a firm with cases not in force today: '
--          || (SELECT count(*) FROM cases k WHERE NOT capability_in_force(k.organization_id, 'cases'))
--          || '   (the same population as A3; untouched)' || chr(10);
--
--   -- ---- the date rule ---------------------------------------------------------
--   r := r || 'A5. in_force from 10 Jan until 20 Jan, on 9/10/19/20 Jan: '
--          || in_force('2026-01-10', '2026-01-20', '2026-01-09') || '/'
--          || in_force('2026-01-10', '2026-01-20', '2026-01-10') || '/'
--          || in_force('2026-01-10', '2026-01-20', '2026-01-19') || '/'
--          || in_force('2026-01-10', '2026-01-20', '2026-01-20')
--          || '   (expect false/true/true/false: on from, off from, both inclusive)' || chr(10);
--   r := r || '    with no end, years later: ' || in_force('2026-01-10', NULL, '2099-01-01')
--          || '   (expect true)' || chr(10);
--   r := r || 'A6. has_capability calls capability_in_force: '
--          || (SELECT prosrc LIKE '%capability_in_force(org, cap, current_date)%' FROM pg_proc
--               WHERE oid = 'has_capability(uuid, capability)'::regprocedure)
--          || '   (expect true)' || chr(10);
--
--   -- ---- B. the fixture, as Dead Ringers ----------------------------------------
--   PERFORM set_config('app.is_internal', 'on', true);
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ verify 1510 funeral home', 'funeral_home')
--   RETURNING id INTO v_a;
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ verify 1510 answering', 'answering_service')
--   RETURNING id INTO v_b;
--   r := r || 'B1. a new funeral home gets cases from today: '
--          || (SELECT count(*) FROM organization_capabilities
--               WHERE organization_id = v_a AND capability = 'cases' AND enabled_on = d AND disabled_on IS NULL)
--          || '; a new answering service: '
--          || (SELECT count(*) FROM organization_capabilities WHERE organization_id = v_b AND capability = 'cases')
--          || '   (expect 1; 0)' || chr(10);
--
--   INSERT INTO users (email, full_name, auth_user_id)
--   VALUES ('zzz-verify-1510@example.invalid', 'ZZZ Verification', v_auth) RETURNING id INTO v_user;
--   INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id)
--   VALUES (v_user, 'organization', 'professional', v_a);
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_a, 'ZZZ Verify') RETURNING id INTO v_contact;
--   INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at,
--                             contact_id, contact_link_method)
--   VALUES (v_a, 'inbound', now(), now(), v_contact, 'confirmed') RETURNING id INTO v_i1;
--   INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at,
--                             contact_id, contact_link_method)
--   VALUES (v_a, 'inbound', now(), now(), v_contact, 'confirmed') RETURNING id INTO v_i2;
--   PERFORM set_config('app.is_internal', 'off', true);
--
--   PERFORM set_config('request.jwt.claims', json_build_object('sub', v_auth::text)::text, true);
--   PERFORM set_config('role', 'authenticated', true);
--
--   -- ---- cases on ------------------------------------------------------------
--   v_case := create_case_for_call(v_i1, 'at_need', 'deceased', 'Zzzverify');
--   r := r || 'B2. ON: create_case_for_call makes a case: ' || (v_case IS NOT NULL)
--          || '   (expect true)' || chr(10);
--   UPDATE cases SET booked_service_date = d - 1 WHERE id = v_case;
--   r := r || 'B3. ON: the bell asks about it: '
--          || (SELECT count(*) FROM my_cases_awaiting_confirmation() WHERE case_id = v_case)
--          || '   (expect 1)' || chr(10);
--
--   -- ---- cases off from today ------------------------------------------------
--   PERFORM set_config('app.is_internal', 'on', true);
--   -- On for the last 30 days, off from today: so "yesterday" below is a day
--   -- the firm really had cases, not the day before it was created.
--   UPDATE organization_capabilities SET enabled_on = d - 30, disabled_on = d
--    WHERE organization_id = v_a AND capability = 'cases';
--   PERFORM set_config('app.is_internal', 'off', true);
--
--   r := r || 'B4. OFF: in force today / yesterday: '
--          || capability_in_force(v_a, 'cases') || ' / ' || capability_in_force(v_a, 'cases', d - 1)
--          || '   (expect false / true)' || chr(10);
--   BEGIN
--     PERFORM create_case_for_call(v_i2, 'at_need', 'deceased', 'Zzzverify');
--     r := r || 'B5. OFF: create_case_for_call: ALLOWED   (expect KP001)' || chr(10);
--   EXCEPTION WHEN OTHERS THEN
--     r := r || 'B5. OFF: create_case_for_call: ' || SQLSTATE || ' ' || SQLERRM || '   (expect KP001)' || chr(10);
--   END;
--   BEGIN
--     INSERT INTO cases (organization_id, need_type) VALUES (v_a, 'pre_need');
--     r := r || 'B6. OFF: a direct INSERT into cases: ALLOWED   (expect KP001)' || chr(10);
--   EXCEPTION WHEN OTHERS THEN
--     r := r || 'B6. OFF: a direct INSERT into cases: ' || SQLSTATE || '   (expect KP001)' || chr(10);
--   END;
--   BEGIN
--     PERFORM set_call_case(v_i2, v_case);
--     r := r || 'B7. OFF: set_call_case: ALLOWED   (expect KP001)' || chr(10);
--   EXCEPTION WHEN OTHERS THEN
--     r := r || 'B7. OFF: set_call_case: ' || SQLSTATE || ' ' || SQLERRM || '   (expect KP001)' || chr(10);
--   END;
--   BEGIN
--     UPDATE interactions SET case_id = v_case WHERE id = v_i2;
--     r := r || 'B8. OFF: a direct UPDATE of case_id: ALLOWED   (expect KP001)' || chr(10);
--   EXCEPTION WHEN OTHERS THEN
--     r := r || 'B8. OFF: a direct UPDATE of case_id: ' || SQLSTATE || '   (expect KP001)' || chr(10);
--   END;
--   r := r || 'B9. OFF: the bell asks: '
--          || (SELECT count(*) FROM my_cases_awaiting_confirmation() WHERE case_id = v_case)
--          || '   (expect 0)' || chr(10);
--
--   -- what must still work with cases off
--   r := r || 'B10. OFF: the existing case is readable: '
--          || (SELECT count(*) FROM cases WHERE id = v_case) || '   (expect 1)' || chr(10);
--   UPDATE cases SET sale_value = sale_value WHERE id = v_case;
--   GET DIAGNOSTICS n = ROW_COUNT;
--   r := r || 'B11. OFF: the existing case can still be edited: ' || n || '   (expect 1)' || chr(10);
--   UPDATE interactions SET case_link_method = 'confirmed' WHERE id = v_i1;
--   GET DIAGNOSTICS n = ROW_COUNT;
--   r := r || 'B12. OFF: a call already on it can be touched without moving it: ' || n || '   (expect 1)' || chr(10);
--   BEGIN
--     UPDATE interactions SET case_id = NULL WHERE id = v_i1;
--     GET DIAGNOSTICS n = ROW_COUNT;
--     r := r || 'B13. OFF: unlinking a call: ' || n || '   (expect 1: it creates nothing)' || chr(10);
--     RAISE EXCEPTION USING ERRCODE = 'ZZ001';
--   EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
--   END;
--
--   -- ---- the positive half: switched back on ---------------------------------
--   PERFORM set_config('app.is_internal', 'on', true);
--   UPDATE organization_capabilities SET disabled_on = NULL
--    WHERE organization_id = v_a AND capability = 'cases';
--   PERFORM set_config('app.is_internal', 'off', true);
--   PERFORM set_call_case(v_i2, v_case);
--   r := r || 'B14. ON AGAIN: set_call_case links the second call: '
--          || (SELECT count(*) FROM interactions WHERE id = v_i2 AND case_id = v_case)
--          || '   (expect 1)' || chr(10);
--
--   -- the answering service: off from the start
--   BEGIN
--     PERFORM set_config('role', 'none', true);
--     INSERT INTO cases (organization_id, need_type) VALUES (v_b, 'pre_need');
--     r := r || 'B15. the answering service, even as postgres: ALLOWED   (expect KP001)' || chr(10);
--   EXCEPTION WHEN OTHERS THEN
--     r := r || 'B15. the answering service, even as postgres: ' || SQLSTATE
--            || '   (expect KP001: a trigger, so BYPASSRLS doesn''t pass it)' || chr(10);
--   END;
--
--   RAISE EXCEPTION 'VERIFY 20261120T1510_cases_capability (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
