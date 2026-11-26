#!/bin/sh
# Run a job against an immutable host checkout with a private Git directory.
set -eu

fail() {
    echo "$*" >&2
    exit 1
}

if [ "$#" -lt 6 ] || [ "$1" != --immutable ] || [ "$5" != -- ]; then
    fail "Usage: pinned-checkout-job.sh --immutable WORKTREE BUNDLE COMMIT -- COMMAND [ARG ...]"
fi
worktree=$(CDPATH='' cd -- "$2" && pwd -P)
bundle=$3
commit=$4
shift 5

case "$bundle" in
    /*) [ -f "$bundle" ] || fail "Git bundle is missing" ;;
    *) fail "Use an absolute path to the Git bundle" ;;
esac
case "$commit" in
    *[!0-9a-f]*) fail "Provide the full lowercase commit ID" ;;
esac
case ${#commit} in
    40) object_format=sha1 ;;
    64) object_format=sha256 ;;
    *) fail "Provide the full lowercase commit ID" ;;
esac

cd "$worktree"
mount_options=$(findmnt -n -o VFS-OPTIONS -T "$worktree")
case ",$mount_options," in
    *,ro,*) ;;
    *) fail "Mount the immutable worktree read-only" ;;
esac
metadata=$worktree/.git
[ -d "$metadata" ] && [ ! -L "$metadata" ] || fail "Mount a private filesystem at $metadata"
worktree_device=$(stat -c %d -- "$worktree")
metadata_device=$(stat -c %d -- "$metadata")
[ "$worktree_device" != "$metadata_device" ] || fail "Mount a private filesystem at $metadata"
[ "$(stat -c %u -- "$metadata")" = "$(id -u)" ] || fail "The job user must own $metadata"
metadata_contents=$(ls -A -- "$metadata")
[ -z "$metadata_contents" ] || fail "The private Git directory must start empty"
mkdir -- "$metadata/micropod-init" || fail "Another process already claimed the private Git directory"

(
    # Scope initialization to the mounted Git directory and the supplied bundle.
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
    unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH
    unset GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
    export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_OPTIONAL_LOCKS=1
    umask 077

    git init --quiet --template= --object-format="$object_format" .
    git bundle unbundle "$bundle" >/dev/null
    [ "$(git cat-file -t "$commit")" = commit ] || fail "The bundle must contain the supplied commit"
    git update-ref --no-deref HEAD "$commit"
    git read-tree HEAD
    if git ls-files --stage | grep -q '^160000 '; then
        fail "The pinned checkout must use a standalone repository without submodules"
    fi
    # Stock Git checks the live files and records stat data for the clean entries.
    tracked_status=$(git status --porcelain=v1 --untracked-files=no)
    [ -z "$tracked_status" ] || fail "The mounted tracked files differ from the pinned commit"
)

exec "$@"
