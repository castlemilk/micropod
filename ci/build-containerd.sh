#!/bin/bash
# ci/build-containerd.sh OUT: the runner's containerd, built from its release
# source with Micropod's patches (ci/patches/containerd/*.patch, in order).
#
# Pinned: the module (its go.sum hash, checked here and by the Go checksum
# database), the Go toolchain the release used, the build tags and flags of
# the release binary nerdctl-full 2.4.2 ships (`go version -m` of it), and
# CGO off. The same inputs give the same binary.
#
# The patches:
#   0001 the overlay snapshotter mounts an active snapshot labelled
#        containerd.io/snapshot/overlay.volatile=true with the volatile
#        option, and CRI gives a container's snapshot that label from the
#        container's annotation of the same name (guest/runner
#        rootfs_volatile_linux.go says which containers ask).
#   0002 group commit: concurrent updates of container, sandbox and lease
#        records share one bbolt transaction, and each caller still returns
#        only after the transaction that holds its update has committed
#        (docs/containerd-group-commit.md has the durability argument).
#   0003 a pod's annotation io.micropod.sandbox.cpu-shares sets its sandbox's
#        CPU shares in place of CRI's minimum of 2 (cgroup v2 weight 1), in
#        which crun's init sets the pod up (guest/runner
#        sandbox_shares_linux.go says which pods ask and for what).
#
# Environment: MICROPOD_CONTAINERD_GOTOOLCHAIN (default the release's
# go1.26.10) for a toolchain that is already installed.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:?output path}
# The build runs in the source copy: an output path relative to the caller's
# directory is made absolute first.
out="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"
module=github.com/containerd/containerd/v2
version=v2.4.2
revision=b7a25261e029d68978bbf290df0a62fc819b3c51
sum='h1:p6Qg+xbEz8lvwdhHDx0U469xENvp4LgGBx+E7djXkGw='
toolchain=${MICROPOD_CONTAINERD_GOTOOLCHAIN:-go1.26.10}
patches=("$root"/ci/patches/containerd/*.patch)

info=$(cd / && env -u GOROOT GOFLAGS=-mod=mod go mod download -json "$module@$version")
dir=$(printf '%s' "$info" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["Dir"] if d.get("Sum")==sys.argv[1] else "")' "$sum")
[ -n "$dir" ] && [ -d "$dir" ] || { echo "containerd $version: module sum differs from $sum" >&2; exit 1; }

src=$(mktemp -d)
trap 'chmod -R u+w "$src" 2>/dev/null; rm -rf "$src"' EXIT
cp -R "$dir/." "$src/"
chmod -R u+w "$src"
for p in "${patches[@]}"; do
    patch -d "$src" -p1 --forward --quiet <"$p" || { echo "containerd patch $(basename "$p") does not apply" >&2; exit 1; }
done
ldflags="-s -w -X $module/version.Version=$version+micropod -X $module/version.Revision=$revision -X $module/version.Package=$module"
(cd "$src" && env -u GOROOT GOTOOLCHAIN="$toolchain" GOOS=linux GOARCH=arm64 GOARM64=v8.0 CGO_ENABLED=0 GOFLAGS=-trimpath \
    go build -mod=readonly -buildvcs=false -tags urfave_cli_no_docs,osusergo,netgo,static_build -ldflags "$ldflags" \
    -o "$out" ./cmd/containerd)
chmod 0755 "$out"
