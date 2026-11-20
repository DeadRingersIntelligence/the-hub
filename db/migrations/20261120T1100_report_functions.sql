-- =============================================================================
-- 20261120T1100_report_functions.sql
-- The Hub — the numbers the Reports page shows, worked out where the rule is.
--
-- WHY HERE AND NOT IN THE APP. Revenue is case_revenue_date_for() (stated
-- once, 20261119T1510). A report over every case would either call the per-
-- case function hundreds of times or copy the rule into TypeScript; the
-- second is what the last two days of migrations exist to prevent. So the
-- aggregation lives beside the rule. Planning session ruling, 19 Nov.
--
-- WHAT THE PAGE SHOWS (Mandie, 20 Nov):
--   * case COUNTS first; value only where recorded, as "across N of M cases
--     with a value" — a missing sale_value is visible, never counted as 0;
--   * 13 months, so the current month has the same month last year beside
--     it; the current month marked in progress;
--   * MANAGERS ONLY. Loosening later is easy; tightening after people have
--     seen their numbers is not. Enforced here as well as on the page: these
--     functions are callable through the API, so the page's check alone would
--     be a hint, not a rule;
--   * a lost case is NOT revenue in any month — case_revenue_date_for
--     returns null for it, so it drops out of the month it would have
--     counted in, always. "Marked lost" is a separate ACTIVITY count, by the
--     month it was marked, never added into revenue. Both views, one rule.
--
-- THREE FUNCTIONS, all INVOKER:
--   revenue_by_month(org, from, to, tz)  one row per month in the range
--   revenue_moves(org, month, tz)        the changes behind "this month
--                                        changed after it closed": the why
--   pipeline_now(org)                    the lines that are about today
--
-- ROW-LEVEL SECURITY IS WHAT SCOPES THEM. p_org IS ONLY A FILTER. Every read
-- here goes through the caller's policies, so a firm's manager passing
-- another firm's id gets nothing — verification 5 shows it. Do not make
-- these SECURITY DEFINER: that would turn p_org into the only thing between
-- one firm's revenue and another's. (The manager check below is not a
-- substitute either: it says what ROLE may ask, not WHICH FIRM's rows.)
--
-- MONTHS AND TIME ZONES. Revenue dates (served_on, booked_service_date) are
-- dates, with no zone, so a month's revenue needs none. Two things are
-- timestamps: when a case was marked lost, and when a revenue move happened
-- (change_history.occurred_at). A firm's month ends at its own midnight, so
-- those are read in p_tz. Firms have no zone of their own — locations do, and
-- the app already works out a firm's usual zone from them (activity-zones);
-- the app passes it rather than this file restating that logic. 'UTC' if
-- omitted; an unknown zone name is refused by Postgres in words.
--
-- "CHANGED AFTER IT CLOSED" reads the revenue_date history rows that
-- 20261120T1000 writes for every revenue move: a closed month changed when a
-- row with `from` or `to` in that month was written after the month ended.
-- Moves before 20261120T1000 were never recorded and cannot be found — none
-- happened outside rolled-back verification, and production had no cases.
--
-- managers_notified, returned by revenue_moves, EXCLUDES whoever made the
-- change (20261120T1000). A firm with one manager will read 0 on most rows:
-- the page must say "no other manager was told", not "nobody was told" —
-- for early clients that is the normal case, not the edge.
--
-- NOT SAFE TO RUN TWICE: the precondition refuses if revenue_by_month exists.
--
-- Requires: 20261119T1510 (case_revenue_date_for, case_awaiting_confirmation_
-- for, booked_service_date), 20261120T1000 (the revenue_date history rows),
-- 038 (can_manage_settings), 20261103T1200 (record_migration).
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 0. Precondition
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regprocedure('revenue_by_month(uuid,date,date,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'revenue_by_month already exists — 20261120T1100 has run here'
      USING HINT = 'This file is not safe to run twice. Nothing has been changed.';
  END IF;
  -- The history rows this reads must be written: 20261120T1000 first.
  IF position('managers_notified' IN COALESCE((SELECT prosrc FROM pg_proc
       WHERE oid = to_regprocedure('case_revenue_moved_notify()')), '')) = 0 THEN
    RAISE EXCEPTION 'case_revenue_moved_notify does not write the revenue_date rows; run 20261120T1000 first';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 1. Who may ask: a manager. One statement of it for all three functions.
-- -----------------------------------------------------------------------------
CREATE FUNCTION report_reader_check() RETURNS void
LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF NOT COALESCE(can_manage_settings(), false) THEN
    RAISE EXCEPTION 'reports are for owners and managers'
      USING ERRCODE = '42501',
            HINT = 'Ask an owner or manager at your firm.';
  END IF;
END $$;

COMMENT ON FUNCTION report_reader_check() IS
  'Refuses (42501) unless can_manage_settings(): reports are managers-only '
  '(Mandie, 20 Nov). Says which ROLE may read a report; row-level security '
  'is what decides which FIRM''s rows it reads.';

-- -----------------------------------------------------------------------------
-- 2. Revenue by month
-- -----------------------------------------------------------------------------
CREATE FUNCTION revenue_by_month(p_org uuid, p_from date, p_to date, p_tz text DEFAULT 'UTC')
RETURNS TABLE (
  month               date,     -- the first of the month
  closed              boolean,  -- the month has ended, in p_tz
  counted             integer,  -- cases whose revenue date falls in it
  confirmed           integer,  -- … of which the served date is confirmed
  unconfirmed         integer,  -- … of which it is a passed booked date
  value_total         numeric,  -- sale_value summed over those that have one
  with_value          integer,  -- how many of `counted` have a sale_value
  marked_lost         integer,  -- ACTIVITY: cases marked lost during the month
                                -- (through set_case_status/set_case_lost,
                                -- which write the status history row; a
                                -- direct UPDATE writes none and is not seen)
  changed_after_close integer   -- cases whose revenue left or entered this
                                -- month by a change made after it ended
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
  PERFORM report_reader_check();
  IF p_from IS NULL OR p_to IS NULL OR p_from > p_to THEN
    RAISE EXCEPTION 'choose a range of months, earliest first';
  END IF;
  IF p_to > p_from + interval '36 months' THEN
    RAISE EXCEPTION 'a report covers at most three years at a time';
  END IF;

  -- p_org is a FILTER. Row-level security scopes every read below to what
  -- the caller may see; never make this SECURITY DEFINER.
  RETURN QUERY
  WITH m AS (
    SELECT d::date AS month,
           (d + interval '1 month')::date AS next_month,
           ((d + interval '1 month')::timestamp AT TIME ZONE p_tz) AS ends_at,
           (d::timestamp AT TIME ZONE p_tz) AS starts_at
      FROM generate_series(date_trunc('month', p_from), date_trunc('month', p_to), interval '1 month') d
  ),
  c AS (
    SELECT case_revenue_date_for(status, served_on, booked_service_date) AS rd,
           served_on, sale_value
      FROM cases
     WHERE organization_id = p_org
  ),
  lost AS (
    SELECT h.entity_id, h.occurred_at
      FROM change_history h
     WHERE h.organization_id = p_org
       AND h.entity = 'case'
       AND h.detail->>'field' = 'status'
       AND h.detail->>'to' = 'lost'
       AND h.detail->>'from' IS DISTINCT FROM 'lost'
  ),
  moves AS (
    SELECT h.entity_id, h.occurred_at,
           (h.detail->>'from')::date AS from_date,
           (h.detail->>'to')::date   AS to_date
      FROM change_history h
     WHERE h.organization_id = p_org
       AND h.entity = 'case'
       AND h.detail->>'field' = 'revenue_date'
  )
  SELECT m.month,
         m.ends_at <= now(),
         (SELECT count(*)::int FROM c WHERE c.rd >= m.month AND c.rd < m.next_month),
         (SELECT count(*)::int FROM c WHERE c.rd >= m.month AND c.rd < m.next_month AND c.served_on IS NOT NULL),
         (SELECT count(*)::int FROM c WHERE c.rd >= m.month AND c.rd < m.next_month AND c.served_on IS NULL),
         (SELECT sum(c.sale_value) FROM c WHERE c.rd >= m.month AND c.rd < m.next_month),
         (SELECT count(*)::int FROM c WHERE c.rd >= m.month AND c.rd < m.next_month AND c.sale_value IS NOT NULL),
         -- Distinct CASES: one lost, reinstated and lost again in a month is
         -- one case marked lost, which is what the page says.
         (SELECT count(DISTINCT lost.entity_id)::int FROM lost WHERE lost.occurred_at >= m.starts_at AND lost.occurred_at < m.ends_at),
         (SELECT count(DISTINCT mv.entity_id)::int FROM moves mv
           WHERE mv.occurred_at >= m.ends_at
             AND ((mv.from_date >= m.month AND mv.from_date < m.next_month)
               OR (mv.to_date   >= m.month AND mv.to_date   < m.next_month)))
    FROM m
   ORDER BY m.month;
END $$;

COMMENT ON FUNCTION revenue_by_month(uuid, date, date, text) IS
  'One row per month from p_from to p_to: cases counted as revenue that month '
  '(case_revenue_date_for — confirmed and booked-not-yet-confirmed apart), '
  'their recorded value and how many have one, cases MARKED LOST during the '
  'month (an activity count, never revenue), and how many cases'' revenue '
  'entered or left the month by a change made after it closed (from the '
  'revenue_date history rows, 20261120T1000). Managers only. INVOKER: '
  'ROW-LEVEL SECURITY SCOPES IT AND p_org IS ONLY A FILTER — never make it '
  'SECURITY DEFINER. Timestamps are read in p_tz, the firm''s usual zone, '
  'passed by the app.';

-- -----------------------------------------------------------------------------
-- 3. Why a closed month changed
-- -----------------------------------------------------------------------------
CREATE FUNCTION revenue_moves(p_org uuid, p_month date, p_tz text DEFAULT 'UTC')
RETURNS TABLE (
  case_id           uuid,
  occurred_at       timestamptz,
  actor_label       text,
  summary           text,       -- the sentence the managers were sent
  from_date         date,       -- revenue date before (null: did not count)
  to_date           date,       -- revenue date after  (null: no longer counts)
  reason            text,
  managers_notified integer     -- EXCLUDES whoever made the change
)
LANGUAGE plpgsql STABLE AS $$
DECLARE v_start date := date_trunc('month', p_month)::date;
        v_next  date := (date_trunc('month', p_month) + interval '1 month')::date;
        v_ends  timestamptz := (date_trunc('month', p_month) + interval '1 month')::timestamp AT TIME ZONE p_tz;
BEGIN
  PERFORM report_reader_check();
  -- p_org is a FILTER; row-level security scopes the read. Never DEFINER.
  RETURN QUERY
  SELECT h.entity_id, h.occurred_at, h.actor_label, h.summary,
         (h.detail->>'from')::date, (h.detail->>'to')::date,
         h.detail->>'reason', (h.detail->>'managers_notified')::int
    FROM change_history h
   WHERE h.organization_id = p_org
     AND h.entity = 'case'
     AND h.detail->>'field' = 'revenue_date'
     AND h.occurred_at >= v_ends
     AND (((h.detail->>'from')::date >= v_start AND (h.detail->>'from')::date < v_next)
       OR ((h.detail->>'to')::date   >= v_start AND (h.detail->>'to')::date   < v_next))
   ORDER BY h.occurred_at;
END $$;

COMMENT ON FUNCTION revenue_moves(uuid, date, text) IS
  'The revenue moves behind "this month changed after it closed": every '
  'revenue_date history row (20261120T1000) whose from or to date is in '
  'p_month and which was written after the month ended in p_tz, oldest '
  'first, with the sentence, the reason and managers_notified — which '
  'EXCLUDES the person who made the change, so 0 means "no other manager was '
  'told". Managers only. INVOKER: row-level security scopes it; p_org is '
  'only a filter.';

-- -----------------------------------------------------------------------------
-- 4. The pipeline, as of today
-- -----------------------------------------------------------------------------
CREATE FUNCTION pipeline_now(p_org uuid)
RETURNS TABLE (
  not_booked             integer,  -- active, no booked or served date
  booked_ahead           integer,  -- active, booked for a date still to come
  awaiting_confirmation  integer,  -- booked date passed, nobody confirmed:
                                   -- already counted as revenue
  on_hold                integer,
  on_hold_would_count    integer   -- … of which would count if taken off hold
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
  PERFORM report_reader_check();
  -- p_org is a FILTER; row-level security scopes the read. Never DEFINER.
  RETURN QUERY
  SELECT
    count(*) FILTER (WHERE status = 'active' AND served_on IS NULL AND booked_service_date IS NULL)::int,
    count(*) FILTER (WHERE status = 'active' AND served_on IS NULL AND booked_service_date > current_date)::int,
    count(*) FILTER (WHERE case_awaiting_confirmation_for(status, served_on, booked_service_date)
                       AND status <> 'on_hold')::int,
    count(*) FILTER (WHERE status = 'on_hold')::int,
    count(*) FILTER (WHERE status = 'on_hold'
                       AND case_revenue_date_for('active', served_on, booked_service_date) IS NOT NULL)::int
    FROM cases
   WHERE organization_id = p_org;
END $$;

COMMENT ON FUNCTION pipeline_now(uuid) IS
  'The report''s lines about today: active cases not yet booked, booked for '
  'a date to come, awaiting confirmation (already counted as revenue on the '
  'booked date), on hold, and on hold that would count if released — the '
  'last asked of case_revenue_date_for as if active, not restated. Managers '
  'only. INVOKER: row-level security scopes it; p_org is only a filter.';

-- -----------------------------------------------------------------------------
-- 5. Grants: the explicit pair
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION report_reader_check() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION report_reader_check() TO authenticated;
REVOKE ALL ON FUNCTION revenue_by_month(uuid, date, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION revenue_by_month(uuid, date, date, text) TO authenticated;
REVOKE ALL ON FUNCTION revenue_moves(uuid, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION revenue_moves(uuid, date, text) TO authenticated;
REVOKE ALL ON FUNCTION pipeline_now(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION pipeline_now(uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- 6. The reviewed bodies
-- -----------------------------------------------------------------------------
DO $$
DECLARE bad text;
BEGIN
  SELECT string_agg(e.sig || ' is ' || COALESCE(md5(p.prosrc), 'MISSING'), '; ') INTO bad
    FROM (VALUES
    ('pipeline_now(uuid)', 'ad89f1435a353e2d291db779269b36f7'),
    ('report_reader_check()', 'fa01dc5a9693dba9a291acad0ec6400d'),
    ('revenue_by_month(uuid,date,date,text)', '3977f30b2271022b2de32583481548c5'),
    ('revenue_moves(uuid,date,text)', '6e71cd4ef364431ff5d4d22484bad69f')
         ) AS e(sig, want)
    LEFT JOIN pg_proc p ON p.oid = to_regprocedure(e.sig)
   WHERE md5(p.prosrc) IS DISTINCT FROM e.want;
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'not the reviewed bodies: %. Nothing has been kept.', bad;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 7. The ledger
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261120T1100_report_functions.sql',
    NULL,
    'revenue_by_month, revenue_moves, pipeline_now, and report_reader_check '
    '(managers only). INVOKER: row-level security scopes them; p_org is a '
    'filter. Revenue by case_revenue_date_for; changes after a month closed '
    'from the revenue_date history rows of 20261120T1000.');
END $rec$;

COMMIT;

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- Builds two firms of its own, so no real case can move the numbers: a
-- report firm with a manager, a director and seven cases of known outcome,
-- across a closed month (two months ago) and today; and another firm with one
-- counted case and its own manager. Line 6 is the positive half of the RLS
-- check — the case is there for its own firm, so the other firm's 0 is RLS.
--
-- RUN ON A SCRATCH REBUILD, 20 Nov — every migration on main, with
-- 20261120T1000 and this file: every line matched. NOT YET RUN ON STAGING.
--
-- DO $$
-- DECLARE
--   r text := ''; t date := current_date;
--   m0 date := (date_trunc('month', current_date) - interval '2 months')::date;   -- a closed month
--   mc date := date_trunc('month', current_date)::date;                           -- this month
--   v_org uuid; v_org2 uuid; v_mgr uuid; v_dir uuid; v_x uuid;
--   a_mgr uuid := gen_random_uuid(); a_dir uuid := gen_random_uuid(); a_x uuid := gen_random_uuid();
--   k_lost uuid; n int; x record;
-- BEGIN
--   PERFORM set_config('app.is_internal', 'on', true);
--   -- Two firms of the fixture's own, so no real case can move these numbers.
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ Report Firm', 'funeral_home') RETURNING id INTO v_org;
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ Other Firm', 'funeral_home') RETURNING id INTO v_org2;
--   INSERT INTO users (email, full_name, auth_user_id, active_organization_id)
--   VALUES ('zzz-b-mgr@example.invalid', 'ZZZ Manager', a_mgr, v_org) RETURNING id INTO v_mgr;
--   INSERT INTO users (email, full_name, auth_user_id, active_organization_id)
--   VALUES ('zzz-b-dir@example.invalid', 'ZZZ Director', a_dir, v_org) RETURNING id INTO v_dir;
--   INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id) VALUES
--     (v_mgr, 'organization', 'manager', v_org), (v_dir, 'organization', 'professional', v_org);
--   -- A manager of the OTHER firm, to read it back as its own (the positive half).
--   INSERT INTO users (email, full_name, auth_user_id, active_organization_id)
--   VALUES ('zzz-b-x@example.invalid', 'ZZZ Other Manager', a_x, v_org2) RETURNING id INTO v_x;
--   INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id) VALUES (v_x, 'organization', 'manager', v_org2);
--
--   -- The report firm's cases. status_item_id set as the app's flow would.
--   INSERT INTO cases (organization_id, need_type, served_on, sale_value, status_item_id)
--   VALUES (v_org, 'at_need', m0 + 4, 1000, case_status_default(v_org, 'active'));          -- k1 confirmed in m0, valued
--   INSERT INTO cases (organization_id, need_type, booked_service_date, status_item_id)
--   VALUES (v_org, 'at_need', m0 + 9, case_status_default(v_org, 'active'));                -- k2 booked in m0, unconfirmed
--   INSERT INTO cases (organization_id, need_type, served_on, status_item_id)
--   VALUES (v_org, 'at_need', m0 + 2, case_status_default(v_org, 'active')) RETURNING id INTO k_lost; -- k3 lost after m0 closed
--   INSERT INTO cases (organization_id, need_type, served_on, status, status_item_id)
--   VALUES (v_org, 'at_need', m0 + 6, 'on_hold', case_status_default(v_org, 'on_hold'));    -- k4 on hold, would count
--   INSERT INTO cases (organization_id, need_type, status_item_id)
--   VALUES (v_org, 'pre_need', case_status_default(v_org, 'active'));                       -- k5 not booked
--   INSERT INTO cases (organization_id, need_type, booked_service_date, status_item_id)
--   VALUES (v_org, 'at_need', t + 20, case_status_default(v_org, 'active'));                -- k6 booked ahead
--   INSERT INTO cases (organization_id, need_type, booked_service_date, status_item_id)
--   VALUES (v_org, 'at_need', t, case_status_default(v_org, 'active'));                     -- k7 booked today: awaiting
--   -- The other firm: one case counted in m0, which the report firm must not see.
--   INSERT INTO cases (organization_id, need_type, served_on, status_item_id)
--   VALUES (v_org2, 'at_need', m0 + 4, case_status_default(v_org2, 'active'));
--
--   -- ---- the director marks k3 lost, now: after m0 closed ----------------------
--   PERFORM set_config('app.is_internal', 'off', true);
--   PERFORM set_config('request.jwt.claims', json_build_object('sub', a_dir::text)::text, true);
--   PERFORM set_config('role', 'authenticated', true);
--   PERFORM set_case_lost(k_lost, true, 'ZZZ family disputed');
--
--   -- 1. A non-manager is refused, for that reason.
--   BEGIN
--     PERFORM * FROM revenue_by_month(v_org, m0, mc);
--     r := r || '1. a professional (non-manager) read the report: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || '1. a professional (non-manager) refused: ' || SQLERRM || ' [' || SQLSTATE || ']'
--            || CASE WHEN SQLSTATE = '42501' AND SQLERRM LIKE '%for owners and managers%' THEN '   (right reason)' ELSE '   (WRONG REASON)' END || chr(10);
--   END;
--
--   -- ---- as the report firm's manager -------------------------------------------
--   PERFORM set_config('request.jwt.claims', json_build_object('sub', a_mgr::text)::text, true);
--   SELECT * INTO x FROM revenue_by_month(v_org, m0, m0) LIMIT 1;
--   r := r || '2. the closed month — closed ' || x.closed || ', counted ' || x.counted || ' (confirmed ' || x.confirmed
--          || ', unconfirmed ' || x.unconfirmed || '), value ' || COALESCE(x.value_total::text, 'null') || ' across ' || x.with_value
--          || ', changed after close ' || x.changed_after_close
--          || '   (expect closed true, counted 2 (1, 1), value 1000.00 across 1, changed after close 1 — the lost k3 is NOT counted)' || chr(10);
--   SELECT * INTO x FROM revenue_by_month(v_org, mc, mc) LIMIT 1;
--   r := r || '3. this month — closed ' || x.closed || ', counted ' || x.counted || ' (unconfirmed ' || x.unconfirmed
--          || '), marked lost ' || x.marked_lost
--          || '   (expect closed false, counted 1 (1) — k7 booked today, marked lost 1 — k3, an activity, not revenue)' || chr(10);
--   SELECT count(*) INTO n FROM revenue_by_month(v_org, (mc - interval '12 months')::date, mc);
--   r := r || '   13-month range returns ' || n || ' rows   (expect 13)' || chr(10);
--
--   SELECT * INTO x FROM revenue_moves(v_org, m0) LIMIT 1;
--   r := r || '4. why the closed month changed — from ' || COALESCE(x.from_date::text, 'null') || ' to ' || COALESCE(x.to_date::text, 'null')
--          || ', reason ' || COALESCE(x.reason, 'null') || ', other managers told ' || COALESCE(x.managers_notified::text, 'null')
--          || '   (expect from ' || (m0 + 2) || ' to null, reason ZZZ family disputed, told 1 — the manager; the director made it)' || chr(10);
--
--   SELECT * INTO x FROM pipeline_now(v_org);
--   r := r || '5. pipeline now — not booked ' || x.not_booked || ', booked ahead ' || x.booked_ahead
--          || ', awaiting confirmation ' || x.awaiting_confirmation || ', on hold ' || x.on_hold || ' (would count ' || x.on_hold_would_count || ')'
--          || '   (expect 1, 1, 2 — k2 booked in the closed month and k7 booked today, both unconfirmed — and 1 (1))' || chr(10);
--
--   -- 6. Row-level security, not p_org, is what scopes it — with its positive half.
--   SELECT counted INTO n FROM revenue_by_month(v_org2, m0, m0);
--   r := r || '6. the report firm''s manager asking for the OTHER firm''s id — counted ' || n
--          || '   (expect 0: RLS hides it; p_org is only a filter)' || chr(10);
--   PERFORM set_config('request.jwt.claims', json_build_object('sub', a_x::text)::text, true);
--   SELECT counted INTO n FROM revenue_by_month(v_org2, m0, m0);
--   r := r || '   the other firm''s own manager, same call — counted ' || n
--          || '   (expect 1: the case is there, so the 0 above is RLS, not an empty firm)' || chr(10);
--
--   -- 7. An unknown time zone is refused, not guessed.
--   BEGIN
--     PERFORM * FROM revenue_by_month(v_org2, m0, m0, 'Not/AZone');
--     r := r || '7. an unknown time zone: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || '7. an unknown time zone refused: ' || SQLERRM
--            || CASE WHEN SQLERRM LIKE '%time zone%' THEN '   (right reason)' ELSE '   (WRONG REASON)' END || chr(10);
--   END;
--
--   RAISE EXCEPTION 'VERIFY 20261120T1100_report_functions (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
