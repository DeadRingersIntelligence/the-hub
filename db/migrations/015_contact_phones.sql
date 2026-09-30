-- =============================================================================
-- 015_contact_phones.sql
-- The Hub — Phase 2, migration 15: a contact holds many numbers, and merging.
--
-- `contacts` shipped with phone_e164 and secondary_phone_e164. Two columns is
-- enough for a family — a daughter with a cell and a landline — and not enough
-- for the repeat business callers that generate the most volume. A vet clinic
-- has a main line, a direct line for the tech who handles cremations, and an
-- after-hours number. A hospice has a main line and a nurse's cell.
--
-- Two columns also can't do two things this build needs:
--   matching becomes "WHERE phone = X OR secondary_phone = X", which cannot
--   use one clean index and has to be written correctly in every query;
--   and a merge leaves no record of which number arrived from which contact,
--   so an incorrect merge cannot be unwound.
--
-- Safe to run now: nothing is live in contacts except seeded shop data.
--
-- Requires: 001 to 014
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- contact_phones
--
-- Every number a contact can be reached on. Matching an inbound call is a join
-- against this table, not an OR across columns.
-- -----------------------------------------------------------------------------
CREATE TYPE phone_label AS ENUM (
  'mobile', 'home', 'work', 'main', 'direct', 'after_hours', 'fax', 'other');

CREATE TABLE contact_phones (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  contact_id        uuid NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,

  e164              text NOT NULL,
  display           text,
  label             phone_label NOT NULL DEFAULT 'other',
  is_primary        boolean NOT NULL DEFAULT false,

  -- Where this number came from. After a merge, says which contact carried it
  -- in — which is what makes an incorrect merge reversible.
  added_by          text,
  merged_from_contact_id uuid REFERENCES contacts(id) ON DELETE SET NULL,

  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX contact_phones_contact_idx ON contact_phones (contact_id);
CREATE TRIGGER contact_phones_touch BEFORE UPDATE ON contact_phones
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE contact_phones ADD CONSTRAINT contact_phones_e164_ck
  CHECK (e164 ~ '^\+[1-9][0-9]{7,14}$');

-- One number reaches one contact within an organization. This is the only
-- automatic matching rule there is: same number, same contact.
CREATE UNIQUE INDEX contact_phones_org_number_uq
  ON contact_phones (organization_id, e164);

-- At most one primary per contact.
CREATE UNIQUE INDEX contact_phones_one_primary_uq
  ON contact_phones (contact_id) WHERE is_primary;

CREATE OR REPLACE FUNCTION contact_phones_normalize() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.e164 := COALESCE(normalize_e164(NEW.e164), NEW.e164);
  RETURN NEW;
END $$;
CREATE TRIGGER contact_phones_normalize_t BEFORE INSERT OR UPDATE ON contact_phones
  FOR EACH ROW EXECUTE FUNCTION contact_phones_normalize();

-- -----------------------------------------------------------------------------
-- Move what's already there, then retire the columns
-- -----------------------------------------------------------------------------
INSERT INTO contact_phones (organization_id, contact_id, e164, label, is_primary, added_by)
SELECT organization_id, id, phone_e164, 'mobile', true, 'migrated from contacts.phone_e164'
FROM contacts WHERE phone_e164 IS NOT NULL
ON CONFLICT (organization_id, e164) DO NOTHING;

INSERT INTO contact_phones (organization_id, contact_id, e164, label, is_primary, added_by)
SELECT organization_id, id, secondary_phone_e164, 'other', false,
       'migrated from contacts.secondary_phone_e164'
FROM contacts WHERE secondary_phone_e164 IS NOT NULL
ON CONFLICT (organization_id, e164) DO NOTHING;

-- Two places holding the same fact is how they drift. The table is the truth.
DROP TRIGGER IF EXISTS contacts_normalize_t ON contacts;
DROP FUNCTION IF EXISTS contacts_normalize();
DROP INDEX IF EXISTS contacts_org_phone_idx;
ALTER TABLE contacts DROP COLUMN phone_e164;
ALTER TABLE contacts DROP COLUMN secondary_phone_e164;

-- Resolve an inbound number to a contact. One index, one join.
CREATE OR REPLACE FUNCTION contact_for_number(p_org uuid, raw text)
RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT COALESCE(c.merged_into, c.id)
  FROM contact_phones p
  JOIN contacts c ON c.id = p.contact_id
  WHERE p.organization_id = p_org
    AND p.e164 = normalize_e164(raw)
  LIMIT 1
$$;

-- -----------------------------------------------------------------------------
-- Merge
--
-- Duplicate names are expected — two real John Smiths are two contacts. Name
-- alone is far too weak a signal to merge on. Name PLUS a shared link — the
-- same case, or the same related contact — is strong enough to be worth
-- asking about and rare enough not to nag.
--
-- The prompt is dismissible, and a dismissal is remembered, so two genuine
-- John Smiths are never asked about twice.
-- -----------------------------------------------------------------------------
CREATE TABLE contact_merge_dismissals (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  -- Stored lowest-id-first so the pair is order-independent.
  contact_a_id      uuid NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
  contact_b_id      uuid NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
  dismissed_by      text NOT NULL,
  dismissed_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (contact_a_id, contact_b_id)
);
ALTER TABLE contact_merge_dismissals ADD CONSTRAINT merge_dismissal_order_ck
  CHECK (contact_a_id < contact_b_id);

-- Candidates: same organization, same name, not already merged, sharing a case
-- or a related contact, and not previously dismissed.
CREATE OR REPLACE FUNCTION merge_candidates(p_org uuid)
RETURNS TABLE (contact_a uuid, contact_b uuid, full_name text, shared_case uuid)
LANGUAGE sql STABLE AS $$
  SELECT DISTINCT LEAST(a.id, b.id), GREATEST(a.id, b.id), a.full_name, ca.case_id
  FROM contacts a
  JOIN contacts b
    ON b.organization_id = a.organization_id
   AND b.id <> a.id
   AND lower(btrim(b.full_name)) = lower(btrim(a.full_name))
  JOIN case_contacts ca ON ca.contact_id = a.id
  JOIN case_contacts cb ON cb.contact_id = b.id AND cb.case_id = ca.case_id
  WHERE a.organization_id = p_org
    AND a.merged_into IS NULL AND b.merged_into IS NULL
    AND a.full_name IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM contact_merge_dismissals d
      WHERE d.contact_a_id = LEAST(a.id, b.id)
        AND d.contact_b_id = GREATEST(a.id, b.id))
$$;

-- Merge. Everything moves to the survivor; the loser keeps its id and points
-- at the survivor, so nothing orphans and the merge can be traced.
--
-- Change history is written by the caller — it is the one action nobody can
-- reconstruct afterwards. `change_history` lands in migration 016.
CREATE OR REPLACE FUNCTION merge_contacts(p_survivor uuid, p_loser uuid, p_actor text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_org uuid;
BEGIN
  IF p_survivor = p_loser THEN RAISE EXCEPTION 'cannot merge a contact into itself'; END IF;

  SELECT organization_id INTO v_org FROM contacts WHERE id = p_survivor;
  IF v_org IS NULL THEN RAISE EXCEPTION 'survivor not found'; END IF;
  IF NOT EXISTS (SELECT 1 FROM contacts WHERE id = p_loser AND organization_id = v_org)
    THEN RAISE EXCEPTION 'contacts belong to different organizations'; END IF;

  UPDATE contact_phones
     SET contact_id = p_survivor,
         is_primary = false,
         merged_from_contact_id = p_loser
   WHERE contact_id = p_loser;

  UPDATE interactions            SET contact_id = p_survivor WHERE contact_id = p_loser;
  UPDATE interaction_participants SET contact_id = p_survivor WHERE contact_id = p_loser;
  UPDATE leads                   SET contact_id = p_survivor WHERE contact_id = p_loser;
  UPDATE transcript_segments     SET contact_id = p_survivor WHERE contact_id = p_loser;

  -- Join rows may already exist on the survivor; move what doesn't, drop what does.
  UPDATE case_contacts SET contact_id = p_survivor
   WHERE contact_id = p_loser
     AND NOT EXISTS (SELECT 1 FROM case_contacts s
                     WHERE s.contact_id = p_survivor AND s.case_id = case_contacts.case_id);
  DELETE FROM case_contacts WHERE contact_id = p_loser;

  UPDATE contact_decedent_links SET contact_id = p_survivor
   WHERE contact_id = p_loser
     AND NOT EXISTS (SELECT 1 FROM contact_decedent_links s
                     WHERE s.contact_id = p_survivor
                       AND s.decedent_id = contact_decedent_links.decedent_id);
  DELETE FROM contact_decedent_links WHERE contact_id = p_loser;

  UPDATE contacts SET merged_into = p_survivor, updated_at = now() WHERE id = p_loser;
END $$;

-- -----------------------------------------------------------------------------
-- Row-level security
-- -----------------------------------------------------------------------------
ALTER TABLE contact_phones           ENABLE ROW LEVEL SECURITY;
ALTER TABLE contact_merge_dismissals ENABLE ROW LEVEL SECURITY;

CREATE POLICY contact_phones_tenant ON contact_phones
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY contact_merge_dismissals_tenant ON contact_merge_dismissals
  USING (is_internal() OR organization_id = current_organization_id());

COMMIT;
