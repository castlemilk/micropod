#!/usr/bin/env bash
# bench_k8s.sh — Micropod k8s engine vs kind (Docker Desktop)
#
# Measures:
#   create→Ready latency   (cached images, warm daemon)
#   node memory in use     (kind: docker stats; micropod: guest /proc/meminfo)
#   LoadBalancer reality   (kind needs extra tooling; micropod uses MetalLB)
#
# Usage: scripts/bench_k8s.sh [--keep]
#   --keep leaves both clusters running for poking around.
set -euo pipefail

KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

MP="${MICROPOD_BIN:-micropod}"
KCFG="$HOME/.micropod/k8s/kubeconfig"

banner() { printf '\n=== %s ===\n' "$1"; }

ready_secs() { # $1: a kubectl context/kubeconfig probe command prefix
    local start=$SECONDS
    until $1 get nodes --no-headers 2>/dev/null | grep -q ' Ready '; do
        sleep 1
        [ $((SECONDS - start)) -gt 300 ] && { echo ">300"; return; }
    done
    echo $((SECONDS - start))
}

banner "micropod k8s"
mp_t0=$(python3 -c 'import time; print(time.time())')
$MP k8s up --no-metallb >/dev/null
mp_ready=$(ready_secs "kubectl --kubeconfig $KCFG")
mp_total=$(python3 -c "import time; print(f'{time.time() - $mp_t0:.1f}')")
echo "  up:          ${mp_total}s (${mp_ready}s to node Ready)"
container exec micropod-k3s sh -c 'grep -E "MemTotal|MemAvailable" /proc/meminfo' | \
    awk '{t[$1]=$2} END {printf "  guest used:  %d MB (of %d MB allocated)\n", (t["MemTotal:"]-t["MemAvailable:"])/1024, t["MemTotal:"]/1024}'

banner "kind (Docker Desktop)"
kind delete cluster --name bench-k8s >/dev/null 2>&1 || true
kind_t0=$(python3 -c 'import time; print(time.time())')
kind create cluster --name bench-k8s >/dev/null
kind_ready=$(ready_secs "kubectl --context kind-bench-k8s")
kind_total=$(python3 -c "import time; print(f'{time.time() - $kind_t0:.1f}')")
echo "  up:          ${kind_total}s (${kind_ready}s to node Ready)"
docker stats --no-stream --format '  node mem:    {{.MemUsage}}' bench-k8s-control-plane

banner "LoadBalancer reality check"
kubectl --kubeconfig "$KCFG" create deployment web --image=nginx:alpine >/dev/null 2>&1 || true
kubectl --kubeconfig "$KCFG" expose deployment web --type=LoadBalancer --port=80 >/dev/null 2>&1 || true
lb_ip=""
for _ in $(seq 1 30); do
    lb_ip=$(kubectl --kubeconfig "$KCFG" get svc web -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    [ -n "$lb_ip" ] && break
    sleep 2
done
if [ -n "$lb_ip" ]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$lb_ip/" || true)
    echo "  micropod:    $lb_ip → HTTP $code from the host"
else
    echo "  micropod:    no LB IP (metallb not installed? rerun: $MP k8s up)"
fi
echo "  kind:        LoadBalancer type stays <pending> without extra tools;"

if [ "$KEEP" -eq 0 ]; then
    banner "cleanup"
    kubectl --kubeconfig "$KCFG" delete svc web deployment web >/dev/null 2>&1 || true
    kind delete cluster --name bench-k8s >/dev/null 2>&1 || true
fi

banner "summary"
printf "  %-14s %8s %s\n" "" "up" "node mem"
printf "  %-14s %8s %s\n" "micropod k8s" "${mp_total}s" "(see guest used above)"
printf "  %-14s %8s %s\n" "kind" "${kind_total}s" "(see node mem above)"
