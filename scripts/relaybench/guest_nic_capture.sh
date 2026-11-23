#!/bin/sh
# Run in the Linux worker's network namespace during an approved diagnostic window.
# Capture stdout to a file, then run guest_nic.py FILE --expected-boot UUID on the host.
set -eu
export LC_ALL=C
nic=/sys/class/net/eth1

identity() {
    cat /proc/sys/kernel/random/boot_id /proc/sys/kernel/osrelease "$nic/ifindex" "$nic/address"
    readlink /proc/self/ns/net
    readlink -f "$nic/device"
    readlink -f "$nic/device/driver"
}

capture() {
    key=$1
    shift
    printf '@@ %s\n' "$key"
    status=0
    "$@" 2>&1 || status=$?
    printf '@@ end %s %s\n' "$key" "$status"
}

# Read identity under errexit separately from optional probes. Any failed read
# terminates the collector and leaves the decoder with an incomplete receipt.
printf '@@ before\n'
identity
printf '@@ end before 0\n'
capture bitmap cat "$nic/device/features"
capture queues ls -1 "$nic/queues"
capture offloads ethtool -k eth1
capture channels ethtool -l eth1
capture coalescing ethtool -c eth1
printf '@@ after\n'
identity
printf '@@ end after 0\n'
