"""Compare timed log reads and Linux inotify on the same Tasks.Wait worker."""

import argparse
from pathlib import Path
import shutil
from unittest.mock import patch

from qualify import HERE, require, terminal
import sibling_file_fault_around as fault
import sibling_file_fault_around_holdout as holdout
import sibling_group
import sibling_job_parent_evidence as parents
import sibling_output_polling as previous
from sibling_worker_volume import mounted_worker_volume


ORDERS = {250277: ("stock", "notify"), 250279: ("notify", "stock")}
MANIFEST = "sibling-log-notification-product.json"
PACKAGER = "sibling_cri_log_watch_product.py"
DELTA = "cri-log-watch-delta.patch"
DRIVER = "sibling_log_notification.py"
TESTS = "linux-log-notify-tests.txt"
PARENT_PRODUCT_SHA = "28d82911155732e3208a64c99430740b85af6370666f1d061d15db416d0845b5"
SOURCE_NAMES = (DRIVER, MANIFEST, PACKAGER, DELTA, previous.START, previous.RUNNER_READ)


def check_tests(log, roots):
    started = [s.removeprefix("=== RUN   ") for s in log.splitlines() if s.startswith("=== RUN   ")]
    passed = [s.strip().split()[2] for s in log.splitlines() if s.strip().startswith("--- PASS: ")]
    require(log.splitlines()[-1] == "PASS" and sorted(started) == sorted(passed)
            and sorted(name for name in started if "/" not in name) == sorted(roots)
            and all(not any(marker in s for marker in ("SKIP:", "FAIL:")) for s in log.splitlines()),
            "the log watcher tests did not all run and pass on Linux")


def run(args):
    kit = parents.read(args.manifest.parent, args.manifest.name)
    candidate, parent = Path(kit["product"]), Path(kit["parent_product"])
    require(terminal.digest(parent) == PARENT_PRODUCT_SHA and terminal.digest(candidate) == kit["product_sha256"]
            and terminal.digest(candidate.parent / DELTA) == kit["delta_sha256"]
            and args.manifest.read_bytes() == (candidate.parent / "cri-log-watch-build.json").read_bytes(),
            "worker package or patch differs from the frozen candidate")
    mode = args.log_notification
    args.product = candidate if mode == "notify" else parent
    args.fault_around_bytes = 65536
    expected = kit["runner_sha256"] if mode == "notify" else kit["stock_rebuilt_sha256"]
    capture, base_stage, group_stage = parents.capture, holdout.stage, sibling_group.stage

    def stage(oci, work, folder, selected):
        fields = base_stage(oci, work, folder, selected)
        for source, name in ((Path(__file__), DRIVER), (args.manifest, MANIFEST),
                             (candidate.parent / PACKAGER, PACKAGER), (candidate.parent / DELTA, DELTA),
                             (oci / "runner/start.sh", previous.START)):
            shutil.copyfile(source, folder / name)
        for target in (work / "probe", folder):
            (target / previous.RUNNER_READ).write_text(previous.ENGINE_READER)
        require(terminal.digest(folder / previous.START) == previous.START_SHA, "ordinary boot script changed")
        return {**fields, "log_notification":mode, "log_notification_runner_sha256":expected,
                "log_notification_product_sha256":terminal.digest(args.product),
                "log_notification_sources":{name:terminal.digest(folder / name) for name in SOURCE_NAMES}}

    def stage_tests(folder, probe, _, env):
        fields = group_stage(folder, probe, candidate, env)
        require(fields["group_runner_test_sha256"] == kit["tests"]["sha256"] ==
                terminal.digest(probe / "group-runner.test"), "live Linux test suite differs from the sealed candidate")
        return fields

    def observe(folder, cohorts, phase):
        capture(folder, cohorts, phase)
        native = cohorts["A"]
        name = previous.readback_name(phase)
        shutil.copyfile(native.work / name, folder / name)
        boot = parents.boots(folder)["A"]
        live = previous.engine_readback(folder / name, boot, expected)
        if phase == "before":
            builder = native.jobs[native.count]
            result = native.cmd("exec", builder["id"], "/bin/sh", "-ec",
                                'export TMPDIR=/dev/shm MICROPOD_CRI_LOG_TEST_TMPFS=/dev/shm; exec /mpcheck/group-runner.test "$@"',
                                "log-tests", "-test.v", "-test.timeout=30s",
                                "-test.run", "^TestCRI(Log|Follow|Output)", timeout=45)
            (folder / TESTS).write_text(result + "\n")
            check_tests(result, kit["tests"]["roots"])
        else:
            require(live == previous.engine_readback(folder / previous.readback_name("before"), boot, expected),
                    "Docker engine changed during the run")

    with mounted_worker_volume(), patch.object(holdout, "PREFIX", "sibling-log-notify-holdout"), \
            patch.object(holdout, "SEED_ORDER", {seed:(65536,) for seed in ORDERS}), \
            patch.object(holdout, "stage", stage), patch.object(parents, "capture", observe), \
            patch.object(fault, "boot_hook", previous.boot_hook), \
            patch.object(sibling_group, "stage", stage_tests):
        holdout.run(args)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    run_parser = parser.add_subparsers(dest="command", required=True).add_parser("run")
    run_parser.add_argument("--log-notification", choices=("stock","notify"), required=True)
    run_parser.add_argument("--seed", type=int, choices=ORDERS, required=True)
    run_parser.add_argument("--manifest", type=Path, default=HERE / MANIFEST)
    for key in ("page-kernel-pair","ipvlan-kernel","quiet-source","image-archive"):
        run_parser.add_argument("--"+key,type=Path,required=True)
    run(parser.parse_args())
