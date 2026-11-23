"""Replay the Darwin relay's 24- versus eight-event readiness polls at fixed work."""
import hashlib
import json
import os
from pathlib import Path
import platform
from statistics import median
import subprocess
import tempfile

from gamma_contrasts import clean_client, paired_median_interval, read_receipt

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
RELAY = ROOT / "Sources/CPublishedTCP"
FILES = (HERE / "late_read_size.c", HERE / "filter_work.c", RELAY / "PublishedTCP.c", RELAY / "include/PublishedTCP.h")
FLAGS = ["-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror", "-DMICROPOD_BENCH_512K_READS=1",
         "-DMICROPOD_BENCH_FIXED_RELAY_BUDGET=1"]
READ_CAP = 512 * 1024
OFFERS = (128 * 1024, READ_CAP, 2 * READ_CAP)
WIDTHS = (24, 8)


def historical():
    archive = ROOT / "docs/benchmarks/2026-11-21/gamma-mixed-scheduler.json.gz"
    sha = "9e3b184de862aafacff47312878441e940d030e8cfc8342c0e479d064f4724c8"
    records = read_receipt(archive, sha)["records"]
    driver = records["fixtures/flat-screen.sh"].encode()
    blocks = []
    modes = ("stock", "8", "24", "64", "orb")
    for number in range(6):
        arms = {}
        for width in (8, 24, 64):
            c = records[f"flat/{number}-{width}.json"]
            arms[width] = {"clean": clean_client(c), "mib_s": c["mib_s"],
                           "p95_ms": c["fresh_p95_us"] / 1000, "p99_ms": c["fresh_p99_us"] / 1000}
        blocks.append({"id": number, "order": [modes[(pos + number) % 5] for pos in (0, 1, 4, 2, 3)],
                       "arms": arms})
    contrasts = {}
    for width in (8, 64):
        paired = [b for b in blocks if b["arms"][width]["clean"] and b["arms"][24]["clean"]]
        ratios = [b["arms"][width]["mib_s"] / b["arms"][24]["mib_s"] for b in paired]
        contrasts[width] = {"common_block_ids": [b["id"] for b in paired], "median_ratio": median(ratios),
                            "paired_bootstrap_ci95": paired_median_interval(ratios),
                            "faster_blocks": sum(r > 1 for r in ratios)}
    return {"archive": str(archive.relative_to(ROOT)), "archive_sha256": sha,
            "driver": "records/fixtures/flat-screen.sh", "driver_sha256": hashlib.sha256(driver).hexdigest(),
            "relay": "records/fixtures/flat.c", "relay_sha256": hashlib.sha256(records["fixtures/flat.c"].encode()).hexdigest(),
            "scope": "Existing four-vCPU Linux 6.18.35 VM. The same flat relay, 256 KiB reads and 32 streams "
                     "plus 240 scheduled fresh arrivals. The older loop checked 128 events between batches, "
                     "allowing one last full poll to exceed that count; the current relay clips to the remainder. "
                     "Order is the five-mode rotation specified in the pinned driver.",
            "blocks": blocks, "relative_to_24": contrasts,
            "p95_over_75ms_blocks": {w: [b["id"] for b in blocks if b["arms"][w]["p95_ms"] > 75] for w in (8, 24, 64)}}


def collect():
    env = dict(os.environ, MICROPOD_BENCH_RELAY_READ_KIB="512")
    result = {}
    with tempfile.TemporaryDirectory(prefix="relay-poll-") as temp:
        binary = Path(temp) / "ready-poll"
        subprocess.run(["clang", *FLAGS, "-I", str(RELAY / "include"), str(FILES[0]), "-o", str(binary)], check=True)
        binary_sha = hashlib.sha256(binary.read_bytes()).hexdigest()
        # Repeat both widths in reverse order; the receipt records fixed-work counts.
        for width in (*WIDTHS, *reversed(WIDTHS)):
            output = subprocess.check_output([binary, str(width)], env=env, text=True, timeout=35)
            rows = [json.loads(line) for line in output.splitlines()]
            if [(r["offer_per_stream"], r["inject_after"]) for r in rows] != [
                (size, position) for size in OFFERS for position in range(17)
            ]:
                raise ValueError("incomplete or duplicate injection positions")
            for row in rows:
                offer = row["offer_per_stream"]
                data_calls = 16 * ((offer + READ_CAP - 1) // READ_CAP)
                if (row["poll_width"] != width or row["verified_bulk_bytes"] != 16 * offer
                        or row["bulk_reads"] != data_calls or row["bulk_writes"] != data_calls
                        or row["empty_polls"] != 1 or not 0 <= row["writes_ahead"] <= data_calls
                        or row["bytes_ahead"] != row["writes_ahead"] * min(offer, READ_CAP)):
                    raise ValueError(f"workload, readiness or byte count changed: {row}")
            if width in result and result[width] != rows:
                raise ValueError(f"poll counts or service order varied between replays at width {width}")
            result[width] = rows

    # Retain all 17 arrival positions while displaying the fixed measurement compactly.
    compact = {}
    for width, rows in result.items():
        compact[width] = {}
        for offer in OFFERS:
            cases = [r for r in rows if r["offer_per_stream"] == offer]
            compact[width][offer] = {
                "verified_bulk_bytes_per_case": 16 * offer,
                "positive_bulk_reads_per_case": cases[0]["bulk_reads"],
                "positive_bulk_writes_per_case": cases[0]["bulk_writes"],
                "bulk_writes_ahead_by_arrival": [r["writes_ahead"] for r in cases],
                "bulk_bytes_ahead_by_arrival": [r["bytes_ahead"] for r in cases],
                "kevent_polls_including_final_empty_by_arrival": [r["polls"] for r in cases],
            }
    return {
        "schema": 1, "machine": platform.machine(), "darwin": platform.release(),
        "compiler": subprocess.check_output(["clang", "--version"], text=True).splitlines()[0],
        "flags": FLAGS, "binary_sha256": binary_sha,
        "source_sha256": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in (*FILES, Path(__file__).resolve())},
        "method": "The same production relay runs on one thread with anonymous Darwin socketpairs. "
                  "Only the maximum number of events passed to a data kevent poll during the scored drain varies. "
                  "The callback allows 128 events and the read maximum is 512 KiB. Sixteen established "
                  "download streams are ready before each drain. Array index zero inserts a one-byte reply "
                  "after queuing all bulk data, before the first poll. Indices 1–16 inject it immediately after "
                  "the corresponding successful bulk write. Counters stop at the single final empty poll. "
                  "The fixture checks payload, flow identity and order for every stream and marker, then "
                  "checks half-close, reverse data and teardown. Two passes per width in reverse order agree exactly. "
                  "The 1 MiB offer keeps streams ready for a second read. Results describe work order and "
                  "kernel call counts; there is no time, TCP, VM or process-scheduling measurement.",
        "rows_by_poll_width_and_bytes_per_stream": compact, "historical_vm": historical(),
    }


if __name__ == "__main__":
    print(json.dumps(collect(), indent=2))
