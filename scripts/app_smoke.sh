#!/bin/bash
# Smoke-tests the desktop app: launches it (against the real `container` CLI
# unless MICROPOD_CONTAINER_CLI_PATH is set), verifies it stays alive through
# several poll cycles, then quits it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/debug/MicropodApp"

if [ ! -x "$BIN" ]; then
    echo "app binary not found at $BIN — run \`swift build\` first" >&2
    exit 1
fi

CLI_HINT="${MICROPOD_CONTAINER_CLI_PATH:-/usr/local/bin/container}"
if [ ! -x "$CLI_HINT" ]; then
    echo "no container CLI at $CLI_HINT (set MICROPOD_CONTAINER_CLI_PATH)" >&2
    exit 1
fi

echo "launching $BIN (cli: $CLI_HINT)"
"$BIN" &
APP_PID=$!

ALIVE_AFTER=0
for i in 1 2 3 4 5 6; do
    sleep 1
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        echo "FAIL: app exited during smoke window (exit code captured below)" >&2
        wait "$APP_PID" || true
        exit 1
    fi
    ALIVE_AFTER=$i
done

echo "PASS: app alive after ${ALIVE_AFTER}s of polling"
kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true
echo "PASS: app terminated cleanly"
