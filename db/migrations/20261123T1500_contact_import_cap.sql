-- =============================================================================
-- 20261123T1500_contact_import_cap.sql
-- The Hub — a contact import is capped at what the database can commit well
-- inside the statement timeout.
--
-- DRAFT: THE CAP IS NOT SET. Every place it goes reads __CAP__, which isn't
-- SQL, so this file cannot run until the number is in. The number comes from
-- db/measurements/contact_import_timing_*.sql, one size per run, on STAGING
-- after the compute upgrade, from a quiet database (Mandie's ruling, 23
-- November). Those files measure the commit as section 3 below leaves it.
--
-- WHY. 20261120T2330 promised 5,000 rows. On staging its 5,000-row commit took
-- 8.07 s, and 8.25 s on production, against authenticated's 8 s
-- statement_timeout: through the app, a 5,000-row import would time out every
-- time. Scratch had said 3.6 s. Both databases are Micro (1 GB, shared CPU),
-- whose disk IO budget depletes under sustained writes; three timing runs on
-- staging went fast, slower, stalled.
--
-- THE RULING (23 November):
--   * the cap is set from a STAGING measurement, never scratch;
--   * the commit at the cap lands at about A THIRD of the timeout, not just
--     under it: a firm's second import runs against a bigger book, and
--     production is slower than staging;
--   * ONE TRANSACTION, KEPT. No chunking into several calls to keep a higher
--     cap: atomicity is why there is no undo, and a half-finished import with
--     no undo is a worse trade than a smaller cap;
--   * the refusal already tells a firm to split the file, so a lower cap needs
--     no new screen. One wording change: at a lower cap a file may need more
--     than two parts, so the message now says how many.
--
-- A NEW FILE, NOT AN EDIT TO 2330. Both databases ran 2330 and recorded the
-- same md5. Amending it would leave them running different code under one
-- filename, which is what the ledger exists to prevent.
--
-- WHAT CHANGES: contact_import_check's body (the cap and the message),
-- preview_contact_import's comment (it named 5,000), and, A SCOPE CHANGE
-- FLAGGED FOR REVIEW, commit_contact_import's body. The classifier is as 2330
-- left it.
--
-- WHY THE COMMIT TOO. Splitting the timing block by size showed the commit's
-- cost growing with the firm's book, not the file: on scratch, 2,000 rows into
-- a 10,000-contact book took 6.35 s, 3,000 rows 9.62 s. Two places, both in how
-- the commit links past calls:
--   * it joined contact_phones again to learn which of a row's numbers ended
--     up on the row's contact; under row-level security that join scanned the
--     book per pair. The commit already knows the answer: a created contact
--     holds all its row's numbers, a filled or unchanged row matched exactly
--     one contact, and a picked held row holds what it added plus any number
--     already on the chosen contact (checked by index, one row at a time);
--   * the link UPDATE's "never a call a person unlinked by hand" was a NOT
--     EXISTS against change_history, which the planner ran as a scan of
--     change_history per call: 280 calls x 21 ms = 5.6 s of a 6.2 s commit,
--     and a cost that grows with every firm's history. Now three statements:
--     the candidate calls, the hand-unlinked ones among them (one indexed
--     lookup, change_history_entity_idx), then the UPDATE by primary key.
-- Same results: 2330's verification, all 28 lines, passes with this body on
-- scratch; lines 4 to 6 below re-check the link rules. After: 2,000 into
-- 10,000 0.73 s, 3,000 into 10,000 1.09 s, 5,000 into 150 2.16 s (scratch,
-- which reads fast: the cap still comes from staging). Also: v_added, the
-- numbers a held row added, is now reset for each row; before, it carried
-- over, harmlessly, because nothing read it for linking.
--
-- AND IN THE VERIFICATION, 2330's line 28 replaced. It used
-- session_replication_role, which needs a superuser; on Supabase it aborted
-- the whole block. The replacement uses ALTER TABLE contacts DISABLE TRIGGER,
-- which needs only ownership of the table for a user trigger, and it catches
-- its own failure: where it can't run, it prints "not runnable here" and the
-- rest of the report survives. While it holds, other WRITES to contacts wait
-- until the block rolls back (reads don't): a few seconds.
--
-- Requires: 20261120T2330 (contact_import_check and commit_contact_import, as
--           reviewed),
--           20261103T1200 (record_migration).
-- NOT SAFE TO RUN TWICE: section 1 refuses once the body has changed.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Preconditions: 2330 ran here, and both functions are its bodies
-- -----------------------------------------------------------------------------
DO $$
DECLARE v text;
BEGIN
  -- In PL/pgSQL an unset __CAP__ would parse as a variable name and fail only
  -- when called, which is worse than not running. So the file refuses here
  -- until the number is written in.
  IF '__CAP__' !~ '^[0-9]+$' THEN
    RAISE EXCEPTION 'DRAFT: the cap is not set; write the staging-measured number in place of every __CAP__ first';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM schema_migrations WHERE filename = '20261120T2330_contact_import.sql') THEN
    RAISE EXCEPTION '20261120T2330 has not run here; run it first';
  END IF;
  SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = to_regprocedure('contact_import_check(jsonb)');
  IF v IS DISTINCT FROM '659d417408f6971d666fc86bc9cae296' THEN
    RAISE EXCEPTION 'contact_import_check is not 20261120T2330''s body (md5 %); already converted, or changed: stop and read it',
      COALESCE(v, 'missing');
  END IF;
  SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = to_regprocedure('commit_contact_import(jsonb, text, jsonb)');
  IF v IS DISTINCT FROM '85c13bfe91a655f4f198c572934ebb72' THEN
    RAISE EXCEPTION 'commit_contact_import is not 20261120T2330''s body (md5 %); already converted, or changed: stop and read it',
      COALESCE(v, 'missing');
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. The cap
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION contact_import_check(p_rows jsonb)
RETURNS uuid LANGUAGE plpgsql STABLE AS $$
DECLARE v_org uuid := current_organization_id(); n int;
BEGIN
  IF v_org IS NULL OR NOT can_manage_settings() THEN
    RAISE EXCEPTION 'importing contacts is for your firm''s owners and managers' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p_rows) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'the import needs a list of rows';
  END IF;
  n := jsonb_array_length(p_rows);
  -- The cap: measured on staging so the commit lands at about a third of
  -- authenticated's statement_timeout (20261123T1500). One transaction, kept.
  IF n > __CAP__ THEN
    RAISE EXCEPTION 'This file has % rows; the limit is %. Split it into % files and import each.',
      to_char(n, 'FM999,999'), to_char(__CAP__, 'FM999,999'), ceil(n / __CAP__::numeric);
  END IF;
  RETURN v_org;
END $$;

COMMENT ON FUNCTION contact_import_check(jsonb) IS
  'The checks both import entry points make, once: owners and managers only, a '
  'list of rows, and at most __CAP__ of them, a figure measured on staging so '
  'the commit lands at about a third of the statement timeout (20261123T1500).';
COMMENT ON FUNCTION preview_contact_import(jsonb) IS
  'For a firm''s owners and managers: what importing these rows would do, row '
  'by row, writing nothing. Held rows carry the contacts a person may pick '
  'between. Up to __CAP__ rows (20261120T2330, 20261123T1500).';

-- -----------------------------------------------------------------------------
-- 3. The commit, linking past calls without a scan per call. Signature,
--    grants and comment are unchanged (OR REPLACE keeps them); the body is
--    2330's but for the two places named in the header.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION commit_contact_import(p_rows jsonb, p_filename text DEFAULT NULL,
                                      p_choices jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_org uuid := contact_import_check(p_rows);
  v_import uuid := gen_random_uuid();
  v_user uuid := current_user_id(); v_actor text;
  x jsonb; v_row jsonb; v_target uuid; v_choice text; v_c record;
  v_fields jsonb; v_added text[]; v_num text; v_label phone_label; i int; v_call uuid;
  k_created int := 0; k_filled int := 0; k_unchanged int := 0; k_resolved int := 0;
  k_skipped int := 0; k_refused int := 0; k_calls int := 0;
  -- Parallel arrays, appended in place (a jsonb || per row would copy the
  -- whole value each time, which is N squared again).
  v_pair_cid uuid[] := '{}'; v_pair_num text[] := '{}';
  v_cand_ids uuid[]; v_cand_cids uuid[]; v_hand uuid[];
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'your sign-in isn''t linked to a Hub user, so the import can''t say who did it';
  END IF;
  SELECT full_name INTO v_actor FROM users WHERE id = v_user;
  v_actor := COALESCE(v_actor, 'Someone');

  FOR x IN SELECT y FROM contact_import_classify(v_org, p_rows) y ORDER BY (y ->> 'row')::int LOOP
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
      SELECT * INTO v_c FROM contacts WHERE id = v_target FOR UPDATE;
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
         WHERE id = v_target;
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
  -- 1. the candidates: calls from these numbers with no contact at all
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
     WHERE i.id = c.id AND i.contact_id IS NULL AND NOT (c.id = ANY ($3::uuid[]))
    RETURNING i.id, c.cid
  $q$ USING v_cand_ids, v_cand_cids, v_hand
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

-- -----------------------------------------------------------------------------
-- 4. Record it
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261123T1500_contact_import_cap.sql',
    NULL,
    'Contact import capped at __CAP__ rows (was 5,000, which took 8 s on staging '
    'against an 8 s timeout), measured on staging to land at about a third of '
    'the timeout; one transaction kept. The refusal says how many files. The '
    'commit links past calls without a scan per call (same rules).');
END $rec$;

COMMIT;

-- =============================================================================
-- Verification — run AFTER the file, as its own statement. One block,
-- everything rolled back by the closing RAISE. As authenticated, a fixture
-- manager at a fixture firm.
--
-- DO $$
-- DECLARE
--   r text := ''; res text; t0 timestamptz; t_pv numeric; t_cm numeric; tmo text; tmo_s numeric;
--   rows jsonb; pv jsonb; cm jsonb;
--   v_org uuid; u_mo uuid; a_mo uuid := gen_random_uuid(); c_a uuid; c_b uuid; c_c uuid;
--   c_x uuid; c_y uuid; c_other uuid; call_open uuid; call_hand uuid; call_conf uuid; call_out uuid; call_y uuid;
-- BEGIN
--   PERFORM set_config('app.is_internal', 'on', true);
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ verify cap', 'funeral_home') RETURNING id INTO v_org;
--   INSERT INTO users (email, full_name, auth_user_id) VALUES ('zzz-cap@example.invalid', 'ZZZ Mo', a_mo) RETURNING id INTO u_mo;
--   INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id) VALUES (u_mo, 'organization', 'manager', v_org);
--   INSERT INTO contacts (organization_id, full_name) SELECT v_org, 'Learned ' || g FROM generate_series(1, 150) g;
--   INSERT INTO contact_phones (organization_id, contact_id, e164, is_primary)
--     SELECT v_org, c.id, '+1513' || lpad((2000000 + substr(c.full_name, 9)::int)::text, 7, '0'), true
--       FROM contacts c WHERE c.organization_id = v_org;
--   -- for lines 4 to 6: Xavier (…9032) and Yvonne (…9033) apart; five calls
--   -- with no contact: two from a new number …9031 (one a person unlinked by
--   -- hand), one TO …9031 (outbound), one from Yvonne's …9033; and one from
--   -- …9031 already confirmed to someone else
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'Xavier') RETURNING id INTO c_x;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'Yvonne') RETURNING id INTO c_y;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'Someone else') RETURNING id INTO c_other;
--   INSERT INTO contact_phones (organization_id, contact_id, e164, is_primary) VALUES
--     (v_org, c_x, '+15135559032', true), (v_org, c_y, '+15135559033', true);
--   INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at, from_e164)
--   VALUES (v_org, 'inbound', now() - interval '3 days', now() - interval '3 days', '+15135559031') RETURNING id INTO call_open;
--   INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at, from_e164)
--   VALUES (v_org, 'inbound', now() - interval '2 days', now() - interval '2 days', '+15135559031') RETURNING id INTO call_hand;
--   INSERT INTO change_history (organization_id, entity, entity_id, action, actor_kind, actor_user_id, actor_label, summary, detail)
--   VALUES (v_org, 'interaction', call_hand, 'unlinked', 'user', u_mo, 'ZZZ', 'took someone off this call', jsonb_build_object('field', 'contact_id'));
--   INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at, to_e164)
--   VALUES (v_org, 'outbound', now() - interval '2 days', now() - interval '2 days', '+15135559031') RETURNING id INTO call_out;
--   INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at, from_e164)
--   VALUES (v_org, 'inbound', now() - interval '2 days', now() - interval '2 days', '+15135559033') RETURNING id INTO call_y;
--   INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at, from_e164, contact_id, contact_link_method)
--   VALUES (v_org, 'inbound', now() - interval '1 day', now() - interval '1 day', '+15135559031', c_other, 'confirmed') RETURNING id INTO call_conf;
--   PERFORM set_config('app.is_internal', 'off', true);
--   PERFORM set_config('request.jwt.claims', json_build_object('sub', a_mo::text)::text, true);
--   PERFORM set_config('role', 'authenticated', true);
--
--   -- ---- 1-2. the cap, and the refusal above it ----------------------------
--   r := r || '1. the cap in contact_import_check: '
--          || (SELECT substring(prosrc FROM 'n > ([0-9]+)') FROM pg_proc WHERE proname = 'contact_import_check')
--          || '   (expect __CAP__)' || chr(10);
--   BEGIN PERFORM preview_contact_import((SELECT jsonb_agg(jsonb_build_object('full_name', 'x')) FROM generate_series(1, 5000)));
--     res := 'ALLOWED';
--   EXCEPTION WHEN OTHERS THEN res := SQLERRM; END;
--   r := r || '2. 5,000 rows: ' || res || chr(10)
--          || '   (expect "This file has 5,000 rows; the limit is ' || to_char(__CAP__, 'FM999,999') || '. Split it into '
--          || ceil(5000 / __CAP__::numeric) || ' files and import each.")' || chr(10);
--
--   -- ---- 3. a file at the cap, timed against a third of the timeout ---------
--   SELECT jsonb_agg(jsonb_build_object('full_name', 'Person ' || g,
--            'email', CASE WHEN g % 4 = 0 THEN 'p' || g || '@example.invalid' END,
--            'phones', jsonb_build_array(jsonb_build_object('number', '+1513' || lpad((2000000 + g)::text, 7, '0')))
--                      || CASE WHEN g % 3 = 0 THEN jsonb_build_array(jsonb_build_object('number', '+1859' || lpad((3000000 + g)::text, 7, '0'))) ELSE '[]' END)
--          ORDER BY g) INTO rows FROM generate_series(1, __CAP__) g;
--   t0 := clock_timestamp(); pv := preview_contact_import(rows); t_pv := extract(epoch FROM clock_timestamp() - t0);
--   t0 := clock_timestamp(); cm := commit_contact_import(rows, 'zzz-cap.csv'); t_cm := extract(epoch FROM clock_timestamp() - t0);
--   SELECT substring(c FROM 'statement_timeout=(.*)') INTO tmo
--     FROM pg_roles, unnest(rolconfig) c WHERE rolname = 'authenticated' AND c LIKE 'statement_timeout=%';
--   tmo_s := CASE WHEN tmo ~ '^[0-9]+s$' THEN rtrim(tmo, 's')::numeric
--                 WHEN tmo ~ '^[0-9]+min$' THEN 60 * replace(tmo, 'min', '')::numeric
--                 WHEN tmo ~ '^[0-9]+(ms)?$' THEN replace(tmo, 'ms', '')::numeric / 1000 END;
--   r := r || '3. a file at the cap: preview ' || to_char(t_pv, 'FM990.00') || ' s, commit ' || to_char(t_cm, 'FM990.00')
--          || ' s; created ' || (cm ->> 'created') || '; statement_timeout ' || COALESCE(tmo, 'not set')
--          || CASE WHEN tmo_s IS NULL THEN '' WHEN t_cm <= tmo_s / 3 THEN ', commit within a third of it'
--                  ELSE ', COMMIT OVER A THIRD OF IT' END
--          || chr(10) || '   (expect "commit within a third of it" on staging and production)' || chr(10);
--
--   -- ---- 4-6. the commit links past calls by the same rules (section 3) -----
--   -- A new contact for …9031, and a held row (…9032 and …9033: two contacts)
--   -- picked onto Xavier, so …9033 stays with Yvonne.
--   rows := jsonb_build_array(
--     jsonb_build_object('full_name', 'New Caller', 'phones', jsonb_build_array(jsonb_build_object('number', '+15135559031'))),
--     jsonb_build_object('full_name', 'Xavier', 'phones', jsonb_build_array(jsonb_build_object('number', '+15135559032'),
--                                                                            jsonb_build_object('number', '+15135559033'))));
--   cm := commit_contact_import(rows, 'zzz-links.csv', jsonb_build_object('2', c_x::text));
--   r := r || '4. calls with …9031: from it, now on the new contact as: '
--          || COALESCE((SELECT contact_link_method::text FROM interactions WHERE id = call_open), 'still unlinked')
--          || '; to it (outbound): ' || COALESCE((SELECT contact_link_method::text FROM interactions WHERE id = call_out), 'still unlinked')
--          || '; both on the same contact, named New Caller: '
--          || ((SELECT count(DISTINCT i.contact_id) FROM interactions i JOIN contacts c ON c.id = i.contact_id
--                WHERE i.id IN (call_open, call_out) AND c.full_name = 'New Caller') = 1)
--          || chr(10) || '   (expect imported; imported; true)' || chr(10);
--   r := r || '5. the hand-unlinked call: ' || COALESCE((SELECT contact_id::text FROM interactions WHERE id = call_hand), 'still unlinked')
--          || '; the confirmed one still on Someone else: ' || ((SELECT contact_id FROM interactions WHERE id = call_conf) = c_other)
--          || '; calls_linked ' || (cm ->> 'calls_linked')
--          || chr(10) || '   (expect still unlinked; true; calls_linked 2)' || chr(10);
--   r := r || '6. the held row picked onto Xavier: the call from Yvonne''s …9033: '
--          || COALESCE((SELECT contact_id::text FROM interactions WHERE id = call_y), 'still unlinked')
--          || '; …9033 still Yvonne''s: ' || ((SELECT contact_id FROM contact_phones WHERE organization_id = v_org AND e164 = '+15135559033') = c_y)
--          || chr(10) || '   (expect still unlinked; true: a number left with the other contact links nothing)' || chr(10);
--
--   -- ---- 7. a merge chain is held (replaces 2330's line 28) -----------------
--   -- The guard (20261102T2200) refuses a chain from both ends, so this builds
--   -- one with the guard switched off: owner-level, not superuser. Where even
--   -- that isn't allowed, the line says so and the report survives.
--   BEGIN
--     PERFORM set_config('role', 'none', true);
--     INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'Chain A') RETURNING id INTO c_a;
--     INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'Chain B') RETURNING id INTO c_b;
--     INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'Chain C') RETURNING id INTO c_c;
--     INSERT INTO contact_phones (organization_id, contact_id, e164, is_primary) VALUES (v_org, c_a, '+15135559028', true);
--     -- contacts.import_id's foreign key is deferred (2330), so line 3 left
--     -- checks queued, and ALTER TABLE refuses while any are (55006). Run them.
--     SET CONSTRAINTS ALL IMMEDIATE;
--     ALTER TABLE contacts DISABLE TRIGGER contacts_merged_into_ck;
--     UPDATE contacts SET merged_into = c_b WHERE id = c_a;
--     UPDATE contacts SET merged_into = c_c WHERE id = c_b;
--     ALTER TABLE contacts ENABLE TRIGGER contacts_merged_into_ck;
--     PERFORM set_config('role', 'authenticated', true);
--     pv := preview_contact_import(jsonb_build_array(jsonb_build_object('full_name', 'Chain', 'phones',
--             jsonb_build_array(jsonb_build_object('number', '+15135559028')))));
--     r := r || '7. a number whose owner was merged into a contact that was itself merged: '
--            || (pv #>> '{rows,0,verdict}') || '/' || (pv #>> '{rows,0,hold}')
--            || '   (expect held/merge_chain)' || chr(10);
--   EXCEPTION WHEN OTHERS THEN
--     r := r || '7. a merge chain: not runnable here: ' || SQLSTATE || ' ' || SQLERRM
--            || '   (the hold is unreachable while 20261102T2200''s guard stands, and untested here)' || chr(10);
--   END;
--
--   RAISE EXCEPTION 'VERIFY 20261123T1500_contact_import_cap (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
