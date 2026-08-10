#!/usr/bin/env bash
#
# Nightly off-site backup for every Academy Manager Supabase project.
#
# WHY THIS EXISTS
#   backup.take_snapshot() copies the tenant tables into the SAME database.
#   That covers a migration doing more than intended. It covers nothing at
#   all if the project itself is lost, because the copy goes with it.
#   This writes outside the database, and outside every git repo.
#
# WHAT IT IS NOT
#   Not a substitute for Supabase Pro's daily physical backups. This captures
#   table DATA plus the schema needed to rebuild — it does NOT capture
#   auth.users password hashes, storage objects, or roles. A restore is
#   "recreate the schema, insert the rows, re-provision the logins", not a
#   one-click revert. For 8 MB of data that is entirely workable; know the
#   difference before relying on it.
#
# USAGE
#   ./backup-all.sh [destination-dir]
#   default destination: ../_archive/backups/<date>/<project>/
#
# SCHEDULE (macOS, runs at 02:00 daily):
#   echo "0 2 * * * cd '$PWD' && ./backup-all.sh >> /tmp/am-backup.log 2>&1" | crontab -
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SQL="$HERE/_sql.py"
STAMP="$(date +%Y-%m-%d)"
DEST="${1:-$HERE/../../_archive/backups/$STAMP}"
KEEP_DAYS=30

# project ref : label
PROJECTS=(
  "ugsklcipzyiogxynshnh:platform"
  "hwxhigwaklzedxufwedv:genalpha"
)

fail=0

run_sql() {  # ref, sqlfile -> stdout json
  SUPABASE_PROJECT_REF="$1" python3 "$SQL" "$2" 2>/dev/null
}

for entry in "${PROJECTS[@]}"; do
  REF="${entry%%:*}"; NAME="${entry##*:}"
  OUT="$DEST/$NAME"
  mkdir -p "$OUT"
  echo "── $NAME ($REF)"

  # --- the table list -------------------------------------------------
  cat > /tmp/_bk_tables.sql <<'SQL'
select string_agg(table_name, ' ' order by table_name) t
  from information_schema.tables
 where table_schema='public' and table_type='BASE TABLE';
SQL
  TABLES=$(run_sql "$REF" /tmp/_bk_tables.sql \
    | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['t'] or '')" 2>/dev/null)
  if [ -z "$TABLES" ]; then
    echo "   !! could not list tables — SKIPPING (not treating as success)"
    fail=1; continue
  fi

  # --- data -----------------------------------------------------------
  n_tab=0; n_row=0
  for T in $TABLES; do   # word-split intentionally (bash)
    cat > /tmp/_bk_one.sql <<SQL
select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) as rows from public.$T x;
SQL
    if run_sql "$REF" /tmp/_bk_one.sql \
       | python3 -c "import sys,json; json.dump(json.load(sys.stdin)[0]['rows'], open('$OUT/$T.json','w'))" 2>/dev/null; then
      c=$(python3 -c "import json;print(len(json.load(open('$OUT/$T.json'))))" 2>/dev/null || echo 0)
      n_tab=$((n_tab+1)); n_row=$((n_row+c))
    else
      echo "   !! $T failed"; fail=1
    fi
  done

  # --- structure: rows alone cannot restore a database ------------------
  cat > /tmp/_bk_ddl.sql <<'SQL'
select jsonb_pretty(jsonb_build_object(
 'captured_at', now(),
 'columns',     (select jsonb_agg(jsonb_build_object('t',table_name,'c',column_name,'ty',data_type,'null',is_nullable,'def',column_default) order by table_name, ordinal_position)
                   from information_schema.columns where table_schema='public'),
 'constraints', (select jsonb_agg(jsonb_build_object('t',conrelid::regclass::text,'name',conname,'def',pg_get_constraintdef(oid)) order by conrelid::regclass::text, conname)
                   from pg_constraint where connamespace='public'::regnamespace),
 'indexes',     (select jsonb_agg(jsonb_build_object('t',tablename,'name',indexname,'def',indexdef) order by tablename, indexname)
                   from pg_indexes where schemaname='public'),
 'policies',    (select jsonb_agg(jsonb_build_object('t',tablename,'name',policyname,'roles',roles::text,'cmd',cmd,'using',qual,'check',with_check) order by tablename, policyname)
                   from pg_policies where schemaname='public'),
 'functions',   (select jsonb_agg(jsonb_build_object('name',p.proname,'def',pg_get_functiondef(p.oid)) order by p.proname)
                   from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'),
 'cron',        (select jsonb_agg(jsonb_build_object('name',jobname,'sched',schedule,'active',active) order by jobname) from cron.job),
 'auth_users',  (select jsonb_agg(jsonb_build_object('email',email,'meta',raw_app_meta_data,'created',created_at) order by email) from auth.users)
)) s;
SQL
  # NOTE: auth_users captures EMAIL AND ROLE ONLY — never the password hash.
  # A restore re-provisions logins; it does not resurrect them.
  if run_sql "$REF" /tmp/_bk_ddl.sql \
     | python3 -c "import sys,json; open('$OUT/_schema.json','w').write(json.load(sys.stdin)[0]['s'])" 2>/dev/null; then
    :
  else
    echo "   !! schema capture failed"; fail=1
  fi

  if [ "$n_tab" -eq 0 ]; then
    echo "   !! ZERO tables captured for $NAME — this is a FAILURE, not an empty database"
    fail=1
  fi
  echo "   $n_tab tables, $n_row rows -> $OUT"
done

# --- integrity marker: a backup you cannot verify is a hope, not a backup
find "$DEST" -name '*.json' -type f -exec shasum -a 256 {} \; \
  | sed "s|$DEST/||" | sort -k2 > "$DEST/SHA256SUMS"
NSUM=$(wc -l < "$DEST/SHA256SUMS" | tr -d ' ')
echo "── checksums: $NSUM files"
if [ "$NSUM" -eq 0 ]; then
  echo "── NOTHING WAS WRITTEN — failing loudly rather than reporting a green run"
  fail=1
fi

# --- retention --------------------------------------------------------
BASE="$(dirname "$DEST")"
if [ -d "$BASE" ]; then
  find "$BASE" -maxdepth 1 -type d -name '20*-*-*' -mtime +$KEEP_DAYS -print -exec rm -rf {} + 2>/dev/null \
    | sed 's/^/── pruned /'
fi

if [ "$fail" -ne 0 ]; then
  echo "── COMPLETED WITH ERRORS — do not treat today as backed up"
  exit 1
fi
echo "── ok  $STAMP"
