-- =============================================================================
-- 018_picklists_and_custom_fields.sql
-- The Hub — Phase 2, migration 18: configurable lists, and fields a firm adds.
--
-- Two shapes, one principle: Dead Ringers defaults a client can hide or extend
-- but never rename or delete, plus client additions that are firm-only forever.
--
-- The reporting consequence is the reason to enforce it rather than trust it.
-- A default means the same thing at every firm, so it can carry a benchmark.
-- A client-added item means whatever that client decided, so it cannot. Once
-- those two sit in the same column with nothing distinguishing them, nobody
-- can tell which numbers are comparable — and somebody eventually promises a
-- cross-client report that cannot honestly be built.
--
-- Call types are NOT here. They are the shared tags seeded in migration 004 —
-- at-need, imminent, pre-need, vendor, trade, solicitation, wrong number — and
-- migration 017 gave them the same defaults-plus-additions behaviour.
--
-- Requires: 001 to 017
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- picklists
--
-- Generalised, because next steps will not be the last configurable list. A
-- list is identified by its kind; its items carry the lock.
-- -----------------------------------------------------------------------------
CREATE TYPE picklist_kind AS ENUM (
  'next_step', 'cancellation_reason', 'unqualified_reason', 'service_type');

CREATE TABLE picklist_items (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Null means a Dead Ringers default, visible to every client.
  organization_id   uuid REFERENCES organizations(id) ON DELETE CASCADE,

  picklist          picklist_kind NOT NULL,
  code              text NOT NULL,
  label             text NOT NULL,

  is_default        boolean NOT NULL DEFAULT false,
  hidden            boolean NOT NULL DEFAULT false,
  sort_order        smallint NOT NULL DEFAULT 100,

  created_by        text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX picklist_items_default_uq
  ON picklist_items (picklist, code) WHERE organization_id IS NULL;
CREATE UNIQUE INDEX picklist_items_org_uq
  ON picklist_items (organization_id, picklist, code) WHERE organization_id IS NOT NULL;
CREATE INDEX picklist_items_lookup_idx ON picklist_items (picklist, organization_id);
CREATE TRIGGER picklist_items_touch BEFORE UPDATE ON picklist_items
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE picklist_items ADD CONSTRAINT picklist_items_default_shared_ck
  CHECK (is_default = false OR organization_id IS NULL);

-- Hiding a default is a per-client act, so it cannot be a column on a row every
-- client shares.
CREATE TABLE picklist_item_hidden (
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  picklist_item_id  uuid NOT NULL REFERENCES picklist_items(id) ON DELETE CASCADE,
  hidden_by         text,
  hidden_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id, picklist_item_id)
);

-- Defaults a client can hide or extend, never rename.
INSERT INTO picklist_items (picklist, code, label, is_default, sort_order) VALUES
  ('next_step', 'call_back',         'Call the family back',        true, 10),
  ('next_step', 'send_information',  'Send information',            true, 20),
  ('next_step', 'schedule_arrangement','Schedule an arrangement',   true, 30),
  ('next_step', 'await_family',      'Waiting on the family',       true, 40),
  ('next_step', 'notify_director',   'Notify the on-call director', true, 50),
  ('next_step', 'no_action',         'No further action',           true, 60),
  ('next_step', 'other',             'Other',                       true, 99);

-- What a client actually sees: defaults they have not hidden, plus their own.
CREATE OR REPLACE FUNCTION picklist_for(p_org uuid, p_kind picklist_kind)
RETURNS TABLE (id uuid, code text, label text, is_default boolean, sort_order smallint)
LANGUAGE sql STABLE AS $$
  SELECT i.id, i.code, i.label, i.is_default, i.sort_order
  FROM picklist_items i
  WHERE i.picklist = p_kind
    AND NOT i.hidden
    AND (i.organization_id = p_org
         OR (i.organization_id IS NULL
             AND NOT EXISTS (SELECT 1 FROM picklist_item_hidden h
                             WHERE h.picklist_item_id = i.id
                               AND h.organization_id = p_org)))
  ORDER BY i.sort_order, i.label
$$;

-- Renaming or deleting a default is refused at the database, not in the UI.
CREATE OR REPLACE FUNCTION picklist_items_protect_defaults() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' AND OLD.is_default THEN
    RAISE EXCEPTION 'a Dead Ringers default cannot be deleted — hide it instead';
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.is_default
     AND (NEW.label <> OLD.label OR NEW.code <> OLD.code) THEN
    RAISE EXCEPTION 'a Dead Ringers default cannot be renamed — hide it and add your own';
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;
CREATE TRIGGER picklist_items_protect BEFORE UPDATE OR DELETE ON picklist_items
  FOR EACH ROW EXECUTE FUNCTION picklist_items_protect_defaults();

-- -----------------------------------------------------------------------------
-- custom_fields
--
-- A firm adds a field once, inline, and it appears on every future interaction
-- with that contact or case. The definition is firm-scoped; the value belongs
-- to the contact or the case, never to a single call — which is exactly why it
-- persists across interactions.
-- -----------------------------------------------------------------------------
CREATE TYPE custom_field_entity AS ENUM ('contact', 'case');

CREATE TYPE custom_field_type AS ENUM (
  'text', 'long_text', 'number', 'date', 'boolean', 'single_select', 'multi_select');

CREATE TABLE custom_field_definitions (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,

  entity            custom_field_entity NOT NULL,
  name              text NOT NULL,
  field_type        custom_field_type NOT NULL DEFAULT 'text',

  -- Only for the select types.
  options           jsonb NOT NULL DEFAULT '[]'::jsonb,

  sort_order        smallint NOT NULL DEFAULT 100,
  active            boolean NOT NULL DEFAULT true,
  created_by        text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, entity, name)
);
CREATE INDEX custom_field_definitions_org_idx
  ON custom_field_definitions (organization_id, entity, active);
CREATE TRIGGER custom_field_definitions_touch BEFORE UPDATE
  ON custom_field_definitions FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE custom_field_definitions ADD CONSTRAINT custom_field_options_ck
  CHECK ( field_type NOT IN ('single_select','multi_select')
       OR jsonb_array_length(options) > 0 );

CREATE TABLE custom_field_values (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  definition_id     uuid NOT NULL REFERENCES custom_field_definitions(id) ON DELETE CASCADE,

  contact_id        uuid REFERENCES contacts(id) ON DELETE CASCADE,
  case_id           uuid REFERENCES cases(id) ON DELETE CASCADE,

  value             jsonb NOT NULL,
  set_by            text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX custom_field_values_contact_idx ON custom_field_values (contact_id);
CREATE INDEX custom_field_values_case_idx    ON custom_field_values (case_id);
CREATE UNIQUE INDEX custom_field_values_contact_uq
  ON custom_field_values (definition_id, contact_id) WHERE contact_id IS NOT NULL;
CREATE UNIQUE INDEX custom_field_values_case_uq
  ON custom_field_values (definition_id, case_id) WHERE case_id IS NOT NULL;
CREATE TRIGGER custom_field_values_touch BEFORE UPDATE
  ON custom_field_values FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- A value belongs to a contact or a case. Never both, never neither.
ALTER TABLE custom_field_values ADD CONSTRAINT custom_field_values_target_ck
  CHECK (num_nonnulls(contact_id, case_id) = 1);

-- A value must sit on the kind of thing its definition was made for.
CREATE OR REPLACE FUNCTION custom_field_values_match_entity() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_entity custom_field_entity;
BEGIN
  SELECT entity INTO v_entity FROM custom_field_definitions WHERE id = NEW.definition_id;
  IF v_entity = 'contact' AND NEW.contact_id IS NULL THEN
    RAISE EXCEPTION 'this custom field belongs on a contact'; END IF;
  IF v_entity = 'case' AND NEW.case_id IS NULL THEN
    RAISE EXCEPTION 'this custom field belongs on a case'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER custom_field_values_entity_ck BEFORE INSERT OR UPDATE
  ON custom_field_values FOR EACH ROW EXECUTE FUNCTION custom_field_values_match_entity();

-- -----------------------------------------------------------------------------
-- Next step on the interaction
--
-- Captured at wrap-up. Points at a picklist item so reporting can group by it,
-- with free text for "Other".
-- -----------------------------------------------------------------------------
ALTER TABLE interactions
  ADD COLUMN next_step_item_id uuid REFERENCES picklist_items(id) ON DELETE SET NULL;
ALTER TABLE interactions ADD COLUMN next_step_note text;

-- -----------------------------------------------------------------------------
-- Row-level security
--
-- Default picklist items are readable by everyone; a client's own items and
-- every custom field are tenant-scoped.
-- -----------------------------------------------------------------------------
ALTER TABLE picklist_items           ENABLE ROW LEVEL SECURITY;
ALTER TABLE picklist_item_hidden     ENABLE ROW LEVEL SECURITY;
ALTER TABLE custom_field_definitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE custom_field_values      ENABLE ROW LEVEL SECURITY;

CREATE POLICY picklist_items_visible ON picklist_items
  USING (is_internal()
      OR organization_id IS NULL
      OR organization_id = current_organization_id());
CREATE POLICY picklist_item_hidden_tenant ON picklist_item_hidden
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY custom_field_definitions_tenant ON custom_field_definitions
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY custom_field_values_tenant ON custom_field_values
  USING (is_internal() OR organization_id = current_organization_id());

COMMIT;

-- =============================================================================
-- Verification
--
--   SET app.is_internal = 'on';
--
--   -- seven defaults, in order
--   SELECT * FROM picklist_for(
--     (SELECT id FROM organizations WHERE code='ALT'), 'next_step');
--
--   -- renaming a default should be refused
--   UPDATE picklist_items SET label = 'Ring them back'
--   WHERE code = 'call_back' AND is_default;
--
--   -- a select field with no options should be refused
--   INSERT INTO custom_field_definitions (organization_id, entity, name, field_type)
--   SELECT id, 'contact', 'Preferred contact time', 'single_select'
--   FROM organizations WHERE code='ALT';
-- =============================================================================
