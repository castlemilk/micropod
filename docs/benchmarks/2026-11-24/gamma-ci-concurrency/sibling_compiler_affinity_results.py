"""Replay the matched compiler-only CPU affinity study."""

import argparse
import json
import random
import re
from collections import Counter
from pathlib import Path

import sibling_build
import sibling_group
import sibling_paced
import sibling_paced_results as paced
import sibling_slice_350_results as signed
import sibling_tmpfs
import sibling_topology
from qualify import LABEL, require, terminal
from sibling_results import CPU_GROUP_LABEL, check_affinity, check_cpu_delta, check_create, check_group_container, create_values, read


LEVELS = ("home", "pool")
SEED_ORDER = {250201: LEVELS, 250203: LEVELS[::-1]}
POOL = "0-3"
LAYOUT = "grouped"
RATE = 64_000
ROUNDS = 4
ENGINES = {"A": "micropod", "B": "orbstack"}
WIN_METRICS = ("p95_us", "build_makespan_s")
METRICS = (*WIN_METRICS, "p50_us", "p99_us", "service_p95_us", "service_p99_us", "dispatch_lateness_p95_us",
           "dispatch_lateness_p99_us", "starts_after_next_due", "completed_after_window",
           "drain_after_window_ns", "completed_after_first_build", "first_build_end_margin_ns")
SOURCES = {
    "sibling-compiler-affinity.py": "compiler_affinity_driver_sha256",
    sibling_build.POLICY_SOURCE: "compiler_affinity_source_sha256",
    "go-dispatch-affinity.sh": "compiler_affinity_dispatch_sha256",
}


def check_plan(folder, plan):
    from sibling_compiler_affinity import DISPATCH
    from sibling_compiler_affinity_evidence import verify_sources

    seed, level = plan.get("seed"), plan.get("compiler_affinity")
    require(type(seed) is int and seed in SEED_ORDER and level in LEVELS, "unexpected compiler affinity seed or level")
    require(all(plan.get(k) == value for k, value in signed.WORKLOAD.items()) and
            plan.get("guest_fair") in (None, "inherit") and plan.get("slice_target", "all") == "all" and
            not any(plan.get(k) is not None for k in
                    ("fair_slice_us", "build_slice_us", "build_policy", "builder_shares", "ext4_cache_profile")) and
            not (folder / "ext4-cache-plan.json").exists(), "compiler affinity requires the signed 250 µs ordinary-cache workload")
    require(all(terminal.digest(folder / name) == plan[key] for name, key in SOURCES.items()) and
            re.fullmatch(r"[a-f0-9]{64}", plan["compiler_affinity_probe_sha256"]) and
            (folder / sibling_build.POLICY_SOURCE).read_bytes() == Path(__file__).with_name(sibling_build.POLICY_SOURCE).read_bytes() and
            (folder / "go-dispatch-affinity.sh").read_text() == DISPATCH,
            "compiler affinity launcher or dispatcher identity differs")
    verify_sources(folder, plan)
    return seed, level


def check_container_cpu(job, builder, home):
    mask = POOL if builder else home
    limits = job["cgroup"]
    require(job["home_cpu"] == home and job["mask"] == job["docker_cpuset"] == limits["cpuset.cpus.effective"] == mask and
            limits["visible_cpus"] == (4 if builder else 1) and limits["cpu.max"] == "100000 100000" and
            limits["gomaxprocs"] == 1 and limits["memory.max"] == str((512 if builder else 128) << 20) and
            limits["pids.max"] == ("192" if builder else "64"), f"wrong CPU allowance or quota for {job['name']}")
    check_affinity(job["affinity"], home)


def check_cohorts(folder, plan, images):
    inventory, counts, primes = [read(folder, f"{LAYOUT}-{name}.json") for name in ("inventory", "cpu", "prime")]
    require(set(inventory) == set(counts) == set(primes) == set(ENGINES), "missing compiler affinity cohorts")
    owner = Path(plan["scope"]).name
    boots = {}
    for arm, cohort in inventory.items():
        prefix = f"{owner}-{arm.lower()}-{LAYOUT}"
        jobs = cohort["jobs"]
        require(cohort["network"] == prefix and cohort["placement"] == signed.PLACEMENT[LAYOUT] and
                len(jobs) == len({j["id"] for j in jobs}) == len({j["ip"] for j in jobs}) == 2 * paced.PAIRS and
                [j["id"] for j in jobs] == [row["id"] for row in counts[arm]], "invalid compiler affinity cohort")
        networks = sibling_topology.check_membership(cohort, owner, prefix, plan["network_topology"])
        for pos, (job, delta) in enumerate(zip(jobs, counts[arm], strict=True)):
            client, slot = divmod(pos, paced.PAIRS)
            builder = bool(client and slot < paced.BUILDERS)
            home, group = str(slot % 4), f"job-{slot:02d}"
            network = sibling_topology.slot_network(prefix, plan["network_topology"], slot)
            name = f"{prefix}-{'c' if client else 's'}{slot}"
            labels = {LABEL: owner, CPU_GROUP_LABEL: group}
            requested = POOL if builder else home if arm == "B" else ""
            placement = "explicit-build-cpuset" if builder else "explicit-cpuset" if arm == "B" else "native-group"
            require(job["name"] == name and job["cpu_group"] == group and job["requested_cpuset"] == requested and
                    job["placement_source"] == placement, f"wrong placement request for {name}")
            check_container_cpu(job, builder, home)
            check_create(job["create_argv"], name, network, labels, "1", requested)
            inspect = job["docker_inspect"]
            check_group_container(inspect, name, network, networks[network]["Id"], labels, 1, job["mask"])
            program = "/mpcheck/netbench" if builder else "/netbench"
            program_args = ["-listen", ":8080", "-marker", name]
            if builder:
                argv = job["create_argv"]
                expected = ["-c", home, program, *program_args]
                require(create_values(argv, "--entrypoint") == ["taskset"] and argv[-len(expected):] == expected,
                        f"wrong resident process entry for {name}")
            require(inspect["Id"] == job["id"] and inspect["Image"] == images["build" if builder else "service"][arm] and
                    inspect["NetworkSettings"]["Networks"][network]["IPAddress"] == job["ip"] and
                    job.get("go_image") == (sibling_build.IMAGE if builder else None) and
                    job["affinity"]["argv"] == [program, *program_args],
                    f"wrong executable, image or network endpoint for {name}")
            check_cpu_delta(job, delta)
            paced.check_link(job["endpoint"], plan["network_driver"], job["ip"])
        boots[arm] = sibling_build.check_revision(primes[arm], "sib-prime", jobs[paced.PAIRS]["name"])["boot"]
        require(re.fullmatch(paced.BOOT_ID, boots[arm]), "missing primed guest boot")
    return inventory, boots


def check_client_threads(rows, jobs, tag, one_request_count):
    for item in rows:
        slot = item["index"]
        require(type(slot) is int and 0 <= slot < paced.PAIRS, "invalid compiler affinity client slot")
        server, client = jobs[slot], jobs[paced.PAIRS + slot]
        dense = one_request_count is None
        pin = ["taskset", "-c", client["home_cpu"]] if slot < paced.BUILDERS else []
        expected = ["exec", client["id"], *pin, "/mpcheck/quiet-http", "-thread-probe", sibling_group.PROBE,
                    "-url", f"http://{server['ip']}:8080", "-marker", server["name"],
                    "-requests", 0 if dense else one_request_count, "-duration-ms", 1500 if dense else 0,
                    *sibling_paced.client_args(RATE if dense else None, slot),
                    "-ready-file", f"/gate/{tag}.{slot}", "-start-file", f"/gate/{tag}"]
        require(item["exec_argv"] == expected, f"wrong measured HTTP exec for {tag} slot {slot}")
        check_affinity(item["receipt"]["window"], client["home_cpu"])


def check_build_threads(rows, jobs, level, arm, tag, block):
    require(len(rows) == paced.BUILDERS, "missing compiler affinity dispatcher rows")
    slices = set()
    for slot, row in enumerate(rows):
        job = jobs[paced.PAIRS + slot]
        expected = job["home_cpu"] if level == "home" else POOL
        argv = ["exec", job["id"], "nice", "-n", 0, "taskset", "-c", expected, "/bin/sh",
                "/mpcheck/go-dispatch-affinity.sh", tag, f"sibling-{block}-{slot}", slot, 0]
        require(row["exec_argv"] == argv, f"wrong compiler exec for engine {arm}, slot {slot}")
        proof = row["compiler_affinity"]
        dispatcher, child = proof["dispatcher"], proof["child"]
        require(type(dispatcher["tid"]) is type(child["tid"]) is int and
                dispatcher["tid"] == proof["child_parent_pid"] > 0 and child["tid"] > 0 and child["tid"] != dispatcher["tid"] and
                dispatcher["cpus_allowed_list"] == child["cpus_allowed_list"] == expected and
                all(task["policy"] == task["nice"] == task["priority"] == 0 for task in (dispatcher, child)) and
                type(dispatcher["slice_ns"]) is type(child["slice_ns"]) is int and
                dispatcher["slice_ns"] == child["slice_ns"] > 0,
                f"compiler affinity differs for engine {arm}, slot {slot}")
        slices.add(dispatcher["slice_ns"])
    require(len(slices) == 1 and (arm != "A" or slices == {250_000}), f"compiler scheduler slice changed on {arm}")
    return slices.pop()


def score_http(rows, jobs, arm, block, tag, one_request_count):
    # Check the real home mask against every HTTP process, then replay the
    # socket and timing evidence using only its endpoint identities.
    check_client_threads(rows, jobs, tag, one_request_count)
    endpoints = [{"ip": job["ip"], "name": job["name"]} for job in jobs]
    page_bytes = 16_384 if arm == "A" else 4_096
    if one_request_count is not None:
        slot = block % paced.PAIRS
        response = rows[0]["receipt"]
        require(not response.get("pace") and response["window"]["page_bytes"] == page_bytes and
                response["url"] == f"http://{jobs[slot]['ip']}:8080/id", "wrong unpaced response")
        return paced.score_unpaced(rows, endpoints, paced.PAIRS, [slot], one_request_count, arm)
    return paced.score_wave(rows, endpoints, RATE, page_bytes)


def replay(folder, plan):
    from sibling_compiler_affinity_evidence import verify_tools, verify_wave

    images = paced.check_inputs(folder, plan)
    boot, worker = paced.check_boot(folder, plan)
    paced.scheduler_identity(worker, "hrtick-250us")
    inventory, boots = check_cohorts(folder, plan, images)
    require(boots["A"] == boot and boots["A"] != boots["B"], "compiler affinity guest boots differ from placement evidence")
    tools = verify_tools(folder, plan, inventory, boots)
    sibling_tmpfs.verify_archived(folder, plan, inventory)
    scratch, mounts = sibling_tmpfs.read_fields((folder / "go-scratch-boot.txt").read_text())
    require(scratch["boot"] == boot and mounts["/"]["source"] == "/dev/vdb" and
            not mounts["/"]["device"].startswith("7:"), "compiler cache was not on the ordinary worker disk")
    saved = read(folder, "windows.json")
    orders = ["AB", "BA"] * (ROUNDS // 2)
    random.Random(plan["seed"]).shuffle(orders)
    last_finish = dict.fromkeys(ENGINES, 0)
    windows = []
    seen = set()
    for block, order in enumerate(orders):
        pair = {"block": block, "order": order}
        for mode in ("one", "all"):
            key = f"{LAYOUT}-{block}-{mode}"
            seen.add(key)
            require(set(saved[key]) == {"order", *ENGINES} and saved[key]["order"] == order, "compiler affinity engine order differs")
            for arm in order:
                tag = f"{key}-{arm}"
                rows = paced.read_wire(folder, tag)
                jobs = inventory[arm]["jobs"]
                require(all(row["receipt"]["window"]["scheduled_unix_ns"] > last_finish[arm] for row in rows),
                        "compiler affinity waves overlap or are reordered")
                last_finish[arm] = max(row["receipt"]["window"]["finished_unix_ns"] for row in rows)
                http = score_http(rows, jobs, arm, block, tag, plan["requests_per_client"] if mode == "one" else None)
                if mode == "one":
                    require(http == saved[key][arm], "saved unpaced score differs")
                    continue
                build_rows = paced.read(folder, f"{tag}-go.json")
                compiler_slice_ns = check_build_threads(build_rows, jobs, plan["compiler_affinity"], arm, tag, block)
                build = paced.score_builds(build_rows, jobs, block, plan["build_nice"], http["scheduled_unix_ns"],
                                           expected_boot=boots[arm])
                live = {k: http[k] for k in paced.LIVE_SCORE_FIELDS}
                require({**live, "build": build} == saved[key][arm], "saved paced compiler affinity score differs")
                pair[arm] = {**{k: http[k] for k in METRICS if k in http}, **paced.build_overlap(rows, build_rows, http),
                             "scheduled_unix_ns": http["scheduled_unix_ns"], "offered_requests": http["offered_requests"],
                             "requests": http["requests"], "per_client_requests": http["per_client_requests"],
                             "warm_connections": len(rows), "timer_slack_ns": http["timer_slack_ns"],
                             "compiler_slice_ns": compiler_slice_ns, "build": build, "build_makespan_s": build["makespan_s"],
                             "enclosing_cpu_counters": verify_wave(folder, block, arm, jobs, boots[arm])}
            if mode == "all":
                require(pair["A"]["build"]["products"] == pair["B"]["build"]["products"], "engine build outputs differ")
        windows.append(pair)
    require(seen == saved.keys(), "unplanned compiler affinity waves")
    return {"archive": folder.name, "boot": boot, "peer_boot": boots["B"], "worker": worker, "images": images,
            "tool_identity": tools, "windows": windows}


def outcomes(pairs, names):
    first, second = names
    first_wins = [i for i, (a, b) in enumerate(pairs) if all(a[k] < b[k] for k in WIN_METRICS)]
    second_wins = [i for i, (a, b) in enumerate(pairs) if all(b[k] < a[k] for k in WIN_METRICS)]
    return {
        "metrics": {k: paced.paired_summary([a[k] for a, _ in pairs], [b[k] for _, b in pairs], k, names) for k in METRICS},
        "same_window_wins": {first: len(first_wins), second: len(second_wins),
                             "split_or_tied": len(pairs) - len(first_wins) - len(second_wins)},
        "same_window_win_positions": {first: first_wins, second: second_wins},
    }


def comparisons(windows):
    return {
        "within_level": {level: outcomes([(wave["B"], wave["A"]) for wave in windows[level]], ("orbstack", "micropod"))
                         for level in LEVELS},
        "within_engine": {engine: outcomes([(a[arm], b[arm]) for a, b in zip(windows["home"], windows["pool"], strict=True)], LEVELS)
                          for arm, engine in ENGINES.items()},
    }


def summarize(verified):
    by_seed, all_rows = [], {level: [] for level in LEVELS}
    for seed, order in SEED_ORDER.items():
        runs = {level: verified[seed, level] for level in LEVELS}
        windows = {level: run["windows"] for level, run in runs.items()}
        require(windows[order[0]][0]["A"]["scheduled_unix_ns"] < windows[order[1]][0]["A"]["scheduled_unix_ns"],
                "unexpected compiler affinity treatment order")
        for a, b in zip(windows["home"], windows["pool"], strict=True):
            require(a["order"] == b["order"] and a["A"]["build"]["products"] == b["A"]["build"]["products"],
                    "compiler affinity changed matched engine order or build outputs")
        for level in LEVELS:
            all_rows[level].extend(windows[level])
        by_seed.append({"seed": seed, "treatment_order": list(order),
                        "boots": {level: {k: run[k] for k in ("archive", "boot")} for level, run in runs.items()},
                        "windows": windows, **comparisons(windows)})
    arms = [row[arm] for waves in all_rows.values() for row in waves for arm in ENGINES]
    timer_slack, compiler_slices = {}, {}
    for arm, engine in ENGINES.items():
        slack = {ns for waves in all_rows.values() for row in waves for ns in row[arm]["timer_slack_ns"]}
        slices = {row[arm]["compiler_slice_ns"] for waves in all_rows.values() for row in waves}
        require(len(slack) == len(slices) == 1, f"compiler slice or issuing-thread timer slack changed on {engine}")
        timer_slack[engine] = slack.pop()
        compiler_slices[engine] = slices.pop()
    return {"by_seed": by_seed, "boot_pairs": len(by_seed), "windows_per_boot": ROUNDS, "engine_windows": len(arms),
            "totals": {**{k: sum(row[k] for row in arms) for k in
                          ("offered_requests", "requests", "warm_connections", "completed_after_first_build")},
                       **{k: sum(row["build"][k] for row in arms) for k in ("jobs", "revisions", "test_passes")}},
            "minimum_first_build_end_margin_ns": min(row["first_build_end_margin_ns"] for row in arms),
            "timer_slack_ns": timer_slack, "compiler_slice_ns": compiler_slices, **comparisons(all_rows)}


def compare(folders):
    paths = [folder.resolve() for folder in folders]
    require(len(paths) == len(set(paths)) == 4, "compiler affinity requires four distinct archives")
    product = read(Path(__file__).resolve().parent, signed.PRODUCT_RECEIPT)
    indexed = {}
    reference = None
    scopes = set()
    for folder in paths:
        plan = read(folder, "plan.json")
        key = check_plan(folder, plan)
        require(key not in indexed and plan["scope"] not in scopes, "duplicate compiler affinity seed, level or scope")
        indexed[key] = folder, plan
        scopes.add(plan["scope"])
        fixed = ({k: v for k, v in plan.items() if k not in ("seed", "scope", "compiler_affinity")},
                 signed.signed_settings(folder, plan, product))
        reference = fixed if reference is None else reference
        require(fixed == reference, "unmatched compiler affinity workload or signed worker settings")
    verified = {key: replay(folder, plan) for key, (folder, plan) in indexed.items()}
    runs = list(verified.values())
    require(len({run["boot"] for run in runs}) == 4 and len({run["peer_boot"] for run in runs}) == 1,
            "duplicate Micropod boot or changed OrbStack boot")
    first = runs[0]
    require(all(all(run[k] == first[k] for k in ("worker", "images", "tool_identity")) for run in runs),
            "unmatched compiler affinity worker readback, images or compiler tools")
    return {"profiles": list(LEVELS), "offered_rps": RATE, "home_placements": signed.PLACEMENT,
            "builder_container_cpu_mask": POOL, "builder_container_cpu_max": "100000 100000",
            "peer_boot": first["peer_boot"], "worker": first["worker"], "kernel": reference[0]["pages"],
            "tool_identity": first["tool_identity"],
            "archives": [path.name for path in paths], **summarize(verified)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folders", nargs=4, type=Path)
    print(json.dumps(compare(parser.parse_args().folders), indent=2))
