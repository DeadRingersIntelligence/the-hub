-- =============================================================================
-- 20261103T2000_people_name_uniqueness_matches.sql
-- The Hub — staging has been enforcing a rule production does not.
--
-- WHAT IS WRONG. people_org_name_uq is a unique index on
-- (organization_id, full_name). On production and in db/migrations/003 as it
-- stands on main it carries WHERE merged_into IS NULL. On staging it has no
-- WHERE clause at all, so staging ran an earlier 003 and has never been
-- corrected.
--
-- WHAT THAT MEANS IN PRACTICE. On production a person who has been merged away
-- stops holding their name, so a firm can create a new person with that name.
-- On staging the merged-away row still occupies it and the insert fails. The
-- test database is STRICTER than the live one.
--
-- WHY THAT ORDER IS THE DANGEROUS ONE. A looser test environment hides
-- mistakes; a stricter one invents them, and worse, it quietly passes tests
-- that would not pass on production. Today's merge-chain work in
-- 20261102T2200 was proved on staging under a uniqueness rule production does
-- not have. Chain formation is about merged_into pointing at a survivor, not
-- about names, so this very probably did not affect those results — but
-- "probably did not" is the whole reason to close it rather than write it
-- down. 2200's verification should be re-run on staging once this has
-- applied, and then it will have been proved against production's rules.
--
-- THIS CANNOT FAIL ON DATA, and it is worth saying why rather than adding a
-- duplicate check that could never fire. The new index is strictly LOOSER than
-- the one staging holds: every pair that satisfies "unique across all rows"
-- also satisfies "unique across unmerged rows". A rebuild in this direction
-- has nothing to reject. The reverse — production's rule tightening to
-- staging's — would need the duplicate check, and that is not what this does.
--
-- ON PRODUCTION THIS SHOULD DO NOTHING. The index is already right there; the
-- precondition recognises it and skips.
--
-- Requires: 003 (people, merged_into, the index).
-- Safe to run twice.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Three states, read from the index definition itself
--
-- pg_get_indexdef rather than a stored hash: the thing being compared is a
-- definition the server will print back, and comparing it to the text we mean
-- to install is more direct than comparing both to a number.
--
-- Matched on the predicate rather than on the whole string, because
-- pg_get_indexdef also carries the index name, the schema, the access method
-- and the operator classes, and a difference in any of those is a different
-- problem that this file should refuse rather than silently rewrite.
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_def text; v_pred text; v_unique boolean; v_cols text;
BEGIN
  SELECT pg_get_indexdef(i.indexrelid),
         pg_get_expr(i.indpred, i.indrelid),
         i.indisunique,
         (SELECT string_agg(a.attname, ',' ORDER BY k.ord)
            FROM unnest(i.indkey::smallint[]) WITH ORDINALITY AS k(attnum, ord)
            JOIN pg_attribute a
              ON a.attrelid = i.indrelid AND a.attnum = k.attnum)
    INTO v_def, v_pred, v_unique, v_cols
    FROM pg_index i
   WHERE i.indexrelid = to_regclass('public.people_org_name_uq');

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'people_org_name_uq does not exist; run 003 first';
  END IF;

  IF NOT v_unique OR v_cols IS DISTINCT FROM 'organization_id,full_name' THEN
    RAISE EXCEPTION
      'people_org_name_uq is not a unique index on (organization_id, full_name) — unique=%, columns=%: %',
      v_unique, v_cols, v_def
      USING HINT = 'Something other than the missing WHERE clause has changed here. Read it before replacing it.';
  END IF;

  IF v_pred IS NULL THEN
    RAISE NOTICE 'found staging''s unconditional index, as expected; replacing with the partial one';
  ELSIF v_pred = '(merged_into IS NULL)' THEN
    RAISE NOTICE 'already partial on merged_into IS NULL — this is production''s shape, or this file has run';
  ELSE
    RAISE EXCEPTION
      'people_org_name_uq has an unexpected predicate %; stop and look', v_pred
      USING HINT = 'Expected either no predicate (staging) or (merged_into IS NULL) (production).';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. The index production and the repository both have
--
-- DROP and CREATE rather than CREATE ... IF NOT EXISTS under a different name
-- and a rename: the name is referenced by nothing but error messages, the
-- table is small, and a second index under a temporary name is a state
-- somebody could be left in if this transaction were interrupted.
--
-- Not CONCURRENTLY, which cannot run inside a transaction block. people is
-- small enough that the lock is measured in milliseconds, and the whole point
-- of a migration being one transaction is that a failure leaves nothing
-- behind.
-- -----------------------------------------------------------------------------
DROP INDEX IF EXISTS people_org_name_uq;

CREATE UNIQUE INDEX people_org_name_uq
  ON people (organization_id, full_name)
  WHERE merged_into IS NULL;

COMMENT ON INDEX people_org_name_uq IS
  'A firm cannot have two people with the same name — among the people it '
  'still has. Someone merged away releases their name, which is what makes a '
  'merge a correction rather than a permanent reservation. Staging enforced '
  'this across all rows, merged ones included, until 20261103T2000: it had '
  'run an earlier 003 and was stricter than production for months.';

-- -----------------------------------------------------------------------------
-- 3. Record it
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM record_migration(
    '20261103T2000_people_name_uniqueness_matches.sql',
    NULL,
    'Staging''s people_org_name_uq rebuilt with WHERE merged_into IS NULL, to '
    'match production and db/migrations/003. A no-op on production.');
END $$;

COMMIT;

-- =============================================================================
-- STILL TO DO
--
-- * RE-RUN 20261102T2200's VERIFICATION ON STAGING. It passed under a
--   uniqueness rule production does not have. Expected to pass again — the
--   merge-chain guard is about merged_into pointing at a survivor and touches
--   no name — but that expectation is exactly what re-running is for.
--
-- * 014 HAS NEVER RUN ON STAGING and is the other half of this parity work:
--   three columns, two enum types, a CHECK constraint, and the functions
--   behavior_detail and section_scores. That one is not a correction to make
--   by hand — the safest version is running the repository's own
--   014_measurement_and_menu_scoring.sql on staging, byte-identical to what
--   production ran, so the resulting function bodies match by construction
--   rather than by my retyping them.
--
-- * WHY DID STAGING RUN AN OLDER 003? Unanswerable from the catalogue and
--   probably unanswerable at all: it predates the ledger by months. The
--   useful response is not an investigation but the structural diff on a
--   schedule, which is what found this.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- The behaviour tests are the point. An index definition can be read from the
-- catalogue; whether a merged-away person releases their name can only be
-- found out by trying it.
--
-- DO $$
-- DECLARE
--   r text := ''; v_org uuid; v_a uuid; v_b uuid;
-- BEGIN
--   r := r || 'index now reads:' || chr(10) || '    '
--          || COALESCE(pg_get_indexdef(to_regclass('public.people_org_name_uq')), 'MISSING')
--          || chr(10)
--          || '   (expect ... UNIQUE ... (organization_id, full_name) WHERE '
--          || '(merged_into IS NULL) — identical on both databases)' || chr(10);
--
--   -- A firm of our own, so nothing below touches a real one. client_type is
--   -- the only NOT NULL column on organizations without a default, so it has
--   -- to be named even though nothing here depends on its value.
--   INSERT INTO organizations (name, client_type)
--   VALUES ('ZZZ verification firm', 'funeral_home')
--     RETURNING id INTO v_org;
--
--   INSERT INTO people (organization_id, full_name) VALUES (v_org, 'Pat Vance')
--     RETURNING id INTO v_a;
--
--   -- Still a live person: the second insert must be refused.
--   BEGIN
--     INSERT INTO people (organization_id, full_name) VALUES (v_org, 'Pat Vance');
--     r := r || 'duplicate name while unmerged: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN unique_violation THEN
--     r := r || 'duplicate name while unmerged: refused — correct' || chr(10); END;
--
--   -- Merge them away, and the name should come free. This is the line that
--   -- behaves differently on the two databases today.
--   INSERT INTO people (organization_id, full_name) VALUES (v_org, 'Robin Vance')
--     RETURNING id INTO v_b;
--   UPDATE people SET merged_into = v_b WHERE id = v_a;
--
--   BEGIN
--     INSERT INTO people (organization_id, full_name) VALUES (v_org, 'Pat Vance');
--     r := r || 'same name after the holder was merged away: allowed — correct, '
--            || 'and this is what staging refused before today' || chr(10);
--   EXCEPTION WHEN unique_violation THEN
--     r := r || 'same name after the holder was merged away: REFUSED (BAD — '
--            || 'the index is still unconditional)' || chr(10); END;
--
--   -- And the rule still binds across the two live rows.
--   BEGIN
--     INSERT INTO people (organization_id, full_name) VALUES (v_org, 'Robin Vance');
--     r := r || 'duplicate of the surviving person: ALLOWED (BAD — the rebuild '
--            || 'dropped more than the predicate)' || chr(10);
--   EXCEPTION WHEN unique_violation THEN
--     r := r || 'duplicate of the surviving person: refused — correct' || chr(10); END;
--
--   -- A different firm is unaffected by any of it.
--   r := r || 'rows in the verification firm: '
--          || (SELECT count(*) FROM people WHERE organization_id = v_org)
--          || '   (expect 3 — Pat merged, Robin, Pat again)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261103T2000_people_name_uniqueness_matches (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
