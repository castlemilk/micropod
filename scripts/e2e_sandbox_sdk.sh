#!/usr/bin/env bash
# scripts/e2e_sandbox_sdk.sh — the TypeScript SDK's Sandbox class against a
# real MicropodAPI: boot, exec/spawn with stdin and signals, files, mounts,
# watch, checkpoints (sdk/ts/test/sandbox.e2e.mjs).
#
# Boots a signed debug MicropodAPI on a scratch port with an isolated engine
# config, so the daemon on :45454 (and its sandboxes) are untouched.
# Needs `swift build --product MicropodAPI` and node ≥ 18.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
API_BIN="$ROOT/.build/debug/MicropodAPI"
PORT="${E2E_PORT:-45988}"
TMP="$(mktemp -d)"

cleanup() {
    [ -n "${API_PID:-}" ] && kill "$API_PID" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

codesign --force --sign - --entitlements "$ROOT/signing/micropod-cli.entitlements" "$API_BIN" 2>/dev/null
MICROPOD_API_PORT="$PORT" MICROPOD_RUNTIMES_CONFIG="$TMP/runtimes.json" "$API_BIN" >"$TMP/api.log" 2>&1 &
API_PID=$!
for _ in $(seq 1 50); do
    curl -sf "http://127.0.0.1:$PORT/health" >/dev/null && break
    sleep 0.2
done

cd "$ROOT/sdk/ts"
[ -d node_modules ] || npm ci --no-audit --no-fund --loglevel=error
npm run --silent build
MICROPOD_API="http://127.0.0.1:$PORT" node test/sandbox.e2e.mjs || {
    echo "--- api log" >&2
    tail -40 "$TMP/api.log" >&2
    exit 1
}
