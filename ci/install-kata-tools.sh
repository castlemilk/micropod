#!/bin/bash
# Install only the optional ARM64 QEMU runtime in an operator-owned tools directory.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
parent=${1:?directory for the versioned Kata tools}
mkdir -p "$parent"
parent=$(cd "$parent" && pwd -P)
dest="$parent/kata-go-4.4.0-arm64"
if [[ -e "$dest" ]]; then echo "Kata tools already exist at $dest" >&2; exit 1; fi
downloads=${MICROPOD_GUEST_DOWNLOADS:-$root/.build/oci-downloads}
bundle="$downloads/kata-go-static-4.4.0-arm64.tar.zst"
bash "$root/ci/fetch-guest-artifact.sh" https://github.com/kata-containers/kata-containers/releases/download/4.4.0/kata-go-static-4.4.0-arm64.tar.zst \
    904e09007f439c6619d9122cd25057d04db61a1b6805a728295c4f02813fb1a4 "$bundle" "${MICROPOD_KATA_ARCHIVE:-}"
stage=$(mktemp -d "$parent/.kata.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
tar -xf "$bundle" -C "$stage" \
    ./opt/kata/bin/containerd-shim-kata-v2 ./opt/kata/bin/qemu-system-aarch64 ./opt/kata/libexec/virtiofsd \
    ./opt/kata/share/kata-containers/kata-ubuntu-resolute.image ./opt/kata/share/kata-containers/kata-containers.img \
    ./opt/kata/share/kata-containers/vmlinux-6.18.62-211 ./opt/kata/share/kata-containers/vmlinux.container \
    ./opt/kata/share/aavmf ./opt/kata/share/kata-qemu \
    ./opt/kata/share/defaults/kata-containers/configuration-qemu.toml ./opt/kata/share/defaults/kata-containers/configuration.toml
mv "$stage/opt/kata" "$dest"
printf '%s\n' "$dest"
