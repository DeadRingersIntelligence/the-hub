-- =============================================================================
-- 055_require_e164.sql
-- The Hub — migration 55: a number nobody could read is not the same as no
-- number.
--
-- APPLIED 29 Oct 2026, staging then production, from the Hub session's copy —
-- which is why this file is reaching the repository after the fact rather than
-- before it ran. Annotated since, not amended: what is below is what ran.
--
-- It keeps its sequence number. 055 is referred to by number throughout
-- 20261030T1500_one_number_rule.sql and by db/README.md's numbering rule, which
-- applies to migrations written after that rule existed.
--
--   * require_e164's own copy of the E.164 pattern, in section 1 below, was
--     replaced on 30 Oct by 20261030T1500_one_number_rule.sql, which moved the
--     pattern into is_e164(). The body below is what ran here; it is not what
--     the database holds now. That file's section 3 is the drift check that
--     recognises this version, and it matches on the pattern this one wrote.
--   * save_wrap_up()'s alternate-phone path, named below as having the
--     identical shape, was not fixed here and has not been fixed since. A
--     number typed into wrap-up that cannot be read is still dropped without a
--     word. Outstanding, as its own migration.
--
-- WHAT WAS WRONG
--
-- normalize_e164() returns null for two different facts: "no number was given"
-- and "a number was given and it can't be read". Every caller in 053 treats
-- null as the first, so:
--
--   create_contact(p_org, 'Margaret Ellis', NULL, 'family', 'ask my daughter')
--
-- creates the contact, returns its id, and silently drops the number. Nothing
-- errors and nothing on screen says a number was lost — the worst shape a
-- defect can take, and the one this build keeps finding.
--
-- save_wrap_up()'s alternate-phone path has the identical shape (its v_alt is
-- normalize_e164(...) and the insert is guarded by IS NOT NULL). It is NOT
-- fixed here — see the note at the end.
--
-- THE FIX, once: require_e164() separates the two. Blank stays null, because a
-- contact with no phone is a real thing. Unreadable raises, with the number the
-- person typed in the message so they can see what the Hub made of it.
--
-- Granted to authenticated as well, so the app's pre-check calls the same rule
-- rather than keeping a fourth copy of it — the same reason create_contact()
-- exists at all.
--
-- Requires: 001 to 054 (051 still unrun and not needed)
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Drift check: these are 053's functions, unchanged since.
-- -----------------------------------------------------------------------------
DO $$
DECLARE v text;
BEGIN
  SELECT prosrc INTO v FROM pg_proc
   WHERE oid = 'create_contact(uuid, text, text, contact_type, text, phone_label, text, text, text)'::regprocedure;
  IF v IS NULL OR v NOT LIKE '%firm_only_number(p_org, v_e164)%'
                OR v NOT LIKE '%normalize_e164(p_number)%' THEN
    RAISE EXCEPTION 'create_contact is not 053''s version; stop and compare before replacing it';
  END IF;

  SELECT prosrc INTO v FROM pg_proc
   WHERE oid = 'import_contact_row(uuid, text, text, contact_type, text, text, text)'::regprocedure;
  IF v IS NULL OR v NOT LIKE '%normalize_e164(p_number)%' THEN
    RAISE EXCEPTION 'import_contact_row is not 053''s version; stop and compare before replacing it';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 1. The rule
--
-- Checked against the pattern contact_phones enforces, not just against null:
-- a value normalize_e164() hands back that still wouldn't satisfy that CHECK
-- should be refused here, with a message about the number, rather than later as
-- a constraint violation with a message about a constraint.
-- -----------------------------------------------------------------------------
CREATE FUNCTION require_e164(raw text) RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE v text;
BEGIN
  -- Nothing given. A contact with no phone is ordinary — an email-only record,
  -- a CSV row with an empty column.
  IF raw IS NULL OR btrim(raw) = '' THEN RETURN NULL; END IF;

  v := normalize_e164(raw);
  IF v IS NULL OR v !~ '^\+[1-9][0-9]{7,14}$' THEN
    RAISE EXCEPTION 'that phone number can''t be read: %', btrim(raw)
      USING ERRCODE = 'P0001',
            HINT = 'Include the area code, for example (513) 555-0100.';
  END IF;
  RETURN v;
END $$;

COMMENT ON FUNCTION require_e164(text) IS
  'A dial string as a stored number, or null when none was given. Raises when '
  'something was given and can''t be read — the distinction normalize_e164() '
  'does not make, which is how an unreadable number used to vanish into a '
  'contact with no phone. Every write path that takes a typed number uses '
  'this; the app calls it for its own check rather than keeping a copy.';

REVOKE ALL ON FUNCTION require_e164(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION require_e164(text) TO authenticated;

-- -----------------------------------------------------------------------------
-- 2. create_contact — 053's text, with the number read through the rule
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION create_contact(
  p_org           uuid,
  p_full_name     text    DEFAULT NULL,
  p_business_name text    DEFAULT NULL,
  p_contact_type  contact_type DEFAULT 'family',
  p_number        text    DEFAULT NULL,
  p_label         phone_label DEFAULT 'mobile',
  p_email         text    DEFAULT NULL,
  p_notes         text    DEFAULT NULL,
  p_added_by      text    DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_contact uuid; v_e164 text; v_existing uuid; v_kind contact_kind; v_label text;
BEGIN
  IF btrim(COALESCE(p_full_name,'')) = ''
     AND btrim(COALESCE(p_business_name,'')) = '' THEN
    RAISE EXCEPTION 'a contact needs a name';
  END IF;

  v_kind := CASE WHEN btrim(COALESCE(p_business_name,'')) <> ''
                  AND btrim(COALESCE(p_full_name,'')) = ''
                 THEN 'business' ELSE 'individual' END::contact_kind;

  -- 055: raises on a number that was given and can't be read, rather than
  -- leaving v_e164 null and dropping it at the insert below.
  v_e164 := require_e164(p_number);

  IF v_e164 IS NOT NULL THEN
    -- The saving rule (053 section 3), not contact_for_number()'s: that decides
    -- what a number MATCHES, and this what may be SAVED. A shared line saves.
    v_label := firm_only_number(p_org, v_e164);
    IF v_label IS NOT NULL THEN
      RAISE EXCEPTION 'that number is in the directory as %, so it belongs to the firm, not to a contact', v_label
            USING ERRCODE = 'P0001';
    END IF;

    SELECT cp.contact_id INTO v_existing FROM contact_phones cp
     WHERE cp.organization_id = p_org AND cp.e164 = v_e164;

    IF v_existing IS NOT NULL THEN
      RAISE EXCEPTION 'that number is already on another contact — link that contact instead'
            USING ERRCODE = 'P0001', DETAIL = v_existing::text;
    END IF;
  END IF;

  INSERT INTO contacts (organization_id, contact_kind, contact_type,
                        full_name, business_name, email, notes)
  VALUES (p_org, v_kind, p_contact_type,
          NULLIF(btrim(COALESCE(p_full_name,'')), ''),
          NULLIF(btrim(COALESCE(p_business_name,'')), ''),
          NULLIF(btrim(COALESCE(p_email,'')), ''),
          p_notes)
  RETURNING id INTO v_contact;

  IF v_e164 IS NOT NULL THEN
    BEGIN
      INSERT INTO contact_phones (organization_id, contact_id, e164, label,
                                  is_primary, added_by)
      VALUES (p_org, v_contact, v_e164, p_label, true,
              COALESCE(p_added_by, 'create_contact'));
    EXCEPTION WHEN unique_violation THEN
      -- Somebody saved this number between the check above and here. Theirs
      -- won; the RAISE undoes our contact with everything else.
      SELECT cp.contact_id INTO v_existing FROM contact_phones cp
       WHERE cp.organization_id = p_org AND cp.e164 = v_e164;
      RAISE EXCEPTION 'that number was just saved on another contact — link that contact instead'
            USING ERRCODE = 'P0001', DETAIL = COALESCE(v_existing::text, '');
    END;
  END IF;

  RETURN v_contact;
END $$;

REVOKE ALL ON FUNCTION create_contact(uuid, text, text, contact_type, text,
                                      phone_label, text, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION create_contact(uuid, text, text, contact_type, text,
                                         phone_label, text, text, text)
  TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. import_contact_row — reports it, never raises
--
-- An import must not stop on row 40 of 300, so an unreadable number is a
-- skipped row with the number in its reason. The operator fixes it in the
-- spreadsheet and runs those rows again; what it must never be is a contact
-- that quietly arrived without a phone.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION import_contact_row(
  p_org           uuid,
  p_full_name     text    DEFAULT NULL,
  p_business_name text    DEFAULT NULL,
  p_contact_type  contact_type DEFAULT 'family',
  p_number        text    DEFAULT NULL,
  p_email         text    DEFAULT NULL,
  p_notes         text    DEFAULT NULL)
RETURNS TABLE (outcome import_outcome, contact_id uuid, detail text)
LANGUAGE plpgsql AS $$
DECLARE v_e164 text; v_existing uuid; v_id uuid;
BEGIN
  IF btrim(COALESCE(p_full_name,'')) = ''
     AND btrim(COALESCE(p_business_name,'')) = '' THEN
    RETURN QUERY SELECT 'skipped'::import_outcome, NULL::uuid, 'no name';
    RETURN;
  END IF;

  IF p_number IS NOT NULL AND btrim(p_number) <> '' THEN
    -- 055: told apart from "no number", and reported rather than dropped.
    BEGIN
      v_e164 := require_e164(p_number);
    EXCEPTION WHEN OTHERS THEN
      RETURN QUERY SELECT 'skipped'::import_outcome, NULL::uuid,
                          'phone number could not be read: ' || btrim(p_number);
      RETURN;
    END;

    IF firm_only_number(p_org, v_e164) IS NOT NULL THEN
      RETURN QUERY SELECT 'skipped'::import_outcome, NULL::uuid,
                          'number is the firm''s own, in the directory';
      RETURN;
    END IF;

    SELECT cp.contact_id INTO v_existing FROM contact_phones cp
     WHERE cp.organization_id = p_org AND cp.e164 = v_e164;

    -- Matched, not merged. The row is reported and nothing is overwritten:
    -- an import must never quietly change a contact a human has edited.
    IF v_existing IS NOT NULL THEN
      RETURN QUERY SELECT 'matched'::import_outcome, v_existing,
                          'number already on an existing contact';
      RETURN;
    END IF;
  END IF;

  BEGIN
    v_id := create_contact(p_org, p_full_name, p_business_name, p_contact_type,
                           p_number, 'mobile', p_email, p_notes, 'csv import');
    RETURN QUERY SELECT 'created'::import_outcome, v_id, NULL::text;
  EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT 'skipped'::import_outcome, NULL::uuid, SQLERRM;
  END;
END $$;

REVOKE ALL ON FUNCTION import_contact_row(uuid, text, text, contact_type,
                                          text, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION import_contact_row(uuid, text, text, contact_type,
                                             text, text, text)
  TO authenticated;

COMMIT;

-- =============================================================================
-- STILL TO DO: save_wrap_up()'s alternate phone
--
-- Its v_alt is normalize_e164(...) guarded by IS NOT NULL, so an unreadable
-- alternate number is dropped exactly as create_contact's was. Fixing it means
-- replacing the whole function, which needs a drift check against the body 053
-- left — and that hash can only be read from a live database:
--
--   SELECT md5(prosrc) FROM pg_proc
--    WHERE oid = 'save_wrap_up(text, uuid[], text, text, uuid, text, text,
--                 timestamptz, text, jsonb, jsonb, jsonb)'::regprocedure;
--
-- Send that and it goes in its own migration, one line changed.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
-- Made-up numbers only.
--
-- DO $$
-- DECLARE r text := ''; v_org uuid; v_id uuid; o import_outcome; d text;
-- BEGIN
--   SELECT id INTO v_org FROM organizations WHERE code = 'DR';
--
--   -- The rule itself
--   r := r || 'blank is no number: ' || (require_e164('   ') IS NULL)
--          || ', messy reads: ' || coalesce(require_e164('(513) 555-0199'), 'null')
--          || '   (expect true, +15135550199)' || chr(10);
--   BEGIN
--     PERFORM require_e164('ask my daughter');
--     r := r || 'unreadable: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN OTHERS THEN r := r || 'unreadable refused: ' || SQLERRM || chr(10); END;
--
--   -- A contact with no number is still fine
--   v_id := create_contact(v_org, 'Verify No Phone', NULL, 'family', NULL, 'mobile', 'v@example.com');
--   r := r || 'no number: created ' || (v_id IS NOT NULL)
--          || ', phones ' || (SELECT count(*) FROM contact_phones WHERE contact_id = v_id)
--          || '   (expect true, 0)' || chr(10);
--
--   -- An unreadable one is refused, and nothing is left behind
--   BEGIN
--     PERFORM create_contact(v_org, 'Verify Bad Phone', NULL, 'family', 'ask my daughter');
--     r := r || 'unreadable on create: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN OTHERS THEN
--     r := r || 'unreadable on create refused' || chr(10); END;
--   r := r || 'no half-made contact: '
--          || NOT EXISTS (SELECT 1 FROM contacts WHERE full_name = 'Verify Bad Phone')
--          || '   (expect true)' || chr(10);
--
--   -- A readable messy one is stored normalized
--   v_id := create_contact(v_org, 'Verify Messy Phone', NULL, 'family', '(513) 555-0199');
--   r := r || 'messy stored as: '
--          || (SELECT e164 FROM contact_phones WHERE contact_id = v_id)
--          || '   (expect +15135550199)' || chr(10);
--
--   -- Import reports it rather than dropping it
--   SELECT outcome, detail INTO o, d
--     FROM import_contact_row(v_org, 'Verify Import Bad', NULL, 'family', 'call the office');
--   r := r || 'import unreadable: ' || o || ' (' || coalesce(d,'') || ')'
--          || '   (expect skipped, says the number)' || chr(10);
--
--   SELECT outcome INTO o
--     FROM import_contact_row(v_org, 'Verify Import No Phone', NULL, 'family', NULL);
--   r := r || 'import no number: ' || o || '   (expect created)' || chr(10);
--
--   r := r || 'anon can call require_e164: '
--          || has_function_privilege('anon', 'require_e164(text)', 'EXECUTE')
--          || ', authenticated: '
--          || has_function_privilege('authenticated', 'require_e164(text)', 'EXECUTE')
--          || '   (expect false, true)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 055 (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
