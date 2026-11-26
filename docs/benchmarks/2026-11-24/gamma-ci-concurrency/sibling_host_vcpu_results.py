"""Relate verified guest CPU numbering to the Mac scheduler's per-vCPU execution counters."""
import argparse
import json
from pathlib import Path
from statistics import median

import sibling_build_tail_results as tail
from qualify import require, terminal
from sibling_host_vcpu import deltas


ZERO_256_MIB_SHA256 = "a6d72ac7690f53be6ae46ba88506bd97302a093f7108472bd9efc3cefda06484"
CPUS = [str(i) for i in range(4)]


def interval(raw, pid, birth):
    before, after = raw["before"], raw["after"]
    for sample in (before, after):
        h = sample["header"]
        threads = sample["threads"]
        require(h["pid"] == pid and sample["birth_ticks"] == birth and
                h["level_names"] == ["Super", "Performance"] and h["levels"] == 2 and
                h["tick_numer"] > 0 and h["tick_denom"] > 0 and
                len(threads) == len({t["id"] for t in threads}) == 4 and
                {str(t["vcpu_index"]) for t in threads} == set(CPUS) and
                all(t["group"] == "vcpu" and len(t["level_cpu_ticks"]) == 2 for t in threads),
                "unexpected VMM identity, vCPU thread set or host performance levels")
    counts = deltas(before, after)
    require(counts == raw["level_tick_deltas"] and all(sum(t) > 0 for t in counts.values()),
            "host counter capture disagrees with its snapshots")
    return counts, before["header"]["tick_numer"] / before["header"]["tick_denom"]


def replay(folder, profiler):
    builds, plan, _ = tail.replay(folder)
    calibration = tail.read(folder, "host-vcpu-calibration.json")
    idle = tail.read(folder, "grouped-idle.json")
    result = {"archive": folder.name, "treatment": plan["compiler_affinity"], "seed": plan["seed"], "engines": {}}
    for arm, pid_field in (("A", "micropod_vmm"), ("B", "orbstack_helper")):
        pid = idle["pids"][pid_field]
        birth, = [p["birth_ticks"] for p in idle["before"]["tasks"] if p["pid"] == pid]
        probes = calibration[arm]["runs"]
        require([str(p["guest_cpu"]) for p in probes] == CPUS, "incomplete guest CPU calibration")
        shares = []
        for p in probes:
            cpu = str(p["guest_cpu"])
            require(p["guest_mask"] == cpu and p["guest_sha256"] == ZERO_256_MIB_SHA256,
                    "wrong calibration CPU mask or work")
            counts, _ = interval(p, pid, birth)
            share = sum(counts[cpu]) / sum(sum(row) for row in counts.values())
            require(share == p["matching_host_thread_cpu_fraction"] and share >= 0.75,
                    "guest CPU number did not identify the matching host thread")
            shares.append(share)
        waves = []
        for w in builds["windows"]:
            path = f"host-vcpu-grouped-{w['round']}-all-{arm}.json"
            raw = tail.read(folder, path)
            require(raw["profiler_sha256"] == profiler, "different host profiler binary")
            counts, tick_ns = interval(raw, pid, birth)
            seconds = {c: sum(ticks) * tick_ns / 1e9 for c, ticks in counts.items()}
            super_ticks = sum(t[0] for t in counts.values())
            all_ticks = sum(sum(t) for t in counts.values())
            wave = {"block": w["round"], "vcpu_cpu_seconds": seconds, "super_fraction": super_ticks / all_ticks,
                    "elapsed_host_seconds": (raw["after"]["monotonic_ns"] - raw["before"]["monotonic_ns"]) / 1e9,
                    "max_over_min_vcpu_cpu_seconds": max(seconds.values()) / min(seconds.values())}
            if plan["compiler_affinity"] == "home":
                last = w["engines"][arm]["last_finisher_vcpu"]
                wave["last_builder_vcpu"] = last
                wave["last_over_other_cpu_seconds"] = seconds[last] / median(s for c, s in seconds.items() if c != last)
                wave["last_has_least_host_cpu"] = seconds[last] == min(seconds.values())
            waves.append(wave)
        result["engines"][arm] = {"calibration_fractions": shares, "windows": waves}
    return result


def report(folders, product):
    receipt = json.loads(product.read_bytes())
    require(all(terminal.digest(Path(receipt[key])) == receipt[key + "_sha256"] for key in ("source", "binary")),
            "host profiler product changed")
    runs = [replay(folder, receipt["binary_sha256"]) for folder in folders]
    require(len(runs) == len({run["archive"] for run in runs}) == 4 and
            len({(r["seed"], r["treatment"]) for r in runs}) == 4, "expected four matched archives")
    summary = {}
    for level in ("home", "pool"):
        summary[level] = {}
        for arm in "AB":
            selected = [r["engines"][arm] for r in runs if r["treatment"] == level]
            require(len(selected) == 2, "missing treatment boot")
            waves = [w for engine in selected for w in engine["windows"]]
            data = {"windows": len(waves), "minimum_calibration_fraction": min(min(e["calibration_fractions"]) for e in selected),
                    "median_super_fraction": median(w["super_fraction"] for w in waves),
                    "minimum_super_fraction": min(w["super_fraction"] for w in waves),
                    "median_max_over_min_vcpu_cpu_seconds": median(w["max_over_min_vcpu_cpu_seconds"] for w in waves)}
            if level == "home":
                data.update(last_has_least_host_cpu_count=sum(w["last_has_least_host_cpu"] for w in waves),
                            median_last_over_other_cpu_seconds=median(w["last_over_other_cpu_seconds"] for w in waves))
            summary[level][arm] = data
    return {"profiler": receipt, "runs": runs, "summary": summary}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--product", required=True, type=Path)
    parser.add_argument("folders", type=Path, nargs=4)
    args = parser.parse_args()
    print(json.dumps(report(args.folders, args.product), indent=2))

