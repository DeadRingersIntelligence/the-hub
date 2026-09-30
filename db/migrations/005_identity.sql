-- =============================================================================
-- 005_identity.sql
-- The Hub — Phase 1, migration 5 of 6: contacts, decedents, cases, leads.
--
-- This is the spine the north star runs on. Three rules shape all of it:
--
--   Attribution is to a CASE, not a caller. Many callers, one case. One
--   caller, many cases over time, each with its own value and its own
--   customer experience.
--
--   A case exists only at conversion. Before a sale there is no case — a
--   researcher is a classified interaction and nothing more. The phantom
--   funeral home is a query, not a table.
--
--   Every link carries how it was made. An agent picking from a typeahead is
--   a fact. A matcher noticing two calls in two days both naming a Jim is an
--   inference, and inferences never blend into a confirmed number.
--
-- Requires: 001, 002, 003, 004
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- contacts
--
-- A caller. Created on first contact, keyed on the normalized phone number,
-- prepopulated on every call after.
--
-- Families, and also businesses: a vet clinic calling a pet provider hundreds
-- of times a year is a contact, with its own history of decedents. So is a
-- hospice calling a funeral home.
--
-- First-touch source is FROZEN here at the moment of capture. The campaign is
-- resolved through number_assignments when the first call lands and then
-- stored — otherwise a Facebook attribution silently becomes a Google one
-- when the tracking number rotates.
-- -----------------------------------------------------------------------------
CREATE TYPE contact_kind AS ENUM ('individual', 'business');

CREATE TABLE contacts (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id       uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,

  contact_kind          contact_kind NOT NULL DEFAULT 'individual',
  full_name             text,
  business_name         text,
  phone_e164            text,
  secondary_phone_e164  text,
  email                 text,

  -- First touch, frozen. Never recomputed.
  first_seen_at         timestamptz NOT NULL DEFAULT now(),
  source_campaign_id    uuid REFERENCES campaigns(id) ON DELETE SET NULL,
  source_referral_id    uuid REFERENCES referral_sources(id) ON DELETE SET NULL,
  source_channel        marketing_channel,

  -- Set when writeback or an arranger identifies them as next of kin on a
  -- prior case: a family member calling years later is already known.
  known_from_prior_case boolean NOT NULL DEFAULT false,

  merged_into           uuid REFERENCES contacts(id) ON DELETE SET NULL,
  notes                 text,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX contacts_org_phone_idx ON contacts (organization_id, phone_e164);
CREATE INDEX contacts_org_name_idx  ON contacts (organization_id, full_name);
CREATE INDEX contacts_merged_idx    ON contacts (merged_into);
CREATE TRIGGER contacts_touch BEFORE UPDATE ON contacts
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE OR REPLACE FUNCTION contacts_normalize() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.phone_e164 := COALESCE(normalize_e164(NEW.phone_e164), NEW.phone_e164);
  NEW.secondary_phone_e164 :=
    COALESCE(normalize_e164(NEW.secondary_phone_e164), NEW.secondary_phone_e164);
  RETURN NEW;
END $$;
CREATE TRIGGER contacts_normalize_t BEFORE INSERT OR UPDATE ON contacts
  FOR EACH ROW EXECUTE FUNCTION contacts_normalize();

ALTER TABLE contacts ADD CONSTRAINT contacts_business_named_ck
  CHECK (contact_kind <> 'business' OR business_name IS NOT NULL);

-- -----------------------------------------------------------------------------
-- decedents
--
-- Exists before death. A man calling about plot pricing for himself and his
-- wife creates two decedents with status pre_need_subject and no date of
-- death — displayed as "future decedent" so nobody reads a living person as
-- deceased.
--
-- Pets are decedents. Same table, same linking, same cases. species and
-- owner_name are all the difference amounts to.
--
-- merged_into rather than delete: two records turning out to be the same
-- person must not orphan the interactions already attached to either.
-- -----------------------------------------------------------------------------
CREATE TYPE decedent_status AS ENUM (
  'pre_need_subject', 'imminent', 'at_need', 'deceased');

CREATE TABLE decedents (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,

  first_name        text,
  last_name         text,
  full_name         text GENERATED ALWAYS AS (
                      NULLIF(trim(COALESCE(first_name,'') || ' ' ||
                                  COALESCE(last_name,'')), '')) STORED,
  date_of_death     date,
  status            decedent_status NOT NULL DEFAULT 'imminent',

  -- Pet deathcare
  species           text,
  owner_name        text,

  merged_into       uuid REFERENCES decedents(id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX decedents_org_name_idx ON decedents (organization_id, last_name, first_name);
CREATE INDEX decedents_org_dod_idx  ON decedents (organization_id, date_of_death);
CREATE INDEX decedents_merged_idx   ON decedents (merged_into);
CREATE TRIGGER decedents_touch BEFORE UPDATE ON decedents
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- A last name is required. First name alone cannot be a valid save — the
-- typeahead exists precisely to push the agent to ask for the full name
-- instead of settling for "Jim".
ALTER TABLE decedents ADD CONSTRAINT decedents_named_ck
  CHECK (last_name IS NOT NULL OR species IS NOT NULL);

-- Someone deceased has a date; someone living must not.
ALTER TABLE decedents ADD CONSTRAINT decedents_dod_ck
  CHECK ( (status IN ('pre_need_subject','imminent') AND date_of_death IS NULL)
       OR (status IN ('at_need','deceased')) );

-- -----------------------------------------------------------------------------
-- contact_decedent_links
--
-- Many callers to one decedent. Mary and her brother both calling about their
-- father Jim.
--
-- link_method is written by the mechanism that made the link, never typed by
-- a person. Picking Jim Smith d. 4/17/26 from a typeahead is 'confirmed'.
-- A matcher spotting two calls in two days both naming a Jim is 'inferred',
-- queryable but never blended into a confirmed statistic.
-- -----------------------------------------------------------------------------
CREATE TYPE link_method AS ENUM ('confirmed', 'inferred', 'writeback', 'imported');

CREATE TABLE contact_decedent_links (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  contact_id        uuid NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
  decedent_id       uuid NOT NULL REFERENCES decedents(id) ON DELETE CASCADE,

  relationship      text,                       -- daughter, son, next of kin
  link_method       link_method NOT NULL,
  linked_by         text,                       -- person, or the matcher's name
  linked_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (contact_id, decedent_id)
);
CREATE INDEX cdl_decedent_idx ON contact_decedent_links (decedent_id);

-- -----------------------------------------------------------------------------
-- cases
--
-- Created ONLY at conversion. The client's CRM or case management system is
-- the system of record for the money; the Hub reads from it and holds enough
-- to make behaviour-to-revenue answerable.
--
-- converting_interaction_id is what makes "which call converted" a fact
-- rather than a guess. Its foreign key is added in 006, once interactions
-- exist.
-- -----------------------------------------------------------------------------
CREATE TYPE case_need_type AS ENUM ('at_need', 'imminent', 'pre_need');

CREATE TABLE cases (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id           uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
  location_id               uuid REFERENCES locations(id) ON DELETE SET NULL,

  need_type                 case_need_type NOT NULL,
  converting_interaction_id uuid,               -- FK added in 006
  opened_on                 date NOT NULL DEFAULT current_date,

  -- From writeback. Absent until the client's system provides it.
  sale_value                numeric(12,2),
  service_type              text,
  arranging_person_id       uuid REFERENCES people(id) ON DELETE SET NULL,
  external_case_id          text,
  source_system             text,
  last_synced_at            timestamptz,

  -- Frozen from the originating contact's first touch, so credit doesn't
  -- move when a later caller reaches a different tracking number.
  source_campaign_id        uuid REFERENCES campaigns(id) ON DELETE SET NULL,
  source_referral_id        uuid REFERENCES referral_sources(id) ON DELETE SET NULL,

  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX cases_org_idx      ON cases (organization_id, opened_on);
CREATE INDEX cases_external_idx ON cases (organization_id, external_case_id);
CREATE TRIGGER cases_touch BEFORE UPDATE ON cases
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- A case can carry several decedents: a couple buying two spaces, or a car
-- accident producing an at-need and a pre-need in one conversation.
CREATE TABLE case_decedents (
  case_id           uuid NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
  decedent_id       uuid NOT NULL REFERENCES decedents(id) ON DELETE CASCADE,
  PRIMARY KEY (case_id, decedent_id)
);

-- Roles cover business relationships as well as family ones, because
-- sometimes the referring clinic is the only party on the call.
CREATE TABLE case_contacts (
  case_id           uuid NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
  contact_id        uuid NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
  role              text,                       -- daughter, next of kin,
                                                -- informant, referring clinic
  is_primary        boolean NOT NULL DEFAULT false,
  PRIMARY KEY (case_id, contact_id)
);

-- -----------------------------------------------------------------------------
-- leads and lead_ownership_rules
--
-- Optional, and pre-need only. An imported lead is someone who has NOT called.
-- A lead is not an opportunity and never becomes a case on its own — it
-- becomes a contact when they call, and a case only if that converts.
-- -----------------------------------------------------------------------------
CREATE TYPE lead_status AS ENUM ('open', 'contacted', 'lost', 'deceased', 'converted');

CREATE TABLE leads (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  location_id       uuid REFERENCES locations(id) ON DELETE SET NULL,

  full_name         text NOT NULL,
  phone_e164        text,
  email             text,

  owner_person_id   uuid REFERENCES people(id) ON DELETE SET NULL,
  source            text,
  assigned_on       date,
  status            lead_status NOT NULL DEFAULT 'open',

  -- Set when they call in and resolve to a contact.
  contact_id        uuid REFERENCES contacts(id) ON DELETE SET NULL,

  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX leads_org_idx   ON leads (organization_id, status);
CREATE INDEX leads_phone_idx ON leads (organization_id, phone_e164);
CREATE TRIGGER leads_touch BEFORE UPDATE ON leads
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE OR REPLACE FUNCTION leads_normalize() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.phone_e164 := COALESCE(normalize_e164(NEW.phone_e164), NEW.phone_e164);
  RETURN NEW;
END $$;
CREATE TRIGGER leads_normalize_t BEFORE INSERT OR UPDATE ON leads
  FOR EACH ROW EXECUTE FUNCTION leads_normalize();

-- Sally owns the lead; Tom took the call. Who gets credit is a per-location
-- policy, not a universal rule.
CREATE TYPE lead_credit_rule AS ENUM ('lead_owner', 'call_handler', 'split', 'manual');

CREATE TABLE lead_ownership_rules (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  location_id       uuid REFERENCES locations(id) ON DELETE CASCADE,
  credit_rule       lead_credit_rule NOT NULL DEFAULT 'lead_owner',
  notes             text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, location_id)
);
CREATE TRIGGER lead_ownership_rules_touch BEFORE UPDATE ON lead_ownership_rules
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- -----------------------------------------------------------------------------
-- Row-level security
-- -----------------------------------------------------------------------------
ALTER TABLE contacts               ENABLE ROW LEVEL SECURITY;
ALTER TABLE decedents              ENABLE ROW LEVEL SECURITY;
ALTER TABLE contact_decedent_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE cases                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE case_decedents         ENABLE ROW LEVEL SECURITY;
ALTER TABLE case_contacts          ENABLE ROW LEVEL SECURITY;
ALTER TABLE leads                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE lead_ownership_rules   ENABLE ROW LEVEL SECURITY;

CREATE POLICY contacts_tenant ON contacts
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY decedents_tenant ON decedents
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY contact_decedent_links_tenant ON contact_decedent_links
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY cases_tenant ON cases
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY leads_tenant ON leads
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY lead_ownership_rules_tenant ON lead_ownership_rules
  USING (is_internal() OR organization_id = current_organization_id());

-- Join tables inherit their parent's tenancy.
CREATE POLICY case_decedents_tenant ON case_decedents
  USING (is_internal() OR EXISTS (
    SELECT 1 FROM cases c WHERE c.id = case_id
      AND c.organization_id = current_organization_id()));
CREATE POLICY case_contacts_tenant ON case_contacts
  USING (is_internal() OR EXISTS (
    SELECT 1 FROM cases c WHERE c.id = case_id
      AND c.organization_id = current_organization_id()));

COMMIT;
