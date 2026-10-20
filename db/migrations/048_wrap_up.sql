-- =============================================================================
-- 048_wrap_up.sql
-- The Hub — migration 48: the in-call wrap-up.
--
-- When a call ends, the person who took it records what it was about before
-- the phone panel clears: call types, who it concerned, the next step, a
-- reminder, a note, and what they learned about the caller. One function
-- writes all of it, in one transaction: a half-saved wrap-up is worse than
-- none.
--
-- THE DECEDENT NAME RULE. Settled in conversation, written down here because
-- it had lived nowhere else:
--
--   A decedent name captured at wrap-up is FREE TEXT ON THE INTERACTION — not
--   a decedents row, and not a case. A case exists only at explicit
--   conversion (005: "Created ONLY at conversion"), and conversion is when
--   the free text becomes a decedent, with the full name 005's
--   decedents_named_ck requires. A later call naming the same decedent
--   SUGGESTS the existing case; it never attaches to it automatically.
--
-- The caller's relationship to that decedent ("daughter") is free text beside
-- the name, for the same reason: its structured home,
-- contact_decedent_links.relationship, needs a decedent, and there isn't one
-- yet.
--
-- NEXT OF KIN IS CAPTURED DETAIL ON THE CALL, never a contact relationship.
-- It is a role relative to the decedent, and situational; a
-- contact_relationships row would assert it permanently between two contacts
-- and be wrong in a year. Like the decedent name, it is promoted at
-- conversion — to case_contacts.role. The wrap-up's picker is the one + Link
-- uses, so its input is the shape that picker produces:
--   {"contact_id": "…"} — someone already a contact: next_of_kin_contact_id.
--     The caller themselves may be the next of kin.
--   {"name": "…"} — someone who isn't a contact yet: next_of_kin_name.
--   Choosing one clears the other; {} clears both. (Changed in review: the
--   draft wrote a contact_relationships row.)
--
-- CONTACTS ARE CREATED EXPLICITLY. Filling an email doesn't make a contact;
-- "Save as a contact" (p_save_contact) does. It writes the contact, adds the
-- caller's number as a contact_phones row so the next call from it matches,
-- and links the call with contact_link_method 'confirmed' (047). It refuses
-- a number that is a directory staff, team or on-call entry (044: the firm's
-- own numbers are never contacts), a number already saved on another contact
-- (link that one instead), and a call that already has a contact. The
-- contact fields (p_contact) need a contact: saved now or already linked.
--
-- WHAT A SECOND SAVE DOES. A wrap-up is one artifact per call: saving again
-- is editing, not adding. The panel posts the whole wrap-up each time, so a
-- second save replaces the call's own fields (types, name, next step, note;
-- next of kin when it's sent). The agent's tags are replaced; tags from rules, routing or AI
-- are never touched. Contact fields change only where a key is present. The
-- reminder this call's wrap-up set is updated, not duplicated — the function
-- guards it (reminders.set_at_wrap_up, one live per call) rather than
-- trusting the panel to send it once. wrapped_up_at keeps the first save: it
-- says whether and when the call was wrapped up, not when it was last edited.
--
-- A NUMBER SAVED BY SOMEONE ELSE AT THE SAME MOMENT. contact_phones is unique
-- on (organization_id, e164) (015), so two saves of one new number can't
-- both land; the loser would get an exception. "Save as a contact" catches
-- that and uses the contact that just won: someone else just saved this
-- number, and theirs is the answer. (Found in review.)
--
-- RIGHTS. Invoker: every table it writes has a tenant policy the caller's
-- firm already writes through (interactions_tenant, interaction_tags_tenant,
-- reminders_tenant, contacts_tenant, contact_phones_tenant). It checks nothing the policies don't, and
-- can't reach another firm's call: the lookup by call ref goes through RLS.
--
-- Requires: 001 to 047
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. On the call
-- -----------------------------------------------------------------------------
ALTER TABLE interactions
  ADD COLUMN decedent_name          text,
  ADD COLUMN decedent_relationship  text,
  ADD COLUMN next_of_kin_name       text,
  ADD COLUMN next_of_kin_contact_id uuid REFERENCES contacts(id) ON DELETE SET NULL,
  ADD COLUMN wrap_up_note           text,
  ADD COLUMN wrapped_up_at          timestamptz,
  ADD COLUMN wrapped_up_by          uuid REFERENCES users(id) ON DELETE SET NULL;

COMMENT ON COLUMN interactions.decedent_name IS
  'Who the call was about, as said, captured at wrap-up. FREE TEXT — not a '
  'decedents row and not a case. Becomes a decedent only at explicit '
  'conversion. A later call naming the same decedent suggests the existing '
  'case and never attaches automatically.';
COMMENT ON COLUMN interactions.decedent_relationship IS
  'The caller''s relationship to decedent_name, as said ("daughter"). Free '
  'text for the same reason: contact_decedent_links needs a decedent.';
ALTER TABLE interactions ADD CONSTRAINT interactions_next_of_kin_one_ck
  CHECK (num_nonnulls(next_of_kin_name, next_of_kin_contact_id) <= 1);

COMMENT ON COLUMN interactions.next_of_kin_name IS
  'Next of kin named on this call who is not a contact yet. Captured detail, '
  'free text; promoted to case_contacts.role at conversion. Never a '
  'contact_relationships row: next of kin is a role relative to the decedent.';
COMMENT ON COLUMN interactions.next_of_kin_contact_id IS
  'Next of kin named on this call who is already a contact (may be the caller). '
  'Captured detail like next_of_kin_name, not a relationship between contacts. '
  'merge_contacts() moves it to the survivor.';

-- The reminder a wrap-up set, so a second save edits it instead of adding one.
ALTER TABLE reminders ADD COLUMN set_at_wrap_up boolean NOT NULL DEFAULT false;
CREATE UNIQUE INDEX reminders_one_live_wrap_up_uq
  ON reminders (interaction_id)
  WHERE set_at_wrap_up AND state IN ('open', 'snoozed');
COMMENT ON COLUMN reminders.set_at_wrap_up IS
  'Set by save_wrap_up(). At most one live (open or snoozed) per call; a '
  'second wrap-up save updates it. Once it is done or canceled, a later save '
  'that sets a reminder makes a new one.';
COMMENT ON COLUMN interactions.wrap_up_note IS
  'The note the person who took the call wrote at wrap-up. Never summary, '
  'which holds the carrier''s AI summary and is overwritten by 041.';
COMMENT ON COLUMN interactions.wrapped_up_at IS
  'When the call was first wrapped up; null on a call nobody wrapped up. '
  'Kept on later edits.';

-- -----------------------------------------------------------------------------
-- 2. On the contact
-- -----------------------------------------------------------------------------
CREATE TYPE contact_method AS ENUM ('call', 'text', 'email', 'mail');

ALTER TABLE contacts
  ADD COLUMN mailing_street       text,
  ADD COLUMN mailing_city         text,
  ADD COLUMN mailing_region       text,
  ADD COLUMN mailing_postal_code  text,
  ADD COLUMN preferred_contact_method contact_method;

COMMENT ON COLUMN contacts.mailing_street IS
  'Mailing address, in parts so sympathy and aftercare mail can be merged. '
  'Street may hold more than one line.';
COMMENT ON COLUMN contacts.preferred_contact_method IS
  'How they asked to be reached. Null when they didn''t say.';

-- -----------------------------------------------------------------------------
-- 3. A merge moves next of kin too
--
-- merge_contacts() repoints every reference to the losing contact; this is
-- one more. As 016 left it, with that line added — and one fix found while
-- verifying it: 016 recorded every merge as a 'user' change with no user id,
-- which change_history_actor_ck refuses, so no merge has ever succeeded
-- (nothing called it). The signed-in user is now recorded; with none, the
-- merge is recorded as 'system' rather than refused. Grants survive CREATE OR
-- REPLACE.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION merge_contacts(p_survivor uuid, p_loser uuid, p_actor text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_org uuid;
  v_survivor_name text;
  v_loser_name text;
  v_moved int;
  v_user uuid := current_user_id();
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
  -- Next of kin captured at wrap-up (048).
  UPDATE interactions SET next_of_kin_contact_id = p_survivor
   WHERE next_of_kin_contact_id = p_loser;

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
    v_org, 'contact', p_survivor, 'merged',
    CASE WHEN v_user IS NOT NULL THEN 'user' ELSE 'system' END::actor_kind, p_actor,
    format('%s merged %s into %s', p_actor,
           COALESCE(v_loser_name, 'an unnamed contact'),
           COALESCE(v_survivor_name, 'this contact')),
    v_user,
    jsonb_build_object('merged_contact_id', p_loser,
                       'merged_contact_name', v_loser_name,
                       'phone_numbers_moved', v_moved));
END $$;

-- -----------------------------------------------------------------------------
-- 4. save_wrap_up()
-- -----------------------------------------------------------------------------
CREATE FUNCTION save_wrap_up(
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
      SELECT d.label INTO v_label FROM directory_entries d
       WHERE d.organization_id = v_org AND d.active
         AND d.entry_kind IN ('staff', 'team', 'on_call') AND d.e164 = v_peer
       LIMIT 1;
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

COMMENT ON FUNCTION save_wrap_up(text, uuid[], text, text, uuid, text, text, timestamptz, text, jsonb, jsonb, jsonb) IS
  'Save a call''s wrap-up in one transaction, by Dial Stack call ref; a '
  'consultation leg''s lands on the call it served. Returns the interaction '
  'id. Invoker rights: RLS decides what it can reach. See 048 for what a '
  'second save replaces and why contacts are only created explicitly.';

REVOKE ALL ON FUNCTION save_wrap_up(text, uuid[], text, text, uuid, text, text, timestamptz, text, jsonb, jsonb, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION save_wrap_up(text, uuid[], text, text, uuid, text, text, timestamptz, text, jsonb, jsonb, jsonb) TO authenticated;

COMMIT;

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
-- Made-up numbers only. app.user_id stands in for a signed-in person; the SQL
-- editor runs as the owner, so RLS is not what's tested here.
--
-- DO $$
-- DECLARE r text := ''; s text; v_org uuid; v_num text; v_user uuid; v_i uuid; v_back uuid;
--         v_c uuid; v_nok uuid; v_tag uuid; v_tag2 uuid; v_step uuid; v_cons uuid;
--         v_caller text := '+15135553333';
-- BEGIN
--   SELECT id INTO v_org FROM organizations WHERE code = 'DR';
--   SELECT e164 INTO v_num FROM phone_numbers WHERE active AND organization_id = v_org ORDER BY e164 LIMIT 1;
--   SELECT u.id INTO v_user FROM users u LIMIT 1;
--   PERFORM set_config('app.user_id', v_user::text, true);
--   SELECT id INTO v_tag  FROM visible_tags(v_org) WHERE NOT hidden_for_firm ORDER BY label LIMIT 1;
--   SELECT id INTO v_tag2 FROM visible_tags(v_org) WHERE NOT hidden_for_firm AND id <> v_tag ORDER BY label LIMIT 1;
--   SELECT id INTO v_step FROM picklist_for(v_org, 'next_step') LIMIT 1;
--
--   v_i := ingest_call_event('call_048_a', 'call.incoming', now() - interval '5 min', 'inbound', v_caller, v_num);
--
--   -- Not arrived yet.
--   BEGIN PERFORM save_wrap_up('call_048_missing'); r := r || 'unknown call: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN no_data_found THEN r := r || 'unknown call refused: ' || SQLERRM || chr(10); END;
--
--   -- Contact fields with no contact: refused, and nothing else saved.
--   BEGIN PERFORM save_wrap_up('call_048_a', ARRAY[v_tag], 'James Ellis', p_contact => '{"email":"a@example.com"}');
--     r := r || 'contact fields without a contact: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN raise_exception THEN r := r || 'contact fields without a contact refused: ' || SQLERRM || chr(10); END;
--   r := r || '  …and the refused save left nothing: '
--          || ((SELECT decedent_name IS NULL AND wrapped_up_at IS NULL FROM interactions WHERE id = v_i)
--              AND NOT EXISTS (SELECT 1 FROM interaction_tags WHERE interaction_id = v_i)) || '   (expect true)' || chr(10);
--
--   -- The full wrap-up: save as a contact, fields, next of kin by name, tags, step, reminder.
--   v_back := save_wrap_up('call_048_a', ARRAY[v_tag, v_tag2], ' James Ellis ', 'daughter', v_step, 'Brochure by Friday',
--               'Asked about cremation costs.', now() + interval '1 hour', 'Send the brochure',
--               '{"full_name":"Margaret Test"}', '{"email":"m@example.com","mailing_city":"Cincinnati","preferred_contact_method":"text","alternate_phone":"(513) 555-2222","alternate_phone_label":"home"}',
--               '{"name":"Tom Test"}');
--   SELECT contact_id, contact_link_method::text INTO v_c, s FROM interactions WHERE id = v_i;
--   r := r || 'contact saved and linked as: ' || coalesce(s, 'NULL') || '   (expect confirmed)' || chr(10);
--   r := r || 'caller''s number on the contact: ' || EXISTS (SELECT 1 FROM contact_phones WHERE contact_id = v_c AND e164 = v_caller)
--          || ', alternate added: ' || EXISTS (SELECT 1 FROM contact_phones WHERE contact_id = v_c AND e164 = '+15135552222' AND label = 'home')
--          || '   (expect true, true)' || chr(10);
--   SELECT email || ' / ' || mailing_city || ' / ' || preferred_contact_method INTO s FROM contacts WHERE id = v_c;
--   r := r || 'contact fields: ' || s || '   (expect m@example.com / Cincinnati / text)' || chr(10);
--   SELECT decedent_name || ' / ' || decedent_relationship || ' / ' || next_of_kin_name || ' / ' || wrap_up_note || ' / ' || (wrapped_up_by = v_user)
--     INTO s FROM interactions WHERE id = v_i;
--   r := r || 'call fields: ' || s || '   (expect James Ellis / daughter / Tom Test / Asked about cremation costs. / true)' || chr(10);
--   r := r || 'no decedent or case created: '
--          || ((SELECT case_id IS NULL FROM interactions WHERE id = v_i)
--              AND NOT EXISTS (SELECT 1 FROM decedents WHERE organization_id = v_org AND last_name = 'Ellis' AND first_name = 'James' AND created_at > now() - interval '1 minute'))
--          || '   (expect true)' || chr(10);
--   r := r || 'agent tags: ' || (SELECT count(*) FROM interaction_tags WHERE interaction_id = v_i AND tag_source = 'agent')
--          || ', reminder: ' || (SELECT count(*) || ' on contact ' || bool_and(contact_id = v_c) FROM reminders WHERE interaction_id = v_i)
--          || '   (expect 2, 1 on contact true)' || chr(10);
--
--   -- A second save: one tag, next of kin as a contact, a rule's tag untouched.
--   INSERT INTO interaction_tags (organization_id, interaction_id, tag_id, tag_source) VALUES (v_org, v_i, v_tag2, 'routing_rule');
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'Brother (test)') RETURNING id INTO v_nok;
--   PERFORM save_wrap_up('call_048_a', ARRAY[v_tag], 'James Ellis', 'daughter',
--             p_reminder_due_at => now() + interval '1 day', p_reminder_note => 'Moved to tomorrow',
--             p_next_of_kin => jsonb_build_object('contact_id', v_nok));
--   r := r || 'after a second save — agent tags: ' || (SELECT count(*) FROM interaction_tags WHERE interaction_id = v_i AND tag_source = 'agent')
--          || ', rule tag kept: ' || EXISTS (SELECT 1 FROM interaction_tags WHERE interaction_id = v_i AND tag_source = 'routing_rule')
--          || ', next of kin on the call: ' || (SELECT next_of_kin_contact_id = v_nok AND next_of_kin_name IS NULL FROM interactions WHERE id = v_i)
--          || ', no relationship row: ' || (NOT EXISTS (SELECT 1 FROM contact_relationships WHERE from_contact_id = v_nok OR to_contact_id = v_nok))
--          || ', reminders: ' || (SELECT count(*) || ' (' || max(note) || ')' FROM reminders WHERE interaction_id = v_i)
--          || '   (expect 1, true, true, true, 1 (Moved to tomorrow))' || chr(10);
--
--   -- A merge moves the next of kin to the survivor.
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'Brother, duplicate (test)') RETURNING id INTO v_cons;
--   PERFORM merge_contacts(v_cons, v_nok, 'verify 048');
--   r := r || 'after merging the next of kin into another contact, the call points at the survivor: '
--          || (SELECT next_of_kin_contact_id = v_cons FROM interactions WHERE id = v_i) || '   (expect true)' || chr(10);
--
--   -- Saving as a contact again is refused; so is a staff number.
--   BEGIN PERFORM save_wrap_up('call_048_a', p_save_contact => '{"full_name":"Again"}'); r := r || 'second contact: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN raise_exception THEN r := r || 'second contact refused: ' || SQLERRM || chr(10); END;
--   INSERT INTO directory_entries (organization_id, entry_kind, label, e164) VALUES (v_org, 'staff', 'Staff cell (test)', '+15135551111');
--   PERFORM ingest_call_event('call_048_s', 'call.incoming', now(), 'inbound', '+15135551111', v_num);
--   BEGIN PERFORM save_wrap_up('call_048_s', p_save_contact => '{"full_name":"Staff"}'); r := r || 'staff number as contact: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN raise_exception THEN r := r || 'staff number refused: ' || SQLERRM || chr(10); END;
--
--   -- A consultation leg's wrap-up lands on the call it served.
--   PERFORM ingest_call_event('call_048_c', 'call.initiated', now() - interval '3 min', 'outbound', v_num, '+15135550000');
--   PERFORM ingest_call_event('call_048_a', 'call.transfer', now() - interval '1 min', 'inbound', v_caller, v_num, NULL, NULL, NULL,
--             jsonb_build_object('data', jsonb_build_object('call_id', 'call_048_a', 'related_call', 'call_048_c', 'transferred_to', '+15135550000')));
--   v_back := save_wrap_up('call_048_c', p_note => 'From the consultation leg');
--   r := r || 'consultation''s wrap-up landed on the original: ' || (v_back = v_i)
--          || ', note: ' || (SELECT wrap_up_note FROM interactions WHERE id = v_i) || '   (expect true, From the consultation leg)' || chr(10);
--
--   r := r || 'authenticated can run save_wrap_up: '
--          || has_function_privilege('authenticated', 'save_wrap_up(text, uuid[], text, text, uuid, text, text, timestamptz, text, jsonb, jsonb, jsonb)', 'EXECUTE')
--          || ', anon: ' || has_function_privilege('anon', 'save_wrap_up(text, uuid[], text, text, uuid, text, text, timestamptz, text, jsonb, jsonb, jsonb)', 'EXECUTE')
--          || '   (expect true, false)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 048 (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
