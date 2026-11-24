"""Bound post-launch fresh latency from the archived mixed read-cap screen.

Reproduce with python3 -B scripts/relaybench/read_cap_dispatch.py. No endpoints
are opened. The original client discarded the pairing between launch delays
and completion times when it sorted its two arrays separately.
"""
import hashlib
import json

from chunk_replay import DIRECTORY, MIXED, MIXED_DRIVER_SHA, MIXED_SHA
from gamma_contrasts import clean_client, read_receipt


CLIENT_SOURCE_SHA = "ed5150165e2fbc8dbba78404db0d5e0acafab47419fa354850ce119ffa2fc9f5"
HISTORICAL_REVISION = "692ace081c989f80fb2bce27a5a13af13098b77c"
LIMIT_US = 75_000


def post_launch_bounds(scheduled_us, max_launch_us):
    # The Go client truncated each nonnegative duration to microseconds. For
    # every request the launch delay is below (max_launch_us + 1) microseconds.
    # Pointwise inequalities also hold for the same order statistic.
    return [max(0, scheduled_us - max_launch_us - 1), scheduled_us + 1]


def replay():
    archive = read_receipt(DIRECTORY / MIXED, MIXED_SHA)
    records = archive["records"]
    for key, expected in (("fixtures/fixed.go", CLIENT_SOURCE_SHA),
                          ("fixtures/chunk-screen.sh", MIXED_DRIVER_SHA)):
        if hashlib.sha256(records[key].encode()).hexdigest() != expected:
            raise ValueError(f"unexpected fixture source {key}")
    if not HISTORICAL_REVISION.startswith(archive["baseline_commit"]):
        raise ValueError("historical revision mismatch")

    pairs = []
    for block in range(7):
        arms = {}
        for kib in ("256", "512"):
            stem = f"chunks/{block}-flat{kib}"
            sample = records[stem + ".json"]
            max_delay = sample["dispatch_max_us"]
            if (not clean_client(sample) or records[stem + ".err"].strip()
                    or not 0 <= sample["dispatch_p95_us"] <= max_delay):
                raise ValueError(f"missing or inconsistent first-attempt evidence for {stem}")
            p95 = sample["fresh_p95_us"]
            bounds = post_launch_bounds(p95, max_delay)
            arms[kib] = {
                "source_record": stem + ".json", "mib_s": sample["mib_s"],
                "delivered_bytes": sample["bytes"], "fresh_requests": sample["arrivals"],
                "client_errors": len(sample["errors"] or []), "reopens": sample["reopened"],
                "scheduled_p95_us": p95, "scheduled_p99_us": sample["fresh_p99_us"],
                "max_launch_delay_us": max_delay, "post_launch_p95_bounds_us": bounds,
                "post_launch_p99_bounds_us": post_launch_bounds(sample["fresh_p99_us"], max_delay),
                "scheduled_p95_over_limit": p95 > LIMIT_US,
            }
        control = arms["256"]["post_launch_p95_bounds_us"]
        candidate = arms["512"]["post_launch_p95_bounds_us"]
        difference = [candidate[0] - control[1], candidate[1] - control[0]]
        direction = "unresolved"
        if difference[0] > 0:
            direction = "slower"
        elif difference[1] < 0:
            direction = "faster"
        pairs.append({"block": block, "arms_kib": arms, "post_launch_p95_difference_us": difference,
                      "larger_cap_post_launch_p95": direction})

    return {
        "date": "2026-11-24", "direction": "230.15",
        "evidence_tier": "VM (offline analysis of historical Gamma round records)",
        "revision": HISTORICAL_REVISION, "replay_base": "2ccda8507355b8220258db2ce8160f3113d3e1ff",
        "raw_archive": MIXED, "archive_sha256": MIXED_SHA, "client_source_sha256": CLIENT_SOURCE_SHA,
        "client_binary_sha256": archive["sha256"]["fixed-client"], "driver_sha256": MIXED_DRIVER_SHA,
        "workload": "4 vCPU VM, detached MP_FLAT=24 host relay, 32 warm bulk streams and 240 fresh "
                    "identity requests spaced 25 ms apart per arm. Only change is flat relay read cap, "
                    "256 vs 512 KiB. Seven rotated blocks, one recorded attempt per arm per block.",
        "latency_definition": "Scheduled target to checked HTTP identity response body. The start timestamp "
                              "is inside the fresh request goroutine before the HTTP operation. Bounds retain "
                              "all client work after goroutine launch, network, relay and service.",
        "method": "For each latency rank, post-launch duration is bounded by scheduled quantile minus "
                  "maximum launch delay minus 1 us, and scheduled quantile plus 1 us. This follows from "
                  "the per-request inequalities and microsecond truncation. Paired differences use the "
                  "extreme endpoints of the two intervals. These are deterministic measurement bounds, "
                  "not resampling intervals or treatment-effect estimates.",
        "official_scheduled_p95_limit_us": LIMIT_US,
        "coverage": "All 14 recorded attempts. No per-arrival pairing or per-process CPU/GiB on these arms.",
        "pairs": pairs,
        "blocks_by_post_launch_p95_direction": {
            label: [p["block"] for p in pairs if p["larger_cap_post_launch_p95"] == label]
            for label in ("slower", "faster", "unresolved")
        },
        "decision": "Timing the client from launch cannot consistently explain the read-cap tail differences. "
                    "Keep scheduled p95 for acceptance. Preserve paired launch and completion times on the "
                    "separate read-cap comparison after the worker decision; individual durations from these "
                    "archived percentile summaries cannot be recovered."
    }


if __name__ == "__main__":
    print(json.dumps(replay(), indent=2))
