-- =============================================================================
-- 20261121T1000_contact_import.sql
-- The Hub — a firm brings its contact list in, and sees what will happen
-- before anything is written.
--
-- WHY. The day-one gap (planning, 20 November): everything built this week
-- keys off contacts, and a firm arrives with its book in a spreadsheet. Until
-- it's in, B's offer (20261120T1600) almost never fires. Mandie: up to 5,000
-- rows per import, so it's a form upload, a preview, and a commit, each one
-- RPC with the rows as JSON. Above 5,000 the refusal says what to do.
--
-- THE RULINGS (planning, 20 November), and where each lives:
--
--   DEDUPE IS THE WHOLE PROBLEM. Matched on phone number, row by row, against
--   the firm's book and against the file's other rows. One classifier,
--   contact_import_classify(), which both the preview and the commit call:
--
--     no match                       create
--     one contact                    fill it: empty fields only, never
--                                    overwrite; differences shown, kept
--     a blocked contact              hold (*)
--     a merged-away contact          follow merged_into to the survivor (*)
--     two or more contacts           hold: "this row's numbers belong to two
--                                    contacts". A row that touches two
--                                    contacts is never partly applied
--     the same number as another     hold, both rows: fix the file
--       row in the file
--     no number                      create, flagged: can't be matched
--     a staff/team/on-call number    refuse the row, naming the entry
--     not a phone number             refuse the row, saying which
--     no name                        refuse the row
--
--     (*) Named at review of the plan, not in the first dedupe table:
--     confirm at review of this file.
--
--   PREVIEW BEFORE COMMIT. preview_contact_import() writes nothing. The
--   commit re-classifies from scratch rather than trusting the preview.
--
--   HELD ROWS ARE NOT KEPT. A held row is a decision waiting, not an error,
--   and it lives only in the preview. A person may resolve it there: for
--   "two contacts" or "blocked", pick one of the listed contacts, or skip.
--   The commit takes those choices with the rows. A row picked onto one
--   contact keeps any number that belongs to the OTHER contact with that
--   other contact; the preview says so in words, so it's a person's choice,
--   not a silent drop. In-file duplicates can't be picked: fix the file.
--   Unresolved rows are simply not imported, and the firm re-imports a
--   corrected file. That's safe because A SECOND COMMIT OF THE SAME ROWS
--   CHANGES NOTHING for any row with a number: it now matches the contact it
--   made and has nothing empty to fill. Rows with no number can't be matched,
--   so they'd be created again; the preview warns on every one.
--   "These two contacts are one person" needs merge_contacts, and there's no
--   merge screen yet (backlog): until there is, pick one, or ask Dead Ringers.
--
--   PAST CALLS. A number that has called before may sit on unlinked calls.
--   The commit links them to the contact, with contact_link_method =
--   'imported' (the value existed and nothing used it), but only calls with
--   no contact at all, and never one a person unlinked by hand
--   (clear_call_contact's 'unlinked' history row). Calls from a staff number
--   are never linked: those rows are refused before linking.
--
--   MANAGERS ONLY: can_manage_settings() (ruled at review of the plan).
--   Importing the book changes shared data for the whole firm, in bulk, and
--   is hard to reverse. Both functions act on current_organization_id(); for
--   Dead Ringers staff that's their own current firm, not one a screen shows.
--
-- THERE IS NO UNDO. Ruled: import_id plus history is the reversal path,
-- and the history is written to be enough for that by hand:
--   * every created contact: a 'created' row with the import's id and the
--     file's row number;
--   * every fill: an 'updated' row with FROM and TO for each field it filled,
--     and the numbers it added;
--   * every linked call: a 'linked' row that says, explicitly, that the call
--     WAS UNLINKED before (previous_contact_id null, previous_state
--     'unlinked'), so un-picking 400 calls knows which ones to clear.
-- Build an undo the first time a firm commits a wrong import (backlog).
--
-- WHAT IS ENFORCED WHERE (the EVENT_CHANNELS question):
--   in the database  a number's format (is_e164, 20261030T1500); one number,
--                    one contact per firm (contact_phones_org_number_uq); and,
--                    NEW HERE, a staff/team/on-call number can't be stored on a
--                    contact. That was only in create_contact; a direct API
--                    insert skipped it. The check on 20 November found no such
--                    rows on staging or production: the door was never walked
--                    through, which is the cheapest time to close it.
--   importer only,   how a batch is classified: dedupe on number,
--   deliberately     fill-empty-only, holding ambiguity. These are about a
--                    batch, not about what a stored row may be. THE RISK: a
--                    second bulk path (a CRM sync, say) must call
--                    contact_import_classify(), or it will dedupe differently.
--
-- THE TRIGGER'S NAME IS LOAD-BEARING. Triggers of the same timing fire in
-- name order. contact_phones_not_firm_only_t must sort after
-- contact_phones_normalize_t, so it sees the stored E.164 form, not what was
-- typed. "nor" sorts before "not". Rename it and it may start checking the
-- un-normalised number; verification line 3 inserts a formatted number to
-- prove the order. It fires on INSERT, and on UPDATE only when e164 actually
-- changes, so 046's dormant case (a contact's number later listed as staff)
-- isn't disturbed, and merge_contacts (which moves contact_id) never fires it.
--
-- Requires: 004 (normalize_e164), 015, 016 (record_change), 053
--           (firm_only_number), 055 (create_contact), 038
--           (can_manage_settings), 20261030T1500, 20261103T1200.
-- NOT SAFE TO RUN TWICE: section 1 refuses on a second run.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Preconditions: the bodies this file calls are the reviewed ones
-- -----------------------------------------------------------------------------
DO $$
DECLARE v text;
BEGIN
  IF to_regclass('public.contact_imports') IS NOT NULL THEN
    RAISE EXCEPTION 'already converted; nothing to do here'
      USING HINT = 'This migration has run on this database. Not an error to fix — stop.';
  END IF;
  SELECT string_agg(f || '=' || COALESCE(m, 'missing'), ', ') INTO v
    FROM (VALUES ('record_change(uuid,history_entity,uuid,history_action,actor_kind,text,text,uuid,jsonb,link_method)', '130654ec3b66364423609c08b9fffdd5'),
                 ('normalize_e164(text)',             'e4bd821f21628e53254c286c53936174'),
                 ('firm_only_number(uuid,text)',      '19aea1e936d3e898deb26e6852102f39'),
                 ('create_contact(uuid,text,text,contact_type,text,phone_label,text,text,text)', 'a9fafd8b827745009841a745fddc62d3')) w(f, want)
    LEFT JOIN LATERAL (SELECT md5(prosrc) AS m FROM pg_proc WHERE oid = to_regprocedure(w.f)) p ON true
   WHERE p.m IS DISTINCT FROM w.want;
  IF v IS NOT NULL THEN
    RAISE EXCEPTION 'these bodies are not the reviewed ones: %; stop and diff them', v;
  END IF;
  IF (SELECT string_agg(tgname, ',' ORDER BY tgname) FROM pg_trigger
       WHERE tgrelid = 'public.contact_phones'::regclass AND NOT tgisinternal)
     IS DISTINCT FROM 'contact_phones_normalize_t,contact_phones_touch' THEN
    RAISE EXCEPTION 'contact_phones carries triggers this file doesn''t expect; stop and read them';
  END IF;
  IF to_regclass('public.contact_phones_org_number_uq') IS NULL THEN
    RAISE EXCEPTION 'contact_phones_org_number_uq is missing: one number, one contact, is what this file dedupes on';
  END IF;
  IF NOT ('contact_phones_normalize_t' < 'contact_phones_not_firm_only_t' COLLATE "C") THEN
    RAISE EXCEPTION 'the staff-number trigger would not fire after the normaliser';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. A staff, team or on-call number can't be stored on a contact
-- -----------------------------------------------------------------------------
CREATE FUNCTION contact_phones_not_firm_only()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_label text;
BEGIN
  IF NEW.e164 IS NULL OR (TG_OP = 'UPDATE' AND NEW.e164 IS NOT DISTINCT FROM OLD.e164) THEN
    RETURN NEW;
  END IF;
  v_label := firm_only_number(NEW.organization_id, NEW.e164);
  IF v_label IS NOT NULL THEN
    RAISE EXCEPTION 'that number is in the directory as %, so it belongs to the firm, not to a contact', v_label
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION contact_phones_not_firm_only() IS
  'A staff, team or on-call number is the firm''s, never a contact''s: the rule '
  'create_contact applied, now on the table, so no path skips it. New numbers '
  'and changed numbers only; a number that became staff later (046) stays, '
  'dormant. Fires after contact_phones_normalize_t by NAME ORDER: keep the name '
  'sorting after it (20261121T1000).';
CREATE TRIGGER contact_phones_not_firm_only_t
  BEFORE INSERT OR UPDATE OF e164 ON contact_phones
  FOR EACH ROW EXECUTE FUNCTION contact_phones_not_firm_only();
REVOKE ALL ON FUNCTION contact_phones_not_firm_only() FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 3. The record of an import, and where a contact came from
-- -----------------------------------------------------------------------------
CREATE TABLE contact_imports (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id    uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  imported_by        uuid NOT NULL REFERENCES users(id),
  filename           text,
  rows_in_file       integer NOT NULL,
  created            integer NOT NULL,
  filled             integer NOT NULL,
  unchanged          integer NOT NULL,
  held_resolved      integer NOT NULL,
  held_skipped       integer NOT NULL,
  refused            integer NOT NULL,
  calls_linked       integer NOT NULL,
  imported_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX contact_imports_org_idx ON contact_imports (organization_id, imported_at DESC);
COMMENT ON TABLE contact_imports IS
  'One row per committed contact import: who, when, the file, and what it did. '
  'Written by commit_contact_import alone, at the end of the import; updated or '
  'deleted by nobody. With change_history (which carries this id), it is the '
  'reversal path: there is no undo (20261121T1000).';

ALTER TABLE contact_imports ENABLE ROW LEVEL SECURITY;
ALTER TABLE contact_imports FORCE ROW LEVEL SECURITY;
-- Every client role, service_role included: on creation it would get TRUNCATE
-- and more by default (db/README.md, "Default privileges").
REVOKE ALL ON contact_imports FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT ON contact_imports TO authenticated;

CREATE POLICY contact_imports_read ON contact_imports FOR SELECT TO authenticated
  USING (is_internal() OR (can_manage_settings() AND organization_id = current_organization_id()));
-- The hub.contact_import flag is a seatbelt, not a lock (db/README.md, "hub.*
-- flags"): commit_contact_import sets it for its own INSERT and clears it.
CREATE POLICY contact_imports_insert ON contact_imports FOR INSERT TO authenticated
  WITH CHECK (can_manage_settings() AND organization_id = current_organization_id()
              AND imported_by = current_user_id()
              AND COALESCE(current_setting('hub.contact_import', true), '') = '1');
COMMENT ON POLICY contact_imports_read ON contact_imports IS
  'A firm''s owners and managers see its imports (20261121T1000).';
COMMENT ON POLICY contact_imports_insert ON contact_imports IS
  'Written only by commit_contact_import (the hub.contact_import seatbelt). No '
  'UPDATE or DELETE grant or policy: an import''s record is kept as written '
  '(20261121T1000).';

ALTER TABLE contacts ADD COLUMN import_id uuid
  REFERENCES contact_imports(id) DEFERRABLE INITIALLY DEFERRED;
COMMENT ON COLUMN contacts.import_id IS
  'The import that created this contact; null for every other path. A pointer, '
  'not the record: change_history is the record (20261121T1000).';

-- -----------------------------------------------------------------------------
-- 4. The classifier: the one statement of how an import row is treated
-- -----------------------------------------------------------------------------
CREATE FUNCTION contact_import_classify(p_org uuid, p_rows jsonb)
RETURNS SETOF jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
  r record; n int; v_full text; v_biz text; v_email text;
  v_raw text; v_e164 text; v_nums text[]; v_bad text; v_staff text; v_dups int[];
  v_matches uuid[]; v_c record; v_fills jsonb; v_diff jsonb; v_new text[]; v_cands jsonb;
BEGIN
  FOR r IN SELECT (e.ord)::int AS row_no, e.val FROM jsonb_array_elements(p_rows) WITH ORDINALITY e(val, ord) LOOP
    v_full  := NULLIF(btrim(COALESCE(r.val ->> 'full_name', '')), '');
    v_biz   := NULLIF(btrim(COALESCE(r.val ->> 'business_name', '')), '');
    v_email := NULLIF(btrim(COALESCE(r.val ->> 'email', '')), '');
    v_nums := '{}'; v_bad := NULL; v_staff := NULL;
    FOR v_raw IN SELECT btrim(COALESCE(p ->> 'number', '')) FROM jsonb_array_elements(COALESCE(r.val -> 'phones', '[]')) p LOOP
      CONTINUE WHEN v_raw = '';
      v_e164 := normalize_e164(v_raw);
      IF v_e164 IS NULL OR NOT is_e164(v_e164) THEN v_bad := COALESCE(v_bad, v_raw); CONTINUE; END IF;
      IF NOT v_e164 = ANY (v_nums) THEN v_nums := v_nums || v_e164; END IF;
      v_staff := COALESCE(v_staff, firm_only_number(p_org, v_e164));
    END LOOP;

    IF v_full IS NULL AND v_biz IS NULL THEN
      RETURN NEXT jsonb_build_object('row', r.row_no, 'verdict', 'refused', 'reason', 'a contact needs a name');
      CONTINUE;
    END IF;
    IF v_bad IS NOT NULL THEN
      RETURN NEXT jsonb_build_object('row', r.row_no, 'verdict', 'refused',
        'reason', format('"%s" isn''t a phone number', v_bad));
      CONTINUE;
    END IF;
    IF v_staff IS NOT NULL THEN
      RETURN NEXT jsonb_build_object('row', r.row_no, 'verdict', 'refused',
        'reason', format('a number on this row is in the directory as %s, so it belongs to the firm, not to a contact', v_staff));
      CONTINUE;
    END IF;

    -- The same number on another row of the file.
    SELECT array_agg(DISTINCT (o.ord)::int ORDER BY (o.ord)::int) INTO v_dups
      FROM jsonb_array_elements(p_rows) WITH ORDINALITY o(val, ord),
           jsonb_array_elements(COALESCE(o.val -> 'phones', '[]')) op
     WHERE (o.ord)::int <> r.row_no
       AND normalize_e164(btrim(COALESCE(op ->> 'number', ''))) = ANY (v_nums);
    IF v_dups IS NOT NULL THEN
      RETURN NEXT jsonb_build_object('row', r.row_no, 'verdict', 'held', 'hold', 'in_file', 'numbers', to_jsonb(v_nums),
        'reason', format('row %s of the file has the same number: fix the file', array_to_string(v_dups, ', ')));
      CONTINUE;
    END IF;

    -- Contacts already holding these numbers, following merged_into.
    SELECT array_agg(DISTINCT COALESCE(c.merged_into, c.id)) INTO v_matches
      FROM contact_phones cp JOIN contacts c ON c.id = cp.contact_id
     WHERE cp.organization_id = p_org AND cp.e164 = ANY (v_nums);

    IF v_matches IS NULL THEN
      RETURN NEXT jsonb_build_object('row', r.row_no,
        'verdict', CASE WHEN cardinality(v_nums) = 0 THEN 'create_no_number' ELSE 'create' END,
        'numbers', to_jsonb(v_nums),
        'reason', CASE WHEN cardinality(v_nums) = 0
                       THEN 'no number: this row can''t be matched, and importing the file again would add it again' END);
      CONTINUE;
    END IF;

    SELECT jsonb_agg(jsonb_build_object('id', c.id, 'name', COALESCE(c.full_name, c.business_name, 'unnamed contact'),
                                        'blocked', c.blocked) ORDER BY c.full_name, c.id)
      INTO v_cands FROM contacts c WHERE c.id = ANY (v_matches);

    IF cardinality(v_matches) > 1 THEN
      RETURN NEXT jsonb_build_object('row', r.row_no, 'verdict', 'held', 'hold', 'two_contacts',
        'numbers', to_jsonb(v_nums), 'candidates', v_cands,
        'reason', 'this row''s numbers belong to two contacts');
      CONTINUE;
    END IF;

    SELECT * INTO v_c FROM contacts WHERE id = v_matches[1];
    IF v_c.blocked THEN
      RETURN NEXT jsonb_build_object('row', r.row_no, 'verdict', 'held', 'hold', 'blocked',
        'numbers', to_jsonb(v_nums), 'candidates', v_cands,
        'reason', 'this row''s number belongs to a blocked contact');
      CONTINUE;
    END IF;

    v_fills := '{}'; v_diff := '{}';
    IF v_full IS NOT NULL AND v_c.full_name IS NULL THEN v_fills := v_fills || jsonb_build_object('full_name', v_full);
    ELSIF v_full IS NOT NULL AND v_c.full_name <> v_full THEN v_diff := v_diff || jsonb_build_object('full_name', jsonb_build_object('have', v_c.full_name, 'file', v_full)); END IF;
    IF v_biz IS NOT NULL AND v_c.business_name IS NULL THEN v_fills := v_fills || jsonb_build_object('business_name', v_biz);
    ELSIF v_biz IS NOT NULL AND v_c.business_name <> v_biz THEN v_diff := v_diff || jsonb_build_object('business_name', jsonb_build_object('have', v_c.business_name, 'file', v_biz)); END IF;
    IF v_email IS NOT NULL AND v_c.email IS NULL THEN v_fills := v_fills || jsonb_build_object('email', v_email);
    ELSIF v_email IS NOT NULL AND v_c.email <> v_email THEN v_diff := v_diff || jsonb_build_object('email', jsonb_build_object('have', v_c.email, 'file', v_email)); END IF;
    SELECT COALESCE(array_agg(x), '{}') INTO v_new FROM unnest(v_nums) x
     WHERE NOT EXISTS (SELECT 1 FROM contact_phones cp WHERE cp.organization_id = p_org AND cp.e164 = x);

    RETURN NEXT jsonb_build_object('row', r.row_no,
      'verdict', CASE WHEN v_fills = '{}' AND cardinality(v_new) = 0 THEN 'unchanged' ELSE 'fill' END,
      'contact_id', v_c.id, 'contact_name', COALESCE(v_c.full_name, v_c.business_name, 'unnamed contact'),
      'numbers', to_jsonb(v_nums), 'fills', v_fills, 'new_numbers', to_jsonb(v_new), 'differences', v_diff);
  END LOOP;
END $$;
COMMENT ON FUNCTION contact_import_classify(uuid, jsonb) IS
  'How each row of a contact import is treated, stated once: preview and commit '
  'both call it, and any other bulk path must too. Matches on phone number '
  'against the firm''s book and the file''s other rows; never on names; never '
  'guesses. Writes nothing (20261121T1000).';

-- The checks both entry points make, once.
CREATE FUNCTION contact_import_check(p_rows jsonb)
RETURNS uuid LANGUAGE plpgsql STABLE AS $$
DECLARE v_org uuid := current_organization_id(); n int;
BEGIN
  IF v_org IS NULL OR NOT can_manage_settings() THEN
    RAISE EXCEPTION 'importing contacts is for your firm''s owners and managers' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p_rows) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'the import needs a list of rows';
  END IF;
  n := jsonb_array_length(p_rows);
  IF n > 5000 THEN
    RAISE EXCEPTION 'This file has % rows; the limit is 5,000. Split it and import twice.', to_char(n, 'FM999,999');
  END IF;
  RETURN v_org;
END $$;

-- -----------------------------------------------------------------------------
-- 5. Preview: what would happen, written nowhere
-- -----------------------------------------------------------------------------
CREATE FUNCTION preview_contact_import(p_rows jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE v_org uuid := contact_import_check(p_rows); v_rows jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg(x ORDER BY (x ->> 'row')::int), '[]') INTO v_rows
    FROM contact_import_classify(v_org, p_rows) x;
  RETURN jsonb_build_object(
    'rows_in_file', jsonb_array_length(p_rows),
    'counts', (SELECT COALESCE(jsonb_object_agg(v, c), '{}') FROM
                (SELECT x ->> 'verdict' AS v, count(*) AS c FROM jsonb_array_elements(v_rows) x GROUP BY 1) t),
    'rows', v_rows);
END $$;
COMMENT ON FUNCTION preview_contact_import(jsonb) IS
  'For a firm''s owners and managers: what importing these rows would do, row '
  'by row, writing nothing. Held rows carry the contacts a person may pick '
  'between. Up to 5,000 rows (20261121T1000).';

-- -----------------------------------------------------------------------------
-- 6. Commit: classify again, apply, and record enough to reverse by hand
-- -----------------------------------------------------------------------------
CREATE FUNCTION commit_contact_import(p_rows jsonb, p_filename text DEFAULT NULL,
                                      p_choices jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_org uuid := contact_import_check(p_rows);
  v_import uuid := gen_random_uuid();
  v_user uuid := current_user_id(); v_actor text;
  x jsonb; v_row jsonb; v_target uuid; v_choice text; v_c record;
  v_fields jsonb; v_added text[]; v_num text; v_label phone_label; i int; v_call uuid;
  k_created int := 0; k_filled int := 0; k_unchanged int := 0; k_resolved int := 0;
  k_skipped int := 0; k_refused int := 0; k_calls int := 0;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'your sign-in isn''t linked to a Hub user, so the import can''t say who did it';
  END IF;
  SELECT full_name INTO v_actor FROM users WHERE id = v_user;
  v_actor := COALESCE(v_actor, 'Someone');

  FOR x IN SELECT y FROM contact_import_classify(v_org, p_rows) y ORDER BY (y ->> 'row')::int LOOP
    v_row := p_rows -> ((x ->> 'row')::int - 1);
    v_target := NULL;

    IF x ->> 'verdict' = 'refused' THEN k_refused := k_refused + 1; CONTINUE; END IF;

    IF x ->> 'verdict' = 'held' THEN
      v_choice := p_choices ->> (x ->> 'row');
      IF x ->> 'hold' = 'in_file' OR v_choice IS NULL OR v_choice = 'skip'
         OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(x -> 'candidates') cnd WHERE cnd ->> 'id' = v_choice) THEN
        k_skipped := k_skipped + 1; CONTINUE;
      END IF;
      v_target := v_choice::uuid;
      k_resolved := k_resolved + 1;
    ELSIF x ->> 'verdict' IN ('create', 'create_no_number') THEN
      INSERT INTO contacts (organization_id, contact_kind, full_name, business_name, email, import_id)
      VALUES (v_org,
              CASE WHEN NULLIF(btrim(COALESCE(v_row ->> 'full_name', '')), '') IS NULL THEN 'business' ELSE 'individual' END::contact_kind,
              NULLIF(btrim(COALESCE(v_row ->> 'full_name', '')), ''),
              NULLIF(btrim(COALESCE(v_row ->> 'business_name', '')), ''),
              NULLIF(btrim(COALESCE(v_row ->> 'email', '')), ''), v_import)
      RETURNING id INTO v_target;
      i := 0;
      FOR v_num IN SELECT jsonb_array_elements_text(x -> 'numbers') LOOP
        v_label := (SELECT CASE WHEN p ->> 'label' = ANY (enum_range(NULL::phone_label)::text[]) THEN (p ->> 'label')::phone_label ELSE 'mobile' END
                      FROM jsonb_array_elements(COALESCE(v_row -> 'phones', '[]')) p
                     WHERE normalize_e164(btrim(COALESCE(p ->> 'number', ''))) = v_num LIMIT 1);
        INSERT INTO contact_phones (organization_id, contact_id, e164, label, is_primary, added_by)
        VALUES (v_org, v_target, v_num, COALESCE(v_label, 'mobile'), i = 0, 'contact import');
        i := i + 1;
      END LOOP;
      PERFORM record_change(v_org, 'contact', v_target, 'created', 'user', v_actor,
        format('%s created this contact by importing %s', v_actor, COALESCE(p_filename, 'a contact list')),
        v_user, jsonb_build_object('import_id', v_import, 'row', (x ->> 'row')::int, 'numbers', x -> 'numbers'));
      k_created := k_created + 1;
    ELSE
      v_target := (x ->> 'contact_id')::uuid;   -- fill or unchanged
    END IF;

    -- Fill the target's empty fields, and add numbers no contact holds.
    IF x ->> 'verdict' IN ('fill', 'unchanged', 'held') THEN
      SELECT * INTO v_c FROM contacts WHERE id = v_target FOR UPDATE;
      v_fields := '{}'; v_added := '{}';
      IF v_c.full_name IS NULL AND NULLIF(btrim(COALESCE(v_row ->> 'full_name', '')), '') IS NOT NULL THEN
        v_fields := v_fields || jsonb_build_object('full_name', jsonb_build_object('from', NULL, 'to', btrim(v_row ->> 'full_name')));
      END IF;
      IF v_c.business_name IS NULL AND NULLIF(btrim(COALESCE(v_row ->> 'business_name', '')), '') IS NOT NULL THEN
        v_fields := v_fields || jsonb_build_object('business_name', jsonb_build_object('from', NULL, 'to', btrim(v_row ->> 'business_name')));
      END IF;
      IF v_c.email IS NULL AND NULLIF(btrim(COALESCE(v_row ->> 'email', '')), '') IS NOT NULL THEN
        v_fields := v_fields || jsonb_build_object('email', jsonb_build_object('from', NULL, 'to', btrim(v_row ->> 'email')));
      END IF;
      IF v_fields <> '{}' THEN
        UPDATE contacts SET
          full_name     = COALESCE(full_name, v_fields #>> '{full_name,to}'),
          business_name = COALESCE(business_name, v_fields #>> '{business_name,to}'),
          email         = COALESCE(email, v_fields #>> '{email,to}'),
          updated_at    = now()
         WHERE id = v_target;
      END IF;
      FOR v_num IN SELECT jsonb_array_elements_text(x -> 'numbers') LOOP
        CONTINUE WHEN EXISTS (SELECT 1 FROM contact_phones cp WHERE cp.organization_id = v_org AND cp.e164 = v_num);
        INSERT INTO contact_phones (organization_id, contact_id, e164, label, is_primary, added_by)
        VALUES (v_org, v_target, v_num, 'mobile',
                NOT EXISTS (SELECT 1 FROM contact_phones cp WHERE cp.contact_id = v_target AND cp.is_primary),
                'contact import');
        v_added := v_added || v_num;
      END LOOP;
      IF v_fields <> '{}' OR cardinality(v_added) > 0 THEN
        PERFORM record_change(v_org, 'contact', v_target, 'updated', 'user', v_actor,
          format('%s added to this contact by importing %s', v_actor, COALESCE(p_filename, 'a contact list')),
          v_user, jsonb_build_object('import_id', v_import, 'row', (x ->> 'row')::int,
                                     'fields', v_fields, 'numbers_added', to_jsonb(v_added),
                                     'held_choice', x ->> 'verdict' = 'held'));
        IF x ->> 'verdict' <> 'held' THEN k_filled := k_filled + 1; END IF;
      ELSIF x ->> 'verdict' <> 'held' THEN
        k_unchanged := k_unchanged + 1;
      END IF;
    END IF;

    -- Past calls from the row's numbers that now belong to the target: only
    -- calls with no contact at all, never one a person unlinked by hand.
    FOR v_call IN
      UPDATE interactions i SET contact_id = v_target, contact_link_method = 'imported', updated_at = now()
       WHERE i.organization_id = v_org AND i.contact_id IS NULL
         AND (CASE WHEN i.direction = 'inbound' THEN i.from_e164 ELSE i.to_e164 END)
             IN (SELECT cp.e164 FROM contact_phones cp
                  WHERE cp.contact_id = v_target
                    AND cp.e164 IN (SELECT jsonb_array_elements_text(x -> 'numbers')))
         AND NOT EXISTS (SELECT 1 FROM change_history h
                          WHERE h.entity = 'interaction' AND h.entity_id = i.id
                            AND h.action = 'unlinked' AND h.detail ->> 'field' = 'contact_id')
      RETURNING i.id
    LOOP
      PERFORM record_change(v_org, 'interaction', v_call, 'linked', 'user', v_actor,
        format('Linked to a contact by %s''s import of %s', v_actor, COALESCE(p_filename, 'a contact list')),
        v_user, jsonb_build_object('field', 'contact_id', 'contact_id', v_target,
                                   'previous_contact_id', NULL, 'previous_state', 'unlinked',
                                   'import_id', v_import),
        'imported');
      k_calls := k_calls + 1;
    END LOOP;
  END LOOP;

  PERFORM set_config('hub.contact_import', '1', true);
  INSERT INTO contact_imports (id, organization_id, imported_by, filename, rows_in_file, created, filled,
                               unchanged, held_resolved, held_skipped, refused, calls_linked)
  VALUES (v_import, v_org, v_user, p_filename, jsonb_array_length(p_rows), k_created, k_filled,
          k_unchanged, k_resolved, k_skipped, k_refused, k_calls);
  PERFORM set_config('hub.contact_import', '', true);

  RETURN jsonb_build_object('import_id', v_import, 'created', k_created, 'filled', k_filled,
    'unchanged', k_unchanged, 'held_resolved', k_resolved, 'held_skipped', k_skipped,
    'refused', k_refused, 'calls_linked', k_calls);
END $$;
COMMENT ON FUNCTION commit_contact_import(jsonb, text, jsonb) IS
  'For a firm''s owners and managers: import contacts. Classifies again (never '
  'trusts the preview), creates, fills empty fields only, applies a held row only '
  'where p_choices names one of its candidates, links past unlinked calls as '
  '''imported'', and records each change with this import''s id: fills with '
  'from and to, calls with their prior unlinked state. One transaction. A second '
  'commit of the same rows changes nothing for rows with numbers. There is no '
  'undo; this history is the reversal path (20261121T1000).';

REVOKE ALL ON FUNCTION contact_import_classify(uuid, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION contact_import_check(jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION preview_contact_import(jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION commit_contact_import(jsonb, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION contact_import_classify(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION contact_import_check(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION preview_contact_import(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION commit_contact_import(jsonb, text, jsonb) TO authenticated;

-- -----------------------------------------------------------------------------
-- 7. Record it
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261121T1000_contact_import.sql',
    NULL,
    'Contact import: contact_import_classify (dedupe on number, the one statement), '
    'preview_contact_import (writes nothing), commit_contact_import (creates, '
    'fills empty fields, applies picked held rows, links past unlinked calls as '
    'imported, records from/to and prior state), contact_imports and '
    'contacts.import_id. Staff numbers refused on contact_phones itself. No undo.');
END $rec$;

COMMIT;

-- =============================================================================
-- Verification — run AFTER the file, as its own statement. One block,
-- everything rolled back by the closing RAISE.
--
-- A fixture firm with a manager (Mo) and a professional (Pat), and a book
-- that already holds: Ellen Park (…01), Xavier (…02) and Yvonne (…03) as
-- separate contacts, a blocked contact (…04), a contact merged into another
-- whose number (…05) stayed on the merged-away one, and a staff cell (…06).
-- Three calls from a new number (…07): one unlinked, one a person unlinked by
-- hand, one already confirmed to someone else. A second firm holds …08. The
-- file has twelve rows, one per case in the dedupe table. All as
-- authenticated, because postgres holds BYPASSRLS.
--
-- DO $$
-- DECLARE
--   r text := ''; res text; n int; m int; pv jsonb; cm jsonb; cm2 jsonb; rows jsonb; v jsonb;
--   v_org uuid; v_b uuid; u_mo uuid; u_pat uuid; a_mo uuid := gen_random_uuid(); a_pat uuid := gen_random_uuid();
--   c_ellen uuid; c_x uuid; c_y uuid; c_z uuid; c_loser uuid; c_surv uuid; c_other uuid; c_b uuid; c_dorm uuid;
--   call_open uuid; call_hand uuid; call_conf uuid; n0 int;
--   num CONSTANT text := '+1513555010';   -- …01 to …11
-- BEGIN
--   PERFORM set_config('app.is_internal', 'on', true);
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ verify import', 'funeral_home') RETURNING id INTO v_org;
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ verify import B', 'funeral_home') RETURNING id INTO v_b;
--   INSERT INTO users (email, full_name, auth_user_id) VALUES ('zzz-imp-m@example.invalid', 'ZZZ Mo', a_mo) RETURNING id INTO u_mo;
--   INSERT INTO users (email, full_name, auth_user_id) VALUES ('zzz-imp-p@example.invalid', 'ZZZ Pat', a_pat) RETURNING id INTO u_pat;
--   INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id) VALUES
--     (u_mo, 'organization', 'manager', v_org), (u_pat, 'organization', 'professional', v_org);
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'Ellen Park') RETURNING id INTO c_ellen;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'Xavier') RETURNING id INTO c_x;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'Yvonne') RETURNING id INTO c_y;
--   INSERT INTO contacts (organization_id, full_name, blocked, blocked_at, blocked_by) VALUES (v_org, 'Zed', true, now(), 'ZZZ') RETURNING id INTO c_z;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'Survivor') RETURNING id INTO c_surv;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'Merged away') RETURNING id INTO c_loser;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'Someone else') RETURNING id INTO c_other;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_b, 'Other firm''s contact') RETURNING id INTO c_b;
--   INSERT INTO contact_phones (organization_id, contact_id, e164, is_primary) VALUES
--     (v_org, c_ellen, num || '1', true), (v_org, c_x, num || '2', true), (v_org, c_y, num || '3', true),
--     (v_org, c_z, num || '4', true), (v_org, c_loser, num || '5', true), (v_b, c_b, num || '8', true);
--   UPDATE contacts SET merged_into = c_surv WHERE id = c_loser;
--   INSERT INTO directory_entries (organization_id, entry_kind, label, e164) VALUES (v_org, 'staff', 'ZZZ Director cell', num || '6');
--   INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at, from_e164)
--   VALUES (v_org, 'inbound', now() - interval '3 days', now() - interval '3 days', num || '7') RETURNING id INTO call_open;
--   INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at, from_e164)
--   VALUES (v_org, 'inbound', now() - interval '2 days', now() - interval '2 days', num || '7') RETURNING id INTO call_hand;
--   INSERT INTO change_history (organization_id, entity, entity_id, action, actor_kind, actor_user_id, actor_label, summary, detail)
--   VALUES (v_org, 'interaction', call_hand, 'unlinked', 'user', u_mo, 'ZZZ', 'took someone off this call', jsonb_build_object('field', 'contact_id'));
--   INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at, from_e164, contact_id, contact_link_method)
--   VALUES (v_org, 'inbound', now() - interval '1 day', now() - interval '1 day', num || '7', c_other, 'confirmed') RETURNING id INTO call_conf;
--   PERFORM set_config('app.is_internal', 'off', true);
--   PERFORM set_config('role', 'authenticated', true);
--
--   rows := jsonb_build_array(
--     jsonb_build_object('full_name', 'Ellen Parker', 'email', 'ellen@example.invalid', 'phones', jsonb_build_array(jsonb_build_object('number', '(513) 555-0101'))),
--     jsonb_build_object('full_name', 'X or Y', 'phones', jsonb_build_array(jsonb_build_object('number', num || '2'), jsonb_build_object('number', num || '3'))),
--     jsonb_build_object('full_name', 'Zed again', 'phones', jsonb_build_array(jsonb_build_object('number', num || '4'))),
--     jsonb_build_object('full_name', 'Merged person', 'email', 'm@example.invalid', 'phones', jsonb_build_array(jsonb_build_object('number', num || '5'))),
--     jsonb_build_object('full_name', 'Staff member', 'phones', jsonb_build_array(jsonb_build_object('number', num || '6'))),
--     jsonb_build_object('full_name', 'New Person', 'phones', jsonb_build_array(jsonb_build_object('number', num || '7', 'label', 'home'))),
--     jsonb_build_object('full_name', 'No Number'),
--     jsonb_build_object('full_name', 'Dup A', 'phones', jsonb_build_array(jsonb_build_object('number', num || '9'))),
--     jsonb_build_object('full_name', 'Dup B', 'phones', jsonb_build_array(jsonb_build_object('number', num || '9'))),
--     jsonb_build_object('email', 'nameless@example.invalid', 'phones', jsonb_build_array(jsonb_build_object('number', num || '10'))),
--     jsonb_build_object('full_name', 'Bad Number', 'phones', jsonb_build_array(jsonb_build_object('number', '12'))),
--     jsonb_build_object('full_name', 'Same number, other firm', 'phones', jsonb_build_array(jsonb_build_object('number', num || '8'))));
--
--   -- ---- who may, and the cap -------------------------------------------
--   PERFORM set_config('request.jwt.claims', json_build_object('sub', a_pat::text)::text, true);
--   BEGIN PERFORM preview_contact_import(rows); res := 'ALLOWED';
--   EXCEPTION WHEN insufficient_privilege THEN res := SQLSTATE; END;
--   r := r || '1. a professional previews an import: ' || res || '   (expect 42501)' || chr(10);
--   PERFORM set_config('request.jwt.claims', json_build_object('sub', a_mo::text)::text, true);
--   BEGIN PERFORM preview_contact_import((SELECT jsonb_agg(jsonb_build_object('full_name', 'x')) FROM generate_series(1, 5001)));
--     res := 'ALLOWED';
--   EXCEPTION WHEN OTHERS THEN res := SQLERRM; END;
--   r := r || '2. 5,001 rows: ' || res || '   (expect "This file has 5,001 rows; the limit is 5,000. Split it and import twice.")' || chr(10);
--
--   -- ---- the staff-number rule, on the table -----------------------------
--   BEGIN INSERT INTO contact_phones (organization_id, contact_id, e164) VALUES (v_org, c_other, '(513) 555-0106'); res := 'ALLOWED';
--   EXCEPTION WHEN OTHERS THEN res := SQLERRM; END;
--   r := r || '3. a direct insert of the staff cell, typed with brackets: ' || res
--          || '   (expect "…in the directory as ZZZ Director cell…": the trigger saw the normalised number)' || chr(10);
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_org, 'Dormant') RETURNING id INTO c_dorm;
--   INSERT INTO contact_phones (organization_id, contact_id, e164, is_primary) VALUES (v_org, c_dorm, num || '11', true);
--   INSERT INTO directory_entries (organization_id, entry_kind, label, e164) VALUES (v_org, 'staff', 'ZZZ Later staff', num || '11');
--   BEGIN UPDATE contact_phones SET label = 'work' WHERE contact_id = c_dorm; res := 'edited';
--   EXCEPTION WHEN OTHERS THEN res := SQLERRM; END;
--   r := r || '4. 046''s case: a contact''s number later listed as staff, then the phone edited: ' || res || '   (expect edited)' || chr(10);
--
--   -- ---- the preview: every case in the dedupe table ---------------------
--   SELECT count(*) INTO n0 FROM contacts WHERE organization_id = v_org;
--   pv := preview_contact_import(rows);
--   r := r || '5. verdicts by row: ' || (SELECT string_agg((x ->> 'row') || ' ' || (x ->> 'verdict') || COALESCE('/' || (x ->> 'hold'), ''), ', ' ORDER BY (x ->> 'row')::int)
--                                        FROM jsonb_array_elements(pv -> 'rows') x) || chr(10)
--          || '   (expect 1 fill, 2 held/two_contacts, 3 held/blocked, 4 fill, 5 refused, 6 create, 7 create_no_number,' || chr(10)
--          || '    8 held/in_file, 9 held/in_file, 10 refused, 11 refused, 12 create)' || chr(10);
--   v := pv -> 'rows' -> 0;
--   r := r || '6. row 1 (Ellen): fills ' || (v -> 'fills')::text || ', differences ' || (v -> 'differences')::text
--          || '   (expect email filled; full_name have "Ellen Park", file "Ellen Parker": shown, kept)' || chr(10);
--   r := r || '7. row 2 (two contacts): ' || (pv #>> '{rows,1,reason}') || '; candidates ' || jsonb_array_length(pv #> '{rows,1,candidates}')
--          || '   (expect "this row''s numbers belong to two contacts"; 2)' || chr(10);
--   r := r || '8. row 3 (blocked contact): ' || (pv #>> '{rows,2,reason}') || '   (expect "…belongs to a blocked contact")' || chr(10);
--   r := r || '9. row 4 (number on a merged-away contact): goes to the survivor: ' || ((pv #>> '{rows,3,contact_id}')::uuid = c_surv)
--          || '   (expect true: merged_into followed)' || chr(10);
--   r := r || '10. rows 5, 10, 11 refused: ' || (pv #>> '{rows,4,reason}') || ' | ' || (pv #>> '{rows,9,reason}') || ' | ' || (pv #>> '{rows,10,reason}') || chr(10)
--          || '   (expect the directory entry named | "a contact needs a name" | "\"12\" isn''t a phone number")' || chr(10);
--   r := r || '11. row 7 (no number): ' || (pv #>> '{rows,6,reason}') || chr(10)
--          || '   (expect "no number: this row can''t be matched, and importing the file again would add it again")' || chr(10);
--   r := r || '12. row 8 (same number as row 9): ' || (pv #>> '{rows,7,reason}') || '   (expect "row 9 of the file has the same number: fix the file")' || chr(10);
--   r := r || '13. row 12 (a number another firm holds): ' || (pv #>> '{rows,11,verdict}') || '   (expect create: firm B''s contact is never matched)' || chr(10);
--   SELECT count(*) INTO n FROM contacts WHERE organization_id = v_org;
--   r := r || '14. the preview wrote nothing: contacts ' || n0 || ' before, ' || n || ' after   (expect equal)' || chr(10);
--
--   -- ---- commit, with row 2 picked onto Xavier and row 3 skipped -----------
--   cm := commit_contact_import(rows, 'zzz-book.csv', jsonb_build_object('2', c_x::text, '3', 'skip'));
--   r := r || '15. commit: ' || (cm - 'import_id')::text || chr(10)
--          || '   (expect created 3 (rows 6, 7, 12), filled 2 (rows 1, 4), unchanged 0, held_resolved 1 (row 2),' || chr(10)
--          || '    held_skipped 3 (rows 3, 8, 9), refused 3 (rows 5, 10, 11), calls_linked 1)' || chr(10);
--   r := r || '16. Ellen: name ' || (SELECT full_name FROM contacts WHERE id = c_ellen) || ', email ' || (SELECT email FROM contacts WHERE id = c_ellen)
--          || '; history fields ' || (SELECT detail -> 'fields' FROM change_history WHERE entity = 'contact' AND entity_id = c_ellen AND action = 'updated')::text
--          || chr(10) || '   (expect name Ellen Park, kept; email filled; fields email from null to the address)' || chr(10);
--   r := r || '17. row 2 picked onto Xavier: …03 still with Yvonne: '
--          || ((SELECT contact_id FROM contact_phones WHERE organization_id = v_org AND e164 = num || '3') = c_y)
--          || '; Zed (skipped) unchanged: ' || ((SELECT email FROM contacts WHERE id = c_z) IS NULL)
--          || '   (expect true; true)' || chr(10);
--   r := r || '18. calls from …07: unlinked one now on the new contact, as imported: '
--          || (SELECT contact_link_method::text FROM interactions WHERE id = call_open)
--          || '; the hand-unlinked one: ' || COALESCE((SELECT contact_id::text FROM interactions WHERE id = call_hand), 'still unlinked')
--          || '; the confirmed one still on Someone else: ' || ((SELECT contact_id FROM interactions WHERE id = call_conf) = c_other)
--          || chr(10) || '   (expect imported; still unlinked; true)' || chr(10);
--   r := r || '19. the linked call''s history says it was unlinked before: '
--          || (SELECT (detail ->> 'previous_state') || ', previous_contact_id ' || COALESCE(detail ->> 'previous_contact_id', 'null')
--                     || ', link_method ' || link_method::text
--                FROM change_history WHERE entity = 'interaction' AND entity_id = call_open AND action = 'linked')
--          || '   (expect unlinked, previous_contact_id null, link_method imported)' || chr(10);
--   r := r || '20. created contacts carry the import and a history row: '
--          || (SELECT count(*) FROM contacts WHERE import_id = (cm ->> 'import_id')::uuid) || ' / '
--          || (SELECT count(*) FROM change_history WHERE action = 'created' AND detail ->> 'import_id' = cm ->> 'import_id')
--          || '   (expect 3 / 3)' || chr(10);
--   r := r || '21. the import''s record: ' || (SELECT filename || ', by ' || (imported_by = u_mo) || ', created ' || created
--                                               FROM contact_imports WHERE id = (cm ->> 'import_id')::uuid)
--          || '   (expect zzz-book.csv, by true, created 3)' || chr(10);
--   -- counted as the system: the manager can't see firm B's rows at all
--   PERFORM set_config('role', 'none', true);
--   r := r || '22. firm B''s contact untouched: …08 still on it: '
--          || EXISTS (SELECT 1 FROM contact_phones WHERE organization_id = v_b AND contact_id = c_b AND e164 = num || '8')
--          || ', and on a new contact at this firm too: '
--          || EXISTS (SELECT 1 FROM contact_phones cp JOIN contacts c ON c.id = cp.contact_id
--                      WHERE cp.organization_id = v_org AND cp.e164 = num || '8' AND c.import_id IS NOT NULL)
--          || '   (expect true, true: one number, two firms, never matched across)' || chr(10);
--   PERFORM set_config('role', 'authenticated', true);
--
--   -- ---- the same file again -------------------------------------------
--   SELECT count(*) INTO n FROM change_history WHERE organization_id = v_org;
--   cm2 := commit_contact_import(rows, 'zzz-book.csv', jsonb_build_object('2', c_x::text, '3', 'skip'));
--   SELECT count(*) INTO m FROM change_history WHERE organization_id = v_org;
--   r := r || '23. the same file again: ' || (cm2 - 'import_id')::text || '; history rows added: ' || (m - n) || chr(10)
--          || '   (expect created 1 (only row 7, no number, as warned), filled 0, unchanged 4, calls_linked 0; 1)' || chr(10);
--
--   -- ---- the record can't be forged or changed --------------------------
--   BEGIN INSERT INTO contact_imports (organization_id, imported_by, rows_in_file, created, filled, unchanged, held_resolved, held_skipped, refused, calls_linked)
--         VALUES (v_org, u_mo, 1, 0, 0, 0, 0, 0, 0, 0); res := 'ALLOWED';
--   EXCEPTION WHEN insufficient_privilege THEN res := SQLSTATE; END;
--   r := r || '24. the manager writes an import record directly: ' || res || '   (expect 42501: only the commit writes it)' || chr(10);
--   r := r || '25. authenticated may UPDATE / DELETE contact_imports: '
--          || has_table_privilege('authenticated', 'public.contact_imports', 'UPDATE') || ' / '
--          || has_table_privilege('authenticated', 'public.contact_imports', 'DELETE')
--          || '   (expect false / false)' || chr(10);
--   PERFORM set_config('request.jwt.claims', json_build_object('sub', a_pat::text)::text, true);
--   r := r || '26. a professional reads the firm''s imports: ' || (SELECT count(*) FROM contact_imports WHERE organization_id = v_org)
--          || '   (expect 0: owners and managers)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261121T1000_contact_import (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
