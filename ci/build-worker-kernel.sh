#!/bin/sh
# Build on ARM64 Linux. Arguments are the upstream archive, the compatible
# Apple guest's .config, an output directory and optional full|full-16k|full-no-mlx5|full-cubic|full-scx|lazy profile.
set -eu
archive=${1:?Linux 7.3.5 source tar.xz}
config=${2:?base Apple guest .config}
out=${3:?output directory}
profile=${4:-full}
archive=$(realpath "$archive")
config=$(realpath "$config")
fresh_output=false
case "$profile" in full-16k|full-no-mlx5) fresh_output=true ;; esac
if [ "$fresh_output" = true ]; then
    mkdir -p "$(dirname "$out")"
    out="$(realpath "$(dirname "$out")")/$(basename "$out")"
    if [ -e "$out" ] || [ -L "$out" ]; then
        echo "$profile requires a new output directory to preserve the control build" >&2
        exit 1
    fi
else
    mkdir -p "$out"
    out=$(realpath "$out")
fi
digest=8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990
printf '%s  %s\n' "$digest" "$archive" | sha256sum -c -
[ "$(uname -m)" = aarch64 ] || { echo "ARM64 Linux build host required" >&2; exit 1; }
work=$(mktemp -d)
claimed_out=
cleanup() {
    rm -rf "$work"
    if [ -n "$claimed_out" ]; then
        rm -f "$claimed_out/Image" "$claimed_out/config" "$claimed_out/release" "$claimed_out/SHA256SUMS"
        rmdir "$claimed_out"
    fi
}
trap cleanup EXIT
tar -xJf "$archive" -C "$work"
cd "$work/linux-7.3.5"
cp "$config" .config
case "$profile" in
    full|full-16k|full-no-mlx5|full-cubic|full-scx)
        localversion=-micropod
        if [ "$profile" = full-16k ]; then
            scripts/config -d ARM64_4K_PAGES -e ARM64_16K_PAGES -d ARM64_64K_PAGES
        fi
        if [ "$profile" = full-no-mlx5 ]; then
            scripts/config -d MLX5_CORE
        fi
        if [ "$profile" = full-cubic ]; then
            localversion=-micropod-cc
            scripts/config -e TCP_CONG_CUBIC
        fi
        if [ "$profile" = full-scx ]; then
            localversion=-micropod-scx
            scripts/config -e BPF -e BPF_SYSCALL -e BPF_JIT -e BPF_JIT_ALWAYS_ON -e BPF_JIT_DEFAULT_ON \
                -e DEBUG_INFO_BTF -e SCHED_CLASS_EXT -e EXT_GROUP_SCHED
        fi
        preempt=PREEMPT
        scripts/config -e PREEMPT -d PREEMPT_LAZY -d PREEMPT_DYNAMIC ;;
    lazy)
        localversion=-micropod-lazy
        preempt=PREEMPT_LAZY
        scripts/config -d PREEMPT -e PREEMPT_LAZY -d PREEMPT_DYNAMIC ;;
    *) echo "Select full, full-16k, full-no-mlx5, full-cubic, full-scx or lazy" >&2; exit 1 ;;
esac
scripts/config --set-str LOCALVERSION "$localversion" -d LOCALVERSION_AUTO \
    -e MACVLAN -e NETKIT -e NET_CLS_ACT -e NET_SCH_INGRESS -e NET_CLS_FLOWER \
    -e NET_CLS_BPF -e NET_ACT_GACT -e NET_ACT_MIRRED -e NET_ACT_PEDIT \
    -e NETFILTER_INGRESS -e NETFILTER_EGRESS -e NF_TABLES_NETDEV \
    -e BPF_STREAM_PARSER -e NET_SCH_FQ -e CC_OPTIMIZE_FOR_PERFORMANCE
make olddefconfig
if [ "$profile" = full-no-mlx5 ]; then
    grep -qx '# CONFIG_MLX5_CORE is not set' .config || { echo "ConnectX core driver still selected" >&2; exit 1; }
    for symbol in VIRTIO_PCI VIRTIO_BLK VIRTIO_NET VIRTIO_CONSOLE VIRTIO_VSOCKETS VIRTIO_FS EXT4_FS OVERLAY_FS; do
        grep -qx "CONFIG_$symbol=y" .config || { echo "Missing worker device or filesystem $symbol" >&2; exit 1; }
    done
fi
if [ "$profile" = full-16k ]; then
    for setting in ARM64_16K_PAGES=y PAGE_SIZE_16KB=y PAGE_SHIFT=14; do
        grep -qx "CONFIG_$setting" .config || { echo "Missing 16 KiB kernel setting $setting" >&2; exit 1; }
    done
    if grep -Eq '^CONFIG_ARM64_(4K|64K)_PAGES=y$' .config; then
        echo "Conflicting arm64 page sizes in resolved config" >&2
        exit 1
    fi
fi
if [ "$profile" = full-cubic ]; then
    grep -qx CONFIG_TCP_CONG_CUBIC=y .config
fi
if [ "$profile" = full-scx ]; then
    for symbol in SCHED_CLASS_EXT EXT_GROUP_SCHED BPF BPF_SYSCALL BPF_JIT BPF_JIT_ALWAYS_ON BPF_JIT_DEFAULT_ON \
        DEBUG_INFO_BTF CGROUP_SCHED FAIR_GROUP_SCHED CFS_BANDWIDTH MEMCG CGROUP_PIDS; do
        grep -qx "CONFIG_$symbol=y" .config || { echo "Missing sched_ext profile option $symbol" >&2; exit 1; }
    done
fi
for symbol in "$preempt" NET_NS VIRTIO_NET MACVLAN NETFILTER_INGRESS NETFILTER_EGRESS NF_TABLES_NETDEV \
    NF_TABLES_INET NF_CONNTRACK NF_CT_NETLINK NF_NAT NFT_NAT NFT_CT NET_SCH_FQ; do
    grep -qx "CONFIG_$symbol=y" .config || { echo "Missing built-in $symbol" >&2; exit 1; }
done
make -j"${JOBS:-4}" Image
if [ "$fresh_output" = true ]; then
    # Claim the destination atomically after the build, even if another build raced our preflight.
    mkdir "$out"
    claimed_out=$out
fi
cp arch/arm64/boot/Image "$out/Image"
cp .config "$out/config"
make -s kernelrelease >"$out/release"
(cd "$out" && sha256sum Image config >SHA256SUMS)
claimed_out=
