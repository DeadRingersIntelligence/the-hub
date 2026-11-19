-- =============================================================================
-- 20261119T1800_case_need_type_can_change.sql
-- The Hub — a case's need type can change after it is created.
--
-- WHY. Mandie, 19 Nov: a pre-need case becomes at-need when the person dies,
-- and a case filed under the wrong type has to be correctable. Until now the
-- need type was set once, by create_case_for_call(), and nothing could
-- change it.
--
-- WHAT HAS TO MOVE WITH IT. create_case_for_call() (057/058) refuses a case
-- whose need type does not match its decedent's status:
--
--   pre_need  <->  pre_need_subject      (living; no date of death)
--   imminent  <->  imminent              (living; no date of death)
--   at_need   <->  at_need or deceased   (a date of death allowed)
--
-- So changing the need type changes the decedent's status in the same
-- statement, or the pairing creation guarantees would be broken by the first
-- edit. Pre-need to at-need is the person dying: the decedent becomes
-- at_need, with a date of death if one is given. At-need back to a living
-- type is a correction, and the date of death has to go — decedents_dod_ck
-- refuses a living person with one — so the old date is kept in the history
-- row rather than lost.
--
-- WHICH DECEDENT. A case can carry several: a couple buying two spaces, an
-- accident producing an at-need and a pre-need in one conversation (005).
-- The need type is about one of them — when one spouse dies, the other is
-- still pre-need. So the change names the decedent it is about; with exactly
-- one decedent on the case it is that one, and with several the caller must
-- say which, or it is refused. Nobody else on the case is touched.
--
-- A decedent's status is a fact about the person, not the case: if the same
-- person is on another case, that case sees them as at-need too. That is
-- correct — they died — and the history row on the decedent records it.
--
-- THE REVERSE IS GUARDED (review, 19 Nov). Making a person living again — a
-- correction — would leave any OTHER case they are on pairing an at-need case
-- with a living person: the pairing create_case_for_call refuses, on a case
-- nobody touched, with no history row to explain it. One person on two cases
-- is a state 20261106T1000's merges now produce on purpose. So before making
-- someone living, this refuses if another case links them with a need type
-- that does not match their new status, and names it: "Ellis is at-need on
-- another case; change that one first." The check covers the two living
-- types against each other too (imminent there, pre-need here), which breaks
-- the same pairing. Forward — the person died — is not refused.
--
-- THIS CAN CHANGE A RECORDED DATE OF DEATH. On a case already at-need, a
-- different p_date_of_death replaces the one recorded: the correction path.
-- The history row says so in words, with the old date and the new.
--
-- NOT TOUCHED: revenue. case_revenue_date() reads status, served_on and the
-- booked date, never need_type, so this moves no money and needs no reason.
-- Reports that group by need type will see the case under its new type,
-- which is the point.
--
-- No manager, no reason: correcting a case's type is ordinary work, and the
-- history row says who did it and what it was before.
--
-- REVIEWED 19 Nov (planning session) on commit ba33402. Changed in answer:
--   * making a person living is refused when another case they are on has a
--     need type that would no longer match them, naming it (verification 6);
--   * a date of death changed on its own gets its own history sentence,
--     instead of "changed Ellis from at-need to at-need" (verification 7);
--   * the header and the function comment now say this can change a recorded
--     date of death.
-- Left as it is, on the reviewer's word: the precondition matches a literal
-- substring of create_case_for_call's source, double space included, so a
-- reformat of that function will trip it one day. It fails safe — it refuses
-- and says compare.
--
-- Safe to run twice? No: the precondition refuses if the function exists,
-- and says so.
--
-- Requires, by what it actually uses:
--   005            decedents, decedents_dod_ck, case_decedents
--   016            record_change(), history_entity 'case' and 'decedent'
--   050            hand_link_actor()
--   20261103T1200  record_migration()
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 0. Precondition
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regprocedure('set_case_need_type(uuid,case_need_type,uuid,date)') IS NOT NULL THEN
    RAISE EXCEPTION 'set_case_need_type already exists — 20261119T1800 has run here'
      USING HINT = 'This file is not safe to run twice. Nothing has been changed.';
  END IF;
  -- The pairing below restates create_case_for_call's. If that function no
  -- longer carries it, the two have drifted and this file would install a
  -- second, different rule.
  IF position('p_need_type = ''pre_need''  AND v_status <> ''pre_need_subject'''
              IN (SELECT prosrc FROM pg_proc
                   WHERE oid = to_regprocedure('create_case_for_call(uuid,case_need_type,decedent_status,text,text,date,uuid,text,uuid[])'))) = 0 THEN
    RAISE EXCEPTION 'create_case_for_call no longer pairs pre_need with pre_need_subject as this file expects; stop and compare';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 1. The change
-- -----------------------------------------------------------------------------
CREATE FUNCTION set_case_need_type(
  p_case uuid,
  p_need_type case_need_type,
  -- Which person on the case this is about. Optional when the case has
  -- exactly one; required when it has several.
  p_decedent uuid DEFAULT NULL,
  -- Only when the change makes the person at-need: when they died, if known.
  p_date_of_death date DEFAULT NULL)
RETURNS cases LANGUAGE plpgsql AS $$
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
    v_new_status := CASE p_need_type
                      WHEN 'pre_need' THEN 'pre_need_subject'
                      WHEN 'imminent' THEN 'imminent'
                      -- deceased already satisfies at_need; leave it.
                      ELSE CASE WHEN v_status IN ('at_need', 'deceased') THEN v_status
                                ELSE 'at_need' END
                    END::decedent_status;
    v_new_dod := CASE WHEN p_need_type = 'at_need' THEN COALESCE(p_date_of_death, v_dod) END;

    -- Making the person living must not break another case they are on.
    IF v_new_status IN ('pre_need_subject', 'imminent') THEN
      SELECT c.need_type INTO v_other
        FROM case_decedents cd JOIN cases c ON c.id = cd.case_id
       WHERE cd.decedent_id = v_dec AND cd.case_id <> p_case
         AND c.need_type IS DISTINCT FROM
             (CASE v_new_status WHEN 'pre_need_subject' THEN 'pre_need' ELSE 'imminent' END)::case_need_type
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
END $$;

COMMENT ON FUNCTION set_case_need_type(uuid, case_need_type, uuid, date) IS
  'Changes a case''s need type after creation — the only writer of '
  'cases.need_type besides create_case_for_call(). Keeps the pairing that '
  'creation enforces by moving the named decedent''s status with it: '
  'pre_need <-> pre_need_subject, imminent <-> imminent, at_need <-> at_need '
  'or deceased. Becoming at-need may take a date of death; on a case already '
  'at-need, a different date REPLACES the recorded one (a correction). '
  'Becoming living clears the date, and the history row keeps it — and is '
  'refused if another case the person is on has a need type that would no '
  'longer match them. With several people on the case, p_decedent must say '
  'which; nobody else is touched. Moves no '
  'revenue, so needs no reason and no manager. History rows on the case and '
  'on the decedent.';

REVOKE ALL ON FUNCTION set_case_need_type(uuid, case_need_type, uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION set_case_need_type(uuid, case_need_type, uuid, date) TO authenticated;

-- -----------------------------------------------------------------------------
-- 2. And it is the body that was reviewed
--
-- In the same transaction, so a mismatch rolls everything back. The hash was
-- taken from a scratch database built from every migration on main, in
-- order, with this file applied.
-- -----------------------------------------------------------------------------
DO $$
DECLARE v text;
BEGIN
  SELECT md5(prosrc) INTO v FROM pg_proc
   WHERE oid = 'set_case_need_type(uuid,case_need_type,uuid,date)'::regprocedure;
  IF v IS DISTINCT FROM 'b0c9f824745b1efdd6257afe0a61e695' THEN
    RAISE EXCEPTION 'set_case_need_type installed as % — not the reviewed body. Nothing has been kept.', v;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 3. The ledger
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261119T1800_case_need_type_can_change.sql',
    NULL,
    'set_case_need_type(case, need_type, decedent, date_of_death): a case''s '
    'need type can change after creation, moving the named decedent''s status '
    'with it so the pairing create_case_for_call enforces still holds.');
END $rec$;

COMMIT;

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
-- Run after the migration; its output comes back as the error text.
--
-- Builds its own fixture at the first organization: one non-manager user,
-- entered through request.jwt.claims as the app does; a pre-need case with
-- one person; a couple's pre-need case; and someone on neither. Every
-- refusal is checked for its own message.
--
-- Lines 6 and 7 are the review's: one person on two cases, and a date of
-- death changed on its own.
--
-- RUN ON A SCRATCH REBUILD, 19 Nov — every migration on main, in order, with
-- this file, after the review's changes: every line matched. NOT YET RUN ON
-- STAGING.
--
-- DO $$
-- DECLARE
--   r text := ''; t date := current_date;
--   v_org uuid; v_user uuid; a_user uuid := gen_random_uuid();
--   d_one uuid; d_him uuid; d_her uuid; d_other uuid;
--   c_one uuid; c_couple uuid; n_notes int;
--   d_s1 uuid; d_s2 uuid; d_s3 uuid; d_late uuid;
--   c_s1a uuid; c_s1b uuid; c_s2a uuid; c_s2b uuid; c_s3a uuid; c_s3b uuid; c_late uuid;
-- BEGIN
--   PERFORM set_config('app.is_internal', 'on', true);
--   SELECT id INTO v_org FROM organizations ORDER BY created_at LIMIT 1;
--   IF v_org IS NULL THEN RAISE EXCEPTION 'no organizations — cannot build the fixture'; END IF;
--
--   INSERT INTO users (email, full_name, auth_user_id, active_organization_id)
--   VALUES ('zzz-need@example.invalid', 'ZZZ Director', a_user, v_org) RETURNING id INTO v_user;
--   INSERT INTO user_scopes (user_id, scope_type, view_profile, organization_id)
--   VALUES (v_user, 'organization', 'professional', v_org);
--
--   -- status and date_of_death as create_case_for_call would leave them.
--   INSERT INTO decedents (organization_id, first_name, last_name, status)
--   VALUES (v_org, 'ZZZ', 'Zone', 'pre_need_subject') RETURNING id INTO d_one;
--   INSERT INTO decedents (organization_id, first_name, last_name, status)
--   VALUES (v_org, 'ZZZ Him', 'Zcouple', 'pre_need_subject') RETURNING id INTO d_him;
--   INSERT INTO decedents (organization_id, first_name, last_name, status)
--   VALUES (v_org, 'ZZZ Her', 'Zcouple', 'pre_need_subject') RETURNING id INTO d_her;
--   INSERT INTO decedents (organization_id, first_name, last_name, status)
--   VALUES (v_org, 'ZZZ', 'Zelsewhere', 'pre_need_subject') RETURNING id INTO d_other;
--
--   INSERT INTO cases (organization_id, need_type, created_by) VALUES (v_org, 'pre_need', v_user) RETURNING id INTO c_one;
--   INSERT INTO case_decedents (case_id, decedent_id) VALUES (c_one, d_one);
--   INSERT INTO cases (organization_id, need_type, created_by) VALUES (v_org, 'pre_need', v_user) RETURNING id INTO c_couple;
--   INSERT INTO case_decedents (case_id, decedent_id) VALUES (c_couple, d_him), (c_couple, d_her);
--
--   -- One person on two cases — what 20261106T1000's merges now produce.
--   -- s1: at-need on both. s2: imminent on both. s3: pre-need on both.
--   INSERT INTO decedents (organization_id, first_name, last_name, status)
--   VALUES (v_org, 'ZZZ', 'Zatneed', 'at_need') RETURNING id INTO d_s1;
--   INSERT INTO decedents (organization_id, first_name, last_name, status)
--   VALUES (v_org, 'ZZZ', 'Zimminent', 'imminent') RETURNING id INTO d_s2;
--   INSERT INTO decedents (organization_id, first_name, last_name, status)
--   VALUES (v_org, 'ZZZ', 'Zplanning', 'pre_need_subject') RETURNING id INTO d_s3;
--   INSERT INTO cases (organization_id, need_type) VALUES (v_org, 'at_need')  RETURNING id INTO c_s1a;
--   INSERT INTO cases (organization_id, need_type) VALUES (v_org, 'at_need')  RETURNING id INTO c_s1b;
--   INSERT INTO cases (organization_id, need_type) VALUES (v_org, 'imminent') RETURNING id INTO c_s2a;
--   INSERT INTO cases (organization_id, need_type) VALUES (v_org, 'imminent') RETURNING id INTO c_s2b;
--   INSERT INTO cases (organization_id, need_type) VALUES (v_org, 'pre_need') RETURNING id INTO c_s3a;
--   INSERT INTO cases (organization_id, need_type) VALUES (v_org, 'pre_need') RETURNING id INTO c_s3b;
--   INSERT INTO case_decedents (case_id, decedent_id) VALUES
--     (c_s1a, d_s1), (c_s1b, d_s1), (c_s2a, d_s2), (c_s2b, d_s2), (c_s3a, d_s3), (c_s3b, d_s3);
--   -- An at-need case whose date of death is not yet known.
--   INSERT INTO decedents (organization_id, first_name, last_name, status)
--   VALUES (v_org, 'ZZZ', 'Zlate', 'at_need') RETURNING id INTO d_late;
--   INSERT INTO cases (organization_id, need_type) VALUES (v_org, 'at_need') RETURNING id INTO c_late;
--   INSERT INTO case_decedents (case_id, decedent_id) VALUES (c_late, d_late);
--
--   SELECT count(*) INTO n_notes FROM notifications;
--
--   -- ---- as a signed-in, non-manager user -------------------------------------
--   PERFORM set_config('app.is_internal', 'off', true);
--   PERFORM set_config('request.jwt.claims', json_build_object('sub', a_user::text)::text, true);
--   PERFORM set_config('role', 'authenticated', true);
--
--   r := r || 'cases visible to the user: '
--          || (SELECT count(*) FROM cases WHERE id IN (c_one, c_couple)) || '   (expect 2. If 0, the rest proves nothing)' || chr(10);
--
--   -- 1. The person dies: pre-need becomes at-need, with a date.
--   PERFORM set_case_need_type(c_one, 'at_need', NULL, t - 1);
--   r := r || '1. pre-need -> at-need with a date — case: ' || (SELECT need_type FROM cases WHERE id = c_one)
--          || ', person: ' || (SELECT status || ' ' || COALESCE(date_of_death::text, 'no date') FROM decedents WHERE id = d_one)
--          || '   (expect at_need, at_need ' || (t - 1) || ')' || chr(10);
--   r := r || '   history — case: ' || COALESCE((SELECT summary FROM change_history WHERE entity = 'case' AND entity_id = c_one
--                                               AND detail->>'field' = 'need_type' LIMIT 1), 'NONE (BAD)') || chr(10)
--          || '   person: ' || COALESCE((SELECT summary FROM change_history WHERE entity = 'decedent' AND entity_id = d_one LIMIT 1), 'NONE (BAD)') || chr(10);
--
--   -- 2. A correction back: the date has to go, and the history keeps it.
--   PERFORM set_case_need_type(c_one, 'pre_need');
--   r := r || '2. at-need -> pre-need (a correction) — person: '
--          || (SELECT status || ' ' || COALESCE(date_of_death::text, 'no date') FROM decedents WHERE id = d_one)
--          || '   (expect pre_need_subject no date)' || chr(10)
--          || '   history keeps the removed date: '
--          || COALESCE((SELECT summary || ' [' || (detail->>'date_of_death_from') || ']' FROM change_history
--                        WHERE entity = 'decedent' AND entity_id = d_one AND detail->>'date_of_death_to' IS NULL
--                          AND detail->>'date_of_death_from' IS NOT NULL LIMIT 1), 'NONE (BAD)') || chr(10);
--
--   -- 3. Refusals, each for its own reason.
--   BEGIN
--     PERFORM set_case_need_type(c_one, 'at_need', NULL, t + 1);
--     r := r || '3. a FUTURE date of death: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || '3. a future date of death refused: ' || SQLERRM
--            || CASE WHEN SQLERRM LIKE '%future%' THEN '   (right reason)' ELSE '   (WRONG REASON)' END || chr(10);
--   END;
--   BEGIN
--     PERFORM set_case_need_type(c_one, 'pre_need', NULL, t - 1);
--     r := r || '   a date of death on a PRE-NEED case: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || '   a date of death on a pre-need case refused: ' || SQLERRM
--            || CASE WHEN SQLERRM LIKE '%only goes with an at-need%' THEN '   (right reason)' ELSE '   (WRONG REASON)' END || chr(10);
--   END;
--   BEGIN
--     PERFORM set_case_need_type(c_couple, 'at_need');
--     r := r || '   a couple''s case with nobody named: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || '   a couple''s case with nobody named refused: ' || SQLERRM
--            || CASE WHEN SQLERRM LIKE '%2 people on it%' THEN '   (right reason)' ELSE '   (WRONG REASON)' END || chr(10);
--   END;
--   BEGIN
--     PERFORM set_case_need_type(c_couple, 'at_need', d_other);
--     r := r || '   naming someone NOT on the case: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || '   naming someone not on the case refused: ' || SQLERRM
--            || CASE WHEN SQLERRM LIKE '%isn''t on this case%' THEN '   (right reason)' ELSE '   (WRONG REASON)' END || chr(10);
--   END;
--
--   -- 4. One of a couple dies: only that person changes.
--   PERFORM set_case_need_type(c_couple, 'at_need', d_him, t - 2);
--   r := r || '4. one of a couple, named — case: ' || (SELECT need_type FROM cases WHERE id = c_couple)
--          || ', him: ' || (SELECT status FROM decedents WHERE id = d_him)
--          || ', her: ' || (SELECT status FROM decedents WHERE id = d_her)
--          || '   (expect at_need, at_need, pre_need_subject — she is untouched)' || chr(10);
--
--   -- 6. Review: making a person living must not break another case they are on.
--   BEGIN
--     PERFORM set_case_need_type(c_s1b, 'pre_need');
--     r := r || '6. at-need person, on another at-need case, made pre-need: ALLOWED (BAD — that case now pairs at-need with a living person)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || '6. at-need on another case, refused: ' || SQLERRM
--            || CASE WHEN SQLERRM LIKE '%Zatneed is at-need on another case; change that one first%' THEN '   (right reason)' ELSE '   (WRONG REASON)' END || chr(10);
--   END;
--   BEGIN
--     PERFORM set_case_need_type(c_s2b, 'pre_need');
--     r := r || '   imminent on another case, made pre-need: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || '   imminent on another case, refused: ' || SQLERRM
--            || CASE WHEN SQLERRM LIKE '%Zimminent is imminent on another case%' THEN '   (right reason)' ELSE '   (WRONG REASON)' END || chr(10);
--   END;
--   r := r || '   after both refusals — person statuses: '
--          || (SELECT status FROM decedents WHERE id = d_s1) || ', ' || (SELECT status FROM decedents WHERE id = d_s2)
--          || '   (expect at_need, imminent — nothing changed)' || chr(10);
--   BEGIN
--     PERFORM set_case_need_type(c_s3b, 'at_need', NULL, t - 1);
--     r := r || '   forward (a pre-need person on two cases dies): allowed — person now '
--            || (SELECT status FROM decedents WHERE id = d_s3) || '   (expect at_need; the other case sees it, by design)' || chr(10);
--   EXCEPTION WHEN others THEN
--     r := r || '   forward: REFUSED (BAD — the person died; every case should see it): ' || SQLERRM || chr(10);
--   END;
--
--   -- 7. Review: only the date of death changes — the history says so.
--   PERFORM set_case_need_type(c_late, 'at_need', NULL, t - 5);
--   PERFORM set_case_need_type(c_late, 'at_need', NULL, t - 3);
--   r := r || '7. date of death recorded, then corrected — person date: '
--          || (SELECT date_of_death FROM decedents WHERE id = d_late) || '   (expect ' || (t - 3) || ')' || chr(10)
--          || '   history: ' || COALESCE((SELECT string_agg(summary, ' | ' ORDER BY summary DESC) FROM change_history
--                                         WHERE entity = 'decedent' AND entity_id = d_late), 'NONE (BAD)') || chr(10)
--          || '   (expect "recorded ZZZ Zlate''s date of death as" and "changed ZZZ Zlate''s date of death from ... to ..."; never "from at-need to at-need")' || chr(10);
--
--   -- 5. Nothing about money.
--   PERFORM set_config('role', 'postgres', true);
--   r := r || '5. notifications written by all of the above: ' || ((SELECT count(*) FROM notifications) - n_notes)
--          || '   (expect 0 — need type moves no revenue)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261119T1800_case_need_type_can_change (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
