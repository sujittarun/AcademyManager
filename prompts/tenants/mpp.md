# MatchPoint Pride — paste into a chat opened in `MatchPointPride/`

Paste `prompts/EXISTING-TENANT.md` first. Current as of **2026-08-12**.

`mpp` — a separate app for the Pride venue owner.

## State — provisioned, cut over, not yet used

**0 members, 0 enrollments, 0 payments, 0 bookings.** The console shows
₹4,000 MRR against an account with no rows, which looks like a broken
integration and is not one. Read this section before diagnosing it.

**The rows were deleted on purpose.** Commit `0588583`, *"Empty mpp for
handover"* (2026-08-04 17:45 UTC), cleared the demo data the app had
accumulated: 63 students, 66 enrolments, 361 payments, 33 expenses, 5
staff, 150 attendance rows, 7 batches, 7 fee rules, 238 timeline
entries, 9 reminder events, 16 WhatsApp flow events. The backup was
taken in the same transaction as the deletion and asserted to contain
mpp rows before anything was removed, with `member_timeline` and
`wa_flow_events` snapshotted by hand because `backup.take_snapshot()`
does not cover them.

So those 63 students were in **Postgres**, not in a browser — MPP has
been writing to the platform since well before the handover. Its 123
action events (`attendance_marked`, `student_added`, `payment_recorded`
…) run 07-29 to **08-04 17:14 UTC** and stop there because the venue was
handed over, not because anything broke. Since then: `page_view` only.

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

- **The `useStore` crash is unresolved, not fixed.** All 33
  `client_error` events say `useStore must be used inside
  <StoreProvider>`, on `#/app` and `#/batches`, at 08-04 17:51 and 17:56
  UTC — i.e. **6 to 11 minutes after the handover wipe at 17:45**. The
  likely cause is the app rendering a tenant that had just become empty,
  with `useStore` being what the global error handler reported rather
  than the root cause.

  It has not recurred in eight days, but that is weak evidence: mpp has
  logged only five events since, all `page_view`, and nobody has reached
  `#/app` — the route redirects to `#/` without an enrolled PIN.

  Nothing was repaired. `src/main.tsx` has not been touched since
  2026-07-29, before the crash, and its wiring is correct both then and
  now: `ErrorBoundary` outside `StoreProvider` outside `App`, and the
  boundary never calls `useStore`, so the fallback cannot be the thrower.
  `StoreProvider` has a single return and always wraps its children, so
  it can only fail to provide by throwing during its own render.

  **To close this, enrol on a device and open `#/app` and `#/batches`
  against the now-empty tenant.** If it reproduces, the real error is
  being masked — capture it before the global handler rewrites it.
- Nothing else MPP-specific is broken. The repo hardcodes the platform
  ref, so a ref change means a rebuild.
