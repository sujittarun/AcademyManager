#!/usr/bin/env bash
# Run a behaviour test against the live schema inside a transaction that
# is always rolled back. There is no staging database and five other
# tenants live in this one, so this is how a migration gets proven.
#
#   AcademyManager/scripts/run-test.sh <migration.sql> <test.sql>
set -euo pipefail
cd "$(dirname "$0")/../.."
MIG="$1"; TEST="$2"
python3 - "$MIG" "$TEST" <<'PY'
import json, os, subprocess, sys
mig, test = sys.argv[1], sys.argv[2]
sql = "begin;\n" + open(mig).read() + "\n" + open(test).read() + "\nrollback;"
tok = open(os.path.expanduser("~/.supabase/access-token")).read().strip()
print(f"→ {os.path.basename(mig)} + {os.path.basename(test)}, in a transaction that will be rolled back")
r = subprocess.run(["curl","-s","-X","POST",
  "https://api.supabase.com/v1/projects/ugsklcipzyiogxynshnh/database/query",
  "-H", f"Authorization: Bearer {tok}", "-H","Content-Type: application/json",
  "--data-binary", json.dumps({"query": sql})], capture_output=True, text=True)
out = (r.stdout or r.stderr).strip()
try: parsed = json.loads(out)
except Exception: print(out); sys.exit(1)
if isinstance(parsed, dict) and parsed.get("message"):
    print("\n✗ FAILED\n"); print(parsed["message"]); sys.exit(1)
print("\n✓", parsed)
PY
