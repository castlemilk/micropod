#!/bin/sh
# Build the same B5 Image for both workspace_compact_requests settings.
set -eu

inputs=$(realpath "${1:?pinned Linux and B5 input directory}")
out=${2:?new absolute output directory}
controls=$(dirname "$(realpath "$0")")
[ "$(uname -sm)" = 'Linux aarch64' ] || { echo 'Build on ARM64 Linux' >&2; exit 1; }
case "$out" in /*) ;; *) echo 'Use an absolute output directory' >&2; exit 1 ;; esac

cd "$inputs"
sha256sum -c <<'SUMS'
8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990  linux-7.3.5.tar.xz
92e12b18d6a6e36f0d304fccba6bf8430c7809eddcf3fe9dbd9b666631a7056d  b5.config
8c66ba3dbb32b40dd5e545c8badb0295223f1254db43743d138ca5e6bccd44dc  bounded-buddy.patch
52de8d7c4fe4f9c30ac93c23c7c8d1f491a27ee62f3a659b42ee10e83fbfb5ae  sync-colocate.patch
d3d1445a2b3f873a4fa1a4e3fd863100b553c8d11781eefa822db27f3183c2c0  idle-poll-bounded.patch
02c8a9a851ebf189a14e7279390f6cba3f8bb751301dfe7ce106aba6103e5b56  upstream-splice.patch
SUMS
cd "$controls"
sha256sum -c <<'SUMS'
7ca10c839d2e8c6994e8d4d077fe42f51eb66a3418c7877321b59ca7576506e3  virtiofs-workspace-async-release.patch
89c755874750d484b7549cfe503cfbb2da8116bc5b429714b648bf79445fbc66  virtiofs-workspace-inline-completion.patch
48c64699f509c4da2ef5a4f628e0f088d7bb1233a53985338993cac97053df7d  virtiofs-workspace-compact-requests.patch
SUMS
mkdir "$out"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
tar -xJf "$inputs/linux-7.3.5.tar.xz" -C "$scratch"
cd "$scratch/linux-7.3.5"
for name in bounded-buddy sync-colocate idle-poll-bounded upstream-splice; do
    patch --fuzz=0 -p1 < "$inputs/$name.patch"
done
for name in async-release inline-completion compact-requests; do
    patch --fuzz=0 -p1 < "$controls/virtiofs-workspace-$name.patch"
done
sha256sum -c <<'SUMS'
374d49cb6584c5eec57c9f589ba07af38c89243f088aa0501c41020c5c786e17  fs/fuse/file.c
52982a7dad0152ebae930d26781d5f76646d5b644caabc9b9c8d0d61bc63961e  fs/fuse/dev.c
fa283409749e7c0040c24fd9259c5411bcfe7e468bd0f272c12e8b2eb638b1da  fs/fuse/fuse_dev_i.h
661c3c3f5fcc3932a2eae17a36f3c3984d42d7dbafe072722847288b6cdf8547  fs/fuse/virtio_fs.c
SUMS
perl scripts/checkpatch.pl --no-tree "$controls/virtiofs-workspace-compact-requests.patch"
export KBUILD_BUILD_TIMESTAMP='Wed Nov 25 11:42:33 UTC 2026'
export KBUILD_BUILD_VERSION=1 KBUILD_BUILD_USER=root KBUILD_BUILD_HOST=20f06b53323b
cp "$inputs/b5.config" .config
make PAHOLE=/dev/null olddefconfig
cmp "$inputs/b5.config" .config
make PAHOLE=/dev/null -j"${JOBS:-4}" fs/fuse/virtio_fs.o
make PAHOLE=/dev/null -j"${JOBS:-4}" Image
cp arch/arm64/boot/Image "$out/Image"
cp .config "$out/config"
make PAHOLE=/dev/null -s kernelrelease > "$out/release"
(cd "$out" && sha256sum Image config > SHA256SUMS)
{
    gcc --version
    ld --version
    make --version
    sha256sum "$inputs/linux-7.3.5.tar.xz" "$inputs/b5.config" "$inputs/"*.patch
    sha256sum "$controls/"virtiofs-workspace-*.patch fs/fuse/virtio_fs.c fs/fuse/fuse_dev_i.h
} > "$out/build-inputs.txt"
