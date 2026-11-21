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
overlap=${BENCH_OVERLAP_ROUNDS:-0}
record_failures=${BENCH_RECORD_FAILURES:-0}
max_time_wait=${BENCH_MAX_TIME_WAIT:-0}
container_cpus=${BENCH_CONTAINER_CPUS:-}
probe_dir=${BENCH_GUEST_PROBE_DIR:-}
network_counters=${BENCH_NETWORK_COUNTERS:-0}
[[ $network_counters =~ ^[01]$ && ( $network_counters == 0 || -n "$probe_dir" ) ]]
run_args=(--pull=never)
if [[ -n "$container_cpus" ]]; then
    if [[ "$container_cpus" == max ]]; then
        expected_quota='max 100000'
        run_args+=(--cpu-quota=-1)
    elif [[ "$container_cpus" =~ ^([0-9]+([.][0-9]{1,9})?|[.][0-9]{1,9})$ ]]; then
        # Docker's 100 ms CFS period represents the first five decimal places in microseconds.
        expected_quota=$(awk -v cpus="$container_cpus" 'BEGIN { split(cpus, a, /[.]/); printf "%.0f 100000", a[1]*100000 + substr(a[2]"00000", 1, 5) }')
        [[ "$expected_quota" != '0 100000' ]] || { echo "CPU quota must be positive" >&2; exit 2; }
        run_args+=(--cpus "$container_cpus")
    else
        echo "BENCH_CONTAINER_CPUS must be a positive CPU count or max" >&2
        exit 2
    fi
    : "${probe_dir:?set BENCH_GUEST_PROBE_DIR to a shared directory containing the Linux netbench binary}"
    run_args+=(--memory 1g --pids-limit 512)
fi
if [[ -n "$probe_dir" ]]; then
    [[ "$probe_dir" == /* && -x "$probe_dir/netbench" ]] || { echo "missing Linux netbench in absolute probe directory" >&2; exit 2; }
    run_args+=(--mount "type=bind,source=$probe_dir,target=/mpcheck,readonly")
fi
[[ "$rounds" =~ ^(0|[1-9][0-9]*)$ && "$mixed" =~ ^(0|[1-9][0-9]*)$ && "$overlap" =~ ^(0|[1-9][0-9]*)$ ]]
(( rounds > 0 || mixed > 0 || overlap > 0 ))
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
    docker --host "$sock" run "${run_args[@]}" -d --rm --name "$name" -p 127.0.0.1::8080 "$image" -listen :8080 -marker "$name" >/dev/null
    docker --host "$sock" inspect "$name" --format '{{json .HostConfig}}' |
        jq '{NanoCpus, CpuQuota, CpuPeriod, Memory, PidsLimit}' > "$out/$e.requested-limits"
    if [[ -n "$probe_dir" ]]; then
        docker --host "$sock" exec "$name" /mpcheck/netbench -cgroup-info > "$out/$e.cgroups"
        if [[ -n "$container_cpus" ]]; then
            jq -e --arg quota "$expected_quota" '.["cpu.max"] == $quota and .["memory.max"] == "1073741824" and .["pids.max"] == "512"' "$out/$e.cgroups" >/dev/null ||
                { echo "$e has different resource limits from the requested comparison" >&2; exit 1; }
        fi
    fi
    docker --host "$sock" port "$name" 8080/tcp > "$out/$e.addr"
    url=http://$(cat "$out/$e.addr")/id
    for _ in {1..100}; do [[ $(curl -fsS --max-time 1 "$url" 2>/dev/null || true) == "$name" ]] && break; sleep .05; done
    [[ $(curl -fsS --max-time 2 "$url") == "$name" ]]
done
snapshot_network() {
    (( network_counters == 1 )) || return 0
    local stage=$1 engine
    for engine in "${engines[@]}"; do
        docker --host "$(socket "$engine")" exec "$prefix-$engine" /mpcheck/netbench -net-info > "$out/$engine.network-$stage.json"
    done
}
snapshot_network before
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
record_failure() {
    local block=$1 engine=$2 status=$3 logfile=$4
    printf '%s\t%s\t%s\n' "$block" "$engine" "$status" >> "$out/failed-blocks.tsv"
    cat "$logfile" >&2
    if (( network_counters == 1 )); then
        local counts="$out/$block-$engine.network-error"
        if ! docker --host "$(socket "$engine")" exec "$prefix-$engine" /mpcheck/netbench -net-info > "$counts.json" 2>"$counts.stderr"; then
            echo "Could not read $engine service counters after $block" >&2
        fi
    fi
    (( record_failures == 1 )) || exit "$status"
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
            record_failure "$r" "$e" "$status" "$dest.error"
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
        if ! wait_for_ports "$prefix_out"; then
            record_failure "mixed-$r" "$e" 1 "$prefix_out.error"
            continue
        fi
        sysctl -n vm.loadavg > "$prefix_out.load"
        "$NETBENCH" -profile bulk -url "$url" -marker "$prefix-$e" -streams 32 -bursts 24 > "$prefix_out.bulk" 2> "$prefix_out.bulk.error" &
        bulk_pid=$!
        sleep .04
        status=0
        "$NETBENCH" -profile fresh -url "$url" -marker "$prefix-$e" -requests 240 > "$prefix_out.fresh" 2> "$prefix_out.fresh.error" || status=$?
        wait "$bulk_pid" || status=$?
        if (( status != 0 )); then
            cat "$prefix_out.bulk.error" "$prefix_out.fresh.error" > "$prefix_out.error"
            record_failure "mixed-$r" "$e" "$status" "$prefix_out.error"
        fi
    done
done
# All streams finish one download before the fresh client starts. Keep them
# transferring until its final response and report bytes in that interval.
for ((r=1;r<=overlap;r++)); do
    set_order "$r"
    echo "${order[*]}" > "$out/overlap-order-$r"
    for e in "${order[@]}"; do
        dest="$out/overlap-$r-$e"
        status=0
        if wait_for_ports "$dest"; then
            sysctl -n vm.loadavg > "$dest.load"
            "$NETBENCH" -profile mixed -url "http://$(cat "$out/$e.addr")" -marker "$prefix-$e" \
                -streams 32 -requests 240 > "$dest.json" 2> "$dest.error" || status=$?
        else
            status=1
        fi
        if (( status == 0 )) && ! jq -e '
            .reopened_connections == 0 and
            (.overlap_bytes_per_stream | length == 32 and all(.[]; . > 0))
        ' "$dest.json" >/dev/null; then
            echo "A bulk connection reopened or failed to transfer bytes during the mixed benchmark" >> "$dest.error"
            status=1
        fi
        if (( status != 0 )); then
            record_failure "overlap-$r" "$e" "$status" "$dest.error"
        fi
    done
done
snapshot_network after
date -u '+%Y-%m-%dT%H:%M:%SZ' > "$out/finished.utc"
[[ ! -s "$out/failed-blocks.tsv" ]]
