"""Check the local observation coverage and summarize whole pairs for the peer report."""

import argparse
import hashlib
import itertools
import json
import tarfile
from bisect import bisect_left, bisect_right
from datetime import datetime
from pathlib import Path
from statistics import median

from score import load, require, score


def journal(folder, name, stamp):
    records = [json.loads(line) for line in (folder / name).read_text().splitlines()]
    times = [datetime.fromisoformat(record[stamp]).timestamp() for record in records]
    require(times and times == sorted(times), f"{name} clock regressed")
    return times, records


def covering_samples(journal_data, start, end):
    times, records = journal_data
    left = bisect_right(times, start) - 1
    right = bisect_left(times, end)
    require(0 <= left < right < len(times), "monitor does not surround the timed client")
    span = times[left : right + 1]
    return records[left : right + 1], max(b - a for a, b in itertools.pairwise(span))


def audit(folder):
    result = score(folder)
    plan = load(folder / "plan.json")
    arms = load(folder / "fixtures-before.json")
    with tarfile.open(folder / "drivers.tar.gz") as archive:
        hashes = {
            Path(m.name).name: hashlib.sha256(archive.extractfile(m).read()).hexdigest()
            for m in archive.getmembers()
            if m.isfile()
        }
    require(all(hashes[k] == v for k, v in plan["driver_sha256"].items()), "admission source archive differs")
    logs = {
        key: journal(folder, file, stamp)
        for key, file, stamp in (
            ("disk", "disk.jsonl", "time"),
            ("host", "admission.jsonl", "utc"),
            ("orb", "orb-activity.jsonl", "time"),
        )
    }
    maximum_gaps = {key: 0 for key in logs}
    workload = {arm: [] for arm in arms}
    coverage = []
    for phase, pairs in plan["order"].items():
        for number, order in enumerate(pairs, 1):
            for arm in order:
                row = load(folder / f"{phase}-{number}-{arm}.json")
                client = json.loads(row["stdout"])
                start, end = (row[k] / 1e9 for k in ("client_spawn_start_ns", "client_reaped_ns"))
                for kind, data in logs.items():
                    observations, gap = covering_samples(data, start, end)
                    maximum_gaps[kind] = max(maximum_gaps[kind], gap)
                    if kind == "orb":
                        require(
                            all(s["running_ids"] == [arms["B"]["id"]] for s in observations),
                            "peer workload changed around client",
                        )
                before, after = row["interfaces_before"], row["interfaces_after"]
                require(before.keys() == after.keys(), "interface changed")
                interface = "mppub0" if arm == "A" else "eth0"
                require(after[interface]["tx_bytes"] > before[interface]["tx_bytes"], "missing service TX")
                drops = [
                    after[key][direction] - before[key][direction]
                    for key in before
                    for direction in ("rx_dropped", "tx_dropped")
                ]
                require(min(drops) >= 0, "interface counters reset")
                coverage.append((row["idle_pct"], row["paired_idle_gap_pp"]))
                if phase == "scored":
                    workload[arm].append(
                        {
                            "clean": row["clean"],
                            "bytes": client["bytes"],
                            "drops": sum(drops),
                            "dispatch_p95_us": client["dispatch_p95_us"],
                            "max_dispatch_us": client["dispatch_max_us"],
                            "p95_us": client["fresh_p95_us"],
                            "idle_pct": row["idle_pct"],
                        }
                    )
    order_ratios = {order: [] for order in ("AB", "BA")}
    lower_delay_gaps = []
    for pair, a, b in zip(result["pairs"], workload["A"], workload["B"]):
        if a["clean"] and b["clean"]:
            order_ratios[pair["order"]].append(pair["A"]["mib_s"] / pair["B"]["mib_s"])
            # All dispatch delays are nonnegative and at most the reported max.
            # Each integer-us timestamp truncates by <1 us. Allow two us for rounding.
            lower_delay_gaps.append(a["p95_us"] - a["max_dispatch_us"] - b["p95_us"] - 2)
    return {
        "timed_windows": len(coverage),
        "largest_monitor_interval_seconds": maximum_gaps,
        "idle_percent_range": [min(s[0] for s in coverage), max(s[0] for s in coverage)],
        "largest_paired_idle_gap_pp": max(s[1] for s in coverage if s[1] is not None),
        "median_throughput_ratio_by_order": {k: median(v) if v else None for k, v in order_ratios.items()},
        "scored": {
            arm: {
                "bytes": sum(r["bytes"] for r in rows),
                "interface_drops": sum(r["drops"] for r in rows),
                "max_fresh_p95_ms": max(r["p95_us"] for r in rows) / 1000,
                "median_dispatch_p95_us": median(r["dispatch_p95_us"] for r in rows),
                "max_dispatch_us": max(r["max_dispatch_us"] for r in rows),
            }
            for arm, rows in workload.items()
        },
        "latency_pairs_with_positive_lower_bound": sum(n > 0 for n in lower_delay_gaps),
        "min_micropod_post_dispatch_p95_minus_orbstack_scheduled_p95_us": min(lower_delay_gaps, default=None),
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("receipt", type=Path)
    print(json.dumps(audit(parser.parse_args().receipt.resolve()), indent=2, allow_nan=False))
