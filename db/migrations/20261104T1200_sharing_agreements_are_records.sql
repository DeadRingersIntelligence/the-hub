-- =============================================================================
-- 20261104T1200_sharing_agreements_are_records.sql
-- The Hub — a signed agreement is a record of something that happened, not
-- a row either party can edit.
--
-- WHAT IS WRONG. data_sharing_agreements carries one policy:
--
--   CREATE POLICY data_sharing_agreements_tenant ON data_sharing_agreements
--     USING (is_internal()
--         OR organization_id  = current_organization_id()
--         OR receiving_org_id = current_organization_id());
--
-- A policy written with no FOR clause is FOR ALL, and with no WITH CHECK the
-- USING expression governs writes as well as reads. So the expression that was
-- written to decide WHO MAY SEE an agreement also decides who may change or
-- delete one — and both parties can. The receiving organization, the one the
-- data is being shared WITH, can rewrite the scope it was granted, move its
-- date range, clear revoked_on, or delete the agreement entirely.
--
-- The comment above it in 002 says what was meant: "Both sides of a sharing
-- agreement may see it." May see. This is finding 0 again, in better clothes —
-- the six reference tables had USING (true) and this has a correct tenant
-- expression, but the mistake is identical and in the same place. A scoped
-- policy is not the same as a read policy, and the write-policy audit of
-- 4 November did not catch this one because it asked whether every policy was
-- scoped. All 112 were. Nobody asked which of them were being used as write
-- policies by accident.
--
-- THE RULING, from the user: nobody changes a data-sharing agreement through
-- the API. Not either firm, and not Dead Ringers. Creating one, ending one by
-- setting revoked_on, and correcting a typo in signed_by are all migrations
-- from here. That is deliberate and it is the point: an agreement is a record
-- of a document somebody signed, and a row that mirrors a signed document
-- should be as hard to change as the document is.
--
-- Both sides keep READ access exactly as they have it, which is the part that
-- must not move: a firm needs to be able to see which consultancy can reach
-- its data.
--
-- HOW THE READ IS PRESERVED. Section 2 does not retype the expression. It
-- reads the existing policy's qual out of the catalogue and builds the new
-- SELECT policy from it, so the two cannot differ — the same reason
-- 20261103T2100 cut 014's body out of the file rather than copying it by eye.
-- The verification prints both so the equality is visible, not assumed.
--
-- WHY THERE IS NO WRITE POLICY, where finding 0's fix added one. 20261103T1000
-- installed an is_internal() write policy on its six tables because somebody
-- internal might one day edit a rubric. Here nobody should, so the absence of
-- a write policy IS the second lock: with row-level security on and no policy
-- admitting an INSERT, UPDATE or DELETE, a stray GRANT would grant nothing.
-- Revoking the privileges is the first lock; having nothing to permit the
-- write is the second.
--
-- MIGRATIONS STILL WRITE IT. postgres holds BYPASSRLS, so no policy applies to
-- it and 024's FORCE does not change that. A future migration that adds or
-- revokes an agreement works with no further grant.
--
-- Requires: 002 (the table and the policy), 024 (RLS and the grants being
--           removed), 20261103T1200 (record_migration).
-- Safe to run twice.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. The policy is the one this file expects
--
-- Three states, read from pg_policy: 002's single FOR ALL policy, this file's
-- single FOR SELECT one, or something else — and something else stops, because
-- a policy nobody has read is not a policy to replace blind.
--
-- polcmd is '*' for ALL and 'r' for SELECT. Matched on the command and the
-- name rather than on the expression text, because the expression is what this
-- file deliberately does not depend on knowing.
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_old int; v_new int; v_total int;
BEGIN
  SELECT count(*) FILTER (WHERE polname = 'data_sharing_agreements_tenant' AND polcmd = '*'),
         count(*) FILTER (WHERE polname = 'data_sharing_agreements_read'   AND polcmd = 'r'),
         count(*)
    INTO v_old, v_new, v_total
    FROM pg_policy
   WHERE polrelid = 'public.data_sharing_agreements'::regclass;

  IF v_new = 1 AND v_total = 1 THEN
    RAISE EXCEPTION 'already read-only; nothing to do here'
      USING HINT = 'This migration has run on this database. Not an error to fix — stop.';
  ELSIF NOT (v_old = 1 AND v_total = 1) THEN
    RAISE EXCEPTION
      'data_sharing_agreements has % policies and they are not 002''s one; stop and read them', v_total
      USING HINT = 'Expected exactly data_sharing_agreements_tenant, FOR ALL.';
  END IF;

  IF NOT (SELECT relrowsecurity FROM pg_class
           WHERE oid = 'public.data_sharing_agreements'::regclass) THEN
    RAISE EXCEPTION 'row-level security is not enabled on data_sharing_agreements; stop and look';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. The same expression, reading only
--
-- The qual is carried across rather than retyped. If 002's expression is ever
-- edited before this file runs, the new policy inherits the edit instead of
-- silently reverting it.
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_qual text;
BEGIN
  SELECT pg_get_expr(polqual, polrelid) INTO v_qual
    FROM pg_policy
   WHERE polrelid = 'public.data_sharing_agreements'::regclass
     AND polname = 'data_sharing_agreements_tenant';

  EXECUTE 'DROP POLICY data_sharing_agreements_tenant ON data_sharing_agreements';
  EXECUTE format(
    'CREATE POLICY data_sharing_agreements_read ON data_sharing_agreements '
    'FOR SELECT TO authenticated USING (%s)', v_qual);
END $$;

COMMENT ON POLICY data_sharing_agreements_read ON data_sharing_agreements IS
  'Both sides of an agreement may see it, and only Dead Ringers sees them all '
  '— the same expression 002 wrote, carried across unchanged. It is now FOR '
  'SELECT, which is what 002''s comment meant by "may see". Written without a '
  'FOR clause it was FOR ALL, so the receiving organization could rewrite the '
  'scope it had been granted, clear revoked_on, or delete the agreement.';

-- -----------------------------------------------------------------------------
-- 3. And no way to write it
--
-- TO authenticated on the read policy means anon matches no policy at all,
-- as well as holding no privilege since 20261103T1600.
--
-- No write policy is installed. With RLS on and nothing admitting an INSERT,
-- UPDATE or DELETE, a grant restored by accident would still permit nothing —
-- which the verification tests rather than asserts.
-- -----------------------------------------------------------------------------
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON data_sharing_agreements
  FROM authenticated, anon, service_role;
REVOKE SELECT ON data_sharing_agreements FROM anon;

COMMENT ON TABLE data_sharing_agreements IS
  'A record of a signed document, not a row anybody edits. Creating an '
  'agreement, ending one by setting revoked_on, and correcting a field are all '
  'migrations: no API role holds INSERT, UPDATE or DELETE, and no policy '
  'admits a write even if one were granted. Both parties may read their own.';

-- -----------------------------------------------------------------------------
-- 4. Record it
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM record_migration(
    '20261104T1200_sharing_agreements_are_records.sql',
    NULL,
    'data_sharing_agreements_tenant was FOR ALL, so either party could edit or '
    'delete an agreement. Replaced with a FOR SELECT policy carrying the same '
    'expression, and the write privileges revoked. Writes are migrations now.');
END $$;

COMMIT;

-- =============================================================================
-- STILL TO DO
--
-- * organizations AND partners HAVE THE SAME SHAPE and the same ruling, in
--   their own file: organizations_tenant and partners_visible are both FOR ALL
--   with read expressions, so any member can UPDATE or DELETE their own firm's
--   row, and any firm holding partner_access can write the partner's record.
--   The user's ruling there is different from this one — Dead Ringers staff may
--   write, firms may not — so they need an is_internal() write policy rather
--   than none, and the grants stay, because internal staff sign in as
--   authenticated like everyone else.
--
-- * THE AUDIT THAT MISSED THIS should be written down beside the one that
--   found nothing. "Is every write policy scoped?" returned a clean 112 of 112.
--   The question that would have found these three is "is any policy written
--   FOR ALL that was meant to be read-only?", and it is not answerable from
--   the catalogue alone — polcmd says ALL for a great many policies that
--   correctly govern writes. What found it was reading them. The practical
--   version for review: a policy whose name or comment says see, visible or
--   readable, and whose polcmd is '*', is wrong until somebody says otherwise.
--
-- * REVOKING revoked_on NOW NEEDS A MIGRATION. That is the ruling, not an
--   oversight, and it is worth a line in db/README.md so the first person who
--   needs to end an agreement does not go looking for a bug.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- DO $$
-- DECLARE r text := ''; n int; v_qual text; v_org uuid;
-- BEGIN
--   r := r || 'policies on the table:' || chr(10) || '    '
--          || COALESCE((SELECT string_agg(polname || '(' || polcmd::text || ')', ', ' ORDER BY polname)
--                         FROM pg_policy
--                        WHERE polrelid = 'public.data_sharing_agreements'::regclass), 'NONE')
--          || '   (expect exactly data_sharing_agreements_read(r))' || chr(10);
--
--   SELECT pg_get_expr(polqual, polrelid) INTO v_qual
--     FROM pg_policy
--    WHERE polrelid = 'public.data_sharing_agreements'::regclass
--      AND polname = 'data_sharing_agreements_read';
--   r := r || 'its expression, carried across from 002:' || chr(10)
--          || '    ' || COALESCE(v_qual, 'NONE') || chr(10)
--          || '   (expect is_internal() OR organization_id = '
--          || 'current_organization_id() OR receiving_org_id = '
--          || 'current_organization_id() — both parties still read)' || chr(10);
--
--   r := r || 'authenticated S/I/U/D: '
--          || has_table_privilege('authenticated', 'public.data_sharing_agreements', 'SELECT')::text || '/'
--          || has_table_privilege('authenticated', 'public.data_sharing_agreements', 'INSERT')::text || '/'
--          || has_table_privilege('authenticated', 'public.data_sharing_agreements', 'UPDATE')::text || '/'
--          || has_table_privilege('authenticated', 'public.data_sharing_agreements', 'DELETE')::text
--          || '   (expect true/false/false/false)' || chr(10);
--   r := r || 'anon SELECT: '
--          || has_table_privilege('anon', 'public.data_sharing_agreements', 'SELECT')::text
--          || '   (expect false)' || chr(10);
--
--   -- postgres writes regardless, which is what keeps future migrations working.
--   SELECT count(*) INTO n FROM data_sharing_agreements;
--   r := r || 'rows the owner can see: ' || n || '   (expect all of them)' || chr(10);
--
--   -- THE SECOND LOCK. Hand the privilege back — the stray GRANT this is meant
--   -- to survive — and the write must still fail, because no policy admits it.
--   -- Unlike a missing grant, which raises, a refusing policy returns 0 rows.
--   GRANT UPDATE ON data_sharing_agreements TO authenticated;
--
--   -- ---- as a signed-in user. Last: the role does not revert. --------------
--   PERFORM set_config('role', 'authenticated', true);
--
--   BEGIN
--     SELECT count(*) INTO n FROM data_sharing_agreements;
--     r := r || 'authenticated can read: ' || n || ' rows   (expect 0 with no '
--            || 'app.user_id set — the policy is scoped, and this only shows '
--            || 'the read path is not refused outright)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'authenticated read REFUSED (BAD): ' || SQLERRM || chr(10); END;
--
--   BEGIN
--     UPDATE data_sharing_agreements SET notes = notes WHERE true;
--     GET DIAGNOSTICS n = ROW_COUNT;
--     r := r || 'authenticated update WITH the grant restored: ' || n || ' rows'
--            || '   (expect 0 — no write policy exists, so the grant alone '
--            || 'permits nothing. This is the lock that survives a future '
--            || 'stray GRANT)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'authenticated update raised instead of returning 0: ' || SQLERRM
--            || '   (acceptable, but it means the grant did not restore)' || chr(10); END;
--
--   BEGIN
--     DELETE FROM data_sharing_agreements WHERE false;
--     r := r || 'authenticated delete: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || 'authenticated delete refused: ' || SQLERRM || chr(10); END;
--
--   RAISE EXCEPTION 'VERIFY 20261104T1200_sharing_agreements_are_records (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
