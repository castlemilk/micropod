#!/bin/bash
# Run trusted Go and Node jobs on the same persistent Linux worker.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
profile="${1:-all}"
case "$profile" in go|npm|all) ;; *) echo "expected go, npm, or all" >&2; exit 2 ;; esac
if [[ $# -eq 2 ]]; then
    # Qualification passes the selected guest or native engine's explicit socket.
    endpoint="$2"
else
    micropod="${MICROPOD_BIN:-micropod}"
    endpoint="$("$micropod" ci endpoint)"
fi
[[ "$endpoint" == unix:///* ]] || { echo "expected a local worker socket" >&2; exit 1; }
unset DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH BUILDX_BUILDER
export DOCKER_HOST="$endpoint" DOCKER_BUILDKIT=1
id="mp-ci-$(uuidgen | tr '[:upper:]' '[:lower:]')"
tmp="$(mktemp -d)"
cleanup() {
    docker rm -f "$id-go" >/dev/null 2>&1 || true
    docker image rm "$id:node" "$id:go" "$id:checks" >/dev/null 2>&1 || true
    rm -rf "$tmp"
}
trap cleanup EXIT

go_job() {
    local app="$root/ci/samples/go-app"
    docker build -f "$app/Dockerfile.checks" -t "$id:checks" "$app"
    docker run --rm --network host \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -e TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock \
        -e TESTCONTAINERS_HOST_OVERRIDE=127.0.0.1 \
        --entrypoint /out/postgres-test "$id:checks" -test.v
    docker build -t "$id:go" "$app"
    docker run -d --name "$id-go" "$id:go" >/dev/null
    docker exec "$id-go" sh -ec 'for x in 1 2 3 4 5; do if wget -qO- http://localhost:8080/healthz; then exit 0; fi; sleep 1; done; exit 1'
}
npm_job() {
    local app="$tmp/node"
    mkdir "$app"
    cp "$root/ci/samples/node-app/"{Dockerfile,package.json,package-lock.json} "$app/"
    cp -R "$root/ci/samples/node-app/"{src,test} "$app/"
    docker build -t "$id:node" "$app"
    [[ "$(docker run --rm "$id:node" ada)" == 'hello, ada' ]]
    echo "console.log('source edit reached the guest')" >> "$app/src/index.js"
    docker build -t "$id:node" "$app"
    docker run --rm "$id:node" ada | grep -Fx 'source edit reached the guest'
}
case "$profile" in
    go) go_job ;;
    npm) npm_job ;;
    all)
        go_job & go_pid=$!
        npm_job & npm_pid=$!
        result=0
        wait "$go_pid" || result=1
        wait "$npm_pid" || result=1
        exit "$result" ;;
esac
