#!/bin/bash
# scripts/e2e_hvf_update.sh — the rootless HVF payload updater end to end.
#
# On a throwaway machine root:
#   1. installs a flat machine (micropod-vmm, kernel, initrd, guest tools, an
#      APFS clone of an ext4 disk and a cache disk) and boots it;
#   2. stages a second payload (a copy of the installed one under another
#      version id): `current` does not move, `updatePending` is true, and
#      neither a kill -9 of the VMM (supervisor relaunch) nor a machine
#      stop/start boots the staged payload; then containers write a named
#      volume and a marker into a cache unit;
#   3. with a container running, `update hvf apply` defers (exit 75) and
#      stops nothing; once it is gone, apply switches over and the
#      switchover time (old VMM exit to the new guest answering _ping) is
#      recorded;
#   4. stages a broken payload (its micropod-vmm exits 1) and applies it: the
#      activation rolls back to known-good by itself; current, known-good and
#      the running payload are the pre-update id, the guest answers again, and
#      the volume, the cache marker and the cache unit list are unchanged; the
#      broken payload stays staged and status says why its apply failed;
#   5. `update hvf rollback --previous` boots, probes and activates the payload
#      before known-good: the imported flat install;
#   6. with `current` moved behind the updater's back and the machine
#      restarted onto it, `update hvf rollback` defers (exit 75) while a
#      container runs and restarts nothing, and `--force` restarts onto
#      known-good (exit 0, rolled_back);
#   7. a store as the earlier updater left it (current on a payload that
#      never booted, no known-good, writable versions) is migrated by the next
#      `update hvf apply`, which then activates that payload through the probe;
#   8. a repeated `update hvf rollback` changes nothing.
# Only processes this script started are signalled, by pid.
#
# Usage: scripts/e2e_hvf_update.sh            (needs `swift build` and vmm/build.sh first)
#   HVF_UPDATE_ROOT  machine root (default /tmp/mpfx-b; under /tmp, short enough
#                    for run/docker.sock). It and "$HVF_UPDATE_ROOT-ws" are deleted
#                    only when empty, absent or marked by an earlier run.
#   HVF_VMM          signed micropod-vmm (default vmm/target/release/micropod-vmm)
#   HVF_KERNEL       arm64 Image (default: newest ~/.micropod/kernels/*/Image)
#   HVF_INITRD       guest initramfs (default vmm/target/mp-hvf-init.cpio)
#   HVF_TOOLS        guest tool bundle containing runner/start.sh (required)
#   HVF_DISK_FROM    ext4 disk to clone, read only (default ~/.micropod/ci/worker.ext4)
#   HVF_DISK_IMAGE   OCI image (or `default`) to unpack into a fresh disk instead
#   HVF_IMAGE        container image for the workloads (default alpine:3.20)
#   HVF_UPDATE_OUT   receipt directory (default .build/e2e-hvf-update/<time>)
#   HVF_UPDATE_KEEP=1 keep the root (stopped) for inspection
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
M="$REPO/.build/debug/micropod"
ROOT_DIR="${HVF_UPDATE_ROOT:-/tmp/mpfx-b}"
VMM="${HVF_VMM:-$REPO/vmm/target/release/micropod-vmm}"
KERNEL="${HVF_KERNEL:-$(ls -t "$HOME"/.micropod/kernels/*/Image 2>/dev/null | head -1)}"
INITRD="${HVF_INITRD:-$REPO/vmm/target/mp-hvf-init.cpio}"
TOOLS="${HVF_TOOLS:-}"
DISK_FROM="${HVF_DISK_FROM:-$HOME/.micropod/ci/worker.ext4}"
DISK_IMAGE="${HVF_DISK_IMAGE:-}"
IMAGE="${HVF_IMAGE:-alpine:3.20}"
OUT="${HVF_UPDATE_OUT:-$REPO/.build/e2e-hvf-update/$(date +%Y%m%d-%H%M%S)}"
WS="$ROOT_DIR-ws"
S="$(date +%s)"
PASS=0
FAIL=0

case "$ROOT_DIR" in
*/ | *//* | */./* | */. | */../* | */..) ROOT_OK=0 ;;
/tmp/?* | /private/tmp/?*) ROOT_OK=1 ;;
*) ROOT_OK=0 ;;
esac
if [ "$ROOT_OK" != 1 ]; then
    echo "HVF_UPDATE_ROOT must be a throwaway directory under /tmp (got '$ROOT_DIR')" >&2
    exit 2
fi
MARKER=.micropod-e2e-hvf-update
ours() { [ ! -e "$1" ] || [ -f "$1/$MARKER" ] || [ -z "$(ls -A "$1" 2>/dev/null)" ]; }
for dir in "$ROOT_DIR" "$WS"; do
    ours "$dir" || {
        echo "$dir exists and was not made by this script (no $MARKER); remove it or pick another HVF_UPDATE_ROOT" >&2
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
mkdir -p "$OUT"
export MICROPOD_HVF_ROOT="$ROOT_DIR"
export MICROPOD_RUNTIMES_CONFIG="$TMP/runtimes.json" # never the user's engine config
export MICROPOD_CLI="$M"                             # the binary that runs `machine serve`
unset MICROPOD_DEFAULT_RUNTIME
SOCK="$ROOT_DIR/run/docker.sock"
VOL="e2eupd-$S"
SCOPE="e2eupd"

# Committed payloads are read-only: make a tree writable before removing it.
remove_tree() { [ ! -e "$1" ] || { chmod -R u+w "$1" && rm -rf "$1"; }; }

cleanup() {
    if [ -S "$SOCK" ]; then
        for name in vol cache busy busy2 check; do "$M" rm --force "e2eupd-$name-$S" >/dev/null 2>&1 || true; done
        "$M" volume rm --runtime hvf "$VOL" >/dev/null 2>&1 || true
    fi
    "$M" machine stop >/dev/null 2>&1 || true
    if [ "${HVF_UPDATE_KEEP:-0}" != 1 ]; then
        for dir in "$ROOT_DIR" "$WS"; do
            if [ -f "$dir/$MARKER" ]; then remove_tree "$dir"; fi
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
hvf_status() { "$M" update hvf status --json | python3 -c "import sys,json; s=json.load(sys.stdin); print($1)"; }
link_id() { [ -L "$ROOT_DIR/$1" ] && basename "$(readlink "$ROOT_DIR/$1")" || echo none; }
canon() { python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$1"; }
loaded_id() { basename "$(state "s.get('loadedPayloadPath') or ''")"; }
vmm_exe() { canon "$(ps -o command= -p "$(state "s['vmmPID']")" | awk '{print $1}')"; }
wait_for() { # wait_for <seconds> <command…>: until the command succeeds
    local deadline=$((SECONDS + $1))
    shift
    until "$@" >/dev/null 2>&1; do
        [ "$SECONDS" -lt "$deadline" ] || return 1
        sleep 0.25
    done
}
running() { [ "$(state "s['phase']")" == running ] && curl -sf -m 2 --unix-socket "$SOCK" http://d/_ping >/dev/null; }
exited() { # exited <name>: the guest reports the container exited
    [ "$(curl -sf -m 5 --unix-socket "$SOCK" "http://d/containers/$1/json" |
        python3 -c 'import sys,json; print(json.load(sys.stdin)["State"]["Status"])')" == exited ]
}
exit_code() {
    curl -sf -m 5 --unix-socket "$SOCK" "http://d/containers/$1/json" |
        python3 -c 'import sys,json; print(json.load(sys.stdin)["State"]["ExitCode"])'
}
# A digest of the guest's cache inventory: policy digest, scopes and their
# stores, and the per-unit sizes when the guest reports them (timestamps and
# lock state left out); then whether a gomod store is listed.
cache_units() {
    curl -sf -m 10 --unix-socket "$SOCK" http://d/micropod/caches | python3 -c '
import sys, json, hashlib
d = json.load(sys.stdin)
units = sorted((u["scope"], u["kind"], u["unit"], u["files"], u["bytes"]) for u in d.get("units") or [])
scopes = {k: sorted(v) for k, v in (d.get("scopes") or {}).items()}
inventory = {"policy": d.get("policyDigest"), "scopes": scopes, "units": units}
gomod = any("gomod" in kinds for kinds in scopes.values())
print(hashlib.sha256(json.dumps(inventory, sort_keys=True).encode()).hexdigest()[:16], "yes" if gomod else "no")'
}
apply_json() { # apply_json <file> [args…]: runs `update hvf apply`, prints its exit code
    local out="$1"
    shift
    set +e
    "$M" update hvf apply --json "$@" >"$out" 2>"$out.err"
    local code=$?
    set -e
    echo "$code"
}
field() { python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('$2'))" "$1"; }
rollback_json() { # rollback_json <file> [args…]: runs `update hvf rollback`, prints its exit code
    local out="$1"
    shift
    set +e
    "$M" update hvf rollback --json "$@" >"$out" 2>"$out.err"
    local code=$?
    set -e
    echo "$code"
}
writable() { [ -w "$1" ] && echo yes || echo no; }

echo "== install a flat machine into $ROOT_DIR"
if [ -e "$ROOT_DIR" ]; then "$M" machine stop >/dev/null 2>&1 || true; fi
for dir in "$ROOT_DIR" "$WS"; do
    remove_tree "$dir" # ours (checked above)
    mkdir -p "$dir"
    touch "$dir/$MARKER"
done
"$M" machine install --vmm "$VMM" --kernel "$KERNEL" --initrd "$INITRD" --tools "$TOOLS" \
    "${DISK_ARGS[@]}" --cache-disk-size 1g --cpus 2 --memory-mib 2048 --workspace "$WS" >/dev/null
"$M" runtime enable hvf >/dev/null
"$M" runtime use hvf >/dev/null # a stopped Apple runtime must not break name lookups
"$M" machine start >/dev/null
check "machine running on the flat layout" "$(loaded_id)" "$(basename "$(canon "$ROOT_DIR")")"

echo "== stage a second payload: nothing boots it before activation"
PAYLOAD2="$TMP/payload-2"
mkdir -p "$PAYLOAD2"
cp -c "$ROOT_DIR/micropod-vmm" "$ROOT_DIR/Image" "$ROOT_DIR/mp-hvf-init.cpio" "$PAYLOAD2/"
cp -cR "$ROOT_DIR/tools" "$PAYLOAD2/tools"
"$M" update hvf stage --from "$PAYLOAD2" --version 9.0.0-e2e --revision "$S" >/dev/null
LEGACY="$(link_id current)"
V2="$(link_id staged)"
check "the flat install was imported as current" "${LEGACY%%-*}" "legacy"
check "known-good is the imported flat install" "$(link_id known-good)" "$LEGACY"
check "staging left current alone" "$(link_id current)" "$LEGACY"
check "update pending" "$(hvf_status "s['updatePending']")" "True"
OLD_VMM="$(state "s['vmmPID']")"
kill -9 "$OLD_VMM" # this script's machine's VMM
wait_for 120 sh -c "[ \"\$(python3 -c \"import json; s=json.load(open('$ROOT_DIR/run/state.json')); print(s['restartCount'], s['phase'])\")\" = '1 running' ]"
check "the relaunch after kill -9 kept its payload" "$(loaded_id)" "$(basename "$(canon "$ROOT_DIR")")"
check "…and its VMM binary" "$(vmm_exe)" "$(canon "$ROOT_DIR")/micropod-vmm"
"$M" machine stop >/dev/null
"$M" machine start >/dev/null
check "a fresh start boots current, not the staged payload" "$(loaded_id)" "$LEGACY"
check "…and its VMM binary" "$(vmm_exe)" "$(canon "$ROOT_DIR")/versions/$LEGACY/micropod-vmm"
check "still pending" "$(hvf_status "s['updatePending']")" "True"

# After the kill -9 above: a guest crash fence may discard cache units an
# unclean stop left unsynced. Only what the update does is measured below.
echo "== workloads write a volume and a cache unit"
"$M" volume create --runtime hvf "$VOL" >/dev/null
"$M" run --runtime hvf --name "e2eupd-vol-$S" -v "$VOL:/data" "$IMAGE" -- sh -c "echo volume-$S > /data/marker" >/dev/null
"$M" run --runtime hvf --name "e2eupd-cache-$S" --label "io.micropod.cache=+gomod" \
    --label "io.micropod.cache.scope=$SCOPE" "$IMAGE" -- \
    sh -c "[ -n \"\$GOMODCACHE\" ] || exit 3; echo cache-$S > \"\$GOMODCACHE/e2eupd-marker\"" >/dev/null
for name in vol cache; do
    wait_for 60 exited "e2eupd-$name-$S" || echo "  (e2eupd-$name-$S did not exit)"
done
check "the volume container wrote its marker" "$(exit_code "e2eupd-vol-$S")" "0"
check "the cache container wrote into an attached gomod cache" "$(exit_code "e2eupd-cache-$S")" "0"
"$M" rm "e2eupd-vol-$S" >/dev/null
"$M" rm "e2eupd-cache-$S" >/dev/null
read -r CACHE_BEFORE CACHE_GOMOD < <(cache_units)
check "the cache inventory lists the gomod store" "$CACHE_GOMOD" "yes"

echo "== activation defers while a container runs, then switches over"
"$M" run --runtime hvf --name "e2eupd-busy-$S" "$IMAGE" -- sleep 600 >/dev/null
VMM_BEFORE="$(state "s['vmmPID']")"
code="$(apply_json "$OUT/apply-busy.json")"
check "apply with a running container defers (exit 75)" "$code:$(field "$OUT/apply-busy.json" action)" "75:deferred"
check "…and stopped nothing" "$(state "s['vmmPID']")" "$VMM_BEFORE"
check "…and current is unchanged" "$(link_id current)" "$LEGACY"
"$M" rm --force "e2eupd-busy-$S" >/dev/null
started=$(python3 -c 'import time; print(time.time())')
code="$(apply_json "$OUT/apply-v2.json")"
WALL_MS=$(python3 -c "import time; print(int((time.time() - $started) * 1000))")
check "apply once idle activates" "$code:$(field "$OUT/apply-v2.json" action)" "0:activated"
SWITCH_MS="$(field "$OUT/apply-v2.json" switchoverMilliseconds)"
echo "    switchover (old VMM exit -> guest _ping): ${SWITCH_MS} ms; whole apply incl. drain check, stop and probes: ${WALL_MS} ms"
check "current is the new payload" "$(link_id current)" "$V2"
check "known-good is the new payload" "$(link_id known-good)" "$V2"
check "the machine runs it" "$(loaded_id)" "$V2"
check "…from its own VMM binary" "$(vmm_exe)" "$(canon "$ROOT_DIR")/versions/$V2/micropod-vmm"
check "nothing pending" "$(hvf_status "s['updatePending']")" "False"

echo "== a broken payload rolls back to known-good by itself"
BROKEN="$TMP/payload-broken"
mkdir -p "$BROKEN"
cp -c "$ROOT_DIR/Image" "$ROOT_DIR/mp-hvf-init.cpio" "$BROKEN/"
cp -cR "$ROOT_DIR/tools" "$BROKEN/tools"
printf '#!/bin/sh\necho "broken micropod-vmm for the update gate" >&2\nexit 1\n' >"$BROKEN/micropod-vmm"
chmod 755 "$BROKEN/micropod-vmm"
"$M" update hvf stage --from "$BROKEN" --version 9.0.1-broken --revision "$S" --no-verify >/dev/null
BROKEN_ID="$(link_id staged)"
check "the broken payload is staged, not current" "$(link_id current)" "$V2"
PRE_UPDATE="$(loaded_id)"
code="$(apply_json "$OUT/apply-broken.json")"
check "apply of the broken payload rolls back (exit 1)" "$code:$(field "$OUT/apply-broken.json" action)" "1:rolled_back"
echo "    $(field "$OUT/apply-broken.json" detail)"
check "current is known-good again" "$(link_id current)" "$V2"
check "known-good unchanged" "$(link_id known-good)" "$V2"
check "the running payload is the pre-update one" "$(loaded_id)" "$PRE_UPDATE"
check "the guest answers" "$(running && echo yes || echo no)" "yes"
check "the broken payload stays staged, still pending" "$(hvf_status "s['updatePending']"):$(link_id staged)" "True:$BROKEN_ID"
check "…and status says why its apply failed" "$(hvf_status "bool(s.get('lastActivationFailure'))")" "True"
"$M" run --runtime hvf --name "e2eupd-check-$S" -v "$VOL:/data" --label "io.micropod.cache=+gomod" \
    --label "io.micropod.cache.scope=$SCOPE" "$IMAGE" -- \
    sh -c "cat /data/marker; cat \"\$GOMODCACHE/e2eupd-marker\"; sleep 600" >/dev/null
check "the volume kept its content" "$("$M" exec "e2eupd-check-$S" -- cat /data/marker)" "volume-$S"
check "the cache disk kept the marker" "$("$M" exec "e2eupd-check-$S" -- sh -c 'cat "$GOMODCACHE/e2eupd-marker"')" "cache-$S"
"$M" rm --force "e2eupd-check-$S" >/dev/null
read -r CACHE_AFTER _ < <(cache_units)
check "the cache inventory is unchanged" "$CACHE_AFTER" "$CACHE_BEFORE"

echo "== rollback --previous returns to the imported flat install through the probe"
code="$(rollback_json "$OUT/rollback-previous.json" --previous)"
check "rollback --previous activates the previous payload (exit 0)" "$code:$(field "$OUT/rollback-previous.json" action)" "0:activated"
check "current and known-good are the imported flat install" "$(link_id current):$(link_id known-good)" "$LEGACY:$LEGACY"
check "the machine runs it" "$(loaded_id)" "$LEGACY"
check "…from its own VMM binary" "$(vmm_exe)" "$(canon "$ROOT_DIR")/versions/$LEGACY/micropod-vmm"
check "the broken payload is no longer staged" "$(link_id staged)" "none"

echo "== a rollback that restarts: deferred while a container runs, then forced"
"$M" machine stop >/dev/null
ln -sfn "versions/$V2" "$ROOT_DIR/current" # current moved behind the updater's back
"$M" machine start >/dev/null
check "the machine runs a payload that is not known-good" "$(loaded_id):$(link_id known-good)" "$V2:$LEGACY"
"$M" run --runtime hvf --name "e2eupd-busy2-$S" "$IMAGE" -- sleep 600 >/dev/null
VMM_BEFORE="$(state "s['vmmPID']")"
code="$(rollback_json "$OUT/rollback-busy.json")"
check "rollback with a running container defers (exit 75)" "$code:$(field "$OUT/rollback-busy.json" action)" "75:deferred"
check "…and restarted nothing" "$(state "s['vmmPID']")" "$VMM_BEFORE"
code="$(rollback_json "$OUT/rollback-force.json" --force)"
check "rollback --force restarts onto known-good (exit 0)" "$code:$(field "$OUT/rollback-force.json" action)" "0:rolled_back"
check "the machine runs known-good" "$(loaded_id):$(link_id current)" "$LEGACY:$LEGACY"
check "the guest answers" "$(running && echo yes || echo no)" "yes"
"$M" rm --force "e2eupd-busy2-$S" >/dev/null 2>&1 || true

echo "== a store the earlier updater left is migrated, then applied through the probe"
ln -sfn "versions/$V2" "$ROOT_DIR/current"
rm -f "$ROOT_DIR/known-good" "$ROOT_DIR/staged"
chmod -R u+w "$ROOT_DIR/versions/$V2" "$ROOT_DIR/versions/$LEGACY"
check "status points at apply" "$(hvf_status "s['updatePending']")" "True"
code="$(apply_json "$OUT/apply-migrated.json")"
check "apply migrates the store and activates the pending payload" "$code:$(field "$OUT/apply-migrated.json" action)" "0:activated"
check "known-good is that payload, after its probe" "$(link_id known-good):$(loaded_id)" "$V2:$V2"
check "the version directories are read-only again" "$(writable "$ROOT_DIR/versions/$V2"):$(writable "$ROOT_DIR/versions/$LEGACY")" "no:no"

echo "== rollback by name is idempotent"
for attempt in 1 2; do
    code="$(rollback_json "$OUT/rollback-$attempt.json")"
    check "rollback #$attempt on known-good changes nothing" "$code:$(field "$OUT/rollback-$attempt.json" action)" "0:noop"
done
check "still on known-good" "$(link_id current):$(loaded_id)" "$V2:$V2"

python3 - "$OUT" "$SWITCH_MS" "$WALL_MS" "$PASS" "$FAIL" "$LEGACY" "$V2" "$CACHE_BEFORE" "$CACHE_AFTER" <<'PY'
import json, sys
out, switch, wall, ok, bad, legacy, v2, before, after = sys.argv[1:]
receipt = {"switchoverMilliseconds": int(switch) if switch.isdigit() else None, "applyMilliseconds": int(wall),
           "passed": int(ok), "failed": int(bad), "importedFlat": legacy, "activated": v2,
           "cacheUnitsBefore": before, "cacheUnitsAfter": after}
json.dump(receipt, open(f"{out}/receipt.json", "w"), indent=2)
PY
echo "receipt: $OUT/receipt.json"
echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
