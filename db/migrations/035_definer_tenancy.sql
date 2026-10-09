-- =============================================================================
-- 035_definer_tenancy.sql
-- The Hub — migration 35: SECURITY DEFINER functions that trusted their input.
--
-- A SECURITY DEFINER function runs as its owner and bypasses row-level
-- security. That is the point of one — and it means the function itself has to
-- do the tenancy check the policies would have done. An audit of every definer
-- function (026–029, 034) found three that did not.
--
-- ONE — find_or_start_thread() / post_to_thread() (034). The organization is
-- read from the subject's own row and never compared with the caller's. Any
-- signed-in user holding another firm's contact or case id could post into
-- that firm's internal chat. The 034 comment says this cannot happen; it was
-- not enforced. Now the subject must be in the caller's organization (or the
-- caller internal), and a post's "about" interaction must be in the thread's.
--
-- TWO — dialstack_identity(p_user) / dialstack_identity_gaps(p_user) (029).
-- Both accept any user id and return that user's person, firm, seat, extension
-- and Dial Stack ids — or their email and configuration gaps. Now a caller can
-- ask about themselves; only internal staff can name someone else.
--
-- THREE — dialstack_identity_gaps_all() (029) was never granted, so it kept
-- Postgres's default EXECUTE for PUBLIC. On Supabase that reaches the anon
-- role, whose key ships in every browser bundle: anyone could list every Hub
-- user's email. Now it returns nothing to non-internal callers, and anon and
-- PUBLIC lose EXECUTE on it and on the other functions here.
--
-- Deliberately NOT revoked from anon: current_user_id(), is_internal(),
-- current_organization_id(). Row-level policies call them as whatever role is
-- querying, anon included; revoking would turn an empty result into an error.
-- They only ever describe the caller, so there is nothing to leak.
--
-- Failure messages for a subject in another organization are the same as for a
-- subject that does not exist, so the function cannot be used to probe which
-- ids are real.
--
-- Requires: 001 to 034
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- ONE — threads: the subject must be in the caller's organization
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION find_or_start_thread(
  p_scope thread_scope,
  p_subject uuid,
  p_title text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid; v_org uuid; v_user uuid; v_title text; v_internal boolean;
BEGIN
  v_user := current_user_id();
  v_internal := is_internal();

  -- A browser session must be a signed-in Hub user. Service and migration
  -- sessions arrive as internal with no user, and stay allowed.
  IF v_user IS NULL AND NOT v_internal THEN
    RAISE EXCEPTION 'not signed in — call claim_hub_identity() first';
  END IF;

  IF p_scope NOT IN ('contact', 'case', 'interaction') THEN
    RAISE EXCEPTION 'threads on a % are not started this way', p_scope;
  END IF;

  v_org := CASE p_scope
    WHEN 'contact'     THEN (SELECT organization_id FROM contacts     WHERE id = p_subject)
    WHEN 'case'        THEN (SELECT organization_id FROM cases        WHERE id = p_subject)
    WHEN 'interaction' THEN (SELECT organization_id FROM interactions WHERE id = p_subject)
  END;

  -- Missing, or someone else's: the same answer either way.
  IF v_org IS NULL
     OR (NOT v_internal AND v_org IS DISTINCT FROM current_organization_id()) THEN
    RAISE EXCEPTION 'no such % to start a thread on', p_scope;
  END IF;

  SELECT t.id INTO v_id FROM threads t
  WHERE t.organization_id = v_org
    AND t.scope = p_scope
    AND CASE p_scope
          WHEN 'contact'     THEN t.contact_id
          WHEN 'case'        THEN t.case_id
          WHEN 'interaction' THEN t.interaction_id
        END = p_subject
  LIMIT 1;

  IF v_id IS NULL THEN
    v_title := COALESCE(p_title, CASE p_scope
      WHEN 'contact' THEN (SELECT COALESCE(full_name, business_name)
                             FROM contacts WHERE id = p_subject)
      WHEN 'case'    THEN 'Case — ' || COALESCE(
                             (SELECT d.first_name || ' ' || d.last_name
                                FROM decedents d
                                JOIN interaction_decedents idc ON idc.decedent_id = d.id
                                JOIN interactions i ON i.id = idc.interaction_id
                               WHERE i.case_id = p_subject LIMIT 1),
                             'arrangement')
      ELSE 'Call'
    END);

    INSERT INTO threads (organization_id, scope, contact_id, case_id,
                         interaction_id, title, created_by, last_message_at)
    VALUES (v_org, p_scope,
            CASE WHEN p_scope = 'contact'     THEN p_subject END,
            CASE WHEN p_scope = 'case'        THEN p_subject END,
            CASE WHEN p_scope = 'interaction' THEN p_subject END,
            v_title, v_user, NULL)
    RETURNING id INTO v_id;
  END IF;

  IF v_user IS NOT NULL THEN
    INSERT INTO thread_participants (thread_id, user_id)
    VALUES (v_id, v_user) ON CONFLICT DO NOTHING;
  END IF;

  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION post_to_thread(
  p_scope thread_scope,
  p_subject uuid,
  p_body text,
  p_about_interaction uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_thread uuid; v_user uuid; v_org uuid; v_id uuid;
BEGIN
  IF btrim(COALESCE(p_body, '')) = '' THEN
    RAISE EXCEPTION 'a message needs a body';
  END IF;

  v_user := current_user_id();
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'not signed in — call claim_hub_identity() first';
  END IF;

  -- The organization check lives in find_or_start_thread().
  v_thread := find_or_start_thread(p_scope, p_subject);
  SELECT organization_id INTO v_org FROM threads WHERE id = v_thread;

  -- A post can only point at a call in the same firm.
  IF p_about_interaction IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM interactions
       WHERE id = p_about_interaction AND organization_id = v_org) THEN
    RAISE EXCEPTION 'no such interaction to refer to';
  END IF;

  INSERT INTO thread_messages (organization_id, thread_id, sender_user_id,
                               body, interaction_id, sent_at)
  VALUES (v_org, v_thread, v_user, btrim(p_body), p_about_interaction, now())
  RETURNING id INTO v_id;

  RETURN v_id;
END $$;

-- -----------------------------------------------------------------------------
-- TWO — Dial Stack identity: yourself, unless internal
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dialstack_identity(p_user uuid DEFAULT NULL)
RETURNS TABLE (
  user_id            uuid,
  person_id          uuid,
  full_name          text,
  organization_id    uuid,
  organization_name  text,
  seat_id            uuid,
  seat_label         text,
  extension          text,
  dialstack_user     text,
  dialstack_account  text
) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT u.id, p.id, p.full_name, p.organization_id, o.name,
         s.id, s.label, s.extension, s.external_ref, a.external_ref
  FROM users u
  JOIN people p        ON p.id = u.person_id
  JOIN organizations o ON o.id = p.organization_id
  JOIN seats s         ON s.person_id = p.id AND s.active
  LEFT JOIN accounts a ON a.id = s.account_id
  WHERE u.id = COALESCE(p_user, current_user_id())
    AND (p_user IS NULL OR p_user = current_user_id() OR is_internal())
    AND s.external_ref IS NOT NULL
  ORDER BY s.created_at
  LIMIT 1
$$;

CREATE OR REPLACE FUNCTION dialstack_identity_gaps(p_user uuid DEFAULT NULL)
RETURNS TABLE (user_email text, gap text, fix text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT u.email,
    CASE
      WHEN u.person_id IS NULL
        THEN 'no person — the Hub does not know which firm they work at'
      WHEN NOT EXISTS (SELECT 1 FROM seats s WHERE s.person_id = u.person_id AND s.active)
        THEN 'no active seat'
      WHEN NOT EXISTS (SELECT 1 FROM seats s
                       WHERE s.person_id = u.person_id AND s.active
                         AND s.external_ref IS NOT NULL)
        THEN 'seat exists but carries no Dial Stack user id'
      WHEN NOT EXISTS (SELECT 1 FROM seats s JOIN accounts a ON a.id = s.account_id
                       WHERE s.person_id = u.person_id AND s.active
                         AND a.external_ref IS NOT NULL)
        THEN 'seat has no account, or the account carries no Dial Stack account id'
      ELSE 'none'
    END,
    CASE
      WHEN u.person_id IS NULL
        THEN 'create a people row under their organization and set users.person_id'
      WHEN NOT EXISTS (SELECT 1 FROM seats s WHERE s.person_id = u.person_id AND s.active)
        THEN 'create a seat for that person'
      WHEN NOT EXISTS (SELECT 1 FROM seats s
                       WHERE s.person_id = u.person_id AND s.active
                         AND s.external_ref IS NOT NULL)
        THEN 'set seats.external_ref to their user_... id'
      WHEN NOT EXISTS (SELECT 1 FROM seats s JOIN accounts a ON a.id = s.account_id
                       WHERE s.person_id = u.person_id AND s.active
                         AND a.external_ref IS NOT NULL)
        THEN 'point the seat at an account and set accounts.external_ref to acct_...'
      ELSE 'nothing'
    END
  FROM users u
  WHERE u.id = COALESCE(p_user, current_user_id())
    AND (p_user IS NULL OR p_user = current_user_id() OR is_internal())
$$;

-- -----------------------------------------------------------------------------
-- THREE — everyone's gaps: internal staff only
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dialstack_identity_gaps_all()
RETURNS TABLE (user_email text, gap text, fix text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT g.* FROM users u
  CROSS JOIN LATERAL dialstack_identity_gaps(u.id) g
  WHERE is_internal()
    AND g.gap <> 'none'
  ORDER BY g.user_email
$$;

-- -----------------------------------------------------------------------------
-- Who may call them at all
--
-- Postgres grants EXECUTE to PUBLIC on every new function, and Supabase's
-- default privileges add anon. None of these is for an anonymous caller.
-- -----------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION find_or_start_thread(thread_scope, uuid, text)     FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION post_to_thread(thread_scope, uuid, text, uuid)     FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION dialstack_identity(uuid)                           FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION dialstack_identity_gaps(uuid)                      FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION dialstack_identity_gaps_all()                      FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION claim_hub_identity()                               FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION set_active_organization(uuid)                      FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION my_organizations()                                 FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION find_or_start_thread(thread_scope, uuid, text)      TO authenticated;
GRANT EXECUTE ON FUNCTION post_to_thread(thread_scope, uuid, text, uuid)      TO authenticated;
GRANT EXECUTE ON FUNCTION dialstack_identity(uuid)                            TO authenticated;
GRANT EXECUTE ON FUNCTION dialstack_identity_gaps(uuid)                       TO authenticated;
GRANT EXECUTE ON FUNCTION dialstack_identity_gaps_all()                       TO authenticated;
GRANT EXECUTE ON FUNCTION claim_hub_identity()                                TO authenticated;
GRANT EXECUTE ON FUNCTION set_active_organization(uuid)                       TO authenticated;
GRANT EXECUTE ON FUNCTION my_organizations()                                  TO authenticated;

COMMIT;

-- =============================================================================
-- Verification
--
-- 0. Before applying — is the exposure real on this project? (read-only)
--
--   SELECT p.proname,
--          has_function_privilege('anon', p.oid, 'EXECUTE')          AS anon_can_execute,
--          has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_can_execute
--   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--   WHERE n.nspname = 'public' AND p.prosecdef
--   ORDER BY p.proname;
--
-- 1. After — no definer function here is callable by anon except the three
--    the policies need (current_user_id, is_internal, current_organization_id)
--
--   (same query; expect anon_can_execute = false for everything else)
--
-- 2. Cross-tenant post refused, with the not-found message
--
--   SET app.user_id = '<a user in organization A>';
--   SELECT post_to_thread('contact', '<a contact in organization B>', 'test');
--   -- expect: no such contact to start a thread on
--
-- 3. Same-tenant post still works (staging only)
--
--   SELECT post_to_thread('contact', '<a contact in the user''s organization>', 'test');
--
-- 4. Someone else's Dial Stack identity is no longer readable
--
--   SELECT * FROM dialstack_identity('<another user id>');   -- as a non-internal user
--   -- expect: no rows
-- =============================================================================
