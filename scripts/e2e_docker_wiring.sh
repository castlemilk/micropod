#!/bin/bash
# scripts/e2e_docker_wiring.sh — `micropod docker install|uninstall|status`
# end to end with the real docker CLI, compose and buildx against a real hvf
# machine in a throwaway root:
#   1. with a context `other` selected, `docker install` creates context
#      `micropod` and leaves `other` current; the machine stays stopped;
#      `--system-socket` prints the sudo line and changes /var/run/docker.sock
#      not at all
#   2. `docker --context micropod run` once the machine runs
#   3. `install --use` selects it; plain `docker run`; a two-service compose
#      project publishing 127.0.0.1:$PORT, fetched with curl; `compose down`
#   4. `docker build` and `docker buildx build --load`, each image run;
#      `--builder remote` adds micropod-buildkit and builds with it
#   5. `DOCKER_HOST=… micropod docker status` reports the override
#   6. `uninstall` selects `other` again and leaves no context, builder or
#      record behind
#   7. the same with `other` deleted first: `default` is selected
# and, afterwards, the files of the user's ~/.docker this run would write if
# DOCKER_CONFIG leaked, ~/.micropod/docker.sock and /var/run/docker.sock are
# unchanged (compared by stat and readlink only).
#
# Usage: scripts/e2e_docker_wiring.sh      (needs `swift build --product micropod`)
#   HVF_PAYLOAD     a directory with micropod-vmm, Image, mp-hvf-init.cpio and
#                   tools/ (a copy of a payload version); or name each one:
#   HVF_VMM HVF_KERNEL HVF_INITRD HVF_TOOLS
#   HVF_DISK_FROM   ext4 disk to clone (same APFS volume as /tmp), or
#   HVF_DISK_IMAGE  OCI image (or `default`) to unpack into a fresh disk (pulls)
#   HVF_DOCKER_PLUGIN_DIR  colon-separated docker CLI plugin directories
#                   (default: the Homebrew, /usr/local, Docker.app and
#                   OrbStack.app plugin directories that exist; never ~/.docker)
#   HVF_E2E_ROOT    machine root (default /tmp/mpdw-$$; under /tmp, marked)
#   HVF_PORT        published port for the compose check (default 20410)
#   HVF_E2E_KEEP=1  keep the root (stopped) for inspection
# Nothing defaults to the rig under ~/.micropod. Exit 0: every check passed;
# 1: a check failed; 2: refused before starting; 77: SKIP (no docker CLI,
# compose or buildx), which is not a pass.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
M="$REPO/.build/debug/micropod"
ROOT_DIR="${HVF_E2E_ROOT:-/tmp/mpdw-$$}"
PAYLOAD="${HVF_PAYLOAD:-}"
VMM="${HVF_VMM:-${PAYLOAD:+$PAYLOAD/micropod-vmm}}"
KERNEL="${HVF_KERNEL:-${PAYLOAD:+$PAYLOAD/Image}}"
INITRD="${HVF_INITRD:-${PAYLOAD:+$PAYLOAD/mp-hvf-init.cpio}}"
TOOLS="${HVF_TOOLS:-${PAYLOAD:+$PAYLOAD/tools}}"
DISK_FROM="${HVF_DISK_FROM:-}"
DISK_IMAGE="${HVF_DISK_IMAGE:-}"
PORT="${HVF_PORT:-20410}"
IMAGE=alpine:3.20
WEB_IMAGE=busybox:1.36 # has httpd; alpine moved it to busybox-extras
MARKER=.micropod-e2e-docker-wiring
PASS=0
FAIL=0

refuse() { echo "e2e_docker_wiring: $*" >&2; exit 2; }
skip() { echo "SKIP: $* (not a pass)"; exit 77; }

case "$ROOT_DIR" in
*/ | *//* | */./* | */. | */../* | */..) refuse "HVF_E2E_ROOT must be a plain path (got '$ROOT_DIR')" ;;
/tmp/?* | /private/tmp/?*) ;;
*) refuse "HVF_E2E_ROOT must be a throwaway directory under /tmp (got '$ROOT_DIR')" ;;
esac
if [ -e "$ROOT_DIR" ] && [ ! -f "$ROOT_DIR/$MARKER" ] && [ -n "$(ls -A "$ROOT_DIR" 2>/dev/null)" ]; then
    refuse "$ROOT_DIR exists and was not made by this script (no $MARKER)"
fi
case "$PORT" in '' | *[!0-9]*) refuse "HVF_PORT must be a number" ;; esac
[ -x "$M" ] || refuse "missing $M (swift build --product micropod)"
for need in "$VMM" "$KERNEL" "$INITRD"; do
    [ -n "$need" ] && [ -f "$need" ] || refuse "set HVF_PAYLOAD (or HVF_VMM, HVF_KERNEL, HVF_INITRD): missing '$need'"
done
[ -n "$TOOLS" ] && [ -f "$TOOLS/runner/start.sh" ] || refuse "set HVF_PAYLOAD or HVF_TOOLS to a tool bundle with runner/start.sh"
if [ -n "$DISK_IMAGE" ]; then
    DISK_ARGS=(--disk-image "$DISK_IMAGE" --disk-size 16g)
elif [ -n "$DISK_FROM" ] && [ -f "$DISK_FROM" ]; then
    DISK_ARGS=(--disk-from "$DISK_FROM")
else
    refuse "set HVF_DISK_FROM to an ext4 disk to clone, or HVF_DISK_IMAGE=default to pull one"
fi
python3 -c "import socket,sys; s=socket.socket(); s.bind(('127.0.0.1', int(sys.argv[1])))" "$PORT" 2>/dev/null ||
    refuse "127.0.0.1:$PORT is in use; pick another HVF_PORT"

DOCKER="${MICROPOD_DOCKER_CLI:-$(command -v docker || true)}"
[ -n "$DOCKER" ] && [ -x "$DOCKER" ] || skip "no docker CLI on PATH"

TMP="$(mktemp -d /tmp/mpdw-tmp.XXXXXX)"
# The docker CLI's own state, isolated from ~/.docker. Plugins come from the
# system plugin directories; one placeholder `auths` entry keeps the CLI from
# defaulting credsStore to the macOS keychain, so pulls are anonymous.
export DOCKER_CONFIG="$TMP/docker"
mkdir -p "$DOCKER_CONFIG"
PLUGIN_DIRS="${HVF_DOCKER_PLUGIN_DIR:-}"
if [ -z "$PLUGIN_DIRS" ]; then
    for dir in /opt/homebrew/lib/docker/cli-plugins /usr/local/lib/docker/cli-plugins \
        /Applications/Docker.app/Contents/Resources/cli-plugins /Applications/OrbStack.app/Contents/MacOS/xbin; do
        [ -d "$dir" ] && PLUGIN_DIRS="${PLUGIN_DIRS:+$PLUGIN_DIRS:}$dir"
    done
fi
python3 - "$DOCKER_CONFIG/config.json" "$PLUGIN_DIRS" <<'PY'
import json, sys
dirs = [d for d in sys.argv[2].split(":") if d]
json.dump({"cliPluginsExtraDirs": dirs, "auths": {"micropod-e2e.invalid": {}}}, open(sys.argv[1], "w"), indent=2)
PY
unset DOCKER_HOST DOCKER_CONTEXT BUILDX_BUILDER DOCKER_API_VERSION BUILDX_CONFIG
"$DOCKER" compose version >/dev/null 2>&1 || { rm -rf "$TMP"; skip "the docker compose plugin is not in '$PLUGIN_DIRS'"; }
"$DOCKER" buildx version >/dev/null 2>&1 || { rm -rf "$TMP"; skip "the docker buildx plugin is not in '$PLUGIN_DIRS'"; }

export MICROPOD_HVF_ROOT="$ROOT_DIR"
export MICROPOD_RUNTIMES_CONFIG="$TMP/runtimes.json"
export MICROPOD_CLI="$M"
export MICROPOD_DOCKER_SOCK="$ROOT_DIR/canonical-docker.sock"
export MICROPOD_LINK_DOCKER_SOCK=0
export MICROPOD_API_SOCK=off
export MICROPOD_DOCKER_CLI="$DOCKER"
export MICROPOD_NO_UPDATE_NOTIFIER=1
unset MICROPOD_DEFAULT_RUNTIME MICROPOD_HVF_AUTOSTART

# What must be unchanged at the end, by metadata and link targets only: every
# file of the user's that this run would write if DOCKER_CONFIG leaked (the
# config with currentContext, the context store, micropod-buildkit's instance,
# its context default and its activity). buildx's `current` and other
# builders' activity are left out: other processes on a shared Mac using the
# user's own contexts rewrite them at any time.
fingerprint() {
    for path in "$HOME/.docker/config.json" "$HOME/.docker/contexts/meta" \
        "$HOME/.docker/buildx/instances/micropod-buildkit" "$HOME/.docker/buildx/defaults/micropod" \
        "$HOME/.docker/buildx/activity/micropod-buildkit" "$HOME/.docker/buildx/activity/micropod"; do
        stat -f '%N %m %z' "$path" 2>/dev/null || echo "$path absent"
    done
    echo "$HOME/.micropod/docker.sock -> $(readlink "$HOME/.micropod/docker.sock" 2>/dev/null || echo none)"
    echo "/var/run/docker.sock -> $(readlink /var/run/docker.sock 2>/dev/null || echo none)"
}
BEFORE="$(fingerprint)"

PROJECT="mpdw$$"
cleanup() {
    set +e
    if [ -S "$ROOT_DIR/run/docker.sock" ]; then
        "$DOCKER" --host "unix://$ROOT_DIR/run/docker.sock" compose -p "$PROJECT" -f "$TMP/compose.yaml" down \
            >/dev/null 2>&1
    fi
    "$M" machine stop >/dev/null 2>&1
    sup=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('supervisorPID') or '')" \
        "$ROOT_DIR/run/state.json" 2>/dev/null)
    if [ -n "$sup" ] && ps -o command= -p "$sup" 2>/dev/null | grep -q "^$M machine serve"; then kill "$sup"; fi
    for pid in $(pgrep -f "^$ROOT_DIR/.*micropod-vmm .*--disk $ROOT_DIR/disk.ext4" 2>/dev/null); do kill "$pid"; done
    if [ "${HVF_E2E_KEEP:-0}" != 1 ] && [ -f "$ROOT_DIR/$MARKER" ] &&
        [ -z "$(pgrep -f "^$ROOT_DIR/.*micropod-vmm .*--disk $ROOT_DIR/disk.ext4" 2>/dev/null)" ]; then
        rm -rf "$ROOT_DIR"
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

check() { # check "label" actual expected
    if [ "$2" == "$3" ]; then
        PASS=$((PASS + 1))
        echo "  ✓ $1"
    else
        FAIL=$((FAIL + 1))
        echo "  ✗ $1 — got '$2', want '$3'"
    fi
}
contains() { # contains "label" haystack needle
    if printf '%s' "$2" | grep -qF -- "$3"; then
        PASS=$((PASS + 1))
        echo "  ✓ $1"
    else
        FAIL=$((FAIL + 1))
        echo "  ✗ $1 — '$3' not in:"
        printf '%s\n' "$2" | sed 's/^/      /'
    fi
}
phase() { "$M" --json machine status | python3 -c 'import sys,json; print(json.load(sys.stdin)["phase"])'; }
record() { python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('$1'))" "$ROOT_DIR/docker-wiring.json" 2>/dev/null || echo absent; }
host_of() { # a missing context prints an empty line and exits 1
    local host
    host="$("$DOCKER" context inspect "$1" --format '{{.Endpoints.docker.Host}}' 2>/dev/null)" || host=""
    host="$(printf '%s' "$host" | tr -d '\n')"
    echo "${host:-absent}"
}
ENDPOINT="unix://$ROOT_DIR/run/docker.sock"

echo "== machine into $ROOT_DIR (docker CLI $("$DOCKER" version --format '{{.Client.Version}}' 2>/dev/null), plugins: $PLUGIN_DIRS)"
mkdir -p "$ROOT_DIR"
touch "$ROOT_DIR/$MARKER"
"$M" machine install --vmm "$VMM" --kernel "$KERNEL" --initrd "$INITRD" --tools "$TOOLS" "${DISK_ARGS[@]}" \
    --cpus 2 --memory-mib 2048 --workspace "" >"$TMP/install.log" 2>&1 || {
    cat "$TMP/install.log"
    refuse "machine install failed"
}
"$DOCKER" context create other --docker "host=unix://$TMP/other.sock" >/dev/null
"$DOCKER" context use other >/dev/null 2>&1

echo "== 1. install without --use (machine stopped)"
out="$("$M" docker install --system-socket 2>"$TMP/err")"
err="$(cat "$TMP/err")"
check "the current context is still other" "$("$DOCKER" context show)" "other"
check "context micropod points at the machine" "$(host_of micropod)" "$ENDPOINT"
contains "install says it created the context" "$out" "docker context micropod -> $ENDPOINT (created)"
contains "install names the unchanged selection" "$out" "current context: other (unchanged;"
contains "the stopped machine is a note" "$err" "note: the machine is stopped: start it with \`micropod machine start\`"
contains "--system-socket prints the sudo line" "$out" "  sudo ln -sfn $ROOT_DIR/run/docker.sock /var/run/docker.sock"
check "install did not start the machine" "$(phase)" "stopped"
check "record: nothing selected" "$(record selectedByMicropod)" "False"
check "a second install changes nothing" "$("$M" docker install 2>/dev/null | head -1)" "docker context micropod -> $ENDPOINT (present)"

echo "== 2. docker --context micropod"
"$M" machine start >/dev/null
check "docker --context micropod run" "$("$DOCKER" --context micropod run --rm "$IMAGE" echo ok)" "ok"
check "plain docker still uses other" "$("$DOCKER" context show)" "other"

echo "== 3. install --use, docker run, compose"
out="$("$M" docker install --use 2>/dev/null)"
contains "install --use says what it replaced" "$out" "current context: micropod (was other; \`micropod docker uninstall\` restores it)"
check "micropod is the current context" "$("$DOCKER" context show)" "micropod"
check "record: previous context" "$(record previousContext)" "other"
"$M" docker install --use >/dev/null 2>&1
check "a repeat keeps the previous context" "$(record previousContext)" "other"
check "docker run" "$("$DOCKER" run --rm "$IMAGE" echo ok)" "ok"
cat >"$TMP/compose.yaml" <<YAML
services:
  web:
    image: $WEB_IMAGE
    command: ["sh", "-c", "mkdir -p /www && echo hello-from-compose > /www/index.html && exec httpd -f -p 80 -h /www"]
    ports: ["127.0.0.1:$PORT:80"]
    depends_on: [worker]
  worker:
    image: $IMAGE
    command: ["sleep", "600"]
YAML
"$DOCKER" compose -p "$PROJECT" -f "$TMP/compose.yaml" up -d >"$TMP/compose.log" 2>&1 || cat "$TMP/compose.log"
check "compose: two services running" \
    "$("$DOCKER" compose -p "$PROJECT" -f "$TMP/compose.yaml" ps --status running --services 2>/dev/null | sort | tr '\n' ' ')" \
    "web worker "
body=""
for _ in $(seq 1 40); do
    body="$(curl -s --max-time 2 "http://127.0.0.1:$PORT/" || true)"
    [ "$body" = hello-from-compose ] && break
    sleep 0.5
done
check "compose: the published port answers" "$body" "hello-from-compose"
"$DOCKER" compose -p "$PROJECT" -f "$TMP/compose.yaml" down >/dev/null 2>&1
check "compose down removed its containers" \
    "$("$DOCKER" ps -a --filter "label=com.docker.compose.project=$PROJECT" --format '{{.Names}}' | wc -l | tr -d ' ')" "0"

echo "== 4. docker build, buildx build --load, the remote builder"
mkdir -p "$TMP/ctx"
printf 'FROM %s\nRUN echo built > /built.txt\nCMD ["cat", "/built.txt"]\n' "$IMAGE" >"$TMP/ctx/Dockerfile"
"$DOCKER" build -q -t mpdw-build:1 "$TMP/ctx" >"$TMP/build.log" 2>&1 || cat "$TMP/build.log"
check "docker build, then run the image" "$("$DOCKER" run --rm mpdw-build:1 2>&1)" "built"
"$DOCKER" buildx build -q --load -t mpdw-buildx:1 "$TMP/ctx" >"$TMP/buildx.log" 2>&1 || cat "$TMP/buildx.log"
check "docker buildx build --load, then run the image" "$("$DOCKER" run --rm mpdw-buildx:1 2>&1)" "built"
out="$("$M" docker install --builder remote 2>/dev/null)"
contains "--builder remote adds micropod-buildkit" "$out" "builder: micropod-buildkit (remote,"
check "record: builder installed" "$(record builderInstalled)" "True"
check "buildx lists micropod-buildkit" \
    "$("$DOCKER" buildx ls --format '{{.Name}}' 2>/dev/null | grep -c '^micropod-buildkit$' || true)" "1"
check "its state is in the temporary DOCKER_CONFIG" \
    "$([ -f "$DOCKER_CONFIG/buildx/instances/micropod-buildkit" ] && echo here || echo elsewhere)" "here"
printf 'FROM %s\nRUN echo remote > /built.txt\nCMD ["cat", "/built.txt"]\n' "$IMAGE" >"$TMP/ctx/Dockerfile"
BUILDX_BUILDER=micropod-buildkit "$DOCKER" --context micropod build -q -t mpdw-remote:1 "$TMP/ctx" \
    >"$TMP/remote.log" 2>&1 || cat "$TMP/remote.log"
check "a build on micropod-buildkit loads into the machine" "$("$DOCKER" run --rm mpdw-remote:1 2>&1)" "remote"

echo "== 5. status and a shell override"
status_err="$(DOCKER_HOST=unix:///nonexistent "$M" docker status 2>&1 >/dev/null)"
contains "DOCKER_HOST is reported" "$status_err" \
    "note: DOCKER_HOST=unix:///nonexistent is set in this shell: docker ignores the selected context while it is set (unset DOCKER_HOST)"
check "status --json: selected, running" \
    "$("$M" --json docker status | python3 -c 'import sys,json; s=json.load(sys.stdin); print(s["selected"], s["machinePhase"], s["remoteBuilder"], s["context"]["state"])')" \
    "True running ok ok"

echo "== 6. uninstall"
out="$("$M" docker uninstall 2>/dev/null)"
contains "uninstall restores other" "$out" "current context: other (restored)"
check "the current context is other again" "$("$DOCKER" context show)" "other"
check "no micropod context" "$(host_of micropod)" "absent"
check "no micropod-buildkit builder" "$("$DOCKER" buildx ls --format '{{.Name}}' 2>/dev/null | grep -c '^micropod-buildkit$' || true)" "0"
check "no record" "$([ -e "$ROOT_DIR/docker-wiring.json" ] && echo present || echo absent)" "absent"

echo "== 7. uninstall after the previous context was deleted"
"$M" docker install --use >/dev/null 2>&1
"$DOCKER" context rm other >/dev/null
out="$("$M" docker uninstall 2>/dev/null)"
contains "uninstall says other is gone" "$out" "current context: default (the previous context 'other' no longer exists)"
check "the current context is default" "$("$DOCKER" context show)" "default"
check "no micropod context" "$(host_of micropod)" "absent"

check "the user's ~/.docker, ~/.micropod/docker.sock and /var/run/docker.sock are unchanged" "$(fingerprint)" "$BEFORE"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
