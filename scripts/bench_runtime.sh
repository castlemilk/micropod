#!/usr/bin/env bash
# bench_runtime.sh — measure Micropod runtime + helper footprint vs Docker Desktop.
#
#   cold    Micropod: `container system start` -> first `container list` OK
#           Docker :  `open -a Docker`        -> `docker info` OK
#   idle    RSS sum of micropod helper processes vs com.docker backend/VM procs,
#           plus optional idle-CPU sample via powermetrics (needs sudo).
#
# Usage: scripts/bench_runtime.sh [cold|idle|all]   (default: all)
#
# Notes:
# - Cold start STOPS both runtimes first (container system stop; quit Docker
#   via osascript). Docker Desktop must be installed for the docker rows.
# - Idle numbers assume each runtime has been running ~60s already.

set -uo pipefail

CONTAINER_CLI="${MICROPOD_CONTAINER_CLI_PATH:-/usr/local/bin/container}"
MODE="${1:-all}"

# Apple's CoreSimulator also runs containermanagerd copies — restrict to the
# real runtime's install paths so simulator processes aren't counted.
MICROPOD_PATTERN='MicropodAPI|micropod-docker-shim|micropod-sharedfs|^/usr/local/bin/container-apiserver|^/usr/local/libexec/container/|^/usr/libexec/containermanagerd'

micropod_procs() {
    # helper daemons + apple container daemons; app itself excluded (UI bench
    # is separate — these are the always-on runtime costs)
    pgrep -fl "$MICROPOD_PATTERN" || true
}

docker_procs() {
    pgrep -fl 'com.docker.backend|com.docker.virtualization|Docker Desktop|docker-desktop|vpnkit|com.docker.build' || true
}

rss_sum_kb() {  # sum RSS of PIDs matching a pattern
    local pattern="$1" total=0 pid rss
    for pid in $(pgrep -f "$pattern" || true); do
        rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
        [ -n "$rss" ] && total=$((total + rss))
    done
    echo "$total"
}

mb() { awk -v kb="$1" 'BEGIN { printf "%.0f MB", kb / 1024 }'; }

cold_micropod() {
    "$CONTAINER_CLI" system stop >/dev/null 2>&1 || true
    sleep 2
    local start end
    start=$(python3 -c 'import time; print(time.time())')
    "$CONTAINER_CLI" system start >/dev/null 2>&1
    until "$CONTAINER_CLI" list >/dev/null 2>&1; do sleep 0.1; done
    end=$(python3 -c 'import time; print(time.time())')
    awk -v a="$start" -v b="$end" 'BEGIN { printf "micropod cold start  : %.2f s\n", b - a }'
}

cold_docker() {
    command -v docker >/dev/null || { echo "docker cold start   : skipped (docker CLI absent)"; return; }
    pgrep -f "Docker Desktop|com.docker.backend" >/dev/null || {
        osascript -e 'quit app "Docker"' >/dev/null 2>&1 || true
    }
    osascript -e 'quit app "Docker"' >/dev/null 2>&1 || true
    sleep 3
    local start end tries=0
    start=$(python3 -c 'import time; print(time.time())')
    open -a Docker >/dev/null 2>&1 || { echo "docker cold start   : skipped (Docker.app absent)"; return; }
    until docker info >/dev/null 2>&1; do
        sleep 1; tries=$((tries + 1))
        [ "$tries" -gt 180 ] && { echo "docker cold start   : timed out after 180s"; return; }
    done
    end=$(python3 -c 'import time; print(time.time())')
    awk -v a="$start" -v b="$end" 'BEGIN { printf "docker cold start    : %.2f s\n", b - a }'
}

idle_report() {
    local mp dp
    mp=$(rss_sum_kb "$MICROPOD_PATTERN")
    dp=$(rss_sum_kb 'com.docker.backend|com.docker.virtualization|Docker Desktop|docker-desktop|vpnkit')
    echo "micropod idle RSS    : $(mb "$mp")"
    micropod_procs | sed 's/^/    /'
    if [ "$dp" -gt 0 ]; then
        echo "docker idle RSS      : $(mb "$dp")"
        docker_procs | sed 's/^/    /'
        awk -v a="$mp" -v b="$dp" 'BEGIN {
            if (a > 0) printf "ratio                : docker uses %.1fx the memory\n", b / a
        }'
    else
        echo "docker idle RSS      : skipped (Docker Desktop not running)"
    fi
}

echo "== runtime bench ($(date '+%Y-%m-%d %H:%M')) — mode: $MODE =="
case "$MODE" in
    cold) cold_micropod; cold_docker ;;
    idle) idle_report ;;
    all)  cold_micropod; cold_docker; echo; idle_report ;;
    *)    echo "unknown mode: $MODE (cold|idle|all)" >&2; exit 2 ;;
esac
