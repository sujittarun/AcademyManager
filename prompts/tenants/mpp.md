# MatchPoint Pride — paste into a chat opened in `MatchPointPride/`

Paste `prompts/EXISTING-TENANT.md` first. Current as of **2026-08-12**.

`mpp` — a separate app for the Pride venue owner.

## State — provisioned, cut over, not yet used

**0 members, 0 enrollments, 0 payments, 0 bookings.** The console shows
₹4,000 MRR against an account with no rows, which looks like a broken
integration and is not one. Read this section before diagnosing it.

MPP was a local-first app: one JSON document in `localStorage` was the
whole backend. **It cut over to Postgres on 2026-08-04.** Its telemetry
shows the changeover precisely — 123 action events (`attendance_marked`,
`student_added`, `payment_recorded` …) between 07-29 and **08-04 17:14**,
and from then on nothing but `page_view` and `client_error`. Those action
events came from the localStorage era. Since the cutover nobody has
entered production data.

So: **empty because unused, not because writes fail.** Verified
2026-08-12 by signing in as `staff@matchpointpride.com` and exercising
the real path — reads its centre, creates a member, reads it back
through RLS — in a transaction that was rolled back.

This makes MPP the safest tenant to build in, and the one where "it
works" proves the least.

### Do not conclude it writes nothing

A grep for `from("members")` finds nothing in this repo and is
misleading. `cloud.ts` goes through RPC helpers, and it uses the right
ones: `record_fee_payment`, `void_payment`, `discontinue_member`,
`set_collection_account`, `log_manual_reminder`, `resolve_fee`. All six
exist, are `SECURITY DEFINER`, and are executable by `authenticated`.
Money goes through `record_fee_payment` as the house rule requires.

`src/lib/vault.ts` is the PIN/session vault — the encrypted refresh
token — **not** the data store. The store is `src/lib/store.tsx`, and it
persists nothing locally; its own header records that the old comment
claiming localStorage was the backend was left standing after the
cutover, "worse than no comment: it is the first thing the next reader
trusts."

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

- **Ask the owner whether real students existed in localStorage before
  04 Aug.** `store.tsx` removes the old keys on load, and nothing was
  migrated into Postgres — the platform has zero rows. If those 8
  `student_added` events were real families rather than trials, that data
  exists only in whatever browser profile he used, until it is cleared.
- The 33 `client_error` events are all `useStore must be used inside
  <StoreProvider>` from 08-04, i.e. from the cutover itself. Worth
  confirming they no longer reproduce before the venue goes live.
- Nothing else MPP-specific is broken. The repo hardcodes the platform
  ref, so a ref change means a rebuild.
