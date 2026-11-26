"""Replay the native compiler-only ordinary scheduler runtime crossover."""

import argparse
import json
import random
import re
from pathlib import Path
from statistics import median

import sibling_build
import sibling_compiler_affinity_results as affinity
import sibling_paced
import sibling_paced_results as paced
import sibling_slice_350_results as signed
import sibling_tmpfs
from qualify import require, terminal
from sibling_results import read


MODES = ("inherit", "long")
SEED_ORDER = {250211: MODES, 250213: MODES[::-1]}
ORDINARY_SLICE_NS = {"A": 250_000, "B": 2_100_000}
SOURCES = {
    "sibling-compiler-runtime.py": "compiler_runtime_driver_sha256",
    "sibling_compiler_runtime_linux.go": "compiler_runtime_source_sha256",
    "go-dispatch-runtime.sh": "compiler_runtime_dispatch_sha256",
}
RUNTIME_PROBE = "/mpcheck/compiler-runtime"


def requested_us(arm, mode):
    return 2100 if arm == "A" and mode == "long" else 0


def effective_ns(arm, mode):
    return requested_us(arm, mode) * 1000 or ORDINARY_SLICE_NS[arm]


def check_plan(folder, plan):
    from sibling_compiler_affinity_evidence import verify_sources
    from sibling_compiler_runtime import DISPATCH, launcher_source

    seed, mode = plan.get("seed"), plan.get("compiler_runtime")
    require(type(seed) is int and seed in SEED_ORDER and mode in MODES, "unexpected compiler runtime seed or mode")
    require(all(plan.get(k) == value for k, value in signed.WORKLOAD.items()) and
            plan.get("compiler_affinity") == "home" and plan.get("guest_fair") in (None, "inherit") and
            plan.get("slice_target", "all") == "all" and
            not any(plan.get(k) is not None for k in
                    ("fair_slice_us", "build_slice_us", "build_policy", "builder_shares", "ext4_cache_profile")) and
            not (folder / "ext4-cache-plan.json").exists(), "compiler runtime requires the signed grouped home workload")
    original = Path(__file__).with_name(sibling_build.POLICY_SOURCE).read_text()
    require(all(terminal.digest(folder / name) == plan[key] for name, key in (affinity.SOURCES | SOURCES).items()) and
            re.fullmatch(r"[a-f0-9]{64}", plan["compiler_runtime_probe_sha256"]) and
            (folder / "sibling_compiler_runtime_linux.go").read_text() == launcher_source(original) and
            (folder / "go-dispatch-runtime.sh").read_text() == DISPATCH,
            "unmatched compiler runtime launcher or dispatcher")
    verify_sources(folder, plan)
    return seed, mode


def check_threads(row, home, arm):
    sibling_build.check_http_policy(row["threads"], row["pid"], home)
    require({thread["slice_ns"] for thread in row["threads"]} == {ORDINARY_SLICE_NS[arm]},
            f"non-compiler process did not keep inherited scheduler runtime on {arm}")


def check_builds(rows, jobs, arm, mode, tag, block):
    require(len(rows) == paced.BUILDERS, "missing timed compiler runtime proof rows")
    request = requested_us(arm, mode)
    for slot, row in enumerate(rows):
        job = jobs[paced.PAIRS + slot]
        home = job["home_cpu"]
        argv = ["exec", job["id"], "nice", "-n", 0, "taskset", "-c", home, RUNTIME_PROBE, "-policy", "normal",
                "-build-slice-us", str(request), "/bin/sh", "/mpcheck/go-dispatch-runtime.sh",
                tag, f"sibling-{block}-{slot}", slot, 0]
        require(row["exec_argv"] == argv, f"wrong compiler runtime exec for {tag} slot {slot}")
        proof = row["compiler_affinity"]
        sibling_build.check_dispatch_policy(proof, "normal", 0, home, build_slice_us=request, slot=slot)
        require(proof["slice"]["inherited_ns"] == ORDINARY_SLICE_NS[arm],
                f"unexpected inherited compiler runtime for {tag} slot {slot}")
    return effective_ns(arm, mode)


def check_residents(inventory, after):
    require(after.keys() == inventory.keys() == affinity.ENGINES.keys(), "missing resident runtime cohorts")
    for arm, cohort in inventory.items():
        for job, stopped in zip(cohort["jobs"], after[arm], strict=True):
            pid = job["affinity"]["pid"]
            require(stopped["id"] == job["id"] and stopped["pid"] == pid,
                    f"resident process changed container or PID on {arm}")
            check_threads({"threads": job["runtime_threads"], "pid": pid}, job["home_cpu"], arm)
            check_threads(stopped, job["home_cpu"], arm)


def score_http(rows, jobs, arm, block, tag, one_request_count):
    dense = one_request_count is None
    for row in rows:
        slot = row["index"]
        require(type(slot) is int and 0 <= slot < paced.PAIRS, f"invalid HTTP slot for {tag}")
        server, client = jobs[slot], jobs[paced.PAIRS + slot]
        pin = ["taskset", "-c", client["home_cpu"]] if slot < paced.BUILDERS else []
        expected = ["exec", client["id"], *pin, "/mpcheck/quiet-http", "-thread-probe", RUNTIME_PROBE,
                    "-url", f"http://{server['ip']}:8080", "-marker", server["name"],
                    "-requests", 0 if dense else one_request_count, "-duration-ms", 1500 if dense else 0,
                    *sibling_paced.client_args(affinity.RATE if dense else None, slot),
                    "-ready-file", f"/gate/{tag}.{slot}", "-start-file", f"/gate/{tag}"]
        require(row["exec_argv"] == expected, f"wrong measured HTTP exec for {tag} slot {slot}")
        check_threads(row["receipt"]["window"], client["home_cpu"], arm)
    endpoints = [{"ip": job["ip"], "name": job["name"]} for job in jobs]
    page_bytes = 16_384 if arm == "A" else 4_096
    if dense:
        return paced.score_wave(rows, endpoints, affinity.RATE, page_bytes)
    slot = block % paced.PAIRS
    response = rows[0]["receipt"]
    require(not response.get("pace") and response["window"]["page_bytes"] == page_bytes and
            response["url"] == f"http://{jobs[slot]['ip']}:8080/id", "wrong unpaced response")
    return paced.score_unpaced(rows, endpoints, paced.PAIRS, [slot], one_request_count, arm)


def replay(folder, plan):
    from sibling_compiler_affinity_evidence import verify_wave
    from sibling_compiler_slice_evidence import verify as verify_tools

    images = paced.check_inputs(folder, plan)
    boot, worker = paced.check_boot(folder, plan)
    paced.scheduler_identity(worker, "hrtick-250us")
    inventory, boots = affinity.check_cohorts(folder, plan, images)
    require(boots["A"] == boot and boots["A"] != boots["B"], "compiler runtime workload belongs to another guest boot")
    tools = verify_tools(folder, plan, inventory, boots)
    require(tools["runtime_ns"] == {arm: effective_ns(arm, plan["compiler_runtime"]) for arm in affinity.ENGINES},
            "actual Go and compile thread runtime differs from the experiment")
    sibling_tmpfs.verify_archived(folder, plan, inventory)
    scratch, mounts = sibling_tmpfs.read_fields((folder / "go-scratch-boot.txt").read_text())
    require(scratch["boot"] == boot and mounts["/"]["source"] == "/dev/vdb" and
            not mounts["/"]["device"].startswith("7:"), "compiler runtime changed the ordinary cache device")
    check_residents(inventory, read(folder, "compiler-runtime-residents-after.json"))

    saved = read(folder, "windows.json")
    orders = ["AB", "BA"] * (affinity.ROUNDS // 2)
    random.Random(plan["seed"]).shuffle(orders)
    seen, windows = set(), []
    last_finish = dict.fromkeys(affinity.ENGINES, 0)
    for block, order in enumerate(orders):
        wave = {"block": block, "order": order}
        for mode in ("one", "all"):
            key = f"grouped-{block}-{mode}"
            seen.add(key)
            require(saved[key].keys() == {"order", *affinity.ENGINES} and saved[key]["order"] == order,
                    "compiler runtime engine order differs")
            for arm in order:
                tag = f"{key}-{arm}"
                rows = paced.read_wire(folder, tag)
                jobs = inventory[arm]["jobs"]
                require(all(row["receipt"]["window"]["scheduled_unix_ns"] > last_finish[arm] for row in rows),
                        "compiler runtime waves overlap or are reordered")
                last_finish[arm] = max(row["receipt"]["window"]["finished_unix_ns"] for row in rows)
                http = score_http(rows, jobs, arm, block, tag, plan["requests_per_client"] if mode == "one" else None)
                if mode == "one":
                    require(http == saved[key][arm], f"saved unpaced score differs for {tag}")
                    continue
                build_rows = read(folder, f"{tag}-go.json")
                effective = check_builds(build_rows, jobs, arm, plan["compiler_runtime"], tag, block)
                build = paced.score_builds(build_rows, jobs, block, plan["build_nice"], http["scheduled_unix_ns"],
                                           expected_boot=boots[arm])
                live = {k: http[k] for k in paced.LIVE_SCORE_FIELDS}
                require({**live, "build": build} == saved[key][arm], f"saved paced compiler runtime score differs for {tag}")
                wave[arm] = {**{k: http[k] for k in affinity.METRICS if k in http},
                             **paced.build_overlap(rows, build_rows, http), "build": build, "build_makespan_s": build["makespan_s"],
                             "offered_requests": http["offered_requests"], "requests": http["requests"],
                             "per_client_requests": http["per_client_requests"], "warm_connections": len(rows),
                             "scheduled_unix_ns": http["scheduled_unix_ns"], "timer_slack_ns": http["timer_slack_ns"],
                             "effective_compiler_runtime_ns": effective,
                             "enclosing_cpu_counters": verify_wave(folder, block, arm, jobs, boots[arm])}
            if mode == "all":
                require(wave["A"]["build"]["products"] == wave["B"]["build"]["products"],
                        "compiler runtime engines built different outputs")
        windows.append(wave)
    require(seen == saved.keys(), "unplanned compiler runtime waves")
    return {"archive": folder.name, "boot": boot, "peer_boot": boots["B"], "worker": worker, "images": images,
            "tool_identity": tools["executables"], "windows": windows}


def comparisons(windows):
    return {
        "within_mode": {mode: affinity.outcomes([(w["B"], w["A"]) for w in windows[mode]], ("orbstack", "micropod"))
                        for mode in MODES},
        "within_engine": {engine: affinity.outcomes([(a[arm], b[arm]) for a, b in zip(windows["inherit"], windows["long"], strict=True)],
                                                    MODES) for arm, engine in affinity.ENGINES.items()},
    }


def summarize(verified):
    pooled, by_seed = {mode: [] for mode in MODES}, []
    for seed, order in SEED_ORDER.items():
        runs = {mode: verified[seed, mode] for mode in MODES}
        windows = {mode: run["windows"] for mode, run in runs.items()}
        require(windows[order[0]][0]["A"]["scheduled_unix_ns"] < windows[order[1]][0]["A"]["scheduled_unix_ns"],
                "unexpected compiler runtime treatment order")
        require(all(a["order"] == b["order"] and a["A"]["build"]["products"] == b["A"]["build"]["products"]
                    for a, b in zip(windows["inherit"], windows["long"], strict=True)),
                "compiler runtime changed matched engine order or build outputs")
        for mode in MODES:
            pooled[mode].extend(windows[mode])
        candidate = windows["long"]
        wins_medians = all(median(w["A"][k] for w in candidate) < median(w["B"][k] for w in candidate) for k in affinity.WIN_METRICS)
        by_seed.append({"seed": seed, "treatment_order": list(order), "micropod_lower_both_long_medians": wins_medians,
                        "boots": {mode: {k: run[k] for k in ("archive", "boot")} for mode, run in runs.items()},
                        "windows": windows, **comparisons(windows)})
    arms = [w[arm] for windows in pooled.values() for w in windows for arm in affinity.ENGINES]
    slack_ns = {}
    for arm, engine in affinity.ENGINES.items():
        slack = {ns for windows in pooled.values() for wave in windows for ns in wave[arm]["timer_slack_ns"]}
        require(len(slack) == 1, f"issuing-thread timer slack changed on {engine}")
        slack_ns[engine] = slack.pop()
    return {"by_seed": by_seed, "boot_pairs": len(by_seed), "engine_windows": len(arms), "windows_per_boot": affinity.ROUNDS,
            "micropod_lower_both_long_medians_in_each_seed": all(row["micropod_lower_both_long_medians"] for row in by_seed),
            "totals": {**{k: sum(row[k] for row in arms) for k in
                          ("offered_requests", "requests", "warm_connections", "completed_after_first_build")},
                       **{k: sum(row["build"][k] for row in arms) for k in ("jobs", "revisions", "test_passes")}},
            "minimum_first_build_end_margin_ns": min(row["first_build_end_margin_ns"] for row in arms),
            "timer_slack_ns": slack_ns, **comparisons(pooled)}


def compare(folders):
    paths = [folder.resolve() for folder in folders]
    require(len(paths) == len(set(paths)) == 4, "compiler runtime requires four distinct archives")
    product = read(Path(__file__).resolve().parent, signed.PRODUCT_RECEIPT)
    indexed, scopes = {}, set()
    reference = None
    for folder in paths:
        plan = read(folder, "plan.json")
        key = check_plan(folder, plan)
        require(key not in indexed and plan["scope"] not in scopes, "duplicate compiler runtime seed, mode or scope")
        indexed[key] = folder, plan
        scopes.add(plan["scope"])
        fixed = ({k: v for k, v in plan.items() if k not in ("scope", "seed", "compiler_runtime")},
                 signed.signed_settings(folder, plan, product))
        reference = fixed if reference is None else reference
        require(fixed == reference, "unmatched compiler runtime signed worker or workload")
    verified = {k: replay(folder, plan) for k, (folder, plan) in indexed.items()}
    runs = list(verified.values())
    require(len({run["boot"] for run in runs}) == 4 and len({run["peer_boot"] for run in runs}) == 1,
            "duplicate Micropod boot or changed OrbStack boot")
    first = runs[0]
    require(all(all(run[k] == first[k] for k in ("worker", "images", "tool_identity")) for run in runs),
            "unmatched compiler runtime worker readback, images or tool identities")
    return {"modes": list(MODES), "worker": first["worker"], "peer_boot": first["peer_boot"], "kernel": reference[0]["pages"],
            "tool_identity": first["tool_identity"], "ordinary_task_runtime_ns": ORDINARY_SLICE_NS, "home_placements": signed.PLACEMENT,
            "compiler_runtime_ns": {mode: {arm: effective_ns(arm, mode) for arm in affinity.ENGINES} for mode in MODES},
            "builder_container_cpu_mask": affinity.POOL, "builder_container_cpu_max": "100000 100000",
            "offered_rps": affinity.RATE, **summarize(verified)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folders", nargs=4, type=Path)
    print(json.dumps(compare(parser.parse_args().folders), indent=2))
