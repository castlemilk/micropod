#!/bin/bash
# The full worker test needs the signed Micropod CLI and a PostgreSQL client.
# --restart additionally exercises shutdown on a dedicated qualification worker.
set -euo pipefail

usage() {
    printf 'Usage\n  %s [--restart]\n  %s --published-ports [--context CONTEXT | --host ENDPOINT] [--check-http]\n  %s --buildx-ci\n' "$0" "$0" "$0"
    printf '  %s --archive --host ENDPOINT --workspace DIR [--overlay-image IMAGE] [--native-retirement]\n' "$0"
    printf '  %s --interactive-exec --host ENDPOINT [--image IMAGE]\n' "$0"
    printf '\nThe published-port check uses a preloaded Alpine image and Python 3.\nUse --check-http when the daemon publishes ports on this host.\n'
}

qualify_published_ports() (
    docker_cli=(docker)
    if [[ ${1-} == --context || ${1-} == --host ]]; then
        if [[ -z ${2-} || $2 == -* ]]; then usage >&2; exit 2; fi
        docker_cli+=("$1" "$2")
        shift 2
    fi
    check_http=false
    if [[ ${1-} == --check-http ]]; then check_http=true; shift; fi
    if [[ $# != 0 ]]; then usage >&2; exit 2; fi

    fail() { printf 'Published-port check failed. %s\n' "$1" >&2; exit 1; }
    d() {
        python3 -c '
import subprocess
import sys

try:
    result = subprocess.run(sys.argv[1:], capture_output=True, timeout=20)
except subprocess.TimeoutExpired:
    sys.exit("Docker CLI timed out after 20 seconds")
sys.stdout.buffer.write(result.stdout)
sys.stderr.buffer.write(result.stderr)
sys.exit(result.returncode)
' "${docker_cli[@]}" "$@"
    }

    if (( ${#docker_cli[@]} == 1 )); then
        # Keep the same selection even if another shell changes the active context.
        context=$(d context show)
        if [[ $context == default && -n ${DOCKER_HOST-} ]]; then
            docker_cli+=(--host "$DOCKER_HOST")
        else
            docker_cli+=(--context "$context")
        fi
    fi
    if $check_http; then command -v curl >/dev/null || fail 'HTTP verification requires curl.'; fi
    image=${MICROPOD_TEST_IMAGE:-alpine:3.23}
    key=mp-port-$(python3 -c 'from uuid import uuid4; print(uuid4().hex)')
    label="io.micropod.qualification=$key"
    # shellcheck disable=SC2329 # Invoked by the EXIT trap.
    cleanup_ports() {
        local owned status=$?
        trap - EXIT
        # Create can succeed on the server after the client loses its answer.
        if owned=$(d container inspect --format '{{.Id}}|{{index .Config.Labels "io.micropod.qualification"}}' "$key" 2>/dev/null) &&
            [[ ${owned#*|} == "$key" && ${owned%%|*} =~ ^[0-9a-f]{64}$ ]]; then
            if (( status != 0 )); then d logs --tail 12 "${owned%%|*}" >&2 || true; fi
            d rm -f "${owned%%|*}" >/dev/null || status=1
        fi
        exit "$status"
    }
    trap cleanup_ports EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    # Alpine's base image includes BusyBox netcat. The handler only returns the run marker.
    fixture=$(cat <<'SH'
printf '%s' "$1" >/tmp/port-check-marker
cat >/tmp/port-check-response <<'HTTP'
#!/bin/sh
cr=$(printf '\r')
while IFS= read -r -t 2 line && [ "$line" != "$cr" ]; do
    :
done
body=$(cat /tmp/port-check-marker)
printf 'HTTP/1.1 200 OK\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' "${#body}" "$body"
HTTP
chmod 700 /tmp/port-check-response
exec timeout -k 2 90 nc -lk -p 8080 -e /tmp/port-check-response
SH
)
    id=$(d create --name "$key" --label "$label" --pull=never -p 127.0.0.1::8080 \
        --entrypoint /bin/sh "$image" -ec "$fixture" sh "$key")
    [[ $id =~ ^[0-9a-f]{64}$ ]] || fail "Unexpected container ID from docker create."
    d start "$id" >/dev/null

    address=$(d port "$id" 8080/tcp)
    if [[ ! $address =~ ^127\.0\.0\.1:([1-9][0-9]{0,4})$ ]] || (( BASH_REMATCH[1] > 65535 )); then
        fail "Expected a dynamically assigned IPv4 loopback port, got [$address] from docker port."
    fi
    format='{{.ID}}|{{.State}}|{{.Ports}}'
    running=$(d ps --no-trunc --filter "id=$id" --format "$format")
    [[ $running == "$id|running|$address->8080/tcp" ]] || fail "Expected docker ps to show $address->8080/tcp, got [$running]."

    if $check_http; then
        deadline=$((SECONDS + 10))
        until response=$(curl -q -fsS --noproxy '*' --max-time 1 "http://$address/" 2>/dev/null) && [[ $response == "$key" ]]; do
            (( SECONDS < deadline )) || fail "The service at $address did not return this run's response."
            sleep .2
        done
        printf 'Matched the test container response over HTTP on %s.\n' "$address"
    fi

    d stop -t 0 "$id" >/dev/null
    stopped=$(d ps -a --no-trunc --filter "id=$id" --format "$format")
    [[ $stopped == "$id|exited|" || $stopped == "$id|exited|8080/tcp" ]] || fail "Expected the stopped container without a published port, got [$stopped]."
    d rm "$id" >/dev/null
    remaining=$(d ps -aq --filter "label=$label")
    [[ -z $remaining ]] || fail "Found test containers after cleanup."
    trap - EXIT
    printf 'Verified that docker ps agreed with docker port on %s->8080/tcp, then removed the test container.\n' "$address"
)

case ${1-} in
    --archive)
        shift
        exec python3 -B "$(dirname "$0")/qualify_docker_archive.py" "$@"
        ;;
    --buildx-ci)
        shift
        exec python3 "$(dirname "$0")/qualify_ci_build.py" "$@"
        ;;
    --interactive-exec)
        shift
        exec python3 -B "$(dirname "$0")/qualify_docker_exec.py" "$@"
        ;;
    --published-ports)
        shift
        qualify_published_ports "$@"
        exit
        ;;
    -h|--help)
        usage
        exit
        ;;
esac

cli=${MICROPOD_CLI:-micropod}
restart=false
if [[ ${1-} == --restart && $# == 1 ]]; then restart=true
elif [[ $# != 0 ]]; then usage >&2; exit 2; fi
if $restart && [[ -z ${MICROPOD_CI_HOME-} ]]; then echo '--restart needs an explicit qualification worker home' >&2; exit 2; fi
endpoint=$("$cli" ci runner-docker-endpoint)
d() { docker --host "$endpoint" "$@"; }
image=${MICROPOD_TEST_IMAGE:-alpine:3.23}
python3 -B "$(dirname "$0")/qualify_docker_exec.py" --host "$endpoint" --image "$image"
database=${MICROPOD_TEST_POSTGRES:-postgres:16-alpine}
key=mp-qual-$(uuidgen | tr '[:upper:]' '[:lower:]')
result=$(mktemp -d)
cleanup() {
    for item in pg collide exit offline; do d rm -f "$key-$item" >/dev/null 2>&1 || true; done
    d volume rm "$key" >/dev/null 2>&1 || true
    rm -f "$result"/{stdout,stderr,stop,collision}
    rmdir "$result"
}
trap cleanup EXIT
d volume create --label "io.micropod.qualification=$key" "$key" >/dev/null
d volume ls -q --filter "label=io.micropod.qualification=$key" | grep -Fx "$key"
if d run --rm --name "$key-offline" --network none "$image" sh -c 'test "$(ls /sys/class/net)" = lo || exit 2; echo first; echo second >&2; exit 17' > "$result/stdout" 2>"$result/stderr"; then exit 1; else code=$?; fi
[[ $code == 17 && $(cat "$result/stdout") == first && $(cat "$result/stderr") == second ]]
[[ -z $(d ps -aq --filter "name=$key-offline") ]]
# The stopped container, label, file and original exit status must survive a clean boot.
d create --name "$key-exit" --mount "type=volume,src=$key,dst=/volume" "$image" sh -c 'echo persisted >/volume/marker; echo saved; exit 23' >/dev/null
d start "$key-exit" >/dev/null
[[ $(d wait "$key-exit") == 23 ]]
export POSTGRES_PASSWORD="$key"
d run -d --name "$key-pg" -e POSTGRES_PASSWORD -p 127.0.0.1::5432 "$database" >/dev/null
address=$(d port "$key-pg" 5432/tcp)
[[ $address == 127.0.0.1:* ]]
port=${address##*:}
export PGPASSWORD="$POSTGRES_PASSWORD"
deadline=$((SECONDS + 60))
until answer=$(PGCONNECT_TIMEOUT=2 psql -XqAt -h 127.0.0.1 -p "$port" -U postgres -d postgres -c 'SELECT 6 * 7' 2>/dev/null); do
    if (( SECONDS >= deadline )); then d logs "$key-pg" >&2; exit 1; fi
    sleep .2
done
[[ $answer == 42 ]]
d stats --no-stream --format '{{json .}}' "$key-pg"
if d exec "$key-pg" sh -c 'echo exec-out; echo exec-err >&2; exit 9' >"$result/stdout" 2>"$result/stderr"; then exit 1; else code=$?; fi
[[ $code == 9 && $(cat "$result/stdout") == exec-out && $(cat "$result/stderr") == exec-err ]]
if d run --rm --name "$key-collide" -p "127.0.0.1:$port:80" "$image" true > "$result/collision" 2>&1; then exit 1; fi
[[ -z $(d ps -aq --filter "name=$key-collide") ]]
if $restart; then
    before=$("$cli" ci runner-status)
    if "$cli" ci runner-stop > "$result/stop" 2>&1; then exit 1; fi
    [[ $(d inspect --format '{{.State.Running}}' "$key-pg") == true ]]
fi
d rm -f "$key-pg" >/dev/null
if pg_isready -q -h 127.0.0.1 -p "$port" -t 1; then exit 1; fi
if $restart; then
    "$cli" ci runner-stop
    after=$("$cli" ci runner-start)
    [[ $(jq -r .worker <<<"$before") == "$(jq -r .worker <<<"$after")" ]]
    [[ $(jq -r .boot <<<"$before") != "$(jq -r .boot <<<"$after")" ]]
    endpoint=$("$cli" ci runner-docker-endpoint)
fi
[[ $(d inspect -f '{{.State.ExitCode}}' "$key-exit") == 23 ]]
[[ $(d logs "$key-exit") == saved ]]
[[ $(d run --rm --mount "type=volume,src=$key,dst=/volume,readonly" "$image" cat /volume/marker) == persisted ]]
d volume ls -q --filter "label=io.micropod.qualification=$key" | grep -Fx "$key"
echo "Passed exit, streams, offline networking, volume, SQL, exec, port collision and cleanup checks. Restart check: $restart."
