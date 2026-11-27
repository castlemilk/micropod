#!/bin/bash
# Stage the guest's x86-64 emulator: QEMU's static user-mode qemu-x86_64,
# as Debian builds it for arm64 (package qemu-user, which ships static
# binaries since Debian 13), with its licence and a note of its exact source.
#
#   ci/fetch-qemu-user.sh <dest dir>
#
# writes <dest>/qemu-x86_64, <dest>/qemu-x86_64.copyright (Debian's licence
# summary: QEMU is GPL-2.0, with LGPL and BSD parts) and <dest>/SOURCE (the
# Debian source package that builds it; GPL-2.0 section 3 asks a distributor
# of the binary to offer that source). The engine registers the binary with
# binfmt_misc (guest/runner/emulation_linux.go). MICROPOD_QEMU_USER_DEB names
# an already downloaded copy of the package; its digest is checked as for a
# download.
set -euo pipefail
dir=$(cd "$(dirname "$0")" && pwd)
dest=${1:?destination directory}
version=10.0.13+ds-0+deb13u1
deb=qemu-user_${version}_arm64.deb
deb_sha256=c73711af02b97cd5e2667e735d9c06890c57165517110ca4e646c95a7083158d
binary_sha256=9af86352fd463ad9ec25bdd6a4b891ac6b6a7f3d46a7db3da6f23e2c09094a59
downloads=${MICROPOD_GUEST_DOWNLOADS:-$dir/../.build/oci-downloads}
pool=https://deb.debian.org/debian/pool/main/q/qemu/qemu-user_10.0.13%2Bds-0%2Bdeb13u1_arm64.deb
# The pool keeps only the current stable update; the snapshot keeps every one.
snapshot=https://snapshot.debian.org/archive/debian/20260905T205002Z/pool/main/q/qemu/qemu-user_10.0.13%2Bds-0%2Bdeb13u1_arm64.deb
if ! bash "$dir/fetch-guest-artifact.sh" "$pool" "$deb_sha256" "$downloads/$deb" "${MICROPOD_QEMU_USER_DEB:-}" 2>/dev/null; then
    bash "$dir/fetch-guest-artifact.sh" "$snapshot" "$deb_sha256" "$downloads/$deb" "${MICROPOD_QEMU_USER_DEB:-}"
fi
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
(cd "$stage" && ar x "$downloads/$deb" data.tar.xz)
tar -xJf "$stage/data.tar.xz" -C "$stage" ./usr/bin/qemu-x86_64 ./usr/share/doc/qemu-user/copyright
actual=$(shasum -a 256 "$stage/usr/bin/qemu-x86_64" | cut -d ' ' -f1)
[[ "$actual" == "$binary_sha256" ]] || { echo "qemu-x86_64 in $deb is $actual, not $binary_sha256" >&2; exit 1; }
mkdir -p "$dest"
install -m 0755 "$stage/usr/bin/qemu-x86_64" "$dest/qemu-x86_64"
install -m 0644 "$stage/usr/share/doc/qemu-user/copyright" "$dest/qemu-x86_64.copyright"
cat >"$dest/SOURCE" <<EOF
qemu-x86_64: QEMU 10.0.13 user-mode emulation, a static build for linux/arm64.
Binary: Debian package qemu-user ${version} (arm64), file /usr/bin/qemu-x86_64,
  sha256 ${binary_sha256}.
Licence: GPL-2.0 (QEMU), with LGPL-2.1 and BSD-licensed parts; see
  qemu-x86_64.copyright (Debian's machine-readable copyright file).
Corresponding source: Debian source package qemu ${version}:
  https://snapshot.debian.org/package/qemu/1:${version}/
EOF
chmod 0644 "$dest/SOURCE"
