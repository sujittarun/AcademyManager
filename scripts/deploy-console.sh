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

cp index.html "$WT/index.html"

cd "$WT"
if git diff --quiet -- index.html; then
  echo "→ gh-pages already matches main. Nothing to deploy."
else
  LINES=$(wc -l < index.html | tr -d ' ')
  git add index.html
  git commit -q -m "deploy console (${LINES} lines)"
  git push -q origin gh-pages
  echo "✓ deployed — https://sujittarun.github.io/AcademyManager/"
  echo "  Pages takes ~30-60s to rebuild."
fi

cd - >/dev/null
git worktree remove "$WT" --force
git worktree prune
