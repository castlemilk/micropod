"""Replay the prespecified native 500,000 ns versus 62,500 ns CI crossover."""

import argparse
from hashlib import sha256
import json
from pathlib import Path
from statistics import median
from unittest.mock import patch

from qualify import require, terminal
from sibling_results import docker_time_ns, read
import sibling_file_fault_around_holdout_results as stock
import sibling_file_fault_around_results as trial
import sibling_http_response_phases as phases
import sibling_log_notification_http_phases as slot_phases
import sibling_log_notification_results as notify
import sibling_output_polling as follower
from sibling_ttwu_queue_results import feature_vector


HERE = Path(__file__).resolve().parent
CONTROL, CANDIDATE = MODES = (500_000, 62_500)
ORDERS = {250283: MODES, 250287: MODES[::-1]}
WINDOW = trial.VALUES[0]
STOCK_SEEDS = {seed: (WINDOW,) for seed in ORDERS}
SHARED, PACED, POLLING = trial.shared, trial.paced, notify.polling
MODE = "migration_cost_ns"
SOURCE_FIELD = "migration_cost_sources"
PRODUCT_SHA256 = "fb8ac000ac36940926475d22f6fbb5c6a2b39d9face4f28ed690771aad49aa8c"
MANIFEST = notify.fixture.MANIFEST
STAGED = "sched-migration-cost-staged.sh"
PHASES = ("boot", "before", "after")
METRICS = ("p95_us", "p99_us", "service_p95_us", "build_makespan_s")
# The staged facts bytes are ordinary guest facts, the stock tmpfs hook, the
# same root observer and the single pre-API apply command with its numeric value.
STAGED_SHA256 = {CONTROL: "3e26d99e1cc59643152d60e5bb98668c0d5d840a7ca1800687cb899159daf9ac",
                 CANDIDATE: "ed328fe2f7c6b347cffba1a79492bfa45c48830b111e951de30605116cce71ad"}
PINNED_SOURCES = {
    "sched-migration-cost.sh": "70b2f4b4eab81eb3a3271e018b31aeeb8f73b58778ba05ca2afead430cb4434d",
    "sibling_migration_cost.py": "1ab3cc8c339e099c0006aa957293a33cd6c68654b1c8103c1f8403cdf8029572",
    follower.RUNNER_READ: "f8bc41a967cdc473bfd77792293e49c167b8e7e549cdd275446ab204fd5f0277",
}
OBSERVER_SHA256 = "eb2b861178615631ac235386ca40342a19a8f435361b53f8d9d85c4b853d74df"
FAIR_HOOK_SHA256 = "46f3d614d832318b55d3e877afdcc3aaff6fa53a1dbf36c51c181e5929649c15"
CONFLICTS = {"ttwu_queue", "ttwu_diagnostic", "log_notification", "output_polling", "compiler_affinity", "compiler_runtime",
             "build_slices", "midwindow_probes", "socket_sched_trace", "timer_counters", "job_network_smoke", "ipam_route"}


def scheduler_readbacks(raw, boot, selected, fair):
    require(set(raw) == set(PHASES) and type(selected) is int and selected in MODES,
            "migration-cost replay is missing a scheduler readback")
    expected = feature_vector(fair["before"])
    require(fair["setting"] == "inherit" and fair["before"] == fair["after"] and fair["base_slice_ns"] == 250_000 and
            fair["clocksource"] == "arch_sys_counter" and
            {"HRTICK", "NEXT_BUDDY", "PICK_BUDDY", "TTWU_QUEUE"} <= expected,
            "migration-cost crossover changed another effective scheduler setting")
    rows = {}
    for phase in PHASES:
        pairs = [line.split("=", 1) for line in raw[phase].splitlines()]
        require(len(pairs) == 5 and all(len(pair) == 2 for pair in pairs), f"invalid migration-cost {phase} receipt")
        row = dict(pairs)
        require(set(row) == {"boot_id", "initial_ns", "effective_ns", "base_slice_ns", "features"} and
                row["boot_id"] == boot and row["base_slice_ns"] == "250000" and row["effective_ns"] == str(selected) and
                row["initial_ns"] == str(CONTROL if phase == "boot" else selected) and
                feature_vector(row["features"].split()) == expected,
                f"wrong boot, threshold, slice or scheduler features in migration-cost {phase} receipt")
        rows[phase] = row
    require(rows["before"] == rows["after"], "migration-cost scheduler readback changed across measured work")
    return rows


def validated_archive(folder, plan, manifest, arm):
    selected = plan.get(MODE)
    require(read(folder, "status.json") == {"complete": True}, f"incomplete migration-cost archive {folder.name}")
    require(type(selected) is int and selected in ORDERS.get(plan.get("seed"), ()) and
            "-sibling-migration-cost-" in folder.name and plan[trial.TREATMENT] == WINDOW and
            plan["migration_cost_product_sha256"] == arm["product_sha256"] == PRODUCT_SHA256 and
            not CONFLICTS.intersection(plan), "unexpected migration-cost seed, threshold, product or second intervention")
    require((folder / MANIFEST).read_bytes() == manifest and
            (folder / "worker-build.json").read_bytes() == arm["path"].read_bytes(),
            "migration-cost crossover did not archive the exact sealed worker")

    observer_bytes = (folder / trial.hierarchy.BOOT_HOOK).read_bytes()
    expected_sources = {**PINNED_SOURCES, MANIFEST: sha256(manifest).hexdigest(), STAGED: STAGED_SHA256[selected]}
    require(plan[SOURCE_FIELD] == expected_sources and
            all(terminal.digest(folder / name) == digest for name, digest in expected_sources.items()) and
            sha256(observer_bytes).hexdigest() == OBSERVER_SHA256 and plan["fair_hook_sha256"] == FAIR_HOOK_SHA256,
            "migration-cost sources changed outside the exact preregistered threshold command")
    with patch.object(stock, "SEED_ORDER", STOCK_SEEDS), patch.object(trial.fixture, "boot_hook", return_value=observer_bytes.decode()):
        (seed, _), settings, protocol = stock.validated_archive(folder, plan, arm["manifest"], arm["package"])
    package, job, *_ = settings
    require(job["ProgramArguments"] == [package["worker_executable"], "ci", "serve"],
            "native job selected a different signed worker")
    init = [line for line in (folder / "a/service.stderr").read_text().splitlines()
            if line.startswith("using ghcr.io/apple/containerization/vminit:")]
    require(len(init) == 1, "missing or ambiguous native vminit selection")
    return (seed, selected), [*settings, init[0]], {**{key: value for key, value in protocol.items() if key != MODE},
                                                  SOURCE_FIELD: {name: digest for name, digest in expected_sources.items() if name != STAGED}}


def admission_rows(folder):
    return tuple([json.loads(line) for line in (folder / name).read_text().splitlines()]
                 for name in ("admission.jsonl", "orb-inventory.jsonl"))


def reconcile_post_work_sample(host, peer, ids, first, last, after):
    require(len(host) == len(peer) + 1 and len(peer) > 1 and all(row["blockers"] == [] for row in host),
            "migration-cost admission has more than one missing peer sample or a reported blocker")
    require(len(ids) == 2 * PACED.PAIRS and
            all(len(row["running"]) == len(set(row["running"])) and set(row["running"]) <= ids for row in peer),
            "migration-cost admission included unknown or repeated peer objects")
    clocks = [(docker_time_ns(a["utc"]), docker_time_ns(b["time"])) for a, b in zip(host[:-1], peer, strict=True)]
    orphan = docker_time_ns(host[-1]["utc"])
    require(all(0 < start <= finish for start, finish in clocks) and
            all(finish < start for (_, finish), (start, _) in zip(clocks, clocks[1:])) and
            clocks[0][1] < first <= last < clocks[-1][1] < orphan and last < after < orphan,
            "the unmatched host admission sample or missing peer observation could overlap measured work")
    return {"first_utc": host[0]["utc"], "last_utc": host[-1]["utc"], "samples": len(peer),
            "full_peer_cohort_samples": sum(set(row["running"]) == ids for row in peer),
            "post_work_host_sample": host[-1], "last_paired_peer_sample": peer[-1],
            "last_scored_host_finish_unix_ns": last, "post_work_capture_finished_unix_ns": after}


def check_admission(folder, inventory):
    host, peer = admission_rows(folder)
    if len(host) == len(peer):
        return POLLING.STRICT_ADMISSION(folder, inventory)
    plan = read(folder, "plan.json")
    POLLING.check_retirement_cleanup(folder, plan)
    before, after = (read(folder, f"job-parent-{phase}.json") for phase in ("before", "after"))
    first, last = stock.check_host_windows(read(folder, stock.WINDOWS), plan["seed"], before["host_finished_unix_ns"],
                                          after["host_started_unix_ns"])
    return reconcile_post_work_sample(host, peer, {job["id"] for job in inventory["B"]["jobs"]}, first, last,
                                      after["host_finished_unix_ns"])


def check_admitted_span(folder, context, last):
    windows = read(folder, stock.WINDOWS)
    first = windows[0]["host_started_unix_ns"]
    host, peer = admission_rows(folder)
    ids = {job["id"] for job in context["inventory"]["B"]["jobs"]}
    pairs = [(docker_time_ns(a["utc"]), docker_time_ns(b["time"]), set(b["running"]))
             for a, b in zip(host[:len(peer)], peer, strict=True)]
    in_work = [running for start, finish, running in pairs if finish >= first and start <= last]
    require(pairs[0][1] < first <= last < pairs[-1][1] and in_work and all(running == ids for running in in_work),
            "migration-cost admission lacked a matched full peer cohort during timed work")
    dense = [{"round": wave["block"], "arm": wave["arm"],
              "samples": sum(wave["host_started_unix_ns"] <= start <= finish <= wave["host_finished_unix_ns"]
                             and running == ids for start, finish, running in pairs)} for wave in windows if wave["mode"] == "all"]
    require(len(dense) == 2 * SHARED.ROUNDS and all(row["samples"] for row in dense),
            "a dense engine window lacks a matched full-cohort admission sample")
    return dense


def verified_run(folder, plan, arm):
    with patch.object(SHARED, "check_admission", check_admission):
        context = trial.qualified_context(folder, plan)
    boot = context["boots"]["A"]
    before, after = [follower.engine_readback(folder / follower.readback_name(phase), boot, arm["runner_sha256"])
                     for phase in ("before", "after")]
    require(before == after, "sealed native engine restarted or changed during the migration-cost run")
    fair = read(folder, "fair-scheduler.json")
    scheduler = scheduler_readbacks({phase: (folder / f"sched-migration-cost-{phase}.txt").read_text() for phase in PHASES},
                                    boot, plan[MODE], fair)
    last, script_proof = stock.verify_stock(folder, plan, context)
    peer_samples = check_admitted_span(folder, context, last)
    admission = context["admission"]
    if "post_work_host_sample" in admission:
        require(docker_time_ns(admission["last_utc"]) < context["volume"]["post_observed_unix_ns"],
                "unmatched post-work host sample is outside the worker volume lifetime")
    mapping = trial.check_mapping(folder, context, WINDOW, last_wave=last)
    collector = slot_phases.SlotCollector(folder)
    with patch.object(PACED, "read_wire", collector.read_wire):
        run, rows = trial.replay_paced(folder, plan, context)
    require(run["worker"]["scheduler"] == fair and run["worker"]["guest"] == before["runner_sha256"] and
            collector.breakdown.keys() == collector.slots.keys() == set(range(SHARED.ROUNDS)) and not collector.pending,
            "raw phase replay disagrees with the native scheduler, engine or measured wave count")
    for index, row in enumerate(rows):
        for letter, engine in SHARED.ENGINES.items():
            witness = collector.breakdown[index]["all"]["service_p95_request"][engine]["duration_ns"]["total"]
            require(witness / 1000 == row[letter]["service_p95_us"], "raw post-dispatch phase witness disagrees with scored p95")

    result = trial.run_identity(folder, plan, context, run, rows)
    result["worker_invariants"] = run["worker"]
    result["receipt"].update(native_engine=before, migration_cost_readbacks=scheduler, stock_builds=script_proof,
                             off_timing_go_mapping=mapping, full_peer_samples_per_dense_window=peer_samples,
                             staged_facts_sha256=STAGED_SHA256[plan[MODE]], raw_http_gzip_sha256=collector.hashes,
                             plan_sha256=terminal.digest(folder / "plan.json"))
    result["phases"] = [{"groups": collector.breakdown[index]} for index in range(SHARED.ROUNDS)]
    result["slots"] = [collector.slots[index] for index in range(SHARED.ROUNDS)]
    return result


def peer_adjusted_rows(rows):
    matches = list(zip(rows[CONTROL], rows[CANDIDATE], strict=True))
    result = {}
    for metric in METRICS:
        scale = 1_000 if metric.endswith("_us") else 1_000_000_000

        def gap(wave):
            return round(wave["A"][metric] * scale) - round(wave["B"][metric] * scale)

        deltas = [gap(candidate) - gap(control) for control, candidate in matches]
        result[metric] = {"median_paired_delta": median(deltas) / scale, "candidate_lower": sum(delta < 0 for delta in deltas),
                          "candidate_higher": sum(delta > 0 for delta in deltas), "tied": sum(delta == 0 for delta in deltas)}
    return result


def boundary_view(durations):
    return {"post_dispatch_ns": durations["total"],
            "before_first_byte_ns": sum(durations[part] for part in phases.PHASES[:3]),
            "after_first_byte_ns": durations["first_byte_to_completion"]}


def phase_view(runs):
    group = phases.pool([wave for run in runs for wave in run["phases"]])["groups"]
    roles = slot_phases.slot_summary([wave for run in runs for wave in run["slots"]])["roles"]
    results = {}
    for role in phases.GROUPS:
        calls = group[role]["all_calls"]
        result = {engine: boundary_view({key: value / calls[engine]["requests"] for key, value in calls[engine]["sum_ns"].items()})
                  for engine in SHARED.ENGINES.values()}
        results[role] = {"all_calls": {"requests_per_engine": calls["micropod"]["requests"], **result,
                                       "micropod_minus_orbstack": boundary_view(calls["micropod_minus_orbstack_mean_ns"])},
                         "same_slot_near_p95": {"matched_offers": roles[role]["matched_offers"],
                                                "micropod_minus_orbstack": boundary_view(
                                                    roles[role]["equal_slot_micropod_minus_orbstack_mean_ns"])},
                         "median_window_post_dispatch_p95_ns": group[role]["median_p95_ns"]}
    return results


def scope_scores(measured, seeds):
    cohorts = {mode: [measured[seed, mode] for seed in seeds] for mode in MODES}
    phases_by_mode = {mode: phase_view(runs) for mode, runs in cohorts.items()}
    a, b = (phases_by_mode[mode] for mode in MODES)
    changes = {role: {engine: {field: b[role]["all_calls"][engine][field] - value
                              for field, value in a[role]["all_calls"][engine].items()}
                      for engine in (*SHARED.ENGINES.values(), "micropod_minus_orbstack")} for role in phases.GROUPS}
    paired_rows = {mode: [row for run in runs for row in run["rows"]] for mode, runs in cohorts.items()}
    return {"peer_adjusted_timing": peer_adjusted_rows(paired_rows),
            "response_phases": {"by_mode": phases_by_mode, "all_calls_candidate_minus_control_ns": changes}}


def compare(folders, *, manifest=HERE / MANIFEST):
    """Independently verify and replay the four prespecified migration-cost boots."""
    paths = [Path(folder).resolve() for folder in folders]
    expected = {(seed, mode) for seed, order in ORDERS.items() for mode in order}
    require(len(paths) == len(set(paths)) == len(expected), "migration-cost crossover needs four distinct completed archives")
    manifest_bytes, kit, arms = notify.check_packages(manifest)
    arm = arms["notify"]
    archives, scopes, common = {}, set(), None
    for folder in paths:
        require((folder / "plan.json").is_file(), f"migration-cost archive lacks a measured plan {folder.name}")
        plan = read(folder, "plan.json")
        key, settings, protocol = validated_archive(folder, plan, manifest_bytes, arm)
        scope = Path(plan["scope"]).resolve()
        require(key in expected and key not in archives and scope not in scopes, "duplicate or unexpected migration-cost boot or scope")
        require(common is None or common == (settings, protocol), "migration-cost crossover changed an independent workload input")
        common = settings, protocol
        archives[key] = folder, plan
        scopes.add(scope)
    require(archives.keys() == expected, "migration-cost crossover lacks a preselected boot")

    measured = {key: verified_run(folder, plan, arm) for key, (folder, plan) in archives.items()}
    identity = POLLING.matched_identity(measured)
    scores = POLLING.summarize(measured, modes=MODES, orders=ORDERS)
    for seed in scores["by_seed"]:
        seed.update(scope_scores(measured, (seed["seed"],)))
    settings, protocol = common
    return {"control_ns": CONTROL, "candidate_ns": CANDIDATE, "product": str(arm["path"]),
            "product_sha256": arm["product_sha256"], "runner_sha256": arm["runner_sha256"],
            "manifest_sha256": sha256(manifest_bytes).hexdigest(), "kernel": kit["kernel"], "vminit_selection": settings[-1],
            "signed_settings_sha256": SHARED.fingerprint(settings),
            "protocol_sha256": SHARED.fingerprint([protocol, next(iter(measured.values()))["launch"]]),
            "placements": trial.signed.PLACEMENT,
            "methods": {"pairing": "Engine A/B within round; threshold contrast paired by seed and round. Lower times win, ties separate.",
                        "peer_adjusted_delta": "Candidate native-minus-peer time minus control native-minus-peer time for the same seed and round.",
                        "replication": "Two independent native boots per threshold; four measured waves per boot.",
                        "all_calls": "Equal complete set of offered slots and ordinals in all four cells of each pair.",
                        "same_slot_near_p95": "Equal client-slot weight; same offer ordinals selected by either engine's 94–96% post-dispatch rank band within slot and round. The band can select different offers across thresholds.",
                        "phase_boundaries": "Client-observed dispatch through first-byte callback and then through validated response completion. Descriptive elapsed times include scheduling waits.",
                        "roles": "Slots 0–7 share the client container with a compiler job; slots 8–31 have no compiler job. Role is fixed by the stock fixture.",
                        "admission": "Every dense window contains at least one matched host and full owned peer observation. One unmatched blocker-free host row may follow the last wave, final matched peer row and post-work capture. Scoped teardown is verified separately."},
            **identity, **scores, **scope_scores(measured, ORDERS)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folders", nargs=4, type=Path)
    parser.add_argument("--manifest", type=Path, default=HERE / MANIFEST)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    data = json.dumps(compare(args.folders, manifest=args.manifest), indent=2, allow_nan=False) + "\n"
    if args.output is None:
        print(data, end="")
    else:
        with args.output.open("x") as output:
            output.write(data)
