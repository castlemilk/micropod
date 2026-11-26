"""Measure dedicated relay callback yields on a single Darwin thread and anonymous socket pairs."""
import hashlib
import json
import platform
import statistics
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "scripts/relaybench/short_ready_set.c"
RELAY = ROOT / "Sources/CPublishedTCP/PublishedTCP.c"
HEADER = ROOT / "Sources/CPublishedTCP/include/PublishedTCP.h"
PROFILES = ((1, 0), (16, 0), (16, 1024))
BLOCKS = 6


def measure(binary, mode):
    result = subprocess.run([str(binary), mode], check=True, capture_output=True,
                            text=True, timeout=15)
    rows = [json.loads(line) for line in result.stdout.splitlines()]
    if [(row["streams"], row["read_cap"]) for row in rows] != list(PROFILES):
        raise ValueError("incomplete socket fixture")
    for row in rows:
        if (row["owner_cpu_ns"] <= 0 or row["waves"] != 256 or
                row["bytes"] != 4096 * row["waves"] * row["streams"]):
            raise ValueError(f"invalid fixture counters: {row}")
    return rows


def summarize(blocks):
    summary = []
    for i, (streams, cap) in enumerate(PROFILES):
        profile = {"streams": streams, "read_cap": cap}
        for mode in ("stock", "yield-short"):
            rows = [block[mode][i] for block in blocks]
            ranges = {}
            for name in ("inner_polls", "empty_inner_polls", "callback_deliveries"):
                values = [row[name] for row in rows]
                ranges[name] = [min(values), max(values)]
            profile[mode] = ranges
        changes = [100 * (block["yield-short"][i]["owner_cpu_ns"] /
                          block["stock"][i]["owner_cpu_ns"] - 1) for block in blocks]
        profile["paired_cpu_change_percent"] = {
            "min": round(min(changes), 2),
            "median": round(statistics.median(changes), 2),
            "max": round(max(changes), 2),
        }
        summary.append(profile)
    return summary


def main():
    if sys.platform != "darwin":
        raise SystemExit("This Darwin kqueue diagnostic requires macOS.")
    flags = ["-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror"]
    with tempfile.TemporaryDirectory(prefix="relay-ready-") as scratch:
        binary = Path(scratch) / "fixture"
        subprocess.run(["clang", *flags, "-I", str(HEADER.parent), str(FIXTURE),
                        "-o", str(binary)], check=True)
        arms = ("stock", "yield-short")
        for mode in arms:
            measure(binary, mode)
        blocks = []
        for i in range(BLOCKS):
            order = arms if i % 2 == 0 else tuple(reversed(arms))
            block = {"order": list(order)}
            for mode in order:
                block[mode] = measure(binary, mode)
            blocks.append(block)
    result = {
        "schema": 1,
        "completed_at": datetime.now(timezone.utc).isoformat(),
        "platform": {"machine": platform.machine(), "darwin_release": platform.release()},
        "compiler": subprocess.check_output(["clang", "--version"], text=True).splitlines()[0],
        "flags": flags,
        "source_sha256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                          for path in (RELAY, HEADER, FIXTURE, Path(__file__).resolve())},
        "method": (
            "One single-threaded fixture process at a time. One unscored warmup per arm. "
            "Six paired blocks with alternating arm order. Each arm handles 256 waves of "
            "4096 bytes per stream in each profile. The 1024-byte read cap forces four reads. "
            "Thread CPU covers outer readiness polls and relay callbacks. Payload setup, comparison and the extra final wave are untimed."
        ),
        "integrity": (
            "Every wave passed an exact ordered byte comparison on each stream. The extra "
            "wave sent data followed immediately by a half-close and required all bytes before EOF."
        ),
        "scope": (
            "Anonymous local UNIX socket pairs with a kqueue watching the data owner's kqueue. "
            "The fixture models an early return after an underfilled poll by suppressing the "
            "next kernel poll within that callback. Counts cover actual kernel calls. "
            "The outer watcher models level-triggered readiness, excluding libdispatch, an "
            "accept path, the guest network, and any inference about live throughput or latency."
        ),
        "counter_summary_ranges": summarize(blocks),
        "blocks": blocks,
    }
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
