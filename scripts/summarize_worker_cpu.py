"""Summarize the fixed-arrival rounds written by bench_published_ports.sh."""
import json
from pathlib import Path
from random import Random
from statistics import median
import sys


def summary(directory, rounds):
    engines = ("baseline", "candidate", "orbstack")
    samples = {}
    result = {"scored_rounds": rounds, "engines": {}, "paired": {}}
    for engine in engines:
        rows = {}
        failed = []
        for number in range(1, rounds + 1):
            path = directory / f"offered-scored-{number}-{engine}"
            if int(path.with_suffix(".status").read_text()) != 0:
                failed.append(number)
                continue
            rows[number] = json.loads(path.with_suffix(".json").read_text())
        samples[engine] = rows
        result["engines"][engine] = {
            "vm_cpus": int((directory / f"{engine}.resources").read_text().split()[0]),
            "clean_rounds": len(rows), "failed_rounds": failed,
            "median_mib_s": median(row["mib_s"] for row in rows.values()) if rows else None,
            "median_fresh_p95_ms": median(row["fresh_p95_us"] for row in rows.values()) / 1000 if rows else None,
        }

    for reference in ("baseline", "orbstack"):
        left, right = samples["candidate"], samples[reference]
        common = sorted(left.keys() & right.keys())
        ratios = [left[n]["mib_s"] / right[n]["mib_s"] for n in common]
        paired = {"common_clean_rounds": common, "candidate_wins": sum(r > 1 for r in ratios)}
        if common:
            paired["median_throughput_ratio"] = median(ratios)
            paired["median_fresh_p95_ratio"] = median(left[n]["fresh_p95_us"] / right[n]["fresh_p95_us"] for n in common)
        if len(common) >= 2:
            rng = Random(7317)
            draws = sorted(median(rng.choices(ratios, k=len(ratios))) for _ in range(10000))
            paired["throughput_ratio_ci95"] = [draws[250], draws[9749]]
        result["paired"][f"candidate_vs_{reference}"] = paired
    return result


if __name__ == "__main__":
    print(json.dumps(summary(Path(sys.argv[1]), int(sys.argv[2])), indent=2))
