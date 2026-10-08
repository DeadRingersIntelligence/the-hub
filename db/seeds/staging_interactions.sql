-- =============================================================================
-- seed_staging_interactions.sql
-- Staging data for building the HelloPhone Activity list and contact detail.
--
-- 28 interactions across two weeks for one organization, shaped like real
-- traffic rather than like a test fixture: inbound and outbound, connected and
-- missed, voicemail, abandoned, two text threads, a wrong number, a vendor, a
-- solicitation, and a family whose calls span a case.
--
-- STAGING ONLY. Every row is marked with the external_ref prefix 'seed_' so the
-- whole set can be removed in one statement — see the end of this file.
--
-- Repeatable: running it twice replaces the data rather than duplicating it.
--
-- WHICH ORGANIZATION. Dead Ringers (code 'DR'), because that is where the
-- sandbox Dial Stack account and Mandie's seat already point. Calls placed from
-- the softphone during development will land alongside these, which is the
-- behaviour you want while building — one list, real and seeded together.
--
-- WHAT IT IS FOR. Every state the Activity list has to render: a row that
-- connected and one that did not, a voicemail with a summary, a missed call
-- followed by a callback, a text thread, calls attached to a contact with two
-- numbers, and three calls belonging to one case. Build the row once against
-- this rather than against whatever happens to exist.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Clear any previous run
-- -----------------------------------------------------------------------------
DELETE FROM interactions
 WHERE external_ref LIKE 'seed_%'
   AND organization_id = (SELECT id FROM organizations WHERE code = 'DR');

DELETE FROM contacts
 WHERE notes = 'staging seed'
   AND organization_id = (SELECT id FROM organizations WHERE code = 'DR');

DELETE FROM cases
 WHERE external_case_id LIKE 'seed_%'
   AND organization_id = (SELECT id FROM organizations WHERE code = 'DR');

DELETE FROM decedents
 WHERE organization_id = (SELECT id FROM organizations WHERE code = 'DR')
   AND last_name IN ('Ellis', 'Novak', 'Brightwater');

DELETE FROM phone_numbers
 WHERE external_ref LIKE 'seed_%';

-- -----------------------------------------------------------------------------
-- A location and the firm's own numbers
-- -----------------------------------------------------------------------------
INSERT INTO locations (organization_id, name, location_type, funeral_rule_applies,
                       city, state)
SELECT id, 'Dead Ringers (sandbox)', 'funeral_home', true, 'Cincinnati', 'OH'
FROM organizations WHERE code = 'DR'
ON CONFLICT DO NOTHING;

INSERT INTO phone_numbers (organization_id, account_id, location_id, e164, display,
                           area_code, purpose, service_line, answered_as,
                           carrier, external_ref, active)
SELECT o.id, a.id, l.id, v.e164, v.display, v.ac, v.purpose::number_purpose,
       'funeral', 'Dead Ringers', 'dial_stack', v.ref, true
FROM organizations o
JOIN accounts  a ON a.organization_id = o.id
JOIN locations l ON l.organization_id = o.id AND l.name = 'Dead Ringers (sandbox)'
CROSS JOIN (VALUES
  ('+15135550100', '(513) 555-0100', '513', 'client_line', 'seed_main'),
  ('+15135550144', '(513) 555-0144', '513', 'tracking',    'seed_gmb')
) AS v(e164, display, ac, purpose, ref)
WHERE o.code = 'DR';

-- -----------------------------------------------------------------------------
-- Contacts
--
-- A spread of the kinds a firm actually hears from: families, a hospice, a
-- cemetery, a vendor, a solicitor, a wrong number. Margaret has two numbers,
-- which is what the Activity list needs to prove it matches on either.
-- -----------------------------------------------------------------------------
INSERT INTO contacts (organization_id, contact_kind, full_name, business_name,
                      email, first_seen_at, source_channel, notes)
SELECT o.id, v.kind::contact_kind, v.full_name, v.business, v.email,
       v.seen::timestamptz, v.channel::marketing_channel, 'staging seed'
FROM organizations o
CROSS JOIN (VALUES
  ('individual','Margaret Ellis',   NULL,                  'margaret.ellis@example.com','2026-09-22T09:14:00Z','organic_search'),
  ('individual','Jim Ellis',        NULL,                  NULL,                        '2026-09-22T15:40:00Z','organic_search'),
  ('individual','Dana Novak',       NULL,                  'dnovak@example.com',        '2026-09-24T11:02:00Z','google_ads'),
  ('individual','Raymond Brightwater',NULL,                NULL,                        '2026-09-25T08:30:00Z','organic_search'),
  ('individual','Theresa Vaughn',   NULL,                  NULL,                        '2026-09-28T13:12:00Z','referral'),
  ('individual','Carl Whitmore',    NULL,                  NULL,                        '2026-09-29T10:05:00Z','organic_search'),
  ('business',  'Alice Reyes',      'Mercy Hospice',       'areyes@example.com',        '2026-09-23T07:45:00Z','referral'),
  ('business',  'Dale Kerr',        'Spring Grove Cemetery',NULL,                       '2026-09-26T14:20:00Z','organic_search'),
  ('business',  NULL,               'Buckeye Casket Supply',NULL,                       '2026-09-23T16:10:00Z','organic_search'),
  ('business',  NULL,               'Unknown caller',      NULL,                        '2026-09-30T11:48:00Z','organic_search')
) AS v(kind, full_name, business, email, seen, channel)
WHERE o.code = 'DR';

-- Margaret holds two numbers — the case the matching logic has to get right.
INSERT INTO contact_phones (organization_id, contact_id, e164, label, is_primary, added_by)
SELECT c.organization_id, c.id, v.e164, v.label::phone_label, v.primary_, 'staging seed'
FROM contacts c
JOIN organizations o ON o.id = c.organization_id AND o.code = 'DR'
JOIN (VALUES
  ('Margaret Ellis',      '+15135551201', 'mobile', true),
  ('Margaret Ellis',      '+15135551202', 'home',   false),
  ('Jim Ellis',           '+15135551210', 'mobile', true),
  ('Dana Novak',          '+15135551220', 'mobile', true),
  ('Raymond Brightwater', '+15135551230', 'home',   true),
  ('Theresa Vaughn',      '+15135551240', 'mobile', true),
  ('Carl Whitmore',       '+15135551250', 'mobile', true),
  ('Alice Reyes',         '+15135551260', 'work',   true),
  ('Dale Kerr',           '+15135551270', 'work',   true)
) AS v(name, e164, label, primary_) ON v.name = c.full_name
WHERE c.notes = 'staging seed';

INSERT INTO contact_phones (organization_id, contact_id, e164, label, is_primary, added_by)
SELECT c.organization_id, c.id, v.e164, 'main'::phone_label, true, 'staging seed'
FROM contacts c
JOIN organizations o ON o.id = c.organization_id AND o.code = 'DR'
JOIN (VALUES
  ('Buckeye Casket Supply', '+18005551280'),
  ('Unknown caller',        '+18885551290')
) AS v(name, e164) ON v.name = c.business_name
WHERE c.notes = 'staging seed';

-- -----------------------------------------------------------------------------
-- Two decedents and two cases
--
-- The Ellis case is the one worth building against: a daughter calls, is called
-- back, texts, and the arrangement is set — four interactions, one case.
-- -----------------------------------------------------------------------------
INSERT INTO decedents (organization_id, first_name, last_name, date_of_death, status)
SELECT id, v.first, v.last, v.dod::date, v.st::decedent_status
FROM organizations o, (VALUES
  ('James',   'Ellis',       '2026-09-22', 'deceased'),
  ('Helen',   'Novak',       '2026-09-24', 'deceased'),
  ('Raymond', 'Brightwater', NULL,         'pre_need_subject')
) AS v(first, last, dod, st)
WHERE o.code = 'DR' AND o.id = id;

INSERT INTO cases (organization_id, location_id, need_type, opened_on,
                   external_case_id, source_system)
SELECT o.id, l.id, v.need::case_need_type, v.opened::date, v.ref, 'staging seed'
FROM organizations o
JOIN locations l ON l.organization_id = o.id AND l.name = 'Dead Ringers (sandbox)'
CROSS JOIN (VALUES
  ('at_need', '2026-09-22', 'seed_case_ellis'),
  ('at_need', '2026-09-24', 'seed_case_novak')
) AS v(need, opened, ref)
WHERE o.code = 'DR';

INSERT INTO case_contacts (case_id, contact_id, role, is_primary)
SELECT k.id, c.id, v.role, v.primary_
FROM cases k
JOIN organizations o ON o.id = k.organization_id AND o.code = 'DR'
JOIN contacts c ON c.organization_id = o.id AND c.notes = 'staging seed'
JOIN (VALUES
  ('seed_case_ellis', 'Margaret Ellis', 'daughter', true),
  ('seed_case_ellis', 'Jim Ellis',      'son',      false),
  ('seed_case_novak', 'Dana Novak',     'daughter', true)
) AS v(ref, name, role, primary_)
  ON v.ref = k.external_case_id AND v.name = c.full_name;

-- -----------------------------------------------------------------------------
-- The interactions
--
-- Ordered oldest first so the Activity list has something to sort. Durations,
-- answer times and hold times are plausible rather than round: a seed of tidy
-- numbers hides the formatting problems a real list runs into.
-- -----------------------------------------------------------------------------
INSERT INTO interactions (
  organization_id, account_id, location_id, source, channel, direction,
  service_line, phone_number_id, from_e164, to_e164,
  handler_person_id, handler_type, attribution_method, attribution_confidence,
  occurred_at, ended_at, duration_seconds, disposition,
  telemetry_status, answer_seconds, hold_seconds, transfer_count,
  qualified, unqualified_reason, contact_id, case_id, is_converting,
  summary, external_ref)
SELECT
  o.id, a.id, l.id, 'real',
  v.channel::interaction_channel, v.dir::direction, 'funeral',
  n.id, v.from_e164, v.to_e164,
  -- An unresolved call cannot claim a person: the handler is set only where
  -- the call was actually attributed to someone.
  CASE WHEN v.handled THEN p.id END,
  CASE WHEN v.handled THEN 'client_staff' ELSE 'unknown' END::handler_type,
  CASE WHEN v.handled THEN 'named_seat'   ELSE 'unresolved' END::attribution_method,
  CASE WHEN v.handled THEN 'certain'      ELSE 'none' END::attribution_confidence,
  v.occurred::timestamptz,
  CASE WHEN v.secs IS NOT NULL
       THEN v.occurred::timestamptz + (v.secs || ' seconds')::interval END,
  v.secs, v.disp::disposition,
  'captured', v.answer_s, v.hold_s, v.transfers,
  v.qualified, v.unqual,
  c.id, k.id, v.converting,
  v.summary, v.ref
FROM organizations o
JOIN accounts  a ON a.organization_id = o.id
JOIN locations l ON l.organization_id = o.id AND l.name = 'Dead Ringers (sandbox)'
LEFT JOIN people p ON p.organization_id = o.id AND p.full_name = 'Mandie Hungarland'
CROSS JOIN (VALUES
  -- The Ellis case. A daughter calls at 9am the morning her father died.
  ('seed_001','call','inbound', '+15135551201','+15135550100','2026-09-22T09:14:00Z', 412,'connected', 6, 0,0,true,NULL,'Margaret Ellis','seed_case_ellis',true,  true, 'Margaret Ellis called about her father James, who died overnight at Mercy. Discussed cremation with a memorial service. Arrangement conference set for Wednesday 2pm.'),
  ('seed_002','call','outbound','+15135550100','+15135551201','2026-09-22T11:30:00Z', 187,'connected', 3, 0,0,true,NULL,'Margaret Ellis','seed_case_ellis',false, true, 'Called Margaret back with the price breakdown she asked for. Sending the GPL by email.'),
  ('seed_003','text','inbound', '+15135551201','+15135550100','2026-09-22T13:05:00Z',NULL,'connected',NULL,NULL,0,true,NULL,'Margaret Ellis','seed_case_ellis',false, true, 'Margaret confirmed Wednesday and asked whether her brother could join by phone.'),
  ('seed_004','call','inbound', '+15135551210','+15135550100','2026-09-22T15:40:00Z', 233,'connected', 4, 22,1,true,NULL,'Jim Ellis','seed_case_ellis',false, true, 'James Ellis''s son calling from out of state. Added to Wednesday''s conference by phone. Asked about veteran benefits.'),

  -- A missed call and the callback that rescued it.
  ('seed_005','call','inbound', '+15135551220','+15135550144','2026-09-24T11:02:00Z',  28,'no_answer',NULL,NULL,0,true,NULL,'Dana Novak',NULL,false, true, NULL),
  ('seed_006','call','outbound','+15135550100','+15135551220','2026-09-24T11:19:00Z', 356,'connected', 9, 0,0,true,NULL,'Dana Novak','seed_case_novak',true,  true, 'Returned Dana Novak''s missed call. Her mother Helen died this morning at home. Walked through at-need options; she is coming in tomorrow at 10.'),
  ('seed_007','text','outbound','+15135550100','+15135551220','2026-09-24T11:52:00Z',NULL,'connected',NULL,NULL,0,true,NULL,'Dana Novak','seed_case_novak',false, true, 'Sent Dana the address and parking directions for tomorrow.'),

  -- Voicemail, out of hours.
  ('seed_008','call','inbound', '+15135551230','+15135550100','2026-09-25T20:47:00Z',  64,'voicemail',NULL,NULL,0,true,NULL,'Raymond Brightwater',NULL,false, false,'Raymond Brightwater left a voicemail asking about pre-arranging for himself. Wants a callback during the day.'),
  ('seed_009','call','outbound','+15135550100','+15135551230','2026-09-26T09:10:00Z', 298,'connected', 5, 0,0,true,NULL,'Raymond Brightwater',NULL,false, true, 'Returned Raymond''s voicemail. Pre-need appointment booked for 8 October.'),

  -- Trade and vendor traffic. Real volume, excluded from conversion.
  ('seed_010','call','inbound', '+15135551260','+15135550100','2026-09-23T07:45:00Z', 142,'connected', 3, 0,0,true,NULL,'Alice Reyes',NULL,false, true, 'Mercy Hospice calling ahead about a patient likely to pass in the next day or two. Took the family''s details.'),
  ('seed_011','call','inbound', '+15135551270','+15135550100','2026-09-26T14:20:00Z',  97,'connected', 2, 0,0,true,NULL,'Dale Kerr',NULL,false, true, 'Spring Grove confirming the committal time for Thursday.'),
  ('seed_012','call','inbound', '+18005551280','+15135550100','2026-09-23T16:10:00Z',  54,'connected', 4, 0,0,false,'vendor','Buckeye Casket Supply',NULL,false, true, 'Buckeye Casket Supply following up on an outstanding order.'),

  -- Noise. Every real Activity list has it, and the UI has to handle it.
  ('seed_013','call','inbound', '+18885551290','+15135550100','2026-09-30T11:48:00Z',  19,'spam',     2, 0,0,false,'solicitation','Unknown caller',NULL,false, false,'Automated call about commercial insurance.'),
  ('seed_014','call','inbound', '+15135551250','+15135550100','2026-09-29T10:05:00Z',  31,'connected', 3, 0,0,false,'wrong_number','Carl Whitmore',NULL,false, true, 'Caller was looking for a florist on the same street.'),

  -- A caller who hung up before anyone reached them. Abandoned, not missed.
  ('seed_015','call','inbound', '+15135551240','+15135550100','2026-09-28T13:12:00Z',  14,'abandoned',NULL,11,0,true,NULL,'Theresa Vaughn',NULL,false, true, NULL),
  ('seed_016','call','inbound', '+15135551240','+15135550100','2026-09-28T13:31:00Z', 204,'connected', 4, 0,0,true,NULL,'Theresa Vaughn',NULL,false, true, 'Theresa called back after hanging up earlier. Asking about costs for her mother, who is in hospice.'),

  -- Ordinary week: a spread of lengths, transfers and holds.
  ('seed_017','call','inbound', '+15135551201','+15135550100','2026-09-25T10:22:00Z', 128,'connected', 5, 0,0,true,NULL,'Margaret Ellis','seed_case_ellis',false, true, 'Margaret asking about the obituary deadline for Sunday''s paper.'),
  ('seed_018','call','inbound', '+15135551202','+15135550100','2026-09-27T16:05:00Z',  88,'connected', 7, 31,1,true,NULL,'Margaret Ellis','seed_case_ellis',false, true, 'Margaret calling from her home number this time. Transferred to the director for a question about the urn selection.'),
  ('seed_019','call','outbound','+15135550100','+15135551210','2026-09-26T08:40:00Z',  45,'no_answer',NULL,NULL,0,true,NULL,'Jim Ellis','seed_case_ellis',false, true, NULL),
  ('seed_020','call','outbound','+15135550100','+15135551210','2026-09-26T13:15:00Z', 162,'connected', 6, 0,0,true,NULL,'Jim Ellis','seed_case_ellis',false, true, 'Reached Jim on the second try. Confirmed the flag presentation for the service.'),
  ('seed_021','call','inbound', '+15135551220','+15135550100','2026-09-25T14:50:00Z', 311,'connected', 4, 0,0,true,NULL,'Dana Novak','seed_case_novak',false, true, 'Dana called after the arrangement conference with questions about the death certificates.'),
  ('seed_022','call','inbound', '+15135551260','+15135550144','2026-09-29T07:30:00Z', 119,'connected', 3, 0,0,true,NULL,'Alice Reyes',NULL,false, true, 'Mercy Hospice with a transfer request for this afternoon.'),
  ('seed_023','call','inbound', '+15135551230','+15135550100','2026-09-30T09:02:00Z',  76,'connected', 8, 0,0,true,NULL,'Raymond Brightwater',NULL,false, true, 'Raymond confirming his appointment and asking whether his wife should come too.'),
  ('seed_024','call','inbound', '+15135551240','+15135550144','2026-10-01T11:14:00Z', 265,'connected', 5, 0,0,true,NULL,'Theresa Vaughn',NULL,false, true, 'Theresa''s mother passed overnight. Beginning arrangements; she is coming in Friday.'),
  ('seed_025','call','outbound','+15135550100','+15135551240','2026-10-01T15:30:00Z',  52,'voicemail',NULL,NULL,0,true,NULL,'Theresa Vaughn',NULL,false, true, 'Left a voicemail for Theresa with the list of documents to bring Friday.'),
  ('seed_026','call','inbound', '+15135551250','+15135550144','2026-10-02T09:45:00Z',  37,'no_answer',NULL,NULL,0,true,NULL,'Carl Whitmore',NULL,false, true, NULL),
  ('seed_027','call','inbound', '+15135551270','+15135550100','2026-10-02T13:20:00Z', 143,'connected', 2, 0,0,true,NULL,'Dale Kerr',NULL,false, true, 'Spring Grove with a question about the headstone setting date.'),
  ('seed_028','call','inbound', '+15135551202','+15135550100','2026-10-03T10:30:00Z', 221,'connected', 4, 0,0,true,NULL,'Margaret Ellis','seed_case_ellis',false, true, 'Margaret calling to thank the staff and ask about the aftercare support group.')
) AS v(ref, channel, dir, from_e164, to_e164, occurred, secs, disp,
       answer_s, hold_s, transfers, qualified, unqual, contact_name, case_ref,
       converting, handled, summary)
LEFT JOIN contacts c ON c.organization_id = o.id AND c.notes = 'staging seed'
     AND COALESCE(c.full_name, c.business_name) = v.contact_name
LEFT JOIN cases k ON k.organization_id = o.id AND k.external_case_id = v.case_ref
LEFT JOIN phone_numbers n ON n.e164 = CASE WHEN v.dir = 'inbound'
                                           THEN v.to_e164 ELSE v.from_e164 END
WHERE o.code = 'DR';

-- -----------------------------------------------------------------------------
-- Message bodies for the two text threads
-- -----------------------------------------------------------------------------
INSERT INTO messages (organization_id, interaction_id, direction, from_e164,
                      to_e164, body, sent_at, external_ref)
SELECT i.organization_id, i.id, v.dir::direction, v.from_e164, v.to_e164,
       v.body, v.sent::timestamptz, v.ref
FROM interactions i
JOIN (VALUES
  ('seed_003','inbound', '+15135551201','+15135550100','Wednesday at 2 works for us. Can my brother join by phone? He''s in Arizona.','2026-09-22T13:05:00Z','seed_msg_001'),
  ('seed_003','outbound','+15135550100','+15135551201','Absolutely — we''ll set up the call. Just send me his number when you get a chance.','2026-09-22T13:11:00Z','seed_msg_002'),
  ('seed_003','inbound', '+15135551201','+15135550100','513-555-1210. Thank you so much.','2026-09-22T13:14:00Z','seed_msg_003'),
  ('seed_007','outbound','+15135550100','+15135551220','Hi Dana — we''re at 4100 Reading Road. Park in the lot behind the building and come in the side entrance. See you at 10.','2026-09-24T11:52:00Z','seed_msg_004'),
  ('seed_007','inbound', '+15135551220','+15135550100','Got it, thank you.','2026-09-24T12:08:00Z','seed_msg_005')
) AS v(call_ref, dir, from_e164, to_e164, body, sent, ref)
  ON v.call_ref = i.external_ref;

-- -----------------------------------------------------------------------------
-- Participants, so a contact's own calls are findable from either side
-- -----------------------------------------------------------------------------
INSERT INTO interaction_participants (organization_id, interaction_id, contact_id, role)
SELECT i.organization_id, i.id, i.contact_id, 'caller'
FROM interactions i
WHERE i.external_ref LIKE 'seed_%' AND i.contact_id IS NOT NULL;

-- -----------------------------------------------------------------------------
-- Tags
--
-- At-need on the family calls, and the caller-type tags that keep vendor and
-- solicitation traffic out of the conversion numbers while still counting it.
-- -----------------------------------------------------------------------------
INSERT INTO interaction_tags (organization_id, interaction_id, tag_id, tag_source)
SELECT i.organization_id, i.id, t.id, 'agent'
FROM interactions i
JOIN (VALUES
  ('seed_001','at_need'), ('seed_002','at_need'), ('seed_004','at_need'),
  ('seed_006','at_need'), ('seed_010','imminent'),('seed_012','vendor'),
  ('seed_013','solicitation'), ('seed_014','wrong_number'),
  ('seed_008','pre_need'), ('seed_009','pre_need'), ('seed_023','pre_need'),
  ('seed_016','imminent'), ('seed_024','at_need'),
  ('seed_011','trade'), ('seed_022','trade'), ('seed_027','trade')
) AS v(ref, code) ON v.ref = i.external_ref
JOIN tags t ON t.code = v.code AND t.organization_id IS NULL
ON CONFLICT DO NOTHING;

-- -----------------------------------------------------------------------------
-- The callback links
--
-- A missed call and the call that rescued it are one conversation. This is what
-- the detail view reads to show "returned 17 minutes later".
-- -----------------------------------------------------------------------------
INSERT INTO interaction_links (organization_id, from_interaction_id,
                               to_interaction_id, link_type, link_method, linked_by)
SELECT a.organization_id, a.id, b.id, 'callback', 'system_matched', 'staging seed'
FROM interactions a
JOIN (VALUES
  ('seed_005','seed_006'),   -- missed, returned 17 minutes later
  ('seed_008','seed_009'),   -- voicemail overnight, returned next morning
  ('seed_015','seed_016'),   -- abandoned, called back 19 minutes later
  ('seed_019','seed_020')    -- no answer outbound, reached on the second try
) AS v(from_ref, to_ref) ON v.from_ref = a.external_ref
JOIN interactions b ON b.external_ref = v.to_ref
                   AND b.organization_id = a.organization_id;

COMMIT;

-- =============================================================================
-- What landed
--
--   SET app.is_internal = 'on';
--
--   SELECT channel, direction, disposition, count(*)
--   FROM interactions WHERE external_ref LIKE 'seed_%'
--   GROUP BY 1,2,3 ORDER BY 1,2,3;
--
--   -- the Activity list, as the screen will read it
--   SELECT i.occurred_at, i.direction, i.channel, i.disposition,
--          COALESCE(c.full_name, c.business_name, i.from_e164) AS who,
--          i.duration_seconds, left(i.summary, 60) AS summary
--   FROM interactions i
--   LEFT JOIN contacts c ON c.id = i.contact_id
--   WHERE i.external_ref LIKE 'seed_%'
--   ORDER BY i.occurred_at DESC;
--
--   -- one contact, both her numbers, every call
--   SELECT i.occurred_at, i.direction, i.from_e164, i.to_e164, i.disposition
--   FROM interactions i
--   JOIN contacts c ON c.id = i.contact_id
--   WHERE c.full_name = 'Margaret Ellis' AND i.external_ref LIKE 'seed_%'
--   ORDER BY i.occurred_at;
--
--   -- the Ellis case: four interactions, one conversion
--   SELECT i.occurred_at, i.channel, i.direction, i.is_converting, i.summary
--   FROM interactions i JOIN cases k ON k.id = i.case_id
--   WHERE k.external_case_id = 'seed_case_ellis' ORDER BY i.occurred_at;
--
-- Removing it all
--
--   DELETE FROM interactions WHERE external_ref LIKE 'seed_%';
--   DELETE FROM contacts     WHERE notes = 'staging seed';
--   DELETE FROM cases        WHERE external_case_id LIKE 'seed_%';
--   DELETE FROM phone_numbers WHERE external_ref LIKE 'seed_%';
-- =============================================================================
