-- =============================================================================
-- 20261120T1600_open_case_offer.sql
-- The Hub — a call from a number already on an open case is offered to it.
--
-- WHY. Backlog item 6, settled as design B (planning, 20 November). When a
-- call arrives from a number already on an open case, offer to join it. This
-- is the offer the app already makes at case creation (a contact's other
-- calls, unticked), extended to calls that arrive later. No new link type and
-- no same_case links: the offer is worked out from what's there. It rests on
-- Anima-Care: 6,251 inbound calls over three months, 40.4% of callers calling
-- more than once, and 58.5% of repeat contact more than an hour apart.
--
-- THE CASE BEING OPEN IS THE WINDOW. Planning: no "within N days" lookback,
-- because openness covers both rhythms measured without a constant to tune.
-- "Open" wasn't defined anywhere, so this file defines it, once:
--
--   case_is_open_for(status, served_on)
--     open  = not lost, and no confirmed service date.
--     So active and on hold are open. A booked date (past or future) doesn't
--     close a case. Confirming the service does, and so does marking it lost.
--
--   THIS DEFINITION IS MINE AND NEEDS A RULING. The alternative is "not lost"
--   alone. That would offer a thank-you call months after the funeral to the
--   case, but a won case would then stay open for ever, and that is an N-day
--   window of infinity. Served-closes-it gives the window an end that a
--   person sets, which is what openness was chosen for.
--
-- WHAT COUNTS AS "A NUMBER ALREADY ON THE CASE", by three routes, all at the
-- call's own firm:
--
--   contact  the call's contact is on the case (case_contacts). This is the
--            common route, since a call is matched to its contact by number
--            when it comes in.
--   number   the call's number belongs to a contact on the case. It catches
--            a call whose contact link was taken off or changed by hand.
--   number   the call's number has called or been called on the case before.
--            It catches a relative whose calls were joined to the case but who
--            was never added to it as a contact.
--
-- The call's number is the other party's: from_e164 inbound, to_e164 outbound.
--
-- NOTHING WHEN CASES ARE OFF. capability_in_force() (20261120T1510) is the
-- first condition. The app also hides the offer, but the function answers
-- the same whoever asks. Nothing either for a call already on a case, or for
-- a consultation leg (never its own row).
--
-- AN OFFER, NOT A LINK. This file writes nothing. Accepting is set_call_case
-- (050), with its history and its KP001. Declining isn't recorded: the offer
-- stays on the call while it has no case and the case is open. Whether
-- "no" should be remembered is a question for review, not decided here.
--
-- INVOKER: RLS scopes everything to the caller's firm.
--
-- NOT SAFE TO RUN TWICE: section 1 refuses if open_cases_for_call exists.
--
-- Requires: 050 (set_call_case), 057 (cases.status), 20261119T1510
--           (served_on), 20261120T1510 (capability_in_force),
--           20261103T1200 (record_migration).
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Preconditions
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM schema_migrations
                  WHERE filename = '20261120T1510_cases_capability.sql') THEN
    RAISE EXCEPTION '20261120T1510 has not run here; run it first';
  END IF;
  IF to_regprocedure('case_is_open_for(case_status, date)') IS NOT NULL
     OR to_regprocedure('open_cases_for_call(uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'case_is_open_for or open_cases_for_call already exists; this file has run'
      USING HINT = 'Not safe to run twice. Stop and read the ledger.';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. What "open" means, once
-- -----------------------------------------------------------------------------
CREATE FUNCTION case_is_open_for(p_status case_status, p_served_on date)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT p_status <> 'lost' AND p_served_on IS NULL
$$;

COMMENT ON FUNCTION case_is_open_for(case_status, date) IS
  'Whether a case is open: not lost, and no confirmed service date. Active and '
  'on hold are open; a booked date doesn''t close a case, confirming the '
  'service does. The window for offering a newly arrived call to a case '
  '(open_cases_for_call), with no day-count lookback (20261120T1600).';

-- -----------------------------------------------------------------------------
-- 3. The offer
-- -----------------------------------------------------------------------------
CREATE FUNCTION open_cases_for_call(p_interaction uuid)
RETURNS TABLE (case_id uuid, family_name text, need_type case_need_type,
               opened_on date, via text)
LANGUAGE sql STABLE AS $$
  WITH c AS (
    SELECT i.id, i.organization_id, i.contact_id,
           CASE WHEN i.direction = 'inbound' THEN i.from_e164 ELSE i.to_e164 END AS peer
      FROM interactions i
     WHERE i.id = p_interaction
       AND i.case_id IS NULL
       AND i.consultation_of IS NULL
       AND capability_in_force(i.organization_id, 'cases')
  ),
  open_cases AS (
    SELECT k.id, k.need_type, k.opened_on
      FROM cases k JOIN c ON k.organization_id = c.organization_id
     WHERE case_is_open_for(k.status, k.served_on)
  ),
  m AS (
    -- The call's contact is on the case.
    SELECT cc.case_id, 'contact' AS via, 1 AS rank
      FROM c JOIN case_contacts cc ON cc.contact_id = c.contact_id
    UNION ALL
    -- The call's number belongs to a contact on the case.
    SELECT cc.case_id, 'number', 2
      FROM c
      JOIN contact_phones p ON p.organization_id = c.organization_id AND p.e164 = c.peer
      JOIN case_contacts cc ON cc.contact_id = p.contact_id
    UNION ALL
    -- The call's number has called, or been called, on the case before.
    SELECT o.case_id, 'number', 2
      FROM c
      JOIN open_cases oc ON true
      JOIN interactions o ON o.case_id = oc.id
     WHERE c.peer IS NOT NULL
       AND o.id <> c.id
       AND c.peer = CASE WHEN o.direction = 'inbound' THEN o.from_e164 ELSE o.to_e164 END
  )
  SELECT oc.id,
         (SELECT d.last_name FROM case_decedents cd
            JOIN decedents d ON d.id = cd.decedent_id
           WHERE cd.case_id = oc.id AND d.last_name IS NOT NULL
           ORDER BY d.last_name LIMIT 1),
         oc.need_type,
         oc.opened_on,
         (array_agg(m.via ORDER BY m.rank))[1]
    FROM m JOIN open_cases oc ON oc.id = m.case_id
   GROUP BY oc.id, oc.need_type, oc.opened_on
   ORDER BY min(m.rank), oc.opened_on DESC NULLS LAST, oc.id
   LIMIT 5
$$;

COMMENT ON FUNCTION open_cases_for_call(uuid) IS
  'The open cases (case_is_open_for) a call could join: its contact is on the '
  'case, its number belongs to a contact on the case, or its number has called '
  'on the case before. via says which: contact, or number. Nothing for a call '
  'already on a case, a consultation leg, or a firm without cases '
  '(capability_in_force). Writes nothing; accepting is set_call_case. INVOKER '
  '(20261120T1600).';

REVOKE ALL ON FUNCTION case_is_open_for(case_status, date) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION open_cases_for_call(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION case_is_open_for(case_status, date) TO authenticated;
GRANT EXECUTE ON FUNCTION open_cases_for_call(uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- 4. Record it
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261120T1600_open_case_offer.sql',
    NULL,
    'Design B: case_is_open_for() defines open once (not lost, not served); '
    'open_cases_for_call() offers a call to the open cases its contact or '
    'number is already on. Nothing when cases are off. Writes nothing.');
END $rec$;

COMMIT;

-- =============================================================================
-- Verification — run AFTER the file, as its own statement. One block,
-- everything rolled back by the closing RAISE.
--
-- Two fixture firms. Firm A has a case in every state, three numbers, and a
-- professional who asks. Firm B shares a number with firm A and has an open
-- case reached by it, so a leak across firms would show. All asking runs as
-- authenticated.
--
--   Tom  (contact, 0101) on K1 active, K2 lost, K3 served
--   Ann  (contact, 0102) on K4 on hold
--   0199 (no contact)    has called on K5 active
--   firm B: 0199 has called on its own open case
--
-- DO $$
-- DECLARE
--   r text := ''; n int; s text;
--   v_a uuid; v_b uuid; v_user uuid; v_auth uuid := gen_random_uuid();
--   v_tom uuid; v_ann uuid;
--   k1 uuid; k2 uuid; k3 uuid; k4 uuid; k5 uuid; kb uuid;
--   c_tom uuid; c_ann uuid; c_199 uuid; c_out uuid; c_on uuid; c_none uuid;
--   d date := current_date;
-- BEGIN
--   r := r || '1. open: active/on hold/lost/served: '
--          || case_is_open_for('active', NULL) || '/' || case_is_open_for('on_hold', NULL) || '/'
--          || case_is_open_for('lost', NULL) || '/' || case_is_open_for('active', d - 3)
--          || '   (expect true/true/false/false; a booked date is not an argument, so it can''t close one)'
--          || chr(10);
--
--   PERFORM set_config('app.is_internal', 'on', true);
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ verify 1600 A', 'funeral_home') RETURNING id INTO v_a;
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ verify 1600 B', 'funeral_home') RETURNING id INTO v_b;
--   INSERT INTO users (email, full_name, auth_user_id)
--   VALUES ('zzz-verify-1600@example.invalid', 'ZZZ Verification', v_auth) RETURNING id INTO v_user;
--   INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id)
--   VALUES (v_user, 'organization', 'professional', v_a);
--
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_a, 'ZZZ Tom') RETURNING id INTO v_tom;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_a, 'ZZZ Ann') RETURNING id INTO v_ann;
--   INSERT INTO contact_phones (organization_id, contact_id, e164, is_primary) VALUES
--     (v_a, v_tom, '+15135550101', true), (v_a, v_ann, '+15135550102', true);
--
--   INSERT INTO cases (organization_id, need_type) VALUES (v_a, 'at_need') RETURNING id INTO k1;
--   INSERT INTO cases (organization_id, need_type) VALUES (v_a, 'at_need') RETURNING id INTO k2;
--   INSERT INTO cases (organization_id, need_type) VALUES (v_a, 'at_need') RETURNING id INTO k3;
--   INSERT INTO cases (organization_id, need_type) VALUES (v_a, 'pre_need') RETURNING id INTO k4;
--   INSERT INTO cases (organization_id, need_type) VALUES (v_a, 'at_need') RETURNING id INTO k5;
--   INSERT INTO cases (organization_id, need_type) VALUES (v_b, 'at_need') RETURNING id INTO kb;
--   UPDATE cases SET status = 'lost' WHERE id = k2;
--   UPDATE cases SET served_on = d - 1 WHERE id = k3;
--   UPDATE cases SET status = 'on_hold' WHERE id = k4;
--   INSERT INTO case_contacts (case_id, contact_id) VALUES (k1, v_tom), (k2, v_tom), (k3, v_tom), (k4, v_ann);
--
--   -- earlier calls already on cases: 0199 on K5 (firm A) and on KB (firm B)
--   INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at, from_e164, case_id, case_link_method)
--   VALUES (v_a, 'inbound', now() - interval '2 days', now() - interval '2 days', '+15135550199', k5, 'confirmed'),
--          (v_b, 'inbound', now() - interval '2 days', now() - interval '2 days', '+15135550199', kb, 'confirmed');
--
--   -- the calls that arrive now
--   INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at, from_e164, contact_id, contact_link_method)
--   VALUES (v_a, 'inbound', now(), now(), '+15135550101', v_tom, 'inferred') RETURNING id INTO c_tom;
--   INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at, from_e164)
--   VALUES (v_a, 'inbound', now(), now(), '+15135550102') RETURNING id INTO c_ann;  -- contact link taken off
--   INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at, from_e164)
--   VALUES (v_a, 'inbound', now(), now(), '+15135550199') RETURNING id INTO c_199;
--   INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at, from_e164, to_e164)
--   VALUES (v_a, 'outbound', now(), now(), '+15135550000', '+15135550199') RETURNING id INTO c_out;
--   INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at, from_e164, contact_id, contact_link_method, case_id, case_link_method)
--   VALUES (v_a, 'inbound', now(), now(), '+15135550101', v_tom, 'inferred', k1, 'confirmed') RETURNING id INTO c_on;
--   INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at, from_e164)
--   VALUES (v_a, 'inbound', now(), now(), '+15135550777') RETURNING id INTO c_none;
--   PERFORM set_config('app.is_internal', 'off', true);
--
--   PERFORM set_config('request.jwt.claims', json_build_object('sub', v_auth::text)::text, true);
--   PERFORM set_config('role', 'authenticated', true);
--
--   SELECT string_agg(CASE o.case_id WHEN k1 THEN 'K1' WHEN k2 THEN 'K2' WHEN k3 THEN 'K3' WHEN k4 THEN 'K4'
--                     WHEN k5 THEN 'K5' WHEN kb THEN 'KB' END || ':' || o.via, ', ') INTO s
--     FROM open_cases_for_call(c_tom) o;
--   r := r || '2. Tom calls: ' || COALESCE(s, 'nothing') || '   (expect K1:contact. K2 is lost, K3 served)' || chr(10);
--   SELECT string_agg(CASE o.case_id WHEN k4 THEN 'K4' ELSE '??' END || ':' || o.via, ', ') INTO s FROM open_cases_for_call(c_ann) o;
--   r := r || '3. Ann''s number, no contact on the call: ' || COALESCE(s, 'nothing') || '   (expect K4:number. On hold is open)' || chr(10);
--   SELECT string_agg(CASE o.case_id WHEN k5 THEN 'K5' WHEN kb THEN 'KB' ELSE '??' END || ':' || o.via, ', ') INTO s FROM open_cases_for_call(c_199) o;
--   r := r || '4. 0199 calls again: ' || COALESCE(s, 'nothing') || '   (expect K5:number. Not KB: firm B''s)' || chr(10);
--   -- the same as Dead Ringers, who can see firm B: the firm match, not RLS, keeps KB out
--   PERFORM set_config('app.is_internal', 'on', true);
--   SELECT string_agg(CASE o.case_id WHEN k5 THEN 'K5' WHEN kb THEN 'KB' ELSE '??' END || ':' || o.via, ', ') INTO s FROM open_cases_for_call(c_199) o;
--   PERFORM set_config('app.is_internal', 'off', true);
--   r := r || '4b. the same, asked by Dead Ringers: ' || COALESCE(s, 'nothing') || '   (expect K5:number. Not KB)' || chr(10);
--   SELECT string_agg(CASE o.case_id WHEN k5 THEN 'K5' ELSE '??' END || ':' || o.via, ', ') INTO s FROM open_cases_for_call(c_out) o;
--   r := r || '5. the firm calls 0199: ' || COALESCE(s, 'nothing') || '   (expect K5:number. Outbound reads to_e164)' || chr(10);
--   SELECT count(*) INTO n FROM open_cases_for_call(c_on);
--   r := r || '6. a call already on a case: ' || n || '   (expect 0)' || chr(10);
--   SELECT count(*) INTO n FROM open_cases_for_call(c_none);
--   r := r || '7. a number nobody knows: ' || n || '   (expect 0)' || chr(10);
--   SELECT family_name IS NULL INTO STRICT s FROM open_cases_for_call(c_tom);
--   r := r || '8. a case with no named decedent gives a null family name: ' || s || '   (expect true)' || chr(10);
--
--   -- accepting the offer is set_call_case; afterwards there's nothing to offer
--   PERFORM set_call_case(c_tom, k1);
--   SELECT count(*) INTO n FROM open_cases_for_call(c_tom);
--   r := r || '9. after accepting: ' || n || '   (expect 0)' || chr(10);
--
--   -- served closes the window
--   PERFORM set_config('app.is_internal', 'on', true);
--   UPDATE cases SET served_on = d WHERE id = k5;
--   PERFORM set_config('app.is_internal', 'off', true);
--   SELECT count(*) INTO n FROM open_cases_for_call(c_199);
--   r := r || '10. 0199 again, K5 now served: ' || n || '   (expect 0)' || chr(10);
--
--   -- cases off: nothing at all
--   PERFORM set_config('app.is_internal', 'on', true);
--   UPDATE organization_capabilities SET enabled_on = d - 30, disabled_on = d
--    WHERE organization_id = v_a AND capability = 'cases';
--   PERFORM set_config('app.is_internal', 'off', true);
--   SELECT count(*) INTO n FROM open_cases_for_call(c_ann);
--   r := r || '11. cases off: Ann''s number again: ' || n || '   (expect 0, where 3. found K4)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261120T1600_open_case_offer (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
