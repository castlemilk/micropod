"""Stage and score one fixed arrival schedule for the 32 sibling clients."""

import shutil
from pathlib import Path
from statistics import median

import sibling_build
import sibling_group
from qualify import require, terminal

CLIENTS = 32
DURATION_MS = 1500
DURATION_NS = DURATION_MS * 1_000_000
SECOND_NS = 1_000_000_000
RATES = (32_000, 64_000, 96_000, 128_000, 160_000)


def stage(folder, offered_rps):
    require(offered_rps in RATES, "unknown offered request rate")
    source = folder / "sibling-paced.py"
    shutil.copy2(Path(__file__), source)
    return {"offered_rps": offered_rps, "paced_driver_sha256": terminal.digest(source)}


def client_args(offered_rps, slot):
    return ("-offered-rps", offered_rps, "-client-slot", slot) if offered_rps else ()


def due_offset(offered_rps, slot, index):
    return (slot + CLIENTS * index) * SECOND_NS // offered_rps


def percentiles(values):
    ordered = sorted(values)
    return tuple(ordered[(len(ordered) * pct + 99) // 100 - 1] / 1000 for pct in (95, 99))


def check_socket(sample, reused, name):
    require(not sample.get("error") and sample["got_conn_count"] == 1 and sample["dial_starts"] == int(not reused)
            and sample["reused"] is reused and sample["same_as_warmup"] is reused
            and 0 < sample["got_conn_ns"] <= sample["wrote_request_ns"] <= sample["first_response_byte_ns"] <= sample["total_ns"],
            f"unverified paced HTTP socket in {name}")


def score_wave(rows, jobs, count, indices, arm, offered_rps, *, check_threads=None):
    slots = list(range(CLIENTS))
    require(count == CLIENTS and len(jobs) == 2 * CLIENTS and list(indices) == slots and offered_rps in RATES,
            "paced waves require 32 client and dependency pairs at a planned rate")
    require([row["index"] for row in rows] == slots, "missing or reordered paced clients")
    offered = (offered_rps * DURATION_NS + SECOND_NS - 1) // SECOND_NS
    deadlines, sockets = set(), set()
    queue_inclusive, service, lateness = [], [], []
    client_counts, client_completions = [], []
    late_starts = starts_after_next_due = completed_after_window = 0
    for item in rows:
        slot, row = item["index"], item["receipt"]
        server, client = jobs[slot], jobs[count + slot]
        expected = len(range(slot, offered, CLIENTS))
        samples = row.get("samples", [])
        w = row.get("window") or {}
        pace = row.get("pace") or {}
        arrivals = pace.get("arrivals", [])
        require(item["code"] == 0 and row.get("complete") is True and len(samples) == len(arrivals) == expected,
                f"incomplete paced {arm} slot {slot}: expected {expected}, recorded {len(samples)}. "
                f"{item['stderr'] or w.get('error') or row.get('error') or row.get('warmup', {}).get('error', '')}")
        require(row["requested"] == expected and pace["offered_rps"] == offered_rps and pace["slot"] == slot
                and w["duration_ns"] == DURATION_NS and w["ready_unix_ns"] < w["scheduled_unix_ns"] and not w.get("error"),
                f"wrong offered schedule for {arm} slot {slot}")
        require(pace.get("wait_clock") == "linux-clock-monotonic-absolute"
                and all(type(pace.get(key)) is int and pace[key] > 0 for key in ("clock_calibration_ns", "timer_slack_ns")),
                f"missing paced Linux clock evidence for {arm} slot {slot}")
        remote = server["ip"] + ":8080"
        host, sep, port = w["local"].rpartition(":")
        require(w["remote"] == remote and sep and host == client["ip"] and port.isascii() and port.isdecimal() and 0 < int(port) <= 65_535
                and row["url"] == "http://" + remote + "/id" and row["marker"] == server["name"]
                and w["page_bytes"] in (4096, 16384), f"wrong paced guest endpoint for {arm} slot {slot}")
        sockets.add((w["local"], w["remote"]))
        if "requested_slice_ns" in client:
            require(check_threads is not None, "paced client slice verification needs the fixture thread checker")
            check_threads(w["threads"], w["pid"], client.get("client_slice_ns", client["requested_slice_ns"]))
        if "affinity" in client:
            sibling_group.check_threads(w["threads"], w["pid"], sibling_group.process_mask(client))
        check_socket(row["warmup"], False, client["name"])

        previous_completion = 0
        for i, (arrival, sample) in enumerate(zip(arrivals, samples, strict=True)):
            due = due_offset(offered_rps, slot, i)
            observed_due, start, end, latency = (arrival["due_offset_ns"], arrival["dispatch_offset_ns"],
                                                 arrival["completion_offset_ns"], arrival["latency_ns"])
            check_socket(sample, True, client["name"])
            require(type(observed_due) is type(start) is type(end) is type(latency) is int
                    and 0 <= observed_due == due < DURATION_NS and due <= start < end
                    and previous_completion <= start and end - start == sample["total_ns"]
                    and latency == end - due, f"wrong paced request timing for {arm} slot {slot} call {i}")
            previous_completion = end
            queue_inclusive.append(end - due)
            service.append(end - start)
            lateness.append(start - due)
            late_starts += start > due
            starts_after_next_due += start >= due_offset(offered_rps, slot, i + 1)
            completed_after_window += end > DURATION_NS

        scheduled = w["scheduled_unix_ns"]
        require(w["started_unix_ns"] == scheduled + arrivals[0]["dispatch_offset_ns"]
                and w["finished_unix_ns"] == scheduled + previous_completion, "paced window timestamps differ from requests")
        deadlines.add(scheduled)
        client_counts.append(expected)
        client_completions.append(previous_completion)
    require(len(deadlines) == 1 and len(sockets) == CLIENTS and sum(client_counts) == offered,
            "paced clients did not share one complete arrival schedule and distinct sockets")
    latest_due = (offered - 1) * SECOND_NS // offered_rps
    latest_completion = max(client_completions)
    p95, p99 = percentiles(queue_inclusive)
    service95, service99 = percentiles(service)
    late95, late99 = percentiles(lateness)
    return {"offered_rps": offered_rps, "offered_requests": offered, "requests": len(service),
            "p50_us": median(queue_inclusive) / 1000, "p95_us": p95, "p99_us": p99,
            "service_p95_us": service95, "service_p99_us": service99,
            "dispatch_lateness_p95_us": late95, "dispatch_lateness_p99_us": late99,
            "late_starts": late_starts, "starts_after_next_due": starts_after_next_due,
            "completed_after_window": completed_after_window, "last_due_offset_ns": latest_due,
            "last_completion_offset_ns": latest_completion, "completion_after_last_due_ns": latest_completion - latest_due,
            "drain_after_window_ns": max(0, latest_completion - DURATION_NS), "per_client_requests": client_counts,
            "client_completion_offsets_ns": client_completions}


def score_build(build_rows, http, clients, block, nice_value, *, build_policy=None, build_slice_us=None):
    # The build must cover every offered slot. A sequential HTTP backlog can
    # drain past that 1.5 s interval. The existing scorer still checks the
    # actual builder clocks, exit status, and artifacts against this interval.
    start = http[0]["receipt"]["window"]["scheduled_unix_ns"]
    offer = [{"receipt": {"window": {"started_unix_ns": start, "finished_unix_ns": start + DURATION_NS}}}]
    return sibling_build.score(build_rows, offer, clients, block, nice_value,
                               build_policy=build_policy, build_slice_us=build_slice_us)
