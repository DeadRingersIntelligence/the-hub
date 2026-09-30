-- =============================================================================
-- 010_reporting.sql
-- The Hub — Phase 3, migration 10: benchmarks, periods, report definitions.
--
-- Reports recompute; benchmarks freeze.
--
-- Scoring lives in the query and observations are immutable facts, so
-- improving the model improves every report ever generated and nobody sees
-- the broken version again. But national averages cannot recompute the same
-- way: if the corpus grows all year, a 53% national average becomes a
-- different number in May for reasons that have nothing to do with the
-- client. Client scores improve; the benchmark they were compared against
-- stays pinned to its period.
--
-- Requires: 001 to 009
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- scoring_model_versions
--
-- When a number moves, the reason is attached. Brent answers "why does
-- November look different" with what changed and when, rather than "we fixed
-- it." Cheap to store, and it turns an awkward moment into a credibility one.
--
-- This matters more than it looks: at least one client pays staff
-- compensation on these scores, so a model change is a client conversation
-- before it is an engineering one.
-- -----------------------------------------------------------------------------
CREATE TABLE scoring_model_versions (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version           text NOT NULL UNIQUE,
  effective_from    date NOT NULL,
  summary           text NOT NULL,              -- what changed, in plain words
  detail            text,
  affects_history   boolean NOT NULL DEFAULT true,
  released_by       text,
  created_at        timestamptz NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- benchmark_snapshots
--
-- One row per behaviour per period per location type. Frozen at close.
--
-- location_type rather than client type, because a cemetery must never be
-- compared against pet cremation handling, and a combo firm runs two
-- instruments inside one organization.
--
-- assurance records what went into the number. AI-unreviewed fact detection
-- from passthrough clients is legitimate national data for fact-driven
-- behaviours and must never be blended into anything subjective — a
-- passthrough client has no shopper, so there is nobody to judge tone.
-- -----------------------------------------------------------------------------
CREATE TABLE benchmark_snapshots (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  behavior_id           uuid NOT NULL REFERENCES behaviors(id) ON DELETE CASCADE,
  location_type         location_type,           -- null = all types combined

  period_start          date NOT NULL,
  period_end            date NOT NULL,

  opportunities         integer NOT NULL,
  observed              integer NOT NULL,
  rate                  numeric(5,2) NOT NULL,

  -- How many distinct clients contributed. A benchmark built on two firms is
  -- not a national average, and the number should be visible rather than
  -- implied.
  contributing_orgs     integer NOT NULL,
  assurance             assurance_level NOT NULL DEFAULT 'reviewed',

  scoring_version       text REFERENCES scoring_model_versions(version),
  frozen_at             timestamptz NOT NULL DEFAULT now(),
  UNIQUE (behavior_id, location_type, period_start, period_end, assurance)
);
CREATE INDEX benchmark_snapshots_period_idx
  ON benchmark_snapshots (period_start, period_end);
CREATE INDEX benchmark_snapshots_behavior_idx
  ON benchmark_snapshots (behavior_id);

ALTER TABLE benchmark_snapshots ADD CONSTRAINT benchmark_period_ck
  CHECK (period_end >= period_start);
ALTER TABLE benchmark_snapshots ADD CONSTRAINT benchmark_counts_ck
  CHECK (observed <= opportunities AND opportunities > 0);

-- A benchmark built on one client is that client's own number wearing a
-- national label. Refuse it.
ALTER TABLE benchmark_snapshots ADD CONSTRAINT benchmark_orgs_ck
  CHECK (contributing_orgs >= 3);

-- -----------------------------------------------------------------------------
-- reporting_periods
--
-- A client's month. Closing it is what fires the finalisation email — calls
-- done, behaviours seen, what is consistent with trend, what changed,
-- identified won and lost revenue, then a link into the Hub for anyone who
-- wants to dig.
--
-- Today that is manual and sits on one person's list. Making it a row makes
-- "did they get their month" answerable without asking anyone.
-- -----------------------------------------------------------------------------
CREATE TYPE period_state AS ENUM ('open', 'in_review', 'finalized', 'delivered');

CREATE TABLE reporting_periods (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id       uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  period_start          date NOT NULL,
  period_end            date NOT NULL,
  state                 period_state NOT NULL DEFAULT 'open',

  evaluations_planned   integer,
  evaluations_complete  integer NOT NULL DEFAULT 0,

  -- Handler coverage, reported honestly. Seven of eight operators had first
  -- calls means evaluate seven and say so.
  handlers_eligible     integer,
  handlers_evaluated    integer,

  finalized_at          timestamptz,
  finalized_by          text,
  delivered_at          timestamptz,

  scoring_version       text REFERENCES scoring_model_versions(version),
  notes                 text,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, period_start, period_end)
);
CREATE INDEX reporting_periods_org_idx ON reporting_periods (organization_id, period_start DESC);
CREATE TRIGGER reporting_periods_touch BEFORE UPDATE ON reporting_periods
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE reporting_periods ADD CONSTRAINT reporting_periods_range_ck
  CHECK (period_end >= period_start);

-- Finalising requires a human. Delivery requires finalisation.
ALTER TABLE reporting_periods ADD CONSTRAINT reporting_periods_finalized_ck
  CHECK (state NOT IN ('finalized','delivered')
      OR (finalized_at IS NOT NULL AND finalized_by IS NOT NULL));
ALTER TABLE reporting_periods ADD CONSTRAINT reporting_periods_delivered_ck
  CHECK (state <> 'delivered' OR delivered_at IS NOT NULL);

-- -----------------------------------------------------------------------------
-- report_definitions
--
-- Per client, because one client's report is materially different from the
-- standard and that difference is contractual rather than cosmetic.
--
-- Altmeyer's monthly report carries professional scores only, excluding
-- initial answer, first engagement and hold-and-transfer — the receptionist
-- sections — because they rank professionals quarterly and pay compensation
-- on the result.
-- -----------------------------------------------------------------------------
CREATE TYPE report_audience AS ENUM (
  'owner', 'manager', 'professional', 'coach', 'partner', 'served_firm', 'internal');

CREATE TYPE report_cadence AS ENUM ('monthly', 'quarterly', 'annual', 'on_demand');

CREATE TABLE report_definitions (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id       uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name                  text NOT NULL,
  audience              report_audience NOT NULL,
  cadence               report_cadence NOT NULL DEFAULT 'monthly',

  -- Empty means every section. Otherwise only these.
  include_sections      uuid[] NOT NULL DEFAULT '{}',
  exclude_sections      uuid[] NOT NULL DEFAULT '{}',

  include_benchmarks    boolean NOT NULL DEFAULT true,
  include_revenue       boolean NOT NULL DEFAULT true,
  recipient_emails      text[] NOT NULL DEFAULT '{}',
  notes                 text,
  active                boolean NOT NULL DEFAULT true,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, name)
);
CREATE INDEX report_definitions_org_idx ON report_definitions (organization_id);
CREATE TRIGGER report_definitions_touch BEFORE UPDATE ON report_definitions
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE report_definitions ADD CONSTRAINT report_definitions_sections_ck
  CHECK (cardinality(include_sections) = 0 OR cardinality(exclude_sections) = 0);

-- -----------------------------------------------------------------------------
-- reports — what was actually sent
-- -----------------------------------------------------------------------------
CREATE TABLE reports (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id       uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  report_definition_id  uuid REFERENCES report_definitions(id) ON DELETE SET NULL,
  reporting_period_id   uuid REFERENCES reporting_periods(id) ON DELETE SET NULL,
  audience              report_audience NOT NULL,
  recipient_person_id   uuid REFERENCES people(id) ON DELETE SET NULL,
  recipient_email       text,
  generated_at          timestamptz NOT NULL DEFAULT now(),
  delivered_at          timestamptz,
  url                   text,
  created_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX reports_org_idx    ON reports (organization_id, generated_at DESC);
CREATE INDEX reports_period_idx ON reports (reporting_period_id);

-- -----------------------------------------------------------------------------
-- Row-level security
-- -----------------------------------------------------------------------------
ALTER TABLE reporting_periods     ENABLE ROW LEVEL SECURITY;
ALTER TABLE report_definitions    ENABLE ROW LEVEL SECURITY;
ALTER TABLE reports               ENABLE ROW LEVEL SECURITY;
ALTER TABLE benchmark_snapshots   ENABLE ROW LEVEL SECURITY;
ALTER TABLE scoring_model_versions ENABLE ROW LEVEL SECURITY;

CREATE POLICY reporting_periods_tenant ON reporting_periods
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY report_definitions_tenant ON report_definitions
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY reports_tenant ON reports
  USING (is_internal() OR organization_id = current_organization_id());

-- Benchmarks and model versions are readable by everyone. A client seeing the
-- national number they are compared against, and what changed in the model
-- that produced their score, is correct.
CREATE POLICY benchmark_snapshots_readable   ON benchmark_snapshots   USING (true);
CREATE POLICY scoring_model_versions_readable ON scoring_model_versions USING (true);

COMMIT;
