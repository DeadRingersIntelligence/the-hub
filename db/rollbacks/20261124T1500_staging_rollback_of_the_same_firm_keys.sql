-- =============================================================================
-- 20261124T1500_staging_rollback_of_the_same_firm_keys.sql
-- The Hub — STAGING ONLY. Put staging back to production's schema by
-- reverting all seven same-firm migrations, and record each rollback.
--
-- WHY. Staging carries 20261123T1810 and T1830-T1835: 123 composite
-- (pointer, organization_id) foreign keys and the unique indexes they need.
-- Production carries none of them — all seven were rolled back on the
-- evening of 23 November, after the app's PostgREST embed hints stopped
-- resolving against composite keys and the Contacts page broke.
-- hellophone#27 part 2 tests the corrected hints against SINGLE-column
-- keys, so staging has to match production before it can run.
--
-- WHAT IT DOES
--   1. Turns each composite key back into the single-column key it
--      replaced, carrying ON DELETE, DEFERRABLE and validity across
--      unchanged.
--   2. Drops the unique indexes on (id, organization_id) that existed only
--      because the composite keys needed them.
--   3. Records all seven rollbacks with record_rollback (20261123T2000)
--      rather than deleting the ledger rows. These are the first rollbacks
--      anywhere recorded with an exact time; production's seven are prose
--      until 20261123T2005 runs.
--
-- IT REBUILDS, IT DOES NOT REMEMBER. Every definition is derived from the
-- catalogue at run time and checked against an md5 you pin yourself, so the
-- file cannot restore a key to something the database did not actually say.
--
-- TWO RUNS, AND THE SECOND IS PINNED TO THE REVIEW, NOT TO THE FIRST.
--   Run it once with neither flag set: it computes everything, prints what
--   it would do, and rolls the whole transaction back.
--
--   Then CHECK what it printed against these two values. They come from
--   the 123 definitions the seven reviewed files pinned, and were computed
--   without reading this database:
--
--     SET hub.rollback_expect_keys_md5 = '472f5c2ab60c209c83b45bdb6a0fc775';
--     SET hub.rollback_expect_indexes  = '24';
--
--   Put both SET lines at the top of the same paste as the file. The SQL
--   editor may not carry a SET from one Run to the next; without them the
--   file simply dry-runs again, which is safe but confusing.
--
--   Pinning what the first run printed would prove only that the database
--   hadn't changed between two runs of the same code. Pinning the reviewed
--   values proves the database is what the review said it was. An earlier
--   draft of this file found 0 indexes instead of 24, for the reason in
--   section 3's comment; "set it to what it printed" would have locked
--   that in and left all 24 behind.
--
-- DO NOT RUN ON PRODUCTION. Section 1 refuses there: production's ledger
-- has none of the seven filenames.
--
-- Requires: 20261123T2000 (schema_rollbacks, record_rollback).
-- SAFE TO RUN TWICE: the second run finds no composite keys and refuses.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Preconditions
-- -----------------------------------------------------------------------------
DO $$
DECLARE n int; files text[];
BEGIN
  IF to_regprocedure('record_rollback(text, text)') IS NULL THEN
    RAISE EXCEPTION '20261123T2000 has not run here: record_rollback does not exist';
  END IF;

  SELECT array_agg(filename ORDER BY filename) INTO files
    FROM schema_migrations WHERE filename LIKE '20261123T18%';

  IF files IS NULL THEN
    RAISE EXCEPTION 'none of the same-firm migrations are in this ledger: this is not staging, or they have already been rolled back';
  END IF;
  IF array_length(files, 1) <> 7 THEN
    RAISE EXCEPTION 'expected the seven same-firm migrations, found %: %',
      array_length(files, 1), array_to_string(files, ', ');
  END IF;
  IF NOT (files[1] LIKE '20261123T1810%') THEN
    RAISE EXCEPTION 'the first same-firm migration should be 20261123T1810, found %', files[1];
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. Collect every composite same-firm key, and prove we can rebuild it
--
-- A key qualifies when it has exactly two columns on each side and one of
-- them, on each side, is organization_id. The other column on each side is
-- the pointer the single-column key used.
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE _rb_keys ON COMMIT DROP AS
SELECT
  c.conname,
  src.relname AS src,
  tgt.relname AS tgt,
  c.confdeltype, c.confupdtype, c.confmatchtype,
  c.condeferrable, c.condeferred, c.convalidated, c.confdelsetcols,
  (SELECT a.attname FROM unnest(c.conkey) k
     JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k
    WHERE a.attname <> 'organization_id')  AS ptr,
  (SELECT a.attname FROM unnest(c.confkey) k
     JOIN pg_attribute a ON a.attrelid = c.confrelid AND a.attnum = k
    WHERE a.attname <> 'organization_id')  AS tptr,
  (SELECT a.attnum FROM unnest(c.conkey) k
     JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k
    WHERE a.attname <> 'organization_id')  AS ptr_attnum
FROM pg_constraint c
JOIN pg_class     src ON src.oid = c.conrelid
JOIN pg_class     tgt ON tgt.oid = c.confrelid
JOIN pg_namespace n   ON n.oid   = src.relnamespace
WHERE c.contype = 'f'
  AND n.nspname = 'public'
  AND array_length(c.conkey,  1) = 2
  AND array_length(c.confkey, 1) = 2
  AND EXISTS (SELECT 1 FROM unnest(c.conkey) k
                JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k
               WHERE a.attname = 'organization_id')
  AND EXISTS (SELECT 1 FROM unnest(c.confkey) k
                JOIN pg_attribute a ON a.attrelid = c.confrelid AND a.attnum = k
               WHERE a.attname = 'organization_id');

ALTER TABLE _rb_keys ADD COLUMN def text;

UPDATE _rb_keys SET def =
     format('FOREIGN KEY (%I) REFERENCES %I(%I)', ptr, tgt, tptr)
  || CASE confdeltype WHEN 'c' THEN ' ON DELETE CASCADE'
                      WHEN 'n' THEN ' ON DELETE SET NULL'
                      WHEN 'r' THEN ' ON DELETE RESTRICT'
                      WHEN 'd' THEN ' ON DELETE SET DEFAULT'
                      ELSE '' END
  || CASE WHEN condeferrable
          THEN CASE WHEN condeferred THEN ' DEFERRABLE INITIALLY DEFERRED'
                    ELSE ' DEFERRABLE' END
          ELSE '' END;

-- Every way the rebuild could be silently wrong, refused rather than guessed.
DO $$
DECLARE n int; bad text;
BEGIN
  SELECT count(*) INTO n FROM _rb_keys;
  IF n = 0 THEN
    RAISE EXCEPTION 'no composite same-firm keys here: already rolled back, or this is production';
  END IF;

  SELECT string_agg(conname, ', ') INTO bad FROM _rb_keys WHERE ptr IS NULL OR tptr IS NULL;
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'cannot tell which column is the pointer on: %', bad;
  END IF;

  -- ON UPDATE is not carried by the rebuild, so refuse if any key has one.
  SELECT string_agg(conname, ', ') INTO bad FROM _rb_keys WHERE confupdtype <> 'a';
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'these keys have an ON UPDATE rule this file would drop: %', bad;
  END IF;

  -- MATCH is not carried either.
  SELECT string_agg(conname, ', ') INTO bad FROM _rb_keys WHERE confmatchtype <> 's';
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'these keys are not MATCH SIMPLE: %', bad;
  END IF;

  SELECT string_agg(conname, ', ') INTO bad FROM _rb_keys WHERE NOT convalidated;
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'these keys are NOT VALID; the rebuild would validate them: %', bad;
  END IF;

  -- A targeted SET NULL must name exactly the pointer column. Anything else
  -- means the shape is not what these migrations made, so stop.
  SELECT string_agg(conname, ', ') INTO bad FROM _rb_keys
   WHERE confdeltype = 'n'
     AND confdelsetcols IS NOT NULL
     AND confdelsetcols <> ARRAY[ptr_attnum]::int2[];
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'these SET NULL keys name columns other than their pointer: %', bad;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 3. The unique indexes on (id, organization_id) that only these keys needed
--
-- Only on the tables these keys point at, only unique, only exactly those
-- two columns, never a primary key and never one backing a constraint.
--
-- The contype <> 'f' matters. pg_constraint.conindid holds the index a
-- constraint BACKS for a unique or primary key, but for a foreign key it
-- holds the index that key REFERENCES. Without it, every one of these 24
-- indexes is excluded precisely because the composite keys point at them,
-- and the file silently drops nothing.
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE _rb_idx ON COMMIT DROP AS
SELECT ic.relname AS idxname, tc.relname AS tbl
FROM pg_index i
JOIN pg_class     ic ON ic.oid = i.indexrelid
JOIN pg_class     tc ON tc.oid = i.indrelid
JOIN pg_namespace n  ON n.oid  = tc.relnamespace
WHERE n.nspname = 'public'
  AND i.indisunique
  AND NOT i.indisprimary
  AND i.indnatts = 2
  AND i.indnkeyatts = 2
  AND i.indpred IS NULL
  AND NOT EXISTS (SELECT 1 FROM pg_constraint pc
                   WHERE pc.conindid = i.indexrelid AND pc.contype <> 'f')
  AND (SELECT array_agg(a.attname::text ORDER BY a.attname)
         FROM generate_series(0, i.indnatts - 1) g(ord)
         JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[g.ord])
      = ARRAY['id', 'organization_id']
  AND tc.relname IN (SELECT DISTINCT tgt FROM _rb_keys);

-- -----------------------------------------------------------------------------
-- 4. Show the work, or do it
--
-- With neither flag set this raises and the whole transaction is discarded.
-- With both set to the reviewed values in the header, it applies. The
-- message's continued lines carry no E: in SQL, string literals continued over
-- a newline join only when the continuations are plain '...', and the first
-- segment's E applies to the whole (E'a\n' then E'b' is a syntax error).
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  want_md5  text := NULLIF(current_setting('hub.rollback_expect_keys_md5', true), '');
  want_idx  text := NULLIF(current_setting('hub.rollback_expect_indexes',  true), '');
  got_md5   text;
  n_keys    int;
  n_idx     int;
  k         record;
  f         text;
BEGIN
  SELECT count(*) INTO n_keys FROM _rb_keys;
  SELECT count(*) INTO n_idx  FROM _rb_idx;
  SELECT md5(string_agg(src || '.' || conname || ' ' || def, chr(10) ORDER BY src, conname))
    INTO got_md5 FROM _rb_keys;

  IF want_md5 IS NULL OR want_idx IS NULL THEN
    RAISE EXCEPTION E'DRY RUN — nothing applied.\n'
      '  keys to restore : %\n'
      '  definitions md5 : %\n'
      '                    the review says 472f5c2ab60c209c83b45bdb6a0fc775\n'
      '  indexes to drop : %\n'
      '                    the review says 24\n'
      '  index names     : %\n'
      '  files to record : %\n'
      '\n'
      'If both match the review, run again with the two SET lines from this\n'
      'file''s header at the top of the same paste. Do NOT copy the figures\n'
      'above into them: pinning what this run printed proves only that\n'
      'nothing changed between two runs of the same code.',
      n_keys, got_md5, n_idx,
      (SELECT string_agg(idxname, ', ' ORDER BY idxname) FROM _rb_idx),
      (SELECT string_agg(filename, ', ' ORDER BY filename) FROM schema_migrations
         WHERE filename LIKE '20261123T18%');
  END IF;

  IF got_md5 <> want_md5 THEN
    RAISE EXCEPTION 'the definitions are not the ones you checked: expected %, computed %', want_md5, got_md5;
  END IF;
  IF n_idx <> want_idx::int THEN
    RAISE EXCEPTION 'expected % indexes to drop, found %', want_idx, n_idx;
  END IF;

  -- 4a. Each composite key back to its single-column form, one statement each.
  FOR k IN SELECT * FROM _rb_keys ORDER BY src, conname LOOP
    EXECUTE format('ALTER TABLE %I DROP CONSTRAINT %I, ADD CONSTRAINT %I %s',
                   k.src, k.conname, k.conname, k.def);
  END LOOP;

  -- 4b. Then, and only then, the indexes they depended on.
  FOR k IN SELECT * FROM _rb_idx ORDER BY idxname LOOP
    EXECUTE format('DROP INDEX %I', k.idxname);
  END LOOP;

  -- 4c. Record all seven. record_rollback removes the ledger row itself and
  --     stamps the time from clock_timestamp(), so these are exact.
  FOR f IN SELECT filename FROM schema_migrations
            WHERE filename LIKE '20261123T18%' ORDER BY filename LOOP
    PERFORM record_rollback(f,
      'Staging put back to production''s schema for hellophone#27 part 2. '
      'Production rolled these seven back on 23 November, when composite keys '
      'stopped the app''s PostgREST column-name embed hints from resolving.');
  END LOOP;

  RAISE NOTICE 'restored % keys, dropped % indexes, recorded 7 rollbacks', n_keys, n_idx;
END $$;

COMMIT;

-- =============================================================================
-- Verification — run AFTER the file, as its own statement. One block,
-- everything rolled back by the closing RAISE. As postgres, in the SQL
-- editor. Read the RAISE's text, not the pane's status.
--
-- DO $$
-- DECLARE r text := ''; n int; m int;
-- BEGIN
--   -- ---- 1. no composite same-firm keys left ------------------------------
--   SELECT count(*) INTO n FROM pg_constraint c
--     JOIN pg_class src ON src.oid = c.conrelid
--     JOIN pg_namespace ns ON ns.oid = src.relnamespace
--    WHERE c.contype = 'f' AND ns.nspname = 'public'
--      AND array_length(c.conkey, 1) = 2
--      AND EXISTS (SELECT 1 FROM unnest(c.conkey) k JOIN pg_attribute a
--                    ON a.attrelid = c.conrelid AND a.attnum = k
--                   WHERE a.attname = 'organization_id');
--   r := r || '1. composite same-firm keys remaining: ' || n || '   (expect 0)' || chr(10);
--
--   -- ---- 2. the single-column keys are back, with their rules -------------
--   SELECT count(*) INTO n FROM pg_constraint c
--     JOIN pg_class src ON src.oid = c.conrelid
--     JOIN pg_class tgt ON tgt.oid = c.confrelid
--     JOIN pg_namespace ns ON ns.oid = src.relnamespace
--    WHERE c.contype = 'f' AND ns.nspname = 'public'
--      AND array_length(c.conkey, 1) = 1
--      AND EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = c.conrelid
--                    AND a.attname = 'organization_id' AND a.attnotnull)
--      AND EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = c.confrelid
--                    AND a.attname = 'organization_id' AND a.attnotnull);
--   SELECT count(*) INTO m FROM pg_constraint c
--    WHERE c.contype = 'f' AND c.confdeltype = 'n' AND c.confdelsetcols IS NOT NULL;
--   r := r || '2. family-A-shaped single-column keys: ' || n
--          || ', keys still carrying a SET NULL column list: ' || m
--          || '   (expect 123, 0)' || chr(10);
--
--   -- ---- 3. the indexes are gone ------------------------------------------
--   SELECT count(*) INTO n FROM pg_class ic
--     JOIN pg_namespace ns ON ns.oid = ic.relnamespace
--    WHERE ns.nspname = 'public' AND ic.relkind = 'i' AND ic.relname LIKE '%\_id\_organization\_uq';
--   r := r || '3. (id, organization_id) unique indexes left: ' || n || '   (expect 0)' || chr(10);
--
--   -- ---- 4. the ledger no longer claims they ran --------------------------
--   SELECT count(*) INTO n FROM schema_migrations WHERE filename LIKE '20261123T18%';
--   r := r || '4. same-firm files still in schema_migrations: ' || n || '   (expect 0)' || chr(10);
--
--   -- ---- 5. seven rollbacks, recorded, with exact times -------------------
--   SELECT count(*), count(*) FILTER (WHERE recorded_how = 'record_rollback'
--            AND rolled_back_at IS NOT NULL AND applied_at_precision = 'exact')
--     INTO n, m FROM schema_rollbacks WHERE filename LIKE '20261123T18%';
--   r := r || '5. rollback rows: ' || n || ', of them exact and recorded live: ' || m
--          || '   (expect 7, 7)' || chr(10);
--
--   -- ---- 6. a spot check you can read ------------------------------------
--   r := r || '6. contact_phones keys: '
--          || COALESCE((SELECT string_agg(conname || ' -> ' || pg_get_constraintdef(c.oid), ' | '
--                                         ORDER BY conname)
--                         FROM pg_constraint c JOIN pg_class s ON s.oid = c.conrelid
--                        WHERE s.relname = 'contact_phones' AND c.contype = 'f'), 'none')
--          || chr(10) || '   (expect single-column FOREIGN KEY, no (organization_id) anywhere)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261124T1500_staging_rollback_of_the_same_firm_keys (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
