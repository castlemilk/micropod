#!/bin/bash
# Profile a known netbench fixture in place on its Mac host.
set -euo pipefail
: "${NETBENCH:?set the Mac netbench executable}"
: "${PUBLISHED_URL:?set the HTTP URL of the already running netbench container}"
: "${MARKER:?set the expected service identity}"
: "${SUPERVISOR_PID:?set the PID from the Micropod worker session}"
out=${1:?set a new results directory}
root=$(cd "$(dirname "$0")" && pwd)
mkdir "$out"
xcrun clang -Wall -O2 "$root/port_profile_rusage.c" -o "$out/read-usage"
trap 'rm -f "$out/read-usage"' EXIT
for mode in fresh bulk; do
    "$out/read-usage" "$SUPERVISOR_PID" > "$out/$mode.before.json"
    sysctl -n vm.loadavg > "$out/$mode.load"
    "$NETBENCH" -profile "$mode" -url "$PUBLISHED_URL" -marker "$MARKER" \
        -requests "${PROFILE_REQUESTS:-2400}" -streams 32 -bursts "${PROFILE_BURSTS:-72}" > "$out/$mode.json" &
    client=$!
    sample "$SUPERVISOR_PID" 2 1 -file "$out/$mode.sample" > "$out/$mode.sample.log" 2>&1 &
    sampler=$!
    status=0
    wait "$client" || status=$?
    "$out/read-usage" "$SUPERVISOR_PID" > "$out/$mode.after.json"
    wait "$sampler"
    ((status == 0)) || exit "$status"
done
