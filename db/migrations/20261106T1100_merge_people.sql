-- =============================================================================
-- 20261106T1100_merge_people.sql
-- The Hub — two records of the same member of staff become one.
--
-- WHAT IS MISSING. Same gap as decedents had: people carries merged_into and
-- the merged_into_points_at_a_survivor trigger, which guards the result and
-- moves nothing. Without a function, merging is a hand UPDATE that leaves 23
-- columns still pointing at a record the application hides, and writes no
-- history.
--
-- 53 people on production, none merged. Prevention, not repair.
--
-- WHY THIS IS THE BIG ONE. A decedent is referenced from three places. A
-- person is referenced from 24 columns across 23 tables, measured from the
-- catalogue rather than counted by hand:
--
--   cases.arranging_person_id           messages.sender_person_id
--   device_sessions.person_id           observations.subject_person_id
--   directory_entries.person_id         person_assignments.person_id
--   evaluations.subject_person_id       reports.recipient_person_id
--   focus_behaviors.person_id           routing_schedules.target_person_id
--   interaction_events.person_id        seats.person_id
--   interaction_participants.person_id  shopper_forms.staff_person_id
--   interactions.handler_person_id      shops.shopper_person_id
--   interactions.original_handler_...   shops.staff_person_requested_id
--   leads.owner_person_id               team_members.person_id
--   transcript_segments.person_id       user_availability_events.person_id
--   users.person_id                     people.merged_into
--
-- The last is the chain and is handled at the end. Of the other 23, exactly
-- ONE carries a unique that includes person_id — team_members, PRIMARY KEY
-- (team_id, person_id) — so it is the only one that needs the skip-then-delete
-- shape. Every other column is a plain repoint. That asymmetry is worth
-- stating because the opposite assumption is the expensive one: a plain
-- UPDATE onto a column with a unique fails loudly, but a skip-then-delete on a
-- column without one silently throws rows away.
--
-- THREE DECISIONS, none of which the catalogue made for me.
--
--   DEAD RINGERS ONLY. This is the decision the first draft got wrong, and the
--   reason is general enough to matter beyond this function.
--
--   An INVOKER function moves only what the caller's policies let it see and
--   write, and neither limit raises: an UPDATE that matches no rows because a
--   policy hid them affects zero rows and returns quietly. A merge touching 23
--   tables is therefore only as complete as the caller's reach, and it reports
--   nothing when it falls short.
--
--   Measured on staging: a firm manager merging a person whose login had no
--   live user_scopes row "succeeded" and left the login on the merged-away
--   record, with the history row saying sign_in_moved false. users_read is
--   can_see_user(id), which is true for any colleague with a live scope — so
--   the invisible population is exactly departed staff whose scope was
--   revoked, who are the people most likely to have a duplicate record in the
--   first place.
--
--   Worse, the two-logins refusal below is blind the same way: if the caller
--   cannot see either login, both counts read zero, nothing refuses, and the
--   merge creates precisely the state the rule exists to prevent.
--
--   The function therefore refuses unless is_internal(). That is not a bypass
--   of row-level security — it stays INVOKER and every policy still applies.
--   It requires a caller for whom the policies are already permissive, which
--   is the only kind of caller that can finish the job. can_see_user returns
--   true for is_internal() on its first line, and every other policy on the 23
--   tables opens with is_internal() OR, so an internal caller sees and writes
--   all of it.
--
--   The other face of the same problem, which the gate also closes:
--   directory_entries_update requires can_manage_settings(). A firm user
--   without it would see those rows and silently fail to move them.
--
--   TWO LOGINS. users.person_id is NOT unique, so one person can end up with
--   two sign-ins and nothing in the schema would say so. The function moves
--   the login when only the loser has one — the login should follow the
--   person — and REFUSES when both do. Refusing is recoverable: clear one
--   user's person_id and run again. Deciding which login a human keeps has
--   email and authentication consequences a merge should not make in passing.
--   With the gate above, this rule can finally see what it is deciding on.
--
--   SEATS AND DIRECTORY ENTRIES MOVE, and are not de-duplicated. Neither has a
--   unique on person_id, so the survivor can end up with two seats or two
--   directory listings. That is the right failure: a duplicate listing is
--   visible and gets tidied, whereas an entry left on a merged-away person
--   vanishes from a staff list that filters merged_into IS NULL, and a seat
--   left behind is an unreleased licence nobody can see. Both counts go into
--   the history detail so whoever ran the merge knows there is tidying to do.
--
--   FACTS DO NOT MOVE. The survivor keeps its own full_name, preferred_name,
--   title, person_type and status. A merge says which record is real, not
--   which details are right.
--
-- WHAT IT DELIBERATELY DOES NOT DO. people.first_name_unique is maintained by
-- the application and read by scoring. Removing a duplicate can make a first
-- name unique that was not, so the flag may be stale after a merge — stale in
-- the cautious direction, since it will say "not unique" when the name has
-- become unique, and scoring treats that conservatively. Recomputing it here
-- would put a second author on a value the application owns.
--
-- Requires: 20261102T2200, 016 (record_change; history_entity has 'person'),
--           20261103T1200, 20261106T1000 for the shape.
-- Safe to run twice.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Nothing is being replaced
-- -----------------------------------------------------------------------------
DO $pre$
DECLARE v_md5 text; v_unhandled text;
BEGIN
  SELECT md5(prosrc) INTO v_md5
    FROM pg_proc
   WHERE oid = to_regprocedure('public.merge_people(uuid,uuid,text)');

  IF v_md5 IS NULL THEN
    RAISE NOTICE 'merge_people does not exist; creating';
  ELSIF v_md5 = 'dd6de70981ab263e1d377b02796eaba5' THEN
    RAISE NOTICE 'already present with this body — this migration has run before';
  ELSE
    RAISE EXCEPTION
      'merge_people already exists with a different body (md5 %); stop and read it', v_md5
      USING HINT = 'Somebody has written one. Compare before replacing it.';
  END IF;

  -- The catalogue, not my list. If a foreign key to people has been added
  -- since this was written, the function below moves 23 of 24 columns and
  -- nobody finds out until a merged record keeps turning up.
  SELECT string_agg(col, ', ' ORDER BY col) INTO v_unhandled FROM (
    SELECT cl.relname || '.' || a.attname AS col
      FROM pg_constraint c
      JOIN pg_class cl ON cl.oid = c.conrelid
      JOIN pg_namespace n ON n.oid = cl.relnamespace
      JOIN LATERAL unnest(c.conkey) AS k(attnum) ON true
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
     WHERE c.contype = 'f'
       AND c.confrelid = 'public.people'::regclass
       AND n.nspname = 'public'
  ) x
  WHERE col <> ALL (ARRAY[
    'cases.arranging_person_id', 'device_sessions.person_id',
    'directory_entries.person_id', 'evaluations.subject_person_id',
    'focus_behaviors.person_id', 'interaction_events.person_id',
    'interaction_participants.person_id', 'interactions.handler_person_id',
    'interactions.original_handler_person_id', 'leads.owner_person_id',
    'messages.sender_person_id', 'observations.subject_person_id',
    'people.merged_into', 'person_assignments.person_id',
    'reports.recipient_person_id', 'routing_schedules.target_person_id',
    'seats.person_id', 'shopper_forms.staff_person_id',
    'shops.shopper_person_id', 'shops.staff_person_requested_id',
    'team_members.person_id', 'transcript_segments.person_id',
    'user_availability_events.person_id', 'users.person_id']);

  IF v_unhandled IS NOT NULL THEN
    RAISE EXCEPTION
      'these columns reference people and this function does not move them: %', v_unhandled
      USING HINT = 'Add them to the function and to the list in this precondition, then run it again.';
  END IF;
END $pre$;

-- -----------------------------------------------------------------------------
-- 2. The function
-- -----------------------------------------------------------------------------
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

COMMENT ON FUNCTION merge_people(uuid, uuid, text) IS
  'DEAD RINGERS ONLY: refuses unless is_internal(). Not because a firm user '
  'should not merge staff, but because an INVOKER function moves only what '
  'the caller can see and write, and neither limit raises — a firm manager '
  'merging someone whose scope was revoked leaves their login behind and '
  'reports success. It stays invoker and every policy still applies; the gate '
  'requires a caller the policies are already permissive for. '
  'Merges one person record into another: repoints all 23 columns that '
  'reference a person, moves team memberships the survivor lacks, follows '
  'anything already merged into the loser, and writes a history row. REFUSES '
  'when both people have a sign-in — users.person_id is not unique, so nothing '
  'else would stop one person ending up with two logins; clear one and run '
  'again. Seats and directory entries MOVE and are not de-duplicated: a '
  'visible duplicate gets tidied, whereas one left on a merged-away person '
  'disappears from every list that filters merged_into IS NULL. Invoker, so '
  'RLS decides who may merge what.';

REVOKE ALL ON FUNCTION merge_people(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION merge_people(uuid, uuid, text) TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. Record it
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261106T1100_merge_people.sql',
    NULL,
    'merge_people(uuid,uuid,text), modelled on merge_contacts and '
    '20261106T1000. Repoints 23 columns; team_members is the only one with a '
    'unique on person_id. Refuses when both people have a sign-in.');
END $rec$;

COMMIT;

-- =============================================================================
-- STILL TO DO
--
-- * THE COLUMN LIST IN SECTION 1 HAS TO BE KEPT, and the precondition is what
--   makes that happen: adding a foreign key to people and not adding it here
--   makes the next run of this file refuse by name. That protects a fresh
--   database. It does NOT protect one where this file has already run, and
--   nothing can — the function is installed and silently incomplete from the
--   moment the column is added. The same check is in the verification, which
--   is the version worth re-running.
--
-- * first_name_unique MAY BE STALE AFTER A MERGE, in the cautious direction.
--   The application owns it; this does not touch it. Worth knowing before
--   somebody reads a scoring result and wonders.
--
-- * NOTHING CALLS IT, as with merge_decedents and merge_contacts. Merging is a
--   Dead Ringers operation through the SQL editor until somebody decides staff
--   should have a screen for it.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- Three things it has to establish, and the fixture is built for them rather
-- than for coverage of all 23 columns: that a plain repoint works, that the
-- one skip-then-delete column behaves, and that both sign-in paths do what
-- they should. The catalogue check at the top is what covers the other 20 —
-- not by exercising them, but by proving the function's list is complete.
--
-- Every refusal is checked for ITS OWN message. A handler that accepts any
-- error cannot tell a working rule from a missing function.
--
-- DO $$
-- DECLARE
--   r text := ''; n int;
--   v_org uuid; v_org2 uuid;
--   v_a uuid; v_b uuid; v_c uuid; v_d uuid; v_e uuid;
--   v_team_shared uuid; v_team_only uuid; v_case uuid;
--   v_user_a uuid; v_user_b uuid; v_auth uuid := gen_random_uuid();
--   v_auth2 uuid := gen_random_uuid(); v_firm_user uuid;
--   v_unhandled text; v_hist int;
-- BEGIN
--   -- The list this function moves, checked against the catalogue. This is
--   -- the only line that says anything about the 20 columns the fixture does
--   -- not touch, and it is a maintenance check rather than a behaviour one.
--   SELECT string_agg(col, ', ' ORDER BY col) INTO v_unhandled FROM (
--     SELECT cl.relname || '.' || a.attname AS col
--       FROM pg_constraint c
--       JOIN pg_class cl ON cl.oid = c.conrelid
--       JOIN pg_namespace n ON n.oid = cl.relnamespace
--       JOIN LATERAL unnest(c.conkey) AS k(attnum) ON true
--       JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
--      WHERE c.contype = 'f' AND c.confrelid = 'public.people'::regclass
--        AND n.nspname = 'public') x
--   WHERE col <> ALL (ARRAY[
--     'cases.arranging_person_id', 'device_sessions.person_id',
--     'directory_entries.person_id', 'evaluations.subject_person_id',
--     'focus_behaviors.person_id', 'interaction_events.person_id',
--     'interaction_participants.person_id', 'interactions.handler_person_id',
--     'interactions.original_handler_person_id', 'leads.owner_person_id',
--     'messages.sender_person_id', 'observations.subject_person_id',
--     'people.merged_into', 'person_assignments.person_id',
--     'reports.recipient_person_id', 'routing_schedules.target_person_id',
--     'seats.person_id', 'shopper_forms.staff_person_id',
--     'shops.shopper_person_id', 'shops.staff_person_requested_id',
--     'team_members.person_id', 'transcript_segments.person_id',
--     'user_availability_events.person_id', 'users.person_id']);
--   r := r || 'columns referencing people that this function does NOT move: '
--          || COALESCE(v_unhandled, 'NONE')
--          || '   (expect NONE. Any name here is a column a merge would '
--          || 'silently leave behind)' || chr(10);
--
--   PERFORM set_config('app.is_internal', 'on', true);
--   SELECT id INTO v_org  FROM organizations ORDER BY created_at LIMIT 1;
--   SELECT id INTO v_org2 FROM organizations WHERE id <> v_org ORDER BY created_at LIMIT 1;
--
--   INSERT INTO people (organization_id, full_name) VALUES (v_org, 'ZZZ Survivor')
--     RETURNING id INTO v_a;
--   INSERT INTO people (organization_id, full_name) VALUES (v_org, 'ZZZ Duplicate')
--     RETURNING id INTO v_b;
--
--   -- team_members: one team both are in, one only the loser is.
--   INSERT INTO teams (organization_id, name) VALUES (v_org, 'ZZZ Shared Team')
--     RETURNING id INTO v_team_shared;
--   INSERT INTO teams (organization_id, name) VALUES (v_org, 'ZZZ Loser Team')
--     RETURNING id INTO v_team_only;
--   INSERT INTO team_members (team_id, person_id) VALUES
--     (v_team_shared, v_a), (v_team_shared, v_b), (v_team_only, v_b);
--
--   -- A seat and a directory entry on each, so the survivor ends with two of
--   -- each and the "not de-duplicated" decision is visible rather than stated.
--   -- seat_type is named / shared / external_destination, and seats_named_ck
--   -- requires a person for 'named'. entry_kind is 'staff', not 'person', and
--   -- directory_entries_reachable_ck wants an e164 or an extension.
--   INSERT INTO seats (organization_id, label, seat_type, person_id)
--   VALUES (v_org, 'ZZZ Seat A', 'named', v_a),
--          (v_org, 'ZZZ Seat B', 'named', v_b);
--   INSERT INTO directory_entries (organization_id, entry_kind, label, person_id, extension)
--   VALUES (v_org, 'staff', 'ZZZ Entry A', v_a, '9901'),
--          (v_org, 'staff', 'ZZZ Entry B', v_b, '9902');
--
--   -- A plain repoint, to show the other 20 shapes work at all.
--   INSERT INTO cases (organization_id, need_type, arranging_person_id)
--   VALUES (v_org, 'at_need', v_b) RETURNING id INTO v_case;
--
--   -- Only the LOSER has a sign-in, which is the case that should move.
--   INSERT INTO users (email, full_name, auth_user_id, person_id)
--   VALUES ('zzz-loser@example.invalid', 'ZZZ Duplicate', v_auth, v_b)
--   RETURNING id INTO v_user_b;
--
--   SELECT count(*) INTO v_hist FROM change_history
--    WHERE entity = 'person' AND entity_id = v_a;
--
--   -- app.is_internal stays ON through part A. The function refuses otherwise,
--   -- and an internal caller is the only one that can see all 23 tables.
--   PERFORM merge_people(v_a, v_b, 'ZZZ verification');
--
--   r := r || 'the loser points at the survivor: '
--          || (SELECT (merged_into = v_a)::text FROM people WHERE id = v_b)
--          || '   (expect true)' || chr(10);
--   r := r || 'the sign-in followed the person: '
--          || (SELECT (person_id = v_a)::text FROM users WHERE id = v_user_b)
--          || '   (expect true — only the loser had one)' || chr(10);
--   r := r || 'the plain repoint worked: '
--          || (SELECT (arranging_person_id = v_a)::text FROM cases WHERE id = v_case)
--          || '   (expect true)' || chr(10);
--
--   SELECT count(*) INTO n FROM team_members WHERE person_id = v_b;
--   r := r || 'team memberships left on the loser: ' || n || '   (expect 0)' || chr(10);
--   SELECT count(*) INTO n FROM team_members WHERE person_id = v_a;
--   r := r || 'the survivor is now in teams: ' || n
--          || '   (expect 2 — the shared one it was already in, plus the moved '
--          || 'one. NOT 3)' || chr(10);
--
--   SELECT count(*) INTO n FROM seats WHERE person_id = v_a;
--   r := r || 'seats on the survivor: ' || n;
--   SELECT count(*) INTO n FROM directory_entries WHERE person_id = v_a;
--   r := r || ', directory entries: ' || n
--          || '   (expect 2 and 2 — moved, NOT de-duplicated. Two visible '
--          || 'duplicates to tidy beats one invisible row left behind)' || chr(10);
--
--   r := r || 'a history row was written: '
--          || ((SELECT count(*) FROM change_history
--                WHERE entity = 'person' AND entity_id = v_a) - v_hist)
--          || '   (expect 1)' || chr(10);
--   r := r || '    its detail: '
--          || COALESCE((SELECT detail::text FROM change_history
--                        WHERE entity = 'person' AND entity_id = v_a AND action = 'merged'
--                        ORDER BY occurred_at DESC LIMIT 1), 'NONE') || chr(10)
--          || '   (expect sign_in_moved true, teams_moved 1, seats_moved 1, '
--          || 'directory_entries_moved 1)' || chr(10);
--
--   -- ---- the refusal that only this function has --------------------------
--   INSERT INTO people (organization_id, full_name) VALUES (v_org, 'ZZZ Both Logins A')
--     RETURNING id INTO v_c;
--   INSERT INTO people (organization_id, full_name) VALUES (v_org, 'ZZZ Both Logins B')
--     RETURNING id INTO v_d;
--   INSERT INTO users (email, full_name, auth_user_id, person_id)
--   VALUES ('zzz-c@example.invalid', 'ZZZ C', gen_random_uuid(), v_c)
--   RETURNING id INTO v_user_a;
--   INSERT INTO users (email, full_name, auth_user_id, person_id)
--   VALUES ('zzz-d@example.invalid', 'ZZZ D', gen_random_uuid(), v_d);
--
--   BEGIN
--     PERFORM merge_people(v_c, v_d, 'ZZZ');
--     r := r || 'TWO SIGN-INS WERE MERGED (BAD — one person now has two '
--            || 'logins and nothing in the schema says so)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'two sign-ins refused: ' || SQLERRM
--            || CASE WHEN SQLERRM LIKE '%two%' THEN '   (right reason)'
--                    ELSE '   (WRONG REASON)' END || chr(10);
--   END;
--   -- A line asking "and nothing was moved by the refused call" was removed
--   -- from here. It read the state after a BEGIN … EXCEPTION, and a caught
--   -- exception rolls that subtransaction back, so it printed true whether
--   -- the refusal came before or after the first UPDATE. Proving it needs the
--   -- call to abort the outer block, which costs the whole report; the
--   -- refusal's position in the source is the better evidence.
--
--   BEGIN
--     PERFORM merge_people(v_a, v_a, 'ZZZ');
--     r := r || 'self-merge ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'self-merge refused: ' || SQLERRM
--            || CASE WHEN SQLERRM LIKE '%themselves%' THEN '   (right reason)'
--                    ELSE '   (WRONG REASON)' END || chr(10);
--   END;
--
--   BEGIN
--     PERFORM merge_people(v_a, v_b, 'ZZZ');
--     r := r || 'merging an already-merged record ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'already-merged loser refused: ' || SQLERRM
--            || CASE WHEN SQLERRM LIKE '%already been merged away%' THEN '   (right reason)'
--                    ELSE '   (WRONG REASON)' END || chr(10);
--   END;
--
--   -- ---- as a signed-in user. Last: the role does not revert. -------------
--   PERFORM set_config('app.is_internal', 'on', true);
--   INSERT INTO users (email, full_name, auth_user_id, active_organization_id)
--   VALUES ('zzz-firm@example.invalid', 'ZZZ Firm User', v_auth2, v_org)
--   RETURNING id INTO v_firm_user;
--   INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id)
--   VALUES (v_firm_user, 'organization', 'manager', v_org);
--   IF v_org2 IS NOT NULL THEN
--     INSERT INTO people (organization_id, full_name) VALUES (v_org2, 'ZZZ Other Firm')
--       RETURNING id INTO v_e;
--   END IF;
--   PERFORM set_config('app.is_internal', 'off', true);
--
--   PERFORM set_config('request.jwt.claims',
--                      json_build_object('sub', v_auth2::text)::text, true);
--   PERFORM set_config('role', 'authenticated', true);
--
--   SELECT count(*) INTO n FROM people WHERE id = v_c;
--   r := r || chr(10) || 'as a firm user — the record is visible: ' || n
--          || '   (expect 1. The firm user can SEE the person; what it cannot '
--          || 'do is finish a merge, which is the whole point of the gate)' || chr(10);
--
--   -- The gate, tested from the side it exists for. Before it, this call
--   -- succeeded and left the loser's login behind.
--   BEGIN
--     PERFORM merge_people(v_c, v_d, 'ZZZ firm user');
--     r := r || 'A FIRM USER MERGED TWO PEOPLE (BAD — and if it reports '
--            || 'success, check whether the login moved; it is the silent '
--            || 'half that made this gate necessary)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'firm user refused: ' || SQLERRM
--            || CASE WHEN SQLERRM LIKE '%Dead Ringers operation%' THEN '   (right reason)'
--                    ELSE '   (WRONG REASON — a missing function, a missing '
--                         || 'privilege and a working rule all raise here)' END
--            || chr(10);
--   END;
--
--   r := r || '    and the pair is untouched: '
--          || (SELECT (merged_into IS NULL)::text FROM people WHERE id = v_d)
--          || '   (expect true — unlike the subtransaction case above, no '
--          || 'UPDATE could have run, because the gate is the first statement)'
--          || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261106T1100_merge_people (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
