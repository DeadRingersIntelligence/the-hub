-- =============================================================================
-- 20261106T1000_merge_decedents.sql
-- The Hub — two records of the same death become one, with a history row.
--
-- WHAT IS MISSING. decedents carries merged_into and the
-- merged_into_points_at_a_survivor trigger from 20261102T2200, which guards
-- the RESULT of a merge and moves nothing. There is no function to do the
-- merge, so the only route is a hand UPDATE in the SQL editor — which moves no
-- links, writes no history, and leaves every case, interaction and contact
-- still attached to a record the application hides.
--
-- Nothing has been merged yet on either database (0 of 0 decedents, 0 of 53
-- people, 0 of 1 contacts), so this is prevention rather than repair. That is
-- the cheap moment to write it: the first person to need it will be in a hurry
-- and will otherwise reach for UPDATE.
--
-- THE MODEL IS merge_contacts, deliberately. Same argument order, same
-- refusals, same skip-then-delete shape for links with a unique, same
-- follow-the-chain step, same record_change call. A reader who knows one
-- should recognise the other on sight, and a difference between them should
-- mean something rather than be a difference.
--
-- WHAT IT MOVES, which is all three things that reference a decedent:
--
--   case_decedents          PRIMARY KEY (case_id, decedent_id)
--   interaction_decedents   PRIMARY KEY (interaction_id, decedent_id)
--   contact_decedent_links  UNIQUE (contact_id, decedent_id)
--
-- All three carry a unique that includes decedent_id, so a link the survivor
-- already has cannot simply be repointed — the UPDATE would violate it. Each
-- is therefore moved only where the survivor has no equivalent row, and what
-- is left is deleted. That is merge_contacts' handling of case_contacts, and
-- the deletion is not a loss: the surviving record already holds the link.
--
-- WHAT IT DOES NOT TOUCH. full_name is a generated column on decedents, so it
-- is read for the history message and never written. date_of_death, status,
-- species and owner_name stay as the survivor has them: a merge decides which
-- record is real, not which facts are right, and a function that silently
-- preferred one record's date of death over another's would be making a
-- judgement nobody asked it for. If the survivor's details are wrong, that is
-- an edit, before or after, and it leaves its own history row.
--
-- Requires: 20261102T2200 (merged_into and its trigger), 016 (record_change,
--           history_entity already has 'decedent'), 20261103T1200.
-- Safe to run twice.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Nothing is being replaced
--
-- Three states: the function is absent (create it), present with this file's
-- body (already run), or present with some other body — which stops, because
-- a merge function somebody else wrote is not one to overwrite without reading.
-- The hash is this file's own body, computed from the text below.
-- -----------------------------------------------------------------------------
DO $pre$
DECLARE v_md5 text;
BEGIN
  SELECT md5(prosrc) INTO v_md5
    FROM pg_proc
   WHERE oid = to_regprocedure('public.merge_decedents(uuid,uuid,text)');

  IF v_md5 IS NULL THEN
    RAISE NOTICE 'merge_decedents does not exist; creating';
  ELSIF v_md5 = 'ea338970478b68160a8e32d770c871fc' THEN
    RAISE NOTICE 'already present with this body — this migration has run before';
  ELSE
    RAISE EXCEPTION
      'merge_decedents already exists with a different body (md5 %); stop and read it', v_md5
      USING HINT = 'Somebody has written one. Compare before replacing it.';
  END IF;

  IF to_regtype('history_entity') IS NULL
     OR NOT EXISTS (SELECT 1 FROM pg_enum
                     WHERE enumtypid = 'history_entity'::regtype
                       AND enumlabel = 'decedent') THEN
    RAISE EXCEPTION 'history_entity has no decedent label; record_change would fail';
  END IF;
END $pre$;

-- -----------------------------------------------------------------------------
-- 2. The function
--
-- INVOKER, like merge_contacts, so row-level security applies to whoever calls
-- it: a user who cannot see both decedents cannot merge them, and the refusals
-- below read "not found" for a record in another firm because that is what it
-- is from the caller's side.
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

COMMENT ON FUNCTION merge_decedents(uuid, uuid, text) IS
  'Merges one decedent record into another: moves case, interaction and '
  'contact links, follows anything already merged into the loser, points the '
  'loser at the survivor and writes a history row. Refuses a self-merge, two '
  'firms, and either end already merged — a chain, because every reader of '
  'merged_into resolves one hop. Invoker, so RLS decides who may merge what. '
  'It moves records, never facts: the survivor keeps its own date of death and '
  'status, because a merge says which record is real and not which details are '
  'right.';

REVOKE ALL ON FUNCTION merge_decedents(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION merge_decedents(uuid, uuid, text) TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. Record it
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261106T1000_merge_decedents.sql',
    NULL,
    'merge_decedents(uuid,uuid,text), modelled on merge_contacts. Moves the '
    'three links that reference a decedent, skipping any the survivor already '
    'has. Nothing had been merged on either database when it was written.');
END $rec$;

COMMIT;

-- =============================================================================
-- STILL TO DO
--
-- * NOTHING CALLS IT. hellophone has no merge screen and does not call
--   merge_contacts either, so for now a merge is a Dead Ringers operation
--   through the SQL editor. That is fine while the count is zero; it stops
--   being fine the first time a client asks for a duplicate to be cleaned up
--   and the answer is a support ticket. Whether staff get a merge screen is a
--   product decision, not a schema one.
--
-- * A DRY RUN WOULD BE WORTH HAVING. "What would this move?" is a question
--   somebody will want answered before running a merge on real data, and the
--   counts are already computed. A merge_decedents_preview returning the three
--   numbers without writing is a small function and an obvious next step — but
--   it is speculative until somebody is about to merge something, and
--   speculative helpers are how two implementations of one rule start.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- Fixture-first: a merge function tested against records with no links proves
-- only that it does not raise. Both decedents get a case, an interaction and a
-- contact link, and one of each is deliberately SHARED with the survivor so
-- the skip-then-delete path is exercised rather than assumed.
--
-- AND EVERY REFUSAL CHECK SAYS WHY IT WAS REFUSED. A block that treats any
-- error as a pass cannot tell a working rule from a missing function — the
-- first run of this verification on staging "passed" a cross-firm refusal
-- because merge_decedents did not exist in that transaction yet. Each
-- EXCEPTION handler below therefore tests the message, and labels the line
-- WRONG REASON when it does not match.
--
-- PART B RUNS AS A SIGNED-IN USER, which is the case that matters: this
-- function is INVOKER and is for staff. Part A runs as the owner, which
-- bypasses row-level security entirely and so cannot test the cross-firm rule
-- at all.
--
-- DO $$
-- DECLARE
--   r text := ''; n int;
--   v_org uuid; v_org2 uuid; v_a uuid; v_b uuid; v_c uuid; v_d uuid; v_e uuid;
--   v_case_shared uuid; v_case_only uuid;
--   v_int_shared uuid; v_int_only uuid;
--   v_contact uuid; v_hist int;
--   v_user uuid; v_auth uuid := gen_random_uuid();
-- BEGIN
--   PERFORM set_config('app.is_internal', 'on', true);
--   SELECT id INTO v_org  FROM organizations ORDER BY created_at LIMIT 1;
--   SELECT id INTO v_org2 FROM organizations WHERE id <> v_org ORDER BY created_at LIMIT 1;
--   IF v_org IS NULL THEN
--     RAISE EXCEPTION 'no organizations — cannot build the fixture';
--   END IF;
--
--   -- ---- part A: as the owner --------------------------------------------
--   INSERT INTO decedents (organization_id, first_name, last_name)
--   VALUES (v_org, 'ZZZ', 'Survivor') RETURNING id INTO v_a;
--   INSERT INTO decedents (organization_id, first_name, last_name)
--   VALUES (v_org, 'ZZZ', 'Duplicate') RETURNING id INTO v_b;
--
--   -- Two cases: one both are linked to, one only the loser is. need_type is
--   -- NOT NULL with no default.
--   INSERT INTO cases (organization_id, need_type)
--   VALUES (v_org, 'at_need') RETURNING id INTO v_case_shared;
--   INSERT INTO cases (organization_id, need_type)
--   VALUES (v_org, 'at_need') RETURNING id INTO v_case_only;
--   INSERT INTO case_decedents (case_id, decedent_id) VALUES
--     (v_case_shared, v_a), (v_case_shared, v_b), (v_case_only, v_b);
--
--   -- channel is 'call', not 'voice'; last_activity_at is NOT NULL with no
--   -- default.
--   INSERT INTO interactions (organization_id, channel, direction, source,
--                             occurred_at, last_activity_at)
--   VALUES (v_org, 'call', 'inbound', 'shop', now(), now())
--   RETURNING id INTO v_int_shared;
--   INSERT INTO interactions (organization_id, channel, direction, source,
--                             occurred_at, last_activity_at)
--   VALUES (v_org, 'call', 'inbound', 'shop', now(), now())
--   RETURNING id INTO v_int_only;
--   INSERT INTO interaction_decedents (interaction_id, decedent_id, link_method) VALUES
--     (v_int_shared, v_a, 'confirmed'),
--     (v_int_shared, v_b, 'confirmed'),
--     (v_int_only,   v_b, 'confirmed');
--
--   INSERT INTO contacts (organization_id, full_name)
--   VALUES (v_org, 'ZZZ Contact') RETURNING id INTO v_contact;
--   INSERT INTO contact_decedent_links (organization_id, contact_id, decedent_id, link_method)
--   VALUES (v_org, v_contact, v_b, 'confirmed');
--
--   -- A second pair for part B, and one in another firm for the cross-firm
--   -- refusal. Both made here, while the owner can still write anywhere.
--   INSERT INTO decedents (organization_id, first_name, last_name)
--   VALUES (v_org, 'ZZZ', 'Survivor B') RETURNING id INTO v_c;
--   INSERT INTO decedents (organization_id, first_name, last_name)
--   VALUES (v_org, 'ZZZ', 'Duplicate B') RETURNING id INTO v_d;
--   IF v_org2 IS NOT NULL THEN
--     INSERT INTO decedents (organization_id, first_name, last_name)
--     VALUES (v_org2, 'ZZZ', 'Other Firm') RETURNING id INTO v_e;
--   END IF;
--
--   -- The user for part B. app.is_internal must be on to create one that
--   -- already has an auth_user_id; users_guard_privileged refuses otherwise.
--   INSERT INTO users (email, full_name, auth_user_id, active_organization_id)
--   VALUES ('zzz-merge@example.invalid', 'ZZZ Verification', v_auth, v_org)
--   RETURNING id INTO v_user;
--   INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id)
--   VALUES (v_user, 'organization', 'manager', v_org);
--
--   PERFORM set_config('app.is_internal', 'off', true);
--
--   SELECT count(*) INTO v_hist FROM change_history
--    WHERE entity = 'decedent' AND entity_id = v_a;
--
--   PERFORM merge_decedents(v_a, v_b, 'ZZZ verification');
--
--   r := r || 'the loser points at the survivor: '
--          || (SELECT (merged_into = v_a)::text FROM decedents WHERE id = v_b)
--          || '   (expect true)' || chr(10);
--
--   SELECT count(*) INTO n FROM case_decedents WHERE decedent_id = v_b;
--   r := r || 'links left on the loser — cases: ' || n;
--   SELECT count(*) INTO n FROM interaction_decedents WHERE decedent_id = v_b;
--   r := r || ', interactions: ' || n;
--   SELECT count(*) INTO n FROM contact_decedent_links WHERE decedent_id = v_b;
--   r := r || ', contact links: ' || n || '   (expect 0, 0, 0)' || chr(10);
--
--   SELECT count(*) INTO n FROM case_decedents WHERE decedent_id = v_a;
--   r := r || 'the survivor now holds cases: ' || n
--          || '   (expect 2 — the shared one it already had, plus the moved '
--          || 'one. NOT 3: the duplicate was deleted, not stacked)' || chr(10);
--   SELECT count(*) INTO n FROM interaction_decedents WHERE decedent_id = v_a;
--   r := r || '    interactions: ' || n || '   (expect 2, same reason)' || chr(10);
--   SELECT count(*) INTO n FROM contact_decedent_links WHERE decedent_id = v_a;
--   r := r || '    contact links: ' || n || '   (expect 1 — the survivor had '
--          || 'none, so the loser''s moved)' || chr(10);
--
--   r := r || 'a history row was written: '
--          || ((SELECT count(*) FROM change_history
--                WHERE entity = 'decedent' AND entity_id = v_a) - v_hist)
--          || '   (expect 1 — the thing a hand UPDATE does not do)' || chr(10);
--   r := r || '    its detail: '
--          || COALESCE((SELECT detail::text FROM change_history
--                        WHERE entity = 'decedent' AND entity_id = v_a
--                          AND action = 'merged'
--                        ORDER BY occurred_at DESC LIMIT 1), 'NONE') || chr(10)
--          || '   (expect cases_moved 1, interactions_moved 1, '
--          || 'contact_links_moved 1 — the MOVED counts, not the totals)' || chr(10);
--
--   -- The three refusals, each checked for ITS OWN message.
--   BEGIN
--     PERFORM merge_decedents(v_a, v_a, 'ZZZ');
--     r := r || 'self-merge ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'self-merge refused: ' || SQLERRM
--            || CASE WHEN SQLERRM LIKE '%into itself%' THEN '   (right reason)'
--                    ELSE '   (WRONG REASON — this line proves nothing)' END || chr(10);
--   END;
--
--   BEGIN
--     PERFORM merge_decedents(v_a, v_b, 'ZZZ');
--     r := r || 'merging an already-merged record ALLOWED (BAD — this is the '
--            || 'chain)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'already-merged loser refused: ' || SQLERRM
--            || CASE WHEN SQLERRM LIKE '%already been merged away%' THEN '   (right reason)'
--                    ELSE '   (WRONG REASON)' END || chr(10);
--   END;
--
--   BEGIN
--     PERFORM merge_decedents(v_b, v_a, 'ZZZ');
--     r := r || 'merging INTO an already-merged record ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'already-merged survivor refused: ' || SQLERRM
--            || CASE WHEN SQLERRM LIKE '%itself been merged%' THEN '   (right reason)'
--                    ELSE '   (WRONG REASON)' END || chr(10);
--   END;
--
--   -- ---- part B: as a signed-in user --------------------------------------
--   -- Last, because the role does not need to revert afterwards. Everything
--   -- above ran as the owner, which bypasses RLS and therefore cannot test
--   -- the cross-firm rule: to the owner there is no other firm.
--   PERFORM set_config('request.jwt.claims',
--                      json_build_object('sub', v_auth::text)::text, true);
--   PERFORM set_config('role', 'authenticated', true);
--
--   SELECT count(*) INTO n FROM decedents WHERE id IN (v_c, v_d);
--   r := r || chr(10) || 'as a firm user — records visible: ' || n
--          || '   (expect 2. If 0, the rest of part B proves nothing)' || chr(10);
--
--   BEGIN
--     PERFORM merge_decedents(v_c, v_d, 'ZZZ firm user');
--     r := r || 'a firm user can merge their own firm''s records: yes' || chr(10);
--     r := r || '    actor_kind on the history row: '
--            || COALESCE((SELECT actor_kind::text FROM change_history
--                          WHERE entity = 'decedent' AND entity_id = v_c
--                            AND action = 'merged'
--                          ORDER BY occurred_at DESC LIMIT 1), 'NO ROW')
--            || '   (expect user, not system — current_user_id() resolved)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'a firm user could NOT merge their own records (BAD): '
--            || SQLERRM || chr(10);
--   END;
--
--   IF v_e IS NULL THEN
--     r := r || 'only one organization — cross-firm refusal NOT TESTED' || chr(10);
--   ELSE
--     BEGIN
--       PERFORM merge_decedents(v_c, v_e, 'ZZZ firm user');
--       r := r || 'a firm user merged ANOTHER firm''s record (BAD)' || chr(10);
--     EXCEPTION WHEN others THEN
--       r := r || 'cross-firm merge refused: ' || SQLERRM
--              || CASE WHEN SQLERRM LIKE '%different organizations%' THEN '   (right reason)'
--                      ELSE '   (WRONG REASON — a missing function, a missing '
--                           || 'privilege and a working rule all raise here)' END
--              || chr(10);
--     END;
--   END IF;
--
--   RAISE EXCEPTION 'VERIFY 20261106T1000_merge_decedents (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
