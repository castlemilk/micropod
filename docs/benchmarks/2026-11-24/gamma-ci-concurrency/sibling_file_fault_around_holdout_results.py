"""Replay the independent stock-workload file fault-around holdout."""

import argparse
import json
from pathlib import Path
from random import Random

import sibling_file_fault_around_results as trial
from sibling_flat_holdout_build_results import SOURCES as STOCK_BUILD_SOURCES
from qualify import require, terminal
from sibling_results import read


SEED_ORDER = {250257: trial.VALUES[::-1], 250259: trial.VALUES}
DRIVER = "sibling_file_fault_around_holdout.py"
WINDOWS = "file-fault-around-holdout-windows.json"
STOCK = "file-fault-around-holdout-stock-builds.json"
HOLDOUT = "file_fault_around_holdout"
IDENTITY_FIELDS = ("signed_product", "signed_settings_sha256", "kernel", "worker", "images", "placements",
                   "compiler_executables", "issuing_timer_slack_ns")
DIRECTION_METRICS = ("p95_us", "p99_us", "service_p95_us", "service_p99_us", "dispatch_lateness_p95_us",
                     "dispatch_lateness_p99_us", "build_makespan_s", "slowest_build_s")
# These are the shared discovery/holdout inputs. The holdout adapter and its
# stock build campaign differ, while these measured HTTP and CI drivers do not.
PACED_INPUTS = {
    "quiet_sha256": "dc212c1fe2ed9878302f88e1f35e588057a44837e015647af8e5b75a570a1f57",
    "quiet_source_sha256": "5635d4bcae1b780d2a3cdf9523231300f843657d099d74044d98d217cf21bda2",
    "harness_sha256": "17ebc7cedceb9eba76232f85a141e64d25c1df9ea1db32f355c55d9a3d58c4a4",
    "paced_driver_sha256": "b5ae99ebe9cf0c94a4046c25638c7a4c38f950dbe8be727f562b6cce0cb075f3",
    "build_driver_sha256": "63a844304d758ad219752bf2830785948e27c1c7ccd13da408224c08b06139fd",
}
MMAP_SOURCE_SHA256 = "89418d47332e199ba75fc25029af514d73c2820a9ba6ae6a0e3c0adb880e1df5"
MMAP_PROBE_SHA256 = "a7793dd7515291f3d831be4b3d3745fb5c5dd220460beaab7ffce9bba8d40399"


def validated_archive(folder, plan, product, candidate):
    result = trial.validated_settings(folder, plan, product, candidate, SEED_ORDER)
    fixture, observer = trial.fixture, trial.evidence
    inputs = (DRIVER, fixture.COMMON, trial.MARKER, fixture.READBACK_SCRIPT)
    probes = plan["file_fault_around_probes"]
    require(plan[HOLDOUT] is True and "file_fault_around_dispatch_sources" not in plan and
            plan["file_fault_around_sources"] == {name: terminal.digest(folder / name) for name in inputs} and
            probes == {observer.MMAP_SOURCE: MMAP_SOURCE_SHA256, observer.MMAP: MMAP_PROBE_SHA256} and
            terminal.digest(folder / observer.MMAP_SOURCE) == MMAP_SOURCE_SHA256 and
            all(plan[key] == digest for key, digest in PACED_INPUTS.items()) and
            (folder / trial.MARKER).read_bytes() == trial.MARKER_CONTENT and
            (folder / fixture.READBACK_SCRIPT).read_text() == "set -eu\n" + trial.native.FINAL_OBSERVER and
            (folder / trial.hierarchy.BOOT_HOOK).read_text() == fixture.boot_hook(),
            "stock holdout changed its signed selector or off-timing mapping sources")
    require(all(terminal.digest(folder / name) == digest for name, digest in STOCK_BUILD_SOURCES.items()) and
            not any((folder / name).exists() for name in (observer.USAGE_SOURCE, observer.PAIR, observer.DISPATCH,
                                                         observer.MEMORY, Path(observer.__file__).name)) and
            not any(folder.glob("file-fault-around-grouped-*.json")), "stock holdout included timed build instrumentation")
    return result


def check_host_windows(windows, seed, lower, upper):
    orders = ["AB", "BA"] * (trial.shared.ROUNDS // 2)
    Random(seed).shuffle(orders)
    expected = [(block, mode, arm) for block, order in enumerate(orders) for mode in ("one", "all") for arm in order]
    require(len(windows) == len(expected) == 4 * trial.shared.ROUNDS, "stock holdout has missing host wave evidence")
    starts, ends = [], []
    for row, (block, mode, arm) in zip(windows, expected, strict=True):
        start, end = row["host_started_unix_ns"], row["host_finished_unix_ns"]
        require((row["block"], row["mode"], row["arm"]) == (block, mode, arm) and type(row["block"]) is int and
                type(start) is type(end) is int and lower < start < end < upper and
                (mode != "all" or end - start >= trial.paced.OFFER_NS),
                "stock holdout actual engine order or host wave bounds disagree with its preselected schedule")
        lower = end
        starts.append(start)
        ends.append(end)
    return starts[0], ends[-1]


def verify_stock(folder, plan, context):
    import sibling_file_fault_around_holdout as fixture

    inventory, boots = context["inventory"], context["boots"]
    proof = fixture.check_stock(folder, inventory, boots)
    before, after = (read(folder, f"job-parent-{phase}.json") for phase in ("before", "after"))
    volume = context["volume"]
    require(volume["live_observed_unix_ns"] < before["host_finished_unix_ns"] < after["host_started_unix_ns"] <
            volume["post_observed_unix_ns"], "stock holdout lifetime did not bracket the measurement suite")
    first, last = check_host_windows(read(folder, WINDOWS), plan["seed"], before["host_finished_unix_ns"],
                                     after["host_started_unix_ns"])
    phases = read(folder, STOCK)["phase_bounds"]
    started, finished = (phases["before"][key] for key in ("started_unix_ns", "finished_unix_ns"))
    after_start, after_end = (phases["after"][key] for key in ("started_unix_ns", "finished_unix_ns"))
    mmap = read(folder, trial.evidence.CALIBRATION)
    require(all(type(value) is int for value in (started, finished, after_start, after_end)) and
            volume["live_observed_unix_ns"] < started < finished < before["host_started_unix_ns"] <=
            before["host_finished_unix_ns"] < first <= last < after_start < after_end <= mmap["host_started_unix_ns"] <=
            mmap["host_finished_unix_ns"] < after["host_started_unix_ns"],
            "stock build bytes and mapping were not witnessed outside the measured work")
    return last, {"script_sha256": proof, "verified_builders_per_engine_per_phase": trial.paced.BUILDERS, "phase_bounds": phases}


def verified_run(folder, plan):
    context = trial.qualified_context(folder, plan)
    last_wave, stock = verify_stock(folder, plan, context)
    mapping = trial.check_mapping(folder, context, plan[trial.TREATMENT], last_wave=last_wave)
    run, rows = trial.replay_paced(folder, plan, context)
    result = trial.run_identity(folder, plan, context, run, rows)
    result["receipt"].update(stock_builds=stock, off_timing_go_mapping=mapping)
    return result


def check_discovery(metadata, verified, discovery):
    if isinstance(discovery, (str, Path)):
        discovery = json.loads(Path(discovery).read_text())
    require(all(metadata[key] == discovery[key] for key in IDENTITY_FIELDS),
            "stock holdout did not reproduce the discovery product, scheduler, images or stable inputs")
    prior = discovery["by_seed"]
    require({row["seed"] for row in prior} == trial.SEED_ORDER.keys() and len(prior) == len(trial.SEED_ORDER) and
            all(row["boot_order_bytes"] == list(trial.SEED_ORDER[row["seed"]]) and row["boots"].keys() == set(trial.LABELS)
                for row in prior), "unexpected discovery cohort or treatment order")
    previous = [boot for row in prior for boot in row["boots"].values()]
    newer = [row["receipt"] for row in verified.values()]
    for key, location in (("archive", None), ("native_boot", None), ("scope", "native_volume"), ("volume_uuid", "native_volume")):
        observed = [{(row[location] if location else row)[key] for row in receipt} for receipt in (previous, newer)]
        require(len(observed[0]) == len(previous) and observed[0].isdisjoint(observed[1]),
                "stock holdout reused a discovery archive, native boot, scope or APFS volume")
    require(len({row["peer_boot"] for row in [*previous, *newer]}) == 1 and
            max(trial.docker_time_ns(row["admission"]["last_utc"]) for row in previous) <
            min(trial.docker_time_ns(row["admission"]["first_utc"]) for row in newer),
            "stock holdout changed the peer guest or started before discovery finished")


def compare(folders, *, discovery=None):
    """Replay the four prespecified stock-workload boots and report both seeds."""
    metadata, verified = trial.compare_boots(folders, SEED_ORDER, validated_archive, verified_run)
    if discovery is not None:
        check_discovery(metadata, verified, discovery)
    scores = trial.summarize(verified, SEED_ORDER, include_resources=False)
    baseline, candidate = trial.LABELS
    for row in scores["by_seed"]:
        deltas = {}
        for engine, values in row["within_engine"].items():
            metrics = values["timing"]["metrics"]
            deltas[engine] = {metric: metrics[metric][candidate] - metrics[metric][baseline] for metric in DIRECTION_METRICS}
        row["medians_1024KiB_minus_64KiB"] = deltas
    direction = {engine: {metric: sum(row["medians_1024KiB_minus_64KiB"][engine][metric] < 0 for row in scores["by_seed"])
                          for metric in DIRECTION_METRICS} for engine in trial.shared.ENGINES.values()}
    return {"cohort": "stock-holdout", "matched_discovery": discovery is not None,
            "seeds_with_lower_1024KiB_median": direction, **metadata, **scores}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--discovery", type=Path, help="saved discovery score to verify fresh boots and identical signed inputs")
    parser.add_argument("folders", nargs=4, type=Path)
    args = parser.parse_args()
    print(json.dumps(compare(args.folders, discovery=args.discovery), indent=2, allow_nan=False))
