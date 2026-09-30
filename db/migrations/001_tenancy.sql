-- =============================================================================
-- 001_tenancy.sql
-- The Hub — Phase 1, migration 1 of 6: the tenancy spine
--
-- Rule 8: multi-tenant from row one. organization_id on every table, RLS in
-- the database rather than in application code. This file establishes the
-- mechanism that every later migration inherits.
--
-- Run: psql -f db/migrations/001_tenancy.sql
-- =============================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS "pgcrypto";   -- gen_random_uuid()

-- -----------------------------------------------------------------------------
-- Tenant context
--
-- Every session sets app.organization_id. RLS policies read it. A session that
-- sets nothing sees nothing, which is the safe default: a forgotten SET is an
-- empty result rather than a cross-tenant leak.
--
-- app.is_internal = 'on' lifts the restriction for Dead Ringers staff and for
-- migrations. Partner access is granted per organization in 003 and is not a
-- blanket override.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION current_organization_id() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.organization_id', true), '')::uuid
$$;

CREATE OR REPLACE FUNCTION is_internal() RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(current_setting('app.is_internal', true), 'off') = 'on'
$$;

-- updated_at maintenance, reused by every table from here on
CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END $$;

-- -----------------------------------------------------------------------------
-- Enumerations
--
-- client_type describes the organization. location_type describes a single
-- site, and they are deliberately independent: the Diocese of Phoenix is one
-- organization holding cemeteries and a funeral home, and Altmeyer holds
-- funeral homes and cremation providers. Scoring splits on location_type.
-- -----------------------------------------------------------------------------
CREATE TYPE client_type AS ENUM (
  'funeral_home', 'cemetery', 'cremation', 'pet', 'combo',
  'answering_service', 'internal');

CREATE TYPE location_type AS ENUM (
  'funeral_home', 'cemetery', 'cremation', 'pet', 'combo', 'transportation');

CREATE TYPE organization_status AS ENUM (
  'prospect', 'active', 'paused', 'former');

-- -----------------------------------------------------------------------------
-- organizations
-- -----------------------------------------------------------------------------
CREATE TABLE organizations (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code              text UNIQUE,                    -- 'ALT', 'DPX', 'PPD'
  name              text NOT NULL,
  client_type       client_type NOT NULL,
  status            organization_status NOT NULL DEFAULT 'active',

  -- Referrer: who sent them. Visible to Dead Ringers management only.
  -- No referral revenue today; the field exists so thanking people properly
  -- is a query and a payout mechanism is a decision rather than a migration.
  referrer_name     text,
  referred_on       date,

  -- Weak link asserting two records are the same real-world firm across
  -- organizations, for reporting and sales. Deliberately NOT a foreign key
  -- join: a served firm under an answering service must never see, or be
  -- joined to, its own data held by that answering service.
  firm_identity     uuid,

  notes             text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX organizations_firm_identity_idx ON organizations (firm_identity);
CREATE TRIGGER organizations_touch BEFORE UPDATE ON organizations
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- -----------------------------------------------------------------------------
-- location_groups — regions, states, shared-staff pools
--
-- Answers "who sees what" and "who can handle calls where". A group may hold
-- a funeral home, a cemetery and a crematory at once, which is exactly why
-- location_type lives on the location and not here.
-- -----------------------------------------------------------------------------
CREATE TABLE location_groups (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
  name              text NOT NULL,
  is_default        boolean NOT NULL DEFAULT false,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, name)
);
CREATE INDEX location_groups_org_idx ON location_groups (organization_id);
CREATE TRIGGER location_groups_touch BEFORE UPDATE ON location_groups
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- -----------------------------------------------------------------------------
-- accounts — the billing construct
--
-- Sits under an organization. Answers "who pays", independently of the
-- permission tree that answers "who sees". Anima-Care runs four states from
-- one account and one login; the per-state invoice is a grouping over cost
-- data, not a reason to fragment the account.
-- -----------------------------------------------------------------------------
CREATE TABLE accounts (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
  name              text NOT NULL,
  external_ref      text,                            -- Dial Stack account id
  is_default        boolean NOT NULL DEFAULT false,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, name)
);
CREATE INDEX accounts_org_idx ON accounts (organization_id);
CREATE TRIGGER accounts_touch BEFORE UPDATE ON accounts
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- -----------------------------------------------------------------------------
-- locations
--
-- location_type drives scoring applicability and FTC exposure.
-- funeral_rule_applies is stored as an explicit column rather than derived,
-- because the rule is "everything except cemetery" — coding the exclusion
-- means a location type added later inherits the right default instead of
-- being silently forgotten.
-- -----------------------------------------------------------------------------
CREATE TABLE locations (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id       uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
  location_group_id     uuid REFERENCES location_groups(id) ON DELETE SET NULL,
  account_id            uuid REFERENCES accounts(id) ON DELETE SET NULL,

  name                  text NOT NULL,
  location_type         location_type NOT NULL,
  funeral_rule_applies  boolean NOT NULL DEFAULT true,

  -- What an operator must say when answering for this site. An answering
  -- service handling forty firms needs the right name before speaking.
  answered_as           text,

  street                text,
  city                  text,
  state                 char(2),
  postal_code           text,
  timezone              text NOT NULL DEFAULT 'America/New_York',
  status                organization_status NOT NULL DEFAULT 'active',

  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX locations_org_idx         ON locations (organization_id);
CREATE INDEX locations_group_idx       ON locations (location_group_id);
CREATE INDEX locations_account_idx     ON locations (account_id);
CREATE INDEX locations_type_idx        ON locations (organization_id, location_type);

-- A location name must be unique within its organization. Without this,
-- ON CONFLICT DO NOTHING has nothing to conflict against and silently
-- duplicates every row on a re-run — which then breaks any lookup by name
-- with "more than one row returned by a subquery", a long way from the cause.
CREATE UNIQUE INDEX locations_org_name_uq ON locations (organization_id, name);

CREATE TRIGGER locations_touch BEFORE UPDATE ON locations
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- Cemeteries are the only exclusion from the Funeral Rule. Enforced rather
-- than trusted, so a bad insert cannot quietly create FTC exposure that
-- doesn't exist or hide exposure that does.
ALTER TABLE locations ADD CONSTRAINT locations_funeral_rule_ck
  CHECK ( (location_type = 'cemetery' AND funeral_rule_applies = false)
       OR (location_type <> 'cemetery') );

-- A location group and a location must belong to the same organization.
CREATE OR REPLACE FUNCTION locations_same_org() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.location_group_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM location_groups g
    WHERE g.id = NEW.location_group_id AND g.organization_id = NEW.organization_id
  ) THEN RAISE EXCEPTION 'location_group belongs to a different organization'; END IF;
  IF NEW.account_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM accounts a
    WHERE a.id = NEW.account_id AND a.organization_id = NEW.organization_id
  ) THEN RAISE EXCEPTION 'account belongs to a different organization'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER locations_same_org_ck BEFORE INSERT OR UPDATE ON locations
  FOR EACH ROW EXECUTE FUNCTION locations_same_org();

-- -----------------------------------------------------------------------------
-- Row-level security
--
-- organizations is filtered on its own id; everything else on organization_id.
-- Later migrations repeat this pattern verbatim.
-- -----------------------------------------------------------------------------
ALTER TABLE organizations   ENABLE ROW LEVEL SECURITY;
ALTER TABLE location_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE accounts        ENABLE ROW LEVEL SECURITY;
ALTER TABLE locations       ENABLE ROW LEVEL SECURITY;

CREATE POLICY organizations_tenant ON organizations
  USING (is_internal() OR id = current_organization_id());

CREATE POLICY location_groups_tenant ON location_groups
  USING (is_internal() OR organization_id = current_organization_id());

CREATE POLICY accounts_tenant ON accounts
  USING (is_internal() OR organization_id = current_organization_id());

CREATE POLICY locations_tenant ON locations
  USING (is_internal() OR organization_id = current_organization_id());

COMMIT;

-- =============================================================================
-- Verification — run after applying
--
--   SET app.is_internal = 'on';
--   INSERT INTO organizations (code, name, client_type)
--     VALUES ('DPX', 'Diocese of Phoenix', 'combo');
--
--   -- cemetery cannot carry FTC exposure
--   INSERT INTO locations (organization_id, name, location_type, funeral_rule_applies)
--   SELECT id, 'Holy Redeemer Catholic Cemetery', 'cemetery', true FROM organizations
--   WHERE code = 'DPX';                      -- expected: constraint violation
--
--   -- tenant isolation
--   SET app.is_internal = 'off';
--   SET app.organization_id = '00000000-0000-0000-0000-000000000000';
--   SELECT count(*) FROM organizations;      -- expected: 0
-- =============================================================================
