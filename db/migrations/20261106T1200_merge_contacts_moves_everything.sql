-- =============================================================================
-- 20261106T1200_merge_contacts_moves_everything.sql
-- The Hub — a merged contact stops leaving things behind, and says so when
-- it cannot.
--
-- WHAT IS WRONG. merge_contacts moves seven things: contact_phones,
-- interactions (both columns), interaction_participants, leads,
-- transcript_segments, case_contacts and contact_decedent_links. Rather more
-- than that references a contact, and everything it misses stays attached to a
-- record the application hides.
--
-- CONSENTS IS THE ONE THAT MATTERS and is the reason this is a file rather
-- than a backlog line. A consent or an opt-out is recorded against a contact.
-- After a merge it stays on the duplicate, so the surviving contact carries no
-- record of it — and the next person to check whether this household may be
-- texted gets the wrong answer, in the permissive direction. Nothing raises,
-- nothing logs, and the row is still there if anybody thinks to look at a
-- contact nobody can see. Zero rows exist on either database today, which is
-- the whole reason to fix it now rather than after.
--
-- The others matter less and in the same way: threads, reminders, alerts,
-- callback_requests, custom_field_values and directory_entries all become
-- invisible work attached to an invisible record.
--
-- TWO THAT ARE NOT SIMPLE MOVES.
--
--   contact_relationships has UNIQUE (from_contact_id, to_contact_id) and
--   BOTH columns reference contacts, so each end needs the skip-then-delete
--   shape — and a relationship recorded BETWEEN the two contacts becomes a
--   contact related to itself the moment either end moves. Those are deleted
--   first, before anything is repointed, so no self-referential row exists
--   even briefly.
--
--   contact_merge_dismissals records "these two are not duplicates". Rows
--   naming the loser are DELETED rather than moved. Moving one would assert
--   that the SURVIVOR is not a duplicate of something nobody has compared it
--   to, which is a claim this function is not entitled to make. The dismissal
--   was about a contact that no longer exists.
--
-- THE FUNCTION NOW CHECKS ITS OWN COMPLETENESS, which is the part worth
-- reading. After moving everything, it reads pg_constraint for every foreign
-- key column referencing contacts, counts rows still pointing at the loser,
-- and RAISES naming any column that still does. That is deliberately driven
-- from the catalogue and not from a list in this file:
--
--   I could not produce a reliable list. Scanning the migrations for
--   "REFERENCES contacts" misses interactions.next_of_kin_contact_id, because
--   048 adds it inside a multi-column ALTER TABLE — and a list that misses one
--   column by accident may miss others the same way. The catalogue knows; I do
--   not.
--
--   It closes the other half too. A column added to contacts next month is
--   moved by nobody, and without this check the first sign is a merged record
--   that keeps turning up. With it, the merge refuses and names the column.
--
--   And it catches a policy, not just a gap. An UPDATE that matches no rows
--   because row-level security forbade the write affects zero rows and raises
--   nothing — directory_entries_update requires can_manage_settings(), so a
--   firm user without it would have silently left those rows behind. The
--   check sees them and refuses.
--
-- WHAT THE CHECK CANNOT SEE, stated because the gap is real: it runs as the
-- caller, so a row hidden from them by a policy counts as zero to it as well.
-- A blind caller cannot detect its own blindness. Every table referencing
-- contacts is firm-scoped, so for this function that case does not arise —
-- which is exactly why merge_contacts stays INVOKER while 20261106T1100 had to
-- be gated to Dead Ringers: merge_people touches users, whose visibility is
-- per-user, and no check it could run would notice.
--
-- contact_phones.merged_from_contact_id IS EXCLUDED from the check. It is set
-- TO the loser on purpose — it is how a phone number records where it came
-- from — so counting it would make the function refuse every merge it
-- performed correctly.
--
-- Requires: 20261102T2200 (the body this replaces), 20261103T1200.
-- Safe to run twice.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. The body is the one this file expects to replace
--
-- Both hashes are measured: prosrc for a plpgsql function is the text between
-- its $$ delimiters, so the first was computed from
-- db/migrations/20261102T2200_merge_chains.sql as it stands on main, and the
-- second from this file's replacement.
-- -----------------------------------------------------------------------------
DO $pre$
DECLARE v_md5 text;
BEGIN
  SELECT md5(prosrc) INTO v_md5
    FROM pg_proc
   WHERE oid = to_regprocedure('public.merge_contacts(uuid,uuid,text)');

  IF v_md5 IS NULL THEN
    RAISE EXCEPTION 'merge_contacts does not exist; run 015, 016, 048 and 20261102T2200 first';
  ELSIF v_md5 = '4768ee1093e4db88ba98f272712a6cb9' THEN
    RAISE NOTICE 'already the complete body — this migration has run before';
  ELSIF v_md5 = '16177d5f2ae691818929c375e222e081' THEN
    RAISE NOTICE '20261102T2200''s body found, as expected; replacing';
  ELSE
    RAISE EXCEPTION
      'merge_contacts has a body this file does not know (md5 %); stop and read it', v_md5
      USING HINT = 'Expected 20261102T2200''s body or this file''s.';
  END IF;
END $pre$;

-- -----------------------------------------------------------------------------
-- 2. Everything, and a check that it was everything
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION merge_contacts(p_survivor uuid, p_loser uuid, p_actor text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_org uuid;
  v_survivor_name text;
  v_loser_name text;
  v_moved int;
  v_consents int;
  v_relationships int;
  v_directory int;
  v_left int;
  v_remaining text;
  r record;
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
  GET DIAGNOSTICS v_left = ROW_COUNT;
  v_relationships := v_relationships + v_left;
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

  -- Did that cover it? Asked of the catalogue rather than of a list, because
  -- a list in this file is exactly what was wrong before. Any column still
  -- pointing at the loser is either one nobody has added here or one a policy
  -- stopped this caller writing; both are reported by name rather than left.
  FOR r IN
    SELECT cl.relname AS tbl, a.attname AS col
      FROM pg_constraint c
      JOIN pg_class cl ON cl.oid = c.conrelid
      JOIN pg_namespace n ON n.oid = cl.relnamespace
      JOIN LATERAL unnest(c.conkey) AS k(attnum) ON true
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
     WHERE c.contype = 'f'
       AND c.confrelid = 'public.contacts'::regclass
       AND n.nspname = 'public'
       -- Set to the loser on purpose: it records where a phone number came from.
       AND NOT (cl.relname = 'contact_phones' AND a.attname = 'merged_from_contact_id')
  LOOP
    EXECUTE format('SELECT count(*) FROM public.%I WHERE %I = $1', r.tbl, r.col)
       INTO v_left USING p_loser;
    IF v_left > 0 THEN
      v_remaining := COALESCE(v_remaining || ', ', '')
                     || r.tbl || '.' || r.col || ' (' || v_left || ')';
    END IF;
  END LOOP;

  IF v_remaining IS NOT NULL THEN
    RAISE EXCEPTION 'the merge is incomplete; these still point at the merged contact: %', v_remaining
      USING HINT = 'Either this function does not move that column, or a policy stopped this caller writing it. Nothing has been committed.';
  END IF;

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

COMMENT ON FUNCTION merge_contacts(uuid, uuid, text) IS
  'Merges one contact into another and then checks, against pg_constraint, '
  'that nothing still points at the loser — raising by name if anything does, '
  'so a column nobody added here, or one a policy stopped this caller '
  'writing, is loud instead of silent. Before 20261106T1200 it moved seven '
  'things and left consents, threads, reminders, alerts, callback_requests, '
  'custom_field_values, directory_entries and contact_relationships behind; '
  'the consent one meant a surviving contact carried no record of an opt-out. '
  'Relationships between the two contacts are deleted rather than moved, and '
  'so are merge dismissals naming the loser. Invoker: the check sees what the '
  'caller sees, which is every contact table, because all of them are '
  'firm-scoped.';

-- -----------------------------------------------------------------------------
-- 3. Record it
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261106T1200_merge_contacts_moves_everything.sql',
    NULL,
    'merge_contacts now moves consents, threads, reminders, alerts, '
    'callback_requests, custom_field_values, directory_entries and '
    'contact_relationships, and verifies its own completeness from '
    'pg_constraint. Body 16177d5f -> this file''s.');
END $rec$;

COMMIT;

-- =============================================================================
-- STILL TO DO
--
-- * merge_decedents AND merge_people SHOULD GET THE SAME SELF-CHECK, in their
--   own file. Both carry a list, and merge_people's list was written from the
--   same text scan that missed next_of_kin_contact_id here — its precondition
--   compares against pg_constraint, which is better, but the function itself
--   still trusts the list. A runtime check would make an omission loud in all
--   three. For merge_people the check cannot see rows hidden from the caller,
--   but that function is already Dead Ringers only, so the caller sees
--   everything.
--
-- * THE CHECK COSTS ONE COUNT PER FOREIGN KEY, around twenty small queries on
--   a table nobody merges in bulk. If merging ever becomes a batch operation
--   that changes, and the answer is to run the check once at the end rather
--   than to drop it.
--
-- * NOTHING CALLS merge_contacts, on any hellophone branch. Merging remains a
--   Dead Ringers operation in the SQL editor until somebody decides staff
--   should have a screen for it.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- The consents fixture is the point: it is the row whose absence from the
-- survivor gives the wrong answer to "may we contact this household".
--
-- ON TESTING THAT A REFUSAL HAPPENS BEFORE ANY WRITE: it cannot be done from
-- inside a block like this one. A caught exception rolls its subtransaction
-- back, so the state afterwards is identical whether the function refused
-- first or wrote and then refused — a snapshot taken before and compared after
-- reads equal either way, and so does reading the rows directly. Two earlier
-- files carried a line claiming otherwise. What CAN be tested is the order of
-- the statements in the source, which is what the last check below does.
--
-- DO $$
-- DECLARE
--   r text := ''; n int;
--   v_org uuid; v_a uuid; v_b uuid; v_c uuid;
--   v_case uuid; v_int uuid; v_thread uuid; v_hist int;
--   v_src text; v_user uuid; v_auth uuid := gen_random_uuid();
-- BEGIN
--   PERFORM set_config('app.is_internal', 'on', true);
--   SELECT id INTO v_org FROM organizations ORDER BY created_at LIMIT 1;
--
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'ZZZ Survivor')
--     RETURNING id INTO v_a;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'ZZZ Duplicate')
--     RETURNING id INTO v_b;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'ZZZ Relative')
--     RETURNING id INTO v_c;
--
--   -- The row this file exists for: an opt-out on the duplicate.
--   INSERT INTO consents (organization_id, contact_id, consent_kind, granted, consent_source)
--   VALUES (v_org, v_b, 'sms', false, 'verbal_on_call');
--
--   INSERT INTO threads (organization_id, scope, contact_id)
--   VALUES (v_org, 'contact', v_b) RETURNING id INTO v_thread;
--   INSERT INTO reminders (organization_id, owner_user_id, due_at, contact_id)
--   VALUES (v_org, (SELECT id FROM users ORDER BY created_at LIMIT 1), now(), v_b);
--   INSERT INTO alerts (organization_id, alert_kind, contact_id)
--   VALUES (v_org, 'missed_call', v_b);
--   INSERT INTO interactions (organization_id, channel, direction, source,
--                             occurred_at, last_activity_at)
--   VALUES (v_org, 'call', 'inbound', 'shop', now(), now()) RETURNING id INTO v_int;
--   INSERT INTO callback_requests (organization_id, interaction_id, contact_id)
--   VALUES (v_org, v_int, v_b);
--   INSERT INTO directory_entries (organization_id, entry_kind, label, contact_id, extension)
--   VALUES (v_org, 'external', 'ZZZ Directory', v_b, '9903');
--
--   -- Relationships: one to a third contact that should move, and one BETWEEN
--   -- the two being merged, which must be deleted rather than become a
--   -- contact related to itself.
--   INSERT INTO contact_relationships (organization_id, from_contact_id, to_contact_id, relationship)
--   VALUES (v_org, v_b, v_c, 'daughter'),
--          (v_org, v_b, v_a, 'same household');
--
--   INSERT INTO contact_merge_dismissals (contact_a_id, contact_b_id)
--   VALUES (v_b, v_c);
--
--   SELECT count(*) INTO v_hist FROM change_history
--    WHERE entity = 'contact' AND entity_id = v_a;
--
--   PERFORM merge_contacts(v_a, v_b, 'ZZZ verification');
--
--   r := r || 'the consent moved to the survivor: '
--          || (SELECT count(*) FROM consents WHERE contact_id = v_a)
--          || '   (expect 1. Before this file it stayed on the duplicate and '
--          || 'the survivor read as never having opted out)' || chr(10);
--   r := r || '    and none is left on the duplicate: '
--          || (SELECT count(*) FROM consents WHERE contact_id = v_b)
--          || '   (expect 0)' || chr(10);
--
--   SELECT count(*) INTO n FROM threads WHERE contact_id = v_a;
--   r := r || 'threads: ' || n;
--   SELECT count(*) INTO n FROM reminders WHERE contact_id = v_a;
--   r := r || ', reminders: ' || n;
--   SELECT count(*) INTO n FROM alerts WHERE contact_id = v_a;
--   r := r || ', alerts: ' || n;
--   SELECT count(*) INTO n FROM callback_requests WHERE contact_id = v_a;
--   r := r || ', callbacks: ' || n;
--   SELECT count(*) INTO n FROM directory_entries WHERE contact_id = v_a;
--   r := r || ', directory: ' || n || '   (expect 1 each)' || chr(10);
--
--   SELECT count(*) INTO n FROM contact_relationships
--    WHERE from_contact_id = v_a AND to_contact_id = v_c;
--   r := r || 'the relationship to a third contact moved: ' || n
--          || '   (expect 1)' || chr(10);
--   SELECT count(*) INTO n FROM contact_relationships
--    WHERE from_contact_id = to_contact_id;
--   r := r || 'contacts related to themselves: ' || n
--          || '   (expect 0 — the loser was recorded as the survivor''s same '
--          || 'household, and that row is deleted rather than moved)' || chr(10);
--   SELECT count(*) INTO n FROM contact_merge_dismissals
--    WHERE contact_a_id IN (v_a, v_b) OR contact_b_id IN (v_a, v_b);
--   r := r || 'merge dismissals naming either contact: ' || n
--          || '   (expect 0 — deleted, not inherited: the survivor has not '
--          || 'been compared to that contact)' || chr(10);
--
--   r := r || 'a history row was written: '
--          || ((SELECT count(*) FROM change_history
--                WHERE entity = 'contact' AND entity_id = v_a) - v_hist)
--          || '   (expect 1)' || chr(10);
--   r := r || '    its detail: '
--          || COALESCE((SELECT detail::text FROM change_history
--                        WHERE entity = 'contact' AND entity_id = v_a AND action = 'merged'
--                        ORDER BY occurred_at DESC LIMIT 1), 'NONE') || chr(10)
--          || '   (expect consents_moved 1, relationships_moved 1, '
--          || 'directory_entries_moved 1)' || chr(10);
--
--   -- ---- the completeness check, made to fire -----------------------------
--   -- Not simulated: run as a firm user whose view_profile is 'professional',
--   -- so can_manage_settings() is false and directory_entries_update refuses
--   -- the write. The rows are visible to them, the UPDATE matches none, and
--   -- before this file the merge would have reported success with the
--   -- directory entry still on the merged-away contact.
--   PERFORM set_config('app.is_internal', 'on', true);
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'ZZZ Second Duplicate')
--     RETURNING id INTO v_b;
--   INSERT INTO directory_entries (organization_id, entry_kind, label, contact_id, extension)
--   VALUES (v_org, 'external', 'ZZZ Stuck Entry', v_b, '9904');
--   INSERT INTO users (email, full_name, auth_user_id, active_organization_id)
--   VALUES ('zzz-pro@example.invalid', 'ZZZ Professional', v_auth, v_org)
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
--          || (SELECT count(*) FROM directory_entries WHERE contact_id = v_b)
--          || '   (expect false and 1: visible but not writable, which is the '
--          || 'case that used to pass silently)' || chr(10);
--
--   BEGIN
--     PERFORM merge_contacts(v_a, v_b, 'ZZZ professional');
--     r := r || 'THE MERGE REPORTED SUCCESS (BAD — check whether the directory '
--            || 'entry is still on the loser; that is the silent half)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'the merge refused: ' || SQLERRM
--            || CASE WHEN SQLERRM LIKE '%merge is incomplete%' THEN '   (right reason)'
--                    ELSE '   (WRONG REASON)' END || chr(10);
--   END;
--
--   -- The ordering property, tested where it can be: the source. A refusal
--   -- that happens before any write cannot be demonstrated by looking at rows
--   -- after a caught exception, because the subtransaction rolled back.
--   SELECT prosrc INTO v_src FROM pg_proc
--    WHERE oid = 'public.merge_contacts(uuid,uuid,text)'::regprocedure;
--   r := r || 'every refusal precedes the first UPDATE: '
--          || (position('cannot merge a contact into itself' in v_src)
--              < position('UPDATE contact_phones' in v_src))::text
--          || ' / '
--          || (position('already been merged away' in v_src)
--              < position('UPDATE contact_phones' in v_src))::text
--          || '   (expect true / true. This is a statement about the source '
--          || 'because it cannot be one about the rows)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261106T1200_merge_contacts_moves_everything (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
