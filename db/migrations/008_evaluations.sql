-- =============================================================================
-- 008_evaluations.sql
-- The Hub — Phase 3, migration 8: evaluations and observations.
--
-- `observations` is where the north star lives. Every row is one behavior on
-- one evaluation, carrying whether there was an OPPORTUNITY for it and
-- whether it was OBSERVED. Behaviour counts against opportunity-based
-- denominators is the entire scoring model, and it has to be here from the
-- first row.
--
-- Never store a composite score. Store observations; compute in the query.
-- That is what makes the scoring reframe a query change rather than a rebuild,
-- and what lets every historical report improve when the model improves.
--
-- Requires: 001 to 007
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- evaluations
--
-- One interaction can carry more than one evaluation. The normal case is one.
-- The second case is an FTC audit reading the same call, or an evaluation
-- aimed at an external audience — an answering service flagging behaviours on
-- the served firm's side as good faith or as a sales opening.
--
-- interaction_id is NULLABLE on purpose. A price-consistency finding spans
-- several calls: direct cremation quoted at $995 on one and $1,095 on another
-- with nobody explaining the difference belongs to a LOCATION and a PERIOD,
-- not to any single interaction. Same shape carries "your team is
-- consistently missing this" findings later.
--
-- Lifecycle is five states and exposes nothing about AI:
--   scheduled -> in_progress -> initial_review -> final_review -> complete
-- Initial review is where AI and shopper fields land. Final review is the
-- human pass. CLIENT-FACING QUERIES FILTER ON complete — which is the fix for
-- clients seeing unfinalised scores and asking why they look wrong.
-- -----------------------------------------------------------------------------
CREATE TYPE evaluation_lifecycle AS ENUM (
  'scheduled', 'in_progress', 'initial_review', 'final_review', 'complete', 'void');

CREATE TYPE evaluation_audience AS ENUM ('client', 'internal', 'external_party');

-- Why this call was picked. One column, and it answers "why was my worst
-- month all Dana's calls" without anyone reconstructing it.
CREATE TYPE selection_reason AS ENUM (
  'rule_matched', 'random', 'manual', 'client_requested', 'historical_sprint');

CREATE TABLE evaluations (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id       uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,

  interaction_id        uuid REFERENCES interactions(id) ON DELETE CASCADE,
  location_id           uuid REFERENCES locations(id) ON DELETE SET NULL,

  -- Period scope, used when the finding spans calls rather than sitting on one.
  period_start          date,
  period_end            date,

  rubric_id             uuid NOT NULL REFERENCES rubrics(id) ON DELETE RESTRICT,
  rubric_type           rubric_type NOT NULL DEFAULT 'cx',
  audience              evaluation_audience NOT NULL DEFAULT 'client',

  -- The person being measured. Null where the handler was never resolved —
  -- the evaluation still happens, it simply scores the seat.
  subject_person_id     uuid REFERENCES people(id) ON DELETE SET NULL,
  seat_id               uuid REFERENCES seats(id) ON DELETE SET NULL,

  lifecycle_state       evaluation_lifecycle NOT NULL DEFAULT 'scheduled',
  selection_reason      selection_reason NOT NULL DEFAULT 'rule_matched',

  -- When the work was done, kept separate from when the call happened, so a
  -- March report does not change when a September historical sprint backfills
  -- it.
  performed_on          date,
  reviewed_by           text,
  reviewed_at           timestamptz,
  completed_at          timestamptz,

  notes                 text,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX evaluations_org_state_idx   ON evaluations (organization_id, lifecycle_state);
CREATE INDEX evaluations_interaction_idx ON evaluations (interaction_id);
CREATE INDEX evaluations_subject_idx     ON evaluations (subject_person_id);
CREATE INDEX evaluations_location_idx    ON evaluations (location_id, period_start);
CREATE TRIGGER evaluations_touch BEFORE UPDATE ON evaluations
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- An evaluation is about a call, or about a location over a period. Never
-- neither.
ALTER TABLE evaluations ADD CONSTRAINT evaluations_scope_ck
  CHECK ( interaction_id IS NOT NULL
       OR (location_id IS NOT NULL AND period_start IS NOT NULL AND period_end IS NOT NULL) );

ALTER TABLE evaluations ADD CONSTRAINT evaluations_period_ck
  CHECK (period_end IS NULL OR period_start IS NULL OR period_end >= period_start);

-- Completing requires a human having signed off. Final review is the human
-- pass, and nothing reaches a client without it.
ALTER TABLE evaluations ADD CONSTRAINT evaluations_complete_ck
  CHECK (lifecycle_state <> 'complete' OR (reviewed_by IS NOT NULL AND completed_at IS NOT NULL));

-- -----------------------------------------------------------------------------
-- observations
--
-- One row per behaviour per evaluation.
--
-- opportunity is the denominator. A behaviour that could not have happened on
-- this call is not a miss — it is simply not counted. Conditional questions
-- already work this way in the live engine, which is why possible_points
-- varies per call, and it is preserved exactly.
--
-- subject_person_id is on the OBSERVATION, not only on the evaluation,
-- because one call scores two people: the receptionist on initial answer,
-- first engagement and hold-and-transfer, the director on everything after.
-- A failed attempt is one where no director was reached, so the receptionist
-- is all there is to score.
--
-- The correction trail is the training signal in both directions. AI error
-- rate per question, and shopper accuracy per shopper, both fall out of
-- keeping the original value beside the corrected one.
-- -----------------------------------------------------------------------------
CREATE TYPE observation_source AS ENUM ('ai', 'shopper', 'reviewer', 'agent', 'import');

-- How far a number derived from this row can be trusted.
--   reviewed      — a human confirmed it. Highest trust.
--   ai_unreviewed — fact-driven fields, no reviewer pass. Error rate unmeasured
--                   for that client. Fine for national fact counts, never for
--                   anything subjective.
--   inferred      — never blended into a confirmed number.
CREATE TYPE assurance_level AS ENUM ('reviewed', 'ai_unreviewed', 'inferred');

CREATE TABLE observations (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id       uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  evaluation_id         uuid NOT NULL REFERENCES evaluations(id) ON DELETE CASCADE,
  behavior_id           uuid NOT NULL REFERENCES behaviors(id) ON DELETE RESTRICT,

  subject_person_id     uuid REFERENCES people(id) ON DELETE SET NULL,

  opportunity           boolean NOT NULL,
  observed              boolean NOT NULL DEFAULT false,

  behavior_answer_id    uuid REFERENCES behavior_answers(id) ON DELETE SET NULL,
  answer_value          text,
  answer_points         numeric(5,2),
  possible_points       numeric(5,2),

  -- Verbatim evidence. A finding without the quote is an assertion.
  quote                 text,
  transcript_offset_s   integer,

  source                observation_source NOT NULL,
  assurance             assurance_level NOT NULL DEFAULT 'reviewed',
  ftc_flag              ftc_flag,

  -- Correction trail. The original survives the correction.
  original_answer_value text,
  original_points       numeric(5,2),
  original_source       observation_source,
  corrected_by          text,
  corrected_at          timestamptz,

  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (evaluation_id, behavior_id)
);
CREATE INDEX observations_eval_idx     ON observations (evaluation_id);
CREATE INDEX observations_behavior_idx ON observations (behavior_id, opportunity);
CREATE INDEX observations_subject_idx  ON observations (subject_person_id);
CREATE INDEX observations_org_idx      ON observations (organization_id);
CREATE TRIGGER observations_touch BEFORE UPDATE ON observations
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- No opportunity means no points either way. This is the denominator rule
-- made unbreakable: a behaviour that could not have happened cannot quietly
-- drag a score down.
ALTER TABLE observations ADD CONSTRAINT observations_opportunity_ck
  CHECK ( opportunity = true
       OR (observed = false AND COALESCE(answer_points,0) = 0
           AND COALESCE(possible_points,0) = 0) );

-- A correction must say who made it.
ALTER TABLE observations ADD CONSTRAINT observations_correction_ck
  CHECK (original_answer_value IS NULL OR (corrected_by IS NOT NULL AND corrected_at IS NOT NULL));

-- The unique index above already stops one question being counted twice in a
-- single evaluation — the defect found in every Altmeyer call, where one
-- question appears twice with the same answer and inflates both sides of the
-- ratio.

-- -----------------------------------------------------------------------------
-- transcript_segments
--
-- Speaker labels with confidence. A table rather than JSONB because the first
-- version of speaker attribution will be wrong sometimes and someone has to
-- be able to correct it.
-- -----------------------------------------------------------------------------
CREATE TABLE transcript_segments (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id       uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  interaction_id        uuid NOT NULL REFERENCES interactions(id) ON DELETE CASCADE,
  segment_order         integer NOT NULL,
  starts_at_s           numeric(8,2),
  ends_at_s             numeric(8,2),
  speaker_label         text,                    -- as the engine produced it
  person_id             uuid REFERENCES people(id) ON DELETE SET NULL,
  contact_id            uuid REFERENCES contacts(id) ON DELETE SET NULL,
  confidence            numeric(4,3),
  corrected_by          text,
  corrected_at          timestamptz,
  body                  text NOT NULL,
  created_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (interaction_id, segment_order)
);
CREATE INDEX transcript_segments_interaction_idx
  ON transcript_segments (interaction_id, segment_order);

-- -----------------------------------------------------------------------------
-- Reporting helpers
-- -----------------------------------------------------------------------------

-- The reframe, as a function. Behaviour counts against opportunity
-- denominators, filtered to completed evaluations only.
CREATE OR REPLACE FUNCTION behavior_rates(
  p_org uuid, p_from date, p_to date, p_source interaction_source DEFAULT NULL)
RETURNS TABLE (
  behavior_code text, label text, section text,
  opportunities bigint, observed bigint, rate numeric
) LANGUAGE sql STABLE AS $$
  SELECT b.code, b.label, s.label,
         count(*) FILTER (WHERE o.opportunity),
         count(*) FILTER (WHERE o.observed),
         round(100.0 * count(*) FILTER (WHERE o.observed)
               / NULLIF(count(*) FILTER (WHERE o.opportunity), 0), 1)
  FROM observations o
  JOIN evaluations e     ON e.id = o.evaluation_id
  JOIN behaviors b       ON b.id = o.behavior_id
  JOIN rubric_sections s ON s.id = b.section_id
  LEFT JOIN interactions i ON i.id = e.interaction_id
  WHERE o.organization_id = p_org
    AND e.lifecycle_state = 'complete'
    AND COALESCE(e.performed_on, e.period_start) BETWEEN p_from AND p_to
    AND (p_source IS NULL OR i.source = p_source)
  GROUP BY b.code, b.label, s.label, s.display_order
  ORDER BY s.display_order, b.code
$$;

-- The composite, reproduced from observations rather than stored. Kept for
-- migration comparison against the existing engine; the professional-level
-- composite is being retired in favour of behaviour rates.
CREATE OR REPLACE FUNCTION composite_score(p_evaluation uuid)
RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT round(100.0 * sum(answer_points) / NULLIF(sum(possible_points), 0), 1)
  FROM observations WHERE evaluation_id = p_evaluation AND opportunity
$$;

-- -----------------------------------------------------------------------------
-- Row-level security
-- -----------------------------------------------------------------------------
ALTER TABLE evaluations         ENABLE ROW LEVEL SECURITY;
ALTER TABLE observations        ENABLE ROW LEVEL SECURITY;
ALTER TABLE transcript_segments ENABLE ROW LEVEL SECURITY;

-- A client sees completed evaluations only. Work in progress is ours until
-- a human has signed it off.
CREATE POLICY evaluations_tenant ON evaluations
  USING (is_internal()
     OR (organization_id = current_organization_id() AND lifecycle_state = 'complete'));

CREATE POLICY observations_tenant ON observations
  USING (is_internal()
     OR (organization_id = current_organization_id()
         AND EXISTS (SELECT 1 FROM evaluations e
                     WHERE e.id = evaluation_id AND e.lifecycle_state = 'complete')));

CREATE POLICY transcript_segments_tenant ON transcript_segments
  USING (is_internal() OR organization_id = current_organization_id());

COMMIT;
