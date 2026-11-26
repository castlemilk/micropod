#!/bin/sh
# Build one Linux 7.3.5 B5 Image for both settings of virtiofs.sync_lookup_completion.
set -eu

archive=$(realpath "${1:?Linux 7.3.5 source archive}")
config=$(realpath "${2:?resolved B5 config}")
buddy=$(realpath "${3:?B5 bounded-buddy patch}")
out=${4:?new output directory}
patches=$(dirname "$(realpath "$0")")

[ "$(uname -m)" = aarch64 ] && [ "$(uname -s)" = Linux ] || {
    echo 'Build on ARM64 Linux' >&2
    exit 1
}
check_input() {
    printf '%s  %s\n' "$1" "$2" | sha256sum -c -
}
check_input 8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990 "$archive"
check_input 92e12b18d6a6e36f0d304fccba6bf8430c7809eddcf3fe9dbd9b666631a7056d "$config"
check_input 8c66ba3dbb32b40dd5e545c8badb0295223f1254db43743d138ca5e6bccd44dc "$buddy"
check_input 52de8d7c4fe4f9c30ac93c23c7c8d1f491a27ee62f3a659b42ee10e83fbfb5ae "$patches/sync-colocate.patch"
check_input d3d1445a2b3f873a4fa1a4e3fd863100b553c8d11781eefa822db27f3183c2c0 "$patches/idle-poll-bounded.patch"

mkdir -p "$(dirname "$out")"
out="$(realpath "$(dirname "$out")")/$(basename "$out")"
[ ! -e "$out" ] && [ ! -L "$out" ] || {
    echo "Output already exists: $out" >&2
    exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar -xJf "$archive" -C "$work"
cd "$work/linux-7.3.5"
patch --fuzz=0 -p1 < "$buddy"
patch --fuzz=0 -p1 < "$patches/sync-colocate.patch"
patch --fuzz=0 -p1 < "$patches/idle-poll-bounded.patch"
patch --fuzz=0 -p1 < "$patches/virtiofs-sync-lookup.patch"
perl scripts/checkpatch.pl --no-tree "$patches/virtiofs-sync-lookup.patch"

# B5 was built without pahole. Keep its Kconfig feature probes identical.
make_pinned() {
    make PAHOLE=/dev/null "$@"
}
cp "$config" .config
make_pinned olddefconfig
if ! cmp -s "$config" .config; then
    diff -u "$config" .config >&2 || true
    echo 'The toolchain did not reproduce the pinned B5 config' >&2
    exit 1
fi
export KBUILD_BUILD_TIMESTAMP='2026-11-25 00:00:00 UTC'
export KBUILD_BUILD_VERSION=1 KBUILD_BUILD_USER=micropod KBUILD_BUILD_HOST=kernel-builder
make_pinned -j"${JOBS:-8}" fs/fuse/virtio_fs.o
make_pinned -j"${JOBS:-8}" Image

mkdir "$out"
cp arch/arm64/boot/Image "$out/Image"
cp .config "$out/config"
make_pinned -s kernelrelease > "$out/release"
(cd "$out" && sha256sum Image config > SHA256SUMS)

{
    gcc --version
    ld --version
    make --version
    sha256sum "$archive" "$config" "$buddy" "$patches/sync-colocate.patch" \
        "$patches/idle-poll-bounded.patch" "$patches/virtiofs-sync-lookup.patch"
} > "$out/build-inputs.txt"
