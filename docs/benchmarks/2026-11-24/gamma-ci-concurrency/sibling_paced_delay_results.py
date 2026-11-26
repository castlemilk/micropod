"""Attribute paced request latency to elapsed intervals on each warmed socket.

The two intervals before dispatch measure the remaining time in the prior call
at the due time and the wait after the client could issue again. The HTTP
intervals measure client-observed elapsed time between callbacks. Tail shares
use the sum of the measured request latencies in that tail.
"""

import argparse
import heapq
import json
import random
from pathlib import Path
from statistics import median

from qualify import require
import sibling_build
import sibling_client_slice
import sibling_paced_results as paced
import sibling_tmpfs
from sibling_results import read


PHASES = (
    "carryover_from_previous_completion", "additional_before_dispatch",
    "dispatch_to_got_conn", "got_conn_to_wrote_request", "wrote_request_to_first_byte", "first_byte_to_completion",
)


def request_phases(previous_completion, arrival, sample):
    due, dispatch, completion, latency = (
        arrival["due_offset_ns"], arrival["dispatch_offset_ns"], arrival["completion_offset_ns"], arrival["latency_ns"])
    connected, wrote, first_byte, call = (
        sample["got_conn_ns"], sample["wrote_request_ns"], sample["first_response_byte_ns"], sample["total_ns"])
    require(all(type(ns) is int for ns in (previous_completion, due, dispatch, completion, latency, connected, wrote, first_byte, call)),
            "request phase timestamps must be integer nanoseconds")
    available = max(due, previous_completion)
    parts = (available - due, dispatch - available, connected, wrote - connected, first_byte - wrote, call - first_byte)
    require(previous_completion >= 0 and due >= 0 and min(parts) >= 0 and
            sum(parts[:2]) == dispatch - due and sum(parts[2:]) == call == completion - dispatch and
            sum(parts) == latency == completion - due and latency > 0,
            "request phases do not add to the observed dispatch, call and arrival times")
    return parts


def by_phase(values):
    return dict(zip(PHASES, values, strict=True))


def client_latency_groups(intervals):
    groups = {}
    for name, clients in (("with_build", intervals[:paced.BUILDERS]), ("without_build", intervals[paced.BUILDERS:])):
        arrivals, calls, client_p95 = [], [], {}
        for slot, scheduled, service in clients:
            arrivals.extend(scheduled)
            calls.extend(service)
            client_p95[slot] = paced.latency_percentiles("", scheduled)["p95_us"]
        worst = max(client_p95.values())
        groups[name] = {"clients": len(clients), "requests": len(arrivals),
                        **paced.latency_percentiles("arrival_", arrivals),
                        **paced.latency_percentiles("service_", calls),
                        "worst_client_arrival_p95_us": worst,
                        "worst_client_slots": [slot for slot, p95 in client_p95.items() if p95 == worst]}
    return groups


def score_wave(rows, jobs, rate, page_bytes):
    """Verify the offered schedule and sockets, then attribute each response."""
    verified = paced.score_wave(rows, jobs, rate, page_bytes)
    count = verified["offered_requests"]
    tail_size = (count + 99) // 100
    all_phases = [[] for _ in PHASES]
    client_intervals = []
    tail = []
    for item in rows:
        slot = item["index"]
        receipt = item["receipt"]
        previous = 0
        arrivals, calls = [], []
        for index, (arrival, sample) in enumerate(zip(receipt["pace"]["arrivals"], receipt["samples"], strict=True)):
            try:
                parts = request_phases(previous, arrival, sample)
            except ValueError as error:
                raise ValueError(f"client {slot}, request {index} has invalid phase accounting") from error
            previous = arrival["completion_offset_ns"]
            arrivals.append(arrival["latency_ns"])
            calls.append(sample["total_ns"])
            for values, phase in zip(all_phases, parts, strict=True):
                values.append(phase)
            # Select exactly the slowest 1%, giving an earlier offer priority on a tie.
            ranked = (arrival["latency_ns"], -(index * paced.PAIRS + slot), parts)
            if len(tail) < tail_size:
                heapq.heappush(tail, ranked)
            elif ranked > tail[0]:
                heapq.heapreplace(tail, ranked)
        client_intervals.append((slot, arrivals, calls))
    require(all(len(values) == count for values in all_phases) and len(tail) == tail_size,
            "incomplete request phase accounting")

    tail_phases = list(zip(*(phases for _, _, phases in tail), strict=True))
    totals = [sum(column) for column in tail_phases]
    total_elapsed = sum(latency for latency, _, _ in tail)
    require(sum(totals) == total_elapsed, "tail phase totals differ from the selected requests")
    largest = [0] * len(PHASES)
    tied = 0
    for _, _, parts in tail:
        longest = max(parts)
        if parts.count(longest) == 1:
            largest[parts.index(longest)] += 1
        else:
            tied += 1
    dispatch_elapsed = sum(totals[:2])
    return verified, {
        "requests": count,
        "arrival_p95_us": verified["p95_us"], "arrival_p99_us": verified["p99_us"],
        "client_latency": client_latency_groups(client_intervals),
        "median_ns": by_phase(map(median, all_phases)),
        "max_ns": by_phase(map(max, all_phases)),
        "positive_requests": by_phase(sum(value > 0 for value in column) for column in all_phases),
        "slowest_one_percent_by_arrival": {
            "requests": tail_size, "min_arrival_ns": tail[0][0], "median_arrival_ns": median(row[0] for row in tail),
            "median_ns": by_phase(map(median, tail_phases)),
            "max_ns": by_phase(map(max, tail_phases)),
            "fraction_of_request_latency": by_phase(value / total_elapsed for value in totals),
            "largest_phase_requests": by_phase(largest), "tied_largest_phase_requests": tied,
            "carryover_fraction_of_dispatch_delay": totals[0] / dispatch_elapsed if dispatch_elapsed else None,
        },
    }


def replay_boot(folder):
    """Check the retained inputs and replay dense HTTP and build receipts once."""
    plan = read(folder, "plan.json")
    images = paced.check_inputs(folder, plan)
    boot, worker = paced.check_boot(folder, plan)
    saved = read(folder, "windows.json")
    orders = random.Random(plan["seed"])
    rounds, rate = plan["rounds"], plan["offered_rps"]
    build_policy = plan.get("build_policy")
    client_slice = plan.get("slice_target") == sibling_client_slice.TARGET
    peer_boot = None
    seen = set()
    finished = {"A": 0, "B": 0}
    layouts = {}
    for layout in plan["layouts"]:
        inventory, _, boots = paced.check_cohorts(folder, plan, layout, images)
        if plan.get("build_scratch"):
            sibling_tmpfs.verify_archived(folder, plan, inventory)
        require(boots["A"] == boot and boot != boots["B"] and peer_boot in (None, boots["B"]),
                "paced cohorts disagree about the measured guest boots")
        peer_boot = boots["B"]
        scheduled_order = ["AB", "BA"] * ((rounds + 1) // 2)
        orders.shuffle(scheduled_order)
        windows = []
        for block, order in enumerate(scheduled_order[:rounds]):
            key = f"{layout}-{block}-all"
            single = f"{layout}-{block}-one"
            for name in (single, key):
                require(saved[name].keys() == {"order", "A", "B"} and saved[name]["order"] == order,
                        f"paced engine order differs for {name}")
                seen.add(name)
            window = {"block": block, "order": order}
            products = {}
            for arm in order:
                tag = f"{key}-{arm}"
                jobs = inventory[arm]["jobs"]
                http = paced.read_wire(folder, tag)
                page_bytes = plan["pages"]["kernel_page_kib"] * 1024 if arm == "A" else 4096
                if build_policy:
                    for item in http:
                        client = jobs[paced.PAIRS + item["index"]]
                        receipt = item["receipt"]
                        detail = receipt["window"]
                        sibling_build.check_http_policy(detail["threads"], detail["pid"], client["mask"])
                        if client_slice:
                            sibling_client_slice.check_client(receipt, client, arm, plan["fair_slice_us"] * 1000, paced=True)
                verified, breakdown = score_wave(http, jobs, rate, page_bytes)
                gate = verified["scheduled_unix_ns"]
                require(gate > finished[arm], f"overlapping or reordered paced waves in engine {arm}")
                finished[arm] = gate + verified["last_completion_offset_ns"]
                build_rows = read(folder, f"{tag}-go.json")
                builds = paced.score_builds(build_rows, jobs, block, plan["build_nice"], gate,
                                            build_policy, expected_boot=boots[arm])
                if client_slice:
                    sibling_client_slice.check_builds(build_rows)
                actual = {name: verified[name] for name in paced.LIVE_SCORE_FIELDS}
                require({**actual, "build": builds} == saved[key][arm], f"stored paced wave differs for {tag}")
                products[arm] = builds["products"]
                window[arm] = {**breakdown, **paced.build_overlap(http, build_rows, verified)}
                del http
            require(products["A"] == products["B"], f"paced build outputs differ for {key}")
            windows.append(window)
        layouts[layout] = windows
    require(seen == saved.keys(), "unplanned paced waves")
    keys = ("seed", "rounds", "offered_rps", "build_nice", "worker_scheduler", "worker_next_buddy",
            "network_driver", "network_topology", "build_scratch", "slice_target", "fair_slice_us")
    return {"run": folder.name, "scope": plan["scope"], "boot": boot, "peer_boot": peer_boot,
            "kernel": plan["pages"], "worker": worker,
            "settings": {k: plan[k] for k in keys if k in plan}, "layouts": layouts}


def report(folders):
    paths = [folder.resolve() for folder in folders]
    require(len(set(paths)) == len(paths) > 0, "duplicate or missing phase replay directories")
    runs = [replay_boot(folder) for folder in paths]
    require(all(len({run[field] for run in runs}) == len(runs) for field in ("scope", "boot")),
            "duplicate Micropod boot or scope in phase replay")
    return {"engines": {"A": "Micropod", "B": "OrbStack"}, "runs": runs}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folders", nargs="+", type=Path, help="qualified paced receipt directories")
    args = parser.parse_args()
    print(json.dumps(report(args.folders), indent=2))
