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

---

## One database, six-plus tenants

Supabase project **`ugsklcipzyiogxynshnh`**, org *Academy Manager*.
Live tenants: `leo`, `machaxi`, `matchpoint`, `raj`, `genalpha`,
`demo-courts`. Every row carries `tenant_id text`.

**Blast radius.** A change to a shared table or function reaches every
live tenant, including client-facing apps in daily use. Dry-run first,
always:

```bash
AcademyManager/scripts/migrate.sh --dry-run --scope <scope> <file.sql>
```

New tables are **generic** (`enrollments`, not `raj_enrollments`) so the
next client reuses them. Per-tenant behaviour goes in `tenants.config`
jsonb, never a new column.

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
| `tenant_exists()`, `tenant_publishes_timetable()` | the `tenants` lookups a policy may safely do |

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

The first three read the catalogue. `anon_probe()` reads behaviour, and
it exists because the shape checks passed cleanly through the worst leak
this platform has had. It also checks the paths that must KEEP working,
because a probe that only hunts leaks reports a healthy system on the
morning you have locked every real user out.

**Not watched, and you should know it:** the project is on the free
plan, so there is no PITR and no restorable daily backup.
`backup.take_snapshot()` copies the tenant tables into the same database
every night and keeps 14 days. That covers a migration doing more than
intended — which has happened — and covers nothing at all if the project
itself is lost. The fix is Pro plus the PITR add-on.

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

## The repos

```
AcademyManager/    platform. Schema, migrations, the runner, operator console.
CourtSync/         optional booking module, per-tenant. Off unless
                   tenants.config.modules.booking is true.
LeoTennis/         tenant 'leo'      — venue + members + bookings
Machaxi/           tenant 'machaxi'  — venue + members + bookings
MatchPoint/        tenant 'matchpoint' — badminton, player tracking
MatchPointPride/   tenant 'mpp'      — separate app for the Pride venue owner
Raj Sports/        tenant 'raj'      — coaching only, NO bookings
RajSportsApp/      Android client for 'raj'
```

Tenant repos are **handed to clients**. Keep platform-wide material out
of them.

---

## Starting a tenant chat

Two prompts, kept in `AcademyManager/prompts/`:

| | |
|---|---|
| `EXISTING-TENANT.md` | Leo, Raj, Machaxi, MatchPoint, MPP |
| `NEW-TENANT.md` | onboarding a new client |

Paste the whole thing into a chat opened inside that tenant's folder.
They carry the house rule, the migration ledger, the four security facts
that are easy to get wrong, and the telemetry a tenant needs to stay
visible in the console. Update them when a lesson is learned rather than
re-teaching it in every chat.

## Working in a session

**Open the terminal inside the folder you intend to change.** That folder
is the session's identity: it loads that repo's `.claude/` settings and
scoped skills, and this file is still inherited. Open at this parent
level only for schema work or when reading across tenants.

Edit only the repo named in the session. If a change spans repos, say so
before making it.

A breaking change to any function the Android app calls ships as `_v2` —
the app cannot be force-updated.
