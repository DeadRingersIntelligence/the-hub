-- =============================================================================
-- 039_tag_hiding.sql
-- The Hub — migration 39: hide a default tag per firm, and stop anyone
-- renaming one for everybody.
--
-- CALL TYPES ARE TAGS. Settled, and the schema already carries it: `tag_kind`
-- is a real enum column — need_type, caller_type, service_interest, quality,
-- other — set on every default. A firm adding its own caller type is an
-- ordinary row with their organization_id and is_default false. No second
-- concept, no data migration.
--
-- TWO GAPS AGAINST THE RULE that defaults can be hidden but not renamed or
-- deleted.
--
-- ONE — `tags.hidden` is a single column on a row every client shares. Hiding a
-- default hides it for everyone, so in practice a firm cannot hide one at all.
-- `picklist_item_hidden` already solved this for next steps; tags need the
-- same table rather than a different answer to the same question.
--
-- TWO — `picklist_items` has a trigger refusing a rename or delete of a
-- default. `tags` has none. `rename_tag()` refuses, but a plain UPDATE from
-- internal staff goes straight through and renames the tag for every client.
--
-- CHECKED AGAINST THE LIVE SCHEMA BEFORE RUNNING; CHANGED FROM THE DRAFT
--   * visible_tags() is SECURITY INVOKER, not DEFINER. As a definer function
--     taking any organization id with no tenancy check, it would have let any
--     signed-in user list another firm's own tags. As invoker, the tags and
--     tag_hidden policies decide what comes back.
--   * The auto-rule check replaces auto_tag_rules_tag_visible(), which is what
--     trigger auto_tag_rules_tag_ck actually calls. The draft created a new
--     function, auto_tag_rules_check_tag(), that nothing called.
--   * The protect trigger also refuses clearing is_default on a default, which
--     would otherwise be a two-step way around every other check here.
--   * A tag_hidden row can only name a shared default. A firm's own tag is
--     hidden with tags.hidden, its own row; two ways to hide one thing is how
--     they come to disagree.
--   * visible_tags() returns the firm's own hidden tags too, flagged, so
--     Settings can show every tag as its comment promised.
--   * anon loses the table grants Supabase's defaults hand every new table.
--   * Messages say "a default tag", not "a Dead Ringers default": they can
--     reach a client's screen.
--
-- Requires: 001 to 038
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Per-firm hiding
--
-- The same shape as picklist_item_hidden: a row means hidden, no row means
-- visible. Nothing to reconcile and nothing to default.
-- -----------------------------------------------------------------------------
CREATE TABLE tag_hidden (
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  tag_id            uuid NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  hidden_by         text,
  hidden_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id, tag_id)
);

COMMENT ON TABLE tag_hidden IS
  'A firm hiding a shared default tag. Presence means hidden. Only shared '
  'defaults go here; a firm''s own tags use tags.hidden, because the row is '
  'theirs.';

CREATE INDEX tag_hidden_tag_idx ON tag_hidden (tag_id);

ALTER TABLE tag_hidden ENABLE ROW LEVEL SECURITY;
ALTER TABLE tag_hidden FORCE ROW LEVEL SECURITY;

CREATE POLICY tag_hidden_read ON tag_hidden FOR SELECT
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY tag_hidden_insert ON tag_hidden FOR INSERT
  WITH CHECK (can_manage_settings()
              AND (is_internal() OR organization_id = current_organization_id())
              AND EXISTS (SELECT 1 FROM tags t
                           WHERE t.id = tag_id AND t.organization_id IS NULL));
CREATE POLICY tag_hidden_delete ON tag_hidden FOR DELETE
  USING (can_manage_settings()
         AND (is_internal() OR organization_id = current_organization_id()));
-- No UPDATE policy: a row here has nothing worth changing. Unhide by deleting.

REVOKE ALL ON tag_hidden FROM PUBLIC, anon;
REVOKE UPDATE ON tag_hidden FROM authenticated;
GRANT SELECT, INSERT, DELETE ON tag_hidden TO authenticated;

-- -----------------------------------------------------------------------------
-- 2. Defaults are protected at the database
--
-- Mirrors picklist_items_protect_defaults(), and also refuses setting `hidden`
-- on a shared default — that column hides it for every client; tag_hidden is
-- the way to hide one for a firm.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tags_protect_defaults() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' AND OLD.is_default THEN
    RAISE EXCEPTION 'a default tag cannot be deleted — hide it for the firm instead';
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.is_default THEN
    IF NOT NEW.is_default THEN
      RAISE EXCEPTION 'a default tag stays a default — add a new tag instead';
    END IF;
    IF NEW.label <> OLD.label OR NEW.code <> OLD.code THEN
      RAISE EXCEPTION 'a default tag cannot be renamed — hide it and add your own';
    END IF;
    IF NEW.tag_kind <> OLD.tag_kind THEN
      RAISE EXCEPTION 'a default tag cannot change kind — cross-client comparisons group on it';
    END IF;
    IF NEW.hidden AND NOT OLD.hidden THEN
      RAISE EXCEPTION 'that would hide the tag for every client — hide it for the firm instead';
    END IF;
    IF NEW.organization_id IS DISTINCT FROM OLD.organization_id THEN
      RAISE EXCEPTION 'a shared default cannot be moved to one firm';
    END IF;
  END IF;

  RETURN COALESCE(NEW, OLD);
END $$;

CREATE TRIGGER tags_protect BEFORE UPDATE OR DELETE ON tags
  FOR EACH ROW EXECUTE FUNCTION tags_protect_defaults();

-- -----------------------------------------------------------------------------
-- 3. What a firm actually sees
--
-- Shared defaults and the firm's own tags, each flagged hidden_for_firm. One
-- place, so the picker, the Settings list and the auto-rule check agree.
--
-- SECURITY INVOKER: the caller's own policies on tags and tag_hidden decide
-- what comes back, so asking about another firm returns only the shared
-- defaults, unflagged — never that firm's tags or choices.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION visible_tags(p_org uuid DEFAULT NULL)
RETURNS TABLE (id uuid, code text, label text, tag_kind tag_kind,
               is_default boolean, hidden_for_firm boolean)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT t.id, t.code, t.label, t.tag_kind, t.is_default,
         (h.tag_id IS NOT NULL OR t.hidden) AS hidden_for_firm
  FROM tags t
  LEFT JOIN tag_hidden h
         ON h.tag_id = t.id
        AND h.organization_id = COALESCE(p_org, current_organization_id())
  WHERE t.active
    AND (t.organization_id IS NULL
         OR t.organization_id = COALESCE(p_org, current_organization_id()))
  ORDER BY t.tag_kind, t.is_default DESC, t.label
$$;

COMMENT ON FUNCTION visible_tags(uuid) IS
  'Every active tag a firm can use, with hidden_for_firm so Settings can show '
  'a hidden tag greyed rather than missing. Pickers filter on '
  'hidden_for_firm = false; Settings shows them all.';

REVOKE ALL ON FUNCTION visible_tags(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION visible_tags(uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- 4. An auto-rule must not point at a tag the firm has hidden
--
-- Replaces the function trigger auto_tag_rules_tag_ck already calls (migration
-- 017), which checked tags.hidden only.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auto_tag_rules_tag_visible() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM tags t
    WHERE t.id = NEW.tag_id AND t.active AND NOT t.hidden
      AND (t.organization_id IS NULL OR t.organization_id = NEW.organization_id))
  THEN RAISE EXCEPTION 'rule points at a tag that is inactive, hidden, or another client''s';
  END IF;

  IF EXISTS (SELECT 1 FROM tag_hidden h
              WHERE h.tag_id = NEW.tag_id AND h.organization_id = NEW.organization_id)
  THEN RAISE EXCEPTION 'rule points at a tag this firm has hidden — unhide it or pick another';
  END IF;

  RETURN NEW;
END $$;

COMMIT;

-- =============================================================================
-- Verification. One block, run as postgres after the migration. It ends by
-- raising its own report, so everything it does — the hidden row, the test
-- tag, the temporary owner — rolls back. Expect no line saying (BAD).
--
--   DO $$
--   DECLARE r text := ''; s text; n int;
--           v_dr uuid; v_alt uuid; v_sol uuid; v_vendor uuid; v_family uuid; v_prof uuid; v_own uuid;
--   BEGIN
--     SELECT id INTO v_dr  FROM organizations WHERE code = 'DR';
--     SELECT id INTO v_alt FROM organizations WHERE code = 'ALT';
--     SELECT id INTO v_sol    FROM tags WHERE code = 'solicitation' AND is_default;
--     SELECT id INTO v_vendor FROM tags WHERE code = 'vendor' AND is_default;
--     SELECT id INTO v_family FROM tags WHERE code = 'family' AND is_default;
--     SELECT user_id INTO v_prof FROM user_scopes
--      WHERE organization_id = v_dr AND view_profile = 'professional' AND revoked_on IS NULL LIMIT 1;
--     PERFORM set_config('app.is_internal', 'on', true);
--
--     -- 1. A default can't be renamed, hidden for everyone, un-defaulted or deleted
--     BEGIN UPDATE tags SET label = 'Renamed' WHERE id = v_sol; r := r || '1a rename: ALLOWED (BAD)' || chr(10);
--     EXCEPTION WHEN OTHERS THEN r := r || '1a rename refused: ' || SQLERRM || chr(10); END;
--     BEGIN UPDATE tags SET hidden = true WHERE id = v_sol; r := r || '1b hide for all: ALLOWED (BAD)' || chr(10);
--     EXCEPTION WHEN OTHERS THEN r := r || '1b hide for all refused: ' || SQLERRM || chr(10); END;
--     BEGIN UPDATE tags SET is_default = false WHERE id = v_sol; r := r || '1c un-default: ALLOWED (BAD)' || chr(10);
--     EXCEPTION WHEN OTHERS THEN r := r || '1c un-default refused: ' || SQLERRM || chr(10); END;
--     BEGIN DELETE FROM tags WHERE id = v_sol; r := r || '1d delete: ALLOWED (BAD)' || chr(10);
--     EXCEPTION WHEN OTHERS THEN r := r || '1d delete refused: ' || SQLERRM || chr(10); END;
--
--     -- 2. Dead Ringers hides solicitation and adds its own caller type
--     INSERT INTO tag_hidden (organization_id, tag_id, hidden_by) VALUES (v_dr, v_sol, 'verification');
--     INSERT INTO tags (organization_id, code, label, tag_kind)
--     VALUES (v_dr, 'pre_arranged_family', 'Pre-arranged family', 'caller_type') RETURNING id INTO v_own;
--     SELECT string_agg(label || CASE WHEN hidden_for_firm THEN ' (hidden)' ELSE '' END
--                             || CASE WHEN is_default THEN '' ELSE ' [firm]' END, ', ') INTO s
--       FROM visible_tags(v_dr) WHERE tag_kind = 'caller_type';
--     r := r || '2 DR caller types: ' || s || chr(10);
--
--     -- 3. Another firm is unaffected
--     SELECT string_agg(label || CASE WHEN hidden_for_firm THEN ' (hidden)' ELSE '' END, ', ') INTO s
--       FROM visible_tags(v_alt) WHERE tag_kind = 'caller_type';
--     r := r || '3 ALT caller types: ' || s || chr(10);
--
--     -- 4. An auto rule can't point at a tag the firm hid
--     BEGIN INSERT INTO auto_tag_rules (organization_id, name, condition, tag_id) VALUES (v_dr, 'verify 039', 'missed', v_sol);
--       r := r || '4 rule on hidden tag: ALLOWED (BAD)' || chr(10);
--     EXCEPTION WHEN OTHERS THEN r := r || '4 rule on hidden tag refused: ' || SQLERRM || chr(10); END;
--
--     -- 5. As a Dead Ringers professional
--     PERFORM set_config('app.is_internal', 'off', true);
--     PERFORM set_config('app.user_id', v_prof::text, true);
--     PERFORM set_config('app.organization_id', v_dr::text, true);
--     SET LOCAL ROLE authenticated;
--     BEGIN INSERT INTO tag_hidden (organization_id, tag_id) VALUES (v_dr, v_vendor); r := r || '5a professional hides: ALLOWED (BAD)' || chr(10);
--     EXCEPTION WHEN OTHERS THEN r := r || '5a professional hide refused: ' || SQLERRM || chr(10); END;
--     DELETE FROM tag_hidden WHERE organization_id = v_dr; GET DIAGNOSTICS n = ROW_COUNT;
--     r := r || '5b professional unhide: rows=' || n || chr(10);
--     SELECT count(*) INTO n FROM visible_tags(v_alt) WHERE NOT is_default;
--     r := r || '5c Altmeyer''s own tags visible to a DR professional: ' || n || chr(10);
--     SELECT count(*) INTO n FROM tag_hidden WHERE organization_id = v_dr;
--     r := r || '5d DR hidden rows the professional can read: ' || n || chr(10);
--     RESET ROLE;
--
--     -- 6. The same person as owner
--     UPDATE user_scopes SET view_profile = 'owner' WHERE user_id = v_prof AND organization_id = v_dr;
--     SET LOCAL ROLE authenticated;
--     BEGIN INSERT INTO tag_hidden (organization_id, tag_id) VALUES (v_dr, v_vendor); r := r || '6a owner hides a default: ok' || chr(10);
--     EXCEPTION WHEN OTHERS THEN r := r || '6a owner hide FAILED: ' || SQLERRM || chr(10); END;
--     BEGIN INSERT INTO tag_hidden (organization_id, tag_id) VALUES (v_dr, v_own); r := r || '6b own tag via tag_hidden: ALLOWED (BAD)' || chr(10);
--     EXCEPTION WHEN OTHERS THEN r := r || '6b own tag via tag_hidden refused: ' || SQLERRM || chr(10); END;
--     BEGIN INSERT INTO tag_hidden (organization_id, tag_id) VALUES (v_alt, v_family); r := r || '6c hide for another firm: ALLOWED (BAD)' || chr(10);
--     EXCEPTION WHEN OTHERS THEN r := r || '6c hide for another firm refused: ' || SQLERRM || chr(10); END;
--     RESET ROLE;
--
--     RAISE EXCEPTION 'VERIFY 039 (all rolled back) %', chr(10) || r;
--   END $$;
-- =============================================================================
