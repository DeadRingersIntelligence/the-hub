-- =============================================================================
-- 007_behaviors_and_rubrics.sql
-- The Hub — Phase 3, migration 7: the scoring instrument.
--
-- `behaviors` is the actual intellectual property. Everything else in this
-- file exists to say which behaviors a client is measured on, what an answer
-- is worth, and who answers it.
--
-- Three rules shape it:
--
--   Behaviors are universal. Every behavior is national from creation. Two
--   clients independently asking for the same thing is how national data
--   starts accumulating — nothing is siloed, so nothing needs retroactive
--   promotion. "Promoting" a behavior means deciding it has enough volume to
--   display on more dashboards.
--
--   Applicability keys on LOCATION type, not client type. Client type is too
--   coarse: the Diocese of Phoenix is one organization running two
--   instruments inside it, and a cemetery must never be scored on pet
--   cremation handling.
--
--   Sections are a table, not a text column. The live data and the rubric
--   lookup currently disagree — INITIAL ANSWER and FIRST ENGAGEMENT separate
--   in one, "Initial Answer/First Engagement" merged in the other, casing
--   different throughout. Any join on section silently fails. One row per
--   section, referenced by id, ends that.
--
-- Requires: 001 to 006
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- rubric_sections
--
-- Objective is eight sections. Impression is a category with four
-- subsections. The handoff's "8 categories" was counting only objective,
-- which is why three different point totals have been circulating.
-- -----------------------------------------------------------------------------
CREATE TYPE score_category AS ENUM ('objective', 'impression');

CREATE TABLE rubric_sections (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code              text NOT NULL UNIQUE,
  label             text NOT NULL,
  score_category    score_category NOT NULL,
  display_order     smallint NOT NULL,
  created_at        timestamptz NOT NULL DEFAULT now()
);

INSERT INTO rubric_sections (code, label, score_category, display_order) VALUES
  ('initial_answer',    'Initial Answer',     'objective',  1),
  ('first_engagement',  'First Engagement',   'objective',  2),
  ('hold_transfer',     'Hold & Transfer',    'objective',  3),
  ('lead_information',  'Lead Information',   'objective',  4),
  ('services_pricing',  'Services & Pricing', 'objective',  5),
  ('etiquette',         'Etiquette',          'objective',  6),
  ('closing',           'Closing',            'objective',  7),
  ('follow_up',         'Follow-Up',          'objective',  8),
  ('accessibility',     'Accessibility',      'impression', 9),
  ('clarity',           'Clarity',            'impression', 10),
  ('sincerity',         'Sincerity',          'impression', 11),
  ('buy_in',            'Buy-In',             'impression', 12);

-- -----------------------------------------------------------------------------
-- behaviors
--
-- The shared library. One row per thing Dead Ringers can detect on a call.
--
-- answered_by carries the division that already exists in the live data:
-- objective questions come from the reviewer form, impression questions from
-- CTM where the shopper enters them. AI owns fact-driven detection. The
-- reviewer sees both and corrects.
--
-- display_from is what "promotion" means — the date a behavior became worth
-- showing on dashboards. It never changes what was collected, only what is
-- shown, because the behavior was gathering national data from day one.
-- -----------------------------------------------------------------------------
CREATE TYPE answered_by AS ENUM ('ai', 'shopper', 'reviewer', 'agent');

CREATE TABLE behaviors (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code              text NOT NULL UNIQUE,
  label             text NOT NULL,              -- the question as asked
  short_label       text,                       -- for dashboards
  section_id        uuid NOT NULL REFERENCES rubric_sections(id) ON DELETE RESTRICT,
  score_category    score_category NOT NULL,

  -- Which kinds of site this behavior can apply to. Empty means all.
  applies_to_types  location_type[] NOT NULL DEFAULT '{}',

  answered_by       answered_by NOT NULL,

  -- Origin, for the record. A behavior invented by one client is still
  -- national from creation; this only says who asked first.
  originated_by_org uuid REFERENCES organizations(id) ON DELETE SET NULL,
  display_from      date,

  active            boolean NOT NULL DEFAULT true,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX behaviors_section_idx ON behaviors (section_id);
CREATE INDEX behaviors_types_idx   ON behaviors USING gin (applies_to_types);
CREATE TRIGGER behaviors_touch BEFORE UPDATE ON behaviors
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- A behavior's category must match its section's.
CREATE OR REPLACE FUNCTION behaviors_category_matches() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM rubric_sections s
                 WHERE s.id = NEW.section_id AND s.score_category = NEW.score_category)
  THEN RAISE EXCEPTION 'behavior category does not match its section'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER behaviors_category_ck BEFORE INSERT OR UPDATE ON behaviors
  FOR EACH ROW EXECUTE FUNCTION behaviors_category_matches();

-- Does this behavior apply at this kind of site.
CREATE OR REPLACE FUNCTION behavior_applies(b uuid, lt location_type)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT cardinality(applies_to_types) = 0 OR lt = ANY(applies_to_types)
  FROM behaviors WHERE id = b
$$;

-- -----------------------------------------------------------------------------
-- behavior_answers
--
-- The answer options and what each is worth. Points live on the OPTION, not
-- on the question, which is how conditional scoring already works.
--
-- ftc_flag is the Funeral Rule severity carried by an individual answer:
--   red    — a clear, direct violation. Price requested, never given.
--   yellow — survivable, but you would be dinged if it were the FTC calling
--            instead of us. Train to it.
--   gray   — probably fine. Best practice says do it differently.
--
-- The verdict is therefore a formula over answered questions, not a judgment.
-- AI answers facts, the flag computes, and no AI verdict is ever stored.
-- -----------------------------------------------------------------------------
CREATE TYPE ftc_flag AS ENUM ('red', 'yellow', 'gray');

CREATE TABLE behavior_answers (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  behavior_id       uuid NOT NULL REFERENCES behaviors(id) ON DELETE CASCADE,
  answer_value      text NOT NULL,
  points            numeric(5,2) NOT NULL DEFAULT 0,

  -- Does selecting this answer mean the behavior was observed. Kept separate
  -- from points because a partially credited answer is still an observation.
  counts_as_observed boolean NOT NULL DEFAULT false,

  ftc_flag          ftc_flag,
  display_order     smallint,
  active            boolean NOT NULL DEFAULT true,
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (behavior_id, answer_value)
);
CREATE INDEX behavior_answers_behavior_idx ON behavior_answers (behavior_id);

-- -----------------------------------------------------------------------------
-- rubric_templates and rubrics
--
-- A template is the Dead Ringers standard, versioned. A rubric is a client's
-- actual instrument, derived from a template with additions and removals.
--
-- rubric_type separates the CX instrument from the FTC audit, which is a
-- separate evaluation priced separately — but reads shared observations,
-- because most FTC-feeding behaviors (how pricing was given, exact versus
-- range, what was included, whether options were offered) are already in the
-- CX rubric and should be answered once.
-- -----------------------------------------------------------------------------
CREATE TYPE rubric_type AS ENUM ('cx', 'ftc');

CREATE TABLE rubric_templates (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name              text NOT NULL,
  rubric_type       rubric_type NOT NULL DEFAULT 'cx',
  version           text NOT NULL,
  effective_from    date NOT NULL DEFAULT current_date,
  notes             text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (name, version)
);

CREATE TABLE rubrics (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id       uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  rubric_template_id    uuid REFERENCES rubric_templates(id) ON DELETE SET NULL,
  name                  text NOT NULL,
  rubric_type           rubric_type NOT NULL DEFAULT 'cx',
  version               text NOT NULL,

  -- Null means the rubric applies at every site in the organization. Set it
  -- to run a different instrument at a funeral home than at its cemeteries.
  applies_to_type       location_type,

  effective_from        date NOT NULL DEFAULT current_date,
  effective_to          date,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, name, version)
);
CREATE INDEX rubrics_org_idx ON rubrics (organization_id, rubric_type);
CREATE TRIGGER rubrics_touch BEFORE UPDATE ON rubrics
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- An FTC rubric cannot be pointed at a cemetery. The Funeral Rule applies to
-- funeral homes, discount cremation providers, and combo sites — cemetery is
-- the only exclusion, and it is coded as the exclusion so a location type
-- added later inherits the right default.
ALTER TABLE rubrics ADD CONSTRAINT rubrics_ftc_not_cemetery_ck
  CHECK (rubric_type <> 'ftc' OR applies_to_type IS DISTINCT FROM 'cemetery');

-- -----------------------------------------------------------------------------
-- rubric_behaviors
--
-- Which behaviors are in which rubric, what each is worth there, and who
-- answers it.
--
-- possible_points is stored per rubric rather than per behavior because it is
-- already acting as a per-question denominator in the live engine, and the
-- conditional logic depends on it. It is also versioned WITH the rubric, so a
-- question moving from shopper to AI next year leaves old evaluations
-- readable exactly as they were scored.
--
-- display controls whether a behavior appears on the client's dashboard.
-- Collection is universal; display is the thing that varies.
-- -----------------------------------------------------------------------------
CREATE TABLE rubric_behaviors (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rubric_id         uuid NOT NULL REFERENCES rubrics(id) ON DELETE CASCADE,
  behavior_id       uuid NOT NULL REFERENCES behaviors(id) ON DELETE RESTRICT,

  possible_points   numeric(5,2) NOT NULL,
  answered_by       answered_by NOT NULL,
  display_order     smallint,
  display           boolean NOT NULL DEFAULT true,

  -- When a behavior is only in play under some conditions. The denominator
  -- is opportunity-based, so a question that did not apply is not a miss.
  conditional_on    text,

  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (rubric_id, behavior_id)
);
CREATE INDEX rubric_behaviors_rubric_idx ON rubric_behaviors (rubric_id);

-- -----------------------------------------------------------------------------
-- focus_behaviors
--
-- The handful surfaced at the top of a professional's profile. Set by the
-- client or by a coach — and which one matters, so it is stored.
-- -----------------------------------------------------------------------------
CREATE TYPE focus_source AS ENUM ('client', 'coach', 'system');

CREATE TABLE focus_behaviors (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  behavior_id       uuid NOT NULL REFERENCES behaviors(id) ON DELETE CASCADE,

  -- Null person means it applies to everyone in the organization.
  person_id         uuid REFERENCES people(id) ON DELETE CASCADE,
  location_id       uuid REFERENCES locations(id) ON DELETE CASCADE,

  focus_source      focus_source NOT NULL,
  set_by            text,
  starts_on         date NOT NULL DEFAULT current_date,
  ends_on           date,
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX focus_behaviors_org_idx    ON focus_behaviors (organization_id);
CREATE INDEX focus_behaviors_person_idx ON focus_behaviors (person_id);

-- -----------------------------------------------------------------------------
-- Row-level security
--
-- The behavior library, sections, answer options and templates are Dead
-- Ringers' own and are readable by every tenant — a client seeing the
-- definition of a behavior they are measured on is correct. Their own rubric
-- and focus behaviors are tenant-scoped.
-- -----------------------------------------------------------------------------
ALTER TABLE rubrics          ENABLE ROW LEVEL SECURITY;
ALTER TABLE rubric_behaviors ENABLE ROW LEVEL SECURITY;
ALTER TABLE focus_behaviors  ENABLE ROW LEVEL SECURITY;
ALTER TABLE behaviors        ENABLE ROW LEVEL SECURITY;
ALTER TABLE behavior_answers ENABLE ROW LEVEL SECURITY;
ALTER TABLE rubric_sections  ENABLE ROW LEVEL SECURITY;
ALTER TABLE rubric_templates ENABLE ROW LEVEL SECURITY;

CREATE POLICY rubrics_tenant ON rubrics
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY focus_behaviors_tenant ON focus_behaviors
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY rubric_behaviors_tenant ON rubric_behaviors
  USING (is_internal() OR EXISTS (
    SELECT 1 FROM rubrics r WHERE r.id = rubric_id
      AND r.organization_id = current_organization_id()));

CREATE POLICY behaviors_readable        ON behaviors        USING (true);
CREATE POLICY behavior_answers_readable ON behavior_answers USING (true);
CREATE POLICY rubric_sections_readable  ON rubric_sections  USING (true);
CREATE POLICY rubric_templates_readable ON rubric_templates USING (true);

COMMIT;
