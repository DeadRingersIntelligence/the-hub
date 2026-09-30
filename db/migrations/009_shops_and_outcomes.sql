-- =============================================================================
-- 009_shops_and_outcomes.sql
-- The Hub — Phase 3, migration 9: shops, shopper forms, outcomes, entitlements.
--
-- A shop is an ASSIGNMENT. A call is an INTERACTION. One shop produces
-- several interactions — attempts, callbacks, transfers — and the current
-- dashboard shows only the last one, which buries the most damning finding.
-- Ten Legacy shops took thirty attempts, and that is how they learned 80% of
-- their calls were not connecting.
--
-- Shop Management Magic stays in Zoho Creator as the operations tool. Creator
-- owns decisions — batch creation, number eligibility, shopper rotation, the
-- staff roster. This file records what Creator decided. Two systems computing
-- the same rule will disagree within a month.
--
-- Requires: 001 to 008
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- shops
--
-- Who gets shopped is a business rule, not a schema one: non-HelloPhone
-- clients are shopped because there is no other way to hear their calls;
-- HelloPhone clients get real-call evaluation instead. Shopping a HelloPhone
-- client is a paid add-on, not the norm.
--
-- A shop and a real call remain the same entity graph either way. A shop call
-- creates a contact and a decedent in the client's system exactly like a real
-- one, so the client can see the prior interaction and call back before the
-- shopper's second attempt — losing that loses half of what a shop measures.
-- Only the COUNTING differs, and interactions.source is what does it.
-- -----------------------------------------------------------------------------
CREATE TYPE shop_status AS ENUM (
  'draft', 'ready_to_publish', 'published', 'in_progress',
  'complete', 'needs_recall', 'canceled');

CREATE TABLE shops (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id           uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
  location_id               uuid REFERENCES locations(id) ON DELETE SET NULL,

  -- Creator's identifier, so a shop can be reconciled back to operations.
  external_ref              text,

  shopper_person_id         uuid REFERENCES people(id) ON DELETE SET NULL,
  staff_person_requested_id uuid REFERENCES people(id) ON DELETE SET NULL,

  -- Known before the call is placed, from the script. No inference needed.
  need_type                 case_need_type,
  script_name               text,
  service_type              text,
  language                  text NOT NULL DEFAULT 'en',

  assigned_date             date,
  due_date                  date,
  published_at              timestamptz,
  scheduling_constraints    text,

  status                    shop_status NOT NULL DEFAULT 'draft',

  -- Rolls up to location and client. "146 shops took 360 attempts" is a
  -- deliverable, and it is invisible today.
  attempts_required         smallint NOT NULL DEFAULT 0,
  reached_director          boolean,

  canceled_reason           text,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX shops_org_status_idx ON shops (organization_id, status);
CREATE INDEX shops_location_idx   ON shops (location_id, assigned_date);
CREATE INDEX shops_external_idx   ON shops (external_ref);
CREATE TRIGGER shops_touch BEFORE UPDATE ON shops
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE shops ADD CONSTRAINT shops_canceled_ck
  CHECK (status <> 'canceled' OR canceled_reason IS NOT NULL);

-- One shop, many interactions, numbered. A failed attempt is one where no
-- director was reached; a complete shop is one where contact was made.
CREATE TABLE shop_interactions (
  shop_id           uuid NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  interaction_id    uuid NOT NULL REFERENCES interactions(id) ON DELETE CASCADE,
  attempt_number    smallint NOT NULL,
  is_primary        boolean NOT NULL DEFAULT false,   -- the fully scored call
  PRIMARY KEY (shop_id, interaction_id),
  UNIQUE (shop_id, attempt_number)
);
CREATE INDEX shop_interactions_interaction_idx ON shop_interactions (interaction_id);

-- -----------------------------------------------------------------------------
-- shopper_forms
--
-- Structured, never free text. The closing question is the outcome field:
-- "would you choose this firm if you had a loved one who passed away?"
-- Yes means won revenue. Maybe or no means lost.
--
-- staff_person_id comes from a dropdown populated with the roster for that
-- location — not typed. Three spellings of Tanya produce three separate
-- reports and a silent aggregation failure.
-- -----------------------------------------------------------------------------
CREATE TYPE would_hire AS ENUM ('yes', 'maybe', 'no');

CREATE TABLE shopper_forms (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id       uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  shop_id               uuid NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  interaction_id        uuid REFERENCES interactions(id) ON DELETE SET NULL,

  -- Resolved from the roster. Null with a name recorded means the shopper
  -- met someone not yet on it, which flags for review.
  staff_person_id       uuid REFERENCES people(id) ON DELETE SET NULL,
  staff_name_heard      text,
  no_name_provided      boolean NOT NULL DEFAULT false,
  shopper_failed_to_ask boolean NOT NULL DEFAULT false,

  would_hire            would_hire,
  impressions           text,
  submitted_at          timestamptz NOT NULL DEFAULT now(),
  created_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (shop_id)
);
CREATE INDEX shopper_forms_shop_idx ON shopper_forms (shop_id);

-- Someone not introducing themselves is a finding about the firm. The shopper
-- failing to ask is a separate finding about the shopper. Both are real, and
-- they are not the same thing — so one cannot be recorded as the other.
ALTER TABLE shopper_forms ADD CONSTRAINT shopper_forms_name_ck
  CHECK ( no_name_provided = false
       OR (staff_person_id IS NULL AND staff_name_heard IS NULL) );

-- -----------------------------------------------------------------------------
-- outcomes
--
-- Lost revenue anchors on the FIRST price quoted on the call. Not an average,
-- not a later quote in the same conversation. A call that never reached a
-- price gets the client's own average lost-call value, stamped as imputed —
-- so a report can always separate what was actually quoted from what was
-- estimated.
--
-- Won revenue is the actual case value where writeback provides it. The gap
-- between $2,995 quoted and $4,200 closed is not an error to reconcile: it is
-- a finding. Either the phone quoted the cheapest option without asking what
-- the family wanted, or the in-person team recovered it. Both are coachable,
-- and both are invisible unless the schema keeps both numbers.
-- -----------------------------------------------------------------------------
CREATE TYPE outcome_type AS ENUM ('won', 'lost', 'unknown', 'not_applicable');

CREATE TYPE valuation_method AS ENUM (
  'actual_case_value',    -- writeback from the client's system
  'first_price_quoted',   -- the anchor for lost calls
  'client_average',       -- imputed, because no price was ever given
  'unvalued');

CREATE TABLE outcomes (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id       uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,

  interaction_id        uuid REFERENCES interactions(id) ON DELETE CASCADE,
  shop_id               uuid REFERENCES shops(id) ON DELETE CASCADE,
  case_id               uuid REFERENCES cases(id) ON DELETE SET NULL,

  outcome_type          outcome_type NOT NULL,
  revenue_amount        numeric(12,2),
  valuation_method      valuation_method NOT NULL,

  -- Kept beside the actual value rather than replaced by it.
  first_quoted_amount   numeric(12,2),

  source_system         text,
  determined_at         timestamptz NOT NULL DEFAULT now(),
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX outcomes_org_idx         ON outcomes (organization_id, determined_at);
CREATE INDEX outcomes_interaction_idx ON outcomes (interaction_id);
CREATE INDEX outcomes_case_idx        ON outcomes (case_id);
CREATE TRIGGER outcomes_touch BEFORE UPDATE ON outcomes
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE outcomes ADD CONSTRAINT outcomes_scope_ck
  CHECK (num_nonnulls(interaction_id, shop_id) >= 1);

-- A valued outcome must carry an amount, and an unvalued one must not.
ALTER TABLE outcomes ADD CONSTRAINT outcomes_amount_ck
  CHECK ( (valuation_method = 'unvalued' AND revenue_amount IS NULL)
       OR (valuation_method <> 'unvalued' AND revenue_amount IS NOT NULL) );

-- Won revenue must come from the client's system or from a shopper's
-- judgment on a shop. It can never be imputed from an average.
ALTER TABLE outcomes ADD CONSTRAINT outcomes_won_ck
  CHECK (outcome_type <> 'won' OR valuation_method <> 'client_average');

-- -----------------------------------------------------------------------------
-- client_entitlements
--
-- Clients buy a set number of evaluations. The team selects from calls
-- bucketed as researcher or first-call, then distributes across handlers to
-- get a fixed number per person.
--
-- Coverage is reported honestly: seven of eight operators had first calls
-- means evaluate seven and tell the client the eighth had none. Someone who
-- never takes a first call is worth a conversation, not a gap to hide.
-- -----------------------------------------------------------------------------
CREATE TYPE entitlement_kind AS ENUM (
  'evaluations', 'ftc_audits', 'shops', 'coaching_hours', 'training_sessions');

CREATE TABLE client_entitlements (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  entitlement_kind  entitlement_kind NOT NULL,
  period_start      date NOT NULL,
  period_end        date NOT NULL,
  purchased_qty     numeric(8,2) NOT NULL,
  notes             text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, entitlement_kind, period_start)
);
CREATE INDEX client_entitlements_org_idx ON client_entitlements (organization_id);
CREATE TRIGGER client_entitlements_touch BEFORE UPDATE ON client_entitlements
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
ALTER TABLE client_entitlements ADD CONSTRAINT client_entitlements_period_ck
  CHECK (period_end >= period_start);

-- -----------------------------------------------------------------------------
-- Reporting helpers
-- -----------------------------------------------------------------------------

-- Attempts required, rolled up. The number that is invisible today.
CREATE OR REPLACE FUNCTION shop_attempts(p_org uuid, p_from date, p_to date)
RETURNS TABLE (shops bigint, attempts bigint, avg_attempts numeric) LANGUAGE sql STABLE AS $$
  SELECT count(*), COALESCE(sum(attempts_required), 0),
         round(AVG(NULLIF(attempts_required, 0)), 2)
  FROM shops
  WHERE organization_id = p_org
    AND status = 'complete'
    AND assigned_date BETWEEN p_from AND p_to
$$;

-- Price consistency: the same service quoted at different figures across a
-- location and period, with nobody explaining the difference. This is the
-- most time-intensive part of an FTC audit today, done by a reviewer
-- listening back across calls.
CREATE OR REPLACE FUNCTION price_variance(p_org uuid, p_from date, p_to date)
RETURNS TABLE (
  location_name text, service_type text, quotes bigint,
  low numeric, high numeric, spread numeric
) LANGUAGE sql STABLE AS $$
  SELECT l.name, q.service_type, count(*),
         min(q.amount), max(q.amount), max(q.amount) - min(q.amount)
  FROM price_quotes q
  JOIN interactions i ON i.id = q.interaction_id
  LEFT JOIN locations l ON l.id = i.location_id
  WHERE q.organization_id = p_org
    AND q.service_type IS NOT NULL
    AND q.amount IS NOT NULL
    AND i.occurred_at::date BETWEEN p_from AND p_to
  GROUP BY l.name, q.service_type
  HAVING count(*) > 1 AND max(q.amount) > min(q.amount)
  ORDER BY (max(q.amount) - min(q.amount)) DESC
$$;

-- -----------------------------------------------------------------------------
-- Row-level security
--
-- Shops are visible to the client at a summary level while in progress —
-- scheduled counts and an in-progress marker, so they know the work is
-- happening. Scores stay invisible until the evaluation is complete, which
-- migration 008 already enforces.
-- -----------------------------------------------------------------------------
ALTER TABLE shops               ENABLE ROW LEVEL SECURITY;
ALTER TABLE shop_interactions   ENABLE ROW LEVEL SECURITY;
ALTER TABLE shopper_forms       ENABLE ROW LEVEL SECURITY;
ALTER TABLE outcomes            ENABLE ROW LEVEL SECURITY;
ALTER TABLE client_entitlements ENABLE ROW LEVEL SECURITY;

CREATE POLICY shops_tenant ON shops
  USING (is_internal() OR organization_id = current_organization_id());

CREATE POLICY outcomes_tenant ON outcomes
  USING (is_internal() OR organization_id = current_organization_id());

CREATE POLICY client_entitlements_tenant ON client_entitlements
  USING (is_internal() OR organization_id = current_organization_id());

-- The shopper's own form is internal. A client never sees the shopper's
-- working notes, only the evaluation that results from them.
CREATE POLICY shopper_forms_internal ON shopper_forms
  USING (is_internal());

CREATE POLICY shop_interactions_tenant ON shop_interactions
  USING (is_internal() OR EXISTS (
    SELECT 1 FROM shops s WHERE s.id = shop_id
      AND s.organization_id = current_organization_id()));

COMMIT;
