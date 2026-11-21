#!/bin/bash
# Run on the Mac with the same scripts/netbench image preloaded in each engine.
set -euo pipefail
: "${BASELINE_HOST:?set the previous Micropod Docker endpoint}"
: "${CANDIDATE_HOST:?set the candidate Micropod Docker endpoint}"
: "${ORBSTACK_HOST:?set the OrbStack Docker endpoint}"
: "${NETBENCH:?set the path to the Mac scripts/netbench executable}"
out=${1:?set a new results directory}
image=${BENCH_IMAGE:-micropod-qa/netbench:local}
rounds=${BENCH_ROUNDS:-6}
pause=${BENCH_ROUND_PAUSE:-8}
mixed=${BENCH_MIXED_ROUNDS:-0}
record_failures=${BENCH_RECORD_FAILURES:-0}
max_time_wait=${BENCH_MAX_TIME_WAIT:-0}
[[ "$rounds" =~ ^(0|[1-9][0-9]*)$ && "$mixed" =~ ^(0|[1-9][0-9]*)$ ]]
(( rounds > 0 || mixed > 0 ))
[[ "$pause" =~ ^[0-9]+$ ]]
[[ "$record_failures" =~ ^[01]$ && "$max_time_wait" =~ ^(0|[1-9][0-9]*)$ ]]
mkdir "$out"
date -u '+%Y-%m-%dT%H:%M:%SZ' > "$out/started.utc"
sysctl -n machdep.cpu.brand_string hw.physicalcpu hw.memsize > "$out/hardware"
sw_vers > "$out/macos"
sysctl net.inet.ip.portrange.first net.inet.ip.portrange.last net.inet.tcp.msl > "$out/tcp-limits"
echo "$pause" > "$out/round-pause-seconds"
unset DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH DOCKER_API_VERSION
prefix=mp-pub-$(uuidgen | cut -c1-12 | tr '[:upper:]' '[:lower:]')
engines=(baseline candidate orbstack)
socket() {
    case "$1" in baseline) echo "$BASELINE_HOST";; candidate) echo "$CANDIDATE_HOST";; orbstack) echo "$ORBSTACK_HOST";; esac
}
cleanup() {
    for e in "${engines[@]}"; do docker --host "$(socket "$e")" rm -f "$prefix-$e" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT
for e in "${engines[@]}"; do
    sock=$(socket "$e")
    name=$prefix-$e
    docker --host "$sock" info --format '{{json .NCPU}} {{json .MemTotal}} {{json .ServerVersion}}' > "$out/$e.resources"
    docker --host "$sock" image save -o "$out/$e.tar" "$image"
    config=$(tar -xOf "$out/$e.tar" manifest.json | jq -er '.[0].Config')
    tar -xOf "$out/$e.tar" "$config" | shasum -a 256 | awk '{ print $1 }' > "$out/$e.config-sha256"
    tar -xOf "$out/$e.tar" "$config" | jq -c '{os, architecture, rootfs}' > "$out/$e.rootfs"
    rm "$out/$e.tar"
    cmp "$out/baseline.config-sha256" "$out/$e.config-sha256"
    cmp "$out/baseline.rootfs" "$out/$e.rootfs"
    docker --host "$sock" run --pull=never -d --rm --name "$name" -p 127.0.0.1::8080 "$image" -listen :8080 -marker "$name" >/dev/null
    docker --host "$sock" port "$name" 8080/tcp > "$out/$e.addr"
    url=http://$(cat "$out/$e.addr")/id
    for _ in {1..100}; do [[ $(curl -fsS --max-time 1 "$url" 2>/dev/null || true) == "$name" ]] && break; sleep .05; done
    [[ $(curl -fsS --max-time 2 "$url") == "$name" ]]
done
set_order() {
    case $(( ($1-1) % 6 )) in
        0) order=(baseline candidate orbstack);; 1) order=(candidate orbstack baseline);; 2) order=(orbstack baseline candidate);;
        3) order=(orbstack candidate baseline);; 4) order=(baseline orbstack candidate);; 5) order=(candidate baseline orbstack);;
    esac
}
wait_for_ports() {
    local dest=$1 count begin=$SECONDS
    (( max_time_wait > 0 )) || return 0
    while :; do
        count=$(netstat -an -p tcp | awk '$NF == "TIME_WAIT" || $NF == "SYN_SENT" {n++} END {print n+0}') || return 1
        printf '%s\t%s\n' "$((SECONDS - begin))" "$count" >> "$dest.ports"
        (( count <= max_time_wait )) && return 0
        if (( SECONDS - begin >= 90 )); then
            echo "TCP port headroom unavailable before timing" > "$dest.error"
            return 1
        fi
        sleep 2
    done
}
for ((r=1;r<=rounds;r++)); do
    # Fresh clients and the Mac relay both allocate TCP source ports. Allow
    # TIME_WAIT to expire between blocks without altering any timed request.
    if (( r > 1 )); then sleep "$pause"; fi
    set_order "$r"
    echo "${order[*]}" > "$out/order-$r"
    for e in "${order[@]}"; do
        dest="$out/$e-$r"
        status=0
        if wait_for_ports "$dest"; then
            sysctl -n vm.loadavg > "$dest.load"
            "$NETBENCH" -url "http://$(cat "$out/$e.addr")" -marker "$prefix-$e" -requests "${BENCH_REQUESTS:-400}" \
                -streams 32 -bursts "${BENCH_BURSTS:-3}" -stream-barrier > "$dest.json" 2> "$dest.error" || status=$?
        else
            status=1
        fi
        if (( status != 0 )); then
            printf '%s\t%s\t%s\n' "$r" "$e" "$status" >> "$out/failed-blocks.tsv"
            cat "$dest.error" >&2
            (( record_failures == 1 )) || exit "$status"
        fi
    done
done
# Exercise interactive clients while large transfers use the same published
# listener. Both workloads verify the service and write independent receipts.
for ((r=1;r<=mixed;r++)); do
    set_order "$r"
    echo "${order[*]}" > "$out/mixed-order-$r"
    for e in "${order[@]}"; do
        prefix_out="$out/mixed-$r-$e"
        url="http://$(cat "$out/$e.addr")"
        sysctl -n vm.loadavg > "$prefix_out.load"
        "$NETBENCH" -profile bulk -url "$url" -marker "$prefix-$e" -streams 32 -bursts 24 > "$prefix_out.bulk" &
        bulk_pid=$!
        sleep .04
        fresh_status=0
        "$NETBENCH" -profile fresh -url "$url" -marker "$prefix-$e" -requests 240 > "$prefix_out.fresh" || fresh_status=$?
        wait "$bulk_pid"
        ((fresh_status == 0)) || exit "$fresh_status"
    done
done
date -u '+%Y-%m-%dT%H:%M:%SZ' > "$out/finished.utc"
[[ ! -s "$out/failed-blocks.tsv" ]]
