#!/bin/bash
# scripts/gates/phase-b.sh — Phase B gate B1/B2 (master plan Phase B; backlog
# B22) on a real hvf machine, as numbered checks with a receipt.
#
#   scripts/gates/phase-b.sh [--sections B1,B2,B2X] [--sabotage NAME]
#                            [--payload DIR] [--receipt-dir DIR] [--keep] [--help]
#
# B1  The cache disk survives an OS disk replacement byte for byte. Trusted
#     containers seed the go (gomod, gobuild), npm and pnpm stores of one
#     scope with real installs (go build, go mod download, npm ci, pnpm
#     install); a census hashes every store tree; `machine install
#     --replace-disk` replaces disk.ext4 (the re-provision path; a volume on
#     the old OS disk must be gone) and the census must be identical (content,
#     inodes, mtimes); then the updater activates another payload (`update hvf
#     stage` + `apply`: a new VMM, kernel, initrd and tool bundle boot) and the
#     census must be identical again; finally warm runs in new containers at
#     new checkout paths with --network none download and compile nothing.
# B2  An untrusted container (io.micropod.cache.trust=untrusted) and a
#     read-only one (io.micropod.cache.readonly=1) do real go, npm and pnpm
#     work against the warm stores (warm hits, a one-file change that
#     compiles, installs that download new packages) and deliberately try to
#     write every store (create, fill, overwrite, append, truncate, delete,
#     rename, chmod, chown, touch, link, wipe, remount, docker cp, a
#     read-write alias volume, the Docker socket): the trusted stores must be
#     unchanged to the byte, inode, mtime and ctime, and the engine's own
#     inventory unchanged. The untrusted warm build must stay within 1.5x of
#     the trusted warm build (medians of three).
# B2X The crash case: a trusted writer streams real bytes into one unit
#     (gomod) of a second scope while the VMM is killed -9 under it; after the
#     supervisor's relaunch the engine must discard exactly that dirty unit,
#     and every other unit (the same scope's gobuild and npm, and all of B1's
#     scope) must be preserved to the inode and ctime; the next build
#     re-downloads the modules and compiles nothing. Then kills at swept
#     offsets (GATE_CRASH_SWEEP_MS, default 50 ms to 6 s) after a writer
#     started on an idle cache disk, for a writer that only adds entries and
#     for one that overwrites committed entries in place with fdatasync: each
#     must discard the unit whole, its mark being on disk before any write.
#
# How the stores are measured. Never from inside the container under test: a
# census container (io.micropod.cache=off, --network none) mounts every store
# of a scope as a read-only legacy alias volume (micropod-ci-scoped-<scope>-
# <kind>:ro), a bind of the store's own directory on the cache disk, and
# phase-b/census.py records every entry's type, mode, owner, size, inode,
# nlink, mtime_ns, ctime_ns, xattrs and sha256; it proves from mountinfo that
# each mount is the real store (root /scopes/<scope>/<kind>, ext4 on the
# cache disk, ro), not a copy-on-write view. The engine itself then reads
# each store through its own descriptor (`docker cp <census>:/c/<store> -`,
# phase-b/archive_manifest.py), and that read must hash the same as the
# census; the engine's GET /micropod/caches unit inventory (files, bytes,
# dirty marks, discards) is the third view.
#
# --sections   default B1,B2,B2X (the seeding always runs). A run of fewer
#              sections that passes has the verdict "partial", not "pass".
# --sabotage   deliberate failures that prove the harness can fail (the
#              verdict of a sabotaged run is never "pass"):
#                b1-mutate          a trusted container appends to one gomod
#                                   file between the B1 censuses (B1 fails)
#                b1-lose-cache-disk caches.ext4 is moved aside before
#                                   `machine install --replace-disk`, so the
#                                   machine comes back without its caches:
#                                   the failure B1 exists to catch (B1 fails)
#                b2-trusted-attack  the B2 attack also runs once without the
#                                   untrusted label, i.e. trusted (B2 fails)
#                b2-touch           a trusted container sets one gomod file's
#                                   mtime between the B2 censuses and writes
#                                   no byte: the content check still passes,
#                                   the inode/mtime and ctime checks fail
# --payload    a payload directory (micropod-vmm, Image, mp-hvf-init.cpio,
#              tools/); default: the payload the rig's known-good link names,
#              cloned once at start (read only; the rig is never touched)
# --receipt-dir default ~/.micropod/gates/b22/<UTC time>/: result.json
#              (machine-readable), checks.tsv, logs/, census/, containers/,
#              engine/
# --keep       keep the throwaway root (stopped) for inspection
#
# Environment: GATE_ROOT (default /tmp/mpg-b22; a plain directory under /tmp,
# deleted at exit only when it carries this harness's marker), GATE_MICROPOD
# (default .build/debug/micropod), GATE_API_PORT (19300), GATE_SHIM_PORT
# (19301), GATE_DISK_FROM (default
# ~/.micropod/ci/worker.ext4, cloned, read only), GATE_DOCKER, GATE_CPUS (4),
# GATE_MEMORY_MIB (4096), GATE_CACHE_DISK (8g), GATE_TIMEOUT (900 s per
# container), GATE_IMG_GO/NODE/PY/BASE.
#
# Safety: one throwaway machine under GATE_ROOT with MICROPOD_LINK_DOCKER_SOCK=0
# and its own MICROPOD_API_SOCK, API port and shim port (19300, 19301); only that
# root's VMM is ever signalled (its pid is checked against the root first),
# and the machine is stopped and the root removed at exit (trap). The rig
# (~/.micropod/hvf, ~/.micropod/docker.sock, ~/.micropod/api.sock, port 45454)
# is never started, stopped, repointed or written.
#
# Exit status: 0 every check passed, 1 a check failed, 2 the gate could not run.
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/phase-b"
REPO="$(cd "$HERE/../.." && pwd)"
SECTIONS="B1,B2,B2X"
SABOTAGE=""
PAYLOAD_SRC=""
KEEP=0
TS="$(date -u +%Y%m%dT%H%M%SZ)"
R="$HOME/.micropod/gates/b22/$TS"

usage() { sed -n '2,/^set -o pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
while [ "$#" -gt 0 ]; do
    case $1 in
    --sections) SECTIONS=$2 && shift ;;
    --sabotage) SABOTAGE=$2 && shift ;;
    --payload) PAYLOAD_SRC=$2 && shift ;;
    --receipt-dir) R=$2 && shift ;;
    --keep) KEEP=1 ;;
    -h | --help) usage && exit 0 ;;
    *) echo "unknown argument $1 (see --help)" >&2 && exit 2 ;;
    esac
    shift
done
case ",$SABOTAGE," in ",," | ",b1-mutate," | ",b1-lose-cache-disk," | ",b2-trusted-attack," | ",b2-touch,") ;; *) echo "unknown --sabotage $SABOTAGE" >&2 && exit 2 ;; esac
# A misspelt section would otherwise run nothing and pass.
[ -n "$SECTIONS" ] || { echo "--sections is empty" >&2 && exit 2; }
for sec in $(echo "$SECTIONS" | tr ',' ' '); do
    case $sec in B1 | B2 | B2X) ;; *) echo "unknown section '$sec' (B1, B2, B2X)" >&2 && exit 2 ;; esac
done
case $SABOTAGE in b1-*) NEEDS=B1 ;; b2-*) NEEDS=B2 ;; *) NEEDS="" ;; esac
want() { case ",$SECTIONS," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
sabotage() { [ "$SABOTAGE" = "$1" ]; }
[ -z "$NEEDS" ] || want "$NEEDS" || { echo "--sabotage $SABOTAGE needs section $NEEDS" >&2 && exit 2; }

BASE="${GATE_ROOT:-/tmp/mpg-b22}"
case "$BASE" in
*/ | *//* | */./* | */. | */../* | */..) echo "GATE_ROOT must be a plain directory under /tmp" >&2 && exit 2 ;;
/tmp/?* | /private/tmp/?*) ;;
*) echo "GATE_ROOT must be a throwaway directory under /tmp (got '$BASE')" >&2 && exit 2 ;;
esac
MARKER=.micropod-gate-b22
if [ -e "$BASE" ] && [ ! -f "$BASE/$MARKER" ] && [ -n "$(ls -A "$BASE" 2>/dev/null)" ]; then
    echo "$BASE exists and was not made by this harness (no $MARKER)" >&2
    exit 2
fi
MROOT="$BASE/m"   # the machine root
WS="$BASE/ws"     # the machine's workspace share
STAGE="$BASE/stage"
TMPD="$BASE/tmp"
SOCK="$MROOT/run/docker.sock"
M="${GATE_MICROPOD:-$REPO/.build/debug/micropod}"
DISK_FROM="${GATE_DISK_FROM:-$HOME/.micropod/ci/worker.ext4}"
if [ -n "${GATE_DOCKER:-}" ]; then DOCKER=$GATE_DOCKER; elif [ -x /opt/homebrew/bin/docker ]; then DOCKER=/opt/homebrew/bin/docker; else DOCKER="$(command -v docker)"; fi
CPUS="${GATE_CPUS:-4}"
MEM="${GATE_MEMORY_MIB:-4096}"
CACHE_DISK="${GATE_CACHE_DISK:-8g}"
TIMEOUT="${GATE_TIMEOUT:-900}"
IMG_GO="${GATE_IMG_GO:-golang:alpine}"
IMG_NODE="${GATE_IMG_NODE:-node:26.13.1-alpine}"
IMG_PY="${GATE_IMG_PY:-python:3.12-alpine}"
IMG_BASE="${GATE_IMG_BASE:-alpine:3.20}"
PNPM_VERSION=10.34.9
FIX="$REPO/scripts/fixtures/caches"
KINDS="gomod gobuild npm pnpm yarn yarnberry pip uv cargo corepack maven gradle bun sccache playwright"
S="$(date +%s)"
SB="gb-$S" # B1/B2 scope
SX="gx-$S" # crash scope
GO_REQ="GOFLAGS=-mod=mod"
GO_LOCAL="GOTOOLCHAIN=local"
GO_OFF="GOPROXY=off"

if [ -z "$PAYLOAD_SRC" ]; then
    KG="$HOME/.micropod/hvf/known-good"
    [ -L "$KG" ] && PAYLOAD_SRC="$HOME/.micropod/hvf/$(readlink "$KG")"
fi
for need in "$M" "$DOCKER"; do [ -x "$need" ] || { echo "missing executable $need" >&2 && exit 2; }; done
for need in micropod-vmm Image mp-hvf-init.cpio tools/runner/start.sh; do
    [ -f "$PAYLOAD_SRC/$need" ] || { echo "payload '$PAYLOAD_SRC' lacks $need (pass --payload)" >&2 && exit 2; }
done
[ -f "$DISK_FROM" ] || { echo "missing OS disk image $DISK_FROM" >&2 && exit 2; }
for f in go/base go/big go/newmod npm/a npm/b pnpm/big pnpm/b; do [ -d "$FIX/$f" ] || { echo "missing fixture $FIX/$f" >&2 && exit 2; }; done

mkdir -p "$R/logs" "$R/census" "$R/containers" "$R/engine" || exit 2
: >"$R/checks.tsv"
: >"$R/metrics.tsv"
exec > >(tee -a "$R/logs/harness.log") 2>&1
log() { printf '%s phase-b: %s\n' "$(date +%H:%M:%S)" "$*"; }

# --- the throwaway machine's environment --------------------------------------
export MICROPOD_HVF_ROOT="$MROOT"
export MICROPOD_RUNTIMES_CONFIG="$TMPD/runtimes.json"
export MICROPOD_CLI="$M"
export MICROPOD_DOCKER_SOCK="$MROOT/canonical-docker.sock"
export MICROPOD_LINK_DOCKER_SOCK=0
export MICROPOD_API_SOCK="$BASE/api.sock"
export MICROPOD_API_PORT="${GATE_API_PORT:-19300}"
export MICROPOD_SHIM_TCP_PORT="${GATE_SHIM_PORT:-19301}"
export MICROPOD_HVF_AUTOSTART=0
export MICROPOD_NO_UPDATE_NOTIFIER=1
unset MICROPOD_DEFAULT_RUNTIME DOCKER_CONTEXT BUILDX_BUILDER DOCKER_BUILDKIT
export DOCKER_HOST="unix://$SOCK"
export DOCKER_CONFIG="$TMPD/docker"
RIG_LINK_BEFORE="$(readlink "$HOME/.micropod/docker.sock" 2>/dev/null || echo absent)"
RIG_VMM_BEFORE="$(python3 -c "import json; print(json.load(open('$HOME/.micropod/hvf/run/state.json')).get('vmmPID'))" 2>/dev/null || echo none)"

# Committed payloads are read-only: make a tree writable before removing it.
remove_tree() { [ ! -e "$1" ] || { chmod -R u+w "$1" 2>/dev/null; rm -rf "$1"; }; }
ABORTED="" # why the gate could not run to the end, if it could not
FINISHED=0
abort() { ABORTED=$1 && log "ABORT: $1" && exit 2; }
# write_result: result.json from checks.tsv, metrics.tsv and versions.txt.
write_result() {
    python3 - "$R" "$TS" "$PASS" "$FAIL" "$SECTIONS" "$SABOTAGE" "$BASE" "$ABORTED" "$FINISHED" <<'PY'
import datetime, json, os, sys
r, ts, ok, bad, sections, sabotage, base, aborted, finished = sys.argv[1:]
def rows(name, sep):
    try:
        return [l.rstrip("\n").split(sep) for l in open(os.path.join(r, name))]
    except OSError:
        return []
checks = [{"id": f[0], "section": f[1], "status": f[2], "label": f[3], "got": f[4], "want": f[5], "evidence": f[6] if len(f) > 6 else ""}
          for f in rows("checks.tsv", "\t") if len(f) >= 6]
metrics = {f[0]: "\t".join(f[1:]) for f in rows("metrics.tsv", "\t") if f and f[0]}
versions = {}
for f in rows("versions.txt", "\n"):
    k, _, v = f[0].partition("=")
    versions[k] = v
names = {"P": "preflight", "S": "seed", "B1": "cache disk across OS disk replacement and payload update",
         "B2": "untrusted and read-only containers write zero bytes", "B2X": "crash: dirty unit discarded, rest preserved"}
by = {}
for c in checks:
    s = by.setdefault(c["section"], {"name": names.get(c["section"], c["section"]), "passed": 0, "failed": 0})
    s["passed" if c["status"] == "pass" else "failed"] += 1
complete = set(sections.split(",")) >= {"B1", "B2", "B2X"} and not sabotage
if aborted or finished != "1":
    verdict = "error"
elif int(bad) or not checks:
    verdict = "fail"
else:
    # Only the whole gate, unsabotaged, passes; anything less says so.
    verdict = "pass" if complete else "partial"
doc = {
    "gate": "micropod Phase B: B1 (OS disk replacement preserves caches.ext4) and B2 (untrusted writes zero bytes)",
    "backlog": "B22",
    "receipt": r,
    "started": datetime.datetime.strptime(ts, "%Y%m%dT%H%M%SZ").replace(tzinfo=datetime.timezone.utc).isoformat(),
    "finished": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "sections": sections.split(","),
    "sabotage": sabotage or None,
    "complete": complete,
    "aborted": aborted or None,
    "throwawayRoot": base,
    "versions": versions,
    "summary": {"checks": len(checks), "passed": int(ok), "failed": int(bad), "bySection": by},
    "verdict": verdict,
    "failed": [c["id"] + " " + c["label"] for c in checks if c["status"] != "pass"],
    "checks": checks,
    "metrics": metrics,
}
json.dump(doc, open(os.path.join(r, "result.json"), "w"), indent=2)
print(f"result: {verdict} — {ok} passed, {bad} failed of {len(checks)} checks" + (f" (aborted: {aborted})" if aborted else ""))
for c in doc["failed"]:
    print("  failed:", c)
PY
}
cleanup() {
    local rc=$?
    set +e
    if [ -S "$SOCK" ]; then
        "$DOCKER" ps -aq --filter "label=gate-run=$S" 2>/dev/null | while read -r id; do "$DOCKER" rm -f "$id" >/dev/null 2>&1; done
        "$M" --json machine status >"$R/engine/machine-status-end.json" 2>&1
        "$M" machine logs -n 400 >"$R/logs/console-tail.log" 2>&1
    fi
    [ "$FINISHED" = 1 ] || [ -n "$ABORTED" ] || ABORTED="interrupted (exit $rc)"
    write_result
    [ -f "$MROOT/machine.json" ] && "$M" machine stop >"$R/logs/final-stop.log" 2>&1
    log "rig link ~/.micropod/docker.sock -> $(readlink "$HOME/.micropod/docker.sock" 2>/dev/null || echo absent) (before: $RIG_LINK_BEFORE)"
    log "rig vmm pid before $RIG_VMM_BEFORE, now $(python3 -c "import json; print(json.load(open('$HOME/.micropod/hvf/run/state.json')).get('vmmPID'))" 2>/dev/null || echo none) (other agents deploy there; this harness never signals it)"
    if [ "$KEEP" != 1 ] && [ -f "$BASE/$MARKER" ]; then
        remove_tree "$BASE"
    fi
    log "receipt: $R/result.json"
    if [ -n "$ABORTED" ]; then exit 2; elif [ "$FAIL" -gt 0 ] || [ "$PASS" -eq 0 ]; then exit 1; else exit 0; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# --- checks ---------------------------------------------------------------------
PASS=0 FAIL=0 SECTION=P
# shellcheck disable=SC2034 # the per-section counters are read through eval (record)
NUM_P=0 NUM_S=0 NUM_B1=0 NUM_B2=0 NUM_B2X=0
record() { # record LABEL GOT WANT OK(1|0) [EVIDENCE]
    local n id st
    eval "n=\$((NUM_$SECTION + 1)); NUM_$SECTION=\$n"
    id=$(printf '%s-%02d' "$SECTION" "$n")
    if [ "$4" = 1 ]; then
        PASS=$((PASS + 1)) st=pass
        echo "  ✓ $id $1"
    else
        FAIL=$((FAIL + 1)) st=fail
        echo "  ✗ $id $1 — got '$2', want $3"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$SECTION" "$st" "$1" "$2" "$3" "${5:-}" | tr -d '\r' >>"$R/checks.tsv"
}
check() { record "$1" "$2" "'$3'" "$([ "$2" == "$3" ] && echo 1 || echo 0)" "${4:-}"; } # equality
checkp() { record "$1" "$2" "$3" "$4" "${5:-}"; }                                     # predicate
ok() { if "$@" >/dev/null 2>&1; then echo 1; else echo 0; fi; }
# matches VALUE GLOB. (bash 3.2 cannot parse `case … in pat)` inside $( ).)
matches() {
    # shellcheck disable=SC2254 # the pattern is the glob
    case $1 in $2) return 0 ;; *) return 1 ;; esac
}
num() { case $1 in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }
gt0() { num "$1" && [ "$1" -gt 0 ]; }
host_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }
wall() { cat "$R/containers/$1.wall-ms" 2>/dev/null || echo na; }
# sha256 of a host file (the cache disk image, while the machine is stopped).
host_sha256() { if command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 -r "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
metric() { printf '%s\t%s\n' "$1" "$2" >>"$R/metrics.tsv"; }
section() {
    SECTION=$1
    echo
    log "== $1: $2"
}

# --- machine ------------------------------------------------------------------
state() { python3 -c "import json; s=json.load(open('$MROOT/run/state.json')); print($1)" 2>/dev/null; }
ping_engine() { curl -s -m 5 --unix-socket "$SOCK" http://d/_ping 2>/dev/null | grep -q OK; }
wait_engine() {
    local deadline=$((SECONDS + $1))
    until ping_engine; do
        [ "$SECONDS" -lt "$deadline" ] || return 1
        sleep 0.5
    done
}
canon() { python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$1"; }
CMROOT=""
# my_vmm: the VMM pid of this root, or "" when the pid is not this root's VMM.
my_vmm() {
    local pid cmd
    pid=$(state "s.get('vmmPID') or ''")
    num "$pid" || return 0
    cmd=$(ps -o command= -p "$pid" 2>/dev/null)
    case "$cmd" in
    "$MROOT"/*micropod-vmm\ * | "$CMROOT"/*micropod-vmm\ *) echo "$pid" ;;
    esac
}
start_machine() { # start_machine TAG
    "$M" machine start --timeout 300 >"$R/logs/machine-start-$1.log" 2>&1
    local rc=$?
    wait_engine 120 || rc=99
    checkp "machine start ($1): the throwaway machine answers on its own socket" "rc=$rc ping=$(ping_engine && echo OK || echo none)" "rc=0 ping=OK" \
        "$([ "$rc" = 0 ] && ping_engine && echo 1 || echo 0)" "logs/machine-start-$1.log"
    local link
    link=$(readlink "$HOME/.micropod/docker.sock" 2>/dev/null || echo absent)
    checkp "machine start ($1): ~/.micropod/docker.sock is not pointed at the throwaway machine" "$link" "not $SOCK" \
        "$(if matches "$link" "$MROOT*" || matches "$link" "$CMROOT*" || matches "$link" "$BASE*"; then echo 0; else echo 1; fi)"
}
inventory() { # inventory TAG [stats=0]: the engine's GET /micropod/caches, saved
    local q=""
    [ "${2:-}" = nostats ] && q="?stats=0"
    curl -s -m 120 --unix-socket "$SOCK" "http://d/micropod/caches$q" >"$R/engine/inventory-$1.json"
}
inv() { # inv TAG PYEXPR over d (the saved inventory)
    python3 - "$R/engine/inventory-$1.json" "$2" <<'PY' 2>/dev/null || echo "?"
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    d = {}
print(eval(sys.argv[2], {"d": d, "units": d.get("units") or []}))
PY
}
# wait_clean SECONDS SCOPE…: until no unit of those scopes is dirty or in use.
wait_clean() {
    local secs=$1 deadline
    shift
    deadline=$((SECONDS + secs))
    while :; do
        inventory clean-poll nostats
        [ "$(inv clean-poll "sum(1 for u in units if u['scope'] in '$*'.split() and (u['dirty'] or u['inUse']))")" = 0 ] && return 0
        [ "$SECONDS" -lt "$deadline" ] || return 1
        sleep 1
    done
}

# --- containers -----------------------------------------------------------------
# The gate's directory in the workspace share, spelled as the machine records
# its workspace (canonical: /private/tmp/…); bind sources must be below it.
WS_GUEST="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$WS")"
GW="$WS_GUEST/gate-$S"
OUTD="$GW/out"
TOOLS_MODE=ro # rw only for the container that installs pnpm into /t
mounts_std() { echo "-v ${GW}/g:/g:ro -v ${GW}/f:/f:ro -v ${GW}/t:/t:${TOOLS_MODE} -v ${GW}/out:/o"; }
# run_c NAME IMAGE [docker args…] -- CMD…: foreground, with a watchdog; keeps
# the inspect, removes the container.
run_c() {
    local name=$1 image=$2 pid waited=0 cname="gpb-$S-$1"
    shift 2
    local args=()
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do args+=("$1") && shift; done
    shift
    rm -f "$OUTD/$name.res" "$OUTD/$name.log" "$R/containers/$name.wall-ms"
    # The host's clock around the whole container (create, cache attach, the
    # command, exit): what the container costs, measured outside it.
    (
        t0=$(host_ms)
        # shellcheck disable=SC2046
        "$DOCKER" run --name "$cname" --label "gate-run=$S" -e "GTAG=$S" $(mounts_std) ${args[@]+"${args[@]}"} "$image" "$@"
        rc=$?
        echo $(($(host_ms) - t0)) >"$R/containers/$name.wall-ms"
        exit "$rc"
    ) >"$R/containers/$name.stdout" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        sleep 0.2
        waited=$((waited + 1))
        if [ "$waited" -ge $((TIMEOUT * 5)) ]; then
            echo "harness: timeout after ${TIMEOUT}s" >>"$R/containers/$name.stdout"
            "$DOCKER" rm -f "$cname" >/dev/null 2>&1
            kill "$pid" 2>/dev/null
            break
        fi
    done
    wait "$pid"
    echo "$?" >"$R/containers/$name.docker-rc"
    finish_c "$name"
}
run_d() { # run_d NAME IMAGE [docker args…] -- CMD…: detached
    local name=$1 image=$2 cname="gpb-$S-$1"
    shift 2
    local args=()
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do args+=("$1") && shift; done
    shift
    rm -f "$OUTD/$name.res" "$OUTD/$name.log"
    # shellcheck disable=SC2046
    "$DOCKER" run -d --name "$cname" --label "gate-run=$S" -e "GTAG=$S" $(mounts_std) ${args[@]+"${args[@]}"} "$image" "$@" \
        >"$R/containers/$name.stdout" 2>&1
    echo "$?" >"$R/containers/$name.docker-rc"
}
finish_c() { # keep inspect, result and log; remove the container
    local cname="gpb-$S-$1"
    "$DOCKER" inspect "$cname" >"$R/containers/$1.inspect.json" 2>/dev/null || echo '[]' >"$R/containers/$1.inspect.json"
    "$DOCKER" rm -f "$cname" >/dev/null 2>&1
    cp "$OUTD/$1.res" "$OUTD/$1.log" "$R/containers/" 2>/dev/null
}
r() { # r NAME KEY: a value from a container's result file ("missing" without a file)
    [ -f "$OUTD/$1.res" ] || { echo missing; return; }
    grep "^$2=" "$OUTD/$1.res" | tail -1 | cut -d= -f2-
}
sentinel() { grep -q "^GATE-SENTINEL $1\$" "$OUTD/$1.res" 2>/dev/null; }
insp() { # insp NAME EXPR: python over the saved inspect (c)
    python3 - "$R/containers/$1.inspect.json" "$2" <<'PY' 2>/dev/null || echo "?"
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    data = []
c = data[0] if data else {}
mc = c.get("MicropodCache") or {}
print(eval(sys.argv[2], {"c": c, "mc": mc, "tools": mc.get("tools") or {}}))
PY
}
access_of() { insp "$1" "' '.join('%s=%s' % (t, (tools.get(t) or {}).get('access') or ('writer' if (tools.get(t) or {}).get('mode') else 'none')) for t in '$2'.split())"; }
# workload NAME TIER SCOPE IMAGE NET ACTION [VARIANT [MODE]] [-- extra docker args…]
# TIER: trusted (no label), untrusted, readonly.
workload() {
    local name=$1 tier=$2 scope=$3 image=$4 net=$5 action=$6 variant="" mode=""
    shift 6
    if [ "$#" -gt 0 ] && [ "$1" != -- ]; then variant=$1 && shift; fi
    if [ "$#" -gt 0 ] && [ "$1" != -- ]; then mode=$1 && shift; fi
    if [ "$#" -gt 0 ] && [ "$1" = -- ]; then shift; fi
    local args=(--label "io.micropod.cache.scope=$scope")
    case $tier in
    untrusted) args+=(--label io.micropod.cache.trust=untrusted) ;;
    readonly) args+=(--label io.micropod.cache.readonly=1) ;;
    esac
    [ "$net" = none ] && args+=(--network none)
    run_c "$name" "$image" "${args[@]}" "$@" -- sh /g/probe.sh "$name" "$action" "$variant" "$mode"
    sentinel "$name" || checkp "$name: its result file carries the sentinel" \
        "missing (docker rc $(cat "$R/containers/$name.docker-rc" 2>/dev/null); $(tail -c 200 "$R/containers/$name.stdout" 2>/dev/null | tr '\n' ' '))" "present" 0
}
landed_all() { # every op on all four stores landed in the attacker's own view
    local t l
    t=$(r "$1" attack.tried) l=$(r "$1" attack.landed)
    [ "$(r "$1" attack.gomod.present)$(r "$1" attack.gobuild.present)$(r "$1" attack.npm.present)$(r "$1" attack.pnpm.present)" = yesyesyesyes ] &&
        [ "$t" = "$l" ] && num "$t" && [ "$t" -ge 52 ] && echo 1 || echo 0
}
go_hits() { echo "rc=$(r "$1" rc) compiles=$(r "$1" compiles) downloads=$(r "$1" downloads)"; }

# census TAG SCOPE…: one census container over every kind of each scope; the
# engine's own read of every real store; the engine inventory.
census() {
    local tag=$1 sc k cname="gpb-$S-census-$1" waited=0 store
    shift
    local args=()
    for sc in "$@"; do for k in $KINDS; do args+=(-v "micropod-ci-scoped-$sc-$k:/c/$sc.$k:ro"); done; done
    rm -f "$OUTD/census-$tag.json" "$OUTD/census-$tag.done"
    local t0=$SECONDS
    "$DOCKER" run -d --name "$cname" --label "gate-run=$S" --label io.micropod.cache=off --network none \
        -v "${GW}/g:/g:ro" -v "${GW}/out:/o" "${args[@]}" "$IMG_PY" \
        sh -c "python3 -I /g/census.py /c /o/census-$tag.json > /o/census-$tag.log 2>&1; touch /o/census-$tag.done; sleep 1800" \
        >"$R/census/census-$tag.run" 2>&1
    while [ ! -f "$OUTD/census-$tag.done" ] && [ "$waited" -lt $((TIMEOUT * 5)) ]; do
        sleep 0.2
        waited=$((waited + 1))
        [ "$("$DOCKER" inspect -f '{{.State.Running}}' "$cname" 2>/dev/null)" = true ] || [ "$waited" -lt 50 ] || break
    done
    cp "$OUTD/census-$tag.json" "$R/census/$tag.json" 2>/dev/null
    cp "$OUTD/census-$tag.log" "$R/census/$tag.log" 2>/dev/null
    if [ -f "$R/census/$tag.json" ]; then
        for store in $(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(' '.join(n for n, r in sorted(d['stores'].items()) if r['real']))" "$R/census/$tag.json"); do
            "$DOCKER" cp "$cname:/c/$store" - 2>"$R/census/archive-$tag-$store.err" |
                python3 -I "$GATE/archive_manifest.py" "$R/census/archive-$tag-$store.json" >"$R/census/archive-$tag-$store.log" 2>&1
        done
    fi
    "$DOCKER" inspect "$cname" >"$R/census/census-$tag.inspect.json" 2>/dev/null
    "$DOCKER" rm -f "$cname" >/dev/null 2>&1
    inventory "$tag"
    metric "census.$tag.seconds" "$((SECONDS - t0))"
    [ -f "$R/census/$tag.json" ]
}
cdiff() { # cdiff A B SCOPE FIELDS [KINDS]: one summary line
    local min=4 # gomod, gobuild, npm, pnpm of a whole scope; else every kind asked for
    [ -z "${5:-}" ] || min=$(echo "$5" | tr ',' '\n' | grep -c .)
    python3 -I "$GATE/compare.py" diff "$R/census/$1.json" "$R/census/$2.json" --scope "$3" --fields "$4" --min-stores "$min" \
        ${5:+--kinds "$5"} --out "$R/census/diff-$1-$2-$3-${4//,/+}.json" 2>&1 | tail -1
}
is_equal() { case $1 in equal:*) return 0 ;; *) return 1 ;; esac; }
store_real() { # store_real TAG SCOPE KIND: "real files=N mount=root,fstype,source,opts" or "absent"
    python3 - "$R/census/$1.json" "$2.$3" <<'PY' 2>/dev/null || echo "no-census"
import json, sys
d = json.load(open(sys.argv[1]))
r = d["stores"].get(sys.argv[2])
if not r or not r["real"]:
    print("absent")
else:
    m = r["mount"]
    print(f"real files={r['files']} ro={r['readOnlyMount']} {m.get('root')} {m.get('fstype')} {m.get('source')}")
PY
}
archive_core() { # archive_core TAG STORE: the engine read's core digest
    python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['coreDigest'])" "$R/census/archive-$1-$2.json" 2>/dev/null || echo "none"
}
# check_engine_reads TAG SCOPE: the engine's read of each real store equals the census's
check_engine_reads() {
    local store res bad="" n=0
    for store in $(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(' '.join(n for n, r in sorted(d['stores'].items()) if r['real'] and r['scope']==sys.argv[2]))" "$R/census/$1.json" "$2"); do
        n=$((n + 1))
        res=$(python3 -I "$GATE/compare.py" cross "$R/census/$1.json" "$R/census/archive-$1-$store.json" --store "$store" 2>&1 | tail -1)
        case $res in same:*) ;; *) bad="$bad $store: $res;" ;; esac
    done
    checkp "census $1: the engine's own read of every real $2 store (docker cp of the alias) hashes the same as the census" \
        "${bad:-all $n same}" "all same, at least 4 stores" "$([ -z "$bad" ] && [ "$n" -ge 4 ] && echo 1 || echo 0)" "census/archive-$1-*.json"
}
median() { python3 -c "import statistics,sys; v=[int(x) for x in sys.argv[1:] if x.isdigit()]; print(int(statistics.median(v)) if len(v)==len(sys.argv[1:]) and v else 'na')" "$@"; }

# --- 0. install the throwaway machine ---------------------------------------------
log "receipt $R"
log "throwaway root $BASE (machine $MROOT, workspace $WS); sections $SECTIONS; sabotage ${SABOTAGE:-none}"
"$M" machine stop >/dev/null 2>&1 # a machine an earlier run of this harness left (ours: marker checked)
remove_tree "$BASE"
{ mkdir -p "$BASE" "$MROOT" "$WS" "$STAGE" "$TMPD/docker" && touch "$BASE/$MARKER"; } || abort "cannot create $BASE"
echo '{}' >"$DOCKER_CONFIG/config.json"
CMROOT="$(canon "$MROOT")"
log "cloning payload $PAYLOAD_SRC"
cp -cR "$PAYLOAD_SRC/." "$STAGE/payload/" 2>/dev/null || cp -R "$PAYLOAD_SRC/." "$STAGE/payload/"
chmod -R u+w "$STAGE/payload"
{
    echo "harness_rev=$(git -C "$REPO" rev-parse HEAD 2>/dev/null)"
    echo "harness_dirty=$(git -C "$REPO" status --porcelain -- scripts/gates 2>/dev/null | wc -l | tr -d ' ')"
    echo "repo_head=$(git -C "$REPO" rev-parse HEAD 2>/dev/null)"
    echo "micropod_cli=$M"
    echo "micropod_cli_sha256=$(shasum -a 256 "$M" | cut -d' ' -f1)"
    echo "payload_src=$PAYLOAD_SRC"
    for f in micropod-vmm Image mp-hvf-init.cpio tools/runner/start.sh tools/runner/bin/job; do
        echo "payload_sha256.$f=$(shasum -a 256 "$STAGE/payload/$f" 2>/dev/null | cut -d' ' -f1)"
    done
    echo "payload_manifest=$(tr -d '\n ' <"$STAGE/payload/payload-manifest.json" 2>/dev/null)"
    echo "bundle_manifest=$(cat "$STAGE/payload/tools/runner/manifest.json" 2>/dev/null)"
    echo "disk_from=$DISK_FROM"
    echo "docker_cli=$("$DOCKER" version --format '{{.Client.Version}}' 2>/dev/null)"
    echo "rig_link_before=$RIG_LINK_BEFORE"
    echo "rig_vmm_before=$RIG_VMM_BEFORE"
    echo "sections=$SECTIONS"
    echo "sabotage=$SABOTAGE"
    echo "scope_b=$SB"
    echo "scope_x=$SX"
} >"$R/versions.txt"
mkdir -p "$GW/g" "$GW/f/go" "$GW/f/npm" "$GW/f/pnpm" "$GW/t" "$OUTD"
cp "$GATE/probe.sh" "$GATE/census.py" "$GW/g/"
for f in go/base go/big go/newmod npm/a npm/b pnpm/big pnpm/b; do cp -R "$FIX/$f" "$GW/f/$(dirname "$f")/"; done
chmod -R a+rX "$GW" && chmod 0777 "$OUTD" "$GW/t"

section P "preflight: a throwaway machine of this tree's payload, with a cache disk"
"$M" machine install --vmm "$STAGE/payload/micropod-vmm" --kernel "$STAGE/payload/Image" --initrd "$STAGE/payload/mp-hvf-init.cpio" \
    --tools "$STAGE/payload/tools" --disk-from "$DISK_FROM" --cache-disk-size "$CACHE_DISK" \
    --cpus "$CPUS" --memory-mib "$MEM" --workspace "$WS" >"$R/logs/install.log" 2>&1
INSTALL_RC=$?
check "machine install into the throwaway root" "$INSTALL_RC" 0 "logs/install.log"
[ "$INSTALL_RC" = 0 ] || { cat "$R/logs/install.log"; abort "machine install failed"; }
check "the machine records its workspace as $WS_GUEST (bind sources are spelled that way)" \
    "$(python3 -c "import json; print(json.load(open('$MROOT/machine.json')).get('workspace'))")" "$WS_GUEST"
start_machine boot
ping_engine || { tail -40 "$R/logs/machine-start-boot.log"; abort "the engine never answered"; }
curl -s -m 5 --unix-socket "$SOCK" http://d/version >"$R/engine/version.json"
"$M" --json machine status >"$R/engine/machine-status-boot.json" 2>&1
"$M" machine cache policy show >"$R/engine/cache-policy.txt" 2>&1
inventory boot nostats
ENGINE_COMMIT=$(python3 -c "import json; v=json.load(open('$R/engine/version.json')); print(v.get('GitCommit') or v.get('MicropodEngineCommit') or v.get('Commit') or 'none')" 2>/dev/null)
HEAD_REV=$(git -C "$REPO" rev-parse HEAD 2>/dev/null)
# The product paths of this tree (guest engine, VMM and guest init, host CLI,
# tool bundle build) must be the engine's commit's: other commits on the
# branch (harness scripts) do not change what is under test.
PRODUCT_PATHS="guest vmm Sources Package.swift Package.resolved ci"
# shellcheck disable=SC2086 # a list of paths
PRODUCT_DIFF=$( [ "${#ENGINE_COMMIT}" -ge 7 ] && git -C "$REPO" diff --stat "$ENGINE_COMMIT" HEAD -- $PRODUCT_PATHS 2>&1 | tail -1)
# shellcheck disable=SC2086
PRODUCT_DIRTY=$(git -C "$REPO" status --porcelain -- $PRODUCT_PATHS 2>/dev/null | wc -l | tr -d ' ')
checkp "the engine under test (GET /version commit) is this tree's product source: no change in $PRODUCT_PATHS since it, none uncommitted" \
    "engine=$ENGINE_COMMIT head=$HEAD_REV diff='${PRODUCT_DIFF}' uncommitted=$PRODUCT_DIRTY" "a commit of HEAD's history, empty diff, 0 uncommitted" \
    "$([ "${#ENGINE_COMMIT}" -ge 7 ] && git -C "$REPO" merge-base --is-ancestor "$ENGINE_COMMIT" HEAD 2>/dev/null && [ -z "$PRODUCT_DIFF" ] && [ "$PRODUCT_DIRTY" = 0 ] && echo 1 || echo 0)" "engine/version.json"
echo "engine_commit=$ENGINE_COMMIT" >>"$R/versions.txt"
# The host CLI does the disk replacement and the update: it must have been
# built from this tree's host sources as they are (no tracked source file
# under Sources/ or Package.* is newer than the binary).
NEWER=$(git -C "$REPO" ls-files -z -- Sources Package.swift Package.resolved 2>/dev/null | python3 -c "
import os, sys
repo, cli = sys.argv[1:]
built = os.stat(cli).st_mtime
names = [n for n in sys.stdin.buffer.read().decode().split('\0') if n]
newer = [n for n in names if os.path.exists(os.path.join(repo, n)) and os.stat(os.path.join(repo, n)).st_mtime > built]
print(len(newer) if names else 'no-sources', *newer[:3])" "$REPO" "$M" 2>/dev/null)
check "the host CLI under test ($M) is not older than any tracked host source file" "${NEWER:-?}" 0
check "the engine's shared caches are on the cache disk (GET /micropod/caches cacheDisk)" \
    "$(inv boot "(d.get('cacheDisk') or {}).get('state'), (d.get('cacheDisk') or {}).get('mounted'), d.get('unavailable')")" "('mounted', True, None)" \
    "engine/inventory-boot.json"
CACHE_DEV=$(inv boot "(d.get('cacheDisk') or {}).get('device')")
check "the shipped cache policy: mode auto, default trust trusted" \
    "$(inv boot "(d.get('policy') or {}).get('mode'), (d.get('policy') or {}).get('defaultTrust') or 'trusted'")" "('auto', 'trusted')" \
    "engine/inventory-boot.json"

# --- seed -----------------------------------------------------------------------------
section S "seed: trusted real installs into scope $SB"
pull_all() { # pull_all TAG: pulls by tag the first time, by digest after
    local img ref rc all=0
    for img in IMG_GO IMG_NODE IMG_PY IMG_BASE; do
        eval "ref=\$$img"
        "$DOCKER" pull -q "$ref" >>"$R/logs/pull-$1.log" 2>&1
        rc=$?
        [ "$rc" = 0 ] || all=1
        case $ref in *@sha256:*) ;; *)
            local dg
            dg=$("$DOCKER" image inspect --format '{{index .RepoDigests 0}}' "$ref" 2>/dev/null)
            case $dg in *@sha256:*) eval "$img=\$dg" && echo "$img=$dg" >>"$R/versions.txt" ;; esac
            ;;
        esac
    done
    return $all
}
pull_all first
check "pull $IMG_GO, $IMG_NODE, $IMG_PY, $IMG_BASE" "$?" 0 "logs/pull-first.log"
log "images: go=$IMG_GO node=$IMG_NODE py=$IMG_PY base=$IMG_BASE"
TOOLS_MODE=rw
run_c tool-pnpm "$IMG_NODE" --label io.micropod.cache=off -e npm_config_cache=/tmp/npmc -e "GPNPM=$PNPM_VERSION" \
    -- sh /g/probe.sh tool-pnpm tool-install
TOOLS_MODE=ro
check "pnpm $PNPM_VERSION installed into the workspace by a cache-off container" "$(r tool-pnpm pnpm)" "$PNPM_VERSION"

workload s-go-build trusted "$SB" "$IMG_GO" on go-build base -- -e "$GO_REQ" -e "$GO_LOCAL"
checkp "s-go-build: a cold trusted go build -x fills gomod and gobuild (it downloads and compiles)" "$(go_hits s-go-build)" "rc=0 compiles>0 downloads>0" \
    "$([ "$(r s-go-build rc)" = 0 ] && gt0 "$(r s-go-build compiles)" && gt0 "$(r s-go-build downloads)" && echo 1 || echo 0)" "containers/s-go-build.log"
check "s-go-build: the engine attached gomod and gobuild as the trusted writer of scope $SB" \
    "$(insp s-go-build "(mc.get('trust') or 'trusted', (tools.get('gomod') or {}).get('scope'), (tools.get('gobuild') or {}).get('scope'), (tools.get('gomod') or {}).get('access'))")" \
    "('trusted', '$SB', '$SB', None)" "containers/s-go-build.inspect.json"
workload s-go-big trusted "$SB" "$IMG_GO" on go-build big -- -e "$GO_REQ" -e "$GO_LOCAL"
checkp "s-go-big: a cold trusted build of x/tools/go/packages and x/text compiles them into gobuild" "$(go_hits s-go-big)" "rc=0 compiles>50 downloads>0" \
    "$([ "$(r s-go-big rc)" = 0 ] && [ "$(r s-go-big compiles)" -gt 50 ] 2>/dev/null && gt0 "$(r s-go-big downloads)" && echo 1 || echo 0)" "containers/s-go-big.log"
metric "seed.go_big_cold_ms" "$(r s-go-big ms)"
workload s-go-download trusted "$SB" "$IMG_GO" on go-download big -- -e "$GO_REQ" -e "$GO_LOCAL"
checkp "s-go-download: go mod download -x completes gomod with every module of the graph (the build fetched the rest)" \
    "rc=$(r s-go-download rc) gets=$(r s-go-download gets)" "rc=0" \
    "$([ "$(r s-go-download rc)" = 0 ] && num "$(r s-go-download gets)" && echo 1 || echo 0)" "containers/s-go-download.log"
workload s-npm-ci trusted "$SB" "$IMG_NODE" on npm-ci a
checkp "s-npm-ci: a cold trusted npm ci fetches its packages into the npm store" "rc=$(r s-npm-ci rc) cache_miss=$(r s-npm-ci cache_miss)" "rc=0 cache_miss>0" \
    "$([ "$(r s-npm-ci rc)" = 0 ] && gt0 "$(r s-npm-ci cache_miss)" && echo 1 || echo 0)" "containers/s-npm-ci.log"
workload s-pnpm trusted "$SB" "$IMG_NODE" on pnpm-install big
checkp "s-pnpm: a cold trusted pnpm install (lodash, typescript, rxjs) downloads into the pnpm store" \
    "rc=$(r s-pnpm rc) downloaded=$(r s-pnpm downloaded) store=$(r s-pnpm store_path)" "rc=0 downloaded>0 store under /micropod/cache/pnpm" \
    "$([ "$(r s-pnpm rc)" = 0 ] && gt0 "$(r s-pnpm downloaded)" && matches "$(r s-pnpm store_path)" "/micropod/cache/pnpm*" && echo 1 || echo 0)" "containers/s-pnpm.log"
wait_clean 120 "$SB"
check "every unit of $SB is clean (no dirty mark, no holder) once the writers exited" "$?" 0 "engine/inventory-clean-poll.json"

# --- B1 -----------------------------------------------------------------------------------
if want B1; then
    section B1 "the cache disk across an OS disk replacement and a payload update"
    census c0 "$SB"
    check "census c0 ran" "$?" 0 "census/c0.json"
    for k in gomod gobuild npm pnpm; do
        st=$(store_real c0 "$SB" $k)
        checkp "census c0 reads the real $k store (alias bind: /scopes/$SB/$k, ext4 on $CACHE_DEV, ro, files>0)" "$st" \
            "real files>0 ro=True /scopes/$SB/$k ext4 $CACHE_DEV" \
            "$(ok matches "$st" "real files=[1-9]* ro=True /scopes/$SB/$k ext4 $CACHE_DEV")" "census/c0.json"
    done
    check_engine_reads c0 "$SB"
    python3 -I "$GATE/compare.py" digest "$R/census/c0.json" --scope "$SB" >"$R/census/digest-c0.json"
    metric "b1.c0.summary" "$(python3 -c "import json; d=json.load(open('$R/census/digest-c0.json')); print(sum(v['files'] for v in d.values()), 'files', sum(v['bytes'] for v in d.values()), 'bytes')")"

    # A volume on the OS disk: it must be gone after the disk is replaced.
    "$DOCKER" volume create "gate-osdisk-$S" >/dev/null 2>&1
    run_c osdisk-mark "$IMG_BASE" --label io.micropod.cache=off -v "gate-osdisk-$S:/v" -- sh -c "echo os-disk-$S > /v/marker"
    check "a volume on the old OS disk holds its marker" "$("$DOCKER" volume ls -q 2>/dev/null | grep -cx "gate-osdisk-$S")" 1
    if sabotage b1-mutate; then
        log "SABOTAGE b1-mutate: a trusted container appends to one gomod file between the censuses"
        workload sabotage-mutate trusted "$SB" "$IMG_GO" none mutate
        log "  mutated: $(r sabotage-mutate mutated)"
    fi
    DISK_INO_BEFORE=$(stat -f %i "$MROOT/disk.ext4")
    CDISK_BEFORE=$(stat -f '%i %z' "$MROOT/caches.ext4")
    "$M" machine stop >"$R/logs/b1-stop.log" 2>&1
    check "machine stop powers the guest off cleanly" "$(state "s['phase'], 'exit_reason=poweroff' in (s.get('lastExitReason') or '')")" "stopped True"
    # The host's own view, with the guest powered off on both sides: every
    # byte of the cache disk image, before and after the replacement.
    CSHA_BEFORE=$(host_sha256 "$MROOT/caches.ext4")
    if sabotage b1-lose-cache-disk; then
        log "SABOTAGE b1-lose-cache-disk: caches.ext4 moved aside before the replacement"
        mv "$MROOT/caches.ext4" "$TMPD/caches.lost.ext4"
    fi
    t0=$SECONDS
    "$M" machine install --replace-disk --disk-from "$DISK_FROM" >"$R/logs/b1-replace-disk.log" 2>&1
    check "machine install --replace-disk --disk-from <worker.ext4> succeeds" "$?" 0 "logs/b1-replace-disk.log"
    metric "b1.replace_disk.seconds" "$((SECONDS - t0))"
    DISK_INO_AFTER=$(stat -f %i "$MROOT/disk.ext4")
    CDISK_AFTER=$(stat -f '%i %z' "$MROOT/caches.ext4" 2>/dev/null || echo absent)
    CSHA_AFTER=$(host_sha256 "$MROOT/caches.ext4" 2>/dev/null)
    checkp "B1 replace-disk: the host's sha256 of the whole caches.ext4 image is the same before and after (guest off both times)" \
        "${CSHA_BEFORE:-none} -> ${CSHA_AFTER:-none}" "the same 64-hex digest" \
        "$([ "${#CSHA_BEFORE}" = 64 ] && [ "$CSHA_BEFORE" = "$CSHA_AFTER" ] && echo 1 || echo 0)"
    checkp "disk.ext4 is a new file (host inode $DISK_INO_BEFORE -> $DISK_INO_AFTER) and caches.ext4 the same file (inode, size)" \
        "disk=$DISK_INO_BEFORE->$DISK_INO_AFTER caches=$CDISK_BEFORE->$CDISK_AFTER" "disk inode changed, caches unchanged" \
        "$([ "$DISK_INO_BEFORE" != "$DISK_INO_AFTER" ] && [ "$CDISK_BEFORE" = "$CDISK_AFTER" ] && echo 1 || echo 0)"
    start_machine replaced-disk
    check "the old OS disk's volume is gone (the guest booted the new disk)" "$("$DOCKER" volume ls -q 2>/dev/null | grep -cx "gate-osdisk-$S")" 0
    inventory replaced nostats
    check "after the replacement the cache disk is mounted again" \
        "$(inv replaced "(d.get('cacheDisk') or {}).get('state'), (d.get('cacheDisk') or {}).get('mounted'), d.get('discardedAtStart') or []")" "('mounted', True, [])" \
        "engine/inventory-replaced.json"
    pull_all replaced >/dev/null
    census c1 "$SB"
    check "census c1 ran" "$?" 0 "census/c1.json"
    got=$(cdiff c0 c1 "$SB" content)
    checkp "B1 replace-disk: every store of $SB is byte-for-byte identical (type, mode, owner, size, sha256 of every file)" "$got" "equal" \
        "$(ok is_equal "$got")" "census/diff-c0-c1-$SB-content.json"
    got=$(cdiff c0 c1 "$SB" identity)
    checkp "B1 replace-disk: …the same inodes with the same mtimes (nothing re-created or rewritten)" "$got" "equal" \
        "$(ok is_equal "$got")" "census/diff-c0-c1-$SB-identity.json"
    metric "b1.replace_disk.ctime_and_xattrs" "$(cdiff c0 c1 "$SB" meta)"
    bad=""
    for store in $SB.gomod $SB.gobuild $SB.npm $SB.pnpm; do
        [ "$(archive_core c0 "$store")" = "$(archive_core c1 "$store")" ] && [ "$(archive_core c1 "$store")" != none ] || bad="$bad $store"
    done
    checkp "B1 replace-disk: the engine's own read of gomod, gobuild, npm and pnpm hashes as before" "${bad:-all equal}" "all equal" \
        "$([ -z "$bad" ] && echo 1 || echo 0)" "census/archive-c1-*.json"
    got=$(python3 -I "$GATE/compare.py" inventory "$R/engine/inventory-c0.json" "$R/engine/inventory-c1.json" --scope "$SB" | tail -1)
    checkp "B1 replace-disk: the engine's unit inventory of $SB (files, bytes per unit) is unchanged" "$got" "equal" "$(ok is_equal "$got")"

    # The updater: stage a payload (the installed one under a new version id) and activate it.
    P2="$STAGE/payload-2"
    mkdir -p "$P2" && cp -c "$MROOT/micropod-vmm" "$MROOT/Image" "$MROOT/mp-hvf-init.cpio" "$P2/" && cp -cR "$MROOT/tools" "$P2/tools"
    "$M" update hvf stage --from "$P2" --version 9.0.0-gate --revision "$S" >"$R/logs/b1-stage.log" 2>&1
    check "update hvf stage of a second payload" "$?" 0 "logs/b1-stage.log"
    STAGED=$([ -L "$MROOT/staged" ] && basename "$(readlink "$MROOT/staged")" || echo none)
    BEFORE_PAYLOAD=$(basename "$(state "s.get('loadedPayloadPath') or ''")")
    VMM_BEFORE_UPDATE=$(my_vmm)
    "$M" update hvf apply --json >"$R/engine/b1-apply.json" 2>"$R/logs/b1-apply.err"
    code=$?
    check "update hvf apply activates it (exit 0, activated)" \
        "$code:$(python3 -c "import json; print(json.load(open('$R/engine/b1-apply.json')).get('action'))" 2>/dev/null)" "0:activated" "engine/b1-apply.json"
    metric "b1.update.switchover_ms" "$(python3 -c "import json; print(json.load(open('$R/engine/b1-apply.json')).get('switchoverMilliseconds'))" 2>/dev/null)"
    AFTER_PAYLOAD=$(basename "$(state "s.get('loadedPayloadPath') or ''")")
    wait_engine 120
    VMM_AFTER_UPDATE=$(my_vmm)
    VMM_CMD=$(ps -o command= -p "${VMM_AFTER_UPDATE:-0}" 2>/dev/null | cut -d' ' -f1)
    checkp "the machine now runs the staged payload ($STAGED), not the one before ($BEFORE_PAYLOAD): a new VMM process, started from it" \
        "$AFTER_PAYLOAD vmm ${VMM_BEFORE_UPDATE:-none}->${VMM_AFTER_UPDATE:-none} $VMM_CMD" "'$STAGED', another pid, …/versions/$STAGED/micropod-vmm" \
        "$([ "$AFTER_PAYLOAD" = "$STAGED" ] && [ "$STAGED" != none ] && [ "$AFTER_PAYLOAD" != "$BEFORE_PAYLOAD" ] &&
            [ -n "$VMM_BEFORE_UPDATE" ] && [ -n "$VMM_AFTER_UPDATE" ] && [ "$VMM_BEFORE_UPDATE" != "$VMM_AFTER_UPDATE" ] &&
            matches "$VMM_CMD" "*/versions/$STAGED/micropod-vmm" && echo 1 || echo 0)"
    census c2 "$SB"
    check "census c2 ran" "$?" 0 "census/c2.json"
    got=$(cdiff c0 c2 "$SB" content)
    checkp "B1 update: every store of $SB is byte-for-byte identical after the payload switch" "$got" "equal" "$(ok is_equal "$got")" "census/diff-c0-c2-$SB-content.json"
    got=$(cdiff c0 c2 "$SB" identity)
    checkp "B1 update: …the same inodes with the same mtimes" "$got" "equal" "$(ok is_equal "$got")" "census/diff-c0-c2-$SB-identity.json"

    # Warm runs on the new OS disk: new containers, new checkout paths, no network.
    workload b1-go-warm trusted "$SB" "$IMG_GO" none go-build base -- -e "$GO_REQ" -e "$GO_LOCAL" -e "$GO_OFF"
    check "B1 warm: go build -x after both replacements compiles and downloads nothing (--network none, GOPROXY=off)" \
        "$(go_hits b1-go-warm)" "rc=0 compiles=0 downloads=0" "containers/b1-go-warm.log"
    workload b1-go-big-warm trusted "$SB" "$IMG_GO" none go-build big -- -e "$GO_REQ" -e "$GO_LOCAL" -e "$GO_OFF"
    check "B1 warm: go build -x of x/tools/go/packages compiles and downloads nothing" \
        "$(go_hits b1-go-big-warm)" "rc=0 compiles=0 downloads=0" "containers/b1-go-big-warm.log"
    workload b1-go-dl-warm trusted "$SB" "$IMG_GO" none go-download big -- -e "$GO_REQ" -e "$GO_LOCAL" -e "$GO_OFF"
    check "B1 warm: go mod download of x/tools etc. is served from gomod (no proxy get)" \
        "rc=$(r b1-go-dl-warm rc) gets=$(r b1-go-dl-warm gets)" "rc=0 gets=0" "containers/b1-go-dl-warm.log"
    workload b1-npm-warm trusted "$SB" "$IMG_NODE" none npm-ci a offline
    check "B1 warm: npm ci --offline installs from the npm store (--network none)" \
        "rc=$(r b1-npm-warm rc) cache_miss=$(r b1-npm-warm cache_miss)" "rc=0 cache_miss=0" "containers/b1-npm-warm.log"
    workload b1-pnpm-warm trusted "$SB" "$IMG_NODE" none pnpm-install big offline
    checkp "B1 warm: pnpm install --offline downloads nothing and reuses the store (--network none)" \
        "rc=$(r b1-pnpm-warm rc) downloaded=$(r b1-pnpm-warm downloaded) reused=$(r b1-pnpm-warm reused)" "rc=0 downloaded=0 reused>0" \
        "$([ "$(r b1-pnpm-warm rc)" = 0 ] && [ "$(r b1-pnpm-warm downloaded)" = 0 ] && gt0 "$(r b1-pnpm-warm reused)" && echo 1 || echo 0)" "containers/b1-pnpm-warm.log"
fi

# --- B2 -----------------------------------------------------------------------------------
if want B2; then
    section B2 "untrusted and read-only containers write nothing into the trusted stores"
    T_TRUSTED="" W_TRUSTED=""
    for i in 1 2 3; do
        workload b2-trusted-warm-$i trusted "$SB" "$IMG_GO" none go-build big -- -e "$GO_REQ" -e "$GO_LOCAL" -e "$GO_OFF"
        T_TRUSTED="$T_TRUSTED $(r b2-trusted-warm-$i ms)"
        W_TRUSTED="$W_TRUSTED $(wall b2-trusted-warm-$i)"
    done
    check "trusted warm go build of x/tools/go/packages (x3) hits fully" "$(go_hits b2-trusted-warm-1) $(go_hits b2-trusted-warm-2) $(go_hits b2-trusted-warm-3)" \
        "rc=0 compiles=0 downloads=0 rc=0 compiles=0 downloads=0 rc=0 compiles=0 downloads=0"
    wait_clean 120 "$SB"
    check "every unit of $SB is clean before the census" "$?" 0
    census d0 "$SB"
    check "census d0 ran" "$?" 0 "census/d0.json"
    for k in gomod gobuild npm pnpm; do
        st=$(store_real d0 "$SB" $k)
        checkp "census d0 reads the real $k store" "$st" "real files>0 ro=True /scopes/$SB/$k ext4 $CACHE_DEV" \
            "$(ok matches "$st" "real files=[1-9]* ro=True /scopes/$SB/$k ext4 $CACHE_DEV")" "census/d0.json"
    done
    check_engine_reads d0 "$SB"

    # Real work as untrusted.
    T_UNTRUSTED="" W_UNTRUSTED=""
    for i in 1 2 3; do
        workload b2-u-warm-$i untrusted "$SB" "$IMG_GO" none go-build big -- -e "$GO_REQ" -e "$GO_LOCAL" -e "$GO_OFF"
        T_UNTRUSTED="$T_UNTRUSTED $(r b2-u-warm-$i ms)"
        W_UNTRUSTED="$W_UNTRUSTED $(wall b2-u-warm-$i)"
    done
    check "untrusted warm go build -x of x/tools/go/packages gets a warm hit: compiles and downloads nothing (x3)" \
        "$(go_hits b2-u-warm-1) $(go_hits b2-u-warm-2) $(go_hits b2-u-warm-3)" \
        "rc=0 compiles=0 downloads=0 rc=0 compiles=0 downloads=0 rc=0 compiles=0 downloads=0"
    check "the engine made it untrusted, gomod and gobuild copy-on-write" \
        "trust=$(insp b2-u-warm-1 "mc.get('trust')") $(access_of b2-u-warm-1 "gomod gobuild")" "trust=untrusted gomod=copy-on-write gobuild=copy-on-write" \
        "containers/b2-u-warm-1.inspect.json"
    # shellcheck disable=SC2086
    MT=$(median $T_TRUSTED)
    # shellcheck disable=SC2086
    MU=$(median $T_UNTRUSTED)
    metric "b2.trusted_warm_go_ms" "$T_TRUSTED"
    metric "b2.untrusted_warm_go_ms" "$T_UNTRUSTED"
    checkp "untrusted warm go build within 1.5x of the trusted warm build (median ms of 3)" "untrusted=$MU trusted=$MT" "untrusted <= 1.5 x trusted, both measured (> 0 ms)" \
        "$(ok python3 -c "import sys; mu, mt = float('$MU'), float('$MT'); sys.exit(0 if mt > 0 and mu > 0 and mu <= 1.5 * mt else 1)")"
    # The same from outside: the host's clock around the whole container, so
    # the cost of building the copy-on-write view at start counts too.
    # shellcheck disable=SC2086
    WT=$(median $W_TRUSTED)
    # shellcheck disable=SC2086
    WU=$(median $W_UNTRUSTED)
    metric "b2.trusted_warm_container_wall_ms" "$W_TRUSTED"
    metric "b2.untrusted_warm_container_wall_ms" "$W_UNTRUSTED"
    checkp "untrusted warm container, start to exit on the host's clock, within 1.5x of the trusted one (median ms of 3)" "untrusted=$WU trusted=$WT" \
        "untrusted <= 1.5 x trusted, both measured (> 0 ms)" \
        "$(ok python3 -c "import sys; mu, mt = float('$WU'), float('$WT'); sys.exit(0 if mt > 0 and mu > 0 and mu <= 1.5 * mt else 1)")"
    workload b2-u-edit untrusted "$SB" "$IMG_GO" none go-build base -- -e "GEDIT=u-$S" -e "$GO_REQ" -e "$GO_LOCAL" -e "$GO_OFF"
    checkp "untrusted one-file change compiles in its own view, downloads nothing" "$(go_hits b2-u-edit)" "rc=0 compiles>0 downloads=0" \
        "$([ "$(r b2-u-edit rc)/$(r b2-u-edit downloads)" = 0/0 ] && gt0 "$(r b2-u-edit compiles)" && echo 1 || echo 0)"
    workload b2-u-newmod untrusted "$SB" "$IMG_GO" on go-build newmod -- -e "$GO_REQ" -e "$GO_LOCAL"
    checkp "untrusted build that adds a module (github.com/google/uuid) downloads and compiles it" "$(go_hits b2-u-newmod)" "rc=0 compiles>0 downloads>0" \
        "$([ "$(r b2-u-newmod rc)" = 0 ] && gt0 "$(r b2-u-newmod compiles)" && gt0 "$(r b2-u-newmod downloads)" && echo 1 || echo 0)"
    workload b2-u-npm-off untrusted "$SB" "$IMG_NODE" none npm-ci a offline
    check "untrusted npm ci --offline is warm (--network none)" "rc=$(r b2-u-npm-off rc) cache_miss=$(r b2-u-npm-off cache_miss)" "rc=0 cache_miss=0"
    workload b2-u-npm-new untrusted "$SB" "$IMG_NODE" on npm-ci b
    checkp "untrusted npm ci that adds picocolors fetches it into its own view" "rc=$(r b2-u-npm-new rc) cache_miss=$(r b2-u-npm-new cache_miss)" "rc=0 cache_miss>0" \
        "$([ "$(r b2-u-npm-new rc)" = 0 ] && gt0 "$(r b2-u-npm-new cache_miss)" && echo 1 || echo 0)"
    workload b2-u-pnpm-off untrusted "$SB" "$IMG_NODE" none pnpm-install big offline
    checkp "untrusted pnpm install --offline is warm: downloads nothing, reuses the store" \
        "rc=$(r b2-u-pnpm-off rc) downloaded=$(r b2-u-pnpm-off downloaded) reused=$(r b2-u-pnpm-off reused)" "rc=0 downloaded=0 reused>0" \
        "$([ "$(r b2-u-pnpm-off rc)" = 0 ] && [ "$(r b2-u-pnpm-off downloaded)" = 0 ] && gt0 "$(r b2-u-pnpm-off reused)" && echo 1 || echo 0)"
    workload b2-u-pnpm-new untrusted "$SB" "$IMG_NODE" on pnpm-install b
    checkp "untrusted pnpm install of new packages downloads them into its own view" \
        "rc=$(r b2-u-pnpm-new rc) downloaded=$(r b2-u-pnpm-new downloaded)" "rc=0 downloaded>0" \
        "$([ "$(r b2-u-pnpm-new rc)" = 0 ] && gt0 "$(r b2-u-pnpm-new downloaded)" && echo 1 || echo 0)"
    check "the engine gave the untrusted node containers npm and pnpm copy-on-write" \
        "$(insp b2-u-npm-new "mc.get('trust')") $(access_of b2-u-npm-new "npm pnpm")" "untrusted npm=copy-on-write pnpm=copy-on-write"

    # Deliberate writes: an untrusted attacker, a read-only attacker.
    # attack NAME TIER [alias]: every store attached (forced on the alpine
    # image), or with "alias" only a read-only alias volume of gomod at /alias
    # (an alias volume of a store is the container's own mount of it: the
    # engine then attaches no gomod, reason user-mount).
    attack() {
        local name=$1 tier=$2 mode=${3:-stores}
        local args
        args=(--label "io.micropod.cache.scope=$SB" -e GHOLD=1)
        if [ "$mode" = alias ]; then
            args+=(--label io.micropod.cache=off -v "micropod-ci-scoped-$SB-gomod:/alias:ro")
        else
            args+=(--label "io.micropod.cache=+gomod,+gobuild,+npm,+pnpm")
        fi
        case $tier in
        untrusted) args+=(--label io.micropod.cache.trust=untrusted) ;;
        readonly) args+=(--label io.micropod.cache.readonly=1) ;;
        esac
        run_d "$name" "$IMG_BASE" "${args[@]}" -- sh /g/probe.sh "$name" attack
        local waited=0
        while ! sentinel "$name" && [ "$waited" -lt 600 ]; do sleep 0.2 && waited=$((waited + 1)); done
        # docker cp into the running attacker (PUT archive): its store path or the ro alias.
        printf 'cp-planted\n' >"$TMPD/cp-$name"
        local into=/micropod/cache/gomod
        [ "$mode" = alias ] && into=/alias
        "$DOCKER" cp "$TMPD/cp-$name" "gpb-$S-$name:$into/gate-cp-$S" >"$R/containers/$name.cp.log" 2>&1
        echo "docker_cp_rc=$? seen_in_container=$("$DOCKER" exec "gpb-$S-$name" cat "$into/gate-cp-$S" 2>/dev/null)" >>"$R/containers/$name.cp.log"
        touch "$OUTD/$name.release"
        "$DOCKER" wait "gpb-$S-$name" >/dev/null 2>&1
        finish_c "$name"
    }
    attack b2-u-attack untrusted
    sentinel b2-u-attack
    check "the untrusted attacker ran (result sentinel)" "$?" 0 "containers/b2-u-attack.res"
    check "the engine made the attacker untrusted with every store copy-on-write" \
        "$(insp b2-u-attack "mc.get('trust')") $(access_of b2-u-attack "gomod gobuild npm pnpm")" \
        "untrusted gomod=copy-on-write gobuild=copy-on-write npm=copy-on-write pnpm=copy-on-write" "containers/b2-u-attack.inspect.json"
    checkp "the untrusted attacker's writes into gomod, gobuild, npm and pnpm all took effect in its own view" \
        "$(r b2-u-attack attack.landed) of $(r b2-u-attack attack.tried) landed; not: $(r b2-u-attack attack.not_landed)" "all four stores present, all landed, >= 52 tried" \
        "$(landed_all b2-u-attack)" "containers/b2-u-attack.res"
    metric "b2.u_attack.docker_cp" "$(tail -1 "$R/containers/b2-u-attack.cp.log")"
    attack b2-u-alias untrusted alias
    check "an untrusted container may mount its scope's gomod alias volume read-only: the real store, read-only" \
        "$(r b2-u-alias attack.alias.fs) $(insp b2-u-alias "[m.get('RW') for m in c.get('Mounts') or [] if m.get('Destination') == '/alias']")" \
        "ext4 /scopes/$SB/gomod $CACHE_DEV [False]" "containers/b2-u-alias.res"
    checkp "…and every write through it is refused (create, overwrite, remount, docker cp)" \
        "$(r b2-u-alias attack.alias.create) | $(r b2-u-alias attack.alias.overwrite) | $(r b2-u-alias attack.alias.remount) | $(tail -1 "$R/containers/b2-u-alias.cp.log")" \
        "all failed, docker cp refused" \
        "$(if matches "$(r b2-u-alias attack.alias.create)$(r b2-u-alias attack.alias.overwrite)$(r b2-u-alias attack.alias.remount)" "*landed*" || matches "$(r b2-u-alias attack.alias.create)" missing || matches "$(tail -1 "$R/containers/b2-u-alias.cp.log")" "docker_cp_rc=0*"; then echo 0; else echo 1; fi)" \
        "containers/b2-u-alias.res"
    # A read-write alias volume and the Docker socket are refused to an untrusted container.
    create_err() { # create_err [docker create args…]: the refusal's last line, or "created"
        local out cid
        out=$("$DOCKER" create --label "gate-run=$S" "$@" 2>&1)
        cid=$(echo "$out" | grep -E '^[0-9a-f]{64}$')
        [ -n "$cid" ] && "$DOCKER" rm -f "$cid" >/dev/null 2>&1 && echo created && return
        echo "$out" | tail -1
    }
    err=$(create_err --label io.micropod.cache.trust=untrusted --label "io.micropod.cache.scope=$SB" -v "micropod-ci-scoped-$SB-gomod:/w" "$IMG_BASE" true)
    checkp "an untrusted container is refused a read-write alias volume of the store" "$err" "refused (400 …read-write)" \
        "$([ "$err" != created ] && echo "$err" | grep -q 'read-write' && echo 1 || echo 0)"
    # The control first: the same create without the label succeeds, so the
    # refusal below is of the untrusted container, not of the request.
    ctl=$(create_err -v /var/run/docker.sock:/var/run/docker.sock "$IMG_BASE" true)
    err=$(create_err --label io.micropod.cache.trust=untrusted -v /var/run/docker.sock:/var/run/docker.sock "$IMG_BASE" true)
    checkp "an untrusted container is refused the Docker socket a trusted one is given (no way to create a trusted writer)" "trusted: $ctl | untrusted: $err" \
        "trusted: created | untrusted: refused (…only a trusted container…)" \
        "$([ "$ctl" = created ] && [ "$err" != created ] && echo "$err" | grep -q 'trusted' && echo 1 || echo 0)"

    # Real work and deliberate writes as read-only.
    workload b2-ro-edit readonly "$SB" "$IMG_GO" none go-build base -- -e "GEDIT=ro-$S" -e "$GO_REQ" -e "$GO_LOCAL" -e "$GO_OFF"
    checkp "read-only one-file change compiles in its own view, downloads nothing" "$(go_hits b2-ro-edit)" "rc=0 compiles>0 downloads=0" \
        "$([ "$(r b2-ro-edit rc)/$(r b2-ro-edit downloads)" = 0/0 ] && gt0 "$(r b2-ro-edit compiles)" && echo 1 || echo 0)"
    check "the engine made it read-only, gomod and gobuild copy-on-write" \
        "trust=$(insp b2-ro-edit "mc.get('trust')") $(access_of b2-ro-edit "gomod gobuild")" "trust=readonly gomod=copy-on-write gobuild=copy-on-write"
    workload b2-ro-npm-new readonly "$SB" "$IMG_NODE" on npm-ci b
    checkp "read-only npm ci that adds a package fetches it into its own view" "rc=$(r b2-ro-npm-new rc) cache_miss=$(r b2-ro-npm-new cache_miss)" "rc=0 cache_miss>0" \
        "$([ "$(r b2-ro-npm-new rc)" = 0 ] && gt0 "$(r b2-ro-npm-new cache_miss)" && echo 1 || echo 0)"
    workload b2-ro-pnpm-new readonly "$SB" "$IMG_NODE" on pnpm-install b
    checkp "read-only pnpm install of new packages downloads them into its own view" \
        "rc=$(r b2-ro-pnpm-new rc) downloaded=$(r b2-ro-pnpm-new downloaded)" "rc=0 downloaded>0" \
        "$([ "$(r b2-ro-pnpm-new rc)" = 0 ] && gt0 "$(r b2-ro-pnpm-new downloaded)" && echo 1 || echo 0)"
    attack b2-ro-attack readonly
    checkp "the read-only attacker ran with every store copy-on-write" \
        "$(sentinel b2-ro-attack && echo ran || echo missing) $(insp b2-ro-attack "mc.get('trust')") $(access_of b2-ro-attack "gomod gobuild npm pnpm")" \
        "ran readonly gomod=copy-on-write gobuild=copy-on-write npm=copy-on-write pnpm=copy-on-write" \
        "$([ "$(sentinel b2-ro-attack && echo ran) $(insp b2-ro-attack "mc.get('trust')") $(access_of b2-ro-attack "gomod gobuild npm pnpm")" = "ran readonly gomod=copy-on-write gobuild=copy-on-write npm=copy-on-write pnpm=copy-on-write" ] && echo 1 || echo 0)"
    checkp "the read-only attacker's writes into the four stores all took effect in its own view" \
        "$(r b2-ro-attack attack.landed) of $(r b2-ro-attack attack.tried) landed; not: $(r b2-ro-attack attack.not_landed)" "all four stores present, all landed, >= 52 tried" \
        "$(landed_all b2-ro-attack)" "containers/b2-ro-attack.res"
    if sabotage b2-trusted-attack; then
        log "SABOTAGE b2-trusted-attack: the attack once more, without the untrusted label"
        attack sabotage-attack trusted
        log "  sabotage attacker: trust=$(insp sabotage-attack "mc.get('trust')") landed $(r sabotage-attack attack.landed) of $(r sabotage-attack attack.tried)"
    fi
    if sabotage b2-touch; then
        log "SABOTAGE b2-touch: a trusted container sets one gomod file's mtime (no byte written)"
        workload sabotage-touch trusted "$SB" "$IMG_GO" none touch
        log "  touched: $(r sabotage-touch touched)"
    fi
    left=$("$DOCKER" ps -aq --filter "label=gate-run=$S" 2>/dev/null | wc -l | tr -d ' ')
    check "no gate container is left before the after-census" "$left" 0
    wait_clean 60 "$SB"
    census d1 "$SB"
    check "census d1 ran" "$?" 0 "census/d1.json"
    got=$(cdiff d0 d1 "$SB" content)
    checkp "B2: zero bytes reached the trusted stores of $SB (every file's sha256 and size, every entry's type, mode, owner)" "$got" "equal" \
        "$(ok is_equal "$got")" "census/diff-d0-d1-$SB-content.json"
    got=$(cdiff d0 d1 "$SB" identity)
    checkp "B2: no entry of the trusted stores was re-created or had its mtime changed (inode, mtime_ns)" "$got" "equal" \
        "$(ok is_equal "$got")" "census/diff-d0-d1-$SB-identity.json"
    got=$(cdiff d0 d1 "$SB" meta)
    checkp "B2: no inode of the trusted stores changed at all (ctime_ns, nlink, xattrs)" "$got" "equal" \
        "$(ok is_equal "$got")" "census/diff-d0-d1-$SB-meta.json"
    bad=""
    for store in $SB.gomod $SB.gobuild $SB.npm $SB.pnpm; do
        [ "$(archive_core d0 "$store")" = "$(archive_core d1 "$store")" ] && [ "$(archive_core d1 "$store")" != none ] || bad="$bad $store"
    done
    checkp "B2: the engine's own read of gomod, gobuild, npm and pnpm hashes as before" "${bad:-all equal}" "all equal" "$([ -z "$bad" ] && echo 1 || echo 0)"
    got=$(python3 -I "$GATE/compare.py" inventory "$R/engine/inventory-d0.json" "$R/engine/inventory-d1.json" --scope "$SB" | tail -1)
    checkp "B2: the engine's unit inventory of $SB is unchanged (no new unit, same files and bytes)" "$got" "equal" "$(ok is_equal "$got")"
fi

# --- B2X ------------------------------------------------------------------------------------
if want B2X; then
    section B2X "kill -9 of the VMM under a trusted writer: the dirty unit goes, the rest stays"
    workload x-go-build trusted "$SX" "$IMG_GO" on go-build base -- -e "$GO_REQ" -e "$GO_LOCAL"
    checkp "x-go-build: a cold trusted build fills gomod and gobuild of $SX" "$(go_hits x-go-build)" "rc=0 compiles>0 downloads>0" \
        "$([ "$(r x-go-build rc)" = 0 ] && gt0 "$(r x-go-build compiles)" && gt0 "$(r x-go-build downloads)" && echo 1 || echo 0)"
    workload x-npm-ci trusted "$SX" "$IMG_NODE" on npm-ci a
    check "x-npm-ci: a cold trusted npm ci fills npm of $SX" "$(r x-npm-ci rc)" 0
    wait_clean 120 "$SX" "$SB"
    check "every unit of $SX and $SB is clean before the crash" "$?" 0
    census e0 "$SB" "$SX"
    check "census e0 ran" "$?" 0 "census/e0.json"
    for k in gomod gobuild npm; do
        st=$(store_real e0 "$SX" $k)
        checkp "census e0 reads the real $SX $k store" "$st" "real files>0" "$(ok matches "$st" "real files=[1-9]*")"
    done
    run_d x-writer "$IMG_BASE" --label "io.micropod.cache.scope=$SX" --label "io.micropod.cache=gomod,+gomod" -- sh /g/probe.sh x-writer writer
    waited=0
    progress() { local p; p=$(cat "$OUTD/${1:-x-writer}.progress" 2>/dev/null); if num "$p"; then echo "$p"; else echo 0; fi; }
    while [ "$(progress)" -lt 25 ] && [ "$waited" -lt 600 ]; do sleep 0.1 && waited=$((waited + 1)); done
    # ext4 commits its journal every 5 s: by the kill some of the writer's
    # entries are on the cache disk and its newest writes are not (the case the
    # fence exists for). The unit's mark went to disk before the writer could
    # write (attach syncs it).
    WRITE_SECS=${GATE_CRASH_WRITE_SECS:-15}
    log "the writer runs ${WRITE_SECS}s before the kill (progress $(progress))"
    sleep "$WRITE_SECS"
    metric "b2x.writer_seconds_before_kill" "$WRITE_SECS"
    inventory x-prekill nostats
    check "while it writes, the engine has $SX/gomod marked dirty and held, and nothing else of $SX or $SB" \
        "$(inv x-prekill "sorted((u['scope'] + '/' + u['unit'], u['dirty'], u['inUse']) for u in units if u['scope'] in ('$SX', '$SB') and (u['dirty'] or u['inUse']))")" \
        "[('$SX/gomod', True, True)]" "engine/inventory-x-prekill.json"
    VMM=$(my_vmm)
    P_AT_KILL=$(progress)
    sleep 0.3
    P_AT_KILL2=$(progress)
    checkp "the writer is mid-write at the kill, ${WRITE_SECS}s after it started (its progress still advances)" "progress $P_AT_KILL -> $P_AT_KILL2" "advancing, >= 25" \
        "$([ "${P_AT_KILL2:-0}" -gt "${P_AT_KILL:-0}" ] 2>/dev/null && [ "$P_AT_KILL" -ge 25 ] && echo 1 || echo 0)"
    RESTARTS=$(state "s.get('restartCount')")
    if [ -n "$VMM" ]; then
        kill -9 "$VMM"
        log "killed this root's VMM $VMM (writer progress $P_AT_KILL2)"
    fi
    checkp "the pid killed is this root's micropod-vmm" "${VMM:-none}" "a pid" "$([ -n "$VMM" ] && echo 1 || echo 0)"
    deadline=$((SECONDS + 240))
    until [ "$(state "s['phase'] == 'running' and s.get('vmmPID') != ${VMM:-0}")" = True ] && ping_engine; do
        [ "$SECONDS" -lt "$deadline" ] || break
        sleep 0.5
    done
    check "the supervisor relaunched the VMM and the engine answers" \
        "$(state "s['phase']") restarts=$(state "s.get('restartCount')") ping=$(ping_engine && echo OK || echo none)" "running restarts=$((${RESTARTS:-0} + 1)) ping=OK"
    "$DOCKER" rm -f "gpb-$S-x-writer" >/dev/null 2>&1
    cp "$OUTD/x-writer.progress" "$OUTD/x-writer.started" "$R/containers/" 2>/dev/null
    inventory x-postkill nostats
    check "the engine discarded exactly the dirty unit at start (discardedAtStart)" \
        "$(inv x-postkill "sorted(d.get('discardedAtStart') or [])")" "['$SX/gomod']" "engine/inventory-x-postkill.json"
    census e1 "$SB" "$SX"
    check "census e1 ran" "$?" 0 "census/e1.json"
    check "the discarded unit's store is gone whole: no pre-crash entry and none of the writer's files remain" \
        "$(python3 -c "
import json
d = json.load(open('$R/census/e1.json'))['stores']['$SX.gomod']
print('real' if d['real'] else 'gone', sum(1 for e in d['entries'] if e['type'] == 'f'), sum(1 for e in d['entries'] if 'gate.example' in e['path']))")" "gone 0 0" "census/e1.json"
    got=$(cdiff e0 e1 "$SX" strict "gobuild,npm")
    checkp "the rest of $SX is preserved: gobuild and npm identical to the byte, inode, mtime and ctime" "$got" "equal" "$(ok is_equal "$got")" \
        "census/diff-e0-e1-$SX-strict.json"
    got=$(cdiff e0 e1 "$SB" strict)
    checkp "every store of $SB is preserved across the crash: identical to the byte, inode, mtime and ctime" "$got" "equal" "$(ok is_equal "$got")" \
        "census/diff-e0-e1-$SB-strict.json"
    workload x-go-after trusted "$SX" "$IMG_GO" on go-build base -- -e "$GO_REQ" -e "$GO_LOCAL"
    checkp "the next build re-downloads the discarded modules and compiles nothing (gobuild was kept)" "$(go_hits x-go-after)" "rc=0 compiles=0 downloads>0" \
        "$([ "$(r x-go-after rc)/$(r x-go-after compiles)" = 0/0 ] && gt0 "$(r x-go-after downloads)" && echo 1 || echo 0)"
    workload x-go-verify trusted "$SX" "$IMG_GO" on go-verify base -- -e "$GO_REQ" -e "$GO_LOCAL"
    check "go mod verify of the rebuilt gomod store" "rc=$(r x-go-verify rc) verified=$(r x-go-verify verified)" "rc=0 verified=1"

    # The same kill inside the first journal commit interval (well under 5 s
    # after the writer attached): the mark went to disk before the writer could
    # write, so the unit is discarded whole. (Before attach synced the mark this
    # kill found neither the mark nor the writer's entries on disk, and kept the
    # unit as it was before the writer: safe for this writer, which only adds
    # entries, but not for one whose bytes reach the disk without a journal
    # commit; the swept kills below have one.)
    wait_clean 120 "$SX" "$SB"
    census e2 "$SB" "$SX"
    run_d x-writer2 "$IMG_BASE" --label "io.micropod.cache.scope=$SX" --label "io.micropod.cache=gomod,+gomod" -- sh /g/probe.sh x-writer2 writer
    waited=0
    while [ "$(progress x-writer2)" -lt 5 ] && [ "$waited" -lt 600 ]; do sleep 0.05 && waited=$((waited + 1)); done
    VMM=$(my_vmm)
    P2=$(progress x-writer2)
    [ -n "$VMM" ] && kill -9 "$VMM" && log "early kill: this root's VMM $VMM (writer2 progress $P2)"
    checkp "early kill: the writer was mid-write in its first second (this root's VMM killed)" "vmm=${VMM:-none} progress=$P2" "a pid, progress >= 5" \
        "$([ -n "$VMM" ] && [ "$P2" -ge 5 ] && echo 1 || echo 0)"
    deadline=$((SECONDS + 240))
    until [ "$(state "s['phase'] == 'running' and s.get('vmmPID') != ${VMM:-0}")" = True ] && ping_engine; do
        [ "$SECONDS" -lt "$deadline" ] || break
        sleep 0.5
    done
    "$DOCKER" rm -f "gpb-$S-x-writer2" >/dev/null 2>&1
    inventory x-postkill2 nostats
    census e3 "$SB" "$SX"
    EARLY=$(python3 - "$R/census/e2.json" "$R/census/e3.json" "$R/engine/inventory-x-postkill2.json" "$SX" <<'PY'
import json, sys
e2 = json.load(open(sys.argv[1]))["stores"][sys.argv[4] + ".gomod"]
e3 = json.load(open(sys.argv[2]))["stores"][sys.argv[4] + ".gomod"]
disc = json.load(open(sys.argv[3])).get("discardedAtStart") or []
writer = sum(1 for e in e3["entries"] if "gate.example" in e["path"])
key = lambda r: sorted((e["path"], e["type"], e["size"], e.get("sha256")) for e in r["entries"])
if sys.argv[4] + "/gomod" in disc:
    print("discarded", "gone" if not e3["real"] else f"real-{len(e3['entries'])}", f"writer-entries={writer}")
else:
    print("kept", "pre-crash-content" if key(e2) == key(e3) else "CHANGED", f"writer-entries={writer}")
PY
)
    metric "b2x.early_kill_outcome" "$EARLY"
    checkp "early kill: the unit is discarded whole (its mark was on disk before the writer wrote)" "$EARLY" \
        "'discarded gone writer-entries=0'" \
        "$([ "$EARLY" = "discarded gone writer-entries=0" ] && echo 1 || echo 0)" "census/e3.json"
    got=$(cdiff e2 e3 "$SX" strict "gobuild,npm")
    checkp "early kill: gobuild and npm of $SX identical to the byte, inode, mtime and ctime" "$got" "equal" "$(ok is_equal "$got")"
    got=$(cdiff e2 e3 "$SB" strict)
    checkp "early kill: every store of $SB identical to the byte, inode, mtime and ctime" "$got" "equal" "$(ok is_equal "$got")"

    # The swept kills. attach puts the unit's mark on disk (synced, renamed,
    # its directory synced) before the writer can write a byte, so a kill at
    # any moment after the writer started must discard the unit whole. Two
    # writers: new entries only, never synced; and one that first overwrites
    # a committed seed entry in place and fdatasyncs it (as SQLite does), whose
    # bytes reach the disk without any journal commit. Before each writer the
    # cache disk has been idle for longer than a journal commit interval, so
    # a mark the engine left to the next commit would not be on disk at any
    # offset below 5 s: the new-entry writer's unit then survives undiscarded,
    # the overwriter's survives changed (measured on 54732c4f: 8 of 21 kills
    # 50 ms..1.7 s after the overwriter started kept a changed gomod). Each
    # kill is followed by a machine stop/start: five kills within a minute of
    # their launches would end supervision.
    sweep_census() { # sweep_census TAG: census of $SX's gomod store alone
        local cname="gpb-$S-census-$1"
        rm -f "$OUTD/census-$1.json"
        "$DOCKER" run --rm --name "$cname" --label "gate-run=$S" --label io.micropod.cache=off --network none \
            -v "${GW}/g:/g:ro" -v "${GW}/out:/o" -v "micropod-ci-scoped-$SX-gomod:/c/$SX.gomod:ro" "$IMG_PY" \
            python3 -I /g/census.py /c "/o/census-$1.json" >"$R/census/$1.log" 2>&1
        cp "$OUTD/census-$1.json" "$R/census/$1.json" 2>/dev/null
    }
    sweep_outcome() { # sweep_outcome PRE POST INVENTORY: discarded|kept, what is left
        python3 - "$R/census/$1.json" "$R/census/$2.json" "$R/engine/inventory-$3.json" "$SX" <<'PY' 2>/dev/null || echo "no-census"
import json, sys
pre = json.load(open(sys.argv[1]))["stores"][sys.argv[4] + ".gomod"]
post = json.load(open(sys.argv[2]))["stores"][sys.argv[4] + ".gomod"]
disc = json.load(open(sys.argv[3])).get("discardedAtStart") or []
key = lambda e: (e["type"], e["size"], e.get("sha256"))
before = {e["path"]: key(e) for e in pre["entries"]}
after = {e["path"]: key(e) for e in post["entries"]}
seed = sum(1 for p in after if "seed.example" in p)
writer = sum(1 for p in after if "gate.example" in p)
if sys.argv[4] + "/gomod" in disc:
    print("discarded", "gone" if not post["real"] else f"real-{len(after)}", f"seed-entries={seed}", f"writer-entries={writer}")
else:
    changed = sum(1 for p, k in before.items() if after.get(p) != k) + sum(1 for p in after if p not in before)
    print("kept", "unchanged" if changed == 0 else f"CHANGED-{changed}", f"seed-entries={seed}", f"writer-entries={writer}")
PY
    }
    SWEEP_MS=${GATE_CRASH_SWEEP_MS:-"50 250 1000 2500 4000 6000"}
    trial=0
    for variant in new overwrite; do
        for off in $SWEEP_MS; do
            trial=$((trial + 1))
            tag="sw$trial-$variant-$off"
            wait_clean 120 "$SX" "$SB" || log "sweep $tag: $SX not clean before the trial"
            "$DOCKER" rm -f "gpb-$S-x-seed" >/dev/null 2>&1
            run_c x-seed "$IMG_BASE" --label "io.micropod.cache.scope=$SX" --label "io.micropod.cache=gomod,+gomod" -- sh /g/probe.sh x-seed seed
            seeded=$(r x-seed rc)
            wait_clean 120 "$SX" "$SB" || log "sweep $tag: $SX not clean after seeding"
            sweep_census "$tag-pre"
            # One full commit interval with nothing written: the journal is idle.
            sleep 6
            rm -f "$OUTD/x-$tag.started"
            run_d "x-$tag" "$IMG_BASE" --label "io.micropod.cache.scope=$SX" --label "io.micropod.cache=gomod,+gomod" -- \
                sh /g/probe.sh "x-$tag" writer "$([ "$variant" = overwrite ] && echo overwrite)"
            waited=0
            while [ ! -f "$OUTD/x-$tag.started" ] && [ "$waited" -lt 600 ]; do sleep 0.01 && waited=$((waited + 1)); done
            t0=$(host_ms)
            perl -MTime::HiRes=sleep -e "sleep($off / 1000)"
            VMM=$(my_vmm)
            [ -f "$OUTD/x-$tag.started" ] && [ -n "$VMM" ] && kill -9 "$VMM"
            actual=$(($(host_ms) - t0))
            deadline=$((SECONDS + 240))
            until [ "$(state "s['phase'] == 'running' and s.get('vmmPID') != ${VMM:-0}")" = True ] && ping_engine; do
                [ "$SECONDS" -lt "$deadline" ] || break
                sleep 0.2
            done
            "$DOCKER" rm -f "gpb-$S-x-$tag" >/dev/null 2>&1
            cp "$OUTD/x-$tag.progress" "$R/containers/x-$tag.progress" 2>/dev/null
            inventory "x-$tag" nostats
            sweep_census "$tag-post"
            outcome=$(sweep_outcome "$tag-pre" "$tag-post" "x-$tag")
            metric "b2x.sweep.$tag" "kill ${actual} ms after the writer started; $outcome"
            checkp "swept kill ($variant writer, ${off} ms after it started; killed at ${actual} ms): the unit is discarded whole" \
                "seed rc=$seeded vmm=${VMM:-none} $outcome" "seed rc=0 vmm=<pid> discarded gone seed-entries=0 writer-entries=0" \
                "$([ "$seeded" = 0 ] && [ -n "$VMM" ] && [ "$outcome" = "discarded gone seed-entries=0 writer-entries=0" ] && echo 1 || echo 0)" \
                "census/$tag-pre.json census/$tag-post.json engine/inventory-x-$tag.json"
            "$M" machine stop >"$R/logs/machine-stop-$tag.log" 2>&1
            "$M" machine start --timeout 300 >"$R/logs/machine-start-$tag.log" 2>&1
            wait_engine 120 || log "sweep $tag: the machine did not come back after its stop/start"
        done
    done
    census e4 "$SB" "$SX"
    check "census e4 ran" "$?" 0 "census/e4.json"
    got=$(cdiff e2 e4 "$SX" strict "gobuild,npm")
    checkp "after the swept kills gobuild and npm of $SX are identical to the byte, inode, mtime and ctime" "$got" "equal" "$(ok is_equal "$got")" \
        "census/diff-e2-e4-$SX-strict.json"
    got=$(cdiff e2 e4 "$SB" strict)
    checkp "after the swept kills every store of $SB is identical to the byte, inode, mtime and ctime" "$got" "equal" "$(ok is_equal "$got")" \
        "census/diff-e2-e4-$SB-strict.json"
fi

# --- result: written by the exit trap (cleanup → write_result) ------------------------
FINISHED=1
