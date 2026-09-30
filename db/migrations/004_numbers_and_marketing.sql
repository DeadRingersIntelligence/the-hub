-- =============================================================================
-- 004_numbers_and_marketing.sql
-- The Hub — Phase 1, migration 4 of 6: phone numbers, campaigns, attribution.
--
-- The load-bearing idea: a number does not identify a source. A number DURING
-- A PERIOD identifies a source. Anima-Care retires and reuses tracking numbers
-- to measure a campaign over a window, and carriers reassign released numbers
-- to strangers. Storing campaign on the number rewrites history the moment
-- either happens.
--
-- Requires: 001, 002, 003
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- marketing_vendors and campaigns
--
-- campaign_spend is the denominator ROI has been missing: attribution counts
-- calls, but return needs what was paid. Spend is optional per client, and a
-- missing figure must read as "not provided" rather than zero — a campaign
-- with unknown spend and 40 calls is not a campaign with infinite return.
-- -----------------------------------------------------------------------------
CREATE TABLE marketing_vendors (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name              text NOT NULL,
  contact_name      text,
  contact_email     text,
  active            boolean NOT NULL DEFAULT true,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, name)
);
CREATE TRIGGER marketing_vendors_touch BEFORE UPDATE ON marketing_vendors
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TYPE marketing_channel AS ENUM (
  'google_ads', 'google_lsa', 'facebook', 'instagram', 'organic_search',
  'website', 'direct_mail', 'print', 'radio', 'tv', 'billboard',
  'referral', 'event', 'other');

CREATE TABLE campaigns (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id       uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  marketing_vendor_id   uuid REFERENCES marketing_vendors(id) ON DELETE SET NULL,
  name                  text NOT NULL,
  channel               marketing_channel NOT NULL,
  starts_on             date,
  ends_on               date,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, name)
);
CREATE INDEX campaigns_org_idx ON campaigns (organization_id);
CREATE TRIGGER campaigns_touch BEFORE UPDATE ON campaigns
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TYPE spend_entry_method AS ENUM ('manual', 'vendor_report', 'api');

CREATE TABLE campaign_spend (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  campaign_id       uuid NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,
  period_start      date NOT NULL,
  period_end        date NOT NULL,
  amount            numeric(12,2) NOT NULL,
  entry_method      spend_entry_method NOT NULL DEFAULT 'manual',
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (campaign_id, period_start, period_end)
);
CREATE INDEX campaign_spend_campaign_idx ON campaign_spend (campaign_id);
ALTER TABLE campaign_spend ADD CONSTRAINT campaign_spend_period_ck
  CHECK (period_end >= period_start);

-- -----------------------------------------------------------------------------
-- referral_sources
--
-- Hospices, hospitals, churches, vet clinics, other firms. These touch calls
-- without being a marketing channel, and a referral relationship is not a
-- campaign: nobody paid for it, and it shouldn't compete with paid media for
-- credit on a family's first call.
-- -----------------------------------------------------------------------------
CREATE TYPE referral_kind AS ENUM (
  'hospice', 'hospital', 'nursing_facility', 'church', 'vet_clinic',
  'funeral_home', 'cemetery', 'insurance', 'individual', 'other');

CREATE TABLE referral_sources (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name              text NOT NULL,
  referral_kind     referral_kind NOT NULL,
  active            boolean NOT NULL DEFAULT true,
  started_on        date,
  ended_on          date,
  notes             text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, name)
);
CREATE INDEX referral_sources_org_idx ON referral_sources (organization_id);
CREATE TRIGGER referral_sources_touch BEFORE UPDATE ON referral_sources
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- -----------------------------------------------------------------------------
-- phone_numbers
--
-- The resolver for nearly everything: which organization, which location,
-- which service line, what the operator must say when answering, and whether
-- this is a real client line, a marketing tracking number, or a Dead Ringers
-- shop number.
--
-- Normalization is a known trap. CTM returns +15138283541; stored values
-- elsewhere are 5138283541 or display-formatted, and matching on an
-- unnormalized number silently returns nothing. e164 is the only value any
-- join may use. Never match on the display field.
-- -----------------------------------------------------------------------------
CREATE TYPE number_purpose AS ENUM (
  'client_line',        -- a real published number for the firm
  'tracking',           -- marketing attribution, rotates
  'shop',               -- Dead Ringers shop pool. Resolves to DR, not the client
  'internal',           -- trade and vendor line, kept out of marketing ROI
  'test');

CREATE TYPE service_line AS ENUM (
  'answering_service', 'transportation', 'funeral', 'cemetery',
  'pet', 'preneed', 'general');

CREATE TABLE phone_numbers (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Null organization means the number belongs to Dead Ringers: shop pool
  -- numbers resolve to us, which is how the Hub knows at ring time.
  organization_id   uuid REFERENCES organizations(id) ON DELETE RESTRICT,
  account_id        uuid REFERENCES accounts(id) ON DELETE SET NULL,
  location_id       uuid REFERENCES locations(id) ON DELETE SET NULL,

  e164              text NOT NULL,             -- +15138283541, the only join key
  display           text,                      -- (513) 828-3541, never joined on
  area_code         char(3),

  purpose           number_purpose NOT NULL,
  service_line      service_line NOT NULL DEFAULT 'general',

  -- What the operator must say. An answering service handling forty firms
  -- needs the right name on screen before the handset reaches their ear.
  answered_as       text,

  carrier           text,                      -- dial_stack, ctm, other
  external_ref      text,
  active            boolean NOT NULL DEFAULT true,
  acquired_on       date,
  released_on       date,
  next_billing_date date,

  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX phone_numbers_e164_active_idx
  ON phone_numbers (e164) WHERE active;
CREATE INDEX phone_numbers_e164_idx     ON phone_numbers (e164);
CREATE INDEX phone_numbers_org_idx      ON phone_numbers (organization_id);
CREATE INDEX phone_numbers_location_idx ON phone_numbers (location_id);
CREATE TRIGGER phone_numbers_touch BEFORE UPDATE ON phone_numbers
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE phone_numbers ADD CONSTRAINT phone_numbers_e164_ck
  CHECK (e164 ~ '^\+[1-9][0-9]{7,14}$');

-- A shop number must not belong to a client organization.
ALTER TABLE phone_numbers ADD CONSTRAINT phone_numbers_shop_ck
  CHECK (purpose <> 'shop' OR organization_id IS NULL);

-- Normalize on write. Any digits in, E.164 out, or null if it can't be one.
CREATE OR REPLACE FUNCTION normalize_e164(raw text) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE d text;
BEGIN
  IF raw IS NULL THEN RETURN NULL; END IF;
  d := regexp_replace(raw, '[^0-9]', '', 'g');
  IF length(d) = 11 AND left(d,1) = '1' THEN RETURN '+' || d;
  ELSIF length(d) = 10 THEN RETURN '+1' || d;
  ELSIF length(d) BETWEEN 8 AND 15 THEN RETURN '+' || d;
  END IF;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION phone_numbers_normalize() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.e164 := COALESCE(normalize_e164(NEW.e164), NEW.e164);
  NEW.area_code := CASE WHEN left(NEW.e164,2) = '+1' THEN substr(NEW.e164,3,3) END;
  RETURN NEW;
END $$;
CREATE TRIGGER phone_numbers_normalize_t BEFORE INSERT OR UPDATE ON phone_numbers
  FOR EACH ROW EXECUTE FUNCTION phone_numbers_normalize();

-- -----------------------------------------------------------------------------
-- number_assignments
--
-- Dated windows. Two independent paths arrived at this table: tracking numbers
-- rotating between campaigns, and carriers reassigning released numbers to
-- other businesses entirely.
--
-- Source resolves by number PLUS call timestamp. A number pointed at a new
-- campaign in March never changes what February's calls were attributed to.
--
-- Shop pool eligibility, burn, renewal margin and retirement stay in Zoho
-- Creator. This table records what Creator decided; it does not re-decide it.
-- Two systems computing the same rule will disagree within a month.
-- -----------------------------------------------------------------------------
CREATE TABLE number_assignments (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  phone_number_id   uuid NOT NULL REFERENCES phone_numbers(id) ON DELETE CASCADE,

  -- Who held the number during this window, and what it was pointed at.
  organization_id   uuid REFERENCES organizations(id) ON DELETE SET NULL,
  location_id       uuid REFERENCES locations(id) ON DELETE SET NULL,
  campaign_id       uuid REFERENCES campaigns(id) ON DELETE SET NULL,
  referral_source_id uuid REFERENCES referral_sources(id) ON DELETE SET NULL,
  purpose           number_purpose NOT NULL,

  starts_at         timestamptz NOT NULL,
  ends_at           timestamptz,

  external_ref      text,
  notes             text,
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX number_assignments_number_time_idx
  ON number_assignments (phone_number_id, starts_at DESC);
CREATE INDEX number_assignments_campaign_idx ON number_assignments (campaign_id);
ALTER TABLE number_assignments ADD CONSTRAINT number_assignments_time_ck
  CHECK (ends_at IS NULL OR ends_at > starts_at);

-- No overlapping windows for one number: a call must resolve to exactly one
-- assignment, or attribution becomes a coin toss.
CREATE EXTENSION IF NOT EXISTS btree_gist;
ALTER TABLE number_assignments ADD CONSTRAINT number_assignments_no_overlap
  EXCLUDE USING gist (
    phone_number_id WITH =,
    tstzrange(starts_at, COALESCE(ends_at, 'infinity'::timestamptz)) WITH &&
  );

-- Resolve a number as it stood at a moment in time.
CREATE OR REPLACE FUNCTION resolve_number(raw text, at_time timestamptz)
RETURNS TABLE (
  phone_number_id uuid, organization_id uuid, location_id uuid,
  campaign_id uuid, purpose number_purpose
) LANGUAGE sql STABLE AS $$
  SELECT n.id,
         COALESCE(a.organization_id, n.organization_id),
         COALESCE(a.location_id, n.location_id),
         a.campaign_id,
         COALESCE(a.purpose, n.purpose)
  FROM phone_numbers n
  LEFT JOIN number_assignments a
    ON a.phone_number_id = n.id
   AND a.starts_at <= at_time
   AND (a.ends_at IS NULL OR a.ends_at > at_time)
  WHERE n.e164 = normalize_e164(raw)
  ORDER BY a.starts_at DESC NULLS LAST
  LIMIT 1
$$;

-- -----------------------------------------------------------------------------
-- tags
--
-- The Hub records the TAG a menu selection produced, never the keypress.
-- Every client's IVR differs, so "pressed 1" means nothing across clients
-- while "at-need" means the same thing everywhere. Configure the menu to
-- produce the tag; store the tag.
--
-- Tags arrive from several sources and keep their own precedence:
--   agent beats caller_selection beats ai.
-- A family in crisis presses whatever reaches a human, so the agent still
-- wins — but pressing a key is an act, not an inference, so it beats a
-- transcript read.
-- -----------------------------------------------------------------------------
CREATE TYPE tag_kind AS ENUM (
  'need_type', 'caller_type', 'service_interest', 'quality', 'other');

CREATE TABLE tags (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Null organization means a shared, cross-client tag: 'at_need',
  -- 'pre_need', 'vendor'. Those are what national comparisons run on.
  organization_id   uuid REFERENCES organizations(id) ON DELETE CASCADE,

  code              text NOT NULL,
  label             text NOT NULL,
  tag_kind          tag_kind NOT NULL,
  active            boolean NOT NULL DEFAULT true,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX tags_shared_code_idx
  ON tags (code) WHERE organization_id IS NULL;
CREATE UNIQUE INDEX tags_org_code_idx
  ON tags (organization_id, code) WHERE organization_id IS NOT NULL;
CREATE TRIGGER tags_touch BEFORE UPDATE ON tags
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

INSERT INTO tags (code, label, tag_kind) VALUES
  ('at_need',      'At-need',              'need_type'),
  ('imminent',     'Imminent',             'need_type'),
  ('pre_need',     'Pre-need',             'need_type'),
  ('family',       'Family',               'caller_type'),
  ('vendor',       'Vendor or supplier',   'caller_type'),
  ('trade',        'Trade or referral',    'caller_type'),
  ('solicitation', 'Solicitation',         'caller_type'),
  ('wrong_number', 'Wrong number',         'caller_type'),
  ('service_not_offered', 'Service not offered', 'quality');

-- -----------------------------------------------------------------------------
-- Row-level security
-- -----------------------------------------------------------------------------
ALTER TABLE marketing_vendors  ENABLE ROW LEVEL SECURITY;
ALTER TABLE campaigns          ENABLE ROW LEVEL SECURITY;
ALTER TABLE campaign_spend     ENABLE ROW LEVEL SECURITY;
ALTER TABLE referral_sources   ENABLE ROW LEVEL SECURITY;
ALTER TABLE phone_numbers      ENABLE ROW LEVEL SECURITY;
ALTER TABLE number_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE tags               ENABLE ROW LEVEL SECURITY;

CREATE POLICY marketing_vendors_tenant ON marketing_vendors
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY campaigns_tenant ON campaigns
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY campaign_spend_tenant ON campaign_spend
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY referral_sources_tenant ON referral_sources
  USING (is_internal() OR organization_id = current_organization_id());

-- Dead Ringers shop numbers carry no organization and stay internal-only:
-- a client must never be able to list the numbers used to shop them.
CREATE POLICY phone_numbers_tenant ON phone_numbers
  USING (is_internal() OR organization_id = current_organization_id());

CREATE POLICY number_assignments_tenant ON number_assignments
  USING (is_internal() OR organization_id = current_organization_id());

-- Shared tags are readable by everyone; client tags only by their owner.
CREATE POLICY tags_visible ON tags
  USING (is_internal()
      OR organization_id IS NULL
      OR organization_id = current_organization_id());

COMMIT;
