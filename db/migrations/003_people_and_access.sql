-- =============================================================================
-- 003_people_and_access.sql
-- The Hub — Phase 1, migration 3 of 6: people, seats, logins, permissions.
--
-- The distinction that drives this file: a PERSON is someone we measure, a
-- USER is a login, and a SEAT is a thing the phone rings. Most directors are
-- a person with no login. A shared prep-room phone is a seat with no person.
-- An answering service's forwarding destination is a seat that isn't even a
-- Dead Ringers record. Collapsing any two of these loses attribution.
--
-- Requires: 001_tenancy.sql, 002_configuration.sql
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- people
--
-- Staff at client firms, Dead Ringers shoppers and coaches, answering-service
-- operators.
--
-- 'pending' exists because of the shopper roster problem: a shopper reaches
-- someone named Danielle who started last month and isn't on the roster, types
-- the name, and it flags for review. Until Wendy confirms the spelling with
-- the client, that name is NOT a person — otherwise three attempts at Danielle
-- become three Danielles and the aggregation is silently wrong.
-- -----------------------------------------------------------------------------
CREATE TYPE person_type AS ENUM (
  'client_staff', 'shopper', 'coach', 'operator', 'internal');

CREATE TYPE person_status AS ENUM ('pending', 'active', 'inactive');

CREATE TABLE people (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,

  full_name         text NOT NULL,
  preferred_name    text,
  title             text,
  person_type       person_type NOT NULL DEFAULT 'client_staff',
  status            person_status NOT NULL DEFAULT 'active',

  -- Set when status = 'pending': who reported the name and how.
  pending_source    text,
  confirmed_by      text,
  confirmed_on      date,

  -- Two people with the same first name in one organization make transcript
  -- attribution unreliable. Maintained by the application, read by scoring.
  first_name_unique boolean NOT NULL DEFAULT true,

  -- Same shape as decedents: merging duplicates must never orphan history.
  merged_into       uuid REFERENCES people(id) ON DELETE SET NULL,

  notes             text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX people_org_idx    ON people (organization_id);
CREATE INDEX people_status_idx ON people (organization_id, status);
CREATE INDEX people_merged_idx ON people (merged_into);

-- A person's full name must be unique within their organization, among
-- records that have not been merged away.
--
-- Two reasons. Mechanically, ON CONFLICT DO NOTHING needs something to
-- conflict against or a re-run silently duplicates everyone. Substantively,
-- two identically named active people break transcript attribution anyway —
-- which is what first_name_unique above exists to flag. A genuine second
-- John Smith gets a middle initial or a suffix, which is what firms do in
-- their own systems regardless.
CREATE UNIQUE INDEX people_org_name_uq
  ON people (organization_id, full_name) WHERE merged_into IS NULL;

CREATE TRIGGER people_touch BEFORE UPDATE ON people
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE people ADD CONSTRAINT people_pending_ck
  CHECK (status <> 'active' OR pending_source IS NULL OR confirmed_on IS NOT NULL);

-- -----------------------------------------------------------------------------
-- person_assignments
--
-- A person belongs to a location OR a location group. Group assignment means
-- they can handle calls anywhere in that group, which is how shared staff
-- work at Busch and the Diocese.
--
-- Dated, so a June report doesn't silently re-score April's calls when someone
-- moves groups in May. Cheap now, impossible to reconstruct later.
-- -----------------------------------------------------------------------------
CREATE TABLE person_assignments (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  person_id         uuid NOT NULL REFERENCES people(id) ON DELETE CASCADE,

  location_id       uuid REFERENCES locations(id) ON DELETE CASCADE,
  location_group_id uuid REFERENCES location_groups(id) ON DELETE CASCADE,

  role              text,
  starts_on         date NOT NULL DEFAULT current_date,
  ends_on           date,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX person_assignments_person_idx ON person_assignments (person_id);
CREATE INDEX person_assignments_loc_idx    ON person_assignments (location_id);
CREATE INDEX person_assignments_group_idx  ON person_assignments (location_group_id);
CREATE TRIGGER person_assignments_touch BEFORE UPDATE ON person_assignments
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE person_assignments ADD CONSTRAINT person_assignments_target_ck
  CHECK (num_nonnulls(location_id, location_group_id) = 1);
ALTER TABLE person_assignments ADD CONSTRAINT person_assignments_dates_ck
  CHECK (ends_on IS NULL OR ends_on >= starts_on);

-- -----------------------------------------------------------------------------
-- seats
--
-- The billable telephony object. Dial Stack bells a SEAT, not a person, and
-- charges per seat — which is why Szal's eight hard phones covering three
-- humans is eight seats.
--
--   named                — Thor's desk phone. Attribution is certain.
--   shared               — prep room, front desk. Evaluable, unattributed
--                          until resolved another way.
--   external_destination — a passthrough client's forwarded number. No device,
--                          no availability, no hot-desk. Lets "the Columbus
--                          office answered" be structural rather than inferred.
-- -----------------------------------------------------------------------------
CREATE TYPE seat_type AS ENUM ('named', 'shared', 'external_destination');

CREATE TABLE seats (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
  account_id        uuid REFERENCES accounts(id) ON DELETE SET NULL,
  location_id       uuid REFERENCES locations(id) ON DELETE SET NULL,

  label             text NOT NULL,             -- 'Thor', 'Prep Room'
  seat_type         seat_type NOT NULL,
  person_id         uuid REFERENCES people(id) ON DELETE SET NULL,
  extension         text,
  external_ref      text,                      -- Dial Stack user id
  active            boolean NOT NULL DEFAULT true,

  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX seats_org_idx    ON seats (organization_id);
CREATE INDEX seats_person_idx ON seats (person_id);
CREATE TRIGGER seats_touch BEFORE UPDATE ON seats
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- A named seat must name someone. A shared seat must not.
ALTER TABLE seats ADD CONSTRAINT seats_named_ck
  CHECK ( (seat_type = 'named'  AND person_id IS NOT NULL)
       OR (seat_type = 'shared' AND person_id IS NULL)
       OR (seat_type = 'external_destination') );

-- -----------------------------------------------------------------------------
-- device_sessions — hot-desking
--
-- Someone takes over a shared phone for a period. Closing the loop on who
-- answered a call on the embalming room handset, without anyone having to
-- punch a code while the phone is ringing.
-- -----------------------------------------------------------------------------
CREATE TABLE device_sessions (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  seat_id           uuid NOT NULL REFERENCES seats(id) ON DELETE CASCADE,
  person_id         uuid NOT NULL REFERENCES people(id) ON DELETE CASCADE,
  started_at        timestamptz NOT NULL,
  ended_at          timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX device_sessions_seat_time_idx
  ON device_sessions (seat_id, started_at DESC);
ALTER TABLE device_sessions ADD CONSTRAINT device_sessions_time_ck
  CHECK (ended_at IS NULL OR ended_at > started_at);

-- -----------------------------------------------------------------------------
-- partners — consulting groups and marketers
--
-- Johnson Consulting, Cairn Partners. A partner is not a tenant: they hold
-- scoped access into specific client organizations, granted and revoked per
-- client. Referral is a separate fact, recorded on the organization.
-- -----------------------------------------------------------------------------
CREATE TABLE partners (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name              text NOT NULL UNIQUE,
  partner_type      text,                      -- consultancy, marketing agency
  active            boolean NOT NULL DEFAULT true,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER partners_touch BEFORE UPDATE ON partners
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TABLE partner_access (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  partner_id        uuid NOT NULL REFERENCES partners(id) ON DELETE CASCADE,
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  granted_on        date NOT NULL DEFAULT current_date,
  revoked_on        date,
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (partner_id, organization_id)
);
CREATE INDEX partner_access_org_idx ON partner_access (organization_id);

-- -----------------------------------------------------------------------------
-- users and user_scopes
--
-- Scope is what you can reach. View profile is what you see when you get
-- there. They are separate: a consultant at a location and a served firm's
-- owner at the same location see completely different surfaces.
--
-- served_firm exists because answering-service clients resell visibility to
-- the firms they answer for — mobile-first, operational reporting only, and
-- no scores, behaviors or coaching, because that is the answering service's
-- data about its own people.
-- -----------------------------------------------------------------------------
CREATE TYPE scope_type AS ENUM (
  'internal', 'partner', 'organization', 'location_group', 'location');

CREATE TYPE view_profile AS ENUM (
  'internal', 'owner', 'manager', 'professional',
  'coach', 'partner', 'served_firm', 'shopper');

CREATE TABLE users (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email             text NOT NULL UNIQUE,
  full_name         text NOT NULL,

  -- A login usually belongs to a person we also measure. Not always: a
  -- bookkeeper logs in and never answers a phone.
  person_id         uuid REFERENCES people(id) ON DELETE SET NULL,
  partner_id        uuid REFERENCES partners(id) ON DELETE SET NULL,

  is_internal       boolean NOT NULL DEFAULT false,
  active            boolean NOT NULL DEFAULT true,
  last_seen_at      timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX users_person_idx  ON users (person_id);
CREATE INDEX users_partner_idx ON users (partner_id);
CREATE TRIGGER users_touch BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TABLE user_scopes (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  scope_type        scope_type NOT NULL,
  view_profile      view_profile NOT NULL,

  organization_id   uuid REFERENCES organizations(id) ON DELETE CASCADE,
  location_group_id uuid REFERENCES location_groups(id) ON DELETE CASCADE,
  location_id       uuid REFERENCES locations(id) ON DELETE CASCADE,
  partner_id        uuid REFERENCES partners(id) ON DELETE CASCADE,

  granted_on        date NOT NULL DEFAULT current_date,
  revoked_on        date,
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX user_scopes_user_idx ON user_scopes (user_id);
CREATE INDEX user_scopes_org_idx  ON user_scopes (organization_id);

-- Each scope names exactly one target, matching its type.
ALTER TABLE user_scopes ADD CONSTRAINT user_scopes_target_ck CHECK (
  (scope_type = 'internal'       AND num_nonnulls(organization_id, location_group_id, location_id, partner_id) = 0)
  OR (scope_type = 'partner'        AND partner_id        IS NOT NULL)
  OR (scope_type = 'organization'   AND organization_id   IS NOT NULL)
  OR (scope_type = 'location_group' AND location_group_id IS NOT NULL)
  OR (scope_type = 'location'       AND location_id       IS NOT NULL)
);

-- -----------------------------------------------------------------------------
-- Row-level security
--
-- Identity tables are filtered on the session's own user rather than on an
-- organization: a login is not owned by a tenant, and users must never be
-- able to enumerate each other across clients.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION current_user_id() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.user_id', true), '')::uuid
$$;

ALTER TABLE people             ENABLE ROW LEVEL SECURITY;
ALTER TABLE person_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE seats              ENABLE ROW LEVEL SECURITY;
ALTER TABLE device_sessions    ENABLE ROW LEVEL SECURITY;
ALTER TABLE partner_access     ENABLE ROW LEVEL SECURITY;
ALTER TABLE partners           ENABLE ROW LEVEL SECURITY;
ALTER TABLE users              ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_scopes        ENABLE ROW LEVEL SECURITY;

CREATE POLICY people_tenant ON people
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY person_assignments_tenant ON person_assignments
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY seats_tenant ON seats
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY device_sessions_tenant ON device_sessions
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY partner_access_tenant ON partner_access
  USING (is_internal() OR organization_id = current_organization_id());

-- A user sees their own login row and nobody else's.
CREATE POLICY users_self ON users
  USING (is_internal() OR id = current_user_id());

-- Likewise their own grants — so a client admin cannot read what access
-- other firms or partners hold.
CREATE POLICY user_scopes_self ON user_scopes
  USING (is_internal() OR user_id = current_user_id());

-- A partner row is visible to Dead Ringers, to that partner's own users, and
-- to any organization that has granted them access — so a client can always
-- see which consultancy can reach their data.
CREATE POLICY partners_visible ON partners
  USING (
    is_internal()
    OR id IN (SELECT partner_id FROM users WHERE id = current_user_id())
    OR id IN (SELECT partner_id FROM partner_access
              WHERE organization_id = current_organization_id()
                AND revoked_on IS NULL)
  );

COMMIT;
