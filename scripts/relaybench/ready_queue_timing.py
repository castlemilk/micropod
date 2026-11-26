"""Measure flat and nested readiness for established transfers on Darwin. Emit a raw JSON receipt."""
import hashlib
import json
import os
from pathlib import Path
import platform
from statistics import median
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

from gamma_contrasts import paired_median_interval

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASE = "dc019c8cc218c2b10a1b9e26abb76c8bf29a33e7"
INPUTS = ("Sources/CPublishedTCP/PublishedTCP.c", "Sources/CPublishedTCP/include/PublishedTCP.h",
          "scripts/relaybench/filter_work.c")
FLAGS = ["-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror", "-DMICROPOD_BENCH_512K_READS=1",
         '-DRELAY_SOURCE="PublishedTCP.c"']
ARMS = ("flat", "nested")
PIECES = (4, 512)
BLOCKS = 12


def digest(data):
    return hashlib.sha256(data).hexdigest()


def sample(binary, arm, kib):
    row = json.loads(subprocess.check_output(
        [binary, arm, str(kib)], env=dict(os.environ, MICROPOD_BENCH_RELAY_READ_KIB="512"), timeout=20))
    if (row["arm"] != arm or row["piece_bytes"] != kib * 1024 or row["verified_bytes"] != 32 * 2**20
            or row["waves"] * 16 * kib * 1024 != row["verified_bytes"] or min(row["owner_ns"], row["wall_ns"]) <= 0):
        raise ValueError(f"invalid measurement: {row}")
    return row


def score(blocks, kib):
    pairs = [{r["arm"]: r for r in block["runs"] if r["piece_bytes"] == kib * 1024} for block in blocks]
    result = {}
    for field, value in (("owner_cpu_s_per_gib", lambda r: r["owner_ns"] / 1e9 / (r["verified_bytes"] / 2**30)),
                         ("verified_mib_s", lambda r: r["verified_bytes"] / 2**20 / (r["wall_ns"] / 1e9))):
        ratios = [value(p["nested"]) / value(p["flat"]) for p in pairs]
        ci = paired_median_interval(ratios)
        result[field] = {
            "median_by_arm": {arm: round(median(value(p[arm]) for p in pairs), 4) for arm in ARMS},
            "nested_paired_median_change_pct": round(100 * (median(ratios) - 1), 3),
            "paired_bootstrap_95_change_pct": [round(100 * (v - 1), 3) for v in ci],
            "nested_faster_blocks": sum((r < 1 if field == "owner_cpu_s_per_gib" else r > 1) for r in ratios),
        }
    return result


def main():
    if sys.platform != "darwin":
        raise SystemExit("Requires Darwin kqueue.")
    fixture = HERE / "ready_queue_timing.c"
    hashes = {p.name: digest(p.read_bytes()) for p in (fixture, Path(__file__), HERE / "gamma_contrasts.py")}
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        for path in INPUTS:
            data = subprocess.check_output(["git", "show", f"{BASE}:{path}"], cwd=ROOT)
            (work / Path(path).name).write_bytes(data)
            hashes[path] = digest(data)
        (work / fixture.name).write_bytes(fixture.read_bytes())
        binaries = {}
        blocks = []
        for name, extra in (("sanitized", ["-O1", "-fsanitize=address,undefined", "-fno-sanitize-recover=all"]),
                            ("timed", [])):
            binary = work / name
            subprocess.run(["clang", *FLAGS, *extra, "-I", tmp, work / fixture.name, "-o", binary], check=True)
            binaries[name] = {"sha256": digest(binary.read_bytes()), "extra_flags": extra}
            for kib in PIECES:
                for arm in ARMS:
                    sample(binary, arm, kib)
        for index in range(BLOCKS):
            # Balance AB/BA and first workload per block; each arm leads 3x at each workload position.
            order = ARMS if index % 2 == 0 else ARMS[::-1]
            widths = PIECES if index % 4 < 2 else PIECES[::-1]
            blocks.append({"index": index, "runs": [sample(work / "timed", arm, kib)
                                                    for kib in widths for arm in order]})
    print(json.dumps({
        "base": BASE, "utc": datetime.now(timezone.utc).isoformat(), "host": platform.platform(),
        "compiler": subprocess.check_output(["clang", "--version"], text=True).splitlines()[0],
        "flags": FLAGS, "binary": binaries, "inputs_sha256": hashes, "blocks": blocks,
        "method": "One background thread. 16 staged local AF_UNIX flows. The two-worker drain argument and "
                  "512 KiB read cap are identical. Flat uses create_data and nested uses create. A 16 KiB "
                  "classification wave and one full workload wave precede timing in every process. Each timed "
                  "wave queues one 4 or 512 KiB write per flow, calls the native drain once, and reads and "
                  "compares every byte with its flow- and wave-tagged input. 32 MiB verified per sample. "
                  "Both FINs and retirement checked. Owner CPU covers drains. Wall throughput includes producers, "
                  "consumers and byte comparison on the same thread. No VM, network, dispatch or fresh marker. "
                  "Setup, classification and teardown excluded. One timed binary for both arms. ASan/UBSan "
                  "qualifies all four cells; one untimed sample per cell. 12 matched pairs per size with alternating "
                  "AB/BA. Intervals resample the within-block ratios (10,000 draws, seed 7317).",
        "summary_by_piece_kib": {kib: score(blocks, kib) for kib in PIECES},
    }, indent=2))


if __name__ == "__main__":
    main()
