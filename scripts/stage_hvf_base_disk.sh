#!/bin/bash
# Copy an optional HVF base disk into a package: an ext4 image that
# `micropod setup` (and `micropod machine install`) clones a new machine's
# disk from when no disk is named. It lands in the app's Contents/Resources
# and the CLI tarball's root as hvf-base-disk.ext4.
#
#   scripts/stage_hvf_base_disk.sh <ext4> <app-resources-dir> <dist-dir>
#
# Copies are clones on APFS (cp -c), so the sparse image costs nothing
# extra. The release pipeline does not build or pin one yet: a package
# without it is still a complete release (verify_release_payload.sh does not
# require it), and setup then asks for --disk-from or --disk-image.
set -euo pipefail

disk=${1:?base disk ext4 image}
resources=${2:?app Contents/Resources directory}
dist=${3:?distribution directory}
name=hvf-base-disk.ext4

[[ -f "$disk" && ! -L "$disk" ]] || { echo "MICROPOD_HVF_BASE_DISK: $disk is not a regular file" >&2; exit 1; }
# The ext4 superblock magic, 0xEF53 little-endian at byte 1024 + 0x38.
magic=$(dd if="$disk" bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
[[ "$magic" == "53ef" ]] || { echo "MICROPOD_HVF_BASE_DISK: $disk is not an ext4 image" >&2; exit 1; }

for dir in "$resources" "$dist"; do
    mkdir -p "$dir"
    staged=$(mktemp "$dir/.$name.XXXXXX")
    rm -f "$staged"
    cp -c "$disk" "$staged" 2>/dev/null || cp "$disk" "$staged"
    chmod 644 "$staged"
    mv -f "$staged" "$dir/$name"
done
echo "==> HVF base disk bundled ($name, $(du -h "$disk" | cut -f1) on disk)"
