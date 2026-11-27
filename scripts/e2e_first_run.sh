#!/bin/bash
# scripts/e2e_first_run.sh — a fresh install's first run, on real machines in
# throwaway roots, from a local package (no download):
#   0. each binary pins the install origin before anything else: micropod
#      and MicropodMCP write runtimes.json {"default":"hvf",
#      "defaultOrigin":"fresh-install"} under MICROPOD_INSTALL_ORIGIN=fresh
#      (MicropodAPI is checked in 6; the app and the shim are not run here)
#   1. `micropod runtime ls`: hvf the default, Apple opt-in
#   2. `micropod run` with no machine says to run `micropod setup`; setup
#      from a package with no base disk names --disk-from and --disk-image
#      and writes nothing
#   3. `micropod setup --payload <package> --cache-disk-size 1g`: all five
#      steps, the disk cloned from the package's hvf-base-disk.ext4; then a
#      container runs with no --runtime flag
#   4. a second setup keeps every step; `setup --docker` adds the docker
#      context in a temporary DOCKER_CONFIG and `docker --context micropod`
#      reaches the machine (SKIP when there is no docker CLI)
#   5. MICROPOD_INSTALL_ORIGIN=existing with a new config: Apple stays the
#      default and enabled, as before
#   6. RigService SetupMachine over a throwaway API (its own socket and port)
#      on a second root: ok, the machine running, and the API pinned the
#      origin first
# and, afterwards, ~/.micropod/docker.sock, ~/.micropod/runtimes.json and
# ~/.docker/config.json are unchanged (stat and readlink only).
#
# Usage: scripts/e2e_first_run.sh
#        (needs `swift build --product micropod --product MicropodAPI --product MicropodMCP`)
#   HVF_PAYLOAD     a directory with micropod-vmm, Image (or vmlinux-hvf),
#                   mp-hvf-init.cpio and tools/ (or micropod-oci-tools/), e.g.
#                   a copy of a payload version; or name each one:
#   HVF_VMM HVF_KERNEL HVF_INITRD HVF_TOOLS
#   HVF_DISK_FROM   the ext4 base disk the package ships (a pristine OS disk,
#                   on the same APFS volume as /tmp so it clones)
#   HVF_E2E_ROOT    the throwaway directory (default /tmp/mpfr-$$; marked)
#   HVF_API_PORT    the throwaway API's loopback port (default 20430)
#   HVF_E2E_KEEP=1  keep the roots (stopped) for inspection
# Nothing defaults to the rig under ~/.micropod. Exit 0: every check passed;
# 1: a check failed; 2: refused before starting.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
M="$REPO/.build/debug/micropod"
API="$REPO/.build/debug/MicropodAPI"
MCP="$REPO/.build/debug/MicropodMCP"
BASE="${HVF_E2E_ROOT:-/tmp/mpfr-$$}"
PAYLOAD="${HVF_PAYLOAD:-}"
pick() { for c in "$@"; do [ -e "$c" ] && { echo "$c"; return; }; done; echo "${1:-}"; }
VMM="${HVF_VMM:-${PAYLOAD:+$PAYLOAD/micropod-vmm}}"
KERNEL="${HVF_KERNEL:-${PAYLOAD:+$(pick "$PAYLOAD/Image" "$PAYLOAD/vmlinux-hvf")}}"
INITRD="${HVF_INITRD:-${PAYLOAD:+$PAYLOAD/mp-hvf-init.cpio}}"
TOOLS="${HVF_TOOLS:-${PAYLOAD:+$(pick "$PAYLOAD/tools" "$PAYLOAD/micropod-oci-tools")}}"
DISK_FROM="${HVF_DISK_FROM:-}"
API_PORT="${HVF_API_PORT:-20430}"
IMAGE=alpine:3.20
MARKER=.micropod-e2e-first-run
PASS=0
FAIL=0
SKIP=0

refuse() { echo "e2e_first_run: $*" >&2; exit 2; }

case "$BASE" in
*/ | *//* | */./* | */. | */../* | */..) refuse "HVF_E2E_ROOT must be a plain path (got '$BASE')" ;;
/tmp/?* | /private/tmp/?*) ;;
*) refuse "HVF_E2E_ROOT must be a throwaway directory under /tmp (got '$BASE')" ;;
esac
if [ -e "$BASE" ] && [ ! -f "$BASE/$MARKER" ] && [ -n "$(ls -A "$BASE" 2>/dev/null)" ]; then
    refuse "$BASE exists and was not made by this script (no $MARKER)"
fi
case "$API_PORT" in '' | *[!0-9]*) refuse "HVF_API_PORT must be a number" ;; esac
for bin in "$M" "$API" "$MCP"; do [ -x "$bin" ] || refuse "missing $bin (swift build --product $(basename "$bin"))"; done
for need in "$VMM" "$KERNEL" "$INITRD"; do
    [ -n "$need" ] && [ -f "$need" ] || refuse "set HVF_PAYLOAD (or HVF_VMM, HVF_KERNEL, HVF_INITRD): missing '$need'"
done
[ -n "$TOOLS" ] && [ -f "$TOOLS/runner/start.sh" ] || refuse "set HVF_PAYLOAD or HVF_TOOLS to a tool bundle with runner/start.sh"
[ -n "$DISK_FROM" ] && [ -f "$DISK_FROM" ] || refuse "set HVF_DISK_FROM to the ext4 base disk the package ships"
case "$(cd "$(dirname "$DISK_FROM")" && pwd -P)/" in "$HOME/.micropod/"*) refuse "HVF_DISK_FROM must not be under ~/.micropod" ;; esac
python3 -c "import socket,sys; s=socket.socket(); s.bind(('127.0.0.1', int(sys.argv[1])))" "$API_PORT" 2>/dev/null ||
    refuse "127.0.0.1:$API_PORT is in use; pick another HVF_API_PORT"
DOCKER="$(command -v docker || true)"

mkdir -p "$BASE"
touch "$BASE/$MARKER"
TMP="$BASE/tmp"
mkdir -p "$TMP"
ROOT="$BASE/a"   # the CLI's machine
ROOT2="$BASE/b"  # the API's machine
ROOT3="$BASE/c"  # a setup with no base disk
PKG="$BASE/pkg"
export DOCKER_CONFIG="$TMP/docker"
mkdir -p "$DOCKER_CONFIG"
echo '{"auths": {"micropod-e2e.invalid": {}}}' >"$DOCKER_CONFIG/config.json"
export MICROPOD_HVF_ROOT="$ROOT"
export MICROPOD_RUNTIMES_CONFIG="$TMP/runtimes.json"
export MICROPOD_INSTALL_ORIGIN=fresh
export MICROPOD_CLI="$M"
export MICROPOD_DOCKER_SOCK="$BASE/canonical-docker.sock"
export MICROPOD_LINK_DOCKER_SOCK=0
export MICROPOD_API_SOCK=off
# Nothing listens here: a `micropod status` never reaches the user's API.
export MICROPOD_API_PORT=$((API_PORT + 9))
export MICROPOD_CI_HOME="$BASE/ci"
export MICROPOD_APP_CONTROL_SOCKET="$BASE/app-control.sock"
export MICROPOD_VOLUME_POLICY="$BASE/volume-policy.json"
export MICROPOD_LAUNCHCTL=/usr/bin/false
export MICROPOD_LAUNCH_AGENTS_DIR="$TMP/LaunchAgents"
export MICROPOD_NO_UPDATE_NOTIFIER=1
export MICROPOD_HVF_AUTOSTART=0
unset MICROPOD_DEFAULT_RUNTIME DOCKER_CONTEXT MICROPOD_LEGACY_APPLE MICROPOD_RUNTIME
# The docker runtime engine's probe (`runtime ls`) must not reach a Docker
# Desktop on this Mac: point it at nothing. The docker CLI below runs
# without it.
export DOCKER_HOST="unix://$BASE/no-docker.sock"

# What must be unchanged at the end, by metadata and link targets only.
fingerprint() {
    echo "$HOME/.micropod/docker.sock -> $(readlink "$HOME/.micropod/docker.sock" 2>/dev/null || echo none)"
    stat -f '%N %m %z' "$HOME/.micropod/runtimes.json" 2>/dev/null || echo "runtimes.json absent"
    stat -f '%N %m %z' "$HOME/.docker/config.json" 2>/dev/null || echo "config.json absent"
}
BEFORE="$(fingerprint)"

API_PID=""
MCP_PID=""
vmm_pids() { pgrep -f "^$BASE/.*micropod-vmm " 2>/dev/null || true; }
cleanup() {
    set +e
    [ -n "$API_PID" ] && kill "$API_PID" 2>/dev/null
    [ -n "$MCP_PID" ] && kill "$MCP_PID" 2>/dev/null
    for root in "$ROOT" "$ROOT2"; do MICROPOD_HVF_ROOT="$root" "$M" machine stop >/dev/null 2>&1; done
    for pid in $(vmm_pids); do kill "$pid"; done
    sleep 1
    if [ "${HVF_E2E_KEEP:-0}" != 1 ] && [ -f "$BASE/$MARKER" ] && [ -z "$(vmm_pids)" ]; then
        rm -rf "$BASE"
    fi
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
skip() { SKIP=$((SKIP + 1)); echo "  - SKIP $1"; }
pinned() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('default','-'), d.get('defaultOrigin','-'))" "$1" 2>/dev/null || echo "no pin"; }

# The package a fresh install would have: the CLI tarball's layout, every
# file an APFS clone.
mkdir -p "$PKG"
cp -c "$VMM" "$PKG/micropod-vmm"
cp -c "$KERNEL" "$PKG/vmlinux-hvf"
cp -c "$INITRD" "$PKG/mp-hvf-init.cpio"
cp -cR "$TOOLS" "$PKG/micropod-oci-tools"
cp -c "$DISK_FROM" "$PKG/hvf-base-disk.ext4"
chmod -R u+w "$PKG"
mkdir -p "$BASE/nodisk"
for f in micropod-vmm vmlinux-hvf mp-hvf-init.cpio; do cp -c "$PKG/$f" "$BASE/nodisk/$f"; done
cp -cR "$PKG/micropod-oci-tools" "$BASE/nodisk/micropod-oci-tools"

echo "== 0. every binary pins the install origin first"
# `setup --help` is answered before anything resolves a runtime.
MICROPOD_RUNTIMES_CONFIG="$TMP/cli-pin.json" "$M" setup --help >/dev/null
check "micropod pins hvf as a fresh install" "$(pinned "$TMP/cli-pin.json")" "hvf fresh-install"
MICROPOD_RUNTIMES_CONFIG="$TMP/mcp-pin.json" "$MCP" </dev/null >/dev/null 2>&1 &
MCP_PID=$!
for _ in $(seq 1 40); do [ -f "$TMP/mcp-pin.json" ] && break; sleep 0.25; done
kill "$MCP_PID" 2>/dev/null || true
MCP_PID=""
check "MicropodMCP pins hvf as a fresh install" "$(pinned "$TMP/mcp-pin.json")" "hvf fresh-install"
MICROPOD_RUNTIMES_CONFIG="$TMP/existing-pin.json" MICROPOD_INSTALL_ORIGIN=existing "$M" setup --help >/dev/null
check "an existing origin pins no default" "$(pinned "$TMP/existing-pin.json")" "- existing-install"
unset_out=$(env -u MICROPOD_INSTALL_ORIGIN MICROPOD_RUNTIMES_CONFIG="$TMP/none.json" "$M" setup --help >/dev/null
    [ -e "$TMP/none.json" ] && echo written || echo untouched)
check "an overridden config with no origin named is never written" "$unset_out" "untouched"

echo "== 1. a fresh install: hvf the default, Apple opt-in"
LS=$("$M" runtime ls)
check "runtimes.json holds the pin" "$(pinned "$MICROPOD_RUNTIMES_CONFIG")" "hvf fresh-install"
contains "hvf is the default" "$LS" "* hvf"
contains "hvf says how to set it up" "$LS" "not set up: \`micropod setup\`"
contains "Apple is opt-in" "$LS" "opt-in: \`micropod runtime enable apple\`"
contains "the default says where it came from" "$LS" "default: hvf (chosen for a fresh install"
RUNTIMES_JSON=$("$M" --json runtime ls)
check "Apple is not enabled" \
    "$(printf '%s' "$RUNTIMES_JSON" | python3 -c 'import json,sys; print([r.get("enabled", False) for r in json.load(sys.stdin) if r["name"]=="apple"])')" \
    "[False]"

echo "== 2. no machine yet"
out=$("$M" run "$IMAGE" true 2>&1 || true)
contains "run says to set the machine up" "$out" "the micropod machine is not set up"
contains "run names micropod setup" "$out" "run \`micropod setup\`"
out=$("$M" run --runtime apple "$IMAGE" true 2>&1 || true)
contains "an Apple run says it is opt-in" "$out" "the Apple runtime is opt-in"
out=$(MICROPOD_HVF_ROOT="$ROOT3" "$M" setup --payload "$BASE/nodisk" 2>&1 || true)
contains "no base disk: --disk-from" "$out" "Pass --disk-from <ext4> (a local image)"
contains "no base disk: --disk-image default" "$out" "--disk-image default to download docker:29.9.3-dind"
check "nothing was written for it" "$(ls -A "$ROOT3" 2>/dev/null | wc -l | tr -d ' ')" "0"
out=$("$M" setup --dry-run --payload "$PKG" 2>&1 || true)
contains "a dry run plans the base disk" "$out" "[2/5] disk            pending: from"
check "a dry run writes nothing" "$(ls -A "$ROOT" 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "== 3. micropod setup from the package"
SETUP_START=$(date +%s)
if "$M" setup --payload "$PKG" --cache-disk-size 1g --cpus 2 --memory-mib 2048 >"$TMP/setup.log" 2>&1; then
    PASS=$((PASS + 1))
    echo "  ✓ setup succeeded in $(($(date +%s) - SETUP_START)) s"
else
    FAIL=$((FAIL + 1))
    echo "  ✗ setup failed:"
    sed 's/^/      /' "$TMP/setup.log"
fi
SETUP=$(cat "$TMP/setup.log")
contains "[1/5] runtime files" "$SETUP" "[1/5] runtime files   micropod-vmm, Image, mp-hvf-init.cpio, tools/ from"
contains "[2/5] disk from the package's base disk" "$SETUP" "/hvf-base-disk.ext4"
contains "[3/5] cache disk created" "$SETUP" "[3/5] cache disk      created (1 GiB sparse)"
contains "[4/5] the machine started" "$SETUP" "[4/5] start           running (engine"
contains "[5/5] hvf is the default" "$SETUP" "[5/5] default runtime hvf"
contains "next: the docker context and autostart" "$SETUP" "next: micropod docker install --use    micropod machine autostart on"
check "nothing was downloaded" "$(grep -c 'pulling' "$TMP/setup.log" || true)" "0"
"$M" run --name mpfr-hello "$IMAGE" echo first-run-ok >/dev/null 2>"$TMP/run.err" || cat "$TMP/run.err"
for _ in $(seq 1 40); do
    [ "$("$M" logs mpfr-hello 2>/dev/null)" = first-run-ok ] && break
    sleep 0.25
done
check "a container runs with no --runtime flag" "$("$M" logs mpfr-hello 2>/dev/null)" "first-run-ok"
check "it ran on hvf" "$("$M" --json ps -a | python3 -c 'import json,sys; print([c.get("runtime") for c in json.load(sys.stdin) if c["id"]=="mpfr-hello"])')" "['hvf']"
"$M" rm -f mpfr-hello >/dev/null
STATUS=$("$M" status)
contains "status shows the machine running" "$STATUS" "machine:     running"
contains "status: Apple not enabled" "$STATUS" "apple:       not enabled"

echo "== 4. setup again keeps everything; --docker adds the context"
AGAIN=$("$M" setup --payload "$PKG" 2>&1)
contains "runtime files kept" "$AGAIN" "[1/5] runtime files   present, kept"
contains "disk kept" "$AGAIN" "[2/5] disk            present, kept"
contains "cache disk kept" "$AGAIN" "[3/5] cache disk      present, kept"
contains "start kept" "$AGAIN" "[4/5] start           running"
if [ -n "$DOCKER" ]; then
    WIRED=$("$M" setup --docker 2>&1 || true)
    contains "the docker context step" "$WIRED" "[6/6] docker          docker context micropod -> unix://"
    check "the current context is unchanged (no --use)" "$(env -u DOCKER_HOST "$DOCKER" context show 2>/dev/null)" "default"
    check "docker reaches the machine through the context" \
        "$(env -u DOCKER_HOST "$DOCKER" --context micropod version --format '{{.Server.Version}}' 2>/dev/null)" "micropod"
    "$M" docker uninstall >/dev/null 2>&1 || true
else
    skip "the docker context (no docker CLI)"
fi

echo "== 5. an existing install keeps the Apple default"
EXISTING=$(MICROPOD_RUNTIMES_CONFIG="$TMP/existing.json" MICROPOD_INSTALL_ORIGIN=existing MICROPOD_RUNTIME=cli \
    "$M" --json runtime ls)
check "Apple is the default" \
    "$(printf '%s' "$EXISTING" | python3 -c 'import json,sys; print([r["name"] for r in json.load(sys.stdin) if r.get("default")])')" \
    "['apple']"
check "Apple is enabled" \
    "$(printf '%s' "$EXISTING" | python3 -c 'import json,sys; print([r.get("enabled", False) for r in json.load(sys.stdin) if r["name"]=="apple"])')" \
    "[True]"
check "the pin names no default" "$(pinned "$TMP/existing.json")" "- existing-install"
"$M" machine stop >/dev/null

echo "== 6. SetupMachine over the API, on a second root"
mkdir -p "$ROOT2"
MICROPOD_HVF_ROOT="$ROOT2" MICROPOD_RUNTIMES_CONFIG="$TMP/api-runtimes.json" \
    MICROPOD_API_SOCK="$BASE/api.sock" MICROPOD_API_PORT="$API_PORT" "$API" >"$TMP/api.log" 2>&1 &
API_PID=$!
for _ in $(seq 1 80); do curl -sf -m 1 --unix-socket "$BASE/api.sock" http://x/health >/dev/null 2>&1 && break; sleep 0.25; done
check "the API pinned hvf as a fresh install" "$(pinned "$TMP/api-runtimes.json")" "hvf fresh-install"
REPLY=$(curl -s -m 600 --unix-socket "$BASE/api.sock" -H 'Content-Type: application/json' \
    -d "{\"payloadPath\": \"$PKG\", \"cacheDiskBytes\": \"1073741824\", \"start\": true}" \
    "http://x/api/micropod.v1.RigService/SetupMachine")
field() { printf '%s' "$REPLY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1" 2>/dev/null || echo "?"; }
check "SetupMachine ok" "$(field 'd.get("ok", False)')" "True"
check "SetupMachine steps" "$(field '[s["id"] + "=" + s["state"] for s in d["steps"]]')" \
    "['runtime-files=done', 'disk=done', 'cache-disk=done', 'start=done', 'default-runtime=done']"
check "the API's machine runs" "$(field 'd["machine"]["readiness"]')" "running"
check "the API's machine is the second root" "$(field 'd["machine"]["root"]')" "$ROOT2"
REPLY=$(curl -s -m 60 --unix-socket "$BASE/api.sock" -H 'Content-Type: application/json' \
    -d "{\"payloadPath\": \"$PKG\"}" "http://x/api/micropod.v1.RigService/SetupMachine")
check "a second SetupMachine keeps it" "$(field '[s["state"] for s in d["steps"]][:4]')" "['kept', 'kept', 'kept', 'kept']"
curl -s -m 120 --unix-socket "$BASE/api.sock" -H 'Content-Type: application/json' -d '{"action": "stop", "force": true}' \
    "http://x/api/micropod.v1.RigService/ControlMachine" >/dev/null
kill "$API_PID" 2>/dev/null || true
API_PID=""

echo "== the user's files"
check "~/.micropod/docker.sock, ~/.micropod/runtimes.json and ~/.docker/config.json unchanged" \
    "$(fingerprint)" "$BEFORE"

echo
echo "e2e_first_run: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
