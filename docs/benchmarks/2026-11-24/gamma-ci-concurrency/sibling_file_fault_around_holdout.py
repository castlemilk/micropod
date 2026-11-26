"""Run the file fault-around holdout with the stock dense CI workload."""

import argparse
from datetime import UTC, datetime
import os
from pathlib import Path
import plistlib
import random
import shutil
import signal
import tempfile
import time
from unittest.mock import patch

import file_fault_around_common as knob
from qualify import HERE, ROOT, require, terminal
import sibling_ci
import sibling_file_fault_around as discovery
from sibling_file_fault_around_evidence import CALIBRATION, MMAP, MMAP_SOURCE
from sibling_flat_holdout_build_results import SOURCES as STOCK_SOURCES
import sibling_job_parent
import sibling_job_parent_evidence as parents
import sibling_tmpfs
from sibling_worker_volume import mounted_worker_volume


SEED_ORDER = {250257: knob.WINDOWS[::-1], 250259: knob.WINDOWS}
PREFIX = "sibling-file-fault-around-holdout"
DRIVER = "sibling_file_fault_around_holdout.py"
STOCK = "file-fault-around-holdout-stock-builds.json"
WINDOWS = "file-fault-around-holdout-windows.json"
SOURCE_NAMES = (DRIVER, discovery.COMMON, discovery.MARKER, discovery.READBACK_SCRIPT)
STOCK_PROBE = ("cat /proc/sys/kernel/random/boot_id\n"
               "exec sha256sum -- /mpcheck/job.sh /mpcheck/go-dispatch.sh")


def stage(oci, work, folder, selected):
    marker = knob.stage_marker(oci)
    for source, name in ((Path(__file__), DRIVER), (Path(knob.__file__), discovery.COMMON),
                         (marker, discovery.MARKER), (Path(sibling_job_parent.__file__), sibling_job_parent.DRIVER)):
        shutil.copyfile(source, folder / name)
    final = "set -eu\n" + knob.FINAL_OBSERVER
    for path in (folder, work / "probe"):
        (path / discovery.READBACK_SCRIPT).write_text(final)
    with patch.object(parents, "BOOT", discovery.boot_hook()):
        membership = parents.stage(oci, work, folder)
    source = folder / MMAP_SOURCE
    shutil.copyfile(Path(__file__).with_name(MMAP_SOURCE), source)
    binary = work / "probe" / MMAP
    env = {**os.environ, "GOOS": "linux", "GOARCH": "arm64", "CGO_ENABLED": "0", "GOPROXY": "off"}
    terminal.invoke("go", "-C", ROOT / "guest/runner", "build", "-trimpath", "-buildvcs=false",
                    "-o", binary, source, env=env, timeout=120)
    return {**membership, "job_parent": "flat",
            "job_parent_driver_sha256": terminal.digest(folder / sibling_job_parent.DRIVER),
            "file_fault_around_holdout": True, "file_fault_around_bytes": selected,
            "file_fault_around_probes": {MMAP_SOURCE: terminal.digest(source), MMAP: terminal.digest(binary)},
            "file_fault_around_sources": {name: terminal.digest(folder / name) for name in SOURCE_NAMES}}


def stock_args(cid):
    return ["exec", cid, "/bin/sh", "-ec", STOCK_PROBE]


def observe_stock(cohorts):
    def read(cohort, job):
        argv = stock_args(job["id"])
        return {"id": job["id"], "argv": argv, "raw": cohort.cmd(*argv, timeout=12)}

    return {arm: sibling_ci.parallel(cohort.builders, lambda job: read(cohort, job),
                                    cohort.jobs[cohort.count:cohort.count + cohort.builders])
            for arm, cohort in cohorts.items()}


def check_stock(folder, inventory, boots, *, phases=("before", "after")):
    require({name: terminal.digest(folder / name) for name in STOCK_SOURCES} == STOCK_SOURCES,
            "archived build job or dispatcher differs from the stock source")
    witness = parents.read(folder, STOCK)
    bounds = witness["phase_bounds"]
    require(set(witness) == {*phases, "phase_bounds"} and set(bounds) == set(phases),
            "stock build digest phases differ")
    for phase in phases:
        start, end = (bounds[phase][name] for name in ("started_unix_ns", "finished_unix_ns"))
        require(type(start) is type(end) is int and 0 < start < end, "invalid stock digest clock bounds")
        require(set(witness[phase]) == set(inventory) == set(boots) == {"A", "B"}, "stock probe lacks both engines")
        for arm, rows in witness[phase].items():
            jobs = inventory[arm]["jobs"][32:40]
            expected = [boots[arm], *(f"{digest}  /mpcheck/{name}" for name, digest in STOCK_SOURCES.items())]
            require(len(jobs) == len(rows) == 8, "stock probe lacks the eight measured builders")
            for slot, (job, row) in enumerate(zip(jobs, rows, strict=True)):
                require(row["id"] == job["id"] and row["argv"] == stock_args(job["id"])
                        and row["raw"].splitlines() == expected,
                        f"{arm} slot {slot} has different live stock build bytes or boot in the {phase} phase")
    return dict(STOCK_SOURCES)


def check_host_windows(folder, plan):
    rows = parents.read(folder, WINDOWS)
    saved = parents.read(folder, "windows.json")
    before, after = (parents.read(folder, f"job-parent-{phase}.json") for phase in ("before", "after"))
    stock = parents.read(folder, STOCK)["phase_bounds"]
    orders = ["AB", "BA"] * 2
    random.Random(plan["seed"]).shuffle(orders)
    scheduled = [(block, mode, arm) for block, order in enumerate(orders) for mode in ("one", "all") for arm in order]
    require(len(rows) == len(scheduled) == 16 and len(saved) == 8, "host envelopes lack a complete stock study")
    last = before["host_finished_unix_ns"]
    for row, (block, mode, arm) in zip(rows, scheduled, strict=True):
        tag = f"grouped-{block}-{mode}"
        start, end = (row[key] for key in ("host_started_unix_ns", "host_finished_unix_ns"))
        require((row["block"], row["mode"], row["arm"]) == (block, mode, arm)
                and saved[tag]["order"] == orders[block] and set(saved[tag]) == {"order", "A", "B"}
                and type(start) is type(end) is int and 0 < last <= start < end,
                f"stock host wave order or clock disagrees at {tag}-{arm}")
        last = end
    mmap = parents.read(folder, CALIBRATION)
    require(stock["before"]["finished_unix_ns"] < before["host_started_unix_ns"]
            and last < stock["after"]["started_unix_ns"] < stock["after"]["finished_unix_ns"]
            <= mmap["host_started_unix_ns"] <= mmap["host_finished_unix_ns"] < after["host_started_unix_ns"],
            "stock byte and Go mapping probes did not bracket the workload")
    return rows


def verify(folder, plan, inventory, boots):
    selected = plan["file_fault_around_bytes"]
    require(plan["file_fault_around_holdout"] is True and selected in SEED_ORDER.get(plan["seed"], ())
            and plan["host_worker_volume"] == "apfs-no-index" and plan["host_worker_volume_final_history"] is True
            and "file_fault_around_dispatch_sources" not in plan and "worker_disk_cache" not in plan,
            "unexpected holdout plan or build instrumentation")
    discovery.check_launch(folder, selected)
    require(plan["file_fault_around_sources"] == {name: terminal.digest(folder / name) for name in SOURCE_NAMES}
            and (folder / discovery.MARKER).read_bytes() == knob.MARKER_TEXT
            and (folder / discovery.READBACK_SCRIPT).read_text() == "set -eu\n" + knob.FINAL_OBSERVER
            and (folder / parents.BOOT_HOOK).read_text() == discovery.boot_hook(), "private selection or observer source changed")
    probes = plan["file_fault_around_probes"]
    require(set(probes) == {MMAP, MMAP_SOURCE} and probes[MMAP_SOURCE] == terminal.digest(folder / MMAP_SOURCE)
            and len(probes[MMAP]) == 64 and all(c in "0123456789abcdef" for c in probes[MMAP]),
            "holdout Go-file probe provenance changed")
    topology = parents.verify(folder, plan, inventory, boots)
    policy = knob.read(folder, selected, boots["A"])
    volume = parents.read(folder, "a/host-volume-detached.json")
    require(volume["mounted"] is volume["image_exists"] is False
            and volume["result"]["persisted_policy"]["mounted_read_only"] is True, "missing retired APFS read-only history")
    return {"policy": policy, "native_paths": topology["native_paths"], "stock_sources": check_stock(folder, inventory, boots),
            "host_windows": check_host_windows(folder, plan),
            "mmap": discovery.check_mmap(folder, inventory["A"]["jobs"][32], boots["A"], selected)}


def run(args):
    profile = sibling_job_parent.workload(args)
    require(all(path is None or path.exists() for path in
                (profile.product, profile.page_kernel_pair, profile.ipvlan_kernel, profile.quiet_source,
                 profile.image_archive)), "file fault-around holdout needs its pinned fixture inputs")
    folder = Path(tempfile.mkdtemp(prefix=datetime.now(UTC).strftime(f"%Y%m%dT%H%M%SZ-{PREFIX}-"), dir=HERE))
    print(folder, flush=True)
    signal.signal(signal.SIGTERM, terminal.exit_on_signal)
    selected = args.fault_around_bytes
    create, clean, parallel = sibling_ci.Siblings.create, sibling_ci.Siblings.clean, sibling_ci.parallel
    base_stage, base_qualify = sibling_tmpfs.stage, sibling_tmpfs.qualify
    run_wave, base_boot = sibling_ci.Siblings.run_wave, terminal.bootstrap_worker
    boots, stock, windows = {}, {"phase_bounds": {}}, []
    retire = False

    def setup(oci, work, output, mode):
        return {**base_stage(oci, work, output, mode), **stage(oci, work, output, selected)}

    def bootstrap(job_id, path, manifest):
        require(Path(manifest) == folder / "a", "file fault-around only applies to the private native arm")
        plist = plistlib.loads(path.read_bytes())
        env = plist["EnvironmentVariables"]
        require(env[discovery.KERNEL_ENV].split() == discovery.SCHEDULER_ARGS, "unexpected private scheduler arguments")
        env[discovery.KERNEL_ENV] += " " + knob.kernel_arg(selected)
        path.write_bytes(plistlib.dumps(plist))
        shutil.copyfile(path, manifest / path.name)
        return base_boot(job_id, path, manifest)

    def qualify(output, cohorts, mode, phase):
        nonlocal retire
        base_qualify(output, cohorts, mode, phase)
        cohort = cohorts["A"]
        inventory = parents.read(output, "grouped-inventory.json")
        if phase == "before":
            boots.update(parents.boots(output))
            discovery.check_launch(output, selected)
            shutil.copyfile(cohort.work / knob.BOOT, output / knob.BOOT)
            knob.parse_readback((output / knob.BOOT).read_text(), selected, boots["A"], before_work=True)
        started = time.time_ns()
        stock[phase] = observe_stock(cohorts)
        bounds = stock["phase_bounds"]
        bounds[phase] = {"started_unix_ns": started, "finished_unix_ns": time.time_ns()}
        terminal.save(output / STOCK, stock)
        check_stock(output, inventory, boots, phases=tuple(bounds))
        if phase == "after":
            terminal.save(output / WINDOWS, windows)
            plan = parents.read(output, "plan.json")
            require(terminal.digest(cohort.work / "probe" / MMAP) == plan["file_fault_around_probes"][MMAP],
                    "staged Go mapping probe changed before calibration")
            discovery.calibrate(cohort, output, boots["A"], selected)
        parents.capture(output, cohorts, phase)
        if phase == "after":
            shutil.copyfile(cohort.work / knob.FINAL, output / knob.FINAL)
            knob.read(output, selected, boots["A"])
            check_host_windows(output, plan)
            parents.verify(output, plan, inventory, boots, require_retired=False)
            retire = True

    def wave(cohort, output, block, indices, requests, dense_ms, offered_rps):
        started = time.time_ns()
        result = run_wave(cohort, output, block, indices, requests, dense_ms, offered_rps)
        windows.append({"block": block, "mode": "all" if len(indices) > 1 else "one", "arm": cohort.arm,
                        "host_started_unix_ns": started, "host_finished_unix_ns": time.time_ns()})
        return result

    def cleanup(cohort):
        clean(cohort)
        if cohort.arm == "A" and retire:
            parents.retire(folder, cohort)

    status = {"complete": False}
    try:
        with terminal.terminal_lock(), patch.object(sibling_tmpfs, "stage", setup), \
                patch.object(terminal, "bootstrap_worker", bootstrap), patch.object(sibling_tmpfs, "qualify", qualify), \
                patch.object(sibling_ci.Siblings, "run_wave", wave), patch.object(sibling_ci.Siblings, "clean", cleanup), \
                patch.object(sibling_ci.Siblings, "create", lambda c: sibling_job_parent.create_fixed(c, create, parallel, "flat")):
            sibling_ci.study(folder, profile)
        verify(folder, parents.read(folder, "plan.json"), parents.read(folder, "grouped-inventory.json"), boots)
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
