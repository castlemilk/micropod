#!/bin/sh
# Build on ARM64 Linux. Arguments are the upstream archive, the compatible
# Apple guest's .config, an output directory and optional full|lazy preemption.
set -eu
archive=${1:?Linux 7.3.5 source tar.xz}
config=${2:?base Apple guest .config}
out=${3:?output directory}
profile=${4:-full}
archive=$(realpath "$archive")
config=$(realpath "$config")
mkdir -p "$out"
out=$(realpath "$out")
digest=8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990
printf '%s  %s\n' "$digest" "$archive" | sha256sum -c -
[ "$(uname -m)" = aarch64 ] || { echo "ARM64 Linux build host required" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar -xJf "$archive" -C "$work"
cd "$work/linux-7.3.5"
cp "$config" .config
case "$profile" in
    full)
        localversion=-micropod
        preempt=PREEMPT
        scripts/config -e PREEMPT -d PREEMPT_LAZY -d PREEMPT_DYNAMIC ;;
    lazy)
        localversion=-micropod-lazy
        preempt=PREEMPT_LAZY
        scripts/config -d PREEMPT -e PREEMPT_LAZY -d PREEMPT_DYNAMIC ;;
    *) echo "Select full or lazy preemption" >&2; exit 1 ;;
esac
scripts/config --set-str LOCALVERSION "$localversion" -d LOCALVERSION_AUTO \
    -e MACVLAN -e NETKIT -e NET_CLS_ACT -e NET_SCH_INGRESS -e NET_CLS_FLOWER \
    -e NET_CLS_BPF -e NET_ACT_GACT -e NET_ACT_MIRRED -e NET_ACT_PEDIT \
    -e NETFILTER_INGRESS -e NETFILTER_EGRESS -e NF_TABLES_NETDEV \
    -e BPF_STREAM_PARSER -e NET_SCH_FQ -e CC_OPTIMIZE_FOR_PERFORMANCE
make olddefconfig
for symbol in "$preempt" NET_NS VIRTIO_NET MACVLAN NETFILTER_INGRESS NETFILTER_EGRESS NF_TABLES_NETDEV \
    NF_TABLES_INET NF_CONNTRACK NF_CT_NETLINK NF_NAT NFT_NAT NFT_CT NET_SCH_FQ; do
    grep -qx "CONFIG_$symbol=y" .config || { echo "Missing built-in $symbol" >&2; exit 1; }
done
make -j"${JOBS:-4}" Image
cp arch/arm64/boot/Image "$out/Image"
cp .config "$out/config"
make -s kernelrelease >"$out/release"
(cd "$out" && sha256sum Image config >SHA256SUMS)
