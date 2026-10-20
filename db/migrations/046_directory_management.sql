-- =============================================================================
-- 046_directory_management.sql
-- The Hub — migration 46: the directory, managed from Settings.
--
-- The app's Settings screen now adds and edits directory entries. Two things
-- the database has to do for that, neither of which the screen should do
-- itself:
--
-- 1. WHO MAY WRITE. 038 split every Settings table into per-command policies,
--    written by can_manage_settings() — but directory_entries wasn't in its
--    list. It still has 021's one policy, USING (is_internal() OR
--    organization_id = current_organization_id()), which covers every
--    command: any signed-in professional at a firm can add, change or delete
--    its directory today. The app hiding the controls isn't a control. This
--    gives the directory 038's shape: read as today, written by manager and
--    above.
--
-- 2. ADDING A NUMBER REACHES BACK. 044 cleared contact_id on stored calls
--    through the numbers in the directory when it ran. A number added later
--    leaves its old calls on a contact that shouldn't exist. A trigger, not
--    an RPC the screen remembers to call: it fires on an insert, on
--    reactivation, and when an entry's number or kind changes to one the
--    rule covers — from the app, the SQL editor, or anything built later.
--
--    It is an invoker trigger. interactions has one policy (006,
--    interactions_tenant) covering every command for the firm's users and
--    internal, so whoever may write the entry may already clear the calls,
--    and RLS confines the update to that firm. No SECURITY DEFINER needed,
--    so none used. IF interactions' policies are ever narrowed (by location,
--    say), this would silently clear only what the writer can see — revisit
--    it then.
--
-- Deactivating an entry doesn't put contacts back: the calls were never that
-- contact's, and contact_for_number() will match the next call normally.
--
-- IT CLEARS A HAND-LINKED CONTACT TOO. interactions.contact_id carries no
-- provenance — no link_method, the one place the schema departs from
-- standing rule 4 — so the trigger can't tell a contact someone chose from
-- one ingestion matched by number, and clears both. Today that is moot:
-- contact_id is set only by ingestion (contact_for_number) and moved by a
-- merge (015, 016); nothing in the app links a call to a contact by hand. The
-- day something does, add contact_link_method ('confirmed' | 'inferred') to
-- interactions and have this clear only 'inferred' — 045's party_name already
-- treats the linked contact as the deliberate one, and this trigger would
-- otherwise silently undo that.
--
-- Requires: 001 to 045
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Read as today, written by manager and above
--
-- 038's drift check first: stop if the policy isn't what 021 left.
-- -----------------------------------------------------------------------------
DO $$
DECLARE n int; found text;
BEGIN
  SELECT count(*), string_agg(polname::text, ', ') INTO n, found
    FROM pg_policy WHERE polrelid = 'public.directory_entries'::regclass;
  IF n <> 1 OR found <> 'directory_entries_tenant' THEN
    RAISE EXCEPTION 'directory_entries: expected exactly the policy directory_entries_tenant, found % (%). Stop and look before changing it.',
      coalesce(found, 'none'), n;
  END IF;
END $$;

DROP POLICY directory_entries_tenant ON directory_entries;

CREATE POLICY directory_entries_read ON directory_entries FOR SELECT
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY directory_entries_insert ON directory_entries FOR INSERT
  WITH CHECK (is_internal() OR (can_manage_settings() AND organization_id = current_organization_id()));
CREATE POLICY directory_entries_update ON directory_entries FOR UPDATE
  USING      (is_internal() OR (can_manage_settings() AND organization_id = current_organization_id()))
  WITH CHECK (is_internal() OR (can_manage_settings() AND organization_id = current_organization_id()));
CREATE POLICY directory_entries_delete ON directory_entries FOR DELETE
  USING (is_internal() OR (can_manage_settings() AND organization_id = current_organization_id()));

-- -----------------------------------------------------------------------------
-- 2. A staff number added later releases its past calls
--
-- The same test as 044's cleanup and contact_for_number(): the far end of the
-- call (the caller inbound, the number dialled outbound) is this number.
-- -----------------------------------------------------------------------------
CREATE FUNCTION directory_entries_release_contacts() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE interactions i
     SET contact_id = NULL, updated_at = now()
   WHERE i.organization_id = NEW.organization_id
     AND i.contact_id IS NOT NULL
     AND NEW.e164 = CASE WHEN i.direction = 'inbound' THEN i.from_e164 ELSE i.to_e164 END;
  RETURN NULL;
END $$;

COMMENT ON FUNCTION directory_entries_release_contacts() IS
  'After an active staff, team or on-call entry gains a number: clear the '
  'contact on the firm''s stored calls through it, as 044 did once. Invoker '
  'rights: interactions_tenant already lets the writer update them. Clears a '
  'hand-linked contact as well as a matched one — contact_id records no link '
  'method. Narrow it to inferred links once interactions carries one.';

CREATE TRIGGER directory_entries_release_contacts_t
  AFTER INSERT OR UPDATE OF e164, entry_kind, active ON directory_entries
  FOR EACH ROW
  WHEN (NEW.active AND NEW.e164 IS NOT NULL AND NEW.entry_kind IN ('staff', 'team', 'on_call'))
  EXECUTE FUNCTION directory_entries_release_contacts();

COMMIT;

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
-- Made-up numbers only. Run in the SQL editor (as the owner, so RLS is not
-- what's tested here; the policies are checked by name and expression).
--
-- DO $$
-- DECLARE r text := ''; s text; v_org uuid; v_num text; v_c uuid; v_i uuid; v_i2 uuid; v_d uuid;
--         v_cell text := '+15135556666';
-- BEGIN
--   SELECT id INTO v_org FROM organizations WHERE code = 'DR';
--   SELECT e164 INTO v_num FROM phone_numbers WHERE active AND organization_id = v_org ORDER BY e164 LIMIT 1;
--
--   -- A call matched to a contact, from a number nobody has entered yet.
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'Saved as a contact (test)') RETURNING id INTO v_c;
--   INSERT INTO contact_phones (organization_id, contact_id, e164, label, is_primary, added_by)
--   VALUES (v_org, v_c, v_cell, 'other', true, 'verify 046');
--   v_i := ingest_call_event('call_046_a', 'call.incoming', now(), 'inbound', v_cell, v_num);
--   r := r || 'before: call on the contact: ' || ((SELECT contact_id FROM interactions WHERE id = v_i) = v_c) || '   (expect true)' || chr(10);
--
--   -- A business entry for the number leaves it alone.
--   INSERT INTO directory_entries (organization_id, entry_kind, label, e164)
--   VALUES (v_org, 'business', 'A business (test)', v_cell) RETURNING id INTO v_d;
--   r := r || 'after a business entry: still on the contact: ' || ((SELECT contact_id FROM interactions WHERE id = v_i) = v_c) || '   (expect true)' || chr(10);
--
--   -- Changing it to staff releases the call.
--   UPDATE directory_entries SET entry_kind = 'staff', label = 'Staff cell (test)' WHERE id = v_d;
--   r := r || 'after it becomes staff: contact: ' || coalesce((SELECT contact_id::text FROM interactions WHERE id = v_i), 'none') || '   (expect none)' || chr(10);
--
--   -- Deactivated, a new call matches the contact again; reactivated, it's released.
--   UPDATE directory_entries SET active = false WHERE id = v_d;
--   v_i2 := ingest_call_event('call_046_b', 'call.incoming', now(), 'inbound', v_cell, v_num);
--   r := r || 'inactive entry, new call on the contact: ' || ((SELECT contact_id FROM interactions WHERE id = v_i2) = v_c) || '   (expect true)' || chr(10);
--   UPDATE directory_entries SET active = true WHERE id = v_d;
--   r := r || 'reactivated, that call: ' || coalesce((SELECT contact_id::text FROM interactions WHERE id = v_i2), 'none') || '   (expect none)' || chr(10);
--
--   -- The policies.
--   SELECT string_agg(polname::text || '=' || polcmd::text, ', ' ORDER BY polname) INTO s
--     FROM pg_policy WHERE polrelid = 'directory_entries'::regclass;
--   r := r || 'policies: ' || s || '   (expect delete=d, insert=a, read=r, update=w)' || chr(10);
--   SELECT string_agg(polname::text, ', ') INTO s FROM pg_policy
--    WHERE polrelid = 'directory_entries'::regclass AND polcmd IN ('a', 'w', 'd')
--      AND coalesce(pg_get_expr(polwithcheck, polrelid), pg_get_expr(polqual, polrelid)) NOT LIKE '%can_manage_settings()%';
--   r := r || 'writes not gated by can_manage_settings: ' || coalesce(s, 'none') || '   (expect none)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 046 (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
