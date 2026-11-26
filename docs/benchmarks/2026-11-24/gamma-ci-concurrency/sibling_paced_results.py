"""Replay fixed-rate HTTP offers and builds from matched sibling worker boots."""

import argparse
import gzip
import json
import plistlib
import random
import re
from bisect import bisect_right
from collections import Counter
from operator import itemgetter
from pathlib import Path
from statistics import median

from qualify import LABEL, require, terminal
import sibling_build
import sibling_client_slice
import sibling_sched
import sibling_tmpfs
import sibling_topology
import sibling_weight
from sibling_ci import check_link, check_threads, placement, score_wave as score_unpaced
from sibling_results import (CPU_GROUP_LABEL, check_affinity, check_cpu_delta, check_group_smoke,
                             check_network, check_placement_inventory, read)


PAIRS = 32
BUILDERS = 8
SECOND_NS = 1_000_000_000
OFFER_NS = 1_500_000_000
OFFERED_RATES = (32_000, 64_000, 96_000, 128_000, 160_000)
WAIT_CLOCK = "linux-clock-monotonic-absolute"
BOOT_ID = r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}"
SCHEDULER_PROFILES = ("hrtick-125us", "hrtick")
CONTRAST_FIELDS = {"build-nice": "build_nice", "worker-scheduler": "worker_scheduler",
                   "native-client-slice": "fair_slice_us", "build-scratch": "build_scratch",
                   "network-topology": "network_topology", "scheduler-and-scratch": "scheduler_and_scratch"}
GROUPED_CONTRAST_ORDER = {"worker_scheduler": "profile_order", "fair_slice_us": "client_slice_order_us",
                          "build_scratch": "build_scratch_order", "network_topology": "topology_order",
                          "scheduler_and_scratch": "treatment_order"}
LIVE_SCORE_FIELDS = (
    "offered_rps", "offered_requests", "requests", "p50_us", "p95_us", "p99_us",
    "service_p95_us", "service_p99_us", "dispatch_lateness_p95_us", "dispatch_lateness_p99_us",
    "late_starts", "starts_after_next_due", "completed_after_window", "last_due_offset_ns",
    "last_completion_offset_ns", "completion_after_last_due_ns", "drain_after_window_ns",
    "per_client_requests", "client_completion_offsets_ns",
)
BUILD_OVERLAP_METRICS = (
    "completed_after_first_build", "completed_after_first_build_fraction", "first_build_end_margin_ns",
)
PAIRED_METRICS = (
    "p50_us", "p95_us", "p99_us", "service_p50_us", "service_p95_us", "service_p99_us",
    "dispatch_lateness_p50_us", "dispatch_lateness_p95_us", "dispatch_lateness_p99_us",
    "late_start_fraction", "starts_after_next_due_fraction", "dispatched_after_window_fraction",
    "completed_by_window_fraction", "completed_after_window_fraction", "drain_after_window_ns",
    "build_makespan_s", "slowest_build_s", *BUILD_OVERLAP_METRICS,
)
CONTRAST_METRICS = (
    "p95_us", "p99_us", "service_p95_us", "service_p99_us",
    "dispatch_lateness_p95_us", "dispatch_lateness_p99_us", "starts_after_next_due_fraction",
    "completed_after_window_fraction", "drain_after_window_ns", "build_makespan_s", *BUILD_OVERLAP_METRICS,
)


def offered_slots(rate, duration):
    return (rate * duration + SECOND_NS - 1) // SECOND_NS


def due_offset(ordinal, rate):
    return ordinal * SECOND_NS // rate


def check_trace(sample, *, warmup):
    require(not sample.get("error") and sample["got_conn_count"] == 1 and
            sample["dial_starts"] == int(warmup) and sample["reused"] is (not warmup) and
            sample["same_as_warmup"] is (not warmup) and
            0 < sample["got_conn_ns"] <= sample["wrote_request_ns"] <= sample["first_response_byte_ns"] <= sample["total_ns"],
            "HTTP tracing did not establish the expected warmed connection and successful request")


def latency_percentiles(kind, values):
    values.sort()
    n = len(values)
    return {f"{kind}p50_us": median(values) / 1_000,
            f"{kind}p95_us": values[(95 * n + 99) // 100 - 1] / 1_000,
            f"{kind}p99_us": values[(99 * n + 99) // 100 - 1] / 1_000}


def score_wave(rows, jobs, rate, page_bytes):
    """Score all scheduled calls, including the requests finishing after the offer window."""
    require(type(rate) is int and rate > 0, "invalid offered rate")
    total = offered_slots(rate, OFFER_NS)
    require(total >= PAIRS and [row["index"] for row in rows] == list(range(PAIRS)), "invalid offered cohort")
    gates, sockets = set(), set()
    offered_latencies, call_latencies, dispatch_lags = [], [], []
    per_client, completion_offsets = [], []
    calibrations, timer_slacks = [], set()
    late_starts = late_dispatches = late_completions = missed_slots = 0
    for slot, row in enumerate(rows):
        response = row["receipt"]
        window, pace = response["window"], response["pace"]
        server, client = jobs[slot], jobs[PAIRS + slot]
        slots = range(slot, total, PAIRS)
        arrivals, samples = pace["arrivals"], response["samples"]
        require(row["code"] == 0 and response["complete"] is True and not window.get("error") and
                type(pace["offered_rps"]) is type(pace["slot"]) is int and pace["offered_rps"] == rate and pace["slot"] == slot and
                response["requested"] == len(samples) == len(arrivals) == len(slots), f"incomplete offers for client {slot}")
        width, slack = pace["clock_calibration_ns"], pace["timer_slack_ns"]
        require(pace["wait_clock"] == WAIT_CLOCK and type(width) is type(slack) is int and width > 0 and slack > 0,
                f"invalid paced clock or timer readback for client {slot}")
        calibrations.append(width)
        timer_slacks.add(slack)
        require(response["url"] == f"http://{server['ip']}:8080/id" and response["marker"] == server["name"],
                f"incorrect response endpoint for client {slot}")
        host, sep, port = window["local"].rpartition(":")
        require(sep and host == client["ip"] and port.isascii() and port.isdecimal() and 0 < int(port) <= 65535 and
                window["remote"] == server["ip"] + ":8080" and window["page_bytes"] == page_bytes,
                f"incorrect warmed connection for client {slot}")
        sockets.add((window["local"], window["remote"]))
        check_trace(response["warmup"], warmup=True)
        if "affinity" in client:
            check_affinity(window, client["mask"])
        if "requested_slice_ns" in client:
            check_threads(window["threads"], window["pid"], client.get("client_slice_ns", client["requested_slice_ns"]))
        ready, gate = window["ready_unix_ns"], window["scheduled_unix_ns"]
        first, last = window["started_unix_ns"], window["finished_unix_ns"]
        require(type(ready) is type(gate) is type(first) is type(last) is int and
                0 < ready < gate and window["duration_ns"] == OFFER_NS and
                first == gate + arrivals[0]["dispatch_offset_ns"] and last == gate + arrivals[-1]["completion_offset_ns"],
                f"incorrect paced time origin for client {slot}")
        gates.add(gate)
        previous_completion = 0
        for ordinal, arrival, sample in zip(slots, arrivals, samples, strict=True):
            due, dispatch, completion, latency = (arrival["due_offset_ns"], arrival["dispatch_offset_ns"],
                                                   arrival["completion_offset_ns"], arrival["latency_ns"])
            if not (type(due) is type(dispatch) is type(completion) is type(latency) is int and
                    due == due_offset(ordinal, rate) < OFFER_NS and dispatch >= max(due, previous_completion) and
                    completion > dispatch and latency == completion - due and sample["total_ns"] == completion - dispatch):
                raise ValueError(f"invalid paced timing for client {slot}, offer {ordinal}")
            check_trace(sample, warmup=False)
            offered_latencies.append(latency)
            call_latencies.append(sample["total_ns"])
            dispatch_lags.append(dispatch - due)
            late_starts += dispatch > due
            late_dispatches += dispatch >= OFFER_NS
            late_completions += completion > OFFER_NS
            missed_slots += dispatch >= due_offset(ordinal + PAIRS, rate)
            previous_completion = completion
        completion_offsets.append(previous_completion)
        per_client.append(len(slots))
    require(len(gates) == 1 and len(sockets) == PAIRS and len(offered_latencies) == total,
            "the clients did not share one gate or distinct warmed sockets")
    last_due, last_completion = due_offset(total - 1, rate), max(completion_offsets)
    return {
        "scheduled_unix_ns": gates.pop(), "offered_rps": rate, "offered_requests": total, "requests": total,
        "late_starts": late_starts, "starts_after_next_due": missed_slots, "completed_after_window": late_completions,
        "late_start_fraction": late_starts / total, "starts_after_next_due_fraction": missed_slots / total,
        "dispatched_after_window_fraction": late_dispatches / total,
        "completed_after_window_fraction": late_completions / total,
        "completed_by_window_fraction": (total - late_completions) / total,
        "last_due_offset_ns": last_due, "last_completion_offset_ns": last_completion,
        "completion_after_last_due_ns": last_completion - last_due,
        "drain_after_window_ns": max(0, last_completion - OFFER_NS),
        "per_client_requests": per_client, "client_completion_offsets_ns": completion_offsets,
        "max_clock_calibration_ns": max(calibrations), "timer_slack_ns": sorted(timer_slacks),
        **latency_percentiles("", offered_latencies), **latency_percentiles("service_", call_latencies),
        **latency_percentiles("dispatch_lateness_", dispatch_lags),
    }


def score_builds(rows, jobs, block, nice_value, gate, build_policy=None, *, expected_boot=None):
    # Build coverage follows the offer deadline. HTTP can continue draining afterward.
    require(len(rows) == BUILDERS and max(r["started_unix_ns"] for r in rows) + 35_000_000 == gate,
            "paced offer gate did not follow all eight build start receipts")
    require(all(("policy" in row) == (build_policy is not None) for row in rows),
            "paced build policy receipt differs from the plan")
    offer = {"receipt": {"window": {"started_unix_ns": gate, "finished_unix_ns": gate + OFFER_NS}}}
    result = sibling_build.score(rows, [offer], jobs[PAIRS:PAIRS + BUILDERS], block, nice_value, build_policy=build_policy)
    if expected_boot is not None:
        require(all(sibling_build.fanout.parse_job(line, 0)["boot"] == expected_boot
                    for row in rows for line in row["stdout"].strip().splitlines()[:2]),
                "paced build readback came from a different guest boot")
    return result


def build_overlap(http, build_rows, wave):
    """Count late completions and return the signed margin to the first build exit."""
    first_build_end_ns = min(int(row["stdout"].strip().splitlines()[-1].split()[1]) for row in build_rows)
    first_build_end_offset_ns = first_build_end_ns - wave["scheduled_unix_ns"]
    completed_after = 0
    for row in http:
        arrivals = row["receipt"]["pace"]["arrivals"]
        # score_wave verified the ordering. A completion at the exit is covered.
        completed_by_end = bisect_right(arrivals, first_build_end_offset_ns, key=itemgetter("completion_offset_ns"))
        completed_after += len(arrivals) - completed_by_end
    return {
        "completed_after_first_build": completed_after,
        "completed_after_first_build_fraction": completed_after / wave["offered_requests"],
        "first_build_end_margin_ns": first_build_end_offset_ns - wave["last_completion_offset_ns"],
    }


def check_inputs(folder, plan):
    cleanup = read(folder, "cleanup.json")
    require(read(folder, "status.json")["complete"] is True and
            read(folder, "verification.json") == {"baseline_files": 24, "extra_cleanup_errors": []} and
            cleanup["scope"] == plan["scope"] and not cleanup["retained"] and not cleanup["errors"] and
            not Path(plan["scope"]).exists(), "paced worker did not complete or clean up")
    require(plan["healthy_pairs"] == PAIRS and plan["builders"] == BUILDERS and
            type(plan["seed"]) is type(plan["rounds"]) is int and plan["rounds"] in (1, 4, 8) and
            plan["dense_ms"] * 1_000_000 == OFFER_NS and plan["requests_per_client"] in (100, 200) and
            type(plan["offered_rps"]) is int and plan["offered_rps"] in OFFERED_RATES and
            not (plan.get("socket_sched_trace") or plan.get("timer_counters")) and
            len(set(plan["layouts"])) == len(plan["layouts"]) > 0 and
            set(plan["layouts"]) <= {"shared", "same", "duo", "split", "free-client", "free-server", "grouped"},
            "paced worker workload differs")
    cpu_groups = plan.get("cpu_groups", False)
    require(cpu_groups is ("grouped" in plan["layouts"]), "paced CPU group mode differs")
    if plan.get("build_scratch"):
        require(plan["layouts"] == ["grouped"], "paced build scratch requires one grouped layout")
    if plan.get("slice_target") == sibling_client_slice.TARGET:
        sibling_client_slice.check_plan(plan)
        sibling_client_slice.check_probe(folder, plan)

    sources = {"quiet-http.go": "quiet_source_sha256", "sibling-driver.py": "harness_sha256",
               "sibling-paced.py": "paced_driver_sha256", "sibling-build.py": "build_driver_sha256"}
    if cpu_groups:
        sources.update({"sibling-group.py": "group_driver_sha256", "sibling_group_affinity_linux.go": "group_affinity_source_sha256"})
        require(plan["cpu_group_label"] == CPU_GROUP_LABEL and
                all(re.fullmatch(r"[0-9a-f]{64}", plan[k]) for k in ("group_affinity_probe_sha256", "group_runner_test_sha256")),
                "paced group proof differs")
        check_group_smoke(folder, plan)
    if plan.get("network_driver"):
        sources["sibling_link_linux.go"] = "link_source_sha256"
    if "network_topology" in plan:
        sources["sibling-topology.py"] = "topology_driver_sha256"
    if plan.get("guest_fair") or plan.get("worker_scheduler"):
        sources["fair-scheduler.sh"] = "fair_hook_sha256"
    if "fair_slice_us" in plan:
        sources["sibling_slice_linux.go"] = "slice_source_sha256"
    if plan.get("builder_shares") is not None:
        sources.update({"weight-driver.py": "weight_driver_sha256", "sibling_weight_linux.go": "weight_source_sha256"})
        require(plan["layouts"] == ["same"] and
                "--- PASS: TestDockerCPUShares" in (folder / "linux-weight-tests.txt").read_text(),
                "paced builder shares qualification differs")
    policy = plan.get("build_policy")
    if policy is not None:
        sources.update({"sibling_build_policy_linux.go": "build_policy_source_sha256",
                        "go-dispatch-policy.sh": "build_policy_dispatch_sha256"})
        require(cpu_groups and policy in ("normal", "batch") and re.fullmatch(r"[0-9a-f]{64}", plan["build_policy_probe_sha256"]) and
                (folder / "go-dispatch-policy.sh").read_text() == sibling_build.POLICY_DISPATCH,
                "paced build policy proof differs")
    require(all(terminal.digest(folder / name) == plan[key] for name, key in sources.items()) and
            re.fullmatch(r"[0-9a-f]{64}", plan["quiet_sha256"]) and
            (folder / "job.sh").read_text() == sibling_build.fanout.JOB and
            (folder / "go-dispatch.sh").read_text() == sibling_build.DISPATCH,
            "paced probe, driver or build inputs changed")

    service, go = read(folder, "images.json"), read(folder, "go-image.json")
    service_ids = {"A": "sha256:" + service["expected"]["config"], "B": "sha256:" + service["expected"]["manifest"]}
    go_ids = {"A": "sha256:" + sibling_build.CONFIG, "B": go["expected"]["manifest_id"]}
    for receipt, ids in ((service, service_ids), (go, go_ids)):
        require(all(row["Id"] == ids[arm] and row["Os"] == "linux" and row["Architecture"] == "arm64"
                    for arm, row in receipt["inspected"].items()) and receipt["inspected"].keys() == ids.keys(),
                "paced service or build image identity differs")
    require(service["inspected"]["B"]["RootFS"]["Layers"] == ["sha256:" + service["expected"]["diff_id"]] and
            go["expected"]["ci_config_sha256"] == sibling_build.CONFIG and
            go["inspected"]["B"]["RootFS"]["Layers"] == go["expected"]["layer_ids"], "paced image layers differ")
    return {"service": service_ids, "build": go_ids}


def check_boot(folder, plan):
    build = read(folder, "worker-build.json")
    job = plistlib.loads((folder / "a/job.plist").read_bytes())
    env = job["EnvironmentVariables"]
    role = plan.get("mac_process_type", "Standard")
    identity = read(folder, "worker-identity.json")
    effective = read(folder, "a/worker.json")
    require(job["ProgramArguments"] == [build["worker_executable"], "ci", "serve"] and job["ProcessType"] == role and
            env["MICROPOD_CI_CPUS"] == "4" and env["MICROPOD_CI_MEMORY_MIB"] == "4096" and
            env["MICROPOD_CI_KERNEL"] == effective["kernel"] and
            read(folder, "launch-role.json")["spawn_type"] == {"Standard": "daemon (3)", "Interactive": "interactive (4)"}[role] and
            identity["candidate_sha256"] == build["worker_executable_sha256"], "paced worker process or resources differ")

    worker, wake = plan.get("worker_scheduler"), plan.get("worker_next_buddy", False)
    fair = plan.get("guest_fair")
    args = ["micropod.ci_sched=" + worker] if worker and worker != "inherit" else []
    if wake:
        args.append("micropod.ci_wakeup=next-buddy")
    require(env.get("MICROPOD_SANDBOX_KERNEL_ARGS") == (" ".join(args) or None) and
            build["guest_start_sha256"] == build["compiled_sources"]["ci/runner/start.sh"] ==
            terminal.digest(Path(build["arena"]) / "micropod-oci-tools/runner/start.sh"),
            "paced worker scheduler arguments or startup script differ")
    scheduler = None
    if worker or fair:
        scheduler = sibling_sched.read(folder / "fair-scheduler", fair or "inherit", worker, wake)
        require(scheduler == read(folder, "fair-scheduler.json") and scheduler["clocksource"] == "arch_sys_counter",
                "paced guest scheduler state differs")
    if plan.get("slice_target") == sibling_client_slice.TARGET:
        sibling_client_slice.check_scheduler(scheduler)

    pages = plan["pages"]
    facts = (folder / "a/guest-facts.txt").read_text().splitlines()
    boot, = [line.removeprefix("boot=") for line in facts if line.startswith("boot=")]
    require(re.fullmatch(BOOT_ID, boot) and
            "machine=aarch64" in facts and "config_sha256=" + pages["kernel_config_sha256"] in facts,
            "paced guest kernel or boot identity differs")
    active_kernel = Path(effective["kernel"])
    if pages.get("kernel_bounded_buddy"):
        import build_bounded_buddy

        require(pages.get("kernel_ipvlan") is True and pages["kernel_page_kib"] == 16 and worker and scheduler and
                "NO_BOUNDED_BUDDY" in scheduler["before"] and ("BOUNDED_BUDDY" in scheduler["after"]) == (fair == "bounded-buddy"),
                "paced bounded-buddy readback differs")
        descriptor = build_bounded_buddy.verify_archived(folder, active_kernel)["candidate"]
    elif pages.get("kernel_ipvlan"):
        import build_ipvlan

        require(pages["kernel_ipvlan"] is True and pages["kernel_page_kib"] == 16 and "kernel_hz" not in pages,
                "paced IPvlan kernel differs")
        descriptor = build_ipvlan.verify_archived(folder, active_kernel)["candidate"]
    else:
        require(plan.get("network_driver") != "ipvlan" and terminal.digest(active_kernel) == pages["kernel_image_sha256"],
                "paced active kernel differs")
        if pages.get("kernel_hz") == 1000:
            descriptor = read(folder, "tick-build.json")["candidate"]
        else:
            descriptor = read(folder, "kernel-page-pair.json")["candidate" if pages["kernel_page_kib"] == 16 else "control"]
    require(descriptor["page_kib"] == pages["kernel_page_kib"] and descriptor["embedded_config_verified"] and
            descriptor["image_sha256"] == pages["kernel_image_sha256"] and descriptor["config_sha256"] == pages["kernel_config_sha256"],
            "paced kernel receipt differs from the plan")
    return boot, {"worker": build["worker_executable_sha256"], "guest": build["guest_runner_sha256"],
                  "guest_start": build["guest_start_sha256"], "scheduler": scheduler}


def check_cohorts(folder, plan, layout, images):
    inventory = read(folder, f"{layout}-inventory.json")
    counts = read(folder, f"{layout}-cpu.json")
    prime = read(folder, f"{layout}-prime.json")
    driver = plan.get("network_driver")
    target = plan.get("slice_target", "all")
    placement_proof = check_placement_inventory(inventory, plan, layout) if plan.get("cpu_groups") else None
    require(set(inventory) == set(counts) == set(prime) == {"A", "B"}, "missing paced engine cohort")
    boot_ids = {}
    for arm in "AB":
        cohort = inventory[arm]
        jobs = cohort["jobs"]
        require(len(jobs) == len({j["id"] for j in jobs}) == len({j["ip"] for j in jobs}) == PAIRS * 2 and
                [j["id"] for j in jobs] == [row["id"] for row in counts[arm]], "invalid paced sibling inventory")
        if driver and not plan.get("cpu_groups"):
            check_network(cohort["inspect"], cohort["network"], cohort["network_id"], Path(plan["scope"]).name, driver)
        for pos, (j, delta) in enumerate(zip(jobs, counts[arm], strict=True)):
            builder = PAIRS <= pos < PAIRS + BUILDERS
            mask = placement_proof["groups"][j["cpu_group"]] if placement_proof else placement(layout, pos % PAIRS, pos >= PAIRS)
            expected_docker_mask = "" if layout == "shared" else mask
            limits = j["cgroup"]
            require(j["mask"] == limits["cpuset.cpus.effective"] == mask and
                    j["docker_cpuset"] == expected_docker_mask and limits["cpu.max"] == "100000 100000" and
                    limits["memory.max"] == str((512 if builder else 128) << 20) and
                    limits["pids.max"] == ("192" if builder else "64") and limits["gomaxprocs"] == 1 and
                    j.get("go_image") == (sibling_build.IMAGE if builder else None) and
                    delta["delta"] and all(type(v) is int and v >= 0 for v in delta["delta"].values()),
                    f"paced resources differ for {j['name']}")
            if plan.get("cpu_groups"):
                require(j["docker_inspect"]["Image"] == images["build" if builder else "service"][arm],
                        f"paced container image differs for {j['name']}")
                check_cpu_delta(j, delta)
                if plan.get("build_policy"):
                    sibling_build.check_http_policy(j["http_policy_threads"], j["affinity"]["pid"], j["mask"])
            if driver:
                check_link(j["endpoint"], driver, j["ip"])
            if "fair_slice_us" in plan:
                requested = 1_000 * plan["fair_slice_us"]
                require(j["requested_slice_ns"] == (requested if target == "all" else 0), "incorrect paced service slice")
                check_threads(j["threads"], j["server_pid"], j["requested_slice_ns"])
                client_ns = requested if target != "build-clients" or builder else 0
                if target == sibling_client_slice.TARGET:
                    sibling_client_slice.check_service(j)
                    client_ns = sibling_client_slice.requested_ns(arm, requested)
                if pos >= PAIRS:
                    require(j["client_slice_ns"] == client_ns, "incorrect paced receiver slice")
            shares = plan.get("builder_shares")
            if shares is not None:
                expected = shares if builder else 0
                require(j["cpu_shares"] == expected and (0 < j["weight"] < 100 if expected else j["weight"] == 100),
                        "incorrect paced cgroup weight")
        boot_ids[arm] = sibling_build.check_revision(prime[arm], "sib-prime", jobs[PAIRS]["name"])["boot"]
        require(re.fullmatch(BOOT_ID, boot_ids[arm]), "missing paced cohort boot ID")
        if plan.get("builder_shares") is not None:
            cases = read(folder, f"cpu-weight-{arm}.json")
            require([c["case"] for c in cases] == ["solo", "paired", "reversed"], "missing paced CPU contention cases")
            for case, indices in zip(cases, ([32], [32, 40], [40, 32]), strict=True):
                clients = [jobs[index] for index in indices]
                require(case["ids"] == [j["id"] for j in clients] and sibling_weight.check(case["raw"], clients) == case["summary"],
                        "paced CPU contention proof differs")
    return inventory, placement_proof, boot_ids


def read_wire(folder, tag):
    with gzip.open(folder / f"{tag}.json.gz", "rt", encoding="utf-8") as raw:
        return json.load(raw)


def replay(folder):
    plan = read(folder, "plan.json")
    images = check_inputs(folder, plan)
    boot, worker = check_boot(folder, plan)
    saved = read(folder, "windows.json")
    randomizer = random.Random(plan["seed"])
    last_finish = {"A": 0, "B": 0}
    rate = plan["offered_rps"]
    n = plan["rounds"]
    build_policy = plan.get("build_policy")
    check_client_slice = plan.get("slice_target") == sibling_client_slice.TARGET
    seen = set()
    windows = {}
    placements = {}
    peer_boot = None
    totals = {"offered_requests": 0, "completed_requests": 0, "warm_connections": 0,
              "jobs": 0, "revisions": 0, "test_passes": 0}
    for layout in plan["layouts"]:
        inventory, group, boot_ids = check_cohorts(folder, plan, layout, images)
        if plan.get("build_scratch"):
            sibling_tmpfs.verify_archived(folder, plan, inventory)
        require(boot_ids["A"] == boot and boot != boot_ids["B"] and peer_boot in (None, boot_ids["B"]),
                "paced cohorts disagree about the measured guest boots")
        peer_boot = boot_ids["B"]
        if group:
            placements[layout] = group
        orders = ["AB", "BA"] * ((n + 1) // 2)
        randomizer.shuffle(orders)
        dense = []
        for block, order in enumerate(orders[:n]):
            for mode in ("one", "all"):
                key = f"{layout}-{block}-{mode}"
                store = saved[key]
                require(store.keys() == {"order", "A", "B"} and store["order"] == order, f"paced engine order differs for {key}")
                seen.add(key)
                pair = {"order": order}
                for arm in order:
                    tag = key + "-" + arm
                    http = read_wire(folder, tag)
                    jobs = inventory[arm]["jobs"]
                    page_bytes = plan["pages"]["kernel_page_kib"] * 1024 if arm == "A" else 4096
                    for item in http:
                        window = item["receipt"]["window"]
                        require(window["scheduled_unix_ns"] > last_finish[arm], f"overlapping or reordered paced waves in engine {arm}")
                        if build_policy:
                            client = jobs[PAIRS + item["index"]]
                            sibling_build.check_http_policy(window["threads"], window["pid"], client["mask"])
                            if check_client_slice:
                                sibling_client_slice.check_client(item["receipt"], client, arm, plan["fair_slice_us"] * 1_000,
                                                                 paced=mode == "all")

                    if mode == "one":
                        index = block % PAIRS
                        actual = score_unpaced(http, jobs, PAIRS, [index], plan["requests_per_client"], arm)
                        response = http[0]["receipt"]
                        require(not response.get("pace") and response["window"]["page_bytes"] == page_bytes and
                                response["url"] == f"http://{jobs[index]['ip']}:8080/id" and actual == store[arm],
                                f"unpaced control evidence differs for {tag}")
                    else:
                        result = score_wave(http, jobs, rate, page_bytes)
                        build_rows = read(folder, f"{tag}-go.json")
                        builds = score_builds(build_rows, jobs, block, plan["build_nice"],
                                              result["scheduled_unix_ns"], build_policy, expected_boot=boot_ids[arm])
                        if check_client_slice:
                            sibling_client_slice.check_builds(build_rows)
                        actual = {field: result[field] for field in LIVE_SCORE_FIELDS}
                        require({**actual, "build": builds} == store[arm], f"stored paced wave differs for {tag}")
                        result.update(build_overlap(http, build_rows, result))
                        result.update(build=builds, build_makespan_s=builds["makespan_s"], slowest_build_s=builds["slowest_job_s"])
                        pair[arm] = result
                        totals["offered_requests"] += result["offered_requests"]
                        totals["completed_requests"] += result["requests"]
                        totals["warm_connections"] += PAIRS
                        for field in ("jobs", "revisions", "test_passes"):
                            totals[field] += builds[field]
                    last_finish[arm] = max(item["receipt"]["window"]["finished_unix_ns"] for item in http)
                if mode == "all":
                    a, b = pair["A"], pair["B"]
                    require(a["per_client_requests"] == b["per_client_requests"] and
                            a["build"]["products"] == b["build"]["products"], f"offered schedule or build outputs differ for {key}")
                    dense.append(pair)
        windows[layout] = dense
    require(seen == saved.keys(), "unplanned paced waves")
    return {"plan": plan, "boot": boot, "peer_boot": peer_boot, "worker": worker, "images": images,
            "placements": placements, "rows": windows, "totals": totals}


def paired_summary(control, candidate, metric, labels):
    first, second = labels
    pairs = list(zip(control, candidate, strict=True))
    ratio = median(b / a for a, b in pairs) if metric != "first_build_end_margin_ns" and all(control) else None
    return {second: median(candidate), first: median(control), "paired_ratio": ratio,
            "paired_difference": median(b - a for a, b in pairs),
            f"{second}_higher": sum(b > a for a, b in pairs),
            f"{second}_lower": sum(b < a for a, b in pairs), "pairs": len(pairs)}


def paired_metrics(rows):
    result = {}
    for metric in PAIRED_METRICS:
        micropod, orbstack = ([row[arm][metric] for row in rows] for arm in "AB")
        result[metric] = paired_summary(orbstack, micropod, metric, ("orbstack", "micropod"))
    return result


def pacing_timers(rows):
    return {arm: {"max_clock_calibration_ns": max(wave[arm]["max_clock_calibration_ns"] for wave in rows),
                  "timer_slack_ns": sorted({ns for wave in rows for ns in wave[arm]["timer_slack_ns"]})} for arm in "AB"}


def build_overlap_by_wave(rows):
    return [{"block": block, **{arm: {name: row[arm][name] for name in BUILD_OVERLAP_METRICS} for arm in "AB"}}
            for block, row in enumerate(rows)]


def source_plans(folders):
    paths = [p.resolve() for p in folders]
    require(len(set(paths)) == len(paths) > 0, "duplicate or missing paced boot directories")
    plans = [read(path, "plan.json") for path in paths]
    require(len({(p["offered_rps"], p["seed"]) for p in plans}) == len(paths), "duplicate paced rate and seed")
    first = plans[0]
    varies = {"scope", "seed", "offered_rps", "layouts"}
    common = {k: v for k, v in first.items() if k not in varies}
    require(all({k: v for k, v in p.items() if k not in varies} == common and
                set(p["layouts"]) == set(first["layouts"]) for p in plans), "unmatched paced workload or protocol")
    return dict(zip(paths, plans, strict=True))


def scheduler_identity(worker, profile):
    scheduler = worker["scheduler"]
    require(scheduler is not None and scheduler["setting"] == "inherit" and
            scheduler["base_slice_ns"] == sibling_sched.WORKER[profile] and
            scheduler["before"] == scheduler["after"] and
            {"HRTICK", "NEXT_BUDDY", "PICK_BUDDY"} <= set(scheduler["after"]) and
            scheduler["clocksource"] == "arch_sys_counter", "unexpected paced scheduler readback for " + profile)
    return {**worker, "scheduler": {k: v for k, v in scheduler.items() if k != "base_slice_ns"}}


def verify_runs(plans, *, compare_scheduler=False):
    require(len({p["scope"] for p in plans.values()}) == len(plans), "duplicate paced boot scope")
    runs = {}
    boots = set()
    identity = None
    for path, plan in plans.items():
        run = replay(path)
        require(run["plan"] == plan, "paced plan changed during replay")
        require(run["boot"] not in boots, "duplicate Micropod boot ID")
        boots.add(run["boot"])
        worker = run["worker"]
        if compare_scheduler:
            worker = scheduler_identity(worker, plan["worker_scheduler"])
        receipt = (worker, run["images"])
        identity = receipt if identity is None else identity
        require(receipt == identity, "unmatched paced worker, guest scheduler or image")
        runs[path] = run
    return runs


def summarize(runs):
    first_run = next(iter(runs.values()))
    first = first_run["plan"]
    rates = {}
    for path, run in runs.items():
        rates.setdefault(run["plan"]["offered_rps"], []).append((path.name, run))
    result = {"kernel": first["pages"], "network_driver": first.get("network_driver", "bridge"),
              "build_policy": first.get("build_policy"), "build_nice": first["build_nice"], "worker": first_run["worker"],
              "duration_ns": OFFER_NS, "pairs_per_wave": PAIRS, "concurrent_builds": BUILDERS, "rates": {}}
    for field in ("network_topology", "build_scratch", "slice_target", "fair_slice_us"):
        if field in first:
            result[field] = first[field]
    for rate, runs in sorted(rates.items()):
        layouts = first["layouts"]
        records = [{"run": name, "seed": run["plan"]["seed"], "boot": run["boot"], "placements": run["placements"],
                    "layouts": {layout: paired_metrics(run["rows"][layout]) for layout in layouts},
                    "build_overlap_by_wave": {layout: build_overlap_by_wave(run["rows"][layout]) for layout in layouts},
                    "timers": {layout: pacing_timers(run["rows"][layout]) for layout in layouts}, "totals": run["totals"]}
                   for name, run in runs]
        totals = {name: sum(record["totals"][name] for record in records) for name in records[0]["totals"]}
        result["rates"][str(rate)] = {
            "boot_count": len(runs), "windows_per_layout_per_boot": first["rounds"],
            "offered_requests_per_engine_per_window": offered_slots(rate, OFFER_NS), "totals": totals, "by_boot": records,
            "layouts": {layout: paired_metrics([row for _, run in runs for row in run["rows"][layout]]) for layout in layouts},
        }
    return result


def pool(folders):
    return summarize(verify_runs(source_plans(folders)))


def contrast_metrics(matched):
    return {
        engine: {metric: paired_summary([a[arm][metric] for a, _ in matched], [b[arm][metric] for _, b in matched],
                                        metric, ("control", "candidate")) for metric in CONTRAST_METRICS}
        for arm, engine in (("A", "micropod"), ("B", "orbstack"))
    }


def grouped_seed_summary(seed, control, candidate, matched, levels, order_field):
    rounds = control["plan"]["rounds"]
    orders = Counter(a["order"] for a, _ in matched)
    require(len(matched) == rounds and orders == {"AB": rounds // 2, "BA": rounds // 2} and
            all(a["order"] == b["order"] for a, b in matched), "unbalanced paced engine order within the matched seed")
    require(all(a[arm]["build"]["products"] == b[arm]["build"]["products"] for a, b in matched for arm in "AB"),
            "paced build outputs changed across comparison arms")
    gates = [run["rows"]["grouped"][0]["A"]["scheduled_unix_ns"] for run in (control, candidate)]
    require(gates[0] != gates[1], "paced comparison boots share the same first gate time")
    boot_order = [level for _, level in sorted(zip(gates, levels, strict=True))]
    return {"seed": seed, "control_boot": control["boot"], "candidate_boot": candidate["boot"],
            order_field: boot_order, "engine_order_counts": dict(orders), "engines": contrast_metrics(matched)}


def compare(control_folders, candidate_folders, *, change="build_nice", scheduler_profiles=None, client_slices=None):
    require(change in CONTRAST_FIELDS.values(), "unknown paced contrast")
    combined = change == "scheduler_and_scratch"
    compare_scheduler = change == "worker_scheduler" or combined
    compare_client_slice = change == "fair_slice_us"
    order_field = GROUPED_CONTRAST_ORDER.get(change)
    require(scheduler_profiles is None or change == "worker_scheduler", "scheduler profiles require a worker-scheduler contrast")
    require(client_slices is None or compare_client_slice, "client slices require a native-client-slice contrast")
    profiles = tuple(scheduler_profiles) if scheduler_profiles is not None else SCHEDULER_PROFILES
    if combined:
        profiles = ("hrtick-125us", "hrtick-250us")
    slices = tuple(client_slices) if client_slices is not None else sibling_client_slice.SLICE_US
    if compare_scheduler:
        require(len(profiles) == 2 and all(isinstance(profile, str) and profile.startswith("hrtick") and
                                           profile in sibling_sched.WORKER for profile in profiles) and
                sibling_sched.WORKER[profiles[0]] != sibling_sched.WORKER[profiles[1]],
                "scheduler contrast requires two distinct HRTICK worker profiles")
    if compare_client_slice:
        require(all(type(us) is int for us in slices) and
                slices in (sibling_client_slice.SLICE_US, sibling_client_slice.INTERMEDIATE_SLICE_US),
                "native client slice contrast requires 0 to 250 or 500 to 750 microseconds")
    expected = {"build_nice": (5, 0), "worker_scheduler": profiles, "fair_slice_us": slices,
                "scheduler_and_scratch": ("125us/overlay", "250us/tmpfs"),
                "build_scratch": sibling_tmpfs.MODES, "network_topology": sibling_topology.MODES}[change]
    controls, candidates = source_plans(control_folders), source_plans(candidate_folders)
    require(controls.keys().isdisjoint(candidates), "paced run appears in both comparison arms")
    control_index = {(p["offered_rps"], p["seed"]): path for path, p in controls.items()}
    candidate_index = {(p["offered_rps"], p["seed"]): path for path, p in candidates.items()}
    require(control_index.keys() == candidate_index.keys(), "unmatched paced rates or seeds")
    varies = {"scope", "worker_scheduler", "build_scratch"} if combined else {"scope", change}
    for (rate, seed), path in control_index.items():
        control, candidate = controls[path], candidates[candidate_index[rate, seed]]
        if order_field:
            require(all(p["layouts"] == ["grouped"] and p.get("cpu_groups") is True and p["rounds"] in (4, 8)
                        for p in (control, candidate)), "paced contrast requires a balanced grouped cohort")
        if compare_scheduler:
            require((control.get("worker_scheduler"), candidate.get("worker_scheduler")) == profiles,
                    f"paced scheduler contrast requires {profiles[0]} to {profiles[1]}")
            if combined:
                require((control.get("build_scratch"), candidate.get("build_scratch")) == sibling_tmpfs.MODES and
                        control.get("network_topology") == candidate.get("network_topology") == "per-job" and
                        control.get("network_driver") == candidate.get("network_driver") == "ipvlan",
                        "packaged worker contrast requires overlay to tmpfs on per-job IPvlan networks")
            for plan in (control, candidate):
                require(rate == 64_000 and plan.get("worker_next_buddy") is True and
                        type(plan["build_nice"]) is int and plan["build_nice"] == 0 and
                        plan.get("guest_fair") in (None, "inherit") and plan.get("build_policy") in (None, "normal") and
                        all(plan.get(field) is None for field in ("fair_slice_us", "build_slice_us", "builder_shares")),
                        "paced scheduler contrast requires 64k at nice 0 with HRTICK and NEXT_BUDDY")
        elif compare_client_slice:
            require((control.get(change), candidate.get(change)) == expected,
                    f"paced native client slice contrast requires {slices[0]} to {slices[1]} microseconds")
            for plan in (control, candidate):
                sibling_client_slice.check_plan(plan)
        elif change == "build_scratch":
            require((control.get(change), candidate.get(change)) == expected,
                    "paced build scratch contrast requires overlay to tmpfs")
        elif change == "network_topology":
            require((control.get(change), candidate.get(change)) == expected and
                    control.get("network_driver") == candidate.get("network_driver") == "ipvlan",
                    "paced network topology contrast requires shared to per-job IPvlan")
        else:
            require(type(control[change]) is type(candidate[change]) is int and (control[change], candidate[change]) == expected,
                    "paced build priority contrast requires nice +5 to 0")
        require({k: v for k, v in control.items() if k not in varies} ==
                {k: v for k, v in candidate.items() if k not in varies},
                f"unmatched paced comparison inputs for rate {rate} and seed {seed}")

    verified = verify_runs(controls | candidates, compare_scheduler=compare_scheduler)
    contrast = {"change": {change: list(expected)}, "rates": {}}
    if combined:
        contrast["change"] = {"worker_scheduler": list(profiles), "build_scratch": list(sibling_tmpfs.MODES)}
    if compare_scheduler:
        contrast["base_slice_ns"] = [sibling_sched.WORKER[profile] for profile in profiles]
    if compare_client_slice:
        contrast["slice_target"] = sibling_client_slice.TARGET
    if order_field:
        require(len({run["peer_boot"] for run in verified.values()}) == 1, "paced comparison changed the OrbStack boot")
    for rate in sorted({rate for rate, _ in control_index}):
        seeds = sorted(seed for offered_rps, seed in control_index if offered_rps == rate)
        boots = [(verified[control_index[rate, seed]], verified[candidate_index[rate, seed]]) for seed in seeds]
        plan = boots[0][0]["plan"]
        by_layout = {layout: [list(zip(a["rows"][layout], b["rows"][layout], strict=True)) for a, b in boots]
                     for layout in plan["layouts"]}
        layouts = {layout: contrast_metrics([pair for windows in by_boot for pair in windows])
                   for layout, by_boot in by_layout.items()}
        result = {"seeds": seeds, "boot_pairs": len(boots),
                  "windows_per_layout_per_boot": plan["rounds"], "layouts": layouts}
        if order_field:
            result["by_seed"] = [grouped_seed_summary(seed, a, b, windows, expected, order_field)
                                 for seed, (a, b), windows in zip(seeds, boots, by_layout["grouped"], strict=True)]
        contrast["rates"][str(rate)] = result
    return {"control": summarize({path: verified[path] for path in controls}),
            "candidate": summarize({path: verified[path] for path in candidates}), "contrast": contrast}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pool", nargs="+", type=Path, required=True)
    parser.add_argument("--compare-to", nargs="+", type=Path, help="control boots matched to candidate boots in --pool")
    parser.add_argument("--contrast", choices=CONTRAST_FIELDS, default="build-nice",
                        help="select the configuration change between matched boots")
    parser.add_argument("--scheduler-profiles", nargs=2, metavar=("CONTROL", "CANDIDATE"),
                        help="HRTICK profiles for --contrast worker-scheduler, defaulting to hrtick-125us hrtick")
    parser.add_argument("--client-slices", type=int, nargs=2, metavar=("CONTROL_US", "CANDIDATE_US"),
                        help="native client slices for --contrast native-client-slice, defaulting to 0 250")
    args = parser.parse_args()
    if args.contrast != "build-nice" and not args.compare_to:
        parser.error("--contrast requires --compare-to")
    if args.scheduler_profiles and args.contrast != "worker-scheduler":
        parser.error("--scheduler-profiles requires --contrast worker-scheduler")
    if args.client_slices and args.contrast != "native-client-slice":
        parser.error("--client-slices requires --contrast native-client-slice")
    result = (compare(args.compare_to, args.pool, change=CONTRAST_FIELDS[args.contrast],
                      scheduler_profiles=args.scheduler_profiles, client_slices=args.client_slices)
              if args.compare_to else pool(args.pool))
    print(json.dumps(result, indent=2))
