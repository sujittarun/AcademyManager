# Raj Sports — paste into a chat opened in `Raj Sports/`

Paste `prompts/EXISTING-TENANT.md` first. This is the tenant-specific part,
current as of **2026-08-12**.

`raj` — coaching only, **no bookings**. Three repos: `Raj Sports/` (web),
`RajSportsApp/` (Android), `RajSportsIOS/` (iOS).

## State

104 members, 112 enrollments, 101 payments, 0 bookings. Public timetable
is **on** — anon sees exactly **5 centres, 14 batches, 5 sports**. Those
are the known-good numbers `anon_probe()` asserts on; if a change makes
them move, the change is wrong.

## What matters here

- **Raj is the reference tenant for the fee chain.** `resolve_fee('raj',
  …, 3, …)` returns **3600**. `anon_probe()` and several migrations
  assert on it.
- **WhatsApp is OFF** (`config.whatsapp.enabled = false`) even though
  `raj-fee-reminders-daily` and `-retry` are active cron jobs. That is
  correct: the sender has three gates (enabled, mode=auto, !dryRun) and
  the cron simply no-ops. Do not "fix" the cron.
- **Two mobile clients cannot be force-updated.** Any breaking change to
  a function they call ships as `_v2`.
- Raj has real `sessions` + `attendance_records`, so the shared
  attendance functions (`attendance_roster`, `_history`, `_dashboard`)
  answer correctly for this tenant. It is the only tenant they fully
  cover.
- `migration-raj-3.sql` once added CHECK constraints to shared
  `batches`/`enrollments`/`fee_rules` from inside the tenant repo,
  binding every tenant to Raj's rules. Shared DDL goes in
  `AcademyManager/supabase/migrations/` at `--scope shared`. Always.
- Raj's session lifecycle CHECK was a bare constraint on a shared table
  until 2026-08-01; it now names the tenant.

## Outstanding

- Nothing Raj-specific is broken today.
- If the platform ref ever changes, the Android and iOS binaries hardcode
  it and must be rebuilt.
