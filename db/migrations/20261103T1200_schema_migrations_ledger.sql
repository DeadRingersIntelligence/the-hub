-- =============================================================================
-- 20261103T1200_schema_migrations_ledger.sql
-- The Hub — a record of which migration ran on which database.
--
-- APPLIED ON STAGING AND PRODUCTION, 2026-11-03, block md5
-- f07ecbce3447791b9ed7688b50328e9c. It superseded an earlier form (block
-- 7fa3265e) whose ran_md5 included the SQL editor's trailer; staging held that
-- form and took the reshape path, production held nothing and took the create
-- path, and the create path was rehearsed on staging in a rolled-back run
-- first. Both databases now record ran_md5 f07ecbce for this file, equal to
-- the block md5, so the strip works.
--
-- TWO BUGS IN THE VERIFICATION BLOCK BELOW, FIXED IN PLACE 2026-11-03. The
-- body is untouched and its md5 is unchanged.
--
--   The trailer test used LIKE '%-- source: dashboard%' on the stripped text
--   and so always reported true — this file quotes the trailer in its own
--   comments, in the COMMENT ON FUNCTION text, and in the test line itself.
--   It was testing whether the file mentions the trailer, not whether the
--   strip removed one. Now anchored on the end of the text, which is the only
--   place a real trailer can be.
--
--   The expected length difference said 70-100. The trailer is 110 characters.
--   A range invented rather than measured, and wrong.
--
-- Neither bug reached the database. Both are the same mistake: a check written
-- to pass rather than to fail, in a file whose whole subject is checks that
-- quietly stop meaning anything.
--
-- WHY. Neither database records Hub migrations. The only migration tables are
-- Supabase's own, for auth, realtime and storage. So the question "has this
-- run here?" has only ever been answerable by reading the catalogue and
-- inferring backwards from the objects a file would have created — which is
-- how staging went a month without 014, with nobody able to notice, because
-- noticing required someone to go looking for a column they had no reason to
-- think was missing.
--
-- WHAT THIS IS NOT. It is not a history. It starts today, and a missing row
-- for anything applied before 2026-11-03 means nothing at all. The table
-- comment says so, so that the gap cannot be read later as evidence.
--
-- TWO HASHES, BECAUSE THEY ANSWER DIFFERENT QUESTIONS.
--
--   sha256  is the file, supplied by whoever applied it. A file cannot record
--           its own sha256 — the hash covers the file that would contain it —
--           so this is an argument, not a self-report. Null means nobody
--           passed one, not that the file went unverified.
--
--   ran_md5 is md5() of the text the client submitted, read inside the
--           transaction. No argument and no circularity: it is computed from
--           text that already exists by the time it is computed.
--
-- THE CLIENT APPENDS A TRAILER, which is why section 1 exists at all. The
-- Supabase SQL editor adds this to every submission before sending it:
--
--     \n\n-- source: dashboard\n-- user: session:<uuid>\n-- date: <ISO ms>
--
-- A session id and a millisecond timestamp. Hash the raw current_query() and
-- two identical pastes produce two different numbers — so the comparison this
-- column exists for would have been defeated on its first use, silently, and
-- the first mismatch would have looked like tampering. submitted_text() strips
-- it. On a client with no trailer, such as psql, the regex matches nothing and
-- the function returns current_query() unchanged.
--
-- WHAT ran_md5 IS FOR. With the trailer gone, a verbatim block paste yields
-- exactly the reviewed block md5. But the use that needs no assumption about
-- what was pasted is the one to lead with: STAGING'S ran_md5 AND PRODUCTION'S
-- SHOULD BE EQUAL. Same file, same paste, same number. When they differ, the
-- two databases were given different text — which is precisely the 003 case,
-- where staging holds a people_org_name_uq that the repository does not, and
-- which was invisible for a month.
--
-- HOW TO READ A MISMATCH, before concluding anything:
--   * A FILE ANNOTATED AFTER IT RAN has a new sha256 and new comments, and the
--     same ran_md5. That is correct, not drift: this column records what was
--     submitted at the time, never whether the repository file still matches.
--   * CRLF AND LF hash differently. A file that crossed machines between the
--     two applies is the likeliest cause of a first mismatch, not tampering.
--   * A FILE WITH MORE THAN ONE TRANSACTION BLOCK — the ALTER TYPE … ADD VALUE
--     case, which cannot add and use a value in one transaction — records only
--     the submission that called record_migration. Such a file should call it
--     in each block, with the block named in note.
--
-- applied_by IS A DATABASE ROLE, NOT A PERSON. Every apply goes through the
-- SQL editor as postgres, so current_user says nothing useful. Pass a fourth
-- argument to say who, or leave it and accept 'postgres'.
--
-- A BACKFILLED ROW HOLDS NULL IN EVERY COLUMN THAT DESCRIBES THE RUN:
-- first_applied_at, applied_at, ran_md5, ran_len. That is why the two
-- timestamps are nullable despite having defaults — the default fires for
-- anything that records itself, and a NULL is a deliberate statement that the
-- run happened elsewhere and its time is not known to us.
--
-- NEW OBJECTS IN public GET THE DEFAULT PRIVILEGES, which is the trap this
-- work exists to close. A table created right now is granted to authenticated
-- (arwdxtm on both databases) and to anon (xtm on production, arwdxtm on
-- staging), because pg_default_acl still says so and the sweep that fixes it
-- has not been written yet. Section 4 therefore revokes explicitly rather
-- than inheriting. When the defaults are aligned, section 4 becomes
-- redundant; it should still stay, because a table that states its own access
-- does not depend on a setting three files away being right.
--
-- Requires: nothing. It creates what it uses, and reshapes what it finds.
-- Safe to run twice, and safe to run over the earlier form.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. The text the client actually sent
--
-- One place, used by both the column defaults and record_migration, so that
-- the day the trailer changes there is one line to fix rather than three.
--
-- STABLE, not IMMUTABLE: it reads the session's current statement, which is
-- constant within a statement and nothing like constant across them. Marking
-- it IMMUTABLE would be a lie the planner is entitled to act on.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION submitted_text() RETURNS text
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT regexp_replace(
           current_query(),
           E'\n\n-- source: dashboard\n-- user: [^\n]*\n-- date: [^\n]*$',
           '');
$$;

COMMENT ON FUNCTION submitted_text() IS
  'current_query() with the Supabase SQL editor''s trailer removed — the '
  '"-- source: dashboard / -- user: session:<uuid> / -- date: <ISO ms>" block '
  'it appends to every submission. The session id and millisecond timestamp '
  'in it are different on every run, so hashing the raw query would make two '
  'identical pastes compare unequal and the column that uses it useless. On a '
  'client that appends nothing, such as psql, the regex matches nothing and '
  'this returns current_query() unchanged.';

-- -----------------------------------------------------------------------------
-- 2. The ledger
--
-- filename is the key, because that is what the question is asked with. Two
-- timestamps rather than one: first_applied_at is the fact, applied_at moves
-- if a file is deliberately run again, and keeping both means a re-run does
-- not quietly rewrite when something first landed. Both are nullable, for the
-- backfill reason in the header.
--
-- The ALTERs are not decoration. Staging already holds this table from the
-- earlier form of this file, with defaults that hash the trailer; CREATE TABLE
-- IF NOT EXISTS would leave them in place and the file would claim to be safe
-- to run twice while being nothing of the kind.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS schema_migrations (
  filename          text        PRIMARY KEY,
  first_applied_at  timestamptz DEFAULT now(),
  applied_at        timestamptz DEFAULT now(),
  applied_by        text        NOT NULL DEFAULT current_user,
  sha256            text,
  ran_md5           text        DEFAULT md5(submitted_text()),
  ran_len           integer     DEFAULT length(submitted_text()),
  note              text
);

ALTER TABLE schema_migrations ADD COLUMN IF NOT EXISTS ran_md5 text;
ALTER TABLE schema_migrations ADD COLUMN IF NOT EXISTS ran_len integer;

ALTER TABLE schema_migrations ALTER COLUMN first_applied_at DROP NOT NULL;
ALTER TABLE schema_migrations ALTER COLUMN applied_at       DROP NOT NULL;
ALTER TABLE schema_migrations ALTER COLUMN ran_md5 SET DEFAULT md5(submitted_text());
ALTER TABLE schema_migrations ALTER COLUMN ran_len SET DEFAULT length(submitted_text());

COMMENT ON TABLE schema_migrations IS
  'Which Hub migration ran on this database, and when. STARTS 2026-11-03 AND '
  'IS NOT A HISTORY: no row exists for anything applied before that date, and '
  'the absence of a row for an older file is not evidence that it did not run. '
  'Before this table, the only way to tell was to read the catalogue for the '
  'objects a file creates — which is how staging went a month without 014. '
  'A row whose run columns are all NULL was backfilled, not self-recorded.';
COMMENT ON COLUMN schema_migrations.first_applied_at IS
  'When this file first landed here. Never rewritten by a re-run. NULL on a '
  'backfilled row: the run happened before this table existed.';
COMMENT ON COLUMN schema_migrations.applied_at IS
  'The most recent run. Equal to first_applied_at unless the file was run '
  'again. NULL on a backfilled row.';
COMMENT ON COLUMN schema_migrations.applied_by IS
  'The DATABASE ROLE that ran it, which is postgres for every apply through '
  'the SQL editor, unless record_migration was passed a fourth argument '
  'naming a person. It is not an audit trail; note is where who belongs.';
COMMENT ON COLUMN schema_migrations.sha256 IS
  'The file hash, supplied by whoever applied it. A file cannot record its own '
  'hash — the hash covers the file that would contain it — so this is an '
  'argument, not a self-report. Null means nobody passed one, not unverified. '
  'It tracks the repository file, so annotating a file after it ran changes '
  'this and must not change ran_md5.';
COMMENT ON COLUMN schema_migrations.ran_md5 IS
  'md5() of the text the client submitted for the most recent run, with the '
  'editor trailer stripped by submitted_text(). THIS VALUE SHOULD MATCH ON '
  'STAGING AND PRODUCTION; when it does not, the two databases were given '
  'different text. Before calling that drift: a file annotated after it ran '
  'keeps this value and changes sha256, CRLF and LF hash differently, and a '
  'file with several transaction blocks records only the block that called '
  'record_migration. NULL means the row was backfilled.';
COMMENT ON COLUMN schema_migrations.ran_len IS
  'Length of that submitted text. Tens of bytes means one statement was sent; '
  'thousands means a block or a file was pasted. It is what makes a ran_md5 '
  'mismatch diagnosable instead of alarming.';
COMMENT ON COLUMN schema_migrations.note IS
  'Anything the next reader needs: who applied it, which block of a multi-block '
  'file this row covers, a partial apply, a hand-edited run, a revert, a file '
  'that ran on one database only and why.';

-- -----------------------------------------------------------------------------
-- 3. How a migration records itself
--
-- One call site, so that every file writes the same shape and a re-run is
-- handled in one place rather than in thirty ON CONFLICT clauses.
--
-- COALESCE on the hash and note, so a re-run that passes neither keeps what
-- the first run recorded: an argument supplied wins, an argument omitted does
-- not erase. The run columns are the exception and are always overwritten,
-- because like applied_at they describe the most recent run rather than the
-- file. That is also what lets this file repair the fingerprint its earlier
-- form left on staging.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION record_migration(
  p_filename   text,
  p_sha256     text DEFAULT NULL,
  p_note       text DEFAULT NULL,
  p_applied_by text DEFAULT NULL
) RETURNS void
LANGUAGE sql
SET search_path = public, pg_temp
AS $$
  INSERT INTO schema_migrations AS m
         (filename, sha256, note, applied_by, ran_md5, ran_len)
  VALUES (p_filename, p_sha256, p_note,
          COALESCE(p_applied_by, current_user),
          md5(submitted_text()), length(submitted_text()))
  ON CONFLICT (filename) DO UPDATE
     SET applied_at       = now(),
         first_applied_at = COALESCE(m.first_applied_at, now()),
         applied_by       = EXCLUDED.applied_by,
         sha256           = COALESCE(EXCLUDED.sha256, m.sha256),
         note             = COALESCE(EXCLUDED.note,   m.note),
         ran_md5          = EXCLUDED.ran_md5,
         ran_len          = EXCLUDED.ran_len;
$$;

COMMENT ON FUNCTION record_migration(text, text, text, text) IS
  'Last statement inside a migration''s transaction block, so the row and the '
  'work commit or roll back together: a file that fails records nothing. Call '
  'it from a DO block rather than a bare SELECT — the SQL editor appends '
  '" limit 100" to a trailing bare SELECT, which lands in the hashed text. '
  'Invoker, and executable by nobody but the owner.';

-- -----------------------------------------------------------------------------
-- 4. Nobody but the owner
--
-- RLS is enabled with no policies, which denies every row to every role that
-- is not exempt. That is the second lock; the revoked grants are the first.
-- Not FORCED, and not for the reason an earlier file of mine gave: postgres
-- holds BYPASSRLS, so FORCE would change nothing either way. It is left off
-- because there is nothing to force — no policy exists for the owner to be
-- held to.
--
-- EXECUTE on a new function is granted to PUBLIC implicitly, by a NULL proacl
-- rather than by a visible grant, which is why it is easy to miss and why it
-- is revoked here by name. submitted_text() is revoked too: it reveals the
-- text of whatever statement its caller is running.
-- -----------------------------------------------------------------------------
ALTER TABLE schema_migrations ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE schema_migrations FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION record_migration(text, text, text, text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION submitted_text()
  FROM PUBLIC, anon, authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 5. Its own row
--
-- A DO block, not a bare SELECT, for the reason in record_migration's comment.
-- On staging this overwrites the fingerprint the earlier form recorded, which
-- included the trailer; first_applied_at is kept, because that run did happen.
--
-- sha256 is null here and only here: this is the one file that cannot be
-- handed its own file hash without the argument becoming circular at the
-- moment it is written. ran_md5 is not null, because it is computed from text
-- that already exists — which is the whole point of the column.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM record_migration(
    '20261103T1200_schema_migrations_ledger.sql',
    NULL,
    'The ledger''s own row. File hash deliberately null: see the header. '
    'Supersedes an earlier form applied to staging whose ran_md5 included the '
    'editor trailer; this run overwrites that fingerprint.');
END $$;

COMMIT;

-- =============================================================================
-- STILL TO DO
--
-- * EVERY MIGRATION FROM HERE ON ENDS WITH A record_migration() CALL, in a DO
--   block, as the last statement before COMMIT. Nothing enforces that and
--   nothing can: a file that forgets is indistinguishable from a file that
--   never ran, which is the state this table was built to leave. It belongs in
--   db/README.md beside the rules it is a rule like.
--
-- * COMPARE ran_md5 ACROSS THE TWO DATABASES as part of the apply, not as an
--   investigation. It is one query and it is the cheapest drift check there is
--   for anything applied after today. Read a mismatch against the three
--   innocent explanations in the header before treating it as drift.
--
-- * THE TRAILER IS A CLIENT DETAIL AND WILL CHANGE. When it does, ran_md5 goes
--   back to including it, quietly, and the first symptom is two databases that
--   stop agreeing. The verification below asserts that nothing resembling the
--   trailer survives submitted_text(); run it, not just the migration, if the
--   editor is ever updated.
--
-- * THE SIX SNAPSHOT QUERIES that produced today's structural diff should live
--   in the repository, not in one session's scrollback — plus the three they
--   do not yet cover: table and function grants (aclexplode with acldefault
--   for NULL acls), pg_default_acl, and column comments. Grants were compared
--   separately today, by hand.
--
-- * A STRUCTURAL DIFF IS WORTH RUNNING ON A SCHEDULE, not only when something
--   smells. Today's found two items, one of them a month old. The cost of
--   running it monthly is a few minutes; the cost of not running it was a
--   month of staging proofs that were weaker than they read.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- DO $$
-- DECLARE
--   r text := ''; n int; v_first timestamptz; v_sha text; v_note text;
-- BEGIN
--   -- The trailer, first, because everything else assumes it is gone.
--   r := r || 'raw current_query() length / stripped length: '
--          || length(current_query()) || ' / ' || length(submitted_text())
--          || '   (expect stripped to be exactly 110 characters shorter in the '
--          || 'SQL editor, and identical under psql)' || chr(10);
--   r := r || 'a trailer survives at the END of the stripped text: '
--          || (submitted_text() ~ E'\n-- source: dashboard\n-- user: [^\n]*\n-- date: [^\n]*$')::text
--          || '   (expect false. Anchored, NOT a LIKE on the marker: this file '
--          || 'quotes the trailer in its own comments, so a LIKE matched the '
--          || 'file and reported true however well the strip worked)' || chr(10);
--   r := r || 'stripped text ends with my last line: '
--          || quote_literal(right(submitted_text(), 40)) || chr(10);
--
--   r := r || 'RLS enabled / forced: '
--          || (SELECT relrowsecurity || ' / ' || relforcerowsecurity
--                FROM pg_class WHERE oid = 'public.schema_migrations'::regclass)
--          || '   (expect true / false)' || chr(10);
--   r := r || 'policies on it: '
--          || (SELECT count(*) FROM pg_policy
--               WHERE polrelid = 'public.schema_migrations'::regclass)
--          || '   (expect 0 — no policy is what denies every row)' || chr(10);
--
--   r := r || 'table privileges held by anon / authenticated / service_role: '
--          || (SELECT count(*) FROM (VALUES ('anon'),('authenticated'),('service_role')) x(role),
--                     unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE']) p
--               WHERE has_table_privilege(x.role, 'public.schema_migrations', p))
--          || '   (expect 0)' || chr(10);
--   r := r || 'record_migration / submitted_text executable by PUBLIC, anon, authenticated: '
--          || (SELECT count(*) FROM (VALUES ('public'),('anon'),('authenticated')) x(role),
--                     unnest(ARRAY['public.record_migration(text,text,text,text)',
--                                  'public.submitted_text()']) f
--               WHERE has_function_privilege(x.role, f, 'EXECUTE'))
--          || '   (expect 0)' || chr(10);
--
--   -- The defaults were reshaped, not left as the earlier form wrote them.
--   r := r || 'ran_md5 default now calls submitted_text: '
--          || (SELECT (pg_get_expr(d.adbin, d.adrelid) LIKE '%submitted_text%')::text
--                FROM pg_attrdef d JOIN pg_attribute a
--                  ON a.attrelid = d.adrelid AND a.attnum = d.adnum
--               WHERE d.adrelid = 'public.schema_migrations'::regclass
--                 AND a.attname = 'ran_md5')
--          || '   (expect true — false means the ALTERs did not fire)' || chr(10);
--   r := r || 'the two timestamps are nullable: '
--          || (SELECT count(*) FROM pg_attribute
--               WHERE attrelid = 'public.schema_migrations'::regclass
--                 AND attname IN ('first_applied_at','applied_at')
--                 AND NOT attnotnull)
--          || '   (expect 2 — the backfill needs them)' || chr(10);
--
--   -- Its own row went in, and fingerprinted the run that wrote it.
--   SELECT count(*) INTO n FROM schema_migrations
--    WHERE filename = '20261103T1200_schema_migrations_ledger.sql';
--   r := r || 'the ledger recorded itself: ' || n || '   (expect 1)' || chr(10);
--
--   -- The mechanism: a row written from inside THIS submission must carry
--   -- THIS submission's stripped fingerprint.
--   PERFORM record_migration('ZZZ_verification_only.sql', 'abc123', 'first run', 'verification');
--   r := r || 'ran_md5 equals md5(submitted_text()) of this block: '
--          || (SELECT (ran_md5 = md5(submitted_text()))::text FROM schema_migrations
--               WHERE filename = 'ZZZ_verification_only.sql')
--          || '   (expect true)' || chr(10);
--   r := r || 'and does NOT equal md5 of the raw query: '
--          || (SELECT (ran_md5 <> md5(current_query()))::text FROM schema_migrations
--               WHERE filename = 'ZZZ_verification_only.sql')
--          || '   (expect true in the SQL editor, FALSE under psql — psql '
--          || 'appends no trailer, so the two are the same text)' || chr(10);
--
--   SELECT first_applied_at, sha256, note INTO v_first, v_sha, v_note
--     FROM schema_migrations WHERE filename = 'ZZZ_verification_only.sql';
--
--   -- A re-run that passes nothing: the hash and note must survive and
--   -- first_applied_at must not move. This is the whole of the function's
--   -- logic, and the only part of it that can be got wrong quietly.
--   PERFORM record_migration('ZZZ_verification_only.sql');
--   SELECT count(*) INTO n FROM schema_migrations
--    WHERE filename = 'ZZZ_verification_only.sql';
--   r := r || 're-run with no arguments — rows: ' || n || '   (expect 1)' || chr(10);
--   r := r || '    first_applied_at held: '
--          || (SELECT (first_applied_at = v_first)::text FROM schema_migrations
--               WHERE filename = 'ZZZ_verification_only.sql')
--          || '   (expect true)' || chr(10);
--   r := r || '    hash and note held: '
--          || (SELECT (sha256 IS NOT DISTINCT FROM v_sha
--                      AND note IS NOT DISTINCT FROM v_note)::text
--                FROM schema_migrations WHERE filename = 'ZZZ_verification_only.sql')
--          || '   (expect true — COALESCE keeps what the first run said)' || chr(10);
--
--   -- A re-run that DOES pass a hash must replace it.
--   PERFORM record_migration('ZZZ_verification_only.sql', 'def456');
--   r := r || '    hash replaced when supplied: '
--          || (SELECT (sha256 = 'def456')::text FROM schema_migrations
--               WHERE filename = 'ZZZ_verification_only.sql')
--          || '   (expect true)' || chr(10);
--
--   -- A backfilled row says so by holding nothing about the run. This is the
--   -- shape the backfill file uses, tested here so it is not tested there.
--   INSERT INTO schema_migrations
--          (filename, sha256, first_applied_at, applied_at, ran_md5, ran_len, note)
--   VALUES ('ZZZ_backfill_shape.sql', 'aaa', NULL, NULL, NULL, NULL, 'after the fact');
--   r := r || 'a backfilled row keeps its nulls: '
--          || (SELECT (first_applied_at IS NULL AND applied_at IS NULL
--                      AND ran_md5 IS NULL AND ran_len IS NULL)::text
--                FROM schema_migrations WHERE filename = 'ZZZ_backfill_shape.sql')
--          || '   (expect true — the defaults must not fire on an explicit NULL)' || chr(10);
--
--   -- ---- as a signed-in user. Last: the role does not revert. ---------------
--   PERFORM set_config('role', 'authenticated', true);
--
--   BEGIN
--     SELECT count(*) INTO n FROM schema_migrations;
--     r := r || 'authenticated can read the ledger: ' || n || ' rows (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'authenticated read refused: ' || SQLERRM || chr(10); END;
--
--   BEGIN
--     PERFORM record_migration('ZZZ_should_never_appear.sql');
--     r := r || 'authenticated could call record_migration (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'authenticated call refused: ' || SQLERRM || chr(10); END;
--
--   RAISE EXCEPTION 'VERIFY 20261103T1200_schema_migrations_ledger (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
