#!/bin/bash
# HTTP/2 and gRPC interop against a throwaway MicropodAPI: real clients
# (grpc-go 1.84 and connect-go through sdk/go's interop tests, curl, grpcurl,
# buf curl) over h2c prior knowledge on the API's Unix socket and loopback
# TCP, beside HTTP/1.1 clients on the same socket and port.
#
#   scripts/h2-interop.sh --api PATH [--root /tmp/mpg-h2i] [--receipt-dir DIR] [--keep]
#       [--machine --micropod PATH --vmm PATH --kernel PATH --initrd PATH --tools DIR
#        [--disk-from EXT4] [--image alpine:3.20] [--flood SECONDS]]
#
# Without --machine the API has no runtime behind it (Apple's is not started:
# reads answer "stopped" or UNAVAILABLE): the protocol itself is exercised.
# With --machine a throwaway hvf machine is installed and booted in the root
# (as scripts/gates/control-plane.sh does, which also pulls --image into
# the throwaway guest) and a container that logs as fast
# as it can is started, for server streams, cancellation, NotFound and the
# --flood soak (default 60 s): grpc-go's BDP pings during a log flood are
# what HTTP2Limits.controlFrames must allow, and the API logs each
# connection's busiest window (MICROPOD_API_H2_LOG_CONTROL_FRAMES=1).
#
# Safety: every path lives under the root (under /tmp, absent, empty or
# marked by an earlier run); the API gets MICROPOD_API_SOCK, MICROPOD_HVF_ROOT,
# MICROPOD_RUNTIMES_CONFIG and the rest inside it and
# MICROPOD_LINK_DOCKER_SOCK=0, so ~/.micropod is never read or written. The
# port is the first free one in H2_INTEROP_PORT_RANGE (default 20030-20059).
# Exit 0 when every check passed, 1 when one failed, 2 on a setup error.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
ROOT=/tmp/mpg-h2i
RECEIPT=/tmp/mpg-h2-interop/$(date -u +%Y%m%dT%H%M%SZ)
API="" MICROPOD="" VMM="" KERNEL="" INITRD="" TOOLS=""
DISK_FROM=$HOME/.micropod/ci/worker.ext4
IMAGE=alpine:3.20
MACHINE=0 KEEP=0 FLOOD=60
PORT_RANGE=${H2_INTEROP_PORT_RANGE:-20030-20059}

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
while [ $# -gt 0 ]; do
    case $1 in
        -h | --help) usage; exit 0 ;;
        --api) API=$2; shift ;;
        --root) ROOT=$2; shift ;;
        --receipt-dir) RECEIPT=$2; shift ;;
        --machine) MACHINE=1 ;;
        --micropod) MICROPOD=$2; shift ;;
        --vmm) VMM=$2; shift ;;
        --kernel) KERNEL=$2; shift ;;
        --initrd) INITRD=$2; shift ;;
        --tools) TOOLS=$2; shift ;;
        --disk-from) DISK_FROM=$2; shift ;;
        --image) IMAGE=$2; shift ;;
        --flood) FLOOD=$2; shift ;;
        --keep) KEEP=1 ;;
        *) echo "unknown argument $1 (see --help)" >&2; exit 2 ;;
    esac
    shift
done

refuse() { echo "h2-interop: $*" >&2; exit 2; }
case "$ROOT" in
    */ | *//* | */./* | */. | */../* | */..) refuse "--root must be a plain path" ;;
    /tmp/?* | /private/tmp/?*) ;;
    *) refuse "--root must be under /tmp (got '$ROOT')" ;;
esac
MARKER=.micropod-h2-interop
if [ -e "$ROOT" ] && [ ! -f "$ROOT/$MARKER" ] && [ -n "$(ls -A "$ROOT" 2>/dev/null)" ]; then
    refuse "$ROOT exists and was not made by this script (no $MARKER)"
fi
[ -x "$API" ] || refuse "--api must name a MicropodAPI binary"
if [ "$MACHINE" = 1 ]; then
    for need in "$MICROPOD" "$VMM"; do [ -x "$need" ] || refuse "--machine needs --micropod and --vmm"; done
    for need in "$KERNEL" "$INITRD" "$DISK_FROM"; do [ -f "$need" ] || refuse "missing file $need"; done
    [ -f "$TOOLS/runner/start.sh" ] || refuse "--tools must be a guest tool bundle (runner/start.sh)"
fi
for tool in curl go python3; do command -v "$tool" >/dev/null || refuse "$tool is needed"; done
PORT=$(python3 -c '
import socket, sys
lo, hi = map(int, sys.argv[1].split("-"))
def free(p):
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", p)); return True
    except OSError:
        return False
    finally:
        s.close()
print(next((p for p in range(lo, hi + 1) if free(p)), ""))' "$PORT_RANGE")
[ -n "$PORT" ] || refuse "no free port in $PORT_RANGE"

rm -rf "$ROOT"
mkdir -p "$ROOT" "$RECEIPT"
chmod 700 "$ROOT"
touch "$ROOT/$MARKER"
mkdir -p "$ROOT/ci" "$ROOT/sandbox" "$ROOT/ws"
exec > >(tee -a "$RECEIPT/interop.log") 2>&1

export MICROPOD_HVF_ROOT=$ROOT/hvf MICROPOD_RUNTIMES_CONFIG=$ROOT/runtimes.json MICROPOD_LINK_DOCKER_SOCK=0
export MICROPOD_DOCKER_SOCK=$ROOT/canonical-docker.sock MICROPOD_API_SOCK=$ROOT/api.sock MICROPOD_API_PORT=$PORT
export MICROPOD_CI_HOME=$ROOT/ci MICROPOD_APP_CONTROL_SOCKET=$ROOT/app-control.sock
export MICROPOD_VOLUME_POLICY=$ROOT/volume-policy.json MICROPOD_SANDBOX_ROOT=$ROOT/sandbox
export MICROPOD_K8S_CONFIG=$ROOT/k8s.json MICROPOD_NO_UPDATE_NOTIFIER=1 MICROPOD_API_H2_LOG_CONTROL_FRAMES=1
export PYTHONDONTWRITEBYTECODE=1
unset MICROPOD_DEFAULT_RUNTIME MICROPOD_HVF_AUTOSTART DOCKER_HOST DOCKER_CONTEXT MICROPOD_BINARY_PROTO
case " ${GOFLAGS:-} " in *" -trimpath "*) ;; *) export GOFLAGS="${GOFLAGS:+$GOFLAGS }-trimpath" ;; esac

API_PID=""
cleanup() {
    local rc=$?
    set +e
    [ -n "$API_PID" ] && kill "$API_PID" 2>/dev/null && wait "$API_PID" 2>/dev/null
    if [ "$MACHINE" = 1 ] && [ -d "$ROOT/hvf" ]; then "$MICROPOD" machine stop >/dev/null 2>&1; fi
    [ -f "$ROOT/api.log" ] && cp "$ROOT/api.log" "$RECEIPT/api.log"
    if [ "$KEEP" != 1 ] && [ -f "$ROOT/$MARKER" ] &&
        [ -z "$(pgrep -f "^$ROOT/hvf/micropod-vmm" 2>/dev/null)" ]; then rm -rf "$ROOT"; fi
    echo "h2-interop: receipt $RECEIPT"
    exit "$rc"
}
trap cleanup EXIT

CONTAINER=""
if [ "$MACHINE" = 1 ]; then
    echo "installing a throwaway machine into $ROOT/hvf"
    "$MICROPOD" machine install --vmm "$VMM" --kernel "$KERNEL" --initrd "$INITRD" --tools "$TOOLS" \
        --disk-from "$DISK_FROM" --cache-disk-size 2g --cpus 4 --memory-mib 4096 --workspace "$(cd "$ROOT/ws" && pwd -P)" \
        >"$RECEIPT/install.log" 2>&1 || { cat "$RECEIPT/install.log"; refuse "machine install failed"; }
    "$MICROPOD" runtime enable hvf >>"$RECEIPT/install.log" 2>&1
    "$MICROPOD" runtime use hvf >>"$RECEIPT/install.log" 2>&1
    "$MICROPOD" machine start --timeout 240 >>"$RECEIPT/install.log" 2>&1 || refuse "machine start failed"
    GUEST=$ROOT/hvf/run/docker.sock
    # As the B25 gate does: the image into the throwaway guest (a no-op when
    # the cloned disk already holds it).
    "$MICROPOD" pull --runtime hvf "$IMAGE" >>"$RECEIPT/install.log" 2>&1 || refuse "could not pull $IMAGE"
    body=$(python3 -c 'import json, sys; print(json.dumps({"Image": sys.argv[1], "Cmd": ["sh", "-c",
        "i=0; while :; do echo \"h2 flood line $i $(printf %0120d 0)\"; i=$((i+1)); done"]}))' "$IMAGE")
    curl -sf --unix-socket "$GUEST" -X POST -H 'Content-Type: application/json' -d "$body" \
        "http://guest/containers/create?name=h2log" >/dev/null || refuse "could not create the log container"
    curl -sf --unix-socket "$GUEST" -X POST "http://guest/containers/h2log/start" >/dev/null ||
        refuse "could not start the log container"
    CONTAINER=$(curl -sf --unix-socket "$GUEST" "http://guest/containers/h2log/json" |
        python3 -c 'import json, sys; print(json.load(sys.stdin)["Id"])')
    echo "log container $CONTAINER"
fi

echo "starting $API on unix://$MICROPOD_API_SOCK and 127.0.0.1:$PORT"
"$API" >"$ROOT/api.log" 2>&1 &
API_PID=$!
for _ in $(seq 1 120); do
    curl -sf -m 2 --unix-socket "$MICROPOD_API_SOCK" http://x/health >/dev/null 2>&1 &&
        curl -sf -m 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
    kill -0 "$API_PID" 2>/dev/null || { cat "$ROOT/api.log"; refuse "the API exited"; }
    sleep 0.25
done
head -1 "$ROOT/api.log"

PASSED=0 FAILED=0
CHECKS=0
check() { # name, command... (each check's whole output: $RECEIPT/checks/N.out)
    local name=$1
    shift
    CHECKS=$((CHECKS + 1))
    mkdir -p "$RECEIPT/checks"
    if out=$("$@" 2>&1); then
        PASSED=$((PASSED + 1))
        printf '  ok   %s\n' "$name"
    else
        FAILED=$((FAILED + 1))
        printf '  FAIL %s\n%s\n' "$name" "$(printf '%s' "$out" | tail -20 | sed 's/^/       /')"
    fi
    printf '%s\n' "$out" >"$RECEIPT/checks/$CHECKS.out"
    printf '%s\t%s\t%s\n' "$CHECKS" "$name" "$(printf '%s' "$out" | tr '\n\t' '  ' | cut -c1-400)" >>"$RECEIPT/checks.tsv"
}
expect() { # needle, command... : the command's output contains needle
    local needle=$1
    shift
    local got
    got=$("$@" 2>&1) || true
    printf '%s\n' "$got"
    case "$got" in *"$needle"*) return 0 ;; *) return 1 ;; esac
}
TCP=http://127.0.0.1:$PORT
SOCK=$MICROPOD_API_SOCK
ping='{}'

echo "curl $(curl --version | head -1 | cut -d' ' -f2)"
check "curl h2c GET /health (unix)" expect 'HTTP/2 200' curl -si --http2-prior-knowledge --unix-socket "$SOCK" http://localhost/health
check "curl h2c GET /health (tcp)" expect 'HTTP/2 200' curl -si --http2-prior-knowledge "$TCP/health"
check "curl h2c GET /v1/system (tcp)" expect '"status"' curl -s --http2-prior-knowledge "$TCP/v1/system"
check "curl h2c Connect JSON Ping (unix)" expect '"status"' curl -s --http2-prior-knowledge --unix-socket "$SOCK" \
    -H 'Content-Type: application/json' -d "$ping" http://localhost/api/micropod.v1.SystemService/Ping
check "curl h2c Connect JSON Ping (tcp)" expect '"status"' curl -s --http2-prior-knowledge \
    -H 'Content-Type: application/json' -d "$ping" "$TCP/api/micropod.v1.SystemService/Ping"
check "curl --http2 (Upgrade) still answers HTTP/1.1" expect 'HTTP/1.1 200' curl -si --http2 "$TCP/health"
check "curl HTTP/1.1 unchanged on the same port" expect 'HTTP/1.1 200' curl -si "$TCP/health"
check "curl h2c foreign Host refused 403 (tcp)" expect 'HTTP/2 403' curl -si --http2-prior-knowledge \
    -H "Host: evil.example:$PORT" "$TCP/health"
if [ -n "$CONTAINER" ]; then
    check "curl h2c SSE logs (tcp)" expect 'data:' curl -s -m 3 --http2-prior-knowledge \
        "$TCP/v1/containers/$CONTAINER/logs?tail=2"
fi

if command -v buf >/dev/null; then
    (cd "$REPO" && buf build -o "$ROOT/micropod.binpb")
    check "buf curl gRPC Ping (tcp)" expect '"status"' buf curl --http2-prior-knowledge --protocol grpc \
        --schema "$ROOT/micropod.binpb" -d "$ping" "$TCP/micropod.v1.SystemService/Ping"
    check "buf curl Connect Ping over h2c (tcp)" expect '"status"' buf curl --http2-prior-knowledge \
        --protocol connect --schema "$ROOT/micropod.binpb" -d "$ping" "$TCP/api/micropod.v1.SystemService/Ping"
fi
if command -v grpcurl >/dev/null && [ -f "$ROOT/micropod.binpb" ]; then
    echo "$(grpcurl -version 2>&1)"
    check "grpcurl Ping (tcp)" expect '"status"' grpcurl -plaintext -protoset "$ROOT/micropod.binpb" -d "$ping" \
        "127.0.0.1:$PORT" micropod.v1.SystemService/Ping
    check "grpcurl Ping (unix)" expect '"status"' grpcurl -plaintext -protoset "$ROOT/micropod.binpb" -d "$ping" \
        "unix://$SOCK" micropod.v1.SystemService/Ping
    check "grpcurl without reflection is told so at once" expect 'does not support the reflection API' \
        grpcurl -plaintext -max-time 5 "127.0.0.1:$PORT" list
    if [ -n "$CONTAINER" ]; then
        check "grpcurl server stream (unix)" expect '"text"' grpcurl -plaintext -protoset "$ROOT/micropod.binpb" \
            -d "{\"id\":\"$CONTAINER\",\"tail\":3,\"no_follow\":true}" "unix://$SOCK" \
            micropod.v1.ContainerService/StreamContainerLogs
    fi
fi

echo "grpc-go and connect-go (sdk/go interop tests)"
check "go interop (grpc-go, connect-go)" env MICROPOD_INTEROP_SOCK="$SOCK" MICROPOD_INTEROP_TCP="127.0.0.1:$PORT" \
    MICROPOD_INTEROP_CONTAINER="$CONTAINER" bash -c "cd '$REPO/sdk/go' && go test -count=1 -tags interop -run 'Interop' -skip LogFlood -v ."
if [ -n "$CONTAINER" ] && [ "$FLOOD" -gt 0 ]; then
    check "grpc-go ${FLOOD}s log flood, no GOAWAY" env MICROPOD_INTEROP_SOCK="$SOCK" MICROPOD_INTEROP_TCP="127.0.0.1:$PORT" \
        MICROPOD_INTEROP_CONTAINER="$CONTAINER" MICROPOD_INTEROP_FLOOD_SECONDS="$FLOOD" \
        bash -c "cd '$REPO/sdk/go' && go test -count=1 -tags interop -run 'LogFlood' -timeout $((FLOOD * 3 + 60))s -v ."
fi
check "the API still answers HTTP/1.1 after all of it" expect '"status":"ok"' curl -s --unix-socket "$SOCK" http://x/health

kill "$API_PID" 2>/dev/null || true
wait "$API_PID" 2>/dev/null || true
API_PID=""
peak=$(sed -n 's/.*peak \([0-9]*\) per.*/\1/p' "$ROOT/api.log" | sort -n | tail -1)
echo "peak control frames from one client in a 10 s window: ${peak:-none} (bound $(
    sed -n 's/.*controlFrames = RateLimit(count: \([0-9_]*\).*/\1/p' "$REPO/Sources/MicropodAPI/HTTP2/HTTP2Limits.swift"))"
printf 'peakControlFramesPer10s\t%s\n' "${peak:-}" >>"$RECEIPT/checks.tsv"
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" = 0 ]
