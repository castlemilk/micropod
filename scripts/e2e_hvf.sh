#!/bin/bash
# scripts/e2e_hvf.sh — the shared hvf machine end to end through the CLI.
#
# Installs micropod-vmm, a kernel, the guest initrd, the guest tool bundle
# and an APFS clone of an ext4 worker disk into a throwaway root, then drives
# `micropod … --runtime hvf`:
#   run (cold: starts the machine), ps, exec, logs, stats, stop, rm;
#   a bind mount through the workspace share;
#   `machine install` is refused while the machine runs;
#   a retained container and volume survive `machine stop`; while stopped,
#   id calls on it name the stopped machine (not another engine) and
#   `micropod start <id>` boots the machine and starts it;
#   `kill -9` of the VMM is survived: the supervisor relaunches it and the
#   Docker API comes back with the data intact;
#   a published TCP port carries traffic and shows up in `ps`;
#   volumes and images on the machine through the micropod CLI: volume
#   create/ls/rm (and a micropod-made volume mounted by a container), image
#   pull/ls/inspect, and the operations the guest engine does not implement
#   (image rm, volume prune, sizes) refused as unsupported;
#   `machine status --json` capabilities, the BuildKit socket in the VMM argv,
#   and `machine buildkit-endpoint` refusing a bundle without BuildKit — or,
#   with a BuildKit bundle, a throwaway remote buildx builder whose
#   `RUN --mount=type=cache` survives a second build and a machine restart
#   (builder state under a temporary DOCKER_CONFIG; removed afterwards).
# Only processes this script started are signalled, by pid.
#
# Usage: scripts/e2e_hvf.sh            (needs `swift build` first)
#   HVF_E2E_ROOT   machine root (default /tmp/mphvf-swift; under /tmp, short
#                  enough for run/docker.sock). It and "$HVF_E2E_ROOT-ws" are
#                  deleted only when empty, absent or marked by an earlier run.
#   HVF_VMM        signed micropod-vmm (default vmm/target/release/micropod-vmm)
#   HVF_KERNEL     arm64 Image (default: newest ~/.micropod/kernels/*/Image)
#   HVF_INITRD     guest initramfs (default vmm/target/mp-hvf-init.cpio)
#   HVF_TOOLS      guest tool bundle containing runner/start.sh (required)
#   HVF_DISK_FROM  ext4 disk to clone (default ~/.micropod/ci/worker.ext4)
#   HVF_DISK_IMAGE OCI image (or `default`) to unpack into a fresh disk
#                  instead of cloning HVF_DISK_FROM (pulls; ~1 min)
#   HVF_PORT       host port for the published-port probe (default 18110)
#   HVF_E2E_KEEP=1 keep the root (stopped) for inspection
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
M="$REPO/.build/debug/micropod"
ROOT_DIR="${HVF_E2E_ROOT:-/tmp/mphvf-swift}"
VMM="${HVF_VMM:-$REPO/vmm/target/release/micropod-vmm}"
KERNEL="${HVF_KERNEL:-$(ls -t "$HOME"/.micropod/kernels/*/Image 2>/dev/null | head -1)}"
INITRD="${HVF_INITRD:-$REPO/vmm/target/mp-hvf-init.cpio}"
TOOLS="${HVF_TOOLS:-}"
DISK_FROM="${HVF_DISK_FROM:-$HOME/.micropod/ci/worker.ext4}"
DISK_IMAGE="${HVF_DISK_IMAGE:-}"
PORT="${HVF_PORT:-18110}"
WS="$ROOT_DIR-ws"
S="$(date +%s)"
PASS=0
FAIL=0

# A directory below /tmp, spelled plainly: no empty, `.` or `..` component and
# no trailing slash, so `rm -rf` can only ever reach the throwaway root.
case "$ROOT_DIR" in
*/ | *//* | */./* | */. | */../* | */..) ROOT_OK=0 ;;
/tmp/?* | /private/tmp/?*) ROOT_OK=1 ;;
*) ROOT_OK=0 ;;
esac
if [ "$ROOT_OK" != 1 ]; then
    echo "HVF_E2E_ROOT must be a throwaway directory under /tmp (got '$ROOT_DIR')" >&2
    exit 2
fi
# Only a directory this script made (it carries the marker) or an empty one is
# ever deleted.
MARKER=.micropod-e2e-hvf
ours() { [ ! -e "$1" ] || [ -f "$1/$MARKER" ] || [ -z "$(ls -A "$1" 2>/dev/null)" ]; }
for dir in "$ROOT_DIR" "$WS"; do
    ours "$dir" || {
        echo "$dir exists and was not made by this script (no $MARKER); remove it or pick another HVF_E2E_ROOT" >&2
        exit 2
    }
done
for need in "$M" "$VMM"; do
    [ -x "$need" ] || { echo "missing executable $need (swift build / vmm/build.sh)" >&2 && exit 2; }
done
for need in "$KERNEL" "$INITRD"; do
    [ -f "$need" ] || { echo "missing file $need" >&2 && exit 2; }
done
if [ -n "$DISK_IMAGE" ]; then
    DISK_ARGS=(--disk-image "$DISK_IMAGE" --disk-size 16g)
else
    [ -f "$DISK_FROM" ] || { echo "missing file $DISK_FROM" >&2 && exit 2; }
    DISK_ARGS=(--disk-from "$DISK_FROM")
fi
[ -n "$TOOLS" ] && [ -f "$TOOLS/runner/start.sh" ] || {
    echo "set HVF_TOOLS to a guest tool bundle (a directory with runner/start.sh)" >&2
    exit 2
}

TMP="$(mktemp -d)"
export MICROPOD_HVF_ROOT="$ROOT_DIR"
export MICROPOD_RUNTIMES_CONFIG="$TMP/runtimes.json"  # never the user's engine config
export MICROPOD_CLI="$M"                              # the binary that runs `machine serve`
unset MICROPOD_DEFAULT_RUNTIME

cleanup() {
    if [ -S "$ROOT_DIR/run/docker.sock" ]; then
        for name in keep vol2 bind port race volm; do
            "$M" rm --force "e2e-$name-$S" >/dev/null 2>&1 || true
        done
        "$M" volume rm --runtime hvf "e2evm-$S" >/dev/null 2>&1 || true
    fi
    if [ -n "${BUILDER:-}" ]; then
        DOCKER_CONFIG="$TMP/docker" docker buildx rm "$BUILDER" >/dev/null 2>&1 || true
    fi
    "$M" machine stop >/dev/null 2>&1 || true
    if [ "${HVF_E2E_KEEP:-0}" != 1 ]; then
        for dir in "$ROOT_DIR" "$WS"; do
            if [ -f "$dir/$MARKER" ]; then rm -rf "$dir"; fi
        done
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
state() { python3 -c "import json; s=json.load(open('$ROOT_DIR/run/state.json')); print($1)"; }
ps_field() { # ps_field <name> <python expr over c>
    "$M" --json ps -a | python3 -c "import sys,json; print(next(($2 for c in json.load(sys.stdin) if c['id']=='$1'), 'absent'))"
}
wait_for() { # wait_for <seconds> <command…>: until the command succeeds
    local deadline=$((SECONDS + $1))
    shift
    until "$@" >/dev/null 2>&1; do
        [ "$SECONDS" -lt "$deadline" ] || return 1
        sleep 0.25
    done
}

echo "== install into $ROOT_DIR"
if [ -e "$ROOT_DIR" ]; then
    "$M" machine stop >/dev/null 2>&1 || true
fi
for dir in "$ROOT_DIR" "$WS"; do
    rm -rf "$dir" # ours (checked above)
    mkdir -p "$dir"
    touch "$dir/$MARKER"
done
"$M" machine install --vmm "$VMM" --kernel "$KERNEL" --initrd "$INITRD" --tools "$TOOLS" \
    "${DISK_ARGS[@]}" --cpus 4 --memory-mib 4096 --workspace "$WS"
check "copied VMM keeps the hypervisor entitlement" \
    "$(codesign -d --entitlements - --xml "$ROOT_DIR/micropod-vmm" 2>/dev/null | grep -c com.apple.security.hypervisor)" "1"
check "machine stopped after install" "$("$M" --json machine status | python3 -c 'import sys,json; print(json.load(sys.stdin)["phase"])')" "stopped"
"$M" runtime enable hvf >/dev/null
"$M" runtime use hvf >/dev/null  # a stopped Apple runtime must not break ps/stats
check "hvf available while stopped" "$("$M" --json runtime ls | python3 -c 'import sys,json; print([r for r in json.load(sys.stdin) if r["name"]=="hvf"][0].get("available", False))')" "True"
check "probe did not boot the machine" "$([ -e "$ROOT_DIR/run/state.json" ] && echo booted || echo cold)" "cold"

echo "== lifecycle (the first run starts the machine)"
NAME="e2e-life-$S"
started=$SECONDS
check "run" "$("$M" run --runtime hvf --name "$NAME" alpine:3.20 -- sh -c 'echo booted-hvf; i=0; while :; do echo tick $i; i=$((i+1)); sleep 1; done')" "$NAME"
echo "    (cold run incl. machine boot + pull: $((SECONDS - started))s)"
check "machine running" "$(state "s['phase']")" "running"
set +e
install_err="$("$M" machine install --cpus 2 2>&1 >/dev/null)"
install_code=$?
set -e
check "install refused while the machine runs" "$install_code:$(echo "$install_err" | grep -c 'is running; stop it first')" "1:1"
check "refused install changed nothing" "$(python3 -c "import json; print(json.load(open('$ROOT_DIR/machine.json'))['cpus'])")" "4"
check "listed with runtime hvf" "$(ps_field "$NAME" "c.get('runtime')")" "hvf"
check "listed running" "$(ps_field "$NAME" "c.get('state')")" "running"
check "exec" "$("$M" exec "$NAME" -- cat /etc/alpine-release | cut -d. -f1-2)" "3.20"
set +e
exec_err="$("$M" exec "$NAME" -- sh -c 'echo out; echo err >&2; exit 3' 2>&1 >/dev/null)"
exec_code=$?
set -e
check "exec non-zero exit surfaces" "$([ "$exec_code" -ne 0 ] && echo yes || echo "no ($exec_code)")" "yes"
# Either as micropod's own exit status or in its error message.
check "exec reports the guest exit code" \
    "$([ "$exec_code" -eq 3 ] || echo "$exec_err" | grep -q 'exit 3' && echo yes || echo "no ($exec_code: $exec_err)")" "yes"
sleep 2
check "logs from the start" "$("$M" logs -n 1000 "$NAME" | head -1)" "booted-hvf"
check "logs tail" "$("$M" logs -n 1 "$NAME" | grep -c '^tick ')" "1"
"$M" logs -f -n 1 "$NAME" >"$TMP/follow.log" 2>&1 &
FOLLOW=$!
sleep 2.5
kill "$FOLLOW" 2>/dev/null || true
wait "$FOLLOW" 2>/dev/null || true
check "logs -f streams new lines" "$([ "$(grep -c '^tick ' "$TMP/follow.log")" -ge 2 ] && echo yes || echo no)" "yes"
check "stats" "$("$M" --json stats | python3 -c "import sys,json; print(any(c['id']=='$NAME' for c in json.load(sys.stdin)['containers']))")" "True"
"$M" restart "$NAME" >/dev/null
check "restart (stop+start)" "$(ps_field "$NAME" "c.get('state')")" "running"
check "copy refused (no archive API)" "$("$M" cp "$NAME:/etc/hosts" "$TMP/hosts" 2>&1 | grep -c "runtime 'hvf' does not support copy")" "1"
"$M" stop --time 1 "$NAME" >/dev/null
check "stopped" "$(ps_field "$NAME" "c.get('state')")" "exited"
"$M" rm "$NAME" >/dev/null
check "deleted" "$(ps_field "$NAME" "c.get('state')")" "absent"
check "interactive run refused" "$("$M" run --runtime hvf -i alpine:3.20 2>&1 | grep -c 'interactive stdin')" "1"

echo "== volumes on the machine through the micropod CLI"
VOL="e2evm-$S"
hvf_volume() { # hvf_volume <python expr over v>: the hvf listing's entry for $VOL
    "$M" --json volume ls --runtime hvf | python3 -c "import sys,json; print(next(($1 for v in json.load(sys.stdin) if v['id']=='$VOL'), 'absent'))"
}
check "volume create --runtime hvf" "$("$M" volume create --runtime hvf "$VOL" --label e2e=1)" "Created volume $VOL on hvf"
check "listed on hvf with its label and runtime stamp" \
    "$(hvf_volume "(v['labels'].get('e2e'), v['labels'].get('com.micropod.runtime'), v.get('driver'))")" "('1', 'hvf', 'local')"
check "merged listing names its runtime" \
    "$("$M" --json volume ls | python3 -c "import sys,json; print([v['labels'].get('com.micropod.runtime','apple') for v in json.load(sys.stdin) if v['id']=='$VOL'])")" "['hvf']"
check "volume ls table lists it" "$("$M" volume ls | grep -c "^$VOL ")" "1"
check "a size is refused as unsupported" \
    "$("$M" volume create --runtime hvf "$VOL-big" --size 1g 2>&1 | grep -c "runtime 'hvf' does not support volume size")" "1"
check "volume prune is refused as unsupported" \
    "$("$M" volume prune --runtime hvf 2>&1 | grep -c "runtime 'hvf' does not support volume prune")" "1"
"$M" run --runtime hvf --name "e2e-volm-$S" -v "$VOL:/data" alpine:3.20 -- sh -c 'echo cached > /data/hit; sleep 600' >/dev/null
check "a container mounts the micropod-made volume" "$("$M" exec "e2e-volm-$S" -- cat /data/hit)" "cached"
check "rm of a volume in use is refused" \
    "$("$M" volume rm --runtime hvf "$VOL" 2>&1 | grep -c 'is in use')" "1"
"$M" rm --force "e2e-volm-$S" >/dev/null
check "volume rm by name finds the hvf volume" "$("$M" volume rm "$VOL")" "Deleted volume $VOL"
check "removed" "$(hvf_volume "v['id']")" "absent"

echo "== images on the machine through the micropod CLI"
hvf_image() { # hvf_image <ref> <python expr over i>
    "$M" --json images --runtime hvf | python3 -c "import sys,json; print(next(($2 for i in json.load(sys.stdin) if '$1' in i.get('names', [])), 'absent'))"
}
check "pull --runtime hvf" "$("$M" pull --runtime hvf busybox:1.36 | tail -1)" "Pulled busybox:1.36 on hvf"
check "listed on hvf" "$(hvf_image docker.io/library/busybox:1.36 "(i.get('runtime'), [v['architecture'] for v in i['variants']])")" "('hvf', ['arm64'])"
check "images table lists it" "$("$M" images --runtime hvf | grep -c '^docker.io/library/busybox:1.36 ')" "1"
check "image inspect --runtime hvf" \
    "$("$M" image inspect --runtime hvf docker.io/library/busybox:1.36 | python3 -c 'import sys,json; print(json.load(sys.stdin)["Id"].startswith("sha256:"))')" "True"
check "a pulled image runs" "$("$M" run --runtime hvf --name "e2e-volm-$S" busybox:1.36 -- sh -c 'echo ran; sleep 600' >/dev/null && "$M" exec "e2e-volm-$S" -- busybox echo ran)" "ran"
"$M" rm --force "e2e-volm-$S" >/dev/null
check "rmi is refused as unsupported (the guest answers 501)" \
    "$("$M" rmi busybox:1.36 2>&1 | grep -c "runtime 'hvf' does not support image removal")" "1"
check "…and the image stays" "$(hvf_image docker.io/library/busybox:1.36 "'kept'")" "kept"
check "another platform is refused by the guest" \
    "$("$M" pull --runtime hvf --platform linux/amd64 alpine:3.20 2>&1 | grep -c 'unsupported platform')" "1"
check "save is refused as unsupported" \
    "$("$M" save --runtime hvf busybox:1.36 -o "$TMP/busybox.tar" 2>&1 | grep -c "runtime 'hvf' does not support image save")" "1"

echo "== capabilities and the BuildKit socket"
status_field() { "$M" --json machine status | python3 -c "import sys,json; s=json.load(sys.stdin); print($1)"; }
check "engine API range from /version" \
    "$(status_field "(s['capabilities']['engine'] or {}).get('minAPIVersion', '?') + '-' + (s['capabilities']['engine'] or {}).get('apiVersion', '?')")" \
    "$(curl -s -m 5 --unix-socket "$ROOT_DIR/run/docker.sock" http://d/version | python3 -c 'import sys,json; v=json.load(sys.stdin); print(v.get("MinAPIVersion", "1.0") + "-" + v["ApiVersion"])')"
check "published path reported" "$(status_field "s['capabilities']['publishedPath']")" "macvlan"
check "the VMM exposes the BuildKit port" \
    "$(ps -o command= -p "$(state "s['vmmPID']")" | grep -c -- "--vsock-expose $ROOT_DIR/run/buildkit.sock:2377")" "1"
check "…as a socket on the host" "$([ -S "$ROOT_DIR/run/buildkit.sock" ] && echo yes || echo no)" "yes"
BUILDKIT="$(status_field "s['capabilities']['buildkit']")"
if [ "$BUILDKIT" != True ]; then
    check "no BuildKit endpoint in status without it" "$(status_field "s.get('buildkitEndpoint')")" "None"
    set +e
    bk_err="$("$M" machine buildkit-endpoint 2>&1)"
    bk_code=$?
    set -e
    check "buildkit-endpoint refuses a bundle without BuildKit" "$bk_code:$(echo "$bk_err" | grep -c 'has no BuildKit')" "1:1"
    echo "    (the tool bundle ships no BuildKit: buildx checks skipped)"
else
    ENDPOINT="$("$M" machine buildkit-endpoint)"
    check "buildkit-endpoint names the socket" "$ENDPOINT" "unix://$ROOT_DIR/run/buildkit.sock"
    # A throwaway builder; DOCKER_CONFIG keeps it out of the user's buildx state.
    BUILDER="mphvf-e2e-$S"
    mkdir -p "$TMP/docker" "$TMP/ctx"
    printf 'FROM alpine:3.20\nARG RUN_ID\nRUN --mount=type=cache,target=/cache,id=mphvf-e2e sh -c "echo $RUN_ID >> /cache/runs; cat /cache/runs > /seen"\n' >"$TMP/ctx/Dockerfile"
    DOCKER_CONFIG="$TMP/docker" docker buildx create --name "$BUILDER" --driver remote "$ENDPOINT" >/dev/null
    bx() { # bx <run id>: build, print what the cache mount held
        rm -rf "$TMP/out"
        DOCKER_CONFIG="$TMP/docker" docker buildx build --builder "$BUILDER" --build-arg "RUN_ID=$1" \
            --output "type=local,dest=$TMP/out" "$TMP/ctx" >/dev/null 2>&1 && tr '\n' ' ' <"$TMP/out/seen"
    }
    check "first build fills the cache mount" "$(bx one)" "one "
    check "second build reuses it" "$(bx two)" "one two "
    "$M" machine restart >/dev/null
    check "the cache survives a machine restart" "$(bx three)" "one two three "
    DOCKER_CONFIG="$TMP/docker" docker buildx rm "$BUILDER" >/dev/null 2>&1 && BUILDER=""
fi

echo "== workspace bind mount"
echo "from-host-$S" >"$WS/hello.txt"
"$M" run --runtime hvf --name "e2e-bind-$S" -v "$WS:/w" alpine:3.20 -- sh -c 'sleep 600' >/dev/null
check "guest reads the host file" "$("$M" exec "e2e-bind-$S" -- cat /w/hello.txt)" "from-host-$S"
"$M" exec "e2e-bind-$S" -- sh -c "echo from-guest-$S > /w/guest.txt" >/dev/null
check "host sees the guest write" "$(cat "$WS/guest.txt" 2>/dev/null)" "from-guest-$S"
"$M" rm --force "e2e-bind-$S" >/dev/null

echo "== retained container and volume across machine stop/start"
"$M" run --runtime hvf --name "e2e-keep-$S" -v "e2evol-$S:/data" alpine:3.20 -- sleep 3600 >/dev/null
"$M" exec "e2e-keep-$S" -- sh -c "echo marker-$S > /data/marker" >/dev/null
"$M" machine stop >/dev/null
check "machine stopped" "$(state "s['phase']")" "stopped"
check "graceful poweroff" "$(state "'exit_reason=poweroff' in (s.get('lastExitReason') or '')")" "True"
check "orderly exit code recorded" "$(state "(s.get('lastExitCode'), s.get('lastExitMeaning'))")" "(0, 'orderly guest poweroff')"
check "stopped machine lists nothing" "$(ps_field "e2e-keep-$S" "c.get('state')")" "absent"
check "…no volumes and no images either" \
    "$("$M" --json volume ls --runtime hvf):$("$M" --json images --runtime hvf)" "[]:[]"
check "a stopped machine reports no engine range" "$(status_field "s['capabilities']['engine']")" "None"
check "the stopped machine's containers are indexed on the host" \
    "$(python3 -c "import json; print(any(c.get('name')=='e2e-keep-$S' for c in json.load(open('$ROOT_DIR/run/containers.json'))['containers']))")" "True"
set +e
stopped_exec="$("$M" exec "e2e-keep-$S" -- true 2>&1)"
stopped_exec_code=$?
stopped_stop="$("$M" stop "e2e-keep-$S" 2>&1)"
stopped_stop_code=$?
set -e
check "exec on a stopped machine's container fails" "$stopped_exec_code" "1"
check "…naming the stopped hvf machine" \
    "$(echo "$stopped_exec" | grep -c "on the hvf machine, which is not running.*micropod machine start")" "1"
check "stop on a stopped machine's container names it too" \
    "$stopped_stop_code:$(echo "$stopped_stop" | grep -c 'on the hvf machine, which is not running')" "1:1"
check "reads and refused calls did not boot it" "$("$M" --json machine status | python3 -c 'import sys,json; print(json.load(sys.stdin)["phase"])')" "stopped"
# By the guest's id (a 12-character prefix, as `docker ps` shows it), which the
# host index resolves the way the guest does.
KEEP_ID="$(python3 -c "import json; print(next(c['id'][:12] for c in json.load(open('$ROOT_DIR/run/containers.json'))['containers'] if c.get('name')=='e2e-keep-$S'))")"
check "start by id boots the machine" "$("$M" start "$KEEP_ID")" "Started $KEEP_ID"
check "machine running after start" "$(state "s['phase']")" "running"
check "container retained and running" "$(ps_field "e2e-keep-$S" "(c.get('runtime'), c.get('state'))")" "('hvf', 'running')"
check "volume data retained" "$("$M" exec "e2e-keep-$S" -- cat /data/marker)" "marker-$S"
"$M" run --runtime hvf --name "e2e-vol2-$S" -v "e2evol-$S:/data" alpine:3.20 -- sleep 600 >/dev/null
check "volume shared by a new container" "$("$M" exec "e2e-vol2-$S" -- cat /data/marker)" "marker-$S"
"$M" rm --force "e2e-vol2-$S" >/dev/null

echo "== supervisor survives kill -9 of the VMM"
VMM_PID="$(state "s['vmmPID']")"
RESTARTS="$(state "s['restartCount']")"
check "pid is this root's micropod-vmm" "$(ps -o command= -p "$VMM_PID" | grep -c -- "^$ROOT_DIR/micropod-vmm .*--disk $ROOT_DIR/disk.ext4")" "1"
kill -9 "$VMM_PID"
back_up() { [ "$(state "s['phase']=='running' and s['vmmPID']!=$VMM_PID")" == True ]; }
if wait_for 120 back_up; then
    check "relaunched and ready" "running" "running"
else
    check "relaunched and ready" "$(state "s['phase']")" "running"
fi
check "restart counted" "$(state "s['restartCount']")" "$((RESTARTS + 1))"
check "last exit recorded" "$(state "'signal 9' in (s.get('lastExitReason') or '')")" "True"
check "docker API answers" "$(curl -s -m 5 --unix-socket "$ROOT_DIR/run/docker.sock" http://d/v1.44/_ping)" "OK"
"$M" start "e2e-keep-$S" >/dev/null
check "volume data survived the abrupt stop" "$("$M" exec "e2e-keep-$S" -- cat /data/marker)" "marker-$S"

echo "== concurrent starts from several processes share one supervisor"
"$M" rm --force "e2e-keep-$S" >/dev/null
"$M" machine stop >/dev/null
for i in 1 2 3 4; do
    ("$M" machine start >"$TMP/start-$i.log" 2>&1 && echo ok >>"$TMP/start-$i.log") &
done
"$M" run --runtime hvf --name "e2e-race-$S" alpine:3.20 -- sleep 600 >"$TMP/race-run.log" 2>&1 || true
wait
check "every starter succeeded" "$(cat "$TMP"/start-*.log | grep -c '^ok$')" "4"
check "the racing run succeeded" "$(cat "$TMP/race-run.log")" "e2e-race-$S"
check "one VMM for the root" "$(pgrep -f "^$ROOT_DIR/micropod-vmm " | wc -l | tr -d ' ')" "1"
check "no restarts from the race" "$(state "s['restartCount']")" "0"
"$M" rm --force "e2e-race-$S" >/dev/null

echo "== published port"
"$M" run --runtime hvf --name "e2e-port-$S" -p "$PORT:8080" alpine:3.20 -- sh -c \
    "while true; do printf 'HTTP/1.0 200 OK\r\n\r\nport-ok' | nc -l -p 8080; done" >/dev/null
served=""
for _ in $(seq 1 20); do
    served="$(curl -s -m 2 "http://127.0.0.1:$PORT/" || true)"
    [ -n "$served" ] && break
    sleep 0.5
done
check "127.0.0.1:$PORT reaches the container" "$served" "port-ok"
check "ps shows the published port" "$(ps_field "e2e-port-$S" "[(p['hostPort'], p['containerPort']) for p in c.get('publishedPorts', [])]")" "[($PORT, 8080)]"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
