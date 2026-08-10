#!/usr/bin/env bash
# ============================================================
# Send ONE WhatsApp reminder, to one enrolment, and put the
# tenant's config back exactly as it was.
#
#   scripts/send-one-reminder.sh <tenant> <enrollment_id>
#
# WHY THIS EXISTS
#
# The edge function derives dry-vs-live from the tenant's own config
# (`whatsapp.enabled`, `.mode`, `.dryRun`), and there is no per-call
# override — deliberately, because "send for real just this once" is
# exactly the flag that gets left on. The only override that does exist
# is `/run?force=1`, and that sweeps the WHOLE queue: on mpp today that
# is eleven real parents.
#
# So a single test send needs the tenant flipped live for the couple of
# seconds the send takes. This does that, and restores the previous
# config from a `trap ... EXIT` so it goes back even if the send fails,
# the network drops, or someone hits Ctrl-C.
#
# It captures the ORIGINAL values first and restores those, rather than
# assuming they were off — a tenant that was legitimately live stays
# live afterwards.
#
# SAFETY
#
# Check before running that no cron sweeps this tenant. Today both
# WhatsApp cron jobs target `raj`, so flipping `mpp` cannot be picked up
# by a schedule. If that ever changes, a sweep firing inside the window
# would message that tenant's entire queue.
# ============================================================
set -euo pipefail

TENANT="${1:?usage: send-one-reminder.sh <tenant> <enrollment_id>}"
ENROLMENT="${2:?usage: send-one-reminder.sh <tenant> <enrollment_id>}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQLPY="$HERE/_sql.py"
FN="https://ugsklcipzyiogxynshnh.supabase.co/functions/v1/whatsapp-reminder"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

sql() { printf '%s' "$1" > "$TMP/q.sql"; python3 "$SQLPY" "$TMP/q.sql"; }

# ---- the shared secret, never printed ----
SECRET=$(sql "select json_build_object('s',(select decrypted_secret from vault.decrypted_secrets where name='am_fn_secret')) as out;" \
  | python3 -c "import sys,json;print(json.loads(sys.stdin.read())[0]['out']['s'] or '')")
[ -n "$SECRET" ] || { echo "could not read am_fn_secret" >&2; exit 1; }

# ---- remember exactly what the config was ----
ORIG=$(sql "select json_build_object('w',(select config->'whatsapp' from tenants where id='$TENANT')) as out;" \
  | python3 -c "
import sys,json
w=json.loads(sys.stdin.read())[0]['out']['w'] or {}
print(json.dumps({'enabled':w.get('enabled',False),'mode':w.get('mode','manual'),'dryRun':w.get('dryRun',True)}))")
echo "→ $TENANT was: $ORIG"

restore() {
  python3 - "$TENANT" "$ORIG" > "$TMP/restore.sql" <<'PY'
import sys, json
tenant, orig = sys.argv[1], json.loads(sys.argv[2])
print(f"""update tenants set config = jsonb_set(jsonb_set(jsonb_set(
    config, '{{whatsapp,enabled}}', '{json.dumps(orig['enabled'])}'::jsonb),
           '{{whatsapp,dryRun}}',  '{json.dumps(orig['dryRun'])}'::jsonb),
           '{{whatsapp,mode}}',    '{json.dumps(orig['mode'])}'::jsonb)
where id='{tenant}';
select json_build_object('restored',(select config->'whatsapp' from tenants where id='{tenant}')) as out;""")
PY
  python3 "$SQLPY" "$TMP/restore.sql" >/dev/null 2>&1 && echo "→ restored: $ORIG"
}
trap 'restore; rm -rf "$TMP"' EXIT

# ---- live, briefly ----
sql "update tenants set config = jsonb_set(jsonb_set(jsonb_set(
       config, '{whatsapp,enabled}', 'true'::jsonb),
              '{whatsapp,dryRun}',  'false'::jsonb),
              '{whatsapp,mode}',    '\"auto\"'::jsonb)
     where id='$TENANT';
     select json_build_object('ok',true) as out;" >/dev/null
echo "→ live for one send…"

curl -sS -X POST "$FN/send?tenant=$TENANT" \
  -H "x-am-secret: $SECRET" -H "Content-Type: application/json" \
  -d "{\"enrollment_id\":$ENROLMENT}" | python3 -m json.tool

# the EXIT trap restores the config
