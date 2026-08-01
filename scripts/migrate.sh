#!/usr/bin/env bash
# ============================================================
# The one migration runner for the Academy Manager platform.
#
#   scripts/migrate.sh --scope shared  supabase/migrations/0002-thing.sql
#   scripts/migrate.sh --scope raj --dry-run  ../Raj\ Sports/supabase/x.sql
#   scripts/migrate.sh --target staging --scope shared  supabase/migrations/x.sql
#
# There is deliberately ONE copy of this script, here, in the platform
# repo. Tenant repos used to carry their own; a stale copy without the
# ledger check is precisely the hazard the ledger exists to prevent.
#
# What it guarantees:
#   1. A file already in schema_migrations is refused.
#   2. A file whose sha256 differs from the recorded one is refused
#      loudly — it changed after being applied.
#   3. The migration AND its ledger row commit in the same transaction,
#      so "applied but unrecorded" cannot happen.
#   4. Failure is decided by HTTP status (see _sql.py), never by
#      grepping the response for the word "error".
#   5. --dry-run runs the real SQL inside a transaction and rolls back.
#
# --target picks the database. `prod` is the default, deliberately: the
# safe choice should be the one you type, not the one you get by
# forgetting. Set STAGING_PROJECT_REF once a staging project exists.
#
#   --target prod      the live platform database (default)
#   --target staging   $STAGING_PROJECT_REF
#   --target <ref>     any project ref, for a one-off
#
# Needs: ~/.supabase/access-token (a Supabase personal access token).
# ============================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQLPY="$HERE/_sql.py"
TXCHECK="$HERE/_txcheck.py"

resolve_target() {
  case "$1" in
    prod)    echo "$PROD_REF" ;;
    staging)
      if [ -z "$STAGING_REF" ]; then
        echo "" ; return
      fi
      echo "$STAGING_REF" ;;
    *)       echo "$1" ;;   # a raw project ref
  esac
}

DRY_RUN=0
SCOPE=""
TARGET="prod"

PROD_REF="ugsklcipzyiogxynshnh"
STAGING_REF="${STAGING_PROJECT_REF:-}"
SQL_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --target)
      TARGET="${2:-}"
      shift 2
      ;;
    --scope)   SCOPE="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *)  SQL_FILE="$1"; shift ;;
  esac
done

if [ -z "$SQL_FILE" ] || [ ! -f "$SQL_FILE" ]; then
  echo "usage: scripts/migrate.sh [--dry-run] --scope <shared|leo|machaxi|raj|matchpoint|mpp> <file.sql>" >&2
  exit 2
fi
if [ -z "$SCOPE" ]; then
  echo "refusing: --scope is required." >&2
  echo "  'shared' = touches tables every tenant uses." >&2
  echo "  otherwise the tenant_id, and it must not alter shared objects." >&2
  exit 2
fi

# ------------------------------------------------------------
# The file must NOT manage its own transaction.
#
# This script wraps it: `begin;`, the file, then either the ledger row
# and `commit;`, or `rollback;` for a dry run. A top-level `commit;` in
# the file ends THIS script's transaction, so:
#
#   * --dry-run applies the migration for real and then prints
#     "✓ dry run clean — Nothing was kept", which is a lie; and
#   * the change lands with no ledger row, because the insert meant to
#     ride in the same transaction never runs inside it.
#
# That is the exact state the ledger exists to make impossible, and it
# is silent — the runner reports success either way. It happened while
# applying 0037, which is why this check is here.
#
# _txcheck.py blanks out comments, string literals and dollar-quoted
# bodies, then asks whether any remaining STATEMENT is transaction
# control. Two things that a grep could not do:
#
#   * `end;` is included. It is a synonym for COMMIT, but it is also how
#     a nested PL/pgSQL block closes — ten times in schema.sql alone —
#     so a line-based check had to skip it and would sail past a real
#     one. After the dollar-quoted bodies are blanked, a surviving
#     `end;` can only be a commit.
#   * matching the WHOLE statement rather than a substring, so
#     `select case when x then 1 else 2 end;` is a select, not a commit.
if ! TX_HITS="$(python3 "$TXCHECK" "$SQL_FILE")"; then
  echo "refusing: $SQL_FILE manages its own transaction." >&2
  printf '%s\n' "$TX_HITS" | sed 's/^/    /' >&2
  echo "  This script already wraps the file in one, and the ledger row" >&2
  echo "  rides inside it. A commit here ends that transaction: --dry-run" >&2
  echo "  would apply for real and still report 'nothing was kept'." >&2
  echo "  Remove them — begin/end inside a do \$\$ … \$\$ block is fine." >&2
  exit 2
fi

# The ledger is keyed on the basename, so the same file cannot be applied
# twice under two different relative paths.
KEY="$(basename "$SQL_FILE")"
SHA="$(shasum -a 256 "$SQL_FILE" | awk '{print $1}')"

# ------------------------------------------------------------
# Naming. Sequence numbers collide when two teams work in parallel —
# 0038 was used twice in one afternoon, by two chat windows that could
# not see each other. Dates cannot collide, and they say when.
# A warning, not a refusal: the numbered files are history and must
# keep applying.
# ------------------------------------------------------------
case "$KEY" in
  [0-9][0-9][0-9][0-9]-*)
    echo "⚠ $KEY uses a sequence number." >&2
    echo "  Parallel sessions have already collided on one. Prefer:" >&2
    echo "    $(date +%Y-%m-%d)-$(echo "$KEY" | sed 's/^[0-9]*-//')" >&2
    ;;
esac

# ------------------------------------------------------------
# Scope gate. A tenant-scoped file may not touch shared objects — that
# is what --scope shared (and a platform-repo review) is for. This is
# the migration-raj-3 incident (check constraints on shared tables from
# a tenant repo) and the player-progress trigger (trigger on shared
# members from a tenant repo), made impossible at the only door.
#
# Static text matching, so it is a shape check: it can be fooled, but
# the DDL sentinel (0037) logs what actually happens in the database
# and flags anything that did not come through here.
# ------------------------------------------------------------
SHARED_TABLES='tenants|subscriptions|members|bookings|payments|expenses|attendance|events|applications|reminders_log|sync_jobs|sync_log|integrations|platform_settings|enrollments|fee_rules|batches|centres|sports|coaches|member_timeline|reminder_events|payouts|payout_rules|schema_migrations|ddl_log|contacts|public_slots'
SHARED_FUNCS='resolve_fee|record_fee_payment|apply_payment_coverage|reminder_queue|void_payment|confirm_payment|mark_attendance|attendance_roster|attendance_history|attendance_dashboard|compute_payouts|tenant_health|platform_health|cron_health_check|cron_anon_probe|cron_ddl_check|rls_audit|rpc_audit|policy_fn_audit|anon_probe|operator_portfolio|request_booking|record_booking|confirm_booking|cancel_booking|block_maintenance|propagate_block|propagate_unblock|process_sync_jobs|sync_ingest|partner_sync|connect_integration|set_integration_secret|submit_application|tenant_exists|tenant_publishes_timetable|is_locked|auth_role|auth_tenant|slot_rate|court_count|reconcile_report|get_channels|events_flowing|platform_errors|set_subscription|assert_staff|assert_staff_or_service|log_ddl|log_ddl_drop'
if [ "$SCOPE" != "shared" ]; then
  VIOLATIONS=""
  V1="$(grep -niE "(alter|drop)[[:space:]]+table[[:space:]]+(if[[:space:]]+exists[[:space:]]+)?(only[[:space:]]+)?(public\.)?($SHARED_TABLES)\b" "$SQL_FILE" || true)"
  V2="$(grep -niE "create([[:space:]]+or[[:space:]]+replace)?[[:space:]]+trigger\b" "$SQL_FILE" || true)"
  V3="$(grep -niE "create[[:space:]]+or[[:space:]]+replace[[:space:]]+function[[:space:]]+(public\.)?($SHARED_FUNCS)[[:space:]]*\(" "$SQL_FILE" || true)"
  V4="$(grep -niE "drop[[:space:]]+function[[:space:]]+(if[[:space:]]+exists[[:space:]]+)?(public\.)?($SHARED_FUNCS)\b" "$SQL_FILE" || true)"
  VIOLATIONS="$(printf '%s\n%s\n%s\n%s' "$V1" "$V2" "$V3" "$V4" | sed '/^$/d')"
  if [ -n "$VIOLATIONS" ]; then
    echo "✗ refusing: --scope $SCOPE, but $KEY touches SHARED objects:" >&2
    printf '%s\n' "$VIOLATIONS" | sed 's/^/    /' >&2
    echo "  Shared DDL belongs in AcademyManager/supabase/migrations with" >&2
    echo "  --scope shared, where every tenant's reviewer can see it." >&2
    echo "  (Triggers count: even tenant-guarded ones live in shared scope" >&2
    echo "  — that is the player-progress-matchpoint lesson.)" >&2
    exit 2
  fi
  # Grants on shared tables are sometimes legitimate from a tenant file
  # (raj's public timetable), but they widen access — say so out loud.
  W1="$(grep -niE "(grant|revoke)[[:space:]].*[[:space:]]on[[:space:]]+(table[[:space:]]+)?(public\.)?($SHARED_TABLES)\b" "$SQL_FILE" || true)"
  if [ -n "$W1" ]; then
    echo "⚠ heads-up: $KEY changes grants on shared tables under tenant scope:" >&2
    printf '%s\n' "$W1" | sed 's/^/    /' >&2
    echo "  Allowed, but exercise the anon paths after applying." >&2
  fi
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say() { printf '%s\n' "$*"; }

# ------------------------------------------------------------
# 1. Ask the ledger about this file.
#    On the very first run the table does not exist yet; that is not an
#    error, it just means nothing can have been applied through it.
# ------------------------------------------------------------
cat > "$TMP/check.sql" <<SQL
select coalesce(
  (select json_agg(json_build_object('sha', sha256, 'at', applied_at))
     from schema_migrations where filename = '$KEY'),
  '[]'::json) as hit
where to_regclass('public.schema_migrations') is not null;
SQL

PROJECT_REF="$(resolve_target "$TARGET")"
if [ -z "$PROJECT_REF" ]; then
  echo "✗ --target staging, but STAGING_PROJECT_REF is not set." >&2
  echo "  Create the staging project, then:" >&2
  echo "    export STAGING_PROJECT_REF=<ref>" >&2
  exit 1
fi
export SUPABASE_PROJECT_REF="$PROJECT_REF"

# Say which database, every time. The migration that took a live tenant
# down was applied by someone who knew perfectly well it was production
# and did it anyway; the ones that follow will be applied by someone
# tired, and they should not have to remember.
if [ "$PROJECT_REF" = "$PROD_REF" ]; then
  say "→ target: PRODUCTION ($PROJECT_REF)"
else
  say "→ target: $TARGET ($PROJECT_REF)"
fi

LEDGER_STATE="new"
if CHECK_OUT="$(python3 "$SQLPY" "$TMP/check.sql" 2>/dev/null)"; then
  case "$CHECK_OUT" in
    *'"sha"'*)
      if printf '%s' "$CHECK_OUT" | grep -q "$SHA"; then
        LEDGER_STATE="same"
      else
        LEDGER_STATE="changed"
      fi
      ;;
  esac
else
  say "!! could not read schema_migrations (first run, or the API is unreachable)."
  say "   Continuing — the insert below is idempotent."
fi

if [ "$DRY_RUN" -eq 0 ]; then
  case "$LEDGER_STATE" in
    same)
      say "✗ $KEY is already applied, unchanged. Refusing."
      say "  If you genuinely need to re-run it, delete its row first — and be"
      say "  certain it does not 'create or replace' something newer."
      exit 1 ;;
    changed)
      say "✗ $KEY is already applied, but the file has CHANGED since."
      say "  recorded sha ≠ $SHA"
      say "  Re-applying an edited migration is how a newer function gets"
      say "  silently reverted. Write a NEW migration instead."
      exit 1 ;;
  esac
fi

# ------------------------------------------------------------
# 2. Build the payload. The ledger row rides inside the same
#    transaction as the change, so the two cannot disagree.
# ------------------------------------------------------------
{
  echo "begin;"
  # Attribution marker for the DDL sentinel (0037): every object this
  # transaction touches is stamped with the file and scope that did it.
  # Transaction-local, so it vanishes at commit/rollback.
  echo "select set_config('app.migration', '$KEY scope=$SCOPE', true);"
  cat "$SQL_FILE"
  echo ""
  if [ "$DRY_RUN" -eq 0 ]; then
    cat <<SQL
insert into schema_migrations (filename, sha256, scope)
values ('$KEY', '$SHA', '$SCOPE')
on conflict (filename) do update
  set sha256 = excluded.sha256, applied_at = now(), scope = excluded.scope;
SQL
    echo "commit;"
  else
    echo "rollback;"
  fi
} > "$TMP/payload.sql"

if [ "$DRY_RUN" -eq 1 ]; then
  say "→ DRY RUN: applying $KEY inside a transaction, then rolling back."
else
  say "→ applying $KEY  (scope: $SCOPE, sha: ${SHA:0:12}…)"
fi

# ------------------------------------------------------------
# 3. Run it. Exit code comes from the HTTP status, not the body text.
# ------------------------------------------------------------
if OUT="$(python3 "$SQLPY" "$TMP/payload.sql")"; then
  [ -n "$OUT" ] && say "   $OUT"
  if [ "$DRY_RUN" -eq 1 ]; then
    say "✓ dry run clean — the SQL executes. Nothing was kept."
  else
    say "✓ applied and recorded in schema_migrations."
  fi
else
  say "✗ FAILED — the transaction rolled back, nothing was applied."
  say "  Nothing was written to schema_migrations either."
  exit 1
fi
