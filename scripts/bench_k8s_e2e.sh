#!/usr/bin/env bash
# bench_k8s_e2e.sh — end-to-end image-load → pod-Ready across engines.
#
# Measures the full loop a developer cares about: take an image that exists
# in the local docker daemon, get it into the cluster's container runtime,
# then create a pod and wait for it Ready. Runs N iterations per engine and
# reports each stage plus total.
#
# Engines: micropod k8s, kind, minikube (docker driver). Clusters must
# already exist (`micropod k8s up`, `kind create`, `minikube start`).
#
#   IMG=hellobench:1 RUNS=3 ./scripts/bench_k8s_e2e.sh
#   SKIP=minikube … to skip engines

set -uo pipefail

IMG="${IMG:-hellobench:1}"
RUNS="${RUNS:-3}"
KCFG="${KUBECONFIG:-$HOME/.micropod/k8s/kubeconfig}"
MP="${MICROPOD_BIN:-micropod}"
KIND_NAME="${KIND_NAME:-bench-kind}"
POD="e2e-bench"
SKIP="${SKIP:-}"

banner() { printf '\n=== %s ===\n' "$1"; }
now() { python3 -c 'import time; print(time.time_ns())'; }
elapsed() { local end; end=$(now); python3 -c "print(f'{($end - $1) / 1e9:.2f}')"; }
p50() { python3 -c "import sys; xs = sorted(map(float, sys.argv[1:])); print(f'{xs[len(xs)//2]:.2f}')" "$@"; }

# kubectl helper: first arg is "file" (use $KCFG) or a kubectl context name.
kc() {
    local how="$1"; shift
    if [ "$how" = "file" ]; then
        kubectl --kubeconfig "$KCFG" "$@"
    else
        kubectl --context "$how" "$@"
    fi
}

run_pod() {  # ctx-or-file
    kc "$1" run "$POD" --image="$IMG" --restart=Never \
        --overrides='{"spec":{"containers":[{"name":"'"$POD"'","image":"'"$IMG"'","imagePullPolicy":"IfNotPresent","command":["sh","-c","sleep 3600"]}]}}' \
        >/dev/null 2>&1
}

ready_wait() {  # ctx-or-file → seconds to Ready
    local t0; t0=$(now)
    kc "$1" wait --for=condition=Ready "pod/$POD" --timeout=120s >/dev/null 2>&1
    elapsed "$t0"
}

clean_pod() { kc "$1" delete pod "$POD" --ignore-not-found >/dev/null 2>&1; }

report() {  # engine loads runs totals
    local loads=($2) runs=($3) totals=($4)
    printf '  load:      %6ss  (%s)\n' "$(p50 "${loads[@]}")" "${loads[*]}"
    printf '  run→Ready: %6ss  (%s)\n' "$(p50 "${runs[@]}")" "${runs[*]}"
    printf '  total:     %6ss\n' "$(p50 "${totals[@]}")"
}

bench() {  # name ctx-or-file prep_cmd load_cmd
    local label="$1" ctx="$2" prep="$3" load="$4"
    banner "$label"
    local load_ts=() run_ts=() total_ts=()
    for _ in $(seq 1 "$RUNS"); do
        clean_pod "$ctx"
        eval "$prep" >/dev/null 2>&1 || true
        local t0 t_load t_run
        t0=$(now)
        eval "$load" >/dev/null 2>&1
        t_load=$(elapsed "$t0")
        t0=$(now)
        run_pod "$ctx"
        t_run=$(ready_wait "$ctx")
        load_ts+=("$t_load"); run_ts+=("$t_run")
        total_ts+=("$(python3 -c "print($t_load + $t_run)")")
    done
    report "$label" "${load_ts[*]}" "${run_ts[*]}" "${total_ts[*]}"
}

printf 'image: %s  runs/engine: %d\n' "$IMG" "$RUNS"

[[ "$SKIP" != *micropod* ]] && bench "micropod k8s" file \
    "container exec micropod-k3s ctr -n k8s.io images rm '$IMG' 'docker.io/library/$IMG'; container exec micropod-k3s ctr -n k8s.io content prune references" \
    "'$MP' k8s load '$IMG'"

[[ "$SKIP" != *kind* ]] && bench "kind ($KIND_NAME)" "kind-$KIND_NAME" \
    "docker exec '$KIND_NAME-control-plane' crictl rmi '$IMG'" \
    "kind load docker-image '$IMG' --name '$KIND_NAME'"

[[ "$SKIP" != *minikube* ]] && bench "minikube" minikube \
    "minikube image rm '$IMG'" \
    "minikube image load '$IMG'"

# cleanup
kc file delete pod "$POD" --ignore-not-found >/dev/null 2>&1 || true
kc "kind-$KIND_NAME" delete pod "$POD" --ignore-not-found >/dev/null 2>&1 || true
kc minikube delete pod "$POD" --ignore-not-found >/dev/null 2>&1 || true
