-- =============================================================================
-- 031_carriers.sql
-- The Hub — migration 31: HelloPhone has two inbound carriers, not one.
--
-- Voice and call events come from Dial Stack. Messages come from Surge, which
-- is a separate account rather than something brokered through Dial Stack. The
-- schema was designed around one event model, and the read side is about to be
-- built on that assumption.
--
-- WHY CARRIER GOES ON THE INTERACTION AND NOT ONLY ON THE NUMBER
--
-- A number does not have one carrier. After the mini-port it has two: voice on
-- Dial Stack, messaging on Surge. And carriers change — that is what a port is.
-- A carrier read from the number at query time would retroactively reassign
-- every past interaction to whoever holds the number today.
--
-- Same rule as freezing first-touch attribution and freezing a benchmark: the
-- fact is recorded as it was, not resolved later from something that moves.
--
-- Requires: 001 to 030
-- =============================================================================

-- PREREQUISITE — run this line as its OWN query first, then this file.
--
--   (now executed below, before the transaction)

-- NOTE: in the Supabase SQL editor, run the ALTER TYPE line on its own first,
-- then run from BEGIN; to COMMIT;. The editor wraps a whole submission in one
-- transaction, and Postgres cannot use a new enum value in the transaction
-- that adds it. This was already run by hand against the database; the
-- IF NOT EXISTS makes it safe to re-run.
ALTER TYPE number_purpose ADD VALUE IF NOT EXISTS 'messaging';

BEGIN;

-- -----------------------------------------------------------------------------
-- Who carried this interaction
--
-- Free text rather than an enum: a carrier is a vendor relationship, and this
-- build has already changed vendors once. An enum would mean a migration every
-- time, with the value needed before it could be used.
-- -----------------------------------------------------------------------------
ALTER TABLE interactions ADD COLUMN carrier text;

COMMENT ON COLUMN interactions.carrier IS
  'Which carrier handled this interaction, as at the time it happened: '
  'dial_stack for voice, surge for messaging, ctm for anything still on the '
  'old platform. Recorded rather than resolved from the number, because a '
  'number''s carrier changes when it ports and past interactions must not '
  'follow it.';

CREATE INDEX interactions_carrier_idx
  ON interactions (organization_id, carrier, occurred_at DESC)
  WHERE carrier IS NOT NULL;

-- Backfill what is already known. Calls on this platform came from Dial Stack;
-- texts from Surge; anything from a shop came through CTM.
UPDATE interactions SET carrier =
  CASE WHEN source = 'shop'      THEN 'ctm'
       WHEN channel = 'text'     THEN 'surge'
       WHEN channel = 'call'     THEN 'dial_stack'
  END
WHERE carrier IS NULL;

-- -----------------------------------------------------------------------------
-- A number's two carriers
--
-- `carrier` on phone_numbers stays as the voice carrier, which is what it has
-- always held. Messaging gets its own, plus the id Surge knows the number by —
-- because the first time a message fails to deliver, the question is which
-- system to look in and what to look it up as.
-- -----------------------------------------------------------------------------
ALTER TABLE phone_numbers ADD COLUMN messaging_carrier     text;
ALTER TABLE phone_numbers ADD COLUMN messaging_external_ref text;
ALTER TABLE phone_numbers ADD COLUMN messaging_enabled     boolean NOT NULL DEFAULT false;
ALTER TABLE phone_numbers ADD COLUMN messaging_ported_at   timestamptz;

COMMENT ON COLUMN phone_numbers.carrier IS
  'The VOICE carrier for this number — dial_stack, ctm, other. Messaging is '
  'separate; see messaging_carrier.';
COMMENT ON COLUMN phone_numbers.messaging_carrier IS
  'The MESSAGING carrier, normally surge. A number that has done the mini-port '
  'is on two carriers at once, which is why this is not the same column.';
COMMENT ON COLUMN phone_numbers.messaging_external_ref IS
  'What the messaging carrier calls this number. The id to quote when a '
  'message does not deliver.';
COMMENT ON COLUMN phone_numbers.messaging_ported_at IS
  'When the mini-port completed. Before this, texts to the number did not '
  'reach us — which is the explanation for a gap in a thread.';

-- A number cannot be reachable for texting without a carrier to carry them.
ALTER TABLE phone_numbers ADD CONSTRAINT phone_numbers_messaging_ck
  CHECK (messaging_enabled = false OR messaging_carrier IS NOT NULL);

COMMENT ON COLUMN messages.external_ref IS
  'The carrier''s own id for this message — the Surge message id. What to '
  'quote when chasing a delivery failure.';

-- -----------------------------------------------------------------------------
-- Resolving an inbound message to an organization
--
-- A Surge webhook arrives knowing only the two numbers. The one that belongs to
-- us is the one in phone_numbers, and that is what names the organization.
--
-- Returns nothing for a number we do not hold, which is the correct answer:
-- a webhook for someone else's number is not ours to store, and guessing at an
-- organization would put another firm's message in a client's inbox.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION organization_for_number(raw text)
RETURNS TABLE (organization_id uuid, phone_number_id uuid, account_id uuid,
               location_id uuid, messaging_enabled boolean)
LANGUAGE sql STABLE AS $$
  SELECT n.organization_id, n.id, n.account_id, n.location_id, n.messaging_enabled
  FROM phone_numbers n
  WHERE n.e164 = normalize_e164(raw) AND n.active
  LIMIT 1
$$;

COMMENT ON FUNCTION organization_for_number(text) IS
  'For an inbound carrier webhook: which organization owns this number. '
  'Returns no row for a number we do not hold — do not store the message.';

-- -----------------------------------------------------------------------------
-- Finding or starting a text thread
--
-- A text conversation is one interaction holding many messages. An inbound
-- message either continues the open thread with that contact on that number, or
-- starts one. Without this each message would become its own interaction and
-- the Activity list would show a conversation as twenty separate rows.
--
-- A thread is considered the same conversation while messages keep arriving
-- within p_window. A reply three weeks later is a new conversation, which is
-- what a person would say about it too.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION find_or_start_text_thread(
  p_org uuid, p_number_id uuid, p_contact uuid, p_direction direction,
  p_from text, p_to text, p_occurred timestamptz,
  p_window interval DEFAULT '24 hours')
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_id uuid; v_account uuid; v_location uuid;
BEGIN
  SELECT i.id INTO v_id
  FROM interactions i
  WHERE i.organization_id = p_org
    AND i.channel = 'text'
    AND i.phone_number_id = p_number_id
    AND i.contact_id IS NOT DISTINCT FROM p_contact
    AND i.occurred_at > p_occurred - p_window
  ORDER BY i.occurred_at DESC
  LIMIT 1;

  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  SELECT n.account_id, n.location_id INTO v_account, v_location
    FROM phone_numbers n WHERE n.id = p_number_id;

  INSERT INTO interactions (organization_id, account_id, location_id, source,
                            channel, direction, phone_number_id,
                            from_e164, to_e164, occurred_at, disposition,
                            carrier, contact_id, handler_type,
                            attribution_method, attribution_confidence)
  VALUES (p_org, v_account, v_location, 'real', 'text', p_direction, p_number_id,
          p_from, p_to, p_occurred, 'connected', 'surge', p_contact, 'unknown',
          'unresolved', 'none')
  RETURNING id INTO v_id;

  RETURN v_id;
END $$;

COMMIT;

-- =============================================================================
-- Verification
--
--   SET app.is_internal = 'on';
--
--   -- every interaction now names its carrier
--   SELECT carrier, channel, source, count(*)
--   FROM interactions GROUP BY 1,2,3 ORDER BY 1,2,3;
--
--   -- a number cannot claim to text without a carrier
--   UPDATE phone_numbers SET messaging_enabled = true
--   WHERE external_ref = 'seed_main';
--   -- expect: violates phone_numbers_messaging_ck
--
--   -- the real thing
--   UPDATE phone_numbers
--      SET messaging_carrier = 'surge', messaging_enabled = true,
--          messaging_ported_at = now()
--   WHERE external_ref = 'seed_main';
--
--   -- what a Surge webhook would resolve
--   SELECT * FROM organization_for_number('(513) 555-0100');
--
--   -- and a number we do not hold returns nothing, correctly
--   SELECT * FROM organization_for_number('+12125550000');
-- =============================================================================
