#!/bin/bash
# The runner uses standalone containerd, its OCI shim and crun. No engine is needed to build it.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
allocation=false
if [[ ${1:-} == --allocation ]]; then allocation=true; shift; fi
out=${1:-$root/.build/oci-tools}
if "$allocation"; then
    # A private allocation uses local Unix sockets inside its own VM.
    mkdir -p "$out/guest"
    bash "$root/ci/fetch-crun.sh" "$out/guest/crun-1.31-arm64"
    chmod 0755 "$out/guest/crun-1.31-arm64"
else
    bash "$root/ci/build-oci-service.sh" "$out"
fi
out=$(cd "$out" && pwd -P)
downloads=${MICROPOD_GUEST_DOWNLOADS:-$root/.build/oci-downloads}
bundle="$downloads/nerdctl-full-2.4.2-linux-arm64.tgz"
bash "$root/ci/fetch-guest-artifact.sh" https://github.com/containerd/nerdctl/releases/download/v2.4.2/nerdctl-full-2.4.2-linux-arm64.tar.gz \
    fe0ef0e9840ee8932640e6058f84b7fa98050f9726e44af44883a5b804ae830e "$bundle" "${MICROPOD_NERDCTL_ARCHIVE:-}"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
runner="$stage/runner"
mkdir -p "$runner/bin" "$runner/cni"
members=(bin/containerd bin/containerd-shim-runc-v2 bin/ctr bin/buildkitd)
if "$allocation"; then members+=(bin/rootlesskit); fi
for plugin in bridge macvlan host-local loopback; do members+=("libexec/cni/$plugin"); done
tar -xzf "$bundle" -C "$stage" "${members[@]}"
install -m 0755 "$stage"/bin/* "$runner/bin/"
install -m 0755 "$stage"/libexec/cni/* "$runner/cni/"
install -m 0644 "$root"/ci/runner/*.toml "$root"/ci/runner/*.conflist "$runner/"
install -m 0755 "$root/ci/runner/start.sh" "$root/ci/runner/rootless.sh" "$runner/"
(cd "$root/guest/runner" && env -u GOROOT GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -o "$runner/bin/job" .)
# Replace the generated directory so older tool or config files cannot leak into the bundle.
mkdir -p "$out/guest"
rm -rf "$out/guest/runner"
mv "$runner" "$out/guest/runner"
