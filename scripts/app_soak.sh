#!/bin/bash
# scripts/app_soak.sh — long-running crash hunt for the desktop app WITH its
# agents (shim, API, sharedfs) running, fully isolated from any installed
# Micropod: private endpoints, run dir, control socket and ports.
#
# Drives the soak app's own API with concurrent load (log streams opened and
# dropped mid-stream, stats, list, exec) and watches for:
#   - the app or any of its agents dying/respawning
#   - new crash reports for Micropod* processes
#   - any installed-app or launchd agent pid changing (isolation breach)
#
# Usage: scripts/app_soak.sh [minutes]      (default 20; needs `swift build`)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MINUTES="${1:-20}"
BIN="$ROOT/.build/debug/MicropodApp"
DIR="$(mktemp -d)"
API_PORT="${SOAK_API_PORT:-45993}"
REPORTS="$HOME/Library/Logs/DiagnosticReports"

export MICROPOD_API_PORT="$API_PORT"
export MICROPOD_SHIM_TCP_PORT="${SOAK_SHIM_TCP_PORT:-45992}"
export MICROPOD_APP_CONTROL_SOCKET="$DIR/app-control.sock"
export MICROPOD_AGENT_RUN_DIR="$DIR/run"
export MICROPOD_SHIM_SOCKET="$DIR/docker.sock"
export MICROPOD_SHAREDFS_SOCKET="$DIR/sharedfs.sock"
export MICROPOD_SHAREDFS_CACHE="$DIR/share-cache"
export MICROPOD_RUNTIMES_CONFIG="$DIR/runtimes.json"
export MICROPOD_VOLUME_POLICY="$DIR/policy.json"

TARGETS=(soak-log-1 soak-log-2)
cleanup() {
    [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null && wait "$APP_PID" 2>/dev/null || true
    for t in "${TARGETS[@]}"; do container rm -f "$t" >/dev/null 2>&1 || true; done
    # Keep app + agent logs when the soak found something.
    if [ "${fail:-0}" -eq 0 ]; then rm -rf "$DIR"; else echo "logs kept in $DIR"; fi
}
trap cleanup EXIT

outside_pids() { # every Micropod* agent not in our process tree, plus launchd's
    pgrep -f 'Micropod.app/Contents/MacOS|connect/bin/MicropodAPI' | sort | tr '\n' ' '
}
crash_count() { ls "$REPORTS" 2>/dev/null | grep -c '^Micropod' || true; }

for t in "${TARGETS[@]}"; do
    container rm -f "$t" >/dev/null 2>&1 || true
    container run -d --name "$t" alpine:3.20 sh -c 'while true; do echo tick; sleep 0.2; done' >/dev/null
done

BASE_OUTSIDE="$(outside_pids)"
BASE_CRASHES="$(crash_count)"
"$BIN" >"$DIR/app.log" 2>&1 &
APP_PID=$!

for _ in $(seq 1 60); do
    curl -sf "http://127.0.0.1:$API_PORT/health" >/dev/null && break
    sleep 1
done
curl -sf "http://127.0.0.1:$API_PORT/health" >/dev/null || { echo "FAIL: soak API never came up"; exit 1; }
agent_pids() { # pid files are single JSON objects without a trailing newline
    python3 -c 'import sys,json; print(" ".join(sorted(str(json.load(open(f))["pid"]) for f in sys.argv[1:])))' "$DIR"/run/*.pid 2>/dev/null
}
sleep 5
BASE_AGENTS="$(agent_pids)"
echo "soak app pid $APP_PID, agents [$BASE_AGENTS], outside [$BASE_OUTSIDE], ${MINUTES}m"

python3 "$ROOT/scripts/soak_load.py" "$API_PORT" "$((MINUTES * 60))" "$(IFS=,; echo "${TARGETS[*]}")" &
LOAD_PID=$!

fail=0
end=$(($(date +%s) + MINUTES * 60))
while [ "$(date +%s)" -lt "$end" ]; do
    sleep 15
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        wait "$APP_PID"; rc=$?
        # >128 = killed by signal (rc-128); 134 = SIGABRT (a crash report follows).
        echo "FAIL: app died (wait status $rc$([ "$rc" -gt 128 ] && echo ", signal $((rc - 128))"))"
        APP_PID=""; fail=1; break
    fi
    now_agents="$(agent_pids)"
    [ "$now_agents" != "$BASE_AGENTS" ] && { echo "WARN: agent respawn [$BASE_AGENTS] -> [$now_agents]"; BASE_AGENTS="$now_agents"; fail=1; }
    now_outside="$(outside_pids)"
    [ "$now_outside" != "$BASE_OUTSIDE" ] && { echo "FAIL: outside pids changed [$BASE_OUTSIDE] -> [$now_outside]"; BASE_OUTSIDE="$now_outside"; fail=1; }
    [ "$(crash_count)" != "$BASE_CRASHES" ] && { echo "FAIL: new crash report(s):"; ls -t "$REPORTS" | grep '^Micropod' | head -3; BASE_CRASHES="$(crash_count)"; fail=1; }
done
wait "$LOAD_PID" || true

if [ -n "$APP_PID" ]; then
    kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; rc=$?
    echo "app exit status on SIGTERM: $rc"
    [ "$rc" -eq 134 ] && fail=1
fi
sleep 2
[ "$(crash_count)" != "$BASE_CRASHES" ] && { echo "FAIL: crash report on exit"; fail=1; }
[ "$fail" -eq 0 ] && echo "PASS: ${MINUTES}m soak — no crashes, no respawns, isolation held" || echo "SOAK FOUND PROBLEMS"
exit "$fail"
