-- =============================================================================
-- 20261030T1500_one_number_rule.sql
-- The Hub — what a stored phone number is, written once.
--
-- Drafted as 056 and renamed: it is applied after 058, so a sequence number
-- would say something untrue about the order. First file under the timestamp
-- rule in db/README.md.
--
-- Safe to run twice: the editor's one-step lag has produced a double-run on
-- 042 and 049, so every step here tells "already applied" from "something
-- else changed it".
--
-- WHY THIS ISN'T JUST A CHECK CONSTRAINT
--
-- directory_entries.e164 has no format constraint at all — the only check on
-- the table is that a non-team entry has a number or an extension. Its
-- normalize trigger is COALESCE(normalize_e164(NEW.e164), NEW.e164), which
-- PRESERVES an unreadable value rather than refusing it. So "call 555 ext 12"
-- is stored as typed.
--
-- A directory number that isn't a number then silently stops working.
-- firm_only_number(), party_name() and 046's release trigger all compare
-- d.e164 = normalize_e164(<a real number>), so a mangled value matches
-- nothing: that person's staff protection never fires, their cell becomes
-- saveable as a contact, and their calls start landing on a family's
-- timeline. The harm 044 exists to prevent, reopened by a typo, with nothing
-- on screen.
--
-- The obvious fix is a regex CHECK — and that would be a FOURTH statement of
-- the rule, days after three copies were taken out of the app. So the pattern
-- moves into is_e164(), FIRST, and everything after it asks:
--
--   is_e164(text)        the rule — the only place the pattern is written
--   the precondition     below, which is why is_e164 is created before it
--   require_e164(text)   055's reader, now asking is_e164 whether it read
--   directory_entries    CHECK (e164 IS NULL OR is_e164(e164))
--   contact_phones       its inline regex from 015, replaced by the same call
--   phone_numbers        its inline regex from 004, replaced by the same call
--
-- phone_numbers was found by the verification scan during the precheck, not by
-- design: this migration was drafted against the two tables the app writes, and
-- 004's copy — the firm's own numbers — went unnoticed through two rounds of
-- review. Had it been left, is_e164's comment would have claimed sole statement
-- of the pattern on a schema that still held another, which is precisely the
-- failure the scan exists to catch. It is cheap to replace here and expensive
-- to find later, so it is in.
--
-- Requires, by what it actually uses:
--   015  contact_phones, and the inline e164 regex this replaces
--   021  directory_entries
--   055  require_e164
-- Independent of 057 and 058; runs before or after either.
--
-- Preconditions: the directory-numbers query came back empty on production
-- and staging on 29 Oct, so section 2 should pass. It re-checks anyway.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. The rule, before anything that needs it
--
-- IMMUTABLE because a CHECK requires it and because it genuinely is: the same
-- string always gives the same answer.
--
-- GRANTED TO PUBLIC, deliberately. Both CHECK constraints call it, and a
-- constraint is evaluated as part of whoever's write — so a role without
-- EXECUTE could be refused on a table it is otherwise allowed to write. The
-- README's revoke-from-PUBLIC rule is about SECURITY DEFINER functions, which
-- run as their owner and can reach past RLS; this is an invoker function that
-- tests a string against a regex and reveals nothing. Locking it down would
-- buy no safety and could break a writer nobody thought about.
--
-- CHANGING THIS DOES NOT RE-CHECK WHAT IS ALREADY STORED. A CHECK is validated
-- on write, so loosening or tightening this leaves existing rows as they are
-- (the same trap as 049's generated column). After changing it, re-scan each
-- table by dropping and re-adding its constraint in the same migration —
-- ALTER ... VALIDATE CONSTRAINT only validates one marked NOT VALID, so it is
-- not the tool for this. That re-add re-reads every row: nothing at today's
-- size, worth planning for at a million.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION is_e164(value text) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT value ~ '^\+[1-9][0-9]{7,14}$'
$$;

COMMENT ON FUNCTION is_e164(text) IS
  'Whether a string is a number this platform will store: E.164, 8 to 15 '
  'digits, no leading zero on the country code. THE ONLY PLACE THE PATTERN IS '
  'WRITTEN — require_e164() asks it, and the CHECK constraints on '
  'contact_phones.e164, directory_entries.e164 and phone_numbers.e164 call it '
  'rather than repeating it. Public on purpose: constraints calling it are '
  'evaluated as whoever is writing. Changing it does not re-check stored rows; '
  'drop and re-add all three constraints in the same migration to re-scan.';

GRANT EXECUTE ON FUNCTION is_e164(text) TO PUBLIC;

-- -----------------------------------------------------------------------------
-- 2. Preconditions
--
-- Stops before changing anything if a stored directory number wouldn't pass,
-- and names the rows. Each one is an entry that currently matches nothing, so
-- it is worth looking at rather than quietly fixing.
--
-- Asks is_e164 rather than writing the pattern again — which is why section 1
-- comes first.
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_bad text;
BEGIN
  SELECT string_agg(format('%s (%s) %L', label, entry_kind, e164), '; ')
    INTO v_bad
    FROM directory_entries
   WHERE e164 IS NOT NULL AND NOT is_e164(e164);

  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION E'these directory numbers would not pass, so nothing was changed:\n%\n'
                     'Each matches nothing today — its staff or transfer rule has never '
                     'fired. Fix or remove them, then run this again.', v_bad;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 3. require_e164 asks it, rather than carrying its own copy
--
-- The drift check tells three states apart, because the version this migration
-- writes no longer contains the pattern: a second run must read as "already
-- applied", not as drift.
-- -----------------------------------------------------------------------------
DO $$
DECLARE v text;
BEGIN
  SELECT prosrc INTO v FROM pg_proc WHERE oid = 'require_e164(text)'::regprocedure;

  IF v IS NULL THEN
    RAISE EXCEPTION 'require_e164 does not exist; run 055 first';
  ELSIF v LIKE '%is_e164%' THEN
    RAISE NOTICE 'require_e164 already asks is_e164 — this migration has run before; replacing it is a no-op';
  ELSIF v LIKE '%[1-9][0-9]{7,14}%' THEN
    NULL;   -- 055's version, as expected. The leading [1-9] is matched, not
            -- assumed: '%7,14%' alone would pass a 055 edited to [0-9], which
            -- differs from is_e164 at precisely the leading-zero edge this
            -- migration exists to close. LIKE has no character classes, so
            -- the brackets and braces here are literal text.
  ELSE
    RAISE EXCEPTION 'require_e164 is neither 055''s version nor this migration''s; stop and compare before replacing it';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION require_e164(raw text) RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE v text;
BEGIN
  -- Nothing given. A contact with no phone is ordinary — an email-only record,
  -- a CSV row with an empty column.
  IF raw IS NULL OR btrim(raw) = '' THEN RETURN NULL; END IF;

  v := normalize_e164(raw);
  -- The pattern lives in is_e164(), not here.
  IF v IS NULL OR NOT is_e164(v) THEN
    RAISE EXCEPTION 'that phone number can''t be read: %', btrim(raw)
      USING ERRCODE = 'P0001',
            HINT = 'Include the area code, for example (513) 555-0100.';
  END IF;
  RETURN v;
END $$;

COMMENT ON FUNCTION require_e164(text) IS
  'A dial string as a stored number, or null when none was given. Raises when '
  'something was given and can''t be read — the distinction normalize_e164() '
  'does not make. Judges by is_e164(), the one statement of the rule; the '
  'CHECK constraints call the same function, so a number this accepts is a '
  'number those will store. Every write path that takes a typed number uses '
  'this, the app included.';

-- -----------------------------------------------------------------------------
-- 4. The directory's number is held to the same standard as a contact's
--
-- Nullable: a team entry has no number, and an extension-only entry is allowed
-- by 021's own check. The normalize trigger is left as it is — with this
-- constraint, its COALESCE fallback hands the raw value to the check, which
-- refuses the write.
--
-- THIS IS A BACKSTOP, NOT THE MESSAGE. A violation here reads "new row for
-- relation directory_entries violates check constraint
-- directory_entries_e164_ck". The constraint's comment below is documentation
-- and never reaches a user. The sentence a person should see — "that phone
-- number can't be read: …" — comes from require_e164(), which the form calls
-- before the write. Any UI writing this column must call require_e164() first;
-- the constraint only guarantees that a path which didn't cannot store
-- garbage.
--
-- An extension belongs in directory_entries.extension, which is why this
-- column can be strict: "call 555 ext 12" is refused here rather than stripped
-- to digits that match nothing.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint
              WHERE conrelid = 'public.directory_entries'::regclass
                AND conname = 'directory_entries_e164_ck') THEN
    RAISE NOTICE 'directory_entries_e164_ck already exists — this migration has run before';
  ELSE
    ALTER TABLE directory_entries ADD CONSTRAINT directory_entries_e164_ck
      CHECK (e164 IS NULL OR is_e164(e164));
  END IF;
END $$;

COMMENT ON CONSTRAINT directory_entries_e164_ck ON directory_entries IS
  'A directory number is a phone number — extensions go in extension. Calls '
  'is_e164(), the same rule require_e164() reads by and contact_phones is '
  'held to. Before this, an unreadable value was stored as typed and then '
  'matched nothing, so the entry''s staff and transfer rules never fired.';

-- -----------------------------------------------------------------------------
-- 5. contact_phones stops carrying its own copy
--
-- 015 wrote the pattern inline. Found by introspection rather than by name (it
-- was anonymous in the table definition), and verified before replacing: if it
-- isn't the rule 015 wrote, this stops rather than overwriting it.
--
-- The re-add re-reads every row in the table. Immaterial now; at scale, plan
-- for a scan.
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_name text; v_def text; v_n int;
BEGIN
  -- Already converted?
  IF EXISTS (SELECT 1 FROM pg_constraint
              WHERE conrelid = 'public.contact_phones'::regclass
                AND conname = 'contact_phones_e164_ck'
                AND pg_get_constraintdef(oid) LIKE '%is_e164%') THEN
    RAISE NOTICE 'contact_phones_e164_ck already calls is_e164 — this migration has run before';
    RETURN;
  END IF;

  SELECT count(*) INTO v_n FROM pg_constraint
   WHERE conrelid = 'public.contact_phones'::regclass AND contype = 'c'
     AND pg_get_constraintdef(oid) LIKE '%e164%~%';

  IF v_n <> 1 THEN
    RAISE EXCEPTION 'expected exactly one e164 format check on contact_phones, found %; stop and look', v_n;
  END IF;

  SELECT conname, pg_get_constraintdef(oid) INTO v_name, v_def
    FROM pg_constraint
   WHERE conrelid = 'public.contact_phones'::regclass AND contype = 'c'
     AND pg_get_constraintdef(oid) LIKE '%e164%~%';

  -- The whole distinguishing span, for the reason given in section 3.
  IF v_def NOT LIKE '%[1-9][0-9]{7,14}%' THEN
    RAISE EXCEPTION 'contact_phones'' e164 check is not the rule 015 wrote (%); stop and compare', v_def;
  END IF;

  EXECUTE format('ALTER TABLE contact_phones DROP CONSTRAINT %I', v_name);
  EXECUTE 'ALTER TABLE contact_phones ADD CONSTRAINT contact_phones_e164_ck
             CHECK (e164 IS NULL OR is_e164(e164))';
END $$;

COMMENT ON CONSTRAINT contact_phones_e164_ck ON contact_phones IS
  'Was an inline regex in 015; now calls is_e164() so the rule is stated '
  'once. Same rule as directory_entries_e164_ck and require_e164().';

-- -----------------------------------------------------------------------------
-- 6. phone_numbers stops carrying its own copy
--
-- 004 wrote the pattern inline, the same text 015 later repeated. Unlike 015's,
-- this constraint was named in the migration that created it, so it is found by
-- name — but its definition is still checked before anything is dropped.
--
-- This is the firm's own numbers: client lines, tracking numbers, the shop
-- pool. Nothing in the app writes the table; it is loaded by hand and by the
-- carrier sync, so the constraint is the only thing standing between a mistyped
-- number and a resolver that silently matches nothing.
--
-- The re-add cannot fail. It is a like-for-like replacement — every stored row
-- already satisfies the identical regex 004 imposed, and is_e164 states that
-- same regex — so unlike section 2, no precondition scan of the rows is needed.
-- The same is true of section 5.
--
-- e164 is NOT NULL here (004), so the IS NULL branch is unreachable. It is
-- written anyway: a CHECK that evaluates to NULL passes regardless, so the
-- branch costs nothing, and all three constraints then read identically.
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_def text;
BEGIN
  SELECT pg_get_constraintdef(oid) INTO v_def
    FROM pg_constraint
   WHERE conrelid = 'public.phone_numbers'::regclass
     AND conname = 'phone_numbers_e164_ck';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'phone_numbers_e164_ck not found; 004 is not as expected, stop and look';
  ELSIF v_def LIKE '%is_e164%' THEN
    RAISE NOTICE 'phone_numbers_e164_ck already calls is_e164 — this migration has run before';
    RETURN;
  ELSIF v_def NOT LIKE '%[1-9][0-9]{7,14}%' THEN
    RAISE EXCEPTION 'phone_numbers'' e164 check is not the rule 004 wrote (%); stop and compare', v_def;
  END IF;

  ALTER TABLE phone_numbers DROP CONSTRAINT phone_numbers_e164_ck;
  ALTER TABLE phone_numbers ADD CONSTRAINT phone_numbers_e164_ck
    CHECK (e164 IS NULL OR is_e164(e164));
END $$;

COMMENT ON CONSTRAINT phone_numbers_e164_ck ON phone_numbers IS
  'Was an inline regex in 004; now calls is_e164() so the rule is stated '
  'once. Same rule as contact_phones_e164_ck, directory_entries_e164_ck and '
  'require_e164().';

COMMIT;

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
-- Made-up numbers only.
--
-- DO $$
-- DECLARE r text := ''; v_org uuid; v_id uuid; v_n int;
-- BEGIN
--   SELECT id INTO v_org FROM organizations WHERE code = 'DR';
--
--   r := r || 'is_e164: good ' || is_e164('+15135550100')
--          || ', no plus ' || is_e164('5135550100')
--          || ', leading zero ' || is_e164('+05135550100')
--          || ', too short ' || is_e164('+1234')
--          || ', text ' || is_e164('call 555 ext 12')
--          || '   (expect true, false, false, false, false)' || chr(10);
--
--   r := r || 'require_e164 agrees with is_e164: '
--          || is_e164(require_e164('(513) 555-0100'))
--          || '   (expect true)' || chr(10);
--
--   -- Every role can evaluate the constraints' function
--   r := r || 'PUBLIC can execute is_e164: '
--          || has_function_privilege('public', 'is_e164(text)', 'EXECUTE')
--          || ', service_role: ' || has_function_privilege('service_role', 'is_e164(text)', 'EXECUTE')
--          || ', anon: ' || has_function_privilege('anon', 'is_e164(text)', 'EXECUTE')
--          || '   (expect true, true, true)' || chr(10);
--
--   -- The directory refuses what require_e164 would refuse
--   BEGIN
--     INSERT INTO directory_entries (organization_id, entry_kind, label, e164)
--     VALUES (v_org, 'staff', 'Verify Bad Number', 'call 555 ext 12');
--     r := r || 'unreadable directory number: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN check_violation THEN
--     r := r || 'unreadable directory number refused' || chr(10); END;
--
--   -- An extension-only entry is still fine
--   INSERT INTO directory_entries (organization_id, entry_kind, label, extension)
--   VALUES (v_org, 'staff', 'Verify Extension Only', '105');
--   r := r || 'extension-only entry allowed' || chr(10);
--
--   -- contact_phones and phone_numbers now call the same function
--   r := r || 'contact_phones check calls is_e164: '
--          || (SELECT pg_get_constraintdef(oid) LIKE '%is_e164%'
--                FROM pg_constraint WHERE conname = 'contact_phones_e164_ck')
--          || ', phone_numbers: '
--          || (SELECT pg_get_constraintdef(oid) LIKE '%is_e164%'
--                FROM pg_constraint WHERE conname = 'phone_numbers_e164_ck')
--          || '   (expect true, true)' || chr(10);
--
--   -- and still refuses what it always refused
--   BEGIN
--     v_id := create_contact(v_org, 'Verify Still Checked', NULL, 'family', '+15135550123');
--     UPDATE contact_phones SET e164 = '55512' WHERE contact_id = v_id;
--     r := r || 'bad number through the back door: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN check_violation THEN
--     r := r || 'bad number through the back door refused' || chr(10); END;
--
--   -- Hunts for other statements of the pattern. Checks function bodies, check
--   -- and domain constraints, RLS policies, column defaults and generated
--   -- expressions, views, materialized views, and trigger WHEN clauses. That is
--   -- a net, not a proof — it is worth running because a hit is always worth
--   -- looking at, not because 0 settles the question. Match stays loose
--   -- ('%7,14%', not the full span the drift checks use): this is looking for a
--   -- copy that may already have drifted, so the narrower the match, the more
--   -- it misses.
--   SELECT count(*) INTO v_n FROM (
--     SELECT 1 FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
--      WHERE ns.nspname = 'public' AND p.prosrc LIKE '%7,14%' AND p.proname <> 'is_e164'
--     UNION ALL
--     SELECT 1 FROM pg_constraint
--      WHERE contype = 'c' AND pg_get_constraintdef(oid) LIKE '%7,14%'
--     UNION ALL
--     SELECT 1 FROM pg_policy
--      WHERE coalesce(pg_get_expr(polqual, polrelid), '') LIKE '%7,14%'
--         OR coalesce(pg_get_expr(polwithcheck, polrelid), '') LIKE '%7,14%'
--     UNION ALL
--     SELECT 1 FROM pg_attrdef WHERE pg_get_expr(adbin, adrelid) LIKE '%7,14%'
--     UNION ALL
--     SELECT 1 FROM pg_views WHERE schemaname = 'public' AND definition LIKE '%7,14%'
--     UNION ALL
--     SELECT 1 FROM pg_matviews WHERE schemaname = 'public' AND definition LIKE '%7,14%'
--     UNION ALL
--     SELECT 1 FROM pg_trigger
--      WHERE NOT tgisinternal AND pg_get_triggerdef(oid) LIKE '%7,14%'
--   ) x;
--   r := r || 'other statements of the pattern, anywhere in the schema: '
--          || v_n || '   (expect 0)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261030T1500_one_number_rule (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
