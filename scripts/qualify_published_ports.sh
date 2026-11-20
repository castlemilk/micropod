#!/bin/bash
# Exercise published TCP leases against an explicitly selected native worker.
set -euo pipefail
: "${DOCKER_HOST:?set the Micropod Docker endpoint}"
image=${1:-micropod-qa/netbench:local}
p=mp-lease-$(uuidgen | cut -c1-12 | tr '[:upper:]' '[:lower:]')
cleanup() {
    for n in "$p" "$p-collision" "$p-offline" "$p-reuse" "$p-bridge" "$p-macvlan" "$p-ipvlan"; do
        docker rm -f "$n" >/dev/null 2>&1 || true
    done
    for d in bridge macvlan ipvlan; do docker network rm "$p-$d" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT
serve() {
    local name=$1
    shift
    docker run --pull=never -d --rm --name "$name" "$@" "$image" -listen :8080 -marker "$name" >/dev/null
}
check() {
    local addr=$1 name=$2
    [[ "$addr" == 127.0.0.1:* ]]
    for _ in {1..60}; do
        if [[ $(curl -fsS --max-time 1 "http://$addr/id" 2>/dev/null || true) == "$name" ]]; then return 0; fi
        sleep .05
    done
    return 1
}
serve "$p" -p 127.0.0.1::8080
addr=$(docker port "$p" 8080/tcp)
check "$addr" "$p"
if serve "$p-collision" -p 127.0.0.1::8080 -p "$addr:8080" 2>/dev/null; then exit 1; fi
check "$addr" "$p"
if serve "$p-offline" --network none -p 127.0.0.1::8080 2>/dev/null; then exit 1; fi
docker rm -f "$p" >/dev/null
if curl -fsS --max-time 1 "http://$addr/id" >/dev/null 2>&1; then exit 1; fi
serve "$p-reuse" -p "$addr:8080"
check "$addr" "$p-reuse"
for d in bridge macvlan ipvlan; do
    name=$p-$d
    if ! msg=$(docker network create --internal --driver "$d" "$name" 2>&1); then
        if [[ "$d" == ipvlan && "$msg" == *'create ipvlan link: operation not supported'* ]]; then
            echo 'IPVLAN unavailable on this guest kernel'
            continue
        fi
        echo "$msg" >&2
        exit 1
    fi
    serve "$name" --network "$name" -p 127.0.0.1::8080
    check "$(docker port "$name" 8080/tcp)" "$name"
done
echo 'Passed dynamic and fixed ports, partial collision rollback, offline rejection, removal, reuse, and publication on available internal network drivers.'
