-- =============================================================================
-- 002_configuration.sql
-- The Hub — Phase 1, migration 2 of 6: what a client bought, and what we may
-- do with their data.
--
-- Three concerns, one file, because they are the same question asked three
-- ways: what is this client entitled to, how long do we keep it, and who
-- else may ever see it.
--
-- Requires: 001_tenancy.sql
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- organization_capabilities
--
-- HelloPhone and the Hub are not two products. They are two surfaces over one
-- database. A capability flag decides which surfaces render.
--
-- Anima-Care holds phone, recording and attribution and sees a call log, an
-- inbox and settings. Szal adds cxpertise. Altmeyer holds evaluations, shops
-- and coaching but no phone at all. A client never sees an empty section for
-- something they don't own — the section does not exist for them.
--
-- Modelled as one row per capability rather than columns, so adding a
-- capability later is an enum value rather than a schema change. Rows carry
-- dates because "when did they buy evaluations" is a question worth being
-- able to answer, and because a lapsed capability is not the same as one
-- never held.
-- -----------------------------------------------------------------------------
CREATE TYPE capability AS ENUM (
  'phone',              -- softphone, routing, call handling
  'recording',          -- call recordings and transcripts retained
  'attribution',        -- tracking numbers, campaigns, marketing ROI
  'texting',
  'evaluations',        -- CX scoring against a rubric
  'ftc_audit',          -- Funeral Rule compliance review, priced separately
  'shops',              -- mystery shopping
  'coaching',
  'training',
  'cxpertise',
  'directory',
  'internal_chat'
);

CREATE TABLE organization_capabilities (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  capability        capability NOT NULL,
  enabled_on        date NOT NULL DEFAULT current_date,
  disabled_on       date,
  notes             text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, capability)
);
CREATE INDEX organization_capabilities_org_idx
  ON organization_capabilities (organization_id);
CREATE TRIGGER organization_capabilities_touch BEFORE UPDATE
  ON organization_capabilities FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE organization_capabilities ADD CONSTRAINT org_capabilities_dates_ck
  CHECK (disabled_on IS NULL OR disabled_on >= enabled_on);

-- Convenience: is a capability live for this organization right now.
CREATE OR REPLACE FUNCTION has_capability(org uuid, cap capability)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM organization_capabilities c
    WHERE c.organization_id = org
      AND c.capability = cap
      AND c.enabled_on <= current_date
      AND (c.disabled_on IS NULL OR c.disabled_on > current_date)
  )
$$;

-- -----------------------------------------------------------------------------
-- retention_policies
--
-- Twelve months by default, matching the Dial Stack agreement. Up to eighty-
-- four months is available, which is Dial Stack's ceiling. Anything beyond
-- the default carries a storage fee, and the storage cost itself lands as a
-- cost_event attributed to the client.
--
-- Retention is also what makes historical review sellable: a passthrough
-- client holding twelve months of calls has twelve months of demo material
-- the day they consider a Growth Plan.
--
-- Deletion is deliberately NOT modelled here. A departing client's data, a
-- family's deletion request, and observations already frozen into a published
-- benchmark are three different questions, and they need a policy decision
-- before they need a table.
-- -----------------------------------------------------------------------------
CREATE TABLE retention_policies (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id       uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  recording_months      smallint NOT NULL DEFAULT 12,
  transcript_months     smallint NOT NULL DEFAULT 12,
  storage_fee_applies   boolean NOT NULL DEFAULT false,
  notes                 text,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id)
);
CREATE TRIGGER retention_policies_touch BEFORE UPDATE
  ON retention_policies FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE retention_policies ADD CONSTRAINT retention_months_ck
  CHECK (recording_months  BETWEEN 1 AND 84
     AND transcript_months BETWEEN 1 AND 84);

-- Anything above the 12-month default must be flagged as billable, so a
-- client cannot quietly sit on seven years of storage for free.
ALTER TABLE retention_policies ADD CONSTRAINT retention_fee_ck
  CHECK ( (recording_months <= 12 AND transcript_months <= 12)
       OR storage_fee_applies = true );

-- -----------------------------------------------------------------------------
-- data_sharing_agreements
--
-- Acquisition history never moves automatically. When a buyer acquires a
-- location, the seller's call history transfers only with a seller-signed
-- agreement naming what is being shared.
--
-- Without this, an acquisition quietly hands one firm's recorded calls and
-- family information to another firm. The row is the evidence that it was
-- permitted.
-- -----------------------------------------------------------------------------
CREATE TYPE sharing_scope AS ENUM (
  'call_recordings', 'transcripts', 'evaluations', 'reports', 'all');

CREATE TABLE data_sharing_agreements (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- The organization whose data is being shared, and the one receiving it.
  -- organization_id is the discloser, which is also what RLS filters on.
  organization_id       uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
  receiving_org_id      uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,

  -- Optional narrowing: a single acquired site rather than the whole firm.
  location_id           uuid REFERENCES locations(id) ON DELETE RESTRICT,

  scope                 sharing_scope NOT NULL,
  covers_from           date,                         -- null = all history
  covers_to             date,

  signed_on             date NOT NULL,
  signed_by             text NOT NULL,                -- name and title
  executed_by           text,                         -- who at Dead Ringers
  document_ref          text,                         -- where the signed copy lives
  revoked_on            date,

  notes                 text,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX dsa_org_idx       ON data_sharing_agreements (organization_id);
CREATE INDEX dsa_receiving_idx ON data_sharing_agreements (receiving_org_id);
CREATE TRIGGER data_sharing_agreements_touch BEFORE UPDATE
  ON data_sharing_agreements FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE data_sharing_agreements ADD CONSTRAINT dsa_not_self_ck
  CHECK (organization_id <> receiving_org_id);

-- -----------------------------------------------------------------------------
-- Row-level security
-- -----------------------------------------------------------------------------
ALTER TABLE organization_capabilities ENABLE ROW LEVEL SECURITY;
ALTER TABLE retention_policies        ENABLE ROW LEVEL SECURITY;
ALTER TABLE data_sharing_agreements   ENABLE ROW LEVEL SECURITY;

CREATE POLICY organization_capabilities_tenant ON organization_capabilities
  USING (is_internal() OR organization_id = current_organization_id());

CREATE POLICY retention_policies_tenant ON retention_policies
  USING (is_internal() OR organization_id = current_organization_id());

-- Both sides of a sharing agreement may see it. Neither may see anyone
-- else's, and only Dead Ringers sees them all.
CREATE POLICY data_sharing_agreements_tenant ON data_sharing_agreements
  USING (is_internal()
      OR organization_id  = current_organization_id()
      OR receiving_org_id = current_organization_id());

COMMIT;

-- =============================================================================
-- Verification — run after applying
--
--   SET app.is_internal = 'on';
--
--   -- Give the Diocese what they actually buy
--   INSERT INTO organization_capabilities (organization_id, capability)
--   SELECT id, c FROM organizations,
--     unnest(ARRAY['evaluations','ftc_audit','shops','coaching','training']::capability[]) c
--   WHERE code = 'DPX';
--
--   SELECT has_capability(id, 'ftc_audit') AS ftc,
--          has_capability(id, 'phone')     AS phone
--   FROM organizations WHERE code = 'DPX';
--   -- expected: ftc = true, phone = false
--
--   -- Seven years of storage without a fee should be refused
--   INSERT INTO retention_policies (organization_id, recording_months, transcript_months)
--   SELECT id, 84, 84 FROM organizations WHERE code = 'DPX';
--   -- expected: violates retention_fee_ck
-- =============================================================================
