"""Recompute the two archived host-pump read-size screens. No services are contacted.

Run python3 -B scripts/relaybench/chunk_replay.py to reproduce the JSON receipt.
The fixed-arrival rates and the earlier separate bursts each use their own
256 KiB control in the same block. Their latency measurements have different
loads. The paired bootstrap interval describes historical blocks only.
"""
import hashlib
import json
import math
from statistics import median

from gamma_contrasts import ROOT, clean_client, paired_median_interval, read_receipt


DIRECTORY = ROOT / "docs/benchmarks/2026-11-21"
MIXED = "gamma-mixed-scheduler.json.gz"
BURSTS = "gamma-published-profile.json.gz"
MIXED_SHA = "9e3b184de862aafacff47312878441e940d030e8cfc8342c0e479d064f4724c8"
BURSTS_SHA = "234f8f89de4462068e31934a8b1fc0ec6ecc93d814dd2da97b13c574481ebe93"
MIXED_DRIVER_SHA = "75373380a6afcdffb2edc3f17dfc391b9e5b290235a0dea7dc2b9bd66e98d042"
P95_LIMIT_MS = 75
# The earlier JSON has numeric round IDs. These orders were read from the
# original chunks.sh and checked against completion order of all 18 originals.
BURST_ORDERS = ("128 256 512", "256 512 128", "512 128 256", "512 256 128", "128 512 256", "256 128 512")


def paired(blocks, size, rate, *, fixed_arrivals):
    common = []
    for block in blocks:
        control, candidate = (block["arms"][arm] for arm in ("256", size))
        if not fixed_arrivals or (control["clean"] and candidate["clean"]):
            common.append((block, candidate[rate] / control[rate]))
    ratios = [ratio for _, ratio in common]
    return {
        "common_block_ids": [block["id"] for block, _ in common],
        "candidate_ran_before_control": sum(block["order"].index(size) < block["order"].index("256")
                                            for block, _ in common),
        "wins": sum(ratio > 1 for ratio in ratios),
        "median_ratio": median(ratios) if ratios else None,
        "paired_bootstrap_ci95": paired_median_interval(ratios),
    }


def mixed():
    study = read_receipt(DIRECTORY / MIXED, MIXED_SHA)
    records = study["records"]
    driver = records["fixtures/chunk-screen.sh"].encode()
    if hashlib.sha256(driver).hexdigest() != MIXED_DRIVER_SHA:
        raise ValueError("unexpected mixed-load chunk driver")
    # chunks.sh calls this rotation over seven modes. Keep even modes outside
    # our comparison in the order so its positional balance can be inspected.
    modes = ("stock", "256", "512", "1024", "2048", "nested1024", "orb")
    sizes = modes[1:5]
    original = records["fixtures/flat.c"].encode()
    definition = b"#define CHUNK (256 * 1024)"
    if original.count(definition) != 1:
        raise ValueError("expected one read-size definition in the flat relay")
    blocks = []
    for i in range(7):
        arms = {}
        for size in sizes:
            sample = records[f"chunks/{i}-flat{size}.json"]
            arms[size] = {"mib_s": sample["mib_s"], "fresh_p95_ms": sample["fresh_p95_us"] / 1000,
                          "clean": clean_client(sample)}
        order = [modes[(pos + i) % 7] for pos in (0, 1, 6, 2, 5, 3, 4)]
        blocks.append({"id": i, "order": order, "arms": arms})
    return {
        "archive": MIXED, "archive_sha256": MIXED_SHA, "guest": study["platform"],
        "driver": "records.fixtures/chunk-screen.sh", "driver_sha256": MIXED_DRIVER_SHA,
        "relay_source": "records.fixtures/flat.c",
        "relay_source_sha256_by_kib": {
            size: hashlib.sha256(original.replace(definition, f"#define CHUNK ({size} * 1024)".encode())).hexdigest()
            for size in sizes},
        "client_sha256": study["sha256"]["fixed-client"],
        "workload": "Same service via detached flat queues (MP_FLAT=24). One write per ready endpoint, "
                    "32 warm streams, 240 fresh requests scheduled at 25 ms over six seconds.",
        "policy": "Pair rates only when both fixed-load clients are clean. Keep every p95 above 75 ms visible, "
                  "including on otherwise clean rounds. Exceeding the limit on any round misses the tail criterion.",
        "blocks": blocks,
        "latency_by_kib": {
            size: {"median_round_p95_ms": median(b["arms"][size]["fresh_p95_ms"] for b in blocks),
                   "p95_over_75ms_blocks": [b["id"] for b in blocks if b["arms"][size]["fresh_p95_ms"] > P95_LIMIT_MS]}
            for size in sizes},
        "rate_vs_256": {size: paired(blocks, size, "mib_s", fixed_arrivals=True) for size in sizes[1:]},
    }


def bursts():
    study = read_receipt(DIRECTORY / BURSTS, BURSTS_SHA)
    rows = sorted(study["experiments"]["chunk_kib"], key=lambda row: row["round"])
    if [row["round"] for row in rows] != list(range(1, 7)):
        raise ValueError("expected six distinct burst rounds")
    blocks = []
    for row, order in zip(rows, BURST_ORDERS):
        arms = {}
        for size in order.split():
            sample = row["engines"][size]
            runs = sample["parallel_bursts_mib_s"]
            if not (sample["requests"] == 100 and sample["bulk_bytes"] == 64 * 2**20
                    and sample["parallel_streams"] == 32 and sample["parallel_barrier"] is True and len(runs) == 3
                    and all(math.isfinite(x) and x > 0 for x in (*runs, sample["bulk_mib_s"]))
                    and sample["parallel_mib_s"] == median(runs)):
                raise ValueError(f"burst workload changed in round {row['round']}, arm {size}")
            arms[size] = {"parallel_mib_s": sample["parallel_mib_s"], "single_mib_s": sample["bulk_mib_s"]}
        blocks.append({"id": row["round"], "order": order.split(), "arms": arms})
    return {
        "archive": BURSTS, "archive_sha256": BURSTS_SHA, "records": "experiments.chunk_kib",
        "original_driver": "chunks.sh", "original_driver_sha256": "41ee51c6084b819f9cabb4066b72bac334204eeb3f1d42ec5861199bf814e7c0",
        "dispatch_probe_sha256": "238fda8259f5b2a7d7fbb918e0fcc0f19ebf57f076938072fd415164eef31873",
        "relay_source_sha256_by_kib": {
            "128": "ed80ad5ace7d3f1285f4a1e7a0704518bf3bfed5aba1045b9bded05b59abd949",
            "256": "da053b6a96a02d613fb2559f7cf93ea0843bf47d580c7b0ee4548b733697bd48",
            "512": "4f3bfd5a2e5c126991d8ff1dd39d582b6f754d5001d411c11aa0c2b0c200fa1f"},
        "client_sha256": study["sha256"]["benchmark_client"],
        "workload": "Three separately launched sizes dial the same guest target. Single serial dispatch queue "
                    "at user-initiated QoS, up to four chunks per turn. Separate request and bulk phases, "
                    "64 MiB single stream and median of three barrier-synchronized 32-stream bursts.",
        "order_provenance": "Round IDs in the archive give matched blocks. Arm order is from the retained "
                            "original driver, cross-checked against output timestamps. All 18 original JSON "
                            "results matched the archive. Each of the six permutations is represented once.",
        "policy": "Use recorded completed burst results. The earlier client lacks the fixed-arrival loss and "
                  "reopen evidence. Its separate fresh phase cannot be scored against the mixed-load p95 limit.",
        "blocks": blocks,
        "parallel_vs_256": {size: paired(blocks, size, "parallel_mib_s", fixed_arrivals=False) for size in ("128", "512")},
        "single_vs_256": {size: paired(blocks, size, "single_mib_s", fixed_arrivals=False) for size in ("128", "512")},
    }


def replay():
    return {"scope": "Archived chunk-size screens with distinct controls. No revised two-worker holdout.",
            "interval": "10,000 paired-block bootstrap draws, seed 7317; percentile interval of the median ratio.",
            "fixed_arrivals": mixed(), "separate_bursts": bursts()}


if __name__ == "__main__":
    print(json.dumps(replay(), indent=2))
