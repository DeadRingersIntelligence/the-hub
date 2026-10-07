-- =============================================================================
-- 014_measurement_and_menu_scoring.sql
-- The Hub — Phase 3, migration 14: how a behaviour is measured, and how a
-- menu-style section is scored.
--
-- Two defects this fixes.
--
-- ONE — behaviours are not all the same shape, and treating them as one shape
-- produces numbers that look fine and mean nothing.
--
--   binary   "Did they ask for your name?"  Yes 2/2, No 0/2. A rate is right.
--   graded   "Did they have a proper greeting?"  Worth 4. Location name alone
--            scores 1, plus their name 2, the full greeting 4. There is no
--            did-it / didn't-do-it, only degree — so a rate is meaningless.
--            Reporting these as observed/not-observed is what made Clarity,
--            Sincerity and Buy-In all read a flat 100%.
--   inverted "Did they lead with direct cremation?"  "Did they use industry
--            jargon?"  The point-scoring answer is No. The win is avoidance.
--
-- TWO — Follow-Up is a menu, not a checklist. Six items worth eight points
-- means nobody reaches full marks without doing all six, and nobody should
-- offer five kinds of follow-up on one call. Some items are sufficient on
-- their own; others only help in combination.
--
-- Requires: 001 to 013
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- How a behaviour is measured
-- -----------------------------------------------------------------------------
CREATE TYPE measurement_type AS ENUM ('binary', 'graded', 'inverted', 'admin');

ALTER TABLE behaviors
  ADD COLUMN measurement_type measurement_type NOT NULL DEFAULT 'binary';

COMMENT ON COLUMN behaviors.measurement_type IS
  'binary: rate of occurrence. graded: points earned over points available. '
  'inverted: rate of successful avoidance. admin: not scored, e.g. reviewer name.';

-- Classify from the answer options already seeded, so nothing is typed by hand:
--   several answers carry partial credit            -> graded
--   the full-credit answer begins with "No"         -> inverted
--   no answer carries points                        -> admin
--   otherwise                                       -> binary
WITH shape AS (
  SELECT b.id,
         MAX(a.points) AS top,
         COUNT(*) FILTER (WHERE a.points > 0
                          AND a.points < (SELECT MAX(a2.points)
                                          FROM behavior_answers a2 WHERE a2.behavior_id = b.id)
                         ) AS partials,
         BOOL_OR(a.points = (SELECT MAX(a3.points) FROM behavior_answers a3
                             WHERE a3.behavior_id = b.id)
                 AND lower(btrim(a.answer_value)) LIKE 'no%') AS top_is_no
  FROM behaviors b
  JOIN behavior_answers a ON a.behavior_id = b.id
  GROUP BY b.id
)
UPDATE behaviors b SET measurement_type =
  (CASE WHEN s.top IS NULL OR s.top = 0 THEN 'admin'
        WHEN s.partials > 0             THEN 'graded'
        WHEN s.top_is_no                THEN 'inverted'
        ELSE 'binary' END)::measurement_type
FROM shape s WHERE s.id = b.id;

-- -----------------------------------------------------------------------------
-- Menu scoring
--
-- An additive section wants every item. A menu section wants ENOUGH — one
-- strong action, or several supporting ones together.
--
-- credit_value is the share of the section a single behaviour is worth.
-- Anything at 1.00 is sufficient on its own. The section's credit is the sum
-- of what was actually done, capped at 1.
-- -----------------------------------------------------------------------------
CREATE TYPE section_scoring AS ENUM ('additive', 'menu');

ALTER TABLE rubric_sections
  ADD COLUMN scoring_mode section_scoring NOT NULL DEFAULT 'additive';

ALTER TABLE rubric_behaviors
  ADD COLUMN credit_value numeric(4,2);

ALTER TABLE rubric_behaviors ADD CONSTRAINT rubric_behaviors_credit_ck
  CHECK (credit_value IS NULL OR (credit_value > 0 AND credit_value <= 1));

UPDATE rubric_sections SET scoring_mode = 'menu' WHERE code = 'follow_up';

-- Credit values for Follow-Up.
--
-- The principle is OWNERSHIP OF THE NEXT STEP, not effort. An action where the
-- director carries the follow-up is sufficient on its own. An action that hands
-- the next step back to the caller is worth half — so two of them together
-- still pass, and one alone does not.
--
--   Sets an appointment        the director owns it
--   Offers to call back        the director owns it
--   Offers to mail or email    the director owns it
--   Gives a direct number      excellent, but the caller has to call
--   Asks about other questions the caller has to know what to ask
--   Refers to the website      the caller has to go and research
UPDATE rubric_behaviors rb SET credit_value = v.credit
FROM (VALUES
  ('attempt to set an appointment', 1.00),
  ('offer to call you back',        1.00),
  ('offer to mail or email',        1.00),
  ('provide their direct phone',    0.50),
  ('ask if you had any other',      0.50),
  ('refer to their website',        0.50)
) AS v(frag, credit)
JOIN behaviors b ON lower(b.label) LIKE '%' || v.frag || '%'
JOIN rubric_sections s ON s.id = b.section_id AND s.code = 'follow_up'
WHERE rb.behavior_id = b.id;

-- -----------------------------------------------------------------------------
-- Section scores, honouring both fixes
--
-- Additive sections: points earned over points available, as before.
-- Menu sections: the capped sum of credit for what was actually done.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION section_scores(p_org uuid, p_from date, p_to date)
RETURNS TABLE (section text, scoring section_scoring, evaluations bigint, score numeric)
LANGUAGE sql STABLE AS $$
WITH obs AS (
  SELECT e.id AS eval_id, s.code, s.label, s.display_order, s.scoring_mode,
         o.answer_points, o.possible_points, rb.credit_value,
         (o.answer_points >= o.possible_points AND o.possible_points > 0) AS achieved
  FROM observations o
  JOIN evaluations e ON e.id = o.evaluation_id
  JOIN behaviors b ON b.id = o.behavior_id
  JOIN rubric_sections s ON s.id = b.section_id
  LEFT JOIN rubric_behaviors rb ON rb.behavior_id = b.id AND rb.rubric_id = e.rubric_id
  WHERE o.organization_id = p_org
    AND e.lifecycle_state = 'complete'
    AND b.measurement_type <> 'admin'
    AND o.opportunity
    AND COALESCE(e.performed_on, e.period_start) BETWEEN p_from AND p_to
),
per_eval AS (
  SELECT eval_id, label, display_order, scoring_mode,
         CASE WHEN scoring_mode = 'menu'
              THEN LEAST(1.0, COALESCE(SUM(credit_value) FILTER (WHERE achieved), 0))
              ELSE SUM(answer_points) / NULLIF(SUM(possible_points), 0)
         END AS frac
  FROM obs GROUP BY eval_id, label, display_order, scoring_mode
)
SELECT label, scoring_mode, COUNT(*), round(100.0 * AVG(frac), 1)
FROM per_eval GROUP BY label, display_order, scoring_mode ORDER BY display_order
$$;

-- Behaviour-level reporting that respects measurement type.
CREATE OR REPLACE FUNCTION behavior_detail(p_org uuid, p_from date, p_to date)
RETURNS TABLE (
  section text, label text, measurement measurement_type,
  n bigint, achieved bigint, value numeric
) LANGUAGE sql STABLE AS $$
  SELECT s.label, b.label, b.measurement_type,
         COUNT(*),
         COUNT(*) FILTER (WHERE o.answer_points >= o.possible_points AND o.possible_points > 0),
         CASE WHEN b.measurement_type = 'graded'
              THEN round(100.0 * SUM(o.answer_points) / NULLIF(SUM(o.possible_points), 0), 1)
              ELSE round(100.0 * COUNT(*) FILTER (WHERE o.answer_points >= o.possible_points
                                                    AND o.possible_points > 0) / COUNT(*), 1)
         END
  FROM observations o
  JOIN evaluations e ON e.id = o.evaluation_id
  JOIN behaviors b ON b.id = o.behavior_id
  JOIN rubric_sections s ON s.id = b.section_id
  WHERE o.organization_id = p_org
    AND e.lifecycle_state = 'complete'
    AND b.measurement_type <> 'admin'
    AND o.opportunity
    AND COALESCE(e.performed_on, e.period_start) BETWEEN p_from AND p_to
  GROUP BY s.label, s.display_order, b.label, b.measurement_type
  ORDER BY s.display_order, 6
$$;

COMMIT;

-- =============================================================================
-- Verification
--
--   SET app.is_internal = 'on';
--   SELECT measurement_type, count(*) FROM behaviors GROUP BY 1 ORDER BY 2 DESC;
--
--   SELECT b.label, rb.credit_value
--   FROM rubric_behaviors rb JOIN behaviors b ON b.id = rb.behavior_id
--   JOIN rubric_sections s ON s.id = b.section_id
--   WHERE s.code = 'follow_up' AND rb.credit_value IS NOT NULL
--   ORDER BY rb.credit_value DESC;
--
--   SELECT * FROM section_scores(
--     (SELECT id FROM organizations WHERE code='ALT'), '2026-08-01','2026-08-31');
-- =============================================================================
