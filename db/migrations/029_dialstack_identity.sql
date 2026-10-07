-- =============================================================================
-- 029_dialstack_identity.sql
-- The Hub — migration 29: resolving a signed-in person to their Dial Stack
-- account and user, for minting a softphone token.
--
-- No new columns. The mapping was designed in:
--
--   accounts.external_ref   -- "Dial Stack account id"   (migration 001)
--   seats.external_ref      -- "Dial Stack user id"      (migration 003)
--
-- Both comments say so. What is missing is three things around them:
-- uniqueness, so the same Dial Stack identity cannot be claimed twice; one
-- lookup, so the token mint is a single call rather than a join written out at
-- every call site; and an explicit statement of what a seat is, because the
-- resolution path depends on it.
--
-- WHY THE ACCOUNT ID IS ON `accounts` AND NOT `organizations`. An organization
-- can hold several accounts — Anima-Care runs four states through one, and the
-- reverse is just as possible. `accounts` is the billing construct, which is
-- exactly what a Dial Stack account is. On `organizations` the id would have to
-- be either wrong or duplicated the moment a second account appeared.
--
-- WHERE SOMEONE WORKS vs WHAT THEY CAN SEE. These are different facts and the
-- softphone needs the first. `users.person_id` → `people.organization_id` is
-- where someone works; every person belongs to a firm, including Dead Ringers
-- staff. `user_scopes` is what they can see, and an internal scope with a null
-- organization grants cross-firm visibility without saying anything about
-- whose phone system is theirs. A softphone resolved from scope would give an
-- internal user no account at all, or the wrong one.
--
-- Requires: 001 to 028
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- One Dial Stack identity, one row
--
-- Two seats pointing at the same Dial Stack user would both mint tokens for it,
-- and the second person would answer the first person's calls. Silently.
-- -----------------------------------------------------------------------------
CREATE UNIQUE INDEX seats_external_ref_uq
  ON seats (external_ref) WHERE external_ref IS NOT NULL;

CREATE UNIQUE INDEX accounts_external_ref_uq
  ON accounts (external_ref) WHERE external_ref IS NOT NULL;

COMMENT ON COLUMN seats.external_ref IS
  'The Dial Stack user id (user_...) this seat is. A seat is a phone presence '
  'and so is a Dial Stack user, so they are the same thing. Unique: two seats '
  'claiming one Dial Stack user would both mint tokens for it.';

COMMENT ON COLUMN accounts.external_ref IS
  'The Dial Stack account id (acct_...) for this account. On accounts rather '
  'than organizations because an organization can hold several.';

-- A seat's account must belong to the seat's own organization. Without this a
-- seat could resolve to another firm's Dial Stack account — the one mapping
-- mistake that would be actively dangerous rather than merely broken.
CREATE OR REPLACE FUNCTION seats_account_same_org() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.account_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM accounts a
                     WHERE a.id = NEW.account_id
                       AND a.organization_id = NEW.organization_id)
  THEN RAISE EXCEPTION 'that account belongs to a different organization';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER seats_account_org_ck BEFORE INSERT OR UPDATE ON seats
  FOR EACH ROW EXECUTE FUNCTION seats_account_same_org();

-- -----------------------------------------------------------------------------
-- The resolution
--
--   users.person_id → people → seats (by person_id)
--     seats.external_ref                     = the Dial Stack user
--     seats.account_id → accounts.external_ref = the Dial Stack account
--
-- Both ids come off the seat. The token mint needs them together, so this
-- returns them together rather than leaving the join to be written out —
-- and rewritten slightly differently — at every call site.
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
    AND s.external_ref IS NOT NULL
  ORDER BY s.created_at
  LIMIT 1
$$;

GRANT EXECUTE ON FUNCTION dialstack_identity(uuid) TO authenticated;

COMMENT ON FUNCTION dialstack_identity(uuid) IS
  'Everything the softphone token mint needs, in one call. Defaults to the '
  'signed-in user. Returns no row when any link is missing — see '
  'dialstack_identity_gaps() for which one.';

-- -----------------------------------------------------------------------------
-- What is missing, and where
--
-- A missing link makes dialstack_identity() return nothing, which looks exactly
-- like "this person has no softphone" and says nothing about why. This names
-- the break. Given how much of this build has turned on a query that returned
-- zero rows without complaining, it earns its place.
-- -----------------------------------------------------------------------------
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
$$;

GRANT EXECUTE ON FUNCTION dialstack_identity_gaps(uuid) TO authenticated;

-- Everyone who is supposed to have a softphone and cannot get one.
CREATE OR REPLACE FUNCTION dialstack_identity_gaps_all()
RETURNS TABLE (user_email text, gap text, fix text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT g.* FROM users u
  CROSS JOIN LATERAL dialstack_identity_gaps(u.id) g
  WHERE g.gap <> 'none'
  ORDER BY g.user_email
$$;

COMMIT;

-- =============================================================================
-- Verification and setup
--
--   SET app.is_internal = 'on';
--
-- 1. Who cannot get a softphone, and why
--
--   SELECT * FROM dialstack_identity_gaps_all();
--
-- 2. Dead Ringers as an organization, if it does not exist. It is a firm with a
--    phone system like any other — the same shape CTM uses, where the agency
--    sees across clients and the agency's own phones live in its own account.
--
--   INSERT INTO organizations (code, name, client_type, status)
--   VALUES ('DR', 'Dead Ringers', 'agency', 'active')
--   ON CONFLICT (code) DO NOTHING;
--
-- 3. Mandie as a person there, and her user pointed at it
--
--   INSERT INTO people (organization_id, full_name, person_type, status)
--   SELECT id, 'Mandie Hungarland', 'internal_staff', 'active'
--   FROM organizations WHERE code = 'DR'
--   ON CONFLICT DO NOTHING;
--
--   UPDATE users SET person_id = (
--     SELECT p.id FROM people p JOIN organizations o ON o.id = p.organization_id
--     WHERE o.code = 'DR' AND p.full_name = 'Mandie Hungarland')
--   WHERE lower(email) = lower('mandie@deadringers.co');
--
-- 4. The account and the seat, from the sandbox ids
--
--   INSERT INTO accounts (organization_id, name, external_ref, is_default)
--   SELECT id, 'Dead Ringers', 'acct_...', true
--   FROM organizations WHERE code = 'DR';
--
--   INSERT INTO seats (organization_id, account_id, label, seat_type,
--                      person_id, external_ref)
--   SELECT o.id, a.id, 'Mandie', 'named', p.id, 'user_...'
--   FROM organizations o
--   JOIN accounts a ON a.organization_id = o.id
--   JOIN people   p ON p.organization_id = o.id
--   WHERE o.code = 'DR' AND p.full_name = 'Mandie Hungarland';
--
-- 5. Then the mint has everything in one call
--
--   SELECT * FROM dialstack_identity(
--     (SELECT id FROM users WHERE lower(email) = lower('mandie@deadringers.co')));
--
-- 6. And a seat cannot point at another firm's account
--
--   UPDATE seats SET account_id = (
--     SELECT a.id FROM accounts a JOIN organizations o ON o.id = a.organization_id
--     WHERE o.code = 'ALT' LIMIT 1)
--   WHERE external_ref = 'user_...';
--   -- expect: that account belongs to a different organization
-- =============================================================================
