"""Replay the stock dense CI crossover between TTWU_QUEUE on and off."""

import argparse
import json
from pathlib import Path
import plistlib
import re
from statistics import median
from types import SimpleNamespace
from unittest.mock import patch

from qualify import require, terminal
from sibling_results import docker_time_ns, read
import sibling_file_fault_around_holdout_results as stock
import sibling_file_fault_around_results as trial


MODES = ("on", "off")
SEED_ORDER = {250263: MODES, 250267: MODES[::-1]}
WINDOW = trial.VALUES[0]
SHARED = trial.shared
PACED = trial.paced
QUEUE = "ttwu_queue"
QUEUE_ARG = "micropod.bench_ttwu_queue="
TOKENS = {"on": "TTWU_QUEUE", "off": "NO_TTWU_QUEUE"}
STOCK_SEEDS = {seed: (WINDOW,) for seed in SEED_ORDER}
STAGED_START_SHA256 = "19515f373abf0a7775cb32457a8686cd20b9e43356936904a4faf968eea114e3"
STAGED_FACTS_SHA256 = "b0ab5f2ce9bc3295f2615588350984b4ebbd175e0a427e169b52bcb23a34bd23"
MAIN_METRICS = ("p95_us", "p99_us", "service_p95_us", "service_p99_us", "dispatch_lateness_p95_us",
                "dispatch_lateness_p99_us", "build_makespan_s", "slowest_build_s")


def expected_kernel_args(mode):
    require(mode in MODES, "unknown TTWU queue setting")
    return [*trial.signed.BOOT_ARGS.split(), trial.TOKEN + str(WINDOW), QUEUE_ARG + mode]


def projected_plist(raw, mode):
    job = plistlib.loads(raw)
    env = job["EnvironmentVariables"]
    args = env[trial.KERNEL_ARGS].split()
    require(args == expected_kernel_args(mode), "raw native launch has the wrong TTWU queue token or extra scheduler options")
    # The generic checks know the ordinary scheduler args. Only project away
    # the two verified private selectors when those readers consume the plist.
    return {**job, "EnvironmentVariables": {**env, trial.KERNEL_ARGS: trial.signed.BOOT_ARGS}}


def launch_view(mode):
    return SimpleNamespace(loads=lambda raw: projected_plist(raw, mode))


def checked_guest_cmdline(cmdline, mode):
    args = cmdline.split()
    settings = [token for token in args if token.startswith(("micropod.ci_", "micropod.bench_"))]
    require(settings == expected_kernel_args(mode), "live kernel command line has the wrong TTWU queue token or extra options")
    return " ".join(token for token in args if not token.startswith((trial.TOKEN, QUEUE_ARG)))


def signed_settings(folder, plan, product, candidate):
    mode = plan[QUEUE]
    with patch.object(trial.signed, "plistlib", launch_view(mode)):
        settings = trial.signed.signed_settings(folder, plan, product)
    facts = settings[-1]
    require(settings[0] == candidate and facts["release"] == product["kernel"]["release"] and
            (folder / "fair-scheduler/cmdline").read_text().split() == facts["cmdline"].split(),
            "archive did not use the sealed worker/kernel or its command-line sources disagree")
    return (*settings[:-1], {**facts, "cmdline": checked_guest_cmdline(facts["cmdline"], mode)})


def feature_vector(features):
    require(isinstance(features, list) and all(isinstance(token, str) and re.fullmatch(r"[A-Z][A-Z_0-9]*", token)
                                               for token in features), "invalid native scheduler feature vector")
    require(len({token.removeprefix("NO_") for token in features}) == len(features),
            "duplicate or contradictory native scheduler feature")
    return set(features)


def scheduler_invariants(mode, initial, installed, final, standard):
    default = feature_vector(initial)
    effective = feature_vector(installed)
    wanted = (default - {TOKENS["on"]}) | {TOKENS[mode]}
    require({TOKENS["on"], "HRTICK", "NEXT_BUDDY", "PICK_BUDDY"} <= default and effective == wanted and
            feature_vector(final) == effective, "TTWU_QUEUE was not the sole effective scheduler feature difference")
    require(standard["setting"] == "inherit" and standard["before"] == standard["after"] == sorted(effective) and
            standard["base_slice_ns"] == 250_000 and standard["clocksource"] == "arch_sys_counter",
            "ordinary scheduler receipt disagrees with the TTWU queue readbacks or worker slice")
    return {"initial_features": sorted(default), "other_effective_features": sorted(effective - set(TOKENS.values())),
            "base_slice_ns": standard["base_slice_ns"], "clocksource": standard["clocksource"]}


def validated_archive(folder, plan, product, candidate):
    import sibling_ttwu_queue as fixture

    mode = plan.get(QUEUE)
    require(mode in MODES and plan.get(trial.TREATMENT) == WINDOW and not plan.get("ttwu_diagnostic") and
            not (folder / "ttwu-summary.json").exists(), "TTWU queue crossover requires an untraced stock 64 KiB worker")
    fixture.check_launch(folder, WINDOW, mode)
    require(terminal.digest(folder / fixture.START) == STAGED_START_SHA256 and
            terminal.digest(folder / fixture.FACTS) == STAGED_FACTS_SHA256 and
            (folder / fixture.MANIFEST).read_bytes() == (fixture.HERE / fixture.MANIFEST).read_bytes(),
            "TTWU queue crossover changed the exact staged startup, facts script or signed parent receipt")
    expected_hook = fixture.post_hook()
    with patch.object(stock, "SEED_ORDER", STOCK_SEEDS), patch.object(trial, "verified_settings", signed_settings), \
            patch.object(trial.fixture, "boot_hook", return_value=expected_hook):
        (seed, _), settings, protocol = stock.validated_archive(folder, plan, product, candidate)
    return (seed, mode), settings, {key: value for key, value in protocol.items() if key != QUEUE}


def verified_run(folder, plan):
    import sibling_ttwu_queue as fixture

    mode = plan[QUEUE]
    context = trial.qualified_context(folder, plan)
    scheduler = fixture.verify(folder, plan, context["boots"])
    final = fixture.read_features(folder / fixture.FINAL, context["boots"]["A"])
    ordinary = read(folder, "fair-scheduler.json")
    invariants = scheduler_invariants(mode, scheduler["initial"], scheduler["features"], final["features"], ordinary)
    last_wave, stock_proof = stock.verify_stock(folder, plan, context)
    mapping = trial.check_mapping(folder, context, WINDOW, last_wave=last_wave)
    with patch.object(trial, "launch_view", return_value=launch_view(mode)):
        run, rows = trial.replay_paced(folder, plan, context)
    worker = run["worker"]
    require(worker["scheduler"] == ordinary and run["boot"] == scheduler["boot_id"],
            "raw paced replay disagrees with the live TTWU feature or boot")
    result = trial.run_identity(folder, plan, context, run, rows)
    result["worker_invariants"] = {key: value for key, value in worker.items() if key != "scheduler"} | invariants
    result["receipt"].update(native_scheduler={"boot": scheduler, "final": final, "ordinary": ordinary},
                             stock_builds=stock_proof, off_timing_go_mapping=mapping)
    return result


def relative_change(windows, metric):
    observations = [(on["A"][metric], on["B"][metric], off["A"][metric], off["B"][metric])
                    for on, off in zip(windows["on"], windows["off"], strict=True)]
    if any(not (on_a and on_b and off_b) for on_a, on_b, _, off_b in observations):
        return None
    return median((off_a / off_b) / (on_a / on_b) for on_a, on_b, off_a, off_b in observations)


def paired_results(windows):
    within_mode = {mode: SHARED.outcomes([wave["B"] for wave in rows], [wave["A"] for wave in rows], ("orbstack", "micropod"))
                   for mode, rows in windows.items()}
    within_engine = {engine: SHARED.outcomes([wave[arm] for wave in windows["on"]], [wave[arm] for wave in windows["off"]], MODES)
                     for arm, engine in SHARED.ENGINES.items()}
    relative = {metric: relative_change(windows, metric) for metric in MAIN_METRICS}
    return {"within_mode": within_mode, "within_engine": within_engine, "median_paired_native_to_peer_ratio_change": relative}


def summarize(verified):
    by_seed, pooled = [], {mode: [] for mode in MODES}
    for seed, order in SEED_ORDER.items():
        boot = {mode: verified[seed, mode] for mode in MODES}
        rows = {mode: row["rows"] for mode, row in boot.items()}
        first, later = (boot[mode]["receipt"]["admission"] for mode in order)
        require(docker_time_ns(first["last_utc"]) < docker_time_ns(later["first_utc"]),
                "TTWU queue crossover reversed its preselected boot order")
        require(len(rows["on"]) == len(rows["off"]) == SHARED.ROUNDS and
                [wave["order"] for wave in rows["on"]] == [wave["order"] for wave in rows["off"]],
                "TTWU queue crossover changed the observed paired engine order")
        result = paired_results(rows)
        by_seed.append({
            "seed": seed, "boot_order": list(order), "engine_order": [wave["order"] for wave in rows["on"]],
            "boots": {mode: boot[mode]["receipt"] for mode in MODES},
            "native_beats_peer_on_both_medians": {
                mode: all(view["metrics"][metric]["micropod"] < view["metrics"][metric]["orbstack"]
                          for metric in SHARED.WIN_METRICS) for mode, view in result["within_mode"].items()},
            "median_off_minus_on": {
                engine: {metric: view["metrics"][metric]["off"] - view["metrics"][metric]["on"] for metric in MAIN_METRICS}
                for engine, view in result["within_engine"].items()},
            **result,
        })
        for mode in MODES:
            pooled[mode].extend(rows[mode])

    require(all(len({tuple(boot["rows"][block][arm]["build"]["products"]) for boot in verified.values()
                     for arm in SHARED.ENGINES}) == 1 for block in range(SHARED.ROUNDS)),
            "TTWU queue crossover changed build artifacts between boots")
    engine_windows = [wave[arm] for rows in pooled.values() for wave in rows for arm in SHARED.ENGINES]
    return {
        "matched_boot_pairs": len(by_seed), "native_boots": len(verified), "rounds_per_boot": SHARED.ROUNDS,
        "paired_engine_windows": len(engine_windows) // 2, "engine_windows": len(engine_windows),
        "offered_rps": SHARED.RATE, "offer_duration_ns": PACED.OFFER_NS, "fault_around_bytes": WINDOW,
        "offered_requests": sum(wave["offered_requests"] for wave in engine_windows),
        "completed_requests": sum(wave["requests"] for wave in engine_windows),
        "build_jobs": sum(wave["build"]["jobs"] for wave in engine_windows),
        "build_revisions": sum(wave["build"]["revisions"] for wave in engine_windows),
        "test_passes": sum(wave["build"]["test_passes"] for wave in engine_windows),
        "minimum_first_build_end_margin_ns": min(wave["first_build_end_margin_ns"] for wave in engine_windows),
        "native_beats_peer_on_both_medians_each_seed": {
            mode: all(seed["native_beats_peer_on_both_medians"][mode] for seed in by_seed) for mode in MODES},
        "seeds_with_lower_off_median": {
            engine: {field: sum(seed["median_off_minus_on"][engine][field] < 0 for seed in by_seed) for field in MAIN_METRICS}
            for engine in SHARED.ENGINES.values()},
        "by_seed": by_seed, **paired_results(pooled),
    }


def matched_identity(verified):
    runs = list(verified.values())
    first = runs[0]
    require(len({row["run"]["boot"] for row in runs}) == len(runs) and len({row["run"]["peer_boot"] for row in runs}) == 1 and
            all(row["run"]["boot"] != row["run"]["peer_boot"] for row in runs),
            "TTWU queue crossover reused a native boot or changed the OrbStack guest")
    require(len(set().union(*(row["ids"] for row in runs))) == len(runs) * 4 * PACED.PAIRS and
            len({row["receipt"]["native_volume"]["volume_uuid"] for row in runs}) == len(runs),
            "TTWU queue crossover reused measured containers or an APFS worker volume")
    identity = ("worker_invariants", "compiler_executables", "launch")
    require(all(all(row[key] == first[key] for key in identity) and row["run"]["images"] == first["run"]["images"]
                for row in runs), "TTWU queue crossover changed other scheduler settings, worker, toolchain, admission or images")
    intervals = sorted((docker_time_ns(row["receipt"]["admission"]["first_utc"]),
                        docker_time_ns(row["receipt"]["admission"]["last_utc"])) for row in runs)
    require(all(end < start for (_, end), (start, _) in zip(intervals, intervals[1:])), "TTWU queue scopes overlapped")
    slacks = {engine: {value for row in runs for wave in row["rows"] for value in wave[arm]["timer_slack_ns"]}
              for arm, engine in SHARED.ENGINES.items()}
    require(all(len(values) == 1 for values in slacks.values()), "TTWU queue crossover changed issuing thread timer slack")
    return {"worker_invariants": first["worker_invariants"], "images": first["run"]["images"],
            "compiler_executables": first["compiler_executables"], "peer_boot": first["run"]["peer_boot"],
            "issuing_timer_slack_ns": {engine: values.pop() for engine, values in slacks.items()}}


def compare(folders):
    """Replay four completed directory archives in the two prespecified boot pairs."""
    paths = [Path(folder).resolve() for folder in folders]
    keys = {(seed, mode) for seed, order in SEED_ORDER.items() for mode in order}
    require(len(paths) == len(set(paths)) == len(keys), "TTWU queue crossover needs four distinct completed directories")
    product, packaged = trial.check_product()
    archives, scopes, common = {}, set(), None
    for folder in paths:
        plan = read(folder, "plan.json")
        key, settings, protocol = validated_archive(folder, plan, product, packaged)
        scope = Path(plan["scope"]).resolve()
        require(key not in archives and key in keys and scope not in scopes, "duplicate or unexpected TTWU queue seed, mode or scope")
        if common is None:
            common = (settings, protocol)
        require((settings, protocol) == common, "TTWU queue crossover changed a signed input or stock workload setting")
        archives[key] = folder, plan
        scopes.add(scope)
    require(archives.keys() == keys, "TTWU queue crossover is missing a preselected boot")
    verified = {key: verified_run(folder, plan) for key, (folder, plan) in archives.items()}
    settings, protocol = common
    first = next(iter(verified.values()))
    return {"signed_product": product["current_product"], "kernel": product["kernel"], "placements": trial.signed.PLACEMENT,
            "protocol_sha256": SHARED.fingerprint([protocol, first["launch"]]),
            "signed_settings_sha256": SHARED.fingerprint(settings), **matched_identity(verified), **summarize(verified)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folders", nargs=4, type=Path)
    print(json.dumps(compare(parser.parse_args().folders), indent=2, allow_nan=False))
