-- =============================================================================
-- 20261123T1500_contact_import_cap.sql
-- The Hub — a contact import is capped at what the database can commit well
-- inside the statement timeout.
--
-- DRAFT: THE CAP IS NOT SET. Every place it goes reads __CAP__, which isn't
-- SQL, so this file cannot run until the number is in. The number comes from
-- db/measurements/contact_import_timing.sql run on STAGING after the compute
-- upgrade, from a quiet database (Mandie's ruling, 23 November).
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
-- WHAT CHANGES: contact_import_check's body (the cap and the message), and
-- preview_contact_import's comment (it named 5,000). Nothing else: the
-- classifier and the commit are as 2330 left them.
--
-- AND IN THE VERIFICATION, 2330's line 28 replaced. It used
-- session_replication_role, which needs a superuser; on Supabase it aborted
-- the whole block. The replacement uses ALTER TABLE contacts DISABLE TRIGGER,
-- which needs only ownership of the table for a user trigger, and it catches
-- its own failure: where it can't run, it prints "not runnable here" and the
-- rest of the report survives. While it holds, other WRITES to contacts wait
-- until the block rolls back (reads don't): a few seconds.
--
-- Requires: 20261120T2330 (contact_import_check, as reviewed),
--           20261103T1200 (record_migration).
-- NOT SAFE TO RUN TWICE: section 1 refuses once the body has changed.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Preconditions: 2330 ran here, and contact_import_check is its body
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
-- 3. Record it
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261123T1500_contact_import_cap.sql',
    NULL,
    'Contact import capped at __CAP__ rows (was 5,000, which took 8 s on staging '
    'against an 8 s timeout), measured on staging to land at about a third of '
    'the timeout; one transaction kept. The refusal says how many files.');
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
-- BEGIN
--   PERFORM set_config('app.is_internal', 'on', true);
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ verify cap', 'funeral_home') RETURNING id INTO v_org;
--   INSERT INTO users (email, full_name, auth_user_id) VALUES ('zzz-cap@example.invalid', 'ZZZ Mo', a_mo) RETURNING id INTO u_mo;
--   INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id) VALUES (u_mo, 'organization', 'manager', v_org);
--   INSERT INTO contacts (organization_id, full_name) SELECT v_org, 'Learned ' || g FROM generate_series(1, 150) g;
--   INSERT INTO contact_phones (organization_id, contact_id, e164, is_primary)
--     SELECT v_org, c.id, '+1513' || lpad((2000000 + substr(c.full_name, 9)::int)::text, 7, '0'), true
--       FROM contacts c WHERE c.organization_id = v_org;
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
--   -- ---- 4. a merge chain is held (replaces 2330's line 28) -----------------
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
--     r := r || '4. a number whose owner was merged into a contact that was itself merged: '
--            || (pv #>> '{rows,0,verdict}') || '/' || (pv #>> '{rows,0,hold}')
--            || '   (expect held/merge_chain)' || chr(10);
--   EXCEPTION WHEN OTHERS THEN
--     r := r || '4. a merge chain: not runnable here: ' || SQLSTATE || ' ' || SQLERRM
--            || '   (the hold is unreachable while 20261102T2200''s guard stands, and untested here)' || chr(10);
--   END;
--
--   RAISE EXCEPTION 'VERIFY 20261123T1500_contact_import_cap (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
