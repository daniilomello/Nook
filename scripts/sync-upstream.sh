#!/usr/bin/env bash
# Brings the original Nook's new work into the fork.
#
#   ./scripts/sync-upstream.sh           fetch and merge upstream/develop into the current branch
#   ./scripts/sync-upstream.sh --check   only show how far behind the fork is
#
# The fork's own changes live in new files where possible, so most merges are clean. The files
# that do differ from upstream are listed in docs/fork/PLAN.md.
set -euo pipefail
cd "$(dirname "$0")/.."

git remote get-url upstream >/dev/null 2>&1 \
  || git remote add upstream https://github.com/nook-browser/Nook.git
git fetch --quiet upstream develop

BEHIND="$(git rev-list --count HEAD..upstream/develop)"
echo "Upstream has $BEHIND new commit(s)."
[[ "${1:-}" == "--check" || "$BEHIND" -eq 0 ]] && exit 0

if [[ -n "$(git status --porcelain)" ]]; then
  echo "✗ Commit or stash your changes first." >&2
  exit 1
fi
git merge --no-edit upstream/develop
echo "✓ Merged. Rebuild with ./scripts/build.sh --install"
