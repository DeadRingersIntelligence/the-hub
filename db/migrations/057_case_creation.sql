-- =============================================================================
-- 057_case_creation.sql
-- The Hub — migration 57: creating a case, which is not a separate act.
--
-- Run on dead-ringers-hub and hellophone-production, 30 Oct 2026. Safe to
-- run twice. 058 later replaced create_case_for_call(), delete_case() and
-- propagate_case_links() and dropped interactions.is_converting.
--
-- Revised 30 Oct 2026 against the live schema (hellophone-production):
--   * record_change() takes (org, entity, id, action, actor_kind, actor_label,
--     summary, actor_user, detail, link_method). The draft passed five
--     arguments, which installs cleanly and then fails every case creation at
--     its last step. Every call now goes through hand_link_actor() the way
--     set_call_case() (050) does.
--   * history_action has no marked_lost, reopened or deleted. Lost and back
--     are recorded as 'updated' with the status change in the detail; undo is
--     recorded as 'unlinked' on the call, because the case it would be
--     recorded against no longer exists. No enum change.
--   * an existing decedent is checked against its own recorded status, not
--     the p_decedent_status argument.
--   * delete_case() removes the decedent and the call's interaction_decedents
--     row this created, when nothing else refers to that decedent, rather than
--     leaving an orphan behind every undo.
--   * delete_case()'s refusal used '%s'; RAISE placeholders are a bare '%'.
--   * the verification block used SELECT set_config(...) inside DO, which
--     PL/pgSQL refuses ("no destination for result data"); now PERFORM.
--
-- THE RULING THIS IMPLEMENTS (30 Oct 2026), written here because the
-- decedent-name rule lived in a chat for three weeks and nobody could find it.
--
-- CONVERSION IS NOT A SEPARATE FLOW. It is the create branch of the case
-- picker. + Link already links a call to an existing case (set_call_case,
-- 050); what was missing is "none of these — create a new case". The same
-- control appears in the wrap-up form and in the call panel's Linked to.
-- There is no "Convert to Case" anything.
--
-- WHAT CREATING A CASE DOES
--   * creates a decedents row, requiring a last name. decedents_named_ck
--     exists to force that question while the family is on the phone; it is
--     asked, never worked around.
--   * sets decedents.status explicitly. The column defaults to 'imminent',
--     which would assert that a pre-need subject is actively dying.
--   * creates the case and case_decedents linking them.
--   * adds the caller to case_contacts.
--   * sets case_id on this call, confirmed.
--
-- WHICH CALLS JOIN
--   * same_case propagation as specced: confirmed propagates one hop in
--     either direction, the call it reaches is marked inferred, and inferred
--     never propagates further. Confirming an inferred link makes that call a
--     source and propagation runs again from it.
--   * the create flow also SHOWS the contact's other recent calls and offers
--     them. Shown, never pre-selected — the ring-screen rule. A call the
--     person ticks is their choice, so it joins as confirmed and propagates
--     like any other confirmed call.
--
-- OTHER PEOPLE
--   * everyone beyond the caller is linked by hand afterwards.
--   * case_contacts.role stays OPTIONAL. Someone linking a contact often
--     doesn't yet know whether they're the daughter or the next of kin, and
--     forcing a guess produces worse data than an empty field.
--
-- LEADS
--   * an open lead for this contact attaches to the case and closes.
--   * this is the attribution point. If the lead doesn't attach, the later
--     call becomes first contact and first-call conversion reads wrong in the
--     direction that flatters the firm.
--
-- WHO MAY
--   * anyone. A director on the call knows it is converting and shouldn't
--     wait for someone else to click. Managers get visibility, not control —
--     the notification is separate work and is NOT in this migration.
--
-- LOST
--   * a case whose family converted but didn't proceed. The case stays:
--     calls, history and contacts all stay. Excluded from revenue reporting.
--     Reversible — a family who comes back becomes active again.
--   * this reintroduces a state on cases, which was dropped deliberately. The
--     reason for dropping it — a case doesn't close, families come back —
--     still holds. Lost isn't closed, and it reverses.
--   * nothing reads it yet; revenue reporting isn't built.
--
-- UNDO is distinct from lost and must not share a control. Lost is an outcome
-- worth reporting; undo is a mistake with nothing to report. One control
-- produces fake lost cases and a report nobody trusts.
--   * unlinking a call is always available — clear_call_case (050).
--   * deleting the case is possible only while nothing hangs off it.
--   * once it has been worked on: unlink only, the case stays. If it stays
--     because the family didn't proceed, that is lost, not undo.
--
-- TWO THINGS THE SCHEMA WAS MISSING, found writing this:
--   * leads has status 'converted' but no case_id, so a converted lead
--     recorded no link to what it became — the attribution point above needs
--     that link, not just a status.
--   * cases had no state at all.
--
-- Requires: 001 to 055. Not 056.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Lost
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'case_status') THEN
    CREATE TYPE case_status AS ENUM ('active', 'lost');
  END IF;
END $$;

ALTER TABLE cases ADD COLUMN IF NOT EXISTS status case_status NOT NULL DEFAULT 'active';

COMMENT ON COLUMN cases.status IS
  'active, or lost: a family who converted and didn''t proceed to services. '
  'A lost case KEEPS everything — calls, history, contacts — and is excluded '
  'from revenue reporting; it is reversible, because a family who comes back '
  'becomes active again. This is not "closed": a case never closes, which is '
  'why the original status column was dropped. Nothing reads this yet. '
  'NEVER set from an undo control — see delete_case().';

CREATE INDEX IF NOT EXISTS cases_status_idx
  ON cases (organization_id, status) WHERE status <> 'active';

-- -----------------------------------------------------------------------------
-- 2. What a lead became
--
-- leads.status could already say 'converted' and nothing recorded converted
-- INTO WHAT. First-call attribution is the reason this link has to exist:
-- without it the price-shopper's call is a closed lead beside a case it has
-- no stated relationship to.
-- -----------------------------------------------------------------------------
ALTER TABLE leads ADD COLUMN IF NOT EXISTS
  case_id uuid REFERENCES cases(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS leads_case_idx ON leads (case_id) WHERE case_id IS NOT NULL;

COMMENT ON COLUMN leads.case_id IS
  'The case this lead became, set when the case was created from a call with '
  'this lead''s contact. The attribution point: the lead''s own call was '
  'first contact, and without this link the later call reads as first contact '
  'and first-call conversion flatters the firm.';

-- -----------------------------------------------------------------------------
-- 3. Propagation, on its own so confirming can re-run it
--
-- One hop from every CONFIRMED call on the case, along same_case links, in
-- either direction. The call it reaches is marked inferred and never
-- propagates on — so a chain of loosely related calls can't drag a case
-- through all of it one link at a time. Confirming an inferred link makes
-- that call a source, and calling this again is how rule 5 happens.
--
-- Never touches a call that already has a case: a link someone made by hand
-- is not overwritten by a derived one.
--
-- Writes no history for the calls it joins. set_call_case() records every
-- hand link; whether a derived link should appear in history is still open.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION propagate_case_links(p_case uuid)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE v_org uuid; n integer;
BEGIN
  SELECT organization_id INTO v_org FROM cases WHERE id = p_case;
  IF v_org IS NULL THEN RETURN 0; END IF;

  UPDATE interactions t
     SET case_id = p_case, case_link_method = 'inferred', updated_at = now()
   WHERE t.organization_id = v_org
     AND t.case_id IS NULL
     AND t.id IN (
       SELECT CASE WHEN l.from_interaction_id = s.id
                   THEN l.to_interaction_id ELSE l.from_interaction_id END
         FROM interaction_links l
         JOIN interactions s
           ON s.id IN (l.from_interaction_id, l.to_interaction_id)
        WHERE l.link_type = 'same_case'
          AND l.organization_id = v_org
          AND l.to_interaction_id IS NOT NULL
          AND s.case_id = p_case
          AND s.case_link_method = 'confirmed');

  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

COMMENT ON FUNCTION propagate_case_links(uuid) IS
  'Joins calls one same_case hop from this case''s CONFIRMED calls, marking '
  'them inferred. Inferred is a sink: it never propagates on, so a long chain '
  'of loosely related calls can''t quietly drag a case through all of it. '
  'Confirming an inferred link turns that call into a source — call this '
  'again then. STILL TO WIRE: set_call_case() (050) should call this, or '
  'rule 5 only happens at creation.';

-- -----------------------------------------------------------------------------
-- 4. Creating the case
--
-- Invoker rights: anyone who may write these rows may do this, which is the
-- ruling — a director on the call doesn't wait for a manager.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION create_case_for_call(
  p_interaction      uuid,
  p_need_type        case_need_type,
  -- For a new decedent. An existing one (p_decedent_id) is checked against
  -- its own recorded status instead.
  p_decedent_status  decedent_status,
  p_decedent_last    text    DEFAULT NULL,
  p_decedent_first   text    DEFAULT NULL,
  p_date_of_death    date    DEFAULT NULL,
  -- An existing decedent instead of a new one: a later call about someone
  -- already known. Offered, never matched automatically.
  p_decedent_id      uuid    DEFAULT NULL,
  -- Optional on purpose: daughter, next of kin, or nothing yet.
  p_role             text    DEFAULT NULL,
  -- Other calls the person ticked from the list the create flow showed.
  -- Their choice, so they join confirmed.
  p_also             uuid[]  DEFAULT '{}')
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
  a record;
  v_org uuid; v_loc uuid; v_contact uuid; v_case uuid; v_decedent uuid;
  v_status decedent_status; v_existing uuid; v_other uuid; v_joined uuid[] := '{}';
BEGIN
  IF current_user_id() IS NULL THEN
    RAISE EXCEPTION 'your sign-in isn''t linked to a Hub user, so a case can''t be created';
  END IF;
  SELECT * INTO a FROM hand_link_actor();

  SELECT organization_id, location_id, contact_id, case_id
    INTO v_org, v_loc, v_contact, v_existing
    FROM interactions WHERE id = p_interaction FOR UPDATE;

  IF v_org IS NULL THEN
    RAISE EXCEPTION 'that call couldn''t be found' USING ERRCODE = 'P0002';
  END IF;
  IF v_existing IS NOT NULL THEN
    RAISE EXCEPTION 'this call is already on a case — unlink it first, or link it to another';
  END IF;

  -- The caller has to be someone. case_contacts is the point of the case
  -- knowing who the family is, and an unnamed caller can't be added to it.
  IF v_contact IS NULL THEN
    RAISE EXCEPTION 'save the caller as a contact first';
  END IF;

  -- ---- The decedent ----------------------------------------------------------
  IF p_decedent_id IS NOT NULL THEN
    -- Its recorded status, not the argument: the check below is about what
    -- the Hub already says of this person.
    SELECT COALESCE(d.merged_into, d.id) INTO v_decedent
      FROM decedents d WHERE d.id = p_decedent_id AND d.organization_id = v_org;
    IF v_decedent IS NULL THEN
      RAISE EXCEPTION 'choose a decedent at this firm';
    END IF;
    SELECT status INTO v_status FROM decedents WHERE id = v_decedent;
  ELSE
    -- decedents_named_ck would refuse this anyway; the message is the point.
    IF NULLIF(btrim(COALESCE(p_decedent_last, '')), '') IS NULL THEN
      RAISE EXCEPTION 'the case needs the deceased person''s last name'
        USING HINT = 'Ask while the family is on the phone — a first name alone can''t be matched later.';
    END IF;

    -- Explicitly, never by default: decedents.status defaults to 'imminent',
    -- which would say a pre-need subject is actively dying.
    IF p_decedent_status IN ('pre_need_subject', 'imminent') AND p_date_of_death IS NOT NULL THEN
      RAISE EXCEPTION 'a date of death can''t be recorded for someone living';
    END IF;

    INSERT INTO decedents (organization_id, first_name, last_name, status, date_of_death)
    VALUES (v_org,
            NULLIF(btrim(COALESCE(p_decedent_first, '')), ''),
            btrim(p_decedent_last),
            p_decedent_status,
            p_date_of_death)
    RETURNING id INTO v_decedent;
    v_status := p_decedent_status;
  END IF;

  -- A pre-need case about someone already deceased, or the reverse, is a
  -- contradiction worth catching here rather than in a report later.
  IF (p_need_type = 'pre_need'  AND v_status <> 'pre_need_subject')
  OR (p_need_type = 'imminent'  AND v_status <> 'imminent')
  OR (p_need_type = 'at_need'   AND v_status NOT IN ('at_need', 'deceased')) THEN
    RAISE EXCEPTION 'a % case doesn''t go with a decedent recorded as %', p_need_type, v_status;
  END IF;

  -- ---- The case ---------------------------------------------------------------
  INSERT INTO cases (organization_id, location_id, need_type,
                     converting_interaction_id, opened_on, status)
  VALUES (v_org, v_loc, p_need_type, p_interaction, current_date, 'active')
  RETURNING id INTO v_case;

  INSERT INTO case_decedents (case_id, decedent_id)
  VALUES (v_case, v_decedent) ON CONFLICT DO NOTHING;

  -- The caller. role stays null when nobody knows it yet.
  INSERT INTO case_contacts (case_id, contact_id, role, is_primary)
  VALUES (v_case, v_contact, NULLIF(btrim(COALESCE(p_role, '')), ''), true)
  ON CONFLICT DO NOTHING;

  -- ---- This call ----------------------------------------------------------------
  UPDATE interactions
     SET case_id = v_case, case_link_method = 'confirmed',
         is_converting = true, updated_at = now()
   WHERE id = p_interaction;

  INSERT INTO interaction_decedents (interaction_id, decedent_id, link_method, linked_by)
  VALUES (p_interaction, v_decedent, 'confirmed', a.v_name)
  ON CONFLICT DO NOTHING;

  -- ---- The calls they ticked ------------------------------------------------------
  -- Shown by the create flow, never pre-selected. A tick is a person's choice,
  -- so these are confirmed and each becomes a propagation source.
  FOREACH v_other IN ARRAY COALESCE(p_also, '{}') LOOP
    CONTINUE WHEN v_other = p_interaction;
    UPDATE interactions
       SET case_id = v_case, case_link_method = 'confirmed', updated_at = now()
     WHERE id = v_other AND organization_id = v_org AND case_id IS NULL;
    IF FOUND THEN v_joined := v_joined || v_other; END IF;
  END LOOP;

  PERFORM propagate_case_links(v_case);

  -- ---- The lead ---------------------------------------------------------------------
  -- Attached and closed. Without this the earlier call stays an open lead and
  -- the later one reads as first contact.
  UPDATE leads
     SET case_id = v_case, status = 'converted', updated_at = now()
   WHERE organization_id = v_org
     AND contact_id = v_contact
     AND status IN ('open', 'contacted');

  -- ---- History, the way set_call_case() (050) records a hand link -----------------
  PERFORM record_change(
    v_org, 'case', v_case, 'created', 'user', a.v_name,
    format('%s created this case from a call', a.v_name), a.v_user,
    jsonb_build_object('converting_interaction_id', p_interaction,
                       'decedent_id', v_decedent, 'need_type', p_need_type));

  PERFORM record_change(
    v_org, 'interaction', p_interaction, 'linked', 'user', a.v_name,
    format('%s created a case from this call', a.v_name), a.v_user,
    jsonb_build_object('field', 'case_id', 'case_id', v_case, 'converting', true),
    'confirmed');

  FOREACH v_other IN ARRAY v_joined LOOP
    PERFORM record_change(
      v_org, 'interaction', v_other, 'linked', 'user', a.v_name,
      format('%s linked this call to a case', a.v_name), a.v_user,
      jsonb_build_object('field', 'case_id', 'case_id', v_case), 'confirmed');
  END LOOP;

  RETURN v_case;
END $$;

COMMENT ON FUNCTION create_case_for_call IS
  'The create branch of the case picker — there is no separate conversion '
  'flow. Creates the decedent (last name required, status explicit), the '
  'case, case_decedents, the caller in case_contacts (role optional), marks '
  'this call confirmed and converting, joins the calls the person ticked, '
  'propagates one hop, and attaches and closes the contact''s open lead. '
  'Anyone may call it: a director on the call shouldn''t wait for a manager.';

-- -----------------------------------------------------------------------------
-- 5. Lost, and back
--
-- history_action has no "lost" or "reopened"; this is an update to the case's
-- status, recorded as one with the change in the detail.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_case_lost(p_case uuid, p_lost boolean DEFAULT true)
RETURNS cases LANGUAGE plpgsql AS $$
DECLARE a record; r cases; v_was case_status;
BEGIN
  SELECT * INTO a FROM hand_link_actor();

  SELECT status INTO v_was FROM cases WHERE id = p_case FOR UPDATE;
  IF v_was IS NULL THEN RAISE EXCEPTION 'no such case'; END IF;

  UPDATE cases SET status = CASE WHEN p_lost THEN 'lost' ELSE 'active' END::case_status,
                   updated_at = now()
   WHERE id = p_case
  RETURNING * INTO r;

  IF r.status IS DISTINCT FROM v_was THEN
    PERFORM record_change(
      r.organization_id, 'case', p_case, 'updated', 'user', a.v_name,
      CASE WHEN p_lost THEN format('%s marked the case lost', a.v_name)
           ELSE format('%s made the case active again', a.v_name) END,
      a.v_user,
      jsonb_build_object('field', 'status', 'from', v_was, 'to', r.status));
  END IF;
  RETURN r;
END $$;

COMMENT ON FUNCTION set_case_lost(uuid, boolean) IS
  'The family converted and didn''t proceed. Keeps everything and reverses — '
  'a family who comes back becomes active again. NOT an undo: an undo is a '
  'mistake with nothing to report, and sharing a control with this produces '
  'fake lost cases and a report nobody trusts. See delete_case().';

-- -----------------------------------------------------------------------------
-- 6. Undo
--
-- Only while nothing hangs off it. Once it has been worked on, the case stays
-- and the call is unlinked instead (clear_call_case, 050) — and if it stays
-- because the family didn't proceed, that is lost, not undo.
--
-- Takes back what create_case_for_call() made: the case, its decedent link,
-- the caller's place on it, and the decedent itself unless something else
-- refers to them (another case, another call). A reopened lead goes back to
-- 'open'; whether it was 'contacted' before isn't recorded anywhere.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION delete_case(p_case uuid)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE
  a record;
  v_org uuid; v_conv uuid; v_contact uuid; v_held text := ''; n integer;
  v_decedents uuid[]; v_d uuid;
BEGIN
  SELECT * INTO a FROM hand_link_actor();

  SELECT organization_id, converting_interaction_id INTO v_org, v_conv
    FROM cases WHERE id = p_case FOR UPDATE;
  IF v_org IS NULL THEN RAISE EXCEPTION 'no such case'; END IF;

  SELECT contact_id INTO v_contact FROM interactions WHERE id = v_conv;

  SELECT count(*) INTO n FROM interactions
   WHERE case_id = p_case AND id IS DISTINCT FROM v_conv;
  IF n > 0 THEN v_held := v_held || format('%s other call(s); ', n); END IF;

  SELECT count(*) INTO n FROM case_contacts
   WHERE case_id = p_case AND contact_id IS DISTINCT FROM v_contact;
  IF n > 0 THEN v_held := v_held || format('%s other contact(s); ', n); END IF;

  SELECT count(*) INTO n FROM threads WHERE case_id = p_case;
  IF n > 0 THEN v_held := v_held || format('%s chat thread(s); ', n); END IF;

  SELECT count(*) INTO n FROM reminders WHERE case_id = p_case;
  IF n > 0 THEN v_held := v_held || format('%s reminder(s); ', n); END IF;

  IF v_held <> '' THEN
    RAISE EXCEPTION 'this case has been worked on (%) — unlink the call instead, '
                    'or mark the case lost if the family didn''t proceed',
                    btrim(v_held, '; ');
  END IF;

  SELECT COALESCE(array_agg(decedent_id), '{}') INTO v_decedents
    FROM case_decedents WHERE case_id = p_case;

  UPDATE interactions
     SET case_id = NULL, case_link_method = NULL, is_converting = false,
         updated_at = now()
   WHERE case_id = p_case;

  UPDATE leads SET case_id = NULL, status = 'open', updated_at = now()
   WHERE case_id = p_case;

  DELETE FROM case_decedents WHERE case_id = p_case;
  DELETE FROM case_contacts  WHERE case_id = p_case;

  -- The decedent this case created, and the converting call's link to them,
  -- unless another case or another call also refers to that person.
  FOREACH v_d IN ARRAY v_decedents LOOP
    DELETE FROM interaction_decedents
     WHERE interaction_id = v_conv AND decedent_id = v_d;
    IF NOT EXISTS (SELECT 1 FROM case_decedents WHERE decedent_id = v_d)
       AND NOT EXISTS (SELECT 1 FROM interaction_decedents WHERE decedent_id = v_d)
       AND NOT EXISTS (SELECT 1 FROM decedents WHERE merged_into = v_d) THEN
      DELETE FROM decedents WHERE id = v_d;
    END IF;
  END LOOP;

  -- Recorded on the call: the case it would be recorded against is gone.
  IF v_conv IS NOT NULL THEN
    PERFORM record_change(
      v_org, 'interaction', v_conv, 'unlinked', 'user', a.v_name,
      format('%s undid a case created from this call by mistake', a.v_name), a.v_user,
      jsonb_build_object('field', 'case_id', 'previous_case_id', p_case,
                         'reason', 'created by mistake', 'case_deleted', true));
  END IF;

  DELETE FROM cases WHERE id = p_case;
  RETURN true;
END $$;

COMMENT ON FUNCTION delete_case(uuid) IS
  'Undo a case created by mistake, only while nothing hangs off it: no other '
  'calls, no contacts beyond the caller, no chat, no reminders. Removes the '
  'decedent it created unless something else refers to them, and reopens the '
  'lead it closed. Refuses once the case has been worked on — then the call '
  'is unlinked and the case stays, and if it stays because the family didn''t '
  'proceed that is set_case_lost(), not this. The two must never share a '
  'control.';

REVOKE ALL ON FUNCTION create_case_for_call(uuid, case_need_type, decedent_status,
  text, text, date, uuid, text, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION create_case_for_call(uuid, case_need_type, decedent_status,
  text, text, date, uuid, text, uuid[]) TO authenticated;

REVOKE ALL ON FUNCTION propagate_case_links(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION propagate_case_links(uuid) TO authenticated;

REVOKE ALL ON FUNCTION set_case_lost(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION set_case_lost(uuid, boolean) TO authenticated;

REVOKE ALL ON FUNCTION delete_case(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION delete_case(uuid) TO authenticated;

COMMIT;

-- =============================================================================
-- STILL TO DO, named so they aren't folded in and skipped
--
--   * set_call_case() (050) should call propagate_case_links(), or rule 5 —
--     confirming an inferred link makes that call a source — only happens at
--     creation. It needs 050's live body hash for a drift check.
--   * cases.converting_interaction_id and interactions.is_converting record
--     the same fact twice. This function sets both; nothing yet stops them
--     disagreeing if something else writes one.
--   * whether propagated (inferred) links should write history. They don't.
--   * the manager notification. Nothing like it exists in the product — no
--     digest, no notifications beyond the missed-call alerts in Settings.
--     Its own piece of work.
--   * nothing reads cases.status yet. Revenue reporting isn't built.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- DO $$
-- DECLARE r text := ''; v_org uuid; v_call uuid; v_other uuid; v_case uuid;
--         v_contact uuid; v_lead uuid;
-- BEGIN
--   SELECT id INTO v_org FROM organizations WHERE code = 'DR';
--   PERFORM set_config('app.user_id', (SELECT id::text FROM users WHERE is_internal LIMIT 1), true);
--
--   SELECT i.id, i.contact_id INTO v_call, v_contact FROM interactions i
--    WHERE i.organization_id = v_org AND i.contact_id IS NOT NULL AND i.case_id IS NULL
--    ORDER BY i.occurred_at DESC LIMIT 1;
--
--   -- A lead for that contact, to watch it attach and close
--   INSERT INTO leads (organization_id, full_name, contact_id, status)
--   VALUES (v_org, 'Verify Lead', v_contact, 'open') RETURNING id INTO v_lead;
--
--   -- A last name is required
--   BEGIN
--     PERFORM create_case_for_call(v_call, 'at_need', 'at_need', NULL, 'Helen');
--     r := r || 'first name only: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN OTHERS THEN r := r || 'first name only refused: ' || SQLERRM || chr(10); END;
--
--   -- need_type and decedent status have to agree
--   BEGIN
--     PERFORM create_case_for_call(v_call, 'pre_need', 'at_need', 'Novak', 'Helen');
--     r := r || 'pre-need case, at-need decedent: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN OTHERS THEN r := r || 'mismatched need and status refused' || chr(10); END;
--
--   -- The real thing
--   v_case := create_case_for_call(v_call, 'at_need', 'at_need', 'Novak', 'Helen',
--                                  current_date, NULL, NULL, '{}');
--   r := r || 'case created: ' || (v_case IS NOT NULL)
--          || ', decedent linked: ' || EXISTS (SELECT 1 FROM case_decedents WHERE case_id = v_case)
--          || ', caller on the case: ' || EXISTS (SELECT 1 FROM case_contacts WHERE case_id = v_case AND contact_id = v_contact)
--          || ', role null: ' || (SELECT role IS NULL FROM case_contacts WHERE case_id = v_case AND contact_id = v_contact)
--          || '   (expect true ×4)' || chr(10);
--   r := r || 'call confirmed and converting: '
--          || (SELECT case_link_method = 'confirmed' AND is_converting FROM interactions WHERE id = v_call)
--          || ', case on it: ' || (SELECT case_id = v_case FROM interactions WHERE id = v_call)
--          || '   (expect true, true)' || chr(10);
--   r := r || 'lead attached and closed: '
--          || (SELECT status::text || ' / ' || (case_id = v_case)::text FROM leads WHERE id = v_lead)
--          || '   (expect converted / true)' || chr(10);
--   r := r || 'decedent status explicit: '
--          || (SELECT d.status::text FROM case_decedents cd JOIN decedents d ON d.id = cd.decedent_id
--               WHERE cd.case_id = v_case)
--          || '   (expect at_need, never imminent-by-default)' || chr(10);
--   r := r || 'history written: case '
--          || (SELECT count(*) FROM change_history WHERE entity_id = v_case)
--          || ', call ' || (SELECT count(*) FROM change_history WHERE entity_id = v_call AND action = 'linked')
--          || '   (expect 1, at least 1)' || chr(10);
--
--   -- A second case on the same call is refused
--   BEGIN
--     PERFORM create_case_for_call(v_call, 'at_need', 'at_need', 'Twice');
--     r := r || 'second case on one call: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN OTHERS THEN r := r || 'second case on one call refused' || chr(10); END;
--
--   -- Undo while nothing hangs off it: everything it made goes, lead reopens
--   DECLARE v_dec uuid;
--   BEGIN
--     SELECT decedent_id INTO v_dec FROM case_decedents WHERE case_id = v_case;
--     PERFORM delete_case(v_case);
--     r := r || 'undo: case gone ' || (NOT EXISTS (SELECT 1 FROM cases WHERE id = v_case))
--            || ', decedent gone ' || (NOT EXISTS (SELECT 1 FROM decedents WHERE id = v_dec))
--            || ', call unlinked ' || (SELECT case_id IS NULL AND NOT is_converting FROM interactions WHERE id = v_call)
--            || ', lead ' || (SELECT status::text FROM leads WHERE id = v_lead)
--            || '   (expect true, true, true, open)' || chr(10);
--   END;
--
--   -- Again, to test propagation, the undo refusal and lost
--   v_case := create_case_for_call(v_call, 'at_need', 'at_need', 'Novak', 'Helen',
--                                  current_date, NULL, NULL, '{}');
--
--   -- Propagation: a same_case link joins one hop, inferred
--   SELECT id INTO v_other FROM interactions
--    WHERE organization_id = v_org AND case_id IS NULL AND id <> v_call LIMIT 1;
--   IF v_other IS NOT NULL THEN
--     INSERT INTO interaction_links (organization_id, from_interaction_id, to_interaction_id,
--                                    link_type, link_method, linked_by)
--     VALUES (v_org, v_call, v_other, 'same_case', 'agent_linked', 'verify 057');
--     PERFORM propagate_case_links(v_case);
--     r := r || 'linked call joined as: '
--            || coalesce((SELECT case_link_method::text FROM interactions WHERE id = v_other), 'none')
--            || '   (expect inferred)' || chr(10);
--     -- and an inferred call is a sink
--     r := r || 'second hop from an inferred call: '
--            || propagate_case_links(v_case) || '   (expect 0)' || chr(10);
--
--     -- Undo is refused once it has been worked on
--     BEGIN
--       PERFORM delete_case(v_case);
--       r := r || 'delete with another call on it: ALLOWED (BAD)' || chr(10);
--     EXCEPTION WHEN OTHERS THEN r := r || 'delete refused: ' || SQLERRM || chr(10); END;
--   END IF;
--
--   -- Lost reverses
--   PERFORM set_case_lost(v_case, true);
--   r := r || 'lost: ' || (SELECT status::text FROM cases WHERE id = v_case);
--   PERFORM set_case_lost(v_case, false);
--   r := r || ', back: ' || (SELECT status::text FROM cases WHERE id = v_case)
--          || '   (expect lost, active)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 057 (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
