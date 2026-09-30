-- =============================================================================
-- 023_money_and_audit.sql
-- The Hub — Phase 2, migration 23: cost attribution, what a client pays, and
-- who touched what.
--
-- BILLING IS NOT HERE. Zoho Books is the biller, every client is on autopay,
-- pricing is per-seat plus service fees. Nothing in this file produces an
-- invoice or a billable total.
--
-- What it does produce is margin. Dial Stack bills Dead Ringers per seat plus
-- regulatory pass-throughs; AI, storage and telephony all cost something per
-- client. Recording cost when it is incurred, attributed to the client that
-- caused it, makes P&L by customer a group-by rather than a spreadsheet — and
-- at zero margin on telecom, a small discrepancy is a straight loss.
--
-- Requires: 001 to 022
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- cost_events
--
-- Record cost when incurred, attributed to the client. Optionally linked to the
-- interaction or evaluation that caused it, which is what makes AI spend
-- traceable to the call that triggered it rather than a monthly lump.
-- -----------------------------------------------------------------------------
CREATE TYPE cost_vendor AS ENUM (
  'dial_stack', 'surge', 'ctm', 'ai', 'storage', 'hosting', 'thinkific', 'other');

CREATE TYPE cost_kind AS ENUM (
  'seat', 'phone_number', 'usage_minutes', 'usage_messages', 'regulatory_fee',
  'ai_transcription', 'ai_evaluation', 'recording_storage', 'platform', 'other');

CREATE TABLE cost_events (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
  account_id        uuid REFERENCES accounts(id) ON DELETE SET NULL,

  -- Location and group so a per-state or per-market cost roll-up is a
  -- group-by rather than a manual split at invoice time.
  location_id       uuid REFERENCES locations(id) ON DELETE SET NULL,
  location_group_id uuid REFERENCES location_groups(id) ON DELETE SET NULL,

  vendor            cost_vendor NOT NULL,
  cost_kind         cost_kind NOT NULL,

  quantity          numeric(12,4) NOT NULL DEFAULT 1,
  unit_cost         numeric(12,6),
  total_cost        numeric(12,4) NOT NULL,
  currency          char(3) NOT NULL DEFAULT 'USD',

  -- What caused it.
  interaction_id    uuid REFERENCES interactions(id) ON DELETE SET NULL,
  evaluation_id     uuid REFERENCES evaluations(id) ON DELETE SET NULL,
  phone_number_id   uuid REFERENCES phone_numbers(id) ON DELETE SET NULL,

  incurred_at       timestamptz NOT NULL DEFAULT now(),
  period_start      date,
  period_end        date,
  external_ref      text,
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX cost_events_org_time_idx  ON cost_events (organization_id, incurred_at DESC);
CREATE INDEX cost_events_vendor_idx    ON cost_events (vendor, incurred_at DESC);
CREATE INDEX cost_events_group_idx     ON cost_events (location_group_id, incurred_at DESC);
CREATE INDEX cost_events_interaction_idx ON cost_events (interaction_id);

ALTER TABLE cost_events ADD CONSTRAINT cost_events_period_ck
  CHECK (period_end IS NULL OR period_start IS NULL OR period_end >= period_start);

-- -----------------------------------------------------------------------------
-- subscriptions and rate_cards
--
-- What a client pays, held here only so margin can be computed. Zoho Books
-- remains the system of record for money; this is a copy kept deliberately
-- thin — enough to answer "is this client profitable", not enough to invoice
-- from, because two systems that can both bill will eventually disagree.
-- -----------------------------------------------------------------------------
CREATE TYPE subscription_kind AS ENUM (
  'growth_plan', 'hellophone', 'cxpertise', 'ftc_audit', 'shops', 'other');

CREATE TABLE subscriptions (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  account_id        uuid REFERENCES accounts(id) ON DELETE SET NULL,

  subscription_kind subscription_kind NOT NULL,
  monthly_amount    numeric(12,2) NOT NULL,
  currency          char(3) NOT NULL DEFAULT 'USD',

  starts_on         date NOT NULL,
  ends_on           date,

  -- Where Books holds the real thing.
  external_ref      text,
  notes             text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX subscriptions_org_idx ON subscriptions (organization_id, starts_on DESC);
CREATE TRIGGER subscriptions_touch BEFORE UPDATE ON subscriptions
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE subscriptions ADD CONSTRAINT subscriptions_dates_ck
  CHECK (ends_on IS NULL OR ends_on >= starts_on);

-- Per-account pricing. Dial Stack allows one account at $12 a seat and another
-- at $25, because one bought the bundle and the other did not.
CREATE TABLE rate_cards (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  account_id        uuid REFERENCES accounts(id) ON DELETE CASCADE,

  per_seat          numeric(10,2),
  per_number        numeric(10,2),
  included_seats    smallint,
  included_numbers  smallint,
  platform_fee      numeric(10,2),

  effective_from    date NOT NULL DEFAULT current_date,
  effective_to      date,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX rate_cards_org_idx ON rate_cards (organization_id, effective_from DESC);
CREATE TRIGGER rate_cards_touch BEFORE UPDATE ON rate_cards
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE rate_cards ADD CONSTRAINT rate_cards_dates_ck
  CHECK (effective_to IS NULL OR effective_to >= effective_from);

-- Margin for a period: what they pay, less what they cost.
CREATE OR REPLACE FUNCTION client_margin(p_org uuid, p_from date, p_to date)
RETURNS TABLE (revenue numeric, cost numeric, margin numeric, margin_pct numeric)
LANGUAGE sql STABLE AS $$
  WITH rev AS (
    SELECT COALESCE(SUM(monthly_amount), 0) AS amount
    FROM subscriptions
    WHERE organization_id = p_org
      AND starts_on <= p_to
      AND (ends_on IS NULL OR ends_on >= p_from)
  ), cst AS (
    SELECT COALESCE(SUM(total_cost), 0) AS amount
    FROM cost_events
    WHERE organization_id = p_org
      AND incurred_at::date BETWEEN p_from AND p_to
  )
  SELECT rev.amount, cst.amount, rev.amount - cst.amount,
         CASE WHEN rev.amount > 0
              THEN round(100.0 * (rev.amount - cst.amount) / rev.amount, 1) END
  FROM rev, cst
$$;

-- -----------------------------------------------------------------------------
-- audit_log
--
-- Not change_history. Change history is what an agent reads mid-call — how did
-- this record get this way. This is what a security review asks for: who saw
-- or altered client call recordings and family information, and when.
--
-- Different readers, different retention, and one of them should never appear
-- on a family-facing screen.
-- -----------------------------------------------------------------------------
CREATE TYPE audit_action AS ENUM (
  'viewed', 'listened', 'downloaded', 'exported', 'created', 'updated',
  'deleted', 'login', 'permission_changed');

CREATE TABLE audit_log (
  id                bigserial PRIMARY KEY,
  organization_id   uuid REFERENCES organizations(id) ON DELETE SET NULL,
  user_id           uuid REFERENCES users(id) ON DELETE SET NULL,
  actor_label       text NOT NULL,

  action            audit_action NOT NULL,
  entity            text NOT NULL,             -- table name, kept loose on purpose
  entity_id         uuid,

  ip_address        inet,
  user_agent        text,
  detail            jsonb NOT NULL DEFAULT '{}'::jsonb,
  occurred_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_log_org_time_idx  ON audit_log (organization_id, occurred_at DESC);
CREATE INDEX audit_log_user_time_idx ON audit_log (user_id, occurred_at DESC);
CREATE INDEX audit_log_entity_idx    ON audit_log (entity, entity_id);

-- -----------------------------------------------------------------------------
-- Row-level security
--
-- Cost and pricing are Dead Ringers' own. A client seeing what they cost to
-- serve is a conversation, not a dashboard — so these stay internal.
-- -----------------------------------------------------------------------------
ALTER TABLE cost_events    ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscriptions  ENABLE ROW LEVEL SECURITY;
ALTER TABLE rate_cards     ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log      ENABLE ROW LEVEL SECURITY;

CREATE POLICY cost_events_internal   ON cost_events   USING (is_internal());
CREATE POLICY subscriptions_internal ON subscriptions USING (is_internal());
CREATE POLICY rate_cards_internal    ON rate_cards    USING (is_internal());
CREATE POLICY audit_log_internal     ON audit_log     USING (is_internal());

COMMIT;

-- =============================================================================
-- Verification
--
--   SET app.is_internal = 'on';
--
--   INSERT INTO subscriptions (organization_id, subscription_kind, monthly_amount, starts_on)
--   SELECT id, 'growth_plan', 1500.00, '2026-01-01' FROM organizations WHERE code='ALT';
--
--   INSERT INTO cost_events (organization_id, vendor, cost_kind, quantity, total_cost)
--   SELECT id, 'ai', 'ai_evaluation', 12, 43.20 FROM organizations WHERE code='ALT';
--
--   SELECT * FROM client_margin(
--     (SELECT id FROM organizations WHERE code='ALT'), '2026-09-01', '2026-09-30');
--
--   -- a client session must not see cost
--   SET app.is_internal = 'off';
--   SET app.organization_id = (SELECT id::text FROM organizations WHERE code='ALT');
--   SELECT count(*) FROM cost_events;     -- expect 0
-- =============================================================================
