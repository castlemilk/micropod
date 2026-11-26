#!/bin/sh
# Build one Linux 7.3.5 B5 + splice + async RELEASE Image for both completion modes.
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

cd "$inputs"
sha256sum -c <<'SUMS'
8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990  linux-7.3.5.tar.xz
92e12b18d6a6e36f0d304fccba6bf8430c7809eddcf3fe9dbd9b666631a7056d  b5.config
8c66ba3dbb32b40dd5e545c8badb0295223f1254db43743d138ca5e6bccd44dc  bounded-buddy.patch
52de8d7c4fe4f9c30ac93c23c7c8d1f491a27ee62f3a659b42ee10e83fbfb5ae  sync-colocate.patch
d3d1445a2b3f873a4fa1a4e3fd863100b553c8d11781eefa822db27f3183c2c0  idle-poll-bounded.patch
02c8a9a851ebf189a14e7279390f6cba3f8bb751301dfe7ce106aba6103e5b56  upstream-splice.patch
SUMS
release="$patches/virtiofs-workspace-async-release.patch"
completion="$patches/virtiofs-workspace-local-completion.patch"
printf '%s  %s\n' \
    7ca10c839d2e8c6994e8d4d077fe42f51eb66a3418c7877321b59ca7576506e3 "$release" \
    5005308f51e5c26dbc8f70ead3209b6f220403873d9b2da34a2d419772d3cc6b "$completion" | sha256sum -c -

mkdir "$out"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
tar -xJf "$inputs/linux-7.3.5.tar.xz" -C "$scratch"
cd "$scratch/linux-7.3.5"
for source in bounded-buddy sync-colocate idle-poll-bounded upstream-splice; do
    patch --fuzz=0 -p1 < "$inputs/$source.patch"
done
patch --fuzz=0 -p1 < "$release"
printf '%s  %s\n' \
    374d49cb6584c5eec57c9f589ba07af38c89243f088aa0501c41020c5c786e17 fs/fuse/file.c \
    a4e8648c21fd94aeb3f97fd300bc63353ef0c75c0a25f69468ef3dcc542c5cc3 fs/fuse/virtio_fs.c | sha256sum -c -
patch --fuzz=0 -p1 < "$completion"
printf '%s  %s\n' 58d2f1c2b42c9b1eeca81473041a4b7a6ad450b1f5f2976086a74965842a9b73 fs/fuse/virtio_fs.c | sha256sum -c -
perl scripts/checkpatch.pl --no-tree "$completion"

export KBUILD_BUILD_TIMESTAMP='Wed Nov 25 11:42:33 UTC 2026'
export KBUILD_BUILD_VERSION=1 KBUILD_BUILD_USER=root KBUILD_BUILD_HOST=20f06b53323b
make_pinned() {
    make PAHOLE=/dev/null "$@"
}
cp "$inputs/b5.config" .config
make_pinned olddefconfig
cmp "$inputs/b5.config" .config
make_pinned -j"${JOBS:-4}" fs/fuse/file.o fs/fuse/virtio_fs.o
make_pinned -j"${JOBS:-4}" Image

cp .config "$out/config"
cp arch/arm64/boot/Image "$out/Image"
make_pinned -s kernelrelease > "$out/release"
(cd "$out" && sha256sum Image config > SHA256SUMS)
{
    printf 'KBUILD_BUILD_TIMESTAMP=%s\nKBUILD_BUILD_VERSION=%s\nKBUILD_BUILD_USER=%s\nKBUILD_BUILD_HOST=%s\n' \
        "$KBUILD_BUILD_TIMESTAMP" "$KBUILD_BUILD_VERSION" "$KBUILD_BUILD_USER" "$KBUILD_BUILD_HOST"
    gcc --version
    ld --version
    make --version
    sha256sum "$inputs/linux-7.3.5.tar.xz" "$inputs/b5.config" "$inputs/"*.patch "$release" "$completion"
    sha256sum fs/fuse/file.c fs/fuse/virtio_fs.c
} > "$out/build-inputs.txt"
