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
    if [[ -n "${MICROPOD_BIN:-}" ]]; then
        micropod="$MICROPOD_BIN"
    elif command -v micropod >/dev/null && micropod ci help >/dev/null 2>&1; then
        micropod=micropod
    else
        (cd "$root" && swift build --product micropod >&2)
        micropod="$root/.build/debug/micropod"
        if ! codesign -d --entitlements - "$micropod" 2>/dev/null | python3 -c '
import plistlib,sys
data = sys.stdin.buffer.read()
sys.exit(0 if data and plistlib.loads(data).get("com.apple.security.virtualization") else 1)'; then
            codesign -f -s - --entitlements "$root/signing/micropod-cli.entitlements" "$micropod"
        fi
    fi
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

stage() {
    local name="$1"
    shift
    if [[ -z "${MICROPOD_CI_STAGE_TIMINGS:-}" ]]; then "$@"; return; fi
    python3 -c '
import json, subprocess, sys, time
start = time.perf_counter()
code = subprocess.call(sys.argv[3:])
with open(sys.argv[1], "a") as output:
    output.write(json.dumps([sys.argv[2], round(time.perf_counter() - start, 3), code]) + "\n")
sys.exit(code)' "$MICROPOD_CI_STAGE_TIMINGS" "$name" "$@"
}
parallel_jobs() {
    local first second result=0
    "$1" & first=$!
    "$2" & second=$!
    wait "$first" || result=1
    wait "$second" || result=1
    return "$result"
}

# Unique job tags keep concurrent revisions usable. These four shared tags keep
# the most recent exports unpacked across jobs, with one copy of each layer.
cache_image="${MICROPOD_CI_SAMPLE_IMAGE:-micropod-internal/ci-samples}"
docker_run=(docker run)
if [[ -n "${MICROPOD_PG_PROFILE_IMAGE:-}" ]]; then
    docker_run+=(--label "io.micropod.postgres-profile=${MICROPOD_PG_PROFILE_RUN:?expected a PostgreSQL profile run ID}")
fi
go_postgres() {
    local -a args=(--rm --network host)
    if [[ -n "${MICROPOD_PG_PROFILE_IMAGE:-}" ]]; then
        args+=(-e MICROPOD_PG_PROFILE_IMAGE -e MICROPOD_PG_PROFILE_RUN)
    fi
    stage postgres "${docker_run[@]}" "${args[@]}" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -e TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock \
        -e TESTCONTAINERS_HOST_OVERRIDE=127.0.0.1 \
        --entrypoint /out/postgres-test "$id:checks" -test.v
}
go_service() {
    stage go-image docker build -t "$id:go" -t "$cache_image:go" "$root/ci/samples/go-app"
    "${docker_run[@]}" -d --name "$id-go" "$id:go" >/dev/null
    # shellcheck disable=SC2016
    docker exec "$id-go" sh -ec '
        for attempt in 1 2 3 4 5; do
            if wget -qO- http://localhost:8080/healthz &&
               greeting=$(wget -qO- "http://localhost:8080/?name=ada") &&
               [ "$greeting" = "hello, ada" ]; then
                exit 0
            fi
            sleep 1
        done
        exit 1
    '
}
go_unit() {
    stage go-unit "${docker_run[@]}" --rm --network none --entrypoint /bin/sh "$id:checks" ci-suite.sh test /out
}
go_checks() {
    local app="$root/ci/samples/go-app"
    stage go-checks docker build -f "$app/Dockerfile.checks" -t "$id:checks" -t "$cache_image:checks" "$app"
    parallel_jobs go_unit go_postgres
}
go_job() {
    parallel_jobs go_checks go_service
}
npm_job() {
    local app="$tmp/node"
    mkdir "$app"
    cp "$root/ci/samples/node-app/"{Dockerfile,package.json,package-lock.json} "$app/"
    cp -R "$root/ci/samples/node-app/"{src,test} "$app/"
    stage node-image docker build -t "$id:node" -t "$cache_image:node" "$app"
    # Check the guest's output and execute the suite even when BuildKit reuses the image.
    # shellcheck disable=SC2016
    stage node-unit "${docker_run[@]}" --rm --network none --entrypoint sh "$id:node" -ec '
        npm test
        greeting=$(node src/index.js ada)
        [ "$greeting" = "hello, ada" ]
    '
    echo "console.log('source edit reached the guest')" >> "$app/src/index.js"
    stage node-edit docker build -t "$id:node" -t "$cache_image:node-edited" "$app"
    "${docker_run[@]}" --rm "$id:node" ada | grep -Fx 'source edit reached the guest'
}
case "$profile" in
    go) go_job ;;
    npm) npm_job ;;
    all) parallel_jobs go_job npm_job ;;
esac
