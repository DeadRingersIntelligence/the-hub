# The Hub — database

Postgres, hosted on Supabase. Schema designed September 2026 across seven
client pressure tests; see *The Hub — Consolidated Table List* for the
reasoning behind every table.

## Layout

```
db/migrations/   structural changes, run in order, never re-run
db/seeds/        data loads — the rubric, and real client calls for validation
```

## Running them

Migrations run **in numeric order** and each is a single transaction. They are
not idempotent: running one twice fails on the first `CREATE TABLE` because the
table already exists. That is intended — a migration is a one-time change.

Paste into the Supabase SQL Editor, one file per query, in order.

### Two things that will happen

**Supabase's row-level-security warning fires on data-only files.** Its scanner
reads the word "their" inside a rubric question as a table name and warns about
a `CREATE TABLE` that isn't there. If the file contains no `CREATE`, "Run
without RLS" is correct. If it does contain `CREATE TABLE`, read it first.

**The editor rejects files over roughly 1 MB.** That is why migration 013 is
split into six parts. Run them in letter order.

## Order

| # | File | What it establishes |
|---|---|---|
| 001 | `tenancy` | Organizations, location groups, accounts, locations. The RLS mechanism everything else inherits |
| 002 | `configuration` | Capabilities, retention policies, data sharing agreements |
| 003 | `people_and_access` | People, assignments, seats, hot-desk sessions, users, scopes, partners |
| 004 | `numbers_and_marketing` | Phone numbers, campaigns, spend, referral sources, dated number assignments, tags |
| 005 | `identity` | Contacts, decedents, links, cases, leads |
| 006 | `interactions` | The universal event, participants, links, tags, messages, price quotes |
| 007 | `behaviors_and_rubrics` | Sections, behaviors, answer options with FTC flags, rubrics |
| 008 | `evaluations` | Evaluations, observations, transcript segments |
| 009 | `shops_and_outcomes` | Shops, shopper forms, outcomes, entitlements |
| 010 | `reporting` | Scoring versions, benchmarks, reporting periods, report definitions |
| 014 | `measurement_and_menu_scoring` | How a behavior is measured; menu-scored sections |
| 015 | `contact_phones` | Contacts hold many numbers; merge |
| 016 | `change_history` | The user-facing record of what happened to a record |

Seeds sit between 010 and 014 chronologically but are data, not structure:

| # | File | What it loads |
|---|---|---|
| 011 | `rubric_seed` | 77 behaviors, 240 answer options, generated from the live BigQuery rubric |
| 012 | `seed_altmeyer` | 12 real August 2026 shops |
| 013a–d3 | `seed_multiclient` | 38 real shops across five more clients, three verticals |

## Session settings

Every session must set its tenant before reading anything:

```sql
SET app.organization_id = '<uuid>';   -- a client session
SET app.is_internal = 'on';           -- Dead Ringers staff and migrations
```

**A session that sets neither sees nothing.** That is the safe default: a
forgotten `SET` returns an empty result rather than leaking across tenants.

The setting lasts only for the run it is in. A `SET` in one query and an
`INSERT … SELECT` in another means the read returns nothing, so the insert
silently does nothing — success, no rows, no clue. Keep them in one block.

## Reading a test result

Several migrations end in verification blocks that are **supposed to fail**. An
error naming a constraint — `locations_funeral_rule_ck`, `outcomes_won_ck`,
`change_history_actor_ck` — means the guardrail works.

A failing test that returns "success, no rows returned" has **not** passed. It
found nothing to insert. Check the source rows exist before trusting it.

## What the schema enforces

Rules that are refused at write time rather than documented and hoped for:

- A cemetery cannot carry FTC exposure, and nothing else can have it removed
- Retention beyond twelve months requires the storage fee flagged
- A named seat must name someone; a shared seat must not
- A person reported by a shopper stays `pending` until someone confirms them
- A decedent cannot be saved on a first name alone
- A living person cannot carry a date of death
- One number cannot have two overlapping assignment windows
- A shop number cannot belong to a client organization
- An attributed call must record how; an unresolved one cannot claim a person
- Telemetry marked unavailable cannot carry numbers
- One question cannot be counted twice in a single evaluation
- No opportunity means no points, either way
- An evaluation cannot complete without a named human sign-off, and a client
  cannot read one until it does
- Won revenue can never be imputed from an average
- A benchmark needs at least three contributing organizations
- Phone numbers normalize to E.164 on write, everywhere they appear

## SECURITY DEFINER functions

A definer function runs as its owner, so it bypasses RLS entirely. Two things
go in the same migration that creates one, every time:

1. **A tenancy check inside it.** The policies underneath are not protecting
   you — that is what the attribute turns off. Any function taking an id must
   check `is_internal() OR organization_id = current_organization_id()` itself.

2. **An explicit revoke beside the grant.**

   ```sql
   REVOKE ALL ON FUNCTION my_function(args) FROM PUBLIC, anon;
   GRANT EXECUTE ON FUNCTION my_function(args) TO authenticated;
   ```

Postgres grants EXECUTE to PUBLIC by default, and PUBLIC includes `anon`, whose
key ships in the browser. Granting to `authenticated` **adds** a grant; it does
not remove that one. Nine functions were reachable by anon before migration 037
because every one of them had a grant and none had a revoke.

## Views over a table

`SELECT *` is expanded when a view is created, so a column added to the table
later is simply absent from the view, and nothing complains. Adding a column
to one of these tables means recreating its view in the same migration, with
the same `security_invoker`, comment and revoke-then-grant:

| Table | View | Since |
|---|---|---|
| `interactions` | `countable_calls` | 043 |
| `locations` | `service_locations` | 049 |

**Changing `location_type_is_service()` doesn't update existing rows.**
`locations.is_service_location` is a stored generated column: computed when a
row is written, never recomputed. A migration that changes the function must
rebuild it in the same migration with
`UPDATE locations SET location_type = location_type;`

## Views over `interactions`

**Adding a column to `interactions` means recreating `countable_calls` in the
same migration.** The view is `SELECT *`, and Postgres expands the `*` when
the view is created: a later column is simply absent from it, and nothing
complains. Recreate it with the same `security_invoker`, comment, and
revoke-then-grant as 043. A reporting view is SELECT only. A plain filter over
one table is auto-updatable, so the default privileges from 024 would
otherwise grant writes through it.

## One check, two questions

**When the same check appears in two places and one of them starts refusing
things that feel wrong, suspect the check is answering two different
questions rather than one question twice.** It has happened twice:

- `answered_at` vs `connected_at` (025). "Answered" covered both "the system
  picked up" and "a person picked up". A greeting answers every call at once,
  so scoring on it would have given every firm with a greeting a perfect
  answer time.
- Matching vs saving a number (053). "Is this a staff number" covered both
  "may a call auto-attach to a contact on it" (any staff entry: no) and "may a
  contact hold it" (only when every entry is staff: no). A hospice's shared
  line was refused as a contact because a liaison was listed on it.
  `contact_for_number()` answers the first, `firm_only_number()` the second.

The fix both times was to name the two questions and give each its own column
or function, not to loosen the one check until it stopped complaining.
