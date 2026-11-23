-- =============================================================================
-- 20261123T1834_same_firm_accounts_cases_seats.sql
-- The Hub — same-firm keys, family A: accounts, cases, seats, campaigns and location groups.
--
-- 22 foreign keys from 18 tables onto 5 targets (accounts, cases, seats,
-- campaigns, location_groups) become composite on organization_id, so a row's
-- parent is at the row's firm for every role, postgres included.
-- By ON DELETE: 15 SET NULL, 7 CASCADE. Batch 6 of 7 of family A (1810 was batch 1).
--
-- THE PATTERN is 20261123T1810's and db/README.md's ("Same-firm keys"):
--   * a unique index on each target's (id, organization_id);
--   * each single-column key REPLACED in one ALTER TABLE per source table,
--     under its existing name, by (x_id, organization_id) REFERENCES
--     target (id, organization_id);
--   * ON DELETE carried over exactly: CASCADE, RESTRICT and NO ACTION as
--     they were; SET NULL as SET NULL (x_id), the column-list form, because
--     a plain SET NULL on a composite key would null organization_id too;
--     DEFERRABLE INITIALLY DEFERRED kept where it was;
--   * ON UPDATE NO ACTION (every key was already);
--   * one transaction: the tables are nearly empty today (Mandie: do family
--     A now, before the first firm loads a book and interactions and
--     change_history need the three-step shape).
-- Each key below is pinned to its exact current definition in section 1,
-- with its zero-mismatch count (<>, both sides NOT NULL), and its intended
-- definition is checked in the catalogue by the verification.
--
-- Requires: 20261123T1810 (the pattern; contacts' index), 20261103T1200
--           (record_migration).
-- NOT SAFE TO RUN TWICE: section 1 refuses once any key is composite.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Preconditions: every key exactly as it is, and no row it would refuse
-- -----------------------------------------------------------------------------
DO $$
DECLARE k record; n int;
BEGIN
  FOR k IN SELECT * FROM (VALUES
      ('cost_events', 'cost_events_account_id_fkey', 'account_id', 'accounts', 'FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE SET NULL'),
      ('interactions', 'interactions_account_id_fkey', 'account_id', 'accounts', 'FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE SET NULL'),
      ('locations', 'locations_account_id_fkey', 'account_id', 'accounts', 'FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE SET NULL'),
      ('rate_cards', 'rate_cards_account_id_fkey', 'account_id', 'accounts', 'FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE'),
      ('seats', 'seats_account_id_fkey', 'account_id', 'accounts', 'FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE SET NULL'),
      ('subscriptions', 'subscriptions_account_id_fkey', 'account_id', 'accounts', 'FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE SET NULL'),
      ('campaign_spend', 'campaign_spend_campaign_id_fkey', 'campaign_id', 'campaigns', 'FOREIGN KEY (campaign_id) REFERENCES campaigns(id) ON DELETE CASCADE'),
      ('cases', 'cases_source_campaign_id_fkey', 'source_campaign_id', 'campaigns', 'FOREIGN KEY (source_campaign_id) REFERENCES campaigns(id) ON DELETE SET NULL'),
      ('contacts', 'contacts_source_campaign_id_fkey', 'source_campaign_id', 'campaigns', 'FOREIGN KEY (source_campaign_id) REFERENCES campaigns(id) ON DELETE SET NULL'),
      ('custom_field_values', 'custom_field_values_case_id_fkey', 'case_id', 'cases', 'FOREIGN KEY (case_id) REFERENCES cases(id) ON DELETE CASCADE'),
      ('interactions', 'interactions_case_id_fkey', 'case_id', 'cases', 'FOREIGN KEY (case_id) REFERENCES cases(id) ON DELETE SET NULL'),
      ('leads', 'leads_case_id_fkey', 'case_id', 'cases', 'FOREIGN KEY (case_id) REFERENCES cases(id) ON DELETE SET NULL'),
      ('outcomes', 'outcomes_case_id_fkey', 'case_id', 'cases', 'FOREIGN KEY (case_id) REFERENCES cases(id) ON DELETE SET NULL'),
      ('reminders', 'reminders_case_id_fkey', 'case_id', 'cases', 'FOREIGN KEY (case_id) REFERENCES cases(id) ON DELETE CASCADE'),
      ('threads', 'threads_case_id_fkey', 'case_id', 'cases', 'FOREIGN KEY (case_id) REFERENCES cases(id) ON DELETE CASCADE'),
      ('cost_events', 'cost_events_location_group_id_fkey', 'location_group_id', 'location_groups', 'FOREIGN KEY (location_group_id) REFERENCES location_groups(id) ON DELETE SET NULL'),
      ('locations', 'locations_location_group_id_fkey', 'location_group_id', 'location_groups', 'FOREIGN KEY (location_group_id) REFERENCES location_groups(id) ON DELETE SET NULL'),
      ('person_assignments', 'person_assignments_location_group_id_fkey', 'location_group_id', 'location_groups', 'FOREIGN KEY (location_group_id) REFERENCES location_groups(id) ON DELETE CASCADE'),
      ('device_sessions', 'device_sessions_seat_id_fkey', 'seat_id', 'seats', 'FOREIGN KEY (seat_id) REFERENCES seats(id) ON DELETE CASCADE'),
      ('evaluations', 'evaluations_seat_id_fkey', 'seat_id', 'seats', 'FOREIGN KEY (seat_id) REFERENCES seats(id) ON DELETE SET NULL'),
      ('interactions', 'interactions_seat_id_fkey', 'seat_id', 'seats', 'FOREIGN KEY (seat_id) REFERENCES seats(id) ON DELETE SET NULL'),
      ('user_availability_events', 'user_availability_events_seat_id_fkey', 'seat_id', 'seats', 'FOREIGN KEY (seat_id) REFERENCES seats(id) ON DELETE SET NULL')
    ) AS x(src, con, col, tgt, def) LOOP
    IF (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = k.src::regclass AND conname = k.con)
       IS DISTINCT FROM k.def THEN
      RAISE EXCEPTION '%.% is not the key this file replaces (%): already converted, or changed: stop and read it',
        k.src, k.con, k.def;
    END IF;
    IF NOT (SELECT attnotnull FROM pg_attribute WHERE attrelid = k.src::regclass AND attname = 'organization_id')
       OR NOT (SELECT attnotnull FROM pg_attribute WHERE attrelid = k.tgt::regclass AND attname = 'organization_id') THEN
      RAISE EXCEPTION '%: organization_id is nullable on % or %; not family A', k.con, k.src, k.tgt;
    END IF;
    -- both sides NOT NULL, so <> is exact
    EXECUTE format('SELECT count(*) FROM %I s JOIN %I t ON t.id = s.%I WHERE s.organization_id <> t.organization_id',
                   k.src, k.tgt, k.col) INTO n;
    IF n > 0 THEN
      RAISE EXCEPTION '%: % rows point at a % row at another firm; the key would refuse them: fix them first', k.con, n, k.tgt;
    END IF;
  END LOOP;
  IF to_regclass('public.accounts_id_organization_uq') IS NOT NULL THEN
    RAISE EXCEPTION 'accounts_id_organization_uq already exists: stop and read it';
  END IF;
  IF to_regclass('public.cases_id_organization_uq') IS NOT NULL THEN
    RAISE EXCEPTION 'cases_id_organization_uq already exists: stop and read it';
  END IF;
  IF to_regclass('public.seats_id_organization_uq') IS NOT NULL THEN
    RAISE EXCEPTION 'seats_id_organization_uq already exists: stop and read it';
  END IF;
  IF to_regclass('public.campaigns_id_organization_uq') IS NOT NULL THEN
    RAISE EXCEPTION 'campaigns_id_organization_uq already exists: stop and read it';
  END IF;
  IF to_regclass('public.location_groups_id_organization_uq') IS NOT NULL THEN
    RAISE EXCEPTION 'location_groups_id_organization_uq already exists: stop and read it';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. What the composite keys reference
-- -----------------------------------------------------------------------------
CREATE UNIQUE INDEX accounts_id_organization_uq ON accounts (id, organization_id);
COMMENT ON INDEX accounts_id_organization_uq IS
  'For composite keys that tie a row to a accounts row AT THE ROW''S FIRM (20261123T1834).';
CREATE UNIQUE INDEX cases_id_organization_uq ON cases (id, organization_id);
COMMENT ON INDEX cases_id_organization_uq IS
  'For composite keys that tie a row to a cases row AT THE ROW''S FIRM (20261123T1834).';
CREATE UNIQUE INDEX seats_id_organization_uq ON seats (id, organization_id);
COMMENT ON INDEX seats_id_organization_uq IS
  'For composite keys that tie a row to a seats row AT THE ROW''S FIRM (20261123T1834).';
CREATE UNIQUE INDEX campaigns_id_organization_uq ON campaigns (id, organization_id);
COMMENT ON INDEX campaigns_id_organization_uq IS
  'For composite keys that tie a row to a campaigns row AT THE ROW''S FIRM (20261123T1834).';
CREATE UNIQUE INDEX location_groups_id_organization_uq ON location_groups (id, organization_id);
COMMENT ON INDEX location_groups_id_organization_uq IS
  'For composite keys that tie a row to a location_groups row AT THE ROW''S FIRM (20261123T1834).';

-- -----------------------------------------------------------------------------
-- 3. The keys, replaced: one ALTER TABLE per source table
-- -----------------------------------------------------------------------------
ALTER TABLE campaign_spend
  DROP CONSTRAINT campaign_spend_campaign_id_fkey,
  ADD CONSTRAINT campaign_spend_campaign_id_fkey FOREIGN KEY (campaign_id, organization_id)
    REFERENCES campaigns(id, organization_id) ON DELETE CASCADE;
ALTER TABLE cases
  DROP CONSTRAINT cases_source_campaign_id_fkey,
  ADD CONSTRAINT cases_source_campaign_id_fkey FOREIGN KEY (source_campaign_id, organization_id)
    REFERENCES campaigns(id, organization_id) ON DELETE SET NULL (source_campaign_id);
ALTER TABLE contacts
  DROP CONSTRAINT contacts_source_campaign_id_fkey,
  ADD CONSTRAINT contacts_source_campaign_id_fkey FOREIGN KEY (source_campaign_id, organization_id)
    REFERENCES campaigns(id, organization_id) ON DELETE SET NULL (source_campaign_id);
ALTER TABLE cost_events
  DROP CONSTRAINT cost_events_account_id_fkey,
  ADD CONSTRAINT cost_events_account_id_fkey FOREIGN KEY (account_id, organization_id)
    REFERENCES accounts(id, organization_id) ON DELETE SET NULL (account_id),
  DROP CONSTRAINT cost_events_location_group_id_fkey,
  ADD CONSTRAINT cost_events_location_group_id_fkey FOREIGN KEY (location_group_id, organization_id)
    REFERENCES location_groups(id, organization_id) ON DELETE SET NULL (location_group_id);
ALTER TABLE custom_field_values
  DROP CONSTRAINT custom_field_values_case_id_fkey,
  ADD CONSTRAINT custom_field_values_case_id_fkey FOREIGN KEY (case_id, organization_id)
    REFERENCES cases(id, organization_id) ON DELETE CASCADE;
ALTER TABLE device_sessions
  DROP CONSTRAINT device_sessions_seat_id_fkey,
  ADD CONSTRAINT device_sessions_seat_id_fkey FOREIGN KEY (seat_id, organization_id)
    REFERENCES seats(id, organization_id) ON DELETE CASCADE;
ALTER TABLE evaluations
  DROP CONSTRAINT evaluations_seat_id_fkey,
  ADD CONSTRAINT evaluations_seat_id_fkey FOREIGN KEY (seat_id, organization_id)
    REFERENCES seats(id, organization_id) ON DELETE SET NULL (seat_id);
ALTER TABLE interactions
  DROP CONSTRAINT interactions_account_id_fkey,
  ADD CONSTRAINT interactions_account_id_fkey FOREIGN KEY (account_id, organization_id)
    REFERENCES accounts(id, organization_id) ON DELETE SET NULL (account_id),
  DROP CONSTRAINT interactions_case_id_fkey,
  ADD CONSTRAINT interactions_case_id_fkey FOREIGN KEY (case_id, organization_id)
    REFERENCES cases(id, organization_id) ON DELETE SET NULL (case_id),
  DROP CONSTRAINT interactions_seat_id_fkey,
  ADD CONSTRAINT interactions_seat_id_fkey FOREIGN KEY (seat_id, organization_id)
    REFERENCES seats(id, organization_id) ON DELETE SET NULL (seat_id);
ALTER TABLE leads
  DROP CONSTRAINT leads_case_id_fkey,
  ADD CONSTRAINT leads_case_id_fkey FOREIGN KEY (case_id, organization_id)
    REFERENCES cases(id, organization_id) ON DELETE SET NULL (case_id);
ALTER TABLE locations
  DROP CONSTRAINT locations_account_id_fkey,
  ADD CONSTRAINT locations_account_id_fkey FOREIGN KEY (account_id, organization_id)
    REFERENCES accounts(id, organization_id) ON DELETE SET NULL (account_id),
  DROP CONSTRAINT locations_location_group_id_fkey,
  ADD CONSTRAINT locations_location_group_id_fkey FOREIGN KEY (location_group_id, organization_id)
    REFERENCES location_groups(id, organization_id) ON DELETE SET NULL (location_group_id);
ALTER TABLE outcomes
  DROP CONSTRAINT outcomes_case_id_fkey,
  ADD CONSTRAINT outcomes_case_id_fkey FOREIGN KEY (case_id, organization_id)
    REFERENCES cases(id, organization_id) ON DELETE SET NULL (case_id);
ALTER TABLE person_assignments
  DROP CONSTRAINT person_assignments_location_group_id_fkey,
  ADD CONSTRAINT person_assignments_location_group_id_fkey FOREIGN KEY (location_group_id, organization_id)
    REFERENCES location_groups(id, organization_id) ON DELETE CASCADE;
ALTER TABLE rate_cards
  DROP CONSTRAINT rate_cards_account_id_fkey,
  ADD CONSTRAINT rate_cards_account_id_fkey FOREIGN KEY (account_id, organization_id)
    REFERENCES accounts(id, organization_id) ON DELETE CASCADE;
ALTER TABLE reminders
  DROP CONSTRAINT reminders_case_id_fkey,
  ADD CONSTRAINT reminders_case_id_fkey FOREIGN KEY (case_id, organization_id)
    REFERENCES cases(id, organization_id) ON DELETE CASCADE;
ALTER TABLE seats
  DROP CONSTRAINT seats_account_id_fkey,
  ADD CONSTRAINT seats_account_id_fkey FOREIGN KEY (account_id, organization_id)
    REFERENCES accounts(id, organization_id) ON DELETE SET NULL (account_id);
ALTER TABLE subscriptions
  DROP CONSTRAINT subscriptions_account_id_fkey,
  ADD CONSTRAINT subscriptions_account_id_fkey FOREIGN KEY (account_id, organization_id)
    REFERENCES accounts(id, organization_id) ON DELETE SET NULL (account_id);
ALTER TABLE threads
  DROP CONSTRAINT threads_case_id_fkey,
  ADD CONSTRAINT threads_case_id_fkey FOREIGN KEY (case_id, organization_id)
    REFERENCES cases(id, organization_id) ON DELETE CASCADE;
ALTER TABLE user_availability_events
  DROP CONSTRAINT user_availability_events_seat_id_fkey,
  ADD CONSTRAINT user_availability_events_seat_id_fkey FOREIGN KEY (seat_id, organization_id)
    REFERENCES seats(id, organization_id) ON DELETE SET NULL (seat_id);

-- -----------------------------------------------------------------------------
-- 4. Record it
-- -----------------------------------------------------------------------------
DO $rec$
BEGIN
  PERFORM record_migration(
    '20261123T1834_same_firm_accounts_cases_seats.sql',
    NULL,
    'Same-firm keys, family A: 22 keys onto accounts, cases, seats, campaigns, location_groups made composite on '
    'organization_id; ON DELETE carried over, SET NULL on the pointer column only.');
END $rec$;

COMMIT;

-- =============================================================================
-- Verification — run AFTER the file, as its own statement. One block,
-- everything rolled back by the closing RAISE. AS postgres: a foreign key
-- holds for every role.
--
-- HOW IT TESTS EVERY KEY ON A REAL ROW. It builds one row in each table
-- involved, at two firms (A and B), with the builders listed below: one
-- INSERT per table, its required columns only, written out so each can be
-- read. Each test row gets fresh parents of its own, so no unique key
-- collides. Then, for each key, inside its own rolled-back sub-block:
--   * cross-firm: a fresh source row at A is pointed at a fresh row at B:
--     expect 23503 naming that key. Some tables' own triggers refuse
--     another firm first (the *_merged_into_ck guards; seats' account
--     check), so the source table's user triggers are switched off inside
--     this sub-block only: the key is what's tested, and the switch is
--     undone with the sub-block;
--   * same firm: the source row pointed at a fresh target row at A: allowed.
--     Where a CHECK ties the pointer to a sibling column (a thread's scope,
--     an interaction's link method, merge dismissals' a < b), the same UPDATE
--     sets that sibling too: the "also" column, one per key, written out;
--   * delete: that fresh target row deleted: CASCADE takes the source row;
--     SET NULL clears only the pointer and keeps organization_id; RESTRICT
--     and NO ACTION refuse with 23503 naming the key (deferred keys are made
--     immediate first, so the refusal is seen here, not at COMMIT).
-- Two keys can't complete a delete today, before this file as after it:
-- deleting a person clears interactions.handler_person_id and
-- seats.person_id, and a CHECK then refuses the row (an attributed call must
-- name its handler; a named seat must name its person). For those two, the
-- rule as before IS that refusal, and line 5 expects it (want_delete).
-- A line reads "N of N" when every key behaves; otherwise it lists each key
-- that didn't, and why.
--
-- DO $$
-- DECLARE
--   r text := ''; v_a uuid; v_b uuid; fa jsonb := '{}'; fb jsonb := '{}'; t text; nid text; sid text; tid text;
--   k record; idc text; st text; msg text; want text; cname text; n_ok int; bad text; c_cross int := 0; c_same int := 0; c_del int := 0;
--   b_cross text := ''; b_same text := ''; b_del text := ''; b_cat text := ''; c_cat int := 0; c_idx int := 0;
--   mk CONSTANT jsonb := (SELECT jsonb_object_agg(tb, sql) FROM (VALUES
--     ('accounts', $b$INSERT INTO accounts (organization_id, name) VALUES ($1, 'zzz-' || left(gen_random_uuid()::text, 8)) RETURNING id$b$),
--     ('alerts', $b$INSERT INTO alerts (organization_id, alert_kind) VALUES ($1, 'missed_call') RETURNING id$b$),
--     ('answering_services', $b$INSERT INTO answering_services (organization_id, name) VALUES ($1, 'zzz-' || left(gen_random_uuid()::text, 8)) RETURNING id$b$),
--     ('tags', $b$INSERT INTO tags (organization_id, code, label, tag_kind) VALUES ($1, 'zzz-' || left(gen_random_uuid()::text, 8), 'zzz-' || left(gen_random_uuid()::text, 8), 'need_type') RETURNING id$b$),
--     ('auto_tag_rules', $b$INSERT INTO auto_tag_rules (organization_id, name, condition, tag_id) VALUES ($1, 'zzz-' || left(gen_random_uuid()::text, 8), 'arrived_on_line', ($2 ->> 'tags')::uuid) RETURNING id$b$),
--     ('behaviors', $b$WITH s AS (INSERT INTO rubric_sections (code, label, score_category, display_order) VALUES ('zzz-' || gen_random_uuid(), 'zzz', 'objective', 1) RETURNING id) INSERT INTO behaviors (code, label, section_id, score_category, answered_by) SELECT 'zzz-' || gen_random_uuid(), 'zzz', s.id, 'objective', 'ai' FROM s RETURNING id$b$),
--     ('interactions', $b$INSERT INTO interactions (organization_id, direction, occurred_at, last_activity_at) VALUES ($1, 'inbound', now(), now()) RETURNING id$b$),
--     ('callback_requests', $b$INSERT INTO callback_requests (organization_id, interaction_id) VALUES ($1, ($2 ->> 'interactions')::uuid) RETURNING id$b$),
--     ('campaigns', $b$INSERT INTO campaigns (organization_id, name, channel) VALUES ($1, 'zzz-' || left(gen_random_uuid()::text, 8), 'google_ads') RETURNING id$b$),
--     ('campaign_spend', $b$INSERT INTO campaign_spend (organization_id, campaign_id, period_start, period_end, amount) VALUES ($1, ($2 ->> 'campaigns')::uuid, date '2000-01-01' + (random() * 3000)::int, date '2100-01-01' + (random() * 3000)::int, 1) RETURNING id$b$),
--     ('cases', $b$INSERT INTO cases (organization_id, need_type) VALUES ($1, 'at_need') RETURNING id$b$),
--     ('contacts', $b$INSERT INTO contacts (organization_id) VALUES ($1) RETURNING id$b$),
--     ('consents', $b$INSERT INTO consents (organization_id, contact_id, consent_kind, granted, consent_source) VALUES ($1, ($2 ->> 'contacts')::uuid, 'sms', false, 'web_form') RETURNING id$b$),
--     ('decedents', $b$INSERT INTO decedents (organization_id, last_name) VALUES ($1, 'Zzz') RETURNING id$b$),
--     ('contact_decedent_links', $b$INSERT INTO contact_decedent_links (organization_id, contact_id, decedent_id, link_method) VALUES ($1, ($2 ->> 'contacts')::uuid, ($2 ->> 'decedents')::uuid, 'confirmed') RETURNING id$b$),
--     ('users', $b$INSERT INTO users (email, full_name, is_internal) VALUES ('zzz-famA-' || gen_random_uuid() || '@example.invalid', 'ZZZ famA', true) RETURNING id$b$),
--     ('contact_imports', $b$INSERT INTO contact_imports (organization_id, imported_by, rows_in_file, created, filled, unchanged, held_resolved, held_skipped, refused, calls_linked) VALUES ($1, ($2 ->> 'users')::uuid, 1, 1, 1, 1, 1, 1, 1, 1) RETURNING id$b$),
--     ('contacts_2', $b$INSERT INTO contacts (organization_id) VALUES ($1) RETURNING id$b$),
--     ('contact_merge_dismissals', $b$INSERT INTO contact_merge_dismissals (organization_id, contact_a_id, contact_b_id, dismissed_by) VALUES ($1, LEAST(($2 ->> 'contacts')::uuid, ($2 ->> 'contacts_2')::uuid), GREATEST(($2 ->> 'contacts')::uuid, ($2 ->> 'contacts_2')::uuid), 'zzz-' || left(gen_random_uuid()::text, 8)) RETURNING id$b$),
--     ('contact_relationships', $b$INSERT INTO contact_relationships (organization_id, from_contact_id, to_contact_id, relationship) VALUES ($1, ($2 ->> 'contacts')::uuid, ($2 ->> 'contacts_2')::uuid, 'zzz-' || left(gen_random_uuid()::text, 8)) RETURNING id$b$),
--     ('cost_events', $b$INSERT INTO cost_events (organization_id, vendor, cost_kind, total_cost) VALUES ($1, 'dial_stack', 'seat', 1) RETURNING id$b$),
--     ('custom_field_definitions', $b$INSERT INTO custom_field_definitions (organization_id, entity, name) VALUES ($1, 'contact', 'zzz-' || left(gen_random_uuid()::text, 8)) RETURNING id$b$),
--     ('custom_field_values', $b$INSERT INTO custom_field_values (organization_id, definition_id, value, contact_id) VALUES ($1, ($2 ->> 'custom_field_definitions')::uuid, '{}', ($2 ->> 'contacts')::uuid) RETURNING id$b$),
--     ('data_sharing_agreements', $b$INSERT INTO data_sharing_agreements (organization_id, receiving_org_id, scope, signed_on, signed_by) VALUES ($1, $3, 'call_recordings', date '2000-01-01' + (random() * 3000)::int, 'zzz-' || left(gen_random_uuid()::text, 8)) RETURNING id$b$),
--     ('people', $b$INSERT INTO people (organization_id, full_name) VALUES ($1, 'zzz-' || left(gen_random_uuid()::text, 8)) RETURNING id$b$),
--     ('seats', $b$INSERT INTO seats (organization_id, label, seat_type) VALUES ($1, 'zzz-' || left(gen_random_uuid()::text, 8), 'shared') RETURNING id$b$),
--     ('device_sessions', $b$INSERT INTO device_sessions (organization_id, seat_id, person_id, started_at) VALUES ($1, ($2 ->> 'seats')::uuid, ($2 ->> 'people')::uuid, now()) RETURNING id$b$),
--     ('directory_entries', $b$INSERT INTO directory_entries (organization_id, entry_kind, label) VALUES ($1, 'team', 'zzz-' || left(gen_random_uuid()::text, 8)) RETURNING id$b$),
--     ('rubrics', $b$INSERT INTO rubrics (organization_id, name, version) VALUES ($1, 'zzz-' || left(gen_random_uuid()::text, 8), 'zzz-' || left(gen_random_uuid()::text, 8)) RETURNING id$b$),
--     ('evaluations', $b$INSERT INTO evaluations (organization_id, rubric_id, interaction_id) VALUES ($1, ($2 ->> 'rubrics')::uuid, ($2 ->> 'interactions')::uuid) RETURNING id$b$),
--     ('focus_behaviors', $b$INSERT INTO focus_behaviors (organization_id, behavior_id, focus_source) VALUES ($1, ($2 ->> 'behaviors')::uuid, 'client') RETURNING id$b$),
--     ('interaction_events', $b$INSERT INTO interaction_events (organization_id, external_call_ref, event_type, occurred_at) VALUES ($1, 'zzz-' || left(gen_random_uuid()::text, 8), 'call.initiated', now()) RETURNING id$b$),
--     ('interaction_links', $b$INSERT INTO interaction_links (organization_id, from_interaction_id, link_type, link_method, to_external_ref) VALUES ($1, ($2 ->> 'interactions')::uuid, 'shop_attempt', 'system_matched', 'zzz') RETURNING id$b$),
--     ('interaction_participants', $b$INSERT INTO interaction_participants (organization_id, interaction_id, contact_id) VALUES ($1, ($2 ->> 'interactions')::uuid, ($2 ->> 'contacts')::uuid) RETURNING id$b$),
--     ('interaction_reads', $b$WITH u AS (INSERT INTO users (email, full_name) VALUES ('zzz-famA-' || gen_random_uuid() || '@example.invalid', 'ZZZ reader') RETURNING id) INSERT INTO interaction_reads (organization_id, interaction_id, user_id) SELECT $1, ($2 ->> 'interactions')::uuid, u.id FROM u RETURNING user_id$b$),
--     ('interaction_tags', $b$INSERT INTO interaction_tags (organization_id, interaction_id, tag_id, tag_source) VALUES ($1, ($2 ->> 'interactions')::uuid, ($2 ->> 'tags')::uuid, 'agent') RETURNING id$b$),
--     ('lead_ownership_rules', $b$INSERT INTO lead_ownership_rules (organization_id) VALUES ($1) RETURNING id$b$),
--     ('leads', $b$INSERT INTO leads (organization_id, full_name) VALUES ($1, 'zzz-' || left(gen_random_uuid()::text, 8)) RETURNING id$b$),
--     ('location_groups', $b$INSERT INTO location_groups (organization_id, name) VALUES ($1, 'zzz-' || left(gen_random_uuid()::text, 8)) RETURNING id$b$),
--     ('locations', $b$INSERT INTO locations (organization_id, name, location_type) VALUES ($1, 'zzz-' || left(gen_random_uuid()::text, 8), 'funeral_home') RETURNING id$b$),
--     ('marketing_vendors', $b$INSERT INTO marketing_vendors (organization_id, name) VALUES ($1, 'zzz-' || left(gen_random_uuid()::text, 8)) RETURNING id$b$),
--     ('messages', $b$INSERT INTO messages (organization_id, interaction_id, direction, sent_at) VALUES ($1, ($2 ->> 'interactions')::uuid, 'inbound', now()) RETURNING id$b$),
--     ('observations', $b$INSERT INTO observations (organization_id, evaluation_id, behavior_id, opportunity, source) VALUES ($1, ($2 ->> 'evaluations')::uuid, ($2 ->> 'behaviors')::uuid, false, 'ai') RETURNING id$b$),
--     ('outcomes', $b$INSERT INTO outcomes (organization_id, outcome_type, valuation_method, interaction_id) VALUES ($1, 'won', 'unvalued', ($2 ->> 'interactions')::uuid) RETURNING id$b$),
--     ('person_assignments', $b$INSERT INTO person_assignments (organization_id, person_id, location_id) VALUES ($1, ($2 ->> 'people')::uuid, ($2 ->> 'locations')::uuid) RETURNING id$b$),
--     ('price_quotes', $b$INSERT INTO price_quotes (organization_id, interaction_id, quote_order) VALUES ($1, ($2 ->> 'interactions')::uuid, 1) RETURNING id$b$),
--     ('rate_cards', $b$INSERT INTO rate_cards (organization_id) VALUES ($1) RETURNING id$b$),
--     ('referral_sources', $b$INSERT INTO referral_sources (organization_id, name, referral_kind) VALUES ($1, 'zzz-' || left(gen_random_uuid()::text, 8), 'hospice') RETURNING id$b$),
--     ('reminders', $b$INSERT INTO reminders (organization_id, owner_user_id, due_at, contact_id) VALUES ($1, ($2 ->> 'users')::uuid, now(), ($2 ->> 'contacts')::uuid) RETURNING id$b$),
--     ('report_definitions', $b$INSERT INTO report_definitions (organization_id, name, audience) VALUES ($1, 'zzz-' || left(gen_random_uuid()::text, 8), 'owner') RETURNING id$b$),
--     ('reporting_periods', $b$INSERT INTO reporting_periods (organization_id, period_start, period_end) VALUES ($1, date '2000-01-01' + (random() * 3000)::int, date '2100-01-01' + (random() * 3000)::int) RETURNING id$b$),
--     ('reports', $b$INSERT INTO reports (organization_id, audience) VALUES ($1, 'owner') RETURNING id$b$),
--     ('response_policies', $b$INSERT INTO response_policies (organization_id) VALUES ($1) RETURNING id$b$),
--     ('routing_schedules', $b$INSERT INTO routing_schedules (organization_id, name, starts_at, ends_at, target, day_of_week) VALUES ($1, 'zzz-' || left(gen_random_uuid()::text, 8), '09:00', '09:00', 'voicemail', 1) RETURNING id$b$),
--     ('shops', $b$INSERT INTO shops (organization_id) VALUES ($1) RETURNING id$b$),
--     ('shopper_forms', $b$INSERT INTO shopper_forms (organization_id, shop_id) VALUES ($1, ($2 ->> 'shops')::uuid) RETURNING id$b$),
--     ('subscriptions', $b$INSERT INTO subscriptions (organization_id, subscription_kind, monthly_amount, starts_on) VALUES ($1, 'growth_plan', 1, date '2000-01-01' + (random() * 3000)::int) RETURNING id$b$),
--     ('teams', $b$INSERT INTO teams (organization_id, name) VALUES ($1, 'zzz-' || left(gen_random_uuid()::text, 8)) RETURNING id$b$),
--     ('threads', $b$INSERT INTO threads (organization_id, scope) VALUES ($1, 'support') RETURNING id$b$),
--     ('thread_messages', $b$INSERT INTO thread_messages (organization_id, thread_id, body, sender_label) VALUES ($1, ($2 ->> 'threads')::uuid, 'zzz-' || left(gen_random_uuid()::text, 8), 'zzz') RETURNING id$b$),
--     ('transcript_segments', $b$INSERT INTO transcript_segments (organization_id, interaction_id, segment_order, body) VALUES ($1, ($2 ->> 'interactions')::uuid, 1, 'zzz-' || left(gen_random_uuid()::text, 8)) RETURNING id$b$),
--     ('transcript_redactions', $b$INSERT INTO transcript_redactions (organization_id, interaction_id, segment_id, whole_segment, requested_by, reason, redacted_by) VALUES ($1, ($2 ->> 'interactions')::uuid, ($2 ->> 'transcript_segments')::uuid, false, 'zzz-' || left(gen_random_uuid()::text, 8), 'zzz-' || left(gen_random_uuid()::text, 8), ($2 ->> 'users')::uuid) RETURNING id$b$),
--     ('user_availability_events', $b$INSERT INTO user_availability_events (organization_id, person_id, state) VALUES ($1, ($2 ->> 'people')::uuid, 'ready') RETURNING id$b$)) AS bl(tb, sql));
--   ord CONSTANT text[] := ARRAY['accounts', 'alerts', 'answering_services', 'tags', 'auto_tag_rules', 'behaviors', 'interactions', 'callback_requests', 'campaigns', 'campaign_spend', 'cases', 'contacts', 'consents', 'decedents', 'contact_decedent_links', 'users', 'contact_imports', 'contacts_2', 'contact_merge_dismissals', 'contact_relationships', 'cost_events', 'custom_field_definitions', 'custom_field_values', 'data_sharing_agreements', 'people', 'seats', 'device_sessions', 'directory_entries', 'rubrics', 'evaluations', 'focus_behaviors', 'interaction_events', 'interaction_links', 'interaction_participants', 'interaction_reads', 'interaction_tags', 'lead_ownership_rules', 'leads', 'location_groups', 'locations', 'marketing_vendors', 'messages', 'observations', 'outcomes', 'person_assignments', 'price_quotes', 'rate_cards', 'referral_sources', 'reminders', 'report_definitions', 'reporting_periods', 'reports', 'response_policies', 'routing_schedules', 'shops', 'shopper_forms', 'subscriptions', 'teams', 'threads', 'thread_messages', 'transcript_segments', 'transcript_redactions', 'user_availability_events'];
--   -- each table's parents, in build order: a fresh row gets fresh parents,
--   -- so no unique key collides with the fixtures
--   anc CONSTANT jsonb := (SELECT jsonb_object_agg(tb, a) FROM (VALUES
--     ('accounts', '[]'::jsonb),
--     ('alerts', '[]'::jsonb),
--     ('answering_services', '[]'::jsonb),
--     ('tags', '[]'::jsonb),
--     ('auto_tag_rules', '["tags"]'::jsonb),
--     ('behaviors', '[]'::jsonb),
--     ('interactions', '[]'::jsonb),
--     ('callback_requests', '["interactions"]'::jsonb),
--     ('campaigns', '[]'::jsonb),
--     ('campaign_spend', '["campaigns"]'::jsonb),
--     ('cases', '[]'::jsonb),
--     ('contacts', '[]'::jsonb),
--     ('consents', '["contacts"]'::jsonb),
--     ('decedents', '[]'::jsonb),
--     ('contact_decedent_links', '["contacts", "decedents"]'::jsonb),
--     ('users', '[]'::jsonb),
--     ('contact_imports', '["users"]'::jsonb),
--     ('contacts_2', '[]'::jsonb),
--     ('contact_merge_dismissals', '["contacts", "contacts_2"]'::jsonb),
--     ('contact_relationships', '["contacts", "contacts_2"]'::jsonb),
--     ('cost_events', '[]'::jsonb),
--     ('custom_field_definitions', '[]'::jsonb),
--     ('custom_field_values', '["contacts", "custom_field_definitions"]'::jsonb),
--     ('data_sharing_agreements', '[]'::jsonb),
--     ('people', '[]'::jsonb),
--     ('seats', '[]'::jsonb),
--     ('device_sessions', '["people", "seats"]'::jsonb),
--     ('directory_entries', '[]'::jsonb),
--     ('rubrics', '[]'::jsonb),
--     ('evaluations', '["interactions", "rubrics"]'::jsonb),
--     ('focus_behaviors', '["behaviors"]'::jsonb),
--     ('interaction_events', '[]'::jsonb),
--     ('interaction_links', '["interactions"]'::jsonb),
--     ('interaction_participants', '["interactions", "contacts"]'::jsonb),
--     ('interaction_reads', '["interactions"]'::jsonb),
--     ('interaction_tags', '["tags", "interactions"]'::jsonb),
--     ('lead_ownership_rules', '[]'::jsonb),
--     ('leads', '[]'::jsonb),
--     ('location_groups', '[]'::jsonb),
--     ('locations', '[]'::jsonb),
--     ('marketing_vendors', '[]'::jsonb),
--     ('messages', '["interactions"]'::jsonb),
--     ('observations', '["behaviors", "interactions", "rubrics", "evaluations"]'::jsonb),
--     ('outcomes', '["interactions"]'::jsonb),
--     ('person_assignments', '["people", "locations"]'::jsonb),
--     ('price_quotes', '["interactions"]'::jsonb),
--     ('rate_cards', '[]'::jsonb),
--     ('referral_sources', '[]'::jsonb),
--     ('reminders', '["contacts", "users"]'::jsonb),
--     ('report_definitions', '[]'::jsonb),
--     ('reporting_periods', '[]'::jsonb),
--     ('reports', '[]'::jsonb),
--     ('response_policies', '[]'::jsonb),
--     ('routing_schedules', '[]'::jsonb),
--     ('shops', '[]'::jsonb),
--     ('shopper_forms', '["shops"]'::jsonb),
--     ('subscriptions', '[]'::jsonb),
--     ('teams', '[]'::jsonb),
--     ('threads', '[]'::jsonb),
--     ('thread_messages', '["threads"]'::jsonb),
--     ('transcript_segments', '["interactions"]'::jsonb),
--     ('transcript_redactions', '["interactions", "users", "transcript_segments"]'::jsonb),
--     ('user_availability_events', '["people"]'::jsonb)) AS al(tb, a));
--   fx jsonb; p text;
-- BEGIN
--   PERFORM set_config('app.is_internal', 'on', true);
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ same firm A', 'funeral_home') RETURNING id INTO v_a;
--   INSERT INTO organizations (name, client_type) VALUES ('ZZZ same firm B', 'funeral_home') RETURNING id INTO v_b;
--   FOREACH t IN ARRAY ord LOOP
--     EXECUTE mk ->> t INTO nid USING v_a, fa, v_b; fa := fa || jsonb_build_object(t, nid);
--     EXECUTE mk ->> t INTO nid USING v_b, fb, v_a; fb := fb || jsonb_build_object(t, nid);
--   END LOOP;
--   -- the lowest and highest contact ids at A, for merge dismissals' a < b
--   INSERT INTO contacts (id, organization_id, full_name) VALUES ('00000000-0000-4000-8000-000000000001', v_a, 'ZZZ lowest'), ('ffffffff-ffff-4fff-bfff-fffffffffffe', v_a, 'ZZZ highest');
--   -- a case field at A, for custom_field_values.case_id
--   INSERT INTO custom_field_definitions (organization_id, entity, name) VALUES (v_a, 'case', 'ZZZ case field');
--   SET CONSTRAINTS ALL IMMEDIATE;
--
--   FOR k IN SELECT * FROM (VALUES
--       ('cost_events_account_id_fkey', 'cost_events', 'account_id', 'accounts', 'SET NULL', 'FOREIGN KEY (account_id, organization_id) REFERENCES accounts(id, organization_id) ON DELETE SET NULL (account_id)', '', NULL),
--       ('interactions_account_id_fkey', 'interactions', 'account_id', 'accounts', 'SET NULL', 'FOREIGN KEY (account_id, organization_id) REFERENCES accounts(id, organization_id) ON DELETE SET NULL (account_id)', '', NULL),
--       ('locations_account_id_fkey', 'locations', 'account_id', 'accounts', 'SET NULL', 'FOREIGN KEY (account_id, organization_id) REFERENCES accounts(id, organization_id) ON DELETE SET NULL (account_id)', '', NULL),
--       ('rate_cards_account_id_fkey', 'rate_cards', 'account_id', 'accounts', 'CASCADE', 'FOREIGN KEY (account_id, organization_id) REFERENCES accounts(id, organization_id) ON DELETE CASCADE', '', NULL),
--       ('seats_account_id_fkey', 'seats', 'account_id', 'accounts', 'SET NULL', 'FOREIGN KEY (account_id, organization_id) REFERENCES accounts(id, organization_id) ON DELETE SET NULL (account_id)', '', NULL),
--       ('subscriptions_account_id_fkey', 'subscriptions', 'account_id', 'accounts', 'SET NULL', 'FOREIGN KEY (account_id, organization_id) REFERENCES accounts(id, organization_id) ON DELETE SET NULL (account_id)', '', NULL),
--       ('campaign_spend_campaign_id_fkey', 'campaign_spend', 'campaign_id', 'campaigns', 'CASCADE', 'FOREIGN KEY (campaign_id, organization_id) REFERENCES campaigns(id, organization_id) ON DELETE CASCADE', '', NULL),
--       ('cases_source_campaign_id_fkey', 'cases', 'source_campaign_id', 'campaigns', 'SET NULL', 'FOREIGN KEY (source_campaign_id, organization_id) REFERENCES campaigns(id, organization_id) ON DELETE SET NULL (source_campaign_id)', '', NULL),
--       ('contacts_source_campaign_id_fkey', 'contacts', 'source_campaign_id', 'campaigns', 'SET NULL', 'FOREIGN KEY (source_campaign_id, organization_id) REFERENCES campaigns(id, organization_id) ON DELETE SET NULL (source_campaign_id)', '', NULL),
--       ('custom_field_values_case_id_fkey', 'custom_field_values', 'case_id', 'cases', 'CASCADE', 'FOREIGN KEY (case_id, organization_id) REFERENCES cases(id, organization_id) ON DELETE CASCADE', ', contact_id = NULL, definition_id = (SELECT d.id FROM custom_field_definitions d WHERE d.organization_id = custom_field_values.organization_id AND d.entity = ''case'' AND d.name = ''ZZZ case field'')', NULL),
--       ('interactions_case_id_fkey', 'interactions', 'case_id', 'cases', 'SET NULL', 'FOREIGN KEY (case_id, organization_id) REFERENCES cases(id, organization_id) ON DELETE SET NULL (case_id)', ', case_link_method = ''confirmed''', NULL),
--       ('leads_case_id_fkey', 'leads', 'case_id', 'cases', 'SET NULL', 'FOREIGN KEY (case_id, organization_id) REFERENCES cases(id, organization_id) ON DELETE SET NULL (case_id)', '', NULL),
--       ('outcomes_case_id_fkey', 'outcomes', 'case_id', 'cases', 'SET NULL', 'FOREIGN KEY (case_id, organization_id) REFERENCES cases(id, organization_id) ON DELETE SET NULL (case_id)', '', NULL),
--       ('reminders_case_id_fkey', 'reminders', 'case_id', 'cases', 'CASCADE', 'FOREIGN KEY (case_id, organization_id) REFERENCES cases(id, organization_id) ON DELETE CASCADE', '', NULL),
--       ('threads_case_id_fkey', 'threads', 'case_id', 'cases', 'CASCADE', 'FOREIGN KEY (case_id, organization_id) REFERENCES cases(id, organization_id) ON DELETE CASCADE', ', scope = ''case''', NULL),
--       ('cost_events_location_group_id_fkey', 'cost_events', 'location_group_id', 'location_groups', 'SET NULL', 'FOREIGN KEY (location_group_id, organization_id) REFERENCES location_groups(id, organization_id) ON DELETE SET NULL (location_group_id)', '', NULL),
--       ('locations_location_group_id_fkey', 'locations', 'location_group_id', 'location_groups', 'SET NULL', 'FOREIGN KEY (location_group_id, organization_id) REFERENCES location_groups(id, organization_id) ON DELETE SET NULL (location_group_id)', '', NULL),
--       ('person_assignments_location_group_id_fkey', 'person_assignments', 'location_group_id', 'location_groups', 'CASCADE', 'FOREIGN KEY (location_group_id, organization_id) REFERENCES location_groups(id, organization_id) ON DELETE CASCADE', ', location_id = NULL', NULL),
--       ('device_sessions_seat_id_fkey', 'device_sessions', 'seat_id', 'seats', 'CASCADE', 'FOREIGN KEY (seat_id, organization_id) REFERENCES seats(id, organization_id) ON DELETE CASCADE', '', NULL),
--       ('evaluations_seat_id_fkey', 'evaluations', 'seat_id', 'seats', 'SET NULL', 'FOREIGN KEY (seat_id, organization_id) REFERENCES seats(id, organization_id) ON DELETE SET NULL (seat_id)', '', NULL),
--       ('interactions_seat_id_fkey', 'interactions', 'seat_id', 'seats', 'SET NULL', 'FOREIGN KEY (seat_id, organization_id) REFERENCES seats(id, organization_id) ON DELETE SET NULL (seat_id)', '', NULL),
--       ('user_availability_events_seat_id_fkey', 'user_availability_events', 'seat_id', 'seats', 'SET NULL', 'FOREIGN KEY (seat_id, organization_id) REFERENCES seats(id, organization_id) ON DELETE SET NULL (seat_id)', '', NULL)
--     ) AS x(con, src, col, tgt, rule, intended, also, want_delete) LOOP
--     idc := CASE WHEN k.src = 'interaction_reads' THEN 'user_id' ELSE 'id' END;
--     -- ---- the catalogue ----
--     IF (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = k.src::regclass AND conname = k.con) = k.intended THEN
--       c_cat := c_cat + 1;
--     ELSE b_cat := b_cat || k.con || ' is: ' || COALESCE((SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = k.src::regclass AND conname = k.con), 'missing') || '; ';
--     END IF;
--     -- ---- cross-firm ----
--     BEGIN
--       fx := '{}';
--       FOR p IN SELECT jsonb_array_elements_text(anc -> k.src) LOOP EXECUTE mk ->> p INTO nid USING v_a, fx, v_b; fx := fx || jsonb_build_object(p, nid); END LOOP;
--       EXECUTE mk ->> k.src INTO sid USING v_a, fx, v_b;
--       -- the source table's own triggers off, so the key is what refuses
--       EXECUTE format('ALTER TABLE %I DISABLE TRIGGER USER', k.src);
--       fx := '{}';
--       FOR p IN SELECT jsonb_array_elements_text(anc -> k.tgt) LOOP EXECUTE mk ->> p INTO nid USING v_b, fx, v_a; fx := fx || jsonb_build_object(p, nid); END LOOP;
--       EXECUTE mk ->> k.tgt INTO tid USING v_b, fx, v_a;
--       EXECUTE format('UPDATE %I SET %I = $1::uuid' || k.also || ' WHERE %I::text = $2', k.src, k.col, idc) USING tid, sid;
--       st := 'ALLOWED';
--       RAISE EXCEPTION USING ERRCODE = 'ZZ001';
--     EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
--               WHEN foreign_key_violation THEN GET STACKED DIAGNOSTICS cname = CONSTRAINT_NAME; st := 'refused by ' || cname;
--               WHEN OTHERS THEN st := SQLSTATE || ' ' || SQLERRM;
--     END;
--     IF st = 'refused by ' || k.con THEN c_cross := c_cross + 1; ELSE b_cross := b_cross || k.con || ': ' || st || '; '; END IF;
--     -- ---- same firm, then delete ----
--     BEGIN
--       fx := '{}';
--       FOR p IN SELECT jsonb_array_elements_text(anc -> k.src) LOOP EXECUTE mk ->> p INTO nid USING v_a, fx, v_b; fx := fx || jsonb_build_object(p, nid); END LOOP;
--       EXECUTE mk ->> k.src INTO sid USING v_a, fx, v_b;
--       FOR p IN SELECT jsonb_array_elements_text(anc -> k.tgt) LOOP EXECUTE mk ->> p INTO nid USING v_a, fx, v_b; fx := fx || jsonb_build_object(p, nid); END LOOP;
--       EXECUTE mk ->> k.tgt INTO tid USING v_a, fx, v_b;
--       EXECUTE format('UPDATE %I SET %I = $1::uuid' || k.also || ' WHERE %I::text = $2', k.src, k.col, idc) USING tid, sid;
--       st := 'allowed';
--       BEGIN
--         EXECUTE format('DELETE FROM %I WHERE id = $1::uuid', k.tgt) USING tid;
--         EXECUTE format('SELECT CASE WHEN count(*) = 0 THEN ''source row gone''
--                                     WHEN bool_and(%I IS NULL AND organization_id = $2) THEN ''pointer cleared, firm kept''
--                                     ELSE ''source row unchanged'' END FROM %I WHERE %I::text = $1', k.col, k.src, idc)
--           INTO msg USING sid, v_a;
--       EXCEPTION WHEN foreign_key_violation THEN GET STACKED DIAGNOSTICS cname = CONSTRAINT_NAME; msg := 'delete refused by ' || cname;
--                 WHEN check_violation THEN GET STACKED DIAGNOSTICS cname = CONSTRAINT_NAME; msg := 'delete refused by check ' || cname;
--                 WHEN OTHERS THEN msg := 'delete: ' || SQLSTATE || ' ' || SQLERRM;
--       END;
--       RAISE EXCEPTION USING ERRCODE = 'ZZ001';
--     EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
--               WHEN OTHERS THEN st := SQLSTATE || ' ' || SQLERRM; msg := 'not reached';
--     END;
--     IF st = 'allowed' THEN c_same := c_same + 1; ELSE b_same := b_same || k.con || ': ' || st || '; '; END IF;
--     want := COALESCE(k.want_delete, CASE k.rule WHEN 'CASCADE' THEN 'source row gone' WHEN 'SET NULL' THEN 'pointer cleared, firm kept'
--                         ELSE 'delete refused by ' || k.con END);
--     IF msg = want THEN c_del := c_del + 1;
--     ELSE b_del := b_del || k.con || ' (' || k.rule || '): ' || msg || '; '; END IF;
--   END LOOP;
--
--   SELECT count(*) INTO c_idx FROM unnest(ARRAY['accounts', 'cases', 'seats', 'campaigns', 'location_groups']) tg
--    WHERE EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = tg::regclass AND i.indisunique
--                    AND i.indkey::text = (SELECT attnum FROM pg_attribute WHERE attrelid = tg::regclass AND attname = 'id') || ' '
--                                      || (SELECT attnum FROM pg_attribute WHERE attrelid = tg::regclass AND attname = 'organization_id'));
--   r := r || '1. targets with a unique (id, organization_id) index: ' || c_idx || ' of 5   (expect 5 of 5)' || chr(10);
--   r := r || '2. keys exactly as intended in the catalogue (composite columns, ON DELETE with its column list, deferrability): '
--          || c_cat || ' of 22' || CASE WHEN b_cat <> '' THEN ' — ' || b_cat ELSE '' END || '   (expect 22 of 22)' || chr(10);
--   r := r || '3. pointed at the other firm''s row, refused by the key itself: ' || c_cross || ' of 22'
--          || CASE WHEN b_cross <> '' THEN ' — ' || b_cross ELSE '' END || '   (expect 22 of 22)' || chr(10);
--   r := r || '4. pointed at a row of its own firm, allowed: ' || c_same || ' of 22'
--          || CASE WHEN b_same <> '' THEN ' — ' || b_same ELSE '' END || '   (expect 22 of 22)' || chr(10);
--   r := r || '5. the target row deleted, the rule as before (15 SET NULL, 7 CASCADE): ' || c_del || ' of 22'
--          || CASE WHEN b_del <> '' THEN ' — ' || b_del ELSE '' END || '   (expect 22 of 22)' || chr(10);
--   PERFORM set_config('app.is_internal', 'off', true);
--   RAISE EXCEPTION 'VERIFY 20261123T1834_same_firm_accounts_cases_seats (all rolled back) %', chr(10) || r;
-- END $$;
-- =============================================================================
