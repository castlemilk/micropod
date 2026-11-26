"""Compare relay read caps at fixed producer supply, with a pinned single-owner socketpair fixture."""
import hashlib
import itertools
import json
import os
from pathlib import Path
import platform
import random
import statistics
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASE = "dc019c8cc218c2b10a1b9e26abb76c8bf29a33e7"
PINNED = ("Sources/CPublishedTCP/PublishedTCP.c", "Sources/CPublishedTCP/include/PublishedTCP.h",
          "scripts/relaybench/filter_work.c")
FLAGS = ["-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror", "-DMICROPOD_BENCH_512K_READS=1"]
CELLS = list(itertools.product(("queued", "fragmented", "pressured"), ("alone", "marker")))
PAIRS = 12


def sha(data):
    return hashlib.sha256(data).hexdigest()


def measure(executable, cap, cell):
    env = dict(os.environ, MICROPOD_BENCH_RELAY_READ_KIB=str(cap))
    row = json.loads(subprocess.check_output([executable, *cell], text=True, env=env, timeout=20))
    if (row["cap"] != cap * 1024 or row["bytes"] != 64 * 2**20 or min(row["wall_ns"], row["owner_ns"]) <= 0
            or row["marker_count"] != (8 if cell[1] == "marker" else 0)):
        raise ValueError("invalid measured work")
    return row


def summary(pairs):
    result = {}
    for metric, value in (("owner_cpu_s_per_gib", lambda r: r["owner_ns"] / 1e9 / (r["bytes"] / 2**30)),
                          ("verified_mib_s", lambda r: r["bytes"] / 2**20 / (r["wall_ns"] / 1e9))):
        samples = {cap: [value(p[cap]) for p in pairs] for cap in ("256", "512")}
        changes = [100 * (b / a - 1) for a, b in zip(samples["256"], samples["512"])]
        rng = random.Random(61307)
        bootstrap = sorted(statistics.median(rng.choices(changes, k=len(changes))) for _ in range(10000))
        result[metric] = {"medians": {cap: round(statistics.median(rows), 4) for cap, rows in samples.items()},
                          "median_paired_change_pct": round(statistics.median(changes), 2),
                          "bootstrap_95_pct": [round(bootstrap[249], 2), round(bootstrap[9749], 2)]}
    return result


def main():
    if sys.platform != "darwin":
        raise SystemExit("Requires Darwin kqueue.")
    sources = {}
    fixture = HERE / "read_supply.c"
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        for path in PINNED:
            data = subprocess.check_output(["git", "show", BASE + ":" + path], cwd=ROOT)
            (work / Path(path).name).write_bytes(data)
            sources[path] = sha(data)
        (work / fixture.name).write_bytes(fixture.read_bytes())
        bins = {}
        for name, flags in (("timed", []), ("counted", ["-DCOUNT_IO=1"]),
                            ("sanitized", ["-DCOUNT_IO=1", "-O1", "-fsanitize=address,undefined", "-fno-sanitize-recover=all"])):
            exe = work / name
            subprocess.run(["clang", *FLAGS, *flags, '-DRELAY_SOURCE="PublishedTCP.c"', "-I", tmp,
                            work / fixture.name, "-o", exe], check=True)
            bins[name] = {"sha256": sha(exe.read_bytes()), "extra_flags": flags}
        counters = {}
        counts = ("reads", "writes", "partial", "blocked")
        for cell in CELLS:
            by_cap = {}
            for cap in (256, 512):
                expected = measure(work / "counted", cap, cell)
                checked = measure(work / "sanitized", cap, cell)
                if any(expected[k] != checked[k] for k in counts):
                    raise ValueError("sanitizer control changed I/O")
                by_cap[str(cap)] = {k: expected[k] for k in counts}
                measure(work / "timed", cap, cell)
            counters["/".join(cell)] = by_cap

        rng = random.Random(61307)
        cap_orders = {}
        for cell in CELLS:
            cap_orders[cell] = [(256, 512), (512, 256)] * (PAIRS // 2)
            rng.shuffle(cap_orders[cell])
        blocks = []
        for i in range(PAIRS):
            block = {}
            order = CELLS.copy()
            rng.shuffle(order)
            for cell in order:
                pair = {}
                for cap in cap_orders[cell][i]:
                    row = measure(work / "timed", cap, cell)
                    if any(row[k] for k in counts):
                        raise ValueError("unexpected instrumentation in timing binary")
                    pair[str(cap)] = {k: v for k, v in row.items() if k not in counts}
                block["/".join(cell)] = pair
            blocks.append(block)
    print(json.dumps({"schema": 1, "completed_utc": datetime.now(timezone.utc).isoformat(), "base": BASE,
          "host": platform.platform(), "compiler": subprocess.check_output(["clang", "--version"], text=True).splitlines()[0],
          "flags": FLAGS, "binaries": bins, "pinned_sha256": sources,
          "experiment_sha256": {p.name: sha(p.read_bytes()) for p in (fixture, Path(__file__).resolve())},
          "method": "Single background thread, 16 established streams, 8 waves; each wave writes four 128 KiB "
                    "pieces per stream and receives/verifies those same four pieces. Roomy 1 MiB sockets at both ends. "
                    "Queued supplies 512 KiB before the drain. Fragmented supplies and drains each 128 KiB piece. "
                    "Pressured supplies 512 KiB, with 128 KiB downstream capacity; drain/write progress alternates with "
                    "128 KiB consumer reads. Marker cells add one co-ready byte from a small established stream per wave. "
                    "Counted builds require its write to be serviced first. Both arms verify all bytes, EOF and reverse data/FIN. "
                    "Thread CPU spans native relay drains only. Wall rate covers producer, drains, consumer and byte checks. "
                    "One warmup per arm/cell. Twelve randomized pairs per cell, six runs in each arm order. Cell order "
                    "randomized in each block. Percentiles bootstrap matched pairs. Primary cell is queued/alone. No IP, VM, "
                    "dispatch timing or concurrent producer/consumer. Both caps use one binary. Actual syscall counts "
                    "were collected separately from timing with the same code, work and cap in an instrumented build.",
          "calls_per_64_mib": counters,
          "summary": {"/".join(cell): summary([b["/".join(cell)] for b in blocks]) for cell in CELLS},
          "blocks": blocks}, indent=2))


if __name__ == "__main__":
    main()
