"""Measure private file fault-around windows on the ordinary dense CI worker."""

import argparse
from datetime import UTC, datetime
import json
from pathlib import Path
import plistlib
import shutil
import signal
import tempfile
import time
from unittest.mock import patch

import file_fault_around_common as knob
from qualify import HERE, fanout, require, terminal
import sibling_build
import sibling_build_tail_results as tail
import sibling_ci
import sibling_file_fault_around_evidence as evidence
import sibling_job_parent
import sibling_job_parent_evidence as parents
import sibling_tmpfs
from sibling_worker_volume import mounted_worker_volume


SEED_ORDER = {250251: knob.WINDOWS, 250253: knob.WINDOWS[::-1]}
KERNEL_ENV = "MICROPOD_SANDBOX_KERNEL_ARGS"
SCHEDULER_ARGS = ["micropod.ci_sched=hrtick-250us", "micropod.ci_wakeup=next-buddy"]
READBACK_SCRIPT = "file-fault-around-read.sh"
MARKER = Path(knob.MARKER).name
DRIVER = "sibling_file_fault_around.py"
COMMON = "file_fault_around_common.py"


def boot_hook():
    anchor = '        mv "$output.tmp" "$output-tree.json"\n'
    require(parents.BOOT.count(anchor) == 1, "unexpected root observer hook")
    read = '''        if [ "$result" = 0 ] && [ "$phase" = after ]; then
            final="$workspace/@FINAL@"
            /bin/sh "$workspace/probe/@READ@" > "$final.tmp" || result=$?
            if [ "$result" = 0 ]; then mv "$final.tmp" "$final"; fi
        fi
'''.replace("@FINAL@", knob.FINAL).replace("@READ@", READBACK_SCRIPT)
    return parents.BOOT.replace(anchor, anchor + read, 1)


def setup(oci, work, folder, selected):
    marker = knob.stage_marker(oci)
    for source in (Path(__file__), Path(knob.__file__), marker, Path(sibling_job_parent.__file__)):
        archive = sibling_job_parent.DRIVER if source == Path(sibling_job_parent.__file__) else source.name
        shutil.copyfile(source, folder / archive)
    script = "set -eu\n" + knob.FINAL_OBSERVER
    (folder / READBACK_SCRIPT).write_text(script)
    (work / "probe" / READBACK_SCRIPT).write_text(script)
    with patch.object(parents, "BOOT", boot_hook()):
        membership = parents.stage(oci, work, folder)
    return {**membership, "job_parent": "flat", "job_parent_driver_sha256": terminal.digest(folder / sibling_job_parent.DRIVER),
            "file_fault_around_bytes": selected, "file_fault_around_probes": evidence.stage_probes(work, folder),
            "file_fault_around_sources": {name: terminal.digest(folder / name)
                                          for name in (DRIVER, COMMON, MARKER, READBACK_SCRIPT)}}


def check_launch(folder, selected):
    env = plistlib.loads((folder / "a/job.plist").read_bytes())["EnvironmentVariables"]
    args = [*SCHEDULER_ARGS, knob.kernel_arg(selected)]
    cmdline, = [line.removeprefix("cmdline=") for line in (folder / "a/guest-facts.txt").read_text().splitlines()
                if line.startswith("cmdline=")]
    actual = [token for token in cmdline.split() if token.startswith(("micropod.ci_", knob.ARG))]
    require(env[KERNEL_ENV].split() == actual == args, "live guest did not receive the exact private launch token")


def first_go_inode(folder):
    checked = set()
    for block in range(4):
        job = tail.read(folder, f"grouped-{block}-all-A-go.json")[0]
        for line in job["stdout"].splitlines()[:2]:
            checked.add(int(fanout.parse_job(line, 0)["toolchain_inode"]))
    require(len(checked) == 1 and min(checked) > 0, "first builder's verified Go executable inode changed")
    return checked.pop()


def check_mmap(folder, job, boot, selected):
    receipt = tail.read(folder, evidence.CALIBRATION)
    require(receipt["id"] == job["id"] and receipt["argv"] == ["exec", job["id"], "/mpcheck/" + evidence.MMAP]
            and receipt["code"] == 0 and not receipt["stderr"]
            and 0 < receipt["host_started_unix_ns"] <= receipt["host_finished_unix_ns"],
            "mmap reference used an unexpected measured native builder")
    return knob.check_mmap(json.loads(receipt["raw"]), boot, first_go_inode(folder), selected)


def calibrate(cohort, folder, boot, selected):
    job = cohort.jobs[cohort.count]
    argv = ["exec", job["id"], "/mpcheck/" + evidence.MMAP]
    started = time.time_ns()
    run = terminal.invoke(*cohort.engine, *argv, check=False, timeout=15)
    terminal.save(folder / evidence.CALIBRATION, {"id": job["id"], "argv": argv, "raw": run.stdout,
                                                "code": run.returncode, "stderr": run.stderr,
                                                "host_started_unix_ns": started, "host_finished_unix_ns": time.time_ns()})
    require(run.returncode == 0, f"private Go-file calibration failed: {run.stderr[-800:]}")
    return check_mmap(folder, job, boot, selected)


def verify(folder, plan, inventory, boots):
    selected = plan["file_fault_around_bytes"]
    require(selected in SEED_ORDER[plan["seed"]] and plan["host_worker_volume"] == "apfs-no-index"
            and plan["host_worker_volume_final_history"] is True and "worker_disk_cache" not in plan,
            "file fault-around requires the ordinary disk on a private APFS volume")
    check_launch(folder, selected)
    require(plan["file_fault_around_sources"] == {name: terminal.digest(folder / name)
                                                  for name in (DRIVER, COMMON, MARKER, READBACK_SCRIPT)}
            and (folder / MARKER).read_bytes() == knob.MARKER_TEXT
            and (folder / READBACK_SCRIPT).read_text() == "set -eu\n" + knob.FINAL_OBSERVER
            and (folder / parents.BOOT_HOOK).read_text() == boot_hook(), "private selection or observer source changed")
    evidence.check_sources(folder, plan)
    topology = parents.verify(folder, plan, inventory, boots)
    policy = knob.read(folder, selected, boots["A"])
    volume = tail.read(folder, "a/host-volume-detached.json")
    require(volume["mounted"] is volume["image_exists"] is False
            and volume["result"]["persisted_policy"]["mounted_read_only"] is True, "missing retired APFS read-only history")
    windows = {
        arm: [evidence.check_wave(folder, block, arm, inventory[arm]["jobs"][32:40], boots[arm]) for block in range(4)]
        for arm in "AB"
    }
    return {"policy": policy, "windows": windows, "native_paths": topology["native_paths"],
            "mmap": check_mmap(folder, inventory["A"]["jobs"][32], boots["A"], selected)}


def run(args):
    profile = sibling_job_parent.workload(args)
    require(all(path is None or path.exists() for path in
                (profile.product, profile.page_kernel_pair, profile.ipvlan_kernel, profile.quiet_source,
                 profile.image_archive)), "file fault-around needs its pinned fixture inputs")
    folder = Path(tempfile.mkdtemp(prefix=datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ-sibling-file-fault-around-"), dir=HERE))
    print(folder, flush=True)
    signal.signal(signal.SIGTERM, terminal.exit_on_signal)
    selected = args.fault_around_bytes
    create, clean, parallel, run_wave = (sibling_ci.Siblings.create, sibling_ci.Siblings.clean, sibling_ci.parallel,
                                        sibling_ci.Siblings.run_wave)
    base_stage, base_qualify = sibling_tmpfs.stage, sibling_tmpfs.qualify
    base_build, base_boot = sibling_build.stage, terminal.bootstrap_worker
    boots, retire = {}, False

    def stage(oci, work, output, mode):
        return {**base_stage(oci, work, output, mode), **setup(oci, work, output, selected)}

    def bootstrap(job_id, path, manifest):
        require(Path(manifest) == folder / "a", "file fault-around only applies to the private native arm")
        plist = plistlib.loads(path.read_bytes())
        env = plist["EnvironmentVariables"]
        require(env[KERNEL_ENV].split() == SCHEDULER_ARGS, "unexpected private worker scheduler arguments")
        env[KERNEL_ENV] += " " + knob.kernel_arg(selected)
        path.write_bytes(plistlib.dumps(plist))
        shutil.copyfile(path, manifest / path.name)
        return base_boot(job_id, path, manifest)

    def stage_build(output, runner, work, engine, archive, **kwargs):
        return {**base_build(output, runner, work, engine, archive, **kwargs),
                "file_fault_around_dispatch_sources": evidence.stage_dispatch(output, work)}

    def qualify(output, cohorts, mode, phase):
        nonlocal retire
        base_qualify(output, cohorts, mode, phase)
        cohort = cohorts["A"]
        if phase == "before":
            boots.update(parents.boots(output))
            check_launch(output, selected)
            shutil.copyfile(cohort.work / knob.BOOT, output / knob.BOOT)
            knob.parse_readback((output / knob.BOOT).read_text(), selected, boots["A"], before_work=True)
        else:
            calibrate(cohort, output, boots["A"], selected)
        parents.capture(output, cohorts, phase)
        if phase == "after":
            shutil.copyfile(cohort.work / knob.FINAL, output / knob.FINAL)
            knob.read(output, selected, boots["A"])
            plan = tail.read(output, "plan.json")
            parents.verify(output, plan, tail.read(output, "grouped-inventory.json"), boots, require_retired=False)
            retire = True

    def wave(cohort, output, block, indices, requests, dense_ms, offered_rps):
        tag = f"grouped-{block}-all-{cohort.arm}"
        dense = len(indices) > 1
        if dense:
            evidence.capture_memory(cohort, output, tag, "before")
        result = run_wave(cohort, output, block, indices, requests, dense_ms, offered_rps)
        if dense:
            evidence.capture_memory(cohort, output, tag, "after")
            evidence.collect_builds(cohort, output, tag, parallel)
            jobs = cohort.jobs[cohort.count:cohort.count + cohort.builders]
            evidence.check_wave(output, block, cohort.arm, jobs, boots[cohort.arm], result)
        return result

    def cleanup(cohort):
        clean(cohort)
        if cohort.arm == "A" and retire:
            parents.retire(folder, cohort)

    status = {"complete": False}
    try:
        with terminal.terminal_lock(), patch.object(sibling_tmpfs, "stage", stage), \
                patch.object(terminal, "bootstrap_worker", bootstrap), patch.object(sibling_build, "stage", stage_build), \
                patch.object(sibling_tmpfs, "qualify", qualify), patch.object(sibling_ci.Siblings, "run_wave", wave), \
                patch.object(sibling_ci.Siblings, "clean", cleanup), patch.object(
                    sibling_ci.Siblings, "create", lambda c: sibling_job_parent.create_fixed(c, create, parallel, "flat")):
            sibling_ci.study(folder, profile)
        verify(folder, tail.read(folder, "plan.json"), tail.read(folder, "grouped-inventory.json"), boots)
        status["complete"] = True
    except BaseException as exc:
        status["error"] = str(exc) or type(exc).__name__
        raise
    finally:
        terminal.save(folder / "status.json", status)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fault-around-bytes", required=True, type=int, choices=knob.WINDOWS)
    parser.add_argument("--seed", required=True, choices=SEED_ORDER, type=int)
    for name in ("product", "page-kernel-pair", "ipvlan-kernel", "quiet-source"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--image-archive", type=Path)
    args = parser.parse_args()
    with mounted_worker_volume():
        run(args)


if __name__ == "__main__":
    main()
