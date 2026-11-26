#!/usr/bin/env bash
# Updater gate (backlog B26; master plan Pillar 2 §2.2 step 4 and the Phase D
# gate "micropod update apply (live drain + 290 ms switchover + simulated
# failed-boot auto-rollback with caches preserved)"), as a repeatable
# measurement with a receipt.
#
#   scripts/gates/updater.sh [--bundle DIR] [--receipt-dir DIR] [--activations N]
#                            [--target-ms MS] [--cpus N] [--memory-mib MIB] [--no-race]
#                            [--break cache|rollback|drain] [--keep] [-h|--help]
#
# One throwaway HVF machine (root /tmp/mpg-b26/m, workspace /tmp/mpg-b26/ws)
# is installed from a real payload bundle and driven through the product's
# own `micropod update hvf stage|apply|rollback` and `machine` commands.
# Nothing is mocked: every check reads the machine (state.json, the payload
# links, the VMM process's executable, the supervisor log, the guest Docker
# API, files containers wrote through the workspace share).
#
#   S0 setup        install a flat machine from the bundle, boot it, cache disk mounted
#   S1 staged       a staged payload is not booted by a supervisor relaunch after
#                   kill -9 of the VMM, by machine stop/start or by machine restart
#   S2 baseline     host-generated files are copied into the attached Go module
#                   cache (cache disk); the guest's hash of them equals the host's
#   S3 drain        apply with a running container defers (exit 75), sends the
#                   supervisor no stop, and the container keeps running and working;
#                   --drain-timeout 5 waits 5 s, then defers the same way
#   S4 lock+drain   apply --drain-timeout waits for a finite job; while it holds
#                   update.lock a second apply, a rollback and a stage are refused;
#                   the job finishes on its own (marker written, exit 0) before the
#                   old VMM exits, then the payload activates
#   S5 activation   N idle activations: stage -> apply -> probed healthy, timed by the
#                   product and from outside (kqueue NOTE_EXIT on the old VMM, then
#                   _ping every 5 ms); median switchover against the plan's 290 ms
#   S6 no-boot      a payload whose initrd is garbage (the kernel panics; panic=-1
#                   resets) rolls back by itself to known-good; cache files equal the
#                   host's byte for byte, the volume and cache inventory are unchanged,
#                   the machine serves a published port again
#   S7 probe-fail   a payload that boots the real guest but whose Docker socket
#                   answers 503 on /micropod/metrics fails the probe and rolls back,
#                   with the same preservation and serving checks
#   S8 restart      the failed payload still staged is not booted by a stop/start
#   S9 race         four simultaneous applies: exactly one activates, the rest are
#                   refused by update.lock or find nothing to do; one VMM, one stop
#   S10 cache-loss  a payload whose guest boots without its cache disk (the VMM
#                   drops --cache-disk; mp.cache_disk=1 stays) must fail the probe
#                   and roll back; the cache files are intact afterwards either way
#   S11 safety      the rig's canonical Docker socket never pointed at this machine
#
# Receipt: ~/.micropod/gates/b26/<UTC time>/ — result.json (machine-readable:
# every check with got/want, the activation and rollback timings), checks.tsv,
# measurements.jsonl, meta.json, apply/ (each CLI call's stdout, stderr,
# timing), monitor/ (outside switchover timings), manifests/, logs/
# (harness.log, the machine's supervisor/console logs, the probe proxy log).
# Exit status: 0 when every check passed, 1 when any failed or the run
# aborted, 2 for bad usage or a missing precondition.
#
# --bundle DIR      payload to install and stage copies of (micropod-vmm, Image,
#                   mp-hvf-init.cpio, tools/). Default: the rig's known-good
#                   payload directory, resolved once and cloned read-only.
# --activations N   idle activations timed in S5 (default 3)
# --target-ms MS    switchover target (default 290, the master plan's)
# --cpus N, --memory-mib MIB
#                   the throwaway machine's size (default 2 and 2048; the rig
#                   runs 8 and 16384)
# --no-race         skip S9
# --break cache     deliberate failure: tamper with the cache content after the
#                   baseline (S6/S7 byte-for-byte checks must fail)
# --break rollback  deliberate failure: stage an intact payload as S6's
#                   "cannot boot" one (S6 rollback checks must fail)
# --break drain     deliberate failure: the S3 container has exited before the
#                   apply, so nothing is deferred (S3 drain checks must fail)
# --keep            keep /tmp/mpg-b26 (stopped) for inspection
#
# The root is /tmp/mpg-b26 unless B26_ROOT names another directory under /tmp.
# Safety: MICROPOD_HVF_ROOT, MICROPOD_API_SOCK, MICROPOD_DOCKER_SOCK and the
# runtimes config all point inside /tmp/mpg-b26; MICROPOD_LINK_DOCKER_SOCK=0.
# The rig (~/.micropod/hvf, ~/.micropod/docker.sock, ~/.micropod/api.sock,
# 127.0.0.1:45454) is only read: the default bundle is cloned from it. Only
# processes proven to be this root's (its VMM on its disk, the proxy on its
# socket) are ever signalled. Published ports: 19360-19362.
set -Eeuo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GATE=$HERE/updater
REPO=$(cd "$HERE/../.." && pwd)
M=${MICROPOD:-$REPO/.build/debug/micropod}
BASE=${B26_ROOT:-/tmp/mpg-b26}
BUNDLE=""
ACTIVATIONS=3
TARGET_MS=290
RACE=1
CPUS=2
MEMORY_MIB=2048
BREAK=""
KEEP=0
TS=$(date -u +%Y%m%dT%H%M%SZ)
R=$HOME/.micropod/gates/b26/$TS
DISK_FROM=${B26_DISK_FROM:-$HOME/.micropod/ci/worker.ext4}
IMAGE=${B26_IMAGE:-alpine:3.20}
PORT_BASE=19362 PORT_NOBOOT=19360 PORT_PROBE=19361
JOB_SECONDS=20

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
while [[ $# -gt 0 ]]; do
    case $1 in
    --bundle) BUNDLE=$2; shift ;;
    --receipt-dir) R=$2; shift ;;
    --activations) ACTIVATIONS=$2; shift ;;
    --target-ms) TARGET_MS=$2; shift ;;
    --no-race) RACE=0 ;;
    --cpus) CPUS=$2; shift ;;
    --memory-mib) MEMORY_MIB=$2; shift ;;
    --break) BREAK=$2; shift ;;
    --keep) KEEP=1 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "unknown argument $1 (see --help)" >&2; exit 2 ;;
    esac
    shift
done
case $BREAK in "" | cache | rollback | drain) ;; *) echo "--break takes cache, rollback or drain" >&2; exit 2 ;; esac
[[ $ACTIVATIONS =~ ^[1-9][0-9]*$ ]] || { echo "--activations wants a positive integer" >&2; exit 2; }
[[ $TARGET_MS =~ ^[0-9]+$ ]] || { echo "--target-ms wants milliseconds" >&2; exit 2; }
[[ $CPUS =~ ^[1-9][0-9]*$ && $MEMORY_MIB =~ ^[1-9][0-9]*$ ]] || { echo "--cpus and --memory-mib want positive integers" >&2; exit 2; }

# --- preconditions (exit 2) ---------------------------------------------------
die2() { echo "updater gate: $*" >&2; exit 2; }
case "$BASE" in
*/ | *//* | */./* | */. | */../* | */..) die2 "B26_ROOT must be spelled plainly (got '$BASE')" ;;
/tmp/?* | /private/tmp/?*) ;;
*) die2 "B26_ROOT must be a throwaway directory under /tmp (got '$BASE')" ;;
esac
MARKER=.micropod-gate-b26
[[ ! -e $BASE || -f $BASE/$MARKER || -z "$(ls -A "$BASE" 2>/dev/null)" ]] ||
    die2 "$BASE exists and was not made by this gate (no $MARKER)"
[[ -x $M ]] || die2 "missing $M (swift build --product micropod, or set MICROPOD)"
[[ -x /usr/bin/python3 ]] && /usr/bin/python3 -I -c 'import socket, select' 2>/dev/null ||
    die2 "/usr/bin/python3 is needed by the probe-failure payload's proxy"
canon() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
RIG=$HOME/.micropod/hvf
if [[ -z $BUNDLE ]]; then BUNDLE=$(canon "$RIG/known-good"); fi
BUNDLE=$(canon "$BUNDLE")
for f in micropod-vmm Image mp-hvf-init.cpio tools/runner/start.sh; do
    [[ -f $BUNDLE/$f ]] || die2 "bundle $BUNDLE has no $f"
done
[[ -f $DISK_FROM ]] || die2 "missing disk to clone: $DISK_FROM"
codesign -d --entitlements - --xml "$BUNDLE/micropod-vmm" 2>/dev/null | grep -q com.apple.security.hypervisor ||
    die2 "$BUNDLE/micropod-vmm lacks the hypervisor entitlement"
busy=$(python3 "$GATE/gate.py" busy-ports $PORT_NOBOOT $PORT_PROBE $PORT_BASE)
[[ -z $busy ]] || die2 "ports already in use: $busy"

mkdir -p "$R"/{logs,apply,monitor,manifests}
exec > >(tee -a "$R/logs/harness.log") 2>&1
log() { printf '%s updater-gate: %s\n' "$(date +%H:%M:%S)" "$*"; }
log "receipt $R"

# --- environment: everything inside the throwaway root --------------------------
MROOT=$BASE/m
WS=$BASE/ws
WORK=$BASE/work
SOCK=$MROOT/run/docker.sock
SUPLOG=$MROOT/logs/supervisor.log
WRAPPER_LOG=$MROOT/logs/b26-wrapper.log
export MICROPOD_HVF_ROOT=$MROOT
export MICROPOD_LINK_DOCKER_SOCK=0
export MICROPOD_DOCKER_SOCK=$MROOT/canonical-docker.sock
export MICROPOD_API_SOCK=$BASE/api.sock
export MICROPOD_API_PORT=19389
export MICROPOD_RUNTIMES_CONFIG=$BASE/runtimes.json
export MICROPOD_CLI=$M
export MICROPOD_NO_UPDATE_NOTIFIER=1
unset MICROPOD_DEFAULT_RUNTIME DOCKER_HOST
S=$(date +%s)
VOL=b26vol-$S
SCOPE=b26gate
CONTAINERS=()
BG_PIDS=()
COMPLETE=0
ERR_LINE=""
ERR_CMD=""
N=0 PASS=0 FAIL=0 SECTION=S0

gate() { python3 "$GATE/gate.py" "$@"; }
remove_tree() { [[ ! -e $1 ]] || { chmod -R u+w "$1" 2>/dev/null; rm -rf "$1"; }; }

cleanup() {
    local rc=$?
    set +e
    trap - ERR
    for p in "${BG_PIDS[@]+"${BG_PIDS[@]}"}"; do kill "$p" 2>/dev/null; done
    for p in "${BG_PIDS[@]+"${BG_PIDS[@]}"}"; do wait "$p" 2>/dev/null; done
    if [[ -S $SOCK ]]; then
        for c in "${CONTAINERS[@]+"${CONTAINERS[@]}"}"; do "$M" rm --force "$c" >/dev/null 2>&1; done
        "$M" volume rm --runtime hvf "$VOL" >/dev/null 2>&1
    fi
    mkdir -p "$R/logs/machine"
    cp -p "$MROOT"/logs/* "$R/logs/machine/" 2>/dev/null
    cp -p "$MROOT/run/state.json" "$MROOT/machine.json" "$R/logs/machine/" 2>/dev/null
    [[ -d $MROOT ]] && "$M" machine stop >/dev/null 2>&1
    # Anything of this root's still alive: the probe proxy on its socket, a VMM on its disk.
    for p in $(pgrep -f "probefail_proxy.py --listen $MROOT/run/docker.sock" 2>/dev/null); do kill "$p" 2>/dev/null; done
    for p in $(pgrep -f -- "--disk $MROOT/disk.ext4" 2>/dev/null); do
        [[ $(gate exe "$p") == */micropod-vmm ]] && { log "killing leftover VMM pid $p of $MROOT"; kill "$p"; }
    done
    if [[ $COMPLETE != 1 ]]; then
        log "ABORTED (exit $rc) at line ${ERR_LINE:-?}: ${ERR_CMD:-?}"
    fi
    python3 "$GATE/summarize.py" "$R" --complete "$COMPLETE" --abort-line "$ERR_LINE" --abort-command "$ERR_CMD"
    local verdict=$?
    if [[ $KEEP != 1 && -f $BASE/$MARKER ]]; then remove_tree "$BASE"; fi
    [[ $COMPLETE == 1 && $verdict == 0 ]] && exit 0
    exit 1
}
trap cleanup EXIT
trap 'ERR_LINE=$LINENO; ERR_CMD=$BASH_COMMAND' ERR
trap 'exit 130' INT TERM

# --- checks -----------------------------------------------------------------
clean() { printf '%s' "$1" | tr '\t\n\r' '   ' | cut -c1-600; }
record() { # record ID LABEL GOT WANT OK
    N=$((N + 1))
    if [[ $5 == 1 ]]; then
        PASS=$((PASS + 1))
        printf '  ✓ [C%02d] %s: %s\n' "$N" "$1" "$2"
    else
        FAIL=$((FAIL + 1))
        printf '  ✗ [C%02d] %s: %s — got %s, want %s\n' "$N" "$1" "$2" "'$3'" "'$4'"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$N" "$SECTION" "$1" "$5" "$(clean "$2")" "$(clean "$3")" "$(clean "$4")" \
        >>"$R/checks.tsv"
}
unread() { # a reader's failure value: equal on both sides it would compare nothing with nothing
    case $1 in "" | absent | absent:* | *:absent | *:absent:* | "error("* | *":error("* | "unavailable ("* | none:none | None:None | None) return 0 ;; esac
    return 1
}
check() {
    if unread "$3"; then record "$1" "$2" "$3 (not measured)" "$4" 0
    elif [[ $3 == "$4" ]]; then record "$1" "$2" "$3" "$4" 1
    else record "$1" "$2" "$3" "$4" 0; fi
}
check_num() { # check_num ID LABEL GOT OP BOUND  (OP: <= >= < >)
    local ok
    ok=$(python3 -c '
import sys
got, op, bound = sys.argv[1:]
try:
    g, b = float(got), float(bound)
except ValueError:
    print(0); sys.exit()
print(int({"<=": g <= b, ">=": g >= b, "<": g < b, ">": g > b}[op]))' "$3" "$4" "$5")
    record "$1" "$2" "$3" "$4 $5" "$ok"
}
check_has() { # check_has ID LABEL HAYSTACK NEEDLE
    if [[ $3 == *"$4"* ]]; then record "$1" "$2" "contains '$4'" "contains '$4'" 1; else record "$1" "$2" "$3" "contains '$4'" 0; fi
}
section() { SECTION=$1; shift; echo; log "== $SECTION $*"; }
measure() { gate measure "$R/measurements.jsonl" "$1" "$2"; }
jnum() { [[ $1 =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && echo "$1" || echo null; }

# --- machine readers --------------------------------------------------------
st() { gate json "$MROOT/run/state.json" "$1"; }
hvf_status() { "$M" update hvf status --json >"$R/apply/.status.json" 2>/dev/null; gate json "$R/apply/.status.json" "$1"; }
link_id() { [[ -L $MROOT/$1 ]] && basename "$(readlink "$MROOT/$1")" || echo none; }
loaded_id() { local p; p=$(st "d.get('loadedPayloadPath') or ''"); [[ -n $p && $p != absent ]] && basename "$p" || echo none; }
vmm_exe() { local pid; pid=$(st "d.get('vmmPID')"); [[ $pid =~ ^[0-9]+$ ]] && gate exe "$pid" || echo none; }
ver_vmm() { echo "$(canon "$MROOT")/versions/$1/micropod-vmm"; }
sup_mark() { [[ -f $SUPLOG ]] && wc -c <"$SUPLOG" | tr -d ' ' || echo 0; }
stop_requests_since() { gate count "$SUPLOG" "$1" "stop requested"; }
api() { curl -sf -m 10 --unix-socket "$SOCK" "http://d$1"; }
pinged() { [[ $(curl -s -m 3 --unix-socket "$SOCK" http://d/_ping 2>/dev/null) == OK ]] && echo yes || echo no; }
inspect() { api "/containers/$1/json" | python3 -c "import sys,json; d=json.load(sys.stdin); print($2)" 2>/dev/null || echo absent; }
exited() { [[ $(inspect "$1" "d['State']['Status']") == exited ]]; }
wait_for() { # wait_for SECONDS CMD...: until CMD succeeds
    local deadline=$((SECONDS + $1))
    shift
    until "$@" >/dev/null 2>&1; do
        [[ $SECONDS -lt $deadline ]] || return 1
        sleep 0.25
    done
}
ours_vmms() { # VMM processes on this root's disk
    local n=0 p
    for p in $(pgrep -f -- "--disk $MROOT/disk.ext4" 2>/dev/null); do [[ $(gate exe "$p") == */micropod-vmm ]] && n=$((n + 1)); done
    echo "$n"
}
run_c() { # run_c NAME ARGS...: a detached container this gate removes at exit
    CONTAINERS+=("$1")
    "$M" run --runtime hvf --name "$@" >/dev/null
}
cache_labels=(--label "io.micropod.cache=+gomod" --label "io.micropod.cache.scope=$SCOPE" --label "io.micropod.cache.trust=trusted")
cache_job() { # cache_job MODE TAG: guest_cache.sh in a fresh container; prints its exit code
    local name="b26-cache-$2-$S"
    rm -f "$WS/out/$2".*
    run_c "$name" "${cache_labels[@]}" -v "$WS:/w" "$IMAGE" -- sh /w/bin/guest_cache.sh "$1" "$2"
    wait_for 120 exited "$name" || true
    inspect "$name" "d['State']['ExitCode']"
}
serve_check() { # serve_check PORT TAG: a published port answers from a new container
    local name="b26-serve-$2-$S" got=""
    run_c "$name" -p "$1:8080" "$IMAGE" -- sh -c \
        "while true; do printf 'HTTP/1.0 200 OK\r\n\r\nb26-$2-$S' | nc -l -p 8080; done"
    for _ in $(seq 1 40); do
        got=$(curl -s -m 2 "http://127.0.0.1:$1/" || true)
        [[ -n $got ]] && break
        sleep 0.5
    done
    "$M" rm --force "$name" >/dev/null 2>&1 || true
    echo "$got"
}
timed() { # timed TAG CMD...: run_timed into apply/TAG; prints the exit code
    set +e
    python3 "$GATE/run_timed.py" "$R/apply/$1" -- "${@:2}"
    local code=$?
    set -e
    echo "$code"
}
field() { gate json "$R/apply/$1.out" "d.get('$2')"; }
ms_of() { gate json "$R/apply/$1.time.json" "d['ms']"; }
monitor_start() { # monitor_start TAG: arms switch_monitor.py; sets MON_PID
    rm -f "$R/monitor/$1.json" "$R/monitor/$1.json.ready"
    python3 "$GATE/switch_monitor.py" --root "$MROOT" --out "$R/monitor/$1.json" --timeout 300 &
    MON_PID=$!
    BG_PIDS+=("$MON_PID")
    wait_for 10 test -f "$R/monitor/$1.json.ready" || log "switch monitor $1 did not arm"
}
monitor_wait() { wait "$MON_PID" 2>/dev/null || true; }
mk_payload() { # mk_payload NAME: a fresh APFS clone of the bundle; prints its directory
    local d=$WORK/payloads/$1
    mkdir -p "$d"
    cp -c "$BUNDLE/micropod-vmm" "$BUNDLE/Image" "$BUNDLE/mp-hvf-init.cpio" "$d/"
    cp -cR "$BUNDLE/tools" "$d/tools"
    chmod -R u+w "$d"
    echo "$d"
}
mk_wrapped_payload() { # mk_wrapped_payload NAME MODE: the bundle with probefail_vmm.sh as its micropod-vmm
    local d
    d=$(mk_payload "$1")
    mkdir -p "$d/tools/b26-gate"
    mv "$d/micropod-vmm" "$d/tools/b26-gate/micropod-vmm"
    cp "$GATE/probefail_proxy.py" "$d/tools/b26-gate/"
    echo "$2" >"$d/tools/b26-gate/mode"
    cp "$GATE/probefail_vmm.sh" "$d/micropod-vmm"
    chmod 755 "$d/micropod-vmm"
    echo "$d"
}
stage() { # stage TAG DIR VERSION [--no-verify]: prints the exit code
    timed "$1" "$M" update hvf stage --json --from "$2" --version "$3" --revision "$S" "${@:4}"
}
verify_ours_vmm() { # the pid is a micropod-vmm on this root's disk
    local cmd
    cmd=$(ps -o command= -p "$1" 2>/dev/null || true)
    [[ $cmd == *"--disk $MROOT/disk.ext4"* && $(gate exe "$1") == */micropod-vmm ]]
}

# Rollback checks shared by S6 and S7. Args: TAG PRE_ID KG_ID STAGED_ID PORT INV_BEFORE CACHE_INODE
rollback_checks() {
    local tag=$1 pre=$2 kg=$3 staged=$4 port=$5 inv=$6 inode=$7
    check "$SECTION.current-known-good" "current and known-good are the pre-update known-good again" \
        "$(link_id current):$(link_id known-good)" "$kg:$kg"
    check "$SECTION.running-pre-update" "the running payload is the pre-update one" "$(loaded_id)" "$pre"
    check "$SECTION.vmm-binary" "…booted from its own VMM binary" "$(vmm_exe)" "$(ver_vmm "$pre")"
    check "$SECTION.serving-ping" "the guest answers _ping on the machine socket" "$(pinged)" "yes"
    check "$SECTION.phase" "machine phase is running" "$(st "d.get('phase')")" "running"
    check "$SECTION.stays-staged" "the failed payload stays staged, update still pending" \
        "$(hvf_status "d['updatePending']"):$(link_id staged)" "True:$staged"
    check "$SECTION.failure-recorded" "update hvf status says why its apply failed" \
        "$(hvf_status "bool(d.get('lastActivationFailure'))")" "True"
    check "$SECTION.serving-port" "a new container's published port $port answers" "$(serve_check "$port" "$tag")" "b26-$tag-$S"
    local code
    code=$(cache_job hash "$tag")
    check "$SECTION.cache-hash-ran" "a fresh container hashed the cache store (exit 0)" "$code" "0"
    cp -p "$WS/out/$tag.manifest" "$WS/out/$tag.df" "$R/manifests/" 2>/dev/null || true
    check "$SECTION.cache-bytes" "cache-disk files equal the host's seed byte for byte" \
        "$(gate manifest-diff "$R/manifests/host.manifest" "$WS/out/$tag.manifest")" "same $SEED_FILES"
    check "$SECTION.cache-device" "…read from the same block device as the baseline, not the root disk" \
        "$(cat "$WS/out/$tag.dev" 2>/dev/null)" "$CACHE_DEV"
    check "$SECTION.cache-inventory" "the guest's cache inventory digest is unchanged" "$(gate cache-inventory "$SOCK")" "$inv"
    check "$SECTION.cache-disk-file" "caches.ext4 is the same file (inode, size)" "$(stat -f '%i %z' "$MROOT/caches.ext4")" "$inode"
    check "$SECTION.cache-disk-mounted" "the guest mounted the cache disk" \
        "$("$M" --json machine status | python3 -c 'import sys,json; d=json.load(sys.stdin).get("cacheDisk") or {}; print(d.get("mounted"))')" "True"
    local vname="b26-volcheck-$tag-$S"
    run_c "$vname" -v "$VOL:/data" "$IMAGE" -- sh -c 'sleep 600'
    check "$SECTION.volume" "the named volume kept its content" "$("$M" exec "$vname" -- cat /data/marker 2>/dev/null)" "volume-$S"
    "$M" rm --force "$vname" >/dev/null 2>&1 || true
}

# --- meta ---------------------------------------------------------------------
python3 - "$R/meta.json" <<PY
import hashlib, json, os, subprocess, sys
def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()
def git(*a):
    return subprocess.run(["git", "-C", "$REPO", *a], capture_output=True, text=True).stdout.strip()
manifest = None
try:
    manifest = json.load(open(os.path.join("$BUNDLE", "payload-manifest.json")))
except (OSError, ValueError):
    pass
meta = {
    "startedAt": "$TS", "root": "$BASE", "machineRoot": "$MROOT", "workspace": "$WS",
    "harnessRev": git("rev-parse", "HEAD"),
    "harnessDirty": bool(git("status", "--porcelain", "--", "scripts/gates/updater.sh", "scripts/gates/updater")),
    "micropodCLI": "$M", "micropodCLISha256": sha("$M"),
    "bundle": "$BUNDLE", "bundleManifest": manifest,
    "bundleDigests": {n: sha(os.path.join("$BUNDLE", n)) for n in ("micropod-vmm", "Image", "mp-hvf-init.cpio")},
    "diskFrom": "$DISK_FROM", "image": "$IMAGE", "activations": $ACTIVATIONS, "race": bool($RACE),
    "machine": {"cpus": $CPUS, "memoryMiB": $MEMORY_MIB, "cacheDisk": "2g"},
    "deliberateFailure": "$BREAK" or None, "jobSeconds": $JOB_SECONDS,
    "switchoverTargetMs": $TARGET_MS,
    "switchoverTargetSource": "master plan §2.2.4 'boots new VMM in ~290 ms' and the Phase D gate '290 ms switchover'; "
                              "backlog B26 'gate target 290 ms, record actual'",
    "ports": [$PORT_NOBOOT, $PORT_PROBE, $PORT_BASE],
}
json.dump(meta, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
log "bundle $BUNDLE; CLI $M; deliberate failure: ${BREAK:-none}"
{
    echo "rig current=$(readlink "$RIG/current" 2>/dev/null) vmmPID=$(gate json "$RIG/run/state.json" "d.get('vmmPID')")"
    echo "canonical docker.sock -> $(readlink "$HOME/.micropod/docker.sock" 2>/dev/null)"
} >"$R/logs/rig-before.txt"
RIG_LINK_BEFORE=$(readlink "$HOME/.micropod/docker.sock" 2>/dev/null || echo no-link)

# =============================================================================
section S0 "install a flat machine into $MROOT from $BUNDLE and boot it"
if [[ -d $MROOT/run ]]; then "$M" machine stop >/dev/null 2>&1 || true; fi
remove_tree "$BASE"
mkdir -p "$BASE" "$WS/out" "$WS/bin" "$WORK"
touch "$BASE/$MARKER"
cp "$GATE/guest_cache.sh" "$WS/bin/"
B0=$(mk_payload install)
"$M" machine install --vmm "$B0/micropod-vmm" --kernel "$B0/Image" --initrd "$B0/mp-hvf-init.cpio" --tools "$B0/tools" \
    --disk-from "$DISK_FROM" --cache-disk-size 2g --cpus "$CPUS" --memory-mib "$MEMORY_MIB" --workspace "$WS" >"$R/logs/install.log" 2>&1
"$M" runtime enable hvf >/dev/null
"$M" runtime use hvf >/dev/null
"$M" machine start >"$R/logs/start.log" 2>&1
check S0.running "the throwaway machine runs" "$(st "d.get('phase')")" "running"
check S0.flat "it booted the flat install" "$(loaded_id)" "$(basename "$(canon "$MROOT")")"
check S0.cache-disk "the guest mounted the cache disk (precondition for S6/S7)" \
    "$("$M" --json machine status | python3 -c 'import sys,json; d=json.load(sys.stdin).get("cacheDisk") or {}; print(d.get("mounted"))')" "True"
check S0.no-link "machine start linked no canonical Docker socket" "$([[ -e $MROOT/canonical-docker.sock ]] && echo linked || echo none)" "none"
"$M" pull --runtime hvf "$IMAGE" >"$R/logs/pull.log" 2>&1
check S0.baseline-serve "a published port answers on the fresh machine (the method S6/S7 reuse)" \
    "$(serve_check $PORT_BASE base)" "b26-base-$S"

# =============================================================================
section S1 "a staged payload is not booted before apply, across restarts"
P2=$(mk_payload v2)
VMM_BEFORE=$(st "d.get('vmmPID')")
code=$(stage stage-v2 "$P2" 9.26.0-gate)
check S1.stage-exit "stage of a second payload built from the same bundle succeeds" "$code" "0"
LEGACY=$(link_id current)
V2=$(link_id staged)
measure "stageMs[]" "$(ms_of stage-v2)"
check S1.imported "the flat install was imported as current" "${LEGACY%%-*}" "legacy"
check S1.known-good "known-good is the imported flat install" "$(link_id known-good)" "$LEGACY"
check S1.staged "staged names the new payload, current does not" "$(link_id staged):$([[ $V2 != "$LEGACY" ]] && echo distinct)" "$V2:distinct"
check S1.pending "update hvf status: update pending" "$(hvf_status "d['updatePending']")" "True"
check S1.stage-no-restart "staging restarted nothing (same VMM pid)" "$(st "d.get('vmmPID')")" "$VMM_BEFORE"
LOADED_BEFORE=$(st "d.get('loadedPayloadPath')")
OLD=$(st "d.get('vmmPID')")
verify_ours_vmm "$OLD" || { log "pid $OLD is not this root's VMM; refusing to signal it"; exit 1; }
kill -9 "$OLD"
relaunched() { [[ $(st "(d.get('restartCount'), d.get('phase'), d.get('vmmPID') != $OLD)") == "(1, 'running', True)" ]]; }
wait_for 120 relaunched || true
check S1.relaunch "the supervisor relaunched the VMM after kill -9" "$(st "(d.get('restartCount'), d.get('phase'))")" "(1, 'running')"
check S1.relaunch-payload "…on the payload it had loaded, not the staged one" "$(st "d.get('loadedPayloadPath')")" "$LOADED_BEFORE"
check S1.relaunch-binary "…from the flat VMM binary" "$(vmm_exe)" "$(canon "$MROOT")/micropod-vmm"
"$M" machine stop >/dev/null
"$M" machine start >/dev/null
check S1.stop-start "machine stop/start boots current, not the staged payload" "$(loaded_id)" "$LEGACY"
check S1.stop-start-binary "…from current's VMM binary" "$(vmm_exe)" "$(ver_vmm "$LEGACY")"
"$M" machine restart >/dev/null
check S1.restart "machine restart boots current, not the staged payload" "$(loaded_id)" "$LEGACY"
check S1.still-staged "the payload is still staged and pending" "$(link_id staged):$(hvf_status "d['updatePending']")" "$V2:True"

# =============================================================================
section S2 "baseline: host-generated files in the attached Go module cache, a named volume"
mkdir -p "$WS/seed/sub/dir"
python3 - "$WS/seed" <<'PY'
import os, random, sys
root = sys.argv[1]
with open(os.path.join(root, "blob.bin"), "wb") as f:
    f.write(os.urandom(8 << 20))
for i in range(48):
    with open(os.path.join(root, f"f{i:02d}.dat"), "wb") as f:
        f.write(os.urandom(random.randint(1, 64) << 10))
with open(os.path.join(root, "sub", "dir", "nested.txt"), "w") as f:
    f.write("b26 updater gate nested file\n")
PY
(cd "$WS/seed" && find . -type f | LC_ALL=C sort | while read -r f; do shasum -a 256 "$f"; done) >"$R/manifests/host.manifest"
SEED_FILES=$(wc -l <"$R/manifests/host.manifest" | tr -d ' ')
CACHE_BLOCKS0=$(stat -f '%b' "$MROOT/caches.ext4")
code=$(cache_job seed base)
check S2.seed-exit "a container copied the seed into its attached gomod cache (exit 0)" "$code" "0"
cp -p "$WS/out/base.manifest" "$WS/out/base.df" "$R/manifests/" 2>/dev/null || true
check S2.seed-bytes "the guest's hash of the cache copy equals the host's" \
    "$(gate manifest-diff "$R/manifests/host.manifest" "$WS/out/base.manifest")" "same $SEED_FILES"
"$M" volume create --runtime hvf "$VOL" >/dev/null
run_c "b26-vol-$S" -v "$VOL:/data" "$IMAGE" -- sh -c "echo volume-$S > /data/marker"
wait_for 60 exited "b26-vol-$S" || true
check S2.volume "a container wrote the volume marker (exit 0)" "$(inspect "b26-vol-$S" "d['State']['ExitCode']")" "0"
CACHE_DEV=$(cat "$WS/out/base.dev" 2>/dev/null || true)
check S2.cache-device "the cache store is on its own block device, not the container's root disk" \
    "$([[ -n ${CACHE_DEV% *} && ${CACHE_DEV% *} == /dev/* && ${CACHE_DEV% *} != "${CACHE_DEV#* }" ]] && echo separate || echo "same ($CACHE_DEV)")" "separate"
CACHE_BLOCKS1=$(stat -f '%b' "$MROOT/caches.ext4")
check_num S2.on-cache-disk "the host's caches.ext4 grew by the seed (512-byte blocks allocated, 8 MiB = 16384)" \
    "$((CACHE_BLOCKS1 - CACHE_BLOCKS0))" ">=" 16384
INV0=$(gate cache-inventory "$SOCK")
check S2.inventory "the cache inventory lists the gomod store in the gate's scope" "${INV0#* }" "gomod:yes b26-gate-scope:yes"
CACHE_INODE=$(stat -f '%i %z' "$MROOT/caches.ext4")

# =============================================================================
section S3 "drain: apply while a container runs"
rm -f "$WS/out/hb"
if [[ $BREAK != drain ]]; then
    run_c "b26-busy-$S" -v "$WS:/w" "$IMAGE" -- sh -c \
        'i=0; while :; do i=$((i+1)); echo $i > /w/out/hb.tmp && mv /w/out/hb.tmp /w/out/hb; sleep 0.5; done'
else
    log "DELIBERATE FAILURE (--break drain): the container has already exited when apply runs"
    run_c "b26-busy-$S" -v "$WS:/w" "$IMAGE" -- sh -c 'echo 1 > /w/out/hb'
    wait_for 60 exited "b26-busy-$S" || true
fi
wait_for 60 test -s "$WS/out/hb" || true
BUSY_START=$(inspect "b26-busy-$S" "d['State']['StartedAt']")
VMM_BEFORE=$(st "d.get('vmmPID')")
SUP_BEFORE=$(st "d.get('supervisorPID')")
MARK=$(sup_mark)
code=$(timed drain-now "$M" update hvf apply --json)
check S3.deferred "apply with a running container defers (exit 75)" "$code:$(field drain-now action)" "75:deferred"
check S3.count "…and counts the running container" "$(field drain-now activeContainers)" "1"
check_has S3.says "…and says why (not silent)" "$(field drain-now detail)" "1 running container(s)"
check S3.no-stop "the supervisor received no stop request" "$(stop_requests_since "$MARK")" "0"
check S3.same-vmm "…and the VMM and supervisor are the same processes" \
    "$(st "d.get('vmmPID')"):$(st "d.get('supervisorPID')")" "$VMM_BEFORE:$SUP_BEFORE"
check S3.container-running "the container still runs, never restarted" \
    "$(inspect "b26-busy-$S" "(d['State']['Running'], d['State']['StartedAt'])")" "(True, '$BUSY_START')"
HB1=$(tr -dc 0-9 <"$WS/out/hb" 2>/dev/null || true)
sleep 2
HB2=$(tr -dc 0-9 <"$WS/out/hb" 2>/dev/null || true)
check_num S3.working "its work went on after the deferral (heartbeat advanced)" "$((${HB2:-0} - ${HB1:-0}))" ">=" 2
check S3.nothing-moved "current and staged are unchanged" "$(link_id current):$(link_id staged)" "$LEGACY:$V2"
MARK=$(sup_mark)
code=$(timed drain-wait5 "$M" update hvf apply --json --drain-timeout 5)
check S3.wait-deferred "apply --drain-timeout 5 with the container still running defers (exit 75)" \
    "$code:$(field drain-wait5 action)" "75:deferred"
check_num S3.waited "…after waiting the 5 s it was given (ms)" "$(ms_of drain-wait5)" ">=" 5000
check_num S3.waited-bounded "…and not much longer (ms)" "$(ms_of drain-wait5)" "<" 20000
check S3.wait-no-stop "…with no stop request and the same VMM" "$(stop_requests_since "$MARK"):$(st "d.get('vmmPID')")" "0:$VMM_BEFORE"
check S3.wait-container "…and the container still running" \
    "$(inspect "b26-busy-$S" "(d['State']['Running'], d['State']['StartedAt'])")" "(True, '$BUSY_START')"
"$M" rm --force "b26-busy-$S" >/dev/null 2>&1 || true
if [[ $BREAK == drain ]]; then # S3 activated the payload; stage another so the later sections have their precondition
    stage stage-v2-again "$P2" 9.26.0-gate-again >/dev/null
    V2=$(link_id staged)
fi

# =============================================================================
section S4 "transaction lock while apply waits for a job, then activation after it finishes"
rm -f "$WS/out/job".*
run_c "b26-job-$S" -v "$WS:/w" "$IMAGE" -- sh -c \
    "date > /w/out/job.start; sleep $JOB_SECONDS; echo done > /w/out/job.done.tmp; mv /w/out/job.done.tmp /w/out/job.done"
wait_for 60 test -f "$WS/out/job.start" || true
JOB_START=$(gate mtime "$WS/out/job.start")
P3=$(mk_payload lock-stage)
VERSIONS_BEFORE=$(ls "$MROOT/versions" | tr '\n' ' ')
VMM_BEFORE=$(st "d.get('vmmPID')")
monitor_start drain-activation
python3 "$GATE/run_timed.py" "$R/apply/lock-A" -- "$M" update hvf apply --json --drain-timeout 180 &
APPLY_A=$!
BG_PIDS+=("$APPLY_A")
wait_for 15 sh -c "[ \"\$(python3 '$GATE/gate.py' lock-held '$MROOT/update.lock')\" = yes ]" || true
check S4.lock-held "apply A holds update.lock while it waits for the job" "$(gate lock-held "$MROOT/update.lock")" "yes"
code=$(timed lock-B "$M" update hvf apply --json)
check S4.apply-refused "a second apply is refused (exit 1)" "$code" "1"
check_has S4.apply-refused-why "…by the transaction lock" "$(cat "$R/apply/lock-B.err")" "another HVF payload update"
check_num S4.apply-refused-fast "…at once (ms)" "$(ms_of lock-B)" "<" 5000
code=$(timed lock-C "$M" update hvf rollback --json)
check S4.rollback-refused "a rollback is refused (exit 1)" "$code" "1"
check_has S4.rollback-refused-why "…by the transaction lock" "$(cat "$R/apply/lock-C.err")" "another HVF payload update"
code=$(stage lock-D "$P3" 9.26.99-gate)
check S4.stage-refused "a stage is refused (exit 1)" "$code" "1"
check_has S4.stage-refused-why "…by the transaction lock" "$(cat "$R/apply/lock-D.err")" "another HVF payload update"
check S4.stage-wrote-nothing "…and wrote no version directory" "$(ls "$MROOT/versions" | tr '\n' ' ')" "$VERSIONS_BEFORE"
check S4.nothing-stopped "while A waits: the job still runs and the VMM is the same" \
    "$([[ -f $WS/out/job.done ]] && echo finished || echo running):$(st "d.get('vmmPID')")" "running:$VMM_BEFORE"
wait "$APPLY_A" 2>/dev/null || true
monitor_wait
check S4.activated "apply A activated once the job was done (exit 0)" \
    "$(gate json "$R/apply/lock-A.time.json" "d['exit']"):$(field lock-A action)" "0:activated"
check S4.job-finished "the job finished its work (done marker written)" "$([[ -f $WS/out/job.done ]] && echo yes || echo no)" "yes"
check S4.job-exit "…and exited 0 by itself" "$(inspect "b26-job-$S" "d['State']['ExitCode']")" "0"
EXIT_WALL=$(gate json "$R/monitor/drain-activation.json" "d.get('exitWall')")
check_num S4.vmm-outlived-job "the old VMM exited after the job's full $JOB_SECONDS s (s from job start)" \
    "$(python3 -c "import sys; print(round(float(sys.argv[1]) - float(sys.argv[2]), 3))" "$EXIT_WALL" "$JOB_START" 2>/dev/null || echo none)" \
    ">=" "$JOB_SECONDS"
DONE_MTIME=$(gate mtime "$WS/out/job.done")
check_num S4.done-before-exit "the done marker was written before the old VMM exited (s before exit)" \
    "$(python3 -c "import sys; print(round(float(sys.argv[1]) - float(sys.argv[2]), 3))" "$EXIT_WALL" "$DONE_MTIME" 2>/dev/null || echo none)" \
    ">=" 0
check S4.current "current and known-good are the new payload" "$(link_id current):$(link_id known-good)" "$V2:$V2"
check S4.running "the machine runs it" "$(loaded_id)" "$V2"
check S4.binary "…from its own VMM binary" "$(vmm_exe)" "$(ver_vmm "$V2")"
check S4.previous "previous is the imported flat install" "$(link_id previous)" "$LEGACY"
check S4.not-pending "nothing pending" "$(hvf_status "d['updatePending']")" "False"
measure drainActivation "{\"applyMs\": $(jnum "$(ms_of lock-A)"), \"switchoverProductMs\": $(jnum "$(field lock-A switchoverMilliseconds)"), \"switchoverExternalMs\": $(jnum "$(gate json "$R/monitor/drain-activation.json" "d.get('switchoverMs')")")}"

# =============================================================================
section S5 "activation time on an idle machine: stage -> apply -> probed healthy (x$ACTIVATIONS)"
SW_EXT=()
for i in $(seq 1 "$ACTIVATIONS"); do
    P=$(mk_payload "act-$i")
    code=$(stage "stage-act-$i" "$P" "9.26.$i-gate")
    ID=$(link_id staged)
    check "S5.staged-$i" "activation $i: the payload is staged" "$code:$([[ $ID != none ]] && echo staged)" "0:staged"
    monitor_start "act-$i"
    code=$(timed "apply-act-$i" "$M" update hvf apply --json)
    monitor_wait
    check "S5.activated-$i" "activation $i: exit 0, activated" "$code:$(field "apply-act-$i" action)" "0:activated"
    check "S5.running-$i" "activation $i: the machine runs the new payload from its own VMM" \
        "$(loaded_id):$(vmm_exe)" "$ID:$(ver_vmm "$ID")"
    check "S5.probed-$i" "activation $i: current and known-good are the new payload, nothing left staged" \
        "$(link_id current):$(link_id known-good):$(link_id staged)" "$ID:$ID:none"
    ext=$(gate json "$R/monitor/act-$i.json" "d.get('switchoverMs')")
    prod=$(field "apply-act-$i" switchoverMilliseconds)
    stage_ms=$(ms_of "stage-act-$i")
    apply_ms=$(ms_of "apply-act-$i")
    total=$(python3 -c "import sys; print(round(float(sys.argv[1]) + float(sys.argv[2]), 1))" "$stage_ms" "$apply_ms")
    log "activation $i: stage ${stage_ms} ms, apply ${apply_ms} ms (stage->healthy ${total} ms); switchover outside ${ext} ms, product ${prod} ms"
    measure "activations[]" "{\"payload\": \"$ID\", \"stageMs\": $(jnum "$stage_ms"), \"applyMs\": $(jnum "$apply_ms"), \"stageToHealthyMs\": $(jnum "$total"), \"switchoverExternalMs\": $(jnum "$ext"), \"switchoverProductMs\": $(jnum "$prod")}"
    measure "stageMs[]" "$stage_ms"
    SW_EXT+=("$ext")
    check "S5.timed-$i" "activation $i: the outside timer saw the old VMM exit and a different VMM answer _ping" \
        "$([[ $ext =~ ^[0-9.]+$ ]] && echo timed):$(gate json "$R/monitor/act-$i.json" "d['newPid'] not in (None, d['oldPid']) and d['newPid'] == $(st "d.get('vmmPID')")")" "timed:True"
done
# Every activation must have been timed: a median over the ones that happened to work is not the gate's.
MEDIAN=$(python3 -c "
import statistics, sys
try:
    print(statistics.median([float(x) for x in sys.argv[1:]]))
except ValueError:
    print('none')" "${SW_EXT[@]}")
check_num S5.target "median switchover, old VMM exit -> new guest _ping (ms), within the plan's target" "$MEDIAN" "<=" "$TARGET_MS"
KG_NOW=$(link_id known-good)

# =============================================================================
section S6 "a payload that cannot boot (garbage initrd) rolls back by itself"
PRE=$(loaded_id)
check S6.precondition "precondition: the machine runs known-good" "$PRE" "$KG_NOW"
PB=$(mk_payload noboot)
if [[ $BREAK != rollback ]]; then
    python3 -c 'import os,sys; p=sys.argv[1]; n=os.path.getsize(p); open(p+".x","wb").write(os.urandom(n)); os.replace(p+".x", p)' "$PB/mp-hvf-init.cpio"
else
    log "DELIBERATE FAILURE (--break rollback): staging an intact payload as the one that cannot boot"
fi
code=$(stage stage-noboot "$PB" 9.26.66-noboot)
NOBOOT=$(link_id staged)
check S6.staged "the payload is staged" "$code:$(link_id current)" "0:$KG_NOW"
check S6.initrd-broken "its staged initrd differs from the bundle's (digest)" \
    "$(gate json "$MROOT/versions/$NOBOOT/payload-manifest.json" "d['digests']['mp-hvf-init.cpio'] != '$(shasum -a 256 "$BUNDLE/mp-hvf-init.cpio" | cut -d' ' -f1)'")" "True"
INV_BEFORE=$(gate cache-inventory "$SOCK")
if [[ $BREAK == cache ]]; then
    log "DELIBERATE FAILURE (--break cache): appending a byte to the cached blob before the apply"
    cache_job tamper tamper >/dev/null
fi
MARK=$(sup_mark)
code=$(timed apply-noboot "$M" update hvf apply --json)
check S6.rolled-back "apply exits 1 with action rolled_back (no second command)" "$code:$(field apply-noboot action)" "1:rolled_back"
log "    $(field apply-noboot detail)"
check S6.trial-booted "the trial boot launched the broken payload" \
    "$(gate in-order "$SUPLOG" "$MARK" "payload $NOBOOT at" "launched micropod-vmm")" "yes"
check S6.trial-crashed "…and its guest crashed at boot (VMM exit status 3)" \
    "$([[ $(gate count "$SUPLOG" "$MARK" "exited with status 3") -ge 1 ]] && echo yes || echo no)" "yes"
check S6.back-on-kg "…then the machine booted known-good again" \
    "$(gate in-order "$SUPLOG" "$MARK" "payload $NOBOOT at" "payload $KG_NOW at" "ready: Docker API answering")" "yes"
rollback_checks noboot "$PRE" "$KG_NOW" "$NOBOOT" "$PORT_NOBOOT" "$INV_BEFORE" "$CACHE_INODE"
measure rollbackNoBoot "{\"applyMs\": $(jnum "$(ms_of apply-noboot)"), \"payload\": \"$NOBOOT\"}"

# =============================================================================
section S7 "a payload that boots but fails the health probe rolls back by itself"
KG_NOW=$(link_id known-good)
PRE=$(loaded_id)
PP=$(mk_wrapped_payload probefail metrics503)
code=$(stage stage-probefail "$PP" 9.26.77-probefail --no-verify)
PROBE=$(link_id staged)
check S7.staged "the payload is staged" "$code:$(link_id current)" "0:$KG_NOW"
INV_BEFORE=$(gate cache-inventory "$SOCK")
MARK=$(sup_mark)
PROXY_LOG=$MROOT/logs/b26-probefail-proxy.log
code=$(timed apply-probefail "$M" update hvf apply --json)
check S7.rolled-back "apply exits 1 with action rolled_back (no second command)" "$code:$(field apply-probefail action)" "1:rolled_back"
check_has S7.probe-named "…naming the failed probe" "$(field apply-probefail detail)" "/micropod/metrics answered HTTP 503"
log "    $(field apply-probefail detail)"
check S7.trial-ready "the trial booted the payload and its guest answered (supervisor: ready)" \
    "$(gate in-order "$SUPLOG" "$MARK" "payload $PROBE at" "ready: Docker API answering" "payload $KG_NOW at")" "yes"
check_num S7.guest-pinged "…the real guest answered _ping with 200 through the payload's socket" "$(grep -cE ' fwd 200 GET (/v1\.[0-9]+)?/_ping ' "$PROXY_LOG" 2>/dev/null || true)" ">=" 1
check_has S7.links-at-probe "when the probe was refused, current and known-good still named known-good (trial: the payload)" \
    "$(grep -m1 '^[0-9.]* 503 GET' "$PROXY_LOG" 2>/dev/null || echo 'no 503 logged')" "[current=$KG_NOW known-good=$KG_NOW trial=$PROBE]"
check_num S7.metrics-withheld "…and the probe's /micropod/metrics got the payload's 503" "$(gate count "$PROXY_LOG" 0 "503 GET")" ">=" 1
check S7.back-on-kg "…then the machine booted known-good again" \
    "$(gate in-order "$SUPLOG" "$MARK" "payload $PROBE at" "stop requested" "payload $KG_NOW at" "ready: Docker API answering")" "yes"
wait_for 10 sh -c "! pgrep -f 'probefail_proxy.py --listen $MROOT/run/docker.sock' >/dev/null" || true
check S7.no-leftover "the failed trial left no process behind" \
    "$(pgrep -f "probefail_proxy.py --listen $MROOT/run/docker.sock" | wc -l | tr -d ' ')" "0"
rollback_checks probe "$PRE" "$KG_NOW" "$PROBE" "$PORT_PROBE" "$INV_BEFORE" "$CACHE_INODE"
measure rollbackProbeFail "{\"applyMs\": $(jnum "$(ms_of apply-probefail)"), \"payload\": \"$PROBE\"}"

# =============================================================================
section S8 "the failed payload, still staged, is not booted by a restart"
WRAPPER_RUNS=$(gate count "$WRAPPER_LOG" 0 "mode=")
"$M" machine stop >/dev/null
"$M" machine start >/dev/null
check S8.stop-start "machine stop/start boots known-good, not the staged failed payload" \
    "$(loaded_id):$(vmm_exe)" "$KG_NOW:$(ver_vmm "$KG_NOW")"
check S8.wrapper-idle "the failed payload's VMM wrapper never ran again" "$(gate count "$WRAPPER_LOG" 0 "mode=")" "$WRAPPER_RUNS"
check S8.still-staged "it is still staged and pending" "$(link_id staged):$(hvf_status "d['updatePending']")" "$PROBE:True"

# =============================================================================
if [[ $RACE == 1 ]]; then
    section S9 "four simultaneous applies: one transaction"
    PR=$(mk_payload race)
    code=$(stage stage-race "$PR" 9.26.88-race)
    RACE_ID=$(link_id staged)
    check S9.staged "the race payload is staged, current unchanged" "$code:$(link_id current):$([[ $RACE_ID != "$PROBE" ]] && echo new)" "0:$KG_NOW:new"
    MARK=$(sup_mark)
    pids=()
    for k in 1 2 3 4; do
        python3 "$GATE/run_timed.py" "$R/apply/race-$k" -- "$M" update hvf apply --json &
        pids+=($!)
    done
    BG_PIDS+=("${pids[@]}")
    for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
    activated=0 refused=0 noop=0 other=0
    for k in 1 2 3 4; do
        c=$(gate json "$R/apply/race-$k.time.json" "d['exit']")
        a=$(field "race-$k" action)
        if [[ $c == 0 && $a == activated ]]; then activated=$((activated + 1))
        elif [[ $c == 1 ]] && grep -q "another HVF payload update" "$R/apply/race-$k.err"; then refused=$((refused + 1))
        elif [[ $c == 0 && $a == noop ]]; then noop=$((noop + 1))
        else other=$((other + 1)); fi
    done
    log "    race: activated=$activated refused=$refused noop=$noop other=$other"
    check S9.one-activation "exactly one apply activated; the others were refused or had nothing to do" \
        "activated=$activated other=$other" "activated=1 other=0"
    check_num S9.lock-refusals "…at least one was refused by update.lock" "$refused" ">=" 1
    check S9.one-stop "the supervisor got exactly one stop request" "$(stop_requests_since "$MARK")" "1"
    check S9.state "current, known-good and the running payload are the race payload" \
        "$(link_id current):$(link_id known-good):$(loaded_id)" "$RACE_ID:$RACE_ID:$RACE_ID"
    check S9.one-vmm "one VMM runs on this root's disk" "$(ours_vmms)" "1"
fi

# =============================================================================
section S10 "a payload whose guest boots without its cache disk must fail the probe"
KG_NOW=$(link_id known-good)
PRE=$(loaded_id)
PN=$(mk_wrapped_payload nocache no-cache-disk)
code=$(stage stage-nocache "$PN" 9.26.55-nocache --no-verify)
NOCACHE=$(link_id staged)
check S10.staged "the payload is staged" "$code:$(link_id current)" "0:$KG_NOW"
RUNS_BEFORE=$(gate count "$WRAPPER_LOG" 0 "mode=no-cache-disk")
code=$(timed apply-nocache "$M" update hvf apply --json)
ACTION=$(field apply-nocache action)
log "    $ACTION ($NOCACHE): $(field apply-nocache detail)"
check_num S10.trial-ran "the trial booted the payload without --cache-disk (wrapper launches)" \
    "$(($(gate count "$WRAPPER_LOG" 0 "mode=no-cache-disk") - RUNS_BEFORE))" ">=" 1
"$M" --json machine status >"$R/logs/nocache-machine-status.json" 2>&1 || true
api "/micropod/caches?stats=0" >"$R/logs/nocache-guest-caches.json" 2>&1 || true
check S10.rolled-back "apply rolls back a guest that came up without its cache disk (exit 1, rolled_back)" \
    "$code:$ACTION" "1:rolled_back"
check S10.state "current, known-good and the running payload are the pre-update known-good" \
    "$(link_id current):$(link_id known-good):$(loaded_id)" "$KG_NOW:$KG_NOW:$PRE"
check S10.serving-cache-disk "the guest serving after the apply has its cache disk mounted" \
    "$(gate json "$R/logs/nocache-machine-status.json" "((d.get('cacheDisk') or {}).get('state'), (d.get('cacheDisk') or {}).get('mounted'))")" \
    "('mounted', True)"
if [[ $ACTION != rolled_back ]]; then
    log "    the cacheless payload is $(link_id current) now; guest caches: $(gate json "$R/logs/nocache-guest-caches.json" "d.get('unavailable')")"
    log "    returning to $KG_NOW with update hvf rollback --previous (not a gate check)"
    timed restore-nocache "$M" update hvf rollback --previous --json >/dev/null
    log "    $(field restore-nocache action): $(field restore-nocache detail)"
fi
code=$(cache_job hash nocache)
cp -p "$WS/out/nocache.manifest" "$R/manifests/" 2>/dev/null || true
check S10.cache-bytes "afterwards, on the cache disk again, the files equal the host's seed byte for byte" \
    "$code:$(gate manifest-diff "$R/manifests/host.manifest" "$WS/out/nocache.manifest")" "0:same $SEED_FILES"

# =============================================================================
section S11 "safety"
RIG_LINK_AFTER=$(readlink "$HOME/.micropod/docker.sock" 2>/dev/null || echo no-link)
check S11.rig-link "the rig's ~/.micropod/docker.sock points where it did before the run, outside this root" \
    "$RIG_LINK_AFTER:$([[ $RIG_LINK_AFTER == "$BASE"/* || $RIG_LINK_AFTER == /private"$BASE"/* ]] && echo ours || echo outside)" "$RIG_LINK_BEFORE:outside"
check S11.own-link-absent "this machine's own canonical-socket path was never linked either" \
    "$([[ -e $MICROPOD_DOCKER_SOCK || -L $MICROPOD_DOCKER_SOCK ]] && echo linked || echo no-link)" "no-link"
check S11.no-api "no API socket was created for this root" "$([[ -e $BASE/api.sock ]] && echo exists || echo none)" "none"
{
    echo "rig current=$(readlink "$RIG/current" 2>/dev/null) vmmPID=$(gate json "$RIG/run/state.json" "d.get('vmmPID')")"
    echo "canonical docker.sock -> $(readlink "$HOME/.micropod/docker.sock" 2>/dev/null)"
} >"$R/logs/rig-after.txt"

COMPLETE=1
echo
log "$PASS passed, $FAIL failed"
