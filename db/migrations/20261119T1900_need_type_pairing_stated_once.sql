-- =============================================================================
-- 20261119T1900_need_type_pairing_stated_once.sql
-- The Hub — which decedent status goes with which need type, stated once.
--
-- WHY. Planning-session ruling on the-hub#48, 19 Nov: the pairing that
-- create_case_for_call() enforces was restated in set_case_need_type()
-- (20261119T1800), and 1800's precondition only checked the two agreed at
-- the moment it installed. After that nothing re-checks them, so a later
-- change to one copy breaks the invariant silently. "The guard protects the
-- moment, not the rule." Two callers is the cheapest this will ever be; a
-- fourth need type is the foreseeable moment a second copy bites.
--
-- There were THREE statements, not two. 1800's review added a guard that
-- maps a living status BACK to its need type (pre_need_subject -> pre_need,
-- imminent -> imminent) to find another case the change would break. That is
-- the same rule read the other way, so it goes too.
--
-- WHAT. One function, decedent_status_for_need_type(need_type, current
-- status): the status a decedent must have for a case of that need type,
-- keeping the current one where it already fits (deceased fits at-need).
--   create_case_for_call   VALIDATES: refuses when the answer differs from
--                          the status it has
--   set_case_need_type     DERIVES the person's new status from it, and its
--                          guard asks it whether another case still fits
--
-- A PURE REFACTOR. No behaviour changes, and the verification block proves
-- it rather than asserting it: it evaluates the old expressions and the new
-- function side by side for every need type against every status, including
-- null, for all three uses. create_case_for_call's check is written with
-- `<>` rather than IS DISTINCT FROM so a null passes exactly as the old
-- three comparisons did.
--
-- Both bodies are otherwise byte-for-byte the ones installed: each was taken
-- with pg_get_functiondef() from a scratch database built from every
-- migration on main, and only the lines above were changed.
--
-- REVIEWED 19 Nov (planning session) on commit 5432d83. Changed in answer:
-- an unknown non-null need type now raises instead of returning null, which
-- would have switched create_case_for_call's validation off for it. A null
-- still returns null. Verification 5 shows the refusal is in the installed
-- source; an actual fourth need type can't be added inside a verification
-- block (ADD VALUE can't be used in its own transaction), so the raise was
-- also exercised on the scratch rebuild with a real added value.
--
-- NOT SAFE TO RUN TWICE: the precondition refuses if the new function
-- exists, and says so.
--
-- Requires: 058 (create_case_for_call as replaced there), 20261119T1800
-- (set_case_need_type), 20261103T1200 (record_migration).
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 0. Precondition: the two bodies this replaces are the ones on main
-- -----------------------------------------------------------------------------
DO $$
DECLARE v text;
BEGIN
  IF to_regprocedure('decedent_status_for_need_type(case_need_type,decedent_status)') IS NOT NULL THEN
    RAISE EXCEPTION 'decedent_status_for_need_type already exists — 20261119T1900 has run here'
      USING HINT = 'This file is not safe to run twice. Nothing has been changed.';
  END IF;

  SELECT md5(prosrc) INTO v FROM pg_proc
   WHERE oid = to_regprocedure('create_case_for_call(uuid,case_need_type,decedent_status,text,text,date,uuid,text,uuid[])');
  IF v IS DISTINCT FROM 'aba6f6884788fdd7dd803caa861bdbd3' THEN
    RAISE EXCEPTION 'create_case_for_call is not 058''s body (found %); stop and compare', v;
  END IF;

  SELECT md5(prosrc) INTO v FROM pg_proc
   WHERE oid = to_regprocedure('set_case_need_type(uuid,case_need_type,uuid,date)');
  IF v IS DISTINCT FROM 'b0c9f824745b1efdd6257afe0a61e695' THEN
    RAISE EXCEPTION 'set_case_need_type is not 20261119T1800''s body (found %); stop and compare', v;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 1. The rule
-- -----------------------------------------------------------------------------
-- AN UNKNOWN NEED TYPE REFUSES (review, 19 Nov). Without the ELSE, a fourth
-- value added to case_need_type would return null here, create_case_for_call's
-- `<>` would be null, its IF would not fire, and every case of the new type
-- would be created with any status at all: the check would not fail, it would
-- stop existing — on the one path that used to refuse. So a non-null value
-- this function does not know raises, naming it. A NULL need type still
-- returns null, which keeps this a pure refactor: a null passed before.
-- plpgsql rather than sql only to be able to RAISE.
CREATE FUNCTION decedent_status_for_need_type(p_need_type case_need_type, p_current decedent_status)
RETURNS decedent_status LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF p_need_type IS NULL THEN
    RETURN NULL;
  END IF;
  CASE p_need_type
    WHEN 'pre_need' THEN RETURN 'pre_need_subject';
    WHEN 'imminent' THEN RETURN 'imminent';
    -- at-need: someone who has died. Deceased already fits; keep it.
    WHEN 'at_need'  THEN RETURN CASE WHEN p_current IN ('at_need', 'deceased') THEN p_current
                                     ELSE 'at_need' END;
    ELSE
      RAISE EXCEPTION 'decedent_status_for_need_type doesn''t know the need type %', p_need_type
        USING HINT = 'A new need type is added here, saying which decedent status goes with it. Until it is, cases of that type are refused rather than created unchecked.';
  END CASE;
END $$;

COMMENT ON FUNCTION decedent_status_for_need_type(case_need_type, decedent_status) IS
  'THE pairing of need type and decedent status, stated once: pre_need -> '
  'pre_need_subject, imminent -> imminent, at_need -> at_need or deceased '
  '(the current status is kept where it already fits). A status FITS a need '
  'type when this returns it unchanged. create_case_for_call validates '
  'against it; set_case_need_type derives a person''s new status from it and '
  'checks the person''s other cases with it. A new need type is added here '
  'and nowhere else — and if someone forgets, it REFUSES rather than passes: '
  'a non-null need type it does not handle raises, naming it, so cases of '
  'that type are refused instead of created unchecked. A null need type '
  'returns null, as the comparisons it replaced let a null through.';

REVOKE ALL ON FUNCTION decedent_status_for_need_type(case_need_type, decedent_status) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION decedent_status_for_need_type(case_need_type, decedent_status) TO authenticated;

-- -----------------------------------------------------------------------------
-- 2. create_case_for_call validates against it
--
-- 058's body with the three comparisons replaced by one call; nothing else.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_case_for_call(p_interaction uuid, p_need_type case_need_type, p_decedent_status decedent_status, p_decedent_last text DEFAULT NULL::text, p_decedent_first text DEFAULT NULL::text, p_date_of_death date DEFAULT NULL::date, p_decedent_id uuid DEFAULT NULL::uuid, p_role text DEFAULT NULL::text, p_also uuid[] DEFAULT '{}'::uuid[])
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
DECLARE
  a record;
  v_org uuid; v_loc uuid; v_contact uuid; v_case uuid; v_decedent uuid;
  v_status decedent_status; v_existing uuid; v_other uuid; v_joined uuid[] := '{}';
BEGIN
  IF current_user_id() IS NULL THEN
    RAISE EXCEPTION 'your sign-in isn''t linked to a Hub user, so a case can''t be created';
  END IF;
  SELECT * INTO a FROM hand_link_actor();

  SELECT organization_id, location_id, contact_id, case_id
    INTO v_org, v_loc, v_contact, v_existing
    FROM interactions WHERE id = p_interaction FOR UPDATE;

  IF v_org IS NULL THEN
    RAISE EXCEPTION 'that call couldn''t be found' USING ERRCODE = 'P0002';
  END IF;
  IF v_existing IS NOT NULL THEN
    RAISE EXCEPTION 'this call is already on a case — unlink it first, or link it to another';
  END IF;

  IF v_contact IS NULL THEN
    RAISE EXCEPTION 'save the caller as a contact first';
  END IF;

  IF p_decedent_id IS NOT NULL THEN
    SELECT COALESCE(d.merged_into, d.id) INTO v_decedent
      FROM decedents d WHERE d.id = p_decedent_id AND d.organization_id = v_org;
    IF v_decedent IS NULL THEN
      RAISE EXCEPTION 'choose a decedent at this firm';
    END IF;
    SELECT status INTO v_status FROM decedents WHERE id = v_decedent;
  ELSE
    IF NULLIF(btrim(COALESCE(p_decedent_last, '')), '') IS NULL THEN
      RAISE EXCEPTION 'the case needs the deceased person''s last name'
        USING HINT = 'Ask while the family is on the phone — a first name alone can''t be matched later.';
    END IF;

    IF p_decedent_status IN ('pre_need_subject', 'imminent') AND p_date_of_death IS NOT NULL THEN
      RAISE EXCEPTION 'a date of death can''t be recorded for someone living';
    END IF;

    INSERT INTO decedents (organization_id, first_name, last_name, status, date_of_death)
    VALUES (v_org,
            NULLIF(btrim(COALESCE(p_decedent_first, '')), ''),
            btrim(p_decedent_last),
            p_decedent_status,
            p_date_of_death)
    RETURNING id INTO v_decedent;
    v_status := p_decedent_status;
  END IF;

  -- The pairing, asked of the one statement of it (20261119T1900). `<>`,
  -- not IS DISTINCT FROM, so a null on either side passes exactly as the
  -- three comparisons this replaces did — this file changes no behaviour.
  IF decedent_status_for_need_type(p_need_type, v_status) <> v_status THEN
    RAISE EXCEPTION 'a % case doesn''t go with a decedent recorded as %', p_need_type, v_status;
  END IF;

  INSERT INTO cases (organization_id, location_id, need_type,
                     converting_interaction_id, opened_on, status)
  VALUES (v_org, v_loc, p_need_type, p_interaction, current_date, 'active')
  RETURNING id INTO v_case;

  INSERT INTO case_decedents (case_id, decedent_id)
  VALUES (v_case, v_decedent) ON CONFLICT DO NOTHING;

  INSERT INTO case_contacts (case_id, contact_id, role, is_primary)
  VALUES (v_case, v_contact, NULLIF(btrim(COALESCE(p_role, '')), ''), true)
  ON CONFLICT DO NOTHING;

  UPDATE interactions
     SET case_id = v_case, case_link_method = 'confirmed', updated_at = now()
   WHERE id = p_interaction;

  INSERT INTO interaction_decedents (interaction_id, decedent_id, link_method, linked_by)
  VALUES (p_interaction, v_decedent, 'confirmed', a.v_name)
  ON CONFLICT DO NOTHING;

  FOREACH v_other IN ARRAY COALESCE(p_also, '{}') LOOP
    CONTINUE WHEN v_other = p_interaction;
    UPDATE interactions
       SET case_id = v_case, case_link_method = 'confirmed', updated_at = now()
     WHERE id = v_other AND organization_id = v_org AND case_id IS NULL;
    IF FOUND THEN v_joined := v_joined || v_other; END IF;
  END LOOP;

  PERFORM propagate_case_links(v_case);

  UPDATE leads
     SET case_id = v_case, status = 'converted', updated_at = now()
   WHERE organization_id = v_org
     AND contact_id = v_contact
     AND status IN ('open', 'contacted');

  PERFORM record_change(
    v_org, 'case', v_case, 'created', 'user', a.v_name,
    format('%s created this case from a call', a.v_name), a.v_user,
    jsonb_build_object('converting_interaction_id', p_interaction,
                       'decedent_id', v_decedent, 'need_type', p_need_type));

  PERFORM record_change(
    v_org, 'interaction', p_interaction, 'linked', 'user', a.v_name,
    format('%s created a case from this call', a.v_name), a.v_user,
    jsonb_build_object('field', 'case_id', 'case_id', v_case, 'converting', true),
    'confirmed');

  FOREACH v_other IN ARRAY v_joined LOOP
    PERFORM record_change(
      v_org, 'interaction', v_other, 'linked', 'user', a.v_name,
      format('%s linked this call to a case', a.v_name), a.v_user,
      jsonb_build_object('field', 'case_id', 'case_id', v_case), 'confirmed');
  END LOOP;

  RETURN v_case;
END $function$;

-- -----------------------------------------------------------------------------
-- 3. set_case_need_type derives from it, and its guard asks it
--
-- 1800's body with the derivation and the reverse guard each replaced by one
-- call; nothing else. The guard asks whether the person's new status still
-- FITS each other case's need type — the same question create_case_for_call
-- asks, from the other side.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_case_need_type(p_case uuid, p_need_type case_need_type, p_decedent uuid DEFAULT NULL::uuid, p_date_of_death date DEFAULT NULL::date)
 RETURNS cases
 LANGUAGE plpgsql
AS $function$
DECLARE
  a record; r cases; v_org uuid; v_was case_need_type; n int;
  v_dec uuid; v_name text; v_status decedent_status; v_dod date;
  v_new_status decedent_status; v_new_dod date; v_other case_need_type;
BEGIN
  SELECT * INTO a FROM hand_link_actor();

  SELECT organization_id, need_type INTO v_org, v_was
    FROM cases WHERE id = p_case FOR UPDATE;
  IF v_org IS NULL THEN RAISE EXCEPTION 'no such case'; END IF;

  -- Which decedent.
  SELECT count(*) INTO n FROM case_decedents WHERE case_id = p_case;
  IF p_decedent IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM case_decedents WHERE case_id = p_case AND decedent_id = p_decedent) THEN
      RAISE EXCEPTION 'that person isn''t on this case';
    END IF;
    v_dec := p_decedent;
  ELSIF n = 1 THEN
    SELECT decedent_id INTO v_dec FROM case_decedents WHERE case_id = p_case;
  ELSIF n > 1 THEN
    RAISE EXCEPTION 'this case has % people on it, so say which one this change is about', n
      USING HINT = 'When one of a couple dies, the other stays pre-need: the change is about one person.';
  END IF;

  IF p_date_of_death IS NOT NULL AND p_need_type <> 'at_need' THEN
    RAISE EXCEPTION 'a date of death only goes with an at-need case'
      USING HINT = 'Pre-need and imminent cases are about someone living.';
  END IF;
  IF p_date_of_death > current_date THEN
    RAISE EXCEPTION 'a date of death can''t be in the future';
  END IF;

  IF v_dec IS NOT NULL THEN
    SELECT full_name, status, date_of_death INTO v_name, v_status, v_dod
      FROM decedents WHERE id = v_dec FOR UPDATE;

    -- The pairing create_case_for_call() enforces, applied the other way.
    v_new_status := decedent_status_for_need_type(p_need_type, v_status);
    v_new_dod := CASE WHEN p_need_type = 'at_need' THEN COALESCE(p_date_of_death, v_dod) END;

    -- Making the person living must not break another case they are on.
    IF v_new_status IN ('pre_need_subject', 'imminent') THEN
      SELECT c.need_type INTO v_other
        FROM case_decedents cd JOIN cases c ON c.id = cd.case_id
       WHERE cd.decedent_id = v_dec AND cd.case_id <> p_case
         AND decedent_status_for_need_type(c.need_type, v_new_status) IS DISTINCT FROM v_new_status
       ORDER BY c.need_type = 'at_need' DESC
       LIMIT 1;
      IF FOUND THEN
        RAISE EXCEPTION '% is % on another case; change that one first',
          COALESCE(v_name, 'This person'), replace(v_other::text, '_', '-')
          USING HINT = 'A person''s status is shared by every case they''re on. Changing this one would leave the other case describing someone who isn''t in the state it says.';
      END IF;
    END IF;

    IF v_new_status IS DISTINCT FROM v_status OR v_new_dod IS DISTINCT FROM v_dod THEN
      UPDATE decedents SET status = v_new_status, date_of_death = v_new_dod, updated_at = now()
       WHERE id = v_dec;
      PERFORM record_change(
        v_org, 'decedent', v_dec, 'updated', 'user', a.v_name,
        CASE WHEN v_new_status IN ('at_need', 'deceased') AND v_status NOT IN ('at_need', 'deceased')
               THEN format('%s recorded %s as having died%s', a.v_name, COALESCE(v_name, 'this person'),
                           COALESCE(' on ' || to_char(v_new_dod, 'FMMonth FMDD, YYYY'), ''))
             WHEN v_dod IS NOT NULL AND v_new_dod IS NULL
               THEN format('%s recorded %s as living (a date of death of %s was removed)', a.v_name,
                           COALESCE(v_name, 'this person'), to_char(v_dod, 'FMMonth FMDD, YYYY'))
             -- Same status, different date: the date of death was corrected.
             WHEN v_new_status = v_status AND v_dod IS NULL
               THEN format('%s recorded %s''s date of death as %s', a.v_name,
                           COALESCE(v_name, 'this person'), to_char(v_new_dod, 'FMMonth FMDD, YYYY'))
             WHEN v_new_status = v_status
               THEN format('%s changed %s''s date of death from %s to %s', a.v_name,
                           COALESCE(v_name, 'this person'),
                           to_char(v_dod, 'FMMonth FMDD, YYYY'), to_char(v_new_dod, 'FMMonth FMDD, YYYY'))
             ELSE format('%s changed %s from %s to %s', a.v_name, COALESCE(v_name, 'this person'),
                         replace(v_status::text, '_', '-'), replace(v_new_status::text, '_', '-')) END,
        a.v_user,
        jsonb_build_object('field', 'status', 'from', v_status, 'to', v_new_status,
                           'date_of_death_from', v_dod, 'date_of_death_to', v_new_dod,
                           'via_case', p_case));
    END IF;
  END IF;

  UPDATE cases SET need_type = p_need_type, updated_at = now()
   WHERE id = p_case
  RETURNING * INTO r;

  IF v_was IS DISTINCT FROM p_need_type THEN
    PERFORM record_change(
      v_org, 'case', p_case, 'updated', 'user', a.v_name,
      format('%s changed the case from %s to %s', a.v_name,
             replace(v_was::text, '_', '-'), replace(p_need_type::text, '_', '-')),
      a.v_user,
      jsonb_build_object('field', 'need_type', 'from', v_was, 'to', p_need_type,
                         'decedent_id', v_dec));
  END IF;

  RETURN r;
END $function$;

-- -----------------------------------------------------------------------------
-- 4. And they are the bodies that were reviewed
-- -----------------------------------------------------------------------------
DO $$
DECLARE bad text;
BEGIN
  SELECT string_agg(e.sig || ' is ' || COALESCE(md5(p.prosrc), 'MISSING'), '; ')
    INTO bad
    FROM (VALUES
    ('create_case_for_call(uuid,case_need_type,decedent_status,text,text,date,uuid,text,uuid[])', 'a7fe724b27a640ae91d0f58a15c5f82d'),
    ('decedent_status_for_need_type(case_need_type,decedent_status)', 'daeec97ba1ae57dfc857220bdfd894ef'),
    ('set_case_need_type(uuid,case_need_type,uuid,date)', '4497b842eed7c61e49ba15c482b3a856')
         ) AS e(sig, want)
    LEFT JOIN pg_proc p ON p.oid = to_regprocedure(e.sig)
   WHERE md5(p.prosrc) IS DISTINCT FROM e.want;
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'not the reviewed bodies: %. Nothing has been kept.', bad;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 5. The ledger
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261119T1900_need_type_pairing_stated_once.sql',
    NULL,
    'decedent_status_for_need_type(need_type, status): the need-type/decedent '
    'pairing stated once. create_case_for_call validates against it; '
    'set_case_need_type derives from it and its other-case guard asks it. A '
    'pure refactor: the verification block proves the old and new agree for '
    'every input.');
END $rec$;

COMMIT;

-- =============================================================================
-- Verification — one block, needing no fixture: it changes nothing, and ends
-- in a RAISE so the editor shows its output.
--
-- 1-3 evaluate the expressions this file removed beside the function that
-- replaced them, for every input each use can see, and report whether they
-- ever disagree. 4 reads the installed source to show the copies are gone.
-- 5 is the review's: the function refuses a need type it does not handle.
--
-- RUN ON A SCRATCH REBUILD, 19 Nov — every migration on main, in order, with
-- this file: every line matched. 20261119T1800's own verification block was
-- then re-run against the rewritten set_case_need_type, and every line of
-- it matched too. After the review's change, all of that was run again and
-- matched, and on the scratch database only a real fourth value was added to
-- case_need_type: the function refused it, naming it, both called directly
-- and through create_case_for_call's `<>` check. NOT YET RUN ON STAGING.
--
-- DO $$
-- DECLARE
--   r text := ''; n_val int := 0; n_der int := 0; n_grd int := 0; bad text := '';
--   needs case_need_type[] := ARRAY['pre_need', 'imminent', 'at_need', NULL]::case_need_type[];
--   stats decedent_status[] := ARRAY['pre_need_subject', 'imminent', 'at_need', 'deceased', NULL]::decedent_status[];
--   nd case_need_type; st decedent_status; o boolean; w boolean; od decedent_status; wd decedent_status;
-- BEGIN
--   -- 1. create_case_for_call's validation: the three comparisons it had,
--   --    against the call it has now, for every need type and status. Both
--   --    are read as "refuses": an IF on a null condition does not raise.
--   FOREACH nd IN ARRAY needs LOOP
--     FOREACH st IN ARRAY stats LOOP
--       o := COALESCE((nd = 'pre_need'  AND st <> 'pre_need_subject')
--                  OR (nd = 'imminent'  AND st <> 'imminent')
--                  OR (nd = 'at_need'   AND st NOT IN ('at_need', 'deceased')), false);
--       w := COALESCE(decedent_status_for_need_type(nd, st) <> st, false);
--       n_val := n_val + 1;
--       IF o IS DISTINCT FROM w THEN bad := bad || format(' validate(%s,%s): old %s new %s;', nd, st, o, w); END IF;
--     END LOOP;
--   END LOOP;
--   r := r || '1. create_case_for_call refuses the same pairs as before: '
--          || (bad = '') || ' over ' || n_val || ' combinations'
--          || '   (expect true over 20 — every need type, null included, against every status, null included)' || chr(10);
--
--   -- 2. set_case_need_type's derivation, for every non-null need type. (A
--   --    null need type fails on cases.need_type NOT NULL either way; the old
--   --    CASE sent it to the at-need branch first, the new returns null and
--   --    fails one statement sooner. Same outcome: refused, nothing kept.)
--   bad := '';
--   FOREACH nd IN ARRAY needs[1:3] LOOP
--     FOREACH st IN ARRAY stats LOOP
--       od := CASE nd WHEN 'pre_need' THEN 'pre_need_subject' WHEN 'imminent' THEN 'imminent'
--                     ELSE CASE WHEN st IN ('at_need', 'deceased') THEN st ELSE 'at_need' END
--             END::decedent_status;
--       wd := decedent_status_for_need_type(nd, st);
--       n_der := n_der + 1;
--       IF od IS DISTINCT FROM wd THEN bad := bad || format(' derive(%s,%s): old %s new %s;', nd, st, od, wd); END IF;
--     END LOOP;
--   END LOOP;
--   r := r || '2. set_case_need_type derives the same status as before: '
--          || (bad = '') || ' over ' || n_der || ' combinations   (expect true over 15)' || chr(10);
--
--   -- 3. The other-case guard: for each living status a person can be made,
--   --    against each need type another case can have (cases.need_type is
--   --    NOT NULL), does the other case still fit?
--   bad := '';
--   FOREACH st IN ARRAY ARRAY['pre_need_subject', 'imminent']::decedent_status[] LOOP
--     FOREACH nd IN ARRAY needs[1:3] LOOP
--       o := nd IS DISTINCT FROM (CASE st WHEN 'pre_need_subject' THEN 'pre_need' ELSE 'imminent' END)::case_need_type;
--       w := decedent_status_for_need_type(nd, st) IS DISTINCT FROM st;
--       n_grd := n_grd + 1;
--       IF o IS DISTINCT FROM w THEN bad := bad || format(' guard(%s on %s): old %s new %s;', st, nd, o, w); END IF;
--     END LOOP;
--   END LOOP;
--   r := r || '3. the other-case guard refuses the same cases as before: '
--          || (bad = '') || ' over ' || n_grd || ' combinations   (expect true over 6)' || chr(10);
--
--   -- 4. The copies are gone from the bodies, and the call is there. Read from
--   --    the installed source (db/README.md, "test them against the source").
--   r := r || '4. create_case_for_call still states the pairing itself: '
--          || (position('p_need_type = ''pre_need''' IN (SELECT prosrc FROM pg_proc WHERE proname = 'create_case_for_call')) > 0)
--          || ', calls the rule: '
--          || (position('decedent_status_for_need_type(p_need_type, v_status) <> v_status' IN (SELECT prosrc FROM pg_proc WHERE proname = 'create_case_for_call')) > 0)
--          || '   (expect false, true)' || chr(10);
--   r := r || '   set_case_need_type still states it: '
--          || (position('WHEN ''pre_need'' THEN ''pre_need_subject''' IN (SELECT prosrc FROM pg_proc WHERE proname = 'set_case_need_type')) > 0
--              OR position('THEN ''pre_need'' ELSE ''imminent''' IN (SELECT prosrc FROM pg_proc WHERE proname = 'set_case_need_type')) > 0)
--          || ', calls the rule twice: '
--          || ((length((SELECT prosrc FROM pg_proc WHERE proname = 'set_case_need_type'))
--               - length(replace((SELECT prosrc FROM pg_proc WHERE proname = 'set_case_need_type'), 'decedent_status_for_need_type(', '')))
--              / length('decedent_status_for_need_type(') = 2)
--          || '   (expect false, true)' || chr(10);
--   r := r || '   callable by authenticated (both callers are invoker): '
--          || has_function_privilege('authenticated', 'decedent_status_for_need_type(case_need_type,decedent_status)', 'EXECUTE')
--          || ', by anon: '
--          || has_function_privilege('anon', 'decedent_status_for_need_type(case_need_type,decedent_status)', 'EXECUTE')
--          || '   (expect true, false)' || chr(10);
--
--   -- 5. Review: a need type the function doesn't know must refuse, not pass.
--   --    No fourth value exists to call it with, so this reads the installed
--   --    source; every value that does exist must get an answer. The search
--   --    text has no apostrophe: in the stored source the message's "doesn't"
--   --    is written doubled, so searching for it as typed never matches.
--   r := r || '5. raises on a need type it doesn''t handle: '
--          || (position('know the need type' IN (SELECT prosrc FROM pg_proc WHERE proname = 'decedent_status_for_need_type')) > 0)
--          || ', every existing need type answered (none null): '
--          || (NOT EXISTS (SELECT 1 FROM unnest(enum_range(NULL::case_need_type)) e
--                           WHERE decedent_status_for_need_type(e, NULL) IS NULL))
--          || ', null need type still null: ' || (decedent_status_for_need_type(NULL, 'at_need') IS NULL)
--          || '   (expect true, true, true)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261119T1900_need_type_pairing_stated_once (nothing to roll back) %', chr(10) || r;
-- END $$;
-- =============================================================================
