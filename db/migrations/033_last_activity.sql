-- =============================================================================
-- 033_last_activity.sql
-- The Hub — migration 33: order the feed by when a thread last moved.
--
-- `occurred_at` is when an interaction STARTED. For a call those are the same
-- fact. For a text thread they are not: a conversation opened three weeks ago
-- and answered this morning sorts three weeks down the feed, so it is not in
-- the page of 50 at all. The app was working around that with three queries, an
-- in-memory merge and a 1,000-row cap.
--
-- WHAT "ACTIVITY" MEANS HERE, AND WHAT IT DOES NOT
--
-- Only the messages belonging to this interaction. Nothing else moves it: not
-- a team chat note about the call, not a reminder falling due, not a tag being
-- applied, not someone opening the record.
--
-- That is deliberate and worth stating because the name invites a wider
-- reading. A reminder is activity ABOUT a conversation, not activity IN it,
-- and a feed where a note nudges a two-week-old call back to the top would be
-- showing staff work rather than family contact — which is the opposite of
-- what the Activity list is for.
--
-- It is also the safer direction. Widening this later is additive. Narrowing it
-- would silently reorder a feed everything has been built against.
--
-- Requires: 001 to 032
-- =============================================================================

BEGIN;

ALTER TABLE interactions ADD COLUMN last_activity_at timestamptz;

COMMENT ON COLUMN interactions.last_activity_at IS
  'When this interaction last moved: the newest message in it, or occurred_at '
  'for a call and for a thread with no messages. Maintained by trigger. '
  'SCOPE IS THIS INTERACTION''S OWN MESSAGES ONLY — a chat note, a reminder, a '
  'tag or a view does not touch it. Those are activity about a conversation, '
  'not in it, and the feed is for family contact rather than staff work.';

-- -----------------------------------------------------------------------------
-- Backfill
-- -----------------------------------------------------------------------------
UPDATE interactions i
   SET last_activity_at = GREATEST(
         i.occurred_at,
         COALESCE((SELECT max(m.sent_at) FROM messages m
                    WHERE m.interaction_id = i.id), i.occurred_at));

ALTER TABLE interactions ALTER COLUMN last_activity_at SET NOT NULL;

-- The feed's own index. Ordering by this is the whole point of the column.
CREATE INDEX interactions_feed_idx
  ON interactions (organization_id, last_activity_at DESC);

-- -----------------------------------------------------------------------------
-- A new interaction starts where it occurred
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION interactions_init_last_activity() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.last_activity_at := COALESCE(NEW.last_activity_at, NEW.occurred_at);
  RETURN NEW;
END $$;
CREATE TRIGGER interactions_init_activity BEFORE INSERT ON interactions
  FOR EACH ROW EXECUTE FUNCTION interactions_init_last_activity();

-- -----------------------------------------------------------------------------
-- A message moves its thread
--
-- Insert and update only move it forward, so a late-arriving message from
-- yesterday cannot drag a live thread backwards. Delete recomputes, because
-- removing the newest message should let the thread fall back.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION messages_touch_interaction() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    UPDATE interactions i
       SET last_activity_at = GREATEST(
             i.occurred_at,
             COALESCE((SELECT max(m.sent_at) FROM messages m
                        WHERE m.interaction_id = i.id), i.occurred_at))
     WHERE i.id = OLD.interaction_id;
    RETURN OLD;
  END IF;

  UPDATE interactions
     SET last_activity_at = GREATEST(last_activity_at, NEW.sent_at)
   WHERE id = NEW.interaction_id;
  RETURN NEW;
END $$;

CREATE TRIGGER messages_touch_activity
  AFTER INSERT OR UPDATE OF sent_at OR DELETE ON messages
  FOR EACH ROW EXECUTE FUNCTION messages_touch_interaction();

COMMIT;

-- =============================================================================
-- Verification
--
--   SET app.is_internal = 'on';
--
--   -- a call's activity is when it happened; a thread's is its last message
--   SELECT external_ref, channel, occurred_at, last_activity_at
--   FROM interactions WHERE external_ref IN ('seed_001','seed_003','seed_007')
--   ORDER BY external_ref;
--   -- seed_003 should sit at 13:22, its newest message, not 13:05
--
--   -- the feed, as one query
--   SELECT external_ref, channel, last_activity_at
--   FROM interactions
--   WHERE organization_id = (SELECT id FROM organizations WHERE code = 'DR')
--   ORDER BY last_activity_at DESC LIMIT 10;
--
--   -- an old thread answered today jumps to the top
--   BEGIN;
--     INSERT INTO messages (organization_id, interaction_id, direction,
--                           from_e164, to_e164, body, sent_at)
--     SELECT organization_id, id, 'inbound', '+15135551201', '+15135550100',
--            'One more question when you have a moment.', now()
--     FROM interactions WHERE external_ref = 'seed_003';
--
--     SELECT external_ref, last_activity_at FROM interactions
--     WHERE organization_id = (SELECT id FROM organizations WHERE code = 'DR')
--     ORDER BY last_activity_at DESC LIMIT 3;
--     -- seed_003 first
--   ROLLBACK;
-- =============================================================================
