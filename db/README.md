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

## Numbering

New migrations get a timestamp, not a sequence number.

```
20261030T1430_add_case_notes.sql
```

Two sessions drafting at the same moment can't collide, the files still sort
into the order they were written, and nobody has to check what number is free.

`001`–`058` keep their numbers. Dozens of comments cross-reference them —
"043's view", "050's set_call_case" — and renaming would break every one of
those for no benefit.

This failed twice before the rule existed. A `035` was written in two sessions
with different contents, and so was an `058` — the second time, one of them
ran on production while the other was being reviewed. Both collisions came
from two writers reading a counter that only reflects what has already been
committed, which is never what either of them is holding.

A sequence number also implies a running order it can't keep: a `056` written
before `058` but applied after it says something untrue about when it ran. A
timestamp says only when it was written, which is all a filename can honestly
claim.

051 (merge chains): drafted, never run on either database, no file in the-hub.
052–055 each state in their headers that they don't need it; nothing has been
checked for 057 or 058.

## Authorship, and review before the run

The migration is written by whoever will apply it.

- A schema change arising from app work is written in the app session, and
  reviewed in the Hub session before it runs.
- A schema change arising from design work is designed in the Hub session and
  handed over to be written, named and run.

Reviewed before it runs — not reported after. On 30 October an `058` was
written and run on production by the session that wrote it, dropping a column
from the live database, while a different `058` was under review elsewhere.
The work was done carefully and the carry-over was handled; nobody saw it
first. That missing step is the entire reason the split exists, so a migration
that is described after the fact has not been reviewed.

Review here is low ceremony and has one requirement: the other session sees
the file, and says go or doesn't, before it is applied. What that catches is
not usually the logic — it is the grant nobody thought about, the second run
that reads as drift, the rule written twice, the function still writing a
column about to be dropped.

Why the split at all: the session that can commit and run is the one that can
see what is actually there, and the session that can't is the one with no
stake in getting it applied. Each is a poor reviewer of its own work for
opposite reasons.

The record of what ran is the `BEGIN;` … `COMMIT;` body. Once a migration has
run, annotate it, don't amend it. A commented-out verification block never ran
as part of the migration; it's a tool for later runs, so it may be fixed in
place, with a note in the file's header saying what changed and why. If a
result from the old block has already been recorded anywhere, the note says
so: a verification output is only meaningful alongside the version of the
block that produced it.

## A comment states what the code proves, not what you concluded

Write what the code establishes. If you want to record what you concluded from
it, say that it is a conclusion.

An overstated comment is worse than none, because it is believed exactly when
someone is deciding whether they still need to check. All three of these were
in one file, on the same day, and each was written in good faith by someone
who had just done the reasoning:

- `-- the check refuses it with a message about the number` — a check
  violation says `new row for relation … violates check constraint
  directory_entries_e164_ck`. The comment described behaviour the code does
  not produce, and it nearly shipped alongside a form that would have shown a
  manager that string.
- `-- The pattern is written once, in the whole schema … (expect 0, 0)` — the
  scan read function bodies and check constraints. RLS policies, column
  defaults, views, materialized views and trigger WHEN clauses went unread. A
  0 would have been taken as proof of something it could not see.
- `ELSIF v LIKE '%7,14%' THEN NULL; -- 055's version, as expected` — four
  characters that a drifted 055 also matches. The comment asserted an
  identification; the code tested for a substring.

Two shapes, two questions:

**It describes behaviour.** Ask what a person would actually see, or what
would actually be written. Not what the code is for — what it emits.

**It asserts a result.** Ask what the query returns if the claim is false. If
it returns the same thing, the comment is a hope and the code is a net. Say
so: *a net, not a proof* is an honest comment; `expect 0` is not, unless 0 is
only reachable one way.

The first of these is the one that gets caught. The second and third were only
found because the first had already moved suspicion from the SQL to the prose
— so treat one overstated comment in a file as a reason to re-read the others,
not as an isolated typo.
