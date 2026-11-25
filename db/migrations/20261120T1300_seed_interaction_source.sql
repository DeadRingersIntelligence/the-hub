-- =============================================================================
-- 20261120T1300_seed_interaction_source.sql
-- The Hub — interaction_source gains 'seed', for calls loaded to measure with.
--
-- WHY. Planning session brief, 19 Nov (Mandie's ruling): seed one client's
-- CTM call data into STAGING to size the call-joining question (backlog item
-- 6, link action vs offer-on-arrival) before live data exists. Rule 1 of that
-- brief: seeded rows must not be source 'real'. Neither existing value fits:
--
--   real   the firm's own calls. Seeded rows marked real would be counted as
--          genuine by every check that asks "is anything still arriving"
--          (db/README.md) and by the feed's default view.
--   shop   mystery-shop calls, which carry evaluations and feed the rubric
--          and benchmark work (008, behavior_rates). Seeded CTM calls marked
--          shop would mix ordinary callers into evaluation data.
--
-- So a third value. This file ONLY adds it. ALTER TYPE … ADD VALUE cannot be
-- used in the transaction that adds it, and the ledger keeps one row per
-- filename, so the load that uses 'seed' is a separate file — the two-pass
-- treatment 20261119T1500 / T1510 worked out (db/README.md, "Two hashes").
--
-- WHERE 'seed' WOULD SHOW, checked 20 Nov across both repositories:
--
--   * The feed's default "Real calls" view filters source = 'real': hidden.
--     "All activity" shows every source: seeded calls appear there, unmarked
--     until the app learns the value (its types say 'real' | 'shop').
--   * db/README.md's "is anything still arriving" query filters
--     source = 'real': not counted.
--   * behavior_rates(… p_source) counts evaluations; seeded calls have none.
--   * countable_calls (058) does NOT filter on source — it already includes
--     shop calls, and would include seeded ones. Nothing in the app reads it
--     today. ANYTHING THAT READS countable_calls FOR A REAL-CALL FIGURE MUST
--     FILTER source = 'real', and has always needed to, for shop calls.
--   * ingest_call_event and find_or_start_text_thread name 'real' only to
--     write it on what arrives from the carriers; nothing seeded passes
--     through them.
--
-- STAGING ONLY, by the brief: no seeded row is to reach production "under
-- any circumstances". The VALUE is added to both databases all the same, so
-- the type stays identical and the nine-query baseline keeps comparing them
-- (`typ` will move on both). A value nothing uses is inert. The load file
-- that writes 'seed' rows is the one that refuses on production.
--
-- Safe to run twice: IF NOT EXISTS, and the ledger row is refreshed.
--
-- Requires: 006 (interaction_source), 20261103T1200 (record_migration).
-- =============================================================================

BEGIN;

ALTER TYPE interaction_source ADD VALUE IF NOT EXISTS 'seed';

-- Said on the type, where a reader of the schema meets it. 'seed' cannot be
-- USED in this transaction; naming it in a comment is not using it.
COMMENT ON TYPE interaction_source IS
  'Where an interaction came from. real: the firm''s own calls and texts, '
  'from the carriers. shop: mystery-shop calls, which carry evaluations. '
  'seed: calls loaded to measure with (20261120T1300) — staging only, never '
  'counted as real, removable as a batch. Anything reporting real activity '
  'filters source = ''real''; countable_calls does not, and includes all '
  'three.';

DO $rec$
BEGIN
  PERFORM record_migration(
    '20261120T1300_seed_interaction_source.sql',
    NULL,
    'interaction_source gains seed, for CTM calls loaded into staging to size '
    'the call-joining question. Its own file: ADD VALUE cannot be used in the '
    'transaction that adds it. Added to both databases so the type stays '
    'identical; only the load, a separate file, writes seed rows, on staging.');
END $rec$;

COMMIT;

-- =============================================================================
-- Verification — run AFTER the file, as its own statement: the new value is
-- usable once the transaction above has committed. Changes nothing; ends in a
-- RAISE so the editor shows its output.
--
-- DO $$
-- DECLARE r text := '';
-- BEGIN
--   r := r || '1. interaction_source, in order: '
--          || (SELECT string_agg(e.enumlabel, ', ' ORDER BY e.enumsortorder)
--                FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
--               WHERE t.typname = 'interaction_source')
--          || '   (expect real, shop, seed — appended, so nothing that sorts or '
--          || 'compares the existing two moves)' || chr(10);
--   r := r || '2. interactions with source seed: '
--          || (SELECT count(*) FROM interactions WHERE source = 'seed')
--          || '   (expect 0 — this file adds the value; the load is separate)' || chr(10);
--   r := r || '3. the type carries its comment: '
--          || (obj_description('interaction_source'::regtype, 'pg_type') LIKE '%seed: calls loaded to measure with%')
--          || '   (expect true)' || chr(10);
--   RAISE EXCEPTION 'VERIFY 20261120T1300_seed_interaction_source %', chr(10) || r;
-- END $$;
-- =============================================================================
