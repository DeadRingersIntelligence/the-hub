-- =============================================================================
-- db/measurements/contact_import_timing.sql
-- Not a migration: nothing here is recorded in the ledger, and everything is
-- rolled back by the closing RAISE, which carries the results.
--
-- WHY. 20261120T2330's 5,000-row commit took 8.07 s on staging and 8.25 s on
-- production, against authenticated's 8 s statement_timeout; scratch had said
-- 3.6 s. Mandie's ruling (23 November): lower the cap to what STAGING says
-- lands near a third of the timeout, keeping one transaction. This block
-- measures it.
--
-- HOW TO RUN. Staging only, in the SQL editor, after 20261120T2330, as one
-- statement. Run it TWICE and use the steadier figures: on scratch one run in
-- three showed a multi-second outlier on a single size that didn't reproduce.
-- If the editor times out, shorten `sizes`; each size is independent.
--
-- WHAT IT REPORTS, per size: preview; a first import into a book of 150
-- learned contacts; a second import of the same size against the book the
-- first one grew. Then one 2,000-row import into a 10,000-contact book, an
-- established firm. A throwaway 200-row import runs first and isn't reported.
-- =============================================================================
-- Contact import: how long does a commit take, by size? Read-only in effect:
-- everything is rolled back by the closing RAISE, which carries the results.
-- Run in the SQL editor on STAGING, as one statement, AFTER 20261120T2330.
-- Edit `sizes` if the editor times out; each size is independent.
DO $$
DECLARE
  sizes CONSTANT int[] := ARRAY[1000, 1500, 2000, 2500, 3000];
  big_book CONSTANT int := 10000;      -- an established firm's book, for one 2,000-row import
  n int; r text := ''; t0 timestamptz; t_pv numeric; t_c1 numeric; t_c2 numeric; f1 jsonb; f2 jsonb; cm jsonb;
  v_org uuid; v_user uuid; v_auth uuid;
BEGIN
  r := r || 'authenticated''s statement_timeout: '
         || COALESCE((SELECT array_to_string(rolconfig, ',') FROM pg_roles WHERE rolname = 'authenticated'), 'not set') || chr(10)
         || 'rows | preview | commit, first import | commit, same size again into the grown book' || chr(10);
  -- 200 first, thrown away: the session's first commit carries a one-off
  -- warm-up cost (5.6 s for 1,000 rows on scratch, against 0.6 s after).
  FOREACH n IN ARRAY ARRAY[200] || sizes || ARRAY[-2000] LOOP     -- -2000: the big-book case
   BEGIN
    v_auth := gen_random_uuid();
    PERFORM set_config('role', 'none', true);
    PERFORM set_config('app.is_internal', 'on', true);
    INSERT INTO organizations (name, client_type) VALUES ('ZZZ measure ' || n, 'funeral_home') RETURNING id INTO v_org;
    INSERT INTO users (email, full_name, auth_user_id) VALUES ('zzz-measure-' || abs(n) || '@example.invalid', 'ZZZ Measure', v_auth) RETURNING id INTO v_user;
    INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id) VALUES (v_user, 'organization', 'manager', v_org);
    -- the book: 150 learned contacts (or big_book), numbers 2000001.., some of which the file repeats
    INSERT INTO contacts (organization_id, full_name)
      SELECT v_org, 'Learned ' || g FROM generate_series(1, CASE WHEN n < 0 THEN big_book ELSE 150 END) g;
    INSERT INTO contact_phones (organization_id, contact_id, e164, is_primary)
      SELECT v_org, c.id, '+1513' || lpad((2000000 + substr(c.full_name, 9)::int)::text, 7, '0'), true
        FROM contacts c WHERE c.organization_id = v_org;
    INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at, from_e164)
      SELECT v_org, 'inbound', now() - (g || ' hours')::interval, now() - (g || ' hours')::interval,
             '+1513' || lpad((2000000 + g * 7)::text, 7, '0') FROM generate_series(1, 300) g;
    PERFORM set_config('app.is_internal', 'off', true);
    -- two files of |n| rows: the first overlaps the book's numbers; the second is new people.
    -- names, one or two numbers each (a third have two), 1% repeating an earlier row's number
    SELECT jsonb_agg(jsonb_build_object('full_name', 'Person ' || g,
             'email', CASE WHEN g % 4 = 0 THEN 'p' || g || '@example.invalid' END,
             'phones', jsonb_build_array(jsonb_build_object('number', '+1513' || lpad((2000000 + CASE WHEN g > abs(n) * 0.99 THEN g - abs(n) / 2 ELSE g END)::text, 7, '0')))
                       || CASE WHEN g % 3 = 0 THEN jsonb_build_array(jsonb_build_object('number', '+1859' || lpad((3000000 + g)::text, 7, '0'))) ELSE '[]' END)
             ORDER BY g) INTO f1 FROM generate_series(1, abs(n)) g;
    SELECT jsonb_agg(jsonb_build_object('full_name', 'Second ' || g,
             'phones', jsonb_build_array(jsonb_build_object('number', '+1606' || lpad((4000000 + g)::text, 7, '0'))))
             ORDER BY g) INTO f2 FROM generate_series(1, abs(n)) g;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_auth::text)::text, true);
    PERFORM set_config('role', 'authenticated', true);

    IF n > 0 THEN
      t0 := clock_timestamp(); PERFORM preview_contact_import(f1); t_pv := extract(epoch FROM clock_timestamp() - t0);
      t0 := clock_timestamp(); cm := commit_contact_import(f1, 'zzz-first.csv'); t_c1 := extract(epoch FROM clock_timestamp() - t0);
      t0 := clock_timestamp(); PERFORM commit_contact_import(f2, 'zzz-second.csv'); t_c2 := extract(epoch FROM clock_timestamp() - t0);
      IF n <> 200 THEN          -- the warm-up isn't reported; it rolls back like the rest
      r := r || lpad(n::text, 4) || ' | ' || to_char(t_pv, 'FM990.00') || ' s | ' || to_char(t_c1, 'FM990.00') || ' s ('
             || (cm ->> 'created') || ' created, ' || (cm ->> 'calls_linked') || ' calls) | ' || to_char(t_c2, 'FM990.00') || ' s' || chr(10);
      END IF;
    ELSE
      t0 := clock_timestamp(); PERFORM commit_contact_import(f2, 'zzz-bigbook.csv'); t_c2 := extract(epoch FROM clock_timestamp() - t0);
      r := r || abs(n) || ' rows into a ' || big_book || '-contact book: commit ' || to_char(t_c2, 'FM990.00') || ' s' || chr(10);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';      -- undo this size before the next
   EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
   END;
  END LOOP;
  RAISE EXCEPTION 'MEASURE contact import (all rolled back) %', chr(10) || r;
END $$;
