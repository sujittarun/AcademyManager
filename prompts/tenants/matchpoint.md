# MatchPoint — paste into a chat opened in `MatchPoint/`

Paste `prompts/EXISTING-TENANT.md` first. Current as of **2026-08-19**.

`matchpoint` — badminton, with the player-tracking cluster.

## Archived — read this before anything else

`config.archived = true`, set by `0012`, and `operator_portfolio()`
filters on it. **MatchPoint does not appear on the operator console, and
that is correct.** Its absence is not a broken integration; do not
"fix" it, and do not conclude the tenant was deleted.

What is still true: the tenant row exists, 10 members and 1 payment are
in the shared tables, the 11-table player-tracking cluster is intact —
and it was **still logging events on 2026-08-19**, so something is
opening the app. Archived describes the business relationship, not the
data and not the traffic.

If it ever comes back, the flag is the whole switch: clear
`config.archived` and it returns to the console with its history.

## State

10 members, 0 enrollments, 1 payment, 1 booking. Private timetable.
WhatsApp off.

## What matters here

- **The 11-table player-progress cluster is the model to copy** for a
  genuinely new noun: own tables, still `tenant_id`-scoped, still
  `--scope shared`, gated on a `config.modules` flag, with RLS and
  `revoke … from public` in the **first** migration rather than a
  follow-up.
- `player-progress-matchpoint.sql:209` puts a trigger on shared
  `public.members`. It is correctly tenant-guarded, so it is safe — but
  it was written in a tenant repo where nobody reviewing Leo or GenAlpha
  would ever see it. A trigger on a shared table is shared-scope work
  even when the guard makes it safe.

## Outstanding

- The dead operator credential is in this repo's git history too.
- `propagate_block`/`propagate_unblock` cross-tenant write path (see
  `leo.md`) affects MatchPoint's bookings as the *target*.
