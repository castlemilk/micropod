"""Replay two fresh flat-worker boots against the same OrbStack peer."""

import argparse
import json
from pathlib import Path

import sibling_job_parent_results as parent
from qualify import require
from sibling_job_parent_evidence import boots
from sibling_results import docker_time_ns, read


MATCHED = ("protocol_sha256", "signed_settings_sha256", "signed_product", "worker", "images", "placements",
           "compiler_executables")


def archive_identity(folder, seed, mode):
    plan = read(folder, "plan.json")
    require(plan["seed"] == seed and plan["job_parent"] == mode and read(folder, "status.json") == {"complete": True},
            "flat holdout references an unqualified archive or the wrong seed and treatment")
    inventory = read(folder, "grouped-inventory.json")
    require(inventory.keys() == parent.ENGINES.keys(), "flat holdout archive has the wrong engine cohorts")
    ids = [job["id"] for arm in parent.ENGINES for job in inventory[arm]["jobs"]]
    require(len(ids) == len(set(ids)) == 128, "flat holdout archive reused a measured container ID")
    guest = boots(folder)
    admission = parent.check_admission(folder, inventory)
    windows = read(folder, "windows.json")
    products = parent.fingerprint([[windows[f"grouped-{block}-all"][arm]["build"]["products"] for arm in parent.ENGINES]
                                   for block in range(parent.ROUNDS)])
    return {"scope": Path(plan["scope"]).resolve(), "native": guest["A"], "peer": guest["B"], "ids": set(ids),
            "products": products, "first": docker_time_ns(admission["first_utc"]), "last": docker_time_ns(admission["last_utc"])}


def initial_archives(root, initial_score):
    expected = parent.SEED_ORDER["initial"]
    rows = initial_score["by_seed"]
    require(initial_score["batch"] == "initial" and initial_score["native_boots"] == len(expected) * len(parent.MODES) and
            len(rows) == len(expected) and {row["seed"] for row in rows} == expected.keys(),
            "flat holdout requires the complete initial crossed score")
    archives = []
    for row in rows:
        require(row["treatment_order"] == list(expected[row["seed"]]) and set(row["boot_receipts"]) == set(parent.MODES),
                "initial crossed score has the wrong seed or treatment order")
        for mode, receipt in row["boot_receipts"].items():
            path = (root / receipt["archive"]).resolve()
            require(path.parent == root and path.name == receipt["archive"], "initial score points outside the archive directory")
            identity = archive_identity(path, row["seed"], mode)
            require((identity["native"], identity["peer"]) == (receipt["native_boot"], receipt["peer_boot"]),
                    "initial score and archived guest boots differ")
            archives.append((path, identity))
    return archives


def wins_both_medians(outcome):
    return all(outcome["metrics"][key]["micropod"] < outcome["metrics"][key]["orbstack"] for key in parent.WIN_METRICS)


def discovery_inputs(initial, initial_score):
    # Older discovery scores do not serialize the signed settings or image
    # identities. Recover them from all four source archives without replaying HTTP.
    missing = {"signed_settings_sha256", "images"} - initial_score.keys()
    if not missing:
        return {key: initial_score[key] for key in MATCHED}
    product, packaged = parent.check_product()
    recovered = []
    for path, _ in initial:
        plan = read(path, "plan.json")
        _, settings, _ = parent.validate_archive(path, plan, parent.SEED_ORDER["initial"], product, packaged)
        recovered.append({"signed_settings_sha256": parent.fingerprint(settings), "images": parent.paced.check_inputs(path, plan)})
    require(all(record == recovered[0] for record in recovered) and
            all(initial_score.get(key, value) == value for key, value in recovered[0].items()),
            "discovery archive settings or image identities differ")
    return {key: initial_score[key] if key in initial_score else recovered[0][key] for key in MATCHED}


def compare_flat_holdout(folders, initial_score):
    if not isinstance(initial_score, dict):
        source = Path(initial_score)
        initial_score = read(source.parent, source.name)
    paths = [Path(folder).resolve() for folder in folders]
    expected = parent.SEED_ORDER["holdout"]
    require(len(paths) == len(set(paths)) == len(expected) and len({path.parent for path in paths}) == 1,
            "flat holdout requires exactly two distinct archived boots in the same directory")
    initial = initial_archives(paths[0].parent, initial_score)
    holdout = {}
    for path in paths:
        seed = read(path, "plan.json")["seed"]
        require(type(seed) is int and seed in expected and seed not in holdout, "flat holdout requires the two prespecified seeds")
        holdout[seed] = path, archive_identity(path, seed, "flat")
    combined = [*initial, *holdout.values()]
    identities = [identity for _, identity in combined]
    require(len({path for path, _ in combined}) == len({r["scope"] for r in identities}) ==
            len({r["native"] for r in identities}) == len(combined) and
            len({r["peer"] for r in identities}) == 1 and
            len(set().union(*(r["ids"] for r in identities))) == 128 * len(combined),
            "flat holdout reused a scope, native boot or container, or changed the peer")
    require(len({r["products"] for r in identities}) == 1, "flat holdout changed the built artifacts")
    latest = max(r["last"] for _, r in initial)
    intervals = sorted((r["first"], r["last"]) for _, r in holdout.values())
    require(latest < intervals[0][0] and intervals[0][1] < intervals[1][0],
            "flat holdout overlapped another scope or preceded discovery")
    inputs = discovery_inputs(initial, initial_score)

    records, windows = [], []
    for seed, (path, identity) in sorted(holdout.items()):
        run = parent.replay(path, batch="holdout")
        require(all(run[key] == inputs[key] for key in MATCHED) and run["seed"] == seed and run["mode"] == "flat" and
                (run["native_boot"], run["peer_boot"]) == (identity["native"], identity["peer"]),
                "flat holdout changed protocol, signed product, workload or boot")
        windows.extend(run["windows"])
        records.append({"seed": seed, "archive": path.name, "native_boot": run["native_boot"], "admission": run["admission"],
                        "both_boot_medians_faster": wins_both_medians(run["within_boot"]),
                        "comparison": run["within_boot"], "windows": run["windows"]})
    engine_windows = [wave[engine] for wave in windows for engine in parent.ENGINES.values()]
    return {
        "comparison": "flat worker versus contemporaneous peer", "signed_product": initial_score["signed_product"],
        "protocol_sha256": initial_score["protocol_sha256"], "peer_boot": identities[0]["peer"],
        "fresh_native_boots": len(records), "paired_engine_windows": len(windows), "engine_windows": len(engine_windows),
        "offered_rps": parent.RATE, "offer_duration_ns": parent.paced.OFFER_NS,
        "offered_requests": sum(wave["offered_requests"] for wave in engine_windows),
        "completed_requests": sum(wave["requests"] for wave in engine_windows),
        "build_jobs": sum(wave["jobs"] for wave in engine_windows),
        "build_revisions": sum(wave["revisions"] for wave in engine_windows),
        "test_passes": sum(wave["test_passes"] for wave in engine_windows),
        "minimum_first_build_end_margin_ns": min(wave["first_build_end_margin_ns"] for wave in engine_windows),
        "both_boot_medians_faster_on_each_holdout": all(r["both_boot_medians_faster"] for r in records),
        "initial_flat_seeds_winning_both_medians": [row["seed"] for row in initial_score["by_seed"]
                                                   if wins_both_medians(row["within_mode"]["flat"])],
        "pooled_windows": parent.outcomes([w["orbstack"] for w in windows], [w["micropod"] for w in windows],
                                         ("orbstack", "micropod")),
        "by_seed": records,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--initial-score", type=Path, required=True)
    parser.add_argument("folders", type=Path, nargs=2)
    args = parser.parse_args()
    print(json.dumps(compare_flat_holdout(args.folders, args.initial_score), indent=2, allow_nan=False))
