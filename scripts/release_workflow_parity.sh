#!/bin/bash
# Whether GitHub will let GITHUB_TOKEN create or update the release at SOURCE.
#
#   scripts/release_workflow_parity.sh SOURCE [BASE]
#
# GitHub's release create/update endpoints refuse (404, or 403 "Resource not
# accessible by integration") a token that cannot modify workflows when the
# release's target commit adds or modifies files under .github/workflows/
# relative to the default branch, and GITHUB_TOKEN can never be granted that.
# This compares conservatively: any difference counts.
#
# Exit 0: SOURCE and BASE (default origin/master, fetched) carry the same
# workflows. Exit 1: they differ (the differing paths are printed). Exit 2:
# the comparison itself failed, which callers treat as a refusal.
set -uo pipefail
source_commit="${1:-}"
base="${2:-origin/master}"
[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || { echo "release_workflow_parity: SOURCE must be a full revision" >&2; exit 2; }
if [ "$base" = origin/master ]; then
    git fetch --quiet origin master || exit 2
fi
git cat-file -e "$source_commit^{commit}" 2>/dev/null || { echo "release_workflow_parity: $source_commit is not available" >&2; exit 2; }
git rev-parse --verify --quiet "$base^{commit}" >/dev/null || { echo "release_workflow_parity: $base is not available" >&2; exit 2; }
changed=$(git diff --name-only "$base" "$source_commit" -- .github/workflows) || exit 2
if [ -n "$changed" ]; then
    printf '%s\n' "$changed"
    exit 1
fi
exit 0
