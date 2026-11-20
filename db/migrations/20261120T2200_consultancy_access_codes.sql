-- =============================================================================
-- 20261120T2200_consultancy_access_codes.sql
-- The Hub — a firm grants a consultancy access with the code the consultancy
-- gives it.
--
-- APPLIED to staging (18:51 UTC) and production (18:52 UTC), 20 Nov 2026,
-- from commit 1c14283, loaded whole. ran_md5 8cdac11962d28fcf0139d77811be26fd
-- (28350 characters) on both, as predicted. All 19 verification lines
-- (1-16, with 12b, 15b and 15c) matched on both, identically. The PR said 20;
-- that was a miscount. All nine baseline queries matched the predicted table:
-- acl 46241, col 77809, com 12171, con 51229 (down 40: a UNIQUE constraint
-- became a partial index), fn 14174 and trg 7084 moved; defacl, mig and typ
-- held. This note was added afterwards.
--
-- WHY. 20261120T1800 let a firm's managers grant a consultancy access
-- (partner_access), but a firm sees only consultancies it has already granted
-- (partners_read), so there was no way to find one: the permission had no
-- path to using it. Mandie's ruling, 20 November: an access code. Each
-- consultancy gets a code from Dead Ringers and gives it to the firm; the
-- manager enters it. It's the handshake that already happens in real life
-- ("give my firm access"), the only design in which the firm starts the grant
-- without learning anything about Dead Ringers' other relationships, and the
-- only one that uses the permission 1800 gave managers rather than leaving it
-- decorative.
--
-- THE FIVE THINGS THE RULING ASKED FOR, and where each one lives:
--
--   1. CONFIRM THE NAME BEFORE THE GRANT COMMITS. partner_for_access_code()
--      returns the consultancy's name, and the app shows it for the manager to
--      confirm. grant_partner_access() then takes the code again, never a
--      bare id. A mistyped code that happens to match a real consultancy is
--      the one failure this design can still produce; the confirm step is
--      what catches it.
--   2. NOT GUESSABLE, NOT ENUMERABLE. Twelve characters of Crockford base32,
--      shown as XXXX-XXXX-XXXX, which is 2^60 codes. The lookup takes an exact,
--      complete code or refuses, so it can't be walked like a search, and an
--      unknown code and a retired consultancy's code refuse alike. No rate
--      limit: at 2^60 a guess isn't the threat. Note it here if that changes.
--   3. ROTATABLE. issue_partner_access_code() replaces a consultancy's code
--      with a new one, shown once. Rotating never touches existing grants;
--      those end through revoked_on, not by invalidating a code.
--   4. RE-GRANTING AFTER A REVOCATION MAKES A NEW ROW. It doesn't clear
--      revoked_on on the old one: "they had access, it ended, it started
--      again" is the sequence an audit wants to read. So the old
--      UNIQUE (partner_id, organization_id) becomes unique among ACTIVE grants
--      only. A guard trigger stops a firm editing a grant or backdating one,
--      and stops ANYONE, Dead Ringers included, clearing revoked_on:
--      reinstating is a new row for everyone (review of #62). (db/README.md, "Evidence isn't erased by the
--      party it concerns". 1800's comment "reinstates by clearing it" is
--      superseded, and re-issued below.)
--   5. ALREADY GRANTED IS NOT AN ERROR. grant_partner_access() returns
--      'already', and the lookup says so before the confirm.
--
-- THE CODE IS STORED ONLY AS A HASH (sha256 of the normalised code) on
-- partners. A firm that has granted a consultancy can read its partners row
-- (partners_read), so a plaintext code there would be readable by every
-- client the consultancy has. Dead Ringers sees a code once, when it's
-- issued; a lost code is replaced, not looked up. Input is forgiving: case,
-- spaces and dashes don't matter, and O reads as 0, I and L as 1. The
-- alphabet has none of I, L, O or U, so read aloud it doesn't mislead.
--
-- REVOKING NOW SENDS NO DATE. revoke_partner_access() sets revoked_on =
-- current_date itself (db/README.md: east of UTC, a firm's today can be UTC's
-- tomorrow, which 20261120T1900's CHECK refuses).
--
-- THE ONE DEFINER PATH FOR FIRMS is the lookup (partner_for_access_code) and
-- the list of the firm's own grants (my_partner_access), because a firm
-- can't see a consultancy it hasn't granted, or one whose grant it has
-- revoked. Both check by hand who's asking and which firm. The grant and the
-- revoke are INVOKER: they write under 1800's manager policies.
--
-- THE CODE IS THE ONLY WAY A FIRM GRANTS (review of #62). 1800's
-- partner_access_insert says nothing about which consultancy, and a firm
-- learns the id of anyone it has granted (my_partner_access), so a direct
-- INSERT would let a firm re-grant a consultancy after its code was rotated.
-- grant_partner_access sets hub.partner_grant_by_code for its own INSERT;
-- partner_access_guard refuses a firm's INSERT without it. Same shape as
-- hub.case_change_reason (20261120T1000).
--
-- "THE FIRM" MEANS current_organization_id(). The grant, the revoke and the
-- list all act on it. For Dead Ringers staff that is their own current firm,
-- whatever firm a screen is showing; the app hides the controls when staff
-- view another firm, and the database doesn't. Said again in each function's
-- comment.
--
-- Requires: 003 (partners, partner_access), 20261120T1800, 20261120T1900,
--           pgcrypto in extensions (001), 20261103T1200 (record_migration).
-- NOT SAFE TO RUN TWICE: section 1 refuses on a second run.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Preconditions
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM schema_migrations
                  WHERE filename = '20261120T1900_revocation_is_not_a_schedule.sql') THEN
    RAISE EXCEPTION '20261120T1900 has not run here; run it first';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public' AND table_name = 'partners'
                AND column_name = 'access_code_hash') THEN
    RAISE EXCEPTION 'already converted; nothing to do here'
      USING HINT = 'This migration has run on this database. Not an error to fix — stop.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.partner_access'::regclass
                    AND conname = 'partner_access_partner_id_organization_id_key'
                    AND pg_get_constraintdef(oid) = 'UNIQUE (partner_id, organization_id)') THEN
    RAISE EXCEPTION 'partner_access_partner_id_organization_id_key is not 003''s UNIQUE (partner_id, organization_id); stop and read it';
  END IF;
  IF to_regprocedure('extensions.gen_random_bytes(integer)') IS NULL THEN
    RAISE EXCEPTION 'pgcrypto''s gen_random_bytes is not in schema extensions; stop';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. The code's home on partners: a hash, and when it was issued
-- -----------------------------------------------------------------------------
ALTER TABLE partners
  ADD COLUMN access_code_hash text,
  ADD COLUMN access_code_issued_at timestamptz;
CREATE UNIQUE INDEX partners_access_code_hash_uq ON partners (access_code_hash)
  WHERE access_code_hash IS NOT NULL;

COMMENT ON COLUMN partners.access_code_hash IS
  'sha256 (hex) of the consultancy''s access code, normalised. Never the code: '
  'a firm that has granted this consultancy can read this row. Set by '
  'issue_partner_access_code() (20261120T2200).';
COMMENT ON COLUMN partners.access_code_issued_at IS
  'When the current access code was issued. Rotating replaces it; existing '
  'grants are untouched (20261120T2200).';

-- -----------------------------------------------------------------------------
-- 3. One active grant per consultancy and firm; history kept
-- -----------------------------------------------------------------------------
ALTER TABLE partner_access DROP CONSTRAINT partner_access_partner_id_organization_id_key;
CREATE UNIQUE INDEX partner_access_one_active_uq ON partner_access (partner_id, organization_id)
  WHERE revoked_on IS NULL;
COMMENT ON INDEX partner_access_one_active_uq IS
  'At most one ACTIVE grant per consultancy and firm. A re-grant after a '
  'revocation is a new row, so the history reads granted, revoked, granted '
  'again (20261120T2200).';

CREATE FUNCTION partner_access_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  -- Nobody clears a revocation, Dead Ringers included: reinstating is a new
  -- row, for everyone. The one rule here with no internal exemption.
  IF TG_OP = 'UPDATE' AND OLD.revoked_on IS NOT NULL AND NEW.revoked_on IS NULL THEN
    RAISE EXCEPTION 'a revocation isn''t undone; to give access again, grant it anew'
      USING HINT = 'A new grant keeps the record of the old one: granted, revoked, granted again.';
  END IF;
  IF is_internal() THEN RETURN NEW; END IF;
  IF TG_OP = 'INSERT' THEN
    -- A firm grants with the consultancy's code, through grant_partner_access,
    -- or not at all. It sets this for its own INSERT and clears it after
    -- (the hub.case_change_reason pattern, 20261120T1000). Without it, a
    -- firm that once knew a consultancy's id could grant it again after
    -- the code was rotated.
    IF COALESCE(current_setting('hub.partner_grant_by_code', true), '') <> '1' THEN
      RAISE EXCEPTION 'a consultancy is given access with its access code'
        USING ERRCODE = '42501',
              HINT = 'Enter the code the consultancy gave you in Settings, Consultancies.';
    END IF;
    IF NEW.revoked_on IS NOT NULL THEN
      RAISE EXCEPTION 'a grant starts active; it can''t be recorded as already revoked';
    END IF;
    NEW.granted_on := current_date;   -- no backdating a consent
    RETURN NEW;
  END IF;
  -- UPDATE: the only change a firm makes is ending the grant.
  IF OLD.revoked_on IS NOT NULL
     OR NEW.revoked_on IS NULL
     OR NEW.partner_id IS DISTINCT FROM OLD.partner_id
     OR NEW.organization_id IS DISTINCT FROM OLD.organization_id
     OR NEW.granted_on IS DISTINCT FROM OLD.granted_on THEN
    RAISE EXCEPTION 'a grant is ended by revoking it, and isn''t otherwise changed'
      USING HINT = 'To give access again, enter the consultancy''s code: that starts a new grant and keeps the old one.';
  END IF;
  RETURN NEW;
END $$;

COMMENT ON FUNCTION partner_access_guard() IS
  'For a firm: a new grant is made only through grant_partner_access (the '
  'consultancy''s code), starts today and active; an existing grant can only be '
  'ended (revoked_on set, once). For everyone, Dead Ringers included: revoked_on '
  'is never cleared; reinstating is a new row. A consent record is evidence '
  '(20261120T2200).';

CREATE TRIGGER partner_access_guard_t
  BEFORE INSERT OR UPDATE ON partner_access
  FOR EACH ROW EXECUTE FUNCTION partner_access_guard();
REVOKE ALL ON FUNCTION partner_access_guard() FROM PUBLIC, anon, authenticated;

COMMENT ON POLICY partner_access_update ON partner_access IS
  'A manager ends a grant by setting revoked_on, which partners_read honours. '
  'Giving access again is a new grant (20261120T1800, 20261120T2200).';

-- -----------------------------------------------------------------------------
-- 4. The code: issued by Dead Ringers, normalised one way, looked up exactly
-- -----------------------------------------------------------------------------
CREATE FUNCTION partner_access_code_normal(p_code text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT translate(upper(regexp_replace(COALESCE(p_code, ''), '[\s-]', '', 'g')), 'OIL', '011')
$$;
COMMENT ON FUNCTION partner_access_code_normal(text) IS
  'The one statement of how an access code is read: case, spaces and dashes '
  'ignored; O as 0, I and L as 1 (Crockford). Twelve characters of '
  '0-9 and A-Z without I, L, O, U, or it isn''t a code (20261120T2200).';

CREATE FUNCTION issue_partner_access_code(p_partner uuid)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  alphabet CONSTANT text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  b bytea := extensions.gen_random_bytes(12);
  c text := '';
  i int;
BEGIN
  IF NOT is_internal() THEN
    RAISE EXCEPTION 'access codes are issued by Dead Ringers' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM partners WHERE id = p_partner AND active) THEN
    RAISE EXCEPTION 'that consultancy couldn''t be found, or isn''t active' USING ERRCODE = 'P0002';
  END IF;
  -- 256 is a multiple of 32, so each byte mod 32 is uniform.
  FOR i IN 0..11 LOOP
    c := c || substr(alphabet, (get_byte(b, i) % 32) + 1, 1);
  END LOOP;
  UPDATE partners
     SET access_code_hash = encode(sha256(convert_to(c, 'UTF8')), 'hex'),
         access_code_issued_at = now(), updated_at = now()
   WHERE id = p_partner;
  RETURN substr(c, 1, 4) || '-' || substr(c, 5, 4) || '-' || substr(c, 9, 4);
END $$;
COMMENT ON FUNCTION issue_partner_access_code(uuid) IS
  'Dead Ringers issues a consultancy''s access code, replacing any earlier one, '
  'and sees it this once: only its hash is kept. Existing grants are untouched '
  '(20261120T2200).';

CREATE FUNCTION partner_for_access_code(p_code text)
RETURNS TABLE (partner_id uuid, partner_name text, already_granted boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_code text := partner_access_code_normal(p_code); v_org uuid := current_organization_id();
BEGIN
  IF v_org IS NULL OR NOT can_manage_settings() THEN
    RAISE EXCEPTION 'granting a consultancy access is for your firm''s owners and managers'
      USING ERRCODE = '42501';
  END IF;
  IF v_code !~ '^[0-9A-HJKMNP-TV-Z]{12}$' THEN
    RAISE EXCEPTION 'that isn''t an access code'
      USING HINT = 'An access code is twelve letters and digits, like K7QM-4XTR-9HZP. The consultancy gives it to you.';
  END IF;
  RETURN QUERY
    SELECT p.id, p.name,
           EXISTS (SELECT 1 FROM partner_access a
                    WHERE a.partner_id = p.id AND a.organization_id = v_org AND a.revoked_on IS NULL)
      FROM partners p
     WHERE p.access_code_hash = encode(sha256(convert_to(v_code, 'UTF8')), 'hex')
       AND p.active;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'no consultancy has that code'
      USING HINT = 'Check it with the consultancy. Codes can be replaced, so an old one may have stopped working.';
  END IF;
END $$;
COMMENT ON FUNCTION partner_for_access_code(text) IS
  'For a firm''s managers: the consultancy an access code belongs to, so the '
  'app can show its name to confirm before granting, and whether the firm '
  'already has it. Exact and complete codes only; it never searches. An '
  'unknown code and a retired consultancy''s refuse alike. DEFINER, because '
  'the firm can''t otherwise see a consultancy it hasn''t granted '
  '(20261120T2200).';

CREATE FUNCTION grant_partner_access(p_code text)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE f record;
BEGIN
  SELECT * INTO f FROM partner_for_access_code(p_code);
  IF f.already_granted THEN RETURN 'already'; END IF;
  -- The guard's proof that this grant came through a code. Transaction-local,
  -- and cleared straight after the INSERT either way.
  PERFORM set_config('hub.partner_grant_by_code', '1', true);
  BEGIN
    INSERT INTO partner_access (partner_id, organization_id)
    VALUES (f.partner_id, current_organization_id());
  EXCEPTION WHEN unique_violation THEN
    PERFORM set_config('hub.partner_grant_by_code', '', true);
    RETURN 'already';   -- granted a moment ago, by someone else
  END;
  PERFORM set_config('hub.partner_grant_by_code', '', true);
  RETURN 'granted';
END $$;
COMMENT ON FUNCTION grant_partner_access(text) IS
  'A manager grants a consultancy access to the firm''s data with its access '
  'code: ''granted'', or ''already'' if the firm has it now (not an error). '
  'Takes the code again, never a bare id, so the confirmed name and the grant '
  'are the same consultancy, and it is the only way a firm grants '
  '(partner_access_guard). INVOKER: writes under partner_access_insert. Acts on '
  'current_organization_id(): for Dead Ringers staff that is their own current '
  'firm, whatever firm a screen is showing. The app hides grant and revoke when '
  'staff view another firm; the database does not (20261120T2200).';

CREATE FUNCTION revoke_partner_access(p_partner uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  UPDATE partner_access SET revoked_on = current_date
   WHERE partner_id = p_partner AND organization_id = current_organization_id()
     AND revoked_on IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'that consultancy doesn''t have access to your firm now';
  END IF;
END $$;
COMMENT ON FUNCTION revoke_partner_access(uuid) IS
  'A manager ends a consultancy''s access from today. The date is the '
  'database''s, never the app''s: east of UTC a firm''s today can be UTC''s '
  'tomorrow. INVOKER: writes under partner_access_update. Acts on '
  'current_organization_id(), like grant_partner_access: the app, not the '
  'database, keeps staff from using it while viewing another firm '
  '(20261120T2200).';

CREATE FUNCTION my_partner_access()
RETURNS TABLE (partner_id uuid, partner_name text, granted_on date, revoked_on date)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT a.partner_id, p.name, a.granted_on, a.revoked_on
    FROM partner_access a JOIN partners p ON p.id = a.partner_id
   WHERE a.organization_id = current_organization_id()
   ORDER BY a.revoked_on IS NOT NULL, a.granted_on DESC, p.name
$$;
COMMENT ON FUNCTION my_partner_access() IS
  'The signed-in user''s firm''s grants, current and ended, with names. '
  'DEFINER only because partners_read hides a consultancy once its grant is '
  'revoked; scoped by current_organization_id(), so it says nothing about '
  'anyone else''s. For Dead Ringers staff that is their own current firm, not '
  'the firm a screen is showing (20261120T2200).';

REVOKE ALL ON FUNCTION partner_access_code_normal(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION issue_partner_access_code(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION partner_for_access_code(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION grant_partner_access(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION revoke_partner_access(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION my_partner_access() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION partner_access_code_normal(text) TO authenticated;
GRANT EXECUTE ON FUNCTION issue_partner_access_code(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION partner_for_access_code(text) TO authenticated;
GRANT EXECUTE ON FUNCTION grant_partner_access(text) TO authenticated;
GRANT EXECUTE ON FUNCTION revoke_partner_access(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION my_partner_access() TO authenticated;

-- -----------------------------------------------------------------------------
-- 5. Record it
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261120T2200_consultancy_access_codes.sql',
    NULL,
    'A firm grants a consultancy access with the code the consultancy gives it. '
    'partners keeps the code''s hash; Dead Ringers issues and rotates it. '
    'partner_for_access_code (DEFINER, exact codes only) shows the name to '
    'confirm; grant_partner_access takes the code again. One active grant per '
    'pair; a re-grant is a new row; partner_access_guard stops a firm editing, '
    'backdating or un-revoking. revoke_partner_access sets the date itself.');
END $rec$;

COMMIT;

-- =============================================================================
-- Verification — run AFTER the file, as its own statement. One block,
-- everything rolled back by the closing RAISE.
--
-- A fixture firm with a manager and a professional, an active consultancy
-- with a code, and a retired consultancy with a code. Everything a firm does
-- runs as authenticated, because postgres holds BYPASSRLS.
--
-- DO $$
-- DECLARE
--   r text := ''; res text; n int; f record;
--   v_org uuid; v_mgr uuid; v_pro uuid; a_mgr uuid := gen_random_uuid(); a_pro uuid := gen_random_uuid();
--   v_p1 uuid; v_p3 uuid; code1 text; code1b text; code3 text;
-- BEGIN
--   -- ---- the fixture, as Dead Ringers -------------------------------------
--   PERFORM set_config('app.is_internal', 'on', true);
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ verify 2200', 'funeral_home') RETURNING id INTO v_org;
--   INSERT INTO users (email, full_name, auth_user_id) VALUES ('zzz-2200-m@example.invalid', 'ZZZ Manager', a_mgr) RETURNING id INTO v_mgr;
--   INSERT INTO users (email, full_name, auth_user_id) VALUES ('zzz-2200-p@example.invalid', 'ZZZ Professional', a_pro) RETURNING id INTO v_pro;
--   INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id) VALUES
--     (v_mgr, 'organization', 'manager', v_org), (v_pro, 'organization', 'professional', v_org);
--   INSERT INTO partners (name, partner_type) VALUES ('ZZZ Consultancy One', 'consultancy') RETURNING id INTO v_p1;
--   INSERT INTO partners (name, partner_type) VALUES ('ZZZ Retired Consultancy', 'consultancy') RETURNING id INTO v_p3;
--   code1 := issue_partner_access_code(v_p1);
--   code3 := issue_partner_access_code(v_p3);
--   UPDATE partners SET active = false WHERE id = v_p3;
--   r := r || '1. an issued code: shape ' || (code1 ~ '^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$')
--          || ', stored in plain anywhere on partners: '
--          || EXISTS (SELECT 1 FROM partners p WHERE to_jsonb(p)::text LIKE '%' || replace(code1, '-', '') || '%')
--          || '   (expect true, false: only the hash is kept)' || chr(10);
--   PERFORM set_config('app.is_internal', 'off', true);
--
--   -- ---- a professional ----------------------------------------------------
--   PERFORM set_config('request.jwt.claims', json_build_object('sub', a_pro::text)::text, true);
--   PERFORM set_config('role', 'authenticated', true);
--   BEGIN PERFORM partner_for_access_code(code1); res := 'ALLOWED';
--   EXCEPTION WHEN insufficient_privilege THEN res := SQLSTATE; END;
--   r := r || '2. a professional looks up a code: ' || res || '   (expect 42501)' || chr(10);
--
--   -- ---- the manager -------------------------------------------------------
--   PERFORM set_config('request.jwt.claims', json_build_object('sub', a_mgr::text)::text, true);
--   SELECT * INTO f FROM partner_for_access_code(lower(replace(code1, '-', ' ')));
--   r := r || '3. the manager types it in lower case with spaces: ' || f.partner_name || ', already: ' || f.already_granted
--          || '   (expect ZZZ Consultancy One, false: the name to confirm)' || chr(10);
--   BEGIN PERFORM partner_for_access_code(left(replace(code1, '-', ''), 6)); res := 'ALLOWED';
--   EXCEPTION WHEN OTHERS THEN res := SQLERRM; END;
--   r := r || '4. half a code: ' || res || '   (expect "that isn''t an access code": no search)' || chr(10);
--   BEGIN PERFORM partner_for_access_code('2222-2222-2222'); res := 'ALLOWED';
--   EXCEPTION WHEN OTHERS THEN res := SQLERRM; END;
--   r := r || '5. a well-formed code nobody has: ' || res || '   (expect "no consultancy has that code")' || chr(10);
--   BEGIN PERFORM partner_for_access_code(code3); res := 'ALLOWED';
--   EXCEPTION WHEN OTHERS THEN res := SQLERRM; END;
--   r := r || '6. a retired consultancy''s code: ' || res || '   (expect the same "no consultancy has that code")' || chr(10);
--
--   -- Each call its own statement: a count in the same expression would read
--   -- a snapshot taken before the grant.
--   res := grant_partner_access(code1);
--   res := res || ', then again: ' || grant_partner_access(code1);
--   r := r || '7. grant: ' || res
--          || ', the firm now sees the consultancy: ' || (SELECT count(*) FROM partners WHERE id = v_p1)
--          || '   (expect granted, already, 1)' || chr(10);
--   SELECT granted_on INTO f FROM partner_access WHERE partner_id = v_p1 AND organization_id = v_org;
--   r := r || '8. granted_on is today: ' || (f.granted_on = current_date) || '   (expect true)' || chr(10);
--
--   PERFORM revoke_partner_access(v_p1);
--   r := r || '9. revoke now: revoked_on is today: '
--          || (SELECT revoked_on = current_date FROM partner_access WHERE partner_id = v_p1 AND organization_id = v_org)
--          || ', the firm sees the consultancy: ' || (SELECT count(*) FROM partners WHERE id = v_p1)
--          || '   (expect true, 0)' || chr(10);
--   BEGIN PERFORM revoke_partner_access(v_p1); res := 'ALLOWED';
--   EXCEPTION WHEN OTHERS THEN res := SQLERRM; END;
--   r := r || '10. revoke again: ' || res || '   (expect "that consultancy doesn''t have access to your firm now")' || chr(10);
--   BEGIN UPDATE partner_access SET revoked_on = NULL WHERE partner_id = v_p1 AND organization_id = v_org; res := 'ALLOWED';
--   EXCEPTION WHEN OTHERS THEN res := SQLERRM; END;
--   r := r || '11. the manager clears revoked_on directly: ' || res
--          || '   (expect "a revocation isn''t undone; to give access again, grant it anew")' || chr(10);
--   BEGIN INSERT INTO partner_access (partner_id, organization_id) VALUES (v_p1, v_org); res := 'ALLOWED';
--   EXCEPTION WHEN insufficient_privilege THEN res := SQLERRM; END;
--   r := r || '12. the manager inserts a grant directly, knowing the id: ' || res
--          || '   (expect "a consultancy is given access with its access code")' || chr(10);
--   r := r || '12b. the flag is left set after a grant: '
--          || (COALESCE(current_setting('hub.partner_grant_by_code', true), '') = '1')
--          || '   (expect false: grant_partner_access clears it)' || chr(10);
--
--   res := grant_partner_access(code1);
--   r := r || '13. re-grant with the code: ' || res
--          || '; rows for this consultancy: ' || (SELECT count(*) FROM partner_access WHERE partner_id = v_p1 AND organization_id = v_org)
--          || ', revoked: ' || (SELECT count(*) FROM partner_access WHERE partner_id = v_p1 AND organization_id = v_org AND revoked_on IS NOT NULL)
--          || '   (expect granted; 2, 1: a new row, the old one kept)' || chr(10);
--   r := r || '14. the firm''s list: ' || (SELECT string_agg(partner_name || ' ' || COALESCE('ended ' || revoked_on::text, 'active'), '; ')
--                                          FROM my_partner_access())
--          || '   (expect ZZZ Consultancy One active, then ZZZ Consultancy One ended today)' || chr(10);
--
--   -- ---- rotation, by Dead Ringers ----------------------------------------
--   PERFORM set_config('app.is_internal', 'on', true);
--   code1b := issue_partner_access_code(v_p1);
--   PERFORM set_config('app.is_internal', 'off', true);
--   BEGIN PERFORM partner_for_access_code(code1); res := 'still works';
--   EXCEPTION WHEN OTHERS THEN res := SQLERRM; END;
--   r := r || '15. after rotation, the old code: ' || res || '; the new one: '
--          || (SELECT partner_name || ', already ' || already_granted FROM partner_for_access_code(code1b))
--          || '; the active grant: ' || (SELECT count(*) FROM partner_access WHERE partner_id = v_p1 AND revoked_on IS NULL)
--          || '   (expect "no consultancy has that code"; ZZZ Consultancy One, already true; 1)' || chr(10);
--   -- Nobody clears a revocation, Dead Ringers included; a new grant is fine.
--   PERFORM set_config('app.is_internal', 'on', true);
--   BEGIN UPDATE partner_access SET revoked_on = NULL
--          WHERE partner_id = v_p1 AND organization_id = v_org AND revoked_on IS NOT NULL;
--     res := 'ALLOWED';
--   EXCEPTION WHEN OTHERS THEN res := SQLERRM; END;
--   r := r || '15b. Dead Ringers clears a revocation: ' || res
--          || '   (expect "a revocation isn''t undone; to give access again, grant it anew")' || chr(10);
--   UPDATE partner_access SET revoked_on = current_date WHERE partner_id = v_p1 AND organization_id = v_org AND revoked_on IS NULL;
--   INSERT INTO partner_access (partner_id, organization_id) VALUES (v_p1, v_org);
--   r := r || '15c. Dead Ringers ends it and grants anew, directly: rows now '
--          || (SELECT count(*) FROM partner_access WHERE partner_id = v_p1 AND organization_id = v_org)
--          || '   (expect 3: internal may insert, and history is kept)' || chr(10);
--   PERFORM set_config('app.is_internal', 'off', true);
--   BEGIN PERFORM issue_partner_access_code(v_p1); res := 'ALLOWED';
--   EXCEPTION WHEN insufficient_privilege THEN res := SQLSTATE; END;
--   r := r || '16. the manager issues a code: ' || res || '   (expect 42501)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261120T2200_consultancy_access_codes (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
