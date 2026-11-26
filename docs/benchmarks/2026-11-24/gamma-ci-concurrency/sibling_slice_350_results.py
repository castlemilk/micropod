"""Replay the signed worker's disposable 250/350 µs slice diagnostic."""

import argparse
import json
import plistlib
from collections import Counter
from pathlib import Path
from tempfile import TemporaryDirectory

import sibling_paced_results as paced
import sibling_sched
import sibling_slice_350 as fixture
import sibling_tmpfs
from qualify import require, terminal
from sibling_results import read


SLICES_US = (250, 350)
SEED_ORDER = {250191: SLICES_US, 250193: SLICES_US[::-1]}
WORKLOAD = {
    "worker_scheduler": "hrtick-250us", "worker_next_buddy": True, "build_scratch": "tmpfs",
    "network_driver": "ipvlan", "network_topology": "per-job", "mac_process_type": "Standard",
    "cpu_groups": True, "layouts": ["grouped"], "healthy_pairs": paced.PAIRS, "builders": paced.BUILDERS,
    "build_nice": 0, "scratch_tmpfs_kib": 128 * 1024, "offered_rps": 64_000, "dense_ms": 1500, "rounds": 4,
    "requests_per_client": 200,
}
PLACEMENT = {"grouped": {
    "groups": {f"job-{slot:02d}": str(slot % 4) for slot in range(paced.PAIRS)},
    "groups_per_cpu": {str(cpu): 8 for cpu in range(4)},
    "builders_per_cpu": {str(cpu): 2 for cpu in range(4)},
}}
PLANNED_VARIATION = {
    "scope", "seed", "guest_fair", "fair_hook_sha256", "slice_350_target_us", "slice_350_guard_sha256",
}
BOOT_ARGS = "micropod.ci_sched=hrtick-250us micropod.ci_wakeup=next-buddy"
PRODUCT_RECEIPT = "sibling-native-scratch-holdout-product.json"
BOOT_PATHS = {"MICROPOD_CI_HOME": "a", "MICROPOD_CI_OCI_TOOLS": "oci", "MICROPOD_CI_WORKSPACE": "workspace"}
STATIC_FACT_KEYS = ("release", "machine", "cmdline", "config_sha256")
STATIC_NIC_PROBES = ("-i", "-l", "-k", "-g", "-c")
WIN_METRICS = ("p95_us", "build_makespan_s")
METRICS = (*WIN_METRICS, "p99_us", "service_p95_us", "dispatch_lateness_p95_us", "drain_after_window_ns")


def fair_hooks():
    with TemporaryDirectory() as directory:
        root = Path(directory)
        (root / "runner").mkdir()
        hooks = {}
        for us in SLICES_US:
            sibling_sched.stage(root, root, f"base-{us}us")
            hooks[us] = (root / "fair-scheduler.sh").read_bytes()
        return hooks


def check_plan(folder, plan, hooks):
    us, seed = plan.get("slice_350_target_us"), plan.get("seed")
    require(type(us) is type(seed) is int and us in SLICES_US and seed in SEED_ORDER and
            plan.get("guest_fair") == f"base-{us}us", "unexpected diagnostic slice or seed")
    require(all(plan.get(k) == value for k, value in WORKLOAD.items()) and
            plan["worker_next_buddy"] is plan["cpu_groups"] is True and type(plan["build_nice"]) is int and
            plan["pages"]["kernel_page_kib"] == 16 and plan["pages"]["kernel_ipvlan"] is True and
            not any(plan.get(key) is not None for key in
                    ("fair_slice_us", "build_slice_us", "builder_shares", "ext4_cache_profile")) and
            plan.get("slice_target", "all") == "all" and plan.get("build_policy") is None and
            not (folder / "ext4-cache-plan.json").exists(), "diagnostic requires the ordinary-cache grouped tmpfs workload")
    require(terminal.digest(folder / "slice-350-driver.py") == plan["slice_350_driver_sha256"] and
            (folder / "fair-scheduler.sh").read_bytes() == hooks[us],
            "diagnostic driver or scheduler hook differs")
    return seed, us


def static_guest_facts(lines):
    # The archived guest facts also contain counters from ethtool and procfs.
    fields = {}
    for key in STATIC_FACT_KEYS:
        values = [line.removeprefix(key + "=") for line in lines if line.startswith(key + "=")]
        require(len(values) == 1 and values[0], f"missing or duplicate guest fact {key}")
        fields[key] = values[0]
    scheduler_args = ("micropod.ci_sched=", "micropod.ci_wakeup=")
    require([token for token in fields["cmdline"].split() if token.startswith(scheduler_args)] == BOOT_ARGS.split(),
            "diagnostic guest did not boot with the signed 250 µs profile")
    probes = [i for i, line in enumerate(lines) if line.startswith("ethtool ")]
    nic = {lines[start]: lines[start + 1:end]
           for start, end in zip(probes, [*probes, len(lines)][1:], strict=True)
           if lines[start].split()[1] in STATIC_NIC_PROBES}
    markers = ("/sys/fs/cgroup/cgroup.controllers", "/proc/self/cgroup")
    require(all(lines.count(marker) == 1 for marker in markers), "missing guest cgroup configuration")
    return {**fields, "cgroups": {marker: lines[lines.index(marker) + 1] for marker in markers},
            "kernel_options": [line for line in lines if line.startswith(("CONFIG_", "# CONFIG_"))],
            "nic_options": nic, "nic_queues": [line for line in lines if line.startswith(("virtio_nic=", "/sys/class/net/"))]}


def signed_settings(folder, plan, product):
    package = read(folder, "worker-build.json")
    expected = {
        "worker_executable_sha256": product["host_sha256"], "guest_runner_sha256": product["new_guest_sha256"],
        "guest_start_sha256": product["new_bootstrap_sha256"], "base_revision": product["base_revision"],
        "entitlements": product["entitlements"],
    }
    require(all(package[k] == value for k, value in expected.items()) and
            Path(package["arena"], "product.json") == Path(product["current_product"]),
            "diagnostic did not use the signed holdout product and bootstrap")
    job = plistlib.loads((folder / "a/job.plist").read_bytes())
    env = job["EnvironmentVariables"]
    runtime = read(folder, "a/worker.json")
    scope = Path(plan["scope"]).resolve()
    require(env.get("MICROPOD_SANDBOX_KERNEL_ARGS") == BOOT_ARGS and
            all(Path(env[key]).resolve() == scope / path for key, path in BOOT_PATHS.items()) and
            Path(runtime["workspace"]).resolve() == scope / "workspace",
            "diagnostic launch command or scoped worker paths differ")
    facts = (folder / "a/guest-facts.txt").read_text().splitlines()
    return (package, {k: v for k, v in job.items() if k not in
                      ("Label", "StandardErrorPath", "StandardOutPath", "EnvironmentVariables")},
            {k: v for k, v in env.items() if k not in BOOT_PATHS},
            {k: v for k, v in runtime.items() if k not in ("worker", "workspace")},
            static_guest_facts(facts))


def verified_run(folder, plan, target):
    observed = fixture.verify_after_work(folder, plan, read(folder, "grouped-inventory.json"))
    run = paced.replay(folder)
    require(run["plan"] == plan and run["placements"] == PLACEMENT, "diagnostic plan or fixed CPU placement differs")
    scratch, mounts = sibling_tmpfs.read_fields((folder / "go-scratch-boot.txt").read_text())
    require(scratch["boot"] == run["boot"] and mounts["/"]["source"] == "/dev/vdb" and
            not mounts["/"]["device"].startswith("7:"), "diagnostic cache was not on the ordinary worker disk")
    scheduler = run["worker"]["scheduler"]
    require(scheduler["setting"] == f"base-{target}us" and scheduler["base_slice_ns"] == target * 1000 and
            scheduler["before"] == scheduler["after"] and
            {"HRTICK", "NEXT_BUDDY", "PICK_BUDDY"} <= set(scheduler["after"]) and
            scheduler["clocksource"] == "arch_sys_counter" and
            observed == {"boot": run["boot"], "effective_ns": target * 1000, "features": scheduler["after"]},
            "unexpected effective diagnostic scheduler readback or guest boot")
    rows = run["rows"]["grouped"]
    require(len(rows) == WORKLOAD["rounds"] and Counter(row["order"] for row in rows) == {"AB": 2, "BA": 2} and
            all(row[arm]["offered_requests"] == row[arm]["requests"] == 96_000 and
                row[arm]["completed_after_first_build"] == 0 and row[arm]["first_build_end_margin_ns"] >= 0
                for row in rows for arm in "AB"), "diagnostic work, engine order or build overlap differs")
    return run


def run_identity(run):
    worker = run["worker"]
    scheduler = {k: v for k, v in worker["scheduler"].items() if k not in ("setting", "base_slice_ns")}
    return {**worker, "scheduler": scheduler}, run["images"]


def outcomes(first, second, labels):
    pairs = list(zip(first, second, strict=True))
    metrics = {key: paced.paired_summary([a[key] for a, _ in pairs], [b[key] for _, b in pairs], key, labels)
               for key in METRICS}
    left, right = labels
    left_wins = [i for i, (a, b) in enumerate(pairs) if all(a[key] < b[key] for key in WIN_METRICS)]
    right_wins = [i for i, (a, b) in enumerate(pairs) if all(b[key] < a[key] for key in WIN_METRICS)]
    return {"metrics": metrics, "same_window_wins": {
        left: len(left_wins), right: len(right_wins), "split_or_tied": len(pairs) - len(left_wins) - len(right_wins),
    }, "simultaneous_win_positions": {left: left_wins, right: right_wins}}


def comparisons(windows):
    return {
        "within_level": {str(us): outcomes([w["B"] for w in windows[us]], [w["A"] for w in windows[us]],
                                           ("orbstack", "micropod")) for us in SLICES_US},
        "within_engine": {engine: outcomes([w[arm] for w in windows[250]], [w[arm] for w in windows[350]],
                                           ("250us", "350us")) for arm, engine in (("A", "micropod"), ("B", "orbstack"))},
    }


def study_results(verified):
    by_seed, pooled = [], {us: [] for us in SLICES_US}
    for seed, order in SEED_ORDER.items():
        paths, runs = zip(*(verified[seed, us] for us in SLICES_US), strict=True)
        windows = {us: run["rows"]["grouped"] for us, run in zip(SLICES_US, runs, strict=True)}
        first = {us: windows[us][0]["A"]["scheduled_unix_ns"] for us in SLICES_US}
        require(first[order[0]] < first[order[1]], "unexpected diagnostic treatment order")
        for a, b in zip(windows[250], windows[350], strict=True):
            require(a["order"] == b["order"] and
                    len({tuple(row[arm]["build"]["products"]) for row in (a, b) for arm in "AB"}) == 1,
                    "diagnostic changed engine order or build outputs")
        for us in SLICES_US:
            pooled[us].extend(windows[us])
        result = comparisons(windows)
        candidate = result["within_level"]["350"]["metrics"]
        by_seed.append({
            "seed": seed, "treatment_order_us": list(order),
            "boots": {str(us): {"archive": path.name, "native_boot": run["boot"], "guest_facts": "a/guest-facts.txt"}
                      for us, path, run in zip(SLICES_US, paths, runs, strict=True)},
            "engine_order": [row["order"] for row in windows[250]],
            "micropod_won_both_350us_boot_medians": all(candidate[k]["micropod"] < candidate[k]["orbstack"] for k in WIN_METRICS),
            **result,
        })
    arms = [row[arm] for rows in pooled.values() for row in rows for arm in "AB"]
    timer_slack = {}
    for arm, engine in (("A", "micropod"), ("B", "orbstack")):
        slacks = {slack for rows in pooled.values() for row in rows for slack in row[arm]["timer_slack_ns"]}
        require(len(slacks) == 1, f"diagnostic issuing-thread timer slack changed on {engine}")
        timer_slack[engine] = slacks.pop()
    return {
        "effective_slice_us": list(SLICES_US), "offered_rps": WORKLOAD["offered_rps"],
        "boot_pairs": len(by_seed), "engine_windows": len(arms), "windows_per_boot": WORKLOAD["rounds"],
        "offered_requests": sum(row["offered_requests"] for row in arms),
        "minimum_first_build_end_margin_ns": min(row["first_build_end_margin_ns"] for row in arms),
        "timer_slack_ns": timer_slack,
        "promotion_gate_met": all(row["micropod_won_both_350us_boot_medians"] for row in by_seed),
        "by_seed": by_seed, **comparisons(pooled),
    }


def compare(folders):
    paths = [folder.resolve() for folder in folders]
    require(len(paths) == len(set(paths)) == 4, "diagnostic requires four distinct archive directories")
    product = read(Path(__file__).resolve().parent, PRODUCT_RECEIPT)
    plans, scopes = {}, set()
    common_plan = common_settings = None
    with fixture.scheduler_profiles():
        hooks = fair_hooks()
        for path in paths:
            plan = read(path, "plan.json")
            key = check_plan(path, plan, hooks)
            require(key not in plans and plan["scope"] not in scopes, "duplicate diagnostic seed, treatment or scope")
            plans[key] = path, plan
            scopes.add(plan["scope"])
            settings = signed_settings(path, plan, product)
            protocol = {k: v for k, v in plan.items() if k not in PLANNED_VARIATION}
            if common_plan is None:
                common_plan, common_settings = protocol, settings
            require(protocol == common_plan and settings == common_settings, "unmatched diagnostic worker or workload inputs")
        verified = {key: (path, verified_run(path, plan, key[1])) for key, (path, plan) in plans.items()}
    runs = [run for _, run in verified.values()]
    require(len({run["boot"] for run in runs}) == 4 and len({run["peer_boot"] for run in runs}) == 1,
            "duplicate Micropod boot or changed OrbStack boot")
    first = runs[0]
    identity = run_identity(first)
    require(all(run_identity(run) == identity for run in runs),
            "unmatched effective diagnostic scheduler, worker or images")
    return {
        **study_results(verified), "peer_boot": first["peer_boot"], "kernel": first["plan"]["pages"],
        "signed_product": {key: product[key] for key in ("host_sha256", "new_guest_sha256", "new_bootstrap_sha256")},
        "placements": PLACEMENT, "scheduler_implementation": "disposable fixture after the signed 250 µs startup",
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folders", nargs=4, type=Path)
    print(json.dumps(compare(parser.parse_args().folders), indent=2))
