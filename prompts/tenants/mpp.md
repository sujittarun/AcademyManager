# MatchPoint Pride — paste into a chat opened in `MatchPointPride/`

Paste `prompts/EXISTING-TENANT.md` first. Current as of **2026-08-12**.

`mpp` — a separate app for the Pride venue owner.

## State

**Empty: 0 members, 0 enrollments, 0 payments, 0 bookings.** Nothing here
is live yet, so this is the safest tenant to build in — and the one where
"it works" proves the least.

## What matters here

- **MPP is React + Vite. That is a deliberate exception, not the new
  default.** New tenants start from the closest vanilla-JS tenant
  (Leo → Machaxi → MatchPoint are the same app renamed). Adopt React for
  a tenant only when someone has decided to carry two stacks.
- Because it is the newest build, MPP is usually the first place a
  platform change is noticed. Its telemetry folds `plat` and `session_id`
  into every event, which the operator console reads.
- A `staff@matchpointpride.com` account existed on GenAlpha's old
  Supabase project — cross-tenant auth contamination. That project is
  deleted; the legitimate `mpp` account lives on the platform.

## Outstanding

- Nothing MPP-specific is broken. The repo hardcodes the platform ref, so
  a ref change means a rebuild.
