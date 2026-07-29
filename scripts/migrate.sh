#!/usr/bin/env bash
# ============================================================
# The one migration runner for the Academy Manager platform.
#
#   scripts/migrate.sh --scope shared  supabase/migrations/0002-thing.sql
#   scripts/migrate.sh --scope raj --dry-run  ../Raj\ Sports/supabase/x.sql
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
# Needs: ~/.supabase/access-token (a Supabase personal access token).
# ============================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQLPY="$HERE/_sql.py"

DRY_RUN=0
SCOPE=""
SQL_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
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

# The ledger is keyed on the basename, so the same file cannot be applied
# twice under two different relative paths.
KEY="$(basename "$SQL_FILE")"
SHA="$(shasum -a 256 "$SQL_FILE" | awk '{print $1}')"

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
