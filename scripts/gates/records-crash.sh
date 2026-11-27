#!/bin/bash
# scripts/gates/records-crash.sh — the engine's records survive a crash right
# after the API answers: kill -9 of the VMM at swept offsets after creates of
# containers, volumes and networks, on a real throwaway hvf machine, as
# numbered checks with a receipt.
#
#   scripts/gates/records-crash.sh [--payload DIR] [--offsets MS,MS,...]
#                                  [--image-trials SPEC] [--sweep records,images]
#                                  [--receipt-dir DIR] [--keep] [--help]
#
# Every trial creates, through the guest's Docker API: a container (created),
# one that ran and whose wait answered exit 7, one whose start answered and
# that still runs, six concurrent creates, an AutoRemove container never
# started and one running, a named volume, a bridge network and a container
# on it. One kind per trial (rotating) comes last and alone, after a quiet
# 6 s (GATE_QUIET_S; ext4 commits its journal by itself every 5 s, so all the
# rest is on the disk by then), and this root's VMM is killed with SIGKILL the
# trial's offset after that last answer: only that kind's own syncs can have
# kept it. The default sweep runs each kind twice, at offsets 0 to 3000 ms
# (0, 1, 3, 10, 30, 100, 300, 1000, 3000, then reversed). The supervisor
# relaunches it, and the checks require:
#   - the relaunched engine answers (its recovery refuses a torn or empty
#     record, so an engine that does not come back fails),
#   - every answered create present with the same labels, env and image, in
#     the state the API reported (created; exited 7; a started container
#     present, not running, never created and never a success),
#   - all six concurrent creates present,
#   - the volume and the network present with their labels, and a container
#     started on the network runs and reads a resolver,
#   - AutoRemove: a started one gone, a never-started one gone or whole,
#   - the exited container starts again (its retained rootfs recovered).
# A kill -9 of the VMM loses what the guest had not flushed (its page cache)
# and keeps what it had: so this proves the guest syncs (engine and
# containerd) are where the answers need them, not the host's disk flushes.
#
# Before any kill (section C): a container runs (CRI pulls its sandbox image
# by itself, and nothing syncs that), the machine is stopped and started, and
# the start must remove no image: a clean stop is never taken for a crash.
#
# Then the image trials (section I): each makes an image the engine never had
# (a pull of a never-pulled public image, or a load and a build of a
# generated image with a unique layer of 32 MiB, GATE_IMAGE_MIB) and kills the VMM
# either MS after the operation answered (after:MS) or a FRACTION of the
# kind's measured duration after it began (before:FRACTION; one that answered
# first is judged as answered). After the relaunch:
#   - an answered pull, load or build: the image is whole,
#   - an unanswered one: the image is gone or whole, never present but broken,
#   - the same pull, load or build again: the image is whole (a broken image
#     that survives its own re-pull fails),
# where whole is a container from it that runs a probe printing the sha256 of
# every regular file, all equal to the image's layers (from the registry for
# a pull, from the generated layer for a load or build). The default trials
# kill 0 to 10000 ms after a pull answered (the engine before image syncs left
# the image broken 0 to 35 s after) and 0 to 3000 ms after a load or build.
#
# It fails when a needed sync is missing: run it with --payload of an engine
# built with one removed (the receipt's versions.txt names the payload).
#
# --payload    a payload directory (micropod-vmm, Image, mp-hvf-init.cpio,
#              tools/); default: the rig's known-good payload, cloned (read only)
# --offsets    kill offsets in ms after the last answer
# --image-trials  comma-separated KIND:after:MS or KIND:before:FRACTION, KIND
#              pull, load or build ("" for none; default: see IMAGE_TRIALS)
# --sweep      which sweeps run: records (the creates above), images, or both
# --receipt-dir default ~/.micropod/gates/records-crash/<UTC time>/:
#              result.json, checks.tsv, versions.txt, logs/, evidence/
# --keep       keep the throwaway root (stopped) for inspection
#
# Environment: GATE_ROOT (default /tmp/mpg-rc; a plain directory under /tmp,
# deleted at exit only when it carries this harness's marker), GATE_MICROPOD
# (default .build/debug/micropod), GATE_API_PORT (19340), GATE_SHIM_PORT
# (19341), GATE_DISK_FROM (default ~/.micropod/ci/worker.ext4, cloned, read
# only), GATE_CPUS (4), GATE_MEMORY_MIB (4096), GATE_IMAGE (alpine:3.20),
# GATE_DOCKER, GATE_PULL_IMAGES and GATE_PULL_BEFORE_IMAGES (comma-separated
# public linux/arm64 images for the pull trials; default busybox, python and
# node from public.ecr.aws), GATE_IMAGE_MIB (32).
#
# Safety: one throwaway machine under GATE_ROOT with MICROPOD_LINK_DOCKER_SOCK=0
# and its own MICROPOD_API_SOCK, API and shim ports; only that root's VMM (its
# binary on its disk, checked against the root before every signal) is ever
# signalled, and the machine is stopped and the root removed at exit. The rig
# (~/.micropod/hvf, ~/.micropod/docker.sock, ~/.micropod/api.sock, port 45454)
# is never started, stopped, repointed or written.
#
# Exit status: 0 every check passed, 1 a check failed, 2 the gate could not run.
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/records-crash"
REPO="$(cd "$HERE/../.." && pwd)"
PAYLOAD_SRC=""
OFFSETS="0,1,3,10,30,100,300,1000,3000,3000,1000,300,100,30,10,3,1,0"
IMAGE_TRIALS="pull:after:0,pull:after:30,pull:after:300,pull:after:3000,pull:after:10000,pull:before:0.5,pull:before:0.8,pull:before:0.95"
IMAGE_TRIALS="$IMAGE_TRIALS,load:after:0,load:after:300,load:after:3000,load:before:0.5,load:before:0.8"
IMAGE_TRIALS="$IMAGE_TRIALS,build:after:0,build:after:300,build:after:3000,build:before:0.35,build:before:0.6"
SWEEP="records,images"
KEEP=0
TS="$(date -u +%Y%m%dT%H%M%SZ)"
R="$HOME/.micropod/gates/records-crash/$TS"

usage() { sed -n '2,/^set -o pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
while [ "$#" -gt 0 ]; do
    case $1 in
    --payload) PAYLOAD_SRC=$2 && shift ;;
    --offsets) OFFSETS=$2 && shift ;;
    --image-trials) IMAGE_TRIALS=$2 && shift ;;
    --sweep) SWEEP=$2 && shift ;;
    --receipt-dir) R=$2 && shift ;;
    --keep) KEEP=1 ;;
    -h | --help) usage && exit 0 ;;
    *) echo "unknown argument $1 (see --help)" >&2 && exit 2 ;;
    esac
    shift
done
case "$OFFSETS" in '' | *[!0-9.,]*) echo "--offsets must be milliseconds separated by commas" >&2 && exit 2 ;; esac
case "$IMAGE_TRIALS" in *[!a-z0-9.,:]*) echo "--image-trials must be KIND:after:MS or KIND:before:FRACTION, comma-separated" >&2 && exit 2 ;; esac
case ",$SWEEP," in *,records,* | *,images,*) ;; *) echo "--sweep must name records, images or both" >&2 && exit 2 ;; esac

BASE="${GATE_ROOT:-/tmp/mpg-rc}"
case "$BASE" in
*/ | *//* | */./* | */. | */../* | */..) echo "GATE_ROOT must be a plain directory under /tmp" >&2 && exit 2 ;;
/tmp/?* | /private/tmp/?*) ;;
*) echo "GATE_ROOT must be a throwaway directory under /tmp (got '$BASE')" >&2 && exit 2 ;;
esac
MARKER=.micropod-gate-records-crash
if [ -e "$BASE" ] && [ ! -f "$BASE/$MARKER" ] && [ -n "$(ls -A "$BASE" 2>/dev/null)" ]; then
    echo "$BASE exists and was not made by this harness (no $MARKER)" >&2
    exit 2
fi
MROOT="$BASE/m"
WS="$BASE/ws"
STAGE="$BASE/stage"
TMPD="$BASE/tmp"
SOCK="$MROOT/run/docker.sock"
M="${GATE_MICROPOD:-$REPO/.build/debug/micropod}"
DISK_FROM="${GATE_DISK_FROM:-$HOME/.micropod/ci/worker.ext4}"
if [ -n "${GATE_DOCKER:-}" ]; then DOCKER=$GATE_DOCKER; elif [ -x /opt/homebrew/bin/docker ]; then DOCKER=/opt/homebrew/bin/docker; else DOCKER="$(command -v docker)"; fi
CPUS="${GATE_CPUS:-4}"
MEM="${GATE_MEMORY_MIB:-4096}"
IMAGE="${GATE_IMAGE:-alpine:3.20}"
RUN="rc$(date +%s)"

if [ -z "$PAYLOAD_SRC" ]; then
    KG="$HOME/.micropod/hvf/known-good"
    [ -L "$KG" ] && PAYLOAD_SRC="$HOME/.micropod/hvf/$(readlink "$KG")"
fi
for need in "$M" "$DOCKER"; do [ -x "$need" ] || { echo "missing executable $need" >&2 && exit 2; }; done
for need in micropod-vmm Image mp-hvf-init.cpio tools/runner/start.sh; do
    [ -f "$PAYLOAD_SRC/$need" ] || { echo "payload '$PAYLOAD_SRC' lacks $need (pass --payload)" >&2 && exit 2; }
done
[ -f "$DISK_FROM" ] || { echo "missing OS disk image $DISK_FROM" >&2 && exit 2; }

mkdir -p "$R/logs" "$R/evidence" || exit 2
R="$(cd "$R" && pwd)"
: >"$R/checks.tsv"
exec > >(tee -a "$R/logs/harness.log") 2>&1
log() { printf '%s records-crash: %s\n' "$(date +%H:%M:%S)" "$*"; }

export MICROPOD_HVF_ROOT="$MROOT"
export MICROPOD_RUNTIMES_CONFIG="$TMPD/runtimes.json"
export MICROPOD_CLI="$M"
export MICROPOD_DOCKER_SOCK="$MROOT/canonical-docker.sock"
export MICROPOD_LINK_DOCKER_SOCK=0
export MICROPOD_API_SOCK="$BASE/api.sock"
export MICROPOD_API_PORT="${GATE_API_PORT:-19340}"
export MICROPOD_SHIM_TCP_PORT="${GATE_SHIM_PORT:-19341}"
export MICROPOD_HVF_AUTOSTART=0
export MICROPOD_NO_UPDATE_NOTIFIER=1
export PYTHONDONTWRITEBYTECODE=1
unset MICROPOD_DEFAULT_RUNTIME DOCKER_CONTEXT BUILDX_BUILDER DOCKER_BUILDKIT
export DOCKER_HOST="unix://$SOCK"
export DOCKER_CONFIG="$TMPD/docker"
RIG_LINK_BEFORE="$(readlink "$HOME/.micropod/docker.sock" 2>/dev/null || echo absent)"

remove_tree() { [ ! -e "$1" ] || { chmod -R u+w "$1" 2>/dev/null; rm -rf "$1"; }; }
ABORTED=""
write_result() {
    python3 - "$R" "$TS" "$BASE" "$ABORTED" "$OFFSETS" <<'PY'
import datetime, json, os, sys
r, ts, base, aborted, offsets = sys.argv[1:]
checks = []
for line in open(os.path.join(r, "checks.tsv")):
    f = line.rstrip("\n").split("\t")
    if len(f) >= 6:
        checks.append({"id": f[0], "section": f[1], "status": f[2], "label": f[3], "got": f[4], "want": f[5], "evidence": f[6] if len(f) > 6 else ""})
versions = {}
for line in open(os.path.join(r, "versions.txt")) if os.path.exists(os.path.join(r, "versions.txt")) else []:
    k, _, v = line.rstrip("\n").partition("=")
    versions[k] = v
bad = [c for c in checks if c["status"] != "pass"]
verdict = "error" if aborted else ("fail" if bad or not checks else "pass")
json.dump({"gate": "records-crash: answered creates and images survive kill -9 of the VMM at swept offsets",
           "receipt": r, "started": datetime.datetime.strptime(ts, "%Y%m%dT%H%M%SZ").replace(tzinfo=datetime.timezone.utc).isoformat(),
           "finished": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
           "offsetsMs": [float(x) for x in offsets.split(",") if x], "throwawayRoot": base, "aborted": aborted or None,
           "versions": versions, "summary": {"checks": len(checks), "passed": len(checks) - len(bad), "failed": len(bad)},
           "verdict": verdict, "failed": [c["id"] + " " + c["label"] for c in bad], "checks": checks},
          open(os.path.join(r, "result.json"), "w"), indent=2)
print("result: %s — %d passed, %d failed of %d checks%s" % (verdict, len(checks) - len(bad), len(bad), len(checks), " (aborted: %s)" % aborted if aborted else ""))
for c in bad:
    print("  failed:", c["id"], c["label"])
PY
}
cleanup() {
    local rc=$?
    set +e
    [ -n "$ABORTED" ] || [ "$rc" -le 1 ] || ABORTED="interrupted (exit $rc)"
    if [ -f "$MROOT/machine.json" ]; then
        "$M" machine logs -n 600 >"$R/logs/console-tail.log" 2>&1
        for f in supervisor.log console.log; do [ -f "$MROOT/logs/$f" ] && tail -c 4000000 "$MROOT/logs/$f" >"$R/logs/$f"; done
        "$M" machine stop >"$R/logs/final-stop.log" 2>&1
    fi
    write_result
    log "rig link ~/.micropod/docker.sock -> $(readlink "$HOME/.micropod/docker.sock" 2>/dev/null || echo absent) (before: $RIG_LINK_BEFORE)"
    if [ "$KEEP" != 1 ] && [ -f "$BASE/$MARKER" ]; then remove_tree "$BASE"; fi
    log "receipt: $R/result.json"
    if [ -n "$ABORTED" ]; then exit 2; fi
    if python3 -c "import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))['verdict'] == 'pass' else 1)" "$R/result.json"; then exit 0; fi
    exit 1
}
trap cleanup EXIT
trap 'exit 130' INT TERM
abort() { ABORTED=$1 && log "ABORT: $1" && exit 2; }

log "receipt $R"
log "throwaway root $BASE; offsets $OFFSETS ms; payload $PAYLOAD_SRC"
"$M" machine stop >/dev/null 2>&1
remove_tree "$BASE"
{ mkdir -p "$BASE" "$MROOT" "$WS" "$STAGE" "$TMPD/docker" && touch "$BASE/$MARKER"; } || abort "cannot create $BASE"
# The user's CLI plugin directory, so `docker build` (buildx) loads; nothing
# else of the user's docker config is read.
python3 -c 'import json,os,sys; json.dump({"cliPluginsExtraDirs": [os.path.expanduser("~/.docker/cli-plugins")]}, open(sys.argv[1], "w"))' "$DOCKER_CONFIG/config.json"
cp -cR "$PAYLOAD_SRC/." "$STAGE/payload/" 2>/dev/null || cp -R "$PAYLOAD_SRC/." "$STAGE/payload/"
chmod -R u+w "$STAGE/payload"
{
    echo "harness_rev=$(git -C "$REPO" rev-parse HEAD 2>/dev/null)"
    echo "payload_src=$PAYLOAD_SRC"
    for f in micropod-vmm Image mp-hvf-init.cpio tools/runner/start.sh tools/runner/bin/job; do
        echo "payload_sha256.$f=$(shasum -a 256 "$STAGE/payload/$f" 2>/dev/null | cut -d' ' -f1)"
    done
    echo "bundle_manifest=$(cat "$STAGE/payload/tools/runner/manifest.json" 2>/dev/null)"
    echo "offsets_ms=$OFFSETS"
    echo "image_trials=$IMAGE_TRIALS"
    echo "sweep=$SWEEP"
    echo "run=$RUN"
} >"$R/versions.txt"
"$M" machine install --vmm "$STAGE/payload/micropod-vmm" --kernel "$STAGE/payload/Image" --initrd "$STAGE/payload/mp-hvf-init.cpio" \
    --tools "$STAGE/payload/tools" --disk-from "$DISK_FROM" --cpus "$CPUS" --memory-mib "$MEM" --workspace "$WS" >"$R/logs/install.log" 2>&1 ||
    { cat "$R/logs/install.log"; abort "machine install failed"; }
"$M" machine start --timeout 300 >"$R/logs/machine-start.log" 2>&1 || { tail -20 "$R/logs/machine-start.log"; abort "machine start failed"; }
for _ in $(seq 1 240); do curl -s -m 2 --unix-socket "$SOCK" http://d/_ping 2>/dev/null | grep -q OK && break; sleep 0.5; done
curl -s -m 5 --unix-socket "$SOCK" http://d/version >"$R/evidence/version.json" || abort "the engine never answered"
echo "engine_commit=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('GitCommit'))" "$R/evidence/version.json")" >>"$R/versions.txt"
"$DOCKER" pull -q "$IMAGE" >"$R/logs/pull.log" 2>&1 || abort "cannot pull $IMAGE"
GATE_IMAGE_TRIALS="$IMAGE_TRIALS" GATE_SWEEP="$SWEEP" GATE_DOCKER_BIN="$DOCKER" GATE_TMP="$TMPD" \
    python3 -I "$GATE/driver.py" "$MROOT" "$R" "$RUN" "$OFFSETS" "$IMAGE"
rc=$?
[ "$rc" -le 1 ] || abort "the driver could not run the trials (exit $rc)"
link=$(readlink "$HOME/.micropod/docker.sock" 2>/dev/null || echo absent)
case "$link" in "$BASE"* | "$MROOT"*) ok=fail ;; *) ok=pass ;; esac
printf 'S-01\tS\t%s\t%s\t%s\t%s\t\n' "$ok" "$HOME/.micropod/docker.sock is not pointed at the throwaway machine" "$link" "not under $BASE" >>"$R/checks.tsv"
