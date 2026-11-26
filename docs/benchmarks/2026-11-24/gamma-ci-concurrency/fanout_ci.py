"""Cross service fanout with CI build dispatch on a fixed set of 32 published tenants."""

import argparse
import hashlib
import json
import math
import re
import statistics
import time
from pathlib import Path

import churn
import replay
from qualify import CONFIG, LABEL, peer, receiver, relay, require, terminal
from gamma_contrasts import clean_client, host_units, invocation_bulk_bytes, paired_median_interval, process_delta


CELLS = ("one-idle", "many-idle", "one-ci", "many-ci")
PERIODS = ((0, 1, 3, 2), (1, 2, 0, 3), (2, 3, 1, 0), (3, 0, 2, 1))
SINGLE_TENANTS = (3, 11, 19, 27)


def schedule():
    return [
        {"block": block, "number": 4 * block + period, "cell": CELLS[cell],
         "target_index": SINGLE_TENANTS[block] if CELLS[cell].startswith("one-") else None,
         "order": "AB" if (block + cell) % 2 == 0 else "BA"}
        for block, conditions in enumerate(PERIODS)
        for period, cell in enumerate(conditions)
    ]


def resident_ids(cohort):
    require(cohort.running() == 32, "resident services changed")
    ids = cohort.cmd("ps", "-q", "--no-trunc", "--filter", f"label={LABEL}={cohort.owner}").splitlines()
    require(len(ids) == 32 and set(ids) == {j["id"] for j in cohort.jobs}, "unexpected scoped workload")
    return sorted(ids)


def study(cohorts, folder, clients, fixtures):
    fixed = clients / "fixed"
    plan = {"schedule": schedule(), "client_sha256": terminal.digest(fixed),
            "target_files": {arm: str(folder / f"targets-{arm}.tsv") for arm in cohorts},
            "resident_services": 32, "build_slots": 4, "streams": 32, "fresh_per_second": 40}
    require(plan["client_sha256"] == peer.CLIENT, "changed workload client")
    terminal.save(folder / "fanout-plan.json", plan)
    for cohort in cohorts.values():
        cohort.add(32)
    for stage in plan["schedule"]:
        number, ordinal = stage["number"], stage["target_index"]
        for arm in stage["order"]:
            cohort = cohorts[arm]
            before_ids = resident_ids(cohort)

            def observe(_position):
                start = time.monotonic()
                snap = relay.snapshot(clients, fixtures[arm])
                return {"start_s": start, "host": snap, "end_s": time.monotonic()}

            if stage["cell"].endswith("-ci"):
                row = churn.batch(cohort, number, fixed, target_index=ordinal, observe=observe)
            else:
                args = churn.traffic_arguments(cohort, fixed, ordinal)
                idle = receiver.path_pilot.cpu_idle()
                before = observe("before")
                proc, invocation = churn.run_traffic(cohort, fixed, args)
                after = observe("after")
                row = {"arm": arm, "block": number, "resident_services": 32, "pre_idle": idle,
                       "client_exit": proc.returncode, "client": json.loads(proc.stdout),
                       "client_stderr": proc.stderr[-1500:], "invocation": invocation, "jobs": [],
                       "running_ephemeral_at_barrier": 0, "counter_before": before, "counter_after": after}
            row.update(resident_ids_before=before_ids, resident_ids_after=resident_ids(cohort), cell=stage["cell"])
            terminal.save(folder / f"fanout-{number}-{arm}.json", row)
            require(row["client_exit"] == 0 and clean_client(row["client"]), "failed fanout window")


def products(row):
    jobs = row["jobs"]
    require(len({j["id"] for j in jobs}) == 32 and sorted(j["exit"] for j in jobs) == [0] * 30 + [1, 137]
            and {j["id"] for j in jobs} == set(row["removed"]), "incomplete churn lifecycles")
    result = {}
    for j in jobs:
        expected_exit = {"pass": 0, "fail": 1, "cancel": 137}[j["kind"]]
        require(j["exit"] == expected_exit and 0 <= j["submitted_s"] < j["finished_s"],
                "incorrect job outcome or timing")
        expected = [j["revision"] + "-a", j["revision"] + "-b"] if j["kind"] == "pass" else []
        require([v["revision"] for v in j["receipts"]] == expected, "missing CI revision")
        for v in j["receipts"]:
            require(v["tests"] == 8 and v["cpu_s"] > 0 and min(v[k] for k in ("compile", "vet", "link")) > 0
                    and re.fullmatch(r"[0-9a-f]{64}", v["product"]),
                    "job work was skipped")
            result[v["revision"]] = v["product"]
    require(len(result) == len(set(result.values())) == 60, "duplicate revision or artifact")
    return result


def minimum_job_overlap(row):
    """Lower bound on released healthy-job time during the six-second scored window."""
    origin = row["job_release_monotonic_s"]
    start = row["invocation"]["started_s"]
    end = row["invocation"]["ended_s"]
    last_covered, covered = start, 0.0
    events = []
    for job in sorted(row["jobs"], key=lambda j: j["submitted_s"]):
        lo, hi = job["submitted_s"], job["finished_s"]
        events.extend(((lo, 1), (hi, -1)))
        # Release-to-completion intervals include the CLI wait and log collection.
        if job["kind"] == "pass":
            left, right = max(last_covered, origin + lo), min(end, origin + hi)
            covered += max(0.0, right - left)
            last_covered = max(last_covered, right)
    active = peak = 0
    for _, change in sorted(events):
        active += change
        peak = max(peak, active)
    require(0 < peak <= 4 and active == 0, "build admission exceeded four slots")
    require(math.isclose(row["last_job_s"], max(j["finished_s"] for j in row["jobs"])),
            "last-job time differs from job receipts")
    return max(0.0, row["client"]["window_s"] - ((end - start) - covered))


def window_metrics(row, stage, arm, tenants, plan, fixture, manifest_hash):
    index, raw = stage["target_index"], row["client"]
    ids = sorted(j["id"] for j in tenants)
    require(row["cell"] == stage["cell"] and row["block"] == stage["number"] and row["arm"] == arm,
            "row does not match the frozen condition")
    require(len(ids) == len(set(ids)) == row["resident_services"] == 32
            and ids == row["resident_ids_before"] == row["resident_ids_after"], "resident set changed")
    expected = ["--targets", plan["target_files"][arm]]
    if index is not None:
        target = tenants[index]
        expected = [f"http://127.0.0.1:{target['port']}", target["name"]]
    invocation = row["invocation"]
    require(invocation["arguments"] == expected and invocation["target_sha256"] == (manifest_hash if index is None else None)
            and raw["published_ports"] == (32 if index is None else 1),
            "target cardinality, address or marker changed")
    require(row["client_exit"] == 0 and clean_client(raw), "unclean receiver delivery")
    count = invocation_bulk_bytes(raw, True)
    before, after = row["counter_before"], row["counter_after"]
    require(before["end_s"] <= invocation["started_s"] < invocation["ended_s"] <= after["start_s"]
            and invocation["ended_s"] - invocation["started_s"] >= raw["window_s"],
            "client escaped counter interval")
    pids = set(fixture["pids"].values())
    require(all({t["pid"] for t in s["tasks"]} == pids for s in (before["host"], after["host"])),
            "host counters do not match fixture processes")
    usage = {name: host_units(process_delta(before["host"], after["host"], pid), count)
             for name, pid in fixture["pids"].items()}
    metrics = {"mib_s": raw["mib_s"], "fresh_p95_ms": raw["fresh_p95_us"] / 1000,
               "fresh_p99_ms": raw["fresh_p99_us"] / 1000,
               "slowest_stream_mib_s": min(raw["per_stream_bytes"]) / 2**20 / raw["window_s"],
               "cpu_s_per_invocation_gib": sum(v["cpu_s_per_gib"] for v in usage.values()),
               "runnable_wait_s_per_s": sum(v["wait_s_per_s"] for v in usage.values())}
    payloads = {}
    if stage["cell"].endswith("-ci"):
        require(row["running_ephemeral_at_barrier"] == len(row["jobs"]) == 32, "missing CI dispatch")
        payloads = products(row)
        origin = row["job_release_monotonic_s"]
        require(origin <= invocation["started_s"] and origin + row["last_job_s"] >= invocation["ended_s"],
                "CI batch did not span the published client")
        overlap = minimum_job_overlap(row)
        require(overlap > 0, "no guaranteed overlap with released healthy jobs in the scored window")
        metrics["min_scored_seconds_with_released_passing_jobs"] = overlap
        metrics["successful_jobs_per_second"] = 30 / row["last_job_s"]
        metrics["verified_revisions_per_second"] = 60 / row["last_job_s"]
        metrics["last_job_s"] = row["last_job_s"]
    else:
        require(row["running_ephemeral_at_barrier"] == 0 and row["jobs"] == [], "idle condition included CI jobs")
    return metrics, payloads


def assess(folder):
    plan = replay.read(folder, "fanout-plan.json")
    ordered = schedule()
    require(plan["schedule"] == ordered and plan["client_sha256"] == peer.CLIENT
            and [plan[k] for k in ("resident_services", "build_slots", "streams", "fresh_per_second")] == [32,4,32,40],
            "fanout plan differs from the preselected design")
    run = replay.read(folder, "plan.json")
    require(run["profile"] == "fanout" and run["worker"] == peer.CANDIDATE and run["ci_config_sha256"] == CONFIG
            and [run[k] for k in ("cpus", "vm_mib", "job_cpus", "job_mib", "pids")] == [4,4096,1,512,192],
            "wrong runtime, image or resource budget")
    fixtures = replay.read(folder, "fixtures-before.json")
    peer.verify_arms(fixtures)
    tenants = {a: replay.read(folder, f"tenants-{a}-32.json")["tenants"] for a in "AB"}
    manifest_hashes = {}
    for arm, items in tenants.items():
        require(len(items) == len({j["port"] for j in items}) == len({j["name"] for j in items}) == 32
                and all(j["identity"]["cpu"] == "100000 100000" and j["identity"]["pids"] == "192"
                        and j["identity"]["memory"] == str(512 << 20) for j in items), "invalid service topology")
        manifest = "".join(f"http://127.0.0.1:{j['port']}\t{j['name']}\n" for j in items)
        name = f"targets-{arm}.tsv"
        require(Path(plan["target_files"][arm]).name == name and (folder / name).read_text() == manifest,
                "manifest differs from live tenants")
        manifest_hashes[arm] = hashlib.sha256(manifest.encode()).hexdigest()
    values = {a: {c: [] for c in CELLS} for a in "AB"}
    last_end = 0
    for st in ordered:
        artifacts = []
        for arm in st["order"]:
            row = replay.read(folder, f"fanout-{st['number']}-{arm}.json")
            require(row["invocation"]["started_s"] > last_end, "windows overlapped or order changed")
            last_end = row["invocation"]["ended_s"]
            metrics, job_hashes = window_metrics(row, st, arm, tenants[arm], plan, fixtures[arm], manifest_hashes[arm])
            values[arm][st["cell"]].append(metrics)
            artifacts.append(job_hashes)
        require(artifacts[0] == artifacts[1], "engines built different revisions")
    result = {"blocks": len(PERIODS), "arms": {}, "peer_throughput_ratios_micropod_over_orbstack": {}}
    for arm, cells in values.items():
        scales = {}
        for name in ("one", "many"):
            paired = zip(cells[name + "-ci"], cells[name + "-idle"], strict=True)
            scales[name] = [ci["mib_s"] / idle["mib_s"] for ci, idle in paired]
        # Above one means CI preserved a larger share of throughput when traffic was spread.
        interaction = [many / one for many, one in zip(scales["many"], scales["one"], strict=True)]
        cell_medians = {
            cell: {key: statistics.median(row[key] for row in rows) for key in rows[0]}
            for cell, rows in cells.items()
        }
        result["arms"][arm] = {
            "cell_medians": cell_medians,
            "ci_over_idle_by_block": scales,
            "interaction_ratios_by_block": interaction,
            "median_interaction": statistics.median(interaction),
            "interaction_bootstrap_ci95": paired_median_interval(interaction),
        }
    for cell in CELLS:
        ratios = [a["mib_s"] / b["mib_s"] for a, b in zip(values["A"][cell], values["B"][cell], strict=True)]
        result["peer_throughput_ratios_micropod_over_orbstack"][cell] = ratios
    return result


def historical(folder):
    """Use only the previously measured 32-service CI cell."""
    require(replay.common(folder) == "churn", "expected the original mixed-peer study")
    replay.churn(folder)
    pairs = []
    for block in range(len(replay.read(folder, "churn-plan.json")["order"])):
        rates = []
        for arm in "AB":
            row = replay.read(folder, f"churn-{block}-{arm}.json")
            client = row["client"]
            require(clean_client(client), "unclean historical client")
            invocation_bulk_bytes(client, True)
            rates.append([v / 2**20 / client["window_s"] for v in client["per_stream_bytes"]])
        a, b = rates
        gap = sum(b) - sum(a)
        gain = 32 * max(a) - sum(a)
        pairs.append({"block": block, "micropod_min_max_mib_s": [min(a), max(a)],
                      "orbstack_min_max_mib_s": [min(b), max(b)],
                      "all_micropod_streams_below_every_orbstack_stream": max(a) < min(b),
                      "lowest_eight_byte_share": {k: sum(sorted(v)[:8])/sum(v) for k,v in zip("AB",rates)},
                      "aggregate_gap_mib_s": gap, "gain_at_observed_fastest_mib_s": gain,
                      "residual_at_observed_fastest_mib_s": gap - gain})
    return {"scope": "two historical matched 32-port CI pairs", "pairs": pairs}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument("--plan", action="store_true")
    actions.add_argument("--historical", type=Path)
    args = parser.parse_args()
    output = schedule() if args.plan else historical(args.historical)
    print(json.dumps(output, indent=2, allow_nan=False))
