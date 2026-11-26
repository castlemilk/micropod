"""Compare flat and per-job CPU parents with the ordinary two-engine CI workload."""

import argparse
import shutil
import signal
import tempfile
from datetime import UTC, datetime
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import sibling_ci
import sibling_slice_350
import sibling_tmpfs
from qualify import HERE, require, terminal
from sibling_ext4_cache import reserve_in_order


MODES = ("flat", "job")
SEED_ORDER = {250221: MODES, 250223: MODES[::-1], 250227: MODES[::-1], 250229: MODES}
LABEL = "io.micropod.bench.ci.job-cgroup"
DRIVER = "sibling-job-parent.py"


def create_fixed(cohort, create, parallel, mode):
    actual = {}
    original = cohort.cmd

    def command(*argv, **kw):
        if argv[0] != "run" or argv[argv.index("--name") + 1] not in cohort.names:
            return original(*argv, **kw)
        launch = [argv[0], "--label", LABEL + "=1", *argv[1:]]
        cid = original(*launch, **kw)
        actual[cid] = launch
        return cid

    with patch.object(cohort, "cmd", command if mode == "job" and cohort.arm == "A" else original):
        if cohort.arm == "A":
            with patch.object(sibling_ci, "parallel", lambda *a: reserve_in_order(parallel, *a)):
                inventory = create(cohort)
        else:
            inventory = create(cohort)
    sibling_slice_350.check_group_mapping(inventory)
    for job in inventory["jobs"]:
        labelled = mode == "job" and cohort.arm == "A"
        labels = job["docker_inspect"]["Config"]["Labels"]
        if labelled:
            require(labels.get(LABEL) == "1" and job["id"] in actual, "native job parent label was not applied")
            job["create_argv"] = actual[job["id"]]
        else:
            require(LABEL not in labels, "unexpected job parent label")
    return inventory


def workload(args):
    profile = sibling_slice_350.workload(SimpleNamespace(**vars(args), target_us=250))
    profile.guest_fair = None
    return profile


def run(args):
    import sibling_job_parent_evidence as evidence

    profile = workload(args)
    require(all(path is None or path.exists() for path in
                (profile.product, profile.page_kernel_pair, profile.ipvlan_kernel, profile.quiet_source,
                 profile.image_archive)), "job parent fixture needs its pinned input files")
    folder = Path(tempfile.mkdtemp(prefix=datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ-sibling-job-parent-"), dir=HERE))
    print(folder, flush=True)
    signal.signal(signal.SIGTERM, terminal.exit_on_signal)
    create, clean, parallel = sibling_ci.Siblings.create, sibling_ci.Siblings.clean, sibling_ci.parallel
    stage_scratch, qualify_scratch = sibling_tmpfs.stage, sibling_tmpfs.qualify
    ready_to_retire = False

    def stage(oci, work, output, mode):
        standard = stage_scratch(oci, work, output, mode)
        shutil.copyfile(__file__, output / DRIVER)
        return {**standard, **evidence.stage(oci, work, output), "job_parent": args.parent_mode,
                "job_parent_driver_sha256": terminal.digest(output / DRIVER)}

    def qualify(output, cohorts, mode, phase):
        nonlocal ready_to_retire
        qualify_scratch(output, cohorts, mode, phase)
        evidence.capture(output, cohorts, phase)
        if phase == "after":
            evidence.verify(output, evidence.read(output, "plan.json"),
                            evidence.read(output, "grouped-inventory.json"), evidence.boots(output),
                            require_retired=False)
            ready_to_retire = True

    def cleanup(cohort):
        clean(cohort)
        if cohort.arm == "A" and ready_to_retire:
            evidence.retire(folder, cohort)

    status = {"complete": False}
    try:
        with terminal.terminal_lock(), patch.object(sibling_tmpfs, "stage", stage), \
                patch.object(sibling_tmpfs, "qualify", qualify), \
                patch.object(sibling_ci.Siblings, "clean", cleanup), \
                patch.object(sibling_ci.Siblings, "create", lambda c: create_fixed(c, create, parallel, args.parent_mode)):
            sibling_ci.study(folder, profile)
        evidence.verify(folder, evidence.read(folder, "plan.json"), evidence.read(folder, "grouped-inventory.json"),
                        evidence.boots(folder))
        status["complete"] = True
    except BaseException as exc:
        status["error"] = str(exc) or type(exc).__name__
        raise
    finally:
        terminal.save(folder / "status.json", status)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--parent-mode", choices=MODES, required=True)
    parser.add_argument("--seed", type=int, choices=SEED_ORDER, required=True)
    for name in ("product", "page-kernel-pair", "ipvlan-kernel", "quiet-source"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--image-archive", type=Path)
    run(parser.parse_args())


if __name__ == "__main__":
    main()
