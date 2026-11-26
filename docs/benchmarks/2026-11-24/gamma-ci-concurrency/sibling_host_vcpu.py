"""Observe named host vCPU counters around each build and verify their guest numbering after timing."""
import hashlib
import json
import subprocess
import sys
from pathlib import Path
from unittest.mock import patch

from qualify import require, terminal
import sibling_build
import sibling_compiler_affinity
import sibling_tmpfs


def sample(binary, folder, arm):
    idle = json.loads((folder / "grouped-idle.json").read_bytes())
    pid = idle["pids"]["micropod_vmm" if arm == "A" else "orbstack_helper"]
    birth, = [task["birth_ticks"] for task in idle["before"]["tasks"] if task["pid"] == pid]
    raw = subprocess.check_output([str(binary), str(pid), "1"], text=True, timeout=4)
    header, snap = map(json.loads, raw.splitlines())
    require(header["pid"] == pid and snap["birth_ticks"] == birth, "host VM changed identity")
    vcpus = [row for row in snap["threads"] if row["group"] == "vcpu"]
    indices = [row.get("vcpu_index") for row in vcpus]
    require(len(vcpus) == 4 and set(indices) == set(range(4)) and
            all(len(row["level_cpu_ticks"]) == header["levels"] for row in vcpus),
            f"expected four numbered host vCPU threads, saw {indices}")
    return {"header": header, "birth_ticks": birth, "epoch_ns": snap["epoch_ns"], "monotonic_ns": snap["monotonic_ns"],
            "threads": vcpus, "other_threads_skipped": snap["skipped_threads"]}


def deltas(before, after):
    require(before["header"] == after["header"] and before["birth_ticks"] == after["birth_ticks"] and
            before["monotonic_ns"] < after["monotonic_ns"], "host VM process or clock changed")
    rows = {}
    prev = {t["vcpu_index"]: t for t in before["threads"]}
    for end in after["threads"]:
        cpu = end["vcpu_index"]
        start = prev[cpu]
        require(start["id"] == end["id"], "host vCPU thread replaced")
        values = [hi - lo for lo, hi in zip(start["level_cpu_ticks"], end["level_cpu_ticks"], strict=True)]
        require(values and min(values) >= 0, "counter reset across host vCPU samples")
        rows[str(cpu)] = values
    require(set(rows) == set(map(str, range(4))), "incomplete host vCPU counter interval")
    return rows


def attempt(fn, *args):
    try:
        return fn(*args)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        return {"unavailable": str(exc)}


def calibrate(binary, folder, cohort):
    # Zeroes flow through a pipe. The digest checks identical work on each CPU.
    block = bytes(1 << 20)
    digest = hashlib.sha256()
    for _ in range(256):
        digest.update(block)
    # Reuse the first broad-cpuset job after all scored work on both VMs.
    job = cohort.jobs[cohort.count]
    require(job["cgroup"]["cpuset.cpus.effective"] == "0-3", "calibration job has a narrower CPU set")
    script = """set -eu
awk '/^Cpus_allowed_list:/ {print $2}' /proc/self/status
head -c 268435456 /dev/zero | sha256sum
"""
    runs = []
    for cpu in range(4):
        before = sample(binary, folder, cohort.arm)
        response = cohort.cmd("exec", job["id"], "taskset", "-c", str(cpu), "sh", "-ec", script, timeout=10)
        after = sample(binary, folder, cohort.arm)
        mask, check = response.splitlines()
        require(mask == str(cpu) and check.split() == [digest.hexdigest(), "-"], "guest calibration workload differs")
        changes = deltas(before, after)
        totals = {i: sum(ticks) for i, ticks in changes.items()}
        share = totals[str(cpu)] / sum(totals.values()) if sum(totals.values()) else 0
        runs.append({"guest_cpu": cpu, "guest_sha256": digest.hexdigest(), "guest_mask": mask,
                     "before": before, "after": after, "level_tick_deltas": changes,
                     "matching_host_thread_cpu_fraction": share})
    return {"runs": runs, "all_numbering_checks_pass": all(r["matching_host_thread_cpu_fraction"] >= 0.75 for r in runs)}


def main():
    binary = Path(sys.argv.pop(1)).resolve(strict=True)
    claimed = terminal.digest(binary)
    start, finish, qualify = sibling_build.BuildWave.start, sibling_build.BuildWave.finish, sibling_tmpfs.qualify

    def observed_start(wave):
        wave.host_vcpu_before = attempt(sample, binary, wave.output.parent, wave.cohort.arm)
        return start(wave)

    def observed_finish(wave):
        builds = finish(wave)
        after = attempt(sample, binary, wave.output.parent, wave.cohort.arm)
        before = wave.host_vcpu_before
        record = {"profiler_sha256": claimed, "before": before, "after": after}
        if "unavailable" not in before and "unavailable" not in after:
            record["level_tick_deltas"] = attempt(deltas, before, after)
        terminal.save(wave.output.parent / f"host-vcpu-{wave.tag}.json", record)
        return builds

    def after_suite(folder, cohorts, mode, phase):
        qualify(folder, cohorts, mode, phase)
        if phase == "after":
            terminal.save(folder / "host-vcpu-calibration.json", {
                arm: attempt(calibrate, binary, folder, cohort) for arm, cohort in cohorts.items()
            })

    with patch.object(sibling_build.BuildWave, "start", observed_start), \
         patch.object(sibling_build.BuildWave, "finish", observed_finish), patch.object(sibling_tmpfs, "qualify", after_suite):
        sibling_compiler_affinity.main()


if __name__ == "__main__":
    main()

