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
install -m 0755 "$root/ci/runner/start.sh" "$root/ci/runner/published-ports.sh" "$root/ci/runner/rootless.sh" "$runner/"
commit=$(git -C "$root" rev-parse HEAD 2>/dev/null || echo unknown)
dirty=false
if [ "$commit" != unknown ] && [ -n "$(git -C "$root" status --porcelain -- guest ci 2>/dev/null)" ]; then dirty=true; fi
# The shared Go build cache: no per-task GOCACHE, and -trimpath even when the
# caller's GOFLAGS replaces the machine-wide setting.
(cd "$root/guest/runner" && env -u GOROOT GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
    go build -trimpath -ldflags "-X main.engineCommit=$commit" -o "$runner/bin/job" .)
for need in bin/buildkitd bin/ctr bin/job buildkitd.toml start.sh; do
    [ -s "$runner/$need" ] || { echo "guest tool bundle is missing runner/$need" >&2; exit 1; }
done
# buildkitd is a linux binary; its Go build info names the BuildKit release.
buildkit=$(go version -m "$runner/bin/buildkitd" | awk '$1 == "mod" && $2 == "github.com/moby/buildkit" { print $3 }')
[[ $buildkit =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]] || { echo "cannot read the BuildKit version of runner/bin/buildkitd" >&2; exit 1; }
# The host reads this to tell what the bundle's engine supports. engineCommit
# is also the GitCommit of the engine's GET /version.
printf '{"engineCommit":"%s","engineDirty":%s,"cacheApi":1,"buildkit":"%s","capabilities":["caches","buildkit","grpc-build"]}\n' \
    "$commit" "$dirty" "$buildkit" >"$runner/manifest.json"
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
