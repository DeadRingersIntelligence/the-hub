-- =============================================================================
-- 022_routing_and_availability.sql
-- The Hub — Phase 2, migration 22: who rings, when, and who answered instead.
--
-- Two mechanisms that look alike and are not.
--
-- AVAILABILITY IS A STATE. Whoever is logged in and marked ready is who rings.
-- Directors asleep at home are not ready, so their phone stays quiet. Real
-- time, per person, changing all day.
--
-- ROUTING IS A SCHEDULE. Forward to the answering service between set hours.
-- Planned, per location, changing rarely.
--
-- Availability HISTORY has to be retained or "nobody answered the 2am call" is
-- unanswerable — you cannot tell whether every director was logged out or
-- three were ready and none picked up. Those are completely different
-- conversations.
--
-- Requires: 001 to 021
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- user_availability_events
--
-- A log, not a current-state column. The current state is the latest row.
-- -----------------------------------------------------------------------------
CREATE TYPE availability_state AS ENUM (
  'ready', 'not_ready', 'on_call', 'busy', 'offline');

CREATE TABLE user_availability_events (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  person_id         uuid NOT NULL REFERENCES people(id) ON DELETE CASCADE,
  seat_id           uuid REFERENCES seats(id) ON DELETE SET NULL,

  state             availability_state NOT NULL,
  reason            text,
  changed_at        timestamptz NOT NULL DEFAULT now(),
  source            text                       -- 'dial_stack', 'manual', 'schedule'
);
CREATE INDEX user_availability_person_time_idx
  ON user_availability_events (person_id, changed_at DESC);
CREATE INDEX user_availability_org_time_idx
  ON user_availability_events (organization_id, changed_at DESC);

-- Who was ready at a moment in time. This is the query that makes a 2am miss
-- explainable.
CREATE OR REPLACE FUNCTION available_at(p_org uuid, p_at timestamptz)
RETURNS TABLE (person_id uuid, full_name text, state availability_state)
LANGUAGE sql STABLE AS $$
  SELECT DISTINCT ON (e.person_id) e.person_id, p.full_name, e.state
  FROM user_availability_events e
  JOIN people p ON p.id = e.person_id
  WHERE e.organization_id = p_org AND e.changed_at <= p_at
  ORDER BY e.person_id, e.changed_at DESC
$$;

-- -----------------------------------------------------------------------------
-- routing_schedules
--
-- Per location. Nights, weekends, holidays. A holiday row has a date and no
-- weekday, which is how it overrides the weekly pattern.
-- -----------------------------------------------------------------------------
CREATE TYPE routing_target AS ENUM (
  'ring_team', 'answering_service', 'voicemail', 'forward_number', 'on_call_person');

CREATE TABLE routing_schedules (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  location_id       uuid REFERENCES locations(id) ON DELETE CASCADE,
  name              text NOT NULL,

  -- 0 = Sunday. Null with a specific_date set means a holiday override.
  day_of_week       smallint,
  specific_date     date,
  starts_at         time NOT NULL,
  ends_at           time NOT NULL,

  target            routing_target NOT NULL,
  target_team_id    uuid REFERENCES teams(id) ON DELETE SET NULL,
  target_person_id  uuid REFERENCES people(id) ON DELETE SET NULL,
  target_e164       text,

  -- Higher wins where two rules cover the same moment. A holiday outranks a
  -- weekday pattern without either having to know about the other.
  priority          smallint NOT NULL DEFAULT 100,
  active            boolean NOT NULL DEFAULT true,

  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX routing_schedules_location_idx
  ON routing_schedules (location_id, active, priority DESC);
CREATE TRIGGER routing_schedules_touch BEFORE UPDATE ON routing_schedules
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE routing_schedules ADD CONSTRAINT routing_schedules_when_ck
  CHECK (num_nonnulls(day_of_week, specific_date) = 1);
ALTER TABLE routing_schedules ADD CONSTRAINT routing_schedules_dow_ck
  CHECK (day_of_week IS NULL OR day_of_week BETWEEN 0 AND 6);

-- A target must be reachable.
ALTER TABLE routing_schedules ADD CONSTRAINT routing_schedules_target_ck CHECK (
     (target = 'ring_team'       AND target_team_id   IS NOT NULL)
  OR (target = 'on_call_person'  AND target_person_id IS NOT NULL)
  OR (target = 'forward_number'  AND target_e164      IS NOT NULL)
  OR (target IN ('answering_service','voicemail')));

CREATE OR REPLACE FUNCTION routing_schedules_normalize() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.target_e164 := COALESCE(normalize_e164(NEW.target_e164), NEW.target_e164);
  RETURN NEW;
END $$;
CREATE TRIGGER routing_schedules_normalize_t BEFORE INSERT OR UPDATE ON routing_schedules
  FOR EACH ROW EXECUTE FUNCTION routing_schedules_normalize();

-- -----------------------------------------------------------------------------
-- answering_services
--
-- A first-class handler, not a gap in the data. Some clients pay specifically
-- to have their answering service evaluated, and after-hours is exactly when
-- at-need calls arrive — so leaving those calls unattributed leaves a blind
-- spot in the hours that matter most.
--
-- An answering service that is itself a Dead Ringers client is also an
-- organization. organization_id here is the firm being served; served_by_org_id
-- points at the service's own tenancy when it has one.
-- -----------------------------------------------------------------------------
CREATE TABLE answering_services (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name              text NOT NULL,

  served_by_org_id  uuid REFERENCES organizations(id) ON DELETE SET NULL,

  main_e164         text,
  evaluated         boolean NOT NULL DEFAULT false,
  active            boolean NOT NULL DEFAULT true,
  notes             text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, name)
);
CREATE TRIGGER answering_services_touch BEFORE UPDATE ON answering_services
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE answering_services ADD CONSTRAINT answering_services_not_self_ck
  CHECK (served_by_org_id IS NULL OR served_by_org_id <> organization_id);

-- Which service handled a call, when one did.
ALTER TABLE interactions
  ADD COLUMN answering_service_id uuid REFERENCES answering_services(id) ON DELETE SET NULL;

-- An answering-service handler must name the service.
ALTER TABLE interactions ADD CONSTRAINT interactions_answering_service_ck
  CHECK (handler_type <> 'answering_service' OR answering_service_id IS NOT NULL);

-- -----------------------------------------------------------------------------
-- Row-level security
-- -----------------------------------------------------------------------------
ALTER TABLE user_availability_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE routing_schedules        ENABLE ROW LEVEL SECURITY;
ALTER TABLE answering_services       ENABLE ROW LEVEL SECURITY;

CREATE POLICY user_availability_events_tenant ON user_availability_events
  USING (is_internal() OR organization_id = current_organization_id());
CREATE POLICY routing_schedules_tenant ON routing_schedules
  USING (is_internal() OR organization_id = current_organization_id());

-- Both sides see the relationship: the firm being served, and the answering
-- service when it is a client in its own right.
CREATE POLICY answering_services_tenant ON answering_services
  USING (is_internal()
      OR organization_id = current_organization_id()
      OR served_by_org_id = current_organization_id());

COMMIT;

-- =============================================================================
-- Verification
--
--   SET app.is_internal = 'on';
--
--   -- a schedule that is neither weekly nor a specific date is refused
--   INSERT INTO routing_schedules
--     (organization_id, name, starts_at, ends_at, target)
--   SELECT id, 'Nights', '17:00', '08:00', 'answering_service'
--   FROM organizations WHERE code='ALT';
--
--   -- weekday nights to the answering service
--   INSERT INTO routing_schedules
--     (organization_id, name, day_of_week, starts_at, ends_at, target)
--   SELECT id, 'Weeknights', 1, '17:00', '08:00', 'answering_service'
--   FROM organizations WHERE code='ALT';
--
--   -- forwarding with nowhere to forward is refused
--   INSERT INTO routing_schedules
--     (organization_id, name, day_of_week, starts_at, ends_at, target)
--   SELECT id, 'Sundays', 0, '00:00', '23:59', 'forward_number'
--   FROM organizations WHERE code='ALT';
-- =============================================================================
