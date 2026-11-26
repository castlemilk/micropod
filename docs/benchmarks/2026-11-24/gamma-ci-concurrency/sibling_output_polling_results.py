"""Replay stock and event-aware runner log following under dense CI."""

import argparse
from hashlib import sha256
import json
from pathlib import Path
import re
from statistics import median
from unittest.mock import patch

from qualify import require, terminal
from sibling_results import docker_time_ns, read
import sibling_file_fault_around_holdout_results as holdout
import sibling_file_fault_around_results as trial
import sibling_output_polling_product as products


HERE = Path(__file__).resolve().parent
MODE = "output_polling"
MODES = products.MODES
ORDERS = {250271: MODES, 250273: MODES[::-1]}
WINDOW = trial.VALUES[0]
STOCK_SEEDS = {seed: (WINDOW,) for seed in ORDERS}
SHARED, PACED = trial.shared, trial.paced
STRICT_ADMISSION = SHARED.check_admission
METRICS = ("p95_us", "p99_us", "service_p95_us", "service_p99_us", "dispatch_lateness_p95_us",
           "dispatch_lateness_p99_us", "build_makespan_s", "slowest_build_s")
STAGED_START = "19515f373abf0a7775cb32457a8686cd20b9e43356936904a4faf968eea114e3"
DEPENDENCIES = {
    "github.com/opencontainers/go-digest": ("v1.0.0", "h1:apOUWs51W5PlhuyGyz9FCeeBIOUDA/6nW8Oi/yOhh5U=",
                                          "h1:0JzlMkj0TRzQZfJkVvzbP0HBR3IKzErnv2BNG4W4MAM="),
    "github.com/opencontainers/image-spec": ("v1.1.1", "h1:y0fUlFfIZhPF1W537XOLg0/fcx6zcHCJwooC2xJA040=",
                                            "h1:qpqAh3Dmcf36wStyyWU+kCeDgrGnAve2nCC8+7h8Q0M="),
}
PRODUCT_PLAN_KEYS = (MODE, "output_polling_runner_sha256", "output_polling_product_sha256", "output_polling_build_manifest_sha256")
TEST_ROOTS = {"TestCRIOutputRecordBoundaries", "TestCRIOutputErrorsAndLimit", "TestCRIFollowStreamsWhileWaitingForTask",
              "TestCRIFollowWaitRechecksUncommittedExit", "TestCRIFollowCancelsTaskWait"}
TEST_SUBCASES = {f"TestCRIFollowWaitRechecksUncommittedExit/{name}" for name in ("OK", "NotFound", "Unavailable")}


def check_inserted_lines(before, after, inserted):
    old, new = before.splitlines(keepends=True), after.splitlines(keepends=True)
    for line in inserted:
        require(new.count(line) == 1 and line not in old, "missing or duplicate pinned Go dependency")
        new.remove(line)
    require(new == old, "output polling changed unrelated module requirements or checksums")


def check_module_delta(previous, candidate):
    old, new = (path.parent / "src" / products.RUNNER for path in (previous, candidate))
    mod = [f"\t{name} {version} // indirect\n" for name, (version, _, _) in DEPENDENCIES.items()]
    sums = [entry for name, (version, source, module) in DEPENDENCIES.items()
            for entry in (f"{name} {version} {source}\n", f"{name} {version}/go.mod {module}\n")]
    for basename, added in (("go.mod", mod), ("go.sum", sums)):
        check_inserted_lines((old / basename).read_text(), (new / basename).read_text(), added)


def check_build_recipe(arm, mode, combined, previous):
    scope = Path(arm["product"]).parent
    identity = {"parent": combined["previous_product_sha256"], "mode": mode,
                "changed": arm["changed_sources"], "toolchain": combined["toolchain"],
                "packager": terminal.digest(Path(products.__file__))}
    require(arm["identity"] == identity and scope.name == "ci-published-link-" + products.hashed(products.encode(identity))[:16] and
            Path(arm["source_dir"]) == scope / "src" and Path(arm["runner_source_dir"]) == scope / "src" / products.RUNNER,
            "runner package identity does not bind the sealed build inputs")
    world = arm["build"]
    cwd = Path(world["cwd"])
    stage = cwd.parents[2]
    require(cwd == stage / "src" / products.RUNNER and stage.name == "product" and stage.parent.parent == products.BASE and
            stage.parent.name.startswith("output-polling-") and
            world["argv"] == [combined["toolchain"]["path"], "build", "-trimpath", "-o", str(stage / products.JOB), "."] and
            world["toolchain"]["environment"] == products.ENV and world["toolchain"]["go_flags"] == "-trimpath" and
            world["stdout"] == world["stderr"] == "", "unexpected Linux runner build invocation or output")
    info = world["binary_build_info"]
    require(info[0] == products.GO_VERSION and {"build\tGOOS=linux", "build\tGOARCH=arm64", "build\tCGO_ENABLED=0",
                                               f"build\tvcs.revision={previous['base_revision']}", "build\tvcs.modified=true"} <= set(info),
            "Linux runner build metadata differs from the signed worker")
    return info


def check_products(path):
    raw = Path(path).read_bytes()
    combined = json.loads(raw)
    parent, old = trial.check_product()
    previous = Path(parent["current_product"])
    require(combined["previous_product"] == str(previous) and combined["kernel"] == parent["kernel"] and
            combined["host_sha256"] == parent["host_sha256"] and
            combined["new_bootstrap_sha256"] == parent["new_bootstrap_sha256"],
            "runner comparison changed the sealed parent, host, bootstrap or kernel")
    guard = {"tools_except_job": products.tree(previous.parent / products.TOOLS, ("runner/bin/job",)),
             "source_except_follower": products.tree(previous.parent / "src", products.ALLOWED)}
    require(combined["tree_guards"] == guard, "runner packages changed files outside the authorized source and binary")
    arms, info = {}, {}
    for mode in MODES:
        product_path, package, build = products.check_arm(combined, mode)
        info[mode] = check_build_recipe(build, mode, combined, old)
        manifest = {**parent, "current_product": str(product_path), "new_guest_sha256": package["guest_runner_sha256"]}
        require((package["guest_runner_sha256"] == old["guest_runner_sha256"]) == (mode == "stock"),
                "the optimized runner was not isolated to its selected product arm")
        arms[mode] = {"path": product_path, "package": package, "arm_build": build, "manifest": manifest}
    check_module_delta(previous, arms["optimized"]["path"])
    added_info = {f"dep\t{name}\t{version}\t{source}" for name, (version, source, _) in DEPENDENCIES.items()}
    require(set(info["optimized"]) - set(info["stock"]) == added_info and
            [line for line in info["optimized"] if line not in added_info] == info["stock"],
            "runner arms used different embedded settings beyond the pinned OCI libraries")
    return combined, raw, arms


def validated_archive(folder, plan, combined, combined_raw, arm):
    import sibling_output_polling as fixture

    mode = plan[MODE]
    sealed = combined["arms"][mode]
    source = arm["path"].parent
    require((folder / products.MANIFEST).read_bytes() == combined_raw and
            (folder / products.ARM).read_bytes() == (source / products.ARM).read_bytes() and
            (folder / products.DELTA).read_bytes() == (source / products.DELTA).read_bytes() and
            (folder / "worker-build.json").read_bytes() == arm["path"].read_bytes() and
            terminal.digest(folder / fixture.PACKAGER) == arm["arm_build"]["identity"]["packager"] and
            terminal.digest(folder / "output-polling-start.sh") == STAGED_START and
            all((folder / "output-polling-src" / path).read_bytes() == (source / "src" / path).read_bytes()
                for path in products.ALLOWED), "archive did not retain the exact selected runner product, patch or startup source")
    require(plan["output_polling_runner_sha256"] == sealed["runner_sha256"] and
            plan["output_polling_product_sha256"] == sealed["product_sha256"] and
            plan["output_polling_build_manifest_sha256"] == sealed["build_manifest_sha256"] and
            plan["output_polling_manifest_sha256"] == sha256(combined_raw).hexdigest() and
            plan.get(trial.TREATMENT) == WINDOW and "ttwu_queue" not in plan and "ttwu_diagnostic" not in plan,
            "archive changed the selected runner or asked for another scheduler treatment")
    expected_hook = fixture.boot_hook()
    with patch.object(holdout, "SEED_ORDER", STOCK_SEEDS), patch.object(trial.fixture, "boot_hook", return_value=expected_hook):
        (seed, _), settings, protocol = holdout.validated_archive(folder, plan, arm["manifest"], arm["package"])
    package, launch, *stable = settings
    require(launch["ProgramArguments"] == [package["worker_executable"], "ci", "serve"],
            "live signed host launch pointed at a different product arm")
    launch_config = {name: value for name, value in launch.items() if name != "ProgramArguments"}
    return (seed, mode), [launch_config, *stable], {name: value for name, value in protocol.items() if name not in PRODUCT_PLAN_KEYS}


def check_test_log(raw):
    lines = raw.strip().splitlines()
    expected = TEST_ROOTS | TEST_SUBCASES
    started = [line.removeprefix("=== RUN   ") for line in lines if line.startswith("=== RUN   ")]
    passed = [match[1] for line in lines if (match := re.match(r"\s*--- PASS: (\S+) \(", line))]
    require(len(started) == len(passed) == len(expected) and set(started) == set(passed) == expected and
            lines[-1] == "PASS" and not any("--- FAIL:" in line or line == "FAIL" for line in lines),
            "raw Linux test receipt lacks a verified CRI output root or exit-repair subtest")
    return started


def reconcile_retirement_sample(host, peer, peer_ids, first_wave, last_wave, after_capture):
    require(len(host) == len(peer) + 1 and len(peer) > 1 and all(row["blockers"] == [] for row in host),
            "only one blocker-free terminal host sample can lack a peer pair")
    require(len(peer_ids) == 2 * PACED.PAIRS and peer[-1]["running"] == [] and
            all(len(row["running"]) == len(set(row["running"])) and set(row["running"]) <= peer_ids for row in peer),
            "terminal admission requires a verified empty peer and no foreign containers")
    clocks = [(docker_time_ns(a["utc"]), docker_time_ns(b["time"])) for a, b in zip(host[:-1], peer, strict=True)]
    orphan = docker_time_ns(host[-1]["utc"])
    require(all(0 < begin <= end for begin, end in clocks) and
            all(end < begin for (_, end), (begin, _) in zip(clocks, clocks[1:])) and
            clocks[0][1] < first_wave <= last_wave < after_capture < clocks[-1][0] <= clocks[-1][1] < orphan and
            any(end > last_wave and set(row["running"]) == peer_ids for (_, end), row in zip(clocks, peer, strict=True)),
            "each scored wave must precede the verified peer retirement and unpaired host sample")
    return {"first_utc": host[0]["utc"], "last_utc": host[-1]["utc"], "samples": len(peer),
            "full_peer_cohort_samples": sum(set(row["running"]) == peer_ids for row in peer),
            "post_work_host_sample": host[-1], "last_paired_peer_sample": peer[-1],
            "last_scored_host_finish_unix_ns": last_wave, "post_work_capture_finished_unix_ns": after_capture}


def check_retirement_cleanup(folder, plan):
    cleanup = read(folder, "cleanup.json")
    retired = read(folder, "job-parent-retired.json")
    require(read(folder, "status.json") == {"complete": True} and cleanup == {"scope": plan["scope"], "retained": False, "errors": []} and
            not Path(plan["scope"]).exists() and read(folder, "verification.json") == {"baseline_files": 24, "extra_cleanup_errors": []} and
            retired["status"] == "unmounted" and retired["worker"]["present"] == [],
            "terminal admission reconciliation requires successful scoped network, cgroup and host cleanup")


def check_admission(folder, inventory):
    host, peer = ([json.loads(line) for line in (folder / name).read_text().splitlines()]
                  for name in ("admission.jsonl", "orb-inventory.jsonl"))
    if len(host) == len(peer):
        return STRICT_ADMISSION(folder, inventory)
    require(len(host) == len(peer) + 1 and len(peer) > 1, "unexpected missing host or peer admission samples")
    plan = read(folder, "plan.json")
    check_retirement_cleanup(folder, plan)
    before, after = (read(folder, f"job-parent-{phase}.json") for phase in ("before", "after"))
    first, last = holdout.check_host_windows(read(folder, holdout.WINDOWS), plan["seed"], before["host_finished_unix_ns"],
                                            after["host_started_unix_ns"])
    saved = read(folder, "windows.json")
    for arm in SHARED.ENGINES:
        guest_ends = []
        for block in range(SHARED.ROUNDS):
            solo, = PACED.read_wire(folder, f"grouped-{block}-one-{arm}")
            builds = read(folder, f"grouped-{block}-all-{arm}-go.json")
            require(len(builds) == PACED.BUILDERS and all(row["code"] == 0 for row in builds), "missing build lifetimes at retirement")
            gate = max(row["started_unix_ns"] for row in builds) + 35_000_000
            responses_end = gate + saved[f"grouped-{block}-all"][arm]["last_completion_offset_ns"]
            guest_ends.extend((solo["receipt"]["window"]["finished_unix_ns"], responses_end,
                               *(int(row["stdout"].splitlines()[-1].split()[1]) for row in builds)))
        require(max(guest_ends) < min(row["inside"]["guest_unix_ns"] for row in after["arms"][arm]["containers"]),
                f"{arm} post-work capture does not enclose all HTTP and build lifetimes")
    peer_ids = {job["id"] for job in inventory["B"]["jobs"]}
    return reconcile_retirement_sample(host, peer, peer_ids, first, last, after["host_finished_unix_ns"])


def verified_run(folder, plan, combined, arm):
    import sibling_output_polling as fixture

    with patch.object(SHARED, "check_admission", check_admission):
        context = trial.qualified_context(folder, plan)
    witness = fixture.verify(folder, plan, context["boots"], combined, arm["package"], arm["arm_build"])
    tests = check_test_log((folder / fixture.TESTS).read_text())
    require(witness["linux_tests"] == tests, "live test receipt disagrees with the independent Linux log replay")
    last_wave, stock = holdout.verify_stock(folder, plan, context)
    mapping = trial.check_mapping(folder, context, WINDOW, last_wave=last_wave)
    run, rows = trial.replay_paced(folder, plan, context)
    worker = run["worker"]
    require(worker["guest"] == arm["package"]["guest_runner_sha256"] == witness["native_engine"]["runner_sha256"] and
            "TTWU_QUEUE" in worker["scheduler"]["after"] and "NO_TTWU_QUEUE" not in worker["scheduler"]["after"],
            "actual running engine bytes or stock scheduler differ from the selected arm")
    result = trial.run_identity(folder, plan, context, run, rows)
    result["worker_invariants"] = {name: value for name, value in worker.items() if name != "guest"}
    result["receipt"].update(stock_builds=stock, off_timing_go_mapping=mapping, native_engine=witness["native_engine"],
                             linux_tests=witness["linux_tests"], mode=plan[MODE])
    return result


def matched_identity(verified):
    rows = list(verified.values())
    first = rows[0]
    require(len({row["run"]["boot"] for row in rows}) == len(rows) and len({row["run"]["peer_boot"] for row in rows}) == 1,
            "output polling crossover reused a native boot or changed the OrbStack peer")
    require(len(set().union(*(row["ids"] for row in rows))) == len(rows) * 4 * PACED.PAIRS and
            len({row["receipt"]["native_volume"]["volume_uuid"] for row in rows}) == len(rows),
            "output polling crossover reused a measured container or APFS volume")
    require(all(all(row[key] == first[key] for key in ("worker_invariants", "compiler_executables", "launch")) and
                row["run"]["images"] == first["run"]["images"] for row in rows),
            "output polling crossover changed another worker setting, toolchain, images or actual placement")
    intervals = sorted((docker_time_ns(row["receipt"]["admission"]["first_utc"]), docker_time_ns(row["receipt"]["admission"]["last_utc"]))
                       for row in rows)
    require(all(finish < start for (_, finish), (start, _) in zip(intervals, intervals[1:])), "output polling boot scopes overlapped")
    timer_slacks = {engine: {slack for row in rows for wave in row["rows"] for slack in wave[arm]["timer_slack_ns"]}
                    for arm, engine in SHARED.ENGINES.items()}
    require(all(len(values) == 1 for values in timer_slacks.values()), "output polling crossover changed HTTP issuing-thread timer slack")
    return {"worker_invariants": first["worker_invariants"], "peer_boot": first["run"]["peer_boot"],
            "images": first["run"]["images"], "compiler_executables": first["compiler_executables"],
            "issuing_timer_slack_ns": {engine: values.pop() for engine, values in timer_slacks.items()}}


def comparisons(windows, modes=MODES):
    control, candidate = modes
    direct = {mode: SHARED.outcomes([row["B"] for row in waves], [row["A"] for row in waves], ("orbstack", "micropod"))
              for mode, waves in windows.items()}
    treatment = {engine: SHARED.outcomes([wave[arm] for wave in windows[control]], [wave[arm] for wave in windows[candidate]], modes)
                 for arm, engine in SHARED.ENGINES.items()}
    relative = {}
    for key in METRICS:
        matched = [(a["A"][key], a["B"][key], b["A"][key], b["B"][key])
                   for a, b in zip(windows[control], windows[candidate], strict=True)]
        relative[key] = (median((new_native / new_peer) / (old_native / old_peer)
                                for old_native, old_peer, new_native, new_peer in matched)
                         if all(a and b and d for a, b, _, d in matched) else None)
    return {"within_mode": direct, "within_engine": treatment, "median_paired_native_to_peer_ratio_change": relative}


def summarize(verified, *, modes=MODES, orders=ORDERS):
    control, candidate = modes
    pooled, by_seed = {mode: [] for mode in modes}, []
    for seed, order in orders.items():
        boots = {mode: verified[seed, mode] for mode in modes}
        windows = {mode: boot["rows"] for mode, boot in boots.items()}
        a, b = (boots[mode]["receipt"]["admission"] for mode in order)
        require(docker_time_ns(a["last_utc"]) < docker_time_ns(b["first_utc"]), "output polling crossover reversed its prespecified boot order")
        require(len(windows[control]) == len(windows[candidate]) == SHARED.ROUNDS and
                [wave["order"] for wave in windows[control]] == [wave["order"] for wave in windows[candidate]],
                "output polling crossover changed the paired engine order")
        metrics = comparisons(windows, modes)
        by_seed.append({"seed": seed, "boot_order": list(order), "boots": {mode: boot["receipt"] for mode, boot in boots.items()},
                        "native_beats_peer_on_both_medians": {
                            mode: all(view["metrics"][metric]["micropod"] < view["metrics"][metric]["orbstack"]
                                      for metric in SHARED.WIN_METRICS) for mode, view in metrics["within_mode"].items()},
                        **metrics})
        for mode in modes:
            pooled[mode].extend(windows[mode])
    require(all(len({tuple(boot["rows"][round_no][arm]["build"]["products"]) for boot in verified.values()
                     for arm in SHARED.ENGINES}) == 1 for round_no in range(SHARED.ROUNDS)),
            "output polling crossover changed the actual CI artifacts")
    waves = [row[arm] for rows in pooled.values() for row in rows for arm in SHARED.ENGINES]
    return {
        "matched_boot_pairs": len(by_seed), "native_boots": len(verified), "rounds_per_boot": SHARED.ROUNDS,
        "paired_engine_windows": len(waves) // 2, "engine_windows": len(waves), "offered_rps": SHARED.RATE,
        "offer_duration_ns": PACED.OFFER_NS, "offered_requests": sum(row["offered_requests"] for row in waves),
        "completed_requests": sum(row["requests"] for row in waves), "build_jobs": sum(row["build"]["jobs"] for row in waves),
        "build_revisions": sum(row["build"]["revisions"] for row in waves), "test_passes": sum(row["build"]["test_passes"] for row in waves),
        "minimum_first_build_end_margin_ns": min(row["first_build_end_margin_ns"] for row in waves),
        "native_beats_peer_on_both_medians_each_seed": {
            mode: all(seed["native_beats_peer_on_both_medians"][mode] for seed in by_seed) for mode in modes},
        "by_seed": by_seed, **comparisons(pooled, modes),
    }


def compare(folders, *, manifest=HERE / products.MANIFEST):
    """Replay the four stock/optimized boots in the two counterbalanced seed pairs."""
    paths = [Path(folder).resolve() for folder in folders]
    scheduled = {(seed, mode) for seed, order in ORDERS.items() for mode in order}
    require(len(paths) == len(set(paths)) == len(scheduled), "output polling crossover needs four distinct completed archives")
    combined, combined_raw, arms = check_products(manifest)
    candidate_sources = arms["optimized"]["path"].parent / "src" / products.RUNNER
    suite = (candidate_sources / "cri_output_linux_test.go").read_text()
    tests = set(re.findall(r"^func (TestCRI(?:Output|Follow)\w*)\(", suite, re.MULTILINE))
    require(tests == TEST_ROOTS, "sealed candidate lacks the expected Linux runner tests")
    archives, scopes, common = {}, set(), None
    for folder in paths:
        plan = read(folder, "plan.json")
        mode = plan.get(MODE)
        require(mode in MODES, "unexpected output polling arm")
        key, settings, protocol = validated_archive(folder, plan, combined, combined_raw, arms[mode])
        scope = Path(plan["scope"]).resolve()
        require(key in scheduled and key not in archives and scope not in scopes, "duplicate output polling seed, mode or scope")
        if common is None:
            common = settings, protocol
        require((settings, protocol) == common, "output polling crossover changed a matched setting beyond the Linux runner")
        archives[key] = folder, plan
        scopes.add(scope)
    require(archives.keys() == scheduled, "output polling crossover is missing a prespecified boot")
    verified = {key: verified_run(folder, plan, combined, arms[key[1]]) for key, (folder, plan) in archives.items()}
    settings, protocol = common
    first = next(iter(verified.values()))
    return {"product_manifest_sha256": sha256(combined_raw).hexdigest(), "products": combined["arms"], "kernel": combined["kernel"],
            "placements": trial.signed.PLACEMENT, "protocol_sha256": SHARED.fingerprint([protocol, first["launch"]]),
            "signed_settings_sha256": SHARED.fingerprint(settings), "changed_sources": sorted(products.ALLOWED),
            **matched_identity(verified), **summarize(verified)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=HERE / products.MANIFEST)
    parser.add_argument("folders", nargs=4, type=Path)
    args = parser.parse_args()
    print(json.dumps(compare(args.folders, manifest=args.manifest), indent=2, allow_nan=False))
