"""Replay build completion times from completed paced archives without reading HTTP samples."""

import argparse
from collections import Counter
import json
from pathlib import Path
from random import Random
from statistics import mean, median

from qualify import require
from sibling_build import AFFINITY_DISPATCH_FILE, check_dispatch_policy, check_revision, compiler_mask
from sibling_group import check_threads


PAIRS, BUILDERS = 32, 8
CPU_MASKS = Counter({str(cpu): 2 for cpu in range(4)})
MATCH_FIELDS = ("product", "dependency", "compile", "vet", "link", "tests")
DECOMPOSITION = ("median_job_elapsed_ns", "last_finisher_excess_ns", "last_finisher_start_offset_ns")
METRICS = ("makespan_ns", "median_job_elapsed_ns", "slowest_job_elapsed_ns", "launch_skew_ns",
           "finish_spread_ns", "last_finisher_excess_ns", "last_finisher_start_offset_ns",
           "last_vs_penultimate_finish_ns", "penultimate_finish_above_median_ns",
           "median_within_vcpu_finish_spread_ns", "between_vcpu_mean_finish_spread_ns",
           "median_two_revision_cgroup_cpu_ns")


def read(folder, name):
    return json.loads((folder / name).read_bytes())


def check_placement(inventory, group_label, *, compiler_affinity=None):
    clients = {}
    for arm in "AB":
        jobs = inventory[arm]["jobs"]
        require(len(jobs) == PAIRS * 2 and len({j["id"] for j in jobs}) == len(jobs),
                f"missing or duplicate {arm} containers")
        clients[arm] = jobs[PAIRS:PAIRS + BUILDERS]
        for slot, (service, client) in enumerate(zip(jobs[:BUILDERS], clients[arm], strict=True)):
            for job in (service, client):
                inspect = job["docker_inspect"]
                require(inspect["Id"] == job["id"] and inspect["Name"] == "/" + job["name"] and
                        inspect["Config"]["Labels"][group_label] == job["cpu_group"] == f"job-{slot:02d}" and
                        inspect["HostConfig"]["CpusetCpus"] == job["cgroup"]["cpuset.cpus.effective"] == job["mask"],
                        f"{arm} slot {slot} has inconsistent Docker or kernel placement")
                if compiler_affinity:
                    affinity = job["affinity"]
                    check_threads(affinity["threads"], affinity["pid"], str(slot % 4))
                    require(job["cgroup"]["cpu.max"] == "100000 100000", f"{arm} slot {slot} changed its CPU quota")
            if compiler_affinity:
                require(service["mask"] == service["home_cpu"] == client["home_cpu"] == str(slot % 4) and
                        client["mask"] == client["requested_cpuset"] == "0-3" and
                        client["placement_source"] == "explicit-build-cpuset",
                        f"{arm} slot {slot} lacks a verified home and broad compiler cgroup")
            else:
                require(client["mask"] == service["mask"], f"{arm} slot {slot} has a split CPU group")
        field = "home_cpu" if compiler_affinity else "mask"
        require(Counter(job[field] for job in clients[arm]) == CPU_MASKS, f"{arm} builder CPU homes are unbalanced")
    return clients


def build_rows(raw, clients, arm, block, boot, nice, *, compiler_affinity=None):
    require(len(raw) == BUILDERS, f"{arm} round {block} is missing builders")
    rows = []
    for slot, (row, job) in enumerate(zip(raw, clients, strict=True)):
        prefix = f"sibling-{block}-{slot}"
        where = f"{arm} round {block}, slot {slot}"
        require(row["code"] == 0 and row["revision"] == prefix and row["id"] == job["id"],
                f"{where} has a failed or unrelated build")
        first, second, end = row["stdout"].strip().splitlines()
        label, finished, actual_nice = end.split()
        started, finished = row["started_unix_ns"], int(finished)
        require(label == "end" and int(actual_nice) == nice and type(started) is int and 0 < started < finished,
                f"{where} has invalid dispatcher timestamps or nice value")
        if compiler_affinity:
            mask = compiler_mask(job, compiler_affinity)
            argv = ["exec", job["id"], "nice", "-n", nice, "taskset", "-c", mask, "/bin/sh",
                    "/mpcheck/" + AFFINITY_DISPATCH_FILE, f"grouped-{block}-all-{arm}", prefix, slot, nice]
            require(row["exec_argv"] == argv, f"{where} changed the compiler launch command")
            check_dispatch_policy(row["compiler_affinity"], "normal", nice, mask, slot=slot)
        revisions = [check_revision(line, f"{prefix}-{suffix}", job["name"])
                     for line, suffix in ((first, "a"), (second, "b"))]
        require(all(r["boot"] == boot for r in revisions), f"{where} has a different guest boot")
        cpu_usec = sum(round(r["cpu_s"] * 1_000_000) for r in revisions)
        rows.append({"slot": slot, "cpu": job["home_cpu"] if compiler_affinity else job["mask"],
                     "start": started, "end": finished,
                     "elapsed_ns": finished - started, "cgroup_cpu_ns": cpu_usec * 1000,
                     "revisions": [{field: r[field] for field in MATCH_FIELDS} for r in revisions]})
    return rows


def timing(rows):
    starts = [r["start"] for r in rows]
    elapsed = [r["elapsed_ns"] for r in rows]
    # Give the lower slot precedence when finish timestamps tie.
    finish_order = sorted(rows, key=lambda r: (r["end"], -r["slot"]))
    penultimate, last = finish_order[-2:]
    first_start = min(starts)
    finish_offsets = [r["end"] - first_start for r in finish_order]
    finish_by_vcpu = {}
    for row in finish_order:
        finish_by_vcpu.setdefault(row["cpu"], []).append(row["end"] - first_start)
    vcpu_means = [mean(offsets) for offsets in finish_by_vcpu.values()]
    middle = median(elapsed)
    return {"makespan_ns": finish_offsets[-1], "median_job_elapsed_ns": middle,
            "slowest_job_elapsed_ns": max(elapsed), "launch_skew_ns": max(starts) - first_start,
            "finish_spread_ns": finish_offsets[-1] - finish_offsets[0],
            "last_finisher_slot": last["slot"], "last_finisher_vcpu": last["cpu"],
            "penultimate_finisher_slot": penultimate["slot"], "last_two_same_vcpu": last["cpu"] == penultimate["cpu"],
            "last_finisher_excess_ns": last["elapsed_ns"] - middle,
            "last_finisher_start_offset_ns": last["start"] - first_start,
            "last_vs_penultimate_finish_ns": finish_offsets[-1] - finish_offsets[-2],
            "penultimate_finish_above_median_ns": finish_offsets[-2] - median(finish_offsets),
            "median_within_vcpu_finish_spread_ns": median(offsets[-1] - offsets[0]
                                                          for offsets in finish_by_vcpu.values()),
            "between_vcpu_mean_finish_spread_ns": max(vcpu_means) - min(vcpu_means),
            "median_two_revision_cgroup_cpu_ns": median(r["cgroup_cpu_ns"] for r in rows)}


def pair(rows):
    require(all((a["slot"], a["cpu"], a["revisions"]) == (b["slot"], b["cpu"], b["revisions"])
                for a, b in zip(rows["A"], rows["B"], strict=True)),
            "matched builds have different slots, CPU placements, or outputs")
    engines = {arm: timing(values) for arm, values in rows.items()}
    gap = {name: engines["A"][name] - engines["B"][name] for name in METRICS}
    require(gap["makespan_ns"] == sum(gap[name] for name in DECOMPOSITION), "build gap failed to reconcile")
    first_start = {arm: min(row["start"] for row in values) for arm, values in rows.items()}
    slots = [{"slot": a["slot"], "cpu": a["cpu"],
              "elapsed_ns": {"A": a["elapsed_ns"], "B": b["elapsed_ns"]},
              "start_offset_ns": {"A": a["start"] - first_start["A"], "B": b["start"] - first_start["B"]}}
             for a, b in zip(rows["A"], rows["B"], strict=True)]
    return {"engines": engines, "gap_ns": gap, "slots": slots}


def summarize(windows):
    """Sum the additive terms across waves. Medians of individual terms need not add up."""
    gaps = {name: [w["gap_ns"][name] for w in windows] for name in METRICS}
    jobs = [s["elapsed_ns"]["A"] - s["elapsed_ns"]["B"] for w in windows for s in w["slots"]]
    engine_medians, late_vcpu = {}, {}
    for arm in "AB":
        timings = [w["engines"][arm] for w in windows]
        engine_medians[arm] = {name: median(row[name] for row in timings) for name in METRICS}
        counts = Counter(row["last_finisher_vcpu"] for row in timings)
        late_vcpu[arm] = {"last_finisher_vcpu_counts": {vcpu: counts[vcpu] for vcpu in CPU_MASKS},
                         "last_two_same_vcpu_windows": sum(row["last_two_same_vcpu"] for row in timings)}
    return {
        "windows": len(windows),
        "engine_medians": engine_medians,
        "median_paired_gaps_ns": {name: median(values) for name, values in gaps.items()},
        "native_lower_windows": {name: sum(gap < 0 for gap in values) for name, values in gaps.items()},
        "late_vcpu": late_vcpu,
        "matched_jobs": {"count": len(jobs), "native_faster": sum(t < 0 for t in jobs),
                         "native_slower": sum(t > 0 for t in jobs), "median_gap_ns": median(jobs)},
        "additive_gap_sum_ns": {name: sum(gaps[name]) for name in ("makespan_ns", *DECOMPOSITION)},
    }


def replay(folder):
    plan = read(folder, "plan.json")
    cleanup = read(folder, "cleanup.json")
    require(read(folder, "status.json")["complete"] is True and
            read(folder, "verification.json") == {"baseline_files": 24, "extra_cleanup_errors": []} and
            cleanup == {"scope": plan["scope"], "retained": False, "errors": []} and
            not Path(plan["scope"]).exists(), f"incomplete or unclean archive {folder}")
    require(plan["cpu_groups"] is True and plan["layouts"] == ["grouped"] and
            plan["healthy_pairs"] == PAIRS and plan["builders"] == BUILDERS and
            type(plan["seed"]) is type(plan["build_nice"]) is type(plan["rounds"]) is int and
            plan["rounds"] in (1, 4, 8) and plan["offered_rps"] > 0 and
            not (folder / "ext4-cache-plan.json").exists(), f"unexpected ordinary-cache workload in {folder}")
    effective = int((folder / "fair-scheduler/base-slice").read_text())
    require(effective > 0 and read(folder, "fair-scheduler.json")["base_slice_ns"] == effective,
            f"guest scheduler readback differs in {folder}")
    compiler_affinity = plan.get("compiler_affinity")
    require(compiler_affinity in (None, "home", "pool"), "unexpected compiler affinity")
    inventory = read(folder, "grouped-inventory.json")
    clients = check_placement(inventory, plan["cpu_group_label"], compiler_affinity=compiler_affinity)
    prime = read(folder, "grouped-prime.json")
    boots = {arm: check_revision(prime[arm], "sib-prime", clients[arm][0]["name"])["boot"] for arm in "AB"}
    facts = (folder / "a/guest-facts.txt").read_text().splitlines()
    require(boots["A"] != boots["B"] and [f for f in facts if f.startswith("boot=")] == ["boot=" + boots["A"]],
            f"guest boots differ from the worker or warmed jobs in {folder}")
    evidence = {}
    if compiler_affinity:
        from sibling_compiler_affinity_evidence import verify_sources, verify_tools, verify_wave

        verify_sources(folder, plan)
        evidence["compiler_executables"] = verify_tools(folder, plan, inventory, boots)
    saved = read(folder, "windows.json")
    orders = ["AB", "BA"] * ((plan["rounds"] + 1) // 2)
    Random(plan["seed"]).shuffle(orders)
    require(set(saved) == {f"grouped-{i}-{mode}" for i in range(plan["rounds"]) for mode in ("one", "all")},
            f"missing or unplanned windows in {folder}")
    windows = []
    for block, order in enumerate(orders[:plan["rounds"]]):
        tag = f"grouped-{block}-all"
        require(saved[tag]["order"] == saved[f"grouped-{block}-one"]["order"] == order,
                f"unexpected engine order in {folder}, round {block}")
        rows = {arm: build_rows(read(folder, f"{tag}-{arm}-go.json"), clients[arm], arm, block,
                                boots[arm], plan["build_nice"], compiler_affinity=compiler_affinity) for arm in "AB"}
        window = pair(rows)
        if compiler_affinity:
            window["compiler_cpu"] = {arm: verify_wave(folder, block, arm, inventory[arm]["jobs"], boots[arm])
                                      for arm in "AB"}
        for arm, measured in window["engines"].items():
            build = saved[tag][arm]["build"]
            products = [rev["product"] for row in rows[arm] for rev in row["revisions"]]
            require(len(set(products)) == BUILDERS * 2 and build["products"] == products and
                    build["makespan_s"] == measured["makespan_ns"] / 1e9 and
                    build["slowest_job_s"] == measured["slowest_job_elapsed_ns"] / 1e9,
                    f"replayed {arm} costs or outputs differ in {folder}, round {block}")
        windows.append({"round": block, "order": order, **window})
    return {"run": folder.name, "seed": plan["seed"], "boots": boots, "scope": plan["scope"], **evidence,
            "windows": windows, "summary": summarize(windows)}, plan, effective


def report(folders):
    paths = [folder.resolve() for folder in folders]
    require(len(set(paths)) == len(paths) > 0, "duplicate or missing build receipt directories")
    results = sorted((replay(folder) for folder in paths), key=lambda row: row[0]["seed"])
    runs = [run for run, _, _ in results]
    common = {key: value for key, value in results[0][1].items() if key not in ("scope", "seed")}
    effective = results[0][2]
    require(all({key: value for key, value in plan.items() if key not in ("scope", "seed")} == common
                and base == effective for _, plan, base in results), "build receipt settings or guest slices differ")
    require(len({r["seed"] for r in runs}) == len({r["scope"] for r in runs}) ==
            len({r["boots"]["A"] for r in runs}) == len(runs) and len({r["boots"]["B"] for r in runs}) == 1,
            "duplicate native seed, scope, or boot, or the peer boot changed")
    settings = {key: common[key] for key in ("worker_scheduler", "offered_rps", "build_nice", "network_topology",
                                            "build_scratch", "mac_process_type", "compiler_affinity") if key in common}
    cpu_scope = "CPU IDs are guest vCPUs from the matched container placement."
    if settings.get("compiler_affinity"):
        first_tools = runs[0]["compiler_executables"]
        require(all(r["compiler_executables"] == first_tools for r in runs), "compiler executable identity changed")
        cpu_scope = "CPU IDs are job homes in the guest. Pooled compilers can execute on any allowed vCPU."
    return {"engines": {"A": "Micropod", "B": "OrbStack"},
            "gap_direction": "Micropod minus OrbStack",
            "cpu_scope": cpu_scope,
            "cpu_accounting": "Revision counters include the entire builder cgroup and its concurrent HTTP client.",
            "settings": {**settings, "effective_native_base_slice_ns": effective},
            "summary": summarize([w for r in runs for w in r["windows"]]), "runs": runs}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folders", type=Path, nargs="+", help="completed paced receipt directories for one treatment")
    print(json.dumps(report(parser.parse_args().folders), indent=2))
