# Leo Tennis — paste into a chat opened in `LeoTennis/`

Paste `prompts/EXISTING-TENANT.md` first. Current as of **2026-08-12**.

`leo` — a **venue**, not a coaching academy: members and court bookings.

## State

15 members, **0 enrollments**, 16 payments, 231 bookings.

## The two things to know before touching anything

1. **Leo is `BLIND` to the shared attendance functions, and that is
   correct.** `shared_fn_coverage()` reports 23 attendance rows the
   shared functions cannot see. `attendance_roster/_history/_dashboard`
   read `sessions` + `attendance_records`, whose columns are all NOT
   NULL, so they require batch → session → enrolment. Leo has **zero
   enrolments** — its rows are `attendance` with `kind='member'`, meaning
   *a member visited the venue* (footfall), which is a different fact,
   not a broken copy of class attendance. Do not merge the models to
   "fix" the canary.

2. **`modules.booking` is `false` while Leo has 231 bookings.** Worth
   resolving deliberately: either the flag is wrong, or CourtSync is
   being used without the module being declared. Do not flip it casually
   — the flag gates operator-console alerting.

## Outstanding

- **A dead operator credential is still in this repo's git history**, and
  the same string is in CourtSync (public) and MatchPoint. It is a
  working password for Leo's staff account.
- `propagate_block` / `propagate_unblock` derive `tenant_id` from a
  booking id **with no caller check**, so Leo staff can enqueue channel
  sync against another tenant's bookings.
- Leo and Machaxi's `cloud.js`/`core.js` are forks of the same engine;
  every security fix has to be hand-applied to each.
- Never prefill a password in a client file. `Raj Sports/login.html` did
  exactly this once; it was removed **and rotated**, because a value in a
  public static site stays in git history.
