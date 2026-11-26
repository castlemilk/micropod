#!/bin/bash
# Run against an explicitly selected Docker endpoint with the scripts/netbench image loaded.
set -euo pipefail
: "${DOCKER_HOST:?set the endpoint of the worker to qualify}"
driver=${1:-bridge}
image=${2:-micropod-qa/netbench:local}
quiet_dir=${MICROPOD_BENCH_QUIET_HTTP_DIR:-}
if [[ -n $quiet_dir && ( $quiet_dir != /* || ! -x "$quiet_dir/quiet-http" ) ]]; then
    echo "Expected an absolute shared directory containing the executable quiet-http" >&2
    exit 2
fi
prefix=mp-net-$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-12)
a=$prefix-a
b=$prefix-b
cleanup(){ docker rm -f "$a" "$b" >/dev/null 2>&1 || true; docker network rm "$a" "$b" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker network create --driver "$driver" --internal "$a" >/dev/null
docker network create --driver "$driver" --internal "$b" >/dev/null
for name in "$a" "$b"; do
    docker run --name "$name" -d --network "$name" --network-alias backend "$image" -listen :8080 -marker "$name" >/dev/null
done
if docker network rm "$a" >/dev/null 2>&1; then echo 'network removal accepted an active endpoint' >&2; exit 1; fi
dns_flags=(-lookups "${MICROPOD_BENCH_DNS_LOOKUPS:-200}")
if [[ -n ${MICROPOD_BENCH_DNS_CLIENTS:-} ]]; then dns_flags+=(-dns-clients "$MICROPOD_BENCH_DNS_CLIENTS"); fi
if [[ -n $quiet_dir ]]; then
    for name in "$a" "$b"; do
        docker run --rm --network "$name" --mount "type=bind,source=$quiet_dir,target=/mpcheck,readonly" \
            --entrypoint /mpcheck/quiet-http "$image" -url http://backend:8080 -marker "$name"
    done
fi
for name in "$a" "$b"; do
    docker run --rm --network "$name" "$image" -url http://backend:8080 -marker "$name" "${dns_flags[@]}" -streams 32
done
docker rm -f "$a" "$b" >/dev/null
docker network rm "$a" "$b" >/dev/null
trap - EXIT
