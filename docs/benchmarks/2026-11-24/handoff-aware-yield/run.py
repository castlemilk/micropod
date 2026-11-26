"""Rebuild and replay four fixed-work Darwin socketpair cases without a VM or TCP listener."""
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
INPUTS = [
    "Sources/CPublishedTCP/PublishedTCP.c",
    "Sources/CPublishedTCP/include/PublishedTCP.h",
    "scripts/relaybench/callback_handoff_work.c",
    "scripts/relaybench/filter_work.c",
]
FLAGS = ["-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror", "-fblocks", "-DMICROPOD_BENCH_FIXED_RELAY_BUDGET=1"]
ORDER = ("control", "candidate", "candidate", "control")


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run():
    with tempfile.TemporaryDirectory(prefix="micropod-handoff-yield-") as directory:
        tree = Path(directory)
        for name in INPUTS:
            (tree / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, tree / name)
        subprocess.run(["patch", "-s", "-p1", "-i", str(HERE / "experiment.patch")], cwd=tree, check=True)
        subprocess.run(["clang", *FLAGS, "-I", "Sources/CPublishedTCP/include", INPUTS[2], "-o", "experiment"],
                       cwd=tree, check=True)
        passes = []
        for arm in ORDER:
            stdout = subprocess.check_output([tree / "experiment", arm], text=True, timeout=25)
            rows = [json.loads(line) for line in stdout.splitlines()]
            if [r["enqueue_after_write"] for r in rows] != [0, 1, 16, 25]:
                raise ValueError("missing or reordered arrival positions")
            for r in rows:
                fresh = r["enqueue_after_write"] > 0
                if (r["yield_on_handoff"] != (arm == "candidate") or r["budget"] != 128
                        or r["read_cap"] != 256 * 1024 or r["bulk_bytes"] != 8 * 2**20 or r["bulk_writes"] != 32
                        or r["verified_half_closes"] != 2 * (8 + fresh)
                        or r["handoff_yields"] != int(fresh and arm == "candidate")
                        or not 0 < r["nonempty_callbacks"] <= r["nonempty_polls"]):
                    raise ValueError(f"incomplete fixed-work arm: {r}")
                if fresh and not 0 <= r["bytes_ahead_of_entry"] <= r["bytes_ahead_of_readable_reply"] <= (
                        r["bulk_bytes"] - r["enqueue_after_write"] * r["read_cap"]):
                    raise ValueError("entry or reply outside the burst")
            passes.append(rows)
    if passes[0] != passes[3] or passes[1] != passes[2]:
        raise ValueError("readiness ordering changed between repetitions")
    return {
        "evidence": "Darwin fixed work on AF_UNIX stream socketpairs, one of four modeled data owners",
        "source_revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "input_sha256": {p: sha(ROOT / p) for p in INPUTS},
        "experiment_sha256": {p: sha(HERE / p) for p in ("experiment.patch", "run.py")},
        "toolchain": subprocess.check_output(["clang", "--version"], text=True).splitlines()[0],
        "platform": [platform.machine(), platform.mac_ver()[0]],
        "compiler_flags": FLAGS, "arm_order": ORDER, "raw_passes": passes,
    }


if __name__ == "__main__":
    print(json.dumps(run(), indent=2))
