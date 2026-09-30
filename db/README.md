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
