"""Summarize the controlled peer holdout's latency gap and bulk delivery distribution."""
import argparse
import json
from pathlib import Path
from statistics import median
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "gamma-local-peer"))
from score import load, require, score


def profile(folder):
    verdict = score(folder)
    require(verdict["common_clean_pairs"] == 16, "latency comparison needs all 16 clean pairs")
    phase = {"A": [], "B": []}
    pairs = []
    for pair in verdict["pairs"]:
        n = pair["pair"]
        clients = {}
        for arm in phase:
            raw = load(folder / f"scored-{n}-{arm}.json")
            client = json.loads(raw["stdout"])
            streams = client["per_stream_bytes"]
            require(len(streams) == 32 and all(type(x) is int and x > 0 for x in streams)
                    and sum(streams) == client["bytes"], "inconsistent delivery by stream")
            clients[arm] = client
            phase[arm].append({
                "slowest_eight_share_pct": 100 * sum(sorted(streams)[:8]) / client["bytes"],
                "dispatch_p95_us": client["dispatch_p95_us"],
            })
        a, b = clients["A"], clients["B"]
        pairs.append({
            "pair": n, "order": pair["order"],
            "micropod_p50_minus_orbstack_p95_us": a["fresh_p50_us"] - b["fresh_p95_us"],
            "p95_gap_us": a["fresh_p95_us"] - b["fresh_p95_us"],
            "p95_ratio": a["fresh_p95_us"] / b["fresh_p95_us"],
            # Every launch lag is between zero and the maximum in that arm.
            # Allow for quantization of both microsecond summaries.
            "post_dispatch_p95_gap_lower_bound_us": a["fresh_p95_us"] - a["dispatch_max_us"] - b["fresh_p95_us"] - 2,
        })
    cross = [p["micropod_p50_minus_orbstack_p95_us"] for p in pairs]
    return {
        "pairs": pairs, "micropod_p50_above_orbstack_p95_pairs": sum(g > 0 for g in cross),
        "micropod_p50_minus_orbstack_p95_range_us": [min(cross), max(cross)],
        "paired_median_p95_gap_us": median(p["p95_gap_us"] for p in pairs),
        "paired_median_p95_ratio": median(p["p95_ratio"] for p in pairs),
        "minimum_post_dispatch_p95_gap_lower_bound_us": min(p["post_dispatch_p95_gap_lower_bound_us"] for p in pairs),
        "per_arm_medians": {arm: {k: median(row[k] for row in rows) for k in rows[0]} for arm, rows in phase.items()},
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("receipt", type=Path)
    print(json.dumps(profile(parser.parse_args().receipt.resolve()), indent=2, allow_nan=False))
