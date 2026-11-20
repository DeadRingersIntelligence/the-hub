-- =============================================================================
-- 20261120T2000_transcripts_are_evidence.sql
-- The Hub — a transcript is what was said. A firm reads it; nobody rewrites it.
--
-- THE DISTINCTION THIS FILE RESTS ON: THE LOCK PROTECTS WHAT WAS SAID;
-- ATTRIBUTION IS CORRECTABLE. (Planning and Mandie, 20 November.)
--
-- WHAT IS WRONG. transcript_segments carries one firm-scoped FOR ALL policy,
-- transcript_segments_tenant, with 024's identical WITH CHECK, and
-- authenticated holds INSERT, UPDATE and DELETE. So any member of a firm can
-- rewrite what a caller or a member of staff said on a recorded call, or
-- delete it. A transcript is not a finding about the firm. It's the system's
-- record of the firm's own call, and nobody hand-writes one, so the reason to
-- lock it is evidence integrity, not ownership. It sits under the retention
-- terms 20261120T1400 locked: a firm that can't shorten retention but can
-- edit transcripts has the same hole through a different door.
-- db/README.md, "Evidence isn't erased by the party it concerns".
--
-- THREE PARTS:
--
--   1. THE LOCK: the 20261120T1400 shape, its fourth use. _read FOR SELECT
--      carries the current expression; _write is is_internal().
--
--   2. REDACTION: Dead Ringers only, on the firm's request (Mandie's ruling).
--      The firm asks; Dead Ringers removes it.
--        * The segment row is never deleted. The removed text becomes a
--          marker, [redacted], and who asked, who did it, when and why go into
--          transcript_redactions. A redaction that leaves no trace can't be
--          told from tampering.
--        * The removed text isn't kept anywhere. If the reason to redact is
--          that something shouldn't be stored, copying it to an audit table
--          recreates the problem one table over. transcript_redactions holds
--          neither the text nor its length.
--        * redact_transcript_segment() is INVOKER, not DEFINER: _write already
--          admits Dead Ringers. Its is_internal() guard is there so a refusal
--          is a sentence, not a silent zero rows.
--        * transcript_redactions can be inserted into by Dead Ringers alone,
--          and updated or deleted by nobody: no grant and no policy for it.
--          It's evidence about evidence.
--
--   3. THE MERGE RE-POINT: the one SECURITY DEFINER path.
--      repoint_transcript_contact() changes contact_id alone, only from a
--      contact already merged into the survivor (contacts.merged_into is its
--      proof), only within that firm, and only for a caller at that firm or
--      Dead Ringers. It can't touch the text. That's what reconciles it with
--      the lock. merge_contacts' body is replaced to call it, with a drift
--      check against 20261106T1300's reviewed text: the direct UPDATE comes
--      out, and the call goes in after merged_into is set.
--
-- THE WRITE PATHS INTO transcript_segments AFTER THIS FILE. There are no
-- others. Anyone adding one should read this first:
--
--   text         redact_transcript_segment()   Dead Ringers, on request
--   contact_id   repoint_transcript_contact()  a contact merge (DEFINER)
--   person_id    merge_people()                Dead Ringers (internal-only
--                                              since 20261106T1100); this is
--                                              attribution too
--   new rows     the transcription pipeline, which writes as service_role
--                (BYPASSRLS), outside this file's reach
--
-- WHY BEFORE CONTACT IMPORT (planning): import is what produces the
-- duplicates that need merge_contacts, and merge_contacts is what this file
-- fixes. Without section 3, locking the table would make every merge of a
-- contact who appears in a transcript refuse, through assert_merge_complete.
--
-- WHAT THE REDACTION CALL CARRIES. p_passage, the exact text to remove, has
-- to be sent in the call, so it passes through the request and may appear in
-- the SQL editor's history or a statement log. The Hub doesn't store it.
-- Whoever runs a redaction should know that the call itself is the one place
-- it travels.
--
-- IT REMOVES NO WORKING FEATURE. hellophone reads transcript_segments (the
-- call panel's transcript tab) and writes it nowhere, on any of its 20
-- branches. The reads are unchanged.
--
-- Requires: 008 (transcript_segments), 024, 20261106T1300 (merge_contacts,
--           assert_merge_complete), 20261120T1400 (the shape),
--           20261103T1200 (record_migration).
-- NOT SAFE TO RUN TWICE: section 1 refuses on a second run.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Preconditions: the policy is the one expected, merge_contacts is
--    20261106T1300's reviewed body, and nothing from this file is here yet
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_n int; v_ok boolean; v_md5 text;
BEGIN
  IF to_regclass('public.transcript_redactions') IS NOT NULL
     OR EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'public.transcript_segments'::regclass
                                          AND polname = 'transcript_segments_read') THEN
    RAISE EXCEPTION 'already converted; nothing to do here'
      USING HINT = 'This migration has run on this database. Not an error to fix — stop.';
  END IF;

  SELECT count(*),
         bool_and(polname = 'transcript_segments_tenant' AND polcmd = '*' AND polroles = '{0}'
                  AND pg_get_expr(polqual, polrelid) = pg_get_expr(polwithcheck, polrelid)),
         md5(string_agg(pg_get_expr(polqual, polrelid), ''))
    INTO v_n, v_ok, v_md5
    FROM pg_policy WHERE polrelid = 'public.transcript_segments'::regclass;
  IF NOT (v_n = 1 AND v_ok AND v_md5 = 'e001fae7c6dc9ee510219d97d074882b') THEN
    RAISE EXCEPTION 'transcript_segments carries % policies, not the expected _tenant (expression md5 %); stop and read them', v_n, v_md5
      USING HINT = 'Expected one FOR ALL policy TO public, WITH CHECK equal to USING: '
                   '(is_internal() OR organization_id = current_organization_id()).';
  END IF;

  IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_class
           WHERE oid = 'public.transcript_segments'::regclass) THEN
    RAISE EXCEPTION 'row-level security is not enabled and FORCEd on transcript_segments; stop and look';
  END IF;

  SELECT md5(prosrc) INTO v_md5 FROM pg_proc WHERE oid = 'merge_contacts(uuid, uuid, text)'::regprocedure;
  IF v_md5 IS DISTINCT FROM '68a128b6d7ece644baffe4369d4b20ae' THEN
    RAISE EXCEPTION 'merge_contacts'' body is not 20261106T1300''s (md5 %); stop and diff it', v_md5;
  END IF;
  IF to_regprocedure('redact_transcript_segment(uuid, text, text, text)') IS NOT NULL
     OR to_regprocedure('repoint_transcript_contact(uuid, uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'a function from this file already exists; stop and read the ledger';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. The lock
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_qual text;
BEGIN
  SELECT pg_get_expr(polqual, polrelid) INTO v_qual
    FROM pg_policy WHERE polrelid = 'public.transcript_segments'::regclass
                     AND polname = 'transcript_segments_tenant';
  DROP POLICY transcript_segments_tenant ON transcript_segments;
  EXECUTE format('CREATE POLICY transcript_segments_read ON transcript_segments FOR SELECT TO authenticated USING (%s)', v_qual);
END $$;

CREATE POLICY transcript_segments_write ON transcript_segments FOR ALL
  USING (is_internal()) WITH CHECK (is_internal());

COMMENT ON POLICY transcript_segments_read ON transcript_segments IS
  'The firm reads its calls'' transcripts as before: 008''s expression, '
  'carried across unchanged and now FOR SELECT (20261120T2000).';
COMMENT ON POLICY transcript_segments_write ON transcript_segments IS
  'Nobody at the firm rewrites what was said. The lock protects the text; '
  'attribution is correctable. After a transcript is written, the only write '
  'paths are redact_transcript_segment() (text, Dead Ringers on request), '
  'repoint_transcript_contact() (contact_id, a merge) and merge_people() '
  '(person_id, Dead Ringers). See 20261120T2000 before adding one.';

-- -----------------------------------------------------------------------------
-- 3. Redaction
-- -----------------------------------------------------------------------------
CREATE TABLE transcript_redactions (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  interaction_id   uuid NOT NULL REFERENCES interactions(id) ON DELETE CASCADE,
  segment_id       uuid NOT NULL REFERENCES transcript_segments(id) ON DELETE CASCADE,
  whole_segment    boolean NOT NULL,
  requested_by     text NOT NULL CHECK (btrim(requested_by) <> ''),
  reason           text NOT NULL CHECK (btrim(reason) <> ''),
  redacted_by      uuid NOT NULL REFERENCES users(id),
  redacted_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX transcript_redactions_interaction_idx ON transcript_redactions (interaction_id);

COMMENT ON TABLE transcript_redactions IS
  'One row per redaction of a transcript segment: who asked, who did it, when '
  'and why. Never the removed text, nor its length: if something shouldn''t be '
  'stored, a copy here would store it one table over. Inserted by '
  'redact_transcript_segment() alone; updated or deleted by nobody '
  '(20261120T2000).';

ALTER TABLE transcript_redactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE transcript_redactions FORCE ROW LEVEL SECURITY;
-- service_role too: on creation it would get TRUNCATE, REFERENCES, TRIGGER and
-- MAINTAIN by default (db/README.md, "Default privileges"). The pipeline has no
-- business with this table, and TRUNCATE would empty the log. Revoking from
-- every client role and granting back only these two makes the grants say
-- what's intended, identically on every database.
REVOKE ALL ON transcript_redactions FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT ON transcript_redactions TO authenticated;

CREATE POLICY transcript_redactions_read ON transcript_redactions FOR SELECT TO authenticated
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY transcript_redactions_insert ON transcript_redactions FOR INSERT
  WITH CHECK (is_internal());

COMMENT ON POLICY transcript_redactions_read ON transcript_redactions IS
  'The firm sees every redaction of its own transcripts (20261120T2000).';
COMMENT ON POLICY transcript_redactions_insert ON transcript_redactions IS
  'Dead Ringers records a redaction. There is no UPDATE or DELETE grant or '
  'policy: a record of a redaction is evidence too (20261120T2000).';

CREATE FUNCTION redact_transcript_segment(p_segment uuid, p_requested_by text,
                                          p_reason text, p_passage text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE s record; v_user uuid := current_user_id(); v_passage text := NULLIF(p_passage, '');
BEGIN
  IF NOT is_internal() THEN
    RAISE EXCEPTION 'a transcript is redacted by Dead Ringers, at the firm''s request'
      USING ERRCODE = '42501',
            HINT = 'Ask Dead Ringers, saying which call, what to remove and why.';
  END IF;
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'your sign-in isn''t linked to a Hub user, so the redaction can''t say who did it';
  END IF;
  IF NULLIF(btrim(COALESCE(p_requested_by, '')), '') IS NULL
     OR NULLIF(btrim(COALESCE(p_reason, '')), '') IS NULL THEN
    RAISE EXCEPTION 'a redaction needs who asked for it and why';
  END IF;

  SELECT id, organization_id, interaction_id, body INTO s
    FROM transcript_segments WHERE id = p_segment FOR UPDATE;
  IF s.id IS NULL THEN
    RAISE EXCEPTION 'that transcript segment couldn''t be found' USING ERRCODE = 'P0002';
  END IF;
  -- The error doesn't repeat the passage: the passage is what's being removed.
  IF v_passage IS NOT NULL AND position(v_passage IN s.body) = 0 THEN
    RAISE EXCEPTION 'that passage isn''t in this segment; nothing was changed';
  END IF;

  UPDATE transcript_segments
     SET body = CASE WHEN v_passage IS NULL THEN '[redacted]'
                     ELSE replace(body, v_passage, '[redacted]') END
   WHERE id = p_segment;

  INSERT INTO transcript_redactions
    (organization_id, interaction_id, segment_id, whole_segment, requested_by, reason, redacted_by)
  VALUES (s.organization_id, s.interaction_id, s.id, v_passage IS NULL,
          btrim(p_requested_by), btrim(p_reason), v_user);
END $$;

COMMENT ON FUNCTION redact_transcript_segment(uuid, text, text, text) IS
  'Dead Ringers removes text from a transcript at the firm''s request. With '
  'p_passage, every occurrence of it in the segment becomes [redacted]; without '
  'it, the whole segment does. The row stays, and transcript_redactions records '
  'who asked, who did it, when and why, never what was removed. INVOKER: '
  'transcript_segments_write admits Dead Ringers; the guard makes a refusal a '
  'sentence (20261120T2000).';

REVOKE ALL ON FUNCTION redact_transcript_segment(uuid, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION redact_transcript_segment(uuid, text, text, text) TO authenticated;

-- -----------------------------------------------------------------------------
-- 4. The merge re-point: the one SECURITY DEFINER path
-- -----------------------------------------------------------------------------
CREATE FUNCTION repoint_transcript_contact(p_loser uuid, p_survivor uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_org uuid; v_into uuid; n integer;
BEGIN
  SELECT organization_id, merged_into INTO v_org, v_into FROM contacts WHERE id = p_loser;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'that contact couldn''t be found' USING ERRCODE = 'P0002';
  END IF;
  -- The proof that this is a merge: the loser already points at the survivor.
  IF v_into IS DISTINCT FROM p_survivor THEN
    RAISE EXCEPTION 'a transcript''s contact moves only when that contact has been merged into this one'
      USING HINT = 'This is called by merge_contacts after it sets merged_into, and by nothing else.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM contacts WHERE id = p_survivor AND organization_id = v_org) THEN
    RAISE EXCEPTION 'contacts belong to different organizations';
  END IF;
  -- DEFINER bypasses RLS, so the caller's reach is checked by hand.
  IF NOT (is_internal() OR v_org = current_organization_id()) THEN
    RAISE EXCEPTION 'you can''t merge contacts at that firm' USING ERRCODE = '42501';
  END IF;

  UPDATE transcript_segments SET contact_id = p_survivor
   WHERE contact_id = p_loser AND organization_id = v_org;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

COMMENT ON FUNCTION repoint_transcript_contact(uuid, uuid) IS
  'The one SECURITY DEFINER write path into transcript_segments: contact_id '
  'alone, only from a contact already merged into the survivor, only within '
  'one firm, only for a caller at that firm or Dead Ringers. It can''t touch '
  'the text: the lock protects what was said; attribution is correctable. '
  'Called by merge_contacts (20261120T2000).';

REVOKE ALL ON FUNCTION repoint_transcript_contact(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION repoint_transcript_contact(uuid, uuid) TO authenticated;

-- merge_contacts: 20261106T1300's body with two changes. The direct
-- UPDATE of transcript_segments is removed, and the call above is added after
-- merged_into is set, before assert_merge_complete. Its comment (20261106T1200)
-- still holds.
CREATE OR REPLACE FUNCTION merge_contacts(p_survivor uuid, p_loser uuid, p_actor text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_org uuid;
  v_survivor_name text;
  v_loser_name text;
  v_moved int;
  v_consents int;
  v_relationships int;
  v_second int;
  v_directory int;
  v_user uuid := current_user_id();
BEGIN
  IF p_survivor = p_loser THEN RAISE EXCEPTION 'cannot merge a contact into itself'; END IF;

  SELECT organization_id, full_name INTO v_org, v_survivor_name
    FROM contacts WHERE id = p_survivor;
  IF v_org IS NULL THEN RAISE EXCEPTION 'survivor not found'; END IF;

  SELECT full_name INTO v_loser_name
    FROM contacts WHERE id = p_loser AND organization_id = v_org;
  IF NOT FOUND THEN RAISE EXCEPTION 'contacts belong to different organizations'; END IF;

  -- Neither end may already be merged away. Without this, merging into a
  -- contact that has itself been merged builds a chain, and every reader of
  -- merged_into resolves exactly one hop — so the call would land on a record
  -- that is no longer anybody.
  IF EXISTS (SELECT 1 FROM contacts WHERE id = p_survivor AND merged_into IS NOT NULL) THEN
    RAISE EXCEPTION 'that contact has itself been merged into another one'
      USING HINT = 'Merge into the surviving contact instead.';
  END IF;
  IF EXISTS (SELECT 1 FROM contacts WHERE id = p_loser AND merged_into IS NOT NULL) THEN
    RAISE EXCEPTION 'that contact has already been merged away'
      USING HINT = 'It is not a contact any more — merge the one it was merged into.';
  END IF;

  UPDATE contact_phones
     SET contact_id = p_survivor, is_primary = false, merged_from_contact_id = p_loser
   WHERE contact_id = p_loser;
  GET DIAGNOSTICS v_moved = ROW_COUNT;

  UPDATE interactions             SET contact_id = p_survivor WHERE contact_id = p_loser;
  UPDATE interaction_participants SET contact_id = p_survivor WHERE contact_id = p_loser;
  UPDATE leads                    SET contact_id = p_survivor WHERE contact_id = p_loser;
  -- Next of kin captured at wrap-up (048).
  UPDATE interactions SET next_of_kin_contact_id = p_survivor
   WHERE next_of_kin_contact_id = p_loser;

  -- Added 20261106T1200. Everything below was left on the loser before.
  UPDATE consents            SET contact_id = p_survivor WHERE contact_id = p_loser;
  GET DIAGNOSTICS v_consents = ROW_COUNT;
  UPDATE directory_entries   SET contact_id = p_survivor WHERE contact_id = p_loser;
  GET DIAGNOSTICS v_directory = ROW_COUNT;
  UPDATE threads             SET contact_id = p_survivor WHERE contact_id = p_loser;
  UPDATE reminders           SET contact_id = p_survivor WHERE contact_id = p_loser;
  UPDATE alerts              SET contact_id = p_survivor WHERE contact_id = p_loser;
  UPDATE callback_requests   SET contact_id = p_survivor WHERE contact_id = p_loser;
  UPDATE custom_field_values SET contact_id = p_survivor WHERE contact_id = p_loser;

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

  -- A relationship recorded BETWEEN these two would become a contact related
  -- to itself as soon as either end moves. Removed first, so no such row
  -- exists even for a statement.
  DELETE FROM contact_relationships
   WHERE (from_contact_id = p_loser    AND to_contact_id = p_survivor)
      OR (from_contact_id = p_survivor AND to_contact_id = p_loser);

  -- UNIQUE (from_contact_id, to_contact_id), and both columns reference
  -- contacts, so each end gets the skip-then-delete shape separately.
  UPDATE contact_relationships SET from_contact_id = p_survivor
   WHERE from_contact_id = p_loser
     AND NOT EXISTS (SELECT 1 FROM contact_relationships s
                     WHERE s.from_contact_id = p_survivor
                       AND s.to_contact_id = contact_relationships.to_contact_id);
  GET DIAGNOSTICS v_relationships = ROW_COUNT;
  DELETE FROM contact_relationships WHERE from_contact_id = p_loser;

  UPDATE contact_relationships SET to_contact_id = p_survivor
   WHERE to_contact_id = p_loser
     AND NOT EXISTS (SELECT 1 FROM contact_relationships s
                     WHERE s.to_contact_id = p_survivor
                       AND s.from_contact_id = contact_relationships.from_contact_id);
  GET DIAGNOSTICS v_second = ROW_COUNT;
  v_relationships := v_relationships + v_second;
  DELETE FROM contact_relationships WHERE to_contact_id = p_loser;

  -- "These two are not duplicates", about a contact that no longer exists.
  -- Moving one would claim the SURVIVOR is not a duplicate of something
  -- nobody has compared it to.
  DELETE FROM contact_merge_dismissals
   WHERE contact_a_id = p_loser OR contact_b_id = p_loser;

  -- Anything already merged into the loser follows it to the survivor, BEFORE
  -- the loser is pointed away. Merging into a contact that has absorbed others
  -- is ordinary; without this it is what creates the chain the guard above
  -- refuses to create directly.
  UPDATE contacts SET merged_into = p_survivor, updated_at = now()
   WHERE merged_into = p_loser;

  UPDATE contacts SET merged_into = p_survivor, updated_at = now() WHERE id = p_loser;

  -- Transcripts are internal-write since 20261120T2000, so this caller can't
  -- re-point them. The one narrow path that can: a DEFINER function that
  -- changes contact_id alone, only from a contact already merged into this
  -- survivor, within one firm. It runs here, after merged_into is set (its
  -- proof that this is a merge) and before assert_merge_complete (which would
  -- otherwise name transcript_segments.contact_id).
  PERFORM repoint_transcript_contact(p_loser, p_survivor);

  -- Did that cover it? assert_merge_complete reads pg_constraint for every
  -- foreign key pointing at contacts and raises, naming any column that still
  -- holds a row for the loser. One implementation, shared with
  -- merge_decedents and merge_people: this loop lived here until
  -- 20261106T1300 and was about to be written a third time.
  PERFORM assert_merge_complete(
    'contacts'::regclass, p_loser,
    -- Set to the loser on purpose: it records where a phone number came from.
    ARRAY['contact_phones.merged_from_contact_id']);

  PERFORM record_change(
    v_org, 'contact', p_survivor, 'merged',
    CASE WHEN v_user IS NOT NULL THEN 'user' ELSE 'system' END::actor_kind, p_actor,
    format('%s merged %s into %s', p_actor,
           COALESCE(v_loser_name, 'an unnamed contact'),
           COALESCE(v_survivor_name, 'this contact')),
    v_user,
    jsonb_build_object('merged_contact_id', p_loser,
                       'merged_contact_name', v_loser_name,
                       'phone_numbers_moved', v_moved,
                       'consents_moved', v_consents,
                       'relationships_moved', v_relationships,
                       'directory_entries_moved', v_directory));
END $$;

-- -----------------------------------------------------------------------------
-- 5. Record it
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261120T2000_transcripts_are_evidence.sql',
    NULL,
    'transcript_segments locked (_read as before, _write is_internal()). '
    'Redaction: Dead Ringers on request, the text becomes [redacted], '
    'transcript_redactions records who/when/why and never the text. Merge: '
    'repoint_transcript_contact (DEFINER, contact_id only), called by '
    'merge_contacts in place of its direct UPDATE.');
END $rec$;

COMMIT;

-- =============================================================================
-- Verification — run AFTER the file, as its own statement. One block,
-- everything rolled back by the closing RAISE.
--
-- A fixture firm with one call and two transcript segments. One carries a card
-- number and is attributed to Ann, whose duplicate, Anne, is the survivor.
-- Another firm has a merged pair of its own. Writes run as authenticated,
-- because postgres holds BYPASSRLS.
--
-- DO $$
-- DECLARE
--   r text := ''; n int; res text; p text;
--   v_org uuid; v_other uuid; v_user uuid; v_auth uuid := gen_random_uuid(); v_call uuid;
--   v_ann uuid; v_anne uuid; v_c uuid; v_d uuid; s1 uuid; s2 uuid;
--   v_card CONSTANT text := '4111 1111 1111 1111';
-- BEGIN
--   r := r || '1. policies: ' || (SELECT string_agg(c.relname || '.' || p2.polname || '(' || p2.polcmd::text || ')', ' ' ORDER BY 1)
--            FROM pg_policy p2 JOIN pg_class c ON c.oid = p2.polrelid
--           WHERE c.relname IN ('transcript_segments', 'transcript_redactions'))
--          || chr(10) || '   (expect transcript_redactions insert(a) read(r); transcript_segments read(r) write(*))' || chr(10);
--   r := r || '2. authenticated may UPDATE / DELETE transcript_redactions: '
--          || has_table_privilege('authenticated', 'public.transcript_redactions', 'UPDATE') || ' / '
--          || has_table_privilege('authenticated', 'public.transcript_redactions', 'DELETE')
--          || '   (expect false / false: nobody, Dead Ringers included)' || chr(10);
--   r := r || '2b. every grant on transcript_redactions: '
--          || (SELECT string_agg(a.grantee::regrole::text || ':' || a.privilege_type, ', ' ORDER BY 1)
--                FROM pg_class c, aclexplode(c.relacl) a
--               WHERE c.oid = 'public.transcript_redactions'::regclass)
--          || chr(10) || '   (expect authenticated:INSERT, authenticated:SELECT, and the owner''s own, nothing for service_role)' || chr(10);
--   r := r || '3. transcript_redactions'' text columns: '
--          || (SELECT string_agg(column_name, ', ' ORDER BY column_name) FROM information_schema.columns
--               WHERE table_name = 'transcript_redactions' AND data_type = 'text')
--          || '   (expect reason, requested_by: nowhere to put the removed text)' || chr(10);
--
--   -- ---- the fixture, as Dead Ringers -------------------------------------
--   PERFORM set_config('app.is_internal', 'on', true);
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ verify 2000', 'funeral_home') RETURNING id INTO v_org;
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ verify 2000 other', 'funeral_home') RETURNING id INTO v_other;
--   INSERT INTO users (email, full_name, auth_user_id)
--   VALUES ('zzz-verify-2000@example.invalid', 'ZZZ Verification', v_auth) RETURNING id INTO v_user;
--   INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id)
--   VALUES (v_user, 'organization', 'professional', v_org);
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'ZZZ Ann') RETURNING id INTO v_ann;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'ZZZ Anne') RETURNING id INTO v_anne;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_other, 'ZZZ C') RETURNING id INTO v_c;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_other, 'ZZZ D') RETURNING id INTO v_d;
--   UPDATE contacts SET merged_into = v_d WHERE id = v_c;
--   INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at)
--   VALUES (v_org, 'inbound', now(), now()) RETURNING id INTO v_call;
--   INSERT INTO transcript_segments (organization_id, interaction_id, segment_order, body, contact_id)
--   VALUES (v_org, v_call, 1, 'my card is ' || v_card || ', thanks', v_ann) RETURNING id INTO s1;
--   INSERT INTO transcript_segments (organization_id, interaction_id, segment_order, body)
--   VALUES (v_org, v_call, 2, 'and my mother''s date of birth is') RETURNING id INTO s2;
--   PERFORM set_config('app.is_internal', 'off', true);
--
--   PERFORM set_config('request.jwt.claims', json_build_object('sub', v_auth::text)::text, true);
--   PERFORM set_config('role', 'authenticated', true);
--
--   -- ---- the lock: a professional, then a manager --------------------------
--   FOREACH p IN ARRAY ARRAY['professional', 'manager'] LOOP
--    BEGIN
--     IF p = 'manager' THEN
--       PERFORM set_config('role', 'none', true);
--       UPDATE user_scopes SET view_profile = 'manager' WHERE user_id = v_user;
--       PERFORM set_config('role', 'authenticated', true);
--     END IF;
--     SELECT count(*) INTO n FROM transcript_segments WHERE interaction_id = v_call;
--     res := n::text;
--     UPDATE transcript_segments SET body = 'rewritten' WHERE interaction_id = v_call;
--     GET DIAGNOSTICS n = ROW_COUNT; res := res || ' / ' || n;
--     DELETE FROM transcript_segments WHERE interaction_id = v_call;
--     GET DIAGNOSTICS n = ROW_COUNT; res := res || ' / ' || n;
--     BEGIN INSERT INTO transcript_segments (organization_id, interaction_id, segment_order, body)
--           VALUES (v_org, v_call, 3, 'invented'); res := res || ' / ALLOWED';
--     EXCEPTION WHEN insufficient_privilege THEN res := res || ' / ' || SQLSTATE; END;
--     BEGIN PERFORM redact_transcript_segment(s1, 'me', 'because'); res := res || ' / redact ALLOWED';
--     EXCEPTION WHEN insufficient_privilege THEN res := res || ' / redact ' || SQLSTATE; END;
--     BEGIN INSERT INTO transcript_redactions (organization_id, interaction_id, segment_id, whole_segment, requested_by, reason, redacted_by)
--           VALUES (v_org, v_call, s1, true, 'x', 'x', v_user); res := res || ' / log ALLOWED';
--     EXCEPTION WHEN insufficient_privilege THEN res := res || ' / log ' || SQLSTATE; END;
--     r := r || '4. ' || rpad(p, 13) || 'read / rewrite / delete / insert / redact / write the log: ' || res
--            || '   (expect 2 / 0 / 0 / 42501 / redact 42501 / log 42501)' || chr(10);
--     RAISE EXCEPTION USING ERRCODE = 'ZZ001';
--    EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
--    END;
--   END LOOP;
--
--   -- ---- redaction, by Dead Ringers ----------------------------------------
--   PERFORM set_config('app.is_internal', 'on', true);
--   BEGIN PERFORM redact_transcript_segment(s1, 'Ann, by phone', 'card number read aloud', 'not in it');
--         res := 'ALLOWED';
--   EXCEPTION WHEN OTHERS THEN res := SQLERRM; END;
--   r := r || '5. a passage that isn''t there: ' || res || '   (expect "that passage isn''t in this segment; nothing was changed")' || chr(10);
--   BEGIN PERFORM redact_transcript_segment(s1, 'Ann, by phone', '  '); res := 'ALLOWED';
--   EXCEPTION WHEN OTHERS THEN res := SQLERRM; END;
--   r := r || '6. no reason: ' || res || '   (expect "a redaction needs who asked for it and why")' || chr(10);
--   PERFORM redact_transcript_segment(s1, 'Ann, by phone', 'card number read aloud', v_card);
--   PERFORM redact_transcript_segment(s2, 'Ann, by phone', 'asked to remove the whole line');
--   r := r || '7. after redacting: "' || (SELECT body FROM transcript_segments WHERE id = s1) || '" and "'
--          || (SELECT body FROM transcript_segments WHERE id = s2) || '"'
--          || '   (expect "my card is [redacted], thanks" and "[redacted]")' || chr(10);
--   r := r || '8. the card number anywhere in either table: '
--          || ((SELECT count(*) FROM transcript_segments WHERE body LIKE '%' || v_card || '%')
--            + (SELECT count(*) FROM transcript_redactions r2
--                WHERE r2.requested_by LIKE '%' || v_card || '%' OR r2.reason LIKE '%' || v_card || '%'))
--          || '   (expect 0)' || chr(10);
--   r := r || '9. the log: ' || (SELECT string_agg(whole_segment::text || ', ' || requested_by || ', ' || reason
--                                       || ', by ' || (redacted_by = v_user)::text, ' | ' ORDER BY whole_segment)
--                                  FROM transcript_redactions WHERE interaction_id = v_call)
--          || chr(10) || '   (expect false, Ann by phone, card number read aloud, by true | true, …, by true)' || chr(10);
--   r := r || '10. segments still there: ' || (SELECT count(*) FROM transcript_segments WHERE interaction_id = v_call)
--          || '   (expect 2: redaction never deletes the row)' || chr(10);
--   BEGIN UPDATE transcript_redactions SET reason = 'changed' WHERE interaction_id = v_call; res := 'ALLOWED';
--   EXCEPTION WHEN insufficient_privilege THEN res := SQLSTATE; END;
--   r := r || '11. Dead Ringers rewriting the log: ' || res || '   (expect 42501: no grant)' || chr(10);
--   PERFORM set_config('app.is_internal', 'off', true);
--
--   -- ---- the merge, by a manager at the firm -------------------------------
--   PERFORM set_config('role', 'none', true);
--   UPDATE user_scopes SET view_profile = 'manager' WHERE user_id = v_user;
--   PERFORM set_config('role', 'authenticated', true);
--   BEGIN PERFORM repoint_transcript_contact(v_ann, v_anne); res := 'ALLOWED';
--   EXCEPTION WHEN OTHERS THEN res := SQLERRM; END;
--   r := r || '12. re-point without a merge: ' || res || '   (expect "…only when that contact has been merged into this one")' || chr(10);
--   BEGIN PERFORM repoint_transcript_contact(v_c, v_d); res := 'ALLOWED';
--   EXCEPTION WHEN OTHERS THEN res := SQLSTATE; END;
--   r := r || '13. re-point at another firm (merged there): ' || res || '   (expect 42501)' || chr(10);
--   PERFORM merge_contacts(v_anne, v_ann, 'ZZZ Verification');
--   r := r || '14. merge_contacts by the firm: done; the segment''s contact is now the survivor: '
--          || (SELECT contact_id = v_anne FROM transcript_segments WHERE id = s1)
--          || ', its text unchanged: ' || (SELECT body = 'my card is [redacted], thanks' FROM transcript_segments WHERE id = s1)
--          || '   (expect true, true)' || chr(10);
--   r := r || '15. the firm reads its redactions: ' || (SELECT count(*) FROM transcript_redactions WHERE interaction_id = v_call)
--          || '   (expect 2)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261120T2000_transcripts_are_evidence (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
