#!/bin/sh
# Capture the guest TX queue boundary read-only. Redirect stdout separately before and after a run.
set -eu
export LC_ALL=C
iface=${1:-eth1}
case "$iface" in ''|.|..|*[!A-Za-z0-9_.-]*) exit 2 ;; esac
root=${BQL_FIXTURE_ROOT:-}
nic="$root/sys/class/net/$iface"
queue="$nic/queues/tx-0/byte_queue_limits"

identity() {
    cat "$root/proc/sys/kernel/random/boot_id" "$root/proc/sys/kernel/osrelease"
    readlink "$root/proc/self/ns/net"
    printf '%s\n' "$iface"
    cat "$nic/ifindex" "$nic/address"
    readlink "$nic/device"
    readlink "$nic/device/driver"
}

printf 'bql-capture-v1\n'
cat "$root/proc/uptime"
identity
for name in limit_max limit_min limit inflight; do
    printf '%s ' "$name"
    cat "$queue/$name"
done
for name in tx_bytes tx_packets tx_errors tx_dropped; do
    printf '%s ' "$name"
    cat "$nic/statistics/$name"
done
identity
cat "$root/proc/uptime"
