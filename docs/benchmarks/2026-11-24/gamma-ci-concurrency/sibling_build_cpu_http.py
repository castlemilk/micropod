"""Relate HTTP latency during eight concurrent builds to the last builder's pinned guest CPU."""
import argparse
from collections import Counter
import json
from pathlib import Path
from statistics import median

from qualify import require
import sibling_build_tail_results as tail
import sibling_paced_results as paced


def nearest_p95(samples):
    require(samples, "missing per-CPU scheduled latencies")
    return sorted(samples)[(95 * len(samples) + 99) // 100 - 1]


def analyze_boot(folder):
    builds, plan, _ = tail.replay(folder)
    require(plan["offered_rps"] == 64_000 and plan.get("network_topology") == "per-job",
            "expected the dense fixed-rate per-job network workload")
    inventory = tail.read(folder, "grouped-inventory.json")
    windows = []
    for wave in builds["windows"]:
        for arm in "AB":
            jobs = inventory[arm]["jobs"]
            clients = jobs[paced.PAIRS:]
            cpus = {str(i) for i in range(4)}
            require(Counter(job["mask"] for job in clients) == {cpu: 8 for cpu in cpus} and
                    all(job["mask"] == job["cgroup"]["cpuset.cpus.effective"] for job in clients),
                    "the HTTP and build tasks must be pinned to the same single guest CPU")
            raw = paced.read_wire(folder, f"grouped-{wave['round']}-all-{arm}")
            computed = paced.score_wave(raw, jobs, plan["offered_rps"], 16_384 if arm == "A" else 4096)
            by_cpu = {cpu: [] for cpu in cpus}
            for row, job in zip(raw, clients, strict=True):
                by_cpu[job["mask"]].extend(a["latency_ns"] for a in row["receipt"]["pace"]["arrivals"])
            require(all(len(values) == 24_000 for values in by_cpu.values()) and computed["requests"] == 96_000,
                    "per-CPU request cohorts differ")
            p95 = {cpu: nearest_p95(values) for cpu, values in sorted(by_cpu.items())}
            last = wave["engines"][arm]["last_finisher_vcpu"]
            rank = 1 + sum(value > p95[last] for value in p95.values())
            other = median(value for cpu, value in p95.items() if cpu != last)
            windows.append({"round": wave["round"], "arm": arm, "last_builder_vcpu": last,
                            "scheduled_p95_ns_by_vcpu": p95, "rank_from_highest_p95": rank,
                            "last_over_other_median_p95": p95[last] / other})
    return {"run": folder.name, "seed": plan["seed"], "events": windows}


def summary(runs):
    events = [event for run in runs for event in run["events"]]
    report = {}
    for arm in "AB":
        own = [e for e in events if e["arm"] == arm]
        require(own, "missing engine")
        report[arm] = {"windows": len(own), "highest_p95_count": sum(e["rank_from_highest_p95"] == 1 for e in own),
                       "above_other_median_count": sum(e["last_over_other_median_p95"] > 1 for e in own),
                       "median_last_over_other_p95": median(e["last_over_other_median_p95"] for e in own)}
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folders", nargs="+", type=Path)
    folders = parser.parse_args().folders
    require(len(folders) == len({f.resolve() for f in folders}), "duplicate archive")
    runs = [analyze_boot(folder) for folder in folders]
    print(json.dumps({"runs": runs, "summary": summary(runs)}, indent=2))

