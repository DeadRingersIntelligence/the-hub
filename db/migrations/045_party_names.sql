-- =============================================================================
-- 045_party_names.sql
-- The Hub — migration 45: one answer to "who is this number".
--
-- Three sources name the other end of a call, and they have to be read in one
-- order everywhere:
--   1. a seat — for a Dial Stack user ref (a transfer to a user, not a number);
--   2. the firm's directory — its own people, teams and on-call lines (021);
--   3. a contact — the families and businesses it serves.
-- 042 put that order inside call_flow(). The feed, the call panel and the
-- timelines name a call from its contact alone, so a call from a staff cell
-- (Wendy Marriott's, 20 Oct 2026) shows a bare number there while the call
-- flow names her. Two lookups drift; this makes it one.
--
-- THIS MIGRATION
--   1. party_name(org, party, contact) — the order, once. Takes a user ref or
--      a number. A contact already linked to the call wins over one found by
--      number, so a call someone linked by hand keeps its contact.
--   2. peer_name(interactions) and peer_source(interactions) — the far end of
--      a call through party_name. Functions of a row, so the app selects them
--      like columns (a PostgREST computed field) and every screen reads the
--      same answer without a lookup of its own.
--   3. call_flow() names the far end and a transfer's destination through
--      party_name. A shared seat now reads as its label ("Prep Room"); 042's
--      lookup needed a person and fell through to the raw user ref.
--
-- The number lookups only run on a value that looks like a phone number, in a
-- CASE (042's rule): normalize_e164() strips non-digits, so a user ref would
-- otherwise become a made-up number.
--
-- All three are invoker functions: they read through the caller's RLS, so
-- they can't name anything the caller couldn't already see. NEVER ADD
-- SECURITY DEFINER TO THEM. An empty result is the policies working, not a
-- permissions bug: a definer version would name a party from a firm the
-- reader has no access to.
--
-- A contact linked to the call beats one found by number for the same reason
-- confirmed beats inferred (standing rule 4): a human correction never loses
-- to a derived match.
--
-- COST. The three branches are a UNION ALL, which doesn't short-circuit: every
-- call is three index lookups, even when the seat answers. Seats are indexed
-- on external_ref (029) and contact_phones on (organization_id, e164) (015);
-- the directory had no index on e164 (021), so this adds one. Nested COALESCE
-- would short-circuit but loses `source`. Not worth it at a feed page of 50;
-- revisit if anything reads thousands of rows through it.
--
-- Requires: 001 to 044
-- =============================================================================

BEGIN;

-- Every feed row looks a number up here; without this, each is a scan.
CREATE INDEX directory_entries_e164_idx
  ON directory_entries (organization_id, e164)
  WHERE active AND e164 IS NOT NULL;

-- -----------------------------------------------------------------------------
-- 1. The order, once
-- -----------------------------------------------------------------------------
CREATE FUNCTION party_name(p_org uuid, p_party text, p_contact uuid DEFAULT NULL)
RETURNS TABLE (name text, source text)
LANGUAGE sql STABLE AS $$
  SELECT x.name, x.source FROM (
    -- A Dial Stack user: the person on the seat, or a shared seat's label.
    (SELECT COALESCE(p.full_name, s.label) AS name, 'seat'::text AS source, 1 AS rank
       FROM seats s LEFT JOIN people p ON p.id = s.person_id
      WHERE s.organization_id = p_org AND s.external_ref = p_party
      LIMIT 1)
    UNION ALL
    -- The firm's own destinations. Before contacts: a number that is both a
    -- staff member's and a contact's reads as the staff member.
    (SELECT d.label, 'directory', 2
       FROM directory_entries d
      WHERE d.organization_id = p_org AND d.active
        AND CASE WHEN p_party ~ '^\+?[0-9 ().-]+$'
                 THEN d.e164 = normalize_e164(p_party) ELSE false END
      ORDER BY d.sort_order, d.label
      LIMIT 1)
    UNION ALL
    -- The contact linked to the call if there is one, else the number's.
    (SELECT COALESCE(c.full_name, c.business_name), 'contact', 3
       FROM contacts c
      WHERE c.id = COALESCE(p_contact,
                            CASE WHEN p_party ~ '^\+?[0-9 ().-]+$'
                                 THEN contact_for_number(p_org, p_party) END)
      LIMIT 1)
  ) x
  WHERE x.name IS NOT NULL
  ORDER BY x.rank
  LIMIT 1
$$;

COMMENT ON FUNCTION party_name(uuid, text, uuid) IS
  'Who a user ref or a number is, for this organization: a seat, then the '
  'firm''s directory, then a contact (p_contact, the one already linked, '
  'before a match by number). The one place that order is written; name a '
  'party through this, never with a lookup of your own. source says which '
  'answered: seat, directory or contact. No row when nothing does. Invoker '
  'rights on purpose — never SECURITY DEFINER: it reads through the caller''s '
  'RLS, and an empty result is the policies working.';

-- -----------------------------------------------------------------------------
-- 2. The far end of a call, as a column
--
-- The caller on an inbound call, the number dialled on an outbound one: the
-- same end contact_for_number() is given at ingestion.
-- -----------------------------------------------------------------------------
CREATE FUNCTION peer_name(i interactions) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT pn.name FROM party_name(i.organization_id,
           CASE WHEN i.direction = 'inbound' THEN i.from_e164 ELSE i.to_e164 END,
           i.contact_id) pn
$$;

CREATE FUNCTION peer_source(i interactions) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT pn.source FROM party_name(i.organization_id,
           CASE WHEN i.direction = 'inbound' THEN i.from_e164 ELSE i.to_e164 END,
           i.contact_id) pn
$$;

COMMENT ON FUNCTION peer_name(interactions) IS
  'The far end of the call, named by party_name(). Select it like a column '
  '(peer_name) rather than naming a call from its contact.';
COMMENT ON FUNCTION peer_source(interactions) IS
  'Which source named peer_name: seat, directory or contact; null when none.';

-- Explicit, as the README asks, though these are invoker functions and RLS
-- applies either way. PostgREST exposes peer_name and peer_source as computed
-- fields only to a role that can execute them.
REVOKE ALL ON FUNCTION party_name(uuid, text, uuid)  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION peer_name(interactions)       FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION peer_source(interactions)     FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION party_name(uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION peer_name(interactions)      TO authenticated;
GRANT EXECUTE ON FUNCTION peer_source(interactions)    TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. The call flow, through the same lookup
--
-- As 043 left it, with the far end and the transfer target from party_name.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION call_flow(p_interaction uuid)
RETURNS TABLE (at timestamptz, seconds numeric, step text, detail text)
LANGUAGE sql STABLE AS $$
  WITH ctx AS (
    -- The far end, named by the shared lookup (party_name, below).
    SELECT i.id, i.direction, i.consultation_of,
           COALESCE(peer_name(i), i.to_e164) AS other_party
    FROM interactions i
    WHERE i.id = p_interaction
  ),
  e AS (
    SELECT ev.*, MIN(ev.occurred_at) OVER () AS t0,
           ctx.direction AS dir, ctx.other_party, ctx.consultation_of,
           -- Whether this call was transferred: its call.end then names a
           -- user who had already left (see interaction_events.user_ref).
           bool_or(ev.event_type = 'call.transfer') OVER () AS transferred,
           -- Who a transfer went to: a user ref or a number, named by the
           -- shared lookup, otherwise the value as given.
           CASE WHEN ev.event_type = 'call.transfer' AND ev.transferred_to IS NOT NULL THEN
             COALESCE((SELECT pn.name FROM party_name(ev.organization_id, ev.transferred_to) pn),
                      ev.transferred_to)
           END AS transfer_target
    FROM interaction_events ev, ctx
    WHERE ev.interaction_id = p_interaction
  )
  SELECT occurred_at,
         round(EXTRACT(EPOCH FROM (occurred_at - t0))::numeric, 1),
         CASE
           -- Outbound: the ring and the answer belong to the far end.
           WHEN dir = 'outbound' AND event_type = 'call.ringing'
             THEN 'Ringing ' || COALESCE(other_party, 'the number')
           WHEN dir = 'outbound' AND event_type = 'call.answered'
             THEN COALESCE(other_party, 'The number') || ' answered'
           WHEN dir = 'outbound' AND event_type = 'call.end'
             THEN 'Call ended'

           WHEN event_type = 'call.incoming'      THEN 'Call arrived'
           WHEN event_type = 'call.initiated'     THEN 'Call placed'
           WHEN event_type = 'flow.menu_played'   THEN 'Menu played'
           WHEN event_type = 'flow.key_pressed'   THEN 'Caller pressed a key'
           WHEN event_type = 'flow.node_entered'  THEN 'Routed'
           WHEN event_type = 'queue.call.queued'  THEN 'Entered the queue'
           WHEN event_type = 'queue.call.dispatched' THEN 'Queue rang an agent'
           WHEN event_type = 'queue.call.answered'   THEN 'Answered from the queue'
           WHEN event_type = 'queue.call.abandoned'  THEN 'Caller hung up in the queue'
           WHEN event_type = 'queue.call.timed_out'  THEN 'Queue timed out'
           WHEN event_type = 'queue.call.exited'     THEN 'Caller left the queue'
           WHEN event_type = 'queue.call.callback_requested'
                                                  THEN 'Caller asked for a callback'
           WHEN event_type = 'call.ringing'       THEN 'Rang'
           WHEN event_type = 'call.mobile_push_wakeup' THEN 'Woke a mobile app'
           WHEN event_type = 'call.answered'      THEN 'Answered'
           -- The consultation leg's transfer is where it handed over and ended;
           -- the original call's is where the caller was passed on.
           WHEN event_type = 'call.transfer' AND consultation_of IS NOT NULL
                                                  THEN 'Transfer completed'
           WHEN event_type = 'call.transfer'      THEN 'Transferred'
           WHEN event_type = 'call.parked'        THEN 'Parked'
           WHEN event_type = 'call.unparked'      THEN 'Picked back up'
           WHEN event_type = 'call.emergency'     THEN 'Emergency call'
           WHEN event_type = 'call.end'           THEN 'Call ended'
           WHEN event_type = 'voicemail.new'      THEN 'Voicemail left'
           WHEN event_type = 'recording.available'              THEN 'Recording ready'
           WHEN event_type = 'recording.failed'                 THEN 'Recording failed'
           WHEN event_type = 'recording.transcription.complete' THEN 'Transcript ready'
           WHEN event_type = 'recording.summary.complete'       THEN 'Summary ready'
           WHEN event_type = 'voicemail.transcription.complete'
                                                  THEN 'Voicemail transcript ready'
           WHEN event_type = 'voicemail.summary.complete'
                                                  THEN 'Voicemail summary ready'
           ELSE replace(event_type::text, '.', ' ')
         END,
         CASE
           -- The far end is already named in the step, so repeating the person
           -- who placed the call as the detail would contradict it.
           WHEN dir = 'outbound'
                AND event_type IN ('call.ringing', 'call.answered')
             THEN NULL

           -- On a transfer the useful fact is where it went, not who sent it. On
           -- the consultation, transferred_to is the caller it was joined to.
           WHEN event_type = 'call.transfer'
             THEN COALESCE(transfer_target,
                           (SELECT full_name FROM people WHERE id = e.person_id))

           -- After a transfer, call.end still names the user who first
           -- answered, though they had handed the caller on. No name is
           -- accurate; theirs isn't. Nothing in the event names who was on
           -- the line at the end. The status isn't stale, so it stays where
           -- it says something — busy, voicemail — and "completed", the
           -- common case, is left off as adding nothing.
           WHEN event_type = 'call.end' AND transferred
             THEN NULLIF(status, 'completed')

           ELSE COALESCE(
                  (SELECT full_name FROM people WHERE id = e.person_id),
                  CASE WHEN park_slot IS NOT NULL THEN 'slot ' || park_slot END,
                  status,
                  payload->>'detail')
         END
  FROM e ORDER BY occurred_at, id
$$;

COMMIT;

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
-- Made-up numbers only.
--
-- DO $$
-- DECLARE r text := ''; s text; v_org uuid; v_num text; v_c uuid; v_c2 uuid; v_i uuid;
--         v_staff text := '+15135558888'; v_fam text := '+15135557777';
-- BEGIN
--   SELECT id INTO v_org FROM organizations WHERE code = 'DR';
--   SELECT e164 INTO v_num FROM phone_numbers WHERE active AND organization_id = v_org ORDER BY e164 LIMIT 1;
--   INSERT INTO directory_entries (organization_id, entry_kind, label, e164)
--   VALUES (v_org, 'staff', 'Staff cell (test)', v_staff);
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'Family (test)') RETURNING id INTO v_c;
--   INSERT INTO contact_phones (organization_id, contact_id, e164, label, is_primary, added_by)
--   VALUES (v_org, v_c, v_fam, 'other', true, 'verify 045');
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'Linked by hand (test)') RETURNING id INTO v_c2;
--
--   SELECT name || ' / ' || source INTO s FROM party_name(v_org, '(513) 555-8888');
--   r := r || 'staff number: ' || coalesce(s, 'nobody') || '   (expect Staff cell (test) / directory)' || chr(10);
--   SELECT name || ' / ' || source INTO s FROM party_name(v_org, v_fam);
--   r := r || 'family number: ' || coalesce(s, 'nobody') || '   (expect Family (test) / contact)' || chr(10);
--   SELECT name || ' / ' || source INTO s FROM party_name(v_org, v_fam, v_c2);
--   r := r || 'family number, linked by hand to another: ' || coalesce(s, 'nobody') || '   (expect Linked by hand (test) / contact)' || chr(10);
--   SELECT name || ' / ' || source INTO s FROM party_name(v_org, 'user_015135558888');
--   r := r || 'unknown user ref: ' || coalesce(s, 'nobody') || '   (expect nobody)' || chr(10);
--   SELECT name || ' / ' || source INTO s FROM party_name(v_org, (SELECT external_ref FROM seats WHERE organization_id = v_org AND external_ref IS NOT NULL LIMIT 1));
--   r := r || 'a seat''s user ref: ' || coalesce(s, 'nobody') || '   (expect a person / seat)' || chr(10);
--   SELECT name INTO s FROM party_name(v_org, '+15135550000');
--   r := r || 'unknown number: ' || coalesce(s, 'nobody') || '   (expect nobody)' || chr(10);
--
--   -- As a column, on a call from the staff cell.
--   v_i := ingest_call_event('call_045_s', 'call.incoming', now(), 'inbound', v_staff, v_num);
--   SELECT peer_name(i) || ' / ' || peer_source(i) INTO s FROM interactions i WHERE i.id = v_i;
--   r := r || 'call from the staff cell: ' || coalesce(s, 'NULL') || '   (expect Staff cell (test) / directory)' || chr(10);
--
--   -- The 20 Oct transfer, both legs, as the feed and the flow will read them.
--   SELECT string_agg(right(external_call_ref, 6) || ' ' || coalesce(peer_name(i), 'NULL') || ' / ' || coalesce(peer_source(i), 'NULL'), '; ' ORDER BY started_at)
--     INTO s FROM interactions i WHERE external_call_ref LIKE '%cjz1g9' OR external_call_ref LIKE '%h4x64e';
--   r := r || 'real legs: ' || coalesce(s, 'none here') || chr(10);
--   SELECT string_agg(step || coalesce(' · ' || detail, ''), ' → ' ORDER BY at) INTO s
--     FROM call_flow((SELECT id FROM interactions WHERE external_call_ref LIKE '%h4x64e'));
--   r := r || 'h4x64e flow: ' || coalesce(s, 'none here') || chr(10);
--   SELECT detail INTO s FROM call_flow((SELECT id FROM interactions WHERE external_call_ref LIKE '%cjz1g9')) WHERE step = 'Transferred';
--   r := r || 'cjz1g9 transferred to: ' || coalesce(s, 'none here') || chr(10);
--
--   -- Reachable by the app's role, as a computed field needs.
--   r := r || 'authenticated can execute peer_name/peer_source/party_name: '
--          || has_function_privilege('authenticated', 'peer_name(interactions)', 'EXECUTE') || '/'
--          || has_function_privilege('authenticated', 'peer_source(interactions)', 'EXECUTE') || '/'
--          || has_function_privilege('authenticated', 'party_name(uuid, text, uuid)', 'EXECUTE')
--          || '   (expect true/true/true)' || chr(10);
--   r := r || 'anon can execute peer_name: ' || has_function_privilege('anon', 'peer_name(interactions)', 'EXECUTE')
--          || '   (expect false)' || chr(10);
--   r := r || 'directory e164 index: ' || (to_regclass('directory_entries_e164_idx') IS NOT NULL)
--          || '   (expect true)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 045 (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
