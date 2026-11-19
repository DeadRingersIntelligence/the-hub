-- =============================================================================
-- 20261119T1510_booked_and_served_dates.sql
-- The Hub — a booked service date, revenue derived from it, a served case
-- that can still be lost, and managers told whenever money moves.
--
-- Designed in the planning session, 19 Nov, from Mandie's ruling of 16 and
-- 19 Nov; written in the app session. Reviewed before it runs.
--
-- WHAT CHANGES, IN ONE PARAGRAPH. A case gets booked_service_date, which may
-- be in the future. Revenue is no longer "served_on IS NOT NULL": it is
-- case_revenue_date(), which is the confirmed served_on if there is one,
-- otherwise the booked date once it has arrived, and nothing for a lost case.
-- Nothing has to run for a booked case to become revenue — the date arriving
-- is enough. served_on keeps its meaning and its no-future rule, and becomes
-- "a person confirmed the date": while it is null and the booked date has
-- passed, the case is awaiting confirmation, and the person responsible for
-- it is asked to confirm, correct, or mark the family lost.
--
-- WHAT THIS REVERSES from 20261030T2100, deliberately:
--
--   * A SERVED CASE CAN BE MARKED LOST. 2100 refused it ("served revenue is
--     final"). Mandie's ruling: a family that disputes after the service can
--     cost the firm the revenue, and the case must be able to say so.
--
--   * MARKING LOST DOES NOT CLEAR served_on. The service happened; erasing
--     the date would record a fact about money by destroying a fact about
--     the world, and would be a way around the reason that removing a date
--     requires. Revenue excludes lost cases instead. This is the rule most
--     likely to be "tidied" later — verification 4 exists for it.
--
--   * NO MANAGER GATE on removing a service date. 2100 required one. Planning
--     session, 19 Nov: a gate on one door and not the other makes marking
--     lost the way around it, and a director recording a dispute should not
--     have to find someone to approve it. The control is visibility instead
--     of permission: both doors need a reason, and both notify the firm's
--     managers with that reason in the body.
--
--   * CHANGING a recorded service date now needs a reason too. 2100 let a
--     correction through without one; it can move revenue between months,
--     which is the thing a manager is now told about.
--
-- REVENUE IN A PAST MONTH CAN NOW MOVE. That is the price of the ruling and
-- it is accepted. What makes a moved month explicable afterwards is the
-- reason on the history row and the notification each manager received.
-- Whoever builds reports should say on the report that a closed month is not
-- frozen, and point at where the reasons live.
--
-- THE RULES ARE STATED ONCE. Three questions are asked in several places —
-- does this case count as revenue and on what date, is it awaiting
-- confirmation, who is responsible for it — and each is one function. The
-- first two come in two forms: *_for(status, served, booked), the rule over
-- values, and *(p_case), which reads the row and calls it. The values form
-- exists because the notification trigger has to ask the question of the row
-- as it WAS (OLD), which no function taking an id can see.
--
-- WHY THE MANAGER NOTIFICATION IS A TRIGGER, and not a call inside the
-- functions. Nobody can insert into notifications except a SECURITY DEFINER
-- function (20261030T1930 §2), and a definer helper that the invoker
-- functions could call would have to be executable by authenticated — at
-- which point anyone could send any manager any text. A trigger needs no
-- EXECUTE grant (PostgreSQL checks it at CREATE TRIGGER), so there is no
-- grantable entry point, the same reason 1930 put its work in a trigger. And
-- it fires on the row changing, so a direct UPDATE of cases, which
-- authenticated can still issue, notifies managers just the same — with "no
-- reason recorded", which is itself worth a manager knowing.
--
-- THE REASON REACHES THE TRIGGER through a transaction-local setting,
-- hub.case_change_reason, set by the function just before its UPDATE. A
-- caller could set it too; all that buys them is choosing the reason text,
-- which they choose anyway by passing p_reason. No policy and no function
-- reads hub.* for any decision — that is what makes it safe, and why it is
-- not under app.*, which policies DO read (db/README.md, "What every policy
-- rests on"). Transaction-local, because on a pooled connection anything
-- longer outlives the request (same section, "set_config and the pool").
--
-- created_by IS A COLUMN, not a reading of change_history. The 'created' row
-- carries actor_user_id but is commentary: it can be missing and nothing
-- enforces it. A notification that depends on parsing history goes nowhere
-- silently. Backfilled from those rows; where none exists it stays null and
-- case_responsible_users() falls through to the managers, which is the
-- designed backstop. A BEFORE INSERT trigger fills it for new cases, so
-- create_case_for_call()'s body is not replaced to do it.
--
-- NOT SAFE TO RUN TWICE. ADD COLUMN and the DROP/CREATE of two functions
-- whose signatures change would half-apply. The precondition refuses a
-- second run, and says so.
--
-- Requires, by what it actually uses:
--   016            change_history, record_change()
--   050            hand_link_actor()
--   057            cases.status, delete_case()
--   20261030T1930  notifications, case_notification_recipients()
--   20261030T2100  served_on, status_item_id, case_status_default(), and the
--                  three bodies this replaces
--   20261103T1200  record_migration()
--   20261119T1500  notification_event 'case_revenue_moved'
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 0. Precondition: the bodies this replaces are 2100's, and this has not run
--
-- Whole-body md5, because each is replaced whole. The three values were
-- computed from 20261030T2100 as it is on main; the ledger's backfill row for
-- it says it ran on both databases with those functions present. If either
-- database disagrees, stop and compare: it means something replaced a body
-- without a file, and this migration would silently discard that change.
-- -----------------------------------------------------------------------------
DO $$
DECLARE v text;
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public' AND table_name = 'cases'
                AND column_name = 'booked_service_date') THEN
    RAISE EXCEPTION 'cases.booked_service_date already exists — 20261119T1510 has run here'
      USING HINT = 'This file is not safe to run twice. Nothing has been changed.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
                  WHERE t.typname = 'notification_event'
                    AND e.enumlabel = 'case_revenue_moved') THEN
    RAISE EXCEPTION 'notification_event has no case_revenue_moved; run 20261119T1500 first';
  END IF;

  SELECT md5(prosrc) INTO v FROM pg_proc
   WHERE oid = to_regprocedure('set_case_served(uuid,date,text)');
  IF v IS DISTINCT FROM '3e261d31d126e29866819a66d78ebbd6' THEN
    RAISE EXCEPTION 'set_case_served is not 20261030T2100''s body (found %); stop and compare', v;
  END IF;

  SELECT md5(prosrc) INTO v FROM pg_proc
   WHERE oid = to_regprocedure('set_case_status(uuid,uuid)');
  IF v IS DISTINCT FROM '4c792da1bbd146271b08c86069afb0de' THEN
    RAISE EXCEPTION 'set_case_status is not 20261030T2100''s body (found %); stop and compare', v;
  END IF;

  SELECT md5(prosrc) INTO v FROM pg_proc
   WHERE oid = to_regprocedure('set_case_lost(uuid,boolean)');
  IF v IS DISTINCT FROM '5992fa53f7ff49e426fcc825502c2178' THEN
    RAISE EXCEPTION 'set_case_lost is not 20261030T2100''s body (found %); stop and compare', v;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 1. Two columns
-- -----------------------------------------------------------------------------
ALTER TABLE cases ADD COLUMN booked_service_date date;
ALTER TABLE cases ADD COLUMN created_by uuid REFERENCES users(id) ON DELETE SET NULL;

-- Partial, like cases_served_idx: the bell's question is "booked, passed,
-- unconfirmed", and the rows that matter are the ones with a booked date.
CREATE INDEX cases_booked_idx
  ON cases (organization_id, booked_service_date) WHERE booked_service_date IS NOT NULL;

COMMENT ON COLUMN cases.booked_service_date IS
  'The date the service is booked for. May be in the future (that is its '
  'purpose) or the past (a case recorded after the service). Not tied to '
  'served_on: services slip, and the two differing is what the confirmation '
  'prompt is for. Once it has arrived, and until someone confirms served_on, '
  'the case counts as revenue on this date — see case_revenue_date(). Written '
  'only by set_case_booked_date().';

COMMENT ON COLUMN cases.created_by IS
  'The Hub user who created the case. Filled on insert by '
  'cases_set_created_by; backfilled from change_history''s created rows by '
  '20261119T1510, and null where no such row existed. Read by '
  'case_responsible_users() as the stand-in for the director who arranged the '
  'service, until an assigned-to field replaces it there.';

-- served_on keeps its meaning; what it no longer is, is the whole of revenue
-- or a lock on the case. Every sentence of 2100's comment that said so goes.
COMMENT ON COLUMN cases.served_on IS
  'The date a person confirmed the family was served. Null until someone '
  'does. Never in the future. REVENUE IS NOT THIS COLUMN ALONE: it is '
  'case_revenue_date(), which reads this date when it is set and the booked '
  'date once it has arrived when it is not, and excludes a lost case. A case '
  'can be marked lost after its service; this date is kept when it is, '
  'because the service happened. Changing or removing a recorded date needs a '
  'reason, and notifies the firm''s managers. Written only by '
  'set_case_served().';

COMMENT ON COLUMN cases.status IS
  'The case''s outcome, one of three fixed values: active — the family chose '
  'the firm; lost — they chose it and did not proceed, or did and the firm '
  'lost the revenue afterwards; on_hold. This column is NOT what revenue '
  'reads: case_revenue_date() is, and it excludes lost and nothing else. A '
  'served case CAN be marked lost (20261119T1510 reversed 2100 on this); doing '
  'so needs a reason and notifies the firm''s managers, and keeps served_on. '
  'The firm''s own name for the state is cases.status_item_id. Lost and '
  'on_hold both KEEP everything and both reverse. NEVER set from an undo '
  'control — see delete_case().';

-- -----------------------------------------------------------------------------
-- 2. created_by: backfill, then keep it filled
--
-- Earliest 'created' row per case, by a user. A case with no such row stays
-- null, and the responsibility rule falls through to the managers.
-- -----------------------------------------------------------------------------
UPDATE cases c
   SET created_by = h.actor_user_id
  FROM (SELECT DISTINCT ON (entity_id) entity_id, actor_user_id
          FROM change_history
         WHERE entity = 'case' AND action = 'created'
           AND actor_kind = 'user' AND actor_user_id IS NOT NULL
         ORDER BY entity_id, occurred_at) h
 WHERE h.entity_id = c.id
   AND EXISTS (SELECT 1 FROM users u WHERE u.id = h.actor_user_id);

CREATE FUNCTION cases_set_created_by() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.created_by := COALESCE(NEW.created_by, current_user_id());
  RETURN NEW;
END $$;

COMMENT ON FUNCTION cases_set_created_by() IS
  'Fills cases.created_by with the signed-in Hub user on insert, unless the '
  'insert names one. Null when there is no Hub user (a migration, the owner), '
  'which case_responsible_users() treats as "ask the managers".';

CREATE TRIGGER cases_set_created_by_t BEFORE INSERT ON cases
  FOR EACH ROW EXECUTE FUNCTION cases_set_created_by();

-- -----------------------------------------------------------------------------
-- 3. The three rules, each stated once
-- -----------------------------------------------------------------------------

-- On hold is NOT excluded. The earlier ruling: on hold suppresses the
-- pipeline view but does not retract recognised revenue. Open question to
-- Mandie in the planning note — if she rules otherwise, this is the one place
-- to change.
CREATE FUNCTION case_revenue_date_for(p_status case_status, p_served date, p_booked date)
RETURNS date LANGUAGE sql STABLE AS $$
  SELECT CASE
           WHEN p_status = 'lost'        THEN NULL
           WHEN p_served IS NOT NULL     THEN p_served
           WHEN p_booked <= current_date THEN p_booked
         END
$$;

COMMENT ON FUNCTION case_revenue_date_for(case_status, date, date) IS
  'THE revenue rule, over values: null for a lost case; otherwise the '
  'confirmed served date; otherwise the booked date once it has arrived; '
  'otherwise null. On hold is not excluded. Takes values rather than a case '
  'so a trigger can ask it of the row as it was. Everything else calls this '
  'or case_revenue_date(); nothing restates it.';

CREATE FUNCTION case_revenue_date(p_case uuid)
RETURNS date LANGUAGE sql STABLE AS $$
  SELECT case_revenue_date_for(status, served_on, booked_service_date)
    FROM cases WHERE id = p_case
$$;

COMMENT ON FUNCTION case_revenue_date(uuid) IS
  'The date this case counts as revenue on, or null if it does not count. '
  'Reports count a case in the month this returns. Revenue in a closed month '
  'can move — a case marked lost, a service date changed or removed — and '
  'each such move has a reason on change_history and a case_revenue_moved '
  'notification to the firm''s managers.';

CREATE FUNCTION case_awaiting_confirmation_for(p_status case_status, p_served date, p_booked date)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT p_status IS DISTINCT FROM 'lost'
     AND p_served IS NULL
     AND p_booked IS NOT NULL
     AND p_booked <= current_date
$$;

COMMENT ON FUNCTION case_awaiting_confirmation_for(case_status, date, date) IS
  'THE confirmation rule, over values: not lost, no confirmed served date, '
  'and a booked date that has arrived. Such a case already counts as revenue '
  'on its booked date; this asks a person to confirm, correct, or mark it '
  'lost.';

CREATE FUNCTION case_awaiting_confirmation(p_case uuid)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT case_awaiting_confirmation_for(status, served_on, booked_service_date)
    FROM cases WHERE id = p_case
$$;

COMMENT ON FUNCTION case_awaiting_confirmation(uuid) IS
  'Whether this case''s booked date has passed with nobody confirming the '
  'served date. What the bell asks, through my_cases_awaiting_confirmation().';

-- The one place that says who is responsible. Replacing the creator with an
-- assigned-to field (Mandie, 19 Nov) changes this function and nothing that
-- notifies. "Still at the firm" means an unrevoked scope at the case's firm,
-- not just an active user: a director who left keeps an active login if they
-- work elsewhere on the platform.
CREATE FUNCTION case_responsible_users(p_case uuid)
RETURNS SETOF uuid LANGUAGE plpgsql STABLE AS $$
DECLARE v_org uuid; v_creator uuid;
BEGIN
  SELECT c.organization_id, c.created_by INTO v_org, v_creator
    FROM cases c WHERE c.id = p_case;
  IF v_org IS NULL THEN RETURN; END IF;

  IF v_creator IS NOT NULL AND EXISTS (
       SELECT 1 FROM users u
         JOIN user_scopes s ON s.user_id = u.id
        WHERE u.id = v_creator AND u.active
          AND s.organization_id = v_org AND s.revoked_on IS NULL) THEN
    RETURN NEXT v_creator;
    RETURN;
  END IF;

  RETURN QUERY SELECT r.user_id FROM case_notification_recipients(v_org) r;
END $$;

COMMENT ON FUNCTION case_responsible_users(uuid) IS
  'Who is responsible for a case: its creator, while they are an active user '
  'with a scope at the case''s firm; otherwise the firm''s managers '
  '(case_notification_recipients). The creator stands in for the director '
  'who arranged the service. When an assigned-to field exists it goes here '
  'and nowhere else. INVOKER: reads users and user_scopes as the caller, which '
  'within a firm sees its colleagues (038).';

-- What the bell reads. Derived, not stored: nothing writes a row when a date
-- passes, because nothing runs on a schedule here, and a row written by a job
-- would make "confirm" a button that changes nothing (planning, 19 Nov).
CREATE FUNCTION my_cases_awaiting_confirmation()
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
   ORDER BY c.booked_service_date, c.id
$$;

COMMENT ON FUNCTION my_cases_awaiting_confirmation() IS
  'The signed-in user''s cases whose booked date has passed unconfirmed: case '
  'id, the family''s last name (null when no decedent has one), and the booked '
  'date, oldest first. The bell shows these above its stored notifications. '
  'Empty for a session with no Hub user. INVOKER, so a firm user sees only '
  'their firm''s cases.';

-- -----------------------------------------------------------------------------
-- 4. Setting the booked date
--
-- No reason and no manager. Booking a date is ordinary work; it affects
-- revenue only once it arrives, and then the confirmation prompt appears.
-- -----------------------------------------------------------------------------
CREATE FUNCTION set_case_booked_date(p_case uuid, p_date date)
RETURNS cases LANGUAGE plpgsql AS $$
DECLARE a record; r cases; v_org uuid; v_was date;
BEGIN
  SELECT * INTO a FROM hand_link_actor();

  SELECT organization_id, booked_service_date INTO v_org, v_was
    FROM cases WHERE id = p_case FOR UPDATE;
  IF v_org IS NULL THEN RAISE EXCEPTION 'no such case'; END IF;

  UPDATE cases SET booked_service_date = p_date, updated_at = now()
   WHERE id = p_case
  RETURNING * INTO r;

  IF v_was IS DISTINCT FROM p_date THEN
    PERFORM record_change(
      v_org, 'case', p_case, 'updated', 'user', a.v_name,
      CASE WHEN p_date IS NULL
             THEN format('%s cleared the booked service date (%s)', a.v_name,
                         to_char(v_was, 'FMMonth FMDD, YYYY'))
           WHEN v_was IS NULL
             THEN format('%s booked the service for %s', a.v_name,
                         to_char(p_date, 'FMMonth FMDD, YYYY'))
           ELSE format('%s moved the booked service from %s to %s', a.v_name,
                       to_char(v_was, 'FMMonth FMDD, YYYY'),
                       to_char(p_date, 'FMMonth FMDD, YYYY')) END,
      a.v_user,
      jsonb_build_object('field', 'booked_service_date', 'from', v_was, 'to', p_date));
  END IF;

  RETURN r;
END $$;

COMMENT ON FUNCTION set_case_booked_date(uuid, date) IS
  'Sets or clears the date a service is booked for — the only writer of '
  'cases.booked_service_date. Any date, past or future; no reason and no '
  'manager. Records a history row when the date changes. Once the date '
  'arrives the case counts as revenue on it until someone confirms '
  'served_on.';

-- -----------------------------------------------------------------------------
-- 5. set_case_served, replaced
--
-- Same signature, so CREATE OR REPLACE keeps its grants. What changed:
--   * removing a date no longer needs a manager; it still needs a reason;
--   * changing a recorded date to another one now needs a reason too;
--   * the first date recorded — the confirmation — needs neither;
--   * the reason is handed to the notification trigger (hub.case_change_reason).
-- The future-date refusal stays, and its hint now points at the booked date.
--
-- NOTE what removing a date means now: if the booked date has passed, the
-- case falls back to counting on it. Removing a served date un-confirms; it
-- does not by itself take a case out of revenue. Marking lost does that.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_case_served(
  p_case uuid,
  p_served_on date DEFAULT current_date,
  -- Required to CHANGE or REMOVE a recorded date. Recording the first one —
  -- confirming — needs none.
  p_reason text DEFAULT NULL)
RETURNS cases LANGUAGE plpgsql AS $$
DECLARE a record; r cases; v_org uuid; v_was date; v_reason text;
BEGIN
  SELECT * INTO a FROM hand_link_actor();

  SELECT organization_id, served_on INTO v_org, v_was
    FROM cases WHERE id = p_case FOR UPDATE;
  IF v_org IS NULL THEN RAISE EXCEPTION 'no such case'; END IF;

  IF p_served_on > current_date THEN
    RAISE EXCEPTION 'a service date can''t be in the future'
      USING HINT = 'This is the date the service took place. For a service that hasn''t happened yet, set the booked date instead.';
  END IF;

  v_reason := NULLIF(btrim(COALESCE(p_reason, '')), '');

  -- Changing or removing a recorded date can move revenue between months, so
  -- it needs a reason. Nobody needs to be a manager: the managers are told.
  IF v_was IS NOT NULL AND p_served_on IS DISTINCT FROM v_was AND v_reason IS NULL THEN
    RAISE EXCEPTION '%',
      CASE WHEN p_served_on IS NULL THEN 'removing a service date needs a reason'
           ELSE 'changing a service date needs a reason' END
      USING ERRCODE = 'RV001',
            HINT = 'Say why — for example, recorded on the wrong case. It goes on the case''s history and to your managers.';
  END IF;

  PERFORM set_config('hub.case_change_reason', COALESCE(v_reason, ''), true);

  UPDATE cases SET served_on = p_served_on, updated_at = now()
   WHERE id = p_case
  RETURNING * INTO r;

  IF v_was IS DISTINCT FROM p_served_on THEN
    PERFORM record_change(
      v_org, 'case', p_case, 'updated', 'user', a.v_name,
      CASE WHEN p_served_on IS NULL
             THEN format('%s removed the service date (%s): %s', a.v_name,
                         to_char(v_was, 'FMMonth FMDD, YYYY'), v_reason)
           WHEN v_was IS NULL
             THEN format('%s recorded the family as served on %s',
                         a.v_name, to_char(p_served_on, 'FMMonth FMDD, YYYY'))
           ELSE format('%s changed the service date from %s to %s: %s', a.v_name,
                       to_char(v_was, 'FMMonth FMDD, YYYY'),
                       to_char(p_served_on, 'FMMonth FMDD, YYYY'), v_reason) END,
      a.v_user,
      jsonb_build_object('field', 'served_on', 'from', v_was, 'to', p_served_on,
                         'reason', v_reason));
  END IF;

  RETURN r;
END $$;

COMMENT ON FUNCTION set_case_served(uuid, date, text) IS
  'Records the date a person confirmed the family was served — the only '
  'writer of cases.served_on. Recording the first date needs no reason. '
  'CHANGING or REMOVING a recorded date needs a non-blank reason (RV001 '
  'without one), written into the history row and into the '
  'case_revenue_moved notification each manager receives; it does NOT need a '
  'manager (20261119T1510 removed that gate). Removing a date un-confirms: a '
  'case whose booked date has passed counts on that date again. Refuses a '
  'future date.';

-- -----------------------------------------------------------------------------
-- 6. set_case_status and set_case_lost, with a reason
--
-- The signature gains p_reason, so these are DROPPED and created rather than
-- replaced — CREATE OR REPLACE with a new argument list would leave the old
-- two-argument function beside the new one, and a call with two arguments
-- would then be ambiguous. Grants and comments go with the drop and are
-- restated below.
--
-- delete_case()'s refusal names set_case_lost, and the app calls it with
-- named arguments (p_case, p_lost), which still resolve: p_reason defaults.
-- -----------------------------------------------------------------------------
DROP FUNCTION set_case_lost(uuid, boolean);
DROP FUNCTION set_case_status(uuid, uuid);

CREATE FUNCTION set_case_status(p_case uuid, p_status uuid, p_reason text DEFAULT NULL)
RETURNS cases LANGUAGE plpgsql AS $$
DECLARE
  a record; r cases;
  v_org uuid; v_was case_status; v_was_item uuid; v_was_label text;
  v_outcome case_status; v_label text; v_served date; v_booked date;
  v_reason text; v_revenue date;
BEGIN
  SELECT * INTO a FROM hand_link_actor();

  SELECT organization_id, status, status_item_id, served_on, booked_service_date
    INTO v_org, v_was, v_was_item, v_served, v_booked
    FROM cases WHERE id = p_case FOR UPDATE;
  IF v_org IS NULL THEN RAISE EXCEPTION 'no such case'; END IF;

  SELECT i.case_outcome, i.label INTO v_outcome, v_label
    FROM picklist_items i
   WHERE i.id = p_status
     AND i.picklist = 'case_status'
     AND i.organization_id = v_org;

  IF v_outcome IS NULL THEN
    RAISE EXCEPTION 'that status doesn''t belong to this firm'
      USING HINT = 'Case statuses are each firm''s own — choose one from this firm''s list.';
  END IF;

  v_reason := NULLIF(btrim(COALESCE(p_reason, '')), '');

  -- A case that counts as revenue can be lost — the family disputed, the
  -- firm comped the service — but it takes money out of a month that may be
  -- closed, so it needs a reason, and the managers are told. Losing a case
  -- that was never revenue needs neither.
  v_revenue := case_revenue_date_for(v_was, v_served, v_booked);
  IF v_outcome = 'lost' AND v_was IS DISTINCT FROM 'lost'
     AND v_revenue IS NOT NULL AND v_reason IS NULL THEN
    RAISE EXCEPTION 'this case counts as revenue on %, so marking it lost needs a reason',
      to_char(v_revenue, 'FMMonth FMDD, YYYY')
      USING ERRCODE = 'RV001',
            HINT = 'Say why — for example, the family disputed the bill and the services were comped. It goes on the case''s history and to your managers.';
  END IF;

  PERFORM set_config('hub.case_change_reason', COALESCE(v_reason, ''), true);

  SELECT label INTO v_was_label FROM picklist_items WHERE id = v_was_item;

  UPDATE cases
     SET status = v_outcome, status_item_id = p_status, updated_at = now()
   WHERE id = p_case
  RETURNING * INTO r;

  IF v_was_item IS DISTINCT FROM p_status OR v_was IS DISTINCT FROM v_outcome THEN
    PERFORM record_change(
      v_org, 'case', p_case, 'updated', 'user', a.v_name,
      format('%s set the case to %s', a.v_name, v_label)
        || COALESCE(': ' || v_reason, ''),
      a.v_user,
      jsonb_build_object('field', 'status',
                         'from', v_was, 'to', v_outcome,
                         'from_label', v_was_label, 'to_label', v_label,
                         'status_item_id', p_status,
                         'reason', v_reason));
  END IF;

  RETURN r;
END $$;

COMMENT ON FUNCTION set_case_status(uuid, uuid, text) IS
  'Sets a case to one of its firm''s named statuses, and its outcome from '
  'that status. The only writer of cases.status and cases.status_item_id, so '
  'the two cannot disagree. Refuses a status belonging to another firm; '
  'accepts a hidden one. Moving a case that counts as revenue '
  '(case_revenue_date) to lost needs a reason (RV001 without one) and '
  'notifies the firm''s managers; served_on is kept. Since 20261119T1510 a '
  'served case CAN be lost — 2100 refused it. NOT an undo — see delete_case().';

CREATE FUNCTION set_case_lost(p_case uuid, p_lost boolean DEFAULT true, p_reason text DEFAULT NULL)
RETURNS cases LANGUAGE plpgsql AS $$
DECLARE v_org uuid; v_item uuid; v_outcome case_status;
BEGIN
  SELECT organization_id INTO v_org FROM cases WHERE id = p_case;
  IF v_org IS NULL THEN RAISE EXCEPTION 'no such case'; END IF;

  v_outcome := CASE WHEN p_lost THEN 'lost' ELSE 'active' END::case_status;
  v_item := case_status_default(v_org, v_outcome);

  IF v_item IS NULL THEN
    RAISE EXCEPTION 'this firm has no % status to set', v_outcome
      USING HINT = 'Add one in Settings — every firm is seeded with Won, On hold and Lost.';
  END IF;

  RETURN set_case_status(p_case, v_item, p_reason);
END $$;

COMMENT ON FUNCTION set_case_lost(uuid, boolean, text) IS
  'The family converted and didn''t proceed, or did and the firm lost the '
  'revenue afterwards. A thin wrapper over set_case_status() that picks the '
  'firm''s lost status, or its active one when reinstating, and passes the '
  'reason through — required when the case counts as revenue. Kept under its '
  'own name because delete_case()''s refusal names it and the app calls it. '
  'Keeps everything and reverses. NOT an undo.';

-- -----------------------------------------------------------------------------
-- 7. The managers are told when money moves
--
-- Fires on the row, so every door is covered, including a direct UPDATE that
-- went round the functions. Two kinds of move, one event:
--   * a case that counted as revenue (judged on OLD) becomes lost;
--   * a recorded served_on is changed or removed.
-- Not notified, by design or by omission — named so a reviewer can rule:
--   * reinstating a lost case (money coming back);
--   * changing a booked date that has already passed, which moves revenue
--     between months the same way changing a served date does. The planning
--     note made the booked date ungated; this follows it.
--
-- To the firm's managers (case_notification_recipients), not to the person
-- responsible for the case — the first notification whose audience is the
-- firm rather than the case. Not to whoever made the change.
--
-- NOT GATED BY notification_preferences, unlike case_converted. Visibility is
-- the control that replaced the manager gate; an opt-in control is one that is
-- off for everyone until they find a setting (an absent preference row means
-- off). Reviewer to confirm.
--
-- NO warn-and-continue handler, unlike case_converted_notify (20261102T1600).
-- That one is a courtesy and must not veto a conversion. This one IS the
-- control: if it cannot notify, the change it reports should not go through
-- unreported. Reviewer to confirm — the cost is that a fault here stops a
-- director recording a loss.
--
-- SECURITY DEFINER because nobody else can insert into notifications. The
-- body is composed from the case's own rows, the actor's name and the reason;
-- the reason is the only caller-chosen text, and it is the text the caller
-- was asked for.
-- -----------------------------------------------------------------------------
CREATE FUNCTION case_revenue_moved_notify() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_lost boolean; v_date_moved boolean;
  v_was_revenue date; v_family text; v_actor_id uuid; v_actor text;
  v_reason text; v_case_words text; v_what text; v_body text;
BEGIN
  v_was_revenue := case_revenue_date_for(OLD.status, OLD.served_on, OLD.booked_service_date);
  v_lost := NEW.status = 'lost' AND OLD.status IS DISTINCT FROM 'lost'
            AND v_was_revenue IS NOT NULL;
  v_date_moved := OLD.served_on IS NOT NULL
                  AND NEW.served_on IS DISTINCT FROM OLD.served_on;

  IF NOT (v_lost OR v_date_moved) THEN RETURN NULL; END IF;

  SELECT d.last_name INTO v_family
    FROM case_decedents cd JOIN decedents d ON d.id = cd.decedent_id
   WHERE cd.case_id = NEW.id AND d.last_name IS NOT NULL
   ORDER BY d.last_name LIMIT 1;

  v_actor_id := current_user_id();
  SELECT full_name INTO v_actor FROM users WHERE id = v_actor_id;
  v_reason := NULLIF(current_setting('hub.case_change_reason', true), '');

  -- "the Ellis family's case", or "a case with no family name" when no
  -- decedent has a last name yet.
  v_case_words := COALESCE('the ' || v_family || ' family''s case', 'a case with no family name');

  v_what := CASE
    WHEN v_lost THEN format('marked %s lost after it had counted as revenue on %s',
                            v_case_words, to_char(v_was_revenue, 'FMMon FMDD, YYYY'))
    WHEN NEW.served_on IS NULL THEN format('removed the service date (%s) from %s',
                            to_char(OLD.served_on, 'FMMon FMDD, YYYY'), v_case_words)
    ELSE format('changed the service date on %s from %s to %s', v_case_words,
                to_char(OLD.served_on, 'FMMon FMDD, YYYY'),
                to_char(NEW.served_on, 'FMMon FMDD, YYYY'))
  END;

  v_body := COALESCE(v_actor, 'Someone') || ' ' || v_what
            || COALESCE(': ' || v_reason, ' — no reason recorded');

  INSERT INTO notifications
    (organization_id, user_id, event, subject_entity, subject_id, body)
  SELECT NEW.organization_id, r.user_id,
         'case_revenue_moved'::notification_event,
         'case'::history_entity,
         NEW.id, v_body
    FROM case_notification_recipients(NEW.organization_id) r
   WHERE r.user_id IS DISTINCT FROM v_actor_id;

  RETURN NULL;
END $$;

COMMENT ON FUNCTION case_revenue_moved_notify() IS
  'Tells a firm''s managers when money moves on a case that has counted as '
  'revenue: a case marked lost after counting, or a recorded service date '
  'changed or removed. One case_revenue_moved notification per manager, not '
  'to the person who made the change, with the reason in the body (or "no '
  'reason recorded" for a change that went round the functions). Fires on '
  'the row, so a direct UPDATE is reported too. Not gated by preferences, and '
  'does not warn-and-continue: this notification is the control that replaced '
  'the manager gate. SECURITY DEFINER because only the Hub inserts '
  'notifications; a trigger, so there is no grantable entry point to it.';

CREATE TRIGGER cases_revenue_moved_t
  AFTER UPDATE OF status, served_on ON cases
  FOR EACH ROW EXECUTE FUNCTION case_revenue_moved_notify();

-- -----------------------------------------------------------------------------
-- 8. Grants: the explicit pair on every callable function, nothing on the
--    trigger functions
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION case_revenue_date_for(case_status, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION case_revenue_date_for(case_status, date, date) TO authenticated;
REVOKE ALL ON FUNCTION case_revenue_date(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION case_revenue_date(uuid) TO authenticated;
REVOKE ALL ON FUNCTION case_awaiting_confirmation_for(case_status, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION case_awaiting_confirmation_for(case_status, date, date) TO authenticated;
REVOKE ALL ON FUNCTION case_awaiting_confirmation(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION case_awaiting_confirmation(uuid) TO authenticated;
REVOKE ALL ON FUNCTION case_responsible_users(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION case_responsible_users(uuid) TO authenticated;
REVOKE ALL ON FUNCTION my_cases_awaiting_confirmation() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION my_cases_awaiting_confirmation() TO authenticated;
REVOKE ALL ON FUNCTION set_case_booked_date(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION set_case_booked_date(uuid, date) TO authenticated;
REVOKE ALL ON FUNCTION set_case_served(uuid, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION set_case_served(uuid, date, text) TO authenticated;
REVOKE ALL ON FUNCTION set_case_status(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION set_case_status(uuid, uuid, text) TO authenticated;
REVOKE ALL ON FUNCTION set_case_lost(uuid, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION set_case_lost(uuid, boolean, text) TO authenticated;

-- Trigger functions need no EXECUTE to fire. Revoked from everyone so neither
-- is callable as a function — case_revenue_moved_notify above all, which is
-- SECURITY DEFINER and inserts notifications.
REVOKE ALL ON FUNCTION cases_set_created_by() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION case_revenue_moved_notify() FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 9. And they are the bodies that were reviewed
--
-- In the same transaction, so a mismatch rolls everything back rather than
-- leaving something nobody has read installed (the 20261102T1600 pattern).
-- The hashes were taken from a scratch database built from every migration on
-- main, in order, with this file applied.
-- -----------------------------------------------------------------------------
DO $$
DECLARE bad text;
BEGIN
  SELECT string_agg(e.sig || ' is ' || COALESCE(md5(p.prosrc), 'MISSING'), '; ')
    INTO bad
    FROM (VALUES
    ('set_case_served(uuid,date,text)', '1511ff4bc7599c9bd53b3536b804ff3a'),
    ('cases_set_created_by()', '8f293d32fd2b62aa31bf8608c6b5c68e'),
    ('case_revenue_date_for(case_status,date,date)', 'f5e6ffad9e68bf7fc259e9779ed60168'),
    ('case_revenue_date(uuid)', '54e85d7ed7f6ead928636461da927086'),
    ('case_awaiting_confirmation_for(case_status,date,date)', '50fce56072199434dc99748c818d3f9b'),
    ('case_awaiting_confirmation(uuid)', '9e477169ce058370a9022a37be9e9215'),
    ('case_responsible_users(uuid)', '49fe944846e63306fd926e9776b50bc3'),
    ('my_cases_awaiting_confirmation()', '2c6ca6d8a9b2a7e5df786116114826b2'),
    ('set_case_booked_date(uuid,date)', '069c52153b8eff7cef7735dd4ddb5f0e'),
    ('set_case_status(uuid,uuid,text)', 'dab3688e7582e6a306d35a7faeb96b04'),
    ('set_case_lost(uuid,boolean,text)', 'f2d2191da56c84bd09cfdb6898731910'),
    ('case_revenue_moved_notify()', 'f053c3a5e9efb481d61e8c2508022170')
         ) AS e(sig, want)
    LEFT JOIN pg_proc p ON p.oid = to_regprocedure(e.sig)
   WHERE md5(p.prosrc) IS DISTINCT FROM e.want;
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'not the reviewed bodies: %. Nothing has been kept.', bad;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 10. The ledger
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261119T1510_booked_and_served_dates.sql',
    NULL,
    'cases.booked_service_date and created_by (backfilled from change_history). '
    'Revenue is case_revenue_date(): confirmed served_on, else the booked date '
    'once arrived, never a lost case. A served case can be lost; doing so, and '
    'changing or removing a service date, needs a reason and notifies managers '
    '(case_revenue_moved) instead of needing a manager. set_case_status and '
    'set_case_lost gain p_reason. my_cases_awaiting_confirmation() feeds the bell.');
END $rec$;

COMMIT;

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
-- Run after the migration. Its output comes back as the error text, which is
-- the only way the SQL editor shows it.
--
-- It builds its own fixture: three users at the first firm that has a lost
-- status (a director, a manager and a colleague, entered through
-- request.jwt.claims as the app does), five cases, and one decedent. Every
-- notification query names the event: linking a decedent fires
-- case_converted too, and an earlier draft of this block counted that as a
-- revenue notification.
--
-- The planning session's eight checks are numbered 1-8; the unnumbered lines
-- are added positive halves and the things the design named as unchanged.
-- Line 6 compares counts BEFORE the fixture exists, and says when both are
-- zero, because then it proves nothing.
--
-- RUN ON A SCRATCH REBUILD, 19 Nov — every migration on main applied in order
-- to a local PostgreSQL 16, with three local adjustments that do not touch
-- this file: 058's drift check reported (057 on main is not the body 058
-- expected, which is older history), 20261103T1700's expected default set
-- without MAINTAIN (PostgreSQL 16 has no such privilege), and
-- 20261103T2100 skipped (it refuses on a database that has 014, by design).
-- Every line matched its expectation, except 6, which was 0 = 0 there; the
-- backfill was then proved separately on the same rebuild — a case with a
-- 'created' row got its creator, one without stayed null. NOT YET RUN ON
-- STAGING. Record its output here when it has been.
--
-- DO $$
-- DECLARE
--   r text := ''; n int; v date; t date := current_date;
--   v_org uuid; v_dir uuid; v_mgr uuid; v_oth uuid;
--   a_dir uuid := gen_random_uuid(); a_mgr uuid := gen_random_uuid(); a_oth uuid := gen_random_uuid();
--   c_future uuid; c_past uuid; c_served uuid; c_served2 uuid; c_unserved uuid; c_new uuid;
--   v_dec uuid; n_hist int; n_set int; n_mgr int;
-- BEGIN
--   PERFORM set_config('app.is_internal', 'on', true);
--
--   -- 6. created_by backfill, counted before any fixture exists.
--   SELECT count(DISTINCT h.entity_id) INTO n_hist
--     FROM change_history h JOIN cases c ON c.id = h.entity_id
--    WHERE h.entity = 'case' AND h.action = 'created' AND h.actor_kind = 'user'
--      AND EXISTS (SELECT 1 FROM users u WHERE u.id = h.actor_user_id);
--   SELECT count(*) INTO n_set FROM cases WHERE created_by IS NOT NULL;
--   r := r || '6. cases with a created history row: ' || n_hist
--          || ', cases with created_by: ' || n_set || '   (expect equal'
--          || CASE WHEN n_hist = 0 THEN '. BOTH ZERO — this database has no history rows, so this line proves nothing here' ELSE '' END
--          || ')' || chr(10);
--
--   SELECT id INTO v_org FROM organizations
--    WHERE EXISTS (SELECT 1 FROM picklist_items i WHERE i.organization_id = organizations.id
--                     AND i.picklist = 'case_status' AND i.case_outcome = 'lost')
--    ORDER BY created_at LIMIT 1;
--   IF v_org IS NULL THEN RAISE EXCEPTION 'no organization with a lost status — cannot build the fixture'; END IF;
--
--   -- Three users: the director who creates cases, a manager, and a colleague.
--   -- app.is_internal must be on to create a user with an auth_user_id.
--   INSERT INTO users (email, full_name, auth_user_id, active_organization_id)
--   VALUES ('zzz-dir@example.invalid', 'ZZZ Director', a_dir, v_org) RETURNING id INTO v_dir;
--   INSERT INTO users (email, full_name, auth_user_id, active_organization_id)
--   VALUES ('zzz-mgr@example.invalid', 'ZZZ Manager', a_mgr, v_org) RETURNING id INTO v_mgr;
--   INSERT INTO users (email, full_name, auth_user_id, active_organization_id)
--   VALUES ('zzz-oth@example.invalid', 'ZZZ Colleague', a_oth, v_org) RETURNING id INTO v_oth;
--   INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id) VALUES
--     (v_dir, 'organization', 'professional', v_org),
--     (v_mgr, 'organization', 'manager',      v_org),
--     (v_oth, 'organization', 'professional', v_org);
--
--   INSERT INTO decedents (organization_id, first_name, last_name)
--   VALUES (v_org, 'ZZZ', 'Zverify') RETURNING id INTO v_dec;
--
--   -- need_type is NOT NULL with no default. created_by named, because the
--   -- owner has no Hub user for the trigger to find.
--   INSERT INTO cases (organization_id, need_type, created_by, booked_service_date)
--   VALUES (v_org, 'at_need', v_dir, t + 10) RETURNING id INTO c_future;
--   INSERT INTO cases (organization_id, need_type, created_by, booked_service_date)
--   VALUES (v_org, 'at_need', v_dir, t - 3) RETURNING id INTO c_past;
--   INSERT INTO case_decedents (case_id, decedent_id) VALUES (c_past, v_dec);
--   INSERT INTO cases (organization_id, need_type, created_by, booked_service_date, served_on)
--   VALUES (v_org, 'at_need', v_dir, t - 6, t - 5) RETURNING id INTO c_served;
--   INSERT INTO case_decedents (case_id, decedent_id) VALUES (c_served, v_dec);
--   INSERT INTO cases (organization_id, need_type, created_by, served_on)
--   VALUES (v_org, 'at_need', v_dir, t - 5) RETURNING id INTO c_served2;
--   INSERT INTO cases (organization_id, need_type, created_by)
--   VALUES (v_org, 'at_need', v_dir) RETURNING id INTO c_unserved;
--   UPDATE cases SET status_item_id = case_status_default(v_org, 'active')
--    WHERE id IN (c_future, c_past, c_served, c_served2, c_unserved);
--
--   -- ---- the rules, as the owner -------------------------------------------
--   r := r || '1. future booked, unserved — revenue date: '
--          || COALESCE(case_revenue_date(c_future)::text, 'null') || '   (expect null: pipeline, not revenue)' || chr(10);
--
--   UPDATE cases SET booked_service_date = t - 1 WHERE id = c_future;
--   r := r || '2. booked moved to yesterday — revenue date: '
--          || COALESCE(case_revenue_date(c_future)::text, 'null') || '   (expect ' || (t - 1) || ')'
--          || ', served_on still: ' || COALESCE((SELECT served_on::text FROM cases WHERE id = c_future), 'null')
--          || '   (expect null: nothing was written to make it count)' || chr(10);
--
--   r := r || '3. confirmed served differs from booked — revenue date: '
--          || case_revenue_date(c_served) || '   (expect ' || (t - 5) || ', the served date, not ' || (t - 6) || ')' || chr(10);
--
--   r := r || '5. awaiting confirmation at today+1: ' || case_awaiting_confirmation_for('active', NULL, t + 1)
--          || ', at today-1: ' || case_awaiting_confirmation_for('active', NULL, t - 1)
--          || '   (expect false, true)' || chr(10);
--   r := r || '   on hold, served — revenue date: ' || COALESCE(case_revenue_date_for('on_hold', t - 5, NULL)::text, 'null')
--          || '   (expect ' || (t - 5) || ' — on hold does not retract revenue; open question to Mandie)' || chr(10);
--
--   r := r || '   trigger functions callable by authenticated: '
--          || has_function_privilege('authenticated', 'case_revenue_moved_notify()', 'EXECUTE') || ', '
--          || has_function_privilege('authenticated', 'cases_set_created_by()', 'EXECUTE')
--          || '   (expect false, false)' || chr(10);
--   r := r || '   old two-argument set_case_status still exists: '
--          || (to_regprocedure('set_case_status(uuid,uuid)') IS NOT NULL) || '   (expect false — it would make calls ambiguous)' || chr(10);
--
--   -- A direct UPDATE that went round the functions still reaches the managers.
--   SELECT count(*) INTO n FROM notifications WHERE user_id = v_mgr AND event = 'case_revenue_moved';
--   UPDATE cases SET served_on = t - 4 WHERE id = c_served2;
--   r := r || '   direct UPDATE changing a served date — manager notified: '
--          || ((SELECT count(*) FROM notifications WHERE user_id = v_mgr AND event = 'case_revenue_moved') - n)
--          || ', body: ' || COALESCE((SELECT body FROM notifications WHERE user_id = v_mgr AND event = 'case_revenue_moved' AND subject_id = c_served2 LIMIT 1), 'NONE')
--          || '   (expect 1, ending "no reason recorded")' || chr(10);
--
--   -- ---- as the director: an ordinary, non-manager user ---------------------
--   PERFORM set_config('app.is_internal', 'off', true);
--   PERFORM set_config('request.jwt.claims', json_build_object('sub', a_dir::text)::text, true);
--   PERFORM set_config('role', 'authenticated', true);
--
--   SELECT count(*) INTO n FROM cases WHERE id IN (c_future, c_past, c_served, c_served2, c_unserved);
--   r := r || chr(10) || 'as the director — fixture cases visible: ' || n
--          || '   (expect 5. If 0, everything below proves nothing)' || chr(10);
--   r := r || '   can_manage_settings(): ' || can_manage_settings() || '   (expect false — a non-manager)' || chr(10);
--
--   r := r || '   bell: ' || COALESCE((SELECT string_agg(COALESCE(family_name, '?') || ' ' || booked_service_date, ', ')
--                                        FROM my_cases_awaiting_confirmation()
--                                       WHERE case_id IN (c_future, c_past)), 'nothing')
--          || '   (expect Zverify ' || (t - 3) || ' and ? ' || (t - 1) || ', oldest first)' || chr(10);
--
--   -- 7. A served case, lost, by a non-manager: refused without a reason ...
--   BEGIN
--     PERFORM set_case_lost(c_served, true);
--     r := r || '7. served case lost WITHOUT a reason: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || '7. served case lost without a reason refused: ' || SQLERRM || ' [' || SQLSTATE || ']'
--            || CASE WHEN SQLSTATE = 'RV001' AND SQLERRM LIKE '%needs a reason%' THEN '   (right reason)'
--                    ELSE '   (WRONG REASON — this line proves nothing)' END || chr(10);
--   END;
--
--   -- ... and allowed with one, notifying the manager and not the director.
--   BEGIN
--     PERFORM set_case_lost(c_served, true, 'ZZZ family disputed, services comped');
--     r := r || '   with a reason: allowed' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || '   with a reason: REFUSED (BAD): ' || SQLERRM || chr(10);
--   END;
--
--   PERFORM set_config('role', 'postgres', true);
--   SELECT count(*) INTO n_mgr FROM notifications
--    WHERE user_id = v_mgr AND subject_id = c_served AND event = 'case_revenue_moved';
--   r := r || '   manager notifications about it: ' || n_mgr || '   (expect 1)' || chr(10)
--          || '   body: ' || COALESCE((SELECT body FROM notifications WHERE user_id = v_mgr AND subject_id = c_served AND event = 'case_revenue_moved' LIMIT 1), 'NONE') || chr(10)
--          || '   (expect the director, "Zverify family''s case lost", the date it counted on, and the reason)' || chr(10);
--   r := r || '   director notified of their own change: '
--          || (SELECT count(*) FROM notifications WHERE user_id = v_dir AND event = 'case_revenue_moved') || '   (expect 0)' || chr(10);
--
--   -- 4. Lost keeps the service date and takes the case out of revenue.
--   r := r || '4. lost served case — revenue date: ' || COALESCE(case_revenue_date(c_served)::text, 'null')
--          || ', served_on: ' || COALESCE((SELECT served_on::text FROM cases WHERE id = c_served), 'null (BAD — the date was erased)')
--          || '   (expect null, ' || (t - 5) || ')' || chr(10);
--   r := r || '   history row carries the reason: '
--          || COALESCE((SELECT summary FROM change_history WHERE entity = 'case' AND entity_id = c_served
--                        AND detail->>'field' = 'status' ORDER BY occurred_at DESC LIMIT 1), 'NO ROW') || chr(10);
--
--   PERFORM set_config('role', 'authenticated', true);
--
--   -- 8. Removing a service date as a non-manager: refused without a reason ...
--   BEGIN
--     PERFORM set_case_served(c_served2, NULL);
--     r := r || '8. removing a service date WITHOUT a reason: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || '8. removing without a reason refused: ' || SQLERRM || ' [' || SQLSTATE || ']'
--            || CASE WHEN SQLSTATE = 'RV001' AND SQLERRM LIKE '%needs a reason%' THEN '   (right reason)'
--                    WHEN SQLERRM LIKE '%manager%' THEN '   (WRONG REASON — the old manager gate is still there)'
--                    ELSE '   (WRONG REASON)' END || chr(10);
--   END;
--   -- ... and allowed with one. The old manager refusal must be gone.
--   BEGIN
--     PERFORM set_case_served(c_served2, NULL, 'ZZZ recorded on the wrong case');
--     r := r || '   with a reason, as a non-manager: allowed' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || '   with a reason, as a non-manager: REFUSED (BAD): ' || SQLERRM || chr(10);
--   END;
--   PERFORM set_config('role', 'postgres', true);
--   r := r || '   manager notifications about it now: '
--          || (SELECT count(*) FROM notifications WHERE user_id = v_mgr AND subject_id = c_served2 AND event = 'case_revenue_moved')
--          || '   (expect 2 — the direct UPDATE above, and this)' || chr(10);
--   PERFORM set_config('role', 'authenticated', true);
--
--   -- Not revenue, so no reason and no notification.
--   BEGIN
--     PERFORM set_case_lost(c_unserved, true);
--     r := r || '   unserved case lost without a reason: allowed' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || '   unserved case lost without a reason: REFUSED (BAD): ' || SQLERRM || chr(10);
--   END;
--   -- Confirming — the first served date — needs no reason and tells nobody.
--   BEGIN
--     PERFORM set_case_served(c_past, t - 3);
--     r := r || '   confirming a booked case''s served date without a reason: allowed' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || '   confirming without a reason: REFUSED (BAD): ' || SQLERRM || chr(10);
--   END;
--   BEGIN
--     PERFORM set_case_served(c_future, t + 1);
--     r := r || '   a FUTURE served date: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || '   a future served date refused: ' || SQLERRM
--            || CASE WHEN SQLERRM LIKE '%future%' THEN '   (right reason)' ELSE '   (WRONG REASON)' END || chr(10);
--   END;
--   BEGIN
--     PERFORM set_case_booked_date(c_future, t + 30);
--     r := r || '   a FUTURE booked date, as a non-manager: allowed' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || '   a future booked date: REFUSED (BAD): ' || SQLERRM || chr(10);
--   END;
--   PERFORM set_config('role', 'postgres', true);
--   r := r || '   notifications for the unserved loss, the confirmation and the booking: '
--          || (SELECT count(*) FROM notifications WHERE subject_id IN (c_unserved, c_past, c_future) AND event = 'case_revenue_moved')
--          || '   (expect 0)' || chr(10);
--   PERFORM set_config('role', 'authenticated', true);
--
--   -- A case the director creates names them.
--   BEGIN
--     INSERT INTO cases (organization_id, need_type) VALUES (v_org, 'pre_need') RETURNING id INTO c_new;
--     PERFORM set_config('role', 'postgres', true);
--     r := r || '   a case inserted as the director has created_by = director: '
--            || ((SELECT created_by FROM cases WHERE id = c_new) = v_dir) || '   (expect true)' || chr(10);
--     PERFORM set_config('role', 'authenticated', true);
--   EXCEPTION WHEN others THEN
--     r := r || '   inserting a case as the director failed (' || SQLERRM || ') — created_by on insert NOT TESTED' || chr(10);
--   END;
--
--   -- ---- who the bell asks ---------------------------------------------------
--   -- c_future is booked ahead again; put it back to yesterday for this part.
--   PERFORM set_config('role', 'postgres', true);
--   UPDATE cases SET booked_service_date = t - 1 WHERE id = c_future;
--
--   PERFORM set_config('request.jwt.claims', json_build_object('sub', a_oth::text)::text, true);
--   PERFORM set_config('role', 'authenticated', true);
--   r := r || chr(10) || 'as a colleague who did not create it — bell: '
--          || (SELECT count(*) FROM my_cases_awaiting_confirmation() WHERE case_id = c_future) || '   (expect 0)' || chr(10);
--
--   PERFORM set_config('request.jwt.claims', json_build_object('sub', a_mgr::text)::text, true);
--   r := r || 'as the manager, while the director is at the firm — bell: '
--          || (SELECT count(*) FROM my_cases_awaiting_confirmation() WHERE case_id = c_future) || '   (expect 0)' || chr(10);
--
--   PERFORM set_config('role', 'postgres', true);
--   UPDATE user_scopes SET revoked_on = current_date WHERE user_id = v_dir;
--   PERFORM set_config('role', 'authenticated', true);
--   r := r || 'as the manager, after the director''s scope is revoked — bell: '
--          || (SELECT count(*) FROM my_cases_awaiting_confirmation() WHERE case_id = c_future) || '   (expect 1 — the backstop)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261119T1510_booked_and_served_dates (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
