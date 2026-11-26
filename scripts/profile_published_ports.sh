#!/bin/bash
# Profile a known netbench fixture in place on its Mac host.
set -euo pipefail
: "${NETBENCH:?set the Mac netbench executable}"
: "${PUBLISHED_URL:?set the HTTP URL of the already running netbench container}"
: "${MARKER:?set the expected service identity}"
: "${SUPERVISOR_PID:?set the PID from the Micropod worker session}"
if [[ -n ${VMM_PID:-} && ( ! $VMM_PID =~ ^[1-9][0-9]*$ || ! $SUPERVISOR_PID =~ ^[1-9][0-9]*$ || $VMM_PID == "$SUPERVISOR_PID" ) ]]; then
    echo "Expected distinct supervisor and VMM PIDs" >&2
    exit 2
fi
out=${1:?set a new results directory}
root=$(cd "$(dirname "$0")" && pwd)
mkdir "$out"
xcrun clang -Wall -O2 "$root/port_profile_rusage.c" -o "$out/read-usage"
trap 'rm -f "$out/read-usage"' EXIT
record_usage() {
    local pid=$1 file=$2 first=$3 start
    if [[ -f $first ]]; then
        start=$(/usr/bin/plutil -extract start_ticks raw -o - "$first")
        "$out/read-usage" "$pid" "$start" > "$file"
    else
        "$out/read-usage" "$pid" > "$file"
    fi
}
snapshot() {
    local stage=$1
    record_usage "$SUPERVISOR_PID" "$out/$mode.$stage.json" "$out/fresh.before.json"
    if [[ -n ${VMM_PID:-} ]]; then
        record_usage "$VMM_PID" "$out/$mode.vmm.$stage.json" "$out/fresh.vmm.before.json"
    fi
}
for mode in fresh bulk; do
    snapshot before
    sysctl -n vm.loadavg > "$out/$mode.load"
    "$NETBENCH" -profile "$mode" -url "$PUBLISHED_URL" -marker "$MARKER" \
        -requests "${PROFILE_REQUESTS:-2400}" -streams 32 -bursts "${PROFILE_BURSTS:-72}" > "$out/$mode.json" &
    client=$!
    sample "$SUPERVISOR_PID" 2 1 -file "$out/$mode.sample" > "$out/$mode.sample.log" 2>&1 &
    sampler=$!
    status=0
    wait "$client" || status=$?
    snapshot after
    wait "$sampler"
    ((status == 0)) || exit "$status"
done
