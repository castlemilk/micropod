#!/bin/bash
# Exercise sudden VM loss on a fresh private disk. A failed run retains its evidence.
set -euo pipefail
cli=$(realpath "$(command -v "${MICROPOD_CLI:-micropod}")")
qa=$(mktemp -d /private/tmp/micropod-crash.XXXXXXXX)
export MICROPOD_CI_HOME="$qa" MICROPOD_CI_ENGINE=containerd
export MICROPOD_CI_CPUS=2 MICROPOD_CI_MEMORY_MIB=2048 MICROPOD_CI_DISK_GIB=4
unset MICROPOD_CI_WORKSPACE MICROPOD_CI_KATA_TOOLS MICROPOD_CI_MAX_STARTING
unset DOCKER_HOST DOCKER_CONTEXT DOCKER_API_VERSION DOCKER_TLS DOCKER_TLS_VERIFY DOCKER_CERT_PATH
image=${MICROPOD_TEST_IMAGE:-alpine:3.23}
echo "Disposable worker and recovery records at $qa"
trap 'code=$?; if ((code)); then echo "Qualification failed. Worker state is retained at $qa" >&2; fi' EXIT
"$cli" ci runner-start > "$qa/before.json"
endpoint=$("$cli" ci runner-docker-endpoint)
[[ $endpoint == unix://* && $(realpath "$(dirname "${endpoint#unix://}")") == "$qa" ]]
d() { docker --host "$endpoint" "$@"; }
d pull "$image" >/dev/null
d volume create --label io.micropod.qualification=crash qa-volume >/dev/null
d create --name saved -v qa-volume:/v "$image" sh -c 'echo from-volume >/v/saved; sync; echo from-logs; exit 23' >/dev/null
d start saved >/dev/null
[[ $(d wait saved) == 23 ]]
d run -d --name inflight -p 127.0.0.1::80 "$image" sleep 300 >/dev/null
d run -d --rm --name automatic "$image" sleep 300 >/dev/null
port=$(d inspect --format '{{(index (index .NetworkSettings.Ports "80/tcp") 0).HostPort}}' inflight)

# Only interrupt the supervisor launched by this test and holding this disk's lock.
pid=$(jq -er '.owner.pid | select(. > 1)' "$qa/session.json")
[[ $(ps -p "$pid" -o command=) == "$cli ci serve" ]]
lsof -a -p "$pid" "$qa/worker.lock" >/dev/null
kill -KILL "$pid"
for ((i=0; i<100; i++)); do
    if ! ps -p "$pid" >/dev/null; then break; fi
    sleep .05
done
"$cli" ci runner-start > "$qa/after.json"
[[ $("$cli" ci runner-docker-endpoint) == "$endpoint" ]]
[[ $(jq -r .worker "$qa/before.json") == "$(jq -r .worker "$qa/after.json")" ]]
[[ $(jq -r .boot "$qa/before.json") != "$(jq -r .boot "$qa/after.json")" ]]
[[ $(d inspect --format '{{.State.Status}} {{.State.ExitCode}}' inflight) == 'dead -1' ]]
[[ $(d inspect --format '{{.State.ExitCode}}' saved) == 23 && $(d logs saved) == from-logs ]]
[[ -z $(d ps -aq --filter name=automatic) ]]
[[ $(d run --rm -v qa-volume:/v:ro "$image" cat /v/saved) == from-volume ]]
d run --rm -p "127.0.0.1:$port:80" "$image" true
d rm inflight saved >/dev/null
d volume rm qa-volume >/dev/null
[[ -z $(d ps -aq) ]]
"$cli" ci runner-stop
rm "$qa/worker.ext4"
echo 'Passed abrupt supervisor recovery, exit status, logs, volume, auto-remove and port reuse.'
