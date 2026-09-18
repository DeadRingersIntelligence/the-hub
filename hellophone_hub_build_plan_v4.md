# HelloPhone + The Hub — Revised Build Plan

**September 2026 · Version 4**
*Supersedes v2 and v3. This file lives in the repo and is the briefing for any fresh Claude Code session. Claude Code does not share context with claude.ai chats — this file is how continuity happens.*

---

## Read this part first

The original scope is structurally sound. Vendors are right, phases are in a sensible order, the risks are the real risks. Three things change.

### 1. There is one database, and it is not a phone database

The earlier scope called the app's call storage "the intelligence hub." That name is already taken by something bigger — the layer holding mystery shop evaluations, real-call evaluations, coaching history, course assignments, cost attribution, and eventually revenue pulled back from client CRMs.

Design the schema around call events and a mystery shop won't fit in it. But "shops are the pointed instrument, real calls are the survey, both score against the same benchmarks" is a decision that's already made. A call-shaped database throws it away.

**One database from the start, designed for every kind of interaction. HelloPhone is simply the first application that writes to it.**

| | What it is | When |
|---|---|---|
| **The Hub** | The database and the intelligence layer | Schema now, fills up over time |
| **HelloPhone** | Softphone + text inbox. Directors live here | Phases 2–5 |
| **The Hub app** | Owners, managers, coaches. Replaces the React portal | Later — Hub v1 in the company roadmap |

Two applications, one database. That's the four-front-doors model, built in the order the work has to happen.

### 2. Postgres is the operational database. BigQuery converges into it.

Evaluation data currently lives in BigQuery, scored by Metabase, fronted by a contractor's React app. Adding Postgres for call data without a plan leaves two stores and a permanent seam.

**Postgres is the operational database for everything new. Evaluation data migrates in once the schema is proven. Metabase points at Postgres, so the scoring engine survives the move. BigQuery retires when it's empty.** Confirm in the discovery block, but this is the default.

### 3. Build the phone first

You can't tag calls you can't make. The Hub's input is call events — until a real number passes real traffic there's nothing to ingest.

**But the schema gets designed before either.** Phase 0 and 1 are mostly waiting on vendors. That window is exactly when you design the data model: no dependencies, cheapest hours you'll spend, and the one decision that's expensive to reverse.

**The softphone is not conditional.** It's needed so people can answer calls and manage texts from a computer, regardless of what Dial Stack ships on mobile. Their mobile app matters for directors on removals, but that's a feature question now, not a build-or-don't decision.

---

## Why Postgres

The features that matter for *this* build, not Postgres in general.

**Row-level security.** Filtering rules live in the database, not application code. A regional manager sees a location group, a location manager sees one location, ownership sees everything and drills down — exactly what RLS exists for. The alternative is enforcing it in app code on every query forever, where one forgotten `WHERE` clause leaks one client's calls to another. This is the strongest single argument, and it's the fix for what's wrong with the current portal, where permission logic lives in the contractor's React code instead of the data.

**JSONB.** Structured columns for what's shared, JSON for what isn't. Per-client custom rubric fields and raw vendor payloads coexist without a schema change per client.

**Full-text search on transcripts**, built in. No separate search service.

**pgvector.** Semantic search over transcripts — "find calls like this one," behavior clustering, similarity across the corpus. You'll want it within two years and it's an extension, not a migration.

**Recursive queries** for organization → group → location. One query walks the tree.

**Window functions and aggregates.** Behavior counts against opportunity denominators, national benchmarks, per-person trends. This is where Postgres is strongest.

**Metabase speaks it natively.** The scoring engine moves off BigQuery instead of being rebuilt.

### The alternatives, and why not

| | Why not |
|---|---|
| **MySQL / PlanetScale** | No row-level security. Weaker JSON. No vector support. Fine database, fewer of the things needed here. |
| **MongoDB** | Flexible fields sound right for custom rubrics, but the data is deeply relational — evaluation → observation → behavior → person → location. Joins *are* the product. JSONB gives the flexibility without losing them. |
| **Firestore** | Tempting given Firebase Auth. Document store, no joins, thin aggregation, per-document-read pricing. A national benchmark across millions of observations would be slow and expensive. Built for app state, not analysis. Note the contractor's Firestore came back empty — he didn't use it either. |
| **BigQuery** | A warehouse. Excellent for analysis, wrong as an operational store — high per-query latency, priced per byte scanned, not built for fast row-level writes. |
| **SQL Server** | Licensing cost and a Microsoft-shaped ecosystem, for no advantage. |

**Supabase over Neon.** Same Postgres underneath, but Supabase bundles auth, storage, and RLS tooling — and its auth could eventually replace Firebase, collapsing one more system. Neon's edge is database branching, which matters more for a team than for one builder.

Postgres is open source. Supabase, Neon, and AWS run the same engine, so leaving any of them is a hosting migration, not a data migration.

---

## The schema

### Five rules

1. **Multi-tenant from row one.** `organization_id` on every table. Retrofitting tenant isolation is the highest-risk change available later.
2. **Never store a composite score.** Store observations; compute scores in the query. This makes the scoring reframe a query change instead of a rebuild.
3. **Every observation carries an opportunity flag.** That's the denominator. Behavior counts against opportunity-based denominators is the whole reframe, and it has to be there from the first row.
4. **A shop and a real call are the same row.** One `interactions` table with a source discriminator. If they diverge into two tables, so does everything built on them.
5. **The outcomes table exists on day one, even empty.** Revenue won't flow from client CRMs for a year. The column existing is what makes "which behaviors lead to a sale" answerable later instead of a migration.

### Organization and people

**`organizations`** — client firms. Name, status, tier (HelloPhone / Intelligence Center / internal).

**`location_groups`** — regions. Belongs to an organization. Supports the regional manager view and lets ownership see how regions perform before drilling into individual locations.

**`locations`** — individual funeral homes, cemeteries, branches. Belongs to an organization, optionally to a location group.

**`people`** — staff at client firms, plus shoppers and coaches. Name, role, location, organization. Per-person performance, coaching history, and course assignment all key off this.

**`users`** — login identities. Separate from `people`, because most directors will never log in but still need to be measured. A user optionally links to a person.

**`user_scopes`** — the permission mechanism. User, scope type (organization / group / location), scope ID. One table covers ownership, regional managers, and location managers, and RLS enforces it at the database rather than in every query.

### Interactions and evaluation

**`interactions`** — the universal event. Organization, location, handled-by person, source (`real_call`, `shop_call`, `text_thread`), direction, timestamps, duration, recording URL, transcript, external vendor ID. Every Dial Stack call and every mystery shop Wendy publishes lands here.

**`behaviors`** — the shared library of every behavior Dead Ringers can detect. Name, category (objective / impression), definition. *This is the actual intellectual property.*

**`rubric_templates`** — standard Dead Ringers rubrics, versioned.

**`rubrics`** — a client's actual rubric, derived from a template, with their additions and removals.

**`rubric_behaviors`** — which behaviors are in which rubric, with weight and order.

**`evaluations`** — one per interaction that gets evaluated. Interaction, rubric version, evaluator type (human / AI), evaluator identity, timestamp. An interaction can have none.

**`observations`** — one row per behavior per evaluation. Behavior ID, observed (true/false), **opportunity (true/false)**, verbatim quote, timestamp offset into the recording. This table is where the north star lives. Every benchmark, every report line, every correlation is a query against it.

**`outcomes`** — interaction, outcome type (appointment set, service sold, lost, unknown), revenue amount, source system. Empty for a long time. Its existence is the point.

### Learning

Split the course question in two.

**Course content** — lessons, video hosting, quizzes, the player. Don't build that. Dead Ringers' own positioning warns firms that building an LMS is the six-figure mistake, and it applies here too.

**Course records** — which module was assigned, to whom, by which coach, in response to which behavior, and whether it was finished. That belongs in the Hub now, regardless of where content lives.

**`courses`** — a registry, not a library. ID, title, provider (Thinkific today), external ID.

**`assignments`** — person, course or coaching session, assigned by, triggering behavior, assigned date, due, completed. Feeds both the coach console and the CXpertise connection.

This is what makes the product claim provable: behavior missed → module assigned → completed → behavior improved on the next call. None of it requires owning the video player. If CXpertise leaves Thinkific later, `provider` changes value and the records are already there — what gets built is content delivery, not record-keeping.

### Cost attribution

**`cost_events`** — organization, vendor (Dial Stack, Surge, CTM, AI, storage, hosting), cost type, quantity, unit cost, total, timestamp, optional link to the interaction or evaluation that caused it.

**The rule: record cost when it's incurred, attributed to the client.** Consequences:

- Profit and loss by customer is a group-by, not a monthly reconstruction
- AI spend per client is visible in real time instead of at invoice time
- Price validation evidence becomes a query — you can prove a client costs more than they pay
- Vendor reconciliation is what you recorded versus what each vendor billed. At zero margin on telecom, a small discrepancy is a straight loss

This is most of the business intelligence module, obtained as a side effect of recording cost properly the first time.

### Evaluation policy — no "always-on" fields

Rather than a hardcoded list of fields that run on every call, each organization has an **evaluation policy**: which rubric, what triggers it (every call / sampled / manual only), and which model tier.

A HelloPhone-only client gets a minimal rubric on a sampling trigger. An Intelligence Center client gets the full rubric on every call and pays for it. Cost per evaluation lands in `cost_events` either way.

**One consequence to decide now: customization and benchmarking pull against each other.** A behavior a client invented can't roll into a national average, because no other client measures it. The shared `behaviors` library resolves this — benchmark queries filter to library behaviors, custom behaviors report client-only. If that rule isn't in the schema from the start, the national numbers quietly stop meaning anything.

### Two design notes that will bite otherwise

**Write fast, tag slow.** When a call ends, write the row and reply to Dial Stack immediately. Tag it in a separate background job. If tagging runs inline and forty calls end at once, the connection times out, Dial Stack retries, and the problem compounds.

**Seed the schema with real mystery shop data before building on it.** If a real shop from last month can't be expressed in these tables, the schema is wrong — and you find out in September for free rather than in January with an application on top of it.

---

## The plan, in order

### Now — September

**External, in motion:**
- Live DID — in progress with Dial Stack
- Carrier-of-record obligations in writing, naming FCC Form 499, USF contributions, CPNI certification, Robocall Mitigation Database entry, STIR/SHAKEN signing, state 911 remittance, Kari's Law and RAY BAUM's Act. Verify independently in the FCC's public 499 filer database and the Robocall Mitigation Database. Forward to Poul.
- Contract terms: written SLA with credits, twelve months of uptime history, wind-down and number portability if Dial Stack ceases operating, no direct sales into deathcare, transcription retention stated as a number.
- Dial Stack's mobile app — timing and quality. Not a blocker, but directors need a phone that rings on removals.
- Open the Surge account. Self-serve, effectively free until texts send.

*Texting consent is signed off by Poul. Done.*

**The build task:** design the schema. 15–25 hours, works in fragments, no dependencies. Write it as SQL migrations, not a diagram. Seed with real shop evaluations.

**Also:** the discovery block — 4–8 hours inside BigQuery and Metabase. Confirms the Postgres call, fixes the two known scoring bugs, unblocks the FTC question revisions. Do it before the schema work if possible.

### October — verification, not building

The shop app cutover, the website rebuild, CXpertise tiers, and NFDA own October. HelloPhone work here is listening:

- Take delivery of the real DID
- Prove on real calls: a transferred call presents *your* number, 933 reads back the right emergency address, a transferred call produces **one** recording and not several
- Build and listen to the full hold experience — greeting, music, acknowledgement, music, second message, overflow rather than voicemail

**If end-to-end recording or caller ID on transfer doesn't behave as documented, the plan changes before any code exists.** That's the point of doing this before Phase 2.

### November–December — the shell

1. Next.js app on Vercel with a login. Nothing else.
2. A server route that mints a Dial Stack session token — the secret key stays on the server and never reaches the browser — then drop in their softphone component. Make a real call from it.
3. Embed Surge's inbox beside the phone.
4. Theme both to Dead Ringers. Same fonts, same colors, no vendor names.

**Done when** you can make a call and send a text from one browser page that looks like your product.

### January–February — ingestion

1. A webhook endpoint receiving a message every time a call ends. Writes the row, replies immediately. Guard against duplicates — Dial Stack may send the same event twice.
2. A background job that evaluates according to each organization's policy.
3. Cost events written alongside, per call and per evaluation.
4. First reports: call volume, missed calls, peak hours, per-person performance.

**Done when** you can show a client a monthly report you didn't assemble by hand.

### February–March — texting and callback

**Texting.** Build the consent form from Dennis's templates, register one real client's 10DLC brand end to end, mini-port that number's messaging from Dial Stack to Surge, send and receive a real text on the number families call. *Known gap: group texting isn't available yet; it's on Surge's roadmap.*

**Callback.** A caller presses a key to leave the queue, Dial Stack fires `queue.call.exited`, the app watches for a real person to become free and places the callback using their own number as caller ID. Nobody has assembled this yet, including Dial Stack — treat the estimate as softer than the others. CTM's version guesses when someone might be free. Yours waits for an actual person, which is worth saying in proposals.

### March–April — first new client

Pick small and forgiving. Not a 53-rooftop group.

Build the account and write down every step. Port or issue the number. Register the 10DLC brand. Provision handsets. **Set outbound caller ID explicitly — never "Auto (first available)," which is how a client presents a number that isn't theirs. Assign a validated emergency address to every device; it defaults to empty and it's the highest-stakes field in the system.**

The written steps become the onboarding checklist.

### Then — make it run without you

A provisioning script that builds a whole client account through the API, since Dial Stack has no account templates. The checklist tested by having Wendy do a build unaided. Monthly billing reconciliation against `cost_events`.

**Done when** Wendy can onboard a client and you find out afterwards.

---

## The honest timeline

The original phase estimates read as full-time weeks. At 12–18 hours a week, with the shop app cutover, the website, CXpertise, and NFDA landing before November:

| | |
|---|---|
| Vendor answers, contracts, schema | September–October |
| Shell | November–December |
| Ingestion, evaluation, cost tracking | January–February |
| Texting and callback | February–March |
| First new client live | March–April 2027 |

That lands the same quarter as Hub v1 in the company roadmap — consistent rather than coincidental. They're the same build approached from two ends.

**If that's too slow, the lever isn't working faster. It's a contractor on the shell.** Phase 2 is the most contractor-friendly piece: bounded, well-specified, no institutional knowledge required. Backend work goes well with Claude — webhook handlers, evaluation jobs, reporting, provisioning are deterministic and fixable by pasting the error. Interface work goes slower, because visual design needs a fast feedback loop and Claude can't see the screen.

---

## What could still change the plan

- **Carrier of record doesn't hold up in writing.** Everything stops. This is the one real risk.
- **Dial Stack's mobile app is late or poor.** Doesn't stop the build, but directors need a phone that rings on removals and a browser won't ring a locked phone.
- **Surge can't host messaging for this setup.** They say they can. Verify with one real number before promising it to anyone.
- **A large prospect signs early.** A 53- or 300-rooftop group compresses every timeline and forces a hire.
- **The schema can't hold a mystery shop.** Found out in September for free, which is why it gets seeded with real shop data first.

---

## Existing clients

Not migrating. Sanders, Anima-Care, and Szal stay on CTM until someone decides otherwise, and that's a long way off.

They're the specification. Everything a new client expects on day one was learned from what these three actually use — Anima-Care's 80 forwarding numbers and 38 tracking sources, Sanders' 23 queues and 120 external destinations and five-and-a-half-minute ring timeouts, Szal's single number and seven people. The feature inventory built from their configuration is a capability checklist, not a migration plan.

Anima-Care is a pure attribution client and should probably stay on CTM permanently. Szal goes first whenever migration happens. Sanders is the hard one.

---

## The short version

Get the regulatory position in writing while the DID is being provisioned. Design one database that can hold a mystery shop and a real call in the same table, that knows what every client costs, and that never stores a composite score. Prove it with real shop data. Verify call behavior with your own ears in October. Build the shell in November. Ingestion in January. Texting and callback after that. One new client, carefully, with every step written down.

Existing clients stay where they are. The phone is what you sell. The database and the rubric are what you own.
