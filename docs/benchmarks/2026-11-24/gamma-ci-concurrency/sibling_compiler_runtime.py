"""Compare ordinary and long native compiler slices at fixed home CPU placement."""

import argparse
import hashlib
import json
import shutil
import signal
import tempfile
from datetime import UTC, datetime
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import sibling_build
import sibling_compiler_affinity as affinity
import sibling_group
from qualify import HERE, ROOT, require, terminal


MODES = ("inherit", "long")
SEEDS = (250211, 250213)
INHERITED_NS = {"A": 250000, "B": 2100000}
LONG_US = 2100
DRIVER = "sibling-compiler-runtime.py"
SOURCE = "sibling_compiler_runtime_linux.go"
PROBE = "/mpcheck/compiler-runtime"
DISPATCH_FILE = "go-dispatch-runtime.sh"
RESIDENTS_AFTER = "compiler-runtime-residents-after.json"
BASE_SOURCE_SHA = "2cda664d9ab2e275732ab6e224272dbbafc6d7262bbf561e6d167831fb01ea30"
DISPATCH = affinity.DISPATCH.replace(f"{affinity.PROBE} -dispatcher", f"{PROBE} -dispatcher", 1)


def launcher_source(original):
    require(hashlib.sha256(original.encode()).hexdigest() == BASE_SOURCE_SHA, "original compiler probe source differs")
    replacements = (
        ("slice.RequestedUS != 250", "slice.RequestedUS != 2100"),
        ("*buildSliceUS != 250", "*buildSliceUS != 2100"),
        ("0 or 250 microseconds", "0 or 2100 microseconds"),
    )
    for before, after in replacements:
        require(original.count(before) == 1, "unexpected original compiler probe guard")
        original = original.replace(before, after, 1)
    return original


def requested_us(mode, arm):
    require(mode in MODES and arm in INHERITED_NS, "unexpected compiler runtime mode or engine")
    return LONG_US if mode == "long" and arm == "A" else 0


def stage(folder, work, mode, env):
    require(mode in MODES, "unexpected compiler runtime")
    archived = folder / SOURCE
    archived.write_text(launcher_source((folder / affinity.SOURCE).read_text()))
    binary = work / "probe" / Path(PROBE).name
    terminal.invoke("go", "-C", ROOT / "guest/runner", "build", "-trimpath", "-buildvcs=false", "-o", binary,
                    archived, env={**env, "GOPROXY": "off"})
    (work / "probe" / DISPATCH_FILE).write_text(DISPATCH)
    (folder / DISPATCH_FILE).write_text(DISPATCH)
    shutil.copyfile(__file__, folder / DRIVER)
    return {"compiler_runtime": mode, "compiler_runtime_driver_sha256": terminal.digest(folder / DRIVER),
            "compiler_runtime_source_sha256": terminal.digest(archived),
            "compiler_runtime_probe_sha256": terminal.digest(binary),
            "compiler_runtime_dispatch_sha256": terminal.digest(folder / DISPATCH_FILE)}


def check_normal_runtime(threads, pid, mask, arm):
    sibling_build.check_http_policy(threads, pid, mask)
    require(all(thread["slice_ns"] == INHERITED_NS[arm] for thread in threads),
            "HTTP or resident process lost its stock slice")


def check_dispatch_runtime(proof, job, mode, arm, slot):
    sibling_build.check_dispatch_policy(proof, "normal", 0, sibling_build.compiler_mask(job, "home"),
                                       build_slice_us=requested_us(mode, arm), slot=slot)
    require(proof["slice"]["inherited_ns"] == INHERITED_NS[arm], "compiler inherited an unexpected worker slice")


class RuntimeBuildWave(sibling_build.BuildWave):
    def __init__(self, cohort, tag, block, folder, *, build_policy=None, build_slice_us=None):
        require(build_policy is None and build_slice_us is None and cohort.compiler_affinity == "home"
                and cohort.builders == 8 and cohort.build_nice == 0, "compiler runtime needs the fixed home workload")
        super().__init__(cohort, tag, block, folder)

    def run(self, i):
        cohort = self.cohort
        job = cohort.jobs[cohort.count + i]
        revision = f"sibling-{self.block}-{i}"
        argv = ["exec", job["id"], "nice", "-n", 0, "taskset", "-c", sibling_build.compiler_mask(job, "home"),
                PROBE, "-policy", "normal", "-build-slice-us", str(requested_us(cohort.compiler_runtime, cohort.arm)),
                "/bin/sh", "/mpcheck/" + DISPATCH_FILE, self.tag, revision, i, 0]
        result = terminal.invoke(*cohort.engine, *argv, timeout=120, check=False)
        return {"id": job["id"], "revision": revision, "code": result.returncode, "stdout": result.stdout,
                "stderr": result.stderr[-1500:], "exec_argv": argv}

    def start(self):
        cohort = self.cohort
        self.futures = [self.pool.submit(self.run, i) for i in range(cohort.builders)]
        sibling_build.await_marks([self.base / f"{self.tag}.go.{i}.ready" for i in range(cohort.builders)], self.futures)
        self.policies = []
        for i in range(cohort.builders):
            proof = json.loads((self.base / f"{self.tag}.go.{i}.policy").read_bytes())
            check_dispatch_runtime(proof, cohort.jobs[cohort.count + i], cohort.compiler_runtime, cohort.arm, i)
            self.policies.append(proof)
        (self.base / (self.tag + ".go")).touch(exist_ok=False)
        self.released = True
        paths = [self.base / f"{self.tag}.go.{i}.start" for i in range(cohort.builders)]
        sibling_build.await_marks(paths, self.futures)
        self.started = [int(path.read_text()) for path in paths]
        return max(self.started)


def resident_threads(cohort, parallel):
    def observe(job):
        pid = job["affinity"]["pid"]
        threads = json.loads(cohort.cmd("exec", job["id"], PROBE, "-inspect", pid))
        check_normal_runtime(threads, pid, sibling_group.process_mask(job), cohort.arm)
        return {"id": job["id"], "pid": pid, "threads": threads}

    return parallel(8, observe, cohort.jobs)


def run(args):
    import sibling_ci
    import sibling_compiler_affinity_evidence as affinity_evidence
    import sibling_compiler_slice_evidence as runtime_evidence
    import sibling_slice_350
    import sibling_tmpfs
    from sibling_ext4_cache import reserve_in_order

    profile = sibling_slice_350.workload(SimpleNamespace(**vars(args), target_us=250))
    profile.guest_fair = None
    profile.compiler_affinity = "home"
    files = (profile.product, profile.page_kernel_pair, profile.ipvlan_kernel, profile.quiet_source, profile.image_archive)
    require(all(path is None or path.exists() for path in files), "compiler runtime fixture needs its pinned inputs")
    folder = Path(tempfile.mkdtemp(prefix=datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ-sibling-compiler-runtime-"), dir=HERE))
    print(folder, flush=True)
    signal.signal(signal.SIGTERM, terminal.exit_on_signal)
    create, parallel, wave = sibling_ci.Siblings.create, sibling_ci.parallel, sibling_ci.Siblings.run_wave
    stage_build, qualify_scratch = sibling_build.stage, sibling_tmpfs.qualify

    def create_fixed(cohort):
        cohort.compiler_runtime = args.compiler_runtime
        if cohort.arm == "A":
            with patch.object(sibling_ci, "parallel", lambda *a: reserve_in_order(parallel, *a)):
                inventory = create(cohort)
        else:
            inventory = create(cohort)
        sibling_slice_350.check_group_mapping(inventory)
        for job, proof in zip(cohort.jobs, resident_threads(cohort, parallel), strict=True):
            job["runtime_threads"] = proof["threads"]
        return inventory

    def prepare(output, runner, work, engine, archive, *, build_policy=None, build_slice_us=None, env=None):
        standard = stage_build(output, runner, work, engine, archive, build_policy=build_policy,
                               build_slice_us=build_slice_us, env=env)
        return {**standard, **affinity.stage(output, work, "home", env), **affinity_evidence.stage(output),
                **stage(output, work, args.compiler_runtime, env), **runtime_evidence.stage(output)}

    def qualify(output, cohorts, mode, phase):
        qualify_scratch(output, cohorts, mode, phase)
        if phase == "before":
            affinity_evidence.qualify(output, cohorts, "home")
            runtime_evidence.qualify(output, cohorts, args.compiler_runtime)
        else:
            terminal.save(output / RESIDENTS_AFTER,
                          {arm: resident_threads(cohort, parallel) for arm, cohort in cohorts.items()})

    def run_wave(cohort, *wave_args):
        def check(threads, pid, mask):
            check_normal_runtime(threads, pid, mask, cohort.arm)

        # Preserve the canonical scoring and raw HTTP receipts. Use the richer
        # read-only inspector for the real issuing process in this fixture.
        with patch.object(sibling_group, "PROBE", PROBE), patch.object(sibling_group, "check_threads", check):
            return affinity_evidence.observe_wave(wave, cohort, *wave_args)

    status = {"complete": False}
    try:
        with terminal.terminal_lock(), patch.object(sibling_ci.Siblings, "create", create_fixed), \
                patch.object(sibling_build, "stage", prepare), patch.object(sibling_build, "BuildWave", RuntimeBuildWave), \
                patch.object(sibling_tmpfs, "qualify", qualify), patch.object(sibling_ci.Siblings, "run_wave", run_wave):
            sibling_ci.study(folder, profile)
        status["complete"] = True
    except BaseException as exc:
        status["error"] = str(exc) or type(exc).__name__
        raise
    finally:
        terminal.save(folder / "status.json", status)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler-runtime", choices=MODES, required=True)
    parser.add_argument("--seed", type=int, choices=SEEDS, required=True)
    for argument in ("product", "page-kernel-pair", "ipvlan-kernel", "quiet-source"):
        parser.add_argument("--" + argument, type=Path, required=True)
    parser.add_argument("--image-archive", type=Path)
    run(parser.parse_args())


if __name__ == "__main__":
    main()
