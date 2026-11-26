#!/bin/bash
# B24 gate: API-to-guest integration on a throwaway hvf machine, as a
# repeatable measurement with a receipt (backlog B24; master plan Phase B/C).
#
#   scripts/gates/api-guest.sh [--sections "R S P H L X F"] [--sabotage NAME[,NAME]]
#       [--receipt-dir DIR] [--root /tmp/mpg-b24] [--port 19330] [--image alpine:3.20]
#       [--vmm PATH] [--kernel PATH] [--initrd PATH] [--tools DIR] [--disk-from EXT4]
#       [--micropod PATH] [--api PATH] [--mcp PATH] [--keep]
#
# It installs a machine into a throwaway root under /tmp, starts the real
# MicropodAPI binary on its own Unix socket (<root>/api.sock) and a loopback
# port, and drives it, the micropod CLI and the MicropodMCP server (stdio
# JSON-RPC) against that machine. Every answer is compared with what the guest
# itself shows: files and sizes measured inside a container, the guest
# engine's own Docker socket (/micropod/caches, /micropod/metrics, inspect),
# run/state.json and the guest console. Sections (checks numbered per section):
#   R  Ping/GetSystem readiness: never started, running, stopped on request,
#      booting (sampled against the guest's _ping)
#   Z  safety: the API, supervisor and VMM serve only this root
#   S  cache summary (API socket and TCP, CLI, MCP) equals guest facts
#   P  prune: dry runs (MCP, REST, CLI) change nothing; apply removes what the
#      dry run listed and only that; unselected applies are refused
#   H  policy hot-apply: default-trust flip and allowedScopes reach the next
#      container within 3 s without a restart, and `cache explain` names the
#      policy digest its plan was made under; malformed policies fail closed
#   L  ListContainers with 8 containers costs exactly one guest request (the
#      guest's own counter); WaitContainer exit code 7, one guest request per
#      poll and its timeout; CLI exec exit code
#   X  exit codes: orderly stop (0), VMM --timeout (5), CLI start timeout (1),
#      guest kernel panic (3) and a crash loop; readiness never says running
#   F  a frozen guest (SIGSTOP of this root's VMM: phase running, _ping
#      unanswered) is not ready, ready again once resumed, and still stops
#
# --sabotage breaks a precondition on purpose so a check must fail:
#   prune-extra    grow the pruned unit between the dry run and the apply
#   policy-skip    never send the default-trust flip
#   stopped-boots  boot the machine before the stopped-readiness checks
#   list-inspect   inspect each container on the guest while the listing is counted
#   guest-blind    the gate cannot read the guest's cache policy (no check may
#                  pass on a default)
#   expect-flip:ID invert one check's expectation
# A sabotaged run is marked as such in its receipt and never passes by design.
#
# Receipt: ~/.micropod/gates/b24/<UTC time>/ (result.json, checks.tsv,
# versions.json, logs/, evidence/). Exit 0 when every check passed, 1 when
# any failed, 2 when setup was refused or failed or the harness itself erred
# (a harness error is never a pass). Only a run of all sections has the
# verdict "pass"; a clean run of some sections says "partial".
#
# Safety: everything lives under the throwaway root (absent, empty or marked
# by an earlier run of this gate; removed at exit unless --keep). Every
# process gets MICROPOD_HVF_ROOT, MICROPOD_API_SOCK, MICROPOD_RUNTIMES_CONFIG,
# MICROPOD_CI_HOME and MICROPOD_DOCKER_SOCK inside it and
# MICROPOD_LINK_DOCKER_SOCK=0, so the rig's ~/.micropod machine, sockets and
# link are never started, stopped, repointed or written; only the receipt is
# written under ~/.micropod/gates. Only processes this gate started (by pid,
# or this root's own micropod-vmm on this root's disk) are signalled.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GATE=$HERE/api-guest
REPO=$(cd "$HERE/../.." && pwd)
TS=$(date -u +%Y%m%dT%H%M%SZ)
ROOT=${B24_ROOT:-/tmp/mpg-b24}
PORT=${B24_PORT:-19330}
RECEIPT=${B24_RECEIPT_DIR:-$HOME/.micropod/gates/b24/$TS}
SECTIONS=${B24_SECTIONS:-R S P H L X F}
SABOTAGE=${B24_SABOTAGE:-}
IMAGE=${B24_IMAGE:-alpine:3.20}
VMM=${B24_VMM:-$REPO/vmm/target/release/micropod-vmm}
# shellcheck disable=SC2012 # newest kernel by mtime; these directory names are plain
KERNEL=${B24_KERNEL:-$(ls -t "$HOME"/.micropod/kernels/*/Image 2>/dev/null | head -1)}
INITRD=${B24_INITRD:-$REPO/vmm/target/mp-hvf-init.cpio}
TOOLS=${B24_TOOLS:-}
DISK_FROM=${B24_DISK_FROM:-$HOME/.micropod/ci/worker.ext4}
MICROPOD=${B24_MICROPOD:-$REPO/.build/debug/micropod}
API=${B24_API:-$REPO/.build/debug/MicropodAPI}
MCP=${B24_MCP:-$REPO/.build/debug/MicropodMCP}
KEEP=${B24_KEEP:-0}

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
while [ $# -gt 0 ]; do
    case $1 in
        -h | --help) usage; exit 0 ;;
        --sections) SECTIONS=$2; shift ;;
        --sabotage) SABOTAGE=$2; shift ;;
        --receipt-dir) RECEIPT=$2; shift ;;
        --root) ROOT=$2; shift ;;
        --port) PORT=$2; shift ;;
        --image) IMAGE=$2; shift ;;
        --vmm) VMM=$2; shift ;;
        --kernel) KERNEL=$2; shift ;;
        --initrd) INITRD=$2; shift ;;
        --tools) TOOLS=$2; shift ;;
        --disk-from) DISK_FROM=$2; shift ;;
        --micropod) MICROPOD=$2; shift ;;
        --api) API=$2; shift ;;
        --mcp) MCP=$2; shift ;;
        --keep) KEEP=1 ;;
        *) echo "unknown argument $1 (see --help)" >&2; exit 2 ;;
    esac
    shift
done

refuse() { echo "api-guest gate: $*" >&2; exit 2; }

# --- preconditions (refused before anything is created) -------------------
case "$ROOT" in
    */ | *//* | */./* | */. | */../* | */..) refuse "--root must be a plain path (got '$ROOT')" ;;
    /tmp/?* | /private/tmp/?*) ;;
    *) refuse "--root must be a throwaway directory under /tmp (got '$ROOT')" ;;
esac
MARKER=.micropod-gate-b24
if [ -e "$ROOT" ] && [ ! -f "$ROOT/$MARKER" ] && [ -n "$(ls -A "$ROOT" 2>/dev/null)" ]; then
    refuse "$ROOT exists and was not made by this gate (no $MARKER)"
fi
for sock in "$ROOT/hvf/run/docker.sock" "$ROOT/hvf/run/buildkit.sock" "$ROOT/api.sock"; do
    long="/private${sock#/private}"
    [ ${#long} -lt 104 ] || refuse "socket path $long is ${#long} bytes; Unix sockets need < 104"
done
case "$PORT" in '' | *[!0-9]*) refuse "--port must be a number" ;; esac
python3 -c "import socket,sys; s=socket.socket(); s.bind(('127.0.0.1', int(sys.argv[1])))" "$PORT" 2>/dev/null ||
    refuse "127.0.0.1:$PORT is in use; pick another --port"
for need in "$MICROPOD" "$API" "$MCP" "$VMM"; do
    [ -x "$need" ] || refuse "missing executable $need (swift build --product micropod/MicropodAPI/MicropodMCP; vmm/build.sh)"
done
for need in "$KERNEL" "$INITRD" "$DISK_FROM"; do
    [ -f "$need" ] || refuse "missing file $need"
done
[ -n "$TOOLS" ] && [ -f "$TOOLS/runner/start.sh" ] || refuse "set --tools to a guest tool bundle (a directory with runner/start.sh)"
codesign -d --entitlements - --xml "$VMM" 2>/dev/null | grep -q com.apple.security.hypervisor ||
    refuse "$VMM lacks the hypervisor entitlement (vmm/build.sh signs it)"

mkdir -p "$RECEIPT/logs" "$RECEIPT/evidence"
RECEIPT=$(cd "$RECEIPT" && pwd)
exec > >(tee -a "$RECEIPT/logs/harness.log") 2>&1
log() { printf '%s api-guest: %s\n' "$(date +%H:%M:%S)" "$*"; }
log "receipt $RECEIPT"
log "root $ROOT, API port $PORT, sections: $SECTIONS${SABOTAGE:+, SABOTAGE: $SABOTAGE}"

# --- the throwaway environment, for every process started below ------------
export MICROPOD_HVF_ROOT=$ROOT/hvf
export MICROPOD_RUNTIMES_CONFIG=$ROOT/runtimes.json
export MICROPOD_CLI=$MICROPOD
export MICROPOD_LINK_DOCKER_SOCK=0
export MICROPOD_DOCKER_SOCK=$ROOT/canonical-docker.sock
export MICROPOD_API_SOCK=$ROOT/api.sock
export MICROPOD_API_PORT=$PORT
export MICROPOD_CI_HOME=$ROOT/ci
export MICROPOD_APP_CONTROL_SOCKET=$ROOT/app-control.sock
export MICROPOD_VOLUME_POLICY=$ROOT/volume-policy.json
export MICROPOD_NO_UPDATE_NOTIFIER=1
export PYTHONDONTWRITEBYTECODE=1 # no __pycache__ beside the gate's helpers
unset MICROPOD_DEFAULT_RUNTIME MICROPOD_HVF_AUTOSTART DOCKER_HOST DOCKER_CONTEXT

# Where the rig's link points before anything is started (check Z06).
B24_RIG_LINK=$(readlink "$HOME/.micropod/docker.sock" 2>/dev/null || true)
export B24_RIG_LINK

API_PID=""
INSTALLED=""
# shellcheck disable=SC2329 # run by the EXIT trap
cleanup() {
    local rc=$?
    set +e
    if [ -n "$INSTALLED" ]; then
        # A VMM this gate froze must run again to power off.
        for pid in $(pgrep -f "^$ROOT/hvf/micropod-vmm .*--disk $ROOT/hvf/disk.ext4" 2>/dev/null); do kill -CONT "$pid"; done
        "$MICROPOD" machine stop >/dev/null 2>&1
    fi
    if [ -n "$API_PID" ]; then kill "$API_PID" 2>/dev/null && wait "$API_PID" 2>/dev/null; fi
    # A supervisor that did not stop: the pid this root's state.json names, if it is this gate's CLI serving.
    sup=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('supervisorPID') or '')" \
        "$ROOT/hvf/run/state.json" 2>/dev/null)
    if [ -n "$sup" ] && ps -o command= -p "$sup" 2>/dev/null | grep -q "^$MICROPOD machine serve"; then kill "$sup"; fi
    # A VMM of this root that outlived its supervisor: this root's binary on this root's disk only.
    for pid in $(pgrep -f "^$ROOT/hvf/micropod-vmm .*--disk $ROOT/hvf/disk.ext4" 2>/dev/null); do kill "$pid"; done
    for _ in $(seq 1 60); do
        { [ -z "$sup" ] || ! kill -0 "$sup" 2>/dev/null; } &&
            [ -z "$(pgrep -f "^$ROOT/hvf/micropod-vmm .*--disk $ROOT/hvf/disk.ext4" 2>/dev/null)" ] && break
        sleep 0.5
    done
    for f in supervisor.log console.log; do
        [ -f "$ROOT/hvf/logs/$f" ] && tail -c 4000000 "$ROOT/hvf/logs/$f" >"$RECEIPT/logs/$f"
    done
    [ -f "$ROOT/hvf/machine.json" ] && cp "$ROOT/hvf/machine.json" "$RECEIPT/logs/machine.json"
    if [ ! -f "$RECEIPT/result.json" ]; then
        python3 - "$RECEIPT" "$rc" <<'PY'
import json, sys
json.dump({"gate": "B24 api-guest", "verdict": "fail", "checks": 0, "passed": 0, "failed": 0,
           "harnessError": f"setup failed before any check ran (exit {sys.argv[2]}); see logs/harness.log"},
          open(f"{sys.argv[1]}/result.json", "w"), indent=2)
PY
    fi
    if [ -n "$(pgrep -f "^$ROOT/hvf/micropod-vmm .*--disk $ROOT/hvf/disk.ext4" 2>/dev/null)" ]; then
        log "a micropod-vmm of $ROOT is still running; leaving the root in place"
    elif [ "$KEEP" != 1 ] && [ -f "$ROOT/$MARKER" ]; then
        rm -rf "$ROOT"
    fi
    log "receipt: $RECEIPT/result.json ($(python3 -c "import json,sys; r=json.load(open(sys.argv[1])); print(r['verdict'], r['passed'], 'passed', r['failed'], 'failed')" "$RECEIPT/result.json" 2>/dev/null))"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# --- install -------------------------------------------------------------------
log "installing a throwaway machine into $ROOT/hvf"
if [ -d "$ROOT/hvf" ]; then "$MICROPOD" machine stop >/dev/null 2>&1 || true; fi
rm -rf "$ROOT" # absent, empty or ours (checked above)
mkdir -p "$ROOT/ws" "$ROOT/ci"
touch "$ROOT/$MARKER"
WS=$(cd "$ROOT/ws" && pwd -P)
INSTALLED=1
"$MICROPOD" machine install --vmm "$VMM" --kernel "$KERNEL" --initrd "$INITRD" --tools "$TOOLS" \
    --disk-from "$DISK_FROM" --cache-disk-size 2g --cpus 2 --memory-mib 2048 --workspace "$WS" \
    >"$RECEIPT/logs/install.log" 2>&1 || { cat "$RECEIPT/logs/install.log"; refuse "machine install failed"; }
"$MICROPOD" runtime enable hvf >>"$RECEIPT/logs/install.log" 2>&1
"$MICROPOD" runtime use hvf >>"$RECEIPT/logs/install.log" 2>&1

python3 - "$RECEIPT/versions.json" "$REPO" "$MICROPOD" "$API" "$MCP" "$VMM" "$KERNEL" "$INITRD" "$TOOLS" "$DISK_FROM" "$IMAGE" <<'PY'
import hashlib, json, subprocess, sys
out, repo, *paths = sys.argv[1:]
cli, api, mcp, vmm, kernel, initrd, tools, disk, image = paths
def digest(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()
git = lambda *a: subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True).stdout.strip()
try:
    manifest = json.load(open(f"{tools}/runner/manifest.json"))
except (OSError, ValueError):
    manifest = None
json.dump({
    "repoCommit": git("rev-parse", "HEAD"),
    "harnessDirty": bool(git("status", "--porcelain", "--", "scripts/gates/api-guest.sh", "scripts/gates/api-guest")),
    "binaries": {name: {"path": p, "sha256": digest(p)} for name, p in
                 (("micropod", cli), ("MicropodAPI", api), ("MicropodMCP", mcp), ("micropod-vmm", vmm),
                  ("kernel", kernel), ("initrd", initrd))},
    "toolsBundle": {"path": tools, "manifest": manifest}, "diskFrom": disk, "image": image,
}, open(out, "w"), indent=2)
PY

# --- the API, on its own socket and port ----------------------------------------
log "starting $API on unix://$MICROPOD_API_SOCK and 127.0.0.1:$PORT"
"$API" >"$RECEIPT/logs/api.log" 2>&1 &
API_PID=$!
ok=""
for _ in $(seq 1 120); do
    if curl -sf -m 2 --unix-socket "$MICROPOD_API_SOCK" http://x/health >/dev/null 2>&1 &&
        curl -sf -m 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
        ok=1
        break
    fi
    kill -0 "$API_PID" 2>/dev/null || break
    sleep 0.25
done
[ -n "$ok" ] || { cat "$RECEIPT/logs/api.log"; refuse "the API did not answer /health on its socket and port"; }
log "$(head -1 "$RECEIPT/logs/api.log")"

# --- the checks -------------------------------------------------------------------
set +e
B24_ROOT=$ROOT B24_WS=$WS B24_API_PID=$API_PID B24_MICROPOD=$MICROPOD B24_MCP=$MCP B24_RECEIPT=$RECEIPT \
    B24_RUN=$(date +%s | tail -c 7) B24_IMAGE=$IMAGE B24_SECTIONS=$SECTIONS B24_SABOTAGE=$SABOTAGE \
    python3 -u "$GATE/gate.py"
rc=$?
set -e
exit "$rc"
