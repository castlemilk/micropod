#!/bin/sh
# Build Linux 7.3.5 16 KiB ARM64 worker kernel with BOUNDED_BUDDY + SYNC_COLOCATE.
set -eu
archive=${1:?Linux 7.3.5 source tar.xz}
config=${2:?base Apple guest .config}
out=${3:?output directory}
archive=$(realpath "$archive")
config=$(realpath "$config")
mkdir -p "$(dirname "$out")"
out="$(realpath "$(dirname "$out")")/$(basename "$out")"
if [ -e "$out" ] || [ -L "$out" ]; then
    echo "Output directory already exists: $out" >&2
    exit 1
fi
digest=8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990
printf '%s  %s\n' "$digest" "$archive" | sha256sum -c -
[ "$(uname -m)" = aarch64 ] || { echo "ARM64 Linux build host required" >&2; exit 1; }
work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
tar -xJf "$archive" -C "$work"
cd "$work/linux-7.3.5"
patch -p1 < /inputs/bounded-buddy.patch
patch -p1 < /inputs/sync-colocate.patch
cp "$config" .config
scripts/config -d ARM64_4K_PAGES -e ARM64_16K_PAGES -d ARM64_64K_PAGES
scripts/config -e PREEMPT -d PREEMPT_LAZY -d PREEMPT_DYNAMIC
scripts/config --set-str LOCALVERSION "-micropod-b4" -d LOCALVERSION_AUTO \
    -e MACVLAN -e IPVLAN -e NETKIT -e NET_CLS_ACT -e NET_SCH_INGRESS -e NET_CLS_FLOWER \
    -e NET_CLS_BPF -e NET_ACT_GACT -e NET_ACT_MIRRED -e NET_ACT_PEDIT \
    -e NETFILTER_INGRESS -e NETFILTER_EGRESS -e NF_TABLES_NETDEV \
    -e BPF_STREAM_PARSER -e NET_SCH_FQ -e NET_SCH_FQ_CODEL -e TCP_CONG_CUBIC \
    -e CC_OPTIMIZE_FOR_PERFORMANCE
make olddefconfig
for setting in ARM64_16K_PAGES=y PAGE_SIZE_16KB=y PAGE_SHIFT=14 PREEMPT=y; do
    grep -qx "CONFIG_$setting" .config || { echo "Missing setting $setting" >&2; exit 1; }
done
make -j"${JOBS:-12}" Image
mkdir -p "$out"
cp arch/arm64/boot/Image "$out/Image"
cp .config "$out/config"
make -s kernelrelease >"$out/release"
(cd "$out" && sha256sum Image config >SHA256SUMS)
