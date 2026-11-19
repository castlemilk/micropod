#!/bin/bash
# Qualify live OrbStack first, then compare the Micropod release binary on the same Mac.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/.build/benchmarks/apple}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
cd "$root"
peer="${MICROPOD_BENCH_ORBSTACK_SOCKET:-$HOME/.orbstack/run/docker.sock}"
image="alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc"
unset DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH BUILDX_BUILDER
if ! docker --host "unix://$peer" image inspect "$image" >/dev/null 2>&1; then
    docker --host "unix://$peer" pull "$image"
fi
if ! python3 scripts/bench_live_kernel.py --engine orbstack --socket "$peer" --image "$image" --json "$out/orbstack.json"; then
    echo "OrbStack qualification recorded a failure; continuing to the worker check" >&2
fi
echo "OrbStack receipt: $out/orbstack.json"
if [[ -n "${MICROPOD_BENCH_BIN:-}" ]]; then
    bin="$MICROPOD_BENCH_BIN"
else
    swift build -c release --product micropod
    bin="$root/.build/release/micropod"
    codesign -f -s - --entitlements signing/micropod-cli.entitlements "$bin"
    codesign --verify --strict "$bin"
fi
python3 scripts/qualify_ci_worker.py apple-worker --micropod "$bin" --orbstack-socket "$peer" --json "$out/apple-pair.json"
echo "Paired receipt: $out/apple-pair.json"
