# Prompt — working on an existing tenant

Copy everything below the line into a new chat opened **inside that
tenant's folder** (Leo, Raj Sports, Machaxi, MatchPoint, MatchPointPride).
Replace `<TENANT>` with the tenant id.

---

You are working on `<TENANT>`, one tenant of the **Academy Manager**
platform. Read `AcademyManager/PLATFORM.md` before you change anything —
it is inherited into this session and it is not background reading.

## The rule that outranks everything else

> **Anything that computes money lives in Postgres.** The fee chain, the
> renewal roll-forward and the payout split are SQL functions called by
> every client. No client does that arithmetic itself.

If a client needs a number, call the RPC. If the number does not exist
yet, add it to the SQL function — never to the app. The reason is not
tidiness: it is that a parent's WhatsApp message and the owner's screen
must never be able to quote different amounts, and two implementations
will eventually disagree.

Call these; do not reimplement them:
`resolve_fee`, `record_fee_payment`, `apply_payment_coverage`,
`reminder_queue`, `void_payment`, `confirm_payment`, `mark_attendance`,
`attendance_roster/history/dashboard`, `compute_payouts`,
`tenant_health`, `platform_health`, `tenant_settings`.

`reminder_queue` owns the chase ladder: −2 heads-up, 0 due, +5 first
chase, +7–14 daily, **+15 stop, manual only**. Do not re-derive any part
of it in a client.

## One database, several tenants

Supabase project `ugsklcipzyiogxynshnh`. Every row carries `tenant_id`.
A change to a shared table or function reaches every live tenant.

- SQL that alters a **shared** table or function goes in
  `AcademyManager/supabase/migrations/` with `--scope shared`.
- A tenant repo's SQL may only create tenant-filtered policies, seed its
  own rows, and create tables only that tenant uses.

Apply everything through the one runner, dry run first:

```bash
AcademyManager/scripts/migrate.sh --dry-run --scope <TENANT> path/to.sql
AcademyManager/scripts/migrate.sh          --scope <TENANT> path/to.sql
```

`schema_migrations` is keyed on **filename + sha256**. Never edit or
rename a file that has been applied — write a new numbered one that
supersedes it.

## Security facts that are easy to get wrong

1. **The anon key is public by design** and is committed in every tenant
   repo. That is correct. `service_role` must never appear in a client.
2. **A policy predicate runs as the calling role.** If a policy for
   `anon` reads another table, `anon` must be able to read that table,
   or the subquery returns nothing and the predicate is silently
   **false** for every row. It does not error; it denies. Anything a
   policy needs from `tenants` goes through a `SECURITY DEFINER` helper
   (`tenant_exists`, `tenant_publishes_timetable`).
3. **`SECURITY DEFINER` bypasses RLS.** Such a function must call
   `assert_staff_or_service(p_tenant)` as its first statement, or the
   tenant is whatever the caller typed.
4. **The default grant is to `PUBLIC`.** `revoke … from anon` is a
   no-op. Revoke from `public, anon`, then grant back deliberately.
5. Do not add a staff guard to anything on an anonymous path
   (`request_booking`, `submit_application`, `slot_rate`,
   `tenant_exists`, `tenant_publishes_timetable`, `sync_ingest`).

These four must stay empty, and are checked hourly by
`cron_health_check`: `rls_audit()`, `rpc_audit()`, `policy_fn_audit()`,
and `events_flowing()` must stay true.

## Staying visible to Academy Manager

The console derives a tenant's status from the newest row in `events`.
A tenant that sends nothing reads as "Onboarding" forever, however live
it is. So the app must:

- post `page_view` on every open (version, device, viewport);
- post `client_error` on an uncaught throw, an unhandled rejection, a
  render crash, **and on a handled failure** — a save that did not save
  is the one that goes unnoticed, because the owner taps the toast away
  and finds out three weeks later;
- post an activity event on real actions (`student_added`,
  `payment_recorded`, `attendance_marked`, …). The activity feed reads
  `events`, not the data tables: a row written without a ping is real in
  the database and invisible in the console.

Never put a name, a phone number or an amount owed in an event.

## How to be sure you have not broken anything

Two outages and one live data leak this platform has had were all found
the same way, and none would have been caught by reading the SQL:

**Measure the same thing before and after, against the live system, with
the real anon key.** A dry run proves the SQL parses. It does not prove
the system still works.

**Assert on content, not on length.** A PostgREST error body is a
four-key JSON object, so `len(response)` reports a hard failure as
"4 rows". Compare against known-good values — Raj publishes 5 centres,
14 batches, 5 sports.

## Working rules

- Edit only this repo. If a change spans repos, say so before making it.
- A breaking change to any function the Android app calls ships as
  `_v2` — the app cannot be force-updated.
- Per-tenant behaviour goes in `tenants.config` jsonb, never a new
  column. New tables are generic (`enrollments`, not `raj_enrollments`).
- **Do not create accounts or set passwords.** If a login is needed,
  give me the exact steps and I will do it. Claims go in **App**
  Metadata: `{"am_role":"staff","tenant_id":"<TENANT>"}` — a user can
  edit their own User Metadata, which is why the policies do not trust
  it.
- Tenant repos are handed to clients. Keep platform-wide material out of
  them.
- Tell me plainly when something you previously said turns out to be
  wrong, and what the correction is.

Start by telling me what you find in this repo that violates any of the
above, before you change anything.
