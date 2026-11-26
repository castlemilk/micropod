#!/bin/sh
# Build stock Linux 7.3.5 B5 and then apply one already-upstream splice fix.
set -eu

inputs=$(realpath "${1:?pinned input directory}")
out=${2:?new output directory}
[ "$(uname -m)" = aarch64 ] && [ "$(uname -s)" = Linux ] || {
    echo 'Build on ARM64 Linux' >&2
    exit 1
}

cd "$inputs"
sha256sum -c <<'SUMS'
8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990  linux-7.3.5.tar.xz
92e12b18d6a6e36f0d304fccba6bf8430c7809eddcf3fe9dbd9b666631a7056d  b5.config
8c66ba3dbb32b40dd5e545c8badb0295223f1254db43743d138ca5e6bccd44dc  bounded-buddy.patch
52de8d7c4fe4f9c30ac93c23c7c8d1f491a27ee62f3a659b42ee10e83fbfb5ae  sync-colocate.patch
d3d1445a2b3f873a4fa1a4e3fd863100b553c8d11781eefa822db27f3183c2c0  idle-poll-bounded.patch
02c8a9a851ebf189a14e7279390f6cba3f8bb751301dfe7ce106aba6103e5b56  upstream-splice.patch
SUMS

case "$out" in
    /*) ;;
    *) echo 'Use an absolute output directory' >&2; exit 1 ;;
esac
mkdir "$out"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
tar -xJf "$inputs/linux-7.3.5.tar.xz" -C "$scratch"
cd "$scratch/linux-7.3.5"
patch --fuzz=0 -p1 < "$inputs/bounded-buddy.patch"
patch --fuzz=0 -p1 < "$inputs/sync-colocate.patch"
patch --fuzz=0 -p1 < "$inputs/idle-poll-bounded.patch"

# Keep the exact resolved B5 configuration and its reproducible build identity.
export KBUILD_BUILD_TIMESTAMP='Wed Nov 25 11:42:33 UTC 2026'
export KBUILD_BUILD_VERSION=1 KBUILD_BUILD_USER=root KBUILD_BUILD_HOST=20f06b53323b
make_pinned() {
    make PAHOLE=/dev/null "$@"
}
cp "$inputs/b5.config" .config
make_pinned olddefconfig
cmp "$inputs/b5.config" .config
make_pinned -j"${JOBS:-4}" Image

mkdir "$out/stock"
cp .config "$out/stock/config"
cp arch/arm64/boot/Image "$out/stock/Image"
make_pinned -s kernelrelease > "$out/stock/release"
(cd "$out/stock" && sha256sum Image config > SHA256SUMS)
stock_sha=$(cut -d ' ' -f1 "$out/stock/SHA256SUMS" | head -1)
printf 'Published B5 SHA256 %s\nRebuilt B5 SHA256 %s\n' \
    5eb46b31203fe4b4d53782f4ba7b216274ad5cd63424df711fc96fd36577e52b "$stock_sha" \
    > "$out/baseline-image-equality.txt"

stock_source=$(sha256sum fs/fuse/file.c | cut -d ' ' -f1)
[ "$stock_source" = 57c206aeb46a5ae2ac5902777a9d0fe6c5a3c524a805fc5345f98950fe109cb0 ]
patch --dry-run --fuzz=0 -p1 < "$inputs/upstream-splice.patch"
patch --fuzz=0 -p1 < "$inputs/upstream-splice.patch"
patched_source=$(sha256sum fs/fuse/file.c | cut -d ' ' -f1)
[ "$patched_source" = 374d49cb6584c5eec57c9f589ba07af38c89243f088aa0501c41020c5c786e17 ]
make_pinned -j"${JOBS:-4}" fs/fuse/file.o
make_pinned -j"${JOBS:-4}" Image

mkdir "$out/splice"
cp .config "$out/splice/config"
cp arch/arm64/boot/Image "$out/splice/Image"
make_pinned -s kernelrelease > "$out/splice/release"
(cd "$out/splice" && sha256sum Image config > SHA256SUMS)
cmp "$out/stock/config" "$out/splice/config"
cmp "$out/stock/release" "$out/splice/release"

{
    printf 'Upstream commit %s\n' 10bd6b32965265688fa277d166ab224de8e86eb2
    printf 'Stock fs/fuse/file.c SHA256 %s\nPatched fs/fuse/file.c SHA256 %s\n' \
        "$stock_source" "$patched_source"
    printf 'KBUILD_BUILD_TIMESTAMP=%s\nKBUILD_BUILD_VERSION=%s\nKBUILD_BUILD_USER=%s\nKBUILD_BUILD_HOST=%s\n' \
        "$KBUILD_BUILD_TIMESTAMP" "$KBUILD_BUILD_VERSION" "$KBUILD_BUILD_USER" "$KBUILD_BUILD_HOST"
    gcc --version
    ld --version
    make --version
} > "$out/build-inputs.txt"
