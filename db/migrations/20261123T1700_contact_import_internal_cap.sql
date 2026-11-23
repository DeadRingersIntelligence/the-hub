-- =============================================================================
-- 20261123T1700_contact_import_internal_cap.sql
-- The Hub — Dead Ringers' contact import is capped at 10,000 rows.
--
-- WHY. 20261123T1630 proposed 20,000, predicted at 16-18 s on production,
-- with its verification line 11 deciding against a 30 s target (a quarter of
-- the SQL editor's two-minute gateway). Measured, from a quiet database:
--                          staging   production
--     preview 20,000        1.95 s     2.64 s
--     commit 20,000        25.85 s    28.61 s
--     deferred checks       0.21 s     0.26 s
-- 28.87 s passed by 1.1 s, a 3.7% margin, and the model behind 20,000 was
-- wrong by about 60%. The largest real file expected is about 5,000, so
-- 20,000 bought nothing anyone will use and spent all the margin. 10,000 is
-- about 14-15 s on the same, linear, measurement: half the target, still
-- twice the largest file expected, and the refusal already tells the operator
-- how many files to split a bigger one into (Mandie, 23 November).
--
-- WHAT CHANGES: the cap in contact_import_for_firm_check, and the two
-- comments that name it, on contact_import_for_firm_check and on
-- contact_import_check (which points readers here). Nothing else. The
-- function keeps its grants (none to any API role) and stays SECURITY
-- INVOKER, which the current_user lock depends on (1630's applied note);
-- line 3 of the verification checks every import function for that.
--
-- Requires: 20261123T1630 (contact_import_for_firm_check, as reviewed),
--           20261103T1200 (record_migration).
-- NOT SAFE TO RUN TWICE: section 1 refuses once the body has changed.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Preconditions: 1630 ran here, and the check is its body
-- -----------------------------------------------------------------------------
DO $$
DECLARE v text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM schema_migrations WHERE filename = '20261123T1630_contact_import_for_a_firm.sql') THEN
    RAISE EXCEPTION '20261123T1630 has not run here; run it first';
  END IF;
  SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = to_regprocedure('contact_import_for_firm_check(uuid, text, jsonb)');
  IF v IS DISTINCT FROM '798ee05288d623c3270e4e58d8874c9b' THEN
    RAISE EXCEPTION 'contact_import_for_firm_check is not 20261123T1630''s body (md5 %); already converted, or changed: stop and read it',
      COALESCE(v, 'missing');
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. The cap
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION contact_import_for_firm_check(p_firm uuid, p_firm_name text, p_rows jsonb)
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
  -- The internal cap: half of 30 s, a quarter of the SQL editor's gateway
  -- (about two minutes, separate from statement_timeout). 20,000 committed in
  -- 28.87 s on production, so 10,000 is about 14-15 s, twice the largest file
  -- expected (20261123T1630, 20261123T1700).
  IF n > 10000 THEN
    RAISE EXCEPTION 'This file has % rows; the limit here is %. Split it into % files and import each.',
      to_char(n, 'FM999,999'), to_char(10000, 'FM999,999'), ceil(n / 10000::numeric);
  END IF;
  RETURN p_firm;
END $$;

COMMENT ON FUNCTION contact_import_for_firm_check(uuid, text, jsonb) IS
  'The checks both internal import entry points make: not an API role, the '
  'firm named by id AND by its exact name (both the same row), a list of rows, '
  'and at most 10,000 of them (20261123T1630, 20261123T1700).';
COMMENT ON FUNCTION contact_import_check(jsonb) IS
  'The app''s import checks: owners and managers only, a list of rows, at most '
  '1,000. CLOSED since 20261123T1630: no API role may execute it, so the 1,000 '
  'is the record of what 20261123T1600 measured as safe through authenticated, '
  'not a live limit. Dead Ringers'' imports use contact_import_for_firm_check '
  '(a 10,000 cap, 20261123T1700).';

-- -----------------------------------------------------------------------------
-- 3. Record it
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261123T1700_contact_import_internal_cap.sql',
    NULL,
    'Dead Ringers'' contact import capped at 10,000 rows (20,000 committed in '
    '28.87 s on production against a 30 s target, 1.1 s to spare); about half '
    'the target, twice the largest file expected.');
END $rec$;

COMMIT;

-- =============================================================================
-- Verification — run AFTER the file, as its own statement. One block,
-- everything rolled back by the closing RAISE. As postgres, in the SQL
-- editor, as imports run. It builds one fixture firm and imports nothing.
--
-- DO $$
-- DECLARE
--   r text := ''; res text; n int; m int; v_a uuid;
--   fns CONSTANT text[] := ARRAY['contact_import_outside_firm(uuid, jsonb)',
--     'contact_import_apply(uuid, uuid, jsonb, text, jsonb)', 'contact_import_for_firm_check(uuid, text, jsonb)',
--     'contact_import_for_firm_preview(uuid, text, jsonb, boolean)',
--     'contact_import_for_firm_commit(uuid, text, text, jsonb, text, jsonb)',
--     'contact_import_classify(uuid, jsonb)', 'contact_import_check(jsonb)', 'preview_contact_import(jsonb)',
--     'commit_contact_import(jsonb, text, jsonb)'];
-- BEGIN
--   PERFORM set_config('app.is_internal', 'on', true);
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ verify cap', 'funeral_home') RETURNING id INTO v_a;
--   PERFORM set_config('app.is_internal', 'off', true);
--
--   -- ---- 1-2. the cap, and the refusal above it (1630's line 10) -----------
--   r := r || '1. the cap in contact_import_for_firm_check: '
--          || (SELECT substring(prosrc FROM 'n > ([0-9]+)') FROM pg_proc
--               WHERE oid = to_regprocedure('contact_import_for_firm_check(uuid, text, jsonb)'))
--          || '   (expect 10000)' || chr(10);
--   res := '';
--   FOREACH n IN ARRAY ARRAY[10001, 25000] LOOP
--     BEGIN PERFORM contact_import_for_firm_preview(v_a, 'ZZZ verify cap',
--             (SELECT jsonb_agg(jsonb_build_object('full_name', 'x')) FROM generate_series(1, n)));
--       res := res || n || ': ALLOWED | ';
--     EXCEPTION WHEN OTHERS THEN res := res || SQLERRM || ' | '; END;
--   END LOOP;
--   BEGIN PERFORM contact_import_for_firm_preview(v_a, 'ZZZ verify cap',
--           (SELECT jsonb_agg(jsonb_build_object('full_name', 'x')) FROM generate_series(1, 10000)));
--     res := res || '10,000: allowed';
--   EXCEPTION WHEN OTHERS THEN res := res || '10,000: ' || SQLERRM; END;
--   r := r || '2. ' || res || chr(10)
--          || '   (expect "This file has 10,001 rows; the limit here is 10,000. Split it into 2 files and import each." | '
--          || '"This file has 25,000 rows; …Split it into 3 files…" | 10,000: allowed)' || chr(10);
--
--   -- ---- 3. what the current_user lock stands on ----------------------------
--   SELECT count(*) FILTER (WHERE p.prosecdef), count(*) INTO n, m
--     FROM unnest(fns) f JOIN pg_proc p ON p.oid = to_regprocedure(f);
--   r := r || '3. import functions that are SECURITY DEFINER: ' || n || ' of ' || m
--          || '; API roles that may execute one: '
--          || (SELECT count(*) FILTER (WHERE has_function_privilege(api.rolname, f, 'EXECUTE'))
--                FROM unnest(fns) f, unnest(ARRAY['anon', 'authenticated', 'service_role']) api(rolname))
--          || chr(10) || '   (expect 0 of 9: the lock reads current_user, which a definer would make the owner; 0)' || chr(10);
--
--   -- ---- 4. the comments name the new number --------------------------------
--   r := r || '4. comments: for_firm_check names 10,000: '
--          || (obj_description(to_regprocedure('contact_import_for_firm_check(uuid, text, jsonb)'), 'pg_proc') ~ '10,000')
--          || ', contact_import_check points at 10,000 and not 20,000: '
--          || (obj_description(to_regprocedure('contact_import_check(jsonb)'), 'pg_proc') ~ '10,000 cap'
--              AND obj_description(to_regprocedure('contact_import_check(jsonb)'), 'pg_proc') !~ '20,000')
--          || '   (expect true, true)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261123T1700_contact_import_internal_cap (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
