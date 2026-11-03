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

## Which database is which

Two Supabase projects. What follows was read from them, from the Vercel
project and from the app's own bundles on 30 October 2026; check again before
relying on it if much has changed since.

- `dead-ringers-hub` (`rnevplbtsilwatvyqmrg`) is staging. A migration runs
  here first.
- `hellophone-production` (`mrmjpqjarlrkyccejvjf`) is production: the firms'
  real calls and contacts.

The SQL editor's tab title names the project. Read it before pressing Run.

How the app (Vercel project `hellophone`) reaches them:

- Production deploys from `main`, at `hellophone-one.vercel.app`, and uses
  production.
- A preview of any other branch uses staging, through the Preview
  environment's variables. Seen on the `conversion-and-contacts` preview,
  which loaded from `rnevplbtsilwatvyqmrg`.
- Except `stage-1-in-call`. It has branch-only Preview overrides, added 27
  October and copied from Production, so its previews use production: anything
  done in them writes to live data. That branch's `CLAUDE.md` says why; the
  overrides go when it merges.
- `SUPABASE_SERVICE_ROLE_KEY` and `DIALSTACK_WEBHOOK_SECRET` are set on
  Production only. No preview can take in a real call, so real calls reach
  only the production database.

### Default privileges differ, and staging is the looser one

New functions created by `postgres` in `public` are granted to a different set
on each database, by `pg_default_acl` rather than by anything a migration
writes:

| | Granted to on creation |
|---|---|
| Production | `postgres`, `authenticated` |
| Staging | `postgres`, `anon`, `authenticated`, `service_role` |

So a migration that creates a function and **forgets its `REVOKE`** leaves that
function callable by `anon` on staging, and would not have on production. The
test environment is more permissive than the live one, which means it hides
this particular mistake instead of catching it — and a function reachable by
`anon` is exactly what migration 037 existed to clean up, nine of them at once.

Two consequences while that remains true:

- **Never conclude from a clean staging run that the grants are right.** Check
  `has_function_privilege('anon', …)` explicitly, as the verification blocks
  from `20261030T1930` onward do.
- Every new function still gets the explicit pair, on both databases:
  `REVOKE ALL … FROM PUBLIC, anon;` then `GRANT EXECUTE … TO authenticated;`
  — see **SECURITY DEFINER functions** below. The revoke is not redundant on
  production; it is what makes the two databases agree.

Aligning staging's defaults to production's would make staging a truer test.
That is a change to `ALTER DEFAULT PRIVILEGES`, it affects every function
created afterwards, and it does not touch the ones already there — so it wants
its own migration and its own review, not a line in another one.

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

## Error codes the app matches on

A refusal the app has to react to carries its own `SQLSTATE`. **The code is the
contract; the wording is not.** The app matches `PostgrestError.code`, so a
message can be reworded without a migration — and a code cannot be changed
without one, with a drift check like any other change to a function body.

### NS — notify SMS

Raised by `request_notify_sms_confirmation()` and `confirm_notify_sms()`
(`20261102T2330`, `20261102T2345`).

| Code | Means | Raised by |
|---|---|---|
| `NS001` | That person has no mobile number to confirm | `request_notify_sms_confirmation` |
| `NS002` | The number is already confirmed — resending would unconfirm it | `request_notify_sms_confirmation` |
| `NS003` | Three codes already sent to that number this hour | `request_notify_sms_confirmation` |
| `NS004` | Ten codes already requested by this user today | `request_notify_sms_confirmation` |
| `NS005` | Not signed in to the Hub | `confirm_notify_sms` |

`NS002` should not read to the person as an error: it means the thing they
wanted is already true.

`NS003` says neither the number nor who caused it, and reads the same whoever
tripped it — counted across users, so a different message for "it wasn't you"
would tell somebody that a colleague has been asking for codes for that number.

### Choosing a class

Five alphanumerics. Postgres reserves classes beginning `A`–`H` for the SQL
standard and already uses `HV` for foreign-data-wrapper errors, so a
self-defined class starts with `5`–`9` or `I`–`Z`. An earlier draft of the NS
codes used `HS`, which is inside the standard's range.

Two more constraints:

- **Nothing beginning `PT`.** PostgREST reads `PTxyz` as an HTTP status to
  return.
- **Nothing ending `000`.** That is the class code itself, and it matches as a
  whole class rather than as one error.

An unrecognised code comes back from PostgREST as a `400` with the code in the
body, which is what the app reads.

### The older shape, still live

`settings.ts`'s `friendly()` turns database messages into sentences by matching
them with regular expressions — `/no mobile number to notify/i` and
`/no email address to notify/i` among them, both raised by
`notification_preferences_reachable()` (019). Rewording either message in the
database breaks the app, silently and in the place a person is already being
refused something.

Those are the shape this section exists to stop repeating. They are not fixed:
coding them means replacing 019's function body, so it waits for a migration
that has another reason to do that. Until then, treat those two messages as
load-bearing text.

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

**051 (merge chains): done, as `20261102T2200_merge_chains.sql`.** Written
fresh against the schema as it then was, not recovered from the October draft
— which predated 052–058 and `20261030T1500` — and timestamped rather than
numbered, so `051` now names a decision rather than a file.

`merged_into` is one hop deep, and is kept that way rather than checked for.

**What guards it.** `merged_into_points_at_a_survivor()`, one trigger function
on `contacts`, `decedents` and `people`, keyed on `TG_TABLE_NAME` and scoped to
`BEFORE INSERT OR UPDATE OF merged_into`. It refuses, in both directions:

- a row merged into itself;
- a target at another firm;
- a target that has itself been merged away;
- **a row being merged away that others are already merged into.**

The last one is the half that is easy to miss. Refusing a merged *target*
stops `A → B` when `B` is already merged; it does nothing about `B → C` when
`A` is already merged into `B`, which strands `A` just as thoroughly. For
decedents and people that is the *only* way a chain can form, because neither
has a merge function and every merge there is a hand `UPDATE`.

The trigger takes `FOR UPDATE` on the target, so two concurrent merges —
`A → B` and `B → C` — cannot each pass while the other is uncommitted.

**What repoints.** `merge_contacts` moves anything merged into the loser onto
the survivor before pointing the loser away, so merging into a contact that
has absorbed others stays an ordinary thing to do instead of being refused. It
also refuses either end that has already been merged. Its body went from
`5a0bf402ed0db21c8ff412f679fa7708` to `16177d5f2ae691818929c375e222e081`.

**Who reads it.** Every reader resolves exactly one hop with
`COALESCE(merged_into, id)`. The functions whose bodies mention the column,
read from the database rather than from the migrations, are:
`contact_for_number`, `create_case_for_call`, `delete_case`,
`ingest_call_event`, `merge_candidates`, `merge_contacts`, `save_wrap_up`,
`set_call_contact`. The previous version of this entry ended "Other readers
weren't looked for"; that is the list.

**`set_call_contact` still refuses a survivor that is itself merged** (050).
The trigger makes that branch unreachable, which is not the same as making it
wrong: it is what would still be there if the trigger were ever dropped.

**050 is superseded in two places, and carries a note saying so**, added in
the same change. Its verification block builds `v_c2 → v_c → v_case` on purpose
to prove that refusal, and building it is now refused, so the block stops
there. And the comment above `set_call_contact`'s merge resolution says
"`merge_contacts()` doesn't flatten chains", which was true when 050 ran and is
not true now — it is in the function body, so the note records it rather than
fixing it.

**Nothing to check any more.** The two `SELECT count(*)` queries this entry
used to carry were there because nothing prevented a chain and nothing detected
one. Both are now prevented, so neither query is a routine to run. The same
counts survive in `20261102T2200` in two different roles: its section 1 is a
**precondition** that refuses to install the guard if any row already breaks
the rule, and its verification block counts again **afterwards** as an
assertion. Neither is a thing to come back and run later.

**Still open, and not guarded by any of this:**

- There is no merge function for `decedents` or `people`. The guard says what a
  merge must leave behind; it does not move anything. Merging a decedent by
  hand means repointing `case_decedents`, `interaction_decedents` and
  `contact_decedent_links` yourself, with nothing checking that it was done.
- A hand-set `merged_into` writes no history. `merge_contacts` records through
  `record_change`; a direct `UPDATE` records nothing, so a contact can stop
  being a contact with no record of who decided that.

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

The record of what ran is the migration's body: every statement outside the
comments. Usually that is one `BEGIN;` … `COMMIT;` block. Some files need more
than one: `ALTER TYPE … ADD VALUE` must commit before anything uses the new
value, so a file that adds an enum value and then uses it has two, and both
are the record. Once a migration has run, annotate it, don't amend it. A commented-out verification block never ran
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

**And a fourth, which writing carefully cannot prevent.** The three above were
wrong when they were written. This one was right when it was written, and the
code underneath it changed:

```sql
-- merge_contacts() doesn't flatten chains (A into B, then B into C leaves A
-- pointing at B), so a survivor that is itself merged away is refused rather
-- than half-resolved.
```

True in 050, in October. `20261102T2200` made `merge_contacts` repoint and made
a chain impossible, and that comment became a statement about the opposite of
what the database does — sitting in a file nobody had any reason to open,
inside a function body, where a reviewer reading only the changed file will
never see it.

No amount of care at writing time catches this one, and no reviewer of the
change catches it either. The only thing that does is looking:

**When you change behaviour, search for comments describing the old behaviour
before you finish.**

Grep for the thing you changed, not the file you changed it in —
`merged_into`, not `merge_contacts` — because the comments that go stale are in
the callers and the neighbours. A comment in a function body cannot be edited
without replacing that body, so when the search finds one, the answer is often
a note in the file's header recording that it is wrong rather than a fix. That
is still worth doing: the next person finds the note beside the lie.
