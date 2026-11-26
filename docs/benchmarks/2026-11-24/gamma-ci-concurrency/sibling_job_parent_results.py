"""Replay the matched, native-only CI CPU-parent diagnostic."""

import argparse
import json
import re
from collections import Counter, defaultdict
from hashlib import sha256
from pathlib import Path
from statistics import median
from unittest.mock import patch

import sibling_build
import sibling_job_parent_cri
import sibling_paced_results as paced
import sibling_slice_350_results as signed
import sibling_tmpfs
import sibling_topology
from qualify import require, terminal
from sibling_results import check_placement_inventory, container_startup, create_values, docker_time_ns, read


MODES = ("flat", "job")
SEED_ORDER = {
    "initial": {250221: MODES, 250223: MODES[::-1]},
    "holdout": {250227: MODES[::-1], 250229: MODES},
}
LAYOUT = "grouped"
ENGINES = {"A": "micropod", "B": "orbstack"}
PRODUCT = "sibling-job-parent-product.json"
PRODUCT_SOURCES = {"guest/runner/docker_engine_linux.go", "guest/runner/docker_engine_linux_test.go",
                   "guest/runner/docker_job_parent_linux.go"}
PARENT_LABEL = "io.micropod.bench.ci.job-cgroup"
LABEL_VALUE = PARENT_LABEL + "=1"
WORKER_PARENT = "/k8s.io"
ROUNDS = signed.WORKLOAD["rounds"]
RATE = signed.WORKLOAD["offered_rps"]
OFFERED = paced.offered_slots(RATE, paced.OFFER_NS)
WIN_METRICS = ("p95_us", "build_makespan_s")
METRICS = (*WIN_METRICS, "p99_us", "service_p95_us", "service_p99_us", "slowest_build_s",
           "dispatch_lateness_p95_us", "dispatch_lateness_p99_us", "starts_after_next_due_fraction",
           "completed_after_window_fraction", "drain_after_window_ns", "first_build_end_margin_ns")


def check_plan(folder, plan, orders):
    seed, mode = plan.get("seed"), plan.get("job_parent")
    pages = plan["pages"]
    require(type(seed) is int and seed in orders and mode in MODES, "unplanned CPU-parent seed or treatment")
    require(read(folder, "status.json") == {"complete": True}, "CPU-parent trial did not complete")
    require(all(plan.get(key) == value for key, value in signed.WORKLOAD.items()) and
            plan["worker_next_buddy"] is plan["cpu_groups"] is True and type(plan["build_nice"]) is int and
            plan["baseline_files"] == 24 and "guest_fair" not in plan and
            plan.get("slice_target", "all") == "all" and pages["kernel_page_kib"] == 16 and pages["kernel_ipvlan"] is True and
            not any(plan.get(key) is not None for key in
                    ("fair_slice_us", "build_slice_us", "build_policy", "builder_shares", "compiler_affinity",
                     "compiler_runtime", "ext4_cache_profile", "mthp_64k")) and
            not any(pages.get(key) for key in ("kernel_bounded_buddy", "kernel_hz")) and
            not (folder / "ext4-cache-plan.json").exists(), "CPU-parent trial requires the ordinary signed 250 µs workload")
    return seed, mode


def check_product():
    product = read(Path(__file__).resolve().parent, PRODUCT)
    candidate, previous = (Path(product[key]) for key in ("current_product", "previous_product"))
    packaged, baseline = (read(path.parent, path.name) for path in (candidate, previous))
    new_guest, old_guest = product["new_guest_sha256"], product["old_guest_sha256"]
    expected = {"worker_executable_sha256": product["host_sha256"], "guest_start_sha256": product["bootstrap_sha256"],
                "base_revision": product["base_revision"], "entitlements": product["entitlements"]}
    require(all(row[key] == value for row in (packaged, baseline) for key, value in expected.items()) and
            packaged["guest_runner_sha256"] == new_guest and baseline["guest_runner_sha256"] == old_guest and new_guest != old_guest and
            packaged["patch_sha256"] == product["patch_sha256"] and product["baseline_files"] == 24,
            "CPU-parent repack changed the host, bootstrap or immutable baseline")
    old_sources, new_sources = baseline["compiled_sources"], packaged["compiled_sources"]
    require({name for name in old_sources.keys() | new_sources.keys() if old_sources.get(name) != new_sources.get(name)} ==
            set(product["changed_packaged_inputs"]) == PRODUCT_SOURCES and
            {name: new_sources[name] for name in PRODUCT_SOURCES} == product["sha256_by_changed_input"],
            "CPU-parent repack changed additional packaged sources")
    tools = candidate.parent / "micropod-oci-tools" / "runner"
    require(terminal.digest(Path(packaged["worker_executable"])) == product["host_sha256"] and
            terminal.digest(tools / "bin" / "job") == product["new_guest_sha256"] and
            terminal.digest(tools / "start.sh") == product["bootstrap_sha256"] and
            terminal.digest(candidate.with_name("worker.patch")) == product["patch_sha256"] and
            all(terminal.digest(candidate.parent / "src" / name) == new_sources[name] for name in PRODUCT_SOURCES),
            "CPU-parent packaged binaries, patch or changed source bytes differ")
    return {**product, "new_bootstrap_sha256": product["bootstrap_sha256"]}, packaged


def placement_inputs(inventory, plan):
    """Check actual admission and expose the common CLI labels to the existing scorer."""
    view = {}
    for arm in ENGINES:
        cohort = inventory[arm]
        jobs = []
        treated = arm == "A" and plan["job_parent"] == "job"
        for job in cohort["jobs"]:
            argv, inspect = job["create_argv"], job["docker_inspect"]
            labels, host = inspect["Config"]["Labels"], inspect["HostConfig"]
            supplied = [label for label in create_values(argv, "--label") if label.partition("=")[0] == PARENT_LABEL]
            require(supplied == ([LABEL_VALUE] if treated else []) and
                    ((PARENT_LABEL in labels) is treated) and (not treated or labels[PARENT_LABEL] == "1") and
                    not (host.get("CgroupParent") or host.get("CpuShares")) and
                    not any(create_values(argv, flag) for flag in ("--cgroup-parent", "--cpu-shares", "--label-file")),
                    f"wrong CPU-parent admission or override for {job['name']}")
            if treated:
                index, = [i for i, arg in enumerate(argv) if arg == f"--label={LABEL_VALUE}" or
                          (arg == "--label" and argv[i + 1] == LABEL_VALUE)]
                count = 2 if argv[index] == "--label" else 1
                argv = argv[:index] + argv[index + count:]
            jobs.append({**job, "create_argv": argv})
        view[arm] = {**cohort, "jobs": jobs}
    return view


def placement_view(inventory, plan, layout):
    return check_placement_inventory(placement_inputs(inventory, plan), plan, layout)


def expected_parent_paths(cohort, mode):
    paths = defaultdict(list)
    for slot, (dependency, client) in enumerate(zip(cohort["jobs"][:paced.PAIRS], cohort["jobs"][paced.PAIRS:], strict=True)):
        network = sibling_topology.slot_network(cohort["network"], "per-job", slot)
        network_id = cohort["attached_networks"][network]["Id"]
        group = f"job-{slot:02d}"
        require(re.fullmatch(r"[0-9a-f]{64}", network_id) and dependency["cpu_group"] == client["cpu_group"] == group and
                all(job["docker_inspect"]["NetworkSettings"]["Networks"][network]["NetworkID"] == network_id
                    for job in (dependency, client)), f"CPU-parent network identity differs for {group}")
        digest = sha256(network_id.encode("ascii") + b"\0" + group.encode("utf-8")).hexdigest()
        parent = f"{WORKER_PARENT}/micropod-job-{digest}" if mode == "job" else WORKER_PARENT
        paths[parent].extend((dependency["id"], client["id"]))
    require(len(paths) == (paced.PAIRS if mode == "job" else 1), "CPU-parent digest or group count differs")
    return {parent: set(ids) for parent, ids in paths.items()}


def check_parent_paths(cohort, mode, native_paths):
    expected = expected_parent_paths(cohort, mode)
    observed = defaultdict(set)
    require(len(set(native_paths.values())) == len(native_paths) == 2 * paced.PAIRS,
            "wrong number of distinct native CPU leaves")
    for container, leaf in native_paths.items():
        parent, separator, runtime_id = leaf.rpartition("/")
        require(separator and re.fullmatch(r"[0-9a-f]{64}", runtime_id), "invalid native runtime cgroup identity")
        observed[parent].add(container)
    require(observed == expected, "native CPU parent differs from its pair's named network and group")
    return dict(sorted((parent, len(ids)) for parent, ids in observed.items()))


def check_ancestor_limits(tree, parents):
    root = tree["groups"]["/"]["files"]
    runtime = tree["groups"][WORKER_PARENT]["files"]
    expected = {"cgroup.type": "domain", "cpuset.cpus.effective": "0-3", "cpu.weight": "100", "pids.max": "max"}
    require(all(root[key] == value for key, value in expected.items()) and root["cpu.max"] == "400000 100000" and
            root["memory.max"] == str(4 << 30), "native worker root CPU or memory allocation changed")
    delegated = set(runtime["cgroup.subtree_control"].split())
    require({"cpu", "cpuset", "memory", "pids"} <= delegated, "native runtime root is missing delegated controllers")
    job_paths = parents.keys() - {WORKER_PARENT}
    observed = {name for name in tree["nodes"][WORKER_PARENT]["children"] if name.startswith("micropod-job-")}
    require(observed == {path.rsplit("/", 1)[1] for path in job_paths}, "unexpected private job parent below the runtime root")
    for path in {WORKER_PARENT} | job_paths:
        files = tree["groups"][path]["files"]
        require(set(files["cgroup.subtree_control"].split()) == delegated and
                set(files["cgroup.events"].splitlines()) == {"populated 1", "frozen 0"} and
                files["cpu.max"] == "max 100000" and files["memory.max"] == "max" and
                all(files[key] == value for key, value in expected.items()),
                f"native CPU-parent controller, weight or bandwidth changed at {path}")
    return {"worker_root": {k: root[k] for k in ("cpu.max", "memory.max", "cpuset.cpus.effective")},
            "parent_cpu_max": runtime["cpu.max"], "parent_weight": int(runtime["cpu.weight"]),
            "parent_subtree_controllers": sorted(delegated)}


def check_admission(folder, inventory):
    def read_lines(name):
        return [json.loads(line) for line in (folder / name).read_text().splitlines()]

    host, peer = read_lines("admission.jsonl"), read_lines("orb-inventory.jsonl")
    peer_ids = {job["id"] for job in inventory["B"]["jobs"]}
    require(len(host) == len(peer) > 1 and all(not row["blockers"] for row in host),
            "host admission is incomplete or reports a blocker")
    require(len(peer_ids) == 2 * paced.PAIRS and any(set(row["running"]) == peer_ids for row in peer) and
            all(len(row["running"]) == len(set(row["running"])) and set(row["running"]) <= peer_ids for row in peer),
            "peer admission is incomplete or reports an unowned container")
    clock = [(docker_time_ns(h["utc"]), docker_time_ns(p["time"])) for h, p in zip(host, peer, strict=True)]
    require(all(0 < first <= last for first, last in clock) and
            all(end < start for (_, end), (start, _) in zip(clock, clock[1:])), "admission observation times are inconsistent")
    return {"first_utc": host[0]["utc"], "last_utc": peer[-1]["time"], "samples": len(host),
            "full_peer_cohort_samples": sum(set(row["running"]) == peer_ids for row in peer)}


def check_waves(folder, run, phase_limits):
    rows = run["rows"][LAYOUT]
    require(len(rows) == ROUNDS and Counter(row["order"] for row in rows) == {"AB": 2, "BA": 2},
            "CPU-parent trial engine order is incomplete or unbalanced")
    last_job_exit = {arm: phase_limits[arm][0] for arm in ENGINES}
    for round_no, window in enumerate(rows):
        for arm in ENGINES:
            wave = window[arm]
            build = wave["build"]
            require(wave["offered_requests"] == wave["requests"] == OFFERED and
                    wave["per_client_requests"] == [OFFERED // paced.PAIRS] * paced.PAIRS and
                    (build["jobs"], build["revisions"], build["test_passes"], build["http_covered_ns"]) ==
                    (paced.BUILDERS, 2 * paced.BUILDERS, 16 * paced.BUILDERS, paced.OFFER_NS),
                    f"CPU-parent trial did not complete the required work in round {round_no} engine {arm}")
            require(wave["completed_after_first_build"] == 0 and wave["first_build_end_margin_ns"] >= 0,
                    f"CPU-parent trial lost build overlap through HTTP drain in round {round_no} engine {arm}")
            single, = paced.read_wire(folder, f"{LAYOUT}-{round_no}-one-{arm}")
            solo = single["receipt"]["window"]
            raw_builds = read(folder, f"{LAYOUT}-{round_no}-all-{arm}-go.json")
            require(last_job_exit[arm] < solo["scheduled_unix_ns"] <= solo["started_unix_ns"] < solo["finished_unix_ns"] <
                    min(row["started_unix_ns"] for row in raw_builds),
                    f"CPU-parent pre-work checks, single-client controls, or build waves are out of order on engine {arm}")
            last_job_exit[arm] = max(int(row["stdout"].strip().splitlines()[-1].split()[1]) for row in raw_builds)
            require(last_job_exit[arm] < phase_limits[arm][1],
                    f"CPU-parent post-work snapshot arrived before the last build ended on engine {arm}")
    return rows


def outcomes(first, second, labels):
    pairs = list(zip(first, second, strict=True))
    statistics = {key: paced.paired_summary([a[key] for a, _ in pairs], [b[key] for _, b in pairs], key, labels)
                  for key in METRICS}
    left, right = labels
    left_wins = [i for i, (a, b) in enumerate(pairs) if all(a[key] < b[key] for key in WIN_METRICS)]
    right_wins = [i for i, (a, b) in enumerate(pairs) if all(b[key] < a[key] for key in WIN_METRICS)]
    return {"metrics": statistics, "joint_wins": {left: len(left_wins), right: len(right_wins),
                                                   "split_or_tied": len(pairs) - len(left_wins) - len(right_wins)},
            "joint_win_positions": {left: left_wins, right: right_wins}}


def comparisons(windows):
    peer_relative = {}
    for metric in WIN_METRICS:
        pairs = zip(windows["flat"], windows["job"], strict=True)
        peer_relative[metric] = median((job["A"][metric] / job["B"][metric]) / (flat["A"][metric] / flat["B"][metric])
                                       for flat, job in pairs)
    return {
        "within_mode": {mode: outcomes([w["B"] for w in rows], [w["A"] for w in rows], ("orbstack", "micropod"))
                        for mode, rows in windows.items()},
        "within_engine": {engine: outcomes([w[arm] for w in windows["flat"]], [w[arm] for w in windows["job"]], MODES)
                          for arm, engine in ENGINES.items()},
        "median_paired_native_to_peer_ratio_change": peer_relative,
    }


def study_results(verified, orders):
    by_seed, pooled = [], {mode: [] for mode in MODES}
    for seed, expected_order in orders.items():
        boots = {mode: verified[seed, mode] for mode in MODES}
        windows = {mode: boot["rows"] for mode, boot in boots.items()}
        first, last = (boots[mode]["admission"] for mode in expected_order)
        require(docker_time_ns(first["last_utc"]) < docker_time_ns(last["first_utc"]),
                "CPU-parent trial reversed the preselected boot order or overlapped scopes")
        for flat, job in zip(windows["flat"], windows["job"], strict=True):
            require(flat["order"] == job["order"] and len({tuple(row[arm]["build"]["products"])
                                                         for row in (flat, job) for arm in ENGINES}) == 1,
                    "CPU-parent trial changed engine order or built artifacts within its matched seed")
        result = comparisons(windows)
        for mode, rows in windows.items():
            pooled[mode].extend(rows)
        direct = result["within_mode"]["job"]["metrics"]
        treatment = result["within_engine"]["micropod"]["metrics"]
        by_seed.append({
            "seed": seed, "treatment_order": list(expected_order), "engine_order": [row["order"] for row in windows["flat"]],
            "boot_receipts": {mode: boot["receipt"] for mode, boot in boots.items()},
            "job_beats_peer_on_both_medians": all(direct[key]["micropod"] < direct[key]["orbstack"] for key in WIN_METRICS),
            "job_beats_flat_on_both_medians": all(treatment[key]["job"] < treatment[key]["flat"] for key in WIN_METRICS),
            **result,
        })
    studies = [wave[arm] for rows in pooled.values() for wave in rows for arm in ENGINES]
    return {
        "matched_boot_pairs": len(by_seed), "native_boots": len(verified), "rounds_per_boot": ROUNDS,
        "paired_engine_windows": sum(map(len, pooled.values())), "engine_windows": len(studies),
        "offered_rps": RATE, "offered_requests_per_engine_window": OFFERED,
        "offered_requests": sum(wave["offered_requests"] for wave in studies),
        "completed_requests": sum(wave["requests"] for wave in studies),
        "build_jobs": sum(wave["build"]["jobs"] for wave in studies),
        "build_revisions": sum(wave["build"]["revisions"] for wave in studies),
        "test_passes": sum(wave["build"]["test_passes"] for wave in studies),
        "minimum_first_build_end_margin_ns": min(wave["first_build_end_margin_ns"] for wave in studies),
        "job_beats_peer_on_both_medians_each_seed": all(row["job_beats_peer_on_both_medians"] for row in by_seed),
        "job_beats_flat_on_both_medians_each_seed": all(row["job_beats_flat_on_both_medians"] for row in by_seed),
        "by_seed": by_seed, **comparisons(pooled),
    }


def wave_receipts(rows):
    fields = (*METRICS, "offered_requests", "requests", "completed_after_first_build", "max_clock_calibration_ns")
    return [{"round": index, "engine_order": wave["order"],
             **{engine: {**{key: wave[arm][key] for key in fields},
                         **{key: wave[arm]["build"][key] for key in ("jobs", "revisions", "test_passes")}}
                for arm, engine in ENGINES.items()}}
            for index, wave in enumerate(rows)]


def verified_run(folder, plan):
    from sibling_job_parent_evidence import verify

    inventory = read(folder, f"{LAYOUT}-inventory.json")
    require(set(inventory) == set(ENGINES), "missing CPU-parent cohort")
    placement_inventory = placement_inputs(inventory, plan)
    placements = check_placement_inventory(placement_inventory, plan, LAYOUT)
    require(placements == signed.PLACEMENT[LAYOUT], "CPU-parent cohort changed its fixed per-pair CPU map")
    owner = Path(plan["scope"]).name
    launch_templates = {arm: [[arg.replace(owner, "{scope}") for arg in job["create_argv"]]
                              for job in placement_inventory[arm]["jobs"]] for arm in ENGINES}
    prime = read(folder, f"{LAYOUT}-prime.json")
    boots = {arm: sibling_build.check_revision(prime[arm], "sib-prime", inventory[arm]["jobs"][paced.PAIRS]["name"])["boot"]
             for arm in ENGINES}
    require(all(re.fullmatch(paced.BOOT_ID, boot) for boot in boots.values()) and boots["A"] != boots["B"],
            "CPU-parent cohort is missing separate native and peer guest boots")
    admission = check_admission(folder, inventory)
    hierarchy = verify(folder, plan, inventory, boots)
    paths = check_parent_paths(inventory["A"], plan["job_parent"], hierarchy["native_paths"])
    cri = sibling_job_parent_cri.verify(folder, hierarchy["native_paths"])
    before, after = [read(folder, f"job-parent-{phase}.json")["arms"] for phase in ("before", "after")]
    ancestors = [check_ancestor_limits(snapshot["A"]["worker"], paths) for snapshot in (before, after)]
    require(ancestors[0] == ancestors[1], "native ancestor limits changed during the CPU-parent trial")
    probes = read(folder, "job-parent-probes.json")
    phase_limits = {}
    for arm in ENGINES:
        before_capture = max(container["inside"]["guest_unix_ns"] for container in before[arm]["containers"])
        before_http = max(json.loads(row["stdout"])["window"]["finished_unix_ns"] for row in probes[arm] if row["role"] == "http")
        after_capture = min(container["inside"]["guest_unix_ns"] for container in after[arm]["containers"])
        phase_limits[arm] = max(before_capture, before_http), after_capture
    earliest_native_before = min(row["inside"]["guest_unix_ns"] for row in before["A"]["containers"])
    latest_native_after = max(row["inside"]["guest_unix_ns"] for row in after["A"]["containers"])
    require(cri["boot"] == boots["A"] and cri["verified_starts"] == cri["verified_sandbox_removals"] == 2 * paced.PAIRS and
            all(docker_time_ns(item["docker_started"]) < earliest_native_before < latest_native_after <
                docker_time_ns(item["stop_request"]) for item in cri["containers"]),
            "native CRI lifecycle does not bracket the measured cohort")
    scratch, mounts = sibling_tmpfs.read_fields((folder / "go-scratch-boot.txt").read_text())
    require(scratch["boot"] == boots["A"] and mounts["/"]["source"] == "/dev/vdb" and
            not mounts["/"]["device"].startswith("7:"), "CPU-parent trial did not use the ordinary worker cache disk")
    with patch.object(paced, "check_placement_inventory", placement_view):
        run = paced.replay(folder)
    require(run["plan"] == plan and run["placements"] == signed.PLACEMENT and
            (run["boot"], run["peer_boot"]) == (boots["A"], boots["B"]), "CPU-parent plan, placement or boot changed during replay")
    paced.scheduler_identity(run["worker"], plan["worker_scheduler"])
    rows = check_waves(folder, run, phase_limits)
    ids = [job["id"] for cohort in inventory.values() for job in cohort["jobs"]]
    require(len(set(ids)) == len(ids) == 4 * paced.PAIRS, "CPU-parent trial reused a container across engines")
    retired = read(folder, "job-parent-retired.json")["worker"]["paths"]
    return {"run": run, "rows": rows, "admission": admission, "container_ids": set(ids),
            "compiler_executables": hierarchy["compiler_executables"], "launch_templates": launch_templates,
            "receipt": {"archive": folder.name, "native_boot": boots["A"], "peer_boot": boots["B"],
                        "native_parents": paths, "native_ancestor_limits": ancestors[0],
                        "native_cri": {k: v for k, v in cri.items() if k != "containers"},
                        "retired_native_paths": len(retired), "admission": admission, "windows": wave_receipts(rows),
                        "startup": {engine: container_startup(inventory[arm]["jobs"]) for arm, engine in ENGINES.items()}}}


def protocol_inputs(folder, plan):
    fields = {name: value for name, value in plan.items() if name not in ("scope", "seed", "job_parent")}
    receipt = folder / "midwindow-probes.json"
    if receipt.is_file():
        probes = read(folder, receipt.name)
        require(terminal.digest(folder / "sibling_job_parent_host.py") == probes["driver_sha256"] and
                all(re.fullmatch(r"[0-9a-f]{64}", digest) for digest in
                    (probes["profiler_sha256"], probes["guest"]["binary_sha256"])),
                "CPU-parent mid-window measurement inputs differ")
        fields["midwindow_probes"] = probes
    return fields


def validate_archive(folder, plan, orders, product, packaged):
    key = check_plan(folder, plan, orders)
    settings = signed.signed_settings(folder, plan, product)
    require(settings[0] == packaged, "CPU-parent trial archive differs from its immutable packaged product")
    return key, settings, protocol_inputs(folder, plan)


def fingerprint(value):
    data = json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    return sha256(data).hexdigest()


def replay(folder, *, batch="initial"):
    """Verify one boot without making a between-treatment comparison."""
    require(batch in SEED_ORDER, "unknown CPU-parent trial batch")
    folder = Path(folder).resolve()
    plan = read(folder, "plan.json")
    product, packaged = check_product()
    _, settings, protocol = validate_archive(folder, plan, SEED_ORDER[batch], product, packaged)
    run = verified_run(folder, plan)
    return {"batch": batch, "seed": plan["seed"], "mode": plan["job_parent"], **run["receipt"],
            "protocol_sha256": fingerprint([protocol, run["launch_templates"]]),
            "signed_settings_sha256": fingerprint(settings), "signed_product": product["current_product"],
            "worker": run["run"]["worker"], "images": run["run"]["images"], "placements": run["run"]["placements"],
            "compiler_executables": run["compiler_executables"],
            "within_boot": outcomes([w["B"] for w in run["rows"]], [w["A"] for w in run["rows"]], ("orbstack", "micropod"))}


def compare(folders, *, batch="initial"):
    require(batch in SEED_ORDER, "unknown CPU-parent trial batch")
    orders = SEED_ORDER[batch]
    paths = [Path(folder).resolve() for folder in folders]
    require(len(paths) == len(set(paths)) == len(orders) * len(MODES), "CPU-parent trial needs four distinct archive directories")
    product, packaged = check_product()
    source, scopes = {}, set()
    common_protocol = common_settings = None
    for folder in paths:
        plan = read(folder, "plan.json")
        key, settings, protocol = validate_archive(folder, plan, orders, product, packaged)
        scope = Path(plan["scope"]).resolve()
        require(key not in source and scope not in scopes, "duplicate CPU-parent seed, treatment or scope")
        source[key] = folder, plan
        scopes.add(scope)
        if common_protocol is None:
            common_protocol, common_settings = protocol, settings
        require(protocol == common_protocol and settings == common_settings, "unmatched CPU-parent trial settings or signed launch")

    verified = {key: verified_run(folder, plan) for key, (folder, plan) in source.items()}
    runs = [item["run"] for item in verified.values()]
    first = runs[0]
    require(len({run["boot"] for run in runs}) == len(runs) and len({run["peer_boot"] for run in runs}) == 1 and
            all((run["worker"], run["images"]) == (first["worker"], first["images"]) for run in runs),
            "CPU-parent trial changed peer boot, worker, scheduler or image, or reused a native boot")
    require(len(set().union(*(r["container_ids"] for r in verified.values()))) == len(runs) * 4 * paced.PAIRS,
            "CPU-parent trial reused a container across scopes")
    reference = next(iter(verified.values()))
    compiler, launch = reference["compiler_executables"], reference["launch_templates"]
    require(all(r["compiler_executables"] == compiler and r["launch_templates"] == launch for r in verified.values()),
            "CPU-parent trial changed the observed Go toolchain or other Docker launch arguments")
    admission = sorted((docker_time_ns(r["admission"]["first_utc"]), docker_time_ns(r["admission"]["last_utc"]))
                       for r in verified.values())
    require(all(end < start for (_, end), (start, _) in zip(admission, admission[1:])), "CPU-parent trial scopes overlapped")
    timer_slacks = {engine: {value for r in verified.values() for wave in r["rows"] for value in wave[arm]["timer_slack_ns"]}
                    for arm, engine in ENGINES.items()}
    require(all(len(values) == 1 for values in timer_slacks.values()), "CPU-parent trial changed issuing-thread timer slack")
    return {
        "batch": batch, "kernel": first["plan"]["pages"], "worker": first["worker"], "placements": signed.PLACEMENT,
        "protocol_sha256": fingerprint([common_protocol, launch]), "signed_product": product["current_product"],
        "signed_settings_sha256": fingerprint(common_settings), "images": first["images"],
        "compiler_executables": compiler,
        "issuing_timer_slack_ns": {engine: values.pop() for engine, values in timer_slacks.items()},
        **study_results(verified, orders),
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--batch", choices=tuple(SEED_ORDER), default="initial")
    parser.add_argument("--single", action="store_true", help="qualify one boot and report its two engine observations")
    parser.add_argument("folders", nargs="+", type=Path)
    args = parser.parse_args()
    if args.single and len(args.folders) != 1:
        parser.error("--single requires one archive directory")
    result = replay(args.folders[0], batch=args.batch) if args.single else compare(args.folders, batch=args.batch)
    print(json.dumps(result, indent=2, allow_nan=False))
