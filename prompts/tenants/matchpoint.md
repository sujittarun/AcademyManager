# MatchPoint — paste into a chat opened in `MatchPoint/`

Paste `prompts/EXISTING-TENANT.md` first. Current as of **2026-08-12**.

`matchpoint` — badminton, with the player-tracking cluster.

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
