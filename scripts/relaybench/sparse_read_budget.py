"""Compare fixed and ready-set-dependent read sizes on one Darwin relay owner."""
import hashlib
import json
import os
import platform
import random
import shutil
import statistics
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASE = "04d4899a20c352f4022185f1cf616ab4fa1401e1"
SOURCES = ("Sources/CPublishedTCP/PublishedTCP.c", "Sources/CPublishedTCP/include/PublishedTCP.h",
           "scripts/relaybench/filter_work.c")
FLAGS = ["-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror", "-DMICROPOD_BENCH_512K_READS=1",
         '-DRELAY_SOURCE="PublishedTCP.c"']
ARMS = ("256", "512", "sparse", "one-large")
SCHEDULES = ("two-ready", "sixteen-ready", "alternating")
SEED = 24017


def sha(data):
    return hashlib.sha256(data).hexdigest()


def sample(binary, arm, *args):
    env = dict(os.environ, MICROPOD_BENCH_RELAY_READ_KIB=arm)
    return json.loads(subprocess.check_output([binary, *map(str, args)], env=env, text=True, timeout=25))


def check(binary):
    # Ready downloads, KiB offered per download, marker insertion (0=co-ready),
    # initial callback budget (0=normal), restricted downstream buffer.
    cases = [(n, 512, 1, 0, 0) for n in (1, 2, 3, 8, 16)]
    cases += [(2, 512, 0, 0, 0), (2, 512, 2, 0, 0), (2, 128, 1, 0, 0), (1, 512, 1, 0, 1)]
    cases += [(16, 512, 1, budget, 0) for budget in (1, 2)]
    result = []
    for case in cases:
        n, kib, marker, budget, pressured = case
        arms = {}
        for arm in ARMS:
            row = sample(binary, arm, "check", *case)
            expected = n * kib * 1024
            assert row["bytes"] == expected
            if not pressured and not budget:
                large = n if arm == "512" else 0
                if n + (marker == 0) <= 2 and arm in ("sparse", "one-large"):
                    large = n if arm == "sparse" else 1
                if kib <= 256:
                    large = 0
                remaining = n - marker
                large_ahead = max(0, large - marker)
                ahead_kib = large_ahead * kib + (remaining - large_ahead) * min(kib, 256)
                assert row["bulk_bytes_ahead_of_marker"] == (ahead_kib * 1024 if marker else 0)
                if marker == 1:
                    assert row["large_reads"] == large
                    assert row["reads"] == row["writes"] == (2 * n - large if kib > 256 else n)
            if pressured:
                assert row["partial_writes"] > 0
            arms[arm] = {k: v for k, v in row.items() if k not in ("wall_ns", "owner_ns")}
        result.append(dict(ready=n, kib=kib, marker_after=marker, first_budget=budget,
                           pressured=bool(pressured), arms=arms))
    return result


def summarize(blocks, schedule):
    rng = random.Random(SEED)
    result = {}
    for metric, ns in (("mib_s", "wall_ns"), ("owner_cpu_s_per_gib", "owner_ns")):
        values = {arm: [] for arm in ARMS}
        for block in blocks:
            for arm, row in block[schedule].items():
                assert row["bytes"] == 88 * 2**20 and min(row["wall_ns"], row["owner_ns"]) > 0
                value = (row["bytes"] / 2**20) / (row[ns] / 1e9) if ns == "wall_ns" else (
                    row[ns] / 1e9) / (row["bytes"] / 2**30)
                values[arm].append(value)
        result[metric] = {"medians": {k: statistics.median(v) for k, v in values.items()}}
        for candidate in ("sparse", "one-large"):
            for control in ("256", "512"):
                effects = [100 * (b / a - 1) for a, b in zip(values[control], values[candidate])]
                boot = sorted(statistics.median(rng.choices(effects, k=len(effects))) for _ in range(10000))
                result[metric][candidate + "_vs_" + control] = dict(
                    paired_pct=statistics.median(effects), ci95_pct=[boot[249], boot[9749]])
    return result


def main():
    rng = random.Random(SEED)
    hashes = {}
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        for name in SOURCES:
            data = subprocess.check_output(["git", "show", BASE + ":" + name], cwd=ROOT)
            (work / Path(name).name).write_bytes(data)
            hashes[name] = sha(data)
        for path in (HERE / "sparse_read_budget.patch", HERE / "sparse_read_budget.c", Path(__file__).resolve()):
            hashes[path.name] = sha(path.read_bytes())
        shutil.copy(HERE / "sparse_read_budget.c", work)
        subprocess.run(["patch", "-s", "-p0", "-i", HERE / "sparse_read_budget.patch"], cwd=work, check=True)
        hashes["candidate PublishedTCP.c"] = sha((work / "PublishedTCP.c").read_bytes())
        bins = {}
        for name, extra in (("timed", ["-DCOUNT_IO=0"]), ("counted", ["-DCOUNT_IO=1"]),
                            ("sanitized", ["-DCOUNT_IO=1", "-O1", "-fsanitize=address,undefined",
                                           "-fno-sanitize-recover=all"])):
            exe = work / name
            subprocess.run(["clang", *FLAGS, *extra, "-I", work, work / "sparse_read_budget.c", "-o", exe], check=True)
            bins[name] = dict(sha256=sha(exe.read_bytes()), extra_flags=extra)
        correctness = check(work / "counted")
        if correctness != check(work / "sanitized"):
            raise ValueError("sanitizer run changed I/O or service order")
        # Four balanced orders place each arm in each position and after each
        # of its peers equally often (a four-treatment Williams design).
        balanced = [tuple(ARMS[(a + shift) % 4] for a in (0, 1, 3, 2)) for shift in range(4)]
        orders = {s: balanced * 3 for s in SCHEDULES}
        for s in SCHEDULES:
            rng.shuffle(orders[s])
            for arm in ARMS:
                sample(work / "timed", arm, "timed", s)
        blocks = []
        for i in range(12):
            block = {}
            for s in rng.sample(SCHEDULES, len(SCHEDULES)):
                block[s] = {arm: sample(work / "timed", arm, "timed", s) for arm in orders[s][i]}
            blocks.append(block)
    print(json.dumps(dict(
        base=BASE, completed_utc=datetime.now(timezone.utc).isoformat(), platform=platform.platform(),
        compiler=subprocess.check_output(["clang", "--version"], text=True).splitlines()[0],
        inputs_sha256=hashes, binaries=bins, flags=FLAGS, seed=SEED, qualification=correctness,
        method="One pinned native relay owner on a background thread, 16 classified AF_UNIX streams, flat queue, "
               "24 events per poll, 128 per callback, one binary per instrumentation mode and equal 512 KiB scratch. "
               "Adaptive policy uses 512 KiB on previously bulk-classified guest downloads only when 1 or 2 events "
               "return with capacity >2, an ordinary read hint exceeds 256 KiB, and no EOF/error is present. "
               "The one-large arm grants only the first eligible read in the sparse poll a larger quantum. "
               "All other reads use 256 KiB in both adaptive arms. Each timed sample warms a full wave, then verifies 88 MiB with 2 ready, "
               "16 ready, or a repeating [1,2,3,16,2,1,16,3] wave. Half-closes, reverse data and retirement are "
               "verified. Wall rates include local producer, relay, consumer and byte comparison on the same thread. "
               "Owner CPU covers relay drains. Untimed builds check exact reads, writes, and bulk bytes ahead of "
               "a one-byte reply. Timed samples have no marker or I/O hooks. Four balanced arm orders occur three times per "
               "schedule, with the arm order and schedule order randomized across blocks. Intervals bootstrap 12 within-block "
               "changes. No live VM, TCP, dispatch or peer measurements.",
        summary={s: summarize(blocks, s) for s in SCHEDULES}, blocks=blocks), indent=2))


if __name__ == "__main__":
    main()
