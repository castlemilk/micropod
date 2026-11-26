"""Compare HTTP response phases on matched client slots in the log notification crossover."""

import argparse
from hashlib import sha256
import json
from pathlib import Path
from statistics import mean, median

from qualify import require
from sibling_results import read
import sibling_http_response_phases as phases
import sibling_log_notification_results as runners


HERE = Path(__file__).resolve().parent
PACED, SHARED = phases.PACED, phases.SHARED
ENGINES = phases.ENGINES


def compare_slot(native, peer, slot):
    offers = range(slot, len(native), PACED.PAIRS)
    count = len(offers)
    rank = (95 * count + 99) // 100
    band = slice(94 * count // 100, 96 * count // 100)
    a = sorted(offers, key=lambda offer: native[offer][0])
    b = sorted(offers, key=lambda offer: peer[offer][0])
    same = sorted(set(a[band]) | set(b[band]))
    return {"p95_ns": {"micropod": native[a[rank - 1]][0], "orbstack": peer[b[rank - 1]][0]},
            "both_near_p95_requests": len(set(a[band]) & set(b[band])),
            "phases": {"micropod": phases.summarize_selection(native, same), "orbstack": phases.summarize_selection(peer, same)}}


class SlotCollector(phases.TraceCollector):
    def __init__(self, folder):
        super().__init__(folder)
        self.slots = {}

    def compare_pair(self, block, pair):
        self.slots[block] = [compare_slot(pair["A"], pair["B"], slot) for slot in range(PACED.PAIRS)]
        return super().compare_pair(block, pair)


def slot_summary(waves):
    slots = []
    for slot in range(PACED.PAIRS):
        observations = [wave[slot] for wave in waves]
        gaps = [row["p95_ns"]["micropod"] - row["p95_ns"]["orbstack"] for row in observations]
        totals = [phases.pooled_stats([row["phases"][engine] for row in observations]) for engine in ENGINES.values()]
        slots.append({"slot": slot, "has_build": slot < PACED.BUILDERS,
                      "median_p95_ns": {engine: median(row["p95_ns"][engine] for row in observations) for engine in ENGINES.values()},
                      "median_paired_p95_gap_ns": median(gaps), "waves_with_higher_native_p95": sum(gap > 0 for gap in gaps),
                      "both_near_p95_requests": sum(row["both_near_p95_requests"] for row in observations),
                      "same_offer_near_p95_band_union": phases.contrast(*totals)})

    roles = {}
    for label, selected in (("all", slots), ("builders", slots[:PACED.BUILDERS]), ("service_only", slots[PACED.BUILDERS:])):
        paired = [row["same_offer_near_p95_band_union"] for row in selected]
        roles[label] = {"slots": len(selected), "matched_offers": sum(row["micropod"]["requests"] for row in paired),
                         "slot_medians_with_higher_native_p95": sum(row["median_paired_p95_gap_ns"] > 0 for row in selected),
                         "slot_windows_with_higher_native_p95": sum(row["waves_with_higher_native_p95"] for row in selected),
                         "median_of_slot_p95_gaps_ns": median(row["median_paired_p95_gap_ns"] for row in selected),
                         "equal_slot_micropod_minus_orbstack_mean_ns": {
                             phase: mean(row["micropod_minus_orbstack_mean_ns"][phase] for row in paired)
                             for phase in phases.COMPONENTS}}
    return {"paired_waves": len(waves), "roles": roles, "slots": slots}


def report(archive_root=HERE):
    archive_root = Path(archive_root).resolve()
    source = archive_root / "sibling-log-notification-results.json"
    source_bytes = source.read_bytes()
    reference = json.loads(source_bytes)
    manifest, kit, arms = runners.check_packages(archive_root / runners.fixture.MANIFEST)
    require(reference["product_manifest_sha256"] == sha256(manifest).hexdigest() and
            all(reference["products"][mode] == {"product": str(arm["path"]), "product_sha256": arm["product_sha256"],
                                                "runner_sha256": arm["runner_sha256"]} for mode, arm in arms.items()),
            "HTTP phase replay changed a sealed runner arm")
    require(len(reference["by_seed"]) == len(runners.ORDERS) and
            {row["seed"] for row in reference["by_seed"]} == runners.ORDERS.keys(), "HTTP phase replay lacks prespecified seeds")
    runs, measured = {}, {}
    for seed in reference["by_seed"]:
        require(seed["boot_order"] == list(runners.ORDERS[seed["seed"]]), "HTTP phase replay changed the boot order")
        for mode in runners.MODES:
            expected = seed["boots"][mode]
            case, name = (seed["seed"], mode), expected["archive"]
            require(Path(name).name == name, "invalid measured log notification archive name")
            folder = archive_root / name
            plan = read(folder, "plan.json")
            arm = arms[mode]
            key, settings, protocol = runners.validated_archive(folder, plan, manifest, kit, arm)
            require(key == case and SHARED.fingerprint(settings) == reference["signed_settings_sha256"],
                    "HTTP phase replay changed signed launch inputs")
            collector = SlotCollector(folder)
            extras = ("native_engine", "admission", "stock_builds", "fault_around_readback", "mode")
            run, replay = phases.replay_qualified_boot(folder, case, plan, expected, reference,
                                                       lambda: runners.verified_run(folder, plan, kit, arm), extras, collector=collector)
            require(SHARED.fingerprint([protocol, replay["launch"]]) == reference["protocol_sha256"] and
                    collector.slots.keys() == set(range(SHARED.ROUNDS)), "actual measured setup or client slots differ")
            run["slot_waves"] = [collector.slots[round_no] for round_no in range(SHARED.ROUNDS)]
            runs[case], measured[case] = run, replay

    identity = runners.polling.matched_identity(measured)
    require(all(identity[key] == reference[key] for key in identity), "native or peer identity changed during HTTP phase replay")
    summary = runners.polling.summarize(measured, modes=runners.MODES, orders=runners.ORDERS)
    counts = {key: summary[key] for key in ("matched_boot_pairs", "native_boots", "paired_engine_windows", "completed_requests",
                                           "build_jobs", "minimum_first_build_end_margin_ns")}
    require(all(reference[key] == value for key, value in counts.items()), "HTTP phase replay changed measured work")

    def view(seeds):
        by_mode = {}
        for mode in runners.MODES:
            runs_for_mode = [runs[seed, mode] for seed in seeds]
            by_mode[mode] = {"near_p95_by_role": phases.runner_mode_summary([w for run in runs_for_mode for w in run["waves"]]),
                             "same_slot": slot_summary([w for run in runs_for_mode for w in run["slot_waves"]])}
        return {"by_mode": by_mode, "notify_minus_stock_ns": phases.runner_phase_change(by_mode["stock"]["near_p95_by_role"],
                                                                                       by_mode["notify"]["near_p95_by_role"])}

    inputs = ("study_key", "archive", "native_boot", "peer_boot", "native_volume_uuid", "plan_sha256", "raw_http_gzip_sha256")
    return {"source_score": {"file": source.name, "sha256": sha256(source_bytes).hexdigest()},
            "protocol_sha256": reference["protocol_sha256"], "products": reference["products"], "placements": reference["placements"],
            "offered_rps": SHARED.RATE, **counts,
            "methods": {"same_slot": "Within each client slot and wave, pair the same offered ordinals selected by either engine's 94–96% post-dispatch rank band.",
                        "role_weighting": "Each measured slot contributes equally to its role's phase means. Per-seed estimates preserve the two boot pairs.",
                        "recorded_boundaries": ["dispatch", "GotConn", "WroteRequest", "GotFirstResponseByte", "completion after read, close and validation"],
                        "unrecorded_boundaries": ["header parse", "transport response handoff", "Client.Do return", "body bytes and EOF",
                                                  "idle-connection acknowledgement", "goroutine ready and running", "kernel thread scheduling"]},
            "aggregate": view(runners.ORDERS), "by_seed": [{"seed": seed, **view([seed])} for seed in runners.ORDERS],
            "inputs": [{key: run[key] for key in inputs} for run in runs.values()]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive-root", type=Path, default=HERE)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    data = json.dumps(report(args.archive_root), indent=2, allow_nan=False) + "\n"
    if args.output is None:
        print(data, end="")
    else:
        with args.output.open("x") as file:
            file.write(data)
