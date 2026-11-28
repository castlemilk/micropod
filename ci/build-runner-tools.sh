#!/bin/bash
# The runner uses standalone containerd, its OCI shim and crun. No engine is needed to build it.
# containerd itself is built from its release source with Micropod's patches
# (ci/build-containerd.sh); the shim, ctr, BuildKit and the CNI plugins are
# the nerdctl-full bundle's.
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
members=(bin/containerd-shim-runc-v2 bin/ctr bin/buildkitd)
if "$allocation"; then members+=(bin/rootlesskit); fi
for plugin in bridge macvlan host-local loopback; do members+=("libexec/cni/$plugin"); done
tar -xzf "$bundle" -C "$stage" "${members[@]}"
install -m 0755 "$stage"/bin/* "$runner/bin/"
bash "$root/ci/build-containerd.sh" "$runner/bin/containerd"
install -m 0755 "$stage"/libexec/cni/* "$root/ci/runner/micropod-bridge" "$runner/cni/"
install -m 0644 "$root"/ci/runner/*.toml "$root"/ci/runner/*.conflist "$runner/"
install -m 0755 "$root/ci/runner/start.sh" "$root/ci/runner/published-ports.sh" "$root/ci/runner/rootless.sh" "$runner/"
# The x86-64 emulator for linux/amd64 containers (guest/runner/emulation_linux.go).
if ! "$allocation"; then
    MICROPOD_GUEST_DOWNLOADS="$downloads" bash "$root/ci/fetch-qemu-user.sh" "$runner/emulators"
fi
commit=$(git -C "$root" rev-parse HEAD 2>/dev/null || echo unknown)
dirty=false
if [ "$commit" != unknown ] && [ -n "$(git -C "$root" status --porcelain -- guest ci 2>/dev/null)" ]; then dirty=true; fi
# The shared Go build cache: no per-task GOCACHE, and -trimpath even when the
# caller's GOFLAGS replaces the machine-wide setting.
(cd "$root/guest/runner" && env -u GOROOT GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
    go build -trimpath -ldflags "-X main.engineCommit=$commit" -o "$runner/bin/job" .)
needs=(bin/containerd bin/buildkitd bin/ctr bin/job buildkitd.toml start.sh)
if ! "$allocation"; then needs+=(emulators/qemu-x86_64 emulators/qemu-x86_64.copyright emulators/SOURCE); fi
for need in "${needs[@]}"; do
    [ -s "$runner/$need" ] || { echo "guest tool bundle is missing runner/$need" >&2; exit 1; }
done
# buildkitd is a linux binary; its Go build info names the BuildKit release.
buildkit=$(go version -m "$runner/bin/buildkitd" | awk '$1 == "mod" && $2 == "github.com/moby/buildkit" { print $3 }')
[[ $buildkit =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]] || { echo "cannot read the BuildKit version of runner/bin/buildkitd" >&2; exit 1; }
# The host reads this to tell what the bundle's engine supports. engineCommit
# is also the GitCommit of the engine's GET /version.
capabilities='"caches","buildkit","grpc-build"'
# The bundle ships the x86-64 emulator; the engine says per boot whether it runs (machine.json amd64).
if [ -x "$runner/emulators/qemu-x86_64" ]; then capabilities="$capabilities"',"platform-linux-amd64"'; fi
printf '{"engineCommit":"%s","engineDirty":%s,"cacheApi":1,"buildkit":"%s","capabilities":[%s]}\n' \
    "$commit" "$dirty" "$buildkit" "$capabilities" >"$runner/manifest.json"
chmod 0644 "$runner/manifest.json"
# Replace the generated directory so older tool or config files cannot leak into the bundle.
mkdir -p "$out/guest"
rm -rf "$out/guest/runner"
mv "$runner" "$out/guest/runner"
# e2fsprogs for `micropod machine disk grow` (guest init grows a cloned disk
# with them in a maintenance boot).
if ! "$allocation"; then
    MICROPOD_GUEST_DOWNLOADS="$downloads" bash "$root/ci/fetch-e2fsprogs.sh" "$out/guest/e2fsprogs"
fi
