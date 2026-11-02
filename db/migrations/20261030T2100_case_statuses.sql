-- =============================================================================
-- 20261030T2100_case_statuses.sql
-- The Hub — three fixed outcomes, and the names a firm gives them.
--
-- THE RULING THIS IMPLEMENTS (30 Oct 2026), written here because the decedent
-- name rule lived in a chat for three weeks and nobody could find it.
--
-- * Three fixed outcomes: active, lost, on_hold. "Won" is not one of them:
--   active means the family chose the firm, and that is what winning is.
--   Code, reports and notifications read the outcome and nothing else.
-- * Being served is a FACT WITH A DATE, not a state. cases.served_on carries
--   it. A booked case and a served case are both active; they differ only in
--   whether that date is set.
-- * REVENUE IS served_on IS NOT NULL, counted by that date. Not "active and
--   served": a served case can no longer be marked lost, so the only state
--   change left that could move it is on_hold, and letting that drop a case
--   out of a past month would be the restatement the ruling forbids. The
--   outcome governs the pipeline; the date governs revenue. They are
--   separate questions and the rule says so.
-- * Served revenue is final, with one door: a manager may remove a date,
--   with a reason, recorded. That is the only change that takes revenue out
--   of a past month, and it leaves a name and a sentence behind.
-- * On top of them, each firm keeps its own named statuses, each mapped to
--   exactly one outcome. A firm may rename, add, hide and reorder; it may
--   never invent an outcome.
-- * Every firm starts with one status per outcome, so the feature works
--   before anyone opens Settings. Won / On hold / Lost, renameable.
-- * Hiding a status leaves the cases already on it alone. It simply stops
--   being offered — the way a hidden call type behaves.
--
-- WHERE THIS DEPARTS FROM 018, AND WHY. 018's rule is that a Dead Ringers
-- default may be hidden or extended but never renamed or deleted, and its
-- trigger refuses a rename at the database. Its reason is reporting: a default
-- means the same thing at every firm, so it can carry a benchmark, and a
-- renamed one quietly cannot.
--
-- That reason does not reach this list, because every case status carries an
-- outcome and every reader reads the outcome. A firm calling lost "Went
-- elsewhere" breaks no comparison. So the three seeded statuses are the FIRM'S
-- OWN rows (organization_id set, is_default false), not Dead Ringers defaults —
-- which means 018's protection never applies to them and the rename in the
-- ruling is possible without weakening that protection for next steps, where
-- the reporting argument does hold.
--
-- The trade is that new firms need seeding, since there is no shared default
-- to fall back on. Section 3 does that; without it a firm created next month
-- would have an empty status list and no way to set one.
--
-- TWO BLOCKS, deliberately. ALTER TYPE ... ADD VALUE cannot be used in the
-- transaction that adds it. Both enum values are added first, alone. The
-- file's record of what ran is both bodies.
--
-- Requires, by what it actually uses:
--   001  organizations
--   018  picklist_items, picklist_for, picklist_kind
--        (not picklist_item_hidden: that table hides a SHARED Dead Ringers
--        default from one firm, and case statuses have no shared defaults —
--        a firm hides its own row with picklist_items.hidden)
--   050  hand_link_actor(), the way 057 takes an actor
--   057  cases.status, case_status, set_case_lost, delete_case
--
-- Safe to run twice: both enum adds are IF NOT EXISTS, the column adds are
-- IF NOT EXISTS, the seed is guarded by NOT EXISTS, and the backfill only
-- touches rows that have no status item yet.
--
-- APPLIED to staging 2 Nov 2026, both blocks, from the file hashed
-- afc364dd. The MIGRATION is unchanged since — what is below is what ran.
-- The commented VERIFICATION BLOCK was fixed afterwards, having never run as
-- part of the migration (db/README.md). Three bugs, all in the block:
--
--   * four '…' || NOT EXISTS (…) || '…' concatenations, which parse as
--     NOT (EXISTS (…) || '…') and raise "argument of NOT must be type
--     boolean". NOT binds looser than ||, so each needs its own parentheses.
--     The same shape was fixed in 20261030T1500 on 30 Oct; it is a property
--     of writing assertions as concatenated strings, not of this file.
--   * the manager pass set an in-use status's outcome to 'active' when the
--     case was already on an active status, so the guard had nothing to
--     refuse and the test reported its own no-op as a failure to refuse.
--   * the history checks took the newest served_on row by occurred_at. Every
--     row written inside one transaction shares an occurred_at, because now()
--     is the transaction's start time, so "newest" was arbitrary and returned
--     a "recorded as served" row instead of the removal.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Block 1 — the two enum values, alone, because they must commit before use
-- -----------------------------------------------------------------------------
ALTER TYPE case_status   ADD VALUE IF NOT EXISTS 'on_hold';
ALTER TYPE picklist_kind ADD VALUE IF NOT EXISTS 'case_status';

-- -----------------------------------------------------------------------------
-- Block 2 — everything that refers to them
-- -----------------------------------------------------------------------------
BEGIN;

-- -----------------------------------------------------------------------------
-- 1. A status item carries its outcome
--
-- On picklist_items rather than in a side table: the outcome is a property of
-- the status, not a relationship, and a second table would be a second place
-- for the mapping to go missing.
--
-- The constraint is an "if and only if": a case_status item must name an
-- outcome, and no other kind of picklist item may. Without the second half,
-- next_step rows could quietly acquire outcomes nobody reads.
-- -----------------------------------------------------------------------------
ALTER TABLE picklist_items
  ADD COLUMN IF NOT EXISTS case_outcome case_status;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.picklist_items'::regclass
                    AND conname = 'picklist_items_case_outcome_ck') THEN
    ALTER TABLE picklist_items ADD CONSTRAINT picklist_items_case_outcome_ck
      CHECK ((picklist = 'case_status') = (case_outcome IS NOT NULL));
  END IF;
END $$;

COMMENT ON COLUMN picklist_items.code IS
  'The stable handle for an item, never shown to anyone. For Dead Ringers '
  'defaults and for the other picklists it is meaningful, because those codes '
  'are the same at every firm and reporting reads them. For case_status it is '
  'meaningful ONLY for the three seeded with every firm — won, on_hold, lost '
  '— and DELIBERATELY OPAQUE for every status a firm adds afterwards, which '
  'gets a generated code bearing no relation to its label. That is why this '
  'column reads as won, on_hold, lost, s_7f3a9c and is not a mess to tidy: a '
  'code derived from a label collides when two labels reduce to the same text '
  '("Lost" and "Lost!"), and it invents a correspondence that is not there — '
  'a firm''s "Gone" is not the shared meaning of lost, only a name mapped to '
  'that outcome. The outcome is in case_outcome; the label is the firm''s. '
  'Immutable once created, enforced by picklist_items_case_status_guard().';

COMMENT ON COLUMN picklist_items.case_outcome IS
  'For a case_status item, which of the three fixed outcomes it means: '
  'active, lost or on_hold. Set on every case_status item and on no other '
  'kind. A firm names and orders its own statuses; the outcome is what code, '
  'reports and notifications read, which is why renaming one breaks nothing.';

-- -----------------------------------------------------------------------------
-- 2. One status per outcome, for the firms that exist today
--
-- The firm's own rows, so they can be renamed. Guarded by NOT EXISTS per
-- organization rather than ON CONFLICT: a firm that has already edited its
-- list must not have Dead Ringers' names pushed back into it on a replay.
-- -----------------------------------------------------------------------------
INSERT INTO picklist_items
  (organization_id, picklist, code, label, is_default, sort_order, case_outcome, created_by)
SELECT o.id, 'case_status', v.code, v.label, false, v.sort_order, v.outcome::case_status,
       'seeded by 20261030T2100'
  FROM organizations o
 CROSS JOIN (VALUES
       ('won',     'Won',     10, 'active'),
       ('on_hold', 'On hold', 20, 'on_hold'),
       ('lost',    'Lost',    30, 'lost')
     ) AS v(code, label, sort_order, outcome)
 WHERE NOT EXISTS (SELECT 1 FROM picklist_items p
                    WHERE p.organization_id = o.id AND p.picklist = 'case_status');

-- -----------------------------------------------------------------------------
-- 3. And for firms created later
--
-- There is no shared Dead Ringers default for this list, by design (see the
-- header), so a new firm with no seed has an empty status picker and no way
-- to set a case to anything. That is not a thing anyone would report as
-- broken — the picker would simply be empty — so it is enforced here rather
-- than left to whoever next creates an organization.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION organizations_seed_case_statuses() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO picklist_items
    (organization_id, picklist, code, label, is_default, sort_order, case_outcome, created_by)
  SELECT NEW.id, 'case_status', v.code, v.label, false, v.sort_order, v.outcome::case_status,
         'seeded on firm creation'
    FROM (VALUES
          ('won',     'Won',     10, 'active'),
          ('on_hold', 'On hold', 20, 'on_hold'),
          ('lost',    'Lost',    30, 'lost')
        ) AS v(code, label, sort_order, outcome)
   WHERE NOT EXISTS (SELECT 1 FROM picklist_items p
                      WHERE p.organization_id = NEW.id AND p.picklist = 'case_status');
  RETURN NULL;
END $$;

COMMENT ON FUNCTION organizations_seed_case_statuses() IS
  'Gives a new firm the same three case statuses section 2 gave the firms '
  'that existed on 30 Oct 2026. Needed because case statuses have no shared '
  'Dead Ringers default to fall back on — they are the firm''s own rows so '
  'that they can be renamed.';

DROP TRIGGER IF EXISTS organizations_seed_case_statuses_t ON organizations;
CREATE TRIGGER organizations_seed_case_statuses_t AFTER INSERT ON organizations
  FOR EACH ROW EXECUTE FUNCTION organizations_seed_case_statuses();

-- -----------------------------------------------------------------------------
-- 4. What the case is on
--
-- cases.status keeps its meaning and its type: it is the OUTCOME, and it is
-- what every reader reads. status_item_id is the firm's name for it.
--
-- Two columns stating related facts is the shape that went wrong with
-- converting_interaction_id and is_converting, so it is worth saying why this
-- one is different: they are not the same fact. The outcome is fixed and
-- comparable across firms; the item is one firm's label, and it can be hidden,
-- renamed or reordered without the outcome moving. set_case_status() is the
-- only writer and sets both from the item, so they cannot drift through it.
--
-- ON DELETE RESTRICT: a status with cases on it must not vanish. Hiding is the
-- way to retire one, and hiding leaves those cases alone.
-- -----------------------------------------------------------------------------
ALTER TABLE cases
  ADD COLUMN IF NOT EXISTS status_item_id uuid REFERENCES picklist_items(id) ON DELETE RESTRICT;

CREATE INDEX IF NOT EXISTS cases_status_item_idx
  ON cases (status_item_id) WHERE status_item_id IS NOT NULL;

-- Existing cases get their firm's item for the outcome they already hold.
UPDATE cases c
   SET status_item_id = (
         SELECT i.id FROM picklist_items i
          WHERE i.picklist = 'case_status'
            AND i.organization_id = c.organization_id
            AND i.case_outcome = c.status
          ORDER BY i.hidden, i.sort_order, i.label
          LIMIT 1)
 WHERE c.status_item_id IS NULL;

COMMENT ON COLUMN cases.status_item_id IS
  'The firm''s name for this case''s state — a picklist_items row of kind '
  'case_status. cases.status is the outcome that row maps to. Written only '
  'by set_case_status(), which sets both from the item. A hidden status keeps '
  'the cases already on it; it just stops being offered.';

-- 057's comment, corrected. Cases do reach an end state; what never happens
-- is a case being closed with its contents discarded.
COMMENT ON COLUMN cases.status IS
  'The case''s outcome, one of three fixed values: active — the family chose '
  'the firm; lost — they chose it and did not proceed; on_hold. Choosing the '
  'firm is not revenue by itself, and this column is NOT what revenue reads: '
  'revenue is cases.served_on IS NOT NULL, counted by that date. The outcome '
  'governs the pipeline, the date governs revenue, and keeping them apart is '
  'what stops a change of state restating a month that has been counted. A '
  'case with served_on set can no longer be moved to lost: served revenue is '
  'final, and a dispute or refund is a separate fact rather than a '
  'change of state. The firm''s own name '
  'for the state is cases.status_item_id. A case does reach an end state — what never '
  'happens is a case being closed with its contents discarded, which is why '
  'lost and on_hold both KEEP everything and both reverse. Nothing reads this '
  'yet; revenue reporting is not built. NEVER set from an undo control — see '
  'delete_case().';

-- -----------------------------------------------------------------------------
-- 4b. Served: a date, not a state
--
-- Revenue counts once the family is served, and that is a different question
-- from which state the case is in. A booked case and a served case are both
-- active. Kept as a nullable date rather than a fourth outcome so that the
-- two facts can be asked separately, which is what reporting needs: how many
-- active, and of those how many served, in which month.
--
-- SERVED REVENUE IS FINAL. Once this date is set the case cannot be moved to
-- the lost outcome, and the date is removed only by a manager, with a reason.
-- The two rules are one rule: without the second, "can't be marked lost" is
-- just "clear the date first", which is not a rule at all.
--
-- A dispute or a refund is a separate fact for revenue reporting to carry. It
-- does not make the case unserved, and it is not a change of state.
--
-- THE ONE DOOR, and why it is not a side door. A service date recorded on the
-- wrong case has no right date to be corrected to, and without a way out that
-- case is counted as revenue for ever and can never be marked lost. So a
-- manager may clear it — can_manage_settings(), a non-blank reason, both
-- recorded in the history row. Afterwards the case is genuinely unserved and
-- may be marked lost, which is the point. What makes it a door rather than a
-- hole is that it is narrow, named, and leaves a sentence behind.
--
-- REVENUE DOES NOT DEPEND ON THE OUTCOME. It is served_on IS NOT NULL,
-- counted by that date. on_hold is a pipeline state and moves nothing that
-- has been counted — which is true because revenue does not read status, not
-- because on_hold is special.
-- -----------------------------------------------------------------------------
ALTER TABLE cases ADD COLUMN IF NOT EXISTS served_on date;

CREATE INDEX IF NOT EXISTS cases_served_idx
  ON cases (organization_id, served_on) WHERE served_on IS NOT NULL;

COMMENT ON COLUMN cases.served_on IS
  'The date the family was served. Null until then. REVENUE IS served_on IS '
  'NOT NULL, counted by this date — it does not read cases.status, so no '
  'change of state can move a case out of a month it was counted in. A booked '
  'case and a served case are both active; being served is this date, not a '
  'state. Once set, served revenue is final: the case can no longer be marked '
  'lost, and the date is corrected to another past date rather than removed — '
  'except by a manager, with a reason, which is the only change that takes '
  'revenue out of a past month. A dispute or a refund is a separate fact for '
  'reporting to carry; it does not make the case unserved. Written only by '
  'set_case_served().';

CREATE OR REPLACE FUNCTION set_case_served(
  p_case uuid,
  p_served_on date DEFAULT current_date,
  -- Required only to REMOVE a recorded date. Setting one, and correcting one
  -- to another past date, need no reason: neither takes revenue out of a
  -- month that has been counted.
  p_reason text DEFAULT NULL)
RETURNS cases LANGUAGE plpgsql AS $$
DECLARE a record; r cases; v_org uuid; v_was date; v_reason text;
BEGIN
  SELECT * INTO a FROM hand_link_actor();

  SELECT organization_id, served_on INTO v_org, v_was
    FROM cases WHERE id = p_case FOR UPDATE;
  IF v_org IS NULL THEN RAISE EXCEPTION 'no such case'; END IF;

  -- A future date is a typo, not a booking. The hint says what the field is
  -- for, because "that date is wrong" doesn't tell anyone what to put there.
  IF p_served_on > current_date THEN
    RAISE EXCEPTION 'a service date can''t be in the future'
      USING HINT = 'This is the date the service took place, so enter it after the service. Booked services don''t go here.';
  END IF;

  -- Removing a recorded date is the one change that takes revenue out of a
  -- past month, and it is also the only way back from a date recorded on the
  -- wrong case. So it is open, and narrow: a manager, and a reason.
  --
  -- Without the gate, set_case_status()'s refusal to lose a served case would
  -- be one step longer to walk around — clear, then mark lost — and
  -- "forbidden" would mean "clear the date first", which is not a rule.
  IF p_served_on IS NULL AND v_was IS NOT NULL THEN
    IF NOT can_manage_settings() THEN
      RAISE EXCEPTION 'only a manager can remove a service date'
        USING HINT = 'Ask an owner or manager at your firm. Removing it takes this case out of the revenue it was counted in, so it needs a reason on the record.';
    END IF;

    v_reason := NULLIF(btrim(COALESCE(p_reason, '')), '');
    IF v_reason IS NULL THEN
      RAISE EXCEPTION 'removing a service date needs a reason'
        USING HINT = 'Say why — for example, recorded on the wrong case. It goes on the case''s history.';
    END IF;
  END IF;

  UPDATE cases SET served_on = p_served_on, updated_at = now()
   WHERE id = p_case
  RETURNING * INTO r;

  IF v_was IS DISTINCT FROM p_served_on THEN
    PERFORM record_change(
      v_org, 'case', p_case, 'updated', 'user', a.v_name,
      CASE WHEN p_served_on IS NULL
           THEN format('%s removed the service date (%s): %s', a.v_name,
                       to_char(v_was, 'FMMon FMDD, YYYY'), v_reason)
           ELSE format('%s recorded the family as served on %s',
                       a.v_name, to_char(p_served_on, 'FMMonth FMDD, YYYY')) END,
      a.v_user,
      jsonb_build_object('field', 'served_on', 'from', v_was, 'to', p_served_on,
                         'reason', v_reason));
  END IF;

  RETURN r;
END $$;

COMMENT ON FUNCTION set_case_served(uuid, date, text) IS
  'Records the date a family was served — the only writer of cases.served_on, '
  'and the point at which a case becomes revenue. Setting a date, and '
  'correcting it to another past date, are open to anyone and need no reason. '
  'REMOVING a recorded date needs can_manage_settings() and a non-blank '
  'reason, which is written into the history row: it is the only change that '
  'takes revenue out of a month already counted, and the only way back from a '
  'date recorded on the wrong case. Afterwards the case is unserved and may '
  'be marked lost, which is the intent. Refuses a future date.';

-- -----------------------------------------------------------------------------
-- 4c. What a status means can't change under the cases on it
--
-- THE HOLE THIS CLOSES. set_case_status() is the only writer of cases.status
-- and cases.status_item_id, so no call site can pair them wrongly — but that
-- is not the same as the pair being safe. UPDATE picklist_items SET
-- case_outcome = 'lost' on a status with live cases reclassifies every one of
-- them and leaves cases.status untouched: a thousand cases reading active
-- while the status they are on now means lost. One writer of two facts does
-- not help when a third door changes what one of them means.
--
-- So the outcome is locked once a case is on the status. Renaming, hiding and
-- reordering stay open — those are what the ruling grants a firm, and none of
-- them changes what a case means. Changing a status from "won" to "lost" is
-- not an edit to a label; it is an edit to every case holding it.
--
-- The way to retire a meaning is the same as everywhere else here: hide it
-- and add the one you want. The cases already on it keep it.
--
-- Deleting is refused for the same reason, and in words. cases.status_item_id
-- is ON DELETE RESTRICT, which already prevents it — but a foreign-key
-- violation says "update or delete on table picklist_items violates foreign
-- key constraint", which is not a sentence a firm's manager can act on. The
-- constraint is the backstop; this is the message.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION picklist_items_case_status_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE n int;
BEGIN
  IF COALESCE(OLD.picklist, NEW.picklist) IS DISTINCT FROM 'case_status' THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  IF TG_OP = 'DELETE' THEN
    SELECT count(*) INTO n FROM cases WHERE status_item_id = OLD.id;
    IF n > 0 THEN
      RAISE EXCEPTION 'that status is on % case(s), so it can''t be deleted', n
        USING HINT = 'Hide it instead: the cases already on it keep it, and it stops being offered.';
    END IF;
    RETURN OLD;
  END IF;

  -- The code is immutable, cases on it or not. 018's protection covers only
  -- Dead Ringers defaults, and these are firm rows — so without this, nothing
  -- stops a code moving under whatever looks a status up by it. The label is
  -- the renameable half; the code is the handle.
  IF NEW.code IS DISTINCT FROM OLD.code THEN
    RAISE EXCEPTION 'a case status''s code can''t be changed once it exists'
      USING HINT = 'Rename the label instead — the code is the handle anything looking this status up uses.';
  END IF;

  IF NEW.case_outcome IS DISTINCT FROM OLD.case_outcome THEN
    SELECT count(*) INTO n FROM cases WHERE status_item_id = OLD.id;
    IF n > 0 THEN
      RAISE EXCEPTION
        'that status is on % case(s), so what it counts as can''t be changed', n
        USING HINT = 'Hide it and add a status with the outcome you want. Changing it here would silently reclassify every case on it.';
    END IF;
  END IF;

  RETURN NEW;
END $$;

COMMENT ON FUNCTION picklist_items_case_status_guard() IS
  'Three rules on a firm''s case statuses, where 018''s protection does not '
  'reach because these are firm rows rather than Dead Ringers defaults. The '
  'code is immutable once created — it is the handle, the label is the '
  'renameable half. The outcome is fixed once cases are on the status, '
  'because changing it reclassifies every one of them without touching '
  'cases.status. A delete with cases on it is refused in words rather than '
  'as a foreign-key violation. Renaming, hiding and reordering stay open: '
  'they are what a firm is granted, and none of them changes what a case '
  'means.';

DROP TRIGGER IF EXISTS picklist_items_case_status_guard_t ON picklist_items;
CREATE TRIGGER picklist_items_case_status_guard_t
  BEFORE UPDATE OR DELETE ON picklist_items
  FOR EACH ROW EXECUTE FUNCTION picklist_items_case_status_guard();

-- -----------------------------------------------------------------------------
-- 5. A firm's status for an outcome
--
-- Which one, when a firm has several mapped to the same outcome: the first in
-- their own order. Hidden ones sort last rather than being excluded, so a firm
-- that has hidden everything still gets a status rather than a failure — a
-- reinstatement should not be refused because of how someone tidied a list.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION case_status_default(p_org uuid, p_outcome case_status)
RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT i.id FROM picklist_items i
   WHERE i.picklist = 'case_status'
     AND i.organization_id = p_org
     AND i.case_outcome = p_outcome
   ORDER BY i.hidden, i.sort_order, i.label
   LIMIT 1
$$;

COMMENT ON FUNCTION case_status_default(uuid, case_status) IS
  'The status a firm uses for an outcome when nobody picked one — the first '
  'in their own order, visible before hidden. Used when reinstating a case '
  'from lost or on hold, which goes to the firm''s active status.';

-- -----------------------------------------------------------------------------
-- 6. The write
--
-- One function. It takes the firm's status, refuses one belonging to another
-- firm, and sets the outcome from the item rather than from its caller — so
-- there is no call site that can pair a status with the wrong outcome.
--
-- A hidden status is accepted here. Hiding governs what is OFFERED; refusing
-- it on write would make it impossible to move a case back onto the status it
-- was already on, and would turn tidying a list into a data change.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_case_status(p_case uuid, p_status uuid)
RETURNS cases LANGUAGE plpgsql AS $$
DECLARE
  a record; r cases;
  v_org uuid; v_was case_status; v_was_item uuid; v_was_label text;
  v_outcome case_status; v_label text; v_served date;
BEGIN
  SELECT * INTO a FROM hand_link_actor();

  SELECT organization_id, status, status_item_id, served_on
    INTO v_org, v_was, v_was_item, v_served
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

  -- A served case cannot be lost. Revenue counted on a date is final: if the
  -- family disputes or is refunded, that is a separate fact for reporting to
  -- carry, not a change of state. set_case_lost() comes through here, so the
  -- refusal covers it too.
  --
  -- on_hold stays allowed. It does not count as revenue either way, and a
  -- served case put on hold is still a served case.
  IF v_outcome = 'lost' AND v_served IS NOT NULL THEN
    RAISE EXCEPTION 'This case was served on %, so it can''t be marked lost',
      to_char(v_served, 'FMMonth FMDD, YYYY')
      USING HINT = 'A served case is counted as revenue on that date. A dispute or a refund is recorded separately — it does not make the case unserved.';
  END IF;

  SELECT label INTO v_was_label FROM picklist_items WHERE id = v_was_item;

  UPDATE cases
     SET status = v_outcome, status_item_id = p_status, updated_at = now()
   WHERE id = p_case
  RETURNING * INTO r;

  IF v_was_item IS DISTINCT FROM p_status OR v_was IS DISTINCT FROM v_outcome THEN
    PERFORM record_change(
      v_org, 'case', p_case, 'updated', 'user', a.v_name,
      format('%s set the case to %s', a.v_name, v_label), a.v_user,
      jsonb_build_object('field', 'status',
                         'from', v_was, 'to', v_outcome,
                         'from_label', v_was_label, 'to_label', v_label,
                         'status_item_id', p_status));
  END IF;

  RETURN r;
END $$;

COMMENT ON FUNCTION set_case_status(uuid, uuid) IS
  'Sets a case to one of its firm''s named statuses, and its outcome from '
  'that status. The only writer of cases.status and cases.status_item_id, so '
  'the two cannot disagree. Refuses a status belonging to another firm; '
  'accepts a hidden one, because hiding governs what is offered, not what a '
  'case may already be on. NOT an undo — see delete_case().';

-- -----------------------------------------------------------------------------
-- 7. set_case_lost, now a wrapper
--
-- Kept because delete_case()'s refusal names it and the app already calls it.
-- Reinstating goes to the firm's active status, which is the ruling: a family
-- who comes back is being served again, and "won" is active.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_case_lost(p_case uuid, p_lost boolean DEFAULT true)
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

  RETURN set_case_status(p_case, v_item);
END $$;

COMMENT ON FUNCTION set_case_lost(uuid, boolean) IS
  'The family converted and didn''t proceed. A thin wrapper over '
  'set_case_status() that picks the firm''s lost status, or its active one '
  'when reinstating. Kept under its own name because delete_case()''s refusal '
  'names it and the app calls it. Keeps everything and reverses. NOT an undo: '
  'an undo is a mistake with nothing to report, and sharing a control with '
  'this produces fake lost cases and a report nobody trusts.';

REVOKE ALL ON FUNCTION set_case_status(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION set_case_status(uuid, uuid) TO authenticated;

REVOKE ALL ON FUNCTION case_status_default(uuid, case_status) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION case_status_default(uuid, case_status) TO authenticated;

REVOKE ALL ON FUNCTION set_case_served(uuid, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION set_case_served(uuid, date, text) TO authenticated;

COMMIT;

-- =============================================================================
-- STILL TO DO, named so they aren't folded in and skipped
--
-- * The Settings screen needs the case_status list: rename, add, hide,
--   reorder, and a choice of outcome on an added status. picklist_for(org,
--   'case_status') returns the visible ones; it does not return case_outcome,
--   so Settings reads picklist_items directly or picklist_for gains a column.
--   Changing picklist_for's signature affects next steps too.
-- * The case page needs the status control, and it must not sit beside undo.
-- * cases_status_idx is still "WHERE status <> 'active'", which now also
--   indexes on_hold. That is right, but worth knowing it changed meaning.
-- * The case screen needs the service date as its own control, not folded
--   into the status one: they are different questions and set_case_served()
--   is a different function.
-- * Nothing reads the outcome or served_on yet. Revenue reporting is not
--   built; the rule it will use is stated on both columns.
-- * The Settings screen needs the reason prompt when a manager removes a
--   service date, and the case screen should not offer removal at all to
--   someone who isn't a manager — the refusal is the backstop, not the
--   interface.
-- * THE REVENUE QUERY, when it is written, must carry its dependency in a
--   comment: "has a service date" is a complete definition of revenue only
--   because a served case can never be marked lost. If that rule is ever
--   relaxed, the query is wrong and nothing about the query itself will say
--   so.
-- * A date removed because it was on the wrong case leaves a second half
--   undone — recording it on the RIGHT case. The help text says to, and
--   nothing tracks whether anyone did. Worth a prompt, a reminder, or an
--   accepted answer that it is on the person who removed it.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
-- Set-up failures are reported rather than raised, so a collision costs one
-- line and not the whole report.
--
-- DO $$
-- DECLARE
--   r text := ''; v_org uuid; v_other uuid; v_case uuid; v_item uuid;
--   v_lost uuid; v_hidden uuid; v_mgr uuid; v_staff uuid; v_n int;
-- BEGIN
--   SELECT id INTO v_org FROM organizations WHERE code = 'DR';
--   SELECT id INTO v_other FROM organizations WHERE code <> 'DR' LIMIT 1;
--
--   -- The session an actor is read from. set_case_status() and
--   -- set_case_served() go through hand_link_actor(), which reads
--   -- current_user_id() — without this they record a null actor or fail,
--   -- and the failure looks like a defect in the function. 057's block does
--   -- the same thing for the same reason.
--   PERFORM set_config('app.is_internal', 'on', true);
--   PERFORM set_config('app.organization_id', v_org::text, true);
--   PERFORM set_config('app.user_id',
--     (SELECT id::text FROM users WHERE active ORDER BY is_internal DESC LIMIT 1), true);
--
--   r := r || 'outcomes available: '
--          || (SELECT string_agg(enumlabel, ',' ORDER BY enumsortorder)
--                FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
--               WHERE t.typname = 'case_status')
--          || '   (expect active,lost,on_hold)' || chr(10);
--
--   SELECT count(*) INTO v_n FROM picklist_items
--    WHERE picklist = 'case_status' AND organization_id = v_org;
--   r := r || 'statuses at this firm: ' || v_n || '   (expect 3)' || chr(10);
--
--   r := r || 'every firm has three: '
--          || (NOT EXISTS (SELECT 1 FROM organizations o
--                           WHERE (SELECT count(*) FROM picklist_items p
--                                   WHERE p.organization_id = o.id
--                                     AND p.picklist = 'case_status') <> 3))
--          || '   (expect true)' || chr(10);
--
--   r := r || 'existing cases backfilled: '
--          || (NOT EXISTS (SELECT 1 FROM cases WHERE status_item_id IS NULL))
--          || ', outcome matches the item: '
--          || (NOT EXISTS (SELECT 1 FROM cases c JOIN picklist_items i ON i.id = c.status_item_id
--                           WHERE i.case_outcome IS DISTINCT FROM c.status))
--          || '   (expect true, true)' || chr(10);
--
--   -- A firm may rename its own status. 018's protection must not fire.
--   BEGIN
--     UPDATE picklist_items SET label = 'Went elsewhere'
--      WHERE organization_id = v_org AND picklist = 'case_status' AND code = 'lost';
--     r := r || 'firm renamed its lost status: true   (expect true)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'RENAME REFUSED (BAD): ' || SQLERRM || chr(10); END;
--
--   -- An outcome cannot be invented: the column is an enum.
--   BEGIN
--     INSERT INTO picklist_items (organization_id, picklist, code, label, case_outcome)
--     VALUES (v_org, 'case_status', 'verify_bad', 'Verify', 'won');
--     r := r || 'invented outcome: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'invented outcome refused' || chr(10); END;
--
--   -- A case_status item must carry an outcome, and nothing else may.
--   BEGIN
--     INSERT INTO picklist_items (organization_id, picklist, code, label)
--     VALUES (v_org, 'case_status', 'verify_none', 'No outcome');
--     r := r || 'status with no outcome: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN check_violation THEN
--     r := r || 'status with no outcome refused' || chr(10);
--   WHEN others THEN
--     r := r || 'status with no outcome NOT TESTED: ' || SQLERRM || chr(10); END;
--
--   BEGIN
--     INSERT INTO picklist_items (organization_id, picklist, code, label, case_outcome)
--     VALUES (v_org, 'next_step', 'verify_outcome', 'Verify', 'lost');
--     r := r || 'next step carrying an outcome: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN check_violation THEN
--     r := r || 'next step carrying an outcome refused' || chr(10);
--   WHEN others THEN
--     r := r || 'next step outcome NOT TESTED: ' || SQLERRM || chr(10); END;
--
--   -- Setting, reversing, and the wrapper.
--   BEGIN
--     SELECT id INTO v_case FROM cases WHERE organization_id = v_org LIMIT 1;
--     SELECT id INTO v_lost FROM picklist_items
--      WHERE organization_id = v_org AND picklist = 'case_status' AND code = 'lost';
--
--     PERFORM set_case_status(v_case, v_lost);
--     r := r || 'set to lost: '
--            || (SELECT status::text || ' / ' || (status_item_id = v_lost)::text
--                  FROM cases WHERE id = v_case)
--            || '   (expect lost / true)' || chr(10);
--
--     PERFORM set_case_lost(v_case, false);
--     r := r || 'reinstated: '
--            || (SELECT status::text FROM cases WHERE id = v_case)
--            || ', to the firm''s active status: '
--            || (SELECT status_item_id = case_status_default(v_org, 'active')
--                  FROM cases WHERE id = v_case)
--            || '   (expect active, true)' || chr(10);
--
--     -- A hidden status still accepts a case already on it.
--     UPDATE picklist_items SET hidden = true WHERE id = v_lost;
--     BEGIN
--       PERFORM set_case_status(v_case, v_lost);
--       r := r || 'hidden status still settable: true   (expect true)' || chr(10);
--     EXCEPTION WHEN others THEN
--       r := r || 'hidden status refused (BAD): ' || SQLERRM || chr(10); END;
--     r := r || 'case kept its hidden status: '
--            || (SELECT status_item_id = v_lost FROM cases WHERE id = v_case)
--            || ', and it is no longer offered: '
--            || (NOT EXISTS (SELECT 1 FROM picklist_for(v_org, 'case_status') WHERE id = v_lost))
--            || '   (expect true, true)' || chr(10);
--
--     -- Another firm's status is refused.
--     IF v_other IS NOT NULL THEN
--       SELECT id INTO v_item FROM picklist_items
--        WHERE organization_id = v_other AND picklist = 'case_status' LIMIT 1;
--       BEGIN
--         PERFORM set_case_status(v_case, v_item);
--         r := r || 'another firm''s status: ALLOWED (BAD)' || chr(10);
--       EXCEPTION WHEN others THEN
--         r := r || 'another firm''s status refused' || chr(10); END;
--     END IF;
--
--     r := r || 'history written: '
--            || (SELECT count(*) FROM change_history
--                 WHERE entity_id = v_case AND action = 'updated')
--            || '   (expect at least 3)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'status-writing tests NOT RUN: ' || SQLERRM || chr(10); END;
--
--   -- The outcome is locked once cases are on the status, and so is the delete.
--   BEGIN
--     UPDATE picklist_items SET case_outcome = 'active'
--      WHERE id = (SELECT status_item_id FROM cases WHERE id = v_case);
--     r := r || 'outcome changed under live cases: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'outcome change refused: ' || SQLERRM || chr(10); END;
--
--   BEGIN
--     DELETE FROM picklist_items
--      WHERE id = (SELECT status_item_id FROM cases WHERE id = v_case);
--     r := r || 'status with cases deleted: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'delete refused: ' || SQLERRM || chr(10); END;
--
--   -- The code is immutable even on an unused status, and even for a firm
--   -- editing its own row.
--   BEGIN
--     UPDATE picklist_items SET code = 'lost_renamed'
--      WHERE organization_id = v_org AND picklist = 'case_status' AND code = 'lost';
--     r := r || 'code changed: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'code change refused: ' || SQLERRM || chr(10); END;
--
--   -- An unused status may still have its outcome changed.
--   BEGIN
--     INSERT INTO picklist_items (organization_id, picklist, code, label, case_outcome)
--     VALUES (v_org, 'case_status', 'verify_unused', 'Verify unused', 'active')
--     RETURNING id INTO v_item;
--     UPDATE picklist_items SET case_outcome = 'on_hold' WHERE id = v_item;
--     r := r || 'unused status may be remapped: true   (expect true)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'unused status remap REFUSED (BAD): ' || SQLERRM || chr(10); END;
--
--   -- Served is a date, not a state. The case is put back to active first:
--   -- the tests above left it lost, and a lost case is the wrong starting
--   -- point for recording a service.
--   BEGIN
--     PERFORM set_case_lost(v_case, false);
--     PERFORM set_case_served(v_case, current_date);
--     r := r || 'served recorded, state unchanged: '
--            || (SELECT (served_on = current_date) AND status::text = 'active'
--                  FROM cases WHERE id = v_case)
--            || '   (expect true)' || chr(10);
--
--     BEGIN
--       PERFORM set_case_served(v_case, current_date + 1);
--       r := r || 'future service date: ALLOWED (BAD)' || chr(10);
--     EXCEPTION WHEN others THEN
--       r := r || 'future service date refused' || chr(10); END;
--
--     -- Correcting to another past date stays open.
--     PERFORM set_case_served(v_case, current_date - 2);
--     r := r || 'corrected to another past date: '
--            || (SELECT served_on = current_date - 2 FROM cases WHERE id = v_case)
--            || '   (expect true)' || chr(10);
--
--     -- A served case cannot be lost, by either route.
--     BEGIN
--       PERFORM set_case_status(v_case, v_lost);
--       r := r || 'served case marked lost by status: ALLOWED (BAD)' || chr(10);
--     EXCEPTION WHEN others THEN
--       r := r || 'served case lost by status refused: ' || SQLERRM || chr(10); END;
--
--     BEGIN
--       PERFORM set_case_lost(v_case, true);
--       r := r || 'served case marked lost by wrapper: ALLOWED (BAD)' || chr(10);
--     EXCEPTION WHEN others THEN
--       r := r || 'served case lost by wrapper refused' || chr(10); END;
--
--     -- And the two-step route around it is closed at the first step.
--     BEGIN
--       PERFORM set_case_served(v_case, NULL);
--       r := r || 'service date cleared: ALLOWED (BAD — side door open)' || chr(10);
--       BEGIN
--         PERFORM set_case_lost(v_case, true);
--         r := r || '  and then marked lost: ALLOWED (BAD)' || chr(10);
--       EXCEPTION WHEN others THEN
--         r := r || '  but still not lost' || chr(10); END;
--     EXCEPTION WHEN others THEN
--       r := r || 'clearing the service date refused' || chr(10); END;
--
--     -- On hold stays open on a served case.
--     BEGIN
--       PERFORM set_case_status(v_case, case_status_default(v_org, 'on_hold'));
--       r := r || 'served case put on hold: '
--              || (SELECT status::text FROM cases WHERE id = v_case)
--              || '   (expect on_hold)' || chr(10);
--     EXCEPTION WHEN others THEN
--       r := r || 'served case on hold REFUSED (BAD): ' || SQLERRM || chr(10); END;
--   EXCEPTION WHEN others THEN
--     r := r || 'served tests NOT RUN: ' || SQLERRM || chr(10); END;
--
--   -- A new firm is seeded. client_type is NOT NULL on organizations (001).
--   BEGIN
--     INSERT INTO organizations (code, name, client_type)
--     VALUES ('VRFY', 'Verify Firm', 'funeral_home');
--     r := r || 'new firm seeded: '
--            || (SELECT count(*) FROM picklist_items p
--                 JOIN organizations o ON o.id = p.organization_id
--                WHERE o.code = 'VRFY' AND p.picklist = 'case_status')
--            || '   (expect 3)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'new-firm seed NOT TESTED: ' || SQLERRM || chr(10); END;
--
--   -- --------------------------------------------------------------------
--   -- Second pass: the path the app actually takes.
--   --
--   -- Everything above ran with app.is_internal = 'on', and every policy on
--   -- picklist_items and cases begins "is_internal() OR ...", so none of them
--   -- were exercised. This pass turns that off, becomes a firm manager, and
--   -- switches to the authenticated role so RLS applies at all — the table
--   -- owner bypasses it otherwise.
--   --
--   -- It runs LAST because the role does not revert inside this block, and
--   -- everything after it would run as authenticated too.
--   -- --------------------------------------------------------------------
--   -- The manager and the non-manager are CREATED here, not looked up:
--   -- neither database has an active, non-internal owner or manager in any
--   -- firm today, so a lookup reports SKIPPED every time and the pass never
--   -- runs. Both rows are rolled back with everything else.
--   BEGIN
--     INSERT INTO users (email, full_name, is_internal, active)
--     VALUES ('verify.manager@example.invalid', 'Verify Manager', false, true)
--     RETURNING id INTO v_mgr;
--     INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id)
--     VALUES (v_mgr, 'organization', 'manager', v_org);
--
--     INSERT INTO users (email, full_name, is_internal, active)
--     VALUES ('verify.staff@example.invalid', 'Verify Staff', false, true)
--     RETURNING id INTO v_staff;
--     INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id)
--     VALUES (v_staff, 'organization', 'professional', v_org);
--
--     IF v_mgr IS NULL THEN
--       r := r || 'manager pass SKIPPED: could not create a test manager' || chr(10);
--     ELSE
--       PERFORM set_config('app.is_internal', 'off', true);
--       PERFORM set_config('app.user_id', v_mgr::text, true);
--       PERFORM set_config('role', 'authenticated', true);
--
--       r := r || 'can_manage_settings() as the manager: ' || can_manage_settings()
--              || '   (expect true)' || chr(10);
--
--       r := r || '-- as a firm manager, RLS applied --' || chr(10);
--       r := r || 'sees own firm''s statuses: '
--              || (SELECT count(*) FROM picklist_for(v_org, 'case_status'))
--              || ', sees another firm''s: '
--              || (SELECT count(*) FROM picklist_items
--                   WHERE organization_id = v_other AND picklist = 'case_status')
--              || '   (expect some, 0)' || chr(10);
--
--       BEGIN
--         UPDATE picklist_items SET label = 'Lost (manager renamed)'
--          WHERE organization_id = v_org AND picklist = 'case_status' AND code = 'lost';
--         r := r || 'manager renamed a status: true' || chr(10);
--       EXCEPTION WHEN others THEN
--         r := r || 'manager rename REFUSED: ' || SQLERRM || chr(10); END;
--
--       BEGIN
--         PERFORM set_case_status(v_case, case_status_default(v_org, 'active'));
--         r := r || 'manager set a status: '
--                || (SELECT status::text FROM cases WHERE id = v_case) || chr(10);
--       EXCEPTION WHEN others THEN
--         r := r || 'manager set_case_status REFUSED: ' || SQLERRM || chr(10); END;
--
--       -- To a DIFFERENT outcome: the case is on Won, which is already
--       -- active, so setting it to active changes nothing, the guard has
--       -- nothing to refuse, and the test passes itself.
--       BEGIN
--         UPDATE picklist_items SET case_outcome = 'on_hold'
--          WHERE id = (SELECT status_item_id FROM cases WHERE id = v_case);
--         r := r || 'manager changed an outcome in use: ALLOWED (BAD)' || chr(10);
--       EXCEPTION WHEN others THEN
--         r := r || 'manager outcome change refused' || chr(10); END;
--
--       BEGIN
--         PERFORM set_case_served(v_case, current_date - 1);
--         r := r || 'manager recorded a service date: '
--                || (SELECT served_on::text FROM cases WHERE id = v_case) || chr(10);
--       EXCEPTION WHEN others THEN
--         r := r || 'manager set_case_served REFUSED: ' || SQLERRM || chr(10); END;
--
--       -- ---- The one door: removing a recorded date ----------------------
--       -- Tested through can_manage_settings(), not through is_internal(),
--       -- which is why this pass had to exist at all.
--
--       -- A non-manager at the same firm cannot.
--       PERFORM set_config('app.user_id', v_staff::text, true);
--       r := r || 'can_manage_settings() as the non-manager: ' || can_manage_settings()
--              || '   (expect false)' || chr(10);
--       BEGIN
--         PERFORM set_case_served(v_case, NULL, 'recorded on the wrong case');
--         r := r || 'non-manager removed the date: ALLOWED (BAD)' || chr(10);
--       EXCEPTION WHEN others THEN
--         r := r || 'non-manager removal refused: ' || SQLERRM || chr(10); END;
--
--       PERFORM set_config('app.user_id', v_mgr::text, true);
--
--       -- A manager without a reason cannot.
--       BEGIN
--         PERFORM set_case_served(v_case, NULL);
--         r := r || 'manager removed it with no reason: ALLOWED (BAD)' || chr(10);
--       EXCEPTION WHEN others THEN
--         r := r || 'removal with no reason refused' || chr(10); END;
--       BEGIN
--         PERFORM set_case_served(v_case, NULL, '   ');
--         r := r || 'manager removed it with a blank reason: ALLOWED (BAD)' || chr(10);
--       EXCEPTION WHEN others THEN
--         r := r || 'removal with a blank reason refused' || chr(10); END;
--
--       -- A manager with a reason can. The removal gets its own block: if a
--       -- check below it fails, the removal must not roll back with it, or
--       -- the "can now be lost" test fails for a reason that has nothing to
--       -- do with the rule it is testing.
--       BEGIN
--         PERFORM set_case_served(v_case, NULL, 'recorded on the wrong case');
--         r := r || 'manager removed the date: '
--                || (SELECT served_on IS NULL FROM cases WHERE id = v_case)
--                || '   (expect true)' || chr(10);
--       EXCEPTION WHEN others THEN
--         r := r || 'manager removal NOT RUN: ' || SQLERRM || chr(10); END;
--
--       -- The reason is on the record, in the detail and in words.
--       --
--       -- Found by its reason, not by being the newest row. Every row written
--       -- in this block shares one occurred_at, because now() is the start of
--       -- the transaction — so ORDER BY occurred_at DESC returns whichever
--       -- served_on row the planner reaches first, which was a "recorded as
--       -- served" one. A removal is the only served_on change that carries a
--       -- reason, so that is what identifies it.
--       BEGIN
--         r := r || 'history carries the reason: '
--                || COALESCE((SELECT detail->>'reason' FROM change_history
--                              WHERE entity_id = v_case AND detail->>'field' = 'served_on'
--                                AND detail->>'reason' IS NOT NULL LIMIT 1), 'NONE')
--                || chr(10);
--         r := r || 'and says so in words: '
--                || COALESCE((SELECT summary FROM change_history
--                              WHERE entity_id = v_case AND detail->>'field' = 'served_on'
--                                AND detail->>'reason' IS NOT NULL LIMIT 1), 'NONE')
--                || chr(10);
--       EXCEPTION WHEN others THEN
--         r := r || 'history checks NOT RUN: ' || SQLERRM || chr(10); END;
--
--       -- And then the case really is unserved, so it can be lost.
--       BEGIN
--         PERFORM set_case_lost(v_case, true);
--         r := r || 'unserved case can now be lost: '
--                || (SELECT status::text FROM cases WHERE id = v_case)
--                || '   (expect lost)' || chr(10);
--       EXCEPTION WHEN others THEN
--         r := r || 'lost after removal REFUSED (BAD): ' || SQLERRM || chr(10); END;
--     END IF;
--   EXCEPTION WHEN others THEN
--     r := r || 'manager pass NOT RUN: ' || SQLERRM || chr(10); END;
--
--   RAISE EXCEPTION 'VERIFY 20261030T2100_case_statuses (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
