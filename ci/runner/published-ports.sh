# Sourced by the native runner bootstrap.
# The broker connects from the vmnet gateway to this VM's own address. Only
# this tuple can enter a published mapping. SNAT also gives internal networks,
# which have no default route, a return path through their own gateway.
pubdev=eth0
if [ -n "${MICROPOD_CI_PUBLISH_IPV4:-}" ]; then
    pubdev=eth1
    gateway=${MICROPOD_CI_PUBLISH_GATEWAY:?missing published gateway}
else
    gateway=$(ip -4 route show default dev eth0 | awk '$1=="default" && $2=="via" { print $3; exit }')
fi
address=$(ip -4 addr show dev "$pubdev" | awk '$1=="inet" { sub(/\/.*/, "", $2); print $2; exit }')
if [ "$pubdev" = eth1 ] && [ "$address" != "$MICROPOD_CI_PUBLISH_IPV4" ]; then
    echo "Host-only published interface has the wrong address" >&2
    exit 1
fi
if [ "$pubdev" = eth1 ] && [ "${MICROPOD_CI_PUBLISHED_PATH:-}" = macvlan ] && [ -n "${MICROPOD_CI_PUBLISHED_GSO_BYTES:-}" ]; then
    ip link set dev "$pubdev" gso_ipv4_max_size "$MICROPOD_CI_PUBLISHED_GSO_BYTES" || {
        echo "Could not set the private interface IPv4 GSO limit to $MICROPOD_CI_PUBLISHED_GSO_BYTES" >&2
        exit 1
    }
fi
# On a multi-CPU worker, keep the dedicated NIC's single IRQ off CPU 0,
# which also handles the egress and filesystem devices. Other queue layouts
# keep the kernel's IRQ policy.
published_irq() {
    virtio=$(basename "$(readlink -f /sys/class/net/eth1/device)") || return 1
    awk -v name="$virtio" '$NF==name { sub(/:$/, "", $1); print $1 }' /proc/interrupts
}
place_published_irq() {
    last=$(awk -F '[-,]' '{print $NF}' /sys/devices/system/cpu/online) || return 1
    [ "$last" -gt 0 ] || return 0
    irq=$(published_irq) || return 1
    case "$irq" in ''|*[!0-9]*) return 0;; esac
    echo "$last" > "/proc/irq/$irq/smp_affinity_list"
}
if [ "$pubdev" = eth1 ] && [ "${MICROPOD_CI_PORT_THROUGHPUT:-}" = 1 ]; then
    place_published_irq || echo "Published NIC is using the kernel IRQ affinity" >&2
fi
# On multi-queue virtio-net (HVF VIRTIO_NET_F_MQ), clear 1:1 CPU->TXQ XPS
# affinity so Linux skb_tx_hash distributes TCP flows evenly across all 4 host
# P-core TX drainer threads without adding cross-CPU RPS IPI latency.
balance_published_mq_tx() (
    set -- /sys/class/net/eth1/queues/tx-*
    [ "$#" -gt 1 ] || return 0
    [ "$(basename "$(readlink -f /sys/class/net/eth1/device/driver)")" = virtio_net ] || return 0
    for qdir in /sys/class/net/eth1/queues/tx-*; do
        [ -w "$qdir/xps_cpus" ] && echo 0 > "$qdir/xps_cpus"
    done
)
if [ "$pubdev" = eth1 ] && [ "${MICROPOD_CI_PORT_THROUGHPUT:-}" = 1 ]; then
    balance_published_mq_tx || echo "Published NIC could not balance multi-queue TX" >&2
fi
# Linux accepts a comma-separated bitmap, with up to eight hex digits per word.
# Use one nibble at a time so the full mask never depends on shell integer width.
off_irq_mask() {
    awk -v excluded="$1" '{
        ranges = split($0, list, ",")
        for (i = 1; i <= ranges; i++) {
            n = split(list[i], ends, "-")
            last = ends[n] + 0
            for (cpu = ends[1] + 0; cpu <= last; cpu++) {
                if (cpu == excluded) { found = 1; continue }
                nibble = int(cpu / 4)
                bits[nibble] += 2 ^ (cpu % 4)
                if (nibble > top) top = nibble
            }
        }
        if (!found) exit 1
        for (i = top + 0; i >= 0; i--) {
            printf "%x", bits[i] + 0
            if (i > 0 && i % 8 == 0) printf ","
        }
        print ""
    }'
}
steer_published_rx() (
    set -- /sys/class/net/eth1/queues/rx-*
    [ "$#" = 1 ] && [ -w "$1/rps_cpus" ] || return 1
    [ "$(basename "$(readlink -f /sys/class/net/eth1/device/driver)")" = virtio_net ] || return 1
    irq=$(published_irq) || return 1
    case "$irq" in ''|*[!0-9]*) return 1;; esac
    cpu=$(cat "/proc/irq/$irq/effective_affinity_list") || return 1
    case "$cpu" in ''|*[!0-9]*) return 1;; esac
    mask=$(off_irq_mask "$cpu" < /sys/devices/system/cpu/online) || return 1
    echo "$mask" > "$1/rps_cpus"
)
if [ "$pubdev" = eth1 ] && [ "${MICROPOD_CI_PUBLISHED_PATH:-}" = macvlan ] && [ "${MICROPOD_CI_PUBLISHED_RPS:-}" = off-irq ]; then
    steer_published_rx || echo "Published NIC could not enable off-IRQ receive steering" >&2
fi
ensure_nat_hook() {
    chain=$1
    shift
    iptables -w 5 -t nat -C "$chain" "$@" 2>/dev/null || iptables -w 5 -t nat -I "$chain" "$@"
}
setup_published_ports() {
    [ -n "$gateway" ] && [ -n "$address" ] || return 1
    iptables-restore -w 5 --noflush <<EOF || return 1
*filter
:MP-PUB-GATE - [0:0]
-F MP-PUB-GATE
-A MP-PUB-GATE -i $pubdev -p tcp -m conntrack --ctstate DNAT --ctdir ORIGINAL --ctorigsrc $gateway --ctorigdst $address -j ACCEPT
-A MP-PUB-GATE -o $pubdev -p tcp -m conntrack --ctstate DNAT --ctdir REPLY --ctorigsrc $gateway --ctorigdst $address -j ACCEPT
-A MP-PUB-GATE -j DROP
COMMIT
*nat
:MP-PUB-IN - [0:0]
-F MP-PUB-IN
COMMIT
EOF
    ensure_nat_hook PREROUTING -i "$pubdev" -s "$gateway" -d "$address" -p tcp -j MP-PUB-IN &&
        ensure_nat_hook POSTROUTING -s "$gateway" -p tcp -m conntrack --ctstate DNAT --ctdir ORIGINAL --ctorigdst "$address" -j MASQUERADE
}
if setup_published_ports; then
    export MICROPOD_PUBLISH_IPV4="$address"
else
    echo "Kernel port forwarding unavailable; using the guest TCP relay" >&2
fi
