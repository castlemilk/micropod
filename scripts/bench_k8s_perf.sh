#!/usr/bin/env bash
# bench_k8s_perf.sh — k8s engine performance profile
#
#   pod launch   create→Running, image cached (p50 over N=10) + 5-pod burst
#   apiserver    kubectl get latency (p50 over N=30)
#   ingress      traefik route on the node IP — p50 latency + sequential rps
#   footprint    guest memory used, host VM RSS, idle CPU% (5s sample)
#
# Runs against the micropod k8s engine; with `--compare` repeats the pod-launch
# + apiserver probes against a kind cluster (LoadBalancer/ingress can't be
# compared — kind's live behind the Docker VM NAT).
set -euo pipefail

KCFG="${KUBECONFIG:-$HOME/.micropod/k8s/kubeconfig}"
MP="${MICROPOD_BIN:-micropod}"
NODE_IP="${K8S_IP:-}"

p50() { # ms, floats on stdin
    python3 -c 'import sys,statistics
v=sorted(float(x) for x in sys.stdin if x.strip())
print(f"{v[len(v)//2]:.0f}" if v else "n/a")'
}

node_ip() {
    kubectl --kubeconfig "$KCFG" get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'
}

ready_wait() { # $1 name — poll pod until Ready
    local start_ns=$(python3 -c 'import time; print(time.time_ns())')
    until kubectl --kubeconfig "$KCFG" get pod "$1" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null | grep -q true; do
        sleep 0.5
    done
    python3 -c "import time; print((time.time_ns() - $start_ns) / 1e6)"
}

banner() { printf '\n=== %s ===\n' "$1"; }

[ -z "$NODE_IP" ] && NODE_IP=$(node_ip)
echo "cluster node: $NODE_IP"

banner "pod launch (image cached, create→Ready)"
kubectl --kubeconfig "$KCFG" run warm --image=nginx:alpine --restart=Never --overrides='{}' >/dev/null 2>&1 || true
kubectl --kubeconfig "$KCFG" wait --for=condition=Ready pod/warm --timeout=120s >/dev/null 2>&1 || true
kubectl --kubeconfig "$KCFG" delete pod warm >/dev/null 2>&1 || true
for i in $(seq 1 10); do
    kubectl --kubeconfig "$KCFG" run p$i --image=nginx:alpine --restart=Never >/dev/null
    echo "$(ready_wait p$i)" 
    kubectl --kubeconfig "$KCFG" delete pod p$i >/dev/null 2>&1 &
done | p50 | xargs -I{} echo "  p50: {} ms"
wait

banner "pod burst (5 pods, create→all Ready)"
bstart=$(python3 -c 'import time; print(time.time_ns())')
for i in $(seq 1 5); do kubectl --kubeconfig "$KCFG" run burst$i --image=nginx:alpine --restart=Never >/dev/null; done
kubectl --kubeconfig "$KCFG" wait --for=condition=Ready pod -l 'run' --field-selector=status.phase=Running --timeout=180s >/dev/null 2>&1 || true
for i in $(seq 1 5); do kubectl --kubeconfig "$KCFG" wait --for=condition=Ready pod/burst$i --timeout=180s >/dev/null 2>&1 || true; done
python3 -c "import time; print(f'  all 5 Ready: {(time.time_ns() - $bstart)/1e9:.1f} s')"
for i in $(seq 1 5); do kubectl --kubeconfig "$KCFG" delete pod burst$i >/dev/null 2>&1 & done; wait

banner "apiserver latency (kubectl get nodes, n=30)"
for _ in $(seq 1 30); do
    t0=$(python3 -c 'import time; print(time.time_ns())')
    kubectl --kubeconfig "$KCFG" get nodes >/dev/null
    python3 -c "import time; print((time.time_ns() - $t0) / 1e6)"
done | p50 | xargs -I{} echo "  p50: {} ms"

banner "ingress (traefik on $NODE_IP)"
kubectl --kubeconfig "$KCFG" create deployment web --image=nginx:alpine >/dev/null 2>&1 || true
kubectl --kubeconfig "$KCFG" expose deployment web --port=80 >/dev/null 2>&1 || true
cat <<'EOF' | kubectl --kubeconfig "$KCFG" apply -f - >/dev/null 2>&1
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: {name: web, annotations: {"traefik.ingress.kubernetes.io/router.entrypoints": web}}
spec:
  rules:
  - host: web.local
    http: {paths: [{path: /, pathType: Prefix, backend: {service: {name: web, port: {number: 80}}}}]}
EOF
kubectl --kubeconfig "$KCFG" wait --for=condition=Ready pod -l app=web --timeout=120s >/dev/null 2>&1 || true
sleep 2
# traefik's Service is type LoadBalancer: with MetalLB/servicelb it answers on
# :80 of its LB IP; without them fall back to its NodePort on the node IP.
TPORT=80
if ! curl -s -o /dev/null --max-time 3 -H 'Host: web.local' "http://$NODE_IP/" | grep -q .; then
    TPORT=$(kubectl --kubeconfig "$KCFG" get svc -n kube-system traefik -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || echo 80)
    echo "  (no LB IP — using traefik NodePort $TPORT)"
fi
ok=0; for _ in $(seq 1 20); do
    t0=$(python3 -c 'import time; print(time.time_ns())')
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: web.local' "http://$NODE_IP:$TPORT/")
    [ "$code" = "200" ] && ok=$((ok+1)) && python3 -c "import time; print((time.time_ns() - $t0) / 1e6)"
done | p50 | xargs -I{} echo "  p50 latency: {} ms (200s: $ok/20)"
r0=$(python3 -c 'import time; print(time.time_ns())')
for _ in $(seq 1 50); do curl -s -o /dev/null --max-time 5 -H 'Host: web.local' "http://$NODE_IP:$TPORT/"; done
python3 -c "import time; print(f'  sequential rps: {50 / ((time.time_ns() - $r0)/1e9):.0f}')"
kubectl --kubeconfig "$KCFG" delete ingress web >/dev/null 2>&1; kubectl --kubeconfig "$KCFG" delete svc web deployment web >/dev/null 2>&1 &

banner "footprint"
container exec micropod-k3s sh -c 'grep -E "MemTotal|MemAvailable" /proc/meminfo' | \
    awk '{t[$1]=$2} END {printf "  guest in use:  %d MB of %d MB\n", (t["MemTotal:"]-t["MemAvailable:"])/1024, t["MemTotal:"]/1024}'
pod=$(ps aux | grep -F 'Virtualization.VirtualMachine' | grep -v grep | tail -1 | awk '{print $2}')
[ -n "$pod" ] && ps -o rss=,pcpu= -p "$pod" | awk '{printf "  VM proc RSS:  %d MB (cpu %.1f%%)\n", $1/1024, $2}'
kubectl --kubeconfig "$KCFG" top node 2>/dev/null | tail -1 | awk '{printf "  kubectl top:  %s cpu, %s mem\n", $2, $4}' || echo "  kubectl top:  metrics-server not ready yet"
wait
