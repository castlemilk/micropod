#!/bin/sh
# The private worker starts this in its initial network namespace. Each request
# is a fixed filename. Only the matched publication interface is sampled.
set -eu
base="$MICROPOD_ENGINE_WORKSPACE/nic-observations"
link=/sys/class/net/eth1
snapshot() {
    printf 'boot=%s\n' "$(cat /proc/sys/kernel/random/boot_id)"
    printf 'netns=%s\n' "$(readlink /proc/self/ns/net)"
    printf 'driver=%s\n' "$(basename "$(readlink "$link/device/driver")")"
    printf 'queues=%s\n' "$(ls -d "$link"/queues/tx-* | wc -l)"
    for name in ifindex address; do printf '%s=%s\n' "$name" "$(cat "$link/$name")"; done
    for field in tx_bytes tx_packets rx_bytes tx_dropped rx_dropped tx_errors rx_errors; do
        printf '%s=%s\n' "$field" "$(cat "$link/statistics/$field")"
    done
    printf 'tx_timeout=%s\n' "$(cat "$link/queues/tx-0/tx_timeout")"
    ethtool -S eth1
}
i=0
while [ "$i" -lt 10 ]; do
    while [ ! -f "$base/request-$i" ]; do sleep 0.25; done
    snapshot > "$base/sample-$i.tmp"
    mv "$base/sample-$i.tmp" "$base/sample-$i"
    # Timed clients have a six-second minimum. Sleep through their main load.
    if [ $((i % 2)) = 0 ]; then sleep 6; fi
    i=$((i + 1))
done
