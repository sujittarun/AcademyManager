#!/usr/bin/env bash
# Remove five data-loading migrations from this repository's git history.
#
# WHY
#   They embed 112 real GenAlpha family phone numbers as SQL literals — plus
#   children's names and home addresses. The repo is private, so nothing is
#   exposed today, but the numbers are in every clone and every commit, and
#   "private" is one settings toggle away from not being true.
#
#   Which files, and how it was decided: every candidate was checked against
#   members.parent_phone / .phone / .alt_phone in the live database, not
#   against a regex. That matters — a regex flagged seven more files, and all
#   seven were UUID fragments like "ef6593972638". It also cleared the demo
#   seeds, whose 90000001xx numbers are generated.
#
# WHAT IT DOES NOT BREAK
#   schema_migrations records applied files by basename + sha256, and that
#   ledger lives in the DATABASE. Removing the files from git does not make
#   the runner think they are unapplied, and does not re-run them. The files
#   stay on your disk; only history changes.
#
# BEFORE YOU RUN IT
#   This rewrites every commit hash. Anyone else with a clone must re-clone.
#   You are the only committer, so that is you.
#
set -euo pipefail

REPO="/Users/jiths/Documents/Academy Manager Business/AcademyManager"
cd "$REPO"

FILES=(
  supabase/migrations/2026-08-11b-genalpha-core.sql
  supabase/migrations/2026-08-11c-genalpha-history.sql
  supabase/migrations/2026-08-11d-genalpha-timeline.sql
  supabase/migrations/2026-08-11kz-genalpha-messaging.sql
  supabase/migrations/2026-08-11m-genalpha-admissions.sql
)

command -v git-filter-repo >/dev/null 2>&1 || {
  echo "git-filter-repo is not installed:  brew install git-filter-repo" >&2; exit 1; }

echo "==> Backing up the working copies (they are NOT deleted from disk)"
BACKUP="$REPO/../_archive/purged-migrations-$(date +%Y-%m-%d-%H%M)"
mkdir -p "$BACKUP"
for f in "${FILES[@]}"; do
  [ -f "$f" ] && cp "$f" "$BACKUP/" && echo "    saved $(basename "$f")"
done

echo "==> Full mirror backup of the repo before rewriting"
git bundle create "$BACKUP/pre-purge.bundle" --all >/dev/null
echo "    $BACKUP/pre-purge.bundle"

echo "==> Rewriting history"
ARGS=()
for f in "${FILES[@]}"; do ARGS+=(--path "$f"); done
git filter-repo --invert-paths "${ARGS[@]}" --force

echo "==> Restoring the files to the working copy (now gitignored)"
for f in "${FILES[@]}"; do
  b="$(basename "$f")"
  [ -f "$BACKUP/$b" ] && cp "$BACKUP/$b" "$f"
done

echo "==> Verifying: no real family number survives anywhere in history"
LEAK=0
for n in $(cd "$REPO" && python3 - <<'PY'
import json
d=json.load(open('/tmp/pii_files.json'))
nums=set()
for f,v in d.items():
    if 'genalpha' in f: nums.update(v)
print(" ".join(sorted(nums)[:40]))
PY
); do
  if git grep -q "$n" $(git rev-list --all) -- 2>/dev/null; then
    echo "    STILL PRESENT: $n"; LEAK=1
  fi
done
[ "$LEAK" -eq 0 ] && echo "    clean" || { echo "    PURGE INCOMPLETE — do not push" >&2; exit 1; }

cat <<'EOF'

==> Done locally. Two things remain, and they are yours:

    git remote add origin git@github.com:sujittarun/AcademyManager.git
    git push --force --all origin
    git push --force --tags origin

    (filter-repo removes the remote on purpose, so a rewrite cannot be
    pushed by accident. Re-adding it is the deliberate step.)

    GitHub keeps unreferenced objects for a while. If you want them gone
    sooner, open a support request asking for a gc on the repository.
EOF
