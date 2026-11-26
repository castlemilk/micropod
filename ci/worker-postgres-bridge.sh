#!/bin/bash
# Run both sides of the SQL check on a unique guest bridge on the selected engine.
set -euo pipefail
[[ ${DOCKER_HOST:-} == unix:///* ]] || { echo "Expected a local worker Docker endpoint" >&2; exit 2; }
job="mp-pg-$(uuidgen | tr '[:upper:]' '[:lower:]')"
network=
server=
cleanup() {
    local status=$?
    trap - EXIT
    # A signal can interrupt a foreground client before Docker auto-removes it.
    docker rm -f "$job-client" >/dev/null 2>&1 || true
    if [[ -n "$server" ]]; then
        docker rm -fv "$server" >/dev/null || status=1
    else
        docker rm -fv "$job-db" >/dev/null 2>&1 || true
    fi
    if [[ -n "$network" ]]; then
        docker network rm "$network" >/dev/null || status=1
    else
        docker network rm "$job" >/dev/null 2>&1 || true
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
network=$(docker network create "$job")
server=$(docker create --name "$job-db" --network "$job" \
    -e POSTGRES_USER=ci -e POSTGRES_PASSWORD=ci -e POSTGRES_DB=ci postgres:16)
docker start "$server" >/dev/null
docker run --rm --name "$job-client" --network "$job" -e PGPASSWORD=ci \
    --entrypoint sh postgres:16 -ec '
        export PGHOST="$1" PGUSER=ci PGDATABASE=ci PGCONNECT_TIMEOUT=2
        for attempt in $(seq 1 60); do
            if pg_isready -q -t 1; then break; fi
            sleep 1
        done
        result=$(psql -XqAtw -v ON_ERROR_STOP=1 -c "CREATE TABLE ci_probe (value integer NOT NULL);
            INSERT INTO ci_probe VALUES (42); SELECT value FROM ci_probe;")
        test "$result" = 42
        echo "Verified PostgreSQL round trip across the guest bridge"
    ' sh "$job-db"
