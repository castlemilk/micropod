#!/bin/sh
# Runs only in the private qualification VM, in its initial network namespace.
set -eu
dir="$MICROPOD_ENGINE_WORKSPACE/kernel-observations"
link=/sys/class/net/eth1
trace=/sys/kernel/tracing
instance="$trace/instances/micropod-artifact"
sample() {
    dev=$(basename "$(readlink -f "$link/device")")
    irq=$(awk -v name="$dev" '$NF == name {gsub(":","",$1); print $1}' /proc/interrupts)
    [ -n "$irq" ]
    echo "boot=$(cat /proc/sys/kernel/random/boot_id)"
    echo "virtio=$dev"
    echo "driver=$(basename "$(readlink -f "$link/device/driver")")"
    echo "ifindex=$(cat "$link/ifindex")"
    echo "irq=$irq"
    echo "effective=$(cat "/proc/irq/$irq/effective_affinity_list")"
    awk -v label="$irq:" '$1==label {print "irq_counts="$2","$3","$4","$5}' /proc/interrupts
    awk '$1=="NET_RX:" || $1=="NET_TX:" {gsub(":","",$1); print $1"="$2","$3","$4","$5}' /proc/softirqs
    for key in tx_bytes rx_bytes tx_packets tx_dropped rx_dropped tx_errors rx_errors; do
        echo "$key=$(cat "$link/statistics/$key")"
    done
    ethtool -S eth1 | awk '$1=="tx_kicks:" || $1=="tx0_kicks:" || $1=="tx_tx_timeouts:" {gsub(":","",$1); print $1"="$2}'
}
steering() {
    set -- "$1" "$link"/queues/rx-*/rps_cpus
    [ "$#" = 2 ] && [ -f "$2" ] || return 1
    case "$1" in
        rps-0) echo 0 > "$2" ;;
        rps-7) echo 7 > "$2" ;;
        rps-c|rps-f)
            [ "$(cat /sys/devices/system/cpu/online)" = 0-3 ] || return 1
            echo "${1#rps-}" > "$2"
            ;;
    esac
    sample
    echo "rps_cpus=$(cat "$2")"
    awk '{print "received_rps_" $13 "=" $10}' /proc/net/softnet_stat
}
flow_steering() {
    queue="$link/queues/rx-0/rps_flow_cnt"
    global=/proc/sys/net/core/rps_sock_flow_entries
    if [ "$1" = rfs-on ]; then
        echo 32768 > "$global"
        echo 32768 > "$queue"
    fi
    steering rps-read
    echo "global_flow_entries=$(cat "$global")"
    echo "queue_flow_entries=$(cat "$queue")"
    echo "egress_flow_entries=$(cat /sys/class/net/eth0/queues/rx-0/rps_flow_cnt)"
    awk '{print "softnet_" $13 "=" $1 "," $2 "," $3}' /proc/net/softnet_stat
}
parent_reply_mac() {
    mac=$(cat "$link/address")
    guest=${MICROPOD_CI_PUBLISH_IPV4:?}
    gateway=${MICROPOD_CI_PUBLISH_GATEWAY:?}
    # Replace just the existing leased-TCP rule, retaining its ownership check.
    # Each child still uses its own address for ARP and inside its namespace.
    if [ "$1" = parent-reply-on ]; then
        rules=$(nft -a list chain netdev mp_publication send)
        handle=$(printf '%s\n' "$rules" | awk -v src="$guest" -v dst="$gateway" '
            $1=="ip" && $2=="saddr" && $3==src && $4=="ip" && $5=="daddr" && $6==dst &&
            index($0,"ether saddr . tcp sport @replies") && $(NF-1)=="handle" {print $NF}')
        case "$handle" in ''|*[!0-9]*) echo "unexpected guest reply rule: $rules" >&2; return 1 ;; esac
        nft -f - <<EOF
replace rule netdev mp_publication send handle $handle ip saddr $guest ip daddr $gateway ip protocol tcp ether saddr . tcp sport @replies ether saddr set $mac counter accept
EOF
    fi
    echo "parent_mac=$mac"
    nft list chain netdev mp_publication send
}
publication_tx() {
    parent=$(cat "$link/ifindex")
    owners=$(nft list set netdev mp_publication neighbors)
    cap= tsq=
    case "$1" in
        gso-32768|gso-40960|gso-45056|gso-49152|gso-65536) cap=${1#gso-} ;;
        tsq-98304|tsq-163840|tsq-196608) tsq=${1#tsq-} ;;
    esac
    for nsfile in /var/run/netns/cni-*; do
        ns=${nsfile##*/}
        info=$(ip -n "$ns" -d -o link show dev mppub0 2>/dev/null) || continue
        case "$info" in *"mppub0@if$parent:"*"macvlan mode private"*) ;; *) continue ;; esac
        mac=$(printf '%s\n' "$info" | awk '{for(i=1;i<NF;i++) if($i=="link/ether") print $(i+1)}')
        case "$owners" in *"$mac . "*) ;; *) continue ;; esac
        if [ -n "$cap" ]; then
            ip -n "$ns" link set dev mppub0 gso_ipv4_max_size "$cap"
            info=$(ip -n "$ns" -d -o link show dev mppub0)
        fi
        case "$1" in tsq-*)
            if [ -n "$tsq" ]; then
                ip netns exec "$ns" sysctl -qw "net.ipv4.tcp_limit_output_bytes=$tsq"
            fi
            echo "tsq-$mac $(ip netns exec "$ns" sysctl -n net.ipv4.tcp_limit_output_bytes)"
        ;; esac
        printf '%s\n' "$info" | awk -v mac="$mac" '{for(i=1;i<NF;i++) if($i=="gso_ipv4_max_size") print mac, $(i+1)}'
    done
    if [ -n "$cap" ]; then ip link set dev eth1 gso_ipv4_max_size "$cap"; fi
    case "$1" in tsq-*) echo "tsq-root $(sysctl -n net.ipv4.tcp_limit_output_bytes)" ;; esac
    ip -d -o link show dev eth1 | awk '{for(i=1;i<NF;i++) if($i=="gso_ipv4_max_size") print "parent", $(i+1)}'
    ethtool -k eth1 | awk '$1=="tx-tcp-segmentation:" {print "ipv4-tso", $2}'
}
trace_on() {
    if [ ! -e "$trace/events/syscalls" ]; then mount -t tracefs tracefs "$trace"; fi
    [ -d "$instance" ] || mkdir "$instance"
    echo 0 > "$instance/tracing_on"
    : > "$instance/trace"
    found=0
    for e in "$instance"/events/syscalls/sys_exit_sendfile*; do
        [ -f "$e/enable" ] || continue
        echo 1 > "$e/enable"
        echo "event=$(basename "$e")"
        found=1
    done
    [ "$found" = 1 ] && echo 1 > "$instance/tracing_on"
}
watch_pressure() {
    # Sample into guest RAM. A congested workspace mount must not stall the observer.
    set -- /proc/uptime /proc/stat /proc/net/dev /proc/diskstats
    for file in /proc/pressure/cpu /proc/pressure/io /proc/pressure/memory; do
        if [ -r "$file" ]; then set -- "$@" "$file"; fi
    done
    while :; do
        awk -v epoch="$(date +%s)" '
            BEGIN {printf "epoch=%s", epoch}
            FILENAME=="/proc/uptime" {printf " uptime=%s", $1}
            FILENAME=="/proc/stat" && $1=="cpu" {for (i=2;i<=9;i++) printf " cpu%d=%s", i-2, $i}
            FILENAME=="/proc/stat" && ($1=="procs_running" || $1=="procs_blocked") {printf " %s=%s", $1,$2}
            FILENAME=="/proc/net/dev" && $1=="eth1:" {printf " rx_bytes=%s tx_bytes=%s", $2,$10}
            FILENAME=="/proc/diskstats" && $3 ~ /^vd[a-z]+$/ {
                printf " %s_read_ms=%s %s_write_ms=%s %s_in_flight=%s", $3,$7,$3,$11,$3,$12
            }
            FILENAME ~ /\/pressure\// {
                n=split(FILENAME,path,"/"); split($NF,delta,"="); printf " %s_%s_us=%s",path[n],$1,delta[2]
            }
            END {print ""}
        ' "$@"
        sleep 1
    done
}
watch_pid=
watch_file=
step=0
while :; do
    while [ ! -f "$dir/request-$step" ]; do sleep .1; done
    IFS= read -r action < "$dir/request-$step"
    case "$action" in
        sample) sample > "$dir/result.tmp" ;;
        link-failure)
            {
                ip -s -d link show dev eth1
                ethtool -S eth1
                cat /proc/net/softnet_stat
                dmesg | grep -Ei 'NETDEV WATCHDOG|virtio_net|eth1.*time.?out|rcu.*stall' | tail -40
            } > "$dir/result.tmp" ;;
        rps-read|rps-0|rps-7|rps-c|rps-f) steering "$action" > "$dir/result.tmp" ;;
        rfs-read|rfs-on) flow_steering "$action" > "$dir/result.tmp" ;;
        pressure-start)
            [ -z "$watch_pid" ]
            watch_file=$(mktemp /run/micropod-pressure.XXXXXX)
            watch_pressure > "$watch_file" &
            watch_pid=$!
            echo "$watch_pid" > "$dir/result.tmp"
            ;;
        pressure-stop)
            [ -n "$watch_pid" ]
            kill "$watch_pid"
            wait "$watch_pid" || :
            cat "$watch_file" > "$dir/result.tmp"
            rm -f "$watch_file"
            watch_pid=
            ;;
        parent-reply-on|parent-reply-read) parent_reply_mac "$action" > "$dir/result.tmp" ;;
        gso-read|gso-32768|gso-40960|gso-45056|gso-49152|gso-65536|tsq-read|tsq-98304|tsq-163840|tsq-196608)
            publication_tx "$action" > "$dir/result.tmp" ;;
        qdisc-read|qdisc-fq-codel)
            "$dir/qdisc" "$action" > "$dir/result.tmp" ;;
        runner-sha)
            for exe in /proc/[0-9]*/exe; do
                case "$(readlink "$exe")" in */runner/bin/job) ;; *) continue ;; esac
                mode=$(tr '\000' '\n' < "${exe%exe}cmdline" | sed -n '2p')
                [ "$mode" = engine ] || continue
                sha256sum "$exe" | awk '{print $1}'
            done > "$dir/result.tmp" ;;
        ipv4-tso-off|offloads-read)
            if [ "$action" = ipv4-tso-off ]; then ethtool -K eth1 tx-tcp-segmentation off >&2; fi
            { echo "ifindex=$(cat "$link/ifindex")"; ethtool -k eth1; } > "$dir/result.tmp" ;;
        trace-on) trace_on > "$dir/result.tmp" ;;
        trace-off)
            echo 0 > "$instance/tracing_on"
            cat "$instance/trace" > "$dir/result.tmp"
            echo 0 > "$instance/events/enable" ;;
        done)
            if [ -d "$instance" ]; then rmdir "$instance"; fi
            echo "done" > "$dir/result.tmp" ;;
        *) exit 2 ;;
    esac
    mv "$dir/result.tmp" "$dir/result-$step"
    [ "$action" != "done" ] || exit 0
    step=$((step+1))
done
