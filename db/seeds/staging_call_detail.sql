-- =============================================================================
-- seed_staging_call_detail.sql
-- Staging data for the Activity DETAIL screen.
--
-- Runs after seed_staging_interactions.sql and fills what that one left empty:
-- the call-flow trace, the people on each call, and transcripts.
--
-- STAGING ONLY, and the transcripts are ILLUSTRATIVE — written to exercise the
-- screen, not taken from any real call. They are marked as such in
-- `corrected_by` on every segment so nobody downstream mistakes them for
-- evidence. No real family's words appear here.
--
-- Repeatable: clears its own rows before inserting.
--
-- WHAT IT COVERS. Seven call shapes, because the detail view renders each
-- differently: a straight answered call, a call through a menu, a transfer
-- between two people, a missed call, an abandoned call, a voicemail, and an
-- outbound call. Plus one spam call, which should produce almost no trace at
-- all — a flat row is a state the screen has to handle.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Clear a previous run
-- -----------------------------------------------------------------------------
DELETE FROM interaction_events
 WHERE external_call_ref LIKE 'seed_%';

DELETE FROM transcript_segments
 WHERE corrected_by LIKE 'staging seed%';

DELETE FROM interaction_participants
 WHERE role <> 'caller'
   AND interaction_id IN (SELECT id FROM interactions WHERE external_ref LIKE 'seed_%');

-- -----------------------------------------------------------------------------
-- Two more people, so a transfer has somewhere to go
--
-- A receptionist who answers and a director she transfers to. Without both, the
-- transfer flow has no second party and the screen cannot be built against it.
-- -----------------------------------------------------------------------------
INSERT INTO people (organization_id, full_name, person_type, status)
SELECT o.id, v.name, 'client_staff', 'active'
FROM organizations o
CROSS JOIN (VALUES ('Ruth Calder'), ('Tom Avery')) AS v(name)
WHERE o.code = 'DR'
ON CONFLICT DO NOTHING;

-- -----------------------------------------------------------------------------
-- Events attach by the carrier's call id, so give the seeded calls one
-- -----------------------------------------------------------------------------
UPDATE interactions SET external_call_ref = external_ref
 WHERE external_ref LIKE 'seed_%' AND external_call_ref IS NULL;

-- -----------------------------------------------------------------------------
-- Who was on each call
--
-- The caller rows already exist. These are the handlers — and on the transfer,
-- both the person who answered and the person it went to.
-- -----------------------------------------------------------------------------
INSERT INTO interaction_participants (organization_id, interaction_id, person_id, role)
SELECT i.organization_id, i.id, p.id, v.role
FROM interactions i
JOIN organizations o ON o.id = i.organization_id AND o.code = 'DR'
JOIN (VALUES
  ('seed_001','Ruth Calder','handler'),
  ('seed_002','Tom Avery',  'handler'),
  ('seed_003','Ruth Calder','handler'),
  ('seed_004','Tom Avery',  'handler'),
  ('seed_006','Ruth Calder','handler'),
  ('seed_007','Ruth Calder','handler'),
  ('seed_009','Tom Avery',  'handler'),
  ('seed_010','Ruth Calder','handler'),
  ('seed_011','Ruth Calder','handler'),
  ('seed_012','Ruth Calder','handler'),
  ('seed_014','Ruth Calder','handler'),
  ('seed_016','Ruth Calder','handler'),
  ('seed_017','Ruth Calder','handler'),
  -- The transfer: Ruth answered, Tom took it.
  ('seed_018','Ruth Calder','handler'),
  ('seed_018','Tom Avery',  'transferred_to'),
  ('seed_020','Tom Avery',  'handler'),
  ('seed_021','Tom Avery',  'handler'),
  ('seed_022','Ruth Calder','handler'),
  ('seed_023','Ruth Calder','handler'),
  ('seed_024','Tom Avery',  'handler'),
  ('seed_025','Tom Avery',  'handler'),
  ('seed_027','Ruth Calder','handler'),
  ('seed_028','Ruth Calder','handler')
) AS v(ref, person, role) ON v.ref = i.external_ref
JOIN people p ON p.organization_id = o.id AND p.full_name = v.person;

-- And point the interaction's own handler at the same person, so the list and
-- the detail view agree about who took the call.
UPDATE interactions i SET handler_person_id = p.id
FROM interaction_participants ip
JOIN people p ON p.id = ip.person_id
WHERE ip.interaction_id = i.id AND ip.role = 'handler'
  AND i.external_ref LIKE 'seed_%';

-- -----------------------------------------------------------------------------
-- The call-flow trace
--
-- Timings are relative to each call's own start, so the trace lines up with the
-- duration already on the interaction. Seconds are deliberately uneven — a
-- flow that ticks over in round numbers hides the spacing problems a real
-- timeline runs into.
-- -----------------------------------------------------------------------------
INSERT INTO interaction_events (
  organization_id, external_call_ref, interaction_id, event_type, occurred_at,
  direction, from_number, to_number, from_label, user_ref, person_id,
  status, transferred_to, payload)
SELECT
  i.organization_id, i.external_call_ref, i.id,
  v.evt::call_event_type,
  i.occurred_at + (v.offset_s || ' seconds')::interval,
  i.direction, i.from_e164, i.to_e164,
  COALESCE(c.full_name, c.business_name),
  CASE WHEN v.person <> '' THEN 'user_seed_' || lower(replace(v.person,' ','_')) END,
  p.id,
  NULLIF(v.status,''), NULLIF(v.xfer,''),
  CASE WHEN v.detail <> '' THEN jsonb_build_object('detail', v.detail)
       ELSE '{}'::jsonb END
FROM interactions i
JOIN organizations o ON o.id = i.organization_id AND o.code = 'DR'
LEFT JOIN contacts c ON c.id = i.contact_id
JOIN (VALUES
  -- Straight inbound, answered by the receptionist.
  ('seed_001','call.incoming',   0,  '', '',          '', ''),
  ('seed_001','call.ringing',    2,  'Ruth Calder','','', ''),
  ('seed_001','call.answered',   6,  'Ruth Calder','','', ''),
  ('seed_001','call.end',        412,'', 'completed','', ''),

  -- Outbound callback. Starts with initiated, not incoming.
  ('seed_006','call.initiated',  0,  'Ruth Calder','','', ''),
  ('seed_006','call.ringing',    3,  'Ruth Calder','','', ''),
  ('seed_006','call.answered',   9,  'Ruth Calder','','', ''),
  ('seed_006','call.end',        356,'', 'completed','', ''),

  -- Through a menu, then a transfer. The busiest trace, and the one the
  -- detail view most needs to render legibly.
  ('seed_018','call.incoming',    0,  '', '',          '', ''),
  ('seed_018','flow.menu_played', 2,  '', '',          '', 'Main menu'),
  ('seed_018','flow.key_pressed', 11, '', '',          '', 'Pressed 2 — arrangements'),
  ('seed_018','call.ringing',     13, 'Ruth Calder','','',''),
  ('seed_018','call.answered',    20, 'Ruth Calder','','',''),
  ('seed_018','call.transfer',    49, 'Ruth Calder','','Tom Avery',''),
  ('seed_018','call.ringing',     51, 'Tom Avery',  '','',''),
  ('seed_018','call.answered',    57, 'Tom Avery',  '','',''),
  ('seed_018','call.end',         88, '', 'completed','',''),

  -- Nobody picked up. Rang three people and ended.
  ('seed_005','call.incoming',    0,  '', '',          '', ''),
  ('seed_005','call.ringing',     2,  'Ruth Calder','','',''),
  ('seed_005','call.ringing',     2,  'Tom Avery',  '','',''),
  ('seed_005','call.end',         28, '', 'no-answer', '',''),

  -- Abandoned: the caller hung up while it was still ringing. Different from
  -- the one above, and the trace is what shows why.
  ('seed_015','call.incoming',    0,  '', '',          '', ''),
  ('seed_015','call.ringing',     3,  'Ruth Calder','','',''),
  ('seed_015','call.end',         14, '', 'no-answer', '','Caller hung up while ringing'),

  -- Voicemail, out of hours. Rang nobody; went straight to the box.
  ('seed_008','call.incoming',    0,  '', '',          '', ''),
  ('seed_008','flow.node_entered',1,  '', '',          '', 'After-hours schedule — closed'),
  ('seed_008','call.answered',    4,  '', '',          '', 'Voicemail greeting'),
  ('seed_008','voicemail.new',    58, '', '',          '', ''),
  ('seed_008','call.end',         64, '', 'voicemail', '',''),

  -- Spam. Almost no trace at all, which is itself a state to design for.
  ('seed_013','call.incoming',    0,  '', '',          '', ''),
  ('seed_013','call.end',         19, '', 'failed',    '','Blocked — known solicitor'),

  -- A queue, for the answering-service shape.
  ('seed_010','call.incoming',       0,  '', '',          '', ''),
  ('seed_010','queue.call.queued',   2,  '', '',          '', 'Front desk queue'),
  ('seed_010','queue.call.dispatched',8, 'Ruth Calder','','',''),
  ('seed_010','queue.call.answered', 14, 'Ruth Calder','','',''),
  ('seed_010','call.end',            142,'', 'completed', '','')
) AS v(ref, evt, offset_s, person, status, xfer, detail) ON v.ref = i.external_ref
LEFT JOIN people p ON p.organization_id = o.id AND p.full_name = NULLIF(v.person,'');

-- Recording and transcription events land after the call, not during it.
INSERT INTO interaction_events (organization_id, external_call_ref, interaction_id,
                                event_type, occurred_at, payload)
SELECT i.organization_id, i.external_call_ref, i.id, v.evt::call_event_type,
       i.ended_at + (v.offset_s || ' seconds')::interval, '{}'::jsonb
FROM interactions i
JOIN (VALUES
  ('seed_001','recording.available',               8),
  ('seed_001','recording.transcription.complete', 94),
  ('seed_001','recording.summary.complete',      121),
  ('seed_018','recording.available',               6),
  ('seed_018','recording.transcription.complete', 48),
  ('seed_006','recording.available',               7),
  ('seed_006','recording.transcription.complete', 88),
  ('seed_008','voicemail.transcription.complete', 31)
) AS v(ref, evt, offset_s) ON v.ref = i.external_ref;

-- -----------------------------------------------------------------------------
-- Transcripts — ILLUSTRATIVE
--
-- Written for this seed. Not a real call, not a real family, no real words.
-- Every segment carries that in `corrected_by` so it travels with the row
-- rather than living only in this comment.
--
-- Three calls: the first at-need call, the transfer, and the voicemail — which
-- is single-channel and so has no second speaker, a shape the screen has to
-- handle differently.
-- -----------------------------------------------------------------------------
INSERT INTO transcript_segments (organization_id, interaction_id, segment_order,
                                 starts_at_s, ends_at_s, speaker_label,
                                 person_id, contact_id, confidence,
                                 corrected_by, body)
SELECT i.organization_id, i.id, v.ord, v.starts, v.ends, v.speaker,
       p.id, CASE WHEN v.speaker = 'Caller' THEN i.contact_id END,
       v.conf,
       'staging seed — illustrative, not a real call',
       v.body
FROM interactions i
JOIN organizations o ON o.id = i.organization_id AND o.code = 'DR'
JOIN (VALUES
  -- seed_001 — the at-need call
  ('seed_001', 1,  0.0,   6.4,  'Agent',  'Ruth Calder', 0.97, 'Thank you for calling Dead Ringers, this is Ruth. How can I help you today?'),
  ('seed_001', 2,  6.9,  21.3,  'Caller', '',            0.94, 'Hi. My father passed away last night at Mercy and I''m not really sure what I''m supposed to do next.'),
  ('seed_001', 3, 21.8,  31.0,  'Agent',  'Ruth Calder', 0.96, 'I''m so sorry. We can take care of all of that for you. Can I start with your name?'),
  ('seed_001', 4, 31.4,  36.2,  'Caller', '',            0.95, 'Margaret Ellis. He was James Ellis.'),
  ('seed_001', 5, 36.7,  52.9,  'Agent',  'Ruth Calder', 0.96, 'Thank you, Margaret. And is the hospital holding him for now? We can arrange transport whenever you''re ready.'),
  ('seed_001', 6, 53.5,  68.1,  'Caller', '',            0.93, 'They said they could keep him until tomorrow. He wanted to be cremated, but we''d still like to have something for people to come to.'),
  ('seed_001', 7, 68.6,  89.4,  'Agent',  'Ruth Calder', 0.97, 'That''s very doable — cremation with a memorial service afterwards. Would you like to come in and sit down with one of our directors? We have Wednesday at two.'),
  ('seed_001', 8, 90.0,  95.2,  'Caller', '',            0.95, 'Wednesday would be good. Thank you.'),

  -- seed_018 — the transfer, two handlers
  ('seed_018', 1,  0.0,   5.8,  'Agent',  'Ruth Calder', 0.97, 'Dead Ringers, this is Ruth.'),
  ('seed_018', 2,  6.2,  17.9,  'Caller', '',            0.92, 'Hi Ruth, it''s Margaret Ellis again. I had a question about the urn we picked — is it possible to change it?'),
  ('seed_018', 3, 18.4,  29.0,  'Agent',  'Ruth Calder', 0.95, 'Let me get Tom for you, he handled your arrangement. Can I put you on hold for just a moment?'),
  ('seed_018', 4, 29.4,  31.1,  'Caller', '',            0.96, 'Of course.'),
  ('seed_018', 5, 57.0,  63.4,  'Agent',  'Tom Avery',   0.97, 'Margaret, hi, it''s Tom. Ruth says you''d like to look at the urns again?'),
  ('seed_018', 6, 63.9,  78.2,  'Caller', '',            0.94, 'My brother thought the wooden one might suit him better. Is it too late?'),
  ('seed_018', 7, 78.7,  87.5,  'Agent',  'Tom Avery',   0.96, 'Not at all. Nothing''s final until Friday. I''ll bring both out when you come in.'),

  -- seed_008 — a voicemail. Single channel, one speaker, no agent.
  ('seed_008', 1,  4.0,  11.2,  'Caller', '',            0.91, 'Hello, my name is Raymond Brightwater.'),
  ('seed_008', 2, 11.6,  34.8,  'Caller', '',            0.89, 'I''m calling because I''d like to get my own arrangements sorted out ahead of time, so my daughter doesn''t have to deal with it.'),
  ('seed_008', 3, 35.2,  52.0,  'Caller', '',            0.90, 'My number is 513-555-1230. Any time during the day is fine. Thank you.')
) AS v(ref, ord, starts, ends, speaker, person, conf, body) ON v.ref = i.external_ref
LEFT JOIN people p ON p.organization_id = o.id AND p.full_name = NULLIF(v.person,'');

-- The transcript body on the interaction itself, assembled from the segments.
UPDATE interactions i SET transcript = t.full_text
FROM (
  SELECT interaction_id,
         string_agg(speaker_label || ': ' || body, E'\n' ORDER BY segment_order)
  FROM transcript_segments
  WHERE corrected_by LIKE 'staging seed%'
  GROUP BY interaction_id
) t(interaction_id, full_text)
WHERE i.id = t.interaction_id;

COMMIT;

-- =============================================================================
-- What landed
--
--   SET app.is_internal = 'on';
--
--   -- every seeded call, and how much trace each has
--   SELECT i.external_ref, i.disposition,
--          count(e.id) AS events,
--          count(DISTINCT ip.person_id) AS people,
--          (SELECT count(*) FROM transcript_segments s WHERE s.interaction_id = i.id) AS segments
--   FROM interactions i
--   LEFT JOIN interaction_events e ON e.interaction_id = i.id
--   LEFT JOIN interaction_participants ip ON ip.interaction_id = i.id
--                                       AND ip.person_id IS NOT NULL
--   WHERE i.external_ref LIKE 'seed_%'
--   GROUP BY i.id, i.external_ref, i.disposition
--   ORDER BY events DESC, i.external_ref;
--
--   -- the transfer, read as the detail screen will render it
--   SELECT * FROM call_flow(
--     (SELECT id FROM interactions WHERE external_ref = 'seed_018'));
--
--   -- who was rung on the call nobody answered
--   SELECT * FROM who_was_rung(
--     (SELECT id FROM interactions WHERE external_ref = 'seed_005'));
--
--   -- a transcript, with its speakers resolved
--   SELECT segment_order, starts_at_s, speaker_label,
--          COALESCE(p.full_name, c.full_name) AS who, body
--   FROM transcript_segments s
--   LEFT JOIN people p   ON p.id = s.person_id
--   LEFT JOIN contacts c ON c.id = s.contact_id
--   WHERE s.interaction_id = (SELECT id FROM interactions WHERE external_ref = 'seed_001')
--   ORDER BY segment_order;
--
-- Removing it
--
--   DELETE FROM interaction_events    WHERE external_call_ref LIKE 'seed_%';
--   DELETE FROM transcript_segments   WHERE corrected_by LIKE 'staging seed%';
--   DELETE FROM interaction_participants WHERE role <> 'caller'
--     AND interaction_id IN (SELECT id FROM interactions WHERE external_ref LIKE 'seed_%');
-- =============================================================================
