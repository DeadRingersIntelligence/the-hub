-- =============================================================================
-- 054_directory_party_by_kind.sql
-- The Hub — migration 54: which party a directory entry may name, by kind.
--
-- Reviewed in the Hub chat; run and verified on staging and production.
--
-- WHY. 053's one-party rule said a served firm needing a named person means
-- "that person is the destination", which reads as person_id or contact_id.
-- The app read it the only way its roster check allowed: a person must be on
-- this firm's `people`, so it silently dropped the person on any non-staff
-- entry. The answer is that a named person at another firm is a CONTACT.
-- `people` means "works here": it carries assignments and seats, and a hospice
-- liaison in it would make an employment claim out of a phone number (the
-- objection that kept 044 from inventing people rows for staff numbers).
--
-- THE RULE, one place, by kind:
--   person_id   staff, on_call        (on-call is a person this week, another next)
--   team_id     team
--   contact_id  served_firm, business, external
-- Each kind names at most its own party, or none.
--
-- THIS MIGRATION
--   1. directory_entries_party_matches_kind_ck states that. It SUPERSEDES
--      053's directory_entries_one_party_ck, which is dropped: the new check
--      is strictly stronger (every kind allows at most one reference), and two
--      constraints would be two things to reconcile when a kind is added.
--   2. A kind the check doesn't name is refused (ELSE false), not waved
--      through. Without it, CASE yields NULL for a new enum value and a CHECK
--      passes on NULL, so a new kind would accept any party until someone
--      remembered this. Adding a kind means adding its line here.
--   3. The three party columns' comments say who each is for, and 053's
--      contact_id comment is reworded.
--
-- CONSEQUENCES, deliberate:
--   * A hospice liaison is a contact (contact_type 'partner', via
--     create_contact), named on a served_firm entry by contact_id. Their calls
--     match them as a contact, and they are a transfer destination: one party,
--     recorded once.
--   * firm_only_number() (053) still lets that number be saved as a contact:
--     the entry is served_firm, not staff-type. Checked in the verification
--     rather than assumed.
--
-- Checked 22 Oct 2026: every existing entry passes (production: 3 staff, one
-- naming a person; staging: 1 on_call, 1 inactive business, none naming a
-- party).
--
-- THE APP after this: Settings offers a person only on staff and on-call
-- entries (not team), and a contact on served firm, business and external
-- ones. Its own filter becomes a reflection of this check, not a rule of its
-- own; the check's refusal is what decides.
--
-- Requires: 001 to 053. Not 051.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Drift check: 053's constraint is the one being replaced.
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_def text;
BEGIN
  SELECT pg_get_constraintdef(oid) INTO v_def FROM pg_constraint
   WHERE conrelid = 'public.directory_entries'::regclass
     AND conname = 'directory_entries_one_party_ck';
  IF v_def IS DISTINCT FROM 'CHECK ((num_nonnulls(person_id, team_id, contact_id) <= 1))' THEN
    RAISE EXCEPTION 'directory_entries_one_party_ck is not as 053 left it (%). Stop and look before replacing it.', v_def;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 1. The party each kind may name
-- -----------------------------------------------------------------------------
ALTER TABLE directory_entries DROP CONSTRAINT directory_entries_one_party_ck;

ALTER TABLE directory_entries ADD CONSTRAINT directory_entries_party_matches_kind_ck
  CHECK (
    CASE entry_kind
      WHEN 'staff'       THEN team_id IS NULL AND contact_id IS NULL
      WHEN 'on_call'     THEN team_id IS NULL AND contact_id IS NULL
      WHEN 'team'        THEN person_id IS NULL AND contact_id IS NULL
      WHEN 'served_firm' THEN person_id IS NULL AND team_id IS NULL
      WHEN 'business'    THEN person_id IS NULL AND team_id IS NULL
      WHEN 'external'    THEN person_id IS NULL AND team_id IS NULL
      ELSE false
    END);

COMMENT ON CONSTRAINT directory_entries_party_matches_kind_ck ON directory_entries IS
  'Which party an entry may name, by kind: a person (people, who work here) '
  'for staff and on_call; a team for team; a contact for served_firm, business '
  'and external. A named person at another firm is a contact, never a people '
  'row. A kind not listed is refused: adding a directory_entry_kind value '
  'means adding its line here. Supersedes directory_entries_one_party_ck (053).';

-- -----------------------------------------------------------------------------
-- 2. Who each reference is for
-- -----------------------------------------------------------------------------
COMMENT ON COLUMN directory_entries.person_id IS
  'Someone who works at this firm (people), for a staff or on_call entry. '
  'Never someone at another firm: they are a contact (contact_id).';

COMMENT ON COLUMN directory_entries.team_id IS
  'The team a team entry rings.';

COMMENT ON COLUMN directory_entries.contact_id IS
  'The contact this destination is, for a served_firm, business or external '
  'entry: a hospice, a vendor, or a named person there (a liaison is a '
  'contact with contact_type partner). The contact is who they are; the entry '
  'is that they are a destination. Same party, two facts, so the number is '
  'not kept twice.';

COMMIT;

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- DO $$
-- DECLARE r text := ''; v_org uuid; v_person uuid; v_team uuid; v_c uuid;
--         v_kind text; v_col text; v_ok boolean;
-- BEGIN
--   SELECT id INTO v_org FROM organizations WHERE code = 'DR';
--   SELECT id INTO v_person FROM people WHERE organization_id = v_org LIMIT 1;
--   SELECT id INTO v_team FROM teams WHERE organization_id = v_org LIMIT 1;
--   v_c := create_contact(v_org, 'Verify Liaison', NULL, 'partner', '+15550007001');
--
--   r := r || 'old constraint gone: '
--          || (NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'directory_entries_one_party_ck'))
--          || '   (expect true)' || chr(10);
--
--   -- Every kind against every party: allowed only where the rule says.
--   FOREACH v_kind IN ARRAY ARRAY['staff','on_call','team','served_firm','business','external'] LOOP
--     FOREACH v_col IN ARRAY ARRAY['person','team','contact'] LOOP
--       CONTINUE WHEN (v_col = 'person' AND v_person IS NULL) OR (v_col = 'team' AND v_team IS NULL);
--       BEGIN
--         INSERT INTO directory_entries (organization_id, entry_kind, label, e164, person_id, team_id, contact_id)
--         VALUES (v_org, v_kind::directory_entry_kind, 'Verify ' || v_kind || ' ' || v_col, '+15550007999',
--                 CASE WHEN v_col = 'person' THEN v_person END,
--                 CASE WHEN v_col = 'team' THEN v_team END,
--                 CASE WHEN v_col = 'contact' THEN v_c END);
--         v_ok := true;
--       EXCEPTION WHEN check_violation THEN v_ok := false; END;
--       r := r || v_kind || '+' || v_col || ': ' || CASE WHEN v_ok THEN 'allowed' ELSE 'refused' END
--              || CASE WHEN v_ok = ((v_col = 'person' AND v_kind IN ('staff','on_call'))
--                                OR (v_col = 'team' AND v_kind = 'team')
--                                OR (v_col = 'contact' AND v_kind IN ('served_firm','business','external')))
--                      THEN '' ELSE '   (WRONG)' END || chr(10);
--     END LOOP;
--   END LOOP;
--   IF v_person IS NULL THEN r := r || 'no person at the firm: person cases not tested' || chr(10); END IF;
--   IF v_team IS NULL THEN r := r || 'no team at the firm: team cases not tested' || chr(10); END IF;
--
--   -- No party at all is still fine for every kind.
--   INSERT INTO directory_entries (organization_id, entry_kind, label, e164)
--   VALUES (v_org, 'served_firm', 'Verify no party', '+15550007998');
--   r := r || 'entry with no party: allowed' || chr(10);
--
--   -- The two rules compose: a liaison on a served_firm entry stays a contact.
--   INSERT INTO directory_entries (organization_id, entry_kind, label, e164, contact_id)
--   VALUES (v_org, 'served_firm', 'Verify Hospice (liaison)', '+15550007001', v_c);
--   r := r || 'liaison number firm-only: ' || coalesce(firm_only_number(v_org, '+15550007001'), 'null')
--          || ', matches the liaison: ' || (contact_for_number(v_org, '+15550007001') IS NOT DISTINCT FROM v_c)
--          || '   (expect null, true)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 054 (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
