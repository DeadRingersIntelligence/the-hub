-- =============================================================================
-- 017_tag_rules.sql
-- The Hub — Phase 2, migration 17: hiding, renaming, and auto-tagging.
--
-- `tags` and `interaction_tags` landed in migration 004. This adds the
-- lifecycle the interface needs and the rules that apply tags automatically.
--
-- RENAME UPDATES EVERYWHERE. A tag keeps its id and gains a new label, so a
-- call tagged in March reads with the new name in a September report. The
-- rename trail lives in change_history rather than on the tag, because two
-- places holding the same fact is how they drift.
--
-- RULES TAG FORWARD ONLY. A rule created in October never reaches back and
-- changes what September's calls were tagged with. Same principle as freezing
-- benchmarks and freezing first-touch attribution: a number that was reported
-- does not move because a rule was written later.
--
-- Requires: 001 to 016
-- =============================================================================

-- PREREQUISITE — run these two lines as their OWN query first, then this file.
-- A new enum value cannot be used in the transaction that adds it, and the
-- Supabase SQL Editor wraps a whole script in one transaction:
--
--   (now executed below, before the transaction)
--   (now executed below, outside the transaction)

-- NOTE: in the Supabase SQL editor, run the two ALTER TYPE lines below on
-- their own first, then run from BEGIN; to COMMIT;. The editor wraps a whole
-- submission in one transaction, and Postgres cannot use a new enum value in
-- the transaction that adds it.
-- Must run outside the transaction: Postgres cannot use a new enum value
-- in the same transaction that adds it.
ALTER TYPE history_entity ADD VALUE IF NOT EXISTS 'tag';
ALTER TYPE tag_source ADD VALUE IF NOT EXISTS 'auto_rule';

BEGIN;

-- -----------------------------------------------------------------------------
-- Tag lifecycle
--
-- Hiding is not deleting. A hidden tag drops out of every picker while every
-- interaction it was ever applied to keeps it — so a client can retire a tag
-- without rewriting their own history.
-- -----------------------------------------------------------------------------
ALTER TABLE tags ADD COLUMN color        text;
ALTER TABLE tags ADD COLUMN hidden       boolean NOT NULL DEFAULT false;
ALTER TABLE tags ADD COLUMN is_default   boolean NOT NULL DEFAULT false;
ALTER TABLE tags ADD COLUMN created_by   text;

-- The shared tags seeded in 004 are Dead Ringers defaults: a client can hide
-- them or add their own, but cannot rename or delete a default. Defaults are
-- comparable across clients and can carry benchmarks; anything a client adds
-- is firm-only, forever.
UPDATE tags SET is_default = true WHERE organization_id IS NULL;

ALTER TABLE tags ADD CONSTRAINT tags_default_is_shared_ck
  CHECK (is_default = false OR organization_id IS NULL);

-- Rename a tag. Everything already tagged reads with the new label; the trail
-- is written to change_history.
--
-- p_actor_user is the logged-in user where there is one. Without it the rename
-- records as a system action — because change_history refuses a user action
-- that cannot name a user, and a display name is not an identity.
CREATE OR REPLACE FUNCTION rename_tag(
  p_tag uuid, p_new_label text, p_actor text, p_actor_user uuid DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_org uuid; v_old text; v_default boolean;
BEGIN
  SELECT organization_id, label, is_default INTO v_org, v_old, v_default
    FROM tags WHERE id = p_tag;
  IF NOT FOUND THEN RAISE EXCEPTION 'tag not found'; END IF;
  IF v_default THEN
    RAISE EXCEPTION 'a Dead Ringers default tag cannot be renamed — hide it and add your own';
  END IF;
  IF btrim(p_new_label) = '' THEN RAISE EXCEPTION 'a tag needs a label'; END IF;

  UPDATE tags SET label = p_new_label, updated_at = now() WHERE id = p_tag;

  PERFORM record_change(
    v_org, 'tag', p_tag, 'updated',
    CASE WHEN p_actor_user IS NULL THEN 'system' ELSE 'user' END::actor_kind,
    p_actor,
    format('%s renamed the tag "%s" to "%s"', p_actor, v_old, p_new_label),
    p_actor_user,
    jsonb_build_object('renamed_from', v_old, 'renamed_to', p_new_label));
END $$;

-- What a tag used to be called, newest first.
CREATE OR REPLACE FUNCTION tag_rename_history(p_tag uuid)
RETURNS TABLE (renamed_from text, renamed_to text, actor text, at timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT detail->>'renamed_from', detail->>'renamed_to', actor_label, occurred_at
  FROM change_history
  WHERE entity = 'tag' AND entity_id = p_tag AND detail ? 'renamed_from'
  ORDER BY occurred_at DESC
$$;

-- -----------------------------------------------------------------------------
-- auto_tag_rules
--
-- Condition plus target tag. The parameters differ per condition, so they sit
-- in JSONB rather than as columns most rules would leave null.
--
--   arrived_on_line     params: {"phone_number_id": "..."}
--   transcript_mentions params: {"phrases": ["cremation", "prepaid"]}
--   missed              params: {}
--   after_hours         params: {}            — uses the location's hours
--   first_call          params: {}            — no prior interaction for this contact
--   contact_kind        params: {"kind": "business"}
--   need_type           params: {"tag_code": "at_need"}
-- -----------------------------------------------------------------------------
CREATE TYPE tag_rule_condition AS ENUM (
  'arrived_on_line', 'transcript_mentions', 'missed', 'after_hours',
  'first_call', 'contact_kind', 'need_type');

CREATE TABLE auto_tag_rules (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name              text NOT NULL,

  condition         tag_rule_condition NOT NULL,
  params            jsonb NOT NULL DEFAULT '{}'::jsonb,
  tag_id            uuid NOT NULL REFERENCES tags(id) ON DELETE CASCADE,

  active            boolean NOT NULL DEFAULT true,

  -- Forward-only. A rule never applies to an interaction that happened before
  -- the rule existed.
  effective_from    timestamptz NOT NULL DEFAULT now(),

  created_by        text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, name)
);
CREATE INDEX auto_tag_rules_org_idx ON auto_tag_rules (organization_id, active);
CREATE TRIGGER auto_tag_rules_touch BEFORE UPDATE ON auto_tag_rules
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- A rule cannot point at a tag hidden from the people it would tag for.
CREATE OR REPLACE FUNCTION auto_tag_rules_tag_visible() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM tags t WHERE t.id = NEW.tag_id
      AND (t.organization_id IS NULL OR t.organization_id = NEW.organization_id)
      AND t.active AND NOT t.hidden)
  THEN RAISE EXCEPTION 'rule points at a tag that is hidden, inactive, or another client''s';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER auto_tag_rules_tag_ck BEFORE INSERT OR UPDATE ON auto_tag_rules
  FOR EACH ROW EXECUTE FUNCTION auto_tag_rules_tag_visible();

-- -----------------------------------------------------------------------------
-- Which rule applied a tag
--
-- Without this, an auto-applied tag is indistinguishable from one an agent
-- chose — and a client asking "why is this call tagged that" has no answer.
-- -----------------------------------------------------------------------------
ALTER TABLE interaction_tags
  ADD COLUMN applied_by_rule_id uuid REFERENCES auto_tag_rules(id) ON DELETE SET NULL;

ALTER TABLE interaction_tags ADD CONSTRAINT interaction_tags_rule_ck
  CHECK (applied_by_rule_id IS NULL OR tag_source = 'auto_rule');

-- Apply a rule's tag to an interaction, honouring forward-only.
CREATE OR REPLACE FUNCTION apply_tag_rule(p_rule uuid, p_interaction uuid)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE r RECORD; v_occurred timestamptz; v_org uuid;
BEGIN
  SELECT * INTO r FROM auto_tag_rules WHERE id = p_rule AND active;
  IF NOT FOUND THEN RETURN false; END IF;

  SELECT occurred_at, organization_id INTO v_occurred, v_org
    FROM interactions WHERE id = p_interaction;
  IF NOT FOUND OR v_org <> r.organization_id THEN RETURN false; END IF;

  -- The whole point: a rule written today does not reach backwards.
  IF v_occurred < r.effective_from THEN RETURN false; END IF;

  INSERT INTO interaction_tags (organization_id, interaction_id, tag_id,
                                tag_source, applied_by_rule_id)
  VALUES (v_org, p_interaction, r.tag_id, 'auto_rule', p_rule)
  ON CONFLICT (interaction_id, tag_id, tag_source) DO NOTHING;

  RETURN true;
END $$;

-- -----------------------------------------------------------------------------
-- Row-level security
-- -----------------------------------------------------------------------------
ALTER TABLE auto_tag_rules ENABLE ROW LEVEL SECURITY;

CREATE POLICY auto_tag_rules_tenant ON auto_tag_rules
  USING (is_internal() OR organization_id = current_organization_id());

COMMIT;

-- =============================================================================
-- Verification
--
--   SET app.is_internal = 'on';
--
--   -- renaming a Dead Ringers default should be refused
--   SELECT rename_tag((SELECT id FROM tags WHERE code='at_need'),
--                     'Death call', 'Dana R.');
--
--   -- a client tag renames cleanly, and the trail survives
--   INSERT INTO tags (organization_id, code, label, tag_kind, created_by)
--   SELECT id, 'price_shopper', 'Price shopper', 'caller_type', 'Dana R.'
--   FROM organizations WHERE code='ALT';
--
--   SELECT rename_tag((SELECT id FROM tags WHERE code='price_shopper'),
--                     'Researcher', 'Dana R.');
--
--   SELECT * FROM tag_rename_history((SELECT id FROM tags WHERE code='price_shopper'));
-- =============================================================================
