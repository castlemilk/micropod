"""Replay post-dispatch HTTP phases for the qualified stock 64 KiB controls."""

import argparse
from collections import Counter
import gzip
from hashlib import sha256
import json
from pathlib import Path
import re
from statistics import median
from unittest.mock import patch

from qualify import require, terminal
from sibling_results import read
import sibling_file_fault_around_holdout_results as holdout
import sibling_file_fault_around_results as trial
import sibling_ttwu_queue_results as queue


HERE = Path(__file__).resolve().parent
STUDIES = (("stock_holdout", "sibling-file-fault-around-holdout.json", "64KiB", holdout.SEED_ORDER, holdout),
           ("ttwu_queue", "sibling-ttwu-queue-results.json", "on", queue.SEED_ORDER, queue))
PACED, SHARED = trial.paced, trial.shared
ENGINES = SHARED.ENGINES
PHASES = ("dispatch_to_got_conn", "got_conn_to_wrote_request", "wrote_request_to_first_byte", "first_byte_to_completion")
COMPONENTS = ("total", *PHASES)
ROLES = ("builders", "service_only")
GROUPS = ("all", *ROLES)
SELECTIONS = ("all_calls", "own_p95_band", "own_slowest_5pct", "same_offers_slowest_5pct_union")
RUNNER_SELECTIONS = ("own_p95_band", "same_offers_slowest_5pct_union")
DENSE = re.compile(r"grouped-([0-3])-all-([AB])")


def sample_phases(sample, arrival):
    g, w, b, t = (sample[key] for key in ("got_conn_ns", "wrote_request_ns", "first_response_byte_ns", "total_ns"))
    require(all(type(value) is int for value in (g, w, b, t)) and 0 < g <= w <= b <= t and
            t == arrival["completion_offset_ns"] - arrival["dispatch_offset_ns"], "invalid post-dispatch phase timestamps")
    return t, g, w - g, b - w, t - b


def phase_rows(rows):
    size = SHARED.OFFERED
    require([row["index"] for row in rows] == list(range(PACED.PAIRS)), "missing or reordered HTTP client slots")
    result = [None] * size
    for slot, row in enumerate(rows):
        receipt = row["receipt"]
        require(receipt["pace"]["slot"] == slot, "paced slot identity changed in HTTP phase replay")
        for ordinal, arrival, sample in zip(range(slot, size, PACED.PAIRS), receipt["pace"]["arrivals"], receipt["samples"], strict=True):
            require(arrival["due_offset_ns"] == PACED.due_offset(ordinal, SHARED.RATE), "offered ordinal or due time changed")
            result[ordinal] = sample_phases(sample, arrival)
    return result


def group_ordinals(size, group):
    if group == "all":
        return range(size)
    return [ordinal for ordinal in range(size) if (ordinal % PACED.PAIRS < PACED.BUILDERS) == (group == "builders")]


def summarize_selection(samples, ordinals):
    builder_offers = sum(ordinal % PACED.PAIRS < PACED.BUILDERS for ordinal in ordinals)
    totals = tuple(sum(samples[ordinal][column] for ordinal in ordinals) for column in range(len(COMPONENTS)))
    require(totals[0] == sum(totals[1:]), "selected HTTP phases do not sum to total duration")
    return {"requests": len(ordinals), "builder_requests": builder_offers,
            "sum_ns": dict(zip(COMPONENTS, totals, strict=True))}


def mean_difference(samples_a, samples_b):
    n, m = samples_a["requests"], samples_b["requests"]
    native, peer = samples_a["sum_ns"], samples_b["sum_ns"]
    return {name: (native[name] * m - peer[name] * n) / (n * m) for name in COMPONENTS}


def contrast(samples_a, samples_b):
    return {"micropod": samples_a, "orbstack": samples_b, "micropod_minus_orbstack_mean_ns": mean_difference(samples_a, samples_b)}


def witness(samples, rank, sorted_offers):
    ordinal = sorted_offers[rank - 1]
    return {"offer_ordinal": ordinal, "client_slot": ordinal % PACED.PAIRS,
            "duration_ns": dict(zip(COMPONENTS, samples[ordinal], strict=True))}


def compare_group(native, peer, group):
    ordinals = group_ordinals(len(native), group)
    n = len(ordinals)
    p95 = (95 * n + 99) // 100
    band = slice(94 * n // 100, 96 * n // 100)
    ranked_a = sorted(ordinals, key=lambda ordinal: native[ordinal][0])
    ranked_b = sorted(ordinals, key=lambda ordinal: peer[ordinal][0])
    tail_a, tail_b = ranked_a[p95:], ranked_b[p95:]
    union = sorted(set(tail_a) | set(tail_b))
    rank_a, rank_b = witness(native, p95, ranked_a), witness(peer, p95, ranked_b)
    selections = ((ordinals, ordinals), (ranked_a[band], ranked_b[band]), (tail_a, tail_b), (union, union))
    return {
        "service_p95_request": {"micropod": rank_a, "orbstack": rank_b},
        "service_p95_gap_ns": rank_a["duration_ns"]["total"] - rank_b["duration_ns"]["total"],
        "joint_slowest_5pct_requests": len(set(tail_a) & set(tail_b)),
        **{name: contrast(summarize_selection(native, selected_a), summarize_selection(peer, selected_b))
           for name, (selected_a, selected_b) in zip(SELECTIONS, selections, strict=True)},
    }


class TraceCollector:
    def __init__(self, folder):
        self.folder = folder
        self.pending = {}
        self.breakdown = {}
        self.hashes = {}

    def compare_pair(self, block, pair):
        return {group: compare_group(pair["A"], pair["B"], group) for group in GROUPS}

    def read_wire(self, folder, tag):
        require(folder == self.folder, "HTTP phase collector received an unrelated archive")
        name = f"{tag}.json.gz"
        compressed = (folder / name).read_bytes()
        digest = sha256(compressed).hexdigest()
        require(self.hashes.setdefault(name, digest) == digest, "raw HTTP archive changed during replay")
        rows = json.loads(gzip.decompress(compressed))
        match = DENSE.fullmatch(tag)
        if match:
            block, arm = int(match[1]), match[2]
            pair = self.pending.setdefault(block, {})
            require(arm not in pair and block not in self.breakdown, "arbitrary replay repeated a dense engine wave")
            pair[arm] = phase_rows(rows)
            if set(pair) == set(ENGINES):
                self.breakdown[block] = self.compare_pair(block, pair)
                del self.pending[block]
        return rows


def pooled_stats(selections):
    return {"requests": sum(s["requests"] for s in selections), "builder_requests": sum(s["builder_requests"] for s in selections),
            "sum_ns": {key: sum(s["sum_ns"][key] for s in selections) for key in COMPONENTS}}


def pool(waves):
    groups = {}
    for group in GROUPS:
        pairs = [wave["groups"][group] for wave in waves]
        groups[group] = {
            "median_p95_ns": {engine: median(pair["service_p95_request"][engine]["duration_ns"]["total"] for pair in pairs)
                              for engine in ENGINES.values()},
            "median_paired_p95_gap_ns": median(pair["service_p95_gap_ns"] for pair in pairs),
            "waves_with_higher_native_p95": sum(pair["service_p95_gap_ns"] > 0 for pair in pairs),
            "joint_slowest_5pct_requests": sum(pair["joint_slowest_5pct_requests"] for pair in pairs),
        }
        for selection in SELECTIONS:
            groups[group][selection] = contrast(*(pooled_stats([pair[selection][engine] for pair in pairs]) for engine in ENGINES.values()))
    # Keep the two role-specific rank selections at their offered 8:24 mix.
    fixed_mix = {selection: {name: (groups["builders"][selection]["micropod_minus_orbstack_mean_ns"][name] +
                                     3 * groups["service_only"][selection]["micropod_minus_orbstack_mean_ns"][name]) / 4
                             for name in COMPONENTS} for selection in ("own_p95_band", "own_slowest_5pct")}
    return {"paired_waves": len(waves), "groups": groups, "fixed_8_to_24_role_mix_mean_gap_ns": fixed_mix}


def replay_qualified_boot(folder, case, plan, expected, reference, replay, extra_receipts=(), *, collector=None):
    if collector is None:
        collector = TraceCollector(folder)
    with patch.object(PACED, "read_wire", collector.read_wire):
        measured = replay()
    run = measured["run"]
    scheduler = run["worker"]["scheduler"]
    require(scheduler["base_slice_ns"] == 250_000 and scheduler["before"] == scheduler["after"] and
            "TTWU_QUEUE" in scheduler["after"] and "NO_TTWU_QUEUE" not in scheduler["after"],
            "HTTP phases require the ordinary enabled TTWU queue scheduler")
    actual = measured["receipt"]
    receipts = ("archive", "native_boot", "peer_boot", "native_volume", "windows", *extra_receipts)
    require(all(actual[name] == expected[name] for name in receipts) and
            run["images"] == reference["images"] and run["placements"] == reference["placements"] and
            run["plan"]["pages"]["kernel_image_sha256"] == reference["kernel"]["image_sha256"] and
            measured["compiler_executables"] == reference["compiler_executables"],
            "raw HTTP or build replay disagrees with the previously scored worker")
    require(not collector.pending and collector.breakdown.keys() == set(range(SHARED.ROUNDS)), "incomplete paired HTTP phase replay")
    waves = []
    for index, wave in enumerate(measured["rows"]):
        groups = collector.breakdown[index]
        require(all(groups["all"]["service_p95_request"][engine]["duration_ns"]["total"] / 1_000 == wave[arm]["service_p95_us"]
                    for arm, engine in ENGINES.items()), "post-dispatch p95 witness differs from independent paced replay")
        waves.append({"round": index, "engine_order": wave["order"], "groups": groups,
                      "builds": {engine: {"jobs": wave[arm]["build"]["jobs"], "makespan_s": wave[arm]["build_makespan_s"],
                                         "first_build_end_margin_ns": wave[arm]["first_build_end_margin_ns"]}
                                 for arm, engine in ENGINES.items()}})
    result = {"study_key": case, "archive": folder.name, "native_boot": run["boot"], "peer_boot": run["peer_boot"],
            "scope": plan["scope"], "native_volume_uuid": actual["native_volume"]["volume_uuid"], "worker": run["worker"],
            "images": run["images"], "placements": run["placements"], "launch": measured["launch"], "containers": measured["ids"],
            "compiler_executables": measured["compiler_executables"], "signed_settings_sha256": reference["signed_settings_sha256"],
            "raw_http_gzip_sha256": collector.hashes, "plan_sha256": terminal.digest(folder / "plan.json"),
            "waves": waves, "summary": pool(waves)}
    return result, measured


def qualify_boot(folder, case, expected, reference, manifest, packaged, adapter):
    plan = read(folder, "plan.json")
    key, settings, _ = adapter.validated_archive(folder, plan, manifest, packaged)
    require(key == case and reference["signed_product"] == manifest["current_product"] and
            reference["signed_settings_sha256"] == SHARED.fingerprint(settings), "stock performance reference and signed inputs differ")
    result, _ = replay_qualified_boot(folder, case, plan, expected, reference, lambda: adapter.verified_run(folder, plan))
    return result


def report(archive_root=HERE):
    archive_root = Path(archive_root).resolve()
    manifest, packaged = trial.check_product()
    known, runs = {}, []
    for study, name, treatment, expected_seeds, adapter in STUDIES:
        raw = (archive_root / name).read_bytes()
        reference = json.loads(raw)
        known[study] = {"file": name, "sha256": sha256(raw).hexdigest()}
        seeds = reference["by_seed"]
        require(len(seeds) == len(expected_seeds) and {boot["seed"] for boot in seeds} == expected_seeds.keys(),
                "stock performance reference lacks the expected prespecified seeds")
        mode = trial.VALUES[0] if adapter is holdout else "on"
        for seed in seeds:
            expected = seed["boots"][treatment]
            name = expected["archive"]
            require(Path(name).name == name, "stock control reference contains an invalid archive name")
            run = qualify_boot(archive_root / name, (seed["seed"], mode), expected, reference, manifest, packaged, adapter)
            runs.append({"study": study, **run})

    require(all(len({run[field] for run in runs}) == len(runs) for field in ("native_boot", "archive", "scope", "native_volume_uuid")) and
            len({run["peer_boot"] for run in runs}) == 1 and
            len(set().union(*(run["containers"] for run in runs))) == len(runs) * 4 * PACED.PAIRS,
            "stock HTTP phase analysis reused a native boot, scope, volume or container or changed the peer")
    fields = ("worker", "images", "placements", "launch", "compiler_executables", "signed_settings_sha256")
    require(all(all(run[key] == runs[0][key] for key in fields) for run in runs), "production controls used different worker or workload inputs")
    aggregate = pool([wave for run in runs for wave in run["waves"]])
    robustness = {group: {selection: {phase: sum(run["summary"]["groups"][group][selection]
                                                ["micropod_minus_orbstack_mean_ns"][phase] > 0 for run in runs)
                                       for phase in COMPONENTS} for selection in SELECTIONS} for group in GROUPS}
    return {
        "sources": known, "signed_product": manifest["current_product"], "kernel": manifest["kernel"],
        "worker": runs[0]["worker"], "compiler_executables": runs[0]["compiler_executables"], "images": runs[0]["images"],
        "native_boots": len(runs), "peer_boot": runs[0]["peer_boot"], "offered_rps": SHARED.RATE,
        "client_slots": {"builders": PACED.BUILDERS, "service_only": PACED.PAIRS - PACED.BUILDERS},
        "selection": {"service_p95_request": "Nearest ranked observed call, with earlier offered ordinal first on ties.",
                      "own_p95_band": "Calls above rank 94% through rank 96%, selected independently within each arm and role.",
                      "own_slowest_5pct": "Calls strictly above the p95 rank, using rank order to break ties.",
                      "same_offers_slowest_5pct_union": "The same slot and offered ordinal in both arms, selected if either arm was in its slowest 5%.",
                      "phase_gaps": "Differences of means over each selection. The phase gaps sum to the selected mean total gap."},
        "aggregate": aggregate, "boots_with_positive_native_minus_peer_mean_gap": robustness,
        "runs": [{key: value for key, value in run.items() if key not in ("containers", "launch", *fields)} for run in runs],
    }


def runner_mode_summary(waves):
    view = pool(waves)
    for group in view["groups"].values():
        for unused in ("all_calls", "own_slowest_5pct"):
            del group[unused]
    del view["fixed_8_to_24_role_mix_mean_gap_ns"]["own_slowest_5pct"]
    return view


def runner_phase_change(stock, optimized):
    changes = {}
    for group in GROUPS:
        a, b = stock["groups"][group], optimized["groups"][group]
        changes[group] = {"median_p95_ns": {engine: b["median_p95_ns"][engine] - a["median_p95_ns"][engine]
                                            for engine in ENGINES.values()}}
        for selection in RUNNER_SELECTIONS:
            first, second = a[selection], b[selection]
            engine_changes = {engine: mean_difference(second[engine], first[engine]) for engine in ENGINES.values()}
            changes[group][selection] = {**engine_changes, "micropod_minus_orbstack": {
                part: engine_changes["micropod"][part] - engine_changes["orbstack"][part] for part in COMPONENTS}}
    return changes


def runner_report(archive_root=HERE):
    import sibling_output_polling_results as polling

    archive_root = Path(archive_root).resolve()
    source = archive_root / "sibling-output-polling-results.json"
    raw = source.read_bytes()
    reference = json.loads(raw)
    combined, combined_raw, arms = polling.check_products(archive_root / polling.products.MANIFEST)
    require(reference["product_manifest_sha256"] == sha256(combined_raw).hexdigest() and
            reference["products"] == combined["arms"], "runner phase replay used different sealed product arms")
    require(len(reference["by_seed"]) == len(polling.ORDERS) and
            {row["seed"] for row in reference["by_seed"]} == polling.ORDERS.keys(), "runner phase replay lacks prescribed seeds")
    runs, verified, common_protocol = {}, {}, None
    for seed in reference["by_seed"]:
        require(seed["boot_order"] == list(polling.ORDERS[seed["seed"]]), "runner phase reference changed the prespecified boot order")
        for mode in polling.MODES:
            expected = seed["boots"][mode]
            case = seed["seed"], mode
            name = expected["archive"]
            require(Path(name).name == name, "runner comparison contains an invalid archive name")
            folder = archive_root / name
            plan = read(folder, "plan.json")
            arm = arms[mode]
            key, settings, protocol = polling.validated_archive(folder, plan, combined, combined_raw, arm)
            require(key == case and SHARED.fingerprint(settings) == reference["signed_settings_sha256"] and
                    (common_protocol is None or protocol == common_protocol), "runner phase replay changed a stock workload or signed input")
            common_protocol = protocol
            extras = ("admission", "native_engine", "stock_builds", "fault_around_readback", "mode")
            run, measured = replay_qualified_boot(folder, case, plan, expected, reference,
                                                  lambda: polling.verified_run(folder, plan, combined, arm), extras)
            require(SHARED.fingerprint([protocol, measured["launch"]]) == reference["protocol_sha256"],
                    "runner phase replay changed actual container admission")
            runs[case], verified[case] = run, measured
    identity = polling.matched_identity(verified)
    require(all(identity[k] == reference[k] for k in identity), "runner replay changed measured worker or peer identity")
    verified_counts = polling.summarize(verified)
    counts = {key: verified_counts[key] for key in ("matched_boot_pairs", "native_boots", "paired_engine_windows", "completed_requests",
                                                   "build_jobs", "minimum_first_build_end_margin_ns")}
    require(all(reference[key] == value for key, value in counts.items()), "runner replay changed measured work")

    def paired_run(seeds):
        by_mode = {mode: runner_mode_summary([wave for seed in seeds for wave in runs[seed, mode]["waves"]]) for mode in polling.MODES}
        return {"by_mode": by_mode, "optimized_minus_stock_ns": runner_phase_change(by_mode["stock"], by_mode["optimized"])}

    inputs = []
    for run in runs.values():
        envelope = {field: run[field] for field in ("archive", "native_boot", "peer_boot", "native_volume_uuid", "plan_sha256", "raw_http_gzip_sha256")}
        inputs.append({"seed": run["study_key"][0], "mode": run["study_key"][1], **envelope,
                       "per_wave_p95_ns": [{"round": wave["round"], "engine_order": wave["engine_order"],
                                             **{engine: wave["groups"]["all"]["service_p95_request"][engine]["duration_ns"]["total"]
                                                for engine in ENGINES.values()}} for wave in run["waves"]]})
    return {
        "source_score": {"file": source.name, "sha256": sha256(raw).hexdigest()},
        "product_manifest_sha256": reference["product_manifest_sha256"], "runner_sha256": {mode: arm["runner_sha256"]
                                                                                          for mode, arm in reference["products"].items()},
        "protocol_sha256": reference["protocol_sha256"], "peer_boot": reference["peer_boot"], **counts,
        "offered_rps": SHARED.RATE,
        "selection": {"own_p95_band": "Post-dispatch ranks above 94% through 96% within each engine and role.",
                      "same_offers_slowest_5pct_union": "Match the offered ordinal within a wave across engines when either arm places it in its slowest 5%.",
                      "optimized_minus_stock_ns": "Differences of selected phase means and of per-wave p95 medians over matched seeds. The selected populations can change with mode."},
        "aggregate": paired_run(polling.ORDERS),
        "by_seed": [{"seed": seed, "boot_order": list(order), **paired_run([seed])} for seed, order in polling.ORDERS.items()],
        "inputs": inputs,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive-root", type=Path, default=HERE)
    parser.add_argument("--output-polling", action="store_true", help="replay the runner crossover instead of the prior stock control set")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    replay = runner_report if args.output_polling else report
    output = json.dumps(replay(args.archive_root), indent=2, allow_nan=False) + "\n"
    if args.output:
        with args.output.open("x") as f:
            f.write(output)
    else:
        print(output, end="")
