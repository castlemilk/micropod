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
# On a multi-CPU worker, keep the dedicated NIC's single IRQ off CPU 0,
# which also handles the egress and filesystem devices. Other queue layouts
# keep the kernel's IRQ policy.
place_published_irq() {
    last=$(awk -F '[-,]' '{print $NF}' /sys/devices/system/cpu/online) || return 1
    [ "$last" -gt 0 ] || return 0
    virtio=$(basename "$(readlink -f /sys/class/net/eth1/device)") || return 1
    irq=$(awk -v name="$virtio" '$NF==name { sub(/:$/, "", $1); print $1 }' /proc/interrupts)
    case "$irq" in ''|*[!0-9]*) return 0;; esac
    echo "$last" > "/proc/irq/$irq/smp_affinity_list"
}
if [ "$pubdev" = eth1 ] && [ "${MICROPOD_CI_PORT_THROUGHPUT:-}" = 1 ]; then
    place_published_irq || echo "Published NIC is using the kernel IRQ affinity" >&2
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
