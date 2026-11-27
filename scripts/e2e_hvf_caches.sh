#!/bin/bash
# scripts/e2e_hvf_caches.sh — qualification for default-on dependency caches
# and the stock `docker build` path on the hvf machine (cache plan P1-Q-CORE).
#
# Every assertion is a count or an offline success measured in a fresh
# container: compile and download counts, offline installs, entries stored by
# each uid, owner-only modes, both uid orders, concurrency, a restart, a VMM
# kill -9 and BuildKit cache mounts. Test containers never get a -v or a cache
# variable from this script: the engine attaches the caches. Each container
# runs scripts/fixtures/caches/qprobe.sh, which writes /qr/<name>.res in the
# machine workspace with a final `QUAL-SENTINEL <name>` line; the harness reads
# those files from the host and fails any container whose sentinel is missing.
# Container stdout is never used for an assertion.
#
# Sections (QUAL_SECTIONS; default all, run in this order):
#   T0 preflight: bundle manifest vs engine /version, BuildKit, kernel recorded
#   T1 per tool: cold run, then a warm run in a new container at another
#      checkout path (--network none wherever the tool can run offline)
#   NC negative controls: the detectors report misses. A store without the
#      default ACL shows the silent Go miss; io.micropod.cache=off misses;
#      a shared pip store shows the pip 23/24 miss; pnpm 12 without a 0666
#      index.db re-downloads
#   T2 both uid orders (0 then 1000, 1000 then 0) per tool, a root entrypoint
#      that drops to uid 1000, and `--user node`
#   T3 precedence: image-prewarmed, an image's own cache env, user mounts and
#      env, opt-outs, scope 400, GOFLAGS merge, postgres:alpine gets only
#      /micropod/cache; an untrusted container builds warm through a
#      copy-on-write view and writes nothing into the trusted store
#   T4 concurrency on one scope (yarn v1: one writer, the rest copy-on-write)
#   T5 restart: machine stop/start, then kill -9 of the VMM mid-download
#   T6 builds with the stock docker CLI (isolated DOCKER_CONFIG, DOCKER_HOST only)
#   T7 create-to-start latency, auto vs io.micropod.cache=off, interleaved
#   T8 trust and sharing: under defaultTrust=untrusted an unlabeled container
#      writes nothing into a store and no container gets a socket that can
#      create another; allowedScopes holds for labels, untrusted readers and
#      alias volumes; with sharedL0 on, maven and gradle stay per scope
#   T9 BuildKit across `machine install --replace-disk` (throwaway installs
#      only): the next cache-mount build succeeds, BuildKit holds no record
#      of a lost snapshot, and the cache disk's stores survive
#
# Each check names what it needs: auto (a cache hit that needs the engine to
# attach), engine (an attach decision visible in inspect or create), build (the
# stock /grpc build path), buildhit (a BuildKit cache-mount hit), safety
# (attaching breaks nothing: cold runs succeed, no EACCES; these may also pass
# with nothing attached), bundle, cli (host CLI commands), perf, control
# (negative controls) and harness. A check about a store's contents counts only
# when the scanned path is that scope's store; otherwise it fails as
# inconclusive, so no auto check can pass on an engine that attaches nothing.
#
# QUAL_MANUAL_WIRING=1 validates the harness on an engine without auto-attach:
# test containers get exactly the mounts and env the plan specifies (stores in
# named volumes laid out by fixtures/caches/qprep.py with the 28-byte default
# ACL; builds through a remote buildx builder this script creates in its
# throwaway DOCKER_CONFIG). Then the auto, buildhit, control, perf, harness
# and safety checks must pass, and the engine, build, bundle and cli checks are
# skipped.
# It is a self-test of the assertions, not a qualification result.
#
# Usage: scripts/e2e_hvf_caches.sh
#   QUAL_ROOT        machine root (default /tmp/mpq-caches; under /tmp, short
#                    enough for run/docker.sock)
#   QUAL_INSTALL     1 (default): install a throwaway machine into QUAL_ROOT and
#                    QUAL_ROOT-ws (each absent, empty or marked by this script),
#                    remove both at the end; 0: use the machine installed there
#                    and leave it as found (its workspace comes from machine.json)
#   QUAL_TOOLS       guest tool bundle (required with QUAL_INSTALL=1)
#   QUAL_VMM QUAL_KERNEL QUAL_INITRD QUAL_DISK_FROM QUAL_DISK_IMAGE
#   QUAL_CPUS (8) QUAL_MEMORY_MIB (12288)   as in scripts/e2e_hvf.sh
#   QUAL_CACHE_DISK_SIZE  size of the persistent cache disk (caches.ext4) the
#                    throwaway install creates (default 32g; "none" installs
#                    without one, the stores then live on the OS disk)
#   QUAL_MICROPOD    micropod CLI (default .build/debug/micropod)
#   QUAL_DOCKER      docker CLI (default /opt/homebrew/bin/docker, else PATH)
#   QUAL_SECTIONS    default "T0 T1 NC T2 T3 T4 T5 T6 T7 T8 T9"
#   QUAL_TOOLSET     default "go npm pnpm yarn1 yarn4 pip uv cargo corepack"
#   QUAL_PNPM_T1     pnpm majors in T1 (default "9 10 11 12"); QUAL_PNPM_T2 ("10 12")
#   QUAL_PIP_IMAGES  T2 pip images (default python:3.12, 3.10 and 3.11 alpine)
#   QUAL_T7_N        samples per configuration in T7 (default 60)
#   QUAL_MANUAL_WIRING=1  see above
#   QUAL_OUT         copy of checks.tsv, summary.txt and results/ (default
#                    .build/qual-caches/<run id>)
#   QUAL_TIMEOUT     seconds per container (default 900)
#   QUAL_KEEP=1      keep an installed root (stopped)
# Only processes and containers this script started are signalled.
set -o pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$REPO/scripts/fixtures/caches"
M="${QUAL_MICROPOD:-$REPO/.build/debug/micropod}"
ROOT_DIR="${QUAL_ROOT:-/tmp/mpq-caches}"
INSTALL="${QUAL_INSTALL:-1}"
MANUAL="${QUAL_MANUAL_WIRING:-0}"
SECTIONS=" ${QUAL_SECTIONS:-T0 T1 NC T2 T3 T4 T5 T6 T7 T8 T9} "
TOOLSET=" ${QUAL_TOOLSET:-go npm pnpm yarn1 yarn4 pip uv cargo corepack} "
PNPM_T1="${QUAL_PNPM_T1:-9 10 11 12}"
PNPM_T2="${QUAL_PNPM_T2:-10 12}"
PIP_IMAGES="${QUAL_PIP_IMAGES:-python:3.12-alpine python:3.10-alpine python:3.11-alpine}"
T7_N="${QUAL_T7_N:-60}"
TIMEOUT="${QUAL_TIMEOUT:-900}"
S="$(date +%s)"
OUT="${QUAL_OUT:-$REPO/.build/qual-caches/$S}"
IMG_GO="${QUAL_IMG_GO:-golang:alpine}"
IMG_NODE="${QUAL_IMG_NODE:-node:26.13.1-alpine}"
IMG_PY="${QUAL_IMG_PY:-python:3.12-alpine}"
IMG_UV="${QUAL_IMG_UV:-ghcr.io/astral-sh/uv:python3.13-alpine}"
IMG_RUST="${QUAL_IMG_RUST:-rust:1-alpine}"
IMG_PG="${QUAL_IMG_PG:-postgres:alpine}"
IMG_BASE="${QUAL_IMG_BASE:-alpine:3.20}"
T7_FIRST="${QUAL_T7_FIRST_IMAGES:-alpine:3.19 alpine:3.18}"
# Pinned harness tools, installed once per workspace into qual-tools/.
PNPM_VERSIONS="9.15.9 10.34.9 11.29.0 12.23.0"
YARN4_VERSION=4.19.0
# Node 26 images ship neither Corepack nor Yarn 1; this is the Yarn 1 that
# node:22-alpine carried.
YARN1_VERSION=1.22.22
QT_VERSIONS="$PNPM_VERSIONS yarn4 $YARN4_VERSION corepack 0.36.0 yarn1 $YARN1_VERSION"
# Contracts from the cache plan (P1-GE-CACHE and amendments).
CACHE_ROOT=/var/lib/micropod/caches
VOL_ROOT=/var/lib/micropod/engine/volumes
# Request env for guest containers only (never the Mac's Go): the engine
# appends -trimpath when it attaches gobuild.
GO_REQ_FLAGS="GOFLAGS=-mod=mod" # guard:guest
GO_NOPROXY="GOPROXY=off"
GO_LOCAL="GOTOOLCHAIN=local"
if [ -n "${QUAL_DOCKER:-}" ]; then DOCKER=$QUAL_DOCKER; elif [ -x /opt/homebrew/bin/docker ]; then DOCKER=/opt/homebrew/bin/docker; else DOCKER="$(command -v docker)"; fi

case "$ROOT_DIR" in
*/ | *//* | */./* | */. | */../* | */..) ROOT_OK=0 ;;
/tmp/?* | /private/tmp/?*) ROOT_OK=1 ;;
*) ROOT_OK=0 ;;
esac
[ "$ROOT_OK" = 1 ] || { echo "QUAL_ROOT must be a throwaway directory under /tmp (got '$ROOT_DIR')" >&2 && exit 2; }
MARKER=.micropod-e2e-hvf-caches
ours() { [ ! -e "$1" ] || [ -f "$1/$MARKER" ] || [ -z "$(ls -A "$1" 2>/dev/null)" ]; }
# QUAL_LIB_ONLY=1 (scripts/e2e_hvf_caches_lib.test.mjs): source the functions,
# touch nothing (no machine, docker config, container or trap).
LIB_ONLY="${QUAL_LIB_ONLY:-0}"
SOCK="$ROOT_DIR/run/docker.sock"
if [ "$LIB_ONLY" != 1 ]; then
    [ -x "$M" ] || { echo "missing micropod CLI $M (swift build, or set QUAL_MICROPOD)" >&2 && exit 2; }
    [ -x "$DOCKER" ] || { echo "missing docker CLI (set QUAL_DOCKER)" >&2 && exit 2; }
fi
mkdir -p "$OUT" || exit 2
: >"$OUT/checks.tsv"

if [ "$LIB_ONLY" != 1 ]; then
TMP="$(mktemp -d)"
export MICROPOD_HVF_ROOT="$ROOT_DIR"
export MICROPOD_RUNTIMES_CONFIG="$TMP/runtimes.json" # never the user's engine config
export MICROPOD_CLI="$M"
unset MICROPOD_DEFAULT_RUNTIME DOCKER_CONTEXT BUILDX_BUILDER DOCKER_BUILDKIT
export DOCKER_HOST="unix://$SOCK"
# A throwaway docker config: no user context, builder or credential is read or
# written. It names the user's CLI plugin directories so buildx and compose load.
export DOCKER_CONFIG="$TMP/docker"
mkdir -p "$DOCKER_CONFIG"
python3 - "${QUAL_REAL_DOCKER_CONFIG:-$HOME/.docker}" "$DOCKER_CONFIG/config.json" <<'PY'
import json, os, sys
real, out = sys.argv[1], sys.argv[2]
dirs = [os.path.join(real, "cli-plugins")]
try:
    with open(os.path.join(real, "config.json")) as f:
        dirs += json.load(f).get("cliPluginsExtraDirs", [])
except (OSError, ValueError):
    pass
with open(out, "w") as f:
    json.dump({"cliPluginsExtraDirs": dirs}, f)
PY
fi

PASS=0 FAIL=0 SKIP=0 NRUN=0 NMISS=0
SECTION=preflight CTX="" CTXFILE=""
SUBST=" auto safety buildhit control perf harness "
WAS_RUNNING=0 INSTALLED=0 BUILDER="" QW="" QR=""

cleanup() {
    if [ -S "$SOCK" ]; then
        "$DOCKER" ps -aq --filter "label=qual-run=$S" 2>/dev/null | while read -r id; do "$DOCKER" rm -f "$id" >/dev/null 2>&1; done
        if [ "$INSTALLED" != 1 ] && [ -n "$QW" ] && [ -f "$QW/volumes.list" ]; then
            sort -u "$QW/volumes.list" | while read -r v; do "$DOCKER" volume rm "$v" >/dev/null 2>&1; done
        fi
    fi
    [ -n "$BUILDER" ] && "$DOCKER" buildx rm "$BUILDER" >/dev/null 2>&1
    if [ -n "$QR" ] && [ -d "$QR" ]; then
        mkdir -p "$OUT/results" && cp -R "$QR/." "$OUT/results/" 2>/dev/null
    fi
    if [ "$INSTALLED" = 1 ]; then
        "$M" machine stop >/dev/null 2>&1
        if [ "${QUAL_KEEP:-0}" != 1 ]; then
            for dir in "$ROOT_DIR" "$ROOT_DIR-ws"; do [ -f "$dir/$MARKER" ] && rm -rf "$dir"; done
        fi
    else
        [ -n "$QW" ] && [ -f "$QW/.qual-run" ] && rm -rf "$QW"
        [ "$WAS_RUNNING" = 1 ] || "$M" machine stop >/dev/null 2>&1
    fi
    rm -rf "$TMP"
}
[ "$LIB_ONLY" = 1 ] || trap cleanup EXIT

# --- checks -------------------------------------------------------------------
section() {
    SECTION=$1
    echo
    echo "== $1: $2"
}
want_section() { case "$SECTIONS" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
want_tool() { case "$TOOLSET" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
record() { # record NEEDS LABEL GOT WANT OK(1|0)
    local needs=$1 label=$2 got=$3 want=$4 ok=$5 st
    if [ -n "$CTX" ]; then # inside a negative control: collected, not counted
        printf '%s\t%s\t%s\t%s\n' "$ok" "$label" "$got" "$want" >>"$CTXFILE"
        if [ "$ok" = 1 ]; then echo "      ($CTX) holds: $label"; else echo "      ($CTX) fails: $label — got '$got', want $want"; fi
        return 0
    fi
    if [ "$MANUAL" = 1 ]; then
        case "$SUBST" in *" $needs "*) ;; *)
            SKIP=$((SKIP + 1))
            echo "  - [$SECTION] $label (not run under QUAL_MANUAL_WIRING: needs $needs)"
            printf 'skip\t%s\t%s\t%s\t%s\t%s\n' "$SECTION" "$needs" "$label" "$got" "$want" >>"$OUT/checks.tsv"
            return 0
            ;;
        esac
    fi
    if [ "$ok" = 1 ]; then
        PASS=$((PASS + 1)) st=pass
        echo "  ✓ [$SECTION] $label"
    else
        FAIL=$((FAIL + 1)) st=fail
        echo "  ✗ [$SECTION] $label — got '$got', want $want  (needs: $needs)"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$st" "$SECTION" "$needs" "$label" "$got" "$want" >>"$OUT/checks.tsv"
}
check() { record "$1" "$2" "$3" "'$4'" "$([ "$3" == "$4" ] && echo 1 || echo 0)"; } # equality
checkp() { record "$1" "$2" "$3" "$4" "$5"; }                                        # predicate
ok() { if "$@"; then echo 1; else echo 0; fi; }
num() { case $1 in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }
gt0() { num "$1" && [ "$1" -gt 0 ]; }
ge() { num "$1" && [ "$1" -ge "$2" ]; }
under() { [ "$1" = "$2" ] || case $1 in "$2"/*) return 0 ;; *) return 1 ;; esac; }
words() { # words VALUE W…: every W is a separate word of VALUE
    local v=" $1 " w
    shift
    for w in "$@"; do case "$v" in *" $w "*) ;; *) return 1 ;; esac; done
}
# r NAME KEY: a value from a container's result file ("missing" without a file).
r() {
    [ -f "$QR/$1.res" ] || { echo missing; return; }
    grep "^$2=" "$QR/$1.res" | tail -1 | cut -d= -f2-
}
# insp NAME EXPR: a python expression over the saved `docker inspect` (c).
insp() {
    python3 - "$QR/$1.inspect.json" "$2" <<'PY' 2>/dev/null || echo "?"
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    data = []
c = data[0] if data else {}
print(eval(sys.argv[2], {"c": c}))
PY
}
mc() { insp "$1" "((c.get('MicropodCache') or {}).get('tools') or {}).get('$2', {}).get('$3')"; } # mc NAME TOOL FIELD
has_cache_mount() { insp "$1" "any(m.get('Destination') == '/micropod/cache' for m in (c.get('Mounts') or []))"; }
hits_go() { echo "rc=$(r "$1" rc) compiles=$(r "$1" compiles) downloads=$(r "$1" downloads)"; }
sum_key() { # sum_key KEY NAME…: sum of a numeric key over results, "?" if any is not a number
    local k=$1 t=0 v n
    shift
    for n in "$@"; do v=$(r "$n" "$k"); num "$v" || { echo "? ($n: $v)"; return; }; t=$((t + v)); done
    echo "$t"
}
begin_ctx() { CTX=$1 CTXFILE="$OUT/control-$1.tsv"; : >"$CTXFILE"; }
end_ctx() { CTX="" CTXFILE=""; }
ctx_failed() { grep -F "$2" "$OUT/control-$1.tsv" 2>/dev/null | head -1 | grep -q '^0'; } # ctx_failed CTX LABEL-FRAGMENT
ctx_got() { grep -F "$2" "$OUT/control-$1.tsv" 2>/dev/null | head -1 | cut -f3; }

# --- containers -----------------------------------------------------------------
# run_container NAME IMAGE [docker args…] -- CMD…   (foreground, with a watchdog)
run_container() {
    local name=$1 image=$2 pid waited=0 cname="q$S-$1"
    shift 2
    local args=()
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do args+=("$1") && shift; done
    shift
    rm -f "$QR/$name.res" "$QR/$name.log" "$QR/$name.progress"
    "$DOCKER" run --name "$cname" --label "qual-run=$S" -v "$QW/q:/q:ro" -v "$QW/qf:/qf:ro" -v "$QT:/qt:ro" -v "$QR:/qr" \
        "${args[@]}" "$image" "$@" >"$QR/$name.stdout" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        sleep 0.2
        waited=$((waited + 1))
        if [ "$waited" -ge $((TIMEOUT * 5)) ]; then
            echo "harness: timeout after ${TIMEOUT}s" >>"$QR/$name.stdout"
            "$DOCKER" rm -f "$cname" >/dev/null 2>&1
            kill "$pid" 2>/dev/null
            break
        fi
    done
    wait "$pid"
    echo "$?" >"$QR/$name.docker-rc"
    finish_container "$name"
}
# run_detached NAME IMAGE [docker args…] -- CMD…   (collect with collect NAME)
run_detached() {
    local name=$1 image=$2 cname="q$S-$1"
    shift 2
    local args=()
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do args+=("$1") && shift; done
    shift
    rm -f "$QR/$name.res" "$QR/$name.log" "$QR/$name.progress"
    "$DOCKER" run -d --name "$cname" --label "qual-run=$S" -v "$QW/q:/q:ro" -v "$QW/qf:/qf:ro" -v "$QT:/qt:ro" -v "$QR:/qr" \
        "${args[@]}" "$image" "$@" >"$QR/$name.stdout" 2>&1
    echo "$?" >"$QR/$name.docker-rc"
    DETACHED+=("$name")
}
collect() { # collect NAME: wait for a detached container, keep its inspect, remove it
    local name=$1 cname="q$S-$1" pid waited=0
    "$DOCKER" wait "$cname" >>"$QR/$name.stdout" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        sleep 0.2
        waited=$((waited + 1))
        if [ "$waited" -ge $((TIMEOUT * 5)) ]; then
            echo "harness: timeout after ${TIMEOUT}s" >>"$QR/$name.stdout"
            kill "$pid" 2>/dev/null
            break
        fi
    done
    wait "$pid"
    finish_container "$name"
    sentinel "$name"
}
finish_container() {
    local cname="q$S-$1"
    "$DOCKER" inspect "$cname" >"$QR/$1.inspect.json" 2>/dev/null || echo '[]' >"$QR/$1.inspect.json"
    "$DOCKER" rm -f "$cname" >/dev/null 2>&1
    NRUN=$((NRUN + 1))
}
sentinel() {
    grep -q "^QUAL-SENTINEL $1\$" "$QR/$1.res" 2>/dev/null && return 0
    NMISS=$((NMISS + 1))
    record harness "$1: result file carries its sentinel" \
        "missing (docker rc $(cat "$QR/$1.docker-rc" 2>/dev/null); $(tail -c 240 "$QR/$1.stdout" 2>/dev/null | tr '\n' ' '))" "present" 0
    return 1
}

uid_of() { case $1 in 0 | drop*) echo 0 ;; *) echo 1000 ;; esac; }
class_of() { case $1 in *golang*) echo go ;; *node*) echo node ;; *uv*) echo uv ;; *python*) echo python ;; *rust*) echo rust ;; *) echo other ;; esac; }
home_of() { if [ "$2" = 0 ]; then echo /root; elif [ "$1" = node ]; then echo /home/node; else echo /; fi; }
yarn_target() { if [ "$1" = 0 ]; then echo /usr/local/share/.cache/yarn; else echo "$2/.cache/yarn"; fi; }
manual() { [ "$MANUAL" = 1 ] || [ "${FORCE_MANUAL:-0}" = 1 ]; }
merge_goflags() { # the plan's merge: append -trimpath unless a -trimpath form is present
    case " $1 " in *" -trimpath"* | *" --trimpath"*) echo "$1" ;; *) echo "${1:+$1 }-trimpath" ;; esac
}
# expect KIND UID SCOPE: the store path a tool's cache must resolve to.
expect() {
    local kind=$1 uid=$2 scope=$3
    if manual; then
        case $kind in
        yarn) echo "$VOL_ROOT/qm-$scope-yarn-u$uid" ;;
        yarnberry) echo "$VOL_ROOT/qm-$scope-yarnberry" ;;
        cargo) echo "$VOL_ROOT/qm-$scope-cargo-registry" ;;
        cargo_lock) echo "/$(basename "$QW")/qm/$scope/package-cache" ;;
        pip) echo "$VOL_ROOT/qm-$scope/pip/u$uid" ;;
        *) echo "$VOL_ROOT/qm-$scope/$kind" ;;
        esac
    else
        case $kind in
        pip | yarn) echo "$CACHE_ROOT/scopes/$scope/$kind/u$uid" ;;
        cargo) echo "$CACHE_ROOT/scopes/$scope/cargo/registry" ;;
        cargo_lock) echo "$CACHE_ROOT/scopes/$scope/cargo/.package-cache" ;;
        *) echo "$CACHE_ROOT/scopes/$scope/$kind" ;;
        esac
    fi
}
# A store property is only evidence when the scanned path is the scope store:
# otherwise (nothing attached) the check fails as inconclusive.
check_on() { # check_on NEEDS LABEL NAME KEY EXPECTED GOT WANT   (equality)
    local st
    st=$(r "$3" "store.$4")
    if under "$st" "$5"; then check "$1" "$2" "$6" "$7"; else checkp "$1" "$2" "inconclusive, $4 is not on the scope store (store=$st): $6" "'$7' on the scope store" 0; fi
}
checkp_on() { # checkp_on NEEDS LABEL NAME KEY EXPECTED GOT WANT-DESC OK
    local st
    st=$(r "$3" "store.$4")
    if under "$st" "$5"; then checkp "$1" "$2" "$6" "$7" "$8"; else checkp "$1" "$2" "inconclusive, $4 is not on the scope store (store=$st): $6" "$7 on the scope store" 0; fi
}
check_store() { # check_store NEEDS NAME KEY EXPECTED
    local got
    got=$(r "$2" "store.$3")
    checkp "$1" "$2: the $3 cache resolves to its scope store" "$got" "under $4" "$(ok under "$got" "$4")"
}

# manual_prep SCOPE: hand-wired stores (QUAL_MANUAL_WIRING=1 and the controls),
# laid out once per scope by qprep.py in PREP_MODE (acl|noacl).
manual_prep() {
    local scope=$1 mode=${PREP_MODE:-acl} idx=${PREP_INDEX:-pnpm-index} u name="prep-$1"
    [ -f "$QR/.prepped-$scope" ] && return 0
    local args=(--label io.micropod.cache=off -v "qm-$scope:/s")
    echo "qm-$scope" >>"$QW/volumes.list"
    for u in yarn-u0 yarn-u1000 yarnberry cargo-registry cargo-git; do
        args+=(-v "qm-$scope-$u:/p/$u")
        echo "qm-$scope-$u" >>"$QW/volumes.list"
    done
    mkdir -p "$QW/qm/$scope"
    : >"$QW/qm/$scope/package-cache"
    : >"$QW/qm/$scope/package-cache-mutate"
    chmod 0666 "$QW/qm/$scope/package-cache" "$QW/qm/$scope/package-cache-mutate"
    run_container "$name" "$IMG_PY" "${args[@]}" -- python3 /q/qprep.py "$name" "$mode" "$idx"
    if [ "$(r "$name" mode)" = "$mode" ]; then
        touch "$QR/.prepped-$scope"
    else
        record harness "hand-wired $mode stores for scope $scope were laid out" "$(tail -c 300 "$QR/$name.stdout" | tr '\n' ' ')" "a prep result file" 0
    fi
}

# build_args IMAGE USER SCOPE NET [extra docker args, env as -e KEY=VAL…]
# USER: 0 (image default), 1000 (--user 1000:1000), node (--user node),
# drop1000 (root entrypoint that drops to 1000). SCOPE: a cache scope, or "-"
# for none (no scope label, no hand wiring). Sets RUNARGS.
build_args() {
    local image=$1 user=$2 scope=$3 net=$4 uid cls home goflags="" e k w
    shift 4
    uid=$(uid_of "$user")
    cls=$(class_of "$image")
    home=$(home_of "$cls" "$uid")
    RUNARGS=()
    local cenv=() cargs=() wenv=() kept=() w2=()
    case $user in
    0) ;;
    drop*) cenv+=("QDROP=${user#drop}") ;;
    node) RUNARGS+=(--user node) ;;
    *) RUNARGS+=(--user "$user:$user") ;;
    esac
    [ "$net" = none ] && RUNARGS+=(--network none)
    while [ "$#" -gt 0 ]; do
        if [ "$1" = -e ]; then cenv+=("$2") && shift 2; else cargs+=("$1") && shift; fi
    done
    for e in "${cenv[@]}"; do case $e in GOFLAGS=*) goflags=${e#GOFLAGS=} ;; esac; done # guard:guest
    if [ "$scope" != - ] && manual; then
        manual_prep "$scope"
        RUNARGS+=(--label io.micropod.cache=off -v "qm-$scope:/micropod/cache")
        wenv=("GOMODCACHE=/micropod/cache/gomod" "GOCACHE=/micropod/cache/gobuild" "GOFLAGS=$(merge_goflags "$goflags")" # guard:guest
            "npm_config_cache=/micropod/cache/npm" "pnpm_config_store_dir=/micropod/cache/pnpm" "npm_config_store_dir=/micropod/cache/pnpm"
            "PIP_CACHE_DIR=/micropod/cache/pip/u$uid" "UV_CACHE_DIR=/micropod/cache/uv" "UV_LINK_MODE=copy" "COREPACK_HOME=/micropod/cache/corepack")
        if [ "$cls" = node ]; then
            [ "${NO_YARN:-0}" = 1 ] || RUNARGS+=(-v "qm-$scope-yarn-u$uid:$(yarn_target "$uid" "$home")")
            RUNARGS+=(-v "qm-$scope-yarnberry:$home/.yarn/berry")
        fi
        if [ "$cls" = rust ]; then
            RUNARGS+=(-v "qm-$scope-cargo-registry:/usr/local/cargo/registry" -v "qm-$scope-cargo-git:/usr/local/cargo/git"
                -v "$QW/qm/$scope/package-cache:/usr/local/cargo/.package-cache"
                -v "$QW/qm/$scope/package-cache-mutate:/usr/local/cargo/.package-cache-mutate")
        fi
        for e in "${cenv[@]}"; do case $e in GOFLAGS=*) ;; *) kept+=("$e") ;; esac; done # guard:guest
        cenv=("${kept[@]}")
        for e in "${cenv[@]}"; do # a request variable wins over the wiring (user-env)
            k=${e%%=*}
            w2=()
            for w in "${wenv[@]}"; do [ "${w%%=*}" = "$k" ] || w2+=("$w"); done
            wenv=("${w2[@]}")
        done
    elif [ "$scope" != - ] && [ "$scope" != default ]; then
        RUNARGS+=(--label "io.micropod.cache.scope=$scope")
    fi
    for e in "${wenv[@]}" "${cenv[@]}"; do RUNARGS+=(-e "$e"); done
    RUNARGS+=("${cargs[@]}")
}
# step NAME IMAGE USER SCOPE NET TOOL ACTION VARIANT [extra…]: one probe run.
step() {
    [ "$#" -ge 8 ] || { record harness "step $1 is called with all eight arguments" "$*" "NAME IMAGE USER SCOPE NET TOOL ACTION VARIANT" 0 && return 1; }
    local name=$1 image=$2 user=$3 scope=$4 net=$5 tool=$6 action=$7 variant=$8
    shift 8
    build_args "$image" "$user" "$scope" "$net" "$@"
    if [ "${BG:-0}" = 1 ]; then
        run_detached "$name" "$image" "${RUNARGS[@]}" -- sh /q/qprobe.sh "$name" "$tool" "$action" "$variant"
    else
        run_container "$name" "$image" "${RUNARGS[@]}" -- sh /q/qprobe.sh "$name" "$tool" "$action" "$variant"
        sentinel "$name"
    fi
}
ping_engine() { curl -s -m 5 --unix-socket "$SOCK" http://d/_ping 2>/dev/null | grep -q OK; }
wait_engine() { # wait_engine SECONDS
    local deadline=$((SECONDS + $1))
    until ping_engine; do
        [ "$SECONDS" -lt "$deadline" ] || return 1
        sleep 0.5
    done
}
state() { python3 -c "import json; s=json.load(open('$ROOT_DIR/run/state.json')); print($1)" 2>/dev/null; }
restart_machine() {
    "$M" machine stop >"$QR/machine-stop-$1.log" 2>&1
    "$M" machine start >"$QR/machine-start-$1.log" 2>&1
    wait_engine 180
}

if [ "$LIB_ONLY" = 1 ]; then return 0 2>/dev/null || exit 0; fi

# --- install or attach ------------------------------------------------------------
echo "== machine at $ROOT_DIR ($([ "$INSTALL" = 1 ] && echo throwaway install || echo existing)); results in $OUT"
if [ "$INSTALL" = 1 ]; then
    VMM="${QUAL_VMM:-$REPO/vmm/target/release/micropod-vmm}"
    KERNEL="${QUAL_KERNEL:-$(ls -t "$HOME"/.micropod/kernels/*/Image 2>/dev/null | head -1)}"
    INITRD="${QUAL_INITRD:-$REPO/vmm/target/mp-hvf-init.cpio}"
    TOOLS="${QUAL_TOOLS:-}"
    [ -x "$VMM" ] && [ -f "$KERNEL" ] && [ -f "$INITRD" ] || { echo "missing VMM, kernel or initrd" >&2 && exit 2; }
    [ -n "$TOOLS" ] && [ -f "$TOOLS/runner/start.sh" ] || { echo "set QUAL_TOOLS to a guest tool bundle (runner/start.sh)" >&2 && exit 2; }
    if [ -n "${QUAL_DISK_IMAGE:-}" ]; then
        DISK_ARGS=(--disk-image "$QUAL_DISK_IMAGE")
    else
        DISK_FROM="${QUAL_DISK_FROM:-$HOME/.micropod/ci/worker.ext4}"
        [ -f "$DISK_FROM" ] || { echo "missing $DISK_FROM" >&2 && exit 2; }
        DISK_ARGS=(--disk-from "$DISK_FROM")
    fi
    for dir in "$ROOT_DIR" "$ROOT_DIR-ws"; do
        ours "$dir" || { echo "$dir exists and was not made by this script (no $MARKER)" >&2 && exit 2; }
    done
    [ -e "$ROOT_DIR" ] && "$M" machine stop >/dev/null 2>&1
    for dir in "$ROOT_DIR" "$ROOT_DIR-ws"; do
        rm -rf "$dir" # ours (checked above)
        mkdir -p "$dir" && touch "$dir/$MARKER"
    done
    INSTALLED=1
    CACHE_DISK_ARGS=()
    [ "${QUAL_CACHE_DISK_SIZE:-32g}" = none ] || CACHE_DISK_ARGS=(--cache-disk-size "${QUAL_CACHE_DISK_SIZE:-32g}")
    "$M" machine install --vmm "$VMM" --kernel "$KERNEL" --initrd "$INITRD" --tools "$TOOLS" "${DISK_ARGS[@]}" "${CACHE_DISK_ARGS[@]}" \
        --cpus "${QUAL_CPUS:-8}" --memory-mib "${QUAL_MEMORY_MIB:-12288}" --workspace "$ROOT_DIR-ws" >"$OUT/install.log" 2>&1 ||
        { cat "$OUT/install.log" >&2 && exit 2; }
else
    [ -f "$ROOT_DIR/machine.json" ] || { echo "no machine installed at $ROOT_DIR" >&2 && exit 2; }
    ping_engine && WAS_RUNNING=1
fi
# A throwaway root never takes the rig's canonical Docker socket link.
RIG_LINK_BEFORE="$(readlink "$HOME/.micropod/docker.sock" 2>/dev/null || echo absent)"
"$M" machine start >"$OUT/start.log" 2>&1
wait_engine 180 || { echo "engine did not answer on $SOCK" >&2 && cat "$OUT/start.log" >&2 && exit 2; }
check engine "machine start on this throwaway root left ~/.micropod/docker.sock alone" \
    "$(readlink "$HOME/.micropod/docker.sock" 2>/dev/null || echo absent)" "$RIG_LINK_BEFORE"
WS="$(python3 -c "import json; print(json.load(open('$ROOT_DIR/machine.json')).get('workspace') or '')")"
[ -n "$WS" ] && [ -d "$WS" ] || { echo "the machine has no workspace share; bind results need one" >&2 && exit 2; }
QW="$WS/qual-$S"
QR="$QW/qr"
QT="$WS/qual-tools"
mkdir -p "$QW/q" "$QW/qf" "$QR" "$QT" && touch "$QW/.qual-run"
cp "$FIX/qprobe.sh" "$FIX/qprep.py" "$QW/q/"
cp -R "$FIX/." "$QW/qf/"
chmod -R a+rX "$QW" && chmod 0777 "$QR"
: >"$QW/volumes.list"
DETACHED=()
echo "   workspace $QW; manual wiring: $MANUAL"
{
    echo "run=$S root=$ROOT_DIR manual=$MANUAL sections=$SECTIONS tools=$TOOLSET"
    echo "docker=$("$DOCKER" version --format '{{.Client.Version}}' 2>/dev/null) buildx=$("$DOCKER" buildx version 2>/dev/null) compose=$("$DOCKER" compose version --short 2>/dev/null)"
    echo "engine_version=$(curl -s -m 5 --unix-socket "$SOCK" http://d/version)"
    echo "kernel=$(curl -s -m 5 --unix-socket "$SOCK" http://d/info | python3 -c 'import sys,json; print(json.load(sys.stdin).get("KernelVersion"))' 2>/dev/null)"
    echo "bundle=$ROOT_DIR/tools manifest=$(cat "$ROOT_DIR/tools/runner/manifest.json" 2>/dev/null || echo none)"
} >"$OUT/environment.txt"

# Images and the pinned harness tools (pnpm and yarn 4 live in the workspace,
# installed by a label-off container with a private npm cache).
SECTION=setup
images="$IMG_BASE $IMG_GO $IMG_NODE $IMG_PY"
want_tool uv && images="$images $IMG_UV"
want_tool cargo && images="$images $IMG_RUST"
want_tool pip && want_section T2 && images="$images $PIP_IMAGES"
want_section T3 && images="$images $IMG_PG"
want_section T8 && images="$images $IMG_PY"
want_section T7 && images="$images $T7_FIRST"
for img in $(echo "$images" | tr ' ' '\n' | sort -u); do
    "$DOCKER" image inspect "$img" >/dev/null 2>&1 && continue
    "$DOCKER" pull -q "$img" >>"$OUT/pull.log" 2>&1 || record harness "pull $img" "failed (see pull.log)" "pulled" 0
done
if [ "$(cat "$QT/versions" 2>/dev/null)" != "$QT_VERSIONS" ]; then
    rm -rf "${QT:?}/"* && chmod 0755 "$QT"
    cat >"$QW/q/install-tools.sh" <<EOF
set -e
for v in $PNPM_VERSIONS; do npm i -g --prefix /qt/pnpm\${v%%.*} pnpm@\$v >/qt/install.log 2>&1; done
npm i -g --prefix /qt/yarn4 @yarnpkg/cli-dist@$YARN4_VERSION >>/qt/install.log 2>&1
npm i -g --prefix /qt/corepack corepack@0.36.0 >>/qt/install.log 2>&1
npm i -g --prefix /qt/yarn1 yarn@$YARN1_VERSION >>/qt/install.log 2>&1
echo "$QT_VERSIONS" >/qt/versions
EOF
    "$DOCKER" run --rm --label "qual-run=$S" --label io.micropod.cache=off -e npm_config_cache=/tmp/npmc -e npm_config_update_notifier=false \
        -v "$QW/q:/q:ro" -v "$QT:/qt" "$IMG_NODE" sh /q/install-tools.sh >"$OUT/install-tools.log" 2>&1
    check harness "pinned pnpm ($PNPM_VERSIONS), yarn $YARN4_VERSION, corepack 0.36.0 and yarn $YARN1_VERSION installed into the workspace" "$(cat "$QT/versions" 2>/dev/null)" "$QT_VERSIONS"
fi

# --- T0 preflight -------------------------------------------------------------------
if want_section T0; then
    section T0 "preflight: the bundle and the engine agree"
    VERSION_JSON="$(curl -s -m 5 --unix-socket "$SOCK" http://d/version)"
    MANIFEST="$ROOT_DIR/tools/runner/manifest.json"
    check bundle "the installed bundle carries runner/manifest.json" "$([ -f "$MANIFEST" ] && echo present || echo absent)" present
    t0=$(python3 - "$MANIFEST" "$VERSION_JSON" <<'PY'
import json, sys
try:
    m = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    m = {}
v = json.loads(sys.argv[2] or "{}")
commit = v.get("GitCommit") or v.get("MicropodEngineCommit") or v.get("Commit") or ""
caps = v.get("MicropodCapabilities") or []
print(f"{m.get('engineCommit', 'none')}|{commit or 'none'}|{','.join(sorted(m.get('capabilities') or [])) or 'none'}|{','.join(sorted(caps)) or 'none'}|{m.get('cacheApi', 'none')}")
PY
    )
    IFS='|' read -r t0_mc t0_vc t0_mcaps t0_vcaps t0_api <<<"$t0"
    checkp bundle "manifest engineCommit equals the engine's GET /version commit" "manifest=$t0_mc engine=$t0_vc" "equal and not none" \
        "$(ok test "$t0_mc" = "$t0_vc" -a "$t0_mc" != none)"
    check bundle "manifest cacheApi" "$t0_api" 1
    checkp bundle "manifest capabilities include caches and grpc-build" "$t0_mcaps" "caches,grpc-build present" \
        "$(ok words "$(echo "$t0_mcaps" | tr ',' ' ')" caches grpc-build)"
    checkp bundle "engine GET /version MicropodCapabilities include caches" "$t0_vcaps" "caches present" "$(ok words "$(echo "$t0_vcaps" | tr ',' ' ')" caches)"
    check bundle "the bundle ships runner/bin/buildkitd" "$([ -x "$ROOT_DIR/tools/runner/bin/buildkitd" ] && echo present || echo absent)" present
    check bundle "the engine reports BuildKit (GET /micropod/buildkit)" "$(curl -s -o /dev/null -w '%{http_code}' -m 5 --unix-socket "$SOCK" http://d/micropod/buildkit)" 200
    # The stores, the fence's marks and the clean-stop record are on the
    # persistent cache disk when the machine has one (guest init mounted it).
    want_disk=none
    [ -f "$ROOT_DIR/caches.ext4" ] && want_disk=mounted
    # cacheDisk is guest init's outcome plus what the guest's mountinfo shows;
    # a mounted disk must be both, with shared caches on (no unavailable).
    check engine "the engine's shared caches are on the persistent cache disk when the machine has caches.ext4 (GET /micropod/caches cacheDisk)" \
        "$(curl -s -m 5 --unix-socket "$SOCK" 'http://d/micropod/caches?stats=0' | python3 -c "
import json, sys
d = json.load(sys.stdin)
disk = d.get('cacheDisk') or {}
state = disk.get('state') or 'none'
if state == 'mounted' and not disk.get('mounted'):
    state = 'mounted-but-not-in-mountinfo'
print(state + ('' if not d.get('unavailable') else ' unavailable'))" 2>/dev/null)" "$want_disk"
    if [ "$want_disk" = mounted ]; then
        check engine "machine status reports the cache disk mounted" \
            "$("$M" --json machine status 2>/dev/null | python3 -c "import json, sys; d = json.load(sys.stdin)['cacheDisk']; print(d.get('mounted'), d.get('sharedCaches'))" 2>/dev/null)" "True on"
    fi
    echo "    kernel $(sed -n 's/^kernel=//p' "$OUT/environment.txt"); engine /version: $VERSION_JSON"
fi

# --- T1 per tool cold then warm ------------------------------------------------------------
T1_SCOPE=default # no labels at all: the default-on path
t1_cold() {
    local sc=$T1_SCOPE m n
    if want_tool go; then
        n=t1-go-cold
        step $n "$IMG_GO" 0 "$sc" on go build base -e "$GO_REQ_FLAGS" -e "$GO_LOCAL"
        check harness "$n: cold go build as root succeeds" "$(r $n rc)" 0
        check_store auto $n gomod "$(expect gomod 0 "$sc")"
        check_store auto $n gobuild "$(expect gobuild 0 "$sc")"
        checkp auto "$n: go env GOFLAGS carries -trimpath next to the request's -mod=mod" "$(r $n goenv.GOFLAGS)" "-mod=mod and -trimpath" \
            "$(ok words "$(r $n goenv.GOFLAGS)" -mod=mod -trimpath)"
    fi
    if want_tool npm; then
        n=t1-npm-cold
        step $n "$IMG_NODE" 0 "$sc" on npm ci a
        check harness "$n: cold npm ci succeeds" "$(r $n rc)" 0
        check_store auto $n npm "$(expect npm 0 "$sc")"
    fi
    if want_tool pnpm; then
        for m in $PNPM_T1; do
            n=t1-pnpm$m-cold
            step $n "$IMG_NODE" 0 "$sc" on pnpm install a -e QPNPM=$m
            check harness "$n: cold pnpm $m install --frozen-lockfile succeeds" "$(r $n rc)" 0
            check_store auto $n pnpm "$(expect pnpm 0 "$sc")"
            check safety "$n: pnpm $m wrote no .pnpm-store into the checkout" "$(r $n project_store)" none
        done
    fi
    if want_tool yarn1; then
        n=t1-yarn1-cold
        step $n "$IMG_NODE" 0 "$sc" on yarn1 install a
        check harness "$n: cold yarn 1 install succeeds" "$(r $n rc)" 0
        check_store auto $n yarn "$(expect yarn 0 "$sc")"
    fi
    if want_tool yarn4; then
        n=t1-yarn4-cold
        step $n "$IMG_NODE" 0 "$sc" on yarn4 install a
        check harness "$n: cold yarn 4 install --immutable succeeds" "$(r $n rc)" 0
        check_store auto $n yarnberry "$(expect yarnberry 0 "$sc")"
        n=t1-yarn4-zero
        step $n "$IMG_NODE" 0 "$sc" none yarn4 zero a
        check_store auto $n yarnberry "$(expect yarnberry 0 "$sc")"
        check safety "$n: a zero-install repo (enableGlobalCache: false) installs offline and its checkout is unchanged" \
            "rc=$(r $n rc) changed_files=$(r $n changed_files)" "rc=0 changed_files=0"
        check_on auto "$n: …and it wrote nothing into the shared yarnberry store" $n yarnberry "$(expect yarnberry 0 "$sc")" "$(r $n new_by_me.yarnberry)" 0
    fi
    if want_tool pip; then
        n=t1-pip-cold
        step $n "$IMG_PY" 0 "$sc" on pip install a
        check harness "$n: cold pip install succeeds" "$(r $n rc)" 0
        check_store auto $n pip "$(expect pip 0 "$sc")"
    fi
    if want_tool uv; then
        n=t1-uv-cold
        step $n "$IMG_UV" 0 "$sc" on uv install a
        check harness "$n: cold uv pip install succeeds" "$(r $n rc)" 0
        check_store auto $n uv "$(expect uv 0 "$sc")"
        check auto "$n: UV_LINK_MODE is copy" "$(r $n env.UV_LINK_MODE)" copy
    fi
    if want_tool cargo; then
        n=t1-cargo-cold
        step $n "$IMG_RUST" 0 "$sc" on cargo fetch a
        check harness "$n: cold cargo fetch --locked succeeds" "$(r $n rc)" 0
        check_store auto $n cargo "$(expect cargo 0 "$sc")"
        checkp auto "$n: \$CARGO_HOME/.package-cache is the shared lock file" "$(r $n store.cargo_lock)" "under $(expect cargo_lock 0 "$sc")" \
            "$(ok under "$(r $n store.cargo_lock)" "$(expect cargo_lock 0 "$sc")")"
    fi
    if want_tool corepack; then
        n=t1-corepack-cold
        step $n "$IMG_NODE" 0 "$sc" on corepack prepare a
        check harness "$n: corepack pnpm@9.15.9 --version succeeds online" "$(r $n rc)" 0
        check_store auto $n corepack "$(expect corepack 0 "$sc")"
    fi
}
t1_warm() { # t1_warm PREFIX: the warm half, also replayed after a restart (T5)
    local p=$1 sc=$T1_SCOPE m n
    if want_tool go; then
        n=$p-go-warm
        step $n "$IMG_GO" 0 "$sc" none go build base -e "$GO_REQ_FLAGS" -e "$GO_NOPROXY" -e "$GO_LOCAL"
        check auto "$n: go build -x in a new container at another checkout path, --network none, GOPROXY=off" "$(hits_go $n)" "rc=0 compiles=0 downloads=0"
    fi
    if want_tool npm; then
        n=$p-npm-warm
        step $n "$IMG_NODE" 0 "$sc" none npm ci-offline a
        check auto "$n: npm ci --offline in a new container, --network none" "rc=$(r $n rc) eacces=$(r $n eacces)" "rc=0 eacces=0"
    fi
    if want_tool pnpm; then
        for m in $PNPM_T1; do
            n=$p-pnpm$m-warm
            if [ "$m" -le 10 ]; then
                step $n "$IMG_NODE" 0 "$sc" none pnpm install-offline a -e QPNPM=$m
                check auto "$n: pnpm $m install --offline --frozen-lockfile, --network none" \
                    "rc=$(r $n rc) downloaded=$(r $n downloaded) project_store=$(r $n project_store)" "rc=0 downloaded=0 project_store=none"
            else # pnpm 11+ needs its metadata cache-dir offline, which is not attached
                step $n "$IMG_NODE" 0 "$sc" on pnpm install a -e QPNPM=$m
                check auto "$n: pnpm $m install --frozen-lockfile (online) downloads nothing" \
                    "rc=$(r $n rc) downloaded=$(r $n downloaded) project_store=$(r $n project_store)" "rc=0 downloaded=0 project_store=none"
            fi
            checkp auto "$n: pnpm $m reused packages from the store" "$(r $n reused)" ">0" "$(ok gt0 "$(r $n reused)")"
        done
    fi
    if want_tool yarn1; then
        n=$p-yarn1-warm
        step $n "$IMG_NODE" 0 "$sc" none yarn1 install-offline a
        check auto "$n: yarn install --offline --frozen-lockfile, --network none" "$(r $n rc)" 0
    fi
    if want_tool yarn4; then
        n=$p-yarn4-warm
        step $n "$IMG_NODE" 0 "$sc" none yarn4 install-nonet a
        check auto "$n: YARN_ENABLE_NETWORK=0 yarn install --immutable, --network none" "$(r $n rc)" 0
    fi
    if want_tool pip; then
        n=$p-pip-warm
        step $n "$IMG_PY" 0 "$sc" on pip install a
        check auto "$n: pip install in a fresh venv downloads nothing" "rc=$(r $n rc) downloading=$(r $n downloading)" "rc=0 downloading=0"
        checkp auto "$n: …every requirement is 'Using cached'" "$(r $n using_cached)" ">=2" "$(ok ge "$(r $n using_cached)" 2)"
    fi
    if want_tool uv; then
        n=$p-uv-warm
        step $n "$IMG_UV" 0 "$sc" none uv install-offline a
        check auto "$n: uv pip install --offline (an sdist built wheel included), --network none" "$(r $n rc)" 0
    fi
    if want_tool cargo; then
        n=$p-cargo-warm
        step $n "$IMG_RUST" 0 "$sc" none cargo build-offline a
        check auto "$n: cargo build --offline --locked in a second container, --network none" "$(r $n rc)" 0
    fi
    if want_tool corepack; then
        n=$p-corepack-warm
        step $n "$IMG_NODE" 0 "$sc" none corepack nonet a
        check auto "$n: COREPACK_ENABLE_NETWORK=0 corepack pnpm@9.15.9 --version, --network none" "rc=$(r $n rc) reported=$(r $n reported)" "rc=0 reported=9.15.9"
    fi
}
if want_section T1; then
    section T1 "each tool cold, then warm in a new container (default scope, no labels)"
    t1_cold
    t1_warm t1
fi

# --- T2 both uid orders ----------------------------------------------------------------------
xy() { if [ "$1" = a ]; then X=0 Y=1000; else X=1000 Y=0; fi; }
# Go (the measured silent miss): X cold; Y one-file change; Y unchanged (the
# third run); then Y adds a module, Y reruns, and X hits Y's entries.
t2_go_seq() { # t2_go_seq ORDER SCOPE PREFIX
    local o=$1 sc=$2 p=$3
    xy "$o"
    step $p-x1 "$IMG_GO" $X "$sc" on go build base -e "$GO_REQ_FLAGS" -e "$GO_LOCAL"
    check safety "$p-x1: uid $X cold build" "rc=$(r $p-x1 rc)" "rc=0"
    step $p-y1 "$IMG_GO" $Y "$sc" none go build base -e QEDIT=$p -e "$GO_REQ_FLAGS" -e "$GO_NOPROXY" -e "$GO_LOCAL"
    check_store auto $p-y1 gobuild "$(expect gobuild $Y "$sc")"
    checkp_on auto "$p-y1: uid $Y's one-file change stores gobuild entries owned by uid $Y" $p-y1 gobuild "$(expect gobuild $Y "$sc")" \
        "rc=$(r $p-y1 rc) compiles=$(r $p-y1 compiles) gobuild_new=$(r $p-y1 new_by_me.gobuild)" "rc=0, gobuild_new>0" \
        "$(ok test "$(r $p-y1 rc)" = 0 -a "$(gt0 "$(r $p-y1 new_by_me.gobuild)" && echo y)" = y)"
    step $p-y2 "$IMG_GO" $Y "$sc" none go build base -e QEDIT=$p -e "$GO_REQ_FLAGS" -e "$GO_NOPROXY" -e "$GO_LOCAL"
    check auto "$p-y2: unchanged rerun by uid $Y hits fully (third run)" "$(hits_go $p-y2)" "rc=0 compiles=0 downloads=0"
    step $p-y3 "$IMG_GO" $Y "$sc" on go build newmod -e QEDIT=$p -e "$GO_REQ_FLAGS" -e "$GO_LOCAL"
    checkp_on auto "$p-y3: uid $Y adds a module and stores gomod entries owned by uid $Y" $p-y3 gomod "$(expect gomod $Y "$sc")" \
        "rc=$(r $p-y3 rc) gomod_new=$(r $p-y3 new_by_me.gomod)" "rc=0, gomod_new>0" \
        "$(ok test "$(r $p-y3 rc)" = 0 -a "$(gt0 "$(r $p-y3 new_by_me.gomod)" && echo y)" = y)"
    step $p-y4 "$IMG_GO" $Y "$sc" none go build newmod -e QEDIT=$p -e "$GO_REQ_FLAGS" -e "$GO_NOPROXY" -e "$GO_LOCAL"
    check auto "$p-y4: uid $Y's rerun with the new module hits fully" "$(hits_go $p-y4)" "rc=0 compiles=0 downloads=0"
    step $p-x2 "$IMG_GO" $X "$sc" none go build newmod -e QEDIT=$p -e "$GO_REQ_FLAGS" -e "$GO_NOPROXY" -e "$GO_LOCAL"
    check auto "$p-x2: uid $X then hits uid $Y's entries" "$(hits_go $p-x2)" "rc=0 compiles=0 downloads=0"
    check_on auto "$p: no gobuild directory lacks 0777 (find -type d ! -perm -0777)" $p-x2 gobuild "$(expect gobuild $X "$sc")" "$(r $p-x2 dirs_not_0777.gobuild)" 0
    check_on auto "$p: no gomod cache/download directory lacks 0777" $p-x2 gomod "$(expect gomod $X "$sc")" "$(r $p-x2 dirs_not_0777.gomod_download)" 0
    check_on auto "$p: no owner-only entries in gobuild or gomod" $p-x2 gobuild "$(expect gobuild $X "$sc")" \
        "gobuild=$(r $p-x2 scan.gobuild.owner_only) gomod=$(r $p-x2 scan.gomod.owner_only)" "gobuild=0 gomod=0"
    check safety "$p: no EACCES/EPERM in any run" "$(sum_key eacces $p-x1 $p-y1 $p-y2 $p-y3 $p-y4 $p-x2)" 0
}
# Shared stores: X cold (a); Y warm of X's entries (a); Y change (b, online);
# Y warm (b); X warm of Y's entries (b).
hit_of() { if [ "$2" = pnpm ]; then echo "rc=$(r "$1" rc) downloaded=$(r "$1" downloaded)"; else echo "rc=$(r "$1" rc)"; fi; }
hit_want() { if [ "$1" = pnpm ]; then echo "rc=0 downloaded=0"; else echo "rc=0"; fi; }
t2_shared() { # t2_shared PREFIX ORDER TOOL IMAGE SCOPE LABEL COLD WARM_A WARM_B NET CHANGE [extra…]
    local p=$1 o=$2 tool=$3 img=$4 sc=$5 label=$6 cold=$7 wa=$8 wb=$9 net=${10} change=${11}
    shift 11
    xy "$o"
    step $p-x1 "$img" $X "$sc" on $tool $cold a "$@"
    check safety "$p-x1: uid $X cold $tool $cold" "$(r $p-x1 rc)" 0
    step $p-y1 "$img" $Y "$sc" "$net" $tool $wa a "$@"
    check_store auto $p-y1 $label "$(expect $label $Y "$sc")"
    check auto "$p-y1: uid $Y's $wa ($net network) hits uid $X's entries" "$(hit_of $p-y1 $tool)" "$(hit_want $tool)"
    step $p-y2 "$img" $Y "$sc" on $tool $change b "$@"
    checkp_on auto "$p-y2: uid $Y adds a package (lockfile change) and stores entries owned by uid $Y" $p-y2 $label "$(expect $label $Y "$sc")" \
        "rc=$(r $p-y2 rc) new=$(r $p-y2 new_by_me.$label)" "rc=0, new>0" "$(ok test "$(r $p-y2 rc)" = 0 -a "$(gt0 "$(r $p-y2 new_by_me.$label)" && echo y)" = y)"
    step $p-y3 "$img" $Y "$sc" "$net" $tool $wb b "$@"
    check auto "$p-y3: unchanged rerun by uid $Y hits" "$(hit_of $p-y3 $tool)" "$(hit_want $tool)"
    step $p-x2 "$img" $X "$sc" "$net" $tool $wb b "$@"
    check auto "$p-x2: uid $X hits uid $Y's new entries" "$(hit_of $p-x2 $tool)" "$(hit_want $tool)"
    check_on auto "$p: no owner-only entries in the shared $label store" $p-x2 $label "$(expect $label $X "$sc")" "$(r $p-x2 scan.$label.owner_only)" 0
    check_on auto "$p-x2: no file in the shared $label store is unreadable to uid $X (e.g. a tarball's 0640 kept by the tool)" $p-x2 $label "$(expect $label $X "$sc")" "$(r $p-x2 unreadable.$label)" 0
    check safety "$p: no EACCES/EPERM in any run" "$(sum_key eacces $p-x1 $p-y1 $p-y2 $p-y3 $p-x2)" 0
}
# Partitioned stores (yarn v1, pip): each uid hits within its own u<uid>.
t2_part() { # t2_part PREFIX ORDER TOOL IMAGE SCOPE LABEL WARM NET
    local p=$1 o=$2 tool=$3 img=$4 sc=$5 label=$6 warm=$7 net=$8
    xy "$o"
    step $p-x1 "$img" $X "$sc" on $tool install a
    check safety "$p-x1: uid $X cold $tool install" "$(r $p-x1 rc)" 0
    check_store auto $p-x1 $label "$(expect $label $X "$sc")"
    step $p-y1 "$img" $Y "$sc" on $tool install a
    check_store auto $p-y1 $label "$(expect $label $Y "$sc")"
    check_on auto "$p-y1: uid $Y installs into its own partition" $p-y1 $label "$(expect $label $Y "$sc")" "$(r $p-y1 rc)" 0
    step $p-y2 "$img" $Y "$sc" on $tool install b
    check_on auto "$p-y2: uid $Y adds a package in its partition" $p-y2 $label "$(expect $label $Y "$sc")" "rc=$(r $p-y2 rc) eacces=$(r $p-y2 eacces)" "rc=0 eacces=0"
    step $p-y3 "$img" $Y "$sc" "$net" $tool $warm b
    step $p-x2 "$img" $X "$sc" "$net" $tool $warm a
    if [ "$tool" = pip ]; then
        check auto "$p-y3: unchanged rerun by uid $Y downloads nothing" "rc=$(r $p-y3 rc) downloading=$(r $p-y3 downloading)" "rc=0 downloading=0"
        check auto "$p-x2: uid $X's partition still hits" "rc=$(r $p-x2 rc) downloading=$(r $p-x2 downloading)" "rc=0 downloading=0"
        check safety "$p: pip never disabled its cache" "$(sum_key cache_disabled_warn $p-x1 $p-y1 $p-y2 $p-y3 $p-x2)" 0
    else
        check auto "$p-y3: unchanged rerun by uid $Y installs offline" "$(r $p-y3 rc)" 0
        check auto "$p-x2: uid $X's partition still installs offline" "$(r $p-x2 rc)" 0
    fi
    check safety "$p: no EACCES/EPERM in any run" "$(sum_key eacces $p-x1 $p-y1 $p-y2 $p-y3 $p-x2)" 0
}
t2() {
    local o m img tag n sc
    for o in a b; do
        echo "   order $o: $([ $o = a ] && echo 'uid 0 then uid 1000' || echo 'uid 1000 then uid 0')"
        want_tool go && t2_go_seq $o q2-go-$o-$S t2-go-$o
        want_tool npm && t2_shared t2-npm-$o $o npm "$IMG_NODE" q2-npm-$o-$S npm ci ci-offline ci-offline none ci
        if want_tool pnpm; then
            for m in $PNPM_T2; do
                if [ "$m" -le 10 ]; then
                    t2_shared t2-pnpm$m-$o $o pnpm "$IMG_NODE" q2-pnpm$m-$o-$S pnpm install install-offline install-offline none install -e QPNPM=$m
                else
                    t2_shared t2-pnpm$m-$o $o pnpm "$IMG_NODE" q2-pnpm$m-$o-$S pnpm install install install on install -e QPNPM=$m
                    check auto "t2-pnpm$m-$o: <store>/v11/index.db is 0666 (so another uid can index)" "$(r t2-pnpm$m-$o-x2 pnpm_index_db_mode)" 666
                fi
            done
        fi
        want_tool yarn1 && t2_part t2-yarn1-$o $o yarn1 "$IMG_NODE" q2-yarn1-$o-$S yarn install-offline none
        want_tool yarn4 && t2_shared t2-yarn4-$o $o yarn4 "$IMG_NODE" q2-yarn4-$o-$S yarnberry install install-nonet install-nonet none install
        want_tool corepack && t2_shared t2-corepack-$o $o corepack "$IMG_NODE" q2-corepack-$o-$S corepack prepare nonet nonet-yarn none prepare-yarn
        if want_tool pip; then
            for img in $PIP_IMAGES; do
                tag=$(echo "$img" | tr -cd '0-9')
                t2_part t2-pip$tag-$o $o pip "$img" q2-pip$tag-$o-$S pip install on
            done
        fi
        want_tool uv && t2_shared t2-uv-$o $o uv "$IMG_UV" q2-uv-$o-$S uv install install-offline install-offline none install
        want_tool cargo && t2_shared t2-cargo-$o $o cargo "$IMG_RUST" q2-cargo-$o-$S cargo fetch build-offline build-offline none fetch
    done
    echo "   a root entrypoint that drops to uid 1000 (su), planned for root"
    sc=q2-drop-$S
    if want_tool go; then
        step t2-drop-go1 "$IMG_GO" drop1000 "$sc" on go build base -e "$GO_REQ_FLAGS" -e "$GO_LOCAL"
        check auto "t2-drop-go1: the dropped uid 1000 process builds into the scope" "rc=$(r t2-drop-go1 rc) uid=$(r t2-drop-go1 uid) store=$(under "$(r t2-drop-go1 store.gobuild)" "$(expect gobuild 0 "$sc")" && echo scope || echo "$(r t2-drop-go1 store.gobuild)")" "rc=0 uid=1000 store=scope"
        step t2-drop-go2 "$IMG_GO" drop1000 "$sc" none go build base -e "$GO_REQ_FLAGS" -e "$GO_NOPROXY" -e "$GO_LOCAL"
        check auto "t2-drop-go2: its second run hits fully" "$(hits_go t2-drop-go2)" "rc=0 compiles=0 downloads=0"
    fi
    if want_tool uv; then
        step t2-drop-uv1 "$IMG_UV" drop1000 "$sc" on uv install a
        step t2-drop-uv2 "$IMG_UV" drop1000 "$sc" none uv install-offline a
        check auto "t2-drop-uv: uv as the dropped uid installs, then installs offline" "$(r t2-drop-uv1 rc) $(r t2-drop-uv2 rc)" "0 0"
    fi
    if want_tool pip; then
        step t2-drop-pip1 "$IMG_PY" drop1000 "$sc" on pip install a
        step t2-drop-pip2 "$IMG_PY" drop1000 "$sc" on pip install a
        check auto "t2-drop-pip: pip as the dropped uid writes the u0 partition it was given, then hits" \
            "rc=$(r t2-drop-pip1 rc) store=$(under "$(r t2-drop-pip1 store.pip)" "$(expect pip 0 "$sc")" && echo u0 || echo "$(r t2-drop-pip1 store.pip)") rerun_downloading=$(r t2-drop-pip2 downloading)" \
            "rc=0 store=u0 rerun_downloading=0"
    fi
    if want_tool npm; then # a user name, not a number (resolved from the image's passwd)
        n=t2-user-node
        build_args "$IMG_NODE" node q2-npm-a-$S none -e QX=1
        run_container $n "$IMG_NODE" "${RUNARGS[@]}" -- sh /q/qprobe.sh $n npm ci-offline a
        if [ -f "$QR/$n.res" ]; then
            check engine "$n: --user node starts, runs as uid 1000 and hits the store" "rc=$(r $n rc) uid=$(r $n uid)" "rc=0 uid=1000"
        else # the create was refused: show the engine's answer
            check engine "$n: --user node starts, runs as uid 1000 and hits the store" \
                "no result file; docker: $(tail -c 160 "$QR/$n.stdout" | tr '\n' ' ')" "rc=0 uid=1000"
        fi
    fi
}
# --- NC negative controls ----------------------------------------------------------
if want_section NC; then
    section NC "negative controls: the assertions detect misses"
    if want_tool go; then
        echo "   NC1: T2-Go on hand-wired stores without the default ACL (the old 1777 layout)"
        begin_ctx nc1
        FORCE_MANUAL=1 PREP_MODE=noacl t2_go_seq a nc1-$S nc1
        end_ctx
        # The measured signature: the rerun exits 0 but compiles again, and the
        # one-file change stored nothing, because root's shards are 0755.
        nc1_third=$(ctx_got nc1 'third run')
        checkp control "NC1: without the ACL the T2-Go detector reports the silent miss (third run fails with rc=0 and compiles>0)" \
            "$nc1_third" "a failing third-run check showing rc=0 and compiles>0" \
            "$(ok test "$(ctx_failed nc1 'third run' && echo y)$(echo "$nc1_third" | grep -Eq '^rc=0 compiles=[1-9]' && echo y)" = yy)"
        checkp control "NC1: …and the one-file change check reports that uid 1000 stored no entries" \
            "$(ctx_got nc1 "one-file change")" "a failing check showing gobuild_new=0" \
            "$(ok test "$(ctx_failed nc1 'one-file change' && echo y)$(ctx_got nc1 'one-file change' | grep -q 'gobuild_new=0$' && echo y)" = yy)"
        checkp control "NC1: …and the directory scan reports gobuild shards without 0777" "$(ctx_got nc1 'no gobuild directory lacks')" \
            "a failing scan with a count >0" "$(ok ctx_failed nc1 'no gobuild directory lacks')"
        echo "   NC2: io.micropod.cache=off"
        step nc2-go-cold "$IMG_GO" 0 - on go build base --label io.micropod.cache=off -e "$GO_REQ_FLAGS" -e "$GO_LOCAL"
        step nc2-go-warm "$IMG_GO" 0 - on go build base --label io.micropod.cache=off -e "$GO_REQ_FLAGS" -e "$GO_LOCAL"
        checkp control "NC2: with io.micropod.cache=off the warm run in a new container compiles again" \
            "rc=$(r nc2-go-warm rc) compiles=$(r nc2-go-warm compiles)" "rc=0 compiles>0" \
            "$(ok test "$(r nc2-go-warm rc)" = 0 -a "$(gt0 "$(r nc2-go-warm compiles)" && echo y)" = y)"
    fi
    if want_tool pip; then
        for img in python:3.11-alpine python:3.10-alpine; do
            tag=$(echo "$img" | tr -cd '0-9')
            if manual; then # hand-wired: PIP_CACHE_DIR forced to the ACL'd u0 partition for both uids
                sc=nc3-$tag-$S nc3_args=(-e PIP_CACHE_DIR=/micropod/cache/pip/u0) nc3_store=$(expect pip 0 "$sc")
                echo "   NC3: $img with a shared pip store (PIP_CACHE_DIR forced to u0 for both uids)"
            else # the engine's qualification hook: one shared pip store (root 0777 + default ACL) for both uids
                sc=qual-nc3-$tag-$S nc3_args=(--label io.micropod.cache.debug-shared=pip) nc3_store=$CACHE_ROOT/scopes/qual-nc3-$tag-$S/pip
                echo "   NC3: $img with a shared pip store (io.micropod.cache.debug-shared=pip on a qual- scope)"
            fi
            "$DOCKER" image inspect "$img" >/dev/null 2>&1 || "$DOCKER" pull -q "$img" >>"$OUT/pull.log" 2>&1
            step nc3-$tag-x "$img" 0 "$sc" on pip install a "${nc3_args[@]}"
            step nc3-$tag-y "$img" 1000 "$sc" on pip install a "${nc3_args[@]}"
            # Conclusive only when the forced store really is the one shared unit.
            if under "$(r nc3-$tag-y store.pip)" "$nc3_store"; then
                checkp control "NC3 $img ($(r nc3-$tag-y version | cut -d' ' -f1-2)): uid 1000 on root's shared pip store re-downloads silently (Downloading>0, rc=0)" \
                    "rc=$(r nc3-$tag-y rc) downloading=$(r nc3-$tag-y downloading) using_cached=$(r nc3-$tag-y using_cached)" "rc=0 downloading>0" \
                    "$(ok test "$(r nc3-$tag-y rc)" = 0 -a "$(gt0 "$(r nc3-$tag-y downloading)" && echo y)" = y)"
            else
                checkp control "NC3 $img: the forced shared pip store is attached (otherwise the control is inconclusive)" \
                    "$(r nc3-$tag-y store.pip)" "under $nc3_store" 0
            fi
        done
    fi
    if want_tool pnpm; then
        echo "   NC4: pnpm 12 on a hand-wired store without the pre-created 0666 index.db"
        sc=nc4-$S
        FORCE_MANUAL=1 PREP_INDEX=no-pnpm-index step nc4-x1 "$IMG_NODE" 0 "$sc" on pnpm install a -e QPNPM=12
        FORCE_MANUAL=1 step nc4-y1 "$IMG_NODE" 1000 "$sc" on pnpm install b -e QPNPM=12
        FORCE_MANUAL=1 step nc4-x2 "$IMG_NODE" 0 "$sc" on pnpm install b -e QPNPM=12
        checkp control "NC4: uid 1000's add is not indexed (index.db $(r nc4-x1 pnpm_index_db_mode)), so root's frozen install re-downloads" \
            "rc=$(r nc4-x2 rc) downloaded=$(r nc4-x2 downloaded)" "rc=0 downloaded>0" \
            "$(ok test "$(r nc4-x2 rc)" = 0 -a "$(gt0 "$(r nc4-x2 downloaded)" && echo y)" = y)"
    fi
fi

if want_section T2; then
    section T2 "both uid orders on golang, node, python and rust images"
    t2
fi

# --- builds (shared by T3's prewarmed images and T6) ----------------------------------
GRPC=""
grpc_probe() { # the probe buildx's docker driver makes: POST /grpc, Upgrade: h2c
    python3 - "$SOCK" <<'PY' 2>/dev/null || echo error
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(10)
s.connect(sys.argv[1])
s.sendall(b"POST /grpc HTTP/1.1\r\nHost: d\r\nConnection: Upgrade\r\nUpgrade: h2c\r\nContent-Length: 0\r\n\r\n")
print(s.recv(128).split(b" ")[1].decode())
PY
}
remote_builder() { # a harness-owned remote builder on run/buildkit.sock (throwaway DOCKER_CONFIG)
    [ -n "$BUILDER" ] && return 0
    "$DOCKER" buildx create --name "qual-remote-$S" --driver remote --driver-opt default-load=true \
        "unix://$ROOT_DIR/run/buildkit.sock" >"$QR/builder-create.log" 2>&1 && BUILDER="qual-remote-$S"
}
# qbuild LOG [docker build args…]: stock `docker build` when /grpc upgrades,
# else (or with hand wiring) through the harness's remote builder.
qbuild() {
    local log=$1
    shift
    [ -n "$GRPC" ] || GRPC=$(grpc_probe)
    if [ "$MANUAL" != 1 ] && [ "$GRPC" = 101 ]; then
        "$DOCKER" build --progress=plain "$@" >"$log" 2>&1
    else
        remote_builder || return 1
        BUILDX_BUILDER="$BUILDER" "$DOCKER" build --progress=plain "$@" >"$log" 2>&1
    fi
}

# --- T3 precedence --------------------------------------------------------------------
# An untrusted container (io.micropod.cache.trust=untrusted) reads the trusted
# stores warm through copy-on-write views and never writes them: its one-file
# change compiles, a trusted container then compiles the same change again
# (the untrusted entry never reached the store), and the next untrusted
# build hits the trusted entry.
t3_untrusted() {
    local sc=q3t-$S u="--label io.micropod.cache.trust=untrusted" n
    step t3-trust-fill "$IMG_GO" 0 "$sc" on go build base -e "$GO_REQ_FLAGS" -e "$GO_LOCAL"
    check safety "t3-trust-fill: a trusted cold build fills the scope" "$(r t3-trust-fill rc)" 0
    n=t3-untrusted-edit
    step $n "$IMG_GO" 0 "$sc" none go build base -e QEDIT=$n-$S -e "$GO_REQ_FLAGS" -e "$GO_NOPROXY" -e "$GO_LOCAL" $u
    checkp auto "$n: an untrusted one-file change builds warm offline (it compiles, downloads nothing)" "$(hits_go $n)" "rc=0 compiles>0 downloads=0" \
        "$(ok test "$(r $n rc)/$(r $n downloads)" = 0/0 -a "$(gt0 "$(r $n compiles)" && echo y)" = y)"
    check engine "$n: inspect shows trust=untrusted and gomod, gobuild copy-on-write" \
        "trust=$(insp $n "(c.get('MicropodCache') or {}).get('trust')") gomod=$(mc $n gomod access) gobuild=$(mc $n gobuild access)" \
        "trust=untrusted gomod=copy-on-write gobuild=copy-on-write"
    step t3-trusted-edit "$IMG_GO" 0 "$sc" none go build base -e QEDIT=$n-$S -e "$GO_REQ_FLAGS" -e "$GO_NOPROXY" -e "$GO_LOCAL"
    check auto "t3-trusted-edit: the untrusted compile never reached the trusted store (a trusted build of the same change compiles it again)" \
        "$(hits_go t3-trusted-edit)" "rc=0 compiles=$(r $n compiles) downloads=0"
    step t3-untrusted-again "$IMG_GO" 0 "$sc" none go build base -e QEDIT=$n-$S -e "$GO_REQ_FLAGS" -e "$GO_NOPROXY" -e "$GO_LOCAL" $u
    check auto "t3-untrusted-again: the next untrusted build reads the trusted entry warm" "$(hits_go t3-untrusted-again)" "rc=0 compiles=0 downloads=0"
}
t3() {
    local sc=q3-$S n
    # Hand wiring has no trust tier (QUAL_MANUAL_WIRING=1): nothing to show.
    want_tool go && [ "$MANUAL" != 1 ] && t3_untrusted
    step t3-control "$IMG_GO" 0 "$sc" on go env base
    local base_ok=0
    [ "$(has_cache_mount t3-control)" = True ] && [ "$(r t3-control goenv.GOMODCACHE)" = /micropod/cache/gomod ] && base_ok=1
    check engine "t3-control: a plain golang container gets the /micropod/cache mount, GOMODCACHE and MicropodCache.tools.gomod.mode=env" \
        "mount=$(has_cache_mount t3-control) GOMODCACHE=$(r t3-control goenv.GOMODCACHE) mode=$(mc t3-control gomod mode)" \
        "mount=True GOMODCACHE=/micropod/cache/gomod mode=env"
    # Negative-form checks ("nothing attached") prove something only when the
    # same engine attaches by default: without the control they fail.
    gcheck() { # gcheck LABEL GOT WANT
        if [ "$base_ok" = 1 ]; then check engine "$1" "$2" "$3"; else checkp engine "$1" "inconclusive, the attach control failed: $2" "'$3' with the control attaching" 0; fi
    }
    # Images with baked caches (built through whichever build path works).
    mkdir -p "$TMP/prewarm" && cp -R "$FIX/." "$TMP/prewarm/"
    qbuild "$QR/t3-build-go.log" -t "qual-prewarm-go:$S" -f "$TMP/prewarm/prewarm/Dockerfile.go" "$TMP/prewarm"
    check harness "t3: built qual-prewarm-go (go mod download and go build baked in)" "$?" 0
    qbuild "$QR/t3-build-node.log" -t "qual-prewarm-node:$S" -f "$TMP/prewarm/prewarm/Dockerfile.node" "$TMP/prewarm"
    check harness "t3: built qual-prewarm-node (npm ci and corepack prepare baked in)" "$?" 0
    n=t3-prewarm-go
    step $n "qual-prewarm-go:$S" 0 "$sc" none go prewarm a -e "$GO_REQ_FLAGS" -e "$GO_NOPROXY" -e "$GO_LOCAL"
    check safety "$n: the baked module cache serves an offline build" "rc=$(r $n rc) downloads=$(r $n downloads)" "rc=0 downloads=0"
    check engine "$n: inspect reports gomod and gobuild image-prewarmed" "$(mc $n gomod reason) $(mc $n gobuild reason)" "image-prewarmed image-prewarmed"
    gcheck "$n: GOMODCACHE stays unset in Config.Env and in the container" \
        "config=$(insp $n "any(e.startswith('GOMODCACHE=') for e in (c.get('Config') or {}).get('Env') or [])") env=$(r $n env.GOMODCACHE)" "config=False env=__unset__"
    n=t3-prewarm-npm
    step $n "qual-prewarm-node:$S" 0 "$sc" none npm prewarm a
    check engine "$n: npm ci --offline from the baked cache, npm reason image-prewarmed" "rc=$(r $n rc) reason=$(mc $n npm reason)" "rc=0 reason=image-prewarmed"
    n=t3-prewarm-corepack
    step $n "qual-prewarm-node:$S" 0 "$sc" none corepack prewarm a
    check engine "$n: the prepared pnpm runs offline, corepack reason image-prewarmed" "rc=$(r $n rc) reason=$(mc $n corepack reason)" "rc=0 reason=image-prewarmed"
    # Images that set their own cache locations, or turn one off themselves.
    qbuild "$QR/t3-build-goenv.log" -t "qual-goenv:$S" -f "$TMP/prewarm/prewarm/Dockerfile.goenv" "$TMP/prewarm"
    check harness "t3: built qual-goenv (its own ENV GOCACHE and GOMODCACHE)" "$?" 0
    qbuild "$QR/t3-build-pipoff.log" -t "qual-pipoff:$S" -f "$TMP/prewarm/prewarm/Dockerfile.pipoff" "$TMP/prewarm"
    check harness "t3: built qual-pipoff (ENV PIP_NO_CACHE_DIR=1)" "$?" 0
    n=t3-imgenv-cold
    step $n "qual-goenv:$S" 0 "$sc" on go build base -e "$GO_REQ_FLAGS"
    check engine "$n: the image's own GOCACHE and GOMODCACHE are kept, and the scope's stores are bound at those paths" \
        "GOCACHE=$(r $n goenv.GOCACHE) GOMODCACHE=$(r $n goenv.GOMODCACHE) modes=$(mc $n gobuild mode),$(mc $n gomod mode) stores=$(under "$(r $n store.gobuild)" "$(expect gobuild 0 "$sc")" && under "$(r $n store.gomod)" "$(expect gomod 0 "$sc")" && echo scope || echo "$(r $n store.gobuild),$(r $n store.gomod)")" \
        "GOCACHE=/opt/qual/gocache GOMODCACHE=/opt/qual/gomod modes=path,path stores=scope"
    # inspect lists the image's environment under the container's, as Docker's does.
    gcheck "$n: …and Config.Env shows the image's own values, never the engine's" \
        "$(insp $n "sorted(e for e in (c.get('Config') or {}).get('Env') or [] if e.split('=')[0] in ('GOCACHE', 'GOMODCACHE'))")" "['GOCACHE=/opt/qual/gocache', 'GOMODCACHE=/opt/qual/gomod']"
    n=t3-imgenv-warm
    step $n "qual-goenv:$S" 0 "$sc" none go build base -e "$GO_REQ_FLAGS" -e "$GO_NOPROXY"
    check auto "$n: a new container of that image, another checkout, --network none, hits the stores at the image's paths" "$(hits_go $n)" "rc=0 compiles=0 downloads=0"
    n=t3-imgoff
    step $n "qual-pipoff:$S" 0 "$sc" on env env a
    gcheck "$n: an image with PIP_NO_CACHE_DIR=1 keeps pip's cache off (disabled-by-image, no PIP_CACHE_DIR; the other tools still attach)" \
        "reason=$(mc $n pip reason) PIP_CACHE_DIR=$(r $n env.PIP_CACHE_DIR) mount=$(has_cache_mount $n)" "reason=disabled-by-image PIP_CACHE_DIR=__unset__ mount=True"
    # The user's own cache choices are kept, and the store does not change.
    step t3-count0 "$IMG_GO" 0 "$sc" on go count base
    n=t3-uvol
    step $n "$IMG_GO" 0 "$sc" on go build base -v "qual-mygo-$S:/root/.cache/go-build" -e "$GO_REQ_FLAGS" -e "$GO_LOCAL"
    echo "qual-mygo-$S" >>"$QW/volumes.list"
    check engine "$n: -v mygo:/root/.cache/go-build gives gobuild reason user-mount" "$(mc $n gobuild reason)" user-mount
    gcheck "$n: …and the build's entries land in the user's volume" \
        "store=$(under "$(r $n store.gobuild)" "$VOL_ROOT/qual-mygo-$S" && echo user-volume || r $n store.gobuild) new=$(gt0 "$(r $n new_by_me.gobuild)" && echo yes || echo no)" "store=user-volume new=yes"
    n=t3-uhome
    step $n "$IMG_GO" 0 "$sc" on go build base -v "qual-home-$S:/root" -e "$GO_REQ_FLAGS" -e "$GO_LOCAL"
    echo "qual-home-$S" >>"$QW/volumes.list"
    check engine "$n: -v home:/root (an ancestor of the gobuild default) skips gobuild, gomod still attaches" "$(mc $n gobuild reason) $(mc $n gomod mode)" "user-mount env"
    n=t3-uenv
    step $n "$IMG_GO" 0 "$sc" on go build base -e GOCACHE=/tmp/x -e "$GO_REQ_FLAGS" -e "$GO_LOCAL" # guard:guest
    check engine "$n: a request GOCACHE (/tmp/x) is kept, reason user-env" "$(r $n goenv.GOCACHE) $(mc $n gobuild reason)" "/tmp/x user-env"
    step t3-count1 "$IMG_GO" 0 "$sc" on go count base
    checkp_on engine "t3: the gobuild store's file count is unchanged by the three user-choice runs" t3-count1 gobuild "$(expect gobuild 0 "$sc")" \
        "before=$(r t3-count0 files.gobuild) after=$(r t3-count1 files.gobuild)" "equal" \
        "$(ok test "$(r t3-count0 files.gobuild)" = "$(r t3-count1 files.gobuild)")"
    # Opt-outs.
    n=t3-off-label
    step $n "$IMG_GO" 0 - on go env base --label io.micropod.cache=off
    gcheck "$n: label io.micropod.cache=off: no cache mount and no injected env" \
        "mount=$(has_cache_mount $n) GOMODCACHE=$(r $n env.GOMODCACHE) npm=$(r $n env.npm_config_cache)" "mount=False GOMODCACHE=__unset__ npm=__unset__"
    n=t3-off-env
    step $n "$IMG_GO" 0 - on go env base -e MICROPOD_CACHE=off
    gcheck "$n: request env MICROPOD_CACHE=off: no cache mount and no injected env" \
        "mount=$(has_cache_mount $n) GOMODCACHE=$(r $n env.GOMODCACHE)" "mount=False GOMODCACHE=__unset__"
    n=t3-off-alias
    step $n "$IMG_GO" 0 - on go env base --label micropod.cache.shared=false
    gcheck "$n: alias label micropod.cache.shared=false opts out too" "mount=$(has_cache_mount $n)" "mount=False"
    # Scope validation answers 400; never a silent fallback.
    local err cid
    err=$("$DOCKER" create --label "qual-run=$S" --label 'io.micropod.cache.scope=Bad!Scope' "$IMG_BASE" true 2>&1)
    cid=$(echo "$err" | grep -E '^[0-9a-f]{64}$')
    [ -n "$cid" ] && "$DOCKER" rm -f "$cid" >/dev/null 2>&1
    checkp engine "t3: an invalid scope name is refused with HTTP 400" "$(echo "$err" | tail -1)" "contains 'cache scope not allowed by machine policy'" \
        "$(ok test -z "$cid" -a "$(echo "$err" | grep -c 'cache scope not allowed by machine policy')" -ge 1)"
    err=$("$DOCKER" create --label "qual-run=$S" --label 'io.micropod.cache=go,notatool' "$IMG_BASE" true 2>&1)
    cid=$(echo "$err" | grep -E '^[0-9a-f]{64}$')
    [ -n "$cid" ] && "$DOCKER" rm -f "$cid" >/dev/null 2>&1
    checkp engine "t3: an unknown tool in io.micropod.cache is refused (400)" "$(echo "$err" | tail -1)" "a refused create" "$(ok test -z "$cid")"
    if "$M" machine cache policy show >"$QR/t3-policy-show.log" 2>&1; then
        "$M" machine cache policy --allow-scopes "q3-*,default" >"$QR/t3-policy-set.log" 2>&1
        sleep 3 # the engine re-reads the policy at most every 2 s
        err=$("$DOCKER" create --label "qual-run=$S" --label "io.micropod.cache.scope=other-$S" "$IMG_BASE" true 2>&1)
        cid=$(echo "$err" | grep -E '^[0-9a-f]{64}$')
        [ -n "$cid" ] && "$DOCKER" rm -f "$cid" >/dev/null 2>&1
        "$M" machine cache policy --allow-scopes '*' >>"$QR/t3-policy-set.log" 2>&1
        checkp cli "t3: a scope outside the policy allow-list is refused with HTTP 400" "$(echo "$err" | tail -1)" \
            "contains 'cache scope not allowed by machine policy'" "$(ok test -z "$cid" -a "$(echo "$err" | grep -c 'cache scope not allowed')" -ge 1)"
    else
        check cli "t3: \`micropod machine cache policy\` exists (needed for the allow-list check)" "$(tail -1 "$QR/t3-policy-show.log")" "a policy"
    fi
    # GOFLAGS merge.
    n=t3-goflags-default
    step $n "$IMG_GO" 0 "$sc" on go env base
    check engine "$n: no request GOFLAGS → GOFLAGS=-trimpath" "$(r $n goenv.GOFLAGS)" -trimpath
    n=t3-goflags-vendor
    step $n "$IMG_GO" 0 "$sc" on go env base -e GOFLAGS=-mod=vendor # guard:guest
    check engine "$n: -mod=vendor is kept and -trimpath appended" "$(r $n goenv.GOFLAGS)" "-mod=vendor -trimpath"
    n=t3-goflags-false
    step $n "$IMG_GO" 0 "$sc" on go env base -e GOFLAGS=-trimpath=false # guard:guest
    gcheck "$n: an explicit -trimpath=false wins" "$(r $n goenv.GOFLAGS)" -trimpath=false
    n=t3-goflags-label
    step $n "$IMG_GO" 0 "$sc" on go env base --label io.micropod.cache.go-trimpath=false
    gcheck "$n: label io.micropod.cache.go-trimpath=false stops the merge" "goflags='$(r $n goenv.GOFLAGS)' mount=$(has_cache_mount $n)" "goflags='' mount=True"
    # A non-toolchain image: only the scope bind, never path-mode binds.
    n=t3-postgres
    step $n "$IMG_PG" 0 "$sc" on env env a
    check engine "$n: postgres:alpine gets exactly one cache mount, at /micropod/cache" \
        "$(insp $n "sorted(m.get('Destination') for m in (c.get('Mounts') or []) if str(m.get('Name','')).startswith('micropod-cache'))")" "['/micropod/cache']"
    check engine "$n: yarn, yarnberry and cargo are not-installed" "$(mc $n yarn reason) $(mc $n yarnberry reason) $(mc $n cargo reason)" \
        "not-installed not-installed not-installed"
}
if want_section T3; then
    section T3 "precedence: the engine leaves the user's and the image's choices alone"
    if [ "$MANUAL" = 1 ]; then
        echo "  - T3 checks the engine's attach decisions; hand wiring has nothing to stand in for (not run)"
        SKIP=$((SKIP + 1))
    else
        t3
    fi
fi

# --- T4 concurrency ---------------------------------------------------------------------
t4() {
    # yarn v1's exclusive lease is taken by every container whose image has
    # node on PATH, the eight pnpm containers here included, so the yarn
    # writers race each other in a scope of their own.
    local sc=q4-$S scy=q4y-$S bar=t4-barrier-$S i n names_go="" names_pnpm="" names_yarn="" names_cargo="" names_uv="" names_npm="" running deadline
    DETACHED=()
    BG=1
    if want_tool go; then for i in 1 2 3 4 5 6 7 8; do step t4-go-$i "$IMG_GO" 0 "$sc" on go build base -e QWAIT=$bar -e "$GO_REQ_FLAGS" -e "$GO_LOCAL"; names_go="$names_go t4-go-$i"; done; fi
    if want_tool pnpm; then for i in 1 2 3 4 5 6 7 8; do step t4-pnpm-$i "$IMG_NODE" 0 "$sc" on pnpm install a -e QWAIT=$bar -e QPNPM=10; names_pnpm="$names_pnpm t4-pnpm-$i"; done; fi
    if want_tool yarn1; then
        for i in 1 2 3 4; do # hand wiring stands in for the engine's exclusive lease: only #1 gets the store
            NO_YARN=$([ "$MANUAL" = 1 ] && [ $i -gt 1 ] && echo 1 || echo 0) step t4-yarn1-$i "$IMG_NODE" 0 "$scy" on yarn1 install a -e QWAIT=$bar
            names_yarn="$names_yarn t4-yarn1-$i"
        done
    fi
    if want_tool cargo; then for i in 1 2 3 4; do step t4-cargo-$i "$IMG_RUST" 0 "$sc" on cargo fetch a -e QWAIT=$bar; names_cargo="$names_cargo t4-cargo-$i"; done; fi
    if want_tool uv; then for i in 1 2 3 4; do step t4-uv-$i "$IMG_UV" 0 "$sc" on uv install a -e QWAIT=$bar; names_uv="$names_uv t4-uv-$i"; done; fi
    if want_tool npm; then for i in 1 2 3 4; do step t4-npm-$i "$IMG_NODE" 0 "$sc" on npm ci a -e QWAIT=$bar; names_npm="$names_npm t4-npm-$i"; done; fi
    BG=0
    deadline=$((SECONDS + 300))
    while :; do
        running=$("$DOCKER" ps -q --filter "label=qual-run=$S" 2>/dev/null | wc -l | tr -d ' ')
        [ "$running" -ge "${#DETACHED[@]}" ] || [ "$SECONDS" -ge "$deadline" ] && break
        sleep 0.5
    done
    check harness "t4: all ${#DETACHED[@]} containers were running before the barrier opened" "$running" "${#DETACHED[@]}"
    touch "$QR/$bar"
    for n in "${DETACHED[@]}"; do collect "$n"; done
    rcs() { local x out=""; for x in "$@"; do out="$out $(r $x rc)"; done; echo "${out# }"; }
    rep() { local i out=""; for i in $(seq 1 "$1"); do out="$out $2"; done; echo "${out# }"; }
    on_store() { local x c=0; local label=$1 e=$2; shift 2; for x in "$@"; do under "$(r $x store.$label)" "$e" && c=$((c + 1)); done; echo $c; }
    if want_tool go; then
        check safety "t4: 8 concurrent cold go builds on one scope all exit 0" "$(rcs $names_go)" "$(rep 8 0)"
        check auto "t4: …all 8 used the scope's gobuild store" "$(on_store gobuild "$(expect gobuild 0 "$sc")" $names_go)" 8
        step t4-go-verify "$IMG_GO" 0 "$sc" none go verify base -e "$GO_REQ_FLAGS" -e "$GO_NOPROXY" -e "$GO_LOCAL"
        check_on auto "t4-go-verify: go mod verify says 'all modules verified'" t4-go-verify gomod "$(expect gomod 0 "$sc")" "rc=$(r t4-go-verify rc) verified=$(r t4-go-verify verify_ok)" "rc=0 verified=1"
        step t4-go-warm "$IMG_GO" 0 "$sc" none go build base -e "$GO_REQ_FLAGS" -e "$GO_NOPROXY" -e "$GO_LOCAL"
        check auto "t4-go-warm: the warm rerun hits fully" "$(hits_go t4-go-warm)" "rc=0 compiles=0 downloads=0"
    fi
    if want_tool pnpm; then
        check safety "t4: 8 concurrent pnpm 10 installs all exit 0" "$(rcs $names_pnpm)" "$(rep 8 0)"
        check auto "t4: …all 8 used the scope's pnpm store" "$(on_store pnpm "$(expect pnpm 0 "$sc")" $names_pnpm)" 8
        step t4-pnpm-status "$IMG_NODE" 0 "$sc" on pnpm store-status a -e QPNPM=10
        check_on auto "t4-pnpm-status: pnpm store status is clean after the concurrent writers" t4-pnpm-status pnpm "$(expect pnpm 0 "$sc")" "rc=$(r t4-pnpm-status rc) status=$(r t4-pnpm-status store_status_rc)" "rc=0 status=0"
        step t4-pnpm-warm "$IMG_NODE" 0 "$sc" none pnpm install-offline a -e QPNPM=10
        check auto "t4-pnpm-warm: offline install downloads nothing" "rc=$(r t4-pnpm-warm rc) downloaded=$(r t4-pnpm-warm downloaded)" "rc=0 downloaded=0"
    fi
    if want_tool yarn1; then
        # One container wins yarn v1's writer slot; the other three hold the
        # store too and read it through copy-on-write views of their own.
        local nwriter=0 ncow=0 nbusy=0 x
        for x in $names_yarn; do
            [ "$(mc $x yarn mode)" = path ] && [ "$(mc $x yarn access)" = None ] && nwriter=$((nwriter + 1))
            [ "$(mc $x yarn access)" = copy-on-write ] && ncow=$((ncow + 1))
            [ "$(mc $x yarn reason)" = busy-exclusive ] && nbusy=$((nbusy + 1))
        done
        check safety "t4: 4 concurrent yarn 1 installs all exit 0" "$(rcs $names_yarn)" "0 0 0 0"
        check auto "t4: exactly one yarn 1 container wrote the shared store (exclusive writer slot)" "$(on_store yarn "$(expect yarn 0 "$scy")" $names_yarn)" 1
        check engine "t4: inspect shows one yarn 1 writer and three copy-on-write readers" "writer=$nwriter cow=$ncow busy=$nbusy" "writer=1 cow=3 busy=0"
        step t4-yarn1-warm "$IMG_NODE" 0 "$scy" none yarn1 install-offline a
        check auto "t4-yarn1-warm: a later yarn install --offline hits" "$(r t4-yarn1-warm rc)" 0
    fi
    if want_tool cargo; then
        local inos="" x blocked=0
        for x in $names_cargo; do inos="$inos $(r $x lock_ino_before) $(r $x lock_ino_after)"; gt0 "$(r $x blocking)" && blocked=$((blocked + 1)); done
        check safety "t4: 4 concurrent cargo fetches all exit 0" "$(rcs $names_cargo)" "0 0 0 0"
        checkp auto "t4: at least one fetch waited on the shared package-cache lock ('Blocking waiting for file lock')" "$blocked of 4" ">=1" "$(ok test "$blocked" -ge 1)"
        checkp auto "t4: \$CARGO_HOME/.package-cache kept one inode before and after in every container" "$inos" "one value, not absent" \
            "$(ok test "$(echo $inos | tr ' ' '\n' | sort -u | wc -l | tr -d ' ')" = 1 -a "$(echo $inos | cut -d' ' -f1)" != absent)"
        step t4-cargo-warm "$IMG_RUST" 0 "$sc" none cargo build-offline a
        check auto "t4-cargo-warm: cargo build --offline after the concurrent fetches" "$(r t4-cargo-warm rc)" 0
    fi
    if want_tool uv; then
        check safety "t4: 4 concurrent uv installs all exit 0" "$(rcs $names_uv)" "0 0 0 0"
        step t4-uv-warm "$IMG_UV" 0 "$sc" none uv install-offline a
        check auto "t4-uv-warm: uv pip install --offline hits" "$(r t4-uv-warm rc)" 0
    fi
    if want_tool npm; then
        check safety "t4: 4 concurrent npm ci all exit 0" "$(rcs $names_npm)" "0 0 0 0"
        step t4-npm-verify "$IMG_NODE" 0 "$sc" on npm cache-verify a
        check_store auto t4-npm-verify npm "$(expect npm 0 "$sc")"
        check_on auto "t4-npm-verify: npm cache verify passes on the scope store" t4-npm-verify npm "$(expect npm 0 "$sc")" "$(r t4-npm-verify rc)" 0
        step t4-npm-warm "$IMG_NODE" 0 "$sc" none npm ci-offline a
        check auto "t4-npm-warm: npm ci --offline hits" "$(r t4-npm-warm rc)" 0
    fi
}
if want_section T4; then
    section T4 "concurrency on one scope (all writers released by one barrier)"
    t4
fi

# --- T5 restart and kill -9 ---------------------------------------------------------------
t5() {
    restart_machine t5
    check harness "t5: machine stop/start, engine answers again" "$(ping_engine && echo up || echo down)" up
    if want_section T1; then
        echo "   T1 warm assertions after the restart"
        t1_warm t5
    else
        echo "   (T1 not selected: no warm stores to replay after the restart)"
    fi
    echo "   kill -9 of the VMM during a cold go mod download, with a cold pnpm install's units still held"
    local sc=q5-$S deadline vmm gets prog inflight pn
    DETACHED=()
    BG=1
    # Both fixtures finish in about 2 s, so they rarely overlap by chance. pnpm
    # starts first and keeps its container (and so its units, fresh writes and
    # dirty marks) for QHOLD seconds after it finishes; go starts once pnpm has
    # progressed and the VMM dies while go is still downloading.
    want_tool pnpm && step t5-kill-pnpm "$IMG_NODE" 0 "$sc" on pnpm install big -e QSTREAM=1 -e QPNPM=10 -e QHOLD=90
    deadline=$((SECONDS + 120))
    while want_tool pnpm && [ "$SECONDS" -lt "$deadline" ]; do
        prog=$(grep -c 'resolved' "$QR/t5-kill-pnpm.progress" 2>/dev/null)
        { ge "$prog" 1 || [ -f "$QR/t5-kill-pnpm.res" ]; } && break
        sleep 0.1
    done
    want_tool go && step t5-kill-go "$IMG_GO" 0 "$sc" on go download big -e QSTREAM=1 -e "$GO_REQ_FLAGS" -e "$GO_LOCAL"
    BG=0
    deadline=$((SECONDS + 120))
    while want_tool go && [ "$SECONDS" -lt "$deadline" ]; do
        gets=$(grep -c '^# get' "$QR/t5-kill-go.progress" 2>/dev/null)
        { ge "$gets" 3 || [ -f "$QR/t5-kill-go.res" ]; } && break
        sleep 0.05
    done
    pn=$({ ! want_tool pnpm && echo skipped; } || { [ ! -f "$QR/t5-kill-pnpm.res" ] && echo in-flight; } ||
        { [ "$("$DOCKER" inspect -f '{{.State.Running}}' "q$S-t5-kill-pnpm" 2>/dev/null)" = true ] && echo holding; } || echo exited)
    inflight="go=$({ ! want_tool go && echo skipped; } || { [ -f "$QR/t5-kill-go.res" ] && echo finished; } || echo in-flight)"
    vmm=$(state "s['vmmPID']")
    if [ -n "$vmm" ] && ps -o command= -p "$vmm" 2>/dev/null | grep -q -- "^$ROOT_DIR/micropod-vmm "; then
        kill -9 "$vmm"
    fi
    echo "    at the kill: $inflight pnpm=$pn"
    case $pn in in-flight | holding) pn=held ;; esac
    check harness "t5: the VMM ($vmm) was killed while go was downloading and pnpm's container still held its units" "$inflight pnpm=$pn" "go=$(want_tool go && echo in-flight || echo skipped) pnpm=$(want_tool pnpm && echo held || echo skipped)"
    deadline=$((SECONDS + 180))
    until [ "$(state "s['phase']=='running' and s['vmmPID']!=$vmm")" = True ] && ping_engine; do
        [ "$SECONDS" -lt "$deadline" ] || break
        sleep 0.5
    done
    check harness "t5: the supervisor relaunched the VMM and the engine answers" "$(ping_engine && echo up || echo down)" up
    local discarded
    # stats=0: the recovery report without the per-unit size walk, which on a
    # cold page cache right after the relaunch can outlast the timeout.
    discarded=$(curl -s -m 5 --unix-socket "$SOCK" 'http://d/micropod/caches?stats=0' | python3 -c "import json, sys; print(' '.join(json.load(sys.stdin).get('discardedAtStart') or []))" 2>/dev/null)
    echo "    units the engine discarded at start: ${discarded:-none}"
    local want_disc="" got_disc=""
    want_tool go && want_disc="gomod" && got_disc=$(words "$discarded" "$sc/gomod" && echo gomod || echo none)
    want_tool pnpm && want_disc="$want_disc pnpm" && got_disc="$got_disc $(words "$discarded" "$sc/pnpm" && echo pnpm || echo none)"
    check engine "t5: the engine discarded the units the kill caught with unsynced writes" "${got_disc# }" "${want_disc# }"
    "$DOCKER" rm -f "q$S-t5-kill-go" "q$S-t5-kill-pnpm" >/dev/null 2>&1
    if want_tool go; then
        step t5-go-verify "$IMG_GO" 0 "$sc" on go verify big -e "$GO_REQ_FLAGS" -e "$GO_LOCAL"
        check_on auto "t5-go-verify: go mod verify of the scope store after the crash" t5-go-verify gomod "$(expect gomod 0 "$sc")" "rc=$(r t5-go-verify rc) verified=$(r t5-go-verify verify_ok)" "rc=0 verified=1"
        check_store auto t5-go-verify gomod "$(expect gomod 0 "$sc")"
        step t5-go-next "$IMG_GO" 0 "$sc" on go build big -e "$GO_REQ_FLAGS" -e "$GO_LOCAL"
        check safety "t5-go-next: the next build completes" "$(r t5-go-next rc)" 0
        step t5-go-after "$IMG_GO" 0 "$sc" none go build big -e "$GO_REQ_FLAGS" -e "$GO_NOPROXY" -e "$GO_LOCAL"
        check auto "t5-go-after: the one after is fully warm" "$(hits_go t5-go-after)" "rc=0 compiles=0 downloads=0"
    fi
    if want_tool pnpm; then
        step t5-pnpm-next "$IMG_NODE" 0 "$sc" on pnpm store-status big -e QPNPM=10
        check_on auto "t5-pnpm-next: the next install completes and pnpm store status of the scope store is clean" t5-pnpm-next pnpm "$(expect pnpm 0 "$sc")" "rc=$(r t5-pnpm-next rc) status=$(r t5-pnpm-next store_status_rc)" "rc=0 status=0"
        check_store auto t5-pnpm-next pnpm "$(expect pnpm 0 "$sc")"
        step t5-pnpm-after "$IMG_NODE" 0 "$sc" none pnpm install-offline big -e QPNPM=10
        check auto "t5-pnpm-after: the one after installs offline downloading nothing" "rc=$(r t5-pnpm-after rc) downloaded=$(r t5-pnpm-after downloaded)" "rc=0 downloaded=0"
    fi
}
if want_section T5; then
    section T5 "restart and crash"
    t5
fi

# --- T6 builds through the stock docker CLI --------------------------------------------------
counts_of() { grep -o 'QUALCOUNTS.*' "$1" 2>/dev/null | tail -1 | sed 's/^QUALCOUNTS //; s/ *$//'; }
ctx_copy() { # ctx_copy DIR TOKEN: a fresh build context whose token.go changes one package
    rm -rf "$1" && mkdir -p "$1" && cp -R "$FIX/build-go/." "$1/"
    printf 'package main\n\nconst token = "%s"\n' "$2" >"$1/token.go"
}
bx() { # bx [docker build args…]: the build under test (stock path, or the fallback builder by hand)
    if [ "$MANUAL" = 1 ]; then BUILDX_BUILDER="$BUILDER" "$DOCKER" build --progress=plain "$@"; else "$DOCKER" build --progress=plain "$@"; fi
}
cm_count() { # exec.cachemount records BuildKit holds
    if [ "$MANUAL" = 1 ]; then
        "$DOCKER" buildx du --builder "$BUILDER" --verbose --filter type=exec.cachemount 2>"$QR/t6-du.err" | grep -c '^ID:'
    else
        "$DOCKER" buildx du --verbose --filter type=exec.cachemount 2>"$QR/t6-du.err" | grep -c '^ID:'
    fi
}
run_image() { # run_image NAME IMAGE-REF: the image's app, its result read back from a file
    run_container "$1" "$2" -- sh -c "printf 'out=%s\n' \"\$(/out/app)\" >/qr/.$1.tmp; cat /out/counts >>/qr/.$1.tmp; echo 'QUAL-SENTINEL $1' >>/qr/.$1.tmp; mv /qr/.$1.tmp /qr/$1.res"
}
t6() {
    local B="$TMP/build" tag="qual-b-$S" rc before after mid
    GRPC=$(grpc_probe)
    check build "t6: the engine upgrades POST /grpc to h2c (the probe buildx's docker driver makes)" "$GRPC" 101
    if [ ! -x "$ROOT_DIR/tools/runner/bin/buildkitd" ]; then
        echo "   the bundle has no buildkitd: negative preflight only"
        ctx_copy "$B/neg" neg
        local t0=$SECONDS
        bx -t "$tag:neg" "$B/neg" >"$QR/t6-neg.log" 2>&1
        rc=$?
        checkp build "t6: without buildkitd, docker build fails fast" "rc=$rc after $((SECONDS - t0))s" "rc!=0 within 60s" "$(ok test "$rc" != 0 -a $((SECONDS - t0)) -le 60)"
        check build "t6: …and pulled no moby/buildkit image into the machine" "$("$DOCKER" images --format '{{.Repository}}' | grep -c moby/buildkit)" 0
        return
    fi
    if [ "$MANUAL" = 1 ]; then
        remote_builder
        check harness "t6: harness remote builder on run/buildkit.sock (stands in for the stock path)" "${BUILDER:-none}" "qual-remote-$S"
    else
        local dflt
        dflt=$("$DOCKER" buildx ls 2>"$QR/t6-ls.err" | awk '$1 == "default" || $1 == "default*" { print $2; exit }')
        check build "t6: docker buildx ls shows the default builder on the docker driver" "$dflt" docker
        if [ "$GRPC" != 101 ]; then
            # buildx would fall back to docker-container and pull moby/buildkit.
            for what in "docker build -t x . && docker run x" "cache-mount build after a source change: compiles=1 downloads=0" \
                "…after machine stop/start and the GC policy sweep" "exec.cachemount records survive the policy sweep" \
                "non-root step with uid= on its cache mounts" "docker compose build of two services"; do
                checkp buildhit "t6: $what" "not run: /grpc answered $GRPC" "a stock docker build" 0
            done
            for what in "run by --iidfile" "docker run \$(docker build -q .)"; do checkp build "t6: $what" "not run: /grpc answered $GRPC" "a stock docker build" 0; done
            t6_builder_install
            return
        fi
    fi
    ctx_copy "$B/c1" one
    bx -t "$tag:1" "$B/c1" >"$QR/t6-b1.log" 2>&1
    check buildhit "t6-b1: docker build -t (cold) exits 0" "$?" 0
    echo "    t6-b1 counts: $(counts_of "$QR/t6-b1.log")"
    run_image t6-run1 "$tag:1"
    check buildhit "t6-run1: docker run of the tag runs the built app (on the stock path with no load step)" "$(r t6-run1 out)" "qual-build one true"
    ctx_copy "$B/c2" two
    bx -t "$tag:2" "$B/c2" >"$QR/t6-b2.log" 2>&1
    check buildhit "t6-b2: after a one-file source change the cache-mount build compiles one package, downloads nothing" "$(counts_of "$QR/t6-b2.log")" "compiles=1 downloads=0 rc=0"
    before=$(cm_count)
    restart_machine t6
    cm_count >/dev/null # any BuildKit connection: the policy sweep runs about 1 s later
    sleep 4
    mid=$(cm_count)
    checkp buildhit "t6: exec.cachemount records survive machine stop/start and the GC policy sweep" "before=$before after=$mid" "equal, >0" \
        "$(ok test "$before" = "$mid" -a "$(gt0 "$before" && echo y)" = y)"
    ctx_copy "$B/c3" three
    bx -t "$tag:3" "$B/c3" >"$QR/t6-b3.log" 2>&1
    check buildhit "t6-b3: after stop/start and the sweep the build still compiles=1 downloads=0" "$(counts_of "$QR/t6-b3.log")" "compiles=1 downloads=0 rc=0"
    sleep 4
    after=$(cm_count)
    check buildhit "t6: the sweep after a build keeps the cache mounts too" "$after" "$mid"
    ctx_copy "$B/n1" n1
    bx -t "$tag:n1" -f "$B/n1/Dockerfile.nonroot" "$B/n1" >"$QR/t6-n1.log" 2>&1
    ctx_copy "$B/n2" n2
    bx -t "$tag:n2" -f "$B/n2/Dockerfile.nonroot" "$B/n2" >"$QR/t6-n2.log" 2>&1
    check buildhit "t6-n2: a non-root step (uid=1000 cache mounts) hits on its second build" "$(counts_of "$QR/t6-n2.log")" "compiles=1 downloads=0 rc=0 uid=1000"
    ctx_copy "$B/compose" compose
    if [ "$MANUAL" = 1 ]; then
        BUILDX_BUILDER="$BUILDER" "$DOCKER" compose -p "qual$S" -f "$B/compose/compose.yaml" build >"$QR/t6-compose.log" 2>&1
    else
        "$DOCKER" compose -p "qual$S" -f "$B/compose/compose.yaml" build >"$QR/t6-compose.log" 2>&1
    fi
    check buildhit "t6: docker compose build of two services" "$?" 0
    ctx_copy "$B/iid" iid
    bx --iidfile "$TMP/iid" -t "$tag:iid" "$B/iid" >"$QR/t6-iid.log" 2>&1
    run_image t6-run-iid "$(cat "$TMP/iid" 2>/dev/null)"
    check build "t6: docker run \$(cat iidfile) runs the image" "$(r t6-run-iid out)" "qual-build iid true"
    ctx_copy "$B/q" quiet
    local qid
    qid=$("$DOCKER" build -q "$B/q" 2>"$QR/t6-q.err") # stock path only (T6 build checks are skipped by hand wiring)
    run_image t6-run-q "$qid"
    check build "t6: docker run \$(docker build -q .) runs the untagged image" "$(r t6-run-q out)" "qual-build quiet true"
    t6_builder_install
}
t6_builder_install() { # the fallback: micropod machine builder install + docker --context micropod
    if "$M" machine builder install >"$QR/t6-builder-install.log" 2>&1; then
        ctx_copy "$TMP/build/f1" f1
        "$DOCKER" --context micropod build --progress=plain "$TMP/build/f1" >"$QR/t6-f1.log" 2>&1
        ctx_copy "$TMP/build/f2" f2
        "$DOCKER" --context micropod build --progress=plain "$TMP/build/f2" >"$QR/t6-f2.log" 2>&1
        check cli "t6: after machine builder install, docker --context micropod build hits on the second build" "$(counts_of "$QR/t6-f2.log")" "compiles=1 downloads=0 rc=0"
        # The documented fallback command: the remote builder on run/buildkit.sock.
        ctx_copy "$TMP/build/f3" f3
        BUILDX_BUILDER=micropod-buildkit "$DOCKER" --context micropod build --progress=plain "$TMP/build/f3" >"$QR/t6-f3.log" 2>&1
        check cli "t6: BUILDX_BUILDER=micropod-buildkit docker --context micropod build uses the remote builder and hits" \
            "$(counts_of "$QR/t6-f3.log") $(grep -o 'using remote driver' "$QR/t6-f3.log" | head -1)" "compiles=1 downloads=0 rc=0 using remote driver"
        "$M" machine builder rm >/dev/null 2>&1
    else
        check cli "t6: micropod machine builder install succeeds" "$(tail -1 "$QR/t6-builder-install.log")" "exit 0"
    fi
}
if want_section T6; then
    section T6 "builds: stock docker CLI, DOCKER_HOST only, throwaway DOCKER_CONFIG"
    t6
fi

# --- T7 latency -------------------------------------------------------------------------
t7() {
    local off="$TMP/t7-off.json" on="$TMP/t7-on.json" img first_on first_off
    echo '{"Labels": {"io.micropod.cache": "off", "qual-run": "'"$S"'"}}' >"$off"
    if [ "$MANUAL" = 1 ]; then
        manual_prep default
        python3 - "$on" "$S" <<'PY'
import json, sys
env = ["GOMODCACHE=/micropod/cache/gomod", "GOCACHE=/micropod/cache/gobuild", "GOFLAGS=-trimpath", "npm_config_cache=/micropod/cache/npm",  # guard:guest
       "pnpm_config_store_dir=/micropod/cache/pnpm", "npm_config_store_dir=/micropod/cache/pnpm", "PIP_CACHE_DIR=/micropod/cache/pip/u0",
       "UV_CACHE_DIR=/micropod/cache/uv", "UV_LINK_MODE=copy", "COREPACK_HOME=/micropod/cache/corepack"]
json.dump({"Labels": {"io.micropod.cache": "off", "qual-run": sys.argv[2]}, "Env": env, "Binds": ["qm-default:/micropod/cache"]}, open(sys.argv[1], "w"))
PY
    else
        echo '{"Labels": {"qual-run": "'"$S"'"}}' >"$on"
    fi
    python3 "$FIX/qlatency.py" series "$SOCK" "$IMG_BASE" "$T7_N" 5 "$off" "$on" "$QR/t7-series.json" >"$QR/t7-series.log" 2>&1
    check harness "t7: the interleaved series ran ($T7_N + $T7_N containers)" "$([ -f "$QR/t7-series.json" ] && echo yes || tail -1 "$QR/t7-series.log")" yes
    local t7
    t7=$(python3 - "$QR/t7-series.json" "$MANUAL" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
i = d["on_inspect"]
if sys.argv[2] == "1":
    att = "qm-default:/micropod/cache" in ((i.get("HostConfig") or {}).get("Binds") or [])
else:
    att = any(m.get("Destination") == "/micropod/cache" for m in (i.get("Mounts") or []))
print(f"{att}|{d['off']['p50']}|{d['off']['p95']}|{d['on']['p50']}|{d['on']['p95']}|{d['delta_p50']}|{d['delta_p95']}")
PY
    )
    IFS='|' read -r t7_att t7_offp50 t7_offp95 t7_onp50 t7_onp95 t7_d50 t7_d95 <<<"$t7"
    echo "    create+start ms: off p50=$t7_offp50 p95=$t7_offp95 | auto p50=$t7_onp50 p95=$t7_onp95 | delta p50=$t7_d50 p95=$t7_d95"
    check auto "t7: the 'auto' containers really had the cache attached" "$t7_att" True
    checkp perf "t7: auto adds at most 10 ms at p95 for a cached image (interleaved, n=$T7_N each)" \
        "$([ "$t7_att" = True ] || echo 'inconclusive, nothing was attached: ')delta p95 ${t7_d95} ms (p50 ${t7_d50} ms)" "<= 10 ms with the cache attached" \
        "$(ok python3 -c "import sys; sys.exit(0 if '$t7_att' == 'True' and float('$t7_d95') <= 10 else 1)")"
    set -- $T7_FIRST
    python3 "$FIX/qlatency.py" first "$SOCK" "$1" "$on" "$QR/t7-first-on.json" >"$QR/t7-first.log" 2>&1
    python3 "$FIX/qlatency.py" first "$SOCK" "$2" "$off" "$QR/t7-first-off.json" >>"$QR/t7-first.log" 2>&1
    first_on=$(python3 -c "import json; print(json.load(open('$QR/t7-first-on.json'))['total_ms'])" 2>/dev/null)
    first_off=$(python3 -c "import json; print(json.load(open('$QR/t7-first-off.json'))['total_ms'])" 2>/dev/null)
    echo "    first container of a new image: auto ($1) ${first_on} ms, off ($2) ${first_off} ms"
    local first_att
    first_att=$(python3 -c "
import json; i = json.load(open('$QR/t7-first-on.json'))['inspect']
print(('qm-default:/micropod/cache' in ((i.get('HostConfig') or {}).get('Binds') or [])) if '$MANUAL' == '1' else any(m.get('Destination') == '/micropod/cache' for m in (i.get('Mounts') or [])))" 2>/dev/null)
    checkp perf "t7: the first container of a new image (image facts probe) adds at most 300 ms" \
        "$([ "$first_att" = True ] || echo 'inconclusive, nothing was attached: ')auto=${first_on} off=${first_off} ms" "auto - off <= 300 ms with the cache attached" \
        "$(ok python3 -c "import sys; sys.exit(0 if '$first_att' == 'True' and float('${first_on:-1e9}') - float('${first_off:-0}') <= 300 else 1)")"
}
if want_section T7; then
    section T7 "create-to-start latency"
    t7
fi

# --- T8 trust tier, scope allow-list and the shared scope ------------------------------------
# qsh NAME IMAGE [docker args…] -- SCRIPT: runs SCRIPT under sh; the key=value
# lines it appends to $RES become /qr/NAME.res, sealed with the sentinel.
qsh() {
    local name=$1 image=$2
    shift 2
    local args=()
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do args+=("$1") && shift; done
    shift
    run_container "$name" "$image" "${args[@]}" -- sh -c "RES=/qr/.$name.tmp; : >\$RES; $1; echo 'QUAL-SENTINEL $name' >>\$RES; mv \$RES /qr/$name.res"
    sentinel "$name"
}
create_err() { # create_err [docker create args…]: the refused create's last line, "" when it was created (then removed)
    local out cid
    out=$("$DOCKER" create --label "qual-run=$S" "$@" 2>&1)
    cid=$(echo "$out" | grep -E '^[0-9a-f]{64}$')
    [ -n "$cid" ] && "$DOCKER" rm -f "$cid" >/dev/null 2>&1
    [ -n "$cid" ] || echo "$out" | tail -1
}
setpol() { # setpol FLAG…: a live machine cache policy edit; the engine re-reads it within 2 s
    "$M" machine cache policy "$@" >>"$QR/t8-policy.log" 2>&1
    local rc=$?
    sleep 3
    return $rc
}
trust_of() { echo "trust=$(insp "$1" "(c.get('MicropodCache') or {}).get('trust')") from=$(insp "$1" "(c.get('MicropodCache') or {}).get('trustFrom')")"; }
t8() {
    local sc=q8-$S mark=qual-t8-$S err cmd
    local G=/micropod/cache/gomod
    # (a) defaultTrust=untrusted: a container that names no tier only reads.
    qsh t8-seed "$IMG_BASE" --label "io.micropod.cache.scope=$sc" -- "echo trusted >$G/$mark-seed && echo seed=ok >>\$RES"
    check safety "t8-seed: a trusted container (the shipped default) writes the scope's gomod store" "$(r t8-seed seed)" ok
    setpol --default-trust untrusted
    check cli "t8: machine cache policy --default-trust untrusted is applied live" "$?" 0
    qsh t8-unlabeled "$IMG_BASE" --label "io.micropod.cache.scope=$sc" -- \
        "echo poisoned >$G/$mark-seed 2>/dev/null && echo overwrote=yes >>\$RES; echo planted >$G/$mark-planted 2>/dev/null && echo planted=yes >>\$RES; echo seen=\$(cat $G/$mark-seed) >>\$RES"
    check engine "t8-unlabeled: under defaultTrust=untrusted an unlabeled container is untrusted by the policy default, gomod copy-on-write" \
        "$(trust_of t8-unlabeled) gomod=$(mc t8-unlabeled gomod access)" "trust=untrusted from=policy-default gomod=copy-on-write"
    check safety "t8-unlabeled: its writes land in its own view (it saw its own overwrite)" \
        "overwrote=$(r t8-unlabeled overwrote) planted=$(r t8-unlabeled planted) seen=$(r t8-unlabeled seen)" "overwrote=yes planted=yes seen=poisoned"
    qsh t8-trusted "$IMG_BASE" --label "io.micropod.cache.scope=$sc" --label io.micropod.cache.trust=trusted -- \
        "echo seed=\$(cat $G/$mark-seed) >>\$RES; if [ -e $G/$mark-planted ]; then echo planted=yes; else echo planted=no; fi >>\$RES"
    check safety "t8: the unlabeled container wrote nothing into the store (a trusted reader sees the seed, no planted file)" \
        "seed=$(r t8-trusted seed) planted=$(r t8-trusted planted)" "seed=trusted planted=no"
    check engine "t8-trusted: on the host-facing socket a container may still claim trusted under that default" "$(trust_of t8-trusted)" "trust=None from=label"
    # (b) A container created from inside it: the engine gives no container
    # a socket that can create one. A docker.sock bind is refused, and the
    # engine's vsock port is unreachable from a container (a container may
    # not even open an AF_VSOCK socket; past that, the kernel has no vsock
    # loopback and the host answers only its own services).
    err=$(create_err -v /var/run/docker.sock:/var/run/docker.sock "$IMG_BASE" true)
    checkp engine "t8: no container gets the engine's socket (a /var/run/docker.sock bind is refused)" "$err" "a refused create" "$(ok test -n "$err")"
    cmd="import errno, socket
for cid in (1, 2):
    try:
        s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
        s.settimeout(3)
        s.connect((cid, 2375))
        r = 'connected'
    except OSError as e:
        r = errno.errorcode.get(e.errno, 'timeout') if e.errno else 'timeout'
    print('vsock%d=%s' % (cid, r))"
    qsh t8-vsock "$IMG_PY" -- "python3 -c \"$cmd\" >>\$RES 2>&1"
    checkp engine "t8-vsock: an untrusted container cannot reach the engine's vsock port 2375 (guest loopback or host)" \
        "vsock1=$(r t8-vsock vsock1) vsock2=$(r t8-vsock vsock2)" "neither connected" \
        "$(ok test -n "$(r t8-vsock vsock1)" -a "$(r t8-vsock vsock1)" != connected -a -n "$(r t8-vsock vsock2)" -a "$(r t8-vsock vsock2)" != connected -a "$(r t8-vsock vsock1)" != missing)"
    # (c) allowedScopes holds for labels, untrusted readers and alias volumes.
    setpol --default-trust trusted --allow-scopes "q8-*,default"
    err=$(create_err --label "io.micropod.cache.scope=other-$S" "$IMG_BASE" true)
    checkp engine "t8: a scope label outside allowedScopes is refused (400)" "$err" "contains 'not allowed'" "$(ok test "$(echo "$err" | grep -c 'not allowed')" -ge 1)"
    err=$(create_err --label "io.micropod.cache.scope=other-$S" --label io.micropod.cache.trust=untrusted "$IMG_BASE" true)
    checkp engine "t8: an untrusted container may not even read a scope outside allowedScopes" "$err" "contains 'not allowed'" "$(ok test "$(echo "$err" | grep -c 'not allowed')" -ge 1)"
    err=$(create_err -v "micropod-ci-scoped-other$S-gomod:/go/pkg/mod:ro" "$IMG_BASE" true)
    checkp engine "t8: a legacy alias volume naming a scope outside allowedScopes is refused" "$err" "contains 'does not allow'" "$(ok test "$(echo "$err" | grep -c 'does not allow')" -ge 1)"
    echo "micropod-ci-scoped-$sc-gomod" >>"$QW/volumes.list"
    err=$(create_err -v "micropod-ci-scoped-$sc-gomod:/go/pkg/mod:ro" "$IMG_BASE" true)
    check engine "t8: an alias volume of an allowed scope is still accepted" "${err:-created}" created
    setpol --allow-scopes '*'
    # (d) sharedL0 shares gomod, npm and pnpm only: maven and gradle stay in
    # each container's scope.
    setpol --share-l0 on
    check cli "t8: machine cache policy --share-l0 on" "$?" 0
    qsh t8-mvn-a "$IMG_BASE" --label "io.micropod.cache.scope=q8a-$S" --label "io.micropod.cache=+maven,+gradle" -- \
        "mkdir -p /root/.m2/repository/qual /root/.gradle/caches/modules-2/qual && echo a >/root/.m2/repository/qual/$mark && echo a >/root/.gradle/caches/modules-2/qual/$mark && echo wrote=yes >>\$RES"
    qsh t8-mvn-b "$IMG_BASE" --label "io.micropod.cache.scope=q8b-$S" --label "io.micropod.cache=+maven,+gradle" -- \
        "for k in maven:/root/.m2/repository gradle:/root/.gradle/caches/modules-2; do if [ -e \${k#*:}/qual/$mark ]; then echo \${k%%:*}=shared; else echo \${k%%:*}=separate; fi; done >>\$RES"
    qsh t8-mvn-a2 "$IMG_BASE" --label "io.micropod.cache.scope=q8a-$S" --label "io.micropod.cache=+maven,+gradle" -- \
        "for k in maven:/root/.m2/repository gradle:/root/.gradle/caches/modules-2; do if [ -e \${k#*:}/qual/$mark ]; then echo \${k%%:*}=kept; else echo \${k%%:*}=lost; fi; done >>\$RES"
    check engine "t8-mvn-a: scope A's maven and gradle stores take its entries (maven, gradle path-mode in q8a-$S; gomod in global)" \
        "wrote=$(r t8-mvn-a wrote) $(mc t8-mvn-a maven scope) $(mc t8-mvn-a gradle scope) $(mc t8-mvn-a gomod scope)" "wrote=yes q8a-$S q8a-$S global"
    check engine "t8-mvn-b: with sharedL0 on, scope B does not see scope A's maven or gradle entries" \
        "maven=$(r t8-mvn-b maven) gradle=$(r t8-mvn-b gradle) scopes=$(mc t8-mvn-b maven scope),$(mc t8-mvn-b gradle scope)" \
        "maven=separate gradle=separate scopes=q8b-$S,q8b-$S"
    check auto "t8-mvn-a2: …while scope A keeps them for its next container" "maven=$(r t8-mvn-a2 maven) gradle=$(r t8-mvn-a2 gradle)" "maven=kept gradle=kept"
    setpol --share-l0 off
}
if want_section T8; then
    section T8 "trust tier, scope allow-list and what sharedL0 shares"
    if [ "$MANUAL" = 1 ]; then
        echo "  - T8 checks the engine's trust and scope decisions; hand wiring has nothing to stand in for (not run)"
        SKIP=$((SKIP + 1))
    else
        t8
    fi
fi

# --- T9 BuildKit across a replaced OS disk -------------------------------------------------------
# BuildKit's metadata and the containerd snapshots it refers to both live on
# the OS disk: replacing disk.ext4 starts BuildKit empty and consistent (no
# record whose snapshot is gone, no failed build), and the cache disk's
# dependency stores survive. The cache mounts themselves do not.
t9() {
    local B="$TMP/build9" tag="qual-b9-$S" before after du rc
    ctx_copy "$B/r1" r1
    bx -t "$tag:1" "$B/r1" >"$QR/t9-b1.log" 2>&1
    ctx_copy "$B/r2" r2
    bx -t "$tag:2" "$B/r2" >"$QR/t9-b2.log" 2>&1
    check buildhit "t9-b2: before the OS disk is replaced the cache-mount build hits" "$(counts_of "$QR/t9-b2.log")" "compiles=1 downloads=0 rc=0"
    before=$(cm_count)
    "$M" machine stop >"$QR/t9-stop.log" 2>&1
    "$M" machine install --replace-disk "${DISK_ARGS[@]}" >"$QR/t9-install.log" 2>&1
    check cli "t9: machine install --replace-disk replaces disk.ext4 and keeps caches.ext4" \
        "rc=$? cache-disk=$([ -f "$ROOT_DIR/caches.ext4" ] && echo kept || echo gone)" "rc=0 cache-disk=kept"
    "$M" machine start >"$QR/t9-start.log" 2>&1
    wait_engine 180
    "$DOCKER" buildx du >"$QR/t9-du.log" 2>&1
    du=$?
    after=$(cm_count)
    checkp build "t9: after the replaced OS disk BuildKit starts empty and consistent (buildx du answers, no cache-mount record left)" \
        "du=$du records before=$before after=$after" "du=0, after=0" "$(ok test "$du" = 0 -a "$after" = 0 -a "$(gt0 "$before" && echo y)" = y)"
    ctx_copy "$B/r3" r3
    bx -t "$tag:3" "$B/r3" >"$QR/t9-b3.log" 2>&1
    rc=$?
    check build "t9-b3: the cache-mount build on the new OS disk succeeds and no step misses a snapshot" \
        "rc=$rc missing=$(grep -c 'does not exist' "$QR/t9-b3.log")" "rc=0 missing=0"
    echo "    t9-b3 counts (the cache mounts start empty with the OS disk): $(counts_of "$QR/t9-b3.log")"
    ctx_copy "$B/r4" r4
    bx -t "$tag:4" "$B/r4" >"$QR/t9-b4.log" 2>&1
    check buildhit "t9-b4: …and the next one hits its cache mounts again" "$(counts_of "$QR/t9-b4.log")" "compiles=1 downloads=0 rc=0"
    if want_section T8; then
        "$DOCKER" pull -q "$IMG_BASE" >>"$OUT/pull.log" 2>&1
        qsh t9-store "$IMG_BASE" --label "io.micropod.cache.scope=q8-$S" -- "echo seed=\$(cat /micropod/cache/gomod/qual-t8-$S-seed) >>\$RES"
        check auto "t9-store: the cache disk's stores survive the replaced OS disk (T8's seed is still there)" "$(r t9-store seed)" trusted
    fi
}
if want_section T9; then
    section T9 "BuildKit state across machine install --replace-disk"
    if [ "$INSTALL" != 1 ] || [ "$MANUAL" = 1 ] || [ ! -x "$ROOT_DIR/tools/runner/bin/buildkitd" ]; then
        echo "  - T9 replaces the OS disk of a throwaway install with BuildKit on the stock path (not run here)"
        SKIP=$((SKIP + 1))
    else
        t9
    fi
fi

# --- summary --------------------------------------------------------------------------------
{
    echo
    echo "run $S on $ROOT_DIR (manual wiring: $MANUAL): $PASS passed, $FAIL failed, $SKIP skipped; $NRUN containers, $NMISS result files without a sentinel"
    if [ "$FAIL" -gt 0 ]; then
        echo "failed checks by requirement:"
        awk -F'\t' '$1 == "fail" { n[$3]++ } END { for (k in n) printf "  %-9s %d\n", k, n[k] }' "$OUT/checks.tsv" | sort
    fi
    [ "$MANUAL" = 1 ] && echo "QUAL_MANUAL_WIRING=1 is a self-test of the harness, not a qualification result."
    echo "checks: $OUT/checks.tsv; container results: $OUT/results/"
} | tee "$OUT/summary.txt"
[ "$FAIL" -eq 0 ]
