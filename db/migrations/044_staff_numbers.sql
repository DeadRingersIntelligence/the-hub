-- =============================================================================
-- 044_staff_numbers.sql
-- The Hub — migration 44: the firm's own numbers are never contacts.
--
-- A number in the firm's directory as staff, a team or an on-call line belongs
-- to the firm. A call from a director's cell, or a consultation dialled to it,
-- is internal; it isn't something that happened with a family.
--
-- WHERE THE RULE GOES
--
-- contact_for_number() (015), because that is where a call meets a contact:
-- ingest_call_event() calls it on every call to set contact_id, hours before
-- anything renders. call_flow() already looks in the directory before contacts
-- (042), but that only orders a label; a contact_id set at ingestion would
-- still put the call on a contact's timeline. In the matcher, every caller
-- inherits it — ingestion, the call flow, and anything built later.
--
-- 015's function is kept exactly, with one condition added. It still follows
-- merged_into to the surviving contact, and its parameter is still `raw`:
-- CREATE OR REPLACE can't rename a parameter, so a new name would fail the
-- whole migration (040 hit the same thing).
--
-- served_firm, business and external entries are left out of the rule: a
-- hospice or a crematory can be in the directory and be a contact too.
--
-- THE LIMIT. It protects only numbers that are in the directory. A staff cell
-- nobody entered still matches a contact. Populating the directory is what
-- makes the rule work. Entries are data about real people, so none are in this
-- file: a committed number stays in the repository's history for good, and a
-- migration that creates entries recreates them in every environment. They
-- go in through the Settings screen (app work, tracked there), or for now
-- directly in the SQL editor, never written to a file.
--
-- THIS MIGRATION
--   1. contact_for_number() returns null for a firm's own active staff, team
--      or on-call number.
--   2. Calls already stored with a contact through such a number lose it —
--      every number in the directory when this runs, so add a firm's entries
--      first. (Production, 20 Oct 2026: none. It's here so the rule holds for
--      everything stored, not just what arrives next.) An entry added later
--      doesn't reach back; the Settings screen should, when it's built.
--
-- WHAT IT DOESN'T DO. A contact_phones row holding a staff number stays; it is
-- simply never matched. The feed and panel name a caller from their contact,
-- so a call from a staff cell shows the number, not the directory name — that
-- is the app's to change.
--
-- Requires: 001 to 043
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. The matcher
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION contact_for_number(p_org uuid, raw text)
RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT COALESCE(c.merged_into, c.id)
  FROM contact_phones p
  JOIN contacts c ON c.id = p.contact_id
  WHERE p.organization_id = p_org
    AND p.e164 = normalize_e164(raw)
    -- A number belonging to the firm's own people is never a contact.
    AND NOT EXISTS (
      SELECT 1 FROM directory_entries d
      WHERE d.organization_id = p_org AND d.active
        AND d.entry_kind IN ('staff', 'team', 'on_call')
        AND d.e164 = normalize_e164(raw))
  LIMIT 1
$$;

COMMENT ON FUNCTION contact_for_number(uuid, text) IS
  'The contact a number belongs to, following merged_into to the survivor. '
  'Null for a number in the firm''s directory as an active staff, team or '
  'on-call entry: the firm''s own numbers are never contacts. Protects only '
  'numbers that are in the directory.';

-- -----------------------------------------------------------------------------
-- 2. What was matched before the rule
--
-- The same test the matcher now applies, against the number the call was
-- matched on (the far end: the caller inbound, the number dialled outbound).
-- -----------------------------------------------------------------------------
UPDATE interactions i
   SET contact_id = NULL, updated_at = now()
 WHERE i.contact_id IS NOT NULL
   AND EXISTS (
     SELECT 1 FROM directory_entries d
     WHERE d.organization_id = i.organization_id AND d.active
       AND d.entry_kind IN ('staff', 'team', 'on_call')
       AND d.e164 = CASE WHEN i.direction = 'inbound' THEN i.from_e164 ELSE i.to_e164 END);

COMMIT;

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- DO $$
-- DECLARE r text := ''; s text; n int; v_org uuid; v_num text; v_c uuid; v_i uuid;
--         v_staff text := '+15135558888';   -- made up; never a real number
-- BEGIN
--   SELECT id INTO v_org FROM organizations WHERE code = 'DR';
--   SELECT e164 INTO v_num FROM phone_numbers WHERE active AND organization_id = v_org ORDER BY e164 LIMIT 1;
--
--   -- What's in the directory, without printing a number.
--   SELECT string_agg(label || ' (' || entry_kind || ', person ' || (person_id IS NOT NULL) || ')', '; ' ORDER BY label)
--     INTO s FROM directory_entries WHERE organization_id = v_org;
--   r := r || 'directory: ' || coalesce(s, 'EMPTY') || chr(10);
--
--   -- A contact holding a staff number is never matched; deactivated, it is.
--   INSERT INTO directory_entries (organization_id, entry_kind, label, e164)
--   VALUES (v_org, 'staff', 'Staff cell (test)', v_staff);
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'Staff-number contact (test)') RETURNING id INTO v_c;
--   INSERT INTO contact_phones (organization_id, contact_id, e164, label, is_primary, added_by)
--   VALUES (v_org, v_c, v_staff, 'other', true, 'verify 044');
--   r := r || 'staff number matches: ' || coalesce(contact_for_number(v_org, '(513) 555-8888')::text, 'nobody') || '   (expect nobody)' || chr(10);
--   UPDATE directory_entries SET active = false WHERE organization_id = v_org AND e164 = v_staff;
--   r := r || 'after deactivating the entry: ' || (contact_for_number(v_org, v_staff) = v_c)::text || '   (expect true)' || chr(10);
--   UPDATE directory_entries SET active = true WHERE organization_id = v_org AND e164 = v_staff;
--
--   -- An ordinary contact number still matches, merges still followed.
--   SELECT string_agg(DISTINCT (contact_for_number(cp.organization_id, cp.e164) = COALESCE(c.merged_into, c.id))::text, ',')
--     INTO s FROM contact_phones cp JOIN contacts c ON c.id = cp.contact_id
--    WHERE NOT EXISTS (SELECT 1 FROM directory_entries d WHERE d.organization_id = cp.organization_id AND d.e164 = cp.e164);
--   r := r || 'every other contact number resolves as 015 did: ' || coalesce(s, 'no contacts') || '   (expect true)' || chr(10);
--
--   -- Ingestion: a call from a staff cell gets no contact, even with one on file.
--   v_i := ingest_call_event('call_044_s', 'call.incoming', now(), 'inbound', v_staff, v_num);
--   r := r || 'ingested call from a staff cell, contact: '
--          || coalesce((SELECT contact_id::text FROM interactions WHERE id = v_i), 'none') || '   (expect none)' || chr(10);
--
--   -- What's left matched through a staff number after the cleanup.
--   SELECT count(*) INTO n FROM interactions i
--    WHERE i.contact_id IS NOT NULL AND i.external_call_ref <> 'call_044_s' AND EXISTS (
--      SELECT 1 FROM directory_entries d WHERE d.organization_id = i.organization_id AND d.active
--        AND d.entry_kind IN ('staff', 'team', 'on_call')
--        AND d.e164 = CASE WHEN i.direction = 'inbound' THEN i.from_e164 ELSE i.to_e164 END);
--   r := r || 'stored calls still on a contact through a staff number: ' || n || '   (expect 0)' || chr(10);
--
--   -- The 20 Oct transfer, named once the firm's entries are in.
--   SELECT detail INTO s FROM call_flow((SELECT id FROM interactions WHERE external_call_ref LIKE '%cjz1g9')) WHERE step = 'Transferred';
--   r := r || 'cjz1g9 transferred to: ' || coalesce(s, 'NULL') || chr(10);
--   SELECT detail INTO s FROM call_flow((SELECT id FROM interactions WHERE external_call_ref LIKE '%h4x64e')) WHERE step = 'Transfer completed';
--   r := r || 'h4x64e joined to: ' || coalesce(s, 'NULL') || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 044 (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
