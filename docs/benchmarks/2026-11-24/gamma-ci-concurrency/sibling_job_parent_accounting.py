"""Replay CPU counters at the worker, job and payload levels from the guest observer."""
import argparse
import json
from pathlib import Path

from qualify import require
from sibling_compiler_affinity_evidence import counters, difference, pressure
from sibling_job_parent_evidence import expected_parent, read


def delta(before, after):
    values = difference(counters(before["cpu.stat"]), counters(after["cpu.stat"]))
    require(("cpu.pressure" in before) == ("cpu.pressure" in after), "CPU pressure accounting changed")
    if "cpu.pressure" in before:
        values["pressure_usec"] = difference(pressure(before["cpu.pressure"]), pressure(after["cpu.pressure"]))
    return values


def total(level):
    return {field: sum(row[field] for row in level) for field in
            ("usage_usec", "user_usec", "system_usec", "nr_periods", "nr_throttled", "throttled_usec")}


def replay(folder):
    plan = read(folder, "plan.json")
    require(read(folder, "status.json") == {"complete": True}, "only completed worker scopes are eligible")
    mode = plan["job_parent"]
    inv = read(folder, "grouped-inventory.json")["A"]["jobs"]
    start, end = [read(folder, "job-parent-" + phase + ".json")["arms"]["A"]["worker"] for phase in ("before", "after")]
    require(len(inv) == len(start["memberships"]) == 64 and start["memberships"] == end["memberships"]
            and start["boot"] == end["boot"] and start["nodes"].keys() == end["nodes"].keys(),
            "kernel task membership or control hierarchy changed during accounting")
    for k, group in start["groups"].items():
        require(group["inode"] == end["groups"][k]["inode"] > 0, "cgroup replaced across samples")
    by_path = {path: delta(row, end["nodes"][path]) for path, row in start["nodes"].items()}
    roles = {"builder": [], "builder_dependency": [], "http_only_client": [], "http_only_service": []}
    parents, leaves = {}, set()
    for i, job in enumerate(inv):
        leaf = start["memberships"][job["id"]]["path"]
        parent = expected_parent(job, mode)
        require(str(Path(leaf).parent) == parent and leaf not in leaves, "incorrect or shared payload leaf")
        leaves.add(leaf)
        parents.setdefault(parent, []).append(leaf)
        role = ("builder_dependency" if i < 8 else "http_only_service") if i < 32 else (
            "builder" if i < 40 else "http_only_client")
        roles[role].append(by_path[leaf])
    require(len(parents) == (1 if mode == "flat" else 32) and
            all(len(row) == (64 if mode == "flat" else 2) for row in parents.values()), "wrong job grouping")
    return {"archive": folder.name, "seed": plan["seed"], "mode": mode, "boot": start["boot"],
            "worker": by_path["/"], "runtime": by_path["/k8s.io"],
            "per_job_parents": {p: by_path[p] for p in sorted(parents) if p != "/k8s.io"},
            "job_parent_totals": total([by_path[p] for p in parents]) if mode == "job" else None,
            "payload_totals": total([by_path[p] for p in leaves]),
            "payload_by_role": {k: {"leaves": len(v), **total(v)} for k, v in roles.items()}}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folders", type=Path, nargs="+")
    paths = parser.parse_args().folders
    require(len(set(paths)) == len(paths), "duplicate archive")
    print(json.dumps({"scope": "Guest snapshots enclose qualification, the paced workload and post-work host counter calibration.",
                      "runs": [replay(folder) for folder in paths]}, indent=2))
