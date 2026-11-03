-- =============================================================================
-- 20261103T2100_fourteen_on_staging.sql
-- The Hub — staging gets the migration it never ran.
--
-- APPLIED ON STAGING ONLY, 2026-11-03, block md5
-- 9cf13d0114d86ba0bfedd649faa3f643. Production was not run and must not be:
-- section 1 refuses there by design, because 014's objects already exist.
-- Lines 146-296 were checked byte-for-byte against main's 014 after the merge.
--
-- PARITY AFTERWARDS. The fn, typ, con and col fingerprints are now identical
-- on the two databases. acl differs by exactly the two entries this file
-- predicted and by nothing else: PUBLIC EXECUTE on section_scores and
-- behavior_detail, which production carries and staging never received.
-- Excluding those two it is ab3fad62 on both. The PUBLIC sweep closes it.
--
-- ONE ASYMMETRY THIS FILE CREATES, worth knowing before a later check trips on
-- it: the two ledgers are no longer the same length. Staging has 21 rows and
-- production 20, because this file can only ever run on one of them. Compare
-- ledgers by filename, not by count. Everything before this one still agrees,
-- fingerprint b3801105 on both.
--
-- WHAT IS MISSING. 014_measurement_and_menu_scoring.sql ran on production on
-- or about 7 October and has never run on staging. Staging therefore has no
-- measurement_type and no section_scoring type, no behaviors.measurement_type,
-- no rubric_sections.scoring_mode, no rubric_behaviors.credit_value, no
-- rubric_behaviors_credit_ck, and neither behavior_detail nor section_scores.
-- It went unnoticed for a month, because nothing records what has run where
-- and because noticing required somebody to go looking for a column they had
-- no reason to think was absent. The structural diff on 3 November found it
-- while looking for something else.
--
-- WHY THE BODY BELOW IS NOT MINE. Section 2 is
-- db/migrations/014_measurement_and_menu_scoring.sql AS IT STANDS ON MAIN —
-- the 7 October version from commit 3cb3758, sha256
-- ddd39e1301afdd1893af297684fbb7a64c26e9ea6f565e46d9a994aaf6fca348, 9,037
-- bytes — cut byte-for-byte from BEGIN to COMMIT and not edited in any way. That is deliberate. Both functions it creates are LANGUAGE sql, so
-- their bodies are stored as written, and a single character of difference
-- would leave the two databases disagreeing forever in a way the structural
-- diff reports as drift. Retyping it would have traded a missing migration
-- for a subtler one.
--
-- The verification proves the cut worked rather than assuming it: it asserts
-- both bodies against the md5(prosrc) values read from production today,
-- behavior_detail 6bb3272e84356abd7fb266dd7d9aa56d and section_scores
-- dfec02e224e7d63ccf07eb620de7f97b.
--
-- NOT main's FIRST 014. The original of 30 September (775703e, e4aca71b…)
-- lacks the ::measurement_type cast on the backfill's CASE and cannot have
-- been what ran; commit 3cb3758 of 7 October fixed it. The two versions differ
-- only in those four lines, and the functions are identical in both. Recorded
-- because an earlier draft of this file was going to be cut from the wrong one.
--
-- IT RUNS OUT OF ORDER, and that is safe for a reason rather than by luck.
-- Staging is at 058; 014 was written for a 013-era database. Nothing in it
-- depends on a later file being absent, and the two places where arriving late
-- could have hurt are both handled in the text below:
--
--   BOTH NEW NOT NULL COLUMNS CARRY DEFAULTS, so the rows already in behaviors
--   and rubric_sections are filled as the column is added rather than
--   rejected. credit_value is nullable and its CHECK opens with
--   "credit_value IS NULL OR", so existing rubric_behaviors rows pass it.
--
--   THE BACKFILL READS DATA, not a schema. It classifies each behaviour from
--   the answer options already seeded in behavior_answers. The rubric content
--   was compared across the two databases on 3 November — 128 behaviors and
--   240 answers, identical as a sorted multiset once ids and timestamps were
--   excluded — so it should produce the same classification here as it did on
--   production. The verification prints the counts per value so that can be
--   checked rather than believed.
--
-- THE GRANTS ARE MINE AND THEY WILL NOT MATCH PRODUCTION. Section 3 adds the
-- explicit pair this schema requires of every new function. 014 itself grants
-- nothing, so on production in October the two functions inherited the default
-- of the day, which was PUBLIC EXECUTE — which is why they are two of the 68
-- functions the pending PUBLIC sweep is for. Staging's default since
-- 20261103T1600 and 20261103T1800 grants no PUBLIC at all.
--
-- So these two arrive as {postgres=X, authenticated=X} and production's read
-- {=X/postgres, postgres=X/postgres, authenticated=X/postgres}. That is a
-- PLANNED, NAMED, TWO-ENTRY DIFFERENCE in the README's acl comparison, and it
-- is the right way round: staging arrives in the shape production is moving
-- to, and the difference disappears when the PUBLIC sweep runs. Granting
-- PUBLIC here to match, three days before sweeping it off, would have been
-- tidier and worse.
--
-- NOT SAFE TO RUN TWICE, and this is the one house rule this file breaks on
-- purpose. CREATE TYPE and ADD COLUMN are not idempotent, and making them so
-- would mean editing the body — which is the one thing this file exists not to
-- do. Section 1 therefore refuses a second run cleanly, with a message saying
-- which it is, rather than failing halfway through on a duplicate type.
--
-- Requires: 001 to 013, and 20261103T1200 (record_migration). It expects
--           staging; on production every object already exists and section 1
--           refuses.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. None of it is here yet
--
-- Eight objects, counted. All absent is the only state this file can act on;
-- all present means it has run, or this is production; anything between means
-- a partial apply that somebody has to look at before a line of it is retried.
--
-- The count is deliberately of objects rather than of a ledger row. Staging
-- has no row for 014 and never will — the ledger starts on 3 November and
-- production's 014 predates it by a month — so the catalogue is the only
-- honest source for this question, which is the same reason the gap existed.
-- -----------------------------------------------------------------------------
DO $pre$
DECLARE v_n int; v_rows int;
BEGIN
  SELECT count(*) INTO v_n FROM (
    SELECT 1 WHERE to_regtype('public.measurement_type') IS NOT NULL
    UNION ALL SELECT 1 WHERE to_regtype('public.section_scoring') IS NOT NULL
    UNION ALL SELECT 1 FROM pg_attribute
               WHERE attrelid = 'public.behaviors'::regclass
                 AND attname = 'measurement_type' AND NOT attisdropped
    UNION ALL SELECT 1 FROM pg_attribute
               WHERE attrelid = 'public.rubric_sections'::regclass
                 AND attname = 'scoring_mode' AND NOT attisdropped
    UNION ALL SELECT 1 FROM pg_attribute
               WHERE attrelid = 'public.rubric_behaviors'::regclass
                 AND attname = 'credit_value' AND NOT attisdropped
    UNION ALL SELECT 1 FROM pg_constraint
               WHERE conrelid = 'public.rubric_behaviors'::regclass
                 AND conname = 'rubric_behaviors_credit_ck'
    UNION ALL SELECT 1 WHERE to_regprocedure('public.section_scores(uuid,date,date)') IS NOT NULL
    UNION ALL SELECT 1 WHERE to_regprocedure('public.behavior_detail(uuid,date,date)') IS NOT NULL
  ) x;

  IF v_n = 8 THEN
    RAISE EXCEPTION
      '014''s objects are all present; nothing to do here'
      USING HINT = 'This is production, or staging has already had this file. Not an error to fix — stop.';
  ELSIF v_n <> 0 THEN
    RAISE EXCEPTION
      'only % of 014''s 8 objects are present; stop and look', v_n
      USING HINT = 'A partial apply. Work out which half landed before retrying any of it.';
  END IF;

  -- The backfill classifies behaviours from their seeded answers. With no
  -- answers it would silently mark everything admin, which is a worse outcome
  -- than refusing.
  SELECT count(*) INTO v_rows FROM behavior_answers;
  IF v_rows = 0 THEN
    RAISE EXCEPTION
      'behavior_answers is empty; the backfill would classify every behaviour as admin'
      USING HINT = 'Seed the rubric first. Production classified 128 behaviours from 240 answers.';
  END IF;
  RAISE NOTICE 'classifying % behaviours from % answers', (SELECT count(*) FROM behaviors), v_rows;
END $pre$;

-- -----------------------------------------------------------------------------
-- 2. db/migrations/014_measurement_and_menu_scoring.sql, verbatim
--
-- Everything from here to the end of this section is main's 014 between its
-- BEGIN and its COMMIT, unmodified. Do not tidy it, do not reflow it, do not
-- fix a comment in it. Its value is that it is identical to what production
-- ran, and any edit at all destroys that.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- How a behaviour is measured
-- -----------------------------------------------------------------------------
CREATE TYPE measurement_type AS ENUM ('binary', 'graded', 'inverted', 'admin');

ALTER TABLE behaviors
  ADD COLUMN measurement_type measurement_type NOT NULL DEFAULT 'binary';

COMMENT ON COLUMN behaviors.measurement_type IS
  'binary: rate of occurrence. graded: points earned over points available. '
  'inverted: rate of successful avoidance. admin: not scored, e.g. reviewer name.';

-- Classify from the answer options already seeded, so nothing is typed by hand:
--   several answers carry partial credit            -> graded
--   the full-credit answer begins with "No"         -> inverted
--   no answer carries points                        -> admin
--   otherwise                                       -> binary
WITH shape AS (
  SELECT b.id,
         MAX(a.points) AS top,
         COUNT(*) FILTER (WHERE a.points > 0
                          AND a.points < (SELECT MAX(a2.points)
                                          FROM behavior_answers a2 WHERE a2.behavior_id = b.id)
                         ) AS partials,
         BOOL_OR(a.points = (SELECT MAX(a3.points) FROM behavior_answers a3
                             WHERE a3.behavior_id = b.id)
                 AND lower(btrim(a.answer_value)) LIKE 'no%') AS top_is_no
  FROM behaviors b
  JOIN behavior_answers a ON a.behavior_id = b.id
  GROUP BY b.id
)
UPDATE behaviors b SET measurement_type =
  (CASE WHEN s.top IS NULL OR s.top = 0 THEN 'admin'
        WHEN s.partials > 0             THEN 'graded'
        WHEN s.top_is_no                THEN 'inverted'
        ELSE 'binary' END)::measurement_type
FROM shape s WHERE s.id = b.id;

-- -----------------------------------------------------------------------------
-- Menu scoring
--
-- An additive section wants every item. A menu section wants ENOUGH — one
-- strong action, or several supporting ones together.
--
-- credit_value is the share of the section a single behaviour is worth.
-- Anything at 1.00 is sufficient on its own. The section's credit is the sum
-- of what was actually done, capped at 1.
-- -----------------------------------------------------------------------------
CREATE TYPE section_scoring AS ENUM ('additive', 'menu');

ALTER TABLE rubric_sections
  ADD COLUMN scoring_mode section_scoring NOT NULL DEFAULT 'additive';

ALTER TABLE rubric_behaviors
  ADD COLUMN credit_value numeric(4,2);

ALTER TABLE rubric_behaviors ADD CONSTRAINT rubric_behaviors_credit_ck
  CHECK (credit_value IS NULL OR (credit_value > 0 AND credit_value <= 1));

UPDATE rubric_sections SET scoring_mode = 'menu' WHERE code = 'follow_up';

-- Credit values for Follow-Up.
--
-- The principle is OWNERSHIP OF THE NEXT STEP, not effort. An action where the
-- director carries the follow-up is sufficient on its own. An action that hands
-- the next step back to the caller is worth half — so two of them together
-- still pass, and one alone does not.
--
--   Sets an appointment        the director owns it
--   Offers to call back        the director owns it
--   Offers to mail or email    the director owns it
--   Gives a direct number      excellent, but the caller has to call
--   Asks about other questions the caller has to know what to ask
--   Refers to the website      the caller has to go and research
UPDATE rubric_behaviors rb SET credit_value = v.credit
FROM (VALUES
  ('attempt to set an appointment', 1.00),
  ('offer to call you back',        1.00),
  ('offer to mail or email',        1.00),
  ('provide their direct phone',    0.50),
  ('ask if you had any other',      0.50),
  ('refer to their website',        0.50)
) AS v(frag, credit)
JOIN behaviors b ON lower(b.label) LIKE '%' || v.frag || '%'
JOIN rubric_sections s ON s.id = b.section_id AND s.code = 'follow_up'
WHERE rb.behavior_id = b.id;

-- -----------------------------------------------------------------------------
-- Section scores, honouring both fixes
--
-- Additive sections: points earned over points available, as before.
-- Menu sections: the capped sum of credit for what was actually done.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION section_scores(p_org uuid, p_from date, p_to date)
RETURNS TABLE (section text, scoring section_scoring, evaluations bigint, score numeric)
LANGUAGE sql STABLE AS $$
WITH obs AS (
  SELECT e.id AS eval_id, s.code, s.label, s.display_order, s.scoring_mode,
         o.answer_points, o.possible_points, rb.credit_value,
         (o.answer_points >= o.possible_points AND o.possible_points > 0) AS achieved
  FROM observations o
  JOIN evaluations e ON e.id = o.evaluation_id
  JOIN behaviors b ON b.id = o.behavior_id
  JOIN rubric_sections s ON s.id = b.section_id
  LEFT JOIN rubric_behaviors rb ON rb.behavior_id = b.id AND rb.rubric_id = e.rubric_id
  WHERE o.organization_id = p_org
    AND e.lifecycle_state = 'complete'
    AND b.measurement_type <> 'admin'
    AND o.opportunity
    AND COALESCE(e.performed_on, e.period_start) BETWEEN p_from AND p_to
),
per_eval AS (
  SELECT eval_id, label, display_order, scoring_mode,
         CASE WHEN scoring_mode = 'menu'
              THEN LEAST(1.0, COALESCE(SUM(credit_value) FILTER (WHERE achieved), 0))
              ELSE SUM(answer_points) / NULLIF(SUM(possible_points), 0)
         END AS frac
  FROM obs GROUP BY eval_id, label, display_order, scoring_mode
)
SELECT label, scoring_mode, COUNT(*), round(100.0 * AVG(frac), 1)
FROM per_eval GROUP BY label, display_order, scoring_mode ORDER BY display_order
$$;

-- Behaviour-level reporting that respects measurement type.
CREATE OR REPLACE FUNCTION behavior_detail(p_org uuid, p_from date, p_to date)
RETURNS TABLE (
  section text, label text, measurement measurement_type,
  n bigint, achieved bigint, value numeric
) LANGUAGE sql STABLE AS $$
  SELECT s.label, b.label, b.measurement_type,
         COUNT(*),
         COUNT(*) FILTER (WHERE o.answer_points >= o.possible_points AND o.possible_points > 0),
         CASE WHEN b.measurement_type = 'graded'
              THEN round(100.0 * SUM(o.answer_points) / NULLIF(SUM(o.possible_points), 0), 1)
              ELSE round(100.0 * COUNT(*) FILTER (WHERE o.answer_points >= o.possible_points
                                                    AND o.possible_points > 0) / COUNT(*), 1)
         END
  FROM observations o
  JOIN evaluations e ON e.id = o.evaluation_id
  JOIN behaviors b ON b.id = o.behavior_id
  JOIN rubric_sections s ON s.id = b.section_id
  WHERE o.organization_id = p_org
    AND e.lifecycle_state = 'complete'
    AND b.measurement_type <> 'admin'
    AND o.opportunity
    AND COALESCE(e.performed_on, e.period_start) BETWEEN p_from AND p_to
  GROUP BY s.label, s.display_order, b.label, b.measurement_type
  ORDER BY s.display_order, 6
$$;


-- -----------------------------------------------------------------------------
-- 3. The grants, which are not from 014
--
-- 014 grants nothing and inherited the default of its day. These two lines are
-- the pair db/README.md requires of every new function, and they state in the
-- file what would otherwise depend on a setting three files away. See the
-- header for why this deliberately does not reproduce production's PUBLIC.
--
-- Both functions are STABLE and INVOKER, so they read as whoever calls them
-- and row-level security applies normally. The EXECUTE grant is not the access
-- control here; it only decides who may ask.
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION section_scores(uuid, date, date) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION behavior_detail(uuid, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION section_scores(uuid, date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION behavior_detail(uuid, date, date) TO authenticated;

-- -----------------------------------------------------------------------------
-- 4. Record it
--
-- One row, for this file. NOT a second row for 014 itself: a row named
-- 014_measurement_and_menu_scoring.sql would exist on staging and not on
-- production, where that file actually ran, and a ledger entry that means
-- opposite things on the two databases is worse than the gap it fills. 014's
-- hash goes in this row's note instead, which is the true statement — these
-- statements ran here, inside this file, today.
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261103T2100_fourteen_on_staging.sql',
    NULL,
    'Carries db/migrations/014_measurement_and_menu_scoring.sql verbatim '
    '(sha256 ddd39e13…, main at 5d36649), which ran on production in October '
    'and never on staging. Production has no ledger row for 014 and will not: '
    'it predates the ledger. The two new functions arrive WITHOUT the PUBLIC '
    'grant production''s have, deliberately — see the header.');
END $rec$;

COMMIT;

-- =============================================================================
-- STILL TO DO
--
-- * acl WILL SHOW EXACTLY TWO DIFFERENCES UNTIL THE PUBLIC SWEEP: section_scores
--   and behavior_detail, PUBLIC on production and not on staging. Expected,
--   named here so it is not investigated twice, and it resolves in the
--   direction of the sweep rather than against it. Everything else matched on
--   3 November — 212 of 212 entries.
--
-- * THE col QUERY CANNOT SEE numeric PRECISION. credit_value is numeric(4,2);
--   information_schema.columns.data_type reads plain "numeric" for that and for
--   an unconstrained numeric alike, and the diff query does not select
--   numeric_precision or numeric_scale. So the one column this file adds with a
--   precision is a column the comparison would not have caught. Worth adding
--   the next time col is touched.
--
-- * PRODUCTION'S 014 IS STILL UNRECORDED, like every other pre-ledger
--   migration. That is the ledger's stated scope and not a gap to patch: the
--   backfill of 3 November covered the eleven timestamped files and
--   deliberately left 001–058 alone, because for those we have objects and no
--   provenance.
-- =============================================================================

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- The body comparison is the first test and the one that matters. Everything
-- else is about whether the data came out the same.
--
-- DO $$
-- DECLARE r text := ''; v_org uuid; n int;
-- BEGIN
--   r := r || 'behavior_detail body: '
--          || COALESCE((SELECT md5(prosrc) FROM pg_proc
--                        WHERE oid = 'public.behavior_detail(uuid,date,date)'::regprocedure), 'MISSING')
--          || chr(10) || '   (expect 6bb3272e84356abd7fb266dd7d9aa56d — production''s)' || chr(10);
--   r := r || 'section_scores body:  '
--          || COALESCE((SELECT md5(prosrc) FROM pg_proc
--                        WHERE oid = 'public.section_scores(uuid,date,date)'::regprocedure), 'MISSING')
--          || chr(10) || '   (expect dfec02e224e7d63ccf07eb620de7f97b — production''s. '
--          || 'A mismatch means the cut from main was not byte-exact and this '
--          || 'file has created a new drift instead of closing one)' || chr(10);
--
--   r := r || 'the two ACLs:' || chr(10);
--   r := r || COALESCE((SELECT string_agg('    ' || rpad(proname, 18) || COALESCE(proacl::text, 'NULL'),
--                                         chr(10) ORDER BY proname)
--                         FROM pg_proc WHERE oid IN (
--                           'public.behavior_detail(uuid,date,date)'::regprocedure,
--                           'public.section_scores(uuid,date,date)'::regprocedure)), '    NONE')
--          || chr(10)
--          || '   (expect postgres=X and authenticated=X, with NO bare =X/postgres. '
--          || 'Production''s have the bare one, which is PUBLIC — the two-entry '
--          || 'difference the header describes)' || chr(10);
--
--   r := r || 'enum labels in order: '
--          || (SELECT string_agg(e.enumlabel, ',' ORDER BY e.enumsortorder)
--                FROM pg_enum e WHERE e.enumtypid = 'public.measurement_type'::regtype)
--          || ' / '
--          || (SELECT string_agg(e.enumlabel, ',' ORDER BY e.enumsortorder)
--                FROM pg_enum e WHERE e.enumtypid = 'public.section_scoring'::regtype)
--          || '   (expect binary,graded,inverted,admin / additive,menu — ORDER is '
--          || 'part of the type and the diff compares it)' || chr(10);
--
--   -- The backfill. These counts are the thing to compare against production,
--   -- because they come from data rather than from the file.
--   r := r || 'behaviours by measurement_type:' || chr(10);
--   r := r || COALESCE((SELECT string_agg('    ' || rpad(measurement_type::text, 10) || c,
--                                         chr(10) ORDER BY measurement_type::text)
--                         FROM (SELECT measurement_type, count(*) c FROM behaviors
--                                GROUP BY measurement_type) q), '    NONE') || chr(10);
--   r := r || '   (compare with production. The rubric content matched on '
--          || '3 November, so these should too)' || chr(10);
--
--   r := r || 'follow_up section is menu: '
--          || COALESCE((SELECT (scoring_mode = 'menu')::text FROM rubric_sections
--                        WHERE code = 'follow_up'), 'NO follow_up SECTION')
--          || chr(10);
--   r := r || 'rubric_behaviors with a credit_value: '
--          || (SELECT count(*) FROM rubric_behaviors WHERE credit_value IS NOT NULL)
--          || '   (expect 36 on staging and 31 on production. NOT six per '
--          || 'rubric: that was my guess from reading the six VALUES rows, and '
--          || 'the backfill only credits a behaviour a rubric actually '
--          || 'contains. Production''s six rubrics hold 5,5,5,6,5,5; staging '
--          || 'has a seventh rubric, which is the whole of the difference)'
--          || chr(10);
--   r := r || '    values: '
--          || COALESCE((SELECT string_agg(DISTINCT credit_value::text, ',' ORDER BY credit_value::text)
--                         FROM rubric_behaviors WHERE credit_value IS NOT NULL), 'NONE')
--          || '   (expect 0.50,1.00)' || chr(10);
--
--   -- They are LANGUAGE sql, so the server validated their bodies at CREATE.
--   -- Calling them proves the other half: that they run against this
--   -- database's data without raising.
--   SELECT id INTO v_org FROM organizations ORDER BY created_at LIMIT 1;
--   IF v_org IS NULL THEN
--     r := r || 'no organization to call the functions with — NOT TESTED' || chr(10);
--   ELSE
--     BEGIN
--       SELECT count(*) INTO n FROM section_scores(v_org, '2026-01-01', '2026-12-31');
--       r := r || 'section_scores runs: ' || n || ' rows' || chr(10);
--     EXCEPTION WHEN others THEN
--       r := r || 'section_scores RAISED (BAD): ' || SQLERRM || chr(10); END;
--     BEGIN
--       SELECT count(*) INTO n FROM behavior_detail(v_org, '2026-01-01', '2026-12-31');
--       r := r || 'behavior_detail runs: ' || n || ' rows' || chr(10);
--     EXCEPTION WHEN others THEN
--       r := r || 'behavior_detail RAISED (BAD): ' || SQLERRM || chr(10); END;
--   END IF;
--
--   r := r || 'the CHECK tolerates the rows that were already there: '
--          || (SELECT count(*) FROM rubric_behaviors WHERE credit_value IS NULL)
--          || ' rows at NULL   (they passed rubric_behaviors_credit_ck, which '
--          || 'is what "IS NULL OR" is for)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 20261103T2100_fourteen_on_staging (all rolled back) %',
--                   chr(10) || r;
-- END $$;
-- =============================================================================
