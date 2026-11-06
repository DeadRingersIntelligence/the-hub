-- =============================================================================
-- 20261106T1300_one_completeness_check.sql
-- The Hub — the merge functions check their own work, and there is one
-- check rather than three.
--
-- WHAT THIS DOES. 20261106T1200 gave merge_contacts a completeness check: a
-- loop over pg_constraint that counts rows still pointing at the merged
-- record and raises, naming any column that does. It was the right idea and
-- the wrong place. merge_decedents and merge_people need the same check, and
-- copying twenty lines twice more is how this schema ended up stating the
-- E.164 pattern in several places and spending four migrations getting back
-- to one.
--
-- So the loop becomes assert_merge_complete(table, id, exclusions), and all
-- three merge functions call it. merge_contacts' body loses the copy it was
-- given yesterday.
--
-- WHY A CHECK AT ALL, which is worth restating because it is not a tidiness
-- measure. An UPDATE that matches no rows affects zero rows and raises
-- nothing, so a merge is silently incomplete in three different ways:
--
--   A COLUMN NOBODY ADDED to the function. My own list of contact-referencing
--   columns, scanned from the migrations, missed
--   interactions.next_of_kin_contact_id because 048 adds it inside a
--   multi-column ALTER TABLE. I only noticed because merge_contacts already
--   moved it. A list I cannot verify is not a list to rely on; the catalogue
--   knows.
--
--   A COLUMN ADDED LATER. merge_people's precondition refuses to install if
--   the catalogue has a people-referencing column its list lacks, which
--   protects a fresh database and does nothing for one where the file has
--   already run. A runtime check protects both.
--
--   A POLICY, not a gap. directory_entries_update requires
--   can_manage_settings(), so a firm user without it sees those rows, writes
--   none, and gets no error. Proved on staging: a 'professional' running
--   merge_contacts is now refused with "directory_entries.contact_id (1)".
--
-- WHAT THE CHECK CANNOT SEE, and the reason the three functions are not
-- identical. It runs as the caller, so a row hidden by a policy counts as
-- zero to it as well: a blind caller cannot detect its own blindness. Every
-- table referencing contacts and decedents is firm-scoped, so both of those
-- stay INVOKER and the check is trustworthy for them. merge_people touches
-- users, whose visibility is per-user — which is why that one is gated to
-- is_internal() and the check is trustworthy there for a different reason:
-- the caller sees everything.
--
-- ONE EXCLUSION EXISTS, and only for contacts.
-- contact_phones.merged_from_contact_id is set TO the loser on purpose, as
-- the record of where a phone number came from. Counting it would make the
-- function refuse every merge it had just performed correctly. decedents and
-- people have no such column and pass no exclusions.
--
-- Requires: 20261106T1000, T1100, T1200 (the three bodies this replaces),
--           20261103T1200.
-- Safe to run twice: each body has a three-state drift check.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. All three bodies are the ones this file expects to replace
--
-- Three hashes, each measured from the file that installed it, and each
-- checked separately so a database where one has drifted says which one.
-- -----------------------------------------------------------------------------
DO $pre$
DECLARE
  v_d text; v_p text; v_c text;
BEGIN
  SELECT md5(prosrc) INTO v_d FROM pg_proc
   WHERE oid = to_regprocedure('public.merge_decedents(uuid,uuid,text)');
  SELECT md5(prosrc) INTO v_p FROM pg_proc
   WHERE oid = to_regprocedure('public.merge_people(uuid,uuid,text)');
  SELECT md5(prosrc) INTO v_c FROM pg_proc
   WHERE oid = to_regprocedure('public.merge_contacts(uuid,uuid,text)');

  IF v_d IS NULL OR v_p IS NULL OR v_c IS NULL THEN
    RAISE EXCEPTION 'merge_decedents, merge_people and merge_contacts must all exist first'
      USING HINT = 'Run 20261106T1000, T1100 and T1200.';
  END IF;

  IF v_d = 'e4af10fedadbb625300c1af01d07386a' AND v_p = '91c26de0d70bc1da6a5bd6edb791484b' AND v_c = '68a128b6d7ece644baffe4369d4b20ae' THEN
    RAISE EXCEPTION 'all three already call the shared check; nothing to do here'
      USING HINT = 'This migration has run on this database. Not an error to fix — stop.';
  END IF;

  IF v_d <> 'ea338970478b68160a8e32d770c871fc' THEN
    RAISE EXCEPTION 'merge_decedents has an unexpected body (md5 %); stop and read it', v_d;
  END IF;
  IF v_p <> 'dd6de70981ab263e1d377b02796eaba5' THEN
    RAISE EXCEPTION 'merge_people has an unexpected body (md5 %); stop and read it', v_p;
  END IF;
  IF v_c <> '4768ee1093e4db88ba98f272712a6cb9' THEN
    RAISE EXCEPTION 'merge_contacts has an unexpected body (md5 %); stop and read it', v_c;
  END IF;
END $pre$;

-- -----------------------------------------------------------------------------
-- 2. The check, once
--
-- INVOKER deliberately. It must see exactly what the merge saw: a definer
-- version would report rows the caller could not have moved, which is a
-- different and more confusing failure than the one it is for.
--
-- regclass rather than text for the table, so a typo is an error at the call
-- site rather than an empty loop that silently approves everything.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION assert_merge_complete(
  p_table regclass, p_id uuid, p_exclude text[] DEFAULT '{}')
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  r record;
  v_left int;
  v_remaining text;
BEGIN
  FOR r IN
    SELECT cl.relname AS tbl, a.attname AS col
      FROM pg_constraint c
      JOIN pg_class cl ON cl.oid = c.conrelid
      JOIN pg_namespace n ON n.oid = cl.relnamespace
      JOIN LATERAL unnest(c.conkey) AS k(attnum) ON true
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
     WHERE c.contype = 'f'
       AND c.confrelid = p_table
       AND n.nspname = 'public'
       AND (cl.relname || '.' || a.attname) <> ALL (p_exclude)
  LOOP
    EXECUTE format('SELECT count(*) FROM public.%I WHERE %I = $1', r.tbl, r.col)
       INTO v_left USING p_id;
    IF v_left > 0 THEN
      v_remaining := COALESCE(v_remaining || ', ', '')
                     || r.tbl || '.' || r.col || ' (' || v_left || ')';
    END IF;
  END LOOP;

  IF v_remaining IS NOT NULL THEN
    RAISE EXCEPTION 'the merge is incomplete; these still point at the merged record: %', v_remaining
      USING HINT = 'Either the merge function does not move that column, or a policy stopped this caller writing it. Nothing has been committed.';
  END IF;
END $$;

COMMENT ON FUNCTION assert_merge_complete(regclass, uuid, text[]) IS
  'Raises if anything still references p_id, naming every column that does. '
  'Called at the end of each merge function, because an UPDATE that moves no '
  'rows — whether the column was forgotten or a policy forbade the write — '
  'affects zero rows and says nothing. Driven from pg_constraint rather than '
  'from a list, because a list scanned from the migrations missed a column '
  'added inside a multi-column ALTER TABLE and there was no way to know what '
  'else it missed. INVOKER on purpose: it must see exactly what the merge '
  'saw. A row hidden from the caller counts as zero here too, so this cannot '
  'rescue a caller who is blind — that is why merge_people is Dead Ringers '
  'only. p_exclude is for columns deliberately left pointing at the merged '
  'record, which today is contact_phones.merged_from_contact_id alone.';

REVOKE ALL ON FUNCTION assert_merge_complete(regclass, uuid, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION assert_merge_complete(regclass, uuid, text[]) TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. The three merge functions, each calling it
--
-- Every other line of all three bodies is byte-identical to what 20261106T1000,
-- T1100 and T1200 installed. The only changes are the PERFORM below, the
-- comment above it, and — in merge_contacts — the removal of the inline loop
-- and the three variables it used.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION merge_decedents(p_survivor uuid, p_loser uuid, p_actor text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_org uuid;
  v_survivor_name text;
  v_loser_name text;
  v_cases int;
  v_interactions int;
  v_contacts int;
  v_user uuid := current_user_id();
BEGIN
  IF p_survivor = p_loser THEN RAISE EXCEPTION 'cannot merge a decedent into itself'; END IF;

  SELECT organization_id, full_name INTO v_org, v_survivor_name
    FROM decedents WHERE id = p_survivor;
  IF v_org IS NULL THEN RAISE EXCEPTION 'survivor not found'; END IF;

  SELECT full_name INTO v_loser_name
    FROM decedents WHERE id = p_loser AND organization_id = v_org;
  IF NOT FOUND THEN RAISE EXCEPTION 'decedents belong to different organizations'; END IF;

  -- Neither end may already be merged away, for merge_contacts' reason: every
  -- reader of merged_into resolves exactly one hop, so a chain lands on a
  -- record that is no longer anybody.
  IF EXISTS (SELECT 1 FROM decedents WHERE id = p_survivor AND merged_into IS NOT NULL) THEN
    RAISE EXCEPTION 'that decedent has itself been merged into another one'
      USING HINT = 'Merge into the surviving record instead.';
  END IF;
  IF EXISTS (SELECT 1 FROM decedents WHERE id = p_loser AND merged_into IS NOT NULL) THEN
    RAISE EXCEPTION 'that decedent has already been merged away'
      USING HINT = 'It is not a record any more — merge the one it was merged into.';
  END IF;

  -- Each of the three has a unique containing decedent_id, so a link the
  -- survivor already holds cannot be repointed onto it. Move what is new,
  -- delete what is duplicate. The delete loses nothing: the survivor has it.
  UPDATE case_decedents SET decedent_id = p_survivor
   WHERE decedent_id = p_loser
     AND NOT EXISTS (SELECT 1 FROM case_decedents s
                     WHERE s.decedent_id = p_survivor
                       AND s.case_id = case_decedents.case_id);
  GET DIAGNOSTICS v_cases = ROW_COUNT;
  DELETE FROM case_decedents WHERE decedent_id = p_loser;

  UPDATE interaction_decedents SET decedent_id = p_survivor
   WHERE decedent_id = p_loser
     AND NOT EXISTS (SELECT 1 FROM interaction_decedents s
                     WHERE s.decedent_id = p_survivor
                       AND s.interaction_id = interaction_decedents.interaction_id);
  GET DIAGNOSTICS v_interactions = ROW_COUNT;
  DELETE FROM interaction_decedents WHERE decedent_id = p_loser;

  UPDATE contact_decedent_links SET decedent_id = p_survivor
   WHERE decedent_id = p_loser
     AND NOT EXISTS (SELECT 1 FROM contact_decedent_links s
                     WHERE s.decedent_id = p_survivor
                       AND s.contact_id = contact_decedent_links.contact_id);
  GET DIAGNOSTICS v_contacts = ROW_COUNT;
  DELETE FROM contact_decedent_links WHERE decedent_id = p_loser;

  -- Anything already merged into the loser follows it, BEFORE the loser is
  -- pointed away. Merging into a record that has absorbed others is ordinary;
  -- without this it is what builds the chain the guard above refuses.
  UPDATE decedents SET merged_into = p_survivor, updated_at = now()
   WHERE merged_into = p_loser;

  UPDATE decedents SET merged_into = p_survivor, updated_at = now() WHERE id = p_loser;

  -- Shared with merge_contacts since 20261106T1300: reads pg_constraint for
  -- every foreign key pointing at decedents and raises, naming any column that
  -- still holds a row for the loser. It catches a column nobody added to this
  -- function, one added to decedents later, and one a policy stopped this caller
  -- writing — all of which otherwise finish quietly.
  PERFORM assert_merge_complete('decedents'::regclass, p_loser);

  PERFORM record_change(
    v_org, 'decedent', p_survivor, 'merged',
    CASE WHEN v_user IS NOT NULL THEN 'user' ELSE 'system' END::actor_kind, p_actor,
    format('%s merged %s into %s', p_actor,
           COALESCE(v_loser_name, 'an unnamed decedent'),
           COALESCE(v_survivor_name, 'this decedent')),
    v_user,
    jsonb_build_object('merged_decedent_id', p_loser,
                       'merged_decedent_name', v_loser_name,
                       'cases_moved', v_cases,
                       'interactions_moved', v_interactions,
                       'contact_links_moved', v_contacts));
END $$;

CREATE OR REPLACE FUNCTION merge_people(p_survivor uuid, p_loser uuid, p_actor text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_org uuid;
  v_survivor_name text;
  v_loser_name text;
  v_survivor_users int;
  v_loser_users int;
  v_teams int;
  v_seats int;
  v_directory int;
  v_user uuid := current_user_id();
BEGIN
  -- First, because everything after it depends on the caller being able to
  -- see and write all 23 tables. See the header: an invoker merge run by a
  -- caller with narrower reach finishes quietly and incompletely.
  IF NOT is_internal() THEN
    RAISE EXCEPTION 'merging people is a Dead Ringers operation'
      USING HINT = 'A firm user cannot see every sign-in, so the merge would leave some behind without saying so.';
  END IF;

  IF p_survivor = p_loser THEN RAISE EXCEPTION 'cannot merge a person into themselves'; END IF;

  SELECT organization_id, full_name INTO v_org, v_survivor_name
    FROM people WHERE id = p_survivor;
  IF v_org IS NULL THEN RAISE EXCEPTION 'survivor not found'; END IF;

  SELECT full_name INTO v_loser_name
    FROM people WHERE id = p_loser AND organization_id = v_org;
  IF NOT FOUND THEN RAISE EXCEPTION 'people belong to different organizations'; END IF;

  IF EXISTS (SELECT 1 FROM people WHERE id = p_survivor AND merged_into IS NOT NULL) THEN
    RAISE EXCEPTION 'that person has themselves been merged into another record'
      USING HINT = 'Merge into the surviving record instead.';
  END IF;
  IF EXISTS (SELECT 1 FROM people WHERE id = p_loser AND merged_into IS NOT NULL) THEN
    RAISE EXCEPTION 'that person has already been merged away'
      USING HINT = 'It is not a record any more — merge the one it was merged into.';
  END IF;

  -- Two sign-ins for one person is not something a merge should create
  -- silently. users.person_id has no unique, so nothing in the schema would
  -- stop it; this is the only thing that does.
  SELECT count(*) INTO v_survivor_users FROM users WHERE person_id = p_survivor;
  SELECT count(*) INTO v_loser_users    FROM users WHERE person_id = p_loser;
  IF v_survivor_users > 0 AND v_loser_users > 0 THEN
    RAISE EXCEPTION 'both of these people have a sign-in; merging would leave one person with two'
      USING HINT = 'Decide which login survives and clear the other user''s person_id first, then merge.';
  END IF;
  UPDATE users SET person_id = p_survivor WHERE person_id = p_loser;

  -- The one column with a unique containing person_id: PRIMARY KEY
  -- (team_id, person_id). Move memberships the survivor lacks, drop the rest.
  UPDATE team_members SET person_id = p_survivor
   WHERE person_id = p_loser
     AND NOT EXISTS (SELECT 1 FROM team_members s
                     WHERE s.person_id = p_survivor
                       AND s.team_id = team_members.team_id);
  GET DIAGNOSTICS v_teams = ROW_COUNT;
  DELETE FROM team_members WHERE person_id = p_loser;

  -- Everything else is a plain repoint: no unique on person_id anywhere else,
  -- so nothing can collide and nothing needs skipping.
  UPDATE seats             SET person_id = p_survivor WHERE person_id = p_loser;
  GET DIAGNOSTICS v_seats = ROW_COUNT;
  UPDATE directory_entries SET person_id = p_survivor WHERE person_id = p_loser;
  GET DIAGNOSTICS v_directory = ROW_COUNT;

  UPDATE cases                    SET arranging_person_id = p_survivor WHERE arranging_person_id = p_loser;
  UPDATE device_sessions          SET person_id = p_survivor WHERE person_id = p_loser;
  UPDATE evaluations              SET subject_person_id = p_survivor WHERE subject_person_id = p_loser;
  UPDATE focus_behaviors          SET person_id = p_survivor WHERE person_id = p_loser;
  UPDATE interaction_events       SET person_id = p_survivor WHERE person_id = p_loser;
  UPDATE interaction_participants SET person_id = p_survivor WHERE person_id = p_loser;
  UPDATE interactions             SET handler_person_id = p_survivor WHERE handler_person_id = p_loser;
  UPDATE interactions             SET original_handler_person_id = p_survivor WHERE original_handler_person_id = p_loser;
  UPDATE leads                    SET owner_person_id = p_survivor WHERE owner_person_id = p_loser;
  UPDATE messages                 SET sender_person_id = p_survivor WHERE sender_person_id = p_loser;
  UPDATE observations             SET subject_person_id = p_survivor WHERE subject_person_id = p_loser;
  UPDATE person_assignments       SET person_id = p_survivor WHERE person_id = p_loser;
  UPDATE reports                  SET recipient_person_id = p_survivor WHERE recipient_person_id = p_loser;
  UPDATE routing_schedules        SET target_person_id = p_survivor WHERE target_person_id = p_loser;
  UPDATE shopper_forms            SET staff_person_id = p_survivor WHERE staff_person_id = p_loser;
  UPDATE shops                    SET shopper_person_id = p_survivor WHERE shopper_person_id = p_loser;
  UPDATE shops                    SET staff_person_requested_id = p_survivor WHERE staff_person_requested_id = p_loser;
  UPDATE transcript_segments      SET person_id = p_survivor WHERE person_id = p_loser;
  UPDATE user_availability_events SET person_id = p_survivor WHERE person_id = p_loser;

  -- Anything already merged into the loser follows it, before the loser is
  -- pointed away.
  UPDATE people SET merged_into = p_survivor, updated_at = now()
   WHERE merged_into = p_loser;

  UPDATE people SET merged_into = p_survivor, updated_at = now() WHERE id = p_loser;

  -- Shared with merge_contacts since 20261106T1300: reads pg_constraint for
  -- every foreign key pointing at people and raises, naming any column that
  -- still holds a row for the loser. It catches a column nobody added to this
  -- function, one added to people later, and one a policy stopped this caller
  -- writing — all of which otherwise finish quietly.
  PERFORM assert_merge_complete('people'::regclass, p_loser);

  PERFORM record_change(
    v_org, 'person', p_survivor, 'merged',
    CASE WHEN v_user IS NOT NULL THEN 'user' ELSE 'system' END::actor_kind, p_actor,
    format('%s merged %s into %s', p_actor,
           COALESCE(v_loser_name, 'an unnamed person'),
           COALESCE(v_survivor_name, 'this person')),
    v_user,
    jsonb_build_object('merged_person_id', p_loser,
                       'merged_person_name', v_loser_name,
                       'sign_in_moved', v_loser_users > 0,
                       'teams_moved', v_teams,
                       'seats_moved', v_seats,
                       'directory_entries_moved', v_directory));
END $$;

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
  UPDATE transcript_segments      SET contact_id = p_survivor WHERE contact_id = p_loser;
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
-- 4. Record it
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261106T1300_one_completeness_check.sql',
    NULL,
    'assert_merge_complete(regclass, uuid, text[]), called by all three merge '
    'functions. merge_contacts loses the inline copy 20261106T1200 gave it; '
    'merge_decedents and merge_people gain the check they did not have.');
END $rec$;

COMMIT;

-- =============================================================================
-- STILL TO DO
--
-- * THE merge_people PRECONDITION LIST IS NOW BELT AND BRACES. It still
--   refuses to install if the catalogue holds a people-referencing column its
--   list lacks, which is a useful thing to learn at install time rather than
--   at merge time. It is no longer the only line of defence, and if keeping
--   it in step becomes a chore it can go: assert_merge_complete covers the
--   same ground at runtime and needs no maintenance.
--
-- * A DRY RUN STILL DOES NOT EXIST. "What would this merge move?" is the
--   question somebody will ask before running one on real data, and the
--   counts are already computed inside each function. It stays unwritten
--   until somebody is about to merge something, because a helper written for
--   an imagined caller is how two implementations of one rule start — which
--   is the thing this file exists to undo.
--
-- * NOTHING CALLS ANY OF THE THREE. Merging remains a Dead Ringers operation
--   in the SQL editor.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- Two things to establish: that all three merge functions still work, and
-- that the shared check actually fires. The second is the one worth the
-- fixture, and it is tested the way 20261106T1200 tested it — as a firm user
-- whose view_profile is 'professional', so can_manage_settings() is false and
-- directory_entries_update refuses the write. The rows are visible, the
-- UPDATE moves none, and without the check the merge would report success.
--
-- ON THE ORDERING CHECKS AT THE END: position() returns 0 when the text is
-- absent, and 0 is less than everything, so "refusal before first UPDATE"
-- written as a bare comparison passes when the message has been renamed or
-- removed. Each one below is written as BETWEEN 1 AND (first update) - 1, so
-- a missing message fails rather than passes.
--
-- DO $$
-- DECLARE
--   r text := ''; n int;
--   v_org uuid; v_a uuid; v_b uuid; v_c uuid;
--   v_pa uuid; v_pb uuid; v_da uuid; v_db uuid;
--   v_user uuid; v_auth uuid := gen_random_uuid(); v_src text;
-- BEGIN
--   r := r || 'the shared check exists and is invoker: '
--          || COALESCE((SELECT (NOT prosecdef)::text FROM pg_proc
--                        WHERE oid = to_regprocedure(
--                          'public.assert_merge_complete(regclass,uuid,text[])')), 'MISSING')
--          || '   (expect true — a definer version would report rows the '
--          || 'caller could not have moved)' || chr(10);
--   r := r || 'anon can call it: '
--          || has_function_privilege('anon',
--               'public.assert_merge_complete(regclass,uuid,text[])', 'EXECUTE')::text
--          || '   (expect false)' || chr(10);
--
--   r := r || 'all three merge functions call it: '
--          || (SELECT count(*) FROM pg_proc
--               WHERE oid IN (to_regprocedure('public.merge_decedents(uuid,uuid,text)'),
--                             to_regprocedure('public.merge_people(uuid,uuid,text)'),
--                             to_regprocedure('public.merge_contacts(uuid,uuid,text)'))
--                 AND prosrc LIKE '%assert_merge_complete%')
--          || '   (expect 3)' || chr(10);
--   r := r || 'and none still carries the inline loop: '
--          || (SELECT count(*) FROM pg_proc
--               WHERE oid IN (to_regprocedure('public.merge_decedents(uuid,uuid,text)'),
--                             to_regprocedure('public.merge_people(uuid,uuid,text)'),
--                             to_regprocedure('public.merge_contacts(uuid,uuid,text)'))
--                 AND prosrc LIKE '%FROM pg_constraint%')
--          || '   (expect 0 — merge_contacts had one until this file)' || chr(10);
--
--   -- ---- all three still merge --------------------------------------------
--   PERFORM set_config('app.is_internal', 'on', true);
--   SELECT id INTO v_org FROM organizations ORDER BY created_at LIMIT 1;
--
--   INSERT INTO decedents (organization_id, first_name, last_name)
--   VALUES (v_org, 'ZZZ', 'Dec A') RETURNING id INTO v_da;
--   INSERT INTO decedents (organization_id, first_name, last_name)
--   VALUES (v_org, 'ZZZ', 'Dec B') RETURNING id INTO v_db;
--   PERFORM merge_decedents(v_da, v_db, 'ZZZ');
--   r := r || chr(10) || 'merge_decedents still works: '
--          || (SELECT (merged_into = v_da)::text FROM decedents WHERE id = v_db)
--          || '   (expect true)' || chr(10);
--
--   INSERT INTO people (organization_id, full_name) VALUES (v_org, 'ZZZ Person A')
--     RETURNING id INTO v_pa;
--   INSERT INTO people (organization_id, full_name) VALUES (v_org, 'ZZZ Person B')
--     RETURNING id INTO v_pb;
--   PERFORM merge_people(v_pa, v_pb, 'ZZZ');
--   r := r || 'merge_people still works: '
--          || (SELECT (merged_into = v_pa)::text FROM people WHERE id = v_pb)
--          || '   (expect true)' || chr(10);
--
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'ZZZ Contact A')
--     RETURNING id INTO v_a;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'ZZZ Contact B')
--     RETURNING id INTO v_b;
--   INSERT INTO contact_phones (contact_id, e164) VALUES (v_b, '+15555550123');
--   PERFORM merge_contacts(v_a, v_b, 'ZZZ');
--   r := r || 'merge_contacts still works: '
--          || (SELECT (merged_into = v_a)::text FROM contacts WHERE id = v_b)
--          || '   (expect true)' || chr(10);
--   r := r || '    and the exclusion still holds: '
--          || (SELECT count(*) FROM contact_phones WHERE merged_from_contact_id = v_b)
--          || '   (expect 1. If assert_merge_complete counted this column the '
--          || 'call above would have raised)' || chr(10);
--
--   -- ---- the check, made to fire -------------------------------------------
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'ZZZ Contact C')
--     RETURNING id INTO v_c;
--   INSERT INTO directory_entries (organization_id, entry_kind, label, contact_id, extension)
--   VALUES (v_org, 'external', 'ZZZ Stuck Entry', v_c, '9904');
--   INSERT INTO users (email, full_name, auth_user_id, active_organization_id)
--   VALUES ('zzz-pro-1300@example.invalid', 'ZZZ Professional', v_auth, v_org)
--   RETURNING id INTO v_user;
--   INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id)
--   VALUES (v_user, 'organization', 'professional', v_org);
--   PERFORM set_config('app.is_internal', 'off', true);
--
--   PERFORM set_config('request.jwt.claims',
--                      json_build_object('sub', v_auth::text)::text, true);
--   PERFORM set_config('role', 'authenticated', true);
--
--   r := r || chr(10) || 'as a professional — can_manage_settings: '
--          || can_manage_settings()::text
--          || ', directory rows visible: '
--          || (SELECT count(*) FROM directory_entries WHERE contact_id = v_c)
--          || '   (expect false and 1: visible but not writable)' || chr(10);
--
--   BEGIN
--     PERFORM merge_contacts(v_a, v_c, 'ZZZ professional');
--     r := r || 'THE MERGE REPORTED SUCCESS (BAD — the shared check did not '
--            || 'fire, and the directory entry is stranded)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'the shared check fired: ' || SQLERRM
--            || CASE WHEN SQLERRM LIKE '%merge is incomplete%'
--                     AND SQLERRM LIKE '%directory_entries.contact_id%'
--                    THEN '   (right reason, and it named the column)'
--                    ELSE '   (WRONG REASON)' END || chr(10);
--   END;
--
--   -- ---- ordering, read from the source ------------------------------------
--   -- Not from the rows: a caught exception rolls its subtransaction back, so
--   -- the state afterwards is the same whether the function refused first or
--   -- wrote and then refused. BETWEEN 1 AND … because position() returns 0
--   -- for absent text, and a bare < comparison would pass for a message that
--   -- had been renamed away.
--   SELECT prosrc INTO v_src FROM pg_proc
--    WHERE oid = to_regprocedure('public.merge_contacts(uuid,uuid,text)');
--   r := r || chr(10) || 'merge_contacts refusals precede the first UPDATE — '
--          || 'self: '
--          || (position('cannot merge a contact into itself' in v_src)
--              BETWEEN 1 AND position('UPDATE contact_phones' in v_src) - 1)::text
--          || ', other firm: '
--          || (position('belong to different organizations' in v_src)
--              BETWEEN 1 AND position('UPDATE contact_phones' in v_src) - 1)::text
--          || ', already merged: '
--          || (position('already been merged away' in v_src)
--              BETWEEN 1 AND position('UPDATE contact_phones' in v_src) - 1)::text
--          || '   (expect true, true, true)' || chr(10);
--
--   SELECT prosrc INTO v_src FROM pg_proc
--    WHERE oid = to_regprocedure('public.merge_people(uuid,uuid,text)');
--   r := r || 'merge_people gate precedes everything — internal: '
--          || (position('Dead Ringers operation' in v_src)
--              BETWEEN 1 AND position('UPDATE users' in v_src) - 1)::text
--          || ', other firm: '
--          || (position('belong to different organizations' in v_src)
--              BETWEEN 1 AND position('UPDATE users' in v_src) - 1)::text
--          || '   (expect true, true)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261106T1300_one_completeness_check (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
