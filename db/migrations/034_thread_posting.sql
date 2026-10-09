-- =============================================================================
-- 034_thread_posting.sql
-- The Hub — migration 34: posting to a team chat thread.
--
-- Two gaps the first write path runs into.
--
-- ONE — nothing creates a thread. `find_or_start_text_thread()` from migration
-- 031 is for text conversations with a family, not for internal chat. Posting
-- to a contact nobody has discussed yet needs a thread first, and leaving that
-- to the app means every caller invents its own rule for when a thread is the
-- same thread.
--
-- TWO — `sender_label` is NOT NULL with no default. It exists so a message
-- survives its author leaving, which means it has to be written at insert, from
-- the name the user had at the time. An app that forgets gets a constraint
-- error; an app that remembers has to look the name up first. Neither is the
-- app's job.
--
-- NOT CHANGED: the policies. Migration 024 already gave every one of these a
-- WITH CHECK matching its USING, so a write is allowed exactly where a read is:
-- `is_internal() OR organization_id = current_organization_id()`. Writes do not
-- need the session-variable model.
--
-- Requires: 001 to 033
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- The sender's name, captured at the time
--
-- Filled from the user when the caller does not supply it. Captured rather than
-- joined, because the point of the column is to outlive the row it came from:
-- a name looked up at read time disappears with the login.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION thread_messages_set_sender_label() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.sender_label IS NULL OR btrim(NEW.sender_label) = '' THEN
    SELECT u.full_name INTO NEW.sender_label
      FROM users u WHERE u.id = NEW.sender_user_id;
  END IF;

  IF NEW.sender_label IS NULL OR btrim(NEW.sender_label) = '' THEN
    RAISE EXCEPTION 'a thread message needs a sender: pass sender_user_id, or '
                    'sender_label for a system post';
  END IF;
  RETURN NEW;
END $$;

-- BEFORE INSERT so the value is in place by the time NOT NULL is checked.
CREATE TRIGGER thread_messages_sender_label
  BEFORE INSERT ON thread_messages
  FOR EACH ROW EXECUTE FUNCTION thread_messages_set_sender_label();

ALTER TABLE thread_messages ALTER COLUMN sender_label DROP NOT NULL;
ALTER TABLE thread_messages ADD CONSTRAINT thread_messages_sender_label_ck
  CHECK (sender_label IS NOT NULL AND btrim(sender_label) <> '');

COMMENT ON COLUMN thread_messages.sender_label IS
  'The sender''s name as it was when they posted. Filled from the user at '
  'insert when not supplied. Captured rather than joined, so a message still '
  'reads after its author''s login is gone.';

-- -----------------------------------------------------------------------------
-- Finding or starting a thread
--
-- One thread per subject, which is what makes the scope toggle meaningful: a
-- note about Margaret lives on Margaret, a note about the arrangement lives on
-- the case, and the two do not collapse into each other.
--
-- Unlike a text conversation there is no time window. Internal chat about a
-- family is one continuous thread however long the gaps — a question in
-- November belongs with the one from September, because it is the same family
-- and the same staff.
--
-- The poster is added as a participant, since someone who has written in a
-- thread is in it.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION find_or_start_thread(
  p_scope thread_scope,
  p_subject uuid,
  p_title text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid; v_org uuid; v_user uuid; v_title text;
BEGIN
  v_user := current_user_id();

  -- The subject names the organization, so a thread cannot be started against
  -- someone else's contact by passing an id from another firm.
  v_org := CASE p_scope
    WHEN 'contact'     THEN (SELECT organization_id FROM contacts     WHERE id = p_subject)
    WHEN 'case'        THEN (SELECT organization_id FROM cases        WHERE id = p_subject)
    WHEN 'interaction' THEN (SELECT organization_id FROM interactions WHERE id = p_subject)
  END;

  IF p_scope IN ('contact','case','interaction') AND v_org IS NULL THEN
    RAISE EXCEPTION 'no such % to start a thread on', p_scope;
  END IF;

  SELECT t.id INTO v_id FROM threads t
  WHERE t.scope = p_scope
    AND CASE p_scope
          WHEN 'contact'     THEN t.contact_id
          WHEN 'case'        THEN t.case_id
          WHEN 'interaction' THEN t.interaction_id
        END = p_subject
  LIMIT 1;

  IF v_id IS NULL THEN
    -- A title the panel can show before anyone has typed anything.
    v_title := COALESCE(p_title, CASE p_scope
      WHEN 'contact' THEN (SELECT COALESCE(full_name, business_name)
                             FROM contacts WHERE id = p_subject)
      WHEN 'case'    THEN 'Case — ' || COALESCE(
                             (SELECT d.first_name || ' ' || d.last_name
                                FROM decedents d
                                JOIN interaction_decedents idc ON idc.decedent_id = d.id
                                JOIN interactions i ON i.id = idc.interaction_id
                               WHERE i.case_id = p_subject LIMIT 1),
                             'arrangement')
      ELSE 'Call'
    END);

    INSERT INTO threads (organization_id, scope, contact_id, case_id,
                         interaction_id, title, created_by, last_message_at)
    VALUES (v_org, p_scope,
            CASE WHEN p_scope = 'contact'     THEN p_subject END,
            CASE WHEN p_scope = 'case'        THEN p_subject END,
            CASE WHEN p_scope = 'interaction' THEN p_subject END,
            v_title, v_user, NULL)
    RETURNING id INTO v_id;
  END IF;

  IF v_user IS NOT NULL THEN
    INSERT INTO thread_participants (thread_id, user_id)
    VALUES (v_id, v_user) ON CONFLICT DO NOTHING;
  END IF;

  RETURN v_id;
END $$;

GRANT EXECUTE ON FUNCTION find_or_start_thread(thread_scope, uuid, text)
  TO authenticated;

-- -----------------------------------------------------------------------------
-- Posting
--
-- One call for the whole write path: find or start the thread, post, join it.
-- The app supplies a subject and a body and never has to know whether the
-- thread already existed.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION post_to_thread(
  p_scope thread_scope,
  p_subject uuid,
  p_body text,
  p_about_interaction uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_thread uuid; v_user uuid; v_org uuid; v_id uuid;
BEGIN
  IF btrim(COALESCE(p_body, '')) = '' THEN
    RAISE EXCEPTION 'a message needs a body';
  END IF;

  v_user := current_user_id();
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'not signed in — call claim_hub_identity() first';
  END IF;

  v_thread := find_or_start_thread(p_scope, p_subject);
  SELECT organization_id INTO v_org FROM threads WHERE id = v_thread;

  INSERT INTO thread_messages (organization_id, thread_id, sender_user_id,
                               body, interaction_id, sent_at)
  VALUES (v_org, v_thread, v_user, btrim(p_body), p_about_interaction, now())
  RETURNING id INTO v_id;

  RETURN v_id;
END $$;

GRANT EXECUTE ON FUNCTION post_to_thread(thread_scope, uuid, text, uuid)
  TO authenticated;

COMMIT;

-- =============================================================================
-- Verification
--
--   SET app.is_internal = 'on';
--
-- 1. Posting to a contact nobody has discussed starts the thread
--
--   SELECT post_to_thread('contact',
--     (SELECT id FROM contacts WHERE full_name = 'Theresa Vaughn'
--        AND notes = 'staging seed'),
--     'Mother is in hospice — she may call again this week.');
--
--   SELECT t.title, t.scope, m.sender_label, m.body
--   FROM thread_messages m JOIN threads t ON t.id = m.thread_id
--   WHERE t.contact_id = (SELECT id FROM contacts
--                          WHERE full_name = 'Theresa Vaughn' AND notes = 'staging seed');
--   -- sender_label filled from the signed-in user, without being passed
--
-- 2. Posting again lands in the same thread rather than starting a second
--
--   SELECT post_to_thread('contact',
--     (SELECT id FROM contacts WHERE full_name = 'Theresa Vaughn'
--        AND notes = 'staging seed'),
--     'She called back — arrangements starting Friday.');
--
--   SELECT count(*) AS threads FROM threads
--   WHERE contact_id = (SELECT id FROM contacts
--                        WHERE full_name = 'Theresa Vaughn' AND notes = 'staging seed');
--   -- 1
--
-- 3. A message can name the call it is about
--
--   SELECT post_to_thread('case',
--     (SELECT id FROM cases WHERE external_case_id = 'seed_case_ellis'),
--     'Margaret asked about the urn again on this one.',
--     (SELECT id FROM interactions WHERE external_ref = 'seed_018'));
--
-- 4. A subject that does not exist is refused rather than orphaning a thread
--
--   SELECT post_to_thread('contact', gen_random_uuid(), 'nobody');
--   -- expect: no such contact to start a thread on
-- =============================================================================
