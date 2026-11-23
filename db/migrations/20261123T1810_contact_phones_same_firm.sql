-- =============================================================================
-- 20261123T1810_contact_phones_same_firm.sql
-- The Hub — a phone record's contact is at the phone record's firm, by the
-- schema, not only by the importer.
--
-- THE HOLE. contact_phones has a foreign key to organizations and a separate
-- one to contacts, and nothing says the two firms agree. Found writing
-- 20261123T1630: under postgres (BYPASSRLS) a phone row of firm A on firm B's
-- contact would hand B's contact to A's import. 1630's importer refuses that
-- shape; the schema still allowed it. Audited on both databases: zero such
-- rows (production 2 phone rows, staging 14), so this is a guard, not a
-- cleanup (Mandie, 23 November).
--
-- THE FIRST BATCH OF FAMILY A. The audit found 140 single-column foreign keys
-- where both sides carry organization_id and the key doesn't include it.
-- Family A (123 keys, both sides NOT NULL) takes a composite key; this file
-- is its first batch, contact_phones -> contacts alone, the relationship the
-- import exposed, to prove the pattern end to end before the rest go in
-- batches by target table. Families B (targets with global, NULL-firm rows)
-- and C (nullable source firm) are not this pattern and not this file.
--
-- THE PATTERN, for every later batch:
--   1. a unique index on the target's (id, organization_id), for the
--      composite key to reference;
--   2. the single-column key REPLACED, not joined, by
--      (x_id, organization_id) REFERENCES target (id, organization_id), in
--      one ALTER TABLE, so there is no moment with neither and no write
--      checks the same relationship twice. The name is kept: anything that
--      reports a constraint by name still sees the same one;
--   3. ON DELETE carried over EXACTLY. CASCADE stays CASCADE. SET NULL
--      CANNOT be carried over as written: on a composite key it would null
--      every column, organization_id included, which is NOT NULL, so a
--      delete that used to clear a pointer would fail instead. It becomes
--      SET NULL (the pointer column), the column-list form (Postgres 15+;
--      production is 17). So comparing confdeltype is not enough: the check
--      must compare confdelsetcols too. Line 5 of the verification does;
--   4. ON UPDATE NO ACTION, never CASCADE: a contact doesn't change firm,
--      and CASCADE would quietly move its phone records instead of refusing.
--
-- THIS PAIR HAS TWO KEYS, not one: contact_id (ON DELETE CASCADE, NOT NULL)
-- and merged_from_contact_id (ON DELETE SET NULL, nullable: the contact a
-- merge moved the number from). Both are replaced here. The second is the
-- first instance of rule 3's trap, which is why it belongs in the batch that
-- proves the pattern.
--
-- No row-level security question: a foreign key holds for every role,
-- postgres included. That is the point. The verification runs as postgres.
--
-- Requires: 015_contact_phones (both keys, as pinned in section 1),
--           20261103T1200 (record_migration).
-- NOT SAFE TO RUN TWICE: section 1 refuses once the keys are composite.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Preconditions: the two keys as they are, and no row they'd refuse
-- -----------------------------------------------------------------------------
DO $$
DECLARE v text; n int;
BEGIN
  IF (SELECT pg_get_constraintdef(oid) FROM pg_constraint
       WHERE conrelid = 'contact_phones'::regclass AND conname = 'contact_phones_contact_id_fkey')
     IS DISTINCT FROM 'FOREIGN KEY (contact_id) REFERENCES contacts(id) ON DELETE CASCADE' THEN
    RAISE EXCEPTION 'contact_phones_contact_id_fkey is not the single-column CASCADE key this file replaces: already converted, or changed: stop and read it';
  END IF;
  IF (SELECT pg_get_constraintdef(oid) FROM pg_constraint
       WHERE conrelid = 'contact_phones'::regclass AND conname = 'contact_phones_merged_from_contact_id_fkey')
     IS DISTINCT FROM 'FOREIGN KEY (merged_from_contact_id) REFERENCES contacts(id) ON DELETE SET NULL' THEN
    RAISE EXCEPTION 'contact_phones_merged_from_contact_id_fkey is not the single-column SET NULL key this file replaces: already converted, or changed: stop and read it';
  END IF;
  SELECT count(*) INTO n FROM pg_constraint
   WHERE conrelid = 'contact_phones'::regclass AND confrelid = 'contacts'::regclass AND contype = 'f';
  IF n <> 2 THEN
    RAISE EXCEPTION 'contact_phones has % foreign keys to contacts, not the 2 this file was written for: stop and read them', n;
  END IF;
  IF NOT (SELECT attnotnull FROM pg_attribute WHERE attrelid = 'contact_phones'::regclass AND attname = 'organization_id')
     OR NOT (SELECT attnotnull FROM pg_attribute WHERE attrelid = 'contacts'::regclass AND attname = 'organization_id') THEN
    RAISE EXCEPTION 'organization_id is nullable on contact_phones or contacts: this is not family A, and a composite key would not hold';
  END IF;
  IF to_regclass('public.contacts_id_organization_uq') IS NOT NULL THEN
    RAISE EXCEPTION 'contacts_id_organization_uq already exists: stop and read it';
  END IF;
  -- Both columns are NOT NULL on the contact_id side, so <> is exact; on the
  -- merged_from side only rows that point anywhere are compared.
  SELECT count(*) INTO n FROM contact_phones cp JOIN contacts c ON c.id = cp.contact_id
   WHERE cp.organization_id <> c.organization_id;
  IF n > 0 THEN
    RAISE EXCEPTION '% phone records are on a contact at another firm; the key would refuse them: fix those rows first', n;
  END IF;
  SELECT count(*) INTO n FROM contact_phones cp JOIN contacts c ON c.id = cp.merged_from_contact_id
   WHERE cp.organization_id <> c.organization_id;
  IF n > 0 THEN
    RAISE EXCEPTION '% phone records say they were merged from a contact at another firm: fix those rows first', n;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. What the composite keys reference
-- -----------------------------------------------------------------------------
CREATE UNIQUE INDEX contacts_id_organization_uq ON contacts (id, organization_id);
COMMENT ON INDEX contacts_id_organization_uq IS
  'For composite foreign keys that tie a row to a contact AT THE ROW''S FIRM: '
  '(x_contact_id, organization_id) REFERENCES contacts (id, organization_id). '
  'Unique because id is (20261123T1810).';

-- -----------------------------------------------------------------------------
-- 3. The keys, replaced in one statement
-- -----------------------------------------------------------------------------
ALTER TABLE contact_phones
  DROP CONSTRAINT contact_phones_contact_id_fkey,
  ADD CONSTRAINT contact_phones_contact_id_fkey
    FOREIGN KEY (contact_id, organization_id) REFERENCES contacts (id, organization_id)
    ON UPDATE NO ACTION ON DELETE CASCADE,
  DROP CONSTRAINT contact_phones_merged_from_contact_id_fkey,
  ADD CONSTRAINT contact_phones_merged_from_contact_id_fkey
    FOREIGN KEY (merged_from_contact_id, organization_id) REFERENCES contacts (id, organization_id)
    ON UPDATE NO ACTION ON DELETE SET NULL (merged_from_contact_id);

COMMENT ON CONSTRAINT contact_phones_contact_id_fkey ON contact_phones IS
  'A phone record''s contact is at the phone record''s firm. Composite, so no '
  'role (postgres included) can attach a number to another firm''s contact. '
  'ON DELETE CASCADE as before; ON UPDATE NO ACTION, so a contact can''t move '
  'firm with numbers on it (20261123T1810).';
COMMENT ON CONSTRAINT contact_phones_merged_from_contact_id_fkey ON contact_phones IS
  'The contact a merge moved this number from, at the same firm. ON DELETE '
  'SET NULL (merged_from_contact_id) clears only the pointer: a plain SET NULL '
  'on a composite key would null organization_id too, and fail '
  '(20261123T1810).';

-- -----------------------------------------------------------------------------
-- 4. Record it
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261123T1810_contact_phones_same_firm.sql',
    NULL,
    'contact_phones -> contacts: both keys composite on organization_id, so a '
    'phone record''s contact is at its firm for every role. ON DELETE carried '
    'over (CASCADE; SET NULL on the pointer column only). First batch of the '
    'same-firm keys.');
END $rec$;

COMMIT;

-- =============================================================================
-- Verification — run AFTER the file, as its own statement. One block,
-- everything rolled back by the closing RAISE. AS postgres: a foreign key
-- holds for every role, and postgres, which bypasses row-level security, is
-- where the hole was.
--
-- DO $$
-- DECLARE
--   r text := ''; res text; v_a uuid; v_b uuid;
--   c_a1 uuid; c_a2 uuid; c_a3 uuid; c_b uuid; p_keep uuid; u_dee uuid;
-- BEGIN
--   PERFORM set_config('app.is_internal', 'on', true);
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ verify same firm A', 'funeral_home') RETURNING id INTO v_a;
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ verify same firm B', 'funeral_home') RETURNING id INTO v_b;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_a, 'A one') RETURNING id INTO c_a1;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_a, 'A two') RETURNING id INTO c_a2;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_a, 'A three') RETURNING id INTO c_a3;
--   INSERT INTO contacts (organization_id, full_name) VALUES (v_b, 'B one') RETURNING id INTO c_b;
--   INSERT INTO users (email, full_name, is_internal) VALUES ('zzz-same-firm@example.invalid', 'ZZZ Dee', true) RETURNING id INTO u_dee;
--
--   -- ---- 1. a phone record on another firm's contact -----------------------
--   BEGIN INSERT INTO contact_phones (organization_id, contact_id, e164) VALUES (v_a, c_b, '+15135559111'); res := 'ALLOWED';
--   EXCEPTION WHEN foreign_key_violation THEN res := '23503 ' || SQLERRM; END;
--   r := r || '1. A''s phone record on B''s contact: ' || res;
--   BEGIN INSERT INTO contact_phones (organization_id, contact_id, e164, is_primary) VALUES (v_a, c_a1, '+15135559101', true); res := 'allowed';
--   EXCEPTION WHEN OTHERS THEN res := SQLSTATE || ' ' || SQLERRM; END;
--   r := r || ' | on A''s own contact: ' || res || chr(10)
--          || '   (expect 23503 naming contact_phones_contact_id_fkey | allowed)' || chr(10);
--
--   -- ---- 2. merged from another firm's contact ------------------------------
--   BEGIN INSERT INTO contact_phones (organization_id, contact_id, e164, merged_from_contact_id) VALUES (v_a, c_a1, '+15135559112', c_b); res := 'ALLOWED';
--   EXCEPTION WHEN foreign_key_violation THEN res := '23503 ' || SQLERRM; END;
--   r := r || '2. merged from B''s contact: ' || res;
--   BEGIN INSERT INTO contact_phones (organization_id, contact_id, e164, merged_from_contact_id) VALUES (v_a, c_a1, '+15135559102', c_a3) RETURNING id INTO p_keep; res := 'allowed';
--   EXCEPTION WHEN OTHERS THEN res := SQLSTATE || ' ' || SQLERRM; END;
--   r := r || ' | from A''s own: ' || res;
--   BEGIN INSERT INTO contact_phones (organization_id, contact_id, e164) VALUES (v_a, c_a1, '+15135559103'); res := 'allowed';
--   EXCEPTION WHEN OTHERS THEN res := SQLSTATE || ' ' || SQLERRM; END;
--   r := r || ' | from nobody: ' || res || chr(10)
--          || '   (expect 23503 naming contact_phones_merged_from_contact_id_fkey | allowed | allowed)' || chr(10);
--
--   -- ---- 3. moving firm is refused, not cascaded -----------------------------
--   BEGIN UPDATE contact_phones SET organization_id = v_b WHERE id = p_keep; res := 'ALLOWED';
--   EXCEPTION WHEN foreign_key_violation THEN res := '23503'; END;
--   r := r || '3. a phone record moved to B under A''s contact: ' || res;
--   BEGIN UPDATE contacts SET organization_id = v_b WHERE id = c_a1; res := 'ALLOWED';
--   EXCEPTION WHEN foreign_key_violation THEN res := '23503 ' || SQLERRM; END;
--   r := r || ' | A''s contact moved to B with numbers on it: ' || res
--          || ' | its numbers still at A: ' || COALESCE((SELECT bool_and(organization_id = v_a) FROM contact_phones WHERE contact_id = c_a1)::text, 'none')
--          || chr(10) || '   (expect 23503 | 23503 naming contact_phones_contact_id_fkey, not a cascade | true)' || chr(10);
--
--   -- ---- 4. ON DELETE, carried over -----------------------------------------
--   -- c_a3 is the merged_from of p_keep (on c_a1): deleting c_a3 clears only
--   -- the pointer. Deleting c_a1 takes its phone records with it.
--   BEGIN DELETE FROM contacts WHERE id = c_a3; res := 'deleted';
--   EXCEPTION WHEN OTHERS THEN res := SQLSTATE || ' ' || SQLERRM; END;
--   r := r || '4. the contact a number was merged from, deleted: ' || res
--          || '; the number''s merged_from ' || COALESCE((SELECT merged_from_contact_id::text FROM contact_phones WHERE id = p_keep), 'null')
--          || ', its firm still A ' || COALESCE(((SELECT organization_id FROM contact_phones WHERE id = p_keep) = v_a)::text, 'no such row');
--   BEGIN DELETE FROM contacts WHERE id = c_a1; res := 'deleted';
--   EXCEPTION WHEN OTHERS THEN res := SQLSTATE || ' ' || SQLERRM; END;
--   r := r || ' | a contact with numbers, deleted: ' || res
--          || '; its numbers left: ' || (SELECT count(*) FROM contact_phones WHERE organization_id = v_a)
--          || chr(10) || '   (expect deleted; null, true | deleted; 0: SET NULL on the pointer only, CASCADE as before)' || chr(10);
--
--   -- ---- 5. the catalogue: one key per relationship, exactly as intended -------
--   r := r || '5. contact_phones -> contacts keys: '
--          || COALESCE((SELECT string_agg(conname || ' (' || array_to_string(ARRAY(SELECT attname FROM unnest(conkey) k JOIN pg_attribute a
--                                   ON a.attrelid = conrelid AND a.attnum = k ORDER BY array_position(conkey, k)), ', ')
--                    || ') delete ' || confdeltype::text || COALESCE(' set ' || NULLIF(array_to_string(ARRAY(SELECT attname FROM unnest(confdelsetcols) k
--                                   JOIN pg_attribute a ON a.attrelid = conrelid AND a.attnum = k), ', '), ''), '')
--                    || ' update ' || confupdtype::text, ' | ' ORDER BY conname)
--               FROM pg_constraint WHERE conrelid = 'contact_phones'::regclass AND confrelid = 'contacts'::regclass AND contype = 'f'), 'none')
--          || chr(10) || '   (expect exactly two: contact_phones_contact_id_fkey (contact_id, organization_id) delete c update a | '
--          || 'contact_phones_merged_from_contact_id_fkey (merged_from_contact_id, organization_id) delete n set '
--          || 'merged_from_contact_id update a)' || chr(10);
--
--   -- ---- 6. the import still writes through it ------------------------------
--   -- the import first, then the check: one statement can't see what a
--   -- function it calls wrote
--   res := COALESCE(contact_import_apply(v_a, u_dee, jsonb_build_array(jsonb_build_object('full_name', 'Imported', 'phones',
--            jsonb_build_array(jsonb_build_object('number', '+15135559104'))))) ->> 'created', 'nothing');
--   r := r || '6. Dead Ringers'' import into A, one new contact with a number: ' || res
--          || ' created, its number at A: '
--          || EXISTS (SELECT 1 FROM contact_phones cp JOIN contacts c ON c.id = cp.contact_id
--                      WHERE cp.e164 = '+15135559104' AND cp.organization_id = v_a AND c.organization_id = v_a)
--          || '   (expect 1 created, true)' || chr(10);
--
--   PERFORM set_config('app.is_internal', 'off', true);
--   RAISE EXCEPTION 'VERIFY 20261123T1810_contact_phones_same_firm (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
