#!/bin/bash
# scripts/e2e_runtimes.sh — live engine matrix through a real MicropodAPI.
#
# Boots a signed MicropodAPI on a scratch port with an isolated engine config
# and drives every engine over Connect + REST: list/default/update, then a
# full container lifecycle on apple, sandbox and docker (each skipped with a
# note when unavailable). Never touches the user's API (45454) or config.
#
# Usage: scripts/e2e_runtimes.sh           (needs `swift build` first)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
API_BIN="$ROOT/.build/debug/MicropodAPI"
PORT="${E2E_PORT:-45987}"
TMP="$(mktemp -d)"
BASE="http://127.0.0.1:$PORT"
PASS=0
FAIL=0

cleanup() {
    [ -n "${API_PID:-}" ] && kill "$API_PID" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

codesign --force --sign - --entitlements "$ROOT/signing/micropod-cli.entitlements" "$API_BIN" 2>/dev/null

MICROPOD_API_PORT="$PORT" MICROPOD_RUNTIMES_CONFIG="$TMP/runtimes.json" \
    "$API_BIN" >"$TMP/api.log" 2>&1 &
API_PID=$!
for _ in $(seq 1 50); do
    curl -sf "$BASE/health" >/dev/null && break
    sleep 0.2
done

rpc() { # rpc Service/Method json
    curl -s -m 180 -H 'Content-Type: application/json' -X POST "$BASE/api/micropod.v1.$1" -d "${2:-{\}}"
}
rest() { # rest METHOD path [json]
    curl -s -m 60 -H 'Content-Type: application/json' -X "$1" "$BASE$2" ${3:+-d "$3"}
}
field() { python3 -c "import sys,json; d=json.load(sys.stdin); print($1)"; }
check() { # check "label" actual expected
    if [ "$2" == "$3" ]; then
        PASS=$((PASS + 1))
        echo "  ✓ $1"
    else
        FAIL=$((FAIL + 1))
        echo "  ✗ $1 — got '$2', want '$3'"
    fi
}
available() {
    rpc SystemService/ListRuntimes | field "[r for r in d['runtimes'] if r['name']=='$1'][0].get('available', False)"
}

echo "== engine management"
check "three engines listed" "$(rpc SystemService/ListRuntimes | field "','.join(r['name'] for r in d['runtimes'])")" "apple,docker,sandbox"
check "apple is default" "$(rpc SystemService/Ping | field "d['defaultRuntime']")" "apple"
check "runtime feature advertised" "$(rpc SystemService/Ping | field "'runtime' in d['features']")" "True"
check "default can't be disabled" "$(rpc SystemService/UpdateRuntime '{"name":"apple","enabled":false}' | field "d['code']")" "failed_precondition"
check "unknown engine refused" "$(rpc ContainerService/RunContainer '{"image":"alpine:3.20","runtime":"nope"}' | field "d['code']")" "failed_precondition"
check "REST list" "$(rest GET /v1/runtimes | field "d['default']")" "apple"
check "metrics history answers" "$(rpc SystemService/GetMetricsHistory '{"kind":"container","id":"never-existed","rangeSeconds":900}' | field "d.get('resolutionSeconds')")" "10"
check "metrics history needs an id" "$(rpc SystemService/GetMetricsHistory '{"kind":"machine"}' | field "d['code']")" "invalid_argument"

lifecycle() { # lifecycle <engine> <name>
    local engine="$1" name="$2" extra="${3:-}"
    echo "== $engine lifecycle"
    local run
    run="$(rpc ContainerService/RunContainer "{\"image\":\"alpine:3.20\",\"name\":\"$name\",\"runtime\":\"$engine\",$extra\"arguments\":[\"sh\",\"-c\",\"echo booted-$engine; sleep 120\"]}")"
    check "run" "$(echo "$run" | field "d.get('id', d)")" "$name"
    check "listed with runtime" "$(rpc ContainerService/ListContainers | field "[c.get('runtime') for c in d.get('containers',[]) if c['id']=='$name']")" "['$engine']"
    local exec
    exec="$(rpc ContainerService/Exec "{\"id\":\"$name\",\"arguments\":[\"sh\",\"-c\",\"echo out; echo err >&2; exit 3\"]}")"
    check "exec exit code" "$(echo "$exec" | field "d.get('exitCode', 0)")" "3"
    check "exec keeps stdout on failure" "$(echo "$exec" | field "d.get('output','').strip()")" "out"
    sleep 1
    check "logs" "$(curl -s -m 5 "$BASE/v1/containers/$name/logs?tail=1" | grep -m1 -o "booted-$engine" || true)" "booted-$engine"
    rpc ContainerService/StopContainer "{\"id\":\"$name\"}" >/dev/null
    check "stopped" "$(rpc ContainerService/GetContainer "{\"id\":\"$name\"}" | field "d['state'] in ('stopped','exited')")" "True"
    rpc ContainerService/DeleteContainer "{\"id\":\"$name\",\"force\":true}" >/dev/null
    check "deleted" "$(rpc ContainerService/GetContainer "{\"id\":\"$name\"}" | field "d.get('code')")" "not_found"
}

suffix="$(date +%s)"
lifecycle apple "e2e-apple-$suffix"

if [ "$(available sandbox)" == "True" ]; then
    lifecycle sandbox "e2e-sbx-$suffix"
    echo "== sandbox extras"
    rpc ContainerService/RunContainer "{\"image\":\"alpine:3.20\",\"name\":\"e2e-sbx-off-$suffix\",\"runtime\":\"sandbox\",\"labels\":{\"micropod.network\":\"none\"},\"arguments\":[\"sleep\",\"60\"]}" >/dev/null
    check "network=none label → no eth0" "$(rpc ContainerService/Exec "{\"id\":\"e2e-sbx-off-$suffix\",\"arguments\":[\"ls\",\"/sys/class/net\"]}" | field "d.get('output','').split()")" "['lo']"
    check "sandbox rejects udp ports" "$(rpc ContainerService/RunContainer '{"image":"alpine:3.20","runtime":"sandbox","ports":[{"hostPort":45989,"containerPort":53,"protocol":"udp"}]}' | field "d['code']")" "unimplemented"
    rpc ContainerService/RunContainer "{\"image\":\"alpine:3.20\",\"name\":\"e2e-sbx-port-$suffix\",\"runtime\":\"sandbox\",\"ports\":[{\"hostPort\":45989,\"containerPort\":8080,\"hostIp\":\"127.0.0.1\"}],\"arguments\":[\"sh\",\"-c\",\"while true; do printf 'HTTP/1.0 200 OK\\\\r\\\\n\\\\r\\\\nport-ok' | nc -l -p 8080; done\"]}" >/dev/null
    served=""
    for _ in $(seq 1 25); do served="$(curl -s -m 2 http://127.0.0.1:45989/ || true)"; [ -n "$served" ] && break; sleep 0.2; done
    check "sandbox publishes a tcp port" "$served" "port-ok"
    rpc ContainerService/DeleteContainer "{\"id\":\"e2e-sbx-port-$suffix\",\"force\":true}" >/dev/null
    # Each networked sandbox must give its vmnet subnet back; a leak ran the
    # daemon out after ~20.
    ok=0
    for i in $(seq 1 25); do
        nid="$(rpc ContainerService/RunContainer "{\"image\":\"alpine:3.20\",\"runtime\":\"sandbox\",\"detach\":true,\"arguments\":[\"true\"]}" | field "d.get('id','')")"
        [ -n "$nid" ] && ok=$((ok + 1)) && rpc ContainerService/DeleteContainer "{\"id\":\"$nid\",\"force\":true}" >/dev/null
    done
    check "25 networked sandboxes in one daemon" "$ok" "25"
    # sandbox.exposeHost: the guest reaches a host loopback port as
    # host.micropod.internal, and WaitContainer reports its exit code.
    mkdir -p "$TMP/www" && echo host-says-hi >"$TMP/www/index.html"
    python3 -m http.server 45991 --bind 127.0.0.1 --directory "$TMP/www" >/dev/null 2>&1 &
    WWW_PID=$!
    sleep 0.5
    xid="$(rpc ContainerService/RunContainer "{\"image\":\"alpine:3.20\",\"runtime\":\"sandbox\",\"labels\":{\"micropod.network\":\"none\"},\"sandbox\":{\"exposeHost\":[45991]},\"arguments\":[\"sh\",\"-c\",\"wget -q -T 5 -O - http://host.micropod.internal:45991/ && exit 7\"]}" | field "d.get('id','')")"
    check "expose_host exit code known" "$(rpc ContainerService/WaitContainer "{\"id\":\"$xid\",\"timeoutSeconds\":60}" | field "(d.get('known'), d.get('exitCode'))")" "(True, 7)"
    check "expose_host reached the host" "$(curl -s -m 5 "$BASE/v1/containers/$xid/logs?tail=5" | grep -m1 -o host-says-hi || true)" "host-says-hi"
    kill "$WWW_PID" 2>/dev/null || true
    rpc ContainerService/DeleteContainer "{\"id\":\"$xid\",\"force\":true}" >/dev/null
    check "API refuses host-command secrets" "$(rpc ContainerService/RunContainer '{"image":"alpine:3.20","runtime":"sandbox","sandbox":{"secrets":{"T":{"value":"v","command":["/usr/bin/id"],"hosts":["h"]}}}}' | field "d['code']")" "invalid_argument"
    check "sandbox options on apple refused" "$(rpc ContainerService/RunContainer '{"image":"alpine:3.20","runtime":"apple","sandbox":{"exposeHost":[1]}}' | field "d['code']")" "unimplemented"
    rpc ContainerService/DeleteContainer "{\"id\":\"e2e-sbx-off-$suffix\",\"force\":true}" >/dev/null
    check "set sandbox default" "$(rest PUT /v1/runtimes/default '{"name":"sandbox"}' | field "d['default']")" "sandbox"
    id="$(rpc ContainerService/RunContainer '{"image":"alpine:3.20","arguments":["sleep","30"]}' | field "d['id']")"
    check "default routes to sandbox" "$(rpc ContainerService/GetContainer "{\"id\":\"$id\"}" | field "d['runtime']")" "sandbox"
    rpc ContainerService/DeleteContainer "{\"id\":\"$id\",\"force\":true}" >/dev/null
    rest PUT /v1/runtimes/default '{"name":"apple"}' >/dev/null
else
    echo "== sandbox: skipped (unavailable)"
fi

if [ "$(available docker)" == "True" ]; then
    check "docker opt-in" "$(rpc ContainerService/RunContainer '{"image":"alpine:3.20","runtime":"docker"}' | field "d['code']")" "failed_precondition"
    rest PATCH /v1/runtimes/docker '{"enabled":true}' >/dev/null
    lifecycle docker "e2e-docker-$suffix"
    rest PATCH /v1/runtimes/docker '{"enabled":false}' >/dev/null
else
    echo "== docker: skipped (unavailable)"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
