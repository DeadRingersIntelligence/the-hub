-- =============================================================================
-- 006_interactions.sql
-- The Hub — Phase 1, migration 6 of 6: the universal event and its satellites.
--
-- A call, a text thread and a web form are the same row with different
-- channels — because a 9:14pm form, a 7:02am text, a 7:40am voicemail and a
-- noon callback are ONE follow-up story, and splitting them across tables
-- splits the story.
--
-- A shop and a real call are the same entity graph. Same tables, same
-- contacts, same decedents, same client visibility. Only the counting
-- differs, and `source` is what does the counting.
--
-- Requires: 001, 002, 003, 004, 005
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Enumerations
-- -----------------------------------------------------------------------------
CREATE TYPE interaction_source  AS ENUM ('real', 'shop');
CREATE TYPE interaction_channel AS ENUM ('call', 'text', 'web_form');
CREATE TYPE direction           AS ENUM ('inbound', 'outbound');

-- 'abandoned' is deliberately separate from 'no_answer'. A caller who hung up
-- waiting is not a call nobody routed — CTM collapses both into "missed",
-- which tells an answering service's client their family was dropped and
-- tells the answering service nothing at all.
CREATE TYPE disposition AS ENUM (
  'connected', 'no_answer', 'abandoned', 'voicemail',
  'busy', 'spam', 'disconnected', 'unqualified');

CREATE TYPE handler_type AS ENUM (
  'client_staff', 'shared_seat', 'shopper', 'answering_service',
  'external_destination', 'unknown');

-- Precedence, strongest first. Where a call lands is recorded honestly
-- rather than guessed: unresolved is a real outcome, and a pile of
-- manual_override is itself a data-quality signal.
CREATE TYPE attribution_method AS ENUM (
  'named_seat', 'mobile_app', 'hot_desk', 'shopper_form',
  'transcript', 'client_confirmed', 'manual_override', 'unresolved');

CREATE TYPE attribution_confidence AS ENUM ('certain', 'probable', 'uncertain', 'none');

-- Rule 14: "not available" is a value, never null. Blank means not yet
-- captured; not_available means the carrier structurally cannot provide it.
-- A passthrough client forwarding to someone else's phone system will never
-- have ring counts, and that is different from a missing one.
CREATE TYPE telemetry_status AS ENUM ('captured', 'not_available', 'not_yet_captured');

-- -----------------------------------------------------------------------------
-- interactions
-- -----------------------------------------------------------------------------
CREATE TABLE interactions (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id       uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
  account_id            uuid REFERENCES accounts(id) ON DELETE SET NULL,

  -- The location the call ARRIVED at (inbound) or was placed to (outbound),
  -- independent of where the handler is assigned. One call rolls up to the
  -- location, to its group, and to the person. Three rollups, one row.
  location_id           uuid REFERENCES locations(id) ON DELETE SET NULL,

  source                interaction_source NOT NULL DEFAULT 'real',
  channel               interaction_channel NOT NULL DEFAULT 'call',
  direction             direction NOT NULL,
  service_line          service_line NOT NULL DEFAULT 'general',

  -- Numbers, stored normalized. phone_number_id resolves through
  -- number_assignments at occurred_at, never by the number alone.
  phone_number_id       uuid REFERENCES phone_numbers(id) ON DELETE SET NULL,
  from_e164             text,
  to_e164               text,

  -- Who handled it. person is nullable on purpose: a shared prep-room seat
  -- is fully evaluable and simply unattributed until resolved another way.
  seat_id               uuid REFERENCES seats(id) ON DELETE SET NULL,
  handler_person_id     uuid REFERENCES people(id) ON DELETE SET NULL,
  handler_type          handler_type NOT NULL DEFAULT 'unknown',
  attribution_method    attribution_method NOT NULL DEFAULT 'unresolved',
  attribution_confidence attribution_confidence NOT NULL DEFAULT 'none',
  -- Reassignment keeps its own trail; the original value is never lost.
  original_handler_person_id uuid REFERENCES people(id) ON DELETE SET NULL,
  reattributed_by       text,
  reattributed_at       timestamptz,

  occurred_at           timestamptz NOT NULL,
  ended_at              timestamptz,
  duration_seconds      integer,

  disposition           disposition,

  -- Telemetry. Captured from the carrier rather than counted by a shopper
  -- and typed into a dropdown, which is a known accuracy problem today.
  telemetry_status      telemetry_status NOT NULL DEFAULT 'not_yet_captured',
  ring_count            smallint,
  answer_seconds        integer,
  hold_seconds          integer,
  transfer_count        smallint,

  -- Excluded from conversion denominators, still counted and reported.
  -- Pet calls to a firm that doesn't do pet, wrong numbers, solicitation.
  qualified             boolean NOT NULL DEFAULT true,
  unqualified_reason    text,

  contact_id            uuid REFERENCES contacts(id) ON DELETE SET NULL,
  case_id               uuid REFERENCES cases(id) ON DELETE SET NULL,
  -- True on the one interaction that produced the sale. This is what makes
  -- "which call converted" a fact instead of a guess.
  is_converting         boolean NOT NULL DEFAULT false,

  recording_url         text,
  transcript            text,
  summary               text,
  external_ref          text,

  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX interactions_org_time_idx    ON interactions (organization_id, occurred_at DESC);
CREATE INDEX interactions_location_idx    ON interactions (location_id, occurred_at DESC);
CREATE INDEX interactions_handler_idx     ON interactions (handler_person_id, occurred_at DESC);
CREATE INDEX interactions_contact_idx     ON interactions (contact_id);
CREATE INDEX interactions_case_idx        ON interactions (case_id);
CREATE INDEX interactions_source_idx      ON interactions (organization_id, source);
CREATE INDEX interactions_external_idx    ON interactions (external_ref);
CREATE TRIGGER interactions_touch BEFORE UPDATE ON interactions
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE OR REPLACE FUNCTION interactions_normalize() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.from_e164 := COALESCE(normalize_e164(NEW.from_e164), NEW.from_e164);
  NEW.to_e164   := COALESCE(normalize_e164(NEW.to_e164),   NEW.to_e164);
  IF NEW.ended_at IS NOT NULL AND NEW.duration_seconds IS NULL THEN
    NEW.duration_seconds := EXTRACT(EPOCH FROM (NEW.ended_at - NEW.occurred_at))::int;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER interactions_normalize_t BEFORE INSERT OR UPDATE ON interactions
  FOR EACH ROW EXECUTE FUNCTION interactions_normalize();

-- Telemetry that is structurally unavailable must not carry numbers, and
-- captured telemetry must carry at least one.
ALTER TABLE interactions ADD CONSTRAINT interactions_telemetry_ck
  CHECK ( telemetry_status <> 'not_available'
       OR num_nonnulls(ring_count, answer_seconds, hold_seconds) = 0 );

-- An attributed call must say how, and an unresolved one must not claim a
-- person.
ALTER TABLE interactions ADD CONSTRAINT interactions_attribution_ck
  CHECK ( (handler_person_id IS NULL AND attribution_method = 'unresolved')
       OR (handler_person_id IS NOT NULL AND attribution_method <> 'unresolved') );

-- A web form has no duration and a call must have a time.
ALTER TABLE interactions ADD CONSTRAINT interactions_unqualified_ck
  CHECK (qualified = true OR unqualified_reason IS NOT NULL);

-- The deferred foreign key from 005, now that interactions exist.
ALTER TABLE cases ADD CONSTRAINT cases_converting_interaction_fk
  FOREIGN KEY (converting_interaction_id)
  REFERENCES interactions(id) ON DELETE SET NULL;

-- -----------------------------------------------------------------------------
-- interaction_participants
--
-- A participant may be a contact OR a person. An operator texting three
-- on-call directors about a family's call puts staff and family on the same
-- thread, and both need to be addressable.
-- -----------------------------------------------------------------------------
CREATE TABLE interaction_participants (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  interaction_id    uuid NOT NULL REFERENCES interactions(id) ON DELETE CASCADE,
  contact_id        uuid REFERENCES contacts(id) ON DELETE CASCADE,
  person_id         uuid REFERENCES people(id) ON DELETE CASCADE,
  role              text,                        -- caller, handler, notified,
                                                 -- transferred_to
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX interaction_participants_interaction_idx
  ON interaction_participants (interaction_id);
ALTER TABLE interaction_participants ADD CONSTRAINT interaction_participants_one_ck
  CHECK (num_nonnulls(contact_id, person_id) = 1);

-- -----------------------------------------------------------------------------
-- interaction_links
--
-- Interactions relate to each other: shop attempts, callbacks, coordination
-- texts attached to the call they are about.
--
-- 'self_reference_invalid' exists because it is what the current data
-- actually contains — shoppers pasting a call's own id into its attempt
-- field. Recording it as invalid is better than counting it as an attempt.
-- -----------------------------------------------------------------------------
CREATE TYPE interaction_link_type AS ENUM (
  'shop_attempt', 'callback', 'coordination', 'transfer', 'same_case', 'manual');

CREATE TYPE interaction_link_method AS ENUM (
  'system_matched', 'manual_entry', 'agent_linked', 'self_reference_invalid');

CREATE TABLE interaction_links (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id       uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  from_interaction_id   uuid NOT NULL REFERENCES interactions(id) ON DELETE CASCADE,
  to_interaction_id     uuid REFERENCES interactions(id) ON DELETE CASCADE,
  to_external_ref       text,                    -- not yet ingested
  link_type             interaction_link_type NOT NULL,
  link_method           interaction_link_method NOT NULL,
  linked_by             text,
  note                  text,
  created_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX interaction_links_from_idx ON interaction_links (from_interaction_id);
CREATE INDEX interaction_links_to_idx   ON interaction_links (to_interaction_id);
ALTER TABLE interaction_links ADD CONSTRAINT interaction_links_target_ck
  CHECK (num_nonnulls(to_interaction_id, to_external_ref) = 1);

-- -----------------------------------------------------------------------------
-- interaction_tags
--
-- Classification is stored as several values with a precedence order and
-- never overwritten. The agent beats the caller's own menu selection, which
-- beats the AI: a family in crisis presses whatever reaches a human, but
-- pressing a key is an act rather than an inference.
--
-- Both sources stay queryable so AI-versus-human disagreement is itself
-- measurable — which is how the model improves and how you prove it can't
-- run alone.
-- -----------------------------------------------------------------------------
CREATE TYPE tag_source AS ENUM ('agent', 'caller_selection', 'routing_rule', 'ai', 'import');

CREATE TABLE interaction_tags (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  interaction_id    uuid NOT NULL REFERENCES interactions(id) ON DELETE CASCADE,
  tag_id            uuid NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  tag_source        tag_source NOT NULL,
  confidence        numeric(4,3),                -- AI only
  applied_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (interaction_id, tag_id, tag_source)
);
CREATE INDEX interaction_tags_interaction_idx ON interaction_tags (interaction_id);

-- Strongest asserted tag of a kind, for reports that need one answer.
CREATE OR REPLACE FUNCTION resolved_tag(p_interaction uuid, p_kind tag_kind)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT t.code
  FROM interaction_tags it JOIN tags t ON t.id = it.tag_id
  WHERE it.interaction_id = p_interaction AND t.tag_kind = p_kind
  ORDER BY CASE it.tag_source
             WHEN 'agent' THEN 1 WHEN 'caller_selection' THEN 2
             WHEN 'routing_rule' THEN 3 WHEN 'import' THEN 4 ELSE 5 END
  LIMIT 1
$$;

-- -----------------------------------------------------------------------------
-- interaction_decedents
--
-- One call, several decedents. A car accident produces an at-need for one
-- parent and a pre-need conversation about the other, in one conversation.
-- Two decedents, and eventually two cases.
-- -----------------------------------------------------------------------------
CREATE TABLE interaction_decedents (
  interaction_id    uuid NOT NULL REFERENCES interactions(id) ON DELETE CASCADE,
  decedent_id       uuid NOT NULL REFERENCES decedents(id) ON DELETE CASCADE,
  link_method       link_method NOT NULL,
  linked_by         text,
  PRIMARY KEY (interaction_id, decedent_id)
);

-- -----------------------------------------------------------------------------
-- messages — message grain inside a text thread
-- -----------------------------------------------------------------------------
CREATE TABLE messages (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  interaction_id    uuid NOT NULL REFERENCES interactions(id) ON DELETE CASCADE,
  direction         direction NOT NULL,
  from_e164         text,
  to_e164           text,
  body              text,
  media_url         text,
  sent_at           timestamptz NOT NULL,
  sender_person_id  uuid REFERENCES people(id) ON DELETE SET NULL,
  external_ref      text,
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX messages_interaction_idx ON messages (interaction_id, sent_at);

-- -----------------------------------------------------------------------------
-- price_quotes
--
-- One row per price said on a call. The FIRST quote is the revenue anchor for
-- lost calls — not an average, not a later quote in the same conversation.
--
-- Keeping every quote rather than one field buys two things: the lowest
-- packaged price stops being thrown away, and grouping quotes by service type
-- across a location and period answers the FTC consistency check that is
-- currently the most time-intensive part of an audit — direct cremation
-- quoted at $995 on one call and $1,095 on another with nobody explaining
-- the difference.
-- -----------------------------------------------------------------------------
CREATE TABLE price_quotes (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id       uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  interaction_id        uuid NOT NULL REFERENCES interactions(id) ON DELETE CASCADE,

  quote_order           smallint NOT NULL,       -- 1 = first price said
  amount                numeric(12,2),
  amount_high           numeric(12,2),           -- set when given as a range
  is_packaged           boolean NOT NULL DEFAULT false,
  is_range              boolean NOT NULL DEFAULT false,
  service_type          text,                    -- direct cremation, burial
  transcript_offset_s   integer,
  link_method           link_method NOT NULL DEFAULT 'confirmed',
  created_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (interaction_id, quote_order)
);
CREATE INDEX price_quotes_interaction_idx ON price_quotes (interaction_id);
CREATE INDEX price_quotes_service_idx
  ON price_quotes (organization_id, service_type, created_at);
ALTER TABLE price_quotes ADD CONSTRAINT price_quotes_range_ck
  CHECK (is_range = false OR amount_high IS NOT NULL);

-- -----------------------------------------------------------------------------
-- Row-level security
-- -----------------------------------------------------------------------------
ALTER TABLE interactions             ENABLE ROW LEVEL SECURITY;
ALTER TABLE interaction_participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE interaction_links        ENABLE ROW LEVEL SECURITY;
ALTER TABLE interaction_tags         ENABLE ROW LEVEL SECURITY;
ALTER TABLE interaction_decedents    ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE price_quotes             ENABLE ROW LEVEL SECURITY;

CREATE POLICY interactions_tenant ON interactions
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY interaction_participants_tenant ON interaction_participants
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY interaction_links_tenant ON interaction_links
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY interaction_tags_tenant ON interaction_tags
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY messages_tenant ON messages
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY price_quotes_tenant ON price_quotes
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY interaction_decedents_tenant ON interaction_decedents
  USING (is_internal() OR EXISTS (
    SELECT 1 FROM interactions i WHERE i.id = interaction_id
      AND i.organization_id = current_organization_id()));

COMMIT;
