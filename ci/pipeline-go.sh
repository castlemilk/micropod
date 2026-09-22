#!/bin/bash
# ci/pipeline-go.sh — Go CI pipeline running entirely on micropod.
#
# Stages: image build (deps-first Dockerfile + Go cache mounts) → go vet +
# unit tests in parallel → -race matrix leg → testcontainers-go Postgres
# integration (Ryuk reaper included) → run the built image + exec health
# check. Everything container-shaped goes through the temp shim.
set -euo pipefail

CI_NS="ci-go"
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

APP="$MICROPOD_ROOT/ci/samples/go-app"
IMAGE="ci-go-app:ci"
cd "$APP"

ci_begin
ci_shim_up

ci_stage "build-image" docker build -t "$IMAGE" "$APP"
echo "(context cache:)"
ci_cache_lines

# vet + unit tests are independent: run as parallel legs.
ci_stage "vet" go vet ./... &
VET_PID=$!
(
    cd "$APP"
    ci_stage "unit" go test ./...
) &
UNIT_PID=$!
wait "$VET_PID"
wait "$UNIT_PID"

(
    cd "$APP"
    ci_stage "race" go test -race -count=1 ./...
)

(
    cd "$APP"
    # DOCKER_HOST already points at the temp shim: testcontainers-go
    # (v0.40.0, same as cuttlefish) spins postgres:16 + the Ryuk reaper
    # through it with zero special-casing.
    ci_stage "integration-postgres" go test -tags=integration -count=1 -v ./integration/
)

ci_stage "run-image" bash -c "
    docker rm -f ${CI_NS}-run >/dev/null 2>&1 || true
    docker create --name ${CI_NS}-run $IMAGE >/dev/null
    docker start ${CI_NS}-run >/dev/null
    sleep 2
    docker exec ${CI_NS}-run wget -qO- http://localhost:8080/healthz
    test \$? -eq 0
    docker rm -f ${CI_NS}-run >/dev/null
"

ci_summary
