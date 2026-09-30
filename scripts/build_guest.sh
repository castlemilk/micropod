#!/usr/bin/env bash
# Build micropod-guest (guest/): the static linux/arm64 helper that sandbox
# VMs run for file operations, watches and the idle main process.
#
#   scripts/build_guest.sh [OUT]   (default .build/guest/micropod-guest)
#
# Also copies it next to the dev executables (.build/<triple>/{debug,release})
# so `swift run MicropodAPI` and the e2e scripts find it without installing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/.build/guest/micropod-guest}"
# The build runs inside guest/: a relative OUT must not resolve there (the
# v0.11.0 release put the helper under guest/dist/ and failed).
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
mkdir -p "$(dirname "$OUT")"
(cd "$ROOT/guest" && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 GOFLAGS=-buildvcs=false \
    go build -trimpath -ldflags="-s -w -buildid=" -o "$OUT" .)
for dir in "$ROOT"/.build/arm64-apple-macosx/debug "$ROOT"/.build/arm64-apple-macosx/release; do
    if [ -d "$dir" ]; then cp "$OUT" "$dir/micropod-guest"; fi
done
echo "micropod-guest: $OUT ($(wc -c <"$OUT" | tr -d ' ') bytes)"
