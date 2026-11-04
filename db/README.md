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

### Four things that will happen

**Supabase's row-level-security warning fires on data-only files.** Its scanner
reads the word "their" inside a rubric question as a table name and warns about
a `CREATE TABLE` that isn't there. If the file contains no `CREATE`, "Run
without RLS" is correct. If it does contain `CREATE TABLE`, read it first.

**The editor rejects files over roughly 1 MB.** That is why migration 013 is
split into six parts. Run them in letter order.

**The editor does not show `RAISE NOTICE`.** Anything a migration reports
that way — a precondition saying what it is about to change, a sweep saying
what it spared — is invisible when the file is run there. Put anything a reader
must see into the verification block, whose text comes back through a
`RAISE EXCEPTION` and therefore does appear. The notices are still worth
writing, for `psql` and for the logs; just never rely on one being read.

**The editor rewrites what you submit**, in two ways that matter. It appends a
trailer to every submission — a `-- source: dashboard` line, a session id and a
millisecond timestamp — which is why `submitted_text()` exists and why the
ledger's `ran_md5` means anything. And when the RLS prompt offers "Run and
enable RLS", that option changes the text before sending it. **Always choose
"Run without RLS."** These migrations enable row-level security themselves,
deliberately and where it belongs; letting the editor add its own version would
both do the wrong thing and make the run's fingerprint disagree with the file's.

## The migration ledger

`schema_migrations` records which migration ran on this database. It starts on
3 November 2026 and **is not a history**: no row exists for `001`–`058`, and an
absent row for anything older than that date is not evidence that it did not
run. Before the table existed, the only way to answer "has this run here?" was
to read the catalogue for the objects a file creates — which is how staging went
a month without `014` and nobody could have noticed.

### Every migration records itself

The last statement inside the transaction block, so the row and the work commit
or roll back together and a file that fails records nothing:

```sql
DO $$
BEGIN
  PERFORM record_migration(
    '20261103T1700_new_tables_are_read_only.sql',
    NULL,                       -- the file's sha256, if the applier passes one
    'One line on what it did.');
END $$;
```

A `DO` block, not a bare `SELECT` — the editor appends ` limit 100` to a
trailing bare `SELECT`, and that lands in the hashed text.

**Nothing enforces this rule and nothing can.** A migration that forgets the
call is indistinguishable from one that never ran, which is precisely the state
the table was built to leave. It only works if it is remembered, which is why
it is written here.

### Two hashes, answering different questions

`sha256` is the file, passed in by whoever applied it. A file cannot record its
own hash — the hash covers the file that would contain it — so it is an
argument, never a self-report. Null means nobody passed one.

`ran_md5` is the text the client actually submitted, with the editor's trailer
stripped. **It should be identical on staging and production.** Same file, same
paste, same number. When it differs, the two databases were given different
text, which is the `003` case: staging holds a `people_org_name_uq` without the
`WHERE merged_into IS NULL` that the repository has, and nothing surfaced it for
a month.

Before calling a mismatch drift, rule out four innocent causes:

- **The file was annotated after it ran.** A header note or a corrected comment
  changes `sha256` and must not change `ran_md5`. This is the common one.
- **CRLF against LF**, if the file crossed machines between the two applies.
- **A file with more than one transaction block** — the `ALTER TYPE … ADD VALUE`
  case — records only the block that called `record_migration`. Such a file
  should call it in each block and name the block in `note`.
- **The editor changed its trailer.** `submitted_text()` anchors on the
  `-- source: dashboard` marker and removes everything after it, so a fourth
  line or a reordering is still stripped; a renamed marker is not.

`ran_len` is the submitted length **in characters**, not bytes — tens means one
statement was sent, thousands means a file was pasted. The text itself is never
stored, only the hash and the length, because it carries the session's identity.

**Compare the two ledgers by filename, never by row count.** Some files can
only ever run on one database — `20261103T2100_fourteen_on_staging.sql` exists
because staging was missing `014`, and refuses to run on production by design.
Staging therefore has one row more, permanently. The rows they share should
still agree exactly; it is the join that means something, not the total.

### A repair file must refuse on the database it is not for

This is the rule that keeps a one-sided row from being ambiguous, and it is
worth stating because the obvious alternatives are both worse.

A row means *this file ran here*. So the absence of a row means *it did not run
here*, and for a repair file that is the truth — but it does not say whether it
was skipped on purpose or missed. Two things close that, and they do different
jobs.

**The file itself refuses on the database it is not for.** That is what stops
the mistake:

```
RAISE EXCEPTION '014''s objects are all present; nothing to do here'
  USING HINT = 'This is production, or staging has already had this file.
                Not an error to fix — stop.';
```

Somebody who sees the gap, concludes production is behind and runs the file is
stopped at the moment of the mistake and told why, which beats a comment they
would have had to find first. The absence is backed by an enforced refusal
rather than by documentation.

**And the row's own `note` says it is one-sided — written when the file is.**
That answers the person who is only looking, not running, and it costs nothing
at write time. A one-sided file's `record_migration` call should say in as many
words which database it is for, why the other does not need it, and that it
refuses there.

The refusal and the note are not alternatives. One prevents the wrong action;
the other prevents the wrong conclusion.

**A ledger row is never edited after it is written.** It is the record of a
run, written once by the thing that ran — the same rule as *an applied
migration is annotated, never amended*, and for the same reason. Where a file's
header can be corrected after the fact, a row cannot: the header is commentary
and the row is evidence.

That invariant costs something here, and the cost is accepted.
`20261103T2100` was written hours before the note convention existed, so its
row does not say it is staging-only. Its **header** does, on main, and it
refuses on production, and this section exists. A migration to append a
sentence to that one row was written and withdrawn: the before-and-after check
in it proved that *that* file touched nothing but `note`, which is not the same
as protecting the invariant from the next file that does not bother. "Rows are
never touched" is a rule anybody can hold; "only `note` may move" has to be
re-proved every time.

Four alternatives were considered and rejected:

- **Guarding the file so it is a clean no-op, then running it on both.** That
  changes the text, so the same filename would carry two different `ran_md5`
  values — which is the exact signal this schema treats as drift. It would
  have to be a second file, not an edit.
- **A row on the other database saying it deliberately did not run.** That
  makes one row mean "did not run here" while every other row, backfills
  included, means "ran here". It removes the ambiguity by introducing a worse
  one.

- **A mirror file** that asserts the other database is already correct and
  records itself. Defensible, and declined: it makes every one-sided file cost
  two, and the thing it buys — a matching row count — is the comparison this
  section just said not to make.
- **Appending the explanation to the existing row's `note`.** The most
  tempting, because `note` has always been "anything the next reader needs" and
  it introduces no new meaning. Rejected on the precedent, above: the first
  edit to a ledger row is the expensive one, whatever it says.

### How a repair file knows whether it applies

A file that refuses on one database needs a test, and there is a choice of two.
`current_database()` is `postgres` on both of ours, so it cannot be the test.

**Prefer asking what is present over asking which database this is.**
`20261103T2100` does not ask where it is running; it counts the eight objects
`014` creates and refuses if they are already there. That answers the question
that actually matters — *does this repair apply here?* — and it stays correct
in cases a name or a marker does not. A clone of production stood up as a new
staging carries production's identity with it, so a marker would call it
production; but it also carries `014`, so a presence test still refuses,
correctly, for the right reason.

A named environment marker — a row, or a designated setting — is the fallback
for a file where **nothing in the schema can tell the databases apart**: a data
correction that applies only to staging's seed, say. Such a marker is a second
thing to keep true, and the clone case is exactly how it goes stale, so
resetting it belongs in whatever stands up a staging database rather than in a
migration. A presence test has no such upkeep.

### How a row got there

`recorded_how` is `'self'` or `'backfill'`, and a constraint ties it to
`ran_md5` so the two cannot come to disagree. The eleven rows for migrations
applied 30 October – 3 November are backfilled: they carry a `sha256` and the
catalogue evidence that the file ran, and nothing about when, because nothing
recorded it at the time. **For eight of the eleven the `sha256` is main's file
and not what was submitted**, since they were annotated after running:
`20261030T1500`, `20261102T1500`, `T1600`, `T1800`, `T2200`, `T2330`, `T2345`
and `20261103T1000`.

## Comparing the two databases

Eight queries. Run each on both databases and compare the two cells. Each
returns a single cell, with `' => '` between a name and its definition and
`' ;; '` between entries, because the editor's result grid flattens newlines
and tabs — so a diff is a text comparison rather than a row-by-row read.

The first six found two things on 3 November 2026: staging missing `014`
entirely, and one index differing. Both were months old and neither was being
looked for.
**Worth running on a schedule rather than on suspicion** — the cost is a few
minutes, and the cost of not running it was a month of staging proofs that were
weaker than they read.

```sql
-- col: every column, its type, nullability and default
SELECT string_agg(k || ' => ' || v, ' ;; ' ORDER BY k) FROM (SELECT c.table_name || '.' || c.column_name AS k, c.data_type || CASE WHEN c.data_type = 'USER-DEFINED' THEN ':' || c.udt_name WHEN c.data_type = 'ARRAY' THEN ':' || c.udt_name ELSE '' END || '|null=' || c.is_nullable || '|def=' || coalesce(c.column_default, '') AS v FROM information_schema.columns c JOIN information_schema.tables t ON t.table_schema = c.table_schema AND t.table_name = c.table_name WHERE c.table_schema = 'public') x;

-- typ: every enum and its labels IN ORDER (order is part of the type)
SELECT string_agg(k || ' => ' || v, ' ;; ' ORDER BY k) FROM (SELECT t.typname AS k, string_agg(e.enumlabel, ',' ORDER BY e.enumsortorder) AS v FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace JOIN pg_enum e ON e.enumtypid = t.oid WHERE n.nspname = 'public' GROUP BY t.typname) x;

-- fn: body hash, volatility, definer/invoker, search_path, return type
SELECT string_agg(k || ' => ' || v, ' ;; ' ORDER BY k) FROM (SELECT p.oid::regprocedure::text AS k, left(md5(p.prosrc), 12) || '|' || p.provolatile::text || '|' || CASE WHEN p.prosecdef THEN 'definer' ELSE 'invoker' END || '|' || coalesce(array_to_string(p.proconfig, ';'), '') || '|ret=' || pg_get_function_result(p.oid) AS v FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.prokind IN ('f','p') AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')) x;

-- con: constraints and indexes by name
SELECT string_agg(k || ' => ' || v, ' ;; ' ORDER BY k) FROM (SELECT 'C ' || cl.relname || '.' || co.conname AS k, left(md5(pg_get_constraintdef(co.oid)), 12) AS v FROM pg_constraint co JOIN pg_class cl ON cl.oid = co.conrelid JOIN pg_namespace n ON n.oid = cl.relnamespace WHERE n.nspname = 'public' UNION ALL SELECT 'I ' || i.tablename || '.' || i.indexname, left(md5(i.indexdef), 12) FROM pg_indexes i WHERE i.schemaname = 'public') x;

-- trg: triggers, including which columns and whether enabled
SELECT string_agg(k || ' => ' || v, ' ;; ' ORDER BY k) FROM (SELECT c.relname || '.' || t.tgname AS k, t.tgtype::text || '|attr=' || t.tgattr::text || '|fn=' || t.tgfoid::regproc::text || '|en=' || t.tgenabled::text AS v FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND NOT t.tgisinternal) x;

-- mig: policies, RLS and FORCE flags, and any migration table
SELECT string_agg(k || ' => ' || v, ' ;; ' ORDER BY k) FROM (SELECT 'table ' || table_schema || '.' || table_name AS k, 'exists' AS v FROM information_schema.tables WHERE table_name ILIKE '%migration%' OR table_name ILIKE '%schema_version%' UNION ALL SELECT 'policy ' || tablename || '.' || policyname, cmd || '|' || array_to_string(roles, ',') || '|' || left(md5(coalesce(qual, '') || '#' || coalesce(with_check, '')), 12) FROM pg_policies WHERE schemaname = 'public' UNION ALL SELECT 'relkind ' || c.relname, c.relkind::text || '|rls=' || c.relrowsecurity::text || '|force=' || c.relforcerowsecurity::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind IN ('r','p','v','m')) x;
```

```sql
-- acl: every grant on every relation, sequence and routine
SELECT string_agg(k || ' => ' || v, ' ;; ' ORDER BY k) FROM (SELECT k, string_agg(DISTINCT gp, ',' ORDER BY gp) AS v FROM (SELECT 'R ' || c.relname AS k, (CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END) || ':' || a.privilege_type AS gp FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace, aclexplode(COALESCE(c.relacl, acldefault((CASE WHEN c.relkind = 'S' THEN 'S' ELSE 'r' END)::"char", c.relowner))) a WHERE n.nspname = 'public' AND c.relkind IN ('r','p','v','m','f','S') UNION ALL SELECT 'F ' || p.oid::regprocedure::text, (CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END) || ':' || a.privilege_type FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace, aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a WHERE n.nspname = 'public' AND p.prokind IN ('f','p') AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')) y GROUP BY k) x;

-- defacl: the default privileges, per granting role and object type
SELECT string_agg(k || ' => ' || v, ' ;; ' ORDER BY k) FROM (SELECT d.defaclrole::regrole::text || '.' || d.defaclobjtype::text AS k, d.defaclacl::text AS v FROM pg_default_acl d JOIN pg_namespace n ON n.oid = d.defaclnamespace WHERE n.nspname = 'public') x;
```

**`COALESCE` with `acldefault` is the whole trick in `acl`**, and leaving it out
is how a grants audit reports a clean result on a database full of grants. A
null `relacl` or `proacl` does not mean "nothing granted" — it means the
built-in default applies, which for a function is `PUBLIC EXECUTE`. And
`aclexplode(NULL)` returns no rows, so the objects with the most permissive
setting are exactly the ones a careless query drops.

`PUBLIC` prints as `-` through `regrole`, hence the `CASE`. That matters here
more than it looks: `PUBLIC` is the grantee that caused both of this schema's
grant surprises.

The other `CASE` needs its `::"char"` cast. `acldefault`'s first argument is
`"char"`, and a `CASE` expression resolves to `text`, so the query fails on
both databases without it — while `acldefault('f', …)` in the function branch
works untouched, because a bare literal is untyped and coerces.

**`defacl` is what keeps the alignment true.** The four files of 3 November
made `postgres`'s three default entries identical on the two databases; nothing
stops the next `ALTER DEFAULT PRIVILEGES`, or a Supabase platform change,
separating them again silently. This query is the only thing that would say so.
It also shows `supabase_admin`'s entries, which cannot be changed and should
be read as a constant rather than a finding.

**One thing these eight still do not cover:** column comments. Not nothing — a
comment is where this schema records why a column exists — but the only one of
the gaps that cannot mislead anybody about access.

### The baseline, 4 November 2026

All eight ran identically on staging and production on 4 November 2026, for the
first time. This is the state to diff against: a later run that differs from
these, on either database, has found a change made since.

| query | md5 | characters |
|---|---|---|
| `acl` | `ffefc02753d113a5fe6c5c47e50ca505` | 43350 |
| `col` | `adffe4348d154de655c6e6d734d9599f` | 68914 |
| `con` | `ced2d050bcded68c18cf2e6e770a9d2b` | 50386 |
| `defacl` | `75defde014c9c174dee94ede905dae2d` | 661 |
| `fn` | `94a58f9bdfb77e2090139869be6d4fc9` | 10689 |
| `mig` | `0d65750186f172bc535c50d7a0c363f1` | 15695 |
| `trg` | `087000700dea24395739dab7f52f3ef0` | 6543 |
| `typ` | `a713741449e51c3fa3d8d84849289f5a` | 6467 |

**A migration applied to both databases moves the baseline, and the migration
that moved it updates this table in its own pull request.** Not later, and not
by whoever next runs the queries. The order is the one already in use: apply on
staging, apply on production, re-run the eight queries, update the affected
rows here, commit the migration and the new baseline together.

That makes the baseline part of review rather than a chore after it. A reviewer
can see which fingerprints a migration claims to move and check that against
what it does, and — the point of the whole thing — **a mismatch found later
always means a change nobody intended**, because every intended one arrived
with its own update.

Two things it does not prove, so that a row of matching hashes is not read as
more than it is: `col` cannot see `numeric` precision, so `numeric(4,2)` and a
bare `numeric` compare equal; and nothing here covers column comments.

## Is anything still arriving

The structural diff asks whether the schema has moved. This asks the other
question, which has no schema symptom at all: **production went five days with
zero interactions**, and it surfaced only because somebody was reading the logs
for an unrelated reason. It was benign — a quiet test number — and nothing in
the database could have told the difference between that and the ingestion
being broken, because both look like an empty table.

Run it daily, beside the structural diff:

```sql
SELECT o.name,
       count(*) FILTER (WHERE i.occurred_at > now() - interval '24 hours') AS last_24h,
       count(*) FILTER (WHERE i.occurred_at > now() - interval '7 days')   AS last_7d,
       max(i.occurred_at)                                                  AS most_recent
  FROM organizations o
  LEFT JOIN interactions i ON i.organization_id = o.id AND i.source = 'real'
 WHERE EXISTS (SELECT 1 FROM phone_numbers p
                WHERE p.organization_id = o.id AND p.active)
 GROUP BY o.id, o.name
 ORDER BY most_recent NULLS FIRST;
```

**`EXISTS`, not a join, and the difference is not style.** Joining
`phone_numbers` before aggregating produces one row per number per interaction,
so a firm with two active numbers reports twice its real counts. `most_recent`
would still be right, which is what makes it nasty: the column you would sanity
check looks fine while the ones you are reading are doubled. Today the query
gives the same answer either way, because Dead Ringers holds the single active
number on production — so this is a bug that would have arrived with the second
firm, in a check nobody re-reads once it is working.

On production, 3 November: one firm, 3 in the last 24 hours, 23 in the last 7
days, most recent 17:39 UTC — the day's test calls.

Read it by the **first rows, not the totals**. A firm with an active number and
a `most_recent` of several days ago is the signal; a busy firm at the bottom
tells you nothing about the quiet one at the top. `source = 'real'` matters —
seeded and shop rows would mask exactly the gap being looked for, which is the
same scoping mistake that made a null-number count read 50 when it was 0.

What it cannot tell you is **why**. A quiet firm, a broken webhook, a carrier
outage and a failing `ingest_call_event` all produce the same empty row. It is
a prompt to look, not a diagnosis.

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

### Default privileges, aligned 3 November 2026

What a new object in `public` is granted on creation comes from
`pg_default_acl`, not from anything a migration writes. Until 3 November the
two databases differed, and **staging was the looser one** — which is the wrong
way round, because it meant a migration that forgot its `REVOKE` was *hidden*
by the test environment instead of caught by it. Four files closed the gap:
`20261103T1600` (`anon`), `1700` (new tables read-only), `1800`
(`service_role`), `1900` (sequences).

What `postgres` now grants on creation, identically on both:

| | `authenticated` | `anon` | `service_role` |
|---|---|---|---|
| Tables | `SELECT` | — | `TRUNCATE`, `REFERENCES`, `TRIGGER`, `MAINTAIN` |
| Sequences | `SELECT`, `USAGE` | — | — |
| Functions | `EXECUTE` | — | — |

**This is the first time a clean staging run means something about production's
grants**, and it is worth not over-reading. Two things still make an explicit
check worth writing into every verification block, as they have been since
`20261030T1930`:

- **`supabase_admin` has its own defaults in `public`**, granting `anon`,
  `authenticated` and `service_role` everything it creates — twelve privileges
  on each database. `ALTER DEFAULT PRIVILEGES` is per granting role and
  `postgres` is not a member of `supabase_admin`, so no migration can change
  them. That is why `btree_gist`'s 188 functions in `public` still grant `anon`
  `EXECUTE` directly on both. Anything created *by* `supabase_admin` — which
  includes some paths through the Supabase dashboard — follows those defaults
  and arrives wide open.
- **A default is not retroactive.** It decides what a new object gets and says
  nothing about the 98 relations and 114 functions already there. (Staging had
  112 until `20261103T2100` gave it `014`'s two.)

So every new function still gets the explicit pair, on both databases:
`REVOKE ALL … FROM PUBLIC, anon;` then `GRANT EXECUTE … TO authenticated;` —
see **SECURITY DEFINER functions** below. The revoke is no longer compensating
for a difference between the databases; it is stating the intent in the file,
where a reviewer can see it.

**`PUBLIC` was the last of it, and `20261104T0900` swept it.** 68 of our own
functions granted `EXECUTE` to `PUBLIC`, which is a grant held by every role —
so the trap worth remembering is that *revoking a role's own grant does not take
away what it holds through `PUBLIC`*. An `anon`-only sweep on production would
have changed nothing and been reported as a fix.

It went as one statement rather than 68 decisions, for two reasons both
measured first:

- **`authenticated` already held a direct `EXECUTE` on all 68 on production.**
  Each had the ACL `{=X/postgres, postgres=X/postgres, authenticated=X/postgres}`.
  Revoking `PUBLIC` left every signed-in caller working. An earlier draft of
  this section asserted the opposite — that `PUBLIC` was the only grant they
  had — and would have built the next migration on it.
- **A trigger function does not need `EXECUTE` at all.** PostgreSQL checks that
  privilege at `CREATE TRIGGER`, not when the trigger fires. Proved on staging:
  with `EXECUTE` revoked from `PUBLIC` *and from `authenticated`*, an `UPDATE`
  run as `authenticated` still fired `touch_updated_at()` and still set
  `updated_at`. That covered 33 of the 68. Revoking only `PUBLIC` proves
  nothing here, because 024's function default gave all 33 a direct grant too.

**`anon` can now execute two of our functions, and they are the two the system
calls during a write.**

### Functions the system calls during a write

These keep `PUBLIC` where the writing role needs it, because a privilege
failure in one of them arrives as a refused write rather than a refused call —
somewhere nobody is looking. Scanned on 4 November across `CHECK` constraints,
column defaults and generated columns, and index expressions and predicates,
the whole category is three:

| | Where it is called from | Who writes those tables | `PUBLIC`? |
|---|---|---|---|
| `is_e164` | `CHECK` on `contact_phones`, `directory_entries`, `phone_numbers`, `routing_schedules`, `users` | `authenticated`, on all five | yes |
| `location_type_is_service` | `CHECK` on `rubrics` and `benchmark_snapshots`; the generated column `locations.is_service_location` | `authenticated` on `rubrics` and `locations`; the owner only on `benchmark_snapshots` | yes |
| `submitted_text` | the defaults for `schema_migrations.ran_md5` and `ran_len` | the owner only, through `record_migration` | **no** |

**The third column is the one that answers a new member.** Read along a row:
the function has to be executable by whoever writes those tables. Where that is
the owner, nothing is needed — the owner can execute anything it owns, which is
why `submitted_text` is correctly not public and why `benchmark_snapshots`
contributes no requirement. Where it is `authenticated`, a grant is needed, and
`authenticated` already holds a **direct** `EXECUTE` on both public members.

So neither `PUBLIC` grant is load-bearing. **Both are kept by choice, not by
need**, and the choices are different:

- `is_e164` for the reason in `20261030T1500` §1 — it is the single statement
  of the E.164 pattern, public so that nothing has an excuse to write a second
  one.
- `location_type_is_service` on the trade. It is a pure predicate over an enum
  and exposes nothing, so revoking it buys nothing; and while the direct
  `authenticated` grant means revoking it would almost certainly be harmless,
  **an action with no benefit and a non-zero cost is one not to take.** The
  "almost" is carrying less weight here than the "nothing".

When a scan turns up a new member, spare it, fill in its row, and decide from
the third column. Do not sweep it and find out.

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

## Grants on a new table

Since `20261103T1700`, a table created in `public` by `postgres` grants
`authenticated` **`SELECT` and nothing else**. If the application needs to write
it through the API, the migration says so in its own `GRANT`, next to the policy
that decides which rows.

This costs something and it is worth knowing in advance: **a migration that
creates a writable table and forgets the grant will look correct, pass review,
and fail at runtime** with `permission denied` — in the application, not in the
migration.

The reason it is worth that cost is finding 0. Six reference tables — the
scoring rubric and the cross-firm benchmark rows — were writable by every
signed-in user at every firm on production for a month. Nobody granted that.
The old default granted it, and a policy written `FOR ALL` because its author
left the `FOR` clause off let it through. Two defaults, neither examined.

**Two things this does not cover.** Existing tables keep every grant they
have: `authenticated` can still write **85 of the 98 relations** in `public`,
because default privileges apply at `CREATE` time and never retroactively. (It
was 91 until `20261103T1000` took the writes off the six reference tables.)
What stands between that and 85 more copies of finding 0 is the policies, so a
policy written `FOR ALL` is still the thing to catch in review — and on
4 November all 85 were checked: every one is scoped, and none has RLS off. And a table created
through the **Supabase UI** is created by `supabase_admin`, follows that role's
defaults rather than `postgres`'s, and arrives writable by everyone signed in —
`ALTER DEFAULT PRIVILEGES` is per granting role and `postgres` is not a member
of `supabase_admin`. The structural diff is what would catch one.

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
