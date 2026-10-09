-- =============================================================================
-- seed_staging_call_flow_coverage.sql
-- Staging data: a call-flow trace for every seeded CALL that lacks one.
--
-- Runs after seed_staging_interactions.sql and seed_staging_call_detail.sql.
-- That seed traced eight calls; this one traces the other eighteen, so a
-- connected call never sits trace-less next to one with eleven steps.
--
-- STAGING ONLY. Built on the same vocabulary — Dial Stack's own event names,
-- rendered by call_flow() (migration 030) — and on the same timing rule: every
-- offset is from the call's own start, `call.answered` lands on the row's
-- answer_seconds and `call.end` on its duration_seconds, so the trace and the
-- interaction never disagree.
--
-- Repeatable: clears its own rows (by call ref, listed below) before inserting.
-- seed_staging_call_detail.sql clears every 'seed_%' event when it runs, so
-- re-run this file after that one.
--
-- WHAT IT ADDS. The shapes the first eight didn't cover:
--   direct line, no menu ....... seed_011, seed_014, seed_017, seed_027
--   ring group, one picks up ... seed_012 (two ring), seed_016, seed_021, seed_028
--   group → voicemail .......... seed_026 (nobody answers; caller hangs up at
--                                the greeting — the row is no_answer, so no
--                                message is left)
--   menu → operator ............ seed_023
--   tracking-number routing .... seed_022
--   outbound ................... seed_002, seed_009, seed_020
--   outbound, no answer ........ seed_019
--   outbound, their voicemail .. seed_025
--   mobile app + park/retrieve . seed_024
--   transfer fails, comes back . seed_004
--
-- TEXTS GET NO EVENTS. seed_003 and seed_007 are deliberately left out: Dial
-- Stack's event surface (call_event_type, migration 025) has no message
-- events at all. A text's history is its `messages` rows, which the
-- interactions seed already writes. An empty call flow is the honest state for
-- a text; the detail screen should show the thread instead.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Clear a previous run — only this file's calls
-- -----------------------------------------------------------------------------
DELETE FROM interaction_events
 WHERE external_call_ref IN (
   'seed_002','seed_004','seed_009','seed_011','seed_012','seed_014',
   'seed_016','seed_017','seed_019','seed_020','seed_021','seed_022',
   'seed_023','seed_024','seed_025','seed_026','seed_027','seed_028');

-- -----------------------------------------------------------------------------
-- A third member of the front desk, so a ring group rings more than two people
--
-- Guarded by NOT EXISTS rather than ON CONFLICT: people has no unique key on a
-- name, so ON CONFLICT would never fire and a re-run would add her again.
-- -----------------------------------------------------------------------------
INSERT INTO people (organization_id, full_name, person_type, status)
SELECT o.id, 'Lena Marsh', 'client_staff', 'active'
FROM organizations o
WHERE o.code = 'DR'
  AND NOT EXISTS (SELECT 1 FROM people p
                   WHERE p.organization_id = o.id AND p.full_name = 'Lena Marsh');

-- Events attach by the carrier's call id. The call-detail seed already does
-- this; repeated here so this file doesn't depend on that one's side effects.
UPDATE interactions SET external_call_ref = external_ref
 WHERE external_ref LIKE 'seed_%' AND external_call_ref IS NULL;

-- -----------------------------------------------------------------------------
-- The traces
--
-- Columns as in the call-detail seed, plus park_slot. Handlers match the
-- handler_person_id each call already carries, so the list, the detail header
-- and the trace name the same person.
-- -----------------------------------------------------------------------------
INSERT INTO interaction_events (
  organization_id, external_call_ref, interaction_id, event_type, occurred_at,
  direction, from_number, to_number, from_label, user_ref, person_id,
  status, transferred_to, park_slot, payload)
SELECT
  i.organization_id, i.external_call_ref, i.id,
  v.evt::call_event_type,
  i.occurred_at + (v.offset_s || ' seconds')::interval,
  i.direction, i.from_e164, i.to_e164,
  COALESCE(c.full_name, c.business_name),
  CASE WHEN v.person <> '' THEN 'user_seed_' || lower(replace(v.person,' ','_')) END,
  p.id,
  NULLIF(v.status,''), NULLIF(v.xfer,''), v.slot,
  CASE WHEN v.detail <> '' THEN jsonb_build_object('detail', v.detail)
       ELSE '{}'::jsonb END
FROM interactions i
JOIN organizations o ON o.id = i.organization_id AND o.code = 'DR'
LEFT JOIN contacts c ON c.id = i.contact_id
JOIN (VALUES
  -- ---- Direct line, no menu: one person rings, picks up ----------------------

  -- Spring Grove confirming a committal. Ruth's line, answered in two seconds.
  ('seed_011','call.incoming',   0,  '',           '',          '', NULL::smallint, ''),
  ('seed_011','call.ringing',    1,  'Ruth Calder','',          '', NULL, ''),
  ('seed_011','call.answered',   2,  'Ruth Calder','',          '', NULL, ''),
  ('seed_011','call.end',        97, '',           'completed', '', NULL, ''),

  -- Wrong number. Short, and the trace is short too.
  ('seed_014','call.incoming',   0,  '',           '',          '', NULL, ''),
  ('seed_014','call.ringing',    1,  'Ruth Calder','',          '', NULL, ''),
  ('seed_014','call.answered',   3,  'Ruth Calder','',          '', NULL, ''),
  ('seed_014','call.end',        31, '',           'completed', '', NULL, ''),

  ('seed_017','call.incoming',   0,  '',           '',          '', NULL, ''),
  ('seed_017','call.ringing',    2,  'Ruth Calder','',          '', NULL, ''),
  ('seed_017','call.answered',   5,  'Ruth Calder','',          '', NULL, ''),
  ('seed_017','call.end',        128,'',           'completed', '', NULL, ''),

  ('seed_027','call.incoming',   0,  '',           '',          '', NULL, ''),
  ('seed_027','call.ringing',    1,  'Ruth Calder','',          '', NULL, ''),
  ('seed_027','call.answered',   2,  'Ruth Calder','',          '', NULL, ''),
  ('seed_027','call.end',        143,'',           'completed', '', NULL, ''),

  -- ---- Ring group: several ring at once, one picks up ------------------------
  -- call.ringing fires once per person, so a group is several rows at the same
  -- instant — who_was_rung() reads exactly this.

  -- Vendor call. A two-person group; Ruth takes it.
  ('seed_012','call.incoming',   0,  '',           '',          '', NULL, ''),
  ('seed_012','call.ringing',    1,  'Ruth Calder','',          '', NULL, ''),
  ('seed_012','call.ringing',    1,  'Tom Avery',  '',          '', NULL, ''),
  ('seed_012','call.answered',   4,  'Ruth Calder','',          '', NULL, ''),
  ('seed_012','call.end',        54, '',           'completed', '', NULL, ''),

  -- Theresa calling back after hanging up. The full front desk rings.
  ('seed_016','call.incoming',   0,  '',           '',          '', NULL, ''),
  ('seed_016','call.ringing',    1,  'Ruth Calder','',          '', NULL, ''),
  ('seed_016','call.ringing',    1,  'Tom Avery',  '',          '', NULL, ''),
  ('seed_016','call.ringing',    1,  'Lena Marsh', '',          '', NULL, ''),
  ('seed_016','call.answered',   4,  'Ruth Calder','',          '', NULL, ''),
  ('seed_016','call.end',        204,'',           'completed', '', NULL, ''),

  -- Same group, and this time Tom is the one who picks up.
  ('seed_021','call.incoming',   0,  '',           '',          '', NULL, ''),
  ('seed_021','call.ringing',    1,  'Ruth Calder','',          '', NULL, ''),
  ('seed_021','call.ringing',    1,  'Tom Avery',  '',          '', NULL, ''),
  ('seed_021','call.ringing',    1,  'Lena Marsh', '',          '', NULL, ''),
  ('seed_021','call.answered',   4,  'Tom Avery',  '',          '', NULL, ''),
  ('seed_021','call.end',        311,'',           'completed', '', NULL, ''),

  ('seed_028','call.incoming',   0,  '',           '',          '', NULL, ''),
  ('seed_028','call.ringing',    1,  'Ruth Calder','',          '', NULL, ''),
  ('seed_028','call.ringing',    1,  'Tom Avery',  '',          '', NULL, ''),
  ('seed_028','call.answered',   4,  'Ruth Calder','',          '', NULL, ''),
  ('seed_028','call.end',        221,'',           'completed', '', NULL, ''),

  -- ---- Group → voicemail: nobody answers ------------------------------------
  -- The whole group rings out, the call falls through to the greeting, and
  -- the caller hangs up during it. The row is no_answer, so no message.
  ('seed_026','call.incoming',    0,  '',           '',          '', NULL, ''),
  ('seed_026','flow.node_entered',1,  '',           '',          '', NULL, 'Google Business Profile line — front desk group'),
  ('seed_026','call.ringing',     1,  'Ruth Calder','',          '', NULL, ''),
  ('seed_026','call.ringing',     1,  'Tom Avery',  '',          '', NULL, ''),
  ('seed_026','call.ringing',     1,  'Lena Marsh', '',          '', NULL, ''),
  ('seed_026','flow.node_entered',26, '',           '',          '', NULL, 'Nobody in the group picked up — sent to voicemail'),
  ('seed_026','call.answered',    27, '',           '',          '', NULL, 'Voicemail greeting'),
  ('seed_026','call.end',         37, '',           'no-answer', '', NULL, 'Hung up during the greeting — no message left'),

  -- ---- Menu, then the operator ----------------------------------------------
  -- answer_seconds is 8, so the menu is short and the caller doesn't wait.
  ('seed_023','call.incoming',    0,  '',           '',          '', NULL, ''),
  ('seed_023','flow.menu_played', 1,  '',           '',          '', NULL, 'Main menu'),
  ('seed_023','flow.key_pressed', 6,  '',           '',          '', NULL, 'Pressed 0 — operator'),
  ('seed_023','call.ringing',     6,  'Ruth Calder','',          '', NULL, ''),
  ('seed_023','call.answered',    8,  'Ruth Calder','',          '', NULL, ''),
  ('seed_023','call.end',         76, '',           'completed', '', NULL, ''),

  -- ---- Routed by the number dialled -----------------------------------------
  -- The hospice called the Google Business Profile tracking number, which skips
  -- the menu and goes straight to the front desk.
  ('seed_022','call.incoming',    0,  '',           '',          '', NULL, ''),
  ('seed_022','flow.node_entered',1,  '',           '',          '', NULL, 'Google Business Profile line — straight to the front desk'),
  ('seed_022','call.ringing',     1,  'Ruth Calder','',          '', NULL, ''),
  ('seed_022','call.answered',    3,  'Ruth Calder','',          '', NULL, ''),
  ('seed_022','call.end',         119,'',           'completed', '', NULL, ''),

  -- ---- Outbound -------------------------------------------------------------
  -- Same shape as seed_006: initiated, not incoming; the ringing row is the
  -- placing user's leg.
  ('seed_002','call.initiated',   0,  'Tom Avery',  '',          '', NULL, ''),
  ('seed_002','call.ringing',     1,  'Tom Avery',  '',          '', NULL, ''),
  ('seed_002','call.answered',    3,  'Tom Avery',  '',          '', NULL, ''),
  ('seed_002','call.end',         187,'',           'completed', '', NULL, ''),

  ('seed_009','call.initiated',   0,  'Tom Avery',  '',          '', NULL, ''),
  ('seed_009','call.ringing',     2,  'Tom Avery',  '',          '', NULL, ''),
  ('seed_009','call.answered',    5,  'Tom Avery',  '',          '', NULL, ''),
  ('seed_009','call.end',         298,'',           'completed', '', NULL, ''),

  ('seed_020','call.initiated',   0,  'Tom Avery',  '',          '', NULL, ''),
  ('seed_020','call.ringing',     1,  'Tom Avery',  '',          '', NULL, ''),
  ('seed_020','call.answered',    6,  'Tom Avery',  '',          '', NULL, ''),
  ('seed_020','call.end',         162,'',           'completed', '', NULL, ''),

  -- Outbound, no answer: the first try at reaching Jim. Rang out.
  -- Placed by the row's own handler (handler_person_id, set by the
  -- interactions seed).
  ('seed_019','call.initiated',   0,  'Mandie Hungarland','',    '', NULL, ''),
  ('seed_019','call.ringing',     1,  'Mandie Hungarland','',    '', NULL, ''),
  ('seed_019','call.end',         45, '',           'no-answer', '', NULL, ''),

  -- Outbound to Theresa's voicemail. Her mailbox answers, not a person, so the
  -- answered row names no one.
  ('seed_025','call.initiated',   0,  'Tom Avery',  '',          '', NULL, ''),
  ('seed_025','call.ringing',     1,  'Tom Avery',  '',          '', NULL, ''),
  ('seed_025','call.answered',    16, '',           '',          '', NULL, 'Their voicemail picked up'),
  ('seed_025','call.end',         52, '',           'completed', '', NULL, ''),

  -- ---- Mobile app, then park and retrieve -----------------------------------
  -- Tom is away from his desk: the call wakes his mobile app, he answers there,
  -- parks it, and picks it back up at his desk 34 seconds later. hold_seconds
  -- is set to match below.
  ('seed_024','call.incoming',          0,  '',         '',          '', NULL, ''),
  ('seed_024','call.ringing',           1,  'Tom Avery','',          '', NULL, ''),
  ('seed_024','call.mobile_push_wakeup',1,  'Tom Avery','',          '', NULL, ''),
  ('seed_024','call.answered',          5,  'Tom Avery','',          '', NULL, ''),
  ('seed_024','call.parked',            58, 'Tom Avery','',          '', 701,  ''),
  ('seed_024','call.unparked',          92, 'Tom Avery','',          '', 701,  ''),
  ('seed_024','call.end',               265,'',         'completed', '', NULL, ''),

  -- ---- A transfer that fails and comes back ---------------------------------
  -- Tom tries to hand Jim to Ruth for the veterans' paperwork. Ruth doesn't
  -- pick up, the transfer returns, and Tom takes the call back. The 22 seconds
  -- from transfer to re-answer are the row's hold_seconds; the attempt is its
  -- one transfer.
  ('seed_004','call.incoming',    0,  '',           '',          '', NULL, ''),
  ('seed_004','call.ringing',     1,  'Tom Avery',  '',          '', NULL, ''),
  ('seed_004','call.answered',    4,  'Tom Avery',  '',          '', NULL, ''),
  ('seed_004','call.transfer',    62, 'Tom Avery',  '',          'Ruth Calder', NULL, ''),
  ('seed_004','call.ringing',     63, 'Ruth Calder','',          '', NULL, ''),
  ('seed_004','flow.node_entered',83, '',           '',          '', NULL, 'Transfer not picked up — returned to Tom Avery'),
  ('seed_004','call.ringing',     83, 'Tom Avery',  '',          '', NULL, ''),
  ('seed_004','call.answered',    84, 'Tom Avery',  '',          '', NULL, ''),
  ('seed_004','call.end',         233,'',           'completed', '', NULL, '')
) AS v(ref, evt, offset_s, person, status, xfer, slot, detail) ON v.ref = i.external_ref
-- One person per name even if a seed has run twice and left a duplicate.
LEFT JOIN LATERAL (
  SELECT pp.id FROM people pp
  WHERE pp.organization_id = o.id AND pp.full_name = NULLIF(v.person,'')
  ORDER BY pp.id LIMIT 1
) p ON true;

-- Recording and transcription events land after the call, not during it.
-- Not every call gets the full set: short and trade calls stop at the
-- recording, which is the variety a real account shows.
INSERT INTO interaction_events (organization_id, external_call_ref, interaction_id,
                                event_type, occurred_at, payload)
SELECT i.organization_id, i.external_call_ref, i.id, v.evt::call_event_type,
       i.ended_at + (v.offset_s || ' seconds')::interval, '{}'::jsonb
FROM interactions i
JOIN organizations o ON o.id = i.organization_id AND o.code = 'DR'
JOIN (VALUES
  ('seed_002','recording.available',               7),
  ('seed_002','recording.transcription.complete', 71),
  ('seed_004','recording.available',               9),
  ('seed_004','recording.transcription.complete',102),
  ('seed_009','recording.available',               8),
  ('seed_009','recording.transcription.complete',117),
  ('seed_009','recording.summary.complete',      140),
  ('seed_012','recording.available',               6),
  ('seed_016','recording.available',               7),
  ('seed_016','recording.transcription.complete', 83),
  ('seed_016','recording.summary.complete',      109),
  ('seed_017','recording.available',               6),
  ('seed_020','recording.available',               8),
  ('seed_020','recording.transcription.complete', 64),
  ('seed_021','recording.available',               9),
  ('seed_021','recording.transcription.complete',131),
  ('seed_021','recording.summary.complete',      158),
  ('seed_022','recording.available',               6),
  ('seed_023','recording.available',               5),
  ('seed_024','recording.available',               8),
  ('seed_024','recording.transcription.complete',119),
  ('seed_024','recording.summary.complete',      144),
  ('seed_025','recording.available',               6),
  ('seed_027','recording.available',               5),
  ('seed_028','recording.available',               7),
  ('seed_028','recording.transcription.complete', 96),
  ('seed_028','recording.summary.complete',      118)
) AS v(ref, evt, offset_s) ON v.ref = i.external_ref;

-- The park holds the caller for 34 seconds; the interactions seed has no hold
-- on this call. Set it so the trace and the call's stats agree.
UPDATE interactions SET hold_seconds = 34
 WHERE external_ref = 'seed_024'
   AND organization_id = (SELECT id FROM organizations WHERE code = 'DR');

COMMIT;

-- =============================================================================
-- What landed
--
--   SET app.is_internal = 'on';
--
--   -- every seeded interaction and its trace length. Expect events on every
--   -- call; the two texts (seed_003, seed_007) stay at zero by design.
--   SELECT i.external_ref, i.channel, i.direction, i.disposition,
--          (SELECT count(*) FROM interaction_events e WHERE e.interaction_id = i.id) AS events
--   FROM interactions i
--   WHERE i.external_ref LIKE 'seed_%'
--   ORDER BY events, i.external_ref;
--
--   -- real interactions still without a trace (should be the two texts, plus
--   -- any call placed from the softphone that its webhooks haven't covered)
--   SELECT i.id, i.external_ref, i.channel, i.disposition, i.occurred_at
--   FROM interactions i
--   WHERE i.source = 'real'
--     AND NOT EXISTS (SELECT 1 FROM interaction_events e WHERE e.interaction_id = i.id)
--   ORDER BY i.occurred_at;
--
--   -- a ring group: three rung, one answered
--   SELECT * FROM who_was_rung(
--     (SELECT id FROM interactions WHERE external_ref = 'seed_016'));
--
--   -- the failed transfer, read as the detail screen will render it
--   SELECT * FROM call_flow(
--     (SELECT id FROM interactions WHERE external_ref = 'seed_004'));
--   -- expect: Transferred — Ruth Calder; Rang — Ruth Calder;
--   --         Routed — Transfer not picked up — returned to Tom Avery;
--   --         Rang — Tom Avery; Answered — Tom Avery
--
--   -- the park: Parked — slot 701 at 58s, Picked back up — slot 701 at 92s
--   SELECT * FROM call_flow(
--     (SELECT id FROM interactions WHERE external_ref = 'seed_024'));
--
-- Removing it
--
--   DELETE FROM interaction_events WHERE external_call_ref IN (
--     'seed_002','seed_004','seed_009','seed_011','seed_012','seed_014',
--     'seed_016','seed_017','seed_019','seed_020','seed_021','seed_022',
--     'seed_023','seed_024','seed_025','seed_026','seed_027','seed_028');
--   UPDATE interactions SET hold_seconds = 0 WHERE external_ref = 'seed_024';
-- =============================================================================
