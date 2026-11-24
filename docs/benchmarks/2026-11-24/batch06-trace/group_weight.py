"""Evaluate stock concur and candidate tasks modes using exact Linux functions."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
FAIR = "d23f85896da9c68cae4f6969c55d8915db51f77b15a3521a4eb8c26c60ce1460"
SCHED = "40f9b78752fbd166a11b3e3d8120b3aaaa7ef52d6101e83d5883d0ba7c1c54f3"
ARCHIVE = ROOT / "docs/benchmarks/2026-11-21/gamma-direct-macvlan.json.gz"
ARCHIVE_SHA = "cc3b9e5c365383a3353423ce1f7fc443c8d858a1af24bb082117bcec24ffa976"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def verified(path, expected):
    data = path.read_bytes()
    assert digest(data) == expected
    return data


def extract(tree):
    src = verified(tree / "kernel/sched/fair.c", FAIR).decode()
    defs = verified(tree / "kernel/sched/sched.h", SCHED).decode()
    functions = []
    for start in ["static long __calc_smp_shares(", "static int tg_cpus(", "static inline int tg_tasks(",
                  "static long calc_tasks_shares(", "static long calc_concur_shares("]:
        a = src.index(start)
        functions.append(src[a:src.index("\n}", a)+2])
    scale = defs[defs.index("# define scale_load(w)"):defs.index("\n#else", defs.index("# define scale_load(w)"))]
    minimum = next(line for line in defs.splitlines() if line.startswith("#define MIN_SHARES"))
    return ("/* SPDX-License-Identifier: GPL-2.0 */\n" + minimum + "\n" + scale + "\n" + "\n".join(functions) + "\n").encode()


def run(tree):
    scope = json.loads(gzip.decompress(verified(ARCHIVE, ARCHIVE_SHA)))["records"]["workers"]["trial"]
    budget = [{k: s[k] for k in ("cpu.max", "cpuset.cpus.effective")} for s in [scope["state"], scope["after"]]]
    assert budget[0] == budget[1] == {"cpu.max": "400000 100000", "cpuset.cpus.effective": "0-3"}
    if tree:
        assert (HERE / "group_weight.inc").read_bytes() == extract(tree)
    with tempfile.TemporaryDirectory() as td:
        out = Path(td) / "weights"
        subprocess.run(["clang", "-std=gnu11", "-O2", "-Wall", "-Werror", str(HERE / "group_weight.c"),
                        "-o", out], check=True)
        lines = subprocess.check_output([out], text=True).splitlines()
    rows = []
    for line in lines:
        service, sibling, mode, sw, bw = map(int, line.split())
        rows.append(dict(service_runnable_tasks=service, sibling_runnable_tasks=sibling,
                         weight_mode=("concur", "tasks")[mode], service_weight=sw, sibling_weight=bw,
                         service_to_sibling_weight_ratio=sw/bw))
    assert len(rows) == 14
    return dict(stable_id="231.10", source_revision="17bcd4355234b11da3a7a1da2ded52f4dc20f5d1",
                linux="7.3.5", fair_c_sha256=FAIR, sched_h_sha256=SCHED, archived_budget=budget[0],
                budget_archive=ARCHIVE.name, budget_archive_sha256=ARCHIVE_SHA,
                fixture_sha256={name:digest((HERE/name).read_bytes()) for name in
                                ("group_weight.c", "group_weight.inc", "group_weight.py")},
                compiler=subprocess.check_output(["clang", "--version"], text=True).splitlines()[0],
                cases=rows)


if __name__ == "__main__":
    cli = argparse.ArgumentParser()
    cli.add_argument("--verify-source", type=Path)
    opts = cli.parse_args()
    print(json.dumps(run(opts.verify_source), indent=2))
