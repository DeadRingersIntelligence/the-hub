-- =============================================================================
-- 20261102T2200_merge_chains.sql
-- The Hub — a merge points at somebody, never at somebody's forwarding address.
--
-- WHY. Every reader of merged_into resolves exactly ONE hop:
--
--   COALESCE(c.merged_into, c.id)
--
-- The functions that mention merged_into, read from staging rather than from
-- the migration files, are: contact_for_number, create_case_for_call,
-- delete_case, ingest_call_event, merge_candidates, merge_contacts,
-- save_wrap_up and set_call_contact. One hop is correct only if a chain
-- cannot exist. Nothing stopped one.
--
-- (An earlier draft of this header named set_call_case and create_contact,
-- neither of which mentions the column, and omitted delete_case,
-- ingest_call_event and merge_candidates. It was assembled by reading
-- file:line out of the migrations and naming the function the line looked
-- like it was in — 053:459 is inside save_wrap_up, not create_contact. The
-- list above is what the database says.)
--
-- merge_contacts builds them by construction. Merging A into B points A at B;
-- merging B into C later points B at C and leaves A still pointing at B — a
-- record that is no longer anybody. A call matching A's number then resolves
-- to B, which has been merged away, and lands on a contact nobody is looking
-- at. The merge that caused it is an ordinary, correct thing for someone to
-- do.
--
-- Nothing stops it being done by hand either. contacts, decedents and people
-- each have merged_into as a plain self-referencing FK with no constraint
-- beyond "a row of this table exists".
--
-- NOTHING IS WRONG TODAY, AND NOTHING IS MERGED AT ALL. Counted on both
-- databases on 2 Nov 2026: of all rows — contacts 13 staging / 1 production,
-- decedents 5 / 0, people 58 / 53 — NONE has merged_into set, on any table on
-- either database. So there is no chain, no self-reference, no cross-firm
-- pointer and nothing dangling, because there is nothing pointed anywhere.
-- This is entirely preventive, which is why it can be a plain trigger with no
-- backfill and no NOT VALID.
--
-- WHAT THIS DOES
--
--   1. One trigger function on all three tables, so the rule is stated once:
--      merged_into must name a row in the same organization that is not this
--      row and is not itself merged — and nothing may already be merged into
--      the row being pointed away.
--
--   2. merge_contacts REPOINTS what was merged into the loser, so merging into
--      a contact that has absorbed others stays ordinary and stops being the
--      thing that creates a chain. And it refuses either end being already
--      merged, which is the direct route to the same state.
--
-- people is included although nothing merges people and nothing reads
-- people.merged_into. The column has the same shape and no rows to violate
-- the rule, so the guard costs a line in a loop now and saves a third shape
-- to remember when something does start merging them.
--
-- WHAT THIS BREAKS, named because it will be found at an awkward moment
-- otherwise. 050's verification block builds a two-hop chain on purpose:
--
--   UPDATE contacts SET merged_into = v_case WHERE id = v_c;   -- v_c2 -> v_c -> v_case
--
-- to prove set_call_contact refuses a survivor that is itself merged away.
-- After this migration that set-up is refused, so the block stops there. The
-- test is not wrong; what it tests has moved from "handled when it happens"
-- to "cannot happen", which is a better place for it to live. 050 has run, so
-- its block wants an in-place note saying the section is now unreachable and
-- why — a separate annotation, not this file.
--
-- AND set_call_contact's OWN REFUSAL STAYS. 050 line 164 raises if the
-- resolved contact is itself merged. This makes that branch unreachable; it
-- is not thereby wrong. It is the check that would still be there if this
-- trigger were ever dropped, and removing it on the grounds that the trigger
-- exists would leave nothing if the trigger did not.
--
-- db/README.md ALREADY HAS A 051 ENTRY, at "051 (merge chains)". It records
-- what was read on 30 October and says deferring is safe only while no chains
-- exist, that nothing prevents or detects one, and that merge_contacts
-- neither repoints nor refuses a merged survivor. All of that stops being
-- true when this runs, so that entry is rewritten in the same change — see
-- README_051_entry.md, delivered alongside. Its closing line, "Other readers
-- weren't looked for", is answered by the list above.
--
-- Requires, by what it actually uses:
--   003  people.merged_into
--   005  contacts.merged_into, decedents.merged_into
--   048  merge_contacts(), whose body this replaces
--
-- Safe to run twice: the trigger function and triggers are replaced rather
-- than added, the drift check tells "already applied" from "something else
-- changed it", and the precondition tolerates both states.
--
-- APPLIED to staging and production, 2 Nov 2026, from the file hashed
-- bb080ed0. Both databases hold the same bodies:
--   merge_contacts                       16177d5f2ae691818929c375e222e081
--   merged_into_points_at_a_survivor     6beb57112c4c7266432416070ebf1c5b
-- and *_merged_into_ck on contacts, decedents and people, enabled and scoped
-- to merged_into alone.
--
-- The verification block was run in full on staging, against those same
-- bodies, and NOT on production: it inserts rows to test the guard, and
-- rolling them back is not the same as never writing them to a live database.
-- What was checked on production is the parity above.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Nothing stored would be trapped
--
-- Counted before the trigger exists, and refused rather than reported. A
-- trigger on UPDATE OF merged_into only fires when that column is written, so
-- an existing bad row is not frozen the way a CHECK would freeze it — but it
-- is still a row the rule says should not exist, and finding out now is worth
-- more than finding out when somebody tries to fix it.
--
-- All four shapes, on all three tables, because they are all things the
-- trigger will refuse from here on.
-- -----------------------------------------------------------------------------
DO $$
DECLARE t text; n int; bad text := '';
BEGIN
  FOREACH t IN ARRAY ARRAY['contacts', 'decedents', 'people'] LOOP
    EXECUTE format($q$
      SELECT count(*) FROM %1$I a JOIN %1$I b ON b.id = a.merged_into
       WHERE b.merged_into IS NOT NULL
          OR b.id = a.id
          OR b.organization_id IS DISTINCT FROM a.organization_id
    $q$, t) INTO n;
    IF n > 0 THEN
      bad := bad || format('%s: %s; ', t, n);
    END IF;
  END LOOP;

  IF bad <> '' THEN
    RAISE EXCEPTION 'merged_into rows that break the rule this adds — %', btrim(bad, '; ')
      USING HINT = 'Each points at a merged row, at itself, or across organizations. Resolve them before adding the guard, or every later write to merged_into on those rows is refused.';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. The rule, once, for all three tables
--
-- Keyed on TG_TABLE_NAME rather than written three times. Three near-identical
-- functions is how two of them end up different.
--
-- Only fires when merged_into is written — UPDATE OF merged_into — so an
-- ordinary edit to a contact's name is not made to re-prove this.
--
-- The FK already says the target is a row of this table. This adds the four
-- things it cannot.
--
-- BOTH DIRECTIONS, which an earlier draft got half right. Refusing a target
-- that is itself merged stops A -> B when B is already merged. It does NOT
-- stop B -> C when A is already merged into B: B's target is unmerged, so the
-- check passes, and A is left pointing at a record that is no longer anybody.
-- That is the same chain from the other end, and for decedents and people it
-- is the ONLY way one can form, since neither has a merge function and every
-- merge there is a hand UPDATE. So the row being merged away must have
-- nothing merged into it.
--
-- This does not obstruct merge_contacts: it repoints dependents to the
-- survivor before pointing the loser away, so the loser has none left by the
-- time this fires, and the repointed rows have no dependents of their own.
-- The guard refuses exactly the thing the repoint exists to avoid doing.
--
-- FOR UPDATE on the target, for the case neither check sees alone: two
-- transactions, one doing A -> B and one doing B -> C, each pass while the
-- other is uncommitted and together leave a chain. Locking the target makes
-- the second wait for the first, and it then finds the dependent and refuses.
-- Merges are rare and done by hand, so this is unlikely — but it costs one
-- clause and the failure it prevents is silent.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION merged_into_points_at_a_survivor() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_merged uuid; v_org uuid; v_their_org uuid; v_has_dependents boolean;
BEGIN
  IF NEW.merged_into IS NULL THEN RETURN NEW; END IF;

  IF NEW.merged_into = NEW.id THEN
    RAISE EXCEPTION 'a % cannot be merged into itself', TG_TABLE_NAME;
  END IF;

  -- The other direction: nothing may already be merged into the row being
  -- pointed away, or those rows become a chain the moment this commits.
  EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I WHERE merged_into = $1)', TG_TABLE_NAME)
    INTO v_has_dependents USING NEW.id;
  IF v_has_dependents THEN
    RAISE EXCEPTION
      'others have been merged into this %, so merging it away would leave them on a chain', TG_TABLE_NAME
      USING HINT = 'Repoint them to the new target first — merge_contacts does that for contacts.';
  END IF;

  -- FOR UPDATE: holds the target until this transaction ends, so a concurrent
  -- merge OF the target waits and then sees this row as its dependent.
  EXECUTE format('SELECT merged_into, organization_id FROM %I WHERE id = $1 FOR UPDATE', TG_TABLE_NAME)
    INTO v_merged, v_their_org USING NEW.merged_into;

  v_org := NEW.organization_id;

  IF v_their_org IS DISTINCT FROM v_org THEN
    RAISE EXCEPTION 'a % can only be merged into one at the same firm', TG_TABLE_NAME;
  END IF;

  IF v_merged IS NOT NULL THEN
    RAISE EXCEPTION
      'that % has itself been merged into another one, so merging into it would leave a chain', TG_TABLE_NAME
      USING HINT = 'Point at the surviving record instead. Every reader follows merged_into exactly one hop.';
  END IF;

  RETURN NEW;
END $$;

COMMENT ON FUNCTION merged_into_points_at_a_survivor() IS
  'Keeps merged_into one hop deep on contacts, decedents and people, in BOTH '
  'directions: the target must be a different row, at the same firm, that has '
  'not itself been merged, AND nothing may already be merged into the row '
  'being pointed away. The second half is the only thing standing between a '
  'hand-merged decedent and a chain, since nothing merges decedents for you. '
  'Every reader resolves COALESCE(merged_into, id) — one hop — so a '
  'chain means a call or a case landing on a record that is no longer '
  'anybody. One function for three tables, keyed on TG_TABLE_NAME, because '
  'three copies is how two of them come to differ.';

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['contacts', 'decedents', 'people'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %1$I_merged_into_ck ON %1$I', t);
    EXECUTE format(
      'CREATE TRIGGER %1$I_merged_into_ck BEFORE INSERT OR UPDATE OF merged_into ON %1$I'
      ' FOR EACH ROW EXECUTE FUNCTION merged_into_points_at_a_survivor()', t);
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- 3. merge_contacts must be the body this was built from
-- -----------------------------------------------------------------------------
DO $$
DECLARE v text; n int;
BEGIN
  SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname = 'public' AND p.proname = 'merge_contacts';
  IF n <> 1 THEN
    RAISE EXCEPTION 'expected one merge_contacts, found %; stop and look', n;
  END IF;

  SELECT md5(prosrc) INTO v FROM pg_proc
   WHERE oid = 'merge_contacts(uuid, uuid, text)'::regprocedure;

  IF v IS NULL THEN
    RAISE EXCEPTION 'merge_contacts does not exist; run 015 to 048 first';
  ELSIF v = '16177d5f2ae691818929c375e222e081' THEN
    RAISE NOTICE 'merge_contacts already repoints and refuses — this migration has run before; replacing it is a no-op';
  ELSIF v <> '5a0bf402ed0db21c8ff412f679fa7708' THEN
    RAISE EXCEPTION 'merge_contacts is neither 048''s version (%) nor this one; stop and compare before replacing it', v;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 4. 048's body, with the refusals and the repoint
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION merge_contacts(p_survivor uuid, p_loser uuid, p_actor text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_org uuid;
  v_survivor_name text;
  v_loser_name text;
  v_moved int;
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

  -- Anything already merged into the loser follows it to the survivor, BEFORE
  -- the loser is pointed away. Merging into a contact that has absorbed others
  -- is ordinary; without this it is what creates the chain the guard above
  -- refuses to create directly.
  UPDATE contacts SET merged_into = p_survivor, updated_at = now()
   WHERE merged_into = p_loser;

  UPDATE contacts SET merged_into = p_survivor, updated_at = now() WHERE id = p_loser;

  PERFORM record_change(
    v_org, 'contact', p_survivor, 'merged',
    CASE WHEN v_user IS NOT NULL THEN 'user' ELSE 'system' END::actor_kind, p_actor,
    format('%s merged %s into %s', p_actor,
           COALESCE(v_loser_name, 'an unnamed contact'),
           COALESCE(v_survivor_name, 'this contact')),
    v_user,
    jsonb_build_object('merged_contact_id', p_loser,
                       'merged_contact_name', v_loser_name,
                       'phone_numbers_moved', v_moved));
END $$;

COMMENT ON FUNCTION merge_contacts(uuid, uuid, text) IS
  'Merges one contact into another: everything moves to the survivor, the '
  'loser keeps its id and points at the survivor, and nothing orphans. '
  'Refuses either end that has already been merged away, and REPOINTS '
  'anything previously merged into the loser so it follows to the survivor — '
  'without that, merging into a contact that has absorbed others leaves those '
  'others pointing at a record that is no longer anybody, and every reader '
  'follows merged_into exactly one hop. RECORDS THE MERGE ITSELF, through '
  'record_change — 015 left that to the caller and 016 moved it in here, so '
  'a caller that also writes history writes it twice.';

-- -----------------------------------------------------------------------------
-- 5. And it is the body that was reviewed
-- -----------------------------------------------------------------------------
DO $$
DECLARE v text;
BEGIN
  SELECT md5(prosrc) INTO v FROM pg_proc
   WHERE oid = 'merge_contacts(uuid, uuid, text)'::regprocedure;

  IF v <> '16177d5f2ae691818929c375e222e081' THEN
    RAISE EXCEPTION
      'merge_contacts installed as % — not the reviewed body (16177d5f2ae691818929c375e222e081). Nothing has been kept.', v;
  END IF;
END $$;

COMMIT;

-- =============================================================================
-- STILL TO DO, named so they aren't folded in and skipped
--
-- * 050's VERIFICATION BLOCK NO LONGER RUNS PAST ITS TWO-HOP SET-UP. It does
--   UPDATE contacts SET merged_into = v_case WHERE id = v_c to build
--   v_c2 -> v_c -> v_case, and that is now refused. 050 has run, so the fix
--   is an in-place note in its block saying the section is unreachable
--   because chains cannot be built, not a change to what 050 did.
--
-- * THERE IS STILL NO merge FUNCTION FOR decedents OR people. The guard says
--   what a merge must leave behind; it does not move anything. Merging a
--   decedent by hand today means repointing case_decedents,
--   interaction_decedents and contact_decedent_links oneself, and nothing
--   checks that it was done. 057's delete_case already deletes a decedent
--   only when nothing refers to it, which is the same question asked from
--   the other end. If decedent merging is ever a product feature it wants a
--   merge_decedents() in the shape of merge_contacts, not a hand procedure.
--
-- * NOTHING RECORDS A HAND-SET merged_into. merge_contacts writes
--   change_history; a direct UPDATE writes nothing, so a contact can stop
--   being a contact with no record of who decided that. Out of scope here —
--   the guard is about the shape of the data, not its provenance — but worth
--   knowing it is not covered.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- DO $$
-- DECLARE
--   r text := ''; v_org uuid; v_other uuid;
--   a uuid; b uuid; c uuid; v_far uuid; t text; n int;
--   -- All six here rather than in the sub-blocks below: a variable declared
--   -- in one sub-block's DECLARE is not visible to its sibling, which is a
--   -- compile error ("p1 is not a known variable") rather than a test that
--   -- quietly does nothing.
--   d1 uuid; d2 uuid; d3 uuid; p1 uuid; p2 uuid; p3 uuid;
-- BEGIN
--   SELECT id INTO v_org FROM organizations WHERE code = 'DR';
--   SELECT id INTO v_other FROM organizations WHERE id <> v_org LIMIT 1;
--   PERFORM set_config('app.is_internal', 'on', true);
--   PERFORM set_config('app.organization_id', v_org::text, true);
--   PERFORM set_config('app.user_id',
--     (SELECT id::text FROM users WHERE active ORDER BY is_internal DESC LIMIT 1), true);
--
--   r := r || 'merge_contacts installed: '
--          || (SELECT md5(prosrc) FROM pg_proc
--               WHERE oid = 'merge_contacts(uuid, uuid, text)'::regprocedure)
--          || '   (expect 16177d5f2ae691818929c375e222e081)' || chr(10);
--
--   r := r || 'guard attached to: '
--          || (SELECT string_agg(c.relname, ', ' ORDER BY c.relname)
--                FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
--                JOIN pg_proc p ON p.oid = t.tgfoid
--               WHERE p.proname = 'merged_into_points_at_a_survivor'
--                 AND NOT t.tgisinternal)
--          || '   (expect contacts, decedents, people)' || chr(10);
--
--   r := r || 'nothing stored breaks the rule: ';
--   FOREACH t IN ARRAY ARRAY['contacts', 'decedents', 'people'] LOOP
--     EXECUTE format($q$
--       SELECT count(*) FROM %1$I a JOIN %1$I b ON b.id = a.merged_into
--        WHERE b.merged_into IS NOT NULL OR b.id = a.id
--           OR b.organization_id IS DISTINCT FROM a.organization_id $q$, t) INTO n;
--     r := r || t || ' ' || n || ' ';
--   END LOOP;
--   r := r || '  (expect 0 0 0)' || chr(10);
--
--   -- ---- The guard, on contacts ---------------------------------------------
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'Verify A') RETURNING id INTO a;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'Verify B') RETURNING id INTO b;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'Verify C') RETURNING id INTO c;
--
--   BEGIN
--     UPDATE contacts SET merged_into = a WHERE id = a;
--     r := r || 'merged into itself: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'merged into itself refused' || chr(10); END;
--
--   UPDATE contacts SET merged_into = b WHERE id = a;
--   r := r || 'a plain merge is allowed' || chr(10);
--
--   BEGIN
--     UPDATE contacts SET merged_into = a WHERE id = c;
--     r := r || 'merged into a merged-away contact: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'merged into a merged-away contact refused' || chr(10); END;
--
--   IF v_other IS NOT NULL THEN
--     BEGIN
--       INSERT INTO contacts (organization_id, full_name)
--       VALUES (v_other, 'Verify Elsewhere') RETURNING id INTO v_far;
--       UPDATE contacts SET merged_into = v_far WHERE id = c;
--       r := r || 'merged across firms: ALLOWED (BAD)' || chr(10);
--     EXCEPTION WHEN others THEN
--       r := r || 'merged across firms refused' || chr(10); END;
--   ELSE
--     r := r || 'cross-firm case SKIPPED: only one organization' || chr(10);
--   END IF;
--
--   -- ---- The other direction, which an earlier draft allowed ---------------
--   -- a -> b already. Pointing b away would strand a.
--   BEGIN
--     UPDATE contacts SET merged_into = c WHERE id = b;
--     r := r || 'merging away a contact that others point at: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'merging away a contact that others point at refused' || chr(10); END;
--
--   -- ---- merge_contacts repoints, which is the half a guard alone misses ----
--   -- a -> b already. Merging b into c must bring a with it.
--   BEGIN
--     PERFORM merge_contacts(c, b, 'verify 20261102T2200');
--     r := r || 'after merging b into c — b points at c: '
--            || (SELECT merged_into = c FROM contacts WHERE id = b)
--            || ', a followed: '
--            || (SELECT merged_into = c FROM contacts WHERE id = a)
--            || '   (expect true, true — a is the repoint)' || chr(10);
--     r := r || 'and no chain exists: '
--            || (SELECT count(*) FROM contacts x JOIN contacts y ON y.id = x.merged_into
--                 WHERE y.merged_into IS NOT NULL)
--            || '   (expect 0)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'repoint test NOT RUN: ' || SQLERRM || chr(10); END;
--
--   -- ---- merge_contacts refuses either end already merged -------------------
--   BEGIN
--     PERFORM merge_contacts(c, a, 'verify');
--     r := r || 'merging an already-merged loser: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'merging an already-merged loser refused' || chr(10); END;
--
--   BEGIN
--     PERFORM merge_contacts(b, c, 'verify');
--     r := r || 'merging into an already-merged survivor: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'merging into an already-merged survivor refused' || chr(10); END;
--
--   -- ---- The same guard on decedents and people -----------------------------
--   BEGIN
--     INSERT INTO decedents (organization_id, last_name, status)
--     VALUES (v_org, 'VerifyOne', 'at_need') RETURNING id INTO d1;
--     INSERT INTO decedents (organization_id, last_name, status)
--     VALUES (v_org, 'VerifyTwo', 'at_need') RETURNING id INTO d2;
--     INSERT INTO decedents (organization_id, last_name, status)
--     VALUES (v_org, 'VerifyThree', 'at_need') RETURNING id INTO d3;
--     UPDATE decedents SET merged_into = d2 WHERE id = d1;
--     BEGIN
--       UPDATE decedents SET merged_into = d1 WHERE id = d3;
--       r := r || 'decedent chain, target end: ALLOWED (BAD)' || chr(10);
--     EXCEPTION WHEN others THEN
--       r := r || 'decedent chain, target end refused' || chr(10); END;
--     -- The hand path, which is the only path decedents have.
--     BEGIN
--       UPDATE decedents SET merged_into = d3 WHERE id = d2;
--       r := r || 'decedent chain, source end: ALLOWED (BAD)' || chr(10);
--     EXCEPTION WHEN others THEN
--       r := r || 'decedent chain, source end refused' || chr(10); END;
--   EXCEPTION WHEN others THEN
--     r := r || 'decedent guard NOT TESTED: ' || SQLERRM || chr(10); END;
--
--   BEGIN
--     INSERT INTO people (organization_id, full_name) VALUES (v_org, 'Verify P1') RETURNING id INTO p1;
--     INSERT INTO people (organization_id, full_name) VALUES (v_org, 'Verify P2') RETURNING id INTO p2;
--     INSERT INTO people (organization_id, full_name) VALUES (v_org, 'Verify P3') RETURNING id INTO p3;
--     UPDATE people SET merged_into = p2 WHERE id = p1;
--     BEGIN
--       UPDATE people SET merged_into = p1 WHERE id = p3;
--       r := r || 'people chain, target end: ALLOWED (BAD)' || chr(10);
--     EXCEPTION WHEN others THEN
--       r := r || 'people chain, target end refused' || chr(10); END;
--     BEGIN
--       UPDATE people SET merged_into = p3 WHERE id = p2;
--       r := r || 'people chain, source end: ALLOWED (BAD)' || chr(10);
--     EXCEPTION WHEN others THEN
--       r := r || 'people chain, source end refused' || chr(10); END;
--   EXCEPTION WHEN others THEN
--     r := r || 'people guard NOT TESTED: ' || SQLERRM || chr(10); END;
--
--   -- ---- The trigger is scoped to the column, asserted directly ------------
--   -- Renaming a row and seeing it succeed proves nothing: after the repoint
--   -- above, a points at c, which is not merged, so the rename would pass
--   -- even if the trigger fired on every UPDATE. The scoping is in tgattr, so
--   -- read it — resolved to column names rather than compared to attnums,
--   -- which differ per database and per table.
--   r := r || 'trigger scoped to: '
--          || (SELECT string_agg(c.relname || '.' || at.attname, ', ' ORDER BY c.relname)
--                FROM pg_trigger tg
--                JOIN pg_class c ON c.oid = tg.tgrelid
--                JOIN pg_proc pr ON pr.oid = tg.tgfoid
--                JOIN pg_attribute at ON at.attrelid = c.oid AND at.attnum = ANY(tg.tgattr)
--               WHERE pr.proname = 'merged_into_points_at_a_survivor'
--                 AND NOT tg.tgisinternal)
--          || '   (expect contacts.merged_into, decedents.merged_into, '
--          || 'people.merged_into — and nothing else, or an ordinary edit '
--          || 'pays for this)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261102T2200_merge_chains (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
