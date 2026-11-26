#!/bin/sh
# Build Linux 7.3.5 16 KiB ARM64 worker kernel with B5 patches + upstream splice +
# VIRTIO_FS_F_NOTIFICATION + default-on workspace_async_release.
set -eu

inputs=$(realpath "${1:?pinned input directory}")
out=${2:?new absolute output directory}
patches=$(dirname "$(realpath "$0")")
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = aarch64 ] || {
    echo 'Build on ARM64 Linux' >&2
    exit 1
}
case "$out" in
    /*) ;;
    *) echo 'Use an absolute output directory' >&2; exit 1 ;;
esac

mkdir -p "$out"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
tar -xJf "$inputs/linux-7.3.5.tar.xz" -C "$scratch"
cd "$scratch/linux-7.3.5"

for source in bounded-buddy sync-colocate idle-poll-bounded upstream-splice; do
    patch --fuzz=0 -p1 < "$inputs/$source.patch"
done
for source in virtiofs-workspace-async-release virtiofs-workspace-inline-completion virtiofs-workspace-compact-requests virtiofs-workspace-notify; do
    patch --fuzz=0 -p1 < "$patches/$source.patch"
done

export KBUILD_BUILD_TIMESTAMP='Wed Nov 26 00:00:00 UTC 2026'
export KBUILD_BUILD_VERSION=1 KBUILD_BUILD_USER=root KBUILD_BUILD_HOST=micropod-b8
cp "$inputs/b5.config" .config
scripts/config --set-str LOCALVERSION "-micropod-b8"
make PAHOLE=/dev/null olddefconfig
make PAHOLE=/dev/null -j"${JOBS:-12}" fs/fuse/file.o fs/fuse/virtio_fs.o
make PAHOLE=/dev/null -j"${JOBS:-12}" Image

cp .config "$out/config"
cp arch/arm64/boot/Image "$out/Image"
make PAHOLE=/dev/null -s kernelrelease > "$out/release"
(cd "$out" && sha256sum Image config > SHA256SUMS)
echo "Built kernel: $(cat "$out/release")"
cat "$out/SHA256SUMS"
