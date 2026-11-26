"""Collect XNU vCPU counters alongside the compiler runtime fixture and calibrate guest instructions."""
import json
import shutil
import sys
from pathlib import Path
from statistics import median
from unittest.mock import patch

from qualify import require, terminal
import sibling_build
import sibling_host_vcpu as host
import sibling_tmpfs


SHORT, LONG = 2**20, 2**24
LOOP_INSTRUCTIONS = 18


def measure(capture, execute):
    runs = []
    for iterations in (SHORT, LONG, LONG, SHORT):
        before = capture()
        mask, n, result = execute(iterations).split()
        require(mask == "0" and int(n) == iterations and int(result) == 16 * iterations,
                "guest arithmetic or affinity differs")
        after = capture()
        host.deltas(before, after)
        counts = {}
        for key in ("level_instructions", "level_cycles"):
            a = next(t for t in before["threads"] if t["vcpu_index"] == 0)
            b = next(t for t in after["threads"] if t["vcpu_index"] == 0)
            delta = [hi - lo for lo, hi in zip(a[key], b[key], strict=True)]
            require(len(delta) == 2 and min(delta) >= 0, "missing or reset host PMU counter")
            counts[key] = delta
        runs.append({"iterations": iterations, "guest_mask": mask, "guest_result": int(result),
                     "before": before, "after": after, **counts})
    instructions = lambda n: median(sum(r["level_instructions"]) for r in runs if r["iterations"] == n)
    observed = instructions(LONG) - instructions(SHORT)
    expected = LOOP_INSTRUCTIONS * (LONG - SHORT)
    return {"runs": runs, "expected_added_guest_instructions": expected, "observed_added_host_instructions": observed,
            "observed_over_expected": observed / expected, "within_ten_percent": abs(observed / expected - 1) <= 0.10}


def main():
    import sibling_compiler_runtime

    guest = Path(sys.argv.pop(1)).resolve(strict=True)
    sampler = Path(sys.argv.pop(1)).resolve(strict=True)
    sampler_sha = terminal.digest(sampler)
    product = json.loads(guest.with_name("product.json").read_bytes())
    require(terminal.digest(guest) == product["binary_sha256"] and
            terminal.digest(guest.with_name("disassembly.txt")) == product["disassembly_sha256"] and
            product["instructions_per_iteration"] == LOOP_INSTRUCTIONS and
            all(terminal.digest(guest.with_name(n)) == h for n, h in product["sources"].items()),
            "guest instruction calibration binary or assembly changed")
    prepare = sibling_build.stage
    wave_class = sibling_compiler_runtime.RuntimeBuildWave
    start, finish, qualify = wave_class.start, wave_class.finish, sibling_tmpfs.qualify

    def stage(output, runner, work, engine, archive, **kwargs):
        result = prepare(output, runner, work, engine, archive, **kwargs)
        shutil.copy2(guest, work / "probe/vcpu-instructions")
        terminal.save(output / "host-vcpu-instruction-probe.json", product)
        return result

    def calibrated(binary, folder, cohort):
        numbering = host.calibrate(binary, folder, cohort)
        job = cohort.jobs[cohort.count]
        require(job["cgroup"]["cpuset.cpus.effective"] == "0-3", "guest counter witness lost its cpuset")
        capture = lambda: host.sample(binary, folder, cohort.arm)
        def execute(n):
            return cohort.cmd("exec", job["id"], "taskset", "-c", "0", "/mpcheck/vcpu-instructions", str(n), timeout=12)
        return {**numbering, "instruction_calibration": host.attempt(measure, capture, execute)}

    def observed_start(wave):
        wave.host_vcpu_before = host.attempt(host.sample, sampler, wave.output.parent, wave.cohort.arm)
        return start(wave)

    def observed_finish(wave):
        rows = finish(wave)
        after = host.attempt(host.sample, sampler, wave.output.parent, wave.cohort.arm)
        before = wave.host_vcpu_before
        record = {"profiler_sha256": sampler_sha, "before": before, "after": after}
        if "unavailable" not in before and "unavailable" not in after:
            record["level_tick_deltas"] = host.attempt(host.deltas, before, after)
        terminal.save(wave.output.parent / f"host-vcpu-{wave.tag}.json", record)
        return rows

    def observed_qualify(folder, cohorts, mode, phase):
        qualify(folder, cohorts, mode, phase)
        if phase == "after":
            terminal.save(folder / "host-vcpu-calibration.json", {
                arm: host.attempt(calibrated, sampler, folder, cohort) for arm, cohort in cohorts.items()
            })

    with patch.object(sibling_build, "stage", stage), patch.object(wave_class, "start", observed_start), \
         patch.object(wave_class, "finish", observed_finish), patch.object(sibling_tmpfs, "qualify", observed_qualify):
        sibling_compiler_runtime.main()


if __name__ == "__main__":
    main()

