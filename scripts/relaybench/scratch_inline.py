"""Independent stock-versus-aligned relay holdout using the ordinary 256 KiB pump."""
import hashlib
import json
import math
from pathlib import Path
import platform
import random
import statistics
import subprocess
import tempfile
from datetime import datetime, timezone

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASE = "a1e7965b277943dba589b8937c3de5a8121f4db7"
SEED = 94673
BLOCKS = 24
# KiB offered, waves, instrument a late fresh reply after the first bulk write.
CELLS = {"bulk": (256, 32, False), "small": (4, 512, False),
         "bulk_with_marker": (256, 64, True), "small_with_marker": (4, 256, True)}
ARMS = ("stock", "aligned")
FLAGS = ["-std=gnu11", "-Wall", "-Wextra", "-Werror", '-DRELAY_SOURCE="pump.h"']


def sha(data):
    return hashlib.sha256(data).hexdigest()


def sample(exe, arm, kib, count, marked):
    row = json.loads(subprocess.check_output([exe, str(kib), str(count)], text=True, timeout=35))
    if (row["verified_bytes"] != kib * 1024 * 16 * count or row["piece"] != kib * 1024 or
            min(row["wall_ns"], row["owner_ns"]) <= 0 or (arm == "aligned" and row["offset"] != 0)):
        raise ValueError("wrong work, timing or candidate layout")
    if marked:
        if (len(row["fresh_ns"]) != count or min(row["fresh_ns"]) <= 0 or
                row["bytes_ahead_per_reply"] != 15 * kib * 1024):
            raise ValueError("missing marker or different scheduled service order")
    elif "fresh_ns" in row:
        raise ValueError("instrumentation in primary run")
    return row


def stats(blocks, cell):
    metrics = {"mib_s": lambda r: r["verified_bytes"] / 2**20 / (r["wall_ns"] / 1e9),
               "owner_cpu_s_per_gib": lambda r: r["owner_ns"] / 1e9 / (r["verified_bytes"] / 2**30)}
    if CELLS[cell][2]:
        for q in (0.95, 0.99):
            metrics[f"fresh_p{round(q*100)}_us"] = lambda r, q=q: sorted(r["fresh_ns"])[math.ceil(q * len(r["fresh_ns"])) - 1] / 1000
    out = {}
    for name, value in metrics.items():
        arms = {arm: [value(block[cell][arm]) for block in blocks] for arm in ARMS}
        paired = [100 * (b / a - 1) for a, b in zip(arms["stock"], arms["aligned"])]
        rng = random.Random(SEED)
        boot = sorted(statistics.median(rng.choices(paired, k=len(paired))) for _ in range(10000))
        out[name] = dict(medians={a: statistics.median(v) for a, v in arms.items()},
                         paired_change_pct=statistics.median(paired), ci95_pct=[boot[249], boot[9749]])
    return out


def main():
    rng = random.Random(SEED)
    hashes, builds, qualification = {}, {}, {}
    with tempfile.TemporaryDirectory(prefix="mp-scratch-inline-") as tmp:
        work = Path(tmp)
        base_files = {}
        for name in ("Sources/CPublishedTCP/PublishedTCP.c", "Sources/CPublishedTCP/include/PublishedTCP.h",
                     "scripts/relaybench/filter_work.c", "scripts/relaybench/ready_queue_timing.c"):
            data = subprocess.check_output(["git", "show", BASE + ":" + name], cwd=ROOT)
            hashes[name] = sha(data)
            base_files[Path(name).name] = data
        for name in ("scratch_inline.c", "scratch_inline.patch", "scratch_inline.py"):
            hashes[name] = sha((HERE / name).read_bytes())
        for arm in ARMS:
            directory = work / arm
            directory.mkdir()
            for name, data in base_files.items():
                (directory / name).write_bytes(data)
            if arm == "aligned":
                subprocess.run(["patch", "-s", "-p0", "-i", HERE / "scratch_inline.patch"], cwd=directory, check=True)
            hashes[f"{arm}_native_source"] = sha((directory / "PublishedTCP.c").read_bytes())
            helpers = (directory / "ready_queue_timing.c").read_text().split("int main(int argc, char **argv)", 1)
            if len(helpers) != 2:
                raise ValueError("expected fixed-work fixture helpers")
            (directory / "wave_helpers.h").write_text(helpers[0])
            (directory / "pump.h").write_text('#if TRACE_MARKER\n#define write(...) trace_write(__VA_ARGS__)\n#endif\n'
                                              '#include "PublishedTCP.c"\n#if TRACE_MARKER\n#undef write\n#endif\n')
            for kind, trace, extras in (("timed", 0, ["-O2"]), ("marked", 1, ["-O2"]),
                                        ("checked", 1, ["-O1", "-fsanitize=address,undefined", "-fno-sanitize-recover=all"])):
                flags = [*FLAGS, *extras, f"-DTRACE_MARKER={trace}"]
                exe = directory / kind
                subprocess.run(["clang", *flags, "-I", directory, HERE / "scratch_inline.c", "-o", exe], check=True)
                builds[f"{arm}/{kind}"] = dict(sha256=sha(exe.read_bytes()), flags=flags)
            qualification[arm] = [sample(directory / "checked", arm, kib, 4, True) for kib in (4, 256)]
        orders = {name: [ARMS, ARMS[::-1]] * (BLOCKS // 2) for name in CELLS}
        for name, (kib, _, marked) in CELLS.items():
            rng.shuffle(orders[name])
            for arm in ARMS:
                sample(work / arm / ("marked" if marked else "timed"), arm, kib, 8, marked)
        blocks = []
        for n in range(BLOCKS):
            block = {}
            for name in rng.sample(list(CELLS), len(CELLS)):
                kib, count, marked = CELLS[name]
                block[name] = {arm: sample(work / arm / ("marked" if marked else "timed"),
                                           arm, kib, count, marked) for arm in orders[name][n]}
            blocks.append(block)
    print(json.dumps(dict(base=BASE, seed=SEED, completed_utc=datetime.now(timezone.utc).isoformat(),
                          platform=platform.platform(), source_sha256=hashes, builds=builds, qualification=qualification,
                          compiler=subprocess.check_output(["clang", "--version"], text=True).splitlines()[0],
                          primary="256 KiB offered on each of 16 established streams; full verified throughput and owner CPU/GiB.",
                          method="Independent randomized paired 24-block holdout with 12 AB and 12 BA per cell. "
                                 "Unmodified stock C and ordinary 256 KiB cap, flat owner, 128 events per callback, "
                                 "identical optimization flags. The candidate moves inline scratch to offset zero, "
                                 "allocates a single host-page-aligned relay object with posix_memalign, explicitly "
                                 "zeros it, and uses stock free/release. Equal requested object sizes. No data-path "
                                 "or buffer pointer substitution. Wall throughput includes all byte generation/delivery "
                                 "and verification within the wave loop on a background thread. Owner CPU times native drains. "
                                 "Priming and teardown are excluded. Marked binaries separately time one reply from "
                                 "injection just after the first bulk write until its forwarded write on the owner; "
                                 "each cell checks exact bulk bytes ahead of every reply, both FINs and reverse data. "
                                 "These are anonymous socketpairs, not TCP latency or an end-to-end peer result. "
                                 "Intervals resample paired per-block changes, including paired within-block p95/p99.",
                          summary={n: stats(blocks, n) for n in CELLS}, blocks=blocks), indent=2))


if __name__ == "__main__":
    main()
