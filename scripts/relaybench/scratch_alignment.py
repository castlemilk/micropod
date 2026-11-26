"""Measure Darwin relay scratch alignment with the same verified payload and native pump."""
import argparse
import hashlib
import json
import os
import platform
import random
import statistics
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASE = "a1e7965b277943dba589b8937c3de5a8121f4db7"
INPUTS = ("Sources/CPublishedTCP/PublishedTCP.c", "Sources/CPublishedTCP/include/PublishedTCP.h",
          "scripts/relaybench/filter_work.c")
ARMS = ("embedded", "matched", "offset128", "page")
CELLS = ((256, 256), (512, 512), (256, 4))
SEED = 88129
BLOCKS = 16
FLAGS = ["-std=gnu11", "-Wall", "-Wextra", "-Werror", '-DRELAY_SOURCE="PublishedTCP.c"']


def digest(data):
    return hashlib.sha256(data).hexdigest()


def trial(exe, mode, cap, piece, order):
    raw = subprocess.check_output([exe, mode, str(piece), *order], text=True, timeout=35,
                                  env=dict(os.environ, MICROPOD_BENCH_RELAY_READ_KIB=str(cap)))
    rows = [json.loads(line) for line in raw.splitlines()]
    if [row["arm"] for row in rows] != list(order):
        raise ValueError("incomplete four-arm block")
    offsets = {row["arm"]: row["tested_offset"] for row in rows}
    if not (offsets["page"] == 0 and offsets["embedded"] == offsets["matched"] and
            offsets["offset128"] == 128 and offsets["matched"] < rows[0]["page"]):
        raise ValueError("actual scratch addresses do not match the planned contrasts")
    for row in rows:
        expected = 64 * 2**20 if mode == "time" else 2 * 8 * piece * 1024
        if row["verified_bytes"] != expected or row["cap"] != 1024 * cap or row["piece"] != 1024 * piece or min(
                row["wall_ns"], row["owner_ns"]) <= 0:
            raise ValueError("different work, cap or invalid timings")
    return rows


def score(blocks, cell):
    measures = {name: {arm: [] for arm in ARMS} for name in ("verified_mib_s", "owner_cpu_s_per_gib")}
    for block in blocks:
        for row in block[cell]:
            measures["verified_mib_s"][row["arm"]].append((row["verified_bytes"] / 2**20) / (row["wall_ns"] / 1e9))
            measures["owner_cpu_s_per_gib"][row["arm"]].append((row["owner_ns"] / 1e9) / (row["verified_bytes"] / 2**30))
    result = {}
    for metric, arms in measures.items():
        result[metric] = {"medians": {arm: statistics.median(values) for arm, values in arms.items()}}
        for new, old in (("page", "matched"), ("offset128", "matched"), ("page", "offset128"), ("matched", "embedded")):
            changes = [100 * (a / b - 1) for a, b in zip(arms[new], arms[old])]
            rng = random.Random(SEED)
            draws = sorted(statistics.median(rng.choices(changes, k=len(changes))) for _ in range(10000))
            result[metric][f"{new}_vs_{old}"] = dict(paired_change_pct=statistics.median(changes),
                                                      ci95_pct=[draws[249], draws[9749]])
    return result


def run(qualify_only):
    with tempfile.TemporaryDirectory(prefix="mp-scratch-align-") as tmp:
        work = Path(tmp)
        hashes = {}
        for name in INPUTS:
            data = subprocess.check_output(["git", "show", BASE + ":" + name], cwd=ROOT)
            hashes[name] = digest(data)
            (work / Path(name).name).write_bytes(data)
        relay = work / "PublishedTCP.c"
        original = relay.read_text()
        # Only redirect the hot scratch pointer and the partial-write copy source.
        # All arms, including the actual embedded buffer, execute this same binary.
        for old, new in (("char *data = r->scratch;", "char *data = trial_scratch;"),
                         ("memcpy(dst->pending, r->scratch + sent, remaining);",
                          "memcpy(dst->pending, trial_scratch + sent, remaining);")):
            if original.count(old) != 1:
                raise ValueError("unexpected pinned pump")
            original = original.replace(old, new)
        relay.write_text(original)
        hashes["trial_pump"] = digest(relay.read_bytes())
        for path in (HERE / "scratch_alignment.c", Path(__file__).resolve()):
            hashes[path.name] = digest(path.read_bytes())
        (work / "trial.c").write_bytes((HERE / "scratch_alignment.c").read_bytes())
        binaries, qual = {}, {}
        rng = random.Random(SEED)
        for cap in (256, 512):
            for kind, extra in (("checked", ["-O1", "-fsanitize=address,undefined", "-fno-sanitize-recover=all"]),
                                ("timed", ["-O2"])):
                exe = work / f"{kind}-{cap}"
                flags = [*FLAGS, f"-DMICROPOD_BENCH_512K_READS={int(cap == 512)}", *extra]
                subprocess.run(["clang", *flags, "-I", work, work / "trial.c", "-o", exe], check=True)
                binaries[exe.name] = dict(sha256=digest(exe.read_bytes()), flags=flags)
            qual[str(cap)] = trial(work / f"checked-{cap}", "qualify", cap, cap, ARMS)
        report = dict(base=BASE, source_sha256=hashes, binaries=binaries, qualification=qual,
                      platform=platform.platform(), compiler=subprocess.check_output(
                          ["clang", "--version"], text=True).splitlines()[0])
        if qualify_only:
            return report
        # Each arm occupies every position equally and follows every other arm equally.
        square = [tuple(ARMS[(i + shift) % 4] for i in (0, 1, 3, 2)) for shift in range(4)]
        orders = {cell: square * (BLOCKS // 4) for cell in CELLS}
        for order in orders.values():
            rng.shuffle(order)
        for cap, piece in CELLS:
            trial(work / f"timed-{cap}", "qualify", cap, piece, ARMS)
        blocks = []
        for i in range(BLOCKS):
            block = {}
            for cap, piece in rng.sample(CELLS, len(CELLS)):
                block[f"cap{cap}_offer{piece}"] = trial(work / f"timed-{cap}", "time", cap, piece, orders[cap, piece][i])
            blocks.append(block)
    return dict(**report, seed=SEED, completed_utc=datetime.now(timezone.utc).isoformat(),
                primary="Page-aligned vs stock-matched offset in one external allocation at 256 KiB cap and offer.",
                method="All four arms in each cell/block share one live flat kqueue owner, eight established AF_UNIX "
                       "streams, an identical compiled pump, two-worker 128-event budget, and the same producer and "
                       "consumer storage. All tested buffers have an equal usable span of one cap. The matched arm "
                       "uses the runtime modulo-page address of the real inline scratch. The offset128 arm starts "
                       "128 bytes after the backing page; the page arm starts at that page. All three share the "
                       "same backing allocation. The embedded arm controls for scratch relocation. Each arm warms "
                       "one wave after touching scratch, then produces, forwards and byte-verifies 64 MiB in "
                       "fixed-size waves on a background thread. Owner CPU covers drains only. Wall throughput "
                       "includes all three roles and validation. Both FINs and reverse traffic verified. "
                       "ASan/UBSan qualification forces partial writes and verifies buffered tails for each arm "
                       "at both caps. Each of sixteen blocks uses randomized cell order with balanced four-arm "
                       "order. Intervals resample the median paired percentage change. No VM, IP, or concurrent "
                       "consumer. The read and write both use the chosen address, so their effects cannot be separated.",
                summary={k: score(blocks, k) for k in blocks[0]}, blocks=blocks)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--qualify-only", action="store_true")
    args = parser.parse_args()
    print(json.dumps(run(args.qualify_only), indent=2))
