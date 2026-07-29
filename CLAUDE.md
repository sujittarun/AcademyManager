# Academy Manager — the platform repo

The owner's console **and** the home of everything shared. This is not a
tenant; it is the thing every tenant runs on.

## THE HOUSE RULE (platform-wide — do not violate)

> **Anything that computes money lives in Postgres.** The fee chain, the
> renewal roll-forward and the payout split are SQL functions called by
> every client. No client does that arithmetic itself.
>
> **If you add a money rule, add it to the database — never to a client.**

Full platform rules: `AcademyManager/PLATFORM.md` (inherited automatically
when this folder sits under *Academy Manager Business*).

---

## What lives here

```
supabase/schema.sql          the frozen, append-only base schema
supabase/migrations/         new shared work, numbered, one file per change
scripts/migrate.sh           the ONE migration runner (ledger-checked)
scripts/_sql.py              Management API call; fails on HTTP status
index.html                   the operator console
```

## Applying a migration

```bash
scripts/migrate.sh --dry-run --scope shared supabase/migrations/00NN-thing.sql
scripts/migrate.sh          --scope shared supabase/migrations/00NN-thing.sql
```

`--scope` is mandatory: `shared` if it touches tables every tenant uses,
otherwise the `tenant_id`. Applying a tenant's file from here is fine —
that is why the runner lives in one place — but the scope must say so.

`schema_migrations` refuses an already-applied filename, and refuses
louder if its sha256 changed. **Never rename an applied .sql file.**

## What this console deliberately does NOT show

Members, phone numbers, schedules, individual payments. Account-level
only: MRR, GMV, adoption, growth signals. Operational data stays in each
tenant's own app. Keep it that way — it is what makes the console safe to
open in front of anyone.

## Observability

`platform_health()` for the console, `cron_health_check()` hourly (cron
job `reconcile-check`) writing warnings to `sync_log` with
`tenant_id='platform'`. `rls_audit()` must stay empty.
