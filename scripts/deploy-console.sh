#!/usr/bin/env bash
# ============================================================
# Publish the operator console to GitHub Pages.
#
# WHY THIS EXISTS
# Pages serves this repo from the `gh-pages` BRANCH, not from `main`.
# Nothing kept them in step, so editing index.html on main and pushing
# changed nothing that anyone could see — gh-pages sat 465 lines behind
# for an entire feature, and the first sign of it was "I don't see
# anything added in AM".
#
# Committing is not deploying, for this repo. Run this after either.
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."

WT="${TMPDIR:-/tmp}/am-ghp-deploy"

git worktree prune
rm -rf "$WT"
git worktree add -q "$WT" gh-pages

# Every page the console serves. A file missing from this list is a file
# that stays invisible no matter how many times it is committed — which is
# the whole failure this script exists to prevent, so adding a page means
# adding it HERE too.
PAGES=(index.html reset.html)

for f in "${PAGES[@]}"; do
  [ -f "$f" ] || { echo "✗ $f is missing from main"; exit 1; }
  cp "$f" "$WT/$f"
done

cd "$WT"
if git diff --quiet -- "${PAGES[@]}"; then
  echo "→ gh-pages already matches main. Nothing to deploy."
else
  LINES=$(cat "${PAGES[@]}" | wc -l | tr -d ' ')
  git add "${PAGES[@]}"
  git commit -q -m "deploy console (${LINES} lines)"
  git push -q origin gh-pages
  echo "✓ deployed — https://sujittarun.github.io/AcademyManager/"
  echo "  Pages takes ~30-60s to rebuild."
fi

cd - >/dev/null
git worktree remove "$WT" --force
git worktree prune
