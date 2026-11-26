#!/bin/sh
# Read inside an already authorized disposable VM's guest network namespace.
# stdout is the receipt. This script performs no setup.
set -eu
export LC_ALL=C
release=$(uname -r)
echo "release=$release"
printf 'boot='
cat /proc/sys/kernel/random/boot_id
printf 'machine='
uname -m
printf 'cmdline='
cat /proc/cmdline
config() {
    if test -r /proc/config.gz; then gzip -dc /proc/config.gz
    elif test -r "/boot/config-$release"; then cat "/boot/config-$release"
    else return 1
    fi
}
config >/dev/null || { echo "Booted configuration unavailable" >&2; exit 1; }
printf 'config_sha256='
config | sha256sum | cut -d' ' -f1
config | grep -E '^(# )?CONFIG_(SCHED_CLASS_EXT|SCHED_BPF|BPF|BPF_SYSCALL|BPF_JIT|DEBUG_INFO_BTF|BPF_STREAM_PARSER|NET_CLS_BPF|XDP_SOCKETS|PREEMPT[^ =]*|HZ[^ =]*|FAIR_GROUP_SCHED|EXT_GROUP_SCHED|CFS_BANDWIDTH|CGROUP_BPF|PSI|RPS|RFS_ACCEL|VIRTIO_NET)(=| )'
for p in /sys/kernel/sched_ext/state /sys/kernel/sched_ext/root/ops /sys/kernel/sched_ext/enable_seq /sys/fs/cgroup/cgroup.controllers /proc/self/cgroup; do
    if test -r "$p"; then echo "$p"; cat "$p"; fi
done
found=0
for path in /sys/class/net/*; do
    driver=$(readlink "$path/device/driver" || true)
    test "${driver##*/}" = virtio_net || continue
    found=1
    nic=${path##*/}
    echo "virtio_nic=$nic"
    for flag in i l k g c S; do
        echo "ethtool -$flag $nic"
        if result=$(ethtool "-$flag" "$nic" 2>&1); then echo "$result"
        else
            echo "$result"
            case "$result" in
                *"not permitted"*|*"denied"*) exit 1 ;;
                *"not supported"*|*"Not supported"*) test "$flag" != k || exit 1 ;;
                *) exit 1 ;;
            esac
        fi
    done
    for q in "$path"/queues/*; do
        test -d "$q" || continue
        echo "$q"
        for mask in "$q"/rps_cpus "$q"/rps_flow_cnt "$q"/xps_cpus; do
            if test -r "$mask"; then echo "$mask $(cat "$mask")"; fi
        done
    done
    for field in "$path"/statistics/*; do echo "$nic/${field##*/} $(cat "$field")"; done
done
test "$found" = 1 || { echo 'No guest virtio_net device visible' >&2; exit 1; }
for p in /proc/interrupts /proc/net/softnet_stat /proc/net/netstat /proc/net/snmp /proc/stat /proc/pressure/cpu /proc/pressure/io /proc/pressure/memory; do
    if test -r "$p"; then echo "$p"; cat "$p"; fi
done
