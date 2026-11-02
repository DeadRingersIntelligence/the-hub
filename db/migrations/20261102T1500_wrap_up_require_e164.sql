-- =============================================================================
-- 20261102T1500_wrap_up_require_e164.sql
-- The Hub — the last place a number nobody could read is dropped in silence.
--
-- WHAT WAS WRONG. 055 separated "no number was given" from "a number was given
-- and it can't be read", and moved create_contact() and import_contact_row()
-- onto require_e164(). It named save_wrap_up()'s alternate-phone path as
-- having the identical shape and did not fix it. Nothing has since.
--
-- So today:
--
--   save_wrap_up(..., p_contact => '{"alternate_phone": "ask my daughter"}')
--
-- saves the wrap-up, returns the call id, and drops the number. Nothing errors
-- and nothing on screen says a number was lost — the shape this build keeps
-- finding, and the last of the three places it lived.
--
-- THE CHANGE IS ONE WORD. v_alt reads through require_e164() instead of
-- normalize_e164(). Nothing else in the body moves, and that is load-bearing:
-- the hashes below are only meaningful because the rest is byte-identical.
--
--   v_alt := require_e164(NULLIF(btrim(p_contact->>'alternate_phone'), v_blank));
--
-- Blank behaves exactly as before: require_e164() returns null for null or for
-- whitespace, so an empty field still clears, and the IF v_alt IS NOT NULL
-- below is reached in the same cases. An unreadable number is now refused with
-- the sentence and hint the app's own pre-check already shows, instead of
-- vanishing.
--
-- HOW THE BODY WAS PRODUCED, since the hashes are the whole guarantee. Cut
-- from 053 as committed in the-hub, between the $$ delimiters of
-- save_wrap_up() — from the newline after the opening $$ to the END and one
-- space before the closing $$. That text is 9930 bytes and hashes to
-- 422384043f13e4efbd03a69c9bb0b276, which is what both databases hold. The one
-- substitution gives 9928 bytes and 8b375d22806ac44e0ef26b36370279c0. The
-- migration checks the first before replacing anything and the second after,
-- in the same transaction — so a run that completes has proved that what is
-- now installed is byte-for-byte what was reviewed.
--
-- GRANTS ARE NOT RESTATED. CREATE OR REPLACE keeps them, and 048's
-- REVOKE/GRANT still stands. Re-granting here would be a second statement of
-- a rule this file has no business holding.
--
-- Requires, by what it actually uses:
--   048  save_wrap_up(), whose body this is
--   053  the version of that body this replaces
--   055  require_e164()
--
-- Safe to run twice: the drift check tells "already applied" from "something
-- else changed it", and a second run reinstalls the same body.
--
-- APPLIED to staging and production, 2 Nov 2026, from the file hashed
-- ad1a56ca. The BEGIN … COMMIT body is unchanged since — what is below is
-- what ran. Two comments OUTSIDE it were corrected afterwards, per
-- db/README.md: the count in the STILL TO DO and in the verification's
-- expectation said fourteen, and the four groups beside it are 1 + 6 + 7 + 1.
-- Staging prints fifteen names. The groups and the names were right; the
-- total was arithmetic.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. It must be the body this was cut from
--
-- Three states, because the version this migration writes is not the version
-- it expects to find: a second run has to read as "already applied" rather
-- than as drift.
--
-- Whole-body md5 rather than a substring: this replaces the entire function,
-- so it must replace the one it was copied from. 053 checked 048's body the
-- same way for the same reason.
-- -----------------------------------------------------------------------------
DO $$
DECLARE v text;
BEGIN
  SELECT md5(prosrc) INTO v FROM pg_proc
   WHERE oid = 'save_wrap_up(text, uuid[], text, text, uuid, text, text, timestamptz, text, jsonb, jsonb, jsonb)'::regprocedure;

  IF v IS NULL THEN
    RAISE EXCEPTION 'save_wrap_up does not exist; run 048 and 053 first';
  ELSIF v = '8b375d22806ac44e0ef26b36370279c0' THEN
    RAISE NOTICE 'save_wrap_up already asks require_e164 — this migration has run before; replacing it is a no-op';
  ELSIF v <> '422384043f13e4efbd03a69c9bb0b276' THEN
    RAISE EXCEPTION 'save_wrap_up is neither 053''s version (%) nor this one; stop and compare before replacing it', v;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. 053's body, with the one word changed
-- -----------------------------------------------------------------------------
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
    v_alt := require_e164(NULLIF(btrim(p_contact->>'alternate_phone'), v_blank));
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

-- -----------------------------------------------------------------------------
-- 3. And it is the body that was reviewed
--
-- In the same transaction, so a mismatch rolls the replacement back rather
-- than leaving something nobody has read installed. This is what makes the
-- header's hashes a guarantee instead of a claim.
-- -----------------------------------------------------------------------------
DO $$
DECLARE v text;
BEGIN
  SELECT md5(prosrc) INTO v FROM pg_proc
   WHERE oid = 'save_wrap_up(text, uuid[], text, text, uuid, text, text, timestamptz, text, jsonb, jsonb, jsonb)'::regprocedure;

  IF v <> '8b375d22806ac44e0ef26b36370279c0' THEN
    RAISE EXCEPTION
      'save_wrap_up installed as % — not the reviewed body (8b375d22806ac44e0ef26b36370279c0). Nothing has been kept.', v;
  END IF;
END $$;

COMMIT;

-- =============================================================================
-- STILL TO DO, named so they aren't folded in and skipped
--
-- * THIS IS THE LAST OF THE THREE PATHS 055 NAMED, not the last caller of
--   normalize_e164(). After this runs the scan
--
--     SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--      WHERE n.nspname = 'public' AND p.prosrc LIKE '%normalize_e164%'
--        AND p.prosrc NOT LIKE '%require_e164%' AND p.proname <> 'normalize_e164'
--      ORDER BY 1;
--
--   still returns fifteen functions on both databases. They are not all the
--   same kind of thing, and they are not all fine:
--
--   (a) require_e164 itself, if the scan is written as above: its body calls
--       normalize_e164 and does not contain its own name. A scan artifact,
--       worth knowing before someone "fixes" it.
--
--   (b) Six resolvers, which pass a number IN to a lookup and store nothing —
--       contact_for_number, firm_only_number, resolve_number,
--       organization_for_call, organization_for_number, party_name. Null
--       meaning "matches nothing" is the truth here, and require_e164 would
--       be wrong: a lookup should not raise because somebody typed badly.
--
--   (c) Seven normalize triggers, which DO store the result —
--       contact_phones, directory_entries, interactions, leads,
--       phone_numbers, routing_schedules and users (notify_sms_e164). Every
--       one writes COALESCE(normalize_e164(x), x), so an unreadable value is
--       kept as typed rather than dropped, and the backstop is a CHECK.
--       Three of those tables have one that calls is_e164: contact_phones,
--       directory_entries, phone_numbers. The other four do not, so a
--       mangled number is stored and then matches nothing, silently — the
--       hole 20261030T1500 closed for directory_entries, still open for
--       leads.phone_e164, routing_schedules.target_e164,
--       users.notify_sms_e164 and interactions.from_e164/to_e164.
--
--   (d) ingest_call_event, which is the one to look at. It stores
--       normalize_e164(p_from) and normalize_e164(p_to) with NO COALESCE
--       (047, lines 251 and 280), so a number the carrier sends that cannot
--       be read is stored as NULL and the call loses its other end outright.
--       require_e164 is NOT the answer: raising would discard the whole call
--       event, which is worse than losing the number. The fix is the COALESCE
--       the seven triggers already use — keep what arrived. Its own
--       migration, and it needs 047's live body hash.
--
-- * The wrap-up form already pre-checks the alternate phone with require_e164
--   (hellophone PR #8, comment reworded in #11), so this migration is the
--   backstop rather than the only check — the same arrangement the Settings
--   and Add-contact forms have.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
-- Made-up numbers only. NPA 555 is not assignable, so these reach nobody.
--
-- Set-up failures are reported rather than raised: a wrap-up needs a real
-- call and a real contact, and on a database that has neither, this should
-- cost a line rather than the whole report.
--
-- DO $$
-- DECLARE
--   r text := ''; v_org uuid; v_ref text; v_contact uuid; v_free text;
--   v_before text; v_after text;
-- BEGIN
--   SELECT id INTO v_org FROM organizations WHERE code = 'DR';
--   PERFORM set_config('app.is_internal', 'on', true);
--   PERFORM set_config('app.organization_id', v_org::text, true);
--   PERFORM set_config('app.user_id',
--     (SELECT id::text FROM users WHERE active ORDER BY is_internal DESC LIMIT 1), true);
--
--   r := r || 'installed body: '
--          || (SELECT md5(prosrc) FROM pg_proc
--               WHERE oid = 'save_wrap_up(text, uuid[], text, text, uuid, text, text, timestamptz, text, jsonb, jsonb, jsonb)'::regprocedure)
--          || '   (expect 8b375d22806ac44e0ef26b36370279c0)' || chr(10);
--
--   -- A call with a contact on it, which is what a wrap-up needs.
--   SELECT i.external_call_ref, i.contact_id INTO v_ref, v_contact
--     FROM interactions i
--    WHERE i.organization_id = v_org AND i.contact_id IS NOT NULL
--      AND i.external_call_ref IS NOT NULL
--    ORDER BY i.occurred_at DESC LIMIT 1;
--
--   IF v_ref IS NULL THEN
--     r := r || 'wrap-up tests SKIPPED: no call with a contact on it' || chr(10);
--   ELSE
--     -- The defect, now refused. Before this migration it returned a call id
--     -- and silently stored nothing.
--     BEGIN
--       PERFORM save_wrap_up(v_ref, '{}', NULL, NULL, NULL, NULL, NULL, NULL, NULL,
--                            NULL, '{"alternate_phone": "ask my daughter"}'::jsonb);
--       r := r || 'unreadable alternate phone: ACCEPTED AND DROPPED (BAD)' || chr(10);
--     EXCEPTION WHEN others THEN
--       r := r || 'unreadable alternate phone refused: ' || SQLERRM || chr(10); END;
--
--     -- Blank still clears, which is the behaviour that must NOT change.
--     BEGIN
--       PERFORM save_wrap_up(v_ref, '{}', NULL, NULL, NULL, NULL, NULL, NULL, NULL,
--                            NULL, '{"alternate_phone": "   "}'::jsonb);
--       r := r || 'blank alternate phone still accepted' || chr(10);
--     EXCEPTION WHEN others THEN
--       r := r || 'blank alternate phone REFUSED (BAD): ' || SQLERRM || chr(10); END;
--
--     -- And a readable one is still stored. A free number, so a collision
--     -- costs this line rather than reading as a defect.
--     BEGIN
--       SELECT c.n INTO v_free FROM (
--         SELECT '+1555000' || lpad(g::text, 4, '0') AS n FROM generate_series(1, 9999) g
--       ) c
--        WHERE NOT EXISTS (SELECT 1 FROM contact_phones
--                           WHERE organization_id = v_org AND e164 = c.n)
--          AND NOT EXISTS (SELECT 1 FROM directory_entries
--                           WHERE organization_id = v_org AND e164 = c.n)
--        LIMIT 1;
--
--       PERFORM save_wrap_up(v_ref, '{}', NULL, NULL, NULL, NULL, NULL, NULL, NULL,
--                            NULL, jsonb_build_object('alternate_phone', v_free));
--       r := r || 'readable alternate phone stored: '
--              || (EXISTS (SELECT 1 FROM contact_phones
--                           WHERE contact_id = v_contact AND e164 = v_free))
--              || '   (expect true)' || chr(10);
--     EXCEPTION WHEN others THEN
--       r := r || 'readable alternate phone NOT TESTED: ' || SQLERRM || chr(10); END;
--   END IF;
--
--   -- What still reads with normalize_e164, printed rather than asserted.
--   -- The expectation is a LIST, not a count, and it is not "all fine" — see
--   -- the STILL TO DO above for which group each name falls in. save_wrap_up
--   -- disappearing from it is what this migration is for; ingest_call_event
--   -- remaining in it is the open item.
--   r := r || 'still reading with normalize_e164:' || chr(10) || '    '
--          || COALESCE((SELECT string_agg(p.proname, ', ' ORDER BY p.proname)
--                         FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--                        WHERE n.nspname = 'public'
--                          AND p.prosrc LIKE '%normalize_e164%'
--                          AND p.proname <> 'normalize_e164'
--                          AND p.prosrc NOT LIKE '%require_e164%'), 'none')
--          || chr(10)
--          || '   (expect 15, WITHOUT save_wrap_up: require_e164 itself;'
--          || ' the six resolvers contact_for_number, firm_only_number,'
--          || ' resolve_number, organization_for_call, organization_for_number,'
--          || ' party_name; the seven *_normalize triggers; and'
--          || ' ingest_call_event, which is still open)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261102T1500_wrap_up_require_e164 (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
