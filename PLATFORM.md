# Academy Manager — platform rules

This file is inherited by **every** session opened anywhere under this
folder, including inside a tenant. It holds what is true across all of
them. Anything specific to one tenant lives in that tenant's own
`CLAUDE.md`.

---

## THE HOUSE RULE

> **Anything that computes money lives in Postgres.** The fee chain, the
> renewal roll-forward and the payout split are SQL functions called by
> the web app, the Android app *and* the reminder engine. No client does
> that arithmetic itself.
>
> **If you add a money rule, add it to the database — never to a client.**

That is the only reason a parent's WhatsApp message and the manager's
screen can never quote different amounts. It is not a style preference.

### What belongs to the platform, and what belongs to a tenant

The money rule is one case of a general one. Something belongs to the
platform if any of these is true:

1. **It must be identical for every tenant.** One implementation cannot
   disagree with itself; six will.
2. **It must hold when nobody is watching.** Anything that only runs
   while an app is open is guaranteed only during office hours.
3. **It needs a secret a client cannot hold.** Tenant apps are public
   static sites carrying a public key; anything in one is published.

Money computation satisfies all three — hence the house rule. Partner
sync satisfies all three too: the Playo and Hudle keys live in
`vault.secrets`, a booking made at 2am must not double-sell a court, and
Playo's API is Playo's API for everyone. Telemetry satisfies the first
two.

A batch's colour satisfies none of them, and belongs in the app.

**Performing something and reporting it are different questions.** The
platform performs channel sync — the keys are in `vault.secrets` and a
booking made at 2am must not double-sell a court. That does not make a
stale Playo connection an operator-console fact. CourtSync owns the
channel board; this console stays account-level, and only alerts on a
module a tenant has actually bought
(`config.modules.booking`).

The split for sync, concretely: the tenant app **causes** the work — a
booking or a court block enqueues a `sync_jobs` row, and staff set their
own credential through `set_integration_secret`. The platform
**performs** it — `process_sync_jobs` drains the queue every minute
under pg_cron, holding the secrets. Inbound never touches an app at all:
`sync_ingest` is called by the partner, authenticated by
`tenants.api_key`.

---

## One database, six-plus tenants

Supabase project **`ugsklcipzyiogxynshnh`** ("PLATFORM - All Tenants"),
org **`hudpirjhvxqbkhcefabj`** (*AcademyManager*), Pro, region
ap-northeast-1. `ozjhyhhnmixvjlfnrree` (*Academy Manager — staging*) is
the empty second org, kept for a staging project.

Live tenants, as `tenants.id`: `leo`, `mpp`, `raj`, `genalpha`, `demo`,
`ska`, `mezzo`. Every row carries `tenant_id text`.

**`mezzo` is the first paying client** — Mezzo School of Music,
Coimbatore, onboarded 2026-08-19. One operator, ~80 active students,
eight instruments. Its brief is `prompts/tenants/mezzo.md`; the two
things it changed platform-wide are a config-driven reminder rule
(`2026-08-19r`) and `attendance_month()` (`2026-08-19s`).

**`matchpoint` is archived, not live.** `0012` set
`config.archived = true`, and `operator_portfolio()` filters on it, so it
is absent from the console by design — its absence is not a bug to chase.
The row, its 10 members and its 1 payment all remain, and it was still
logging events on 2026-08-19, so the app is not gone either. Treat it as
present in the database and retired from the business.

`machaxi` was retired harder — the repo is kept private and there is no
tenant row. Do not add either back to a list from memory. The id is
`demo`, not `demo-courts`.

The demo tenant is named **Demo Sports Academy** (`2026-08-19m`). It was
"Sports Academy", which read like a real client on a dashboard sitting
between two real ones. `0012` decided it stays visible rather than
hidden, so it has to be legible as a demo from the name alone. Its
`config.brand` still says "Crescent Sports Academy" and the demo app's
own title is still "Sports Academy" — deliberately, because the word
"Demo" belongs on the operator's screen and not in the product a
prospect is being shown.

**Blast radius.** A change to a shared table or function reaches every
live tenant, including client-facing apps in daily use. Dry-run first,
always:

```bash
AcademyManager/scripts/migrate.sh --dry-run --scope <scope> <file.sql>
```

A dry run proves the SQL parses. For anything that touches a grant, a
policy or a role, follow it with a behaviour test holding the real token:

```bash
AcademyManager/scripts/run-test.sh <migration.sql> <test.sql>
```

Both run inside a transaction that is always rolled back. Tests live in
`AcademyManager/supabase/tests/`, named for the migration they prove.

New tables are **generic** (`enrollments`, not `raj_enrollments`) so the
next client reuses them. Per-tenant behaviour goes in `tenants.config`
jsonb, never a new column.

---

## Which table does a new feature go in?

Six teams, one schema, and a new client every few months wanting
something nobody has asked for before. Four questions, in order; stop at
the first that fits. The picture is `docs/tables.html`.

**1. Does the platform already have this thing, meaning the same thing?**
→ use the existing table. Not the same *word* — whether one sentence
honestly describes both. A client calling members "students" is a label,
not a new noun; that is `mapping.ts`'s job, and it may reshape, not
decide.

**2. Same thing, one tenant wants an extra detail on it?** → a jsonb
field on the shared table. Not a new column, not a parallel table.
Promote it to a real column when a **shared** function reads it, a second
tenant needs it, or it needs a constraint or an index — the moment a
shared function reads a key it has become platform vocabulary.

**3. A genuinely new noun only some tenants have?** → its own tables,
still `tenant_id`-scoped, still `--scope shared`, gated on
`config.modules.X`, with RLS and `revoke … from public` in the **first**
migration rather than a follow-up. MatchPoint's 11-table player-tracking
cluster did this correctly; copy it.

**4. Same word, different shape?** → **the trap.** Two teams model the
same-sounding thing two ways, each inside their own repo, and nobody
sees both. Decide out loud before writing anything.

**The forcing question before any new table:** *can one SQL function
answer this for every tenant that has the feature?* If not, you have
either the wrong table or the wrong noun, and you must say which.

### What case 4 actually cost

"Attendance" means three things here, and two of them shared a table
told apart only by an unconstrained text column:

| | | |
|---|---|---|
| `attendance` `kind='staff'` | an employee worked. Payroll | mpp 130, leo 8 |
| `attendance` `kind='member'` | a member visited the venue. Footfall | leo 23, machaxi 5 |
| `sessions`+`attendance_records` | a student present in a scheduled batch | raj 1,884 |

`attendance_roster()`, `attendance_history()`, `attendance_dashboard()`
and `mark_attendance()` read the third only — so the functions this file
lists under *"call these, do not reimplement"* answer for Raj and are
blind to Leo's 23 rows. Nobody noticed, because nothing ever asked.

They were **not** merged, and that is the right call:
`attendance_records.session_id`, `.enrollment_id` and `sessions.batch_id`
are all `NOT NULL`, so the rich model requires batch → session →
enrolment. Leo has 231 bookings and **zero enrolments** — a court venue,
not a coaching academy. Its rows are a different fact, not a broken copy
of class attendance. `0041` constrained `kind`, wrote what each table
holds into `comment on table`, and added the coverage canary below.

---

## The shared-vs-tenant SQL rule

A file in a **tenant** repo may:
- create tenant-filtered policies
- seed its own rows
- create tables only that tenant uses

A file in a tenant repo may **not**:
- `alter` a shared table
- `create trigger` on a shared table
- `create or replace` a shared function

Those go in `AcademyManager/supabase/migrations/` with `--scope shared`.

Two live examples of why: `migration-raj-3.sql` adds check constraints to
shared `batches`/`enrollments`/`fee_rules`, binding every tenant to Raj's
rules; `player-progress-matchpoint.sql:209` puts a trigger on shared
`public.members`. The trigger is correctly tenant-guarded, so it is fine
in practice — but it was written in a tenant repo where nobody reviewing
Leo or Machaxi would ever see it.

---

## Migrations

One runner, `AcademyManager/scripts/migrate.sh`. The per-tenant copies
were deleted — a copy without the ledger check is the hazard itself.

```bash
AcademyManager/scripts/migrate.sh --dry-run --scope raj "Raj Sports/supabase/x.sql"
AcademyManager/scripts/migrate.sh          --scope raj "Raj Sports/supabase/x.sql"
```

`schema_migrations` records every applied file by **filename + sha256**.
The runner refuses a file already applied, and refuses louder if the file
changed since. The ledger row commits in the same transaction as the
change.

**Never rename or move an applied .sql file** — the ledger is keyed on
its basename.

**An assertion that WRITES will commit.** A `do $$ … $$` block at the
foot of a migration is the right way to prove the change works — but the
dry run rolls it back and the real apply does **not**. Anything it
inserted is now production data.

`2026-08-17d` proved `submit_application` by calling it seven times and
left seven fake admissions across two tenants, including rows that
counted against a real per-phone rate limit. They were found only by
counting the table afterwards, which is the check that should be the
habit — the migration reported `✓ applied` either way.

So an assertion may **read** freely, and must clean up anything it
**writes**, in the same block:

```sql
do $$ declare v_id bigint; begin
  v_id := (submit_application('ska','ZZ Probe','9000000901')->>'id')::bigint;
  if …not what was expected… then raise exception '…'; end if;
  delete from applications where tenant_id = 'ska' and id = v_id;  -- always
end $$;
```

Better still, put write-heavy proofs in `supabase/tests/`, which
`run-test.sh` executes inside a transaction it always rolls back. That
is what the directory is for.

The base schema is `AcademyManager/supabase/schema.sql`. It is frozen and
append-only; its in-file redefinitions are correct only read top to
bottom.

---

## Shared functions — call these, do not reimplement

| Function | Owns |
|---|---|
| `resolve_fee()` | the 7-level fee chain (enrolment override → member → batch → centre+sport → sport → centre → tenant default) |
| `record_fee_payment()` | the one write path for fees; rolls `enrollments.renewal_on` forward, writes the timeline, closes the reminder |
| `apply_payment_coverage()` | which months a payment covers |
| `reminder_queue()` | who is due, and for how much. The ladder: −2 heads-up, 0 due, +5 first chase, +7–14 daily, **+15 stop — manual only** |
| `void_payment()`, `confirm_payment()` | reversing and confirming |
| `mark_attendance()`, `attendance_roster()`, `attendance_history()`, `attendance_dashboard()` | attendance |
| `compute_payouts()` | centre revenue share |
| `tenant_health()`, `platform_health()`, `cron_health_check()` | operator observability |
| `rls_audit()` | anon policies with no `tenant_id` in their predicate; logged hourly |
| `rpc_audit()` | `SECURITY DEFINER` functions `anon` can execute that touch tenant data; hourly |
| `policy_fn_audit()` | functions named in a policy that `anon` cannot execute; hourly |
| `platform_errors()` | client-side errors per tenant, grouped by message + version |
| `events_flowing()` | canary: false when the events sink has gone quiet despite recent traffic |
| `shared_fn_coverage()` | per tenant, rows the shared functions can see vs rows that exist where they do not read. `BLIND` means a function in this table cannot answer for that tenant |
| `tenant_exists()`, `tenant_publishes_timetable()` | the `tenants` lookups a policy may safely do |
| `resolve_upi()` | which account a fee is collected to: batch → centre → tenant `config.billing`. It is money, so it lives here |
| `my_access()` | who the caller is and what they may reach. Clients route on it after sign-in |
| `my_centres()`, `my_attendance_batches()`, `assert_attendance_access()` | the attendance-only `coach` role, scoped to its assigned centres |
| `my_attendance_insights()` | one batch's calendar, rates and per-student standing. `p_batch` is a required **target**, which is what lets a coach call it; no money, no phone numbers |

If a client needs a number, there is probably already a function for it.
Read before writing.

---

## What is watched, and what is not

| | |
|---|---|
| `rls_audit()` | anon policies with no tenant filter — a shape check |
| `rpc_audit()` | definer functions anon can execute — a shape check |
| `policy_fn_audit()` | functions a policy names that anon cannot execute |
| `anon_probe()` | **actually calls the dangerous endpoints as anon**, hourly |
| `events_flowing()` | the sink has gone quiet despite recent traffic |
| `shared_fn_coverage()` | a tenant's rows sit somewhere no shared function reads. Hourly at :37 |

The first three read the catalogue. `anon_probe()` reads behaviour, and
it exists because the shape checks passed cleanly through the worst leak
this platform has had. It also checks the paths that must KEEP working,
because a probe that only hunts leaks reports a healthy system on the
morning you have locked every real user out.

**Backups, and what they do not cover.** Since 2026-08-11 the project is
on **Pro**, in org `hudpirjhvxqbkhcefabj` (*AcademyManager*), so there
are real daily physical backups — 8 of them at the time of writing.
Before that there were none at all, which is worth remembering the next
time a migration is about to run.

Two layers, and they fail differently:

| | |
|---|---|
| `backup.take_snapshot()` | nightly 22:10 UTC / 03:40 IST, copies the tenant tables **into the same database**, keeps 14 days. Covers a migration doing more than intended — which has happened. Covers nothing if the project is lost. |
| Supabase daily physical backup | a real off-box restore point, one per day. Covers losing the project. |

**PITR is deliberately NOT enabled.** It is $100/month for 7 days — four
times the entire Pro bill — and the gap it closes is now "up to 24 hours
of loss" rather than "everything", which at this traffic is a handful of
payments recoverable from WhatsApp records. Declined on 2026-08-11 with
that arithmetic on the table, not overlooked. Revisit when a tenant
takes money at a volume where a lost day cannot be re-entered by hand.

## Latency, and why the project ref must not change casually

The database is not slow. Measured 2026-08-12: the roster reads in 5 ms,
finance in 4 ms, attendance over 1,477 rows in 5 ms, `reminder_queue` in
20 ms. The largest table on the platform is `attendance_records` at
5,117 rows and the whole database is a few megabytes.

**A round-trip to the API takes ~180 ms**, because the project is in
`ap-northeast-1` (Tokyo) and every user is in India. Network is ~97% of
each request. So the only optimisation that matters is *fewer
round-trips* — the Finance tab went roughly 4× faster purely by fetching
its four independent reads in parallel instead of one after another.
Nothing is gained by tuning SQL, and the performance advisor's 47
unindexed foreign keys are advice for tables a hundred times larger;
adding them here is write cost for no reader.

**Moving to `ap-south-1` would fix the 180 ms** — and Supabase cannot
change a region in place. It means a new project, so a new ref AND a new
anon key, and:

- **57 files across 13 repos** hardcode `ugsklcipzyiogxynshnh`.
- **Four mobile clients cannot be force-updated** — GenAlphaApp,
  RajSportsApp, MatchPointPride and RajSportsIOS. None has a minimum-
  version check. RajSportsIOS needs App Store review, so it is days.
- The Meta webhook, storage objects, edge functions, vault secrets and
  every cron job move by hand.

**So the prerequisite is a version gate in all four clients, shipped,
before the ref changes.** Otherwise every installed copy writes to a
project that is about to be deleted — exactly what GenAlpha's app spent
2026-08-11 recovering from, times four, with Apple in the path.

Deferred on 2026-08-12 with that arithmetic on the table. Do not start a
ref change without the gates.

## Security

- The **anon** key is public by design and committed in every tenant
  repo. That is correct. `service_role` must never appear in a client.
- RLS is the only thing separating tenants. `rls_audit()` must stay
  empty; `cron_health_check` logs to `sync_log` if it does not.
- Anonymous read of `centres`/`batches`/`sports` is **opt-in** per tenant
  via `config.features.publicTimetable`. New tenants are private by
  default. Do not widen a policy to "fix" a client filter.
- A PIN compared in JavaScript is not access control. Where a tenant app
  uses one, it must sit on top of a real Supabase session, not instead of
  one.
- **Never prefill a password in a client file.** Tenant apps are public
  static sites, so a value in `login.html` is a live credential on the
  open web, and it stays in git history after you remove it. Rotate, do
  not merely delete. `Raj Sports/login.html` did exactly this; removed
  and rotated.

### A third role: `coach`, and the shape to copy

`app_metadata.am_role = 'coach'` is attendance-only, scoped to the centres
named in `staff_scopes` (migration `0039`). The shape is worth reusing,
because the tempting version is wrong in four ways:

1. **Do not loosen `assert_staff()`** to admit the new role. That single
   line guards `record_fee_payment`, `reminder_queue`, `compute_payouts`
   and every other definer function; widening it to let someone mark a
   register hands them the whole academy. Write a narrower guard for the
   specific functions instead — `assert_attendance_access(tenant, batch)`.
2. **A new role passes no RLS policy**, because every policy tests
   `auth_role() = 'staff'`. That is what keeps the change small: the
   tables return nothing and the guarded functions are the role's entire
   reach. Verify it; do not assume it.
3. **Only guard on an argument that is a target, not a filter.**
   `attendance_history(p_tenant, p_from, p_to, p_centre, p_batch, …)`
   takes `p_batch` as an optional filter, so a per-batch check waves a
   null straight through and returns every centre. Those keep the staff
   guard.
4. **Prove it by signing in.**
   `supabase/tests/0039-attendance-access.sql` sets a real JWT and asserts
   what the role can and cannot reach. It is mutation-tested, so it fails
   when the guard is broken. Reading the grants would have caught none of
   the above — the same lesson as `anon_probe()`.

### SECURITY DEFINER goes around RLS — grants are the only gate

A `SECURITY DEFINER` function runs as its owner, so **RLS does not
apply inside it**. If it takes `p_tenant` and `anon` can execute it, the
tenant is whatever the caller types, and the public key in every repo is
enough to read it.

**The default grant is to `PUBLIC`.** A function is anon-callable unless
you revoke it *from `PUBLIC`* — `revoke … from anon` is a no-op. And
`p_tenant` is a naming convention, not a security property: the ones
that leaked hardest (`enrollment_fee`, `enrollment_payment_summary`)
take an enrollment id and no tenant at all.

So, for any `SECURITY DEFINER` function:

1. `revoke execute … from public, anon` — note **`public`**, the
   pseudo-role. The grant that matters is usually the bare `=X/postgres`
   in the ACL; revoking `anon` alone silently changes nothing.
2. `grant execute … to authenticated, service_role`.
3. `perform assert_staff_or_service(p_tenant)` as the **first line** of
   the body, so a signed-in staff member of one tenant cannot pass
   another tenant's id. All of them now do, except the four public ones
   and `slot_rate` — check before adding.

   For a helper only ever called by other `SECURITY DEFINER` functions,
   `revoke execute … from authenticated` instead. Definer functions run
   as the owner, so internal calls are unaffected, and it is a smaller
   change than editing a body.
4. **But never on a function a policy or an anon path calls.** Revoking
   `is_locked()` from `PUBLIC` took Raj's timetable down, because
   policies for the `public` role apply to anon and call it.

`rpc_audit()` must stay empty apart from the four that are public by
design: `request_booking`, `submit_application`, `tenant_exists`,
`tenant_publishes_timetable`.

### A policy predicate runs as the calling role

If a policy for `anon` reads another table, `anon` must be able to read
that table — otherwise the subquery returns nothing and the predicate is
silently **false**, for every row. It does not fail; it denies.

Anything a policy needs from `tenants` goes through a `SECURITY DEFINER`
helper: `tenant_exists()`, `tenant_publishes_timetable()`. Never inline
`exists (select 1 from tenants …)` into a policy.

This has cost two outages, both mine, both fixed the same day:

| Broke | Cause | Fix |
|---|---|---|
| Raj's public timetable, ~4 min | `jsonb_set` with `create_missing` only creates the *final* key; Raj's config had no `features` object, so the update was a no-op | `0004`, object merge + `raise exception` guard |
| Every tenant's analytics and error reporting, ~3 h | `exists (select … from tenants)` inlined into `events_public_w`, evaluated as `anon` | `0007`, `tenant_exists()` + `events_flowing()` canary |
| Every family's name and phone at every tenant, readable by anyone (pre-existing) | `reminder_queue{p_tenant:"raj"}` returned 55 rows to the public key — `SECURITY DEFINER` with no guard and `PUBLIC` execute | `0009`, revoke from `public`+`anon` |
| Fees, payment summaries, the sync queue and the health job, all anon-callable (pre-existing, plus three functions I had added hours earlier) | `0009` keyed on the *argument name* `p_tenant`; `enrollment_fee` and friends take an enrollment id, so it never saw them | `0010`, default-closed across every `SECURITY DEFINER`, `rpc_audit()` redefined around the real property |
| Raj's public timetable, again, ~6 min | `0010` revoked `is_locked()` from `PUBLIC`; policies for the `public` role apply to anon and call it, so every read errored | `0011`, grant restored, `policy_fn_audit()` canary |

Both were caught by **measuring the same thing before and after** — anon
row counts, then event counts. Neither would have been caught by reading
the SQL, and `rls_audit()` passed cleanly through the second one, because
a shape check cannot see behaviour.

So: after any migration that touches a policy **or a grant**, exercise
the real path with the real anon key. A dry run proves the SQL parses,
not that the system still works.

And **assert on content, not on length.** The `is_locked` breakage hid
for several minutes behind a probe that did `len(response)` — a
PostgREST error body is a four-key object, so a hard failure read back
as "4 rows". A check that cannot tell an error from data is not a check.
Compare against known-good values: Raj publishes 5 centres, 14 batches,
5 sports.

---

## Billing: free, trial, paying, churned

**Mezzo School of Music is the first paying client** — ₹899/month,
paid 2026-08-19, `status = 'paying'`, first invoice due 19 Sep 2026. That
is the platform's entire real revenue, and it is the only MRR figure in
the database that anyone has actually paid.

Every MRR figure before that date was a placeholder invented to make the
dashboard look populated — Leo's ₹899 and MPP's ₹1,500 said so in their
own `notes` — and they were adding ₹2,399 of imaginary revenue to the
portfolio total. `2026-08-19n` zeroed them and moved the old values into
`notes`, so the real contract value can be set against what was assumed.

### The four statuses

`subscriptions.status` is one of four, and a CHECK constraint refuses
anything else:

| status | what it means | what `renews_on` means |
|---|---|---|
| `free` | used, deliberately never billed | nothing; ignored |
| `trial` | evaluating | when the trial **ends** |
| `paying` | real money | when the next invoice **falls due** |
| `churned` | stopped | nothing; ignored |

**`overdue` is not a status.** It cannot be stored. It is derived, and
only a `paying` account can be it.

### The badge, derived from status *and* date together

| shows | when |
|---|---|
| **Paying** | `paying`, invoice date ahead |
| **Overdue** | `paying`, invoice date behind — the only red badge |
| **Trial** | `trial`, end date ahead — "Trial ends 1 Sep" |
| **Trial ended** | `trial`, end date behind — a decision is due, not a debt |
| **Free** / **Churned** | grey, needs nothing |

### Why it used to be wrong, which is the part worth keeping

The old rule was *"`status = 'overdue'` **or** `renews_on` is in the
past"*, and it read the date without the status. Two faults compounded:

1. **Six statuses, three meanings.** `active` and `paid` did the same
   job; `trial` and `pilot` did the same job; `overdue` was both a stored
   status and a derived one, so the same fact had two homes that could
   disagree.
2. **One date, two jobs.** `renews_on` meant "next invoice" for a paying
   account and "pilot review date" for everyone else. Every tenant was a
   pilot whose review date had passed, so **every tenant showed red** —
   money late on accounts that had never been invoiced. That is the
   *same word, different shape* trap from the table-choice rules, in the
   billing column.

A red badge that is always on tells you nothing, and this one was always
on. If you find yourself reading `renews_on` without also reading
`status`, you are re-introducing it.

### Changing it

`set_subscription(tenant, status, plan, mrr, renews_on)` — operator only,
every change written to `sync_log`, and a tenant's own staff cannot mark
themselves paying. The old words (`active`, `paid`, `pilot`, `cancelled`,
`overdue`) still map rather than erroring, because the point was to stop
anyone needing to know six of them. Marking someone `paying` with a date
already behind them rolls the date forward a month, so the change cannot
show as overdue a second after you make it.

Change it from the academy's card in the console, under Plan & billing.

### Who is what, 2026-08-19

| | | |
|---|---|---|
| `ska` | **trial → 1 Sep 2026** | testing through 31 Aug, going live 1 Sep. Set the contract value and flip to `paying` on the day |
| `leo`, `raj`, `mpp` | trial | dates already behind them, so they read "Trial ended" — a decision is due on each |
| `mezzo` | **paying — ₹899/mo** | first paying client. Next invoice 19 Sep 2026 |
| `genalpha` | free | first client, used daily, deliberately unbilled |
| `demo` | free | the sales demo. Never bill |
| `matchpoint` | — | archived; no subscription row |

## Federated tenants

A tenant does not have to live in this database to appear in the
console. The mechanism exists and works — but **nothing uses it today**,
and this section used to describe GenAlpha, which is now a native
tenant. Read it as the design for the next outside client, not as a
description of anything currently running.

How it works: the outside app posts `page_view`, `client_error` and a
daily `tenant_rollup` to this project's `events` table with the public
anon key — no new secret, no new endpoint, no new table.
`operator_portfolio()` falls back to the newest rollup when a tenant's
native rows are empty, so the card shows real numbers.

Counts only, never a name or a phone number. Forgeable by anyone holding
the public key, which is acceptable for aggregate numbers on a dashboard
and is exactly why nothing personal goes in one.

`tenants.config.federated = true` marks them. Every live tenant is
`false` as of 2026-08-12.

**What happened to the GenAlpha exception.** It ran federated because
merging meant migrating live data and rewriting a working app. That was
right until it wasn't: reporting counts kept it visible but left its
money outside `record_fee_payment`, its fees hardcoded in three clients,
and 81 families on a project with `USING(true)` on every table. It was
migrated on 2026-08-10/11 — nineteen tables onto the shared schema
behind a `genalpha` compatibility layer of views. The old project was
deleted on 2026-08-12.

The lesson for the next one: federation is fine for a tenant you are
only *watching*. The moment you need to fix its money, it has to come
inside.

## Watching the teams: how one tenant is stopped from breaking another

Six tenant teams now ship into one database. The danger is no longer a
leak — RLS handles reads — it is a **write or a schema change made by
one team that lands on everyone**. Three layers, in the order they fire:

**1. Prevention — the runner refuses it.**
`migrate.sh` rejects a file applied with a tenant `--scope` that alters
a shared table, creates any trigger, or replaces a shared function. This
is the `migration-raj-3` and `player-progress-matchpoint` lesson made
mechanical. Grants on shared tables are allowed but warn out loud.

**2. Attribution — every change is stamped.**
The runner sets `app.migration` inside the transaction, so the database
records *which file, at which scope* caused each object change.

**3. Detection — the database tells on everyone, including us.**
| | |
|---|---|
| `ddl_log` + `schema_drift(days)` | every DDL statement in the database, whoever ran it. A shared-object row with `migration IS NULL` **bypassed the runner** — dashboard, psql, another chat window. Hourly alarm. |
| `cross_tenant_integrity()` | walks the FK catalogue and finds rows whose parent belongs to a *different* tenant (a payment on another academy's enrollment). Catalogue-driven, so new tables are covered the day they get a FK. Hourly alarm. |

`schema_migrations` records intent; `ddl_log` records what actually
happened. When they disagree, believe `ddl_log`.

**The manager's view:** `scripts/team-report.sh [days]` — what each team
shipped, any shared-boundary DDL in their repo, plus the platform truth
(drift, cross-tenant rows, the three audits, the probe). Read the
second half; the first half is a shape check on git history.

### Shared tables hold what EVERY tenant needs

A shared table is not a convenient place to put a field. It is a
contract six academies sign.

- **Tenant-specific field** → a tenant-owned table keyed on the shared
  row's id, or `config` jsonb. Not a new column on `members`.
- **Tenant-specific rule** → a partial constraint that names the tenant:
  `check (tenant_id <> 'raj' or status in ('held','cancelled'))`.
  A bare `CHECK` on a shared table is a law for all six. Raj's session
  lifecycle was one until 2026-08-01.
- **Genuine data sanity** (`amount >= 0`, `end_time > start_time`,
  valid UPI) *should* bind everyone. Keep those.

`shared_widening_audit()` finds both drifts — columns only one tenant
fills, and policy-shaped `CHECK`s with no tenant scope. Everything true
on 2026-08-01 is **baselined as accepted**, so the weekly report shows
only what is NEW. One new finding is a five-minute conversation; forty
is wallpaper, which is why the baseline exists.

### New tenants start from the vanilla-JS template

Leo → Machaxi → MatchPoint are the same app with the names changed.
That is the intended path: a new academy starts as a copy of the
closest existing vanilla-JS tenant, not a new stack.

MatchPoint Pride (React + Vite) is a **deliberate exception**, not the
new default. Adopt React for a tenant only when that tenant's product
needs it and someone has decided to carry two stacks — never by
accident, and never because it is the most recent thing built.

### The week runs itself

| When | What | Where |
|---|---|---|
| every minute | sync queue drains | `process_sync_jobs` |
| hourly | audits, anon probe, DDL drift, cross-tenant rows | `sync_log`, tenant `platform` |
| **Monday 07:00 UTC** | **weekly digest** — what needs a human, what each team shipped, which academies were active | `sync_log`, action `weekly_digest` |
| when you want it | the same, on screen, plus per-repo git activity | `scripts/team-report.sh [days]` |

Migration files are named **by date** (`2026-08-01-thing.sql`), not by
sequence. Two sessions collided on `0038` in one afternoon.

**Dates collide too — this file used to claim they could not.** It is the
same-day suffix that runs out: `2026-08-01c`, `2026-08-05c`,
`2026-08-12u`, `2026-08-12v` and `2026-08-19a` are each used by two
different migrations, and `2026-08-14a` by three. Nothing breaks, because
`schema_migrations` keys on the whole basename — but "re-run 12u" stops
having one answer, and two parallel sessions can each believe they own
the letter.

So the runner checks it rather than the docs asserting it: applying a
file whose date+letter prefix is already taken prints the file that owns
it and suggests the next free letter. It warns rather than refuses,
because the colliding files are applied already and must keep applying.
It still warns on numbered names.

**Renaming an applied file means renaming its ledger row in the same
breath.** The ledger keys on the basename, so a rename alone leaves the
runner seeing an unapplied migration and the old row pointing at nothing.
Update `schema_migrations.filename` *and* `sha256` together, then prove
it by running the real apply and watching it refuse. Done that way a
rename is safe; done half-way it is how a migration gets applied twice.

### The rules teams are held to

1. **Shared DDL is shared-scope, always** — even when it is tenant-
   guarded. A trigger on `members` fires for all six tenants; the guard
   makes it *safe*, not *tenant repo material*.
2. **Never DELETE or UPDATE a shared table without `tenant_id` in the
   WHERE clause.** Ids are global. `delete from bookings where ext_ref
   is not null` empties every academy's channel bookings.
3. **Never write another tenant's id** — not in app code, not in a
   seed, not in a test. A test that inserts `tenant_id='leo'` from the
   Raj repo is a cross-tenant write with a friendly name.
4. **Tests do not run against production.** A regression harness that
   inserts into shared tables and rolls back is one failed rollback away
   from being a data incident.
5. **A new `SECURITY DEFINER` function is `PUBLIC`-executable until you
   revoke it.** Revoking `anon` alone changes nothing.
6. **Pick your migration number immediately before applying.** Parallel
   sessions have collided; the ledger is keyed on the filename.

## One database, one business

This project holds Academy Manager and nothing else.

It briefly also held two tables (`memories`, `push_subscriptions`), an
edge function and an every-minute cron job belonging to a family side
project that borrowed the space when a free-project quota ran out. That
app moved to Deno KV long before; what remained was residue, and it
cost four pieces of platform machinery to guard — a seal, an hourly
probe, table comments, and a rule in this file.

Migration `0041` removed all of it, with the owner's consent and after
exporting the rows. The lesson is worth keeping even though the
tenant is gone: **nothing shares this project that is not Academy
Manager.** A side project needing a database gets its own — the cost
of a second free project is far below the cost of explaining, guarding
and second-guessing a stranger's tables inside a client-facing system.

## The repos

```
AcademyManager/    platform. Schema, migrations, the runner, operator console.
CourtSync/         optional booking module, per-tenant. Off unless
                   tenants.config.modules.booking is true.
GenAlpha/          tenant 'genalpha' — cricket, manager web app
                   (genalphaacademy.in). Moved in here 2026-08-11 from
                   Documents/GitHub/cricket-academy-manager.
GenAlphaApp/       Android client for 'genalpha', plus GenAlpha-era SQL.
                   Moved in 2026-08-11 from Documents/New project.
LeoTennis/         tenant 'leo'      — venue + members + bookings
Machaxi/           RETIRED tenant. Repo kept private: its git history
                   holds real member names and phone numbers.
MatchPoint/        ARCHIVED tenant 'matchpoint' — badminton, player
                   tracking. config.archived = true, so it is absent from
                   the console; the rows and the 11-table player cluster
                   are all still there.
MatchPointPride/   tenant 'mpp'      — separate app for the Pride venue owner
Mezzo/             tenant 'mezzo'    — music school, first paying client.
                   Three tabs: register, dues, money. One operator.
Raj Sports/        tenant 'raj'      — coaching only, NO bookings
RajSportsApp/      Android client for 'raj'
RajSportsIOS/      iOS client for 'raj'
```

Tenant repos are **handed to clients**. Keep platform-wide material out
of them.

---

## Starting a tenant chat

Two prompts, kept in `AcademyManager/prompts/`:

| | |
|---|---|
| `EXISTING-TENANT.md` | Leo, Raj, GenAlpha, MPP, SKA, Demo |
| `NEW-TENANT.md` | onboarding a new client |

Paste the whole thing into a chat opened inside that tenant's folder.
They carry the house rule, the migration ledger, the four security facts
that are easy to get wrong, and the telemetry a tenant needs to stay
visible in the console. Update them when a lesson is learned rather than
re-teaching it in every chat.

**Then paste the tenant's own brief** from `prompts/tenants/<id>.md`.
Those hold what is true for ONE tenant this week — Leo being correctly
`BLIND` to the attendance functions, GenAlpha's two `reminder_events`,
MPP being React on purpose — the things a general prompt cannot carry and
a fresh chat otherwise re-learns the hard way.

## Say only what you have checked

Six statements in one session on 2026-08-12 were confidently wrong. None
was a coin flip; they fall into four repeatable shapes, and each has a
cheap defence.

| What was said | Why it was wrong |
|---|---|
| "The plan is to transfer the project between orgs" | Reconstructed from the live dashboard. The decision on record was the opposite — move the subscription, not the project. |
| "Realtime publishes nothing and is unfixed" | It had been fixed earlier **in the same session**, by me. |
| "MPP writes to zero shared tables" | `grep 'from("members")'` found nothing. MPP writes through RPC helpers — `record_fee_payment`, `void_payment`, `discontinue_member`. |
| "Ask the owner if students were stranded in localStorage" | Built on the line above. 63 students were in Postgres, deleted deliberately for handover, with a backup asserted in the same transaction. |
| "Meta is delivering callbacks to the dead project" | Compared `16:29` from a database rendering IST against `13:08` from one rendering UTC. The legacy row was two hours *older*. |
| "The columns are missing from reminder_events" — five times | The owner was reading `public.reminder_events`; every answer described `genalpha.reminder_events`. |

**The four shapes, and the rule for each.**

1. **Reconstructing a decision from current state.** What a system looks
   like now does not tell you what was agreed, or what you already did an
   hour ago. Read the record — this file, the migration headers, the
   ledger, `git log` — before describing a plan or calling work
   outstanding.

2. **A negative from a single search.** "X does not exist" and "nothing
   does Y" are the least reliable things said here, because one narrow
   grep feels like proof. A negative needs either a second search shaped
   differently, or a behavioural test. Never ship one on its own.

3. **Comparing values whose units were never established.** Two numbers
   that look comparable and are not. See the timestamp section below; the
   same trap applies to counts across schemas, and to sizes before and
   after a `gc`.

4. **Answering about the wrong object.** Schema-qualify everything.
   `public.reminder_events` and `genalpha.reminder_events` are different
   relations with different column counts, and "the table" is not an
   answer to which one.

**Distinguish verified from believed, out loud.** The real damage is not
being wrong; it is being wrong in the same confident register as being
right, so the reader cannot tell which they are getting. Say "I checked
X and saw Y", or say "I think" — never state an unchecked inference in
the voice of a measurement.

**What actually catches this** is not more care. It is a check that runs:

- `2026-08-12t` asserted, as anon over the real API, that `phone`, `name`
  and `amount` were refused. The reasoning behind that migration was
  wrong — anon held a blanket `arwdDxtm` grant, so the "fix" would have
  published every parent's phone number. The check caught it; the
  thinking did not.
- The touch-trigger probe printed `UNCHANGED` rather than being assumed.
- Behaviour was tested over HTTP with the real anon key, not simulated
  in-database.

So: assert on content, exercise the real path, and put the assertion in
the migration where it runs again. A conclusion defended only by
reasoning is the kind that has been wrong here.

## Timestamps: say the zone, or you will get it wrong

**Every timestamp you compare, print or reason about must carry its zone
explicitly.** This has produced a wrong conclusion more than once in a
single day, each time by comparing two numbers that looked comparable
and were not.

The traps, all real:

| | |
|---|---|
| Two databases, two zones | the platform session renders UTC; GenAlpha's legacy project rendered `+05:30`. `16:29` in one is `10:59` in the other, and "the old project is receiving newer traffic" was concluded from exactly that. |
| Cron is UTC | `30 9 * * *` is **15:00 IST**. `config.whatsapp.sendHourIST` is read into the sender's config object and never used to schedule anything — the cron line is the only thing that sets the hour. |
| Meta sends epoch seconds | a webhook's `timestamp` is UTC epoch. Compare it to `created_at` only after converting one of them. |
| `current_date` follows the session | so a "today" filter run from a UTC session drops the last 5½ hours of an IST day, and the reminder ladder is built on IST calendar days. |

So:

- **Print the zone.** `created_at at time zone 'Asia/Kolkata'` with the
  column aliased `_ist`, or `::timestamptz` left in UTC and aliased
  `_utc`. Never a bare `::text`.
- **Compare epochs, not strings.** `extract(epoch from …)` on both sides
  when the two values came from different systems.
- **Convert once, at the edge.** IST is presentation. Storage and
  comparison are UTC.
- **State the zone in prose too.** "10:59 UTC (16:29 IST)" — writing both
  is what catches the error before it becomes a conclusion.

Reminders go out **15:00 IST = 09:30 UTC**. If those two ever stop
agreeing in something you read, the reading is wrong, not the schedule.

## Commit messages: 100 characters, all repos

**A commit message is at most 100 characters.** One line. Every repo,
every tenant, platform included.

```
v1.0.61 - the PIN is a real sign-in, so the roster loads
```

The reasoning does not vanish, it moves to where it is read: a migration
header, a comment above the code it explains, or this file when it is a
rule. A paragraph in `git log` is read once by nobody; the same paragraph
at the top of the .sql file is read by whoever opens it next.

## Working in a session

**Open the terminal inside the folder you intend to change.** That folder
is the session's identity: it loads that repo's `.claude/` settings and
scoped skills, and this file is still inherited. Open at this parent
level only for schema work or when reading across tenants.

Edit only the repo named in the session. If a change spans repos, say so
before making it.

A breaking change to any function the Android app calls ships as `_v2` —
the app cannot be force-updated.
