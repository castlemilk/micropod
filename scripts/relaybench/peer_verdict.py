"""Assess one completed, matched Gamma published-TCP holdout from local files.

Use --archive to replay the historical study. To qualify a new holdout, pass --run-directory
with the --candidate-sha256, --candidate-workers and --candidate-vcpus selected before timing.
Omitting both resource selections replays the results without qualifying a candidate.
For a plan that selected a launchd role, pass the same --candidate-process-type to qualify it.
The directory must contain the peer driver's
plan.json, handoff.json, fixtures.json (including scope and service_limits), complete.json
and the original per-arm JSON receipts for three warmup and 16 scored pairs. Both admission
observations must bracket the host counters for each attempt. New plans also require the host counters
to bracket the client process from launch through exit. All inputs are read-only.
New holdouts use the checksum-pinned client that records scheduled-arrival p50, p95 and p99.
Each row retains the invoked URL and service marker in client_arguments and the raw
client output must identify one published port for both products. Supply --candidate-read-kib
for a selected nondefault native cap. Historical directories without a cap remain unattributed.

Exit codes are 0 for a qualified result, 1 for a completed comparison that missed the criteria
and 2 for invalid or incomplete evidence. --json includes every scored arm, its errors and
the CPU and runnable-time counters for the individual VMM and relay processes.
"""
import argparse
import json
import math
import re
from pathlib import Path, PurePosixPath
from statistics import median

from gamma_contrasts import GIB, IMAGE, VM, clean_client, host_units, invocation_bulk_bytes, paired_median_interval, process_delta, read_receipt
from gamma_pilot import DIRECT_ROUTE, HASHES, STOCK_KERNEL, arm_settings, check_peer_role, check_peer_stock_controls, plan, require, single_port_client
from host_role import CLIENT_SHA256, LEGACY_P50_CLIENT_SHA256, SPAWN_TYPES, timestamp

ARCHIVE_SHA = "066cd4071f3f926a228d87310f6d7b6f361c38f07c7a8240aa09a57f03f201e4"
LIMITS = {"cpu.max": "400000 100000", "memory.max": "1073741824", "pids.max": "512"}
MIN_COMMON = 15
PRODUCT = {"A": "Micropod", "B": "OrbStack"}


def observation(record, pids, full_body_counts=False):
    c = record["client"]
    # A recorded failure has an outcome. An absent or malformed record cannot count as a failed peer.
    stream_bytes = c["per_stream_bytes"]
    require(c["streams"] == 32 and c["arrivals"] == 240 and c["period_us"] == 25000
            and len(stream_bytes) == 32 and all(type(n) is int and n >= 0 for n in stream_bytes)
            and sum(stream_bytes) == c["bytes"] and c["bytes"] > 0 and math.isfinite(c["mib_s"])
            and c["mib_s"] > 0 and c["window_s"] >= 6
            and math.isclose(c["bytes"] / 2**20 / c["window_s"], c["mib_s"])
            and type(c["reopened"]) is int and c["reopened"] >= 0
            and (c["errors"] is None or isinstance(c["errors"], list)),
            "malformed fixed-load client receipt")
    errors = c["errors"] or []
    require(all(isinstance(e, str) and e for e in errors), "invalid client errors")
    clean = record["exit_code"] in (None, 0) and clean_client(c)
    require(record["clean"] is clean, "recorded clean status disagrees with raw client")
    p50, p95, p99 = (c.get(f"fresh_p{q}_us") for q in (50, 95, 99))
    require(type(p95) is int and type(p99) is int and 0 <= p95 <= p99
            and (p50 is None or type(p50) is int and 0 <= p50 <= p95), "invalid fresh percentiles")
    before, after = record["before"], record["after"]
    require((after["epoch_ns"] - before["epoch_ns"]) / 1e9 >= c["window_s"],
            "host counters do not cover the reported client window")
    for sample in (before, after):
        require(sorted(t["pid"] for t in sample["tasks"]) == sorted(pids.values()), "process identity mismatch")
    whole = invocation_bulk_bytes(c, clean) if full_body_counts else None
    processes = {}
    for role, pid in pids.items():
        delta = process_delta(before, after, pid)
        costs = host_units(delta, c["bytes"])
        require(all(math.isfinite(n) and n >= 0 for n in costs.values()), "invalid host counter")
        processes[role] = dict(pid=pid, **delta, **costs,
                               invocation_cpu_s_per_bulk_gib=delta["cpu_s"] / (whole / GIB) if whole else None)
    host = processes.values()
    verified_fresh_errors = len(errors) if min(stream_bytes) > 0 and all('/id"' in e for e in errors) else None
    return dict(clean=clean, mib_s=c["mib_s"], fresh_failed=verified_fresh_errors, offered=c["arrivals"],
                bulk_reopens=c["reopened"], client_errors=errors, exit_code=record["exit_code"],
                p50_ms=p50 / 1000 if p50 is not None else None, p95_ms=p95 / 1000, p99_ms=p99 / 1000,
                processes=processes, cpu_s_per_gib=sum(h["cpu_s_per_gib"] for h in host),
                invocation_bulk_bytes=whole,
                invocation_cpu_s_per_bulk_gib=sum(h["cpu_s"] for h in host) / (whole / GIB) if whole else None,
                wait_s_per_s=sum(h["wait_s_per_s"] for h in host),
                runnable_s_per_s=sum(h["runnable_s_per_s"] for h in host))


def assess(orders, pids, get_record, *, full_body_counts=False):
    require(len(orders["warmup"]) == 3 and len(orders["scored"]) == 16, "need three warmups and 16 scored pairs")
    require(all(sorted(orders["scored"][n:n+2]) == ["AB", "BA"] for n in range(0, 16, 2)),
            "scored orders must balance within each two-pair block")
    require(set(pids["A"]) == {"vmm", "relay"} and set(pids["B"]) == {"vmm"} and
            len(set(pids["A"].values()) | set(pids["B"].values())) == 3, "incorrect process coverage")
    previous_end = 0
    births = {}
    rows, ratios, reasons = [], [], []
    for phase in ("warmup", "scored"):
        for number, order in enumerate(orders[phase], 1):
            require(order in ("AB", "BA"), "invalid pair order")
            pair = {"pair": number, "order": order}
            for arm in order:
                record = get_record(phase, number, arm)
                first, last = record["before"], record["after"]
                require(previous_end <= first["epoch_ns"] < last["epoch_ns"], "run windows overlap or contradict the plan")
                previous_end = last["epoch_ns"]
                identity = {t["pid"]: t["birth_ticks"] for t in first["tasks"]}
                require(births.setdefault(arm, identity) == identity, "process replaced across rounds")
                row = observation(record, pids[arm], full_body_counts)
                if phase == "warmup":
                    require(row["clean"], "dirty warmup")
                pair[arm] = row
            if phase == "scored":
                rows.append(pair)
                if not pair["A"]["clean"]:
                    reasons.append(f"Micropod round {number} failed the fixed-work client")
                if pair["A"]["p95_ms"] > 75:
                    reasons.append(f"Micropod round {number} exceeded 75 ms fresh p95")
                if pair["A"]["clean"] and pair["B"]["clean"]:
                    ratios.append(pair["A"]["mib_s"] / pair["B"]["mib_s"])
    interval = paired_median_interval(ratios)
    if len(ratios) < MIN_COMMON:
        reasons.append(f"fewer than {MIN_COMMON} common clean pairs")
    if interval is None or interval[0] <= 1:
        reasons.append("lower 95% paired throughput bound did not exceed parity")
    summary = {}
    for arm, name in PRODUCT.items():
        attempts = [r[arm] for r in rows]
        clean = [r for r in attempts if r["clean"]]
        metrics = ("mib_s", "p50_ms", "p95_ms", "p99_ms", "cpu_s_per_gib",
                   "invocation_cpu_s_per_bulk_gib", "wait_s_per_s", "runnable_s_per_s")
        summary[name] = {k: median(r[k] for r in clean) if clean and all(r[k] is not None for r in clean) else None
                         for k in metrics}
        summary[name].update(clean=len(clean), offered=sum(r["offered"] for r in attempts),
                             known_fresh_failures=sum(r["fresh_failed"] or 0 for r in attempts),
                             unknown_fresh_failure_counts=sum(r["fresh_failed"] is None for r in attempts),
                             bulk_reopens=sum(r["bulk_reopens"] for r in attempts))
    return dict(verdict="qualified on this workload" if not reasons else "did not qualify",
                reasons=reasons, ratio_direction="Micropod/OrbStack", minimum_common_pairs=MIN_COMMON,
                common_clean_pairs=len(ratios), micropod_pair_wins=sum(r > 1 for r in ratios),
                median_ratio=median(ratios) if ratios else None, bootstrap_ci95=interval,
                arm_clean_medians_and_all_attempt_counts=summary, pairs=rows)


def archived():
    # This exact receipt includes the matched quotas, artifacts, schedule and sampler for the historical study.
    receipt = read_receipt(VM, ARCHIVE_SHA)
    arms = {"A": "confirm-micropod", "B": "confirm-orb"}
    scope = {arm: receipt["scopes"][key] for arm, key in arms.items()}
    for s in scope.values():
        require(s["image"] == IMAGE and s["vm"].startswith("4 ") and s["state"]["cpuset.cpus.effective"] == "0-3"
                and all(s["state"][k] == v for k, v in LIMITS.items()), "archived workload controls changed")
    pids = {arm: {k: s[k] for k in ("vmm", "relay") if k in s} for arm, s in scope.items()}
    phases = {phase: receipt["phases"]["grace-" + name] for phase, name in (("warmup", "warmup"), ("scored", "holdout"))}
    letters = {value: key for key, value in arms.items()}
    orders = {p: ["".join(letters[s] for s in entry.split()) for entry in data["orders"]] for p, data in phases.items()}

    def get_record(phase, n, arm):
        r = phases[phase]["runs"][arms[arm]][str(n)]
        # The archived recorder stored client data and a clean flag, without a separate process status.
        return dict(r, exit_code=None)

    return dict(source=VM.name, source_sha256=ARCHIVE_SHA, evidence="historical archive", vcpus=4, image_config=IMAGE,
                installed_package_sha256=receipt["installation"]["host_sha256"], **assess(orders, pids, get_record))


def admission(observation, handoff, scopes):
    require(isinstance(observation, dict) and observation["mode"] == "peer" and observation["scopes"] == scopes
            and all(isinstance(observation[k], str) and observation[k].strip() and observation[k] == handoff[k]
                    for k in ("owner", "reservation", "starts_at", "expires_at")), "wrong peer handoff, owner or fixture scopes")
    disk = observation["effective_disk_gate"]
    require(disk["passed"] is True and isinstance(disk["source"], str) and disk["source"].strip(),
            "missing effective disk clearance")
    fleet = timestamp(observation["fleet_time"])
    start = max(timestamp(observation["starts_at"]), timestamp(disk["checked_at"]), fleet)
    expiry = min(timestamp(observation["expires_at"]), timestamp(disk["expires_at"]))
    checked = timestamp(observation["observed_at"])
    valid_until = observation["valid_until_epoch"]  # May be earlier because an individual runner heartbeat expires.
    require(type(valid_until) in (float, int) and math.isfinite(valid_until)
            and start <= checked < expiry and checked <= valid_until <= min(expiry, fleet + 90),
            "stale or expired peer admission")
    return checked, start, valid_until


def directory(root, candidate_sha, candidate_read_kib=None, *, candidate_workers=None, candidate_vcpus=None,
              candidate_process_type=None):
    def load(name):
        path = root / name
        require(path.is_file(), f"missing regular receipt file: {name}")
        return json.loads(path.read_text())
    schedule, fixtures, completion = load("plan.json"), load("fixtures.json"), load("complete.json")
    require(re.fullmatch("[a-f0-9]{64}", candidate_sha or "") is not None, "need the independently selected CLI SHA-256")
    require(schedule["mode"] == "peer" and schedule["host"].split(".")[0] == "Gamma-128GB"
            and schedule["macos"] and schedule["tools"]["rusage"] == HASHES["rusage"]
            and schedule["tools"]["fixed"] in (CLIENT_SHA256, LEGACY_P50_CLIENT_SHA256)
            and completion["identity_rechecked"] is True and completion["ratio_direction"] == "Micropod/OrbStack",
            "missing completed Gamma peer controls")
    order = plan(schedule["seed"], 16)
    require(order == schedule["order"], "holdout order differs from the seeded schedule")
    a, b = fixtures["A"], fixtures["B"]
    # The same executable can run with different worker counts and VM sizes.
    # Check both the plan and the booted fixtures against the external selection.
    selected = candidate_workers is not None or candidate_vcpus is not None
    planned = schedule["arms"]
    planned_role = planned["A"].get("process_type")
    if candidate_process_type is not None:
        require(candidate_process_type in SPAWN_TYPES and planned_role == candidate_process_type,
                "planned launch role differs from the independently selected process type")
    if planned_role is not None:
        check_peer_role(a, planned_role)
    check_peer_stock_controls(a, planned_role or "Interactive")
    if selected:
        require(type(candidate_workers) is int and candidate_workers in (2, 4)
                and type(candidate_vcpus) is int and candidate_vcpus in (4, 6),
                "supply both --candidate-workers (2 or 4) and --candidate-vcpus (4 or 6)")
    workers = candidate_workers if selected else a["relay_workers"]
    vcpus = candidate_vcpus if selected else a["cpus"]
    worker_counts = (a["relay_workers"], planned["A"]["relay_workers"])
    cpu_counts = (a["cpus"], b["cpus"], planned["A"]["vcpus"], planned["B"]["vcpus"])
    require(all(type(n) is int and n == workers for n in worker_counts),
            "holdout worker count differs from the plan or the selected candidate")
    require(all(type(n) is int and n == vcpus for n in cpu_counts),
            "holdout vCPU count differs from the plan or the selected candidate")
    # One benchmark binary can serve at either read size. Bind a selected cap to
    # the plan and the booted relay. A legacy receipt has neither field.
    selected_read = (candidate_read_kib or 256) * 1024
    expected_arms = arm_settings("peer", workers, vcpus, candidate_read_kib, peer_process_type=planned_role)
    if "read_bytes" not in schedule["arms"]["A"] and a.get("read_bytes") is None and candidate_read_kib is None:
        del expected_arms["A"]["read_bytes"]  # Old receipt, unknown size, no cap-specific conclusion.
    else:
        planned_read = schedule["arms"]["A"].get("read_bytes")
        require(type(a.get("read_bytes")) is int and type(planned_read) is int
                and a["read_bytes"] == planned_read == selected_read,
                "holdout read size differs from the selected or planned relay cap")
    require(planned == expected_arms
            and a["callback_events"] == 128 and a["cli_sha256"] == candidate_sha
            and a["kernel_image_sha256"] == STOCK_KERNEL and a["route"] == DIRECT_ROUTE,
            "candidate hash, path or matched resources differ")
    for f in (a, b):
        require(f["image_config"] == IMAGE and f["cpuset"] == "0-3" and 3.7 * 2**30 < f["memory_bytes"] <= 4 * 2**30
                and f["service_limits"] == LIMITS and f["release"] and f["engine_version"], "missing workload controls")
    require(all(a[k] and b[k] and a[k] != b[k] for k in ("engine", "id", "address", "name")), "fixtures share identity")
    scopes = [a["scope"], b["scope"]]
    for name in scopes:
        path = PurePosixPath(name)
        require(path.is_absolute() and str(path) == name and ".." not in path.parts and not name.startswith("//"),
                "invalid canonical peer fixture scope")
    require(scopes[0] != scopes[1], "fixtures share a scope")
    handoff = load("handoff.json")
    first_check, _, _ = admission(handoff, handoff, scopes)
    timed_clients = "client_timing" in schedule
    if timed_clients:
        require(schedule["client_timing"] == "spawn-to-reap", "unknown peer client timing protocol")

    def get_record(phase, n, arm):
        r = load(f"{phase}-{n}-{arm}.json")
        require((r["phase"], r["pair"], r["arm"]) == (phase, n, arm) and type(r["exit_code"]) is int,
                "first attempt identity or exit status missing")
        require("error" not in r, "interrupted attempt cannot support a completed holdout")
        before, _, first_expiry = admission(r["admission"], handoff, scopes)
        after, last_start, _ = admission(r["admission_after"], handoff, scopes)
        require(first_check <= before <= r["before"]["epoch_ns"] / 1e9
                and r["after"]["epoch_ns"] / 1e9 <= after < timestamp(r["admission"]["effective_disk_gate"]["expires_at"])
                and last_start <= first_expiry,
                "admission observations do not provide continuous coverage around the measured window")
        client = single_port_client(fixtures[arm], r)
        if timed_clients or "client_spawn_start_ns" in r or "client_reaped_ns" in r:
            start, end = r.get("client_spawn_start_ns"), r.get("client_reaped_ns")
            require(type(start) is int and type(end) is int and
                    r["before"]["epoch_ns"] <= start < end <= r["after"]["epoch_ns"],
                    "host counters do not bracket the peer client invocation")
            require(0 < client["window_s"] <= (end - start) / 1e9,
                    "bulk window exceeds peer client lifetime")
        pin = schedule["tools"]["fixed"]
        if pin == CLIENT_SHA256 or "fixed_sha256" in r:
            require(r.get("fixed_sha256") == pin, "attempt load-client hash differs from the peer plan")
        if pin == LEGACY_P50_CLIENT_SHA256:
            require("bulk_body_bytes" not in client, "legacy client cannot emit full-invocation body counters")
        for q in (50, 95, 99):
            value = client.get(f"fresh_p{q}_us")
            require(type(value) is int and value > 0, f"missing or invalid fresh p{q} from selected load client")
        return dict(r, client=client)
    result = assess(order, {arm: f["pids"] for arm, f in fixtures.items()}, get_record,
                    full_body_counts=schedule["tools"]["fixed"] == CLIENT_SHA256)
    if not selected:
        result["reasons"].append("qualification requires independently selected --candidate-workers and --candidate-vcpus")
        result["verdict"] = "did not qualify"
    if planned_role is not None and candidate_process_type is None:
        result["reasons"].append("qualification of the planned launch role requires --candidate-process-type")
        result["verdict"] = "did not qualify"
    return dict(source=str(root), reservation=handoff["reservation"], candidate_sha256=candidate_sha,
                candidate_resources_verified=selected, client_timing=schedule.get("client_timing", "legacy"),
                relay_workers=workers, vcpus=vcpus, candidate_process_type_verified=candidate_process_type is not None,
                process_type=planned_role,
                image_config=IMAGE, relay_read_bytes=a.get("read_bytes"), **result)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--archive", action="store_true", help="replay the pinned November four-vCPU holdout")
    source.add_argument("--run-directory", type=Path, help="completed gamma_pilot.py --mode peer --holdout output")
    parser.add_argument("--candidate-sha256", help="previously selected Micropod executable, required for a run directory")
    parser.add_argument("--candidate-workers", type=int, choices=(2, 4), help="independently selected Micropod relay workers")
    parser.add_argument("--candidate-vcpus", type=int, choices=(4, 6), help="independently selected VM vCPUs for both peers")
    parser.add_argument("--candidate-process-type", choices=tuple(SPAWN_TYPES),
                        help="independently selected Micropod launchd role from --peer-process-type")
    parser.add_argument("--candidate-read-kib", type=int, choices=(256, 512),
                        help="previously selected Micropod read cap, to match --relay-read-kib in the peer pilot")
    parser.add_argument("--json", action="store_true", help="include complete per-attempt results in JSON")
    args = parser.parse_args()
    if args.archive and any(v is not None for v in (args.candidate_sha256, args.candidate_read_kib,
                                                     args.candidate_workers, args.candidate_vcpus, args.candidate_process_type)):
        parser.error("candidate selection applies to a new run directory")
    try:
        result = archived() if args.archive else directory(args.run_directory, args.candidate_sha256, args.candidate_read_kib,
                                                           candidate_workers=args.candidate_workers,
                                                           candidate_vcpus=args.candidate_vcpus,
                                                           candidate_process_type=args.candidate_process_type)
        if args.json:
            print(json.dumps(result, indent=2, allow_nan=False))
        else:
            def fmt(value):
                return "unknown" if value is None else f"{value:.3f}"
            title = "Historical matched published TCP" if args.archive else "Matched published TCP"
            print(f'{title} {result["verdict"]} ({result["common_clean_pairs"]}/16 common clean pairs)')
            if args.run_directory:
                print(f'{result["relay_workers"]} Micropod relay workers, {result["vcpus"]} vCPUs per VM')
                if result["process_type"] is not None:
                    print(f'Micropod launchd role: {result["process_type"]} (independently selected: {result["candidate_process_type_verified"]})')
                cap = result["relay_read_bytes"]
                print(f'Micropod relay read cap: {str(cap // 1024) + " KiB" if cap else "unknown in this receipt"}')
            for name, arm in result["arm_clean_medians_and_all_attempt_counts"].items():
                latency = "/".join(fmt(arm[f"p{q}_ms"]) for q in (50, 95, 99))
                print(f'{name} completed {arm["clean"]}/16 clean rounds at {fmt(arm["mib_s"])} MiB/s, '
                      f'fresh p50/p95/p99 {latency} ms, '
                      f'{fmt(arm["invocation_cpu_s_per_bulk_gib"])} CPU-s per full-invocation bulk GiB '
                      f'({fmt(arm["cpu_s_per_gib"])} invocation CPU-s per scored GiB), '
                      f'{fmt(arm["wait_s_per_s"])} runnable wait thread-s/s, {arm["known_fresh_failures"]} '
                      f'known fresh failures, {arm["unknown_fresh_failure_counts"]} unknown failure counts, '
                      f'{arm["bulk_reopens"]} bulk reopens')
            interval = result["bootstrap_ci95"]
            band = "unavailable" if interval is None else " to ".join(fmt(n) for n in interval)
            print(f'Micropod/OrbStack median ratio {fmt(result["median_ratio"])}, 95% paired interval {band}')
            for reason in result["reasons"]:
                print(reason)
    except (OSError, ValueError, KeyError, TypeError, AttributeError, OverflowError, StopIteration) as exc:
        parser.exit(2, f"Insufficient or invalid holdout evidence: {exc}\n")
    if result["verdict"] != "qualified on this workload":
        parser.exit(1)
