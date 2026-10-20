-- =============================================================================
-- 047_contact_provenance_and_auto_cancel.sql
-- The Hub — migration 47: how a call got its contact, and reminders that
-- close themselves when the person calls.
--
-- Two changes to ingestion, together because both rewrite ingest_call_event()
-- and one rewrite is easier to review than two. They come before the wrap-up
-- (048), which depends on both.
--
-- 1. CONTACT PROVENANCE. interactions.contact_id has been a bare reference:
--    the one place the schema departs from standing rule 4. Everywhere else a
--    link says how it was made (contact_decedent_links.link_method,
--    interaction_links.link_method). 045's party_name already treats a linked
--    contact as a deliberate choice; 046's trigger clears a contact without
--    being able to tell. This adds contact_link_method, using the existing
--    link_method type:
--      inferred  — ingestion matched it by number (contact_for_number);
--      confirmed — a person chose it (save_wrap_up's "Save as a contact", 048);
--      imported  — it arrived with seeded or loaded data;
--      writeback — reserved, as on the other links.
--    Set whenever contact_id is set and cleared with it, by a check. 046's
--    trigger now clears only 'inferred': a human correction never loses to a
--    derived match.
--
-- 2. AUTO-CANCEL. 020 made reminders.cancel_on_inbound default true and wrote
--    cancel_reminders_on_inbound(), but nothing ever called it: no reminder
--    has ever auto-canceled. That stays invisible while the app never creates
--    reminders, and stops being invisible the moment wrap-up does. Ingestion
--    now calls it when an inbound call from the contact is ANSWERED BY A
--    PERSON — a missed call from them is a reason to call back, not evidence
--    the follow-up happened. 020's wording ("an inbound call ... means the
--    follow-up already happened") is narrowed to that on purpose.
--
--    Only reminders that predate the call are canceled, and never one set on
--    the call itself, so a reminder made at this call's wrap-up survives this
--    call's own late or retried events. Each cancellation is labeled, since
--    there is no signed-in user to record from the webhook.
--
-- 3. THE CLOSER STAMP LETS A SYSTEM CLOSE NAME ITSELF. 037's
--    reminders_stamp_closer() overwrites closed_by_label unconditionally from
--    current_user_id() — right for a person (no stale or misattributed
--    closer survives), but in a webhook there is no user, so the label above
--    would be silently nulled and every auto-canceled reminder would read as
--    closed by nobody. Now: with a signed-in user, they are the closer, as
--    before; without one, a label set by this same update stands, and a label
--    left over from an earlier close is still cleared. (Found in review.)
--
-- WHAT IT DOESN'T DO. It doesn't reopen anything, and it doesn't backfill:
-- reminders that should have auto-canceled in the past stay as they are.
--
-- Requires: 001 to 046
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. contact_link_method
-- -----------------------------------------------------------------------------
ALTER TABLE interactions ADD COLUMN contact_link_method link_method;

COMMENT ON COLUMN interactions.contact_link_method IS
  'How contact_id was set: inferred (matched by number at ingestion), '
  'confirmed (a person chose it), imported (seeded or loaded data). Null '
  'exactly when contact_id is. Anything that clears or replaces a contact on '
  'its own initiative touches inferred links only.';

-- What's already stored: ingested calls were matched by number; everything
-- else (seeds, imports) arrived with its contact.
UPDATE interactions
   SET contact_link_method = CASE WHEN external_call_ref IS NOT NULL
                                  THEN 'inferred' ELSE 'imported' END::link_method
 WHERE contact_id IS NOT NULL;

-- Cleared with the contact, whoever clears it (044, 046, a merge's loser).
CREATE FUNCTION interactions_contact_link_clear() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.contact_id IS NULL THEN NEW.contact_link_method := NULL; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER interactions_contact_link_clear_t
  BEFORE INSERT OR UPDATE OF contact_id ON interactions
  FOR EACH ROW EXECUTE FUNCTION interactions_contact_link_clear();

ALTER TABLE interactions ADD CONSTRAINT interactions_contact_link_method_ck
  CHECK ((contact_id IS NULL) = (contact_link_method IS NULL));

-- 046's trigger, narrowed: a staff number added to the directory releases
-- the calls it was matched to, and leaves a contact a person chose.
CREATE OR REPLACE FUNCTION directory_entries_release_contacts() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE interactions i
     SET contact_id = NULL, updated_at = now()
   WHERE i.organization_id = NEW.organization_id
     AND i.contact_id IS NOT NULL
     AND i.contact_link_method = 'inferred'
     AND NEW.e164 = CASE WHEN i.direction = 'inbound' THEN i.from_e164 ELSE i.to_e164 END;
  RETURN NULL;
END $$;

COMMENT ON FUNCTION directory_entries_release_contacts() IS
  'After an active staff, team or on-call entry gains a number: clear the '
  'contact on the firm''s stored calls matched to it by number (inferred). '
  'A contact a person chose (confirmed) stays. Invoker rights: '
  'interactions_tenant already lets the writer update them.';

-- -----------------------------------------------------------------------------
-- 2. The closer stamp, for a close with no signed-in user
--
-- As 037 left it, with the closer branch split on whether there is a user.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reminders_stamp_closer() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_user uuid;
BEGIN
  IF NEW.state = OLD.state THEN RETURN NEW; END IF;

  -- Reopening, or going back to snoozed, clears the record rather than leaving
  -- a stale closer on something that is live again.
  IF NEW.state IN ('open', 'snoozed') THEN
    NEW.closed_at := NULL; NEW.closed_by_user_id := NULL;
    NEW.closed_by_label := NULL; NEW.completed_at := NULL;
    RETURN NEW;
  END IF;

  v_user := current_user_id();
  NEW.closed_at    := now();
  NEW.completed_at := CASE WHEN NEW.state = 'done' THEN now() END;

  IF v_user IS NOT NULL THEN
    NEW.closed_by_user_id := v_user;
    NEW.closed_by_label   := (SELECT full_name FROM users WHERE id = v_user);
  ELSE
    -- No signed-in user: a system close may name itself, but a label left
    -- over from an earlier close must not survive.
    NEW.closed_by_user_id := NULL;
    NEW.closed_by_label   := CASE
      WHEN NEW.closed_by_label IS DISTINCT FROM OLD.closed_by_label
      THEN NEW.closed_by_label END;
  END IF;

  RETURN NEW;
END $$;

-- -----------------------------------------------------------------------------
-- 3. Auto-cancel
--
-- 020's one-argument version is replaced, not overloaded: it has never been
-- called, and a second signature beside it would be a second way to do this.
-- It is called only from ingest_call_event(), a definer function, so it takes
-- the firm from the call rather than trusting a caller, and no client role
-- may execute it.
-- -----------------------------------------------------------------------------
DROP FUNCTION cancel_reminders_on_inbound(uuid);

CREATE FUNCTION cancel_reminders_on_inbound(p_contact uuid, p_call uuid)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE n integer; v_org uuid; v_started timestamptz;
BEGIN
  SELECT organization_id, started_at INTO v_org, v_started FROM interactions WHERE id = p_call;
  IF v_org IS NULL OR v_started IS NULL THEN RETURN 0; END IF;

  UPDATE reminders r
     SET state = 'canceled',
         closed_by_label = 'Canceled automatically: they called and reached someone',
         updated_at = now()
   WHERE r.organization_id = v_org
     AND r.cancel_on_inbound
     AND r.state IN ('open', 'snoozed')
     AND r.created_at < v_started
     AND r.interaction_id IS DISTINCT FROM p_call
     -- Set on the contact, or on one of their calls.
     AND (r.contact_id = p_contact
          OR r.interaction_id IN (SELECT i.id FROM interactions i
                                   WHERE i.organization_id = v_org AND i.contact_id = p_contact));
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

COMMENT ON FUNCTION cancel_reminders_on_inbound(uuid, uuid) IS
  'Cancel the open and snoozed reminders on this contact (or their calls) that '
  'predate p_call, because they called and reached someone. Called by '
  'ingest_call_event on an inbound call answered by a person. Not for clients.';

REVOKE ALL ON FUNCTION cancel_reminders_on_inbound(uuid, uuid) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 4. Ingestion
--
-- The whole function, as 042 left it, with two changes: a new call's contact
-- is marked 'inferred', and an inbound call answered by a person cancels the
-- reminders it overtakes. Grants (service role only) survive CREATE OR REPLACE.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ingest_call_event(
  p_call_ref      text,
  p_event_type    text,
  p_occurred_at   timestamptz,
  p_direction     text    DEFAULT NULL,
  p_from          text    DEFAULT NULL,
  p_to            text    DEFAULT NULL,
  p_user_ref      text    DEFAULT NULL,
  p_status        text    DEFAULT NULL,
  p_duration      integer DEFAULT NULL,
  p_payload       jsonb   DEFAULT '{}'::jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_org uuid; v_number uuid; v_account uuid; v_location uuid; v_matched text;
  v_interaction uuid; v_contact uuid; v_person uuid; v_dir direction;
  v_new_rows integer;
  v_related_ref text; v_related uuid; v_related_start timestamptz; v_own_start timestamptz;
  v_call_contact uuid;
BEGIN
  IF p_call_ref IS NULL OR btrim(p_call_ref) = '' THEN
    RAISE EXCEPTION 'a call event needs the carrier call id';
  END IF;
  -- The event's own time, never ours: it's part of what makes a retry a
  -- duplicate rather than a second event.
  IF p_occurred_at IS NULL THEN
    RAISE EXCEPTION 'a call event needs the time it happened';
  END IF;
  IF NOT p_event_type = ANY (enum_range(NULL::call_event_type)::text[]) THEN
    RAISE EXCEPTION 'unknown call event type %', p_event_type;
  END IF;

  v_dir := CASE WHEN p_direction = 'outbound' THEN 'outbound' ELSE 'inbound' END::direction;

  -- Have we already seen this call?
  SELECT i.id, i.organization_id INTO v_interaction, v_org
  FROM interactions i WHERE i.external_call_ref = p_call_ref LIMIT 1;

  IF v_interaction IS NULL THEN
    SELECT o.organization_id, o.phone_number_id, o.account_id, o.location_id, o.matched_e164
      INTO v_org, v_number, v_account, v_location, v_matched
    FROM organization_for_call(p_from, p_to, p_direction) o;

    -- A number we do not hold. Not an error and not ours to store.
    IF v_org IS NULL THEN RETURN NULL; END IF;

    -- Migration 015's matcher, which follows a merged contact to the survivor.
    v_contact := contact_for_number(v_org, CASE WHEN v_dir = 'inbound' THEN p_from ELSE p_to END);

    INSERT INTO interactions (
      organization_id, account_id, location_id, source, channel, direction,
      phone_number_id, from_e164, to_e164, occurred_at, started_at,
      disposition, telemetry_status, carrier, contact_id,
      handler_type, attribution_method, attribution_confidence,
      external_call_ref, last_activity_at, contact_link_method)
    VALUES (
      v_org, v_account, v_location, 'real', 'call', v_dir,
      v_number, normalize_e164(p_from), normalize_e164(p_to),
      p_occurred_at, p_occurred_at,
      -- Nothing has happened yet. "Still ringing" is honest; "connected"
      -- would be a guess that survives if the end event never arrives.
      'no_answer', 'from_events', 'dial_stack', v_contact,
      'unknown', 'unresolved', 'none',
      p_call_ref, p_occurred_at,
      -- Matched by number, so derived: 047. A person choosing a contact is
      -- 'confirmed' (save_wrap_up, 048), and only 'inferred' is cleared by
      -- the directory rule (046).
      CASE WHEN v_contact IS NOT NULL THEN 'inferred'::link_method END)
    ON CONFLICT (organization_id, external_call_ref)
      WHERE external_call_ref IS NOT NULL
      DO UPDATE SET updated_at = now()
    RETURNING id INTO v_interaction;
  END IF;

  -- Who, if the event names a Dial Stack user we hold a seat for.
  IF p_user_ref IS NOT NULL THEN
    SELECT s.person_id INTO v_person
    FROM seats s WHERE s.external_ref = p_user_ref AND s.organization_id = v_org;
  END IF;

  INSERT INTO interaction_events (
    organization_id, external_call_ref, interaction_id, event_type, occurred_at,
    direction, from_number, to_number, user_ref, person_id, status,
    transferred_to, related_call_ref, payload)
  VALUES (
    v_org, p_call_ref, v_interaction, p_event_type::call_event_type, p_occurred_at,
    v_dir, normalize_e164(p_from), normalize_e164(p_to), p_user_ref, v_person,
    -- DialStack puts these inside the envelope's `data`; 040 read the envelope's
    -- top level and stored nulls. The top level is kept as a fallback only.
    p_status,
    COALESCE(p_payload->'data'->>'transferred_to', p_payload->>'transferred_to'),
    COALESCE(p_payload->'data'->>'related_call',   p_payload->>'related_call'),
    COALESCE(p_payload, '{}'::jsonb))
  ON CONFLICT DO NOTHING;      -- a retry lands here and changes nothing
  GET DIAGNOSTICS v_new_rows = ROW_COUNT;

  -- Move the interaction forward, per event. Each branch is safe to replay.
  CASE p_event_type
    WHEN 'call.incoming', 'call.initiated' THEN
      -- The call's real start. If a later event reached us first, the row was
      -- created at that event's time; pull the start back to this one.
      UPDATE interactions SET
        occurred_at = LEAST(occurred_at, p_occurred_at),
        started_at  = LEAST(started_at, p_occurred_at),
        answer_seconds = CASE WHEN connected_at IS NOT NULL
                              THEN EXTRACT(EPOCH FROM (connected_at - LEAST(started_at, p_occurred_at)))::integer
                              ELSE answer_seconds END,
        updated_at = now()
      WHERE id = v_interaction AND started_at > p_occurred_at;

    WHEN 'call.answered' THEN
      UPDATE interactions SET
        -- The media path answering is not a person answering: a greeting or a
        -- menu fires this too. connected_at is set by whoever actually takes
        -- the call, which is the leg that names a user.
        answered_at = COALESCE(answered_at, p_occurred_at),
        connected_at = CASE WHEN v_person IS NOT NULL
                            THEN COALESCE(connected_at, p_occurred_at)
                            ELSE connected_at END,
        answer_seconds = CASE WHEN v_person IS NOT NULL AND answer_seconds IS NULL
                              THEN EXTRACT(EPOCH FROM (p_occurred_at - started_at))::integer
                              ELSE answer_seconds END,
        disposition = CASE WHEN v_person IS NOT NULL THEN 'connected' ELSE disposition END,
        handler_person_id = COALESCE(handler_person_id, v_person),
        handler_type = CASE WHEN v_person IS NOT NULL THEN 'client_staff' ELSE handler_type END,
        attribution_method = CASE WHEN v_person IS NOT NULL THEN 'named_seat' ELSE attribution_method END,
        attribution_confidence = CASE WHEN v_person IS NOT NULL THEN 'certain' ELSE attribution_confidence END,
        last_activity_at = GREATEST(last_activity_at, p_occurred_at),
        updated_at = now()
      WHERE id = v_interaction;

      -- They called and reached someone: a reminder to follow up with them
      -- has been overtaken (047). Inbound and answered by a person only — a
      -- missed call from them is a reason to call back, not proof it
      -- happened. Only on the first time this event is stored, so a retry
      -- can't cancel a reminder set after the call was answered.
      IF v_person IS NOT NULL AND v_dir = 'inbound' AND v_new_rows > 0 THEN
        SELECT contact_id INTO v_call_contact FROM interactions WHERE id = v_interaction;
        IF v_call_contact IS NOT NULL THEN
          PERFORM cancel_reminders_on_inbound(v_call_contact, v_interaction);
        END IF;
      END IF;

    WHEN 'call.end' THEN
      UPDATE interactions SET
        ended_at = COALESCE(ended_at, p_occurred_at),
        duration_seconds = COALESCE(duration_seconds, p_duration,
                             EXTRACT(EPOCH FROM (p_occurred_at - started_at))::integer),
        disposition = CASE
          WHEN connected_at IS NOT NULL THEN 'connected'::disposition
          WHEN p_status IN ('voicemail')  THEN 'voicemail'::disposition
          WHEN p_status IN ('busy')       THEN 'busy'::disposition
          WHEN p_status IN ('no-answer','no_answer') THEN 'no_answer'::disposition
          ELSE disposition END,
        last_activity_at = GREATEST(last_activity_at, p_occurred_at),
        updated_at = now()
      WHERE id = v_interaction;

    WHEN 'voicemail.new' THEN
      UPDATE interactions SET disposition = 'voicemail',
             last_activity_at = GREATEST(last_activity_at, p_occurred_at),
             updated_at = now()
      WHERE id = v_interaction AND connected_at IS NULL;

    WHEN 'call.transfer' THEN
      -- Only a transfer event we hadn't stored before counts, so a retry can't
      -- inflate the number. transfer_count has no default and starts null on
      -- a new call, and null + 1 is null — so count from zero.
      IF v_new_rows > 0 THEN
        UPDATE interactions SET transfer_count = COALESCE(transfer_count, 0) + 1, updated_at = now()
        WHERE id = v_interaction;
      END IF;

      -- A warm transfer is two calls, and each leg's call.transfer names the
      -- other in related_call. The consultation is the leg placed later: the
      -- call it served already existed when it was dialled. It is merged into
      -- that call rather than hung up, so it never sends call.end; it ended
      -- at the transfer, and that is the time recorded. No duration is
      -- derived. Both directions are handled here, so it doesn't matter which
      -- leg's event arrives first, and a replay changes nothing.
      v_related_ref := COALESCE(p_payload->'data'->>'related_call', p_payload->>'related_call');
      IF v_related_ref IS NOT NULL THEN
        SELECT i.id, i.started_at INTO v_related, v_related_start
        FROM interactions i
        WHERE i.external_call_ref = v_related_ref AND i.organization_id = v_org;

        SELECT started_at INTO v_own_start FROM interactions WHERE id = v_interaction;

        IF v_related IS NOT NULL AND v_own_start IS NOT NULL AND v_related_start IS NOT NULL THEN
          IF v_own_start > v_related_start THEN
            -- This leg is the consultation.
            UPDATE interactions SET consultation_of = v_related,
                   ended_at = COALESCE(ended_at, p_occurred_at),
                   last_activity_at = GREATEST(last_activity_at, p_occurred_at),
                   updated_at = now()
            WHERE id = v_interaction AND consultation_of IS NULL;
          ELSIF v_related_start > v_own_start THEN
            -- The other leg is.
            UPDATE interactions SET consultation_of = v_interaction,
                   ended_at = COALESCE(ended_at, p_occurred_at),
                   last_activity_at = GREATEST(last_activity_at, p_occurred_at),
                   updated_at = now()
            WHERE id = v_related AND consultation_of IS NULL;
          END IF;
          -- Equal start times: no way to tell which leg is which, so neither
          -- is marked. Never seen in practice; a placed call follows the call.
        END IF;
      END IF;

    ELSE NULL;   -- ringing, recording, queue and flow events: the event row is the record
  END CASE;

  -- A participant row for whoever took it, so the contact's record shows them.
  -- interaction_participants has no unique key, so check rather than rely on
  -- ON CONFLICT, which would never fire.
  IF v_person IS NOT NULL AND p_event_type = 'call.answered' THEN
    INSERT INTO interaction_participants (organization_id, interaction_id, person_id, role)
    SELECT v_org, v_interaction, v_person, 'handler'
    WHERE NOT EXISTS (
      SELECT 1 FROM interaction_participants p
      WHERE p.interaction_id = v_interaction AND p.person_id = v_person AND p.role = 'handler');
  END IF;

  RETURN v_interaction;
END $$;

COMMIT;

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
-- Made-up numbers only.
--
-- DO $$
-- DECLARE r text := ''; s text; v_org uuid; v_num text; v_c uuid; v_user uuid;
--         v_old uuid; v_new uuid; v_other uuid; v_i uuid; v_i2 uuid; v_d uuid;
--         v_cell text := '+15135554444';
-- BEGIN
--   SELECT id INTO v_org FROM organizations WHERE code = 'DR';
--   SELECT e164 INTO v_num FROM phone_numbers WHERE active AND organization_id = v_org ORDER BY e164 LIMIT 1;
--   SELECT u.id INTO v_user FROM users u LIMIT 1;
--   PERFORM set_config('app.user_id', '', true);   -- as the webhook: no signed-in user
--   SELECT s.external_ref INTO s FROM seats s WHERE s.organization_id = v_org AND s.external_ref IS NOT NULL LIMIT 1;
--
--   -- Backfill: every stored contact has a method, and none without one.
--   r := r || 'contacts without a method: '
--          || (SELECT count(*) FROM interactions WHERE (contact_id IS NULL) <> (contact_link_method IS NULL))
--          || '   (expect 0)' || chr(10);
--
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'Family (test)') RETURNING id INTO v_c;
--   INSERT INTO contact_phones (organization_id, contact_id, e164, label, is_primary, added_by)
--   VALUES (v_org, v_c, v_cell, 'mobile', true, 'verify 047');
--
--   -- A reminder from before the call, one on another contact.
--   INSERT INTO reminders (organization_id, owner_user_id, contact_id, due_at, created_at)
--   VALUES (v_org, v_user, v_c, now() + interval '1 day', now() - interval '1 hour') RETURNING id INTO v_old;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'Someone else (test)') RETURNING id INTO v_other;
--   INSERT INTO reminders (organization_id, owner_user_id, contact_id, due_at, created_at)
--   VALUES (v_org, v_user, v_other, now() + interval '1 day', now() - interval '1 hour');
--
--   -- They call; nobody answers. Nothing is canceled.
--   v_i := ingest_call_event('call_047_m', 'call.incoming', now() - interval '10 min', 'inbound', v_cell, v_num);
--   PERFORM ingest_call_event('call_047_m', 'call.end', now() - interval '9 min', 'inbound', v_cell, v_num, NULL, 'no-answer', 20);
--   r := r || 'ingested contact method: ' || (SELECT coalesce(contact_link_method::text, 'NULL') FROM interactions WHERE id = v_i) || '   (expect inferred)' || chr(10);
--   r := r || 'after a missed call: ' || (SELECT state FROM reminders WHERE id = v_old) || '   (expect open)' || chr(10);
--
--   -- They call; a person answers. The old reminder cancels, labeled.
--   v_i2 := ingest_call_event('call_047_a', 'call.incoming', now() - interval '5 min', 'inbound', v_cell, v_num);
--   -- A reminder set on this call (as wrap-up will), after it started.
--   INSERT INTO reminders (organization_id, owner_user_id, interaction_id, contact_id, due_at)
--   VALUES (v_org, v_user, v_i2, v_c, now() + interval '1 day') RETURNING id INTO v_new;
--   PERFORM ingest_call_event('call_047_a', 'call.answered', now() - interval '4 min', 'inbound', v_cell, v_num, s);
--   SELECT state || ' / ' || coalesce(closed_by_label, 'no label') INTO s FROM reminders WHERE id = v_old;
--   r := r || 'after an answered call, the earlier reminder: ' || s || '   (expect canceled / Canceled automatically…)' || chr(10);
--   r := r || 'the reminder set on this call: ' || (SELECT state FROM reminders WHERE id = v_new) || '   (expect open)' || chr(10);
--   r := r || 'another contact''s reminder: ' || (SELECT state FROM reminders WHERE contact_id = v_other) || '   (expect open)' || chr(10);
--
--   -- A confirmed contact survives the directory rule; an inferred one doesn't.
--   UPDATE interactions SET contact_link_method = 'confirmed' WHERE id = v_i2;
--   INSERT INTO directory_entries (organization_id, entry_kind, label, e164)
--   VALUES (v_org, 'staff', 'Staff cell (test)', v_cell) RETURNING id INTO v_d;
--   r := r || 'after the number becomes staff — inferred call: '
--          || coalesce((SELECT contact_id::text FROM interactions WHERE id = v_i), 'none')
--          || ', confirmed call kept its contact: ' || ((SELECT contact_id FROM interactions WHERE id = v_i2) = v_c)
--          || '   (expect none, true)' || chr(10);
--   r := r || 'cleared call has no method: ' || ((SELECT contact_link_method FROM interactions WHERE id = v_i) IS NULL) || '   (expect true)' || chr(10);
--
--   -- A contact without a method is refused.
--   BEGIN
--     UPDATE interactions SET contact_link_method = NULL WHERE id = v_i2;
--     r := r || 'contact without a method: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN check_violation THEN r := r || 'contact without a method: refused' || chr(10); END;
--
--   -- A person closing still names themselves.
--   PERFORM set_config('app.user_id', v_user::text, true);
--   UPDATE reminders SET state = 'open' WHERE id = v_old;
--   UPDATE reminders SET state = 'done' WHERE id = v_old;
--   r := r || 'closed by a person, labeled with them: '
--          || ((SELECT closed_by_label FROM reminders WHERE id = v_old) = (SELECT full_name FROM users WHERE id = v_user))
--          || '   (expect true)' || chr(10);
--
--   r := r || 'clients can run cancel_reminders_on_inbound: '
--          || has_function_privilege('authenticated', 'cancel_reminders_on_inbound(uuid, uuid)', 'EXECUTE')
--          || '   (expect false)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 047 (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
