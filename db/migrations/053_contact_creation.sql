-- =============================================================================
-- 053_contact_creation.sql
-- The Hub — migration 53: one way to create a contact, and what a contact is.
--
-- Reviewed in the Hub chat and revised: matching and saving diverge,
-- save_wrap_up included, comment and Requires corrected.
--
-- THREE WAYS IN, ONE SET OF RULES. A contact can be created during a call, from
-- the Contacts screen, or by CSV import. Today only the first exists, inside
-- save_wrap_up(), and the rules live there: refuse a number in the staff
-- directory, refuse a number already on another contact, write the contact and
-- its number in one transaction. Three more entry points copying those is how
-- they stop agreeing — and the copy that drifts will be the import, which is
-- the one nobody watches run.
--
-- So: create_contact() holds the rules, and every path calls it.
--
-- CORRECTION FROM REVIEW: directory_entries.contact_id already exists (021).
-- The gap was three nullable party references with no rule, not a missing
-- column. And there is no unique rule on a directory number, so one line
-- reaching several people is not forbidden — only unmodelled. Both are
-- recorded below rather than quietly assumed.
--
-- MATCHING AND SAVING DIVERGE (decided in review). The staff rule exists to
-- keep a colleague off a family's timeline, and that harm comes from MATCHING
-- a call to a contact, not from SAVING one:
--   * Matching stays broad. contact_for_number() (044) refuses a number if ANY
--     active staff, team or on-call entry has it. An ambiguous number must not
--     silently attach a family's call to a business when it may have been a
--     colleague: a missed match is visible on screen, a wrong one isn't.
--   * Saving narrows. create_contact(), import_contact_row() and save_wrap_up()
--     refuse only when EVERY active entry on the number is staff, team or
--     on-call: firm_only_number(), below. If any entry is a business, served
--     firm or external, the line is genuinely shared and a hospice is still a
--     hospice. Its calls still won't auto-attach (matching is broad); the firm
--     links them by hand, which is the right friction for an ambiguous number.
--
-- save_wrap_up() is replaced here with that one condition changed, from 048's
-- text (the only definition), behind a drift check that stops if the live
-- function isn't 048's. Rewiring it to call create_contact() is still to do.
--
-- THE APP'S COPY. HelloPhone's saveContactBlock (src/app/actions/wrap-up.ts)
-- checks the staff and existing-holder rules itself before offering "Save as
-- a contact". It is the fourth copy and the likeliest to drift: another
-- language, another repo. After this runs, the app calls firm_only_number()
-- for its hint and renders the function's own refusal — any pre-check is
-- advisory UI, never the thing that decides.
--
-- Requires: 001 to 050. Not 051 (merge chains), which hasn't run and isn't
-- needed here.
-- =============================================================================

-- ---- Run alone, first --------------------------------------------------------
-- (none — contact_type is a new type, created below)
-- ------------------------------------------------------------------------------

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. What this party is
--
-- Single-valued. A clergy member who is also family on a past case is real and
-- rare; multiple types would mean every filter and report deciding what "count
-- the vendors" means for someone who is two things, and that question has no
-- good answer that survives a spreadsheet.
--
-- 'family' is the default because it is the overwhelming majority and because
-- the wrong default should be the harmless one: a vendor mislabelled as family
-- shows up in a list a human reads, where a family member mislabelled as a
-- vendor could be filtered out of one.
-- -----------------------------------------------------------------------------
CREATE TYPE contact_type AS ENUM (
  'family', 'vendor', 'partner', 'contractor', 'clergy', 'government', 'other');

ALTER TABLE contacts
  ADD COLUMN contact_type contact_type NOT NULL DEFAULT 'family';

COMMENT ON COLUMN contacts.contact_type IS
  'What this party is to the firm: family, vendor, partner (hospice, '
  'facility), contractor, clergy, government (coroner, vital records), other. '
  'Single-valued and changeable — someone who is two things gets their primary '
  'role. '
  'NOT the same claim as a caller_type tag. A tag says what one CALL turned '
  'out to be; this says what the PARTY is. A vendor is a vendor before they '
  'ever ring, and an imported contact has no calls to tag. Both are useful and '
  'neither derives from the other.';

COMMENT ON COLUMN contacts.contact_kind IS
  'Whether this is a person or a business — which name field is the real one. '
  'A different axis from contact_type: a hospice is business + partner, a '
  'priest is individual + clergy.';

CREATE INDEX contacts_type_idx
  ON contacts (organization_id, contact_type)
  WHERE merged_into IS NULL;

-- -----------------------------------------------------------------------------
-- 2. The directory's party, made single
--
-- `contact_id` ALREADY EXISTS on directory_entries, from 021, alongside
-- person_id and team_id. Nothing has ever written it. So the gap was real in
-- effect — a hospice kept as a contact and as a destination, with the number in
-- two places — but it was never a missing column. It was three nullable party
-- references and no rule about them.
--
-- The rule: a destination is ONE party. A served firm whose entry needs a named
-- person means that person is the destination; the firm is context on the
-- label, not a second party.
--
-- A SHARED LINE: a served firm with one main line and several reachable
-- people is several entries on one number, and nothing forbids it (021 made no
-- unique rule on e164). The staff checks don't pick an entry — they ask
-- whether any (matching) or every (saving, section 3) active entry on the
-- number is staff, team or on-call — so duplicates don't make them arbitrary.
-- Only naming takes one entry: party_name() (045) by sort_order then label,
-- and firm_only_number() the same way. (save_wrap_up's refusal used LIMIT 1
-- with no order; it now names through firm_only_number().)
-- -----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS directory_entries_contact_idx
  ON directory_entries (contact_id) WHERE contact_id IS NOT NULL;

COMMENT ON COLUMN directory_entries.contact_id IS
  'The contact this destination is, for a business or served firm in the '
  'transfer directory. The contact is who they are; the entry is that they are '
  'a destination. Same party, two facts — so the number is not kept twice.';

-- One party per destination: a person, a team, or a contact. Never two.
ALTER TABLE directory_entries ADD CONSTRAINT directory_entries_one_party_ck
  CHECK (num_nonnulls(person_id, team_id, contact_id) <= 1);

COMMENT ON CONSTRAINT directory_entries_one_party_ck ON directory_entries IS
  'A destination is one party. A served firm needing a named person means that '
  'person is the destination and the firm is context on the label. Does not '
  'cover one shared line reaching several people — that is several entries on '
  'one number, which nothing currently forbids.';

-- A directory entry must not claim a contact at another firm.
CREATE OR REPLACE FUNCTION directory_entries_contact_same_org() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.contact_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM contacts c
                     WHERE c.id = NEW.contact_id
                       AND c.organization_id = NEW.organization_id)
  THEN RAISE EXCEPTION 'that contact belongs to a different firm';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER directory_entries_contact_org_ck
  BEFORE INSERT OR UPDATE OF contact_id ON directory_entries
  FOR EACH ROW EXECUTE FUNCTION directory_entries_contact_same_org();

-- -----------------------------------------------------------------------------
-- 3. Whether a number may be saved as a contact
--
-- The saving rule, once. Not the matching rule: contact_for_number() refuses
-- if ANY staff-type entry has the number; this answers only when EVERY active
-- entry is staff-type. Named for the app too: its "Save as a contact" hint
-- calls this rather than keeping its own copy.
-- -----------------------------------------------------------------------------
CREATE FUNCTION firm_only_number(p_org uuid, p_number text) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT (array_agg(d.label ORDER BY d.sort_order, d.label))[1]
    FROM directory_entries d
   WHERE d.organization_id = p_org AND d.active
     AND d.e164 = normalize_e164(p_number)
  HAVING bool_and(d.entry_kind IN ('staff', 'team', 'on_call'))
$$;

COMMENT ON FUNCTION firm_only_number(uuid, text) IS
  'The directory label when a number is the firm''s alone — every active '
  'entry on it staff, team or on-call — so it can''t be saved as a contact. '
  'Null when it has no entry, or any entry is a business, served firm or '
  'external (a shared line, which may be saved). The SAVING rule; matching '
  'is contact_for_number(), which is broader on purpose. Invoker rights.';

REVOKE ALL ON FUNCTION firm_only_number(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION firm_only_number(uuid, text) TO authenticated;

-- -----------------------------------------------------------------------------
-- 4. Creating a contact
--
-- Invoker rights, like the other write paths: RLS decides what the caller may
-- write, and a refusal is the policies working rather than a bug.
--
-- p_number is optional — a contact created from an email or a CSV row with no
-- phone is still a contact. The number rules apply only when there is one.
-- -----------------------------------------------------------------------------
CREATE FUNCTION create_contact(
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

  IF p_number IS NOT NULL AND btrim(p_number) <> '' THEN
    v_e164 := normalize_e164(p_number);

    -- The saving rule (section 3), not contact_for_number()'s: that decides
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

COMMENT ON FUNCTION create_contact IS
  'The one way to create a contact. Used by the Contacts screen, the mid-call '
  'path and CSV import, so the rules — a name is required, a staff directory '
  'number is refused, a number already on another contact is refused — hold '
  'everywhere rather than in three copies. Invoker rights: RLS decides who '
  'may write.';

REVOKE ALL ON FUNCTION create_contact(uuid, text, text, contact_type, text,
                                      phone_label, text, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION create_contact(uuid, text, text, contact_type, text,
                                         phone_label, text, text, text)
  TO authenticated;

-- -----------------------------------------------------------------------------
-- 5. Importing a row
--
-- One row at a time, reporting what it did, never raising. A batch that fails
-- on row 40 of 300 leaves the importer with no idea what landed, and a batch
-- that silently merges is worse — it is the one case where quiet success is
-- more dangerous than loud failure.
--
-- Matching is deliberately only by number, which is the one identifier that is
-- actually unique. Name similarity is left to merge_candidates() and the merge
-- screen, so the importer and the merge view never disagree about who is a
-- duplicate. An importer that invents its own matching is worse than none.
-- -----------------------------------------------------------------------------
CREATE TYPE import_outcome AS ENUM ('created', 'matched', 'skipped');

CREATE FUNCTION import_contact_row(
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
    v_e164 := normalize_e164(p_number);

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

COMMENT ON FUNCTION import_contact_row IS
  'One CSV row. Returns created, matched or skipped with a reason, and never '
  'raises — so a bad row 40 of 300 does not cost the other 299. Matches only '
  'by number; name-similarity duplicates are left to merge_candidates() and '
  'the merge screen, so the importer cannot disagree with what that screen '
  'shows. Never overwrites an existing contact.';

REVOKE ALL ON FUNCTION import_contact_row(uuid, text, text, contact_type,
                                          text, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION import_contact_row(uuid, text, text, contact_type,
                                             text, text, text)
  TO authenticated;

-- -----------------------------------------------------------------------------
-- 6. save_wrap_up(), with the saving rule
--
-- 048's text exactly, but for the staff check, which now names through
-- firm_only_number(). Stops first if the live function has changed since 048:
-- this replaces the whole body, so it must replace the body it was copied from.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF (SELECT md5(prosrc) FROM pg_proc
       WHERE oid = 'save_wrap_up(text, uuid[], text, text, uuid, text, text, timestamptz, text, jsonb, jsonb, jsonb)'::regprocedure)
     IS DISTINCT FROM 'f9bc944cf31dbdfbef92d847a4e711c6' THEN
    RAISE EXCEPTION 'save_wrap_up has changed since 048; stop and compare before replacing it';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION save_wrap_up(
  p_call_ref               text,
  p_tag_ids                uuid[]      DEFAULT '{}',
  p_decedent_name          text        DEFAULT NULL,
  p_decedent_relationship  text        DEFAULT NULL,
  p_next_step_item_id      uuid        DEFAULT NULL,
  p_next_step_note         text        DEFAULT NULL,
  p_note                   text        DEFAULT NULL,
  p_reminder_due_at        timestamptz DEFAULT NULL,
  p_reminder_note          text        DEFAULT NULL,
  -- {"full_name": "…"} or {"contact_kind": "business", "business_name": "…"}
  p_save_contact           jsonb       DEFAULT NULL,
  -- Any of: email, mailing_street, mailing_city, mailing_region,
  -- mailing_postal_code, preferred_contact_method, alternate_phone,
  -- alternate_phone_label. A present key with an empty value clears it.
  p_contact                jsonb       DEFAULT NULL,
  -- {"contact_id": "…"} or {"name": "…"}; {} clears both. Stored on the call.
  p_next_of_kin            jsonb       DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
  v_id uuid; v_org uuid; v_contact uuid; v_peer text; v_user uuid; v_user_name text;
  v_tag uuid; v_label text; v_kind contact_kind; v_alt text; v_holder uuid; v_nok uuid;
  -- A key present with an empty value means clear it.
  v_blank constant text := '';
BEGIN
  IF p_call_ref IS NULL OR btrim(p_call_ref) = '' THEN
    RAISE EXCEPTION 'a wrap-up needs the call it is for';
  END IF;

  v_user := current_user_id();
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'your sign-in isn''t linked to a Hub user, so a wrap-up can''t be saved';
  END IF;
  SELECT full_name INTO v_user_name FROM users WHERE id = v_user;

  -- The call, through RLS. A consultation leg's wrap-up belongs to the call it
  -- served: the caller's call, which the person is wrapping up.
  SELECT COALESCE(i.consultation_of, i.id) INTO v_id
    FROM interactions i WHERE i.external_call_ref = p_call_ref;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'that call hasn''t reached the Hub yet; try again in a moment'
      USING ERRCODE = 'P0002';
  END IF;

  SELECT organization_id, contact_id,
         CASE WHEN direction = 'inbound' THEN from_e164 ELSE to_e164 END
    INTO v_org, v_contact, v_peer
    FROM interactions WHERE id = v_id
     FOR UPDATE;

  -- ---- Save as a contact -----------------------------------------------------
  IF p_save_contact IS NOT NULL THEN
    IF v_contact IS NOT NULL THEN
      RAISE EXCEPTION 'this call already has a contact';
    END IF;
    v_kind := COALESCE(NULLIF(p_save_contact->>'contact_kind', ''), 'individual')::contact_kind;
    IF v_kind = 'business' AND NULLIF(btrim(p_save_contact->>'business_name'), '') IS NULL THEN
      RAISE EXCEPTION 'a business contact needs its name';
    END IF;
    IF v_kind <> 'business' AND NULLIF(btrim(p_save_contact->>'full_name'), '') IS NULL THEN
      RAISE EXCEPTION 'give the contact a name';
    END IF;
    IF v_peer IS NOT NULL THEN
      -- 053: refused only when the number is the firm's alone (every active
      -- entry on it staff, team or on-call); a shared line can be saved.
      v_label := firm_only_number(v_org, v_peer);
      IF v_label IS NOT NULL THEN
        RAISE EXCEPTION '% is in the directory as %, so it can''t be a contact', v_peer, v_label;
      END IF;
      SELECT cp.contact_id INTO v_holder FROM contact_phones cp
       WHERE cp.organization_id = v_org AND cp.e164 = v_peer;
      IF v_holder IS NOT NULL THEN
        RAISE EXCEPTION 'that number is already saved as %; link that contact instead',
          (SELECT COALESCE(full_name, business_name, 'another contact') FROM contacts WHERE id = v_holder);
      END IF;
    END IF;

    -- In a block of its own: if someone saves this number in the moment
    -- between the check above and here, the new contact is undone and theirs
    -- is used.
    BEGIN
      INSERT INTO contacts (organization_id, contact_kind, full_name, business_name)
      VALUES (v_org, v_kind,
              NULLIF(btrim(p_save_contact->>'full_name'), ''),
              NULLIF(btrim(p_save_contact->>'business_name'), ''))
      RETURNING id INTO v_contact;

      IF v_peer IS NOT NULL THEN
        INSERT INTO contact_phones (organization_id, contact_id, e164, label, is_primary, added_by)
        VALUES (v_org, v_contact, v_peer, 'other', true, v_user_name);
      END IF;
    EXCEPTION WHEN unique_violation THEN
      SELECT COALESCE(c.merged_into, c.id) INTO v_contact
        FROM contact_phones cp JOIN contacts c ON c.id = cp.contact_id
       WHERE cp.organization_id = v_org AND cp.e164 = v_peer;
      IF v_contact IS NULL THEN RAISE; END IF;
    END;

    UPDATE interactions
       SET contact_id = v_contact, contact_link_method = 'confirmed', updated_at = now()
     WHERE id = v_id;
  END IF;

  -- ---- Contact fields ----------------------------------------------------------
  IF p_contact IS NOT NULL AND p_contact <> '{}'::jsonb THEN
    IF v_contact IS NULL THEN
      RAISE EXCEPTION 'save the caller as a contact first';
    END IF;
    UPDATE contacts c SET
      email               = CASE WHEN p_contact ? 'email' THEN NULLIF(btrim(p_contact->>'email'), v_blank) ELSE c.email END,
      mailing_street      = CASE WHEN p_contact ? 'mailing_street' THEN NULLIF(btrim(p_contact->>'mailing_street'), v_blank) ELSE c.mailing_street END,
      mailing_city        = CASE WHEN p_contact ? 'mailing_city' THEN NULLIF(btrim(p_contact->>'mailing_city'), v_blank) ELSE c.mailing_city END,
      mailing_region      = CASE WHEN p_contact ? 'mailing_region' THEN NULLIF(btrim(p_contact->>'mailing_region'), v_blank) ELSE c.mailing_region END,
      mailing_postal_code = CASE WHEN p_contact ? 'mailing_postal_code' THEN NULLIF(btrim(p_contact->>'mailing_postal_code'), v_blank) ELSE c.mailing_postal_code END,
      preferred_contact_method = CASE WHEN p_contact ? 'preferred_contact_method'
                                      THEN NULLIF(p_contact->>'preferred_contact_method', v_blank)::contact_method
                                      ELSE c.preferred_contact_method END,
      updated_at = now()
    WHERE c.id = v_contact;

    -- An alternate number: added to the contact, unless it's already theirs.
    v_alt := normalize_e164(NULLIF(btrim(p_contact->>'alternate_phone'), v_blank));
    IF v_alt IS NOT NULL THEN
      SELECT cp.contact_id INTO v_holder FROM contact_phones cp
       WHERE cp.organization_id = v_org AND cp.e164 = v_alt;
      IF v_holder IS NOT NULL AND v_holder <> v_contact THEN
        RAISE EXCEPTION '% is already saved on %', v_alt,
          (SELECT COALESCE(full_name, business_name, 'another contact') FROM contacts WHERE id = v_holder);
      END IF;
      IF v_holder IS NULL THEN
        BEGIN
          INSERT INTO contact_phones (organization_id, contact_id, e164, label, is_primary, added_by)
          VALUES (v_org, v_contact, v_alt,
                  COALESCE(NULLIF(p_contact->>'alternate_phone_label', v_blank), 'other')::phone_label,
                  false, v_user_name);
        EXCEPTION WHEN unique_violation THEN
          -- Saved by someone else just now: fine if it's this contact's.
          SELECT cp.contact_id INTO v_holder FROM contact_phones cp
           WHERE cp.organization_id = v_org AND cp.e164 = v_alt;
          IF v_holder IS DISTINCT FROM v_contact THEN
            RAISE EXCEPTION '% was just saved on another contact', v_alt;
          END IF;
        END;
      END IF;
    END IF;
  END IF;

  -- ---- Next of kin ---------------------------------------------------------------
  -- Captured on the call, either form; one clears the other.
  IF p_next_of_kin IS NOT NULL THEN
    IF p_next_of_kin ? 'contact_id' THEN
      v_nok := (p_next_of_kin->>'contact_id')::uuid;
      IF NOT EXISTS (SELECT 1 FROM contacts WHERE id = v_nok AND organization_id = v_org) THEN
        RAISE EXCEPTION 'choose a contact at this firm';
      END IF;
      UPDATE interactions SET next_of_kin_contact_id = v_nok, next_of_kin_name = NULL WHERE id = v_id;
    ELSE
      UPDATE interactions
         SET next_of_kin_name = NULLIF(btrim(p_next_of_kin->>'name'), v_blank),
             next_of_kin_contact_id = NULL
       WHERE id = v_id;
    END IF;
  END IF;

  -- ---- Call types: the agent's tags, replaced --------------------------------
  FOREACH v_tag IN ARRAY COALESCE(p_tag_ids, '{}') LOOP
    IF NOT EXISTS (SELECT 1 FROM visible_tags(v_org) t WHERE t.id = v_tag AND NOT t.hidden_for_firm) THEN
      RAISE EXCEPTION 'one of those call types isn''t available to this firm';
    END IF;
  END LOOP;
  DELETE FROM interaction_tags
   WHERE interaction_id = v_id AND tag_source = 'agent'
     AND NOT (tag_id = ANY (COALESCE(p_tag_ids, '{}')));
  INSERT INTO interaction_tags (organization_id, interaction_id, tag_id, tag_source)
  SELECT v_org, v_id, t, 'agent' FROM unnest(COALESCE(p_tag_ids, '{}')) AS t
  ON CONFLICT (interaction_id, tag_id, tag_source) DO NOTHING;

  -- ---- Next step -------------------------------------------------------------------
  IF p_next_step_item_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM picklist_for(v_org, 'next_step') s WHERE s.id = p_next_step_item_id) THEN
    RAISE EXCEPTION 'that next step isn''t available to this firm';
  END IF;

  -- ---- The call's own fields ---------------------------------------------------
  UPDATE interactions SET
    decedent_name         = NULLIF(btrim(p_decedent_name), v_blank),
    decedent_relationship = NULLIF(btrim(p_decedent_relationship), v_blank),
    next_step_item_id     = p_next_step_item_id,
    next_step_note        = NULLIF(btrim(p_next_step_note), v_blank),
    wrap_up_note          = NULLIF(btrim(p_note), v_blank),
    wrapped_up_at         = COALESCE(wrapped_up_at, now()),
    wrapped_up_by         = COALESCE(wrapped_up_by, v_user),
    updated_at            = now()
  WHERE id = v_id;

  -- ---- Reminder ------------------------------------------------------------------------
  IF p_reminder_due_at IS NOT NULL THEN
    IF p_reminder_due_at < now() - interval '1 minute' THEN
      RAISE EXCEPTION 'that reminder time has already passed';
    END IF;
    -- This call's wrap-up reminder, if one is still live: edit it.
    UPDATE reminders
       SET due_at = p_reminder_due_at,
           note = NULLIF(btrim(p_reminder_note), v_blank),
           next_step_item_id = p_next_step_item_id,
           contact_id = v_contact,
           state = 'open', snoozed_until = NULL,
           updated_at = now()
     WHERE interaction_id = v_id AND set_at_wrap_up AND state IN ('open', 'snoozed');
    IF NOT FOUND THEN
      INSERT INTO reminders (organization_id, owner_user_id, interaction_id, contact_id,
                             next_step_item_id, note, due_at, created_by, set_at_wrap_up)
      VALUES (v_org, v_user, v_id, v_contact, p_next_step_item_id,
              NULLIF(btrim(p_reminder_note), v_blank), p_reminder_due_at, v_user_name, true);
    END IF;
  END IF;

  RETURN v_id;
END $$;

COMMIT;

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- DO $$
-- DECLARE r text := ''; v_org uuid; v_a uuid; v_b uuid; v_staff text;
--         o import_outcome; d text; v_id uuid;
-- BEGIN
--   SELECT id INTO v_org FROM organizations WHERE code = 'DR';
--
--   -- A plain create
--   v_a := create_contact(v_org, 'Verify Person', NULL, 'family', '+15550001111');
--   r := r || 'created with type: '
--          || (SELECT contact_type FROM contacts WHERE id = v_a)
--          || ', kind: ' || (SELECT contact_kind FROM contacts WHERE id = v_a)
--          || '   (expect family, individual)' || chr(10);
--
--   -- A business gets the business kind
--   v_b := create_contact(v_org, NULL, 'Verify Hospice', 'partner', '+15550002222');
--   r := r || 'business kind: ' || (SELECT contact_kind FROM contacts WHERE id = v_b)
--          || ', type: ' || (SELECT contact_type FROM contacts WHERE id = v_b)
--          || '   (expect business, partner)' || chr(10);
--
--   -- The same number twice is refused
--   BEGIN
--     PERFORM create_contact(v_org, 'Duplicate Number', NULL, 'family', '+15550001111');
--     r := r || 'duplicate number: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN OTHERS THEN r := r || 'duplicate number refused' || chr(10); END;
--
--   -- A staff directory number is refused
--   SELECT e164 INTO v_staff FROM directory_entries
--    WHERE organization_id = v_org AND active AND entry_kind = 'staff' LIMIT 1;
--   IF v_staff IS NOT NULL THEN
--     BEGIN
--       PERFORM create_contact(v_org, 'Staff As Contact', NULL, 'family', v_staff);
--       r := r || 'staff number: ALLOWED (BAD)' || chr(10);
--     EXCEPTION WHEN OTHERS THEN r := r || 'staff number refused' || chr(10); END;
--   ELSE r := r || 'staff number: no staff entry to test with' || chr(10); END IF;
--
--   -- A shared line saves; a firm-only line doesn't; matching stays broad.
--   INSERT INTO directory_entries (organization_id, entry_kind, label, e164)
--   VALUES (v_org, 'staff', 'Verify Liaison', '+15550007777'),
--          (v_org, 'served_firm', 'Verify Hospice Main', '+15550007777'),
--          (v_org, 'staff', 'Verify Staff Only', '+15550008888');
--   r := r || 'firm_only_number shared: ' || coalesce(firm_only_number(v_org, '+15550007777'), 'null')
--          || ', staff only: ' || coalesce(firm_only_number(v_org, '+15550008888'), 'null')
--          || ', none: ' || coalesce(firm_only_number(v_org, '+15550009999'), 'null')
--          || '   (expect null, Verify Staff Only, null)' || chr(10);
--   v_id := create_contact(v_org, NULL, 'Verify Shared Hospice', 'partner', '+15550007777');
--   r := r || 'shared line saved: ' || (v_id IS NOT NULL)
--          || ', matches it: ' || (contact_for_number(v_org, '+15550007777') IS NOT NULL)
--          || '   (expect true, false)' || chr(10);
--   BEGIN
--     PERFORM create_contact(v_org, 'Verify Staff Cell', NULL, 'family', '+15550008888');
--     r := r || 'firm-only number: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN OTHERS THEN r := r || 'firm-only number refused: ' || SQLERRM || chr(10); END;
--
--   -- A nameless contact is refused
--   BEGIN
--     PERFORM create_contact(v_org, NULL, NULL, 'family', '+15550003333');
--     r := r || 'no name: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN OTHERS THEN r := r || 'no name refused' || chr(10); END;
--
--   -- Import: created, then matched, then skipped
--   SELECT outcome, contact_id INTO o, v_id
--     FROM import_contact_row(v_org, 'Import One', NULL, 'vendor', '+15550004444');
--   r := r || 'import new: ' || o || chr(10);
--
--   SELECT outcome, detail INTO o, d
--     FROM import_contact_row(v_org, 'Import One Again', NULL, 'vendor', '+15550004444');
--   r := r || 'import same number: ' || o || ' (' || coalesce(d,'') || ')'
--          || '   (expect matched, nothing overwritten)' || chr(10);
--   r := r || 'original name kept: '
--          || (SELECT full_name FROM contacts WHERE id = v_id)
--          || '   (expect Import One)' || chr(10);
--
--   SELECT outcome, detail INTO o, d
--     FROM import_contact_row(v_org, NULL, NULL, 'family', '+15550005555');
--   r := r || 'import no name: ' || o || ' (' || coalesce(d,'') || ')' || chr(10);
--
--   -- A directory entry pointing at a contact, and the cross-firm refusal
--   INSERT INTO directory_entries (organization_id, entry_kind, label, e164, contact_id)
--   VALUES (v_org, 'business', 'Verify Hospice', '+15550002222', v_b);
--   r := r || 'directory entry linked to contact: true' || chr(10);
--
--   BEGIN
--     INSERT INTO directory_entries (organization_id, entry_kind, label, e164,
--                                    person_id, contact_id)
--     SELECT v_org, 'business', 'Both', '+15550006666', p.id, v_b
--       FROM people p WHERE p.organization_id = v_org LIMIT 1;
--     r := r || 'two parties on one entry: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN check_violation THEN
--     r := r || 'two parties on one entry refused' || chr(10); END;
--
--   r := r || 'save_wrap_up uses the saving rule: '
--          || (SELECT prosrc LIKE '%firm_only_number(v_org, v_peer)%' FROM pg_proc
--               WHERE oid = 'save_wrap_up(text, uuid[], text, text, uuid, text, text, timestamptz, text, jsonb, jsonb, jsonb)'::regprocedure)
--          || '   (expect true)' || chr(10);
--
--   r := r || 'anon can execute create_contact: '
--          || has_function_privilege('anon',
--               'create_contact(uuid, text, text, contact_type, text, phone_label, text, text, text)',
--               'EXECUTE')
--          || '   (expect false)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 053 (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
