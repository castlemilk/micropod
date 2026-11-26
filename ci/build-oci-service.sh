#!/bin/bash
# Native transport client, guest service, executor and the pinned standalone OCI runtime.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/.build/oci-tools}"
mkdir -p "$out/guest"
out="$(cd "$out" && pwd -P)"
bash "$root/ci/fetch-crun.sh" "$out/guest/crun-1.31-arm64"
chmod 0755 "$out/guest/crun-1.31-arm64"
manifest="$root/guest/oci-service/Cargo.toml"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$root/.build/oci-cargo}"
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=rust-lld
cargo build --locked --manifest-path "$manifest" --release
cargo build --locked --manifest-path "$manifest" --release --target aarch64-unknown-linux-musl
install -m 0755 "$CARGO_TARGET_DIR/release/micropod-oci" "$out/client"
install -m 0755 "$CARGO_TARGET_DIR/aarch64-unknown-linux-musl/release/micropod-oci" "$out/guest/service"
(cd "$root/guest" && env -u GOROOT GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -o "$out/guest/executor" ./cmd/oci-batch)
