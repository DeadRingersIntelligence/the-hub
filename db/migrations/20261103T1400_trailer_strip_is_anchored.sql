-- =============================================================================
-- 20261103T1400_trailer_strip_is_anchored.sql
-- The Hub — submitted_text() should not depend on the trailer having
-- exactly three lines.
--
-- WHAT IS WRONG. 20261103T1200 strips the SQL editor's trailer with a regex
-- that spells out its current shape: a source line, a user line, a date line,
-- in that order, at the end of the submission. It works, today, exactly.
--
-- The problem is what happens when it stops working. If the editor adds a
-- fourth line, or reorders two, or renames one, the pattern matches nothing
-- and submitted_text() returns the raw query with the trailer still on it.
-- Every ran_md5 from that moment includes a session id and a millisecond
-- timestamp, so staging and production stop agreeing — and the failure looks
-- exactly like the drift the column exists to detect. A check that fails by
-- reporting drift is worse than no check, because somebody acts on it.
--
-- THE FIX. Anchor on the one part that is a marker rather than a format —
-- "-- source: dashboard" at the start of the trailer — and remove everything
-- from there to the end. A fourth line, a reordering, a renamed field: all
-- still stripped, because none of them is being matched.
--
-- IT CHANGES NOTHING TODAY, which is the point and is worth proving rather
-- than asserting. Against the current three-line trailer both expressions
-- return the same text, so every ran_md5 already recorded stays valid and the
-- thirteen rows on each database are unaffected. The verification asserts
-- that equality rather than taking it on trust.
--
-- ALSO HERE, two comment corrections that could not be made in place because
-- they live inside 20261103T1200's transaction block:
--
--   ran_len IS CHARACTERS, NOT BYTES. length() counts characters. The two
--   self-recorded rows read 10111 and 6666 against files of 10125 and 6674
--   bytes; the difference is em dashes in the comments. Harmless — it is a
--   diagnostic, and either unit tells one statement from a pasted file — but
--   the comment said neither and a reader would assume bytes.
--
--   THE QUERY TEXT IS NEVER STORED. Only its md5 and its length. Worth saying
--   in the table comment, because the raw text carries a session identity and
--   anyone reading this design should be able to see at a glance that it is
--   not being kept.
--
--   AND "THE EDITOR CHANGED ITS TRAILER" joins the list of innocent
--   explanations for a ran_md5 mismatch. After this file it should be a rare
--   one, but it is no longer impossible — only harder.
--
-- THE TWO BODY HASHES IN SECTION 1 ARE MEASURED, not placeholders. Read on
-- 2026-11-03, agreeing three ways and two ways respectively:
--
--   302a9c873d7a7350696012de540a75fd  (145 chars)  20261103T1200's body, read
--                                     from staging, from production, and
--                                     hashed from 1200's own file text
--   8d363c7ee9c576690bc6f22b356dd56a  (81 chars)   this file's body, read from
--                                     staging after a rolled-back CREATE, and
--                                     hashed from this file's own text
--
-- The file text agreeing with what the database holds is the part worth
-- noting: the precondition is checking the thing this file ships, not a value
-- transcribed from somewhere and hoped over.
--
-- APPLIED ON STAGING AND PRODUCTION, 2026-11-03, block md5
-- c24089ae0c380963b4c67bbb0dc490bb, recorded as its own ran_md5 on both. The
-- staging dry run passed every line first.
--
-- Requires: 20261103T1200 (submitted_text, schema_migrations).
-- Safe to run twice.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. It is there, and it is the one this file expects to replace
--
-- Three states, as usual: 1200's exact-shape regex, this file's anchored one,
-- or something else — and something else stops. A function body nobody has
-- read is not a body to replace blind, and this one is load-bearing for every
-- fingerprint the ledger will ever take.
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_md5 text;
BEGIN
  SELECT md5(prosrc) INTO v_md5
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'submitted_text'
     AND p.pronargs = 0;

  IF v_md5 IS NULL THEN
    RAISE EXCEPTION 'submitted_text() does not exist; run 20261103T1200 first';
  ELSIF v_md5 = '8d363c7ee9c576690bc6f22b356dd56a' THEN
    RAISE NOTICE 'already anchored — this migration has run before';
  ELSIF v_md5 = '302a9c873d7a7350696012de540a75fd' THEN
    RAISE NOTICE 'found 20261103T1200''s exact-shape regex, as expected';
  ELSE
    RAISE EXCEPTION
      'submitted_text() is neither 20261103T1200''s body nor this file''s (md5 %); stop and read it', v_md5
      USING HINT = 'Every ran_md5 in the ledger was taken through this function.';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. Anchored on the marker, not on the shape
--
-- '.' matches a newline in Postgres by default — newline-sensitive matching is
-- off unless asked for — so '.*$' from the marker consumes the whole trailer
-- however many lines it has.
--
-- The marker keeps its leading two newlines. Without them a line of ordinary
-- SQL that happened to contain the words would start the match; with them, the
-- text has to be preceded by a blank line, which is the trailer's own shape
-- and not something a statement produces by accident. It is not proof against
-- a file that deliberately quotes the trailer after a blank line — this file
-- is careful not to, writing it on one line with escaped newlines — but a
-- migration that does will strip its own tail and see a short ran_len, which
-- is visible rather than silent.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION submitted_text() RETURNS text
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT regexp_replace(current_query(), E'\n\n-- source: dashboard\n.*$', '');
$$;

COMMENT ON FUNCTION submitted_text() IS
  'current_query() with the Supabase SQL editor''s trailer removed — the '
  'block beginning "-- source: dashboard" that it appends to every submission, '
  'carrying a session id and a millisecond timestamp. Hashing the raw query '
  'would make two identical pastes compare unequal and the ledger''s ran_md5 '
  'useless. Anchored on that marker and removing everything after it, rather '
  'than matching the trailer''s current three-line shape, so that a fourth '
  'line or a reordering does not silently stop the strip and turn every later '
  'comparison into a false drift report. On a client that appends nothing, '
  'such as psql, this returns current_query() unchanged.';

-- -----------------------------------------------------------------------------
-- 3. The two comments that could not be fixed in place
-- -----------------------------------------------------------------------------
COMMENT ON COLUMN schema_migrations.ran_len IS
  'Length IN CHARACTERS of the submitted text — length(), not octet_length(), '
  'so a file with em dashes reads shorter than its byte count. Tens means one '
  'statement was sent; thousands means a block or a file was pasted. It is '
  'what makes a ran_md5 mismatch diagnosable instead of alarming.';

COMMENT ON COLUMN schema_migrations.ran_md5 IS
  'md5() of the text the client submitted for the most recent run, with the '
  'editor trailer stripped by submitted_text(). THE TEXT ITSELF IS NEVER '
  'STORED — only this hash and its length — because it carries the submitting '
  'session''s identity. THIS VALUE SHOULD MATCH ON STAGING AND PRODUCTION; '
  'when it does not, the two databases were given different text. Before '
  'calling that drift, rule out: a file annotated after it ran (which changes '
  'sha256 and must not change this), CRLF against LF, a multi-block file where '
  'only one block records itself, and the editor having changed its trailer '
  'beyond what submitted_text() strips.';

-- -----------------------------------------------------------------------------
-- 4. Record it
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM record_migration(
    '20261103T1400_trailer_strip_is_anchored.sql',
    NULL,
    'Anchors submitted_text() on the trailer''s marker instead of its '
    'three-line shape. No effect on existing ran_md5 values: both expressions '
    'return the same text against the current trailer.');
END $$;

COMMIT;

-- =============================================================================
-- STILL TO DO
--
-- * A FILE THAT CANNOT CHECK ITS OWN PRECONDITION SHOULD SAY SO IN THE FILE.
--   Section 1's hashes shipped as placeholders, because the Hub has no
--   database and md5(prosrc) is not computable from a file alone — prosrc is
--   the body as the server stored it, not as the file spells it. They were
--   measured and substituted before this ran. The general rule that earns:
--   when a migration needs a value only a database can give, the placeholder
--   goes in STILL TO DO where it will be read, never inline where it looks
--   like a measurement.
--
-- * SUBMITTED TEXT IS STILL CLIENT-SHAPED. Nothing stops a future client from
--   prepending rather than appending, or from rewriting the statement before
--   sending it. ran_md5 is a comparison between two runs, not a signature, and
--   should never be relied on as one.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- DO $$
-- DECLARE
--   r text := ''; v_exact text; v_anchored text;
-- BEGIN
--   -- The change is a no-op against today's trailer. Proved, not asserted:
--   -- both expressions are applied to the same live submission here.
--   v_exact := regexp_replace(current_query(),
--                E'\n\n-- source: dashboard\n-- user: [^\n]*\n-- date: [^\n]*$', '');
--   v_anchored := regexp_replace(current_query(),
--                   E'\n\n-- source: dashboard\n.*$', '');
--   r := r || 'exact-shape and anchored strips agree today: '
--          || (v_exact = v_anchored)::text
--          || '   (expect true — this is what makes the change safe for the '
--          || 'ran_md5 values already recorded)' || chr(10);
--   r := r || 'submitted_text() agrees with both: '
--          || (submitted_text() = v_anchored)::text || '   (expect true)' || chr(10);
--
--   r := r || 'raw / stripped length: '
--          || length(current_query()) || ' / ' || length(submitted_text())
--          || '   (expect 110 characters shorter in the SQL editor, identical '
--          || 'under psql)' || chr(10);
--   r := r || 'a trailer survives at the END of the stripped text: '
--          || (submitted_text() ~ E'\n-- source: dashboard(\n.*)?$')::text
--          || '   (expect false. End-anchored, like 1200''s corrected test: '
--          || 'an unanchored match would be true the moment any line of any '
--          || 'migration started with that marker, which is the bug this '
--          || 'file''s predecessor shipped)' || chr(10);
--
--   -- The point of the change: a trailer this function has never seen.
--   r := r || 'a FOUR-line trailer would still be stripped: '
--          || (regexp_replace(
--                'SELECT 1;' || E'\n\n-- source: dashboard\n-- user: x\n-- date: y\n-- client: z',
--                E'\n\n-- source: dashboard\n.*$', '') = 'SELECT 1;')::text
--          || '   (expect true. Against 20261103T1200''s regex this is false, '
--          || 'and the trailer would have gone into every hash from then on)'
--          || chr(10);
--   r := r || '    and under the old expression: '
--          || (regexp_replace(
--                'SELECT 1;' || E'\n\n-- source: dashboard\n-- user: x\n-- date: y\n-- client: z',
--                E'\n\n-- source: dashboard\n-- user: [^\n]*\n-- date: [^\n]*$', '') = 'SELECT 1;')::text
--          || '   (expect false — this is the failure being removed)' || chr(10);
--
--   -- The ledger is undisturbed.
--   r := r || 'ledger rows / backfilled / self-recorded: '
--          || (SELECT count(*) FROM schema_migrations) || ' / '
--          || (SELECT count(*) FROM schema_migrations WHERE ran_md5 IS NULL) || ' / '
--          || (SELECT count(*) FROM schema_migrations WHERE ran_md5 IS NOT NULL)
--          || '   (expect 14 / 11 / 3 after this file records itself)' || chr(10);
--   r := r || '1200 and 1300 still hold their block md5s: '
--          || (SELECT (count(*) = 2) FROM schema_migrations
--               WHERE (filename = '20261103T1200_schema_migrations_ledger.sql'
--                      AND ran_md5 = 'f07ecbce3447791b9ed7688b50328e9c')
--                  OR (filename = '20261103T1300_backfill_applied_migrations.sql'
--                      AND ran_md5 = 'bcf7f807327f3b920be2b30d36676248'))::text
--          || '   (expect true — this file must not touch them)' || chr(10);
--
--   r := r || 'ran_len comment now says characters: '
--          || (col_description('public.schema_migrations'::regclass,
--                (SELECT attnum FROM pg_attribute
--                  WHERE attrelid = 'public.schema_migrations'::regclass
--                    AND attname = 'ran_len')) LIKE '%CHARACTERS%')::text
--          || '   (expect true)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261103T1400_trailer_strip_is_anchored (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
