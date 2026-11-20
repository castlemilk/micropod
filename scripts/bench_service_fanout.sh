#!/bin/bash
# Fresh stock Docker CLI clients fetch the expected service identity via DNS.
# Inputs are cached locally. API setup, execution, output and cleanup are timed.
set -euo pipefail
: "${DOCKER_HOST:?select the worker explicitly}"
clients=${1:?choose 16 or 32 simultaneous jobs}
[[ $clients == 16 || $clients == 32 ]]
server_image=${2:-micropod-qa/netbench:local}
client_image=${3:-alpine:3.23}
net=mp-wave-$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-12)
dir=$(mktemp -d)
cleanup(){ docker rm -f "$net" >/dev/null 2>&1 || true; docker network rm "$net" >/dev/null 2>&1 || true; rm -r "$dir"; }
trap cleanup EXIT
docker network create --internal "$net" >/dev/null
docker run --pull=never --network "$net" --network-alias backend --name "$net" -d "$server_image" -listen :8080 -marker "$net" >/dev/null
# The first request absorbs server readiness. Every timed job must return this token.
test "$(docker run --pull=never --rm --network "$net" "$client_image" wget -qO- http://backend:8080/id)" = "$net"
export net clients dir client_image
/usr/bin/time -p bash -euc '
 pids=()
 for ((i=0;i<clients;i++));do
   docker run --pull=never --rm --network "$net" "$client_image" wget -qO- http://backend:8080/id > "$dir/$i" &
   pids+=("$!")
 done
 failed=0
 for pid in "${pids[@]}";do wait "$pid" || failed=1;done
 for ((i=0;i<clients;i++));do [[ $(cat "$dir/$i") == "$net" ]] || failed=1;done
 exit "$failed"
'
docker rm -f "$net" >/dev/null
docker network rm "$net" >/dev/null
