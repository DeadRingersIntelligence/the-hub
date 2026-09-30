-- ==========================================================================
-- 013a_reference.sql  —  five clients, part A of D
--
-- Organizations, behaviors absent from the rubric lookup, locations, people, rubrics.
--
-- Run parts A, B, C and D in order. Each is its own transaction.
-- ==========================================================================

BEGIN;

INSERT INTO organizations (code, name, client_type, status) VALUES
  ('DOUG', 'Douglass', 'funeral_home', 'active'),
  ('DPX', 'Diocese of Phoenix', 'combo', 'active'),
  ('GIV', 'Givnish', 'funeral_home', 'active'),
  ('PPD', 'Peaceful Pets', 'pet', 'active'),
  ('WHIT', 'Whitaker', 'funeral_home', 'active')
ON CONFLICT (code) DO NOTHING;

-- Scored in production, absent from reviewer_form_points.
INSERT INTO behaviors (code, label, section_id, score_category, answered_by) VALUES
  ('custom_fields_professional_name_live', 'custom_fields_professional_name', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('custom_fields_is_this_a_complete_call_live', 'custom_fields_is_this_a_complete_call', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('custom_fields_value_statement_live', 'custom_fields_value_statement', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('custom_fields_final_impression_live', 'custom_fields_final_impression', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('custom_fields_client_name_live', 'custom_fields_client_name', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('custom_fields_website_live', 'custom_fields_website', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('custom_fields_location_type_live', 'custom_fields_location_type', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('custom_fields_package_type_live', 'custom_fields_package_type', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('custom_fields_brand_parent_company_live', 'custom_fields_brand_parent_company', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('custom_fields_director_live', 'custom_fields_director', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('custom_fields_competitor_live', 'custom_fields_competitor', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('custom_fields_pre_need_or_at_need_script_live', 'custom_fields_pre_need_or_at_need_script', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('why_did_you_have_to_make_multiple_attempts_to_reach__live', 'Why did you have to make multiple attempts to reach a professional?', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('please_enter_the_name_of_the_professional_that_you_s_live', 'Please enter the name of the professional that you spoke with.', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('did_they_ask_if_you_had_pre_arrangements_on_file_or__live', 'Did they ask if you had pre-arrangements on file, or had utilized their services in the past?', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('did_they_ask_if_you_had_any_relevant_affiliations_or_live', 'Did they ask if you had any relevant affiliations or memberships? (i.e. Military, Non-profit, Discount programs)', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('what_did_they_say_regarding_their_competitor_live', 'What did they say regarding their competitor?', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('did_they_mention_budget_financing_or_insurance_live', 'Did they mention budget, financing or insurance?', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('what_was_the_cost_for_first_service_package_they_off_live', 'What was the cost for FIRST service/package they offered?', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('when_describing_services_did_they_give_a_reason_for__live', 'When describing services, did they give a reason for their value?', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('did_they_describe_any_requirements_or_regulations_re_live', 'Did they describe any requirements or regulations related to their products or services?', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('did_the_professional_attempt_to_upsell_you_on_a_prod_live', 'Did the professional attempt to upsell you on a product or service?', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('did_the_professional_express_condolences_and_or_empa_live', 'Did the professional express condolences and/or empathetic statements?', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('did_they_ask_how_you_heard_of_them_or_whether_you_ha_live', 'Did they ask how you heard of them, or whether you had prior interactions with their firm?', (SELECT id FROM rubric_sections WHERE code='lead_information'), 'objective', 'reviewer'),
  ('did_they_attempt_to_set_an_appointment_or_close_the__live', 'Did they attempt to set an appointment or "close the sale"?', (SELECT id FROM rubric_sections WHERE code='follow_up'), 'objective', 'reviewer'),
  ('did_they_express_gratitude_for_your_call_live', 'Did they express gratitude for your call?', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('did_they_lead_with_direct_cremation_live', 'Did they lead with direct cremation?', (SELECT id FROM rubric_sections WHERE code='services_pricing'), 'objective', 'reviewer'),
  ('did_they_offer_a_value_statement_or_explain_why_thei_live', 'Did they offer a value statement or explain why their business/service is unique?', (SELECT id FROM rubric_sections WHERE code='services_pricing'), 'objective', 'reviewer'),
  ('reviewer_name_live', 'Reviewer Name', (SELECT id FROM rubric_sections WHERE code='initial_answer'), 'objective', 'reviewer'),
  ('when_describing_services_did_they_attempt_to_upsell__live', 'When describing services, did they attempt to upsell by offering additional services like catering or memorialization merchandise, casket or urn options?', (SELECT id FROM rubric_sections WHERE code='services_pricing'), 'objective', 'reviewer'),
  ('is_this_a_complete_call_live', 'Is this a complete call', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('was_it_easy_to_reach_the_right_professional_live', 'Was it easy to reach the right professional?', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('did_they_seem_prepared_live', 'Did they seem prepared?', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('were_the_clear_and_concise_live', 'Were the clear and concise?', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('did_they_provide_enough_information_live', 'Did they provide enough information?', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('how_would_you_describe_their_phone_etiquette_live', 'How would you describe their phone etiquette?', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('did_they_show_sincere_concern_live', 'Did they show sincere concern?', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('would_you_trust_them_live', 'Would you trust them?', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('would_you_hire_this_person_live', 'Would you hire this person?', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('would_you_hire_this_company_live', 'Would you hire this company?', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('did_this_call_meet_your_expectations_live', 'Did this call meet your expectations?', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('script_type_live', 'Script Type', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('were_there_multiple_attempts_to_reach_a_professional_live', 'Were there multiple attempts to reach a professional?', (SELECT id FROM rubric_sections WHERE code='initial_answer'), 'objective', 'reviewer'),
  ('were_any_of_your_call_attempts_answered_by_an_automa_live', 'Were any of your call attempts answered by an automated message?', (SELECT id FROM rubric_sections WHERE code='initial_answer'), 'objective', 'reviewer'),
  ('did_they_have_any_poor_phone_behaviors_live', 'Did they have any poor phone behaviors?', (SELECT id FROM rubric_sections WHERE code='etiquette'), 'objective', 'reviewer'),
  ('how_long_before_callback_live', 'How long before Callback?', (SELECT id FROM rubric_sections WHERE code='initial_answer'), 'objective', 'reviewer'),
  ('how_many_prompts_did_you_have_to_go_through_to_reach_live', 'How many prompts did you have to go through to reach a live representative?', (SELECT id FROM rubric_sections WHERE code='initial_answer'), 'objective', 'reviewer'),
  ('were_you_transferred_to_voicemail_or_a_live_agent_live', 'Were you transferred to voicemail or a live agent?', (SELECT id FROM rubric_sections WHERE code='hold_transfer'), 'objective', 'reviewer'),
  ('did_you_have_to_repeat_any_information_to_the_new_pr_live', 'Did you have to repeat any information to the new professional?', (SELECT id FROM rubric_sections WHERE code='hold_transfer'), 'objective', 'reviewer'),
  ('immediate_abrupt_hold_live', 'Immediate abrupt hold?', (SELECT id FROM rubric_sections WHERE code='hold_transfer'), 'objective', 'reviewer'),
  ('transferred_more_than_once_live', 'Transferred more than once?', (SELECT id FROM rubric_sections WHERE code='hold_transfer'), 'objective', 'reviewer')
ON CONFLICT (code) DO NOTHING;

-- location_type is what splits a combo firm's scoring.
INSERT INTO locations (organization_id, name, location_type, funeral_rule_applies, city, state) VALUES
  ((SELECT id FROM organizations WHERE code='DOUG'), 'Cremation Society of Laguna', 'cremation', true, 'Laguna Hills', 'CA'),
  ((SELECT id FROM organizations WHERE code='DOUG'), 'Cremation Society of Orange Coast', 'cremation', true, 'Garden Grove', 'CA'),
  ((SELECT id FROM organizations WHERE code='DOUG'), 'Douglas and Dunaway Mortuary', 'funeral_home', true, 'Hawthorne', 'CA'),
  ((SELECT id FROM organizations WHERE code='DOUG'), 'Douglass Family Mortuary - Lynwood', 'funeral_home', true, 'Lynwood', 'CA'),
  ((SELECT id FROM organizations WHERE code='DOUG'), 'Douglass Mortuary - El Segundo', 'funeral_home', true, 'El Segundo', 'CA'),
  ((SELECT id FROM organizations WHERE code='DPX'), 'Holy Cross Catholic Cemetery and Funeral Home', 'combo', true, 'Avondale', 'AZ'),
  ((SELECT id FROM organizations WHERE code='DPX'), 'Holy Redeemer Catholic Cemetery', 'cemetery', false, 'Phoenix', 'AZ'),
  ((SELECT id FROM organizations WHERE code='GIV'), 'Boyd Horrox Givnish Funeral Home', 'funeral_home', true, 'Norristown', 'PA'),
  ((SELECT id FROM organizations WHERE code='GIV'), 'Craft Givnish Funeral Home', 'funeral_home', true, 'Abington', 'PA'),
  ((SELECT id FROM organizations WHERE code='GIV'), 'JFG Buckingham', 'funeral_home', true, 'Buckingham', 'PA'),
  ((SELECT id FROM organizations WHERE code='GIV'), 'John F Givnish Funeral Home', 'funeral_home', true, 'Philadelphia', 'PA'),
  ((SELECT id FROM organizations WHERE code='GIV'), 'Keates Plum Funeral Home', 'funeral_home', true, 'Briganine', 'NJ'),
  ((SELECT id FROM organizations WHERE code='GIV'), 'McGhee Givnish Funeral Home', 'funeral_home', true, 'Southampton', 'PA'),
  ((SELECT id FROM organizations WHERE code='PPD'), 'Peaceful Pets', 'pet', false, 'Arlington', 'TX'),
  ((SELECT id FROM organizations WHERE code='PPD'), 'Peaceful Pets Dallas', 'pet', false, 'Arlington', 'TX'),
  ((SELECT id FROM organizations WHERE code='WHIT'), 'Whitaker Funeral Home - Chapin', 'funeral_home', true, 'Chapin', 'SC'),
  ((SELECT id FROM organizations WHERE code='WHIT'), 'Whitaker Funeral Home - Newberry', 'funeral_home', true, 'Newberry', 'SC')
ON CONFLICT DO NOTHING;

INSERT INTO people (organization_id, full_name, person_type, status) VALUES
  ((SELECT id FROM organizations WHERE code='DOUG'), 'Kim', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='DOUG'), 'Lauralee', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='DOUG'), 'Not Given', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='DOUG'), 'Sean Douglass', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='DOUG'), 'Sylvia', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='DOUG'), 'Vera', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='DOUG'), 'Veronica', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='DPX'), 'Judy', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='DPX'), 'Liz Hansen', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='DPX'), 'Lupe', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='GIV'), 'Andrew Hoffman', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='GIV'), 'Chandler', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='GIV'), 'John Givnish', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='GIV'), 'Rick', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='GIV'), 'Robin', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='GIV'), 'taylor', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='PPD'), 'Amanda', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='PPD'), 'AnaMarie', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='PPD'), 'Jennifer', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='PPD'), 'Leslie', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='PPD'), 'Paytin', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='PPD'), 'Robert Paek', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='PPD'), 'STEPHANIE', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='PPD'), 'Stephanie', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='PPD'), 'Stephenie', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='PPD'), 'Tessa', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='PPD'), 'not given', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='WHIT'), 'Courtney', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='WHIT'), 'Derek', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='WHIT'), 'Derrick', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='WHIT'), 'Erin Whitaker', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='WHIT'), 'James', 'client_staff', 'active'),
  ((SELECT id FROM organizations WHERE code='WHIT'), 'Meagan', 'client_staff', 'active')
ON CONFLICT DO NOTHING;

INSERT INTO rubrics (organization_id, name, rubric_type, version) VALUES
  ((SELECT id FROM organizations WHERE code='DOUG'), 'Douglass CX', 'cx', '2026.09'),
  ((SELECT id FROM organizations WHERE code='DPX'), 'Diocese of Phoenix CX', 'cx', '2026.09'),
  ((SELECT id FROM organizations WHERE code='GIV'), 'Givnish CX', 'cx', '2026.09'),
  ((SELECT id FROM organizations WHERE code='PPD'), 'Peaceful Pets CX', 'cx', '2026.09'),
  ((SELECT id FROM organizations WHERE code='WHIT'), 'Whitaker CX', 'cx', '2026.09')
ON CONFLICT (organization_id, name, version) DO NOTHING;

COMMIT;
