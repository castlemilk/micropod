#!/bin/bash
# e2fsprogs for the guest tool bundle (tools/e2fsprogs/): e2fsck, resize2fs
# and dumpe2fs with their libraries, from the Alpine release the guest root
# runs (its musl loader runs them). `micropod machine disk grow` boots a
# maintenance machine whose guest init grows a cloned disk with them offline:
# the disks are ext4 with sparse_super2, which the kernel does not grow
# online, and the OS disk ships no e2fsprogs of its own.
#
#   ci/fetch-e2fsprogs.sh OUT_DIR
#
# Downloads are pinned by SHA-256 and kept in MICROPOD_GUEST_DOWNLOADS
# (default .build/oci-downloads).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:?OUT_DIR}
downloads=${MICROPOD_GUEST_DOWNLOADS:-$root/.build/oci-downloads}
mirror=${MICROPOD_ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine/v3.24/main/aarch64}
packages=(
    "e2fsprogs-1.47.4-r0 52fd401e79ce6b0ff7648733ba4de3135083cd0132543534e72106e7ea767a00"
    "e2fsprogs-extra-1.47.4-r0 70b0a01bf62349263a8f400809c7512e991b7db13dbebbf9b3a1cb3b3d21efcc"
    "e2fsprogs-libs-1.47.4-r0 52124971ae397d599aadd79263fcd68fc9e271922ccf8185b124f35fe24c60c8"
    "libcom_err-1.47.4-r0 a75b5955ff57046e33fc2842cfe466dc77d8e68305d5c86c6646b38a069490a2"
    "libblkid-2.42.3-r1 9d0f24976c575c53c12526b6e078edf34c980c153bc8e5f1c1053cbece5b8cfa"
    "libuuid-2.42.3-r1 9ce20c7ffe2ccaa7c321893c10564abbca13c3f2edb82f60a35f1f68e004f86c"
    "libeconf-0.8.3-r0 cf0899d49ded0a6891e3cdf1b37887f2ecd77293afe1d8f3cb8937763c83f183"
)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
for entry in "${packages[@]}"; do
    read -r name digest <<<"$entry"
    apk="$downloads/alpine-$name.apk"
    bash "$root/ci/fetch-guest-artifact.sh" "$mirror/$name.apk" "$digest" "$apk"
    # An .apk is concatenated gzip-compressed tar segments (signature,
    # control, data); tar reads them all, and only the data has these paths.
    tar -xzf "$apk" -C "$stage" 2>/dev/null || true
done
dest="$stage/e2fsprogs"
mkdir -p "$dest/lib"
# Wherever the release puts them (/sbin or /usr/sbin, /lib or /usr/lib).
member() {
    local dir
    for dir in sbin usr/sbin lib usr/lib; do
        [ -e "$stage/$dir/$1" ] && { echo "$stage/$dir/$1"; return; }
    done
    echo "e2fsprogs: no $1 in the packages" >&2
    exit 1
}
for tool in e2fsck resize2fs dumpe2fs; do
    install -m 0755 "$(member "$tool")" "$dest/$tool"
done
for lib in libext2fs.so.2 libcom_err.so.2 libe2p.so.2 libblkid.so.1 libuuid.so.1 libeconf.so.0; do
    cp -L "$(member "$lib")" "$dest/lib/$lib"
done
chmod 0644 "$dest"/lib/*
for need in e2fsck resize2fs dumpe2fs lib/libext2fs.so.2 lib/libblkid.so.1 lib/libeconf.so.0; do
    [ -s "$dest/$need" ] || { echo "e2fsprogs bundle is missing $need" >&2; exit 1; }
done
rm -rf "$out"
mkdir -p "$(dirname "$out")"
mv "$dest" "$out"
echo "e2fsprogs: $out"
