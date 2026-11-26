"""Measure the Linux scheduler migration-cost threshold on the sealed CI worker."""

import argparse
from pathlib import Path
import shutil
from unittest.mock import patch

from qualify import HERE, require, terminal
import sibling_file_fault_around as fault
import sibling_file_fault_around_holdout as holdout
import sibling_job_parent_evidence as parents
import sibling_log_notification as notification
import sibling_output_polling as follower
from sibling_worker_volume import mounted_worker_volume


PREFIX = "sibling-migration-cost"
ORDERS = {250283: (500000, 62500), 250287: (62500, 500000)}
SCRIPT = "sched-migration-cost.sh"
DRIVER = "sibling_migration_cost.py"
PRODUCT_SHA = "fb8ac000ac36940926475d22f6fbb5c6a2b39d9face4f28ed690771aad49aa8c"
QUIET_SHA = "5635d4bcae1b780d2a3cdf9523231300f843657d099d74044d98d217cf21bda2"

# The boot caller and observer execute in the disposable native worker.
GUEST = r'''set -eu
[ "$(id -u)" = 0 ]
case "$1" in
    apply) case "$2" in 500000|62500) selected=$2 ;; *) exit 2 ;; esac
           options=nosuid,nodev,noexec ;;
    read)  [ "$#" = 1 ]; options=ro,nosuid,nodev,noexec ;;
    *) exit 2 ;;
esac
root=$(mktemp -d)
debug="$root/debug"
mkdir "$debug"
trap 'rmdir "$debug" "$root"' EXIT
mount -t debugfs -o "$options" debugfs "$debug"
trap 'status=$?; if ! umount "$debug" || ! rmdir "$debug" "$root"; then status=1; fi; exit "$status"' EXIT
knob="$debug/sched/migration_cost_ns"
before=$(cat "$knob")
if [ "$1" = apply ]; then
    [ "$before" = 500000 ] || { echo "Unexpected migration cost $before" >&2; exit 1; }
    printf '%s' "$selected" > "$knob"
    [ "$(cat "$knob")" = "$selected" ]
fi
printf 'boot_id=%s\ninitial_ns=%s\neffective_ns=%s\nbase_slice_ns=%s\nfeatures=%s\n' \
    "$(cat /proc/sys/kernel/random/boot_id)" "$before" "$(cat "$knob")" \
    "$(cat "$debug/sched/base_slice_ns")" "$(cat "$debug/sched/features")"
'''


def observer():
    source = follower.boot_hook()
    anchor = '        printf \'%s\\n\' "$result" > "$output-status.tmp"\n'
    require(source.count(anchor) == 1, "unknown native root observer")
    extra = '''        if [ "$result" = 0 ]; then
            file="$workspace/sched-migration-cost-$phase.txt"
            /bin/sh "$workspace/probe/sched-migration-cost.sh" read > "$file.tmp" || result=$?
            if [ "$result" = 0 ]; then mv "$file.tmp" "$file"; fi
        fi
'''
    return source.replace(anchor, extra + anchor)


def proof(folder, phase, boot, selected):
    path = folder / f"sched-migration-cost-{phase}.txt"
    pairs = [line.split("=", 1) for line in path.read_text().splitlines()]
    row = dict(pairs)
    features = sorted(row["features"].split())
    fair = parents.read(folder, "fair-scheduler.json")
    require(len(row) == len(pairs) == 5 and row == {
        "boot_id": boot, "initial_ns": str(500000 if phase == "boot" else selected),
        "effective_ns": str(selected), "base_slice_ns": "250000", "features": row["features"],
    } and features == fair["before"] == fair["after"]
        and {"HRTICK", "NEXT_BUDDY", "PICK_BUDDY", "TTWU_QUEUE"} <= set(features),
        f"scheduler boot or readback mismatch in {phase}")
    return row


def run(args):
    kit = parents.read(args.manifest.parent, args.manifest.name)
    args.product = Path(kit["product"])
    require(terminal.digest(args.product) == kit["product_sha256"] == PRODUCT_SHA
            and terminal.digest(args.quiet_source) == QUIET_SHA, "unexpected product or HTTP workload")
    selected = args.migration_cost_ns
    args.fault_around_bytes = 65536
    base_stage, capture, verify_holdout = holdout.stage, parents.capture, holdout.verify

    def stage(oci, work, folder, window):
        fields = base_stage(oci, work, folder, window)
        for output in (folder, oci / "runner", work / "probe"):
            (output / SCRIPT).write_text(GUEST)
        for output in (folder, work / "probe"):
            (output / follower.RUNNER_READ).write_text(follower.ENGINE_READER)
        hook = f'\n/bin/sh "/opt/micropod-oci/runner/{SCRIPT}" apply {selected} ' \
               '> "$MICROPOD_ENGINE_WORKSPACE/sched-migration-cost-boot.txt" || exit 1\n'
        facts = oci / "runner/fixture-facts.sh"
        with facts.open("a") as stream:
            stream.write(hook)
        shutil.copyfile(facts, folder / "sched-migration-cost-staged.sh")
        shutil.copyfile(__file__, folder / DRIVER)
        shutil.copyfile(args.manifest, folder / notification.MANIFEST)
        return {**fields, "migration_cost_ns": selected, "migration_cost_product_sha256": PRODUCT_SHA,
                "migration_cost_sources": {name: terminal.digest(folder / name) for name in
                                           (SCRIPT, DRIVER, notification.MANIFEST, follower.RUNNER_READ,
                                            "sched-migration-cost-staged.sh")}}

    def observe(folder, cohorts, phase):
        capture(folder, cohorts, phase)
        work = cohorts["A"].work
        boot = parents.boots(folder)["A"]
        phases = ("boot", "before") if phase == "before" else ("after",)
        for name in phases:
            filename = f"sched-migration-cost-{name}.txt"
            shutil.copyfile(work / filename, folder / filename)
            proof(folder, name, boot, selected)
        filename = follower.readback_name(phase)
        shutil.copyfile(work / filename, folder / filename)
        follower.engine_readback(folder / filename, boot, kit["runner_sha256"])

    def verify(folder, plan, inventory, boots):
        result = verify_holdout(folder, plan, inventory, boots)
        require(plan["migration_cost_ns"] == selected and plan["quiet_source_sha256"] == QUIET_SHA
                and parents.read(folder, "worker-build.json") == parents.read(args.product.parent, args.product.name)
                and plan["migration_cost_product_sha256"] == PRODUCT_SHA
                and (folder / SCRIPT).read_text() == GUEST
                and (folder / follower.RUNNER_READ).read_text() == follower.ENGINE_READER
                and all(terminal.digest(folder / name) == digest for name, digest in plan["migration_cost_sources"].items()),
                "migration-cost test product, stock workload or sources changed")
        states = {phase: proof(folder, phase, boots["A"], selected) for phase in ("boot", "before", "after")}
        require(states["before"] == states["after"], "scheduler changed during scored CI")
        engines = [follower.engine_readback(folder / follower.readback_name(phase), boots["A"], kit["runner_sha256"])
                   for phase in ("before", "after")]
        require(engines[0] == engines[1], "native engine changed during scored CI")
        return {**result, "migration_cost": states}

    with mounted_worker_volume(), patch.object(holdout, "PREFIX", PREFIX), \
            patch.object(holdout, "SEED_ORDER", {seed: (65536,) for seed in ORDERS}), \
            patch.object(holdout, "stage", stage), patch.object(holdout, "verify", verify), \
            patch.object(parents, "capture", observe), patch.object(fault, "boot_hook", observer):
        holdout.run(args)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    run_parser = parser.add_subparsers(dest="command", required=True).add_parser("run")
    run_parser.add_argument("--migration-cost-ns", type=int, choices=ORDERS[250283], required=True)
    run_parser.add_argument("--seed", type=int, choices=ORDERS, required=True)
    run_parser.add_argument("--manifest", type=Path, default=HERE / notification.MANIFEST)
    for name in ("page-kernel-pair", "ipvlan-kernel", "quiet-source", "image-archive"):
        run_parser.add_argument("--" + name, type=Path, required=True)
    run(parser.parse_args())
