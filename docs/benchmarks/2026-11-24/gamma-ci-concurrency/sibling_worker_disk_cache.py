"""Compare Virtualization.framework host caching modes on the ordinary CI disk."""

import argparse
from datetime import UTC, datetime
from pathlib import Path
import signal
import tempfile
from unittest.mock import patch

import sibling_ci
import sibling_job_parent
import sibling_tmpfs
import sibling_worker_disk_cache_evidence as evidence
from qualify import HERE, require, terminal


SEED_ORDER = {250231: evidence.MODES, 250233: evidence.MODES[::-1]}


def run(args):
    profile = sibling_job_parent.workload(args)
    require(all(path is None or path.exists() for path in
                (profile.product, profile.page_kernel_pair, profile.ipvlan_kernel, profile.quiet_source,
                 profile.image_archive)), "disk cache fixture needs its pinned input files")
    folder = Path(tempfile.mkdtemp(prefix=datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ-sibling-worker-disk-"), dir=HERE))
    print(folder, flush=True)
    signal.signal(signal.SIGTERM, terminal.exit_on_signal)
    create, parallel, run_wave = sibling_ci.Siblings.create, sibling_ci.parallel, sibling_ci.Siblings.run_wave
    stage_scratch, qualify_scratch = sibling_tmpfs.stage, sibling_tmpfs.qualify
    guest_boots, device = {}, None

    def stage(oci, work, output, mode):
        return {**stage_scratch(oci, work, output, mode), **evidence.stage(work, output, args.cache_mode, __file__)}

    def qualify(output, cohorts, mode, phase):
        qualify_scratch(output, cohorts, mode, phase)
        if phase == "before":
            guest_boots.update(evidence.boots(output))
            evidence.attachment(output, evidence.read(output, "plan.json"))
        else:
            require(device is not None, "native scored waves did not observe the worker disk")
            evidence.calibrate(cohorts["A"], output, guest_boots["A"], device)

    def wave(cohort, output, block, indices, requests, dense_ms, offered_rps):
        nonlocal device
        if cohort.arm != "A" or len(indices) == 1:
            return run_wave(cohort, output, block, indices, requests, dense_ms, offered_rps)
        require(len(indices) == 32 and cohort.layout == "grouped" and offered_rps == 64_000
                and dense_ms == 1500, "wrong paced workload for disk evidence")
        boot = guest_boots["A"]
        before = evidence.capture(cohort, output, evidence.filename(block, "before"), boot)
        if device is None:
            device = before["device"]
        require(device == before["device"], "worker disk settings changed across windows")
        result = run_wave(cohort, output, block, indices, requests, dense_ms, offered_rps)
        after = evidence.capture(cohort, output, evidence.filename(block, "after"), boot)
        evidence.check_window(output, block, before, after)
        return result

    status = {"complete": False}
    try:
        with terminal.terminal_lock(), patch.object(sibling_tmpfs, "stage", stage), \
                patch.object(sibling_tmpfs, "qualify", qualify), patch.object(sibling_ci.Siblings, "run_wave", wave), \
                patch.object(sibling_ci.Siblings, "create",
                             lambda c: sibling_job_parent.create_fixed(c, create, parallel, "flat")):
            sibling_ci.study(folder, profile)
        evidence.verify(folder, evidence.read(folder, "plan.json"),
                        evidence.read(folder, "grouped-inventory.json"), guest_boots)
        status["complete"] = True
    except BaseException as exc:
        status["error"] = str(exc) or type(exc).__name__
        raise
    finally:
        terminal.save(folder / "status.json", status)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-mode", required=True, choices=evidence.MODES)
    parser.add_argument("--seed", required=True, choices=SEED_ORDER, type=int)
    for name in ("product", "page-kernel-pair", "ipvlan-kernel", "quiet-source"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--image-archive", type=Path)
    args = parser.parse_args()
    from sibling_worker_volume import mounted_worker_volume
    with mounted_worker_volume():
        run(args)


if __name__ == "__main__":
    main()
