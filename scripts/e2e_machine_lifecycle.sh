#!/bin/bash
# scripts/e2e_machine_lifecycle.sh — the hvf machine's lifecycle as launchd
# and the API drive it, on a real machine in a throwaway root:
#   1. `machine serve --link-socket` (what the autostart LaunchAgent runs) in
#      the foreground, sent SIGTERM as launchd does at logout: it exits 0
#      within the LaunchAgent's ExitTimeOut, after an orderly guest poweroff,
#      and it had linked the canonical socket once the machine was ready
#   2. `machine autostart on --no-load`: a plist that passes `plutil -lint`,
#      with the D7 keys, and nothing loaded; `autostart status`; `off`
#   3. `machine autostart on` and `off` through a stand-in launchctl that runs
#      the job as launchd would (RunAtLoad, kickstart, bootout with SIGTERM):
#      `on` starts the machine under it, `machine start` after a stop
#      kickstarts the job, `off` stops it and starts it again outside launchd
#   4. the API (its own socket and port): ControlMachine start, then
#      GetMachineStatus carries the engine, container counts, disk flush and
#      cache disk; a running container defers stop until it is forced;
#      SetMachineAutostart on and off
#   5. `micropod status` with the API up and down gives the same machine line
# and, afterwards, ~/.micropod/docker.sock, ~/Library/LaunchAgents and
# ~/.docker/config.json are unchanged (stat and readlink only). The real
# launchctl is never run: MICROPOD_LAUNCHCTL names the stand-in throughout.
#
# Usage: scripts/e2e_machine_lifecycle.sh
#        (needs `swift build --product micropod --product MicropodAPI`)
#   HVF_PAYLOAD     a directory with micropod-vmm, Image, mp-hvf-init.cpio and
#                   tools/ (a copy of a payload version); or name each one:
#   HVF_VMM HVF_KERNEL HVF_INITRD HVF_TOOLS
#   HVF_DISK_FROM   ext4 disk to clone (same APFS volume as /tmp), or
#   HVF_DISK_IMAGE  OCI image (or `default`) to unpack into a fresh disk (pulls)
#   HVF_E2E_ROOT    machine root (default /tmp/mpml-$$; under /tmp, marked)
#   HVF_API_PORT    the throwaway API's loopback port (default 20420)
#   HVF_E2E_KEEP=1  keep the root (stopped) for inspection
# Nothing defaults to the rig under ~/.micropod. Exit 0: every check passed;
# 1: a check failed; 2: refused before starting.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
M="$REPO/.build/debug/micropod"
API="$REPO/.build/debug/MicropodAPI"
ROOT_DIR="${HVF_E2E_ROOT:-/tmp/mpml-$$}"
PAYLOAD="${HVF_PAYLOAD:-}"
VMM="${HVF_VMM:-${PAYLOAD:+$PAYLOAD/micropod-vmm}}"
KERNEL="${HVF_KERNEL:-${PAYLOAD:+$PAYLOAD/Image}}"
INITRD="${HVF_INITRD:-${PAYLOAD:+$PAYLOAD/mp-hvf-init.cpio}}"
TOOLS="${HVF_TOOLS:-${PAYLOAD:+$PAYLOAD/tools}}"
DISK_FROM="${HVF_DISK_FROM:-}"
DISK_IMAGE="${HVF_DISK_IMAGE:-}"
API_PORT="${HVF_API_PORT:-20420}"
IMAGE=alpine:3.20
MARKER=.micropod-e2e-machine-lifecycle
PASS=0
FAIL=0

refuse() { echo "e2e_machine_lifecycle: $*" >&2; exit 2; }

case "$ROOT_DIR" in
*/ | *//* | */./* | */. | */../* | */..) refuse "HVF_E2E_ROOT must be a plain path (got '$ROOT_DIR')" ;;
/tmp/?* | /private/tmp/?*) ;;
*) refuse "HVF_E2E_ROOT must be a throwaway directory under /tmp (got '$ROOT_DIR')" ;;
esac
if [ -e "$ROOT_DIR" ] && [ ! -f "$ROOT_DIR/$MARKER" ] && [ -n "$(ls -A "$ROOT_DIR" 2>/dev/null)" ]; then
    refuse "$ROOT_DIR exists and was not made by this script (no $MARKER)"
fi
case "$API_PORT" in '' | *[!0-9]*) refuse "HVF_API_PORT must be a number" ;; esac
[ -x "$M" ] || refuse "missing $M (swift build --product micropod)"
[ -x "$API" ] || refuse "missing $API (swift build --product MicropodAPI)"
for need in "$VMM" "$KERNEL" "$INITRD"; do
    [ -n "$need" ] && [ -f "$need" ] || refuse "set HVF_PAYLOAD (or HVF_VMM, HVF_KERNEL, HVF_INITRD): missing '$need'"
done
[ -n "$TOOLS" ] && [ -f "$TOOLS/runner/start.sh" ] || refuse "set HVF_PAYLOAD or HVF_TOOLS to a tool bundle with runner/start.sh"
if [ -n "$DISK_IMAGE" ]; then
    DISK_ARGS=(--disk-image "$DISK_IMAGE" --disk-size 16g)
elif [ -n "$DISK_FROM" ] && [ -f "$DISK_FROM" ]; then
    DISK_ARGS=(--disk-from "$DISK_FROM")
else
    refuse "set HVF_DISK_FROM to an ext4 disk to clone, or HVF_DISK_IMAGE=default to pull one"
fi
python3 -c "import socket,sys; s=socket.socket(); s.bind(('127.0.0.1', int(sys.argv[1])))" "$API_PORT" 2>/dev/null ||
    refuse "127.0.0.1:$API_PORT is in use; pick another HVF_API_PORT"
DOCKER="$(command -v docker || true)"

TMP="$(mktemp -d /tmp/mpml-tmp.XXXXXX)"
export DOCKER_CONFIG="$TMP/docker"
mkdir -p "$DOCKER_CONFIG"
echo '{"auths": {"micropod-e2e.invalid": {}}}' >"$DOCKER_CONFIG/config.json"
export MICROPOD_HVF_ROOT="$ROOT_DIR"
export MICROPOD_RUNTIMES_CONFIG="$TMP/runtimes.json"
echo '{"default": "hvf", "engines": {"apple": {"enabled": false}}}' >"$MICROPOD_RUNTIMES_CONFIG"
export MICROPOD_CLI="$M"
# The canonical link lives in the root, so linking it is allowed and safe.
export MICROPOD_DOCKER_SOCK="$ROOT_DIR/canonical-docker.sock"
unset MICROPOD_LINK_DOCKER_SOCK
export MICROPOD_API_SOCK="$ROOT_DIR/api.sock"
export MICROPOD_API_PORT="$API_PORT"
export MICROPOD_CI_HOME="$ROOT_DIR/ci"
export MICROPOD_APP_CONTROL_SOCKET="$ROOT_DIR/app-control.sock"
export MICROPOD_VOLUME_POLICY="$ROOT_DIR/volume-policy.json"
export MICROPOD_LAUNCHCTL="$TMP/launchctl"
export MICROPOD_LAUNCH_AGENTS_DIR="$TMP/LaunchAgents"
export MICROPOD_NO_UPDATE_NOTIFIER=1
export MICROPOD_HVF_AUTOSTART=0
unset MICROPOD_DEFAULT_RUNTIME DOCKER_HOST DOCKER_CONTEXT MICROPOD_AUTOSTART_ANY_ROOT

# launchctl as far as `machine autostart` uses it, with launchd's part played:
# `bootstrap` loads the plist and, RunAtLoad, runs its ProgramArguments with
# its EnvironmentVariables and log paths; `kickstart` runs the job when it is
# not running; `bootout` sends it SIGTERM and waits ExitTimeOut, then
# SIGKILL. Every call is logged.
JOBS="$TMP/jobs"
mkdir -p "$JOBS"
{
    printf '#!/bin/bash\nJOBS=%q\nUSER_HOME=%q\n' "$JOBS" "$HOME"
    cat <<'SH'
echo "$*" >>"$JOBS/calls.log"
label_of() { echo "${1##*/}"; }
running() { [ -f "$JOBS/$1.pid" ] && kill -0 "$(cat "$JOBS/$1.pid")" 2>/dev/null; }
run_job() { # label: the plist's ProgramArguments with its environment and log
    local plist="$JOBS/$1.plist" log arg i=0
    local args=() envs=()
    log=$(plutil -extract StandardErrorPath raw "$plist")
    while IFS= read -r line; do envs+=("$line"); done < <(plutil -extract EnvironmentVariables json -o - "$plist" |
        python3 -c 'import json,sys; [print(k + "=" + v) for k, v in json.load(sys.stdin).items()]')
    while arg=$(plutil -extract "ProgramArguments.$i" raw "$plist" 2>/dev/null); do
        args+=("$arg")
        i=$((i + 1))
    done
    env -i HOME="$USER_HOME" "${envs[@]}" "${args[@]}" </dev/null >>"$log" 2>&1 &
    echo $! >"$JOBS/$1.pid"
}
case "$1" in
print)
    label=$(label_of "$2")
    [ -f "$JOBS/$label.loaded" ] || exit 113
    echo "program = $(plutil -extract ProgramArguments.0 raw "$JOBS/$label.plist")" ;;
bootstrap)
    label=$(plutil -extract Label raw "$3")
    cp "$3" "$JOBS/$label.plist"
    touch "$JOBS/$label.loaded"
    running "$label" || run_job "$label" ;;
kickstart)
    label=$(label_of "$2")
    [ -f "$JOBS/$label.loaded" ] || exit 113
    running "$label" || run_job "$label" ;;
bootout)
    label=$(label_of "$2")
    [ -f "$JOBS/$label.loaded" ] || exit 113
    if running "$label"; then
        pid=$(cat "$JOBS/$label.pid")
        wait_s=$(plutil -extract ExitTimeOut raw "$JOBS/$label.plist")
        kill -TERM "$pid"
        for _ in $(seq 1 $((wait_s * 10))); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
        done
        kill -0 "$pid" 2>/dev/null && kill -KILL "$pid"
    fi
    rm -f "$JOBS/$label.loaded" "$JOBS/$label.pid" ;;
*) exit 64 ;;
esac
exit 0
SH
} >"$MICROPOD_LAUNCHCTL"
chmod +x "$MICROPOD_LAUNCHCTL"

# What must be unchanged at the end, by metadata and link targets only.
fingerprint() {
    echo "$HOME/.micropod/docker.sock -> $(readlink "$HOME/.micropod/docker.sock" 2>/dev/null || echo none)"
    stat -f '%N %m %z' "$HOME/.docker/config.json" 2>/dev/null || echo "config.json absent"
    find "$HOME/Library/LaunchAgents" -maxdepth 1 -name 'com.skunkworq.micropod.machine*' 2>/dev/null | sort |
        while read -r plist; do stat -f '%N %m %z' "$plist"; done
}
BEFORE="$(fingerprint)"

API_PID=""
SERVE_PID=""
cleanup() {
    set +e
    [ -n "$API_PID" ] && kill "$API_PID" 2>/dev/null
    for f in "$JOBS"/*.pid; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; done
    [ -n "$SERVE_PID" ] && kill "$SERVE_PID" 2>/dev/null
    "$M" machine stop >/dev/null 2>&1
    for pid in $(pgrep -f "^$ROOT_DIR/.*micropod-vmm .*--disk $ROOT_DIR/disk.ext4" 2>/dev/null); do kill "$pid"; done
    sleep 1
    if [ "${HVF_E2E_KEEP:-0}" != 1 ] && [ -f "$ROOT_DIR/$MARKER" ] &&
        [ -z "$(pgrep -f "^$ROOT_DIR/.*micropod-vmm .*--disk $ROOT_DIR/disk.ext4" 2>/dev/null)" ]; then
        rm -rf "$ROOT_DIR"
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

check() { # check "label" actual expected
    if [ "$2" == "$3" ]; then
        PASS=$((PASS + 1))
        echo "  ✓ $1"
    else
        FAIL=$((FAIL + 1))
        echo "  ✗ $1 — got '$2', want '$3'"
    fi
}
contains() { # contains "label" haystack needle
    if printf '%s' "$2" | grep -qF -- "$3"; then
        PASS=$((PASS + 1))
        echo "  ✓ $1"
    else
        FAIL=$((FAIL + 1))
        echo "  ✗ $1 — '$3' not in:"
        printf '%s\n' "$2" | sed 's/^/      /'
    fi
}
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }
phase() { "$M" --json machine status | json 'd["phase"]'; }
state() { python3 -c "import json,sys; s=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" "$ROOT_DIR/run/state.json" "$1"; }
supervisor_cmd() { ps -o command= -p "$(state 's["supervisorPID"]')" 2>/dev/null || echo gone; }
wait_running() { # seconds
    for _ in $(seq 1 $(($1 * 4))); do
        [ "$(phase)" = running ] && curl -sf -m 2 --unix-socket "$ROOT_DIR/run/docker.sock" http://x/_ping >/dev/null 2>&1 && return 0
        sleep 0.25
    done
    return 1
}
wait_stopped() { # seconds
    for _ in $(seq 1 $(($1 * 4))); do
        [ "$(phase)" != running ] && [ "$(phase)" != starting ] && [ "$(phase)" != stopping ] && return 0
        sleep 0.25
    done
    return 1
}
rpc() { # method json
    curl -s -m 240 --unix-socket "$MICROPOD_API_SOCK" -H 'Content-Type: application/json' -d "$2" \
        "http://x/api/micropod.v1.RigService/$1"
}
calls() { grep -v '^print ' "$JOBS/calls.log" 2>/dev/null | awk '{print $1}' | tr '\n' ' ' || true; }

echo "== machine into $ROOT_DIR"
mkdir -p "$ROOT_DIR"
touch "$ROOT_DIR/$MARKER"
"$M" machine install --vmm "$VMM" --kernel "$KERNEL" --initrd "$INITRD" --tools "$TOOLS" "${DISK_ARGS[@]}" \
    --cache-disk-size 1g --cpus 2 --memory-mib 2048 --workspace "" >"$TMP/install.log" 2>&1 || {
    cat "$TMP/install.log"
    refuse "machine install failed"
}

echo "== 1. machine serve --link-socket in the foreground, SIGTERM as at logout"
"$M" machine autostart on --no-load >/dev/null
LABEL=$("$M" --json machine autostart status | json 'd["autostart"]["label"]')
PLIST="$MICROPOD_LAUNCH_AGENTS_DIR/$LABEL.plist"
EXIT_TIMEOUT=$(plutil -extract ExitTimeOut raw "$PLIST")
"$M" machine autostart off >/dev/null
"$M" machine serve --link-socket 2>"$TMP/serve.log" &
SERVE_PID=$!
if wait_running 180; then
    PASS=$((PASS + 1))
    echo "  ✓ the foreground supervisor brought the machine up"
else
    FAIL=$((FAIL + 1))
    echo "  ✗ the machine never ran:"
    tail -20 "$TMP/serve.log" | sed 's/^/      /'
fi
for _ in $(seq 1 40); do [ -L "$MICROPOD_DOCKER_SOCK" ] && break; sleep 0.25; done
check "--link-socket linked the canonical socket once ready" "$(readlink "$MICROPOD_DOCKER_SOCK" 2>/dev/null || echo none)" \
    "$ROOT_DIR/run/docker.sock"
start_ns=$(python3 -c 'import time; print(time.monotonic_ns())')
kill -TERM "$SERVE_PID"
set +e
wait "$SERVE_PID"
code=$?
set -e
SERVE_PID=""
elapsed=$(python3 -c "import time,sys; print(round((time.monotonic_ns() - int(sys.argv[1])) / 1e9, 1))" "$start_ns")
check "SIGTERM: the supervisor exits 0" "$code" "0"
check "state.json says stopped" "$(state 's["phase"]')" "stopped"
check "the guest powered off in order" \
    "$(state '(s.get("lastExitCode"), s.get("lastExitMeaning"), "exit_reason=poweroff" in (s.get("lastExitReason") or ""))')" \
    "(0, 'orderly guest poweroff', True)"
contains "the supervisor logged the graceful stop" "$(cat "$TMP/serve.log")" "for a graceful guest poweroff"
check "it stopped within the LaunchAgent's ExitTimeOut ($EXIT_TIMEOUT s; took $elapsed s)" \
    "$(python3 -c "import sys; print(float(sys.argv[1]) < float(sys.argv[2]))" "$elapsed" "$EXIT_TIMEOUT")" "True"

echo "== 2. machine autostart on --no-load, status, off"
out="$("$M" machine autostart on --no-load)"
contains "on --no-load says next login" "$out" "autostart: on at next login ($LABEL, $PLIST)"
check "the plist lints" "$(plutil -lint "$PLIST" | awk '{print $NF}')" "OK"
check "ProgramArguments" "$(plutil -extract ProgramArguments json -o - "$PLIST" | json 'd')" \
    "['$M', 'machine', 'serve', '--link-socket']"
check "KeepAlive only after a crash" "$(plutil -extract KeepAlive json -o - "$PLIST" | json 'd')" "{'Crashed': True}"
check "RunAtLoad" "$(plutil -extract RunAtLoad raw "$PLIST")" "true"
check "ExitTimeOut is the stop grace plus 10 s" "$EXIT_TIMEOUT" "25"
check "the job's root" "$(plutil -extract EnvironmentVariables.MICROPOD_HVF_ROOT raw "$PLIST")" "$ROOT_DIR"
check "the label is this root's, not the standard one" "$([ "$LABEL" != com.skunkworq.micropod.machine ] && echo own)" "own"
check "--no-load loaded nothing" "$(calls)" ""
contains "status: on, not loaded" "$("$M" machine autostart status)" "not loaded; launchd loads it at the next login"
"$M" machine autostart off >/dev/null
check "off removed the plist" "$([ -e "$PLIST" ] && echo present || echo gone)" "gone"
check "off removed the record" "$([ -e "$ROOT_DIR/autostart.json" ] && echo present || echo gone)" "gone"

echo "== 3. machine autostart on/off through launchd (the stand-in)"
: >"$JOBS/calls.log"
out="$("$M" machine autostart on 2>&1)"
contains "on loads the job" "$out" "loaded: launchd starts the machine now and at every login"
check "launchd was asked to bootstrap it" "$(calls)" "bootstrap "
if wait_running 180; then PASS=$((PASS + 1)); echo "  ✓ the job brought the machine up"; else
    FAIL=$((FAIL + 1)); echo "  ✗ the job never brought the machine up"; tail -20 "$ROOT_DIR/logs/supervisor.log" | sed 's/^/      /'; fi
contains "the supervisor is the job's (machine serve --link-socket)" "$(supervisor_cmd)" "machine serve --link-socket"
contains "autostart status: on, loaded" "$("$M" machine autostart status)" "autostart: on (launchd $LABEL, loaded,"
"$M" machine stop >/dev/null
check "machine stop stops the job's machine (the job exits 0: no crash, no relaunch)" "$(phase)" "stopped"
: >"$JOBS/calls.log"
"$M" machine start >/dev/null
check "machine start kickstarts the loaded job" "$(calls)" "kickstart "
contains "…so the job runs the machine again" "$(supervisor_cmd)" "machine serve --link-socket"
: >"$JOBS/calls.log"
out="$("$M" machine autostart off 2>&1)"
check "off unloads the job" "$(calls)" "bootout "
contains "off starts the machine again outside launchd" "$out" "machine: running again outside launchd"
check "the machine runs" "$(phase)" "running"
check "…under a detached supervisor, not the job" \
    "$(supervisor_cmd | grep -c -- '--link-socket' || true)" "0"
"$M" machine stop >/dev/null

echo "== 4. the API: ControlMachine, GetMachineStatus, SetMachineAutostart"
"$API" >"$TMP/api.log" 2>&1 &
API_PID=$!
for _ in $(seq 1 120); do
    curl -sf -m 2 --unix-socket "$MICROPOD_API_SOCK" http://x/health >/dev/null 2>&1 && break
    kill -0 "$API_PID" 2>/dev/null || break
    sleep 0.25
done
before="$(rpc GetMachineStatus '{}')"
check "GetMachineStatus on a stopped machine" "$(echo "$before" | json '(d.get("readiness"), d.get("stoppedOnRequest"))')" \
    "('stopped', True)"
sleep 1
check "…and the status read did not start it" "$(phase)" "stopped"
started="$(rpc ControlMachine '{"action": "start"}')"
check "ControlMachine start" "$(echo "$started" | json 'd.get("readiness")')" "running"
check "ControlMachine start linked the canonical socket" "$(readlink "$MICROPOD_DOCKER_SOCK" 2>/dev/null || echo none)" \
    "$ROOT_DIR/run/docker.sock"
if [ -n "$DOCKER" ]; then
    "$DOCKER" --host "unix://$ROOT_DIR/run/docker.sock" run -d --name mpml-sleeper "$IMAGE" sleep 600 >/dev/null
fi
st="$(rpc GetMachineStatus '{}')"
check "engine version" "$(echo "$st" | json 'bool(d.get("engineVersion")) and d.get("engineApiVersion", "") >= "1.44"')" "True"
check "container counts" "$(echo "$st" | json '(d.get("containersRunning", 0), d.get("containersTotal", 0) >= 1)')" "(1, True)"
check "disk flush" "$(echo "$st" | json 'bool(d.get("diskFlush"))')" "True"
check "cache disk mounted, with its size" \
    "$(echo "$st" | json '(d["cacheDisk"].get("mounted"), int(d["cacheDisk"].get("sizeBytes", 0)) > 0)')" "(True, True)"
check "docker endpoint" "$(echo "$st" | json 'd.get("dockerEndpoint")')" "unix://$ROOT_DIR/run/docker.sock"
check "autostart off" "$(echo "$st" | json 'd["autostart"].get("enabled", False)')" "False"
deferred="$(rpc ControlMachine '{"action": "stop"}')"
check "stop with a container running is deferred" "$(echo "$deferred" | json 'd.get("code")')" "failed_precondition"
contains "…naming it" "$(echo "$deferred" | json 'd.get("message")')" "deferred: 1 running container(s) on the machine"
check "…and nothing stopped" "$(phase)" "running"
deferred="$(rpc SetMachineAutostart '{"enabled": true}')"
check "SetMachineAutostart on is deferred too" "$(echo "$deferred" | json 'd.get("code")')" "failed_precondition"
: >"$JOBS/calls.log"
on="$(rpc SetMachineAutostart '{"enabled": true, "force": true}')"
check "SetMachineAutostart on (force)" "$(echo "$on" | json '(d["autostart"].get("enabled"), d["autostart"].get("loaded"))')" \
    "(True, True)"
check "…stopped the detached machine and loaded the job" "$(calls)" "bootstrap "
wait_running 180 || true
contains "…which runs the machine now" "$(supervisor_cmd)" "machine serve --link-socket"
off="$(rpc SetMachineAutostart '{"enabled": false, "force": true}')"
check "SetMachineAutostart off (force)" "$(echo "$off" | json 'd["autostart"].get("enabled", False)')" "False"
check "…and the machine runs outside launchd again" "$(phase):$(supervisor_cmd | grep -c -- '--link-socket' || true)" \
    "running:0"

echo "== 5. micropod status, with the API and without"
with_api="$("$M" status)"
contains "status reads the API" "$with_api" "api:         running ($MICROPOD_API_SOCK)"
contains "status: running" "$with_api" "machine:     running"
contains "status: containers" "$with_api" "containers:  0 running"
contains "status: no Apple ping (Apple disabled)" "$with_api" "apple:       not enabled"
kill "$API_PID"
wait "$API_PID" 2>/dev/null || true
API_PID=""
without_api="$("$M" status)"
contains "status without the API reads from disk" "$without_api" "api:         not running (read from disk)"
check "the same machine line either way" "$(echo "$without_api" | grep '^machine:')" "$(echo "$with_api" | grep '^machine:')"
check "the same container line either way" \
    "$(echo "$without_api" | grep '^containers:' | sed 's/[0-9]* total//')" \
    "$(echo "$with_api" | grep '^containers:' | sed 's/[0-9]* total//')"
"$M" machine stop >/dev/null 2>&1 || true

echo "== the user's own state"
check "the rig link, the docker config and the LaunchAgents directory are unchanged" "$(fingerprint)" "$BEFORE"

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
