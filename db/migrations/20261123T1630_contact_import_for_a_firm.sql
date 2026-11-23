-- =============================================================================
-- 20261123T1630_contact_import_for_a_firm.sql
-- The Hub — Dead Ringers imports a client firm's contacts, in a database
-- session, through the same code the firm's own import used.
--
-- THE DECISION (Mandie, 23 November): contact import is INTERNAL ONLY. Dead
-- Ringers runs it during onboarding, as SQL in the SQL editor, which runs as
-- postgres and so isn't held to authenticated's 8 s statement_timeout. No
-- screen, internal or client-facing: a server action on the signed-in session
-- runs as authenticated even for internal staff, and service_role has the
-- same missing boundary as postgres plus a UI to build.
--
-- WHAT THE EXISTING FUNCTIONS COULDN'T DO, AND THIS FILE DOES:
--   1. NAME THE FIRM. current_organization_id() is the session's firm, which
--      for Dead Ringers' staff is Dead Ringers. contact_import_for_firm_*
--      take the firm's id.
--   2. CROSS-CHECK IT BY NAME. They take the firm's name too, and refuse
--      unless both are the same row. postgres has BYPASSRLS: a mistyped id
--      would put thousands of contacts in another funeral home's book, with
--      nothing to stop it and no undo. A screen would have given this by
--      letting a person pick from a list; choosing SQL is choosing to build
--      it.
--   3. NAME THE PERSON. The commit took its actor from the session, and
--      postgres has no Hub user. contact_import_for_firm_commit takes the
--      acting Dead Ringers person's Hub email, and refuses anyone who isn't
--      an active internal user, so every import still leaves an actor.
--
-- ONE BODY, NOT TWO. commit_contact_import's body (2330's rules, 1500's call
-- linking) moves, with the firm and the person as parameters, into
-- contact_import_apply. commit_contact_import becomes a one-line wrapper over
-- it, and contact_import_for_firm_commit calls it too. The previews both call
-- contact_import_classify, unchanged. So the dedupe, fill and link rules
-- exist once. What contact_import_apply adds to the old body, and nothing
-- else (a diff against 1500's commit shows exactly this):
--   * it refuses to run as anon, authenticated or service_role, checked on
--     current_user, which an API caller can't set: a lock, not a grant, so a
--     grant added later by mistake doesn't open it;
--   * THE TENANT CHECK. Under postgres no row-level security applies, so the
--     function is the only boundary. Nothing ties a contact_phones row's
--     organization_id to its contact's firm (two separate foreign keys), so
--     a phone row of this firm on another firm's contact would make the
--     classifier offer that contact, and a fill would write to it; under the
--     app's RLS it was invisible and harmless. Now every row is classified
--     first, and the import refuses before any write if any contact it names
--     is outside the firm (contact_import_outside_firm, which the preview
--     reports too);
--   * every write names the firm in its own WHERE or VALUES: the contact
--     read FOR UPDATE and the fill (both refuse if the contact isn't at the
--     firm), the call link UPDATE, and the inserts (which always did);
--   * SET plan_cache_mode = force_custom_plan, for the function and
--     everything under it. Measuring the internal cap found the old body
--     QUADRATIC above about 5,000 rows: 20,000 rows took 17.8 s and 40,000
--     took 59 s on scratch. The cause was cached plans, the foreign-key
--     checks' included, made while the tables were nearly empty (production
--     held 2 contacts on 23 November), so each scanned a table the import was
--     growing. With fresh plans: 0.37 ms per row, flat from 5,000 to 40,000.
--     The app's path never went above 1,000 rows, where this barely showed.
--     READ WITH 1600's APPLIED NOTE: this is probably part of the ~2.07 s
--     "fixed cost" measured on production that afternoon (two points, 1,000
--     and 2,000 rows, both into a nearly empty database), and so part of why
--     the app's cap landed at 1,000. The same bug, seen from the other end.
--     It changes nothing now: the app's path is closed (section 4).
--
-- THE CLIENT PATH IS CLOSED IN THE CATALOGUE. preview_contact_import,
-- commit_contact_import, contact_import_check and contact_import_classify
-- lose authenticated's EXECUTE: import is internal only, and
-- contact_import_apply refuses authenticated anyway, so leaving the grants
-- would leave the catalogue saying something false. Re-exposing import to
-- clients is a reviewed change, not a grant: it would lift the lock for a
-- caller importing into their own firm as themselves. 1600's 1,000 cap stays
-- in contact_import_check as the record of that measurement, NOT as a live
-- limit; its comment now says so (Mandie, 23 November).
--
-- THE INTERNAL CAP: 20,000 ROWS, proposed. The ceiling is no longer the 8 s
-- statement_timeout but the SQL editor's gateway, which cut runs off twice on
-- 23 November at about two minutes (not raisable). The largest real file
-- expected is about 5,000. Scratch, postgres, a first-day firm (150 contacts,
-- 300 past calls), commit only:
--     1,000 rows 0.45 s;  5,000 1.89 s;  10,000 3.69 s;  20,000 7.23 s;
--     40,000 14.96 s (0.37 ms per row, linear). The checks COMMIT runs
--     afterwards (contacts.import_id is deferred) add 0.06 s at 20,000.
-- Production ran 2.2 to 2.5 times scratch's times today, so 20,000 should
-- commit in about 16 to 18 s there: a sixth of the gateway, four times the
-- largest file expected. Not set on that prediction: line 11 of the
-- verification times 20,000 rows on production, and the target is a quarter
-- of a two-minute gateway (30 s). Over it, the cap comes down before merge.
--
-- NOT REACHABLE THROUGH THE API. Every function this file creates has EXECUTE
-- revoked from PUBLIC, anon, authenticated and service_role: PostgREST can't
-- call them, so there is no second path to reason about. The gate is "you
-- have database access".
--
-- HOW TO RUN AN IMPORT (the SQL editor, as postgres):
--   1. SELECT id, name FROM organizations WHERE name ILIKE '%part of it%';
--   2. SELECT contact_import_for_firm_preview('<id>', '<name, exactly>', '<rows>'::jsonb);
--      Read counts, outside_the_firm (must be null) and needs_a_look. Held
--      rows list their candidates; decide each.
--   3. SELECT contact_import_for_firm_commit('<id>', '<name, exactly>',
--        '<your Hub email>', '<rows>'::jsonb, '<file name>',
--        '{"<row>": "<candidate id>", "<row>": "skip"}'::jsonb);
--   Rows are the same shape the app's import took: [{"full_name", 
--   "business_name", "email", "phones": [{"number", "label"}]}, ...].
--
-- Requires: 20261120T2330, 20261123T1500, 20261123T1600 (the bodies pinned in
--           section 1), 20261103T1200 (record_migration).
-- NOT SAFE TO RUN TWICE: section 1 refuses once commit_contact_import has
-- become the wrapper.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Preconditions: the three files ran here, and every body this depends on
--    is as reviewed
-- -----------------------------------------------------------------------------
DO $$
DECLARE v text; f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['20261120T2330_contact_import.sql', '20261123T1500_contact_import_cap.sql',
                           '20261123T1600_contact_import_cap_1000.sql'] LOOP
    IF NOT EXISTS (SELECT 1 FROM schema_migrations WHERE filename = f) THEN
      RAISE EXCEPTION '% has not run here; run it first', f;
    END IF;
  END LOOP;
  FOR f, v IN VALUES
      ('commit_contact_import(jsonb, text, jsonb)', '293a2ee6014ac4fb31fa6942622002ef'),   -- 1500
      ('contact_import_check(jsonb)', 'ede87756e2d4f05d72904d1557a9e389'),                -- 1600
      ('preview_contact_import(jsonb)', '5880349fd600b84cfdc2fa996f0e07cf'),              -- 2330
      ('contact_import_classify(uuid, jsonb)', 'd185238e619ab41a0f9677ddddc06816'),      -- 2330
      ('record_change(uuid, history_entity, uuid, history_action, actor_kind, text, text, uuid, jsonb, link_method)',
       '130654ec3b66364423609c08b9fffdd5'),
      ('firm_only_number(uuid, text)', '19aea1e936d3e898deb26e6852102f39') LOOP
    IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure(f)) IS DISTINCT FROM v THEN
      RAISE EXCEPTION '% is not the body this file was reviewed against (md5 %, expected %): already converted, or changed: stop and read it',
        f, COALESCE((SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure(f)), 'missing'), v;
    END IF;
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- 2. The tenant check: any contact the classifier named that isn't at the firm
-- -----------------------------------------------------------------------------
CREATE FUNCTION contact_import_outside_firm(p_org uuid, p_classified jsonb)
RETURNS text LANGUAGE sql STABLE AS $$
  -- Every contact a classified row names: a fill's or unchanged row's
  -- contact, and every candidate of a held row. Says which rows, never which
  -- firm the contact is at.
  WITH named AS (
    SELECT (x ->> 'row')::int AS row_no, (x ->> 'contact_id')::uuid AS cid
      FROM jsonb_array_elements(p_classified) x WHERE x ? 'contact_id'
    UNION ALL
    SELECT (x ->> 'row')::int, (cd ->> 'id')::uuid
      FROM jsonb_array_elements(p_classified) x, jsonb_array_elements(COALESCE(x -> 'candidates', '[]')) cd),
  bad AS (
    SELECT DISTINCT n.row_no FROM named n LEFT JOIN contacts c ON c.id = n.cid
     WHERE c.organization_id IS DISTINCT FROM p_org)
  SELECT CASE WHEN count(*) = 1 THEN 'row ' ELSE 'rows ' END
         || string_agg(row_no::text, ', ' ORDER BY row_no)
         || ': a number this firm holds is on a phone record attached to a contact at another firm. '
         || 'Fix that phone record first; nothing outside the firm is ever written'
    FROM bad HAVING count(*) > 0
$$;
COMMENT ON FUNCTION contact_import_outside_firm(uuid, jsonb) IS
  'The import''s tenant check: which classified rows name a contact that is '
  'not at the firm (null when none). Both the internal preview and '
  'contact_import_apply call it; the apply refuses before writing anything '
  '(20261123T1630).';

-- -----------------------------------------------------------------------------
-- 3. The one body: 1500's commit, with the firm and the person as parameters
-- -----------------------------------------------------------------------------
CREATE FUNCTION contact_import_apply(p_org uuid, p_actor uuid, p_rows jsonb,
                                     p_filename text DEFAULT NULL, p_choices jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql
-- Fresh plans for every statement, the foreign-key and trigger queries under
-- them included. A cached plan is built for the tables as they are when it's
-- first made, and on a nearly empty database (production on 23 November held
-- 2 contacts) that's a scan, which the import then makes longer with every
-- row it adds: 20,000 rows committed in 17.8 s with cached plans and 7.5 s
-- without, on scratch, and the gap grew with the file (20261123T1630).
SET plan_cache_mode = force_custom_plan
AS $$
DECLARE
  v_org uuid := p_org;
  v_import uuid := gen_random_uuid();
  v_user uuid := p_actor; v_actor text;
  v_rows jsonb[]; v_foreign text;
  x jsonb; v_row jsonb; v_target uuid; v_choice text; v_c record;
  v_fields jsonb; v_added text[]; v_num text; v_label phone_label; i int; v_call uuid;
  k_created int := 0; k_filled int := 0; k_unchanged int := 0; k_resolved int := 0;
  k_skipped int := 0; k_refused int := 0; k_calls int := 0;
  -- Parallel arrays, appended in place (a jsonb || per row would copy the
  -- whole value each time, which is N squared again).
  v_pair_cid uuid[] := '{}'; v_pair_num text[] := '{}';
  v_cand_ids uuid[]; v_cand_cids uuid[]; v_hand uuid[];
BEGIN
  -- Not through the app. Only a database session (postgres, in the SQL
  -- editor) reaches this, and it checks the role it runs as itself, so a
  -- grant added later by mistake still doesn't open it (20261123T1630).
  IF current_user IN ('anon', 'authenticated', 'service_role') THEN
    RAISE EXCEPTION 'contact import runs in a Dead Ringers database session, not through the app'
      USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM organizations WHERE id = v_org) THEN
    RAISE EXCEPTION 'no firm with id %', v_org;
  END IF;
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'the import needs the person running it, so it can say who did it';
  END IF;
  SELECT full_name INTO v_actor FROM users WHERE id = v_user AND active;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'no active Hub user with id %, so the import can''t say who did it', v_user;
  END IF;

  -- THE TENANT BOUNDARY. This runs where row-level security doesn't (postgres
  -- bypasses it), so nothing but this function keeps the import inside the
  -- firm. Every row is classified first, and the import refuses, before any
  -- write, if the classifier named a contact outside the firm: possible
  -- because nothing ties contact_phones.organization_id to its contact's
  -- firm. Then every write below names the firm in its own WHERE or VALUES,
  -- and a fill that finds no contact at the firm stops the import.
  SELECT array_agg(y ORDER BY (y ->> 'row')::int) INTO v_rows FROM contact_import_classify(v_org, p_rows) y;
  v_foreign := contact_import_outside_firm(v_org, to_jsonb(COALESCE(v_rows, '{}')));
  IF v_foreign IS NOT NULL THEN
    RAISE EXCEPTION 'nothing imported: %', v_foreign;
  END IF;

  FOREACH x IN ARRAY COALESCE(v_rows, '{}') LOOP
    v_row := p_rows -> ((x ->> 'row')::int - 1);
    v_target := NULL;
    v_added := '{}';

    IF x ->> 'verdict' = 'refused' THEN k_refused := k_refused + 1; CONTINUE; END IF;

    IF x ->> 'verdict' = 'held' THEN
      v_choice := p_choices ->> (x ->> 'row');
      IF x ->> 'hold' = 'in_file' OR v_choice IS NULL OR v_choice = 'skip'
         OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(x -> 'candidates') cnd WHERE cnd ->> 'id' = v_choice) THEN
        k_skipped := k_skipped + 1; CONTINUE;
      END IF;
      v_target := v_choice::uuid;
      k_resolved := k_resolved + 1;
    ELSIF x ->> 'verdict' IN ('create', 'create_no_number') THEN
      INSERT INTO contacts (organization_id, contact_kind, full_name, business_name, email, import_id)
      VALUES (v_org,
              CASE WHEN NULLIF(btrim(COALESCE(v_row ->> 'full_name', '')), '') IS NULL THEN 'business' ELSE 'individual' END::contact_kind,
              NULLIF(btrim(COALESCE(v_row ->> 'full_name', '')), ''),
              NULLIF(btrim(COALESCE(v_row ->> 'business_name', '')), ''),
              NULLIF(btrim(COALESCE(v_row ->> 'email', '')), ''), v_import)
      RETURNING id INTO v_target;
      i := 0;
      FOR v_num IN SELECT jsonb_array_elements_text(x -> 'numbers') LOOP
        v_label := (SELECT CASE WHEN p ->> 'label' = ANY (enum_range(NULL::phone_label)::text[]) THEN (p ->> 'label')::phone_label ELSE 'mobile' END
                      FROM jsonb_array_elements(COALESCE(v_row -> 'phones', '[]')) p
                     WHERE normalize_e164(btrim(COALESCE(p ->> 'number', ''))) = v_num LIMIT 1);
        INSERT INTO contact_phones (organization_id, contact_id, e164, label, is_primary, added_by)
        VALUES (v_org, v_target, v_num, COALESCE(v_label, 'mobile'), i = 0, 'contact import');
        i := i + 1;
      END LOOP;
      PERFORM record_change(v_org, 'contact', v_target, 'created', 'user', v_actor,
        format('%s created this contact by importing %s', v_actor, COALESCE(p_filename, 'a contact list')),
        v_user, jsonb_build_object('import_id', v_import, 'row', (x ->> 'row')::int, 'numbers', x -> 'numbers'));
      k_created := k_created + 1;
    ELSE
      v_target := (x ->> 'contact_id')::uuid;   -- fill or unchanged
    END IF;

    -- Fill the target's empty fields, and add numbers no contact holds.
    IF x ->> 'verdict' IN ('fill', 'unchanged', 'held') THEN
      SELECT * INTO v_c FROM contacts WHERE id = v_target AND organization_id = v_org FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'nothing imported: row % names a contact that isn''t at this firm', x ->> 'row';
      END IF;
      v_fields := '{}'; v_added := '{}';
      IF v_c.full_name IS NULL AND NULLIF(btrim(COALESCE(v_row ->> 'full_name', '')), '') IS NOT NULL THEN
        v_fields := v_fields || jsonb_build_object('full_name', jsonb_build_object('from', NULL, 'to', btrim(v_row ->> 'full_name')));
      END IF;
      IF v_c.business_name IS NULL AND NULLIF(btrim(COALESCE(v_row ->> 'business_name', '')), '') IS NOT NULL THEN
        v_fields := v_fields || jsonb_build_object('business_name', jsonb_build_object('from', NULL, 'to', btrim(v_row ->> 'business_name')));
      END IF;
      IF v_c.email IS NULL AND NULLIF(btrim(COALESCE(v_row ->> 'email', '')), '') IS NOT NULL THEN
        v_fields := v_fields || jsonb_build_object('email', jsonb_build_object('from', NULL, 'to', btrim(v_row ->> 'email')));
      END IF;
      IF v_fields <> '{}' THEN
        UPDATE contacts SET
          full_name     = COALESCE(full_name, v_fields #>> '{full_name,to}'),
          business_name = COALESCE(business_name, v_fields #>> '{business_name,to}'),
          email         = COALESCE(email, v_fields #>> '{email,to}'),
          updated_at    = now()
         WHERE id = v_target AND organization_id = v_org;
      END IF;
      FOR v_num IN SELECT jsonb_array_elements_text(x -> 'numbers') LOOP
        CONTINUE WHEN EXISTS (SELECT 1 FROM contact_phones cp WHERE cp.organization_id = v_org AND cp.e164 = v_num);
        INSERT INTO contact_phones (organization_id, contact_id, e164, label, is_primary, added_by)
        VALUES (v_org, v_target, v_num, 'mobile',
                NOT EXISTS (SELECT 1 FROM contact_phones cp WHERE cp.contact_id = v_target AND cp.is_primary),
                'contact import');
        v_added := v_added || v_num;
      END LOOP;
      IF v_fields <> '{}' OR cardinality(v_added) > 0 THEN
        PERFORM record_change(v_org, 'contact', v_target, 'updated', 'user', v_actor,
          format('%s added to this contact by importing %s', v_actor, COALESCE(p_filename, 'a contact list')),
          v_user, jsonb_build_object('import_id', v_import, 'row', (x ->> 'row')::int,
                                     'fields', v_fields, 'numbers_added', to_jsonb(v_added),
                                     'held_choice', x ->> 'verdict' = 'held'));
        IF x ->> 'verdict' <> 'held' THEN k_filled := k_filled + 1; END IF;
      ELSIF x ->> 'verdict' <> 'held' THEN
        k_unchanged := k_unchanged + 1;
      END IF;
    END IF;

    -- Which of this row's numbers are now on the target, worked out from
    -- what the commit knows rather than by joining contact_phones again (that
    -- join, under row-level security, was 34 s of a 37 s commit into a
    -- 10,000-contact book: 20261123T1500). A created contact holds all its
    -- row's numbers; a filled or unchanged row matched exactly one contact,
    -- so all its numbers are on it; a picked held row holds the numbers it
    -- added plus any already on the chosen contact, checked by index, not
    -- any left with the other contact.
    FOR v_num IN SELECT jsonb_array_elements_text(x -> 'numbers') LOOP
      IF x ->> 'verdict' = 'held'
         AND NOT v_num = ANY (v_added)
         AND NOT EXISTS (SELECT 1 FROM contact_phones cp WHERE cp.contact_id = v_target AND cp.e164 = v_num) THEN
        CONTINUE;
      END IF;
      v_pair_cid := v_pair_cid || v_target;
      v_pair_num := v_pair_num || v_num;
    END LOOP;
  END LOOP;

  -- Past calls from the imported numbers, linked in one statement: only calls
  -- with no contact at all, never one a person unlinked by hand, and only
  -- numbers that ended up on the contact (a number left with another contact
  -- by a picked row isn't linked to the picked one).
  -- In three steps, none of which the planner can turn into a loop over a
  -- table: as one statement with NOT EXISTS against change_history, it
  -- misjudged the number of calls and scanned change_history once per call
  -- (5.6 s of a 6.2 s commit into a 10,000-contact book), a cost that grows
  -- with every firm's history (20261123T1500).
  -- 1. the candidates: calls from these numbers with no contact at all.
  --    THE TWO array_agg CALLS MUST STAY IN THE SAME ORDER: step 3 unnests
  --    them side by side, so the Nth call is linked to the Nth contact. Both
  --    are fed by this one scan, so they line up. An ORDER BY on one and not
  --    the other, or splitting this into two queries, would link every call
  --    to the wrong person with no error, and the history rows would record
  --    the wrong answer as fact (review of #65).
  EXECUTE $q$
    WITH owned AS (
      SELECT DISTINCT ON (e164) cid, e164 FROM unnest($2::uuid[], $3::text[]) AS t(cid, e164) ORDER BY e164, cid)
    SELECT COALESCE(array_agg(i.id), '{}'), COALESCE(array_agg(o.cid), '{}')
      FROM interactions i JOIN owned o
        ON (CASE WHEN i.direction = 'inbound' THEN i.from_e164 ELSE i.to_e164 END) = o.e164
     WHERE i.organization_id = $1 AND i.contact_id IS NULL
  $q$ INTO v_cand_ids, v_cand_cids USING v_org, v_pair_cid, v_pair_num;
  -- 2. which of them a person unlinked by hand: one indexed lookup
  --    (change_history_entity_idx), never re-linked
  SELECT COALESCE(array_agg(DISTINCT h.entity_id), '{}') INTO v_hand
    FROM change_history h
   WHERE h.entity = 'interaction' AND h.entity_id = ANY (v_cand_ids)
     AND h.action = 'unlinked' AND h.detail ->> 'field' = 'contact_id';
  -- 3. link the rest, by primary key
  FOR v_call, v_target IN EXECUTE $q$
    UPDATE interactions i SET contact_id = c.cid, contact_link_method = 'imported', updated_at = now()
      FROM unnest($1::uuid[], $2::uuid[]) AS c(id, cid)
     WHERE i.id = c.id AND i.organization_id = $4 AND i.contact_id IS NULL AND NOT (c.id = ANY ($3::uuid[]))
    RETURNING i.id, c.cid
  $q$ USING v_cand_ids, v_cand_cids, v_hand, v_org
  LOOP
    PERFORM record_change(v_org, 'interaction', v_call, 'linked', 'user', v_actor,
      format('Linked to a contact by %s''s import of %s', v_actor, COALESCE(p_filename, 'a contact list')),
      v_user, jsonb_build_object('field', 'contact_id', 'contact_id', v_target,
                                 'previous_contact_id', NULL, 'previous_state', 'unlinked',
                                 'import_id', v_import),
      'imported');
    k_calls := k_calls + 1;
  END LOOP;

  PERFORM set_config('hub.contact_import', '1', true);
  INSERT INTO contact_imports (id, organization_id, imported_by, filename, rows_in_file, created, filled,
                               unchanged, held_resolved, held_skipped, refused, calls_linked)
  VALUES (v_import, v_org, v_user, p_filename, jsonb_array_length(p_rows), k_created, k_filled,
          k_unchanged, k_resolved, k_skipped, k_refused, k_calls);
  PERFORM set_config('hub.contact_import', '', true);

  RETURN jsonb_build_object('import_id', v_import, 'created', k_created, 'filled', k_filled,
    'unchanged', k_unchanged, 'held_resolved', k_resolved, 'held_skipped', k_skipped,
    'refused', k_refused, 'calls_linked', k_calls);
END $$;

COMMENT ON FUNCTION contact_import_apply(uuid, uuid, jsonb, text, jsonb) IS
  'The one body of a contact import commit: classifies again (never trusts a '
  'preview), refuses if any contact named is outside the firm, creates, fills '
  'empty fields only, applies a held row only where p_choices names one of its '
  'candidates, links past unlinked calls as imported, and records each change '
  'with the import''s id and the person. One transaction; no undo. Not through '
  'the app: it refuses anon, authenticated and service_role itself '
  '(20261120T2330, 20261123T1500, 20261123T1630).';

-- -----------------------------------------------------------------------------
-- 4. The app's commit becomes a wrapper over the one body, and the app's path
--    is closed
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION commit_contact_import(p_rows jsonb, p_filename text DEFAULT NULL,
                                      p_choices jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  -- The rules live in contact_import_apply, once. Closed to the app since
  -- 20261123T1630 (import is internal only): authenticated has no EXECUTE
  -- here, and contact_import_apply refuses authenticated in any case.
  RETURN contact_import_apply(contact_import_check(p_rows), current_user_id(), p_rows, p_filename, p_choices);
END $$;
COMMENT ON FUNCTION commit_contact_import(jsonb, text, jsonb) IS
  'The app''s import commit, for a firm''s own owners and managers: '
  'contact_import_check, then contact_import_apply for the session''s firm and '
  'user. CLOSED since 20261123T1630: import is internal only, so no API role '
  'may execute it, and contact_import_apply refuses them. Kept so the rules '
  'have one body if import is ever offered to clients again, which would be a '
  'reviewed change, not a grant.';
COMMENT ON FUNCTION contact_import_check(jsonb) IS
  'The app''s import checks: owners and managers only, a list of rows, at most '
  '1,000. CLOSED since 20261123T1630: no API role may execute it, so the 1,000 '
  'is the record of what 20261123T1600 measured as safe through authenticated, '
  'not a live limit. Dead Ringers'' imports use contact_import_for_firm_check '
  '(a 20,000 cap).';
COMMENT ON FUNCTION preview_contact_import(jsonb) IS
  'For a firm''s owners and managers: what importing these rows would do, row '
  'by row, writing nothing. Up to 1,000 rows (20261120T2330, 20261123T1600). '
  'CLOSED since 20261123T1630: import is internal only; Dead Ringers previews '
  'with contact_import_for_firm_preview.';

-- -----------------------------------------------------------------------------
-- 5. The internal entry points
-- -----------------------------------------------------------------------------
CREATE FUNCTION contact_import_for_firm_check(p_firm uuid, p_firm_name text, p_rows jsonb)
RETURNS uuid LANGUAGE plpgsql STABLE AS $$
DECLARE n int;
BEGIN
  IF current_user IN ('anon', 'authenticated', 'service_role') THEN
    RAISE EXCEPTION 'contact import runs in a Dead Ringers database session, not through the app'
      USING ERRCODE = '42501';
  END IF;
  IF p_firm IS NULL OR NULLIF(p_firm_name, '') IS NULL THEN
    RAISE EXCEPTION 'name the firm twice: its id and its name, exactly as the Hub has them';
  END IF;
  -- Both must be the same row. The message doesn't say what the id's name
  -- is: copying it from an error would defeat the check.
  IF NOT EXISTS (SELECT 1 FROM organizations WHERE id = p_firm AND name = p_firm_name) THEN
    RAISE EXCEPTION 'that id and that name are not the same firm: nothing checked, nothing imported'
      USING HINT = 'Look the firm up again: SELECT id, name FROM organizations WHERE name ILIKE ''%part of the name%'';';
  END IF;
  IF jsonb_typeof(p_rows) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'the import needs a list of rows';
  END IF;
  n := jsonb_array_length(p_rows);
  -- The internal cap: measured so the commit at the cap stays well inside the
  -- SQL editor's gateway timeout (about two minutes, separate from
  -- statement_timeout), on production (20261123T1630).
  IF n > 20000 THEN
    RAISE EXCEPTION 'This file has % rows; the limit here is %. Split it into % files and import each.',
      to_char(n, 'FM999,999'), to_char(20000, 'FM999,999'), ceil(n / 20000::numeric);
  END IF;
  RETURN p_firm;
END $$;
COMMENT ON FUNCTION contact_import_for_firm_check(uuid, text, jsonb) IS
  'The checks both internal import entry points make: not an API role, the '
  'firm named by id AND by its exact name (both the same row), a list of rows, '
  'and at most 20,000 of them (20261123T1630).';

CREATE FUNCTION contact_import_for_firm_preview(p_firm uuid, p_firm_name text, p_rows jsonb,
                                                p_all_rows boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE v_org uuid := contact_import_for_firm_check(p_firm, p_firm_name, p_rows); v_rows jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg(x ORDER BY (x ->> 'row')::int), '[]') INTO v_rows
    FROM contact_import_classify(v_org, p_rows) x;
  -- needs_a_look: the rows a person must decide or fix (held, refused, no
  -- number) and fills whose file disagrees with what the firm has (never
  -- overwritten). The rest are creates and quiet fills; p_all_rows shows them.
  RETURN jsonb_build_object(
    'firm', p_firm_name,
    'rows_in_file', jsonb_array_length(p_rows),
    'counts', (SELECT COALESCE(jsonb_object_agg(v, c), '{}') FROM
                (SELECT x ->> 'verdict' AS v, count(*) AS c FROM jsonb_array_elements(v_rows) x GROUP BY 1) t),
    'outside_the_firm', contact_import_outside_firm(v_org, v_rows),
    'needs_a_look', (SELECT COALESCE(jsonb_agg(x ORDER BY (x ->> 'row')::int), '[]') FROM jsonb_array_elements(v_rows) x
                      WHERE x ->> 'verdict' IN ('held', 'refused', 'create_no_number')
                         OR COALESCE(x -> 'differences', '{}') <> '{}'),
    'rows', CASE WHEN p_all_rows THEN v_rows END);
END $$;
COMMENT ON FUNCTION contact_import_for_firm_preview(uuid, text, jsonb, boolean) IS
  'Dead Ringers'' preview of an import into a named firm: counts, the tenant '
  'check (outside_the_firm, which must be null for the commit to run), and the '
  'rows a person must look at. The same classifier as every import; writes '
  'nothing (20261123T1630).';

CREATE FUNCTION contact_import_for_firm_commit(p_firm uuid, p_firm_name text, p_actor_email text,
                                               p_rows jsonb, p_filename text DEFAULT NULL,
                                               p_choices jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_org uuid := contact_import_for_firm_check(p_firm, p_firm_name, p_rows); v_actor uuid;
BEGIN
  SELECT id INTO v_actor FROM users WHERE email = p_actor_email AND is_internal AND active;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'the import must name the Dead Ringers person running it, by their Hub email: % is not an active internal user',
      COALESCE(quote_literal(p_actor_email), 'no email');
  END IF;
  RETURN contact_import_apply(v_org, v_actor, p_rows, p_filename, p_choices)
         || jsonb_build_object('firm', p_firm_name, 'imported_by', p_actor_email);
END $$;
COMMENT ON FUNCTION contact_import_for_firm_commit(uuid, text, text, jsonb, text, jsonb) IS
  'Dead Ringers imports contacts into a named firm, as a named internal person: '
  'contact_import_for_firm_check, then the one commit body, '
  'contact_import_apply. Run in the SQL editor; unreachable through the API '
  '(20261123T1630).';

-- -----------------------------------------------------------------------------
-- 6. Who may execute: no API role, on anything import does
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION contact_import_outside_firm(uuid, jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION contact_import_apply(uuid, uuid, jsonb, text, jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION contact_import_for_firm_check(uuid, text, jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION contact_import_for_firm_preview(uuid, text, jsonb, boolean) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION contact_import_for_firm_commit(uuid, text, text, jsonb, text, jsonb) FROM PUBLIC, anon, authenticated, service_role;
-- The app's path, closed (section 4).
REVOKE ALL ON FUNCTION contact_import_classify(uuid, jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION contact_import_check(jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION preview_contact_import(jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION commit_contact_import(jsonb, text, jsonb) FROM PUBLIC, anon, authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 7. Record it
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261123T1630_contact_import_for_a_firm.sql',
    NULL,
    'Contact import is internal: contact_import_for_firm_preview and _commit '
    'take the firm by id and exact name, and the acting Dead Ringers person by '
    'Hub email; up to 20,000 rows. The commit body is now '
    'contact_import_apply (one body; commit_contact_import wraps it), with its '
    'own tenant check. No API role may execute any import function.');
END $rec$;

COMMIT;

-- =============================================================================
-- Verification — run AFTER the file, as its own statement. One block,
-- everything rolled back by the closing RAISE. AS postgres, in the SQL
-- editor: that is how imports run, and the point is what holds where
-- row-level security doesn't.
--
-- THE FIXTURE. Firm A is the firm being imported into; firm B is another
-- client. B holds the same number as A's Ellen (…01), has its own unlinked
-- call from the number A's file brings (…07), and lists …09 as staff. A Dead
-- Ringers person (Dee), a firm user who isn't internal (Nat), and an internal
-- user who is no longer active (Ivy).
--
-- LINE 6 IS THE SAFETY NET. Before the import it arms a trap: a trigger on
-- each of the five tables the import writes (contacts, contact_phones,
-- interactions, change_history, contact_imports) that raises on any insert,
-- update or delete of a row that isn't firm A's, even one later undone. It
-- also fingerprints every row that isn't firm A's in those tables. Then it
-- imports a file built to tempt the import outside: B's numbers, B's call,
-- B's staff number, and a held row whose choice names B's contact. The line
-- passes only if the trap never fired, the fingerprint didn't move, and the
-- trap is shown to fire on a deliberate write to B (so it isn't asleep).
-- Line 7 adds the one shape the schema allows that leads outside the firm: a
-- phone record of A's attached to B's contact.
--
-- LINE 11 IS THE MEASUREMENT THAT CONFIRMS THE CAP: 20,000 rows into a
-- first-day firm (150 contacts, 300 past calls), commit plus the deferred
-- checks COMMIT would run. Run on production from a quiet database (a few
-- minutes after anything else that wrote in bulk, never straight after
-- another run). The block writes and rolls back about 75,000 rows; leave
-- production a few minutes afterwards too.
--
-- DO $$
-- DECLARE
--   r text := ''; res text; n int; m int; pv jsonb; cm jsonb; rows jsonb; fp_before text; fp_after text;
--   t0 timestamptz; t_pv numeric; t_cm numeric; t_def numeric; ro text; a0 int; a1 int; trap text;
--   v_a uuid; v_b uuid; v_c uuid; u_dee uuid; u_nat uuid; u_ivy uuid;
--   c_ellen uuid; c_x uuid; c_y uuid; c_other uuid; c_ann uuid; c_andy uuid; c_bob uuid;
--   call_open uuid; call_hand uuid; call_conf uuid; call_b uuid;
--   num CONSTANT text := '+1513555090';   -- …01 to …12
--   fns CONSTANT text[] := ARRAY['contact_import_outside_firm(uuid, jsonb)',
--     'contact_import_apply(uuid, uuid, jsonb, text, jsonb)', 'contact_import_for_firm_check(uuid, text, jsonb)',
--     'contact_import_for_firm_preview(uuid, text, jsonb, boolean)',
--     'contact_import_for_firm_commit(uuid, text, text, jsonb, text, jsonb)',
--     'contact_import_classify(uuid, jsonb)', 'contact_import_check(jsonb)', 'preview_contact_import(jsonb)',
--     'commit_contact_import(jsonb, text, jsonb)'];
-- BEGIN
--   PERFORM set_config('app.is_internal', 'on', true);
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ verify firm A', 'funeral_home') RETURNING id INTO v_a;
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ verify firm B', 'funeral_home') RETURNING id INTO v_b;
--   INSERT INTO users (email, full_name, is_internal) VALUES ('zzz-dee@example.invalid', 'ZZZ Dee', true) RETURNING id INTO u_dee;
--   INSERT INTO users (email, full_name, is_internal) VALUES ('zzz-nat@example.invalid', 'ZZZ Nat', false) RETURNING id INTO u_nat;
--   INSERT INTO users (email, full_name, is_internal, active) VALUES ('zzz-ivy@example.invalid', 'ZZZ Ivy', true, false) RETURNING id INTO u_ivy;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_a, 'Ellen Park') RETURNING id INTO c_ellen;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_a, 'Xavier') RETURNING id INTO c_x;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_a, 'Yvonne') RETURNING id INTO c_y;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_a, 'Someone else') RETURNING id INTO c_other;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_a, 'Ann') RETURNING id INTO c_ann;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_a, 'Andy') RETURNING id INTO c_andy;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_b, 'Bob at firm B') RETURNING id INTO c_bob;
--   INSERT INTO contact_phones (organization_id, contact_id, e164, is_primary) VALUES
--     (v_a, c_ellen, num || '1', true), (v_a, c_x, num || '2', true), (v_a, c_y, num || '3', true),
--     (v_a, c_ann, '+15135550911', true), (v_a, c_andy, '+15135550912', true),
--     (v_b, c_bob, num || '1', true), (v_b, c_bob, num || '7', false);
--   INSERT INTO directory_entries (organization_id, entry_kind, label, e164) VALUES (v_b, 'staff', 'ZZZ B director cell', num || '9');
--   INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at, from_e164)
--   VALUES (v_a, 'inbound', now() - interval '3 days', now() - interval '3 days', num || '7') RETURNING id INTO call_open;
--   INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at, from_e164)
--   VALUES (v_a, 'inbound', now() - interval '2 days', now() - interval '2 days', num || '7') RETURNING id INTO call_hand;
--   INSERT INTO change_history (organization_id, entity, entity_id, action, actor_kind, actor_user_id, actor_label, summary, detail)
--   VALUES (v_a, 'interaction', call_hand, 'unlinked', 'user', u_dee, 'ZZZ', 'took someone off this call', jsonb_build_object('field', 'contact_id'));
--   INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at, from_e164, contact_id, contact_link_method)
--   VALUES (v_a, 'inbound', now() - interval '1 day', now() - interval '1 day', num || '7', c_other, 'confirmed') RETURNING id INTO call_conf;
--   INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at, from_e164)
--   VALUES (v_b, 'inbound', now() - interval '3 days', now() - interval '3 days', num || '7') RETURNING id INTO call_b;
--   PERFORM set_config('app.is_internal', 'off', true);
--
--   -- the file: Ellen's number with an email (fill A's Ellen; B's Bob holds
--   -- …01 too), Xavier's and Yvonne's numbers on one row (held; picked onto
--   -- Xavier), a new caller on …07 (create; A's unlinked call links, B's
--   -- doesn't), B's staff number …09 (an ordinary new number at A), and Ann's
--   -- and Andy's numbers on one row (held), whose choice names B's Bob
--   rows := jsonb_build_array(
--     jsonb_build_object('full_name', 'Ellen Parker', 'email', 'ellen@example.invalid', 'phones', jsonb_build_array(jsonb_build_object('number', num || '1'))),
--     jsonb_build_object('full_name', 'Xavier', 'phones', jsonb_build_array(jsonb_build_object('number', num || '2'), jsonb_build_object('number', num || '3'))),
--     jsonb_build_object('full_name', 'New Caller', 'phones', jsonb_build_array(jsonb_build_object('number', num || '7'))),
--     jsonb_build_object('full_name', 'Not B''s staff here', 'phones', jsonb_build_array(jsonb_build_object('number', num || '9'))),
--     jsonb_build_object('full_name', 'Ann or Andy', 'phones', jsonb_build_array(jsonb_build_object('number', '+15135550911'), jsonb_build_object('number', '+15135550912'))));
--
--   -- ---- 1. nothing import does is reachable through the API ---------------
--   SELECT count(*) FILTER (WHERE has_function_privilege(api.rolname, f, 'EXECUTE')), count(*)
--     INTO n, m FROM unnest(fns) f, unnest(ARRAY['anon', 'authenticated', 'service_role']) api(rolname);
--   r := r || '1. API roles that may execute an import function: ' || n || ' of ' || m
--          || '; postgres may run all ' || (SELECT count(*) FROM unnest(fns) f WHERE has_function_privilege('postgres', f, 'EXECUTE'))
--          || chr(10) || '   (expect 0 of 27; postgres may run all 9)' || chr(10);
--
--   -- ---- 2. the lock holds even if a grant is added by mistake -------------
--   -- Grant everything to the role, become it, try: the functions refuse on
--   -- current_user, which an API caller can't choose. The grant is undone with
--   -- the attempt.
--   res := '';
--   FOREACH ro IN ARRAY ARRAY['authenticated', 'service_role'] LOOP
--     BEGIN
--       EXECUTE format('GRANT EXECUTE ON FUNCTION contact_import_for_firm_commit(uuid, text, text, jsonb, text, jsonb), '
--                      'contact_import_for_firm_check(uuid, text, jsonb), contact_import_apply(uuid, uuid, jsonb, text, jsonb), '
--                      'contact_import_classify(uuid, jsonb), contact_import_outside_firm(uuid, jsonb) TO %I', ro);
--       PERFORM set_config('role', ro, true);
--       PERFORM contact_import_for_firm_commit(v_a, 'ZZZ verify firm A', 'zzz-dee@example.invalid', rows);
--       res := res || ro || ': ALLOWED; ';
--       RAISE EXCEPTION USING ERRCODE = 'ZZ001';
--     EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
--               WHEN OTHERS THEN res := res || ro || ': ' || SQLSTATE || ' ' || SQLERRM || '; ';
--     END;
--   END LOOP;
--   r := r || '2. granted and called as an API role: ' || res || chr(10)
--          || '   (expect 42501 "contact import runs in a Dead Ringers database session, not through the app" for both)' || chr(10);
--
--   -- ---- 3. the firm, named twice ---------------------------------------------
--   res := '';
--   FOR ro, pv IN VALUES ('A''s id, B''s name', jsonb_build_object('id', v_a, 'name', 'ZZZ verify firm B')),
--                        ('B''s id, A''s name', jsonb_build_object('id', v_b, 'name', 'ZZZ verify firm A')),
--                        ('A''s id, A''s name with a trailing space', jsonb_build_object('id', v_a, 'name', 'ZZZ verify firm A ')),
--                        ('A''s id, A''s name in lower case', jsonb_build_object('id', v_a, 'name', 'zzz verify firm a')),
--                        ('A''s id, no name', jsonb_build_object('id', v_a, 'name', NULL)) LOOP
--     BEGIN PERFORM contact_import_for_firm_preview((pv ->> 'id')::uuid, pv ->> 'name', rows); res := res || ro || ': ALLOWED | ';
--     EXCEPTION WHEN OTHERS THEN res := res || ro || ': ' || SQLERRM || ' | '; END;
--   END LOOP;
--   r := r || '3. ' || res || chr(10)
--          || '   (expect each refused: "that id and that name are not the same firm: nothing checked, nothing imported", '
--          || 'and the last "name the firm twice…")' || chr(10);
--
--   -- ---- 4. the person, named and internal ---------------------------------
--   SELECT count(*) INTO a0 FROM contacts WHERE organization_id = v_a;
--   res := '';
--   FOR ro IN VALUES (NULL), ('zzz-nat@example.invalid'), ('zzz-ivy@example.invalid'), ('nobody@example.invalid') LOOP
--     BEGIN PERFORM contact_import_for_firm_commit(v_a, 'ZZZ verify firm A', ro, rows); res := res || COALESCE(ro, 'no email') || ': ALLOWED | ';
--     EXCEPTION WHEN OTHERS THEN res := res || COALESCE(ro, 'no email') || ': refused | '; END;
--   END LOOP;
--   SELECT count(*) INTO a1 FROM contacts WHERE organization_id = v_a;
--   r := r || '4. ' || res || 'contacts at A ' || a0 || ' before, ' || a1 || ' after' || chr(10)
--          || '   (expect all four refused: no email, not internal (Nat), not active (Ivy), unknown; contacts equal)' || chr(10);
--
--   -- ---- 5. the preview ------------------------------------------------------
--   pv := contact_import_for_firm_preview(v_a, 'ZZZ verify firm A', rows);
--   r := r || '5. preview: counts ' || (pv -> 'counts')::text || '; outside_the_firm ' || COALESCE(pv ->> 'outside_the_firm', 'null')
--          || '; needs_a_look rows ' || (SELECT string_agg(x ->> 'row', ', ' ORDER BY (x ->> 'row')::int) FROM jsonb_array_elements(pv -> 'needs_a_look') x)
--          || '; rows ' || COALESCE(pv ->> 'rows', 'not shown') || '; wrote nothing: '
--          || ((SELECT count(*) FROM contacts WHERE organization_id = v_a) = a0) || chr(10)
--          || '   (expect fill 1, held 2, create 2; null; 1, 2, 5 (Ellen''s name differs, and the two held); not shown; true)' || chr(10);
--
--   -- ---- 6. THE BOUNDARY: it cannot write outside the named firm --------------
--   BEGIN
--     EXECUTE $trap$
--       CREATE FUNCTION zzz_import_trap() RETURNS trigger LANGUAGE plpgsql AS $f$
--       DECLARE v_firm text := NULLIF(current_setting('zzz.firm', true), '');
--       BEGIN
--         IF v_firm IS NOT NULL AND (
--              (TG_OP <> 'DELETE' AND NEW.organization_id::text IS DISTINCT FROM v_firm)
--           OR (TG_OP <> 'INSERT' AND OLD.organization_id::text IS DISTINCT FROM v_firm)) THEN
--           RAISE EXCEPTION 'TRAP: % on % at another firm', TG_OP, TG_TABLE_NAME USING ERRCODE = 'ZZ002';
--         END IF;
--         RETURN COALESCE(NEW, OLD);
--       END $f$
--     $trap$;
--     FOREACH ro IN ARRAY ARRAY['contacts', 'contact_phones', 'interactions', 'change_history', 'contact_imports'] LOOP
--       EXECUTE format('CREATE TRIGGER zzz_import_trap BEFORE INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION zzz_import_trap()', ro);
--     END LOOP;
--     trap := 'armed';
--   EXCEPTION WHEN OTHERS THEN trap := 'NOT ARMED: ' || SQLERRM;
--   END;
--   SELECT md5(string_agg(t, '|' ORDER BY t)) INTO fp_before FROM (
--     SELECT 'c' || c::text AS t FROM contacts c WHERE organization_id IS DISTINCT FROM v_a
--     UNION ALL SELECT 'p' || p::text FROM contact_phones p WHERE organization_id IS DISTINCT FROM v_a
--     UNION ALL SELECT 'i' || i::text FROM interactions i WHERE organization_id IS DISTINCT FROM v_a
--     UNION ALL SELECT 'h' || h::text FROM change_history h WHERE organization_id IS DISTINCT FROM v_a
--     UNION ALL SELECT 'm' || ci::text FROM contact_imports ci WHERE organization_id IS DISTINCT FROM v_a) s;
--   PERFORM set_config('zzz.firm', v_a::text, true);
--   BEGIN
--     cm := contact_import_for_firm_commit(v_a, 'ZZZ verify firm A', 'zzz-dee@example.invalid', rows, 'zzz-tempt.csv',
--                                          jsonb_build_object('2', c_x::text, '5', c_bob::text));
--     res := 'committed';
--   EXCEPTION WHEN OTHERS THEN res := SQLSTATE || ' ' || SQLERRM;
--   END;
--   PERFORM set_config('zzz.firm', '', true);
--   SELECT md5(string_agg(t, '|' ORDER BY t)) INTO fp_after FROM (
--     SELECT 'c' || c::text AS t FROM contacts c WHERE organization_id IS DISTINCT FROM v_a
--     UNION ALL SELECT 'p' || p::text FROM contact_phones p WHERE organization_id IS DISTINCT FROM v_a
--     UNION ALL SELECT 'i' || i::text FROM interactions i WHERE organization_id IS DISTINCT FROM v_a
--     UNION ALL SELECT 'h' || h::text FROM change_history h WHERE organization_id IS DISTINCT FROM v_a
--     UNION ALL SELECT 'm' || ci::text FROM contact_imports ci WHERE organization_id IS DISTINCT FROM v_a) s;
--   -- the trap is awake: a deliberate write to B, armed, must be caught
--   PERFORM set_config('zzz.firm', v_a::text, true);
--   BEGIN UPDATE contacts SET email = 'caught@example.invalid' WHERE id = c_bob; ro := 'NOT CAUGHT';
--   EXCEPTION WHEN SQLSTATE 'ZZ002' THEN ro := 'caught'; WHEN OTHERS THEN ro := SQLERRM; END;
--   PERFORM set_config('zzz.firm', '', true);
--   r := r || '6. trap ' || trap || '; the tempting import: ' || res
--          || ' (created ' || COALESCE(cm ->> 'created', '-') || ', filled ' || COALESCE(cm ->> 'filled', '-')
--          || ', held resolved ' || COALESCE(cm ->> 'held_resolved', '-') || ', held skipped ' || COALESCE(cm ->> 'held_skipped', '-')
--          || ', calls linked ' || COALESCE(cm ->> 'calls_linked', '-') || ')'
--          || '; everything not at A unchanged: ' || (fp_before = fp_after)
--          || '; a deliberate write to B under the trap: ' || ro
--          || '; B''s Bob untouched: ' || ((SELECT email FROM contacts WHERE id = c_bob) IS NULL)
--          || ', B''s call still unlinked: ' || ((SELECT contact_id FROM interactions WHERE id = call_b) IS NULL)
--          || ', Ann and Andy still apart: ' || (SELECT count(DISTINCT contact_id) = 2 FROM contact_phones WHERE e164 IN ('+15135550911', '+15135550912'))
--          || chr(10) || '   (expect armed; committed (created 2, filled 1, held resolved 1, held skipped 1, calls linked 1); '
--          || 'true; caught; true, true, true. ANY TRAP IN THIS LINE IS A FAILURE OF THE FILE. If only the fingerprint '
--          || 'differs, check whether something else wrote at the same time: the trap is the decisive half)' || chr(10);
--
--   -- ---- 7. a phone record of A's on B's contact: refused before any write ----
--   -- The schema allows it (contact_phones has no rule that its contact is at
--   -- its firm). Under the app's row-level security it was invisible; here it
--   -- would hand B's contact to A's import.
--   PERFORM set_config('app.is_internal', 'on', true);
--   INSERT INTO contact_phones (organization_id, contact_id, e164, is_primary) VALUES (v_a, c_bob, num || '5', false);
--   PERFORM set_config('app.is_internal', 'off', true);
--   SELECT count(*) INTO a0 FROM contacts WHERE organization_id = v_a;
--   res := '';
--   FOR ro, rows IN VALUES
--       ('alone', jsonb_build_array(jsonb_build_object('full_name', 'Five', 'email', 'five@example.invalid',
--                                                      'phones', jsonb_build_array(jsonb_build_object('number', num || '5'))))),
--       ('as one of two candidates', jsonb_build_array(jsonb_build_object('full_name', 'Five or Ellen',
--                                                      'phones', jsonb_build_array(jsonb_build_object('number', num || '5'), jsonb_build_object('number', num || '1'))))) LOOP
--     pv := contact_import_for_firm_preview(v_a, 'ZZZ verify firm A', rows);
--     PERFORM set_config('zzz.firm', v_a::text, true);
--     BEGIN PERFORM contact_import_for_firm_commit(v_a, 'ZZZ verify firm A', 'zzz-dee@example.invalid', rows, 'zzz-five.csv',
--                                                  jsonb_build_object('1', c_bob::text));
--       res := res || ro || ': ALLOWED | ';
--     EXCEPTION WHEN OTHERS THEN res := res || ro || ': preview says "' || COALESCE(pv ->> 'outside_the_firm', 'nothing') || '"; commit: ' || SQLERRM || ' | ';
--     END;
--     PERFORM set_config('zzz.firm', '', true);
--   END LOOP;
--   r := r || '7. ' || res || 'Bob''s email still empty: ' || ((SELECT email FROM contacts WHERE id = c_bob) IS NULL)
--          || '; contacts at A ' || a0 || ' before, ' || (SELECT count(*) FROM contacts WHERE organization_id = v_a) || ' after' || chr(10)
--          || '   (expect both refused, preview and commit naming row 1, "nothing imported: row 1: a number this firm holds is on a '
--          || 'phone record attached to a contact at another firm…", no TRAP; true; equal)' || chr(10);
--
--   -- ---- 8. the record says who and where ------------------------------------
--   r := r || '8. the import record: firm A ' || ((SELECT organization_id FROM contact_imports WHERE id = (cm ->> 'import_id')::uuid) = v_a)
--          || ', imported_by Dee ' || ((SELECT imported_by FROM contact_imports WHERE id = (cm ->> 'import_id')::uuid) = u_dee)
--          || '; its history rows: ' || (SELECT count(*) FROM change_history WHERE detail ->> 'import_id' = cm ->> 'import_id')
--          || ', all by Dee: ' || (SELECT bool_and(actor_user_id = u_dee AND actor_label = 'ZZZ Dee' AND organization_id = v_a)
--                                   FROM change_history WHERE detail ->> 'import_id' = cm ->> 'import_id')
--          || '; calls from …07: A''s open one ' || COALESCE((SELECT contact_link_method::text FROM interactions WHERE id = call_open), 'unlinked')
--          || ', the hand-unlinked one ' || COALESCE((SELECT contact_id::text FROM interactions WHERE id = call_hand), 'still unlinked')
--          || ', the confirmed one still on Someone else ' || ((SELECT contact_id FROM interactions WHERE id = call_conf) = c_other)
--          || '; Ellen filled, name kept: ' || (SELECT full_name || ' / ' || email FROM contacts WHERE id = c_ellen) || chr(10)
--          || '   (expect true, true; 4 (2 created, 1 filled, 1 call: the row picked onto Xavier added nothing to him), true; '
--          || 'imported, still unlinked, true; '
--          || 'Ellen Park / ellen@example.invalid)' || chr(10);
--
--   -- ---- 9. one body ---------------------------------------------------------
--   r := r || '9. commit_contact_import calls contact_import_apply and writes nothing itself: '
--          || (SELECT prosrc ~ 'contact_import_apply\(' AND prosrc !~* '(INSERT|UPDATE|DELETE)\s' FROM pg_proc WHERE oid = to_regprocedure('commit_contact_import(jsonb, text, jsonb)'))
--          || '; so does contact_import_for_firm_commit: '
--          || (SELECT prosrc ~ 'contact_import_apply\(' AND prosrc !~* '(INSERT|UPDATE|DELETE)\s' FROM pg_proc WHERE oid = to_regprocedure('contact_import_for_firm_commit(uuid, text, text, jsonb, text, jsonb)'))
--          || '; both previews classify with contact_import_classify: '
--          || (SELECT bool_and(prosrc ~ 'contact_import_classify\(') FROM pg_proc
--               WHERE oid IN (to_regprocedure('preview_contact_import(jsonb)'), to_regprocedure('contact_import_for_firm_preview(uuid, text, jsonb, boolean)')))
--          || chr(10) || '   (expect true; true; true)' || chr(10);
--
--   -- ---- 10. the cap ---------------------------------------------------------
--   BEGIN PERFORM contact_import_for_firm_preview(v_a, 'ZZZ verify firm A',
--           (SELECT jsonb_agg(jsonb_build_object('full_name', 'x')) FROM generate_series(1, 20000 + 1))); res := 'ALLOWED';
--   EXCEPTION WHEN OTHERS THEN res := SQLERRM; END;
--   r := r || '10. ' || to_char(20000 + 1, 'FM999,999') || ' rows: ' || res || chr(10)
--          || '   (expect "This file has ' || to_char(20000 + 1, 'FM999,999') || ' rows; the limit here is '
--          || to_char(20000, 'FM999,999') || '. Split it into 2 files and import each.")' || chr(10);
--
--   -- ---- 11. a file at the cap, into a first-day firm, timed ------------------
--   PERFORM set_config('app.is_internal', 'on', true);
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ verify firm C', 'funeral_home') RETURNING id INTO v_c;
--   INSERT INTO contacts (organization_id, full_name) SELECT v_c, 'Learned ' || g FROM generate_series(1, 150) g;
--   INSERT INTO contact_phones (organization_id, contact_id, e164, is_primary)
--     SELECT v_c, c.id, '+1513' || lpad((2000000 + substr(c.full_name, 9)::int)::text, 7, '0'), true
--       FROM contacts c WHERE c.organization_id = v_c;
--   INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at, from_e164)
--     SELECT v_c, 'inbound', now() - (g || ' hours')::interval, now() - (g || ' hours')::interval,
--            '+1513' || lpad((2000000 + g * 3)::text, 7, '0') FROM generate_series(1, 300) g;
--   PERFORM set_config('app.is_internal', 'off', true);
--   SELECT jsonb_agg(jsonb_build_object('full_name', 'Person ' || g,
--            'email', CASE WHEN g % 4 = 0 THEN 'p' || g || '@example.invalid' END,
--            'phones', jsonb_build_array(jsonb_build_object('number', '+1513' || lpad((2000000 + g)::text, 7, '0')))
--                      || CASE WHEN g % 3 = 0 THEN jsonb_build_array(jsonb_build_object('number', '+1859' || lpad((3000000 + g)::text, 7, '0'))) ELSE '[]' END)
--          ORDER BY g) INTO rows FROM generate_series(1, 20000) g;
--   t0 := clock_timestamp(); pv := contact_import_for_firm_preview(v_c, 'ZZZ verify firm C', rows); t_pv := extract(epoch FROM clock_timestamp() - t0);
--   t0 := clock_timestamp(); cm := contact_import_for_firm_commit(v_c, 'ZZZ verify firm C', 'zzz-dee@example.invalid', rows, 'zzz-cap.csv');
--   t_cm := extract(epoch FROM clock_timestamp() - t0);
--   t0 := clock_timestamp(); SET CONSTRAINTS ALL IMMEDIATE; t_def := extract(epoch FROM clock_timestamp() - t0);
--   r := r || '11. ' || to_char(20000, 'FM999,999') || ' rows into a first-day firm: preview ' || to_char(t_pv, 'FM990.00')
--          || ' s, commit ' || to_char(t_cm, 'FM990.00') || ' s, the checks COMMIT runs ' || to_char(t_def, 'FM990.00')
--          || ' s; created ' || (cm ->> 'created') || ', calls linked ' || (cm ->> 'calls_linked')
--          || '; this session''s statement_timeout ' || current_setting('statement_timeout')
--          || CASE WHEN t_cm + t_def <= 30 THEN '; within a quarter of a two-minute gateway' ELSE '; OVER A QUARTER OF A TWO-MINUTE GATEWAY' END
--          || chr(10) || '   (expect created ' || to_char(20000 - 150, 'FM999,999') || ', calls linked 300, "within a quarter" ON PRODUCTION, '
--          || 'about 16-18 s predicted from scratch''s 7.1 s; ruled on that reading)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261123T1630_contact_import_for_a_firm (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
