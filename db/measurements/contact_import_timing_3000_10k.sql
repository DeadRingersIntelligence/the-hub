-- =============================================================================
-- db/measurements/contact_import_timing_3000_10k.sql
-- Contact import timing: 3,000 rows into a 10,000-contact book. ONE preview,
-- ONE commit. Not a migration: nothing goes in the ledger, and everything is
-- rolled back by the closing RAISE, which carries the result.
--
-- One of four files (2,000 and 3,000 rows; a 150-contact book and a
-- 10,000-contact book), split so each finishes well inside the SQL editor's
-- gateway timeout, which is separate from statement_timeout and can't be
-- raised. Run them one at a time, and stop as soon as a size is clearly over
-- budget. The 10,000-contact book decides the cap: that's an established firm.
--
-- RUN IT ON A QUIET DATABASE, AND LEAVE IT QUIET AFTERWARDS. This block writes
-- and rolls back about 26,800 rows, and autovacuum then has to clear them.
-- On staging, runs stacked back to back went fast, slower (1,000 rows in
-- 20.74 s), then stalled: the import wasn't slower, the database was still
-- cleaning up. So:
--   * BEFORE: the block reports dead rows and the last autovacuum on the four
--     tables it writes, and REFUSES TO MEASURE if more than 2,000 dead rows are
--     waiting. If it refuses, wait and run it again; nothing was written.
--   * AFTER: wait a few minutes (until last_autovacuum on those tables has
--     moved past this run, or the next run's check passes) before the next
--     file. Never read a slow result from a run that followed another closely.
--
-- WHICH COMMIT IT TIMES: 20261123T1500's, not 2330's. 2330's commit scanned
-- change_history once per call it linked, so its time grew with the firm's
-- history (6.35 s for this file on scratch); 1500 replaces it, and the cap
-- must be set for the body that will ship. Until 1500 runs, this block swaps
-- 1500's commit in, byte for byte (it checks the md5), and the closing RAISE
-- rolls the swap back with everything else. It refuses if the installed commit
-- is neither 2330's nor 1500's. While it runs (seconds), anything else calling
-- commit_contact_import waits; nothing in the app calls it yet.
--
-- THE FILE: names, one or two numbers each (a third have two), 1% repeating an
-- earlier row's number. Half its numbers are already in the book (those rows
-- fill), half are new (those rows create), and 300 past calls with no contact
-- are spread across both halves, so one run exercises every path the commit
-- has at that size.
--
-- What it prints: the before-check; which commit it timed; how long the fixture took (not part of the
-- import); preview and commit; authenticated's statement_timeout and whether
-- the commit landed within a third of it (the ruled target); the block's total.
--
-- Staging or production, in the SQL editor, after 20261120T2330, as one
-- statement.
-- =============================================================================
DO $measure$
DECLARE
  n_rows          CONSTANT int := 3000;
  book_size       CONSTANT int := 10000;
  quiet_dead_rows CONSTANT int := 2000;
  t_start timestamptz := clock_timestamp(); t0 timestamptz;
  t_fix numeric; t_pv numeric; t_cm numeric; tmo text; tmo_s numeric; v_md5 text; body_note text;
  r text := ''; dead bigint; f jsonb; cm jsonb; v_org uuid; v_user uuid; v_auth uuid := gen_random_uuid();
BEGIN
  SELECT sum(n_dead_tup) INTO dead FROM pg_stat_user_tables
   WHERE relname IN ('contacts', 'contact_phones', 'interactions', 'change_history');
  r := r || 'before: ' || (SELECT string_agg(relname || ' ' || n_dead_tup || ' dead, last autovacuum '
                                             || COALESCE(to_char(last_autovacuum, 'HH24:MI:SS'), 'never'), '; ' ORDER BY relname)
                            FROM pg_stat_user_tables
                           WHERE relname IN ('contacts', 'contact_phones', 'interactions', 'change_history')) || chr(10);
  IF dead > quiet_dead_rows THEN
    RAISE EXCEPTION 'NOT QUIET: % dead rows waiting for cleanup; wait a few minutes and run again (nothing measured) %', dead, chr(10) || r;
  END IF;

  -- the commit as 20261123T1500 leaves it (see the header)
  SELECT md5(prosrc) INTO v_md5 FROM pg_proc WHERE oid = to_regprocedure('commit_contact_import(jsonb, text, jsonb)');
  IF v_md5 = '85c13bfe91a655f4f198c572934ebb72' THEN
    EXECUTE $fn$
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
END $$
    $fn$;
    body_note := '20261123T1500''s, swapped in for this run (2330''s is installed; the swap is rolled back)';
  ELSIF v_md5 = 'df1fa9927abe40d0b4cc14e89181cbe5' THEN
    body_note := '20261123T1500''s, installed';
  ELSE
    RAISE EXCEPTION 'commit_contact_import is neither 2330''s body nor 1500''s (md5 %): stop and read it', COALESCE(v_md5, 'missing');
  END IF;
  SELECT md5(prosrc) INTO v_md5 FROM pg_proc WHERE oid = to_regprocedure('commit_contact_import(jsonb, text, jsonb)');
  IF v_md5 IS DISTINCT FROM 'df1fa9927abe40d0b4cc14e89181cbe5' THEN
    RAISE EXCEPTION 'the swapped-in commit is not 1500''s body (md5 %): stop', v_md5;
  END IF;

  -- the fixture firm, its manager and its book, as the system
  t0 := clock_timestamp();
  PERFORM set_config('app.is_internal', 'on', true);
  INSERT INTO organizations (name, client_type) VALUES ('ZZZ measure', 'funeral_home') RETURNING id INTO v_org;
  INSERT INTO users (email, full_name, auth_user_id) VALUES ('zzz-measure@example.invalid', 'ZZZ Measure', v_auth) RETURNING id INTO v_user;
  INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id) VALUES (v_user, 'organization', 'manager', v_org);
  INSERT INTO contacts (organization_id, full_name) SELECT v_org, 'Learned ' || g FROM generate_series(1, book_size) g;
  INSERT INTO contact_phones (organization_id, contact_id, e164, is_primary)
    SELECT v_org, c.id, '+1513' || lpad((2000000 + substr(c.full_name, 9)::int)::text, 7, '0'), true
      FROM contacts c WHERE c.organization_id = v_org;
  INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at, from_e164)
    SELECT v_org, 'inbound', now() - (g || ' hours')::interval, now() - (g || ' hours')::interval,
           '+1513' || lpad((2000000 + g * 7 + CASE WHEN g * 7 % 2 = 0 THEN book_size ELSE 0 END)::text, 7, '0')
      FROM generate_series(1, 300) g;
  PERFORM set_config('app.is_internal', 'off', true);
  -- the file (see the header): row k's first number is the book's k-th when k
  -- is odd, and past the book when k is even; the last 1% repeat earlier rows
  SELECT jsonb_agg(jsonb_build_object('full_name', 'Person ' || g,
           'email', CASE WHEN g % 4 = 0 THEN 'p' || g || '@example.invalid' END,
           'phones', jsonb_build_array(jsonb_build_object('number', '+1513' || lpad((2000000 + k + CASE WHEN k % 2 = 0 THEN book_size ELSE 0 END)::text, 7, '0')))
                     || CASE WHEN g % 3 = 0 THEN jsonb_build_array(jsonb_build_object('number', '+1859' || lpad((3000000 + g)::text, 7, '0'))) ELSE '[]' END)
           ORDER BY g) INTO f
    FROM generate_series(1, n_rows) g, LATERAL (SELECT CASE WHEN g > n_rows * 0.99 THEN g - n_rows / 2 ELSE g END AS k) kk;
  t_fix := extract(epoch FROM clock_timestamp() - t0);

  -- the import, as the firm's manager
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_auth::text)::text, true);
  PERFORM set_config('role', 'authenticated', true);
  t0 := clock_timestamp(); PERFORM preview_contact_import(f); t_pv := extract(epoch FROM clock_timestamp() - t0);
  t0 := clock_timestamp(); cm := commit_contact_import(f, 'zzz-measure.csv'); t_cm := extract(epoch FROM clock_timestamp() - t0);

  SELECT substring(c FROM 'statement_timeout=(.*)') INTO tmo
    FROM pg_roles, unnest(rolconfig) c WHERE rolname = 'authenticated' AND c LIKE 'statement_timeout=%';
  tmo_s := CASE WHEN tmo ~ '^[0-9]+s$' THEN rtrim(tmo, 's')::numeric
                WHEN tmo ~ '^[0-9]+min$' THEN 60 * replace(tmo, 'min', '')::numeric
                WHEN tmo ~ '^[0-9]+(ms)?$' THEN replace(tmo, 'ms', '')::numeric / 1000 END;
  r := r || 'commit timed: ' || body_note || chr(10) || 'fixture: ' || to_char(t_fix, 'FM990.00') || ' s (not part of the import)' || chr(10)
         || n_rows || ' rows into a ' || book_size || '-contact book: preview ' || to_char(t_pv, 'FM990.00')
         || ' s, commit ' || to_char(t_cm, 'FM990.00') || ' s (' || (cm ->> 'created') || ' created, '
         || (cm ->> 'filled') || ' filled, ' || (cm ->> 'unchanged') || ' unchanged, '
         || (cm ->> 'held_skipped') || ' held, ' || (cm ->> 'calls_linked') || ' calls linked)' || chr(10)
         || 'authenticated''s statement_timeout: ' || COALESCE(tmo, 'not set')
         || CASE WHEN tmo_s IS NULL THEN '' WHEN t_cm <= tmo_s / 3 THEN ' -> commit WITHIN a third of it'
                 ELSE ' -> commit OVER a third of it' END || chr(10)
         || 'rows written, all to be rolled back: '
         || (SELECT sum(n_tup_ins + n_tup_upd + n_tup_del) FROM pg_stat_xact_user_tables) || chr(10)
         || 'whole block: ' || to_char(extract(epoch FROM clock_timestamp() - t_start), 'FM990.00') || ' s' || chr(10);
  RAISE EXCEPTION 'MEASURE contact import, % rows into %, (all rolled back) %', n_rows, book_size, chr(10) || r;
END $measure$;
