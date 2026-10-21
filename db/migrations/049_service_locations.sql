-- =============================================================================
-- 049_service_locations.sql
-- The Hub — migration 49: places families reach, and places a firm works from.
--
-- RUN THE TWO ALTER TYPE LINES BELOW ON THEIR OWN FIRST, then run from BEGIN;
-- to COMMIT;. Postgres can't use a new enum value in the transaction that
-- adds it (031 did the same). IF NOT EXISTS makes the first part safe to re-run.
--
-- WHY. A location has been one thing: a site families reach, which gets shopped
-- and scored, lands in benchmarks, and carries FTC applicability. Every
-- location_type value (funeral_home, cemetery, cremation, pet, combo,
-- transportation) is that kind. But a firm also has places it works FROM — an
-- office, an administrative building, a hospice it doesn't own — that need an
-- address and a timezone and nothing else. Dead Ringers' own office is the
-- first: real calls have shown UTC because the firm had no location at all.
--
-- Typing an office as funeral_home would be the consultation-leg defect again —
-- a plausible wrong number with nothing on screen to explain it:
--   * behavior_applies() treats an empty applies_to_types as "every site", so an
--     office would get every universal rubric question;
--   * benchmark_snapshots are keyed on location_type (null = all combined), so
--     an office would sit in the funeral-home and combined denominators;
--   * funeral_rule_applies defaults to TRUE, so an office would carry FTC
--     exposure unless someone remembered to say otherwise.
--
-- THIS MIGRATION
--   1. location_type gains 'office' and 'other' — the non-service kinds.
--   2. location_type_is_service(type): the rule, written once.
--   3. locations.is_service_location, GENERATED from the type, so it can't
--      disagree with it and nothing has to set it. A non-service location
--      can't carry the Funeral Rule (a check).
--   4. behavior_applies() is false for a non-service type, however a behavior's
--      applies_to_types is set; behaviors, rubrics and benchmark snapshots
--      can't name a non-service type (checks).
--   5. service_locations: active service locations only. Report and score from
--      this, never from locations directly. Read-only, like countable_calls.
--
-- WHAT IT DOESN'T DO. It doesn't create Dead Ringers' office: that row is a
-- real address, entered in the SQL editor and never written to a file.
--
-- Requires: 001 to 048
-- =============================================================================

-- ---- Run alone, first ---------------------------------------------------------
ALTER TYPE location_type ADD VALUE IF NOT EXISTS 'office';
ALTER TYPE location_type ADD VALUE IF NOT EXISTS 'other';
-- ---- Then from here -----------------------------------------------------------

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. The rule, once
--
-- CHANGING THIS FUNCTION DOES NOT UPDATE EXISTING ROWS. is_service_location
-- is STORED, so it is computed on write and never recomputed. After adding a
-- value here, force a rebuild in the same migration:
--     UPDATE locations SET location_type = location_type;
-- (Found in review.)
-- -----------------------------------------------------------------------------
CREATE FUNCTION location_type_is_service(lt location_type) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT lt NOT IN ('office', 'other')
$$;

COMMENT ON FUNCTION location_type_is_service(location_type) IS
  'Whether a kind of location is a place families reach (shopped, scored, '
  'benchmarked, FTC-relevant) rather than a place the firm works from. The '
  'one place this is decided; a new location_type value is a service type '
  'unless it is added here. CHANGING THIS DOES NOT UPDATE EXISTING ROWS: '
  'locations.is_service_location is stored, so rebuild it in the same '
  'migration with UPDATE locations SET location_type = location_type.';

-- -----------------------------------------------------------------------------
-- 2. On the location
-- -----------------------------------------------------------------------------
ALTER TABLE locations
  ADD COLUMN is_service_location boolean
  GENERATED ALWAYS AS (location_type_is_service(location_type)) STORED;

COMMENT ON COLUMN locations.is_service_location IS
  'Derived from location_type: true for a place families reach, false for an '
  'office or other non-service site. Non-service locations have an address and '
  'a timezone and nothing else — never scored, never benchmarked, never under '
  'the Funeral Rule. Use service_locations to leave them out.';

ALTER TABLE locations ADD CONSTRAINT locations_non_service_no_funeral_rule_ck
  CHECK (is_service_location OR funeral_rule_applies = false);

-- -----------------------------------------------------------------------------
-- 3. Scoring and benchmarks can't reach a non-service location
-- -----------------------------------------------------------------------------
-- As 007 left it, with the non-service exclusion first: an empty
-- applies_to_types means "every service site", never "an office too".
CREATE OR REPLACE FUNCTION behavior_applies(b uuid, lt location_type)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT location_type_is_service(lt)
     AND (cardinality(applies_to_types) = 0 OR lt = ANY(applies_to_types))
  FROM behaviors WHERE id = b
$$;

ALTER TABLE behaviors ADD CONSTRAINT behaviors_service_types_only_ck
  CHECK (NOT (applies_to_types && ARRAY['office', 'other']::location_type[]));

ALTER TABLE rubrics ADD CONSTRAINT rubrics_service_type_only_ck
  CHECK (applies_to_type IS NULL OR location_type_is_service(applies_to_type));

ALTER TABLE benchmark_snapshots ADD CONSTRAINT benchmark_snapshots_service_type_only_ck
  CHECK (location_type IS NULL OR location_type_is_service(location_type));

-- -----------------------------------------------------------------------------
-- 4. The right thing as the default
--
-- security_invoker, so locations' RLS applies to the reader. SELECT only, for
-- the reason countable_calls is (043): a one-table filter is auto-updatable
-- and the default privileges would otherwise grant writes. SELECT * is
-- expanded at creation — adding a column to locations means recreating this
-- view in the same migration (db/README.md).
-- -----------------------------------------------------------------------------
CREATE VIEW service_locations WITH (security_invoker = true) AS
SELECT * FROM locations WHERE is_service_location AND status = 'active';

COMMENT ON VIEW service_locations IS
  'Active locations families reach. Score, shop, benchmark and report from '
  'this rather than from locations: offices and other non-service sites are '
  'left out.';

REVOKE ALL ON service_locations FROM PUBLIC, anon, authenticated;
GRANT SELECT ON service_locations TO authenticated;

COMMIT;

-- =============================================================================
-- Verification — one block, everything rolled back by the closing RAISE.
--
-- DO $$
-- DECLARE r text := ''; v_org uuid; v_loc uuid; v_b uuid;
-- BEGIN
--   SELECT id INTO v_org FROM organizations WHERE code = 'DR';
--
--   -- Two reasons a location can be missing from service_locations: it isn't a
--   -- service site, or it isn't active. Counted apart, so neither is mistaken
--   -- for the other.
--   r := r || 'locations: ' || (SELECT count(*) FROM locations)
--          || ', not active: ' || (SELECT count(*) FROM locations WHERE status <> 'active')
--          || ', non-service: ' || (SELECT count(*) FROM locations WHERE NOT is_service_location)
--          || ', in service_locations: ' || (SELECT count(*) FROM service_locations) || chr(10);
--   r := r || 'existing locations still service: '
--          || (SELECT bool_and(is_service_location) FROM locations WHERE location_type::text NOT IN ('office', 'other'))
--          || '   (expect true)' || chr(10);
--
--   INSERT INTO locations (organization_id, name, location_type, funeral_rule_applies, city, state, timezone)
--   VALUES (v_org, 'Office (test)', 'office', false, 'Testville', 'OH', 'America/New_York') RETURNING id INTO v_loc;
--   r := r || 'office is non-service: ' || (NOT (SELECT is_service_location FROM locations WHERE id = v_loc))
--          || ', in service_locations: ' || EXISTS (SELECT 1 FROM service_locations WHERE id = v_loc)
--          || '   (expect true, false)' || chr(10);
--
--   BEGIN
--     INSERT INTO locations (organization_id, name, location_type, city, state, timezone)
--     VALUES (v_org, 'Office, FTC by default (test)', 'office', 'Testville', 'OH', 'America/New_York');
--     r := r || 'office with the Funeral Rule: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN check_violation THEN r := r || 'office with the Funeral Rule refused' || chr(10); END;
--
--   SELECT id INTO v_b FROM behaviors WHERE cardinality(applies_to_types) = 0 LIMIT 1;
--   r := r || 'a universal behavior applies at a funeral home: ' || coalesce(behavior_applies(v_b, 'funeral_home')::text, 'no universal behavior')
--          || ', at an office: ' || coalesce(behavior_applies(v_b, 'office')::text, 'n/a')
--          || '   (expect true, false)' || chr(10);
--
--   BEGIN
--     UPDATE behaviors SET applies_to_types = ARRAY['office']::location_type[] WHERE id = v_b;
--     r := r || 'behavior aimed at an office: ALLOWED (BAD)' || chr(10);
--   EXCEPTION WHEN check_violation THEN r := r || 'behavior aimed at an office refused' || chr(10); END;
--
--   r := r || 'authenticated can read service_locations: ' || has_table_privilege('authenticated', 'service_locations', 'SELECT')
--          || ', write it: ' || has_table_privilege('authenticated', 'service_locations', 'INSERT,UPDATE,DELETE')
--          || ', anon read: ' || has_table_privilege('anon', 'service_locations', 'SELECT')
--          || '   (expect true, false, false)' || chr(10);
--
--   RAISE EXCEPTION 'VERIFY 049 (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
