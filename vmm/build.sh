#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "=== Building and signing micropod-vmm (release) ==="
cargo build --release
codesign --sign - --entitlements entitlements.plist --force target/release/micropod-vmm

echo "=== Building Linux arm64 static mp-hvf-init + initramfs ==="
(cd guest-init && env -u GOROOT GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -ldflags="-s -w" -o "$ROOT/target/mp-hvf-init" .)
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$ROOT/target/mp-hvf-init" "$TMP/init"
chmod 755 "$TMP/init"
(cd "$TMP" && echo "init" | cpio -o -H newc --quiet > "$ROOT/target/mp-hvf-init.cpio")
ls -lh "$ROOT/target/release/micropod-vmm" "$ROOT/target/mp-hvf-init.cpio"
