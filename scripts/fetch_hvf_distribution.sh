#!/bin/bash
# Fetch a release operator's pinned runtime from a successful build of this commit.
set -euo pipefail

run_id=${1:?GitHub Actions run ID required}
expected=${2:?payload SHA-256 required}
output=${3:?new distribution directory required}
: "${GITHUB_REPOSITORY:?}" "${GITHUB_SHA:?}"
[[ "$run_id" =~ ^[1-9][0-9]*$ && "$expected" =~ ^[0-9a-f]{64}$ ]] || {
    echo "Expected a numeric Actions run ID and a lowercase SHA-256 digest" >&2
    exit 1
}

gh api "repos/$GITHUB_REPOSITORY/actions/runs/$run_id" |
    jq -e --arg repo "$GITHUB_REPOSITORY" --arg sha "$GITHUB_SHA" '
        .head_repository.full_name == $repo and .head_sha == $sha and
        .status == "completed" and .conclusion == "success" and
        (.event == "push" or .event == "workflow_dispatch")
    ' >/dev/null || { echo "The selected run did not qualify this release commit" >&2; exit 1; }

mkdir "$output"
finished=false
cleanup() {
    if [[ "$finished" == true ]]; then
        rm -rf "$staged"
    else
        # mkdir above reserved a new, exclusively owned destination.
        rm -rf "$output"
    fi
}
trap cleanup EXIT
staged=$(mktemp -d "$output/.download.XXXXXX")
gh run download "$run_id" --repo "$GITHUB_REPOSITORY" --name micropod-hvf-runtime --dir "$staged"
archive="$staged/micropod-hvf-runtime.tgz"
actual=$(/usr/bin/shasum -a 256 "$archive" | awk '{print $1}')
[[ "$actual" == "$expected" ]] || { echo "HVF runtime archive digest mismatch" >&2; exit 1; }
mkdir "$staged/payload"
/usr/bin/tar -xzf "$archive" -C "$staged/payload"
payload="$staged/payload"
bash "$(dirname "$0")/stage_hvf_assets.sh" "$payload" "$payload" "$output" "$output"
finished=true
