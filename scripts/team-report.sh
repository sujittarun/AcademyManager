#!/usr/bin/env bash
# ============================================================
# The technical manager's morning report.
#
#   scripts/team-report.sh            last 7 days
#   scripts/team-report.sh 14         last 14 days
#
# Two halves, because the risk lives in both:
#
#   TEAMS   — what each tenant repo shipped, and whether any of it
#             reached across the shared boundary (shared table, shared
#             function, trigger, another tenant's id).
#   PLATFORM— what the database says happened, regardless of which chat
#             window did it: schema drift outside the runner, rows
#             pointing across tenants, the RLS/anon audits.
#
# The repo half is a shape check on git history; the platform half is
# the behaviour check. Trust the second one.
# ============================================================
set -uo pipefail

DAYS="${1:-7}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$HERE/../.." && pwd)"
SQLPY="$HERE/_sql.py"

b()  { printf '\033[1m%s\033[0m\n' "$*"; }
dim(){ printf '\033[2m%s\033[0m\n' "$*"; }
red(){ printf '\033[31m%s\033[0m\n' "$*"; }
grn(){ printf '\033[32m%s\033[0m\n' "$*"; }

SHARED_TABLES='tenants|subscriptions|members|bookings|payments|expenses|attendance|events|applications|reminders_log|sync_jobs|sync_log|integrations|platform_settings|enrollments|fee_rules|batches|centres|sports|coaches|member_timeline|reminder_events|payouts|payout_rules|schema_migrations|ddl_log'
TENANT_IDS='leo|machaxi|matchpoint|mpp|raj|genalpha'

echo
b "════ TEAM ACTIVITY · last $DAYS days ════"
echo

for dir in "$BASE"/*/; do
  name="$(basename "$dir")"
  [ -d "$dir/.git" ] || continue
  [ "$name" = "AcademyManager" ] && continue

  commits="$(git -C "$dir" log --since="$DAYS days ago" --format='%h %ad %s' --date=short 2>/dev/null)"
  dirty="$(git -C "$dir" status --short 2>/dev/null | wc -l | tr -d ' ')"

  if [ -z "$commits" ] && [ "$dirty" = "0" ]; then
    dim "  $name — quiet"
    continue
  fi

  b "  $name"
  if [ -n "$commits" ]; then
    printf '%s\n' "$commits" | sed 's/^/      /'
  else
    dim "      no commits"
  fi
  [ "$dirty" != "0" ] && dim "      ($dirty uncommitted file(s))"

  # Did any commit in the window touch shared SQL from a tenant repo?
  sqlfiles="$(git -C "$dir" log --since="$DAYS days ago" --name-only --format='' 2>/dev/null | grep -iE '\.sql$' | sort -u)"
  if [ -n "$sqlfiles" ]; then
    while IFS= read -r f; do
      [ -f "$dir/$f" ] || continue
      hits="$(grep -niE "(alter|drop)[[:space:]]+table[[:space:]]+(if[[:space:]]+exists[[:space:]]+)?(only[[:space:]]+)?(public\.)?($SHARED_TABLES)\b|create([[:space:]]+or[[:space:]]+replace)?[[:space:]]+trigger\b" "$dir/$f" 2>/dev/null | head -3)"
      [ -n "$hits" ] && { red "      ⚠ shared-object DDL in $f"; printf '%s\n' "$hits" | sed 's/^/          /'; }
    done <<< "$sqlfiles"
  fi

  # A repo writing another tenant's id is the loudest smell there is.
  own="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
  foreign="$(grep -rhoiE "tenant_id[[:space:]]*=[[:space:]]*'($TENANT_IDS)'" "$dir" \
              --include='*.sql' --include='*.js' --include='*.ts' --include='*.kt' 2>/dev/null \
              | grep -oiE "($TENANT_IDS)" | sort -u | tr '\n' ' ')"
  if [ -n "$foreign" ]; then
    n="$(echo "$foreign" | wc -w | tr -d ' ')"
    [ "$n" -gt 1 ] && red "      ⚠ references multiple tenant ids: $foreign"
  fi
  echo
done

echo
b "════ PLATFORM TRUTH · what the database says ════"
echo

run_sql() {
  local sql="$1" tmp
  tmp="$(mktemp)"; printf '%s\n' "$sql" > "$tmp"
  python3 "$SQLPY" "$tmp" 2>/dev/null
  rm -f "$tmp"
}

out="$(run_sql "select
  (select count(*) from schema_drift($DAYS))                                as drift,
  (select count(*) from schema_drift($DAYS) where via = 'BYPASSED THE RUNNER') as bypassed,
  (select count(*) from cross_tenant_integrity())                           as cross_tenant,
  (select count(*) from rls_audit())                                        as rls,
  (select count(*) from rpc_audit())                                        as rpc,
  (select count(*) from anon_probe() where verdict <> 'ok')                 as probe,
  (select count(*) from schema_migrations where applied_at >= now() - make_interval(days => $DAYS)) as migrations;")"

py() { python3 -c "import sys,json;d=json.load(sys.stdin)[0];print(d['$1'])" <<< "$out" 2>/dev/null || echo "?"; }

DRIFT="$(py drift)"; BYP="$(py bypassed)"; XT="$(py cross_tenant)"
RLS="$(py rls)"; RPC="$(py rpc)"; PROBE="$(py probe)"; MIG="$(py migrations)"

line() { # label value badness
  if [ "$2" = "0" ]; then grn "  ✓ $1: $2"; else red "  ✗ $1: $2   ← $3"; fi
}
DRIFTNEW="$(run_sql "select count(*) as n from shared_widening_new();" | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['n'])" 2>/dev/null || echo "?")"

line "cross-tenant rows"          "$XT"    "one tenant's row points at another's — investigate now"
line "shared DDL outside runner"  "$BYP"   "someone changed the shared schema without migrate.sh"
line "unsafe anon policies"       "$RLS"   "rls_audit()"
line "anon-callable definers"     "$RPC"   "rpc_audit()"
line "probe failures"             "$PROBE" "anon_probe()"
line "new shared-surface drift"   "$DRIFTNEW" "a tenant-specific column or rule landed in a shared table"
dim  "  · shared-schema changes reviewed-pending: $DRIFT"
dim  "  · migrations applied in window: $MIG"

echo
if [ "$DRIFT" != "0" ] && [ "$DRIFT" != "?" ]; then
  b "  Recent shared-schema changes"
  run_sql "select at, db_user, command, obj_name, via from schema_drift($DAYS) limit 15;" \
    | python3 -c "
import sys, json
try: rows = json.load(sys.stdin)
except Exception: sys.exit()
for r in rows:
    print('      %s  %-14s %-28s %s' % (str(r['at'])[:16], r['command'][:14], r['obj_name'][:28], r['via']))"
  echo
fi

if [ "$XT" != "0" ] && [ "$XT" != "?" ]; then
  b "  Cross-tenant rows"
  run_sql "select child_table, fk_column, parent_table, bad_rows, sample from cross_tenant_integrity();" \
    | python3 -c "
import sys, json
try: rows = json.load(sys.stdin)
except Exception: sys.exit()
for r in rows:
    print('      %s.%s -> %s : %s rows  %s' % (r['child_table'], r['fk_column'], r['parent_table'], r['bad_rows'], r['sample'][:60]))"
  echo
fi

dim "  Reviewed a drift row? "
dim "    update ddl_log set reviewed_at=now(), reviewed_by='<you>' where id=<id>;"
echo
