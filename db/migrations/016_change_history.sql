-- =============================================================================
-- 016_change_history.sql
-- The Hub — Phase 2, migration 16: the change history a person reads.
--
-- "HelloPhone created this contact from a voicemail."
-- "Dana R. linked this contact to Case: Jim Ellis."
-- "Pat M. merged Mary Ellis into Margaret Ellis."
--
-- This is NOT audit_log. audit_log answers a security question — who viewed or
-- changed what, retained for review. change_history answers a working question
-- an agent asks mid-call: how did this record come to look like this, and who
-- decided it. Different readers, different retention, different shape. Folding
-- them together would mean showing a family-facing screen a security log.
--
-- It is also where link provenance surfaces. Almost nobody will open it, and
-- that is fine — the reason to store provenance is reporting, not the screen.
-- The moment anything counts links between calls and cases, a system-guessed
-- link and a human-confirmed one cannot sit in the same number.
--
-- Requires: 001 to 015
-- =============================================================================

BEGIN;

CREATE TYPE history_entity AS ENUM (
  'contact', 'case', 'decedent', 'interaction', 'lead', 'person');

CREATE TYPE history_action AS ENUM (
  'created', 'updated', 'linked', 'unlinked', 'merged', 'converted',
  'blocked', 'unblocked', 'tagged', 'untagged', 'assigned', 'resolved');

-- Who did it. 'system' covers anything the platform did on its own —
-- creating a contact from a voicemail, applying an auto-tag rule.
CREATE TYPE actor_kind AS ENUM ('user', 'system', 'integration', 'import');

CREATE TABLE change_history (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,

  entity            history_entity NOT NULL,
  entity_id         uuid NOT NULL,
  action            history_action NOT NULL,

  actor_kind        actor_kind NOT NULL,
  actor_user_id     uuid REFERENCES users(id) ON DELETE SET NULL,
  actor_label       text NOT NULL,             -- "Dana R.", "HelloPhone"

  -- One sentence, already written for display. Composing it at read time
  -- means every screen reinvents the wording.
  summary           text NOT NULL,

  -- What changed, and anything the summary doesn't carry: the other side of a
  -- link, the previous value, the rule that fired.
  detail            jsonb NOT NULL DEFAULT '{}'::jsonb,

  -- Set when this row records a link being made, so provenance is queryable
  -- without parsing the summary.
  link_method       link_method,

  occurred_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX change_history_entity_idx
  ON change_history (entity, entity_id, occurred_at DESC);
CREATE INDEX change_history_org_idx
  ON change_history (organization_id, occurred_at DESC);
CREATE INDEX change_history_actor_idx
  ON change_history (actor_user_id) WHERE actor_user_id IS NOT NULL;

-- A user action names a user. A system action must not.
ALTER TABLE change_history ADD CONSTRAINT change_history_actor_ck
  CHECK ( (actor_kind = 'user' AND actor_user_id IS NOT NULL)
       OR (actor_kind <> 'user') );

-- A link event records how the link was made.
ALTER TABLE change_history ADD CONSTRAINT change_history_link_ck
  CHECK (action <> 'linked' OR link_method IS NOT NULL);

-- Write a history row. Thin on purpose: every caller composes its own summary
-- so the wording reads naturally rather than being assembled from fragments.
CREATE OR REPLACE FUNCTION record_change(
  p_org uuid, p_entity history_entity, p_entity_id uuid, p_action history_action,
  p_actor_kind actor_kind, p_actor_label text, p_summary text,
  p_actor_user uuid DEFAULT NULL, p_detail jsonb DEFAULT '{}'::jsonb,
  p_link_method link_method DEFAULT NULL)
RETURNS uuid LANGUAGE sql AS $$
  INSERT INTO change_history (organization_id, entity, entity_id, action,
    actor_kind, actor_user_id, actor_label, summary, detail, link_method)
  VALUES (p_org, p_entity, p_entity_id, p_action,
    p_actor_kind, p_actor_user, p_actor_label, p_summary, p_detail, p_link_method)
  RETURNING id
$$;

-- -----------------------------------------------------------------------------
-- Merging now writes its own history
--
-- A merge is the one action nobody can reconstruct afterwards, so it records
-- itself rather than relying on the caller to remember.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION merge_contacts(p_survivor uuid, p_loser uuid, p_actor text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_org uuid;
  v_survivor_name text;
  v_loser_name text;
  v_moved int;
BEGIN
  IF p_survivor = p_loser THEN RAISE EXCEPTION 'cannot merge a contact into itself'; END IF;

  SELECT organization_id, full_name INTO v_org, v_survivor_name
    FROM contacts WHERE id = p_survivor;
  IF v_org IS NULL THEN RAISE EXCEPTION 'survivor not found'; END IF;

  SELECT full_name INTO v_loser_name
    FROM contacts WHERE id = p_loser AND organization_id = v_org;
  IF NOT FOUND THEN RAISE EXCEPTION 'contacts belong to different organizations'; END IF;

  UPDATE contact_phones
     SET contact_id = p_survivor, is_primary = false, merged_from_contact_id = p_loser
   WHERE contact_id = p_loser;
  GET DIAGNOSTICS v_moved = ROW_COUNT;

  UPDATE interactions             SET contact_id = p_survivor WHERE contact_id = p_loser;
  UPDATE interaction_participants SET contact_id = p_survivor WHERE contact_id = p_loser;
  UPDATE leads                    SET contact_id = p_survivor WHERE contact_id = p_loser;
  UPDATE transcript_segments      SET contact_id = p_survivor WHERE contact_id = p_loser;

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

  PERFORM record_change(
    v_org, 'contact', p_survivor, 'merged', 'user', p_actor,
    format('%s merged %s into %s', p_actor,
           COALESCE(v_loser_name, 'an unnamed contact'),
           COALESCE(v_survivor_name, 'this contact')),
    NULL,
    jsonb_build_object('merged_contact_id', p_loser,
                       'merged_contact_name', v_loser_name,
                       'phone_numbers_moved', v_moved));
END $$;

-- -----------------------------------------------------------------------------
-- Row-level security
--
-- History is readable by the tenant it belongs to — it is a working record an
-- agent reads mid-call, not a security artefact.
-- -----------------------------------------------------------------------------
ALTER TABLE change_history ENABLE ROW LEVEL SECURITY;

CREATE POLICY change_history_tenant ON change_history
  USING (is_internal() OR organization_id = current_organization_id());

COMMIT;

-- =============================================================================
-- Verification
--
--   SET app.is_internal = 'on';
--
--   -- a system-created contact, as HelloPhone would write it
--   SELECT record_change(
--     (SELECT id FROM organizations WHERE code='ALT'),
--     'contact',
--     (SELECT id FROM contacts WHERE full_name='Mary Ellis'),
--     'created', 'system', 'HelloPhone',
--     'HelloPhone created this contact from a voicemail');
--
--   -- a user action with no user should be refused
--   SELECT record_change(
--     (SELECT id FROM organizations WHERE code='ALT'), 'contact',
--     (SELECT id FROM contacts WHERE full_name='Mary Ellis'),
--     'updated', 'user', 'Dana R.', 'Dana R. renamed this contact');
--
--   SELECT occurred_at, actor_label, summary FROM change_history ORDER BY occurred_at;
-- =============================================================================
