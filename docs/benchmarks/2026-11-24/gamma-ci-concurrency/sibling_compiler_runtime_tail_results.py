"""Replay timed compiler tails and enclosing CPU counters without reading HTTP samples."""

import argparse
import json
from pathlib import Path
from random import Random
from statistics import median

import sibling_build_tail_results as tail
import sibling_compiler_runtime_results as runtime
from qualify import require
from sibling_compiler_affinity_evidence import verify_wave
from sibling_compiler_slice_evidence import verify as verify_tools
from sibling_build import check_revision


ARMS = {"A": "Micropod", "B": "OrbStack"}
ROLES = ("builder", "dependency")


def read_run(folder):
    read = lambda name: tail.read(folder, name)
    plan = read("plan.json")
    seed, mode = runtime.check_plan(folder, plan)
    require(read("status.json")["complete"] is True
            and read("verification.json") == {"baseline_files": 24, "extra_cleanup_errors": []}
            and read("cleanup.json") == {"scope": plan["scope"], "retained": False, "errors": []}
            and not Path(plan["scope"]).exists(), f"incomplete or unclean compiler runtime archive {folder}")
    inventory = read("grouped-inventory.json")
    clients = tail.check_placement(inventory, plan["cpu_group_label"], compiler_affinity="home")
    prime = read("grouped-prime.json")
    boots = {arm: check_revision(prime[arm], "sib-prime", clients[arm][0]["name"])["boot"] for arm in ARMS}
    facts = (folder / "a/guest-facts.txt").read_text().splitlines()
    require([row for row in facts if row.startswith("boot=")] == ["boot=" + boots["A"]],
            "compiler records belong to a different native boot")
    tool_identity = verify_tools(folder, plan, inventory, boots)

    saved = read("windows.json")
    orders = ["AB", "BA"] * (plan["rounds"] // 2)
    Random(seed).shuffle(orders)
    require(set(saved) == {f"grouped-{i}-{window}" for i in range(plan["rounds"]) for window in ("one", "all")},
            "missing or unplanned runtime windows")
    windows = []
    for block, order in enumerate(orders):
        key = f"grouped-{block}-all"
        require(saved[key]["order"] == saved[f"grouped-{block}-one"]["order"] == order,
                "compiler runtime engine order differs")
        matched, cpu = {}, {}
        for arm in ARMS:
            tag = f"{key}-{arm}"
            jobs = inventory[arm]["jobs"]
            raw = read(f"{tag}-go.json")
            runtime.check_builds(raw, jobs, arm, mode, tag, block)
            rows = tail.build_rows(raw, clients[arm], arm, block, boots[arm], plan["build_nice"])
            for row, job in zip(rows, clients[arm], strict=True):
                row["cpu"] = job["home_cpu"]
            measured = tail.timing(rows)
            products = [r["product"] for slot in rows for r in slot["revisions"]]
            build = saved[key][arm]["build"]
            require(len(set(products)) == 2 * tail.BUILDERS and build["products"] == products
                    and build["makespan_s"] == measured["makespan_ns"] / 1e9
                    and build["slowest_job_s"] == measured["slowest_job_elapsed_ns"] / 1e9,
                    f"saved compiler times or products differ for {tag}")
            matched[arm] = rows
            cpu[arm] = verify_wave(folder, block, arm, jobs, boots[arm])
        windows.append({"order": order, "rows": matched, "cpu": cpu, "paired_engines": tail.pair(matched)})
    return {"run": folder.name, "plan": plan, "boots": boots, "tools": tool_identity,
            "start": min(row["start"] for row in windows[0]["rows"]["A"]), "windows": windows}


def comparison(pairs, first, second):
    result = tail.summarize(pairs)
    jobs = result["matched_jobs"]
    return {"window_count": result["windows"],
            "median_by_side": {first: result["engine_medians"]["A"], second: result["engine_medians"]["B"]},
            "median_paired_first_minus_second_ns": result["median_paired_gaps_ns"],
            "first_lower_windows": result["native_lower_windows"],
            "same_home_late_pairs": {first: result["late_vcpu"]["A"], second: result["late_vcpu"]["B"]},
            "matched_slots": {"count": jobs["count"], first: jobs["native_faster"], second: jobs["native_slower"],
                              "median_first_minus_second_ns": jobs["median_gap_ns"]},
            "additive_first_minus_second_sum_ns": result["additive_gap_sum_ns"]}


def window_pressure(window, arm, role):
    samples = [row[role]["psi_usec"] for row in window["cpu"][arm]["groups"]]
    return sum(row["some"] for row in samples) if all("some" in row for row in samples) else None


def counters(windows, arm, role):
    samples = [[row[role] for row in window["cpu"][arm]["groups"]] for window in windows]
    totals = {field: sum(row[field] for rows in samples for row in rows)
              for field in ("nr_periods", "nr_throttled", "throttled_usec")}
    usage = [sum(row["usage_usec"] for row in rows) for rows in samples]
    pressure = [value for window in windows if (value := window_pressure(window, arm, role)) is not None]
    return {"cgroup_observations": sum(map(len, samples)), **totals,
            "median_window_usage_usec": median(usage),
            "some_pressure_windows": len(pressure),
            "median_window_sum_some_pressure_usec": median(pressure) if pressure else None}


def paired_pressure(inherit, long, arm, role):
    pairs = [(window_pressure(a, arm, role), window_pressure(b, arm, role)) for a, b in zip(inherit, long, strict=True)]
    deltas = [b - a for a, b in pairs if a is not None and b is not None]
    return {"matched_windows": len(deltas), "long_lower_windows": sum(value < 0 for value in deltas),
            "median_long_minus_inherit_usec": median(deltas) if deltas else None}


def summary(inherit, long):
    require(len(inherit) == len(long) and all(a["order"] == b["order"] for a, b in zip(inherit, long, strict=True)),
            "compiler runtime changed matched engine order")
    modes = {"inherit": inherit, "long": long}
    return {
        "native_minus_peer": {
            mode: comparison([window["paired_engines"] for window in windows], "Micropod", "OrbStack")
            for mode, windows in modes.items()},
        "long_minus_inherit": {
            label: comparison([tail.pair({"A": b["rows"][arm], "B": a["rows"][arm]})
                               for a, b in zip(inherit, long, strict=True)], "long", "inherit")
            for arm, label in ARMS.items()},
        "enclosing_cpu_counters": {
            mode: {label: {role: counters(windows, arm, role) for role in ROLES} for arm, label in ARMS.items()}
            for mode, windows in modes.items()},
        "paired_some_pressure": {
            label: {role: paired_pressure(inherit, long, arm, role) for role in ROLES} for arm, label in ARMS.items()},
    }


def report(folders):
    paths = [path.resolve() for path in folders]
    require(len(paths) == len(set(paths)) == 4, "expected four distinct compiler runtime archives")
    indexed = {}
    reference = None
    for path in paths:
        run = read_run(path)
        plan = run["plan"]
        key = plan["seed"], plan["compiler_runtime"]
        require(key not in indexed, "duplicate compiler runtime seed and mode")
        fixed = ({k: v for k, v in plan.items() if k not in ("scope", "seed", "compiler_runtime")},
                 run["boots"]["B"], run["tools"]["executables"])
        if reference is None:
            reference = fixed
        require(fixed == reference, "compiler runtime changed fixed plan, peer boot or actual Go executables")
        indexed[key] = run
    require(set(indexed) == {(seed, mode) for seed in runtime.SEED_ORDER for mode in runtime.MODES}
            and len({run["boots"]["A"] for run in indexed.values()}) == 4
            and len({run["plan"]["scope"] for run in indexed.values()}) == 4,
            "missing runtime comparison cells or duplicate native guest boot")

    pooled = {mode: [] for mode in runtime.MODES}
    by_seed = []
    for seed, order in runtime.SEED_ORDER.items():
        runs = {mode: indexed[seed, mode] for mode in runtime.MODES}
        require(runs[order[0]]["start"] < runs[order[1]]["start"], "unexpected compiler runtime treatment order")
        for mode, run in runs.items():
            pooled[mode].extend(run["windows"])
        by_seed.append({"seed": seed, "treatment_order": order,
                        "runs": {mode: run["run"] for mode, run in runs.items()},
                        **summary(runs["inherit"]["windows"], runs["long"]["windows"])})
    return {"slices_ns": {mode: {label: runtime.effective_ns(arm, mode) for arm, label in ARMS.items()}
                          for mode in runtime.MODES},
            "cpu_scope": "CPU counters include the enclosing build and HTTP workload, including setup and drain.",
            "by_seed": by_seed, **summary(pooled["inherit"], pooled["long"])}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folders", type=Path, nargs=4, help="the four completed compiler runtime archives")
    print(json.dumps(report(parser.parse_args().folders), indent=2, allow_nan=False))
