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
[[ "$rounds" =~ ^[1-9][0-9]*$ ]]
[[ "$pause" =~ ^[0-9]+$ ]]
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
for ((r=1;r<=rounds;r++)); do
    # Fresh clients and the Mac relay both allocate TCP source ports. Allow
    # TIME_WAIT to expire between blocks without altering any timed request.
    if (( r > 1 )); then sleep "$pause"; fi
    case $(( (r-1) % 6 )) in
        0) order=(baseline candidate orbstack);; 1) order=(candidate orbstack baseline);; 2) order=(orbstack baseline candidate);;
        3) order=(orbstack candidate baseline);; 4) order=(baseline orbstack candidate);; 5) order=(candidate baseline orbstack);;
    esac
    echo "${order[*]}" > "$out/order-$r"
    for e in "${order[@]}"; do
        sysctl -n vm.loadavg > "$out/$e-$r.load"
        "$NETBENCH" -url "http://$(cat "$out/$e.addr")" -marker "$prefix-$e" -requests "${BENCH_REQUESTS:-400}" \
            -streams 32 -bursts "${BENCH_BURSTS:-3}" -stream-barrier > "$out/$e-$r.json"
    done
done
date -u '+%Y-%m-%dT%H:%M:%SZ' > "$out/finished.utc"
