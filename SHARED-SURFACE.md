# The shared surface — what one team's change can reach

Generated from the 2026-08-01 team review. This is the inventory the
platform did not have: **which shared objects were created or altered
from a tenant repo, and therefore which teams can affect each other.**

The point is not blame. Every entry here was written by someone solving
a real problem for their client, and most are tenant-guarded and safe in
practice. The point is *visibility*: before this file existed, a
reviewer of the Leo repo had no way to learn that a MatchPoint file put
a trigger on `members`, or that a Raj file owns the money write path.

Keep it current when shared DDL lands. `scripts/team-report.sh` and
`schema_drift()` will tell you when it happens.

---

## Objects owned by the platform, altered from tenant repos

| Shared object | Reached from | What was done | Status |
|---|---|---|---|
| `members` (table) | MatchPoint | `add column venue`, `add column is_demo` | Live. Additive, harmless, but `is_demo` semantics now exist for every tenant |
| `members` (trigger) | MatchPoint | `initialize_member_progress()` fires on every tenant's member insert | **Hardened by 0040** — was able to abort member creation platform-wide; now exception-guarded |
| `members`, `payments`, `applications` | Raj | ~30 added columns (parent_name, alt_phone, …) | Live. Additive |
| `sessions` | Raj | six columns; `sessions_status_check` restricts **every** tenant to `held\|cancelled` | Live. A constraint on a shared table is a rule for all six academies |
| `batches`, `enrollments`, `fee_rules`, `payout_rules` | Raj | check constraints + partial unique indexes | Live. Same caveat |
| DELETE policies on `sports`, `centres`, `batches`, `coaches`, `fee_rules`, `payout_rules` | Raj | dropped and recreated platform-wide | Live. Predicate is the standard staff/operator pattern, so behaviour matches |
| `members` DELETE policy | Leo (`lockdown.sql`) | `members_staff_d` grants DELETE to every tenant's staff | Live. Intended, but authored in a tenant repo |
| `bookings`, `integrations` (triggers) | Raj | module guards, config-gated | Live. Safe |

## Shared FUNCTIONS defined from tenant repos

These are the ones every client calls. A change here reaches the web
apps, the Android app and the reminder engine at once.

| Function | Defined in | Note |
|---|---|---|
| `record_fee_payment`, `apply_payment_coverage`, `confirm_payment`, `void_payment`, `enrollment_payment_summary` | Raj (`migration-raj-8`) | The money write path. `rpc_audit()` is clean today, so grants are correct |
| `reminder_queue` | Raj (`migration-raj-5`) | Was briefly anon-callable; closed by platform `0017` |
| `mark_attendance`, `attendance_roster` | Raj (`migration-raj-7`, `0039`) | Correctly guarded; placement was the issue |
| `record_skill_assessment`, `promote_player`, `record_development_review` | MatchPoint | `assert_staff` first line; grants verified clean |

## Rules that follow from this table

1. **Shared DDL is `--scope shared`, always** — the runner now refuses
   otherwise (`migrate.sh`).
2. **A feature trigger on a shared table must be exception-guarded.** It
   may fail its own feature; it may never fail its host transaction.
   0040 made this true for the one that existed.
3. **A constraint on a shared table is a platform decision.** Raj's
   `sessions_status_check` binds Leo. If a tenant needs a rule, prefer
   a tenant-filtered partial constraint (`... where tenant_id = 'raj'`).
4. **Adding a column is fine. Changing or dropping one is not** — not
   without checking who reads it (`SELECT` in the other five repos, and
   the Android app, which cannot be force-updated).

## What is watched automatically

| | |
|---|---|
| `schema_drift(days)` | every DDL statement, and whether it came through `migrate.sh` |
| `cross_tenant_integrity()` | rows whose parent belongs to another tenant |
| `rls_audit()`, `rpc_audit()`, `policy_fn_audit()`, `anon_probe()` | access shape and behaviour |
| `scripts/team-report.sh` | all of the above, plus what each repo shipped |
