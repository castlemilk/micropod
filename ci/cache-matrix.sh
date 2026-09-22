#!/bin/bash
# ci/cache-matrix.sh — cache re-use validation matrix.
#
# Builds a family of related Go + Node images through the temp shim and
# reports, per build, WHERE the re-use came from:
#   * shim context cache  (HIT = no tar staging, mtime-proof tree-hash)
#   * builder layer cache (#N CACHED steps parsed out of the build log)
#   * shared cache mounts (warm module/npm caches make "re-run" steps instant)
#
# The matrix is designed so sharing is observable:
#   go-svc-a / go-svc-b  same dep set (uuid), different code
#   go-svc-c             different dep set (chi) — genuine fetch
#   node-app / node-app-b same dep (picocolors), different code
#   node-app-c           different dep (nanoid) — genuine fetch
#
# Deterministic assertions (fail the run if violated):
#   * an identical rebuild gets a context-cache HIT,
#   * an identical rebuild keeps its build steps CACHED,
#   * a touch-only rebuild (fresh mtimes, same bytes) still HITs,
#   * every built image runs and prints its expected line.
set -euo pipefail

CI_NS="ci-mx"
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

SAMPLES_DIR="$MICROPOD_ROOT/ci/samples"

# name|dir|run-args|expected-output-grep
MATRIX="
go-svc-a|go-svc-a||svc-a ok
go-svc-b|go-svc-b||svc-b ok
go-svc-c|go-svc-c||svc-c ok
node-app|node-app||hello, world
node-app-b|node-app-b||hey, world!
node-app-c|node-app-c|^tok-
"

RESULTS=""
FAILURES=0

# Build one sample; echoes "wall|cached|done|hitmiss".
mx_build() {
    local name="$1" dir="$2"
    local log="$CI_TMP/build-$name.log"
    local start end
    start=$(python3 -c "import time; print(time.time())")
    if ! docker build -t "ci-mx-$name:ci" "$SAMPLES_DIR/$dir" >"$log" 2>&1; then
        echo "BUILD FAILED: $name (see $log)" >&2
        tail -n 15 "$log" >&2
        return 1
    fi
    end=$(python3 -c "import time; print(time.time())")
    local wall cached done_steps hitmiss
    wall=$(python3 -c "print('%.1f' % ($end-$start))")
    cached=$(grep -cE "^#[0-9]+ CACHED" "$log" || true)
    done_steps=$(grep -cE "^#[0-9]+ DONE" "$log" || true)
    hitmiss=$(grep "context-cache" "$SHIM_LOG" | tail -n 1 | grep -oE "HIT|MISS" || echo "?")
    echo "$wall|$cached|$done_steps|$hitmiss"
}

mx_run_assert() {
    local name="$1" args="$2" expect="$3"
    local out
    # shellcheck disable=SC2086
    out=$(docker run --rm "ci-mx-$name:ci" $args 2>&1 | tr -d '\r')
    if echo "$out" | grep -Eq "$expect"; then
        echo "run-ok"
    else
        echo "RUN MISMATCH ($name): got [$out], want /$expect/" >&2
        return 1
    fi
}

main() {
    ci_begin
    ci_shim_up
    CI_TMP_MATRIX_RESULTS="$CI_TMP/results.tsv"
    RESULTS="$CI_TMP_MATRIX_RESULTS"
    : >"$RESULTS"

    echo "=== cache matrix: fresh builds ==="
    printf "%-12s %8s %12s %14s\n" "sample" "wall(s)" "steps(C/D)" "ctx"
    while IFS='|' read -r name dir args expect; do
        [ -z "$name" ] && continue
        if result=$(mx_build "$name" "$dir"); then
            echo "$name|$result" >>"$RESULTS"
            printf "%-12s %8s %7s/%-5s %14s\n" "$name" \
                "$(echo "$result" | cut -d'|' -f1)" \
                "$(echo "$result" | cut -d'|' -f2)" \
                "$(echo "$result" | cut -d'|' -f3)" \
                "$(echo "$result" | cut -d'|' -f4)"
        else
            FAILURES=$((FAILURES + 1))
        fi
        if ! mx_run_assert "$name" "$args" "$expect" >/dev/null; then
            FAILURES=$((FAILURES + 1))
        fi
    done <<<"$MATRIX"

    echo "=== cross-context file sharing (svc-a/b share Dockerfile+go.sum) ==="
    shared_bytes=$("$MICROPOD_ROOT/.build/debug/micropod" build-cache stats 2>/dev/null \
        | awk '/^shared-bytes:/ {print $2}')
    echo "shared-bytes across retained contexts: ${shared_bytes:-?}"
    [ "${shared_bytes:-0}" -gt 0 ] || {
        echo "FAIL: expected shared file bytes between related contexts" >&2
        FAILURES=$((FAILURES + 1))
    }

    echo "=== identical rebuild must HIT context cache + keep layers CACHED ==="
    if result=$(mx_build "go-svc-a" "go-svc-a"); then
        echo "go-svc-a rebuild: wall=$(echo "$result" | cut -d'|' -f1)s" \
            "cached=$(echo "$result" | cut -d'|' -f2)" \
            "ctx=$(echo "$result" | cut -d'|' -f4)"
        [ "$(echo "$result" | cut -d'|' -f4)" = "HIT" ] || {
            echo "FAIL: identical rebuild missed the context cache" >&2
            FAILURES=$((FAILURES + 1))
        }
        [ "$(echo "$result" | cut -d'|' -f2)" -ge 3 ] || {
            echo "FAIL: identical rebuild lost layer cache" >&2
            FAILURES=$((FAILURES + 1))
        }
    else
        FAILURES=$((FAILURES + 1))
    fi

    echo "=== touch-only rebuild must still HIT (mtime-proof hashing) ==="
    # Guarded: node_modules symlinks can make touch exit nonzero; the rebuild
    # assertion below is what actually validates.
    find "$SAMPLES_DIR/node-app" -exec touch -d "2020-01-01" {} + 2>/dev/null || true
    if result=$(mx_build "node-app" "node-app"); then
        echo "node-app touch-rebuild: wall=$(echo "$result" | cut -d'|' -f1)s" \
            "ctx=$(echo "$result" | cut -d'|' -f4)"
        [ "$(echo "$result" | cut -d'|' -f4)" = "HIT" ] || {
            echo "FAIL: touch-only rebuild missed the context cache" >&2
            FAILURES=$((FAILURES + 1))
        }
    else
        FAILURES=$((FAILURES + 1))
    fi

    echo "=== run assertions ==="
    while IFS='|' read -r name dir args expect; do
        [ -z "$name" ] && continue
        if out=$(mx_run_assert "$name" "$args" "$expect"); then
            echo "$name: $out"
        else
            FAILURES=$((FAILURES + 1))
        fi
    done <<<"$MATRIX"

    if [ "$FAILURES" -gt 0 ]; then
        echo "== MATRIX FAIL ($FAILURES failures) =="
        return 1
    fi
    ci_summary
}

main "$@"
