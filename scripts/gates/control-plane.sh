#!/bin/bash
# B25 gate: the Phase C control plane (MicropodAPI over api.sock and TCP, and
# the MicropodMCP suite) measured on a throwaway hvf machine, with a receipt
# (backlog B25; master plan Phase C gate and §3.1-§3.3).
#
#   scripts/gates/control-plane.sh [--sections "L T M"] [--sabotage NAME[,NAME]]
#       [--samples 200] [--receipt-dir DIR] [--root /tmp/mpg-b25] [--port 19530]
#       [--image alpine:3.20] [--vmm PATH] [--kernel PATH] [--initrd PATH] [--tools DIR]
#       [--disk-from EXT4] [--micropod PATH] [--api PATH] [--mcp PATH] [--keep]
#
# It installs a machine into a throwaway root under /tmp, starts the real
# MicropodAPI on its own Unix socket (<root>/api.sock) and a loopback port, and
# measures it with cpbench (control-plane/cpbench: the generated connect-go
# clients of sdk/go, binary protobuf and proto-JSON, plus plain HTTP for the
# REST routes) and the real MicropodMCP over stdio. A process-spawn census
# (control-plane/procwatch.py, libproc polling every 1 ms, calibrated first)
# records every child the API and each MCP process start. Sections:
#   L  latency per transport (Unix socket, TCP) and codec (binary Connect,
#      proto-JSON, REST): Ping, GetSystem, ListContainers with 0/8/64
#      containers, inspect, cache summary and explain; p50/p95/p99 over
#      >= 200 warm samples, the cold first call of a fresh API, 16 concurrent
#      clients; connections opened per call (client dials, corroborated by the
#      server's TIME_WAIT sockets); guest requests per listing (the guest's own
#      counter); the MICROPOD_BINARY_PROTO opt-out; gRPC over HTTP/2
#   T  create→start→wait→remove round trips; log stream, exec and attach time
#      to first byte
#   M  MCP over stdio: initialize, tools/list (typed schemas, plan tool names),
#      every tool safe on a throwaway machine called with valid arguments and
#      its effect checked against the guest (or the throwaway file or sandbox
#      root it changes), invalid arguments refused with nothing changed,
#      cache_prune a dry run unless apply:true, no replay of a mutation after a
#      dropped connection (a recording proxy in front of the API), MCP tool
#      latency and wire format
# C (census calibration) and Z (safety) always run.
#
# Checks compare each number with the plan's Phase C target where the plan
# (or backlog B25/B39 for Phase C) states one; every other number is a metric
# in result.json without a verdict. No check passes on a missing number, fewer
# than 200 samples, a failed call, a failed instrument or an uncalibrated
# census. Targets the product misses stay failing: that is the receipt.
#
# --sabotage breaks a precondition on purpose so a check must fail:
#   list-inspect   inspect every container on the guest while a listing is counted
#   list-ping      ping the guest once per listing while a listing is counted
#   prune-apply    send the first "dry run" cache_prune as apply: true
#   replay-proxy   the proxy in front of the API sends a dropped Exec twice
#   census-blind   the census watches a pid that does not exist (calibration and
#                  every zero-children check must then fail, never pass on 0)
#   census-dead    the census is killed after its calibration passed (every
#                  zero-children check must then fail, never pass on 0)
#   few-samples    20 samples per latency case (no latency verdict may stand)
#   expect-flip:ID invert one check's expectation
# A sabotaged run is marked as such in its receipt and never passes by design.
#
# Receipt: ~/.micropod/gates/b25/<UTC time>/ (result.json, checks.tsv,
# latency.tsv, versions.json, census.jsonl, bench/ (one JSON per case),
# samples/ (every raw sample), logs/, evidence/). Exit 0 when every check
# passed, 1 when any failed, 2 when setup was refused or failed or the harness
# itself erred (never a pass). Only a run of all sections with >= 200 samples
# and no sabotage has the verdict "pass"; a clean run of fewer says "partial".
#
# Defaults: release binaries in .build/release (swift build -c release
# --product micropod|MicropodAPI|MicropodMCP; the CLI and the API signed with
# signing/micropod-cli.entitlements, as scripts/package_app.sh signs them: the
# MCP's sandbox tools boot their micro-VMs in the API, and the CLI's
# standalone sandbox is the fallback without one), the VMM from
# vmm/target/release (vmm/build.sh), the newest ~/.micropod/kernels/*/Image
# (read only) and --tools a guest bundle (ci/build-runner-tools.sh OUT, then
# OUT/guest). Ports: --port and --port+1 (the replay proxy), both inside
# B25_PORT_RANGE (LO-HI, default 19530-19629). Without --port (or B25_PORT)
# the first free pair in that range is taken, so runs given separate ranges
# never collide.
#
# Safety: everything lives under the throwaway root (absent, empty or marked
# by an earlier run of this gate; removed at exit unless --keep). Every
# process gets MICROPOD_HVF_ROOT, MICROPOD_API_SOCK, MICROPOD_RUNTIMES_CONFIG,
# MICROPOD_SANDBOX_ROOT, MICROPOD_K8S_CONFIG, MICROPOD_CI_HOME and
# MICROPOD_DOCKER_SOCK inside it and MICROPOD_LINK_DOCKER_SOCK=0, so the rig's
# ~/.micropod machine, sockets and link are never started, stopped, repointed
# or written; only the receipt is written under ~/.micropod/gates. Tools that
# would act on the host's Apple runtime, a registry or the app are never
# called with valid arguments (named in the receipt with the reason). Only
# processes this gate started (by pid, or this root's own micropod-vmm on this
# root's disk) are signalled.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GATE=$HERE/control-plane
REPO=$(cd "$HERE/../.." && pwd)
TS=$(date -u +%Y%m%dT%H%M%SZ)
ROOT=${B25_ROOT:-/tmp/mpg-b25}
PORT=${B25_PORT:-}
PORT_RANGE=${B25_PORT_RANGE:-19530-19629}
RECEIPT=${B25_RECEIPT_DIR:-$HOME/.micropod/gates/b25/$TS}
SECTIONS=${B25_SECTIONS:-L T M}
SABOTAGE=${B25_SABOTAGE:-}
SAMPLES=${B25_SAMPLES:-200}
IMAGE=${B25_IMAGE:-alpine:3.20}
VMM=${B25_VMM:-$REPO/vmm/target/release/micropod-vmm}
# shellcheck disable=SC2012 # newest kernel by mtime; these directory names are plain
KERNEL=${B25_KERNEL:-$(ls -t "$HOME"/.micropod/kernels/*/Image 2>/dev/null | head -1)}
INITRD=${B25_INITRD:-$REPO/vmm/target/mp-hvf-init.cpio}
TOOLS=${B25_TOOLS:-}
DISK_FROM=${B25_DISK_FROM:-$HOME/.micropod/ci/worker.ext4}
MICROPOD=${B25_MICROPOD:-$REPO/.build/release/micropod}
API=${B25_API:-$REPO/.build/release/MicropodAPI}
MCP=${B25_MCP:-$REPO/.build/release/MicropodMCP}
KEEP=${B25_KEEP:-0}

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
while [ $# -gt 0 ]; do
    case $1 in
        -h | --help) usage; exit 0 ;;
        --sections) SECTIONS=$2; shift ;;
        --sabotage) SABOTAGE=$2; shift ;;
        --samples) SAMPLES=$2; shift ;;
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

refuse() { echo "control-plane gate: $*" >&2; exit 2; }

# --- preconditions (refused before anything is created) -------------------
case "$ROOT" in
    */ | *//* | */./* | */. | */../* | */..) refuse "--root must be a plain path (got '$ROOT')" ;;
    /tmp/?* | /private/tmp/?*) ;;
    *) refuse "--root must be a throwaway directory under /tmp (got '$ROOT')" ;;
esac
MARKER=.micropod-gate-b25
if [ -e "$ROOT" ] && [ ! -f "$ROOT/$MARKER" ] && [ -n "$(ls -A "$ROOT" 2>/dev/null)" ]; then
    refuse "$ROOT exists and was not made by this gate (no $MARKER)"
fi
for sock in "$ROOT/hvf/run/docker.sock" "$ROOT/hvf/run/buildkit.sock" "$ROOT/api.sock" "$ROOT/mcp-rec.sock" \
    "$ROOT/mcp-rep.sock"; do
    long="/private${sock#/private}"
    [ ${#long} -lt 104 ] || refuse "socket path $long is ${#long} bytes; Unix sockets need < 104"
done
PORT_LO=${PORT_RANGE%%-*} PORT_HI=${PORT_RANGE#*-}
case "$PORT_LO:$PORT_HI" in *[!0-9:]* | :* | *:) refuse "B25_PORT_RANGE must be LO-HI (got '$PORT_RANGE')" ;; esac
[ "$PORT_LO" -ge 1024 ] && [ "$PORT_HI" -le 65535 ] && [ "$PORT_LO" -lt "$PORT_HI" ] ||
    refuse "B25_PORT_RANGE must be LO-HI within 1024-65535 (got '$PORT_RANGE')"
if [ -z "$PORT" ]; then
    # The first pair in the range where nothing listens on either port.
    PORT=$(python3 -c '
import socket, sys
lo, hi = int(sys.argv[1]), int(sys.argv[2])
def free(p):
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", p))
        return True
    except OSError:
        return False
    finally:
        s.close()
print(next((p for p in range(lo, hi) if free(p) and free(p + 1)), ""))
' "$PORT_LO" "$PORT_HI")
    [ -n "$PORT" ] || refuse "no free pair of ports in $PORT_RANGE (B25_PORT_RANGE)"
fi
case "$PORT" in '' | *[!0-9]*) refuse "--port must be a number" ;; esac
PROXY_PORT=$((PORT + 1))
[ "$PORT" -ge "$PORT_LO" ] && [ "$PROXY_PORT" -le "$PORT_HI" ] ||
    refuse "--port must leave --port and --port+1 within $PORT_RANGE (B25_PORT_RANGE)"
for p in "$PORT" "$PROXY_PORT"; do
    python3 -c "import socket,sys; s=socket.socket(); s.bind(('127.0.0.1', int(sys.argv[1])))" "$p" 2>/dev/null ||
        refuse "127.0.0.1:$p is in use; pick another --port"
done
case "$SAMPLES" in '' | *[!0-9]*) refuse "--samples must be a number" ;; esac
for need in "$MICROPOD" "$API" "$MCP" "$VMM"; do
    [ -x "$need" ] || refuse "missing executable $need (swift build -c release --product micropod/MicropodAPI/MicropodMCP; vmm/build.sh)"
done
for need in "$KERNEL" "$INITRD" "$DISK_FROM"; do
    [ -f "$need" ] || refuse "missing file $need"
done
[ -n "$TOOLS" ] && [ -f "$TOOLS/runner/start.sh" ] || refuse "set --tools to a guest tool bundle (a directory with runner/start.sh)"
codesign -d --entitlements - --xml "$VMM" 2>/dev/null | grep -q com.apple.security.hypervisor ||
    refuse "$VMM lacks the hypervisor entitlement (vmm/build.sh signs it)"
case " $SECTIONS " in
    *" M "*)
        for need in "$MICROPOD" "$API"; do
            codesign -d --entitlements - --xml "$need" 2>/dev/null | grep -q com.apple.security.virtualization ||
                refuse "$need lacks the virtualization entitlement the sandbox tools need (codesign --force --sign - --entitlements signing/micropod-cli.entitlements $need)"
        done
        ;;
esac
command -v go >/dev/null || refuse "go is needed to build cpbench"

mkdir -p "$RECEIPT/logs" "$RECEIPT/evidence"
RECEIPT=$(cd "$RECEIPT" && pwd)
exec > >(tee -a "$RECEIPT/logs/harness.log") 2>&1
log() { printf '%s control-plane: %s\n' "$(date +%H:%M:%S)" "$*"; }
log "receipt $RECEIPT"
log "root $ROOT, API port $PORT, proxy port $PROXY_PORT, sections: $SECTIONS, samples $SAMPLES${SABOTAGE:+, SABOTAGE: $SABOTAGE}"

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
export MICROPOD_SANDBOX_ROOT=$ROOT/sandbox
export MICROPOD_K8S_CONFIG=$ROOT/k8s.json
export MICROPOD_NO_UPDATE_NOTIFIER=1
export PYTHONDONTWRITEBYTECODE=1 # no __pycache__ beside the gate's helpers
unset MICROPOD_DEFAULT_RUNTIME MICROPOD_HVF_AUTOSTART DOCKER_HOST DOCKER_CONTEXT MICROPOD_BINARY_PROTO

B25_RIG_LINK=$(readlink "$HOME/.micropod/docker.sock" 2>/dev/null || true)
export B25_RIG_LINK

INSTALLED=""
# shellcheck disable=SC2329 # run by the EXIT trap
cleanup() {
    local rc=$?
    set +e
    if [ -n "$INSTALLED" ]; then
        for pid in $(pgrep -f "^$ROOT/hvf/micropod-vmm .*--disk $ROOT/hvf/disk.ext4" 2>/dev/null); do kill -CONT "$pid"; done
        "$MICROPOD" machine stop >/dev/null 2>&1
    fi
    # The API this gate runs (the driver restarts it and records the pid).
    api_pid=$(cat "$ROOT/api.pid" 2>/dev/null)
    if [ -n "$api_pid" ] && ps -o command= -p "$api_pid" 2>/dev/null | grep -q "^$API"; then
        kill "$api_pid" 2>/dev/null
        for _ in $(seq 1 40); do kill -0 "$api_pid" 2>/dev/null || break; sleep 0.25; done
    fi
    sup=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('supervisorPID') or '')" \
        "$ROOT/hvf/run/state.json" 2>/dev/null)
    if [ -n "$sup" ] && ps -o command= -p "$sup" 2>/dev/null | grep -q "^$MICROPOD machine serve"; then kill "$sup"; fi
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
    [ -f "$ROOT/runtimes.json" ] && cp "$ROOT/runtimes.json" "$RECEIPT/logs/runtimes.json"
    if [ ! -f "$RECEIPT/result.json" ]; then
        python3 - "$RECEIPT" "$rc" <<'PY'
import json, sys
json.dump({"gate": "B25 control-plane", "verdict": "fail", "checks": 0, "passed": 0, "failed": 0,
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
mkdir -p "$ROOT/ws" "$ROOT/ci" "$ROOT/bin" "$ROOT/sandbox"
touch "$ROOT/$MARKER"
WS=$(cd "$ROOT/ws" && pwd -P)

# cpbench, against this checkout's sdk/go. The shared Go build cache: no
# per-task GOCACHE, and -trimpath kept when GOFLAGS replaces the machine-wide value.
case " ${GOFLAGS:-} " in *" -trimpath "*) ;; *) GOFLAGS="${GOFLAGS:+$GOFLAGS }-trimpath" ;; esac
(cd "$GATE/cpbench" && GOFLAGS="$GOFLAGS" go build -o "$ROOT/bin/cpbench" .) >"$RECEIPT/logs/cpbench-build.log" 2>&1 ||
    { cat "$RECEIPT/logs/cpbench-build.log"; refuse "cpbench did not build"; }

INSTALLED=1
"$MICROPOD" machine install --vmm "$VMM" --kernel "$KERNEL" --initrd "$INITRD" --tools "$TOOLS" \
    --disk-from "$DISK_FROM" --cache-disk-size 2g --cpus 4 --memory-mib 4096 --workspace "$WS" \
    >"$RECEIPT/logs/install.log" 2>&1 || { cat "$RECEIPT/logs/install.log"; refuse "machine install failed"; }
"$MICROPOD" runtime enable hvf >>"$RECEIPT/logs/install.log" 2>&1
"$MICROPOD" runtime use hvf >>"$RECEIPT/logs/install.log" 2>&1

python3 - "$RECEIPT/versions.json" "$REPO" "$MICROPOD" "$API" "$MCP" "$VMM" "$KERNEL" "$INITRD" "$TOOLS" "$DISK_FROM" \
    "$IMAGE" "$ROOT/bin/cpbench" <<'PY'
import hashlib, json, subprocess, sys
out, repo, *paths = sys.argv[1:]
cli, api, mcp, vmm, kernel, initrd, tools, disk, image, cpbench = paths
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
    "harnessDirty": bool(git("status", "--porcelain", "--", "scripts/gates/control-plane.sh", "scripts/gates/control-plane")),
    "binaries": {name: {"path": p, "sha256": digest(p)} for name, p in
                 (("micropod", cli), ("MicropodAPI", api), ("MicropodMCP", mcp), ("micropod-vmm", vmm),
                  ("kernel", kernel), ("initrd", initrd), ("cpbench", cpbench))},
    "toolsBundle": {"path": tools, "manifest": manifest}, "diskFrom": disk, "image": image,
    "go": subprocess.run(["go", "version"], capture_output=True, text=True).stdout.strip(),
}, open(out, "w"), indent=2)
PY

# --- the API, on its own socket and port ----------------------------------------
log "starting $API on unix://$MICROPOD_API_SOCK and 127.0.0.1:$PORT"
"$API" >"$RECEIPT/logs/api.log" 2>&1 &
API_PID=$!
echo "$API_PID" >"$ROOT/api.pid"
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
B25_ROOT=$ROOT B25_WS=$WS B25_API_PID=$API_PID B25_API=$API B25_API_LOG=$RECEIPT/logs/api.log \
    B25_MICROPOD=$MICROPOD B25_MCP=$MCP B25_CPBENCH=$ROOT/bin/cpbench B25_RECEIPT=$RECEIPT \
    B25_RUN=$(date +%s | tail -c 7) B25_IMAGE=$IMAGE B25_SECTIONS=$SECTIONS B25_SABOTAGE=$SABOTAGE \
    B25_SAMPLES=$SAMPLES B25_PROXY_PORT=$PROXY_PORT \
    python3 -u "$GATE/gate.py"
rc=$?
set -e
exit "$rc"
