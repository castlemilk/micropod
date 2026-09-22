#!/bin/bash
# Compose startup benchmark: identical postgres:16 compose stack, started via
# Micropod's compose pipeline (Apple `container` runtime) vs Docker Desktop.
#
# Measures wall time from "compose up" to *ready*: Micropod's stream completes
# only after its real healthcheck readiness probe passes; Docker uses
# `up -d --wait`, which waits for the container healthcheck.
#
# Every run uses a unique project name on BOTH runtimes so a stale container
# can never block a run, and each phase tears down before and after.
#
# Usage: scripts/bench_compose_startup.sh [runs]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
RUNS="${1:-3}"

# macOS ships no `timeout(1)` — fall back to a python3-based implementation
# with the same `timeout <secs> <cmd...>` interface (exit 124 on expiry,
# like GNU timeout) so `task bench-compose` works on stock macOS.
if ! command -v timeout >/dev/null 2>&1; then
    timeout() {
        local duration="$1"
        shift
        python3 -c '
import subprocess, sys
try:
    p = subprocess.run(sys.argv[2:], timeout=float(sys.argv[1]))
    sys.exit(p.returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
' "$duration" "$@"
    }
fi

swift build --product MicropodMCP >/dev/null 2>&1
MCP="$ROOT/.build/debug/MicropodMCP"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- Apple runtime (Micropod compose pipeline via MCP) ----------------------

micropod_up() {
    local run="$1"
    local dir="$WORK/apple-$run"
    mkdir -p "$dir"
    cat > "$dir/docker-compose.yml" <<EOF
name: micropod-bench-$run
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_PASSWORD: bench
    healthcheck:
      test: ["CMD", "/usr/lib/postgresql/16/bin/pg_isready", "-U", "postgres"]
      interval: 1s
      timeout: 2s
      retries: 60
      start_period: 3s
    stop_grace_period: 10s
EOF
    local start end ok
    start=$(date +%s.%N)
    ok=$(printf '%s\n' \
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"compose_up\",\"arguments\":{\"path\":\"$dir/docker-compose.yml\"}}}" \
        | timeout 600 "$MCP" \
        | python3 -c "import json,sys
line=sys.stdin.readline()
r=json.loads(line)
print('ok' if not r.get('error') and not r.get('result',{}).get('isError') else 'FAIL')")
    end=$(date +%s.%N)
    if [ "$ok" != "ok" ]; then
        echo "FAIL"
        return 1
    fi
    echo "$end - $start" | bc
}

micropod_down() {
    local run="$1"
    printf '%s\n' \
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"compose_down\",\"arguments\":{\"name\":\"micropod-bench-$run\"}}}" \
        | timeout 120 "$MCP" >/dev/null 2>&1 || true
}

# --- Docker Desktop ----------------------------------------------------------

docker_up() {
    local run="$1"
    local dir="$WORK/docker-$run"
    mkdir -p "$dir"
    cat > "$dir/docker-compose.yml" <<EOF
name: micropod-bench-$run
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_PASSWORD: bench
    healthcheck:
      test: ["CMD", "/usr/lib/postgresql/16/bin/pg_isready", "-U", "postgres"]
      interval: 1s
      timeout: 2s
      retries: 60
      start_period: 3s
    stop_grace_period: 10s
EOF
    docker compose -f "$dir/docker-compose.yml" down --remove-orphans >/dev/null 2>&1 || true
    local start end
    start=$(date +%s.%N)
    if ! timeout 300 docker compose -f "$dir/docker-compose.yml" up -d --wait --quiet-pull >/dev/null 2>&1; then
        docker compose -f "$dir/docker-compose.yml" down -v --remove-orphans >/dev/null 2>&1 || true
        echo "FAIL"
        return 1
    fi
    end=$(date +%s.%N)
    echo "$end - $start" | bc
}

docker_down() {
    local run="$1"
    docker compose -f "$WORK/docker-$run/docker-compose.yml" down -v --remove-orphans >/dev/null 2>&1 || true
}

# --- Run ---------------------------------------------------------------------

echo "postgres:16 compose startup (seconds to ready)"
echo "=============================================="
printf "%-14s %-10s %-10s\n" "run" "micropod" "docker"

# Docker daemon pre-check (it has proven unstable under load on this box).
if ! timeout 5 docker info >/dev/null 2>&1; then
    echo "NOTE: Docker daemon unreachable — docker column will report FAIL."
fi

apple_times=()
docker_times=()
for i in $(seq 1 "$RUNS"); do
    apple=$(micropod_up "$i" || echo "FAIL")
    micropod_down "$i"
    docker_t=$(docker_up "$i" || echo "FAIL")
    docker_down "$i"
    printf "%-14s %-10s %-10s\n" "run-$i" "$apple" "$docker_t"
    apple_times+=("$apple")
    docker_times+=("$docker_t")
done

echo "=============================================="
median() {
    printf '%s\n' "$@" | sort -n | awk '{ a[NR]=$1 } END { if (NR%2) print a[(NR+1)/2]; else print (a[NR/2]+a[NR/2+1])/2 }'
}
am=$(median "${apple_times[@]}")
dm=$(median "${docker_times[@]}")
echo "median: micropod=$am s  docker=$dm s"
