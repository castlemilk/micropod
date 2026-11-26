"""Replay calibrated XNU vCPU instructions, cycles and execution time around compiler windows."""
import argparse
import json
from pathlib import Path
from statistics import median

import sibling_compiler_runtime_host as probe
from qualify import require, terminal
from sibling_host_vcpu import deltas
from sibling_host_vcpu_results import CPUS, ZERO_256_MIB_SHA256, interval
from sibling_results import read


def hardware_counts(raw, pid, birth, *, stored_ticks=False):
    ticks = deltas(raw["before"], raw["after"])
    checked, scale = interval(raw if stored_ticks else {**raw, "level_tick_deltas": ticks}, pid, birth)
    counts = {}
    for cpu in CPUS:
        samples = [next(t for t in raw[point]["threads"] if str(t["vcpu_index"]) == cpu) for point in ("before", "after")]
        row = {"cpu_seconds": sum(checked[cpu]) * scale / 1e9}
        for key in ("level_instructions", "level_cycles"):
            start, end = [s[key] for s in samples]
            delta = [b - a for a, b in zip(start, end, strict=True)]
            require(len(delta) == 2 and min(delta) >= 0, "host hardware counters reset or changed shape")
            row[key] = delta
        counts[cpu] = row
    return counts


def verify_calibration(raw, pid, birth):
    shares = []
    for cpu, row in zip(CPUS, raw["runs"], strict=True):
        require(row["guest_cpu"] == int(cpu) and row["guest_mask"] == cpu and row["guest_sha256"] == ZERO_256_MIB_SHA256,
                "wrong guest thread-numbering workload")
        ticks, _ = interval(row, pid, birth)
        share = sum(ticks[cpu]) / sum(sum(r) for r in ticks.values())
        require(share == row["matching_host_thread_cpu_fraction"] and share >= .75, "unverified guest/host vCPU number")
        shares.append(share)
    cal = raw["instruction_calibration"]
    inputs = (probe.SHORT, probe.LONG, probe.LONG, probe.SHORT)
    counts = {n: [] for n in inputs}
    for n, row in zip(inputs, cal["runs"], strict=True):
        require(row["iterations"] == n and row["guest_mask"] == "0" and row["guest_result"] == n * 16,
                "calibration used a different guest CPU or instruction count")
        vcpu = hardware_counts(row, pid, birth)["0"]
        require(all(vcpu[key] == row[key] for key in ("level_instructions", "level_cycles")),
                "calibration host counters disagree with raw snapshots")
        counts[n].append(sum(vcpu["level_instructions"]))
    expected = probe.LOOP_INSTRUCTIONS * (probe.LONG - probe.SHORT)
    added = median(counts[probe.LONG]) - median(counts[probe.SHORT])
    fraction = added / expected
    require(expected == cal["expected_added_guest_instructions"] and added == cal["observed_added_host_instructions"]
            and fraction == cal["observed_over_expected"] and (abs(fraction - 1) <= .1) == cal["within_ten_percent"],
            "instruction calibration disagrees with raw captures")
    return {"minimum_numbering_fraction": min(shares), "observed_over_expected_instructions": fraction,
            "instruction_calibration_passed": abs(fraction - 1) <= .1}


def replay(folder, sha):
    plan = read(folder, "plan.json")
    idle = read(folder, "grouped-idle.json")
    cal = read(folder, "host-vcpu-calibration.json")
    jobs = read(folder, "grouped-inventory.json")
    saved = read(folder, "windows.json")
    where = plan["compiler_runtime"]
    result = {"mode": where, "seed": plan["seed"], "archive": folder.name, "engines": {}}
    for arm, field in (("A", "micropod_vmm"), ("B", "orbstack_helper")):
        pid = idle["pids"][field]
        birth, = [task["birth_ticks"] for task in idle["before"]["tasks"] if task["pid"] == pid]
        engine = verify_calibration(cal[arm], pid, birth)
        waves = []
        for i in range(4):
            tag = f"grouped-{i}-all"
            raw = read(folder, f"host-vcpu-{tag}-{arm}.json")
            require(raw["profiler_sha256"] == sha, "different XNU sampler product")
            counters = hardware_counts(raw, pid, birth, stored_ticks=True)
            builds = read(folder, f"{tag}-{arm}-go.json")
            homes = jobs[arm]["jobs"][32:40]
            require(len(builds) == len(homes) == 8, "missing pinned build job")
            starts, ends = [], []
            for b, job in zip(builds, homes, strict=True):
                home = job["home_cpu"]
                require(b["id"] == job["id"] and b["compiler_affinity"]["dispatcher"]["cpus_allowed_list"] == home,
                        "wrong compiler assignment")
                fields = b["stdout"].rstrip().splitlines()[-1].split()
                require(fields[0] == "end", "missing build completion")
                starts.append(b["started_unix_ns"])
                ends.append(int(fields[1]))
            require((max(ends) - min(starts)) / 1e9 == saved[tag][arm]["build"]["makespan_s"], "wrong job timing")
            last = homes[ends.index(max(ends))]["home_cpu"]
            instructions = {c: sum(r["level_instructions"]) for c, r in counters.items()}
            cycles = {c: sum(r["level_cycles"]) for c, r in counters.items()}
            require(min(cycles.values()) > 0 and min(instructions.values()) > 0, "empty host PMU window")
            wave = {"block": i, "last_build_cpu": last, "vcpu_counters": counters,
                    "vcpu_instructions": sum(instructions.values()), "vcpu_cycles": sum(cycles.values()),
                    "vcpu_cpu_seconds": sum(v["cpu_seconds"] for v in counters.values()),
                    "instructions_per_cycle": sum(instructions.values()) / sum(cycles.values()),
                    "last_over_other_instructions": instructions[last] / median(v for c, v in instructions.items() if c != last),
                    "last_over_other_cpu_seconds": counters[last]["cpu_seconds"] /
                    median(v["cpu_seconds"] for c, v in counters.items() if c != last)}
            waves.append(wave)
        result["engines"][arm] = {**engine, "windows": waves}
    return result


def report(score, profiler):
    check = json.loads(score.read_bytes())
    receipt = json.loads(profiler.read_bytes())
    require(all(terminal.digest(Path(receipt[k])) == receipt[k + "_sha256"] for k in ("binary", "source")),
            "host sampler does not match its receipt")
    boots = [boot["archive"] for s in check["by_seed"] for boot in s["boots"].values()]
    require(len(set(boots)) == len(boots) == 4, "expected the four scored boots")
    runs = [replay(score.parent / boot, receipt["binary_sha256"]) for boot in boots]
    guest = read(score.parent / boots[0], "host-vcpu-instruction-probe.json")
    require(all(read(score.parent / boot, "host-vcpu-instruction-probe.json") == guest for boot in boots)
            and terminal.digest(Path(guest["elf"])) == guest["binary_sha256"] and guest["instructions_per_iteration"] == 18,
            "guest assembly product differs between measurements")
    summary = {}
    for mode in ("inherit", "long"):
        summary[mode] = {}
        for arm in "AB":
            engines = [boot["engines"][arm] for boot in runs if boot["mode"] == mode]
            waves = [w for e in engines for w in e["windows"]]
            require(len(waves) == 8 and len(engines) == 2, "missing host or guest observations")
            summary[mode][arm] = {
                "minimum_numbering_fraction": min(e["minimum_numbering_fraction"] for e in engines),
                "instruction_calibration_ratios": [e["observed_over_expected_instructions"] for e in engines],
                "all_instruction_calibrations_passed": all(e["instruction_calibration_passed"] for e in engines),
                "window_medians": {k: median(w[k] for w in waves) for k in
                    ("vcpu_instructions", "vcpu_cycles", "vcpu_cpu_seconds", "instructions_per_cycle",
                     "last_over_other_instructions", "last_over_other_cpu_seconds")}}
    return {"host_profiler": receipt, "guest_instruction_loop": guest, "runs": runs, "summary": summary}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("score", type=Path)
    parser.add_argument("profiler_receipt", type=Path)
    args = parser.parse_args()
    print(json.dumps(report(args.score, args.profiler_receipt), indent=2))
