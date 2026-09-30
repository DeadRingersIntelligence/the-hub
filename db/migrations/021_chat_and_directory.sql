-- =============================================================================
-- 021_chat_and_directory.sql
-- The Hub — Phase 2, migration 21: teams, internal chat, the directory.
--
-- Two problems, one migration.
--
-- CHAT. Coordination about a family currently happens in SMS to personal cells,
-- where it is invisible, unsearchable, and lost when someone leaves. A thread
-- scoped to a contact or a case follows the family across every call and text,
-- so the next person to pick up sees what was already said.
--
-- DIRECTORY. Finding an outbound number today means leaving the softphone,
-- opening receiving numbers, copying, reopening, pasting. Transfers are hard
-- for the same reason. One searchable, structured list fixes both — and a
-- director changing their cell updates in one place rather than in everyone's
-- memory.
--
-- Requires: 001 to 020
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- teams
--
-- Named groups, addressable in chat and in the directory. An answering service
-- messages "the on-call directors" rather than three people by name.
-- -----------------------------------------------------------------------------
CREATE TABLE teams (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  location_id       uuid REFERENCES locations(id) ON DELETE SET NULL,
  name              text NOT NULL,
  description       text,
  active            boolean NOT NULL DEFAULT true,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, name)
);
CREATE INDEX teams_org_idx ON teams (organization_id, active);
CREATE TRIGGER teams_touch BEFORE UPDATE ON teams
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TABLE team_members (
  team_id           uuid NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
  person_id         uuid NOT NULL REFERENCES people(id) ON DELETE CASCADE,
  added_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (team_id, person_id)
);
CREATE INDEX team_members_person_idx ON team_members (person_id);

-- -----------------------------------------------------------------------------
-- threads
--
-- Scope is the whole point. "Margaret only" keeps a note about one caller from
-- surfacing on her brother's call; "the whole case" follows the family. A
-- support thread belongs to neither and reaches Dead Ringers instead.
-- -----------------------------------------------------------------------------
CREATE TYPE thread_scope AS ENUM ('contact', 'case', 'interaction', 'support', 'direct');

CREATE TABLE threads (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,

  scope             thread_scope NOT NULL,
  contact_id        uuid REFERENCES contacts(id) ON DELETE CASCADE,
  case_id           uuid REFERENCES cases(id) ON DELETE CASCADE,
  interaction_id    uuid REFERENCES interactions(id) ON DELETE CASCADE,

  title             text,
  created_by        uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  last_message_at   timestamptz
);
CREATE INDEX threads_contact_idx ON threads (contact_id);
CREATE INDEX threads_case_idx    ON threads (case_id);
CREATE INDEX threads_org_recent_idx
  ON threads (organization_id, last_message_at DESC NULLS LAST);
CREATE TRIGGER threads_touch BEFORE UPDATE ON threads
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- A scoped thread must name what it is scoped to; support and direct must not.
ALTER TABLE threads ADD CONSTRAINT threads_scope_ck CHECK (
     (scope = 'contact'     AND contact_id     IS NOT NULL)
  OR (scope = 'case'        AND case_id        IS NOT NULL)
  OR (scope = 'interaction' AND interaction_id IS NOT NULL)
  OR (scope IN ('support','direct')
      AND num_nonnulls(contact_id, case_id, interaction_id) = 0));

CREATE TABLE thread_participants (
  thread_id         uuid NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  user_id           uuid REFERENCES users(id) ON DELETE CASCADE,
  team_id           uuid REFERENCES teams(id) ON DELETE CASCADE,
  added_at          timestamptz NOT NULL DEFAULT now(),
  last_read_at      timestamptz
);
CREATE UNIQUE INDEX thread_participants_user_uq
  ON thread_participants (thread_id, user_id) WHERE user_id IS NOT NULL;
CREATE UNIQUE INDEX thread_participants_team_uq
  ON thread_participants (thread_id, team_id) WHERE team_id IS NOT NULL;
CREATE INDEX thread_participants_user_idx ON thread_participants (user_id);

ALTER TABLE thread_participants ADD CONSTRAINT thread_participants_one_ck
  CHECK (num_nonnulls(user_id, team_id) = 1);

CREATE TABLE thread_messages (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  thread_id         uuid NOT NULL REFERENCES threads(id) ON DELETE CASCADE,

  sender_user_id    uuid REFERENCES users(id) ON DELETE SET NULL,
  sender_label      text NOT NULL,             -- survives a departed user
  body              text NOT NULL,

  -- A message can point at the call it is about, so "Jane confirmed she'd
  -- reach out" sits beside the interaction rather than floating.
  interaction_id    uuid REFERENCES interactions(id) ON DELETE SET NULL,

  sent_at           timestamptz NOT NULL DEFAULT now(),
  edited_at         timestamptz
);
CREATE INDEX thread_messages_thread_idx ON thread_messages (thread_id, sent_at);

-- Keep the thread's recency current without a separate write from the caller.
CREATE OR REPLACE FUNCTION threads_touch_last_message() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE threads SET last_message_at = NEW.sent_at, updated_at = now()
   WHERE id = NEW.thread_id;
  RETURN NEW;
END $$;
CREATE TRIGGER thread_messages_bump AFTER INSERT ON thread_messages
  FOR EACH ROW EXECUTE FUNCTION threads_touch_last_message();

-- -----------------------------------------------------------------------------
-- push_tokens
--
-- A message has to buzz the phone like a text does or field staff will not see
-- it. Delivery is separate from the message: SMS fallback works day one with
-- nothing installed, push arrives with the mobile app, and neither changes what
-- is stored.
-- -----------------------------------------------------------------------------
CREATE TYPE push_platform AS ENUM ('ios', 'android', 'web');

CREATE TABLE push_tokens (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  platform          push_platform NOT NULL,
  token             text NOT NULL,
  device_label      text,
  last_seen_at      timestamptz NOT NULL DEFAULT now(),
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (platform, token)
);
CREATE INDEX push_tokens_user_idx ON push_tokens (user_id);

-- -----------------------------------------------------------------------------
-- directory_entries
--
-- Searchable from wherever calling and transferring happens. An entry may point
-- at a person, a contact, a team, or stand alone as a plain number — a hospice,
-- a coroner, a crematory.
--
-- transferable marks what can be reached from the softphone's transfer list,
-- which is the flag the interface needs on business contacts.
-- -----------------------------------------------------------------------------
CREATE TYPE directory_entry_kind AS ENUM (
  'staff', 'team', 'served_firm', 'business', 'on_call', 'external');

CREATE TABLE directory_entries (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,

  entry_kind        directory_entry_kind NOT NULL,
  label             text NOT NULL,
  subtitle          text,                      -- 'Riverside Chapel', 'Hospice liaison'

  person_id         uuid REFERENCES people(id) ON DELETE CASCADE,
  team_id           uuid REFERENCES teams(id) ON DELETE CASCADE,
  contact_id        uuid REFERENCES contacts(id) ON DELETE CASCADE,
  location_id       uuid REFERENCES locations(id) ON DELETE SET NULL,

  -- Structured, not a copied phone field. One place to change a cell number.
  e164              text,
  extension         text,

  transferable      boolean NOT NULL DEFAULT true,
  sort_order        smallint NOT NULL DEFAULT 100,
  active            boolean NOT NULL DEFAULT true,

  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX directory_entries_org_idx
  ON directory_entries (organization_id, active, sort_order);
CREATE INDEX directory_entries_search_idx
  ON directory_entries (organization_id, lower(label));
CREATE TRIGGER directory_entries_touch BEFORE UPDATE ON directory_entries
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- A team entry rings a team; everything else needs somewhere to ring.
ALTER TABLE directory_entries ADD CONSTRAINT directory_entries_reachable_ck
  CHECK (entry_kind = 'team' OR e164 IS NOT NULL OR extension IS NOT NULL);

CREATE OR REPLACE FUNCTION directory_entries_normalize() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.e164 := COALESCE(normalize_e164(NEW.e164), NEW.e164);
  RETURN NEW;
END $$;
CREATE TRIGGER directory_entries_normalize_t BEFORE INSERT OR UPDATE ON directory_entries
  FOR EACH ROW EXECUTE FUNCTION directory_entries_normalize();

-- -----------------------------------------------------------------------------
-- Row-level security
-- -----------------------------------------------------------------------------
ALTER TABLE teams               ENABLE ROW LEVEL SECURITY;
ALTER TABLE team_members        ENABLE ROW LEVEL SECURITY;
ALTER TABLE threads             ENABLE ROW LEVEL SECURITY;
ALTER TABLE thread_participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE thread_messages     ENABLE ROW LEVEL SECURITY;
ALTER TABLE push_tokens         ENABLE ROW LEVEL SECURITY;
ALTER TABLE directory_entries   ENABLE ROW LEVEL SECURITY;

CREATE POLICY teams_tenant ON teams
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY threads_tenant ON threads
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY thread_messages_tenant ON thread_messages
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY directory_entries_tenant ON directory_entries
  USING (is_internal() OR organization_id = current_organization_id());

CREATE POLICY team_members_tenant ON team_members
  USING (is_internal() OR EXISTS (
    SELECT 1 FROM teams t WHERE t.id = team_id
      AND t.organization_id = current_organization_id()));
CREATE POLICY thread_participants_tenant ON thread_participants
  USING (is_internal() OR EXISTS (
    SELECT 1 FROM threads t WHERE t.id = thread_id
      AND t.organization_id = current_organization_id()));

CREATE POLICY push_tokens_self ON push_tokens
  USING (is_internal() OR user_id = current_user_id());

COMMIT;

-- =============================================================================
-- Verification
--
--   SET app.is_internal = 'on';
--
--   -- a contact-scoped thread with no contact is refused
--   INSERT INTO threads (organization_id, scope)
--   SELECT id, 'contact' FROM organizations WHERE code='ALT';
--
--   -- a directory entry with nowhere to ring is refused
--   INSERT INTO directory_entries (organization_id, entry_kind, label)
--   SELECT id, 'on_call', 'On-call director' FROM organizations WHERE code='ALT';
--
--   -- a clean one, typed in any format
--   INSERT INTO directory_entries (organization_id, entry_kind, label, e164)
--   SELECT id, 'on_call', 'On-call director', '(304) 555-9876'
--   FROM organizations WHERE code='ALT';
--   SELECT label, e164, transferable FROM directory_entries;
-- =============================================================================
