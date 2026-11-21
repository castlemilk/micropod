#!/bin/bash
# Exercise ordinary Docker clients against a disposable native macvlan worker.
# The alpine image must already be loaded. This script never changes Docker context.
set -euo pipefail
: "${DOCKER_HOST:?select the disposable Micropod worker socket}"
[[ "$DOCKER_HOST" == unix://* ]] && unset DOCKER_CONTEXT
sock=${DOCKER_HOST#unix://}
metrics(){ curl -fsS --unix-socket "$sock" http://localhost/micropod/metrics; }
metrics | jq -e '.network.macvlan_quarantined_ports == 0' >/dev/null
prefix=mp-pub-$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-12)
image=${MICROPOD_TEST_ALPINE:-alpine:3.23}
root=$(cd "$(dirname "$0")/.." && pwd)
: "${MICROPOD_CI_WORKSPACE:?select the worker workspace for the read-only fixture}"
fixture=$(mktemp -d "$MICROPOD_CI_WORKSPACE/mp-port-test.XXXXXXXX")
nets=(); containers=(); held=; guard_pid=
cleanup() {
    local id
    if [[ -n "$guard_pid" ]]; then kill "$guard_pid" 2>/dev/null || true; wait "$guard_pid" 2>/dev/null || true; fi
    if [[ -n "$held" ]]; then kill "$held" 2>/dev/null || true; wait "$held" 2>/dev/null || true; fi
    for id in "${containers[@]}"; do docker rm -f "$id" >/dev/null 2>&1 || true; done
    for id in "${nets[@]}"; do docker network rm "$id" >/dev/null 2>&1 || true; done
    rm -f "$fixture"/{host,service,ready,reused,guard.addr}; rmdir "$fixture"
}
trap cleanup EXIT
# Both the advertised and the private sibling listener bind specifically to
# the container's Docker IP. This covers applications that avoid wildcard binds.
src="$root/guest/runner/testdata/published-service.go"
env -u GOROOT GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -o "$fixture/service" "$src"
env -u GOROOT go build -trimpath -o "$fixture/host" "$src"
for k in a b; do nets+=("$(docker network create --internal "$prefix-$k")"); done
create() {
    local label=$1 network=$2; shift 2
    created=$(docker create --name "$prefix-$label" --network "$network" --mount "type=bind,src=$fixture,dst=/mpcheck,readonly" "$@" "$image" /mpcheck/service serve "$label")
    containers+=("$created")
}
expect() {
    local url=$1 marker=$2 got n
    for n in {1..20}; do
        got=$(curl -fsS --max-time 1 "http://$url/id" 2>/dev/null) && [[ $got == "$marker" ]] && return 0
        sleep .1
    done
    echo "Expected $marker from $url" >&2; return 1
}
create a "$prefix-a" -p 127.0.0.1::8080; a=$created
create b "$prefix-b" -p 127.0.0.1::8080 -p 127.0.0.1::8080; b=$created
docker start "$a" >/dev/null & p=$!
docker start "$b" >/dev/null
wait "$p"
a_addr=$(docker port "$a" 8080/tcp); b_addrs=$(docker port "$b" 8080/tcp)
[[ $(wc -w <<<"$b_addrs") -eq 2 ]]
expect "$a_addr" a
for addr in $b_addrs; do expect "$addr" b; done
a_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$a")
docker exec "$a" wget -q -T 2 -O - "http://$a_ip:8081/id" | grep -qx a
if docker exec "$b" wget -q -T 1 -O - "http://$a_ip:8081/id"; then echo 'Cross-network listener was reachable' >&2; exit 1; fi
guest=$(jq -er .publishedAddress "$(dirname "$sock")/session.json")
"$fixture/host" guard "${guest%.*}.1" "$fixture/guard.addr" & guard_pid=$!
for _ in {1..100}; do [[ -s "$fixture/guard.addr" ]] && break; sleep .05; done
host_addr=$(cat "$fixture/guard.addr")
expect "$host_addr" host
if docker exec "$a" wget -q -T 1 -O - "http://$host_addr/id"; then echo 'Private container reached an unleased host service' >&2; exit 1; fi
if curl -fsS --max-time 1 "http://$guest:8081/id" 2>/dev/null; then echo 'Private container port reached from Mac' >&2; exit 1; fi
create conflict "$prefix-b" -p 127.0.0.1::8081 -p "$a_addr:8080"
if docker start "$created" >/dev/null 2>&1; then echo 'A duplicate host port was accepted' >&2; exit 1; fi
expect "$a_addr" a
"$fixture/host" hold "$a_addr" a "$fixture" & held=$!
for _ in {1..100}; do [[ -e "$fixture/ready" ]] && break; sleep .05; done
[[ -e "$fixture/ready" ]]
docker stop -t 1 "$a" >/dev/null
if curl -fsS --max-time 1 "http://$a_addr/id" 2>/dev/null; then echo 'Retired host port still serves' >&2; exit 1; fi
create replacement "$prefix-a" -p "$a_addr:8080"; replacement=$created
docker start "$replacement" >/dev/null
expect "$a_addr" replacement
touch "$fixture/reused"; wait "$held"; held=
docker rm -f "$a" >/dev/null
expect "$a_addr" replacement
for addr in $b_addrs; do expect "$addr" b; done
docker stop -t 1 "$replacement" >/dev/null
docker start "$replacement" >/dev/null
expect "$a_addr" replacement
metrics | jq -e '.network.macvlan_quarantined_ports == 0' >/dev/null
echo "Passed concurrent ownership, explicit-IP listeners, multiple leases, internal-network and host egress isolation, conflict rollback, revocation of live connections, port reuse and restart."
