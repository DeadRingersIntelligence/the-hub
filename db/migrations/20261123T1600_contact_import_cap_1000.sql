-- =============================================================================
-- 20261123T1600_contact_import_cap_1000.sql
-- The Hub — a contact import is capped at 1,000 rows.
--
-- APPLIED 23 November, as reviewed: ledger md5
-- 07dad16229de65aab986c0360d510cea, 11,266 characters, on staging (about
-- 15:40) and production (15:41:48 UTC). This note, and the correction to
-- line 3's expectation text in the verification, were added afterwards; the
-- file is otherwise as it ran. Lines 1, 2 and 4 passed on both. Line 3, with
-- the first-day fixture (850 created, 75 filled, 300 calls linked on each):
--   staging (Nano)     preview 0.12 s, commit 1.51 s -> within a third
--   production (Micro) preview 1.45 s, commit 2.96 s -> OVER A THIRD (37%)
--
-- WHY THE CAP STAYED AT 1,000 ANYWAY. By the rule below, OVER A THIRD meant
-- dropping again. It didn't, deliberately (Mandie, 23 November). Two
-- production measurements with comparable fixtures, 1,000 rows in 2.96 s
-- and 2,000 in 3.85 s (db/measurements/contact_import_timing_2000_small.sql),
-- give about 0.89 ms per row and about 2.07 s of FIXED cost, whatever the
-- file's size. A third of the 8 s timeout is 2.67 s, so the fixed cost alone
-- is 26% of the budget, and no cap in any useful range reaches the target:
-- even a one-row file would sit at about 26%. Halving the cap again would buy
-- about 15% for half the capacity. The one-third rule was set before that was
-- known and can't be met by capping, so it was abandoned deliberately, not
-- met. 1,000 leaves 2.7x headroom against the timeout on the binding case,
-- measured on the slower of the two databases with its IO balance at 99%,
-- and the failure mode is a clean, atomic rollback.
--
-- SUPERSEDED IN PURPOSE THE SAME DAY: contact import became internal-only,
-- run as SQL by Dead Ringers, so the cap no longer governs onboarding. It
-- stays as the record of what is safe through authenticated if import is
-- ever exposed to clients.
--
-- WHY. 20261123T1500 set the cap at 1,500 and timed a file at the cap on
-- both databases (its verification, line 3), from a quiet database:
--   staging (Nano)     preview 0.15 s, commit 2.04 s -> within a third
--   production (Micro) preview 1.49 s, commit 3.48 s -> OVER A THIRD (43.5%)
-- Production read Disk IO Balance 99% and CPU 15% at the time: a healthy
-- reading, not a depleted one. The ruling is that the commit at the cap lands
-- at about a third of authenticated's 8 s statement_timeout, so the cap drops
-- to 1,000 (Mandie, 23 November). 1,000 extrapolates to about 2.3 s (29%);
-- the cap is not set on that: line 3 below decides, on production.
--
-- A BIGGER INSTANCE IS NOT THE LEVER. Production (Micro, 768 MB
-- effective_cache_size) was SLOWER than staging (Nano, 384 MB) for identical
-- work: 3.48 s against 2.04 s. The commit is write-bound; more memory does
-- little for it. If imports need to be bigger, the cap is the lever, and the
-- ruling stands: one transaction, no chunking, no undo.
--
-- THE BINDING CASE is a new firm with an empty book: its first import, almost
-- all creates (a create costs more than a fill), linking its past calls. So
-- line 3's fixture is that firm: a 150-contact book and 300 past calls with no
-- contact, from numbers in the file. 1500's line 3 built only about five
-- calls, linked almost none, and so understated the first-day case; this one
-- measures it.
--
-- WHAT CHANGES: the cap in contact_import_check, and the two comments that
-- name it. NOTHING ELSE. 2330's classifier and 1500's commit (the rework that
-- links calls without a scan per call) both stay; section 1 checks both are
-- exactly as reviewed, and line 4 of the verification shows the commit
-- untouched. Both databases ran 1500, so they stay in step as long as this
-- file runs on both.
--
-- Requires: 20261123T1500 (contact_import_check and commit_contact_import, as
--           reviewed), 20261103T1200 (record_migration).
-- NOT SAFE TO RUN TWICE: section 1 refuses once the body has changed.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Preconditions: 1500 ran here, and both functions are as it left them
-- -----------------------------------------------------------------------------
DO $$
DECLARE v text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM schema_migrations WHERE filename = '20261123T1500_contact_import_cap.sql') THEN
    RAISE EXCEPTION '20261123T1500 has not run here; run it first';
  END IF;
  SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = to_regprocedure('contact_import_check(jsonb)');
  IF v IS DISTINCT FROM 'dc76a138568663d05d2e6c83d69e7419' THEN
    RAISE EXCEPTION 'contact_import_check is not 20261123T1500''s body (md5 %); already converted, or changed: stop and read it',
      COALESCE(v, 'missing');
  END IF;
  SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = to_regprocedure('commit_contact_import(jsonb, text, jsonb)');
  IF v IS DISTINCT FROM '293a2ee6014ac4fb31fa6942622002ef' THEN
    RAISE EXCEPTION 'commit_contact_import is not 20261123T1500''s body (md5 %): stop and read it',
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
  -- The cap: measured on production so the commit lands at about a third of
  -- authenticated's statement_timeout (20261123T1600; 1,500 came in at 43.5%).
  -- One transaction, kept. A bigger instance is not the lever: see the file.
  IF n > 1000 THEN
    RAISE EXCEPTION 'This file has % rows; the limit is %. Split it into % files and import each.',
      to_char(n, 'FM999,999'), to_char(1000, 'FM999,999'), ceil(n / 1000::numeric);
  END IF;
  RETURN v_org;
END $$;

COMMENT ON FUNCTION contact_import_check(jsonb) IS
  'The checks both import entry points make, once: owners and managers only, a '
  'list of rows, and at most 1,000 of them, a figure measured on production so '
  'the commit lands at about a third of the statement timeout (20261123T1600).';
COMMENT ON FUNCTION preview_contact_import(jsonb) IS
  'For a firm''s owners and managers: what importing these rows would do, row '
  'by row, writing nothing. Held rows carry the contacts a person may pick '
  'between. Up to 1,000 rows (20261120T2330, 20261123T1600).';

-- -----------------------------------------------------------------------------
-- 3. Record it
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261123T1600_contact_import_cap_1000.sql',
    NULL,
    'Contact import capped at 1,000 rows (1,500 committed in 3.48 s on '
    'production, 43.5% of the timeout); measured to land at about a third of '
    'it. Nothing else changes: 1500''s commit stays.');
END $rec$;

COMMIT;

-- =============================================================================
-- Verification — run AFTER the file, as its own statement. One block,
-- everything rolled back by the closing RAISE. As authenticated, a fixture
-- manager at a fixture firm.
--
-- LINE 3 IS THE MEASUREMENT THAT CONFIRMS THE CAP, and production decides
-- (staging is Nano and read faster for the same work). Run it there from a
-- quiet database: a few minutes after anything else that wrote in bulk, and
-- never straight after another run. The block writes and rolls back about
-- 4,200 rows.
--
-- DO $$
-- DECLARE
--   r text := ''; res text; t0 timestamptz; t_pv numeric; t_cm numeric; tmo text; tmo_s numeric;
--   rows jsonb; pv jsonb; cm jsonb;
--   v_org uuid; u_mo uuid; a_mo uuid := gen_random_uuid();
-- BEGIN
--   -- the first-day firm: a 150-contact book, and 300 past calls with no
--   -- contact from numbers the file will carry
--   PERFORM set_config('app.is_internal', 'on', true);
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ verify cap', 'funeral_home') RETURNING id INTO v_org;
--   INSERT INTO users (email, full_name, auth_user_id) VALUES ('zzz-cap@example.invalid', 'ZZZ Mo', a_mo) RETURNING id INTO u_mo;
--   INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id) VALUES (u_mo, 'organization', 'manager', v_org);
--   INSERT INTO contacts (organization_id, full_name) SELECT v_org, 'Learned ' || g FROM generate_series(1, 150) g;
--   INSERT INTO contact_phones (organization_id, contact_id, e164, is_primary)
--     SELECT v_org, c.id, '+1513' || lpad((2000000 + substr(c.full_name, 9)::int)::text, 7, '0'), true
--       FROM contacts c WHERE c.organization_id = v_org;
--   INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at, from_e164)
--     SELECT v_org, 'inbound', now() - (g || ' hours')::interval, now() - (g || ' hours')::interval,
--            '+1513' || lpad((2000000 + g * 3)::text, 7, '0') FROM generate_series(1, 300) g;
--   PERFORM set_config('app.is_internal', 'off', true);
--   PERFORM set_config('request.jwt.claims', json_build_object('sub', a_mo::text)::text, true);
--   PERFORM set_config('role', 'authenticated', true);
--
--   -- ---- 1-2. the cap, and the refusal above it ----------------------------
--   r := r || '1. the cap in contact_import_check: '
--          || (SELECT substring(prosrc FROM 'n > ([0-9]+)') FROM pg_proc WHERE proname = 'contact_import_check')
--          || '   (expect 1000)' || chr(10);
--   BEGIN PERFORM preview_contact_import((SELECT jsonb_agg(jsonb_build_object('full_name', 'x')) FROM generate_series(1, 1001)));
--     res := 'ALLOWED';
--   EXCEPTION WHEN OTHERS THEN res := SQLERRM; END;
--   r := r || '2. 1,001 rows: ' || res || chr(10)
--          || '   (expect "This file has 1,001 rows; the limit is 1,000. Split it into 2 files and import each.")' || chr(10);
--
--   -- ---- 3. a file at the cap, the first-day case, timed -------------------
--   -- 1,000 rows, a third with a second number, a quarter with an email; the
--   -- first 150 numbers are the book's (fills), the rest new (creates); the
--   -- 300 calls are from numbers in rows 3, 6, ... 900.
--   SELECT jsonb_agg(jsonb_build_object('full_name', 'Person ' || g,
--            'email', CASE WHEN g % 4 = 0 THEN 'p' || g || '@example.invalid' END,
--            'phones', jsonb_build_array(jsonb_build_object('number', '+1513' || lpad((2000000 + g)::text, 7, '0')))
--                      || CASE WHEN g % 3 = 0 THEN jsonb_build_array(jsonb_build_object('number', '+1859' || lpad((3000000 + g)::text, 7, '0'))) ELSE '[]' END)
--          ORDER BY g) INTO rows FROM generate_series(1, 1000) g;
--   t0 := clock_timestamp(); pv := preview_contact_import(rows); t_pv := extract(epoch FROM clock_timestamp() - t0);
--   t0 := clock_timestamp(); cm := commit_contact_import(rows, 'zzz-cap.csv'); t_cm := extract(epoch FROM clock_timestamp() - t0);
--   SELECT substring(c FROM 'statement_timeout=(.*)') INTO tmo
--     FROM pg_roles, unnest(rolconfig) c WHERE rolname = 'authenticated' AND c LIKE 'statement_timeout=%';
--   tmo_s := CASE WHEN tmo ~ '^[0-9]+s$' THEN rtrim(tmo, 's')::numeric
--                 WHEN tmo ~ '^[0-9]+min$' THEN 60 * replace(tmo, 'min', '')::numeric
--                 WHEN tmo ~ '^[0-9]+(ms)?$' THEN replace(tmo, 'ms', '')::numeric / 1000 END;
--   r := r || '3. a file at the cap: preview ' || to_char(t_pv, 'FM990.00') || ' s, commit ' || to_char(t_cm, 'FM990.00')
--          || ' s; created ' || (cm ->> 'created') || ', filled ' || (cm ->> 'filled')
--          || ', calls linked ' || (cm ->> 'calls_linked') || '; statement_timeout ' || COALESCE(tmo, 'not set')
--          || CASE WHEN tmo_s IS NULL THEN '' WHEN t_cm <= tmo_s / 3 THEN ', commit within a third of it'
--                  ELSE ', COMMIT OVER A THIRD OF IT' END
--          || chr(10) || '   (expect created 850, filled 75, calls linked 300. On production (Micro) this read 2.96 s,'
--          || ' OVER A THIRD, and was ACCEPTED: about 2.07 s of the commit is fixed cost, so no cap reaches a'
--          || ' third; see the APPLIED note at the top of the file. Not a failure unless it nears 8 s.)' || chr(10);
--
--   -- ---- 4. the commit is 1500's, untouched --------------------------------
--   r := r || '4. commit_contact_import''s body: '
--          || (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure('commit_contact_import(jsonb, text, jsonb)'))
--          || '   (expect 293a2ee6014ac4fb31fa6942622002ef, 20261123T1500''s)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261123T1600_contact_import_cap_1000 (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
