#!/bin/bash
# ci/lib.sh — shared plumbing for the micropod CI pipelines.
#
# Each pipeline boots an ISOLATED micropod-docker-shim (own socket, TCP port
# and state file under a temp dir) so validation runs never disturb the
# user's launchd-managed shim, then drives it with the stock `docker` CLI
# (legacy builder: DOCKER_BUILDKIT=0) exactly like cuttlefish's
# dev-up-micropod target does.
#
# Usage:
#   source "$(dirname "$0")/lib.sh"
#   ci_shim_up          # sets DOCKER_HOST, SHIM_LOG, CI_TMP
#   ci_stage "name" cmd args...   # timed stage with PASS/FAIL + log
#   ci_summary          # total wall time + PASS banner
#   # cleanup is automatic via trap (kills shim, force-rms CI containers)
set -euo pipefail

CI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MICROPOD_ROOT="$(cd "$CI_ROOT/.." && pwd)"
SHIM_BIN="${MICROPOD_SHIM_BIN:-$MICROPOD_ROOT/.build/debug/micropod-docker-shim}"

# Container/image name prefix for this run (namespaced per pipeline file).
CI_NS="${CI_NS:-ci}"

ci_cleanup() {
    # Best-effort: remove this run's containers/images, stop the temp shim,
    # drop the temp dir. Never fail the pipeline from cleanup.
    if [ -n "${DOCKER_HOST:-}" ]; then
        docker rm -f $(docker ps -aq --filter "name=${CI_NS}-" 2>/dev/null) >/dev/null 2>&1 || true
    fi
    if [ -n "${CI_SHIM_PID:-}" ]; then
        kill "$CI_SHIM_PID" 2>/dev/null || true
    fi
    if [ -n "${CI_TMP:-}" ] && [ -d "$CI_TMP" ]; then
        rm -rf "$CI_TMP"
    fi
}

ci_shim_up() {
    if [ ! -x "$SHIM_BIN" ]; then
        echo "building micropod-docker-shim (one time)..." >&2
        (cd "$MICROPOD_ROOT" && swift build --product micropod-docker-shim >&2) || {
            echo "FATAL: cannot build shim" >&2
            exit 1
        }
    fi
    CI_TMP="$(mktemp -d)"
    CI_TCP_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
    export DOCKER_HOST="unix://$CI_TMP/docker.sock"
    export DOCKER_BUILDKIT=0
    export SHIM_LOG="$CI_TMP/shim.log"
    trap ci_cleanup EXIT
    MICROPOD_SHIM_SOCKET="$CI_TMP/docker.sock" \
        MICROPOD_SHIM_TCP_PORT="$CI_TCP_PORT" \
        MICROPOD_SHIM_STATE="$CI_TMP/shim-state.json" \
        nohup "$SHIM_BIN" >"$SHIM_LOG" 2>&1 &
    CI_SHIM_PID=$!
    # Wait for the socket to answer _ping (up to 15s).
    for _ in $(seq 1 150); do
        if [ -S "$CI_TMP/docker.sock" ] && docker version >/dev/null 2>&1; then
            break
        fi
        sleep 0.1
    done
    docker version >/dev/null 2>&1 || {
        echo "FATAL: temp shim never came up; log:" >&2
        tail -n 20 "$SHIM_LOG" >&2
        exit 1
    }
    echo "shim up: $DOCKER_HOST (tcp $CI_TCP_PORT, log $SHIM_LOG)" >&2
}

CI_T0=0
ci_begin() {
    CI_T0=$(python3 -c "import time; print(time.time())")
}

# ci_stage "name" -- cmd...  (times, echoes, fails the pipeline on error)
ci_stage() {
    local name="$1"
    shift
    echo "--- stage: $name ---"
    local start end
    start=$(python3 -c "import time; print(time.time())")
    if "$@"; then
        end=$(python3 -c "import time; print(time.time())")
        python3 -c "print('PASS $name in %.1fs' % ($end-$start))"
    else
        end=$(python3 -c "import time; print(time.time())")
        python3 -c "print('FAIL $name after %.1fs' % ($end-$start))"
        return 1
    fi
}

ci_summary() {
    local end
    end=$(python3 -c "import time; print(time.time())")
    python3 -c "print('== PIPELINE PASS in %.1fs == ' % ($end-$CI_T0))"
}

# Print HIT/MISS lines the shim logged for build stages (cache re-use proof).
ci_cache_lines() {
    grep -h "context-cache" "$SHIM_LOG" 2>/dev/null | tail -n 5 || true
}
