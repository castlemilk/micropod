#!/bin/bash
# Run with the signed Micropod CLI and PostgreSQL client on a Mac rig.
# --restart additionally exercises shutdown on a dedicated qualification worker.
set -euo pipefail
cli=${MICROPOD_CLI:-micropod}
restart=false
if [[ ${1-} == --restart && $# == 1 ]]; then restart=true
elif [[ $# != 0 ]]; then echo "usage: $0 [--restart]" >&2; exit 2; fi
if $restart && [[ -z ${MICROPOD_CI_HOME-} ]]; then echo '--restart needs an explicit qualification worker home' >&2; exit 2; fi
endpoint=$("$cli" ci runner-docker-endpoint)
d() { docker --host "$endpoint" "$@"; }
image=${MICROPOD_TEST_IMAGE:-alpine:3.23}
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
