#!/bin/bash
# Each TSV row contains a fixture name, its service URL and its expected marker.
# Complete every block and retain failed transfers alongside successful timings.
set -euo pipefail
fixtures=${1:?expected fixtures.tsv}
out=${2:?expected a new results directory}
client=${NETBENCH:?expected the Mac netbench executable}
rounds=${ROUNDS:-6}
[[ $rounds =~ ^[1-9][0-9]*$ && -x "$client" && ! -e "$out" ]]
names=()
urls=()
markers=()
while IFS=$'\t' read -r name url marker; do
    [[ $name =~ ^[a-zA-Z0-9_-]+$ && -n "$url" && -n "$marker" ]]
    names+=("$name")
    urls+=("$url")
    markers+=("$marker")
done < "$fixtures"
count=${#names[@]}
(( count >= 2 ))
mkdir "$out"
cp "$fixtures" "$out/fixtures.tsv"
modes=(fresh warm fresh warm fresh warm fresh warm)
barriers=(false false true true false false true true)
transfers=(1 1 1 1 24 24 24 24)
for ((round=0; round<rounds; round++)); do
    for ((block=0; block<8; block++)); do
        shape=$(((block + round) % 8))
        mode=${modes[$shape]}
        barrier=${barriers[$shape]}
        repetitions=${transfers[$shape]}
        # Rotate the first engine for each individual shape across the rounds.
        # Reverse the order on the second rotation for a three-engine crossover.
        start=$(((round + shape) % count))
        for ((offset=0; offset<count; offset++)); do
            if (( (round / count) % 2 == 0 )); then
                engine=$(((start + offset) % count))
            else
                engine=$(((start - offset + count) % count))
            fi
            key="$out/$round-${names[$engine]}-$mode-$barrier-$repetitions"
            date -u '+%FT%TZ' > "$key.start"
            status=0
            "$client" -profile "burst-$mode" -url "${urls[$engine]}" -marker "${markers[$engine]}" \
                -streams 32 -bursts "$repetitions" -stream-barrier="$barrier" > "$key.json" 2>"$key.err" || status=$?
            if (( status == 0 )) && ! jq -e '.initial_connection_mismatches == 0 and .unexpected_reconnects == 0' "$key.json" >/dev/null; then
                echo "Measured connections did not retain the requested socket reuse" >> "$key.err"
                status=1
            fi
            echo "$status" > "$key.status"
            if (( status != 0 )); then
                printf '%s\t%s\n' "${key##*/}" "$status" >> "$out/failed-blocks.tsv"
            fi
        done
    done
done
date -u '+%FT%TZ' > "$out/finished"
[[ ! -s "$out/failed-blocks.tsv" ]]
