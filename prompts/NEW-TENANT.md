# Prompt — onboarding a new tenant

Copy everything below the line into a new chat opened **inside the new
tenant's folder**, under *Academy Manager Business*. Fill in the four
values at the top and delete anything that does not apply.

---

I am onboarding a new tenant of the **Academy Manager** platform.

    tenant id      <short-lowercase-id, e.g. mpp>
    academy name   <what the operator console should display>
    city / venue   <city, venue name, address, courts, hours>
    model          coaching fees | court bookings | both

Read `AcademyManager/PLATFORM.md` first. It is inherited into this
session and it is the contract, not background reading.

## The rule that outranks everything else

> **Anything that computes money lives in Postgres.** The fee chain, the
> renewal roll-forward and the payout split are SQL functions called by
> every client. No client does that arithmetic itself.

Build the app against these from the first commit. Retrofitting is
expensive: the last tenant to be built standalone cost ~950 lines of
TypeScript to unpick, and until it was unpicked its screen and its
WhatsApp messages could disagree about what a parent owed.

`resolve_fee`, `record_fee_payment`, `apply_payment_coverage`,
`reminder_queue`, `void_payment`, `mark_attendance`,
`attendance_roster/history/dashboard`, `compute_payouts`,
`tenant_settings`. If a number is needed and no function returns it, add
it to the SQL — never to the client.

`reminder_queue` owns the chase ladder: −2 heads-up, 0 due, +5 first
chase, +7–14 daily, **+15 stop, manual only**. Never re-derive it.

## Do these in order

**1. Register the tenant.** One migration, `--scope <tenant>`:

```sql
insert into tenants (id, name, kind, config) values (…)
```

`config` carries per-tenant behaviour — brand, venues, billing, feature
flags. Never add a column to a shared table for one tenant. Set
`modules.booking` only if they actually want CourtSync, and leave
`features.publicTimetable` **false**: anonymous read of
centres/batches/sports is opt-in, and new tenants are private by default.

Nothing else can happen before this row exists: the `events` insert
policy rejects an unregistered `tenant_id`, so the app cannot even
report an error.

**2. Structure.** A `centres` row and a `sports` row. Batches and fee
rules come with the real data, not before it.

**3. The staff login.** *I* create it in the Supabase dashboard — you do
not create accounts or set passwords. Tell me when to, then set its
claims by migration:

```json
{ "am_role": "staff", "tenant_id": "<tenant>" }
```

It must be **App** Metadata, not User Metadata — a user can edit their
own User Metadata, which is exactly why RLS does not trust it. An
account without these claims signs in perfectly and then sees nothing at
all, which looks identical to a broken app; have the client check the
claims and say which tenant the login belongs to.

**4. The app.** Postgres is the store. No local copy of the academy's
records — no cached document, no draft. Every write goes to the database
and is read straight back, because a write usually changes more than it
says: recording a fee moves a renewal date and closes a reminder.

Local storage is for the session and the unlock secret only.

**5. Telemetry, from day one.** The console derives a tenant's status
from the newest row in `events`. A tenant that sends nothing reads as
"Onboarding" forever. Post `page_view` on open; `client_error` on
crashes **and on handled failures**; an activity event on real actions.
No names, no phone numbers, no amounts in any event.

**6. Seed sample data** so the client can be shown a working app before
they type anything. Mark it (`members.is_demo = true`) so it can be
removed with one delete on the day they go live. Spread renewal dates
across a plausible month so the ladder has something at each rung —
seeding them all on the 1st produces a valid dataset showing an academy
in total collapse.

**Never put a real-looking payment handle in sample data.** Sample data
may be fake; payment destinations may not. A UPI id that looks real and
belongs to someone else is how a parent's fee reaches a stranger.

## Security facts that are easy to get wrong

1. The **anon key is public by design** and belongs in the repo.
   `service_role` must never appear in a client.
2. **A policy predicate runs as the calling role.** If a policy for
   `anon` reads another table, `anon` must be able to read it, or the
   predicate is silently **false** for every row — it denies rather than
   errors. Use the `SECURITY DEFINER` helpers.
3. **`SECURITY DEFINER` bypasses RLS.** Any such function taking
   `p_tenant` calls `assert_staff_or_service(p_tenant)` first.
4. **The default grant is to `PUBLIC`.** `revoke … from anon` is a
   no-op. Revoke from `public, anon`, then grant back deliberately.

`rls_audit()`, `rpc_audit()` and `policy_fn_audit()` must stay empty and
`events_flowing()` true; `cron_health_check` checks hourly.

## Migrations

One runner, dry run first, `--scope` mandatory:

```bash
AcademyManager/scripts/migrate.sh --dry-run --scope <tenant> path/to.sql
AcademyManager/scripts/migrate.sh          --scope <tenant> path/to.sql
```

`schema_migrations` is keyed on filename + sha256. Never edit or rename
an applied file — supersede it with a new numbered one.

## How to be sure it works

**Measure the same thing before and after, against the live system, with
the real anon key.** A dry run proves the SQL parses, not that anything
works. **Assert on content, not on length** — a PostgREST error body is
a four-key object, so `len(response)` reports a failure as "4 rows".

Then run the app and look at it. The worst bugs on this platform have
all been valid, consistent and wrong: correct row counts, passing
assertions, and a dashboard showing an academy that had never taken a
rupee.

## Working rules

- Tenant repos are handed to clients. Keep platform-wide material out.
- Per-tenant behaviour in `tenants.config`; generic table names.
- **Before proposing any new table**, work through "Which table does a
  new feature go in?" in PLATFORM.md — same noun → existing table; extra
  detail → jsonb; genuinely new noun → a module cluster gated on
  `config.modules.X`. The forcing question: *can one SQL function answer
  this for every tenant that has the feature?* Say which noun you
  believe is new, and why, before writing the migration. `attendance`
  is what happens when nobody does.
- **Set the module flags when a module is sold.** Nothing enforces it,
  and a gate reading `config.modules.X` on a tenant whose `modules` is
  `{}` is correct only by accident.
- A breaking change to anything an Android client calls ships as `_v2`.
- Tell me plainly when something you said turns out to be wrong.

Start by proposing the tenant row and the migration plan. Do not write
app code until the tenant exists and I have confirmed the login.
