"""Paced sweep of every arrival position in the original finite bulk burst."""
import json
import random
from collections import Counter
from pathlib import Path
import platform
import shutil
from statistics import median
import subprocess
import tempfile
import time

from run import FLAGS, HERE, INPUTS, ROOT, sha

SEED = 23003
PAUSE_S = 0.125
POSITIONS = list(range(33))
ARMS = ["control", "candidate"]


def schedule():
    positions = POSITIONS.copy()
    random.Random(SEED).shuffle(positions)
    pairs = [(p, ARMS if i % 2 == 0 else ARMS[::-1]) for i, p in enumerate(positions)]
    return pairs + [(p, order[::-1]) for p, order in reversed(pairs)]


def summarize(pairs):
    seen = {}
    for pair, (p, arms) in zip(pairs, schedule(), strict=True):
        if [pair["position"], pair["order"]] != [p, arms] or set(pair["rows"]) != set(ARMS):
            raise ValueError("arrival or arm order differs from the plan")
        for arm, r in pair["rows"].items():
            if (r["enqueue_after_write"] != p or r["yield_on_handoff"] != (arm == "candidate")
                    or (r["budget"], r["read_cap"], r["bulk_bytes"], r["bulk_writes"]) != (128, 262144, 8388608, 32)
                    or r["verified_half_closes"] != 2 * (8 + (p != 0))
                    or not 0 < r["nonempty_callbacks"] <= r["nonempty_polls"]
                    or r["handoff_yields"] != int(arm == "candidate" and p != 0)):
                raise ValueError(f"wrong controls or incomplete work at position {p}, arm {arm}")
            if p and not 0 <= r["bytes_ahead_of_entry"] <= r["bytes_ahead_of_readable_reply"] <= (32 - p) * 262144:
                raise ValueError("bulk byte position outside the burst")
        if p in seen and pair["rows"] != seen[p]:
            raise ValueError(f"repeat disagrees at arrival {p}")
        seen[p] = pair["rows"]

    # Cross-check against the unmodified four-case receipt on its original positions.
    original = json.loads((HERE / "result.json").read_text())
    for arm, rows in zip(original["arm_order"], original["raw_passes"], strict=True):
        for r in rows:
            if seen[r["enqueue_after_write"]][arm] != r:
                raise ValueError("original experiment did not reproduce")

    result = {"no_handoff": seen[0], "positions_with_handoff": 32}
    for metric in ("bytes_ahead_of_entry", "bytes_ahead_of_readable_reply"):
        values = {a: [seen[p][a][metric] for p in POSITIONS[1:]] for a in ARMS}
        savings = [c - y for c, y in zip(*values.values(), strict=True)]
        result[metric] = {"improved_positions": [p for p, s in enumerate(savings, 1) if s > 0],
                          "tied_positions": [p for p, s in enumerate(savings, 1) if s == 0],
                          "worse_positions": [p for p, s in enumerate(savings, 1) if s < 0],
                          "maximum_by_arm": {a: max(counts) for a, counts in values.items()},
                          "median_saving_bytes_across_positions": median(savings),
                          "maximum_saving_bytes": max(savings)}
    result["productive_callbacks_by_arm"] = {
        a: dict(Counter(seen[p][a]["nonempty_callbacks"] for p in POSITIONS[1:])) for a in ARMS}
    return result


def sweep():
    pairs = []
    with tempfile.TemporaryDirectory(prefix="micropod-handoff-sweep-") as directory:
        tree = Path(directory)
        for name in INPUTS:
            (tree / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, tree / name)
        for patch in ("experiment.patch", "sweep.patch"):
            subprocess.run(["patch", "-s", "-p1", "-i", str(HERE / patch)], cwd=tree, check=True)
        subprocess.run(["clang", *FLAGS, "-I", "Sources/CPublishedTCP/include", INPUTS[2], "-o", "experiment"],
                       cwd=tree, check=True)
        for position, order in schedule():
            pair = {"position": position, "order": order, "rows": {}}
            for arm in order:
                stdout = subprocess.check_output([tree / "experiment", arm, str(position)], text=True, timeout=25)
                pair["rows"][arm] = json.loads(stdout)
                time.sleep(PAUSE_S)
            pairs.append(pair)
    return {
        "evidence": "Darwin AF_UNIX fixed delivery ordering",
        "source_revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "input_sha256": {p: sha(ROOT / p) for p in INPUTS},
        "experiment_sha256": {p: sha(HERE / p) for p in ("experiment.patch", "sweep.patch", "sweep.py", "run.py", "result.json")},
        "toolchain": subprocess.check_output(["clang", "--version"], text=True).splitlines()[0],
        "platform": [platform.machine(), platform.mac_ver()[0]], "compiler_flags": FLAGS,
        "seed": SEED, "pause_between_invocations_s": PAUSE_S, "summary": summarize(pairs), "pairs": pairs,
    }


if __name__ == "__main__":
    print(json.dumps(sweep(), indent=2))
