#!/bin/bash
# ci/pipeline-npm.sh — Node CI pipeline running entirely on micropod.
#
# Stages: image build (deps-first Dockerfile + npm cache mount) concurrent
# with host install+test → run the built image and assert its output →
# source-change rebuild (layer re-use proof). Everything container-shaped
# goes through the temp shim.
set -euo pipefail

CI_NS="ci-npm"
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

APP="$MICROPOD_ROOT/ci/samples/node-app"
IMAGE="ci-node-app:ci"

ci_begin
ci_shim_up

# Build and host-side install+test are independent: parallel legs.
ci_stage "build-image" docker build -t "$IMAGE" "$APP" &
BUILD_PID=$!
(
    cd "$APP"
    ci_stage "host-install-test" bash -c "npm ci --no-audit --no-fund >/dev/null && npm test 2>&1 | tail -n 4"
) &
HOST_PID=$!
wait "$BUILD_PID"
wait "$HOST_PID"
echo "(context cache:)"
ci_cache_lines

ci_stage "run-image" bash -c "
    out=\$(docker run --rm $IMAGE ada 2>&1 | tr -d '\r')
    echo \"container output: \$out\"
    echo \"\$out\" | grep -q 'hello, ada'
"

# Rebuild after a source-only change: deps + npm-ci layers must stay CACHED.
cp "$APP/src/index.js" "$APP/src/index.js.bak"
echo "// ci touch" >>"$APP/src/index.js"
ci_stage "rebuild-after-change" docker build -t "$IMAGE" "$APP" >/dev/null
mv "$APP/src/index.js.bak" "$APP/src/index.js"
echo "(context cache:)"
ci_cache_lines

ci_summary
