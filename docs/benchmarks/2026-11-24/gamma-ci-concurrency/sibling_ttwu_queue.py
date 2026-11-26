"""Compare TTWU_QUEUE on and off with the signed worker and stock dense CI workload."""

import argparse
import plistlib
import re
import shutil
from pathlib import Path
from unittest.mock import patch

import file_fault_around_common as knob
import sibling_file_fault_around as fault
import sibling_file_fault_around_holdout as holdout
import sibling_job_parent_evidence as parents
import sibling_sched
from qualify import HERE, require, terminal
from sibling_worker_volume import mounted_worker_volume


PREFIX = "sibling-ttwu-queue"
SEED_ORDER = {250263: ("on", "off"), 250267: ("off", "on")}
MODES = {"on": "TTWU_QUEUE", "off": "NO_TTWU_QUEUE"}
WINDOW = knob.DEFAULT_BYTES
SLICE = 250000
ARG = "micropod.bench_ttwu_queue"
SCHEMA = "micropod-ttwu-queue-v1"
BOOT = "ttwu-queue-boot.txt"
FINAL = "ttwu-queue-final.txt"
BOOT_SCRIPT = "ttwu-queue-boot.sh"
FINAL_SCRIPT = "ttwu-queue-read.sh"
START = "ttwu-queue-start.sh"
FACTS = "ttwu-queue-staged-facts.sh"
DRIVER = "sibling_ttwu_queue.py"
READY = "ttwu-queue-readiness.json"
MANIFEST = "sibling-file-fault-around-product.json"
SOURCES = (DRIVER, BOOT_SCRIPT, FINAL_SCRIPT, START, MANIFEST)
BOOT_INVOCATION = '\nsh /opt/micropod-oci/runner/ttwu-queue-boot.sh || exit 1\n'
_FAULT_POST_HOOK = fault.boot_hook


_DEBUG = r'''
isolated=$(mktemp -d)
debug="$isolated/debug"
mkdir "$debug"
trap 'rmdir "$debug" "$isolated"' EXIT
mount -t debugfs -o @OPTIONS@ debugfs "$debug"
trap 'status=$?; if ! umount "$debug" || ! rmdir "$debug" "$isolated"; then status=1; fi; exit "$status"' EXIT
sched="$debug/sched"
features() { awk '{$1=$1; print}' "$sched/features"; }
boot=$(cat /proc/sys/kernel/random/boot_id)
'''

BOOT_SOURCE = r'''set -eu
workspace=${MICROPOD_ENGINE_WORKSPACE:-}
[ "$(id -u)" = 0 ] && [ "${MICROPOD_ENGINE_API:-}" = 1 ] && [ -d "$workspace" ] || exit 1
arg=$(tr ' ' '\n' </proc/cmdline | sed -n '/^micropod\.bench_ttwu_queue=/p')
case "$arg" in
    micropod.bench_ttwu_queue=on) mode=on; selected=TTWU_QUEUE ;;
    micropod.bench_ttwu_queue=off) mode=off; selected=NO_TTWU_QUEUE ;;
    *) echo "Unknown or repeated private TTWU_QUEUE selection" >&2; exit 1 ;;
esac
''' + _DEBUG.replace("@OPTIONS@", "nosuid,nodev,noexec") + r'''
before=$(features)
base=$(cat "$sched/base_slice_ns")
window=$(cat "$debug/fault_around_bytes")
case " $before " in
    *' TTWU_QUEUE '*) ;;
    *) echo "TTWU_QUEUE was not enabled in the initial scheduler" >&2; exit 1 ;;
esac
[ "$base" = 250000 ] && [ "$window" = 65536 ] || { echo "Unexpected initial slice or fault window" >&2; exit 1; }
printf '%s' "$selected" > "$sched/features"
after=$(features)
updated_base=$(cat "$sched/base_slice_ns")
expected=$(printf '%s\n' "$before" | awk -v selected="$selected" '{for(i=1;i<=NF;i++) if($i=="TTWU_QUEUE") $i=selected; print}')
[ "$after" = "$expected" ] && [ "$updated_base" = "$base" ] || { echo "TTWU_QUEUE or scheduler readback differs" >&2; exit 1; }
file="$workspace/ttwu-queue-boot.txt"
[ ! -e "$file" ] && [ ! -L "$file" ] || exit 1
printf 'schema=micropod-ttwu-queue-v1\nboot_id=%s\nselection=%s\ninitial_base_slice_ns=%s\neffective_base_slice_ns=%s\ninitial_features=%s\neffective_features=%s\nfile_fault_around_bytes=%s\n' \
    "$boot" "$mode" "$base" "$updated_base" "$before" "$after" "$window" > "$file"
'''

FINAL_SOURCE = 'set -eu\n[ "$(id -u)" = 0 ]\n' + _DEBUG.replace("@OPTIONS@", "ro,nosuid,nodev,noexec") + r'''
base=$(cat "$sched/base_slice_ns")
state=$(features)
window=$(cat "$debug/fault_around_bytes")
printf 'schema=micropod-ttwu-queue-v1\nboot_id=%s\neffective_base_slice_ns=%s\neffective_features=%s\nfile_fault_around_bytes=%s\n' \
    "$boot" "$base" "$state" "$window"
'''


def post_hook():
    source = _FAULT_POST_HOOK()
    anchor = '''        printf '%s\\n' "$result" > "$output-status.tmp"\n'''
    require(source.count(anchor) == 1, "unknown stock post-work observer")
    read = '''        if [ "$result" = 0 ] && [ "$phase" = after ]; then
            ttwu_final="$workspace/ttwu-queue-final.txt"
            /bin/sh "$workspace/probe/ttwu-queue-read.sh" > "$ttwu_final.tmp" || result=$?
            if [ "$result" = 0 ]; then mv "$ttwu_final.tmp" "$ttwu_final"; fi
        fi
'''
    return source.replace(anchor, read + anchor, 1)


def launch_args(mode):
    require(mode in MODES, "invalid TTWU_QUEUE treatment")
    return [*fault.SCHEDULER_ARGS, knob.kernel_arg(WINDOW), f"{ARG}={mode}"]


def check_launch(folder, window, mode):
    require(window == WINDOW, "TTWU_QUEUE requires the stock file fault-around window")
    env = plistlib.loads((folder / "a/job.plist").read_bytes())["EnvironmentVariables"]
    facts = (folder / "a/guest-facts.txt").read_text().splitlines()
    line, = [s.removeprefix("cmdline=") for s in facts if s.startswith("cmdline=")]
    fair = (folder / "fair-scheduler/cmdline").read_text().strip()
    require(fair == line and env[fault.KERNEL_ENV].split() == launch_args(mode) == [
        token for token in line.split() if token.startswith(("micropod.ci_", knob.ARG + "=", ARG + "="))
    ], "native guest or scheduler did not receive the exact TTWU launch selection")


def feature_vector(tokens):
    bare = [name.removeprefix("NO_") for name in tokens]
    require(tokens and len(set(bare)) == len(tokens) and all(re.fullmatch(r"[A-Z][A-Z0-9_]*", x) for x in tokens),
            "invalid or duplicate scheduler features")
    return sorted(tokens)


def read_features(path, boot_id, *, before=False):
    pairs = [line.split("=", 1) for line in path.read_text().splitlines()]
    common = {"schema", "boot_id", "effective_base_slice_ns", "effective_features", "file_fault_around_bytes"}
    initial = {"selection", "initial_base_slice_ns", "initial_features"} if before else set()
    row = dict(pairs)
    require(len(pairs) == len(row) and set(row) == common | initial and row["schema"] == SCHEMA and
            row["boot_id"] == boot_id and re.fullmatch(knob.BOOT_ID, boot_id) is not None and
            row["effective_base_slice_ns"] == str(SLICE) and row["file_fault_around_bytes"] == str(WINDOW),
            "TTWU scheduler proof has a wrong boot, slice, or file-fault window")
    expected = {"boot_id": boot_id, "base_slice_ns": SLICE, "features": feature_vector(row["effective_features"].split()),
                "file_fault_around_bytes": WINDOW}
    if before:
        require(row["initial_base_slice_ns"] == str(SLICE), "TTWU changed the inherited fair slice")
        expected.update(selection=row["selection"], initial=feature_vector(row["initial_features"].split()))
    return expected


def check_features(folder, mode, boot_id, *, finished):
    boot = read_features(folder / BOOT, boot_id, before=True)
    initial = set(boot["initial"])
    scheduler = sibling_sched.read(folder / "fair-scheduler", "inherit", "hrtick-250us", True)
    require(boot["selection"] == mode and {"TTWU_QUEUE", "HRTICK", "NEXT_BUDDY", "PICK_BUDDY"} <= initial
            and boot["features"] == sorted((initial - {"TTWU_QUEUE"}) | {MODES[mode]})
            and scheduler == parents.read(folder, "fair-scheduler.json")
            and scheduler["before"] == scheduler["after"] == boot["features"]
            and scheduler["base_slice_ns"] == SLICE, "TTWU boot transition changed another scheduler feature or slice")
    effective = {key: value for key, value in boot.items() if key not in {"selection", "initial"}}
    if finished:
        require(read_features(folder / FINAL, boot_id) == effective, "live TTWU scheduler changed during the workload")
    return {"selection": mode, "initial": boot["initial"], **effective}


def readiness(folder, staged_facts):
    start = (folder / START).read_text()
    build = parents.read(folder, "worker-build.json")
    manifest = parents.read(folder, MANIFEST)
    packaged = Path(build["arena"]) / "micropod-oci-tools/runner/start.sh"
    require(build == parents.read(Path(manifest["current_product"]).parent, "product.json")
            and terminal.digest(packaged) == build["guest_start_sha256"] == manifest["new_bootstrap_sha256"],
            "unexpected signed fault-around parent")
    tag = '"$tools/runner/bin/job" recover'
    baseline = packaged.read_text().replace("apk add --no-cache", "apk --repositories-file /dev/null add --no-network")
    head, tail = baseline.split(tag)
    tail = tag + tail
    observer = 'if sh "$tools/runner/fixture-facts.sh"'
    require(start.startswith(head) and start.endswith(tail) and start.count(observer) == 1
            and start.index(observer) < start.index(tag), "terminal did not stage the standard pre-recovery facts hook")
    fair = (folder / "fair-scheduler.sh").read_text()
    require(staged_facts.count(BOOT_INVOCATION) == staged_facts.count(fair) == 1
            and staged_facts.index(BOOT_INVOCATION) < staged_facts.index(fair),
            "TTWU hook did not precede the standard fair capture")
    return {"packaged_start_sha256": terminal.digest(packaged), "staged_start_sha256": terminal.digest(folder / START),
            "staged_facts_sha256": terminal.digest(folder / FACTS), "fair_hook_sha256": terminal.digest(folder / "fair-scheduler.sh")}


def verify(folder, plan, boots):
    mode = plan["ttwu_queue"]
    require(mode in SEED_ORDER.get(plan["seed"], ()) and plan["file_fault_around_bytes"] == WINDOW and
            plan["host_worker_volume"] == "apfs-no-index" and plan["host_worker_volume_final_history"] is True
            and plan["ttwu_queue_sources"] == {name: terminal.digest(folder / name) for name in SOURCES}
            and (folder / BOOT_SCRIPT).read_text() == BOOT_SOURCE and (folder / FINAL_SCRIPT).read_text() == FINAL_SOURCE
            and (folder / parents.BOOT_HOOK).read_text() == post_hook(), "TTWU fixture or source differs")
    check_launch(folder, WINDOW, mode)
    require(readiness(folder, (folder / FACTS).read_text()) == parents.read(folder, READY),
            "TTWU staged readiness receipt differs")
    return check_features(folder, mode, boots["A"], finished=True)


def run(args):
    manifest_path = HERE / MANIFEST
    manifest = parents.read(HERE, MANIFEST)
    require(args.product.resolve() == Path(manifest["current_product"]).resolve(), "use the sealed fault-around product")
    mode = args.ttwu_queue
    stage, boot, capture, verify_holdout = holdout.stage, terminal.bootstrap_worker, parents.capture, holdout.verify
    oci_bundle = None

    def setup(oci, work, folder, window):
        nonlocal oci_bundle
        oci_bundle = oci
        (oci / "runner" / BOOT_SCRIPT).write_text(BOOT_SOURCE)
        with (oci / "runner/fixture-facts.sh").open("a") as file:
            file.write(BOOT_INVOCATION)
        (work / "probe" / FINAL_SCRIPT).write_text(FINAL_SOURCE)
        (folder / BOOT_SCRIPT).write_text(BOOT_SOURCE)
        (folder / FINAL_SCRIPT).write_text(FINAL_SOURCE)
        shutil.copyfile(__file__, folder / DRIVER)
        shutil.copyfile(manifest_path, folder / MANIFEST)
        shutil.copyfile(oci / "runner/start.sh", folder / START)
        return {**stage(oci, work, folder, window), "ttwu_queue": mode,
                "ttwu_queue_sources": {name: terminal.digest(folder / name) for name in SOURCES}}

    def bootstrap(job_id, path, manifest_dir):
        folder = Path(manifest_dir).parent
        require(oci_bundle is not None and Path(manifest_dir).name == "a", "unexpected TTWU bootstrap scope")
        shutil.copyfile(oci_bundle / "runner/fixture-facts.sh", folder / FACTS)
        terminal.save(folder / READY, readiness(folder, (folder / FACTS).read_text()))
        plist = plistlib.loads(path.read_bytes())
        env = plist["EnvironmentVariables"]
        wanted = launch_args(mode)
        require(env[fault.KERNEL_ENV].split() == wanted[:-1], "unexpected parent guest boot arguments")
        env[fault.KERNEL_ENV] = " ".join(wanted)
        path.write_bytes(plistlib.dumps(plist))
        shutil.copyfile(path, Path(manifest_dir) / path.name)
        return boot(job_id, path, manifest_dir)

    def observe(folder, cohorts, phase):
        capture(folder, cohorts, phase)
        name = BOOT if phase == "before" else FINAL
        shutil.copyfile(cohorts["A"].work / name, folder / name)
        check_features(folder, mode, parents.boots(folder)["A"], finished=phase == "after")

    def complete(folder, plan, inventory, boots):
        result = verify_holdout(folder, plan, inventory, boots)
        return {**result, "ttwu_queue": verify(folder, plan, boots)}

    args.fault_around_bytes = WINDOW
    with mounted_worker_volume(), patch.object(holdout, "PREFIX", PREFIX), \
            patch.object(holdout, "SEED_ORDER", {seed: (WINDOW,) for seed in SEED_ORDER}), \
            patch.object(holdout, "stage", setup), patch.object(holdout, "verify", complete), \
            patch.object(terminal, "bootstrap_worker", bootstrap), patch.object(parents, "capture", observe), \
            patch.object(fault, "boot_hook", post_hook), patch.object(fault, "check_launch", lambda f, w: check_launch(f, w, mode)):
        holdout.run(args)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    run_parser = parser.add_subparsers(dest="command", required=True).add_parser("run")
    run_parser.add_argument("--ttwu-queue", choices=tuple(MODES), required=True)
    run_parser.add_argument("--seed", type=int, choices=tuple(SEED_ORDER), required=True)
    for name in ("product", "page-kernel-pair", "ipvlan-kernel", "quiet-source"):
        run_parser.add_argument("--" + name, type=Path, required=True)
    run_parser.add_argument("--image-archive", type=Path)
    run(parser.parse_args())


if __name__ == "__main__":
    main()
