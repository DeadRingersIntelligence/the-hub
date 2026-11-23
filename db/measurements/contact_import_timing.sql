-- =============================================================================
-- db/measurements/contact_import_timing.sql
-- Not a migration: nothing here is recorded in the ledger, and everything is
-- rolled back by the closing RAISE, which carries the result.
--
-- WHY. 20261120T2330's 5,000-row commit took 8.07 s on staging and 8.25 s on
-- production, against authenticated's 8 s statement_timeout (scratch said
-- 3.6 s). Mandie's ruling (23 November): set the cap from STAGING, at about a
-- third of the timeout, keeping one transaction. This measures it, after the
-- compute upgrade.
--
-- ONE SIZE PER RUN. The first version measured five sizes in one block, wrote
-- and rolled back about 30,000 rows, and left the database cleaning up for the
-- next run: on staging, three runs went fast, slower (1,000 rows in 20.74 s
-- after autovacuum on all four tables), then past the SQL editor's gateway
-- timeout. So:
--   * set `n_rows` (and `second_import`, `book_size`) below, run, read, change,
--     run again;
--   * the block first reports dead rows and the last autovacuum on the four
--     tables it writes, and REFUSES TO MEASURE if more than `quiet_dead_rows`
--     are waiting: wait a few minutes and run it again;
--   * one run writes about 2 x n_rows contacts and phones (plus the book), so
--     even 3,000 rows finishes in seconds, well inside the gateway timeout.
-- Suggested runs: n_rows 1000, 1500, 2000, 2500, 3000 with book_size 150; then
-- n_rows 2000 with book_size 10000 (an established firm). Two of each, a few
-- minutes apart, using the steadier figure.
--
-- Staging only, in the SQL editor, after 20261120T2330, as one statement.
-- =============================================================================
DO $$
DECLARE
  n_rows          CONSTANT int     := 2000;   -- rows in the file
  second_import   CONSTANT boolean := true;   -- also time a second file of n_rows new people, into the grown book
  book_size       CONSTANT int     := 150;    -- contacts already in the book (150 learned; 10000 for an established firm)
  quiet_dead_rows CONSTANT int     := 2000;   -- refuse to measure above this many dead rows waiting for cleanup
  r text := ''; dead bigint; t0 timestamptz; t_pv numeric; t_c1 numeric; t_c2 numeric;
  f1 jsonb; f2 jsonb; cm jsonb; v_org uuid; v_user uuid; v_auth uuid := gen_random_uuid();
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
  r := r || 'authenticated''s statement_timeout: '
         || COALESCE((SELECT array_to_string(rolconfig, ',') FROM pg_roles WHERE rolname = 'authenticated'), 'not set') || chr(10);

  -- the fixture firm, its manager and its book, as the system
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
           '+1513' || lpad((2000000 + g * 7)::text, 7, '0') FROM generate_series(1, 300) g;
  PERFORM set_config('app.is_internal', 'off', true);

  -- the files: names, one or two numbers each (a third have two), 1% repeating
  -- an earlier row's number; the first overlaps the book, the second is new people
  SELECT jsonb_agg(jsonb_build_object('full_name', 'Person ' || g,
           'email', CASE WHEN g % 4 = 0 THEN 'p' || g || '@example.invalid' END,
           'phones', jsonb_build_array(jsonb_build_object('number', '+1513' || lpad((2000000 + CASE WHEN g > n_rows * 0.99 THEN g - n_rows / 2 ELSE g END)::text, 7, '0')))
                     || CASE WHEN g % 3 = 0 THEN jsonb_build_array(jsonb_build_object('number', '+1859' || lpad((3000000 + g)::text, 7, '0'))) ELSE '[]' END)
           ORDER BY g) INTO f1 FROM generate_series(1, n_rows) g;
  SELECT jsonb_agg(jsonb_build_object('full_name', 'Second ' || g,
           'phones', jsonb_build_array(jsonb_build_object('number', '+1606' || lpad((4000000 + g)::text, 7, '0'))))
           ORDER BY g) INTO f2 FROM generate_series(1, n_rows) g;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_auth::text)::text, true);
  PERFORM set_config('role', 'authenticated', true);
  t0 := clock_timestamp(); PERFORM preview_contact_import(f1); t_pv := extract(epoch FROM clock_timestamp() - t0);
  t0 := clock_timestamp(); cm := commit_contact_import(f1, 'zzz-first.csv'); t_c1 := extract(epoch FROM clock_timestamp() - t0);
  r := r || n_rows || ' rows into a ' || book_size || '-contact book: preview ' || to_char(t_pv, 'FM990.00') || ' s, commit '
         || to_char(t_c1, 'FM990.00') || ' s (' || (cm ->> 'created') || ' created, ' || (cm ->> 'calls_linked') || ' calls linked)' || chr(10);
  IF second_import THEN
    t0 := clock_timestamp(); PERFORM commit_contact_import(f2, 'zzz-second.csv'); t_c2 := extract(epoch FROM clock_timestamp() - t0);
    r := r || 'the same size again, into the grown book: commit ' || to_char(t_c2, 'FM990.00') || ' s' || chr(10);
  END IF;

  RAISE EXCEPTION 'MEASURE contact import (all rolled back) %', chr(10) || r;
END $$;
