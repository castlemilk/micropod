#!/usr/bin/env python3
"""Extract, replay or attribute recorded Gamma TCP samples offline."""

import argparse
import gzip
import hashlib
import json
import math
import random
import re
import statistics
import subprocess
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "docs/benchmarks/2026-11-22/kernel-path"
RELAY_REV = "86ca2713a0791d26c137e9a8c6385e1b6bd04ebb"
RUNTIME_REVS = {RELAY_REV, "2ee6f14375781702107dafc43322334fabf49e73"}
IMAGE = "sha256:80996a25c9c753fcaf3f421a3f61557497b8ab539bdd68076074d181cfa71889"
CLIENT = "a1e2609f9d052b2765dc717fac1b227a8247aa9e73364bf3962168c30c8ffc53"
STOCK_WINDOW_VERSION = 3
ROUNDS_SHA256 = "82f9803d9d423015d1f2a26086e8bee172b219acf8a3cb5fb72a89b3d6ae686a"
ARCHIVES = {
    "gamma-direct-macvlan": "cc3b9e5c365383a3353423ce1f7fc443c8d858a1af24bb082117bcec24ffa976",
    "gamma-vcpu-priority": "066cd4071f3f926a228d87310f6d7b6f361c38f07c7a8240aa09a57f03f201e4",
    "gamma-vnic": "2d20e203cc135a4a86828b8b365fc7885b225b9b452c276ad1f761fd97556b8f",
}
SERIES = {
    "path-confirmation": ("full-bridge", "full-reno"),
    "path-first": ("new", "direct"),
    "path-holdout-lazy": ("lazy-bridge", "lazy-reno"),
    "bridge-kernel": ("old", "new"),
    "older-relay-vm-holdout": ("confirm-orb", "confirm-micropod"),
    "rps-rfs": ("base", "rfs"),
}


def require(ok, detail):
    if not ok:
        raise ValueError(detail)


def stamp(value):
    require(isinstance(value, str), "missing timestamp")
    value = re.sub(r"(\.\d{6})\d+", r"\1", value).replace("Z", "+00:00")
    dt = datetime.fromisoformat(value)
    require(dt.tzinfo is not None, "timestamp lacks timezone")
    return dt.timestamp()


def disk_expiry(clearance, now):
    require(isinstance(clearance, dict) and clearance.get("passed") is True
            and isinstance(clearance.get("source"), str) and clearance["source"].strip(),
            "missing verified effective disk clearance")
    checked, expires = stamp(clearance.get("checked_at")), stamp(clearance.get("expires_at"))
    require(checked <= now < expires, "stale or future effective disk clearance")
    return expires


def sha(data):
    return hashlib.sha256(data).hexdigest()


def encoded(obj):
    return json.dumps(obj, sort_keys=True, allow_nan=False, separators=(",", ":"))


def archived(tree, name):
    path = f"docs/benchmarks/2026-11-21/{name}.json.gz"
    raw = subprocess.check_output(["git", "-C", tree, "show", f"{RELAY_REV}:{path}"])
    require(sha(raw) == ARCHIVES[name], f"archive digest differs: {path}")
    return json.loads(gzip.decompress(raw))


def window(source, scope, tag, arm, number, order, expected):
    row = dict(
        series=tag,
        block=int(number),
        arm=arm,
        order=order,
        client=source["client"],
        archived_clean=expected,
        cpu=None,
        link=None,
    )
    for stage in ("before", "after"):
        if stage not in source:
            continue
        s = source[stage]
        snap = {k: s[k] for k in ("epoch_ns", "tick_numer", "tick_denom")}
        for role in ("vmm", "relay"):
            if role in scope:
                pid = int(scope[role])
                (process,) = (t for t in s["tasks"] if t["pid"] == pid)
                snap[role] = {
                    k: process[k]
                    for k in ("pid", "birth_ticks", "user_ticks", "system_ticks", "runnable_ticks")
                }
        if row["cpu"] is None:
            row["cpu"] = {}
        row["cpu"][stage] = snap
    if source.get("linkbefore") and source.get("linkafter"):
        row["link"] = {k: source["link" + k]["published_link"] for k in ("before", "after")}
    return row


def extract(tree, dest):
    dest.mkdir()
    out = []
    path = archived(tree, "gamma-direct-macvlan")
    require(
        path["image_config_sha256"] == IMAGE.split(":")[1] and path["sha256"]["fixed"] == CLIENT,
        "fixture mismatch",
    )
    for tag, group in (
        ("path-confirmation", "confirmation"),
        ("bridge-kernel", "matched"),
        ("path-first", "matched"),
        ("path-holdout-lazy", "kernel-holdout"),
    ):
        scopes = path["records"]["holdout_workers" if group == "kernel-holdout" else "workers"]
        for n, pair in sorted(path["records"][group].items(), key=lambda x: int(x[0])):
            for arm in SERIES[tag]:
                scope = scopes[arm]
                st = scope["state"]
                require(
                    scope["image"] == IMAGE
                    and st["cpu.max"] == "400000 100000"
                    and st["cpuset.cpus.effective"] == "0-3"
                    and st["memory.max"] == "1073741824"
                    and st["pids.max"] == "512",
                    "historical fixture limits differ",
                )
                raw = pair["engines"][arm]
                out.append(window(raw, scope, tag, arm, n, pair["order"], raw["valid"]))
    vm = archived(tree, "gamma-vcpu-priority")
    require(
        vm["binaries"]["client"] == CLIENT and vm["binaries"]["image_config"] == IMAGE,
        "holdout fixture mismatch",
    )
    old = vm["phases"]["grace-holdout"]
    for arm, trials in old["runs"].items():
        for n, raw in sorted(trials.items(), key=lambda x: int(x[0])):
            out.append(
                window(
                    raw,
                    vm["scopes"][arm],
                    "older-relay-vm-holdout",
                    arm,
                    n,
                    old["orders"][int(n) - 1].split(),
                    raw["clean"],
                )
            )
    nic = archived(tree, "gamma-vnic")
    for arm in SERIES["rps-rfs"]:
        for n in range(6):
            key = f"qdisc/{n}-{arm}.mixed"
            sample = nic["raw"][key]
            out.append(
                dict(
                    series="rps-rfs",
                    arm=arm,
                    block=n,
                    order=None,
                    client=sample,
                    archived_clean=nic["raw"][key + "-status"] == 0,
                    cpu=None,
                    link=None,
                )
            )
    (dest / "rounds.jsonl").write_text("".join(encoded(r) + "\n" for r in out))
    proof = {}
    for arm in SERIES["path-confirmation"]:
        s = path["records"]["workers"][arm]
        nic_name = "eth0" if arm == "full-bridge" else "mppub0"
        (route,) = (x for x in s["routes.json"][nic_name] if x.get("Congctl") == "reno")
        proof[arm] = dict(
            release=s["state"]["release"],
            image=s["image"],
            cpu_max=s["state"]["cpu.max"],
            cpuset=s["state"]["cpuset.cpus.effective"],
            memory=s["state"]["memory.max"],
            pids=s["state"]["pids.max"],
            route={k: route[k] for k in ("RtoMin", "RtoMinLock", "Congctl", "QuickACK", "MTU")},
            accepted_controller=s.get("controller"),
            path_tx_bytes=s["tx_delta"],
        )
    index = dict(
        source_revision=RELAY_REV,
        archives_sha256=ARCHIVES,
        rounds_sha256=sha((dest / "rounds.jsonl").read_bytes()),
        image=IMAGE,
        client_sha256=CLIENT,
        full_kernel_image_sha256=path["kernels"]["full"]["image_sha256"],
        full_kernel_config_sha256=path["kernels"]["full"]["config_sha256"],
        confirmation_path_readback=proof,
        older_holdout_host_binary=vm["installation"]["host_sha256"],
    )
    (dest / "index.json").write_text(json.dumps(index, indent=2) + "\n")


def cpu(before, after, role, count):
    require(
        before["tick_numer"] == after["tick_numer"]
        and before["tick_denom"] == after["tick_denom"]
        and min(before["tick_numer"], before["tick_denom"]) > 0
        and count > 0,
        "invalid counter scale",
    )
    x, y = before[role], after[role]
    require((x["pid"], x["birth_ticks"]) == (y["pid"], y["birth_ticks"]), "counter process identity changed")
    scale = before["tick_numer"] / before["tick_denom"] / 1e9
    parts = [y[k] - x[k] for k in ("system_ticks", "user_ticks", "runnable_ticks")]
    require(min(parts) >= 0 and after["epoch_ns"] > before["epoch_ns"], "counter reset")
    seconds = (parts[0] + parts[1]) * scale
    interval = (after["epoch_ns"] - before["epoch_ns"]) / 1e9
    return dict(
        cpu_s_per_gib=seconds / (count / 2**30),
        cpu_ns_per_byte=seconds * 1e9 / count,
        cpu_seconds=seconds,
        counter_window_s=interval,
        runnable_wait_thread_s_per_s=(parts[2] * scale - seconds) / interval,
    )


def complete_bulk_streams(client):
    values = client["per_stream_bytes"]
    return (
        type(client["streams"]) is int and client["streams"] == 32
        and isinstance(values, list) and len(values) == client["streams"]
        and all(type(count) is int and count > 0 for count in values)
        and type(client["bytes"]) is int and sum(values) == client["bytes"]
    )


def fixed_bulk_rate(client):
    rate = client["bytes"] / 2**20 / client["window_s"]
    require(math.isclose(rate, client["mib_s"]), "reported bulk rate differs from bytes and window")
    return rate


def measure(row):
    c = row["client"]
    if row["series"] == "rps-rfs":
        b = c["overlap_bytes_per_stream"]
        fresh = c["fresh"]
        require(
            len(b) == c["streams"] == 32
            and min(b) > 0
            and sum(b) == c["overlap_bytes"]
            and fresh["iterations"] == 150
            and math.isclose(c["overlap_mib_s"], c["overlap_bytes"] / 2**20 / c["overlap_s"]),
            "closed-loop byte or workload mismatch",
        )
        return dict(
            clean=row["archived_clean"] and c["reopened_connections"] == 0,
            mib_s=c["overlap_mib_s"],
            p95_ms=fresh["complete_ns"]["p95"] / 1e6,
            p99_ms=fresh["complete_ns"]["p99"] / 1e6,
            seconds=c["overlap_s"],
            offered=150,
            fresh_failed=None,
            reopened=c["reopened_connections"],
        )
    require(
        c["arrivals"] == 240 and c["period_us"] == 25000 and c["streams"] == 32 and c["window_s"] >= 6,
        "different offered workload",
    )
    bulk = complete_bulk_streams(c)
    rate = fixed_bulk_rate(c)
    require(0 < c["fresh_p95_us"] <= c["fresh_p99_us"], "invalid fresh latency tails")
    ok = bulk and c["reopened"] == 0 and c["errors"] in (None, [])
    require(ok == row["archived_clean"], "archive disagrees with replayed assertions")
    err = c["errors"] or []
    r = dict(
        clean=ok,
        bulk_payload_bytes=c["bytes"],
        mib_s=rate,
        p95_ms=c["fresh_p95_us"] / 1000,
        p99_ms=c["fresh_p99_us"] / 1000,
        seconds=c["window_s"],
        offered=240,
        fresh_failed=len(err) if bulk and all('/id"' in s for s in err) else None,
        reopened=c["reopened"],
    )
    if row["cpu"]:
        a, b = row["cpu"]["before"], row["cpu"]["after"]
        for role in ("vmm", "relay"):
            if role in a:
                r[role] = cpu(a, b, role, c["bytes"])
    if row["link"]:
        a, b = row["link"]["before"], row["link"]["after"]
        r["link_drops"] = sum(b[k] - a[k] for k in ("rx_dropped", "tx_dropped"))
        require(r["link_drops"] >= 0, "link counters reset")
    return r


def recorded_scores(source):
    index = json.loads((source / "index.json").read_text())
    raw = (source / "rounds.jsonl").read_bytes()
    require(
        sha(raw) == index["rounds_sha256"] == ROUNDS_SHA256 and index["archives_sha256"] == ARCHIVES,
        "receipt integrity",
    )
    scores = {}
    for line in raw.splitlines():
        row = json.loads(line)
        slots = scores.setdefault(row["series"], {}).setdefault(row["arm"], {})
        require(row["block"] not in slots, "duplicate arm in paired block")
        slots[row["block"]] = {**measure(row), "order": row["order"]}
    return scores


def replay(source):
    scores = recorded_scores(source)
    out = {}
    for tag, (left, right) in SERIES.items():
        arms = scores[tag]
        a, b = arms[left], arms[right]
        require(a.keys() == b.keys(), "incomplete schedule")
        common = [i for i in sorted(a) if a[i]["clean"] and b[i]["clean"]]
        ratios = [b[i]["mib_s"] / a[i]["mib_s"] for i in common]
        rng = random.Random(7317)
        draws = sorted(statistics.median(rng.choices(ratios, k=len(ratios))) for _ in range(10000))
        block = dict(
            control=left,
            candidate=right,
            paired_blocks=common,
            paired_ratios=ratios,
            paired_change_pct=100 * (statistics.median(ratios) - 1),
            paired_bootstrap_interval_pct=[100 * (draws[j] - 1) for j in (250, 9749)],
            arms={},
        )
        for arm, rows in arms.items():
            clean = [r for r in rows.values() if r["clean"]]
            result = {
                k: statistics.median(r[k] for r in clean) for k in ("mib_s", "p95_ms", "p99_ms", "seconds")
            }
            result.update(
                attempted=len(rows),
                clean=len(clean),
                dirty_blocks=[i for i in rows if not rows[i]["clean"]],
                offered=sum(r["offered"] for r in rows.values()),
                reopened=sum(r["reopened"] for r in rows.values()),
            )
            for k in ("fresh_failed", "link_drops"):
                result[k] = (
                    sum(r[k] for r in rows.values())
                    if all(r.get(k) is not None for r in rows.values())
                    else None
                )
            for role in ("vmm", "relay"):
                result[role] = (
                    {k: statistics.median(r[role][k] for r in clean) for k in clean[0][role]}
                    if clean and all(role in r for r in clean)
                    else None
                )
            block["arms"][arm] = result
        out[tag] = block
    return out


PATH_SERIES = ("path-confirmation", "path-first", "path-holdout-lazy")
CPU_ROLES = ("vmm", "relay", "vmm_plus_relay")


def arm_cpu(sample):
    costs = {}
    cores = {}
    for role in CPU_ROLES[:2]:
        if role in sample:
            counters = sample[role]
            costs[role] = counters["cpu_ns_per_byte"]
            cores[role] = counters["cpu_seconds"] / counters["counter_window_s"]
    if len(cores) == 2:
        require(sample["vmm"]["counter_window_s"] == sample["relay"]["counter_window_s"], "unequal CPU windows")
        costs["vmm_plus_relay"] = costs["vmm"] + costs["relay"]
        cores["vmm_plus_relay"] = cores["vmm"] + cores["relay"]
    return {"cpu_ns_per_payload_byte": costs, "mean_host_cores": cores}


def cpu_report(scores, orders, arms, complete=True):
    paired = len(arms) == 2
    report = {"operation": "direct minus bridge" if paired else "absolute stock baseline", "blocks": []}
    for n, order in sorted(orders.items()):
        require(sorted(a for a in order if a in arms) == sorted(arms), "incomplete path order")
        outcomes = {}
        samples = []
        for arm in arms:
            sample = scores[arm].get(n)
            if sample is None:
                outcomes[arm] = {"state": "no receipt"}
            elif not sample["clean"]:
                outcomes[arm] = {"state": "failed" if sample.get("started", True) else "stopped before client"}
            else:
                outcomes[arm] = {"state": "clean"}
                samples.append(arm_cpu(sample))
            if sample is not None:
                for k in ("offered", "fresh_failed", "reopened", "link_drops", "p95_ms", "p99_ms"):
                    outcomes[arm][k] = sample.get(k)
                outcomes[arm].update(
                    bulk_payload_bytes=sample.get("bulk_payload_bytes"),
                    client_window_s=sample.get("seconds"),
                    counter_window_s=sample.get("vmm", {}).get("counter_window_s"),
                    cpu_seconds={role: sample.get(role, {}).get("cpu_seconds") for role in CPU_ROLES[:2]},
                )
        block = {"block": n, "order": list(order), "arms": outcomes}
        if len(samples) == len(arms):
            for metric, first in samples[0].items():
                last = samples[-1][metric]
                values = dict.fromkeys(CPU_ROLES)
                for role in first.keys() & last.keys():
                    values[role] = last[role] - first[role] if paired else first[role]
                block[metric] = values
        report["blocks"].append(block)

    report["summary"] = {} if complete else None
    if not complete:
        return report
    for metric in ("cpu_ns_per_payload_byte", "mean_host_cores"):
        stats = {}
        for role in CPU_ROLES:
            values = [
                block[metric][role]
                for block in report["blocks"]
                if metric in block and block[metric][role] is not None
            ]
            stats[role] = {
                "observed_blocks": len(values),
                "median": statistics.median(values) if values else None,
                "min": min(values, default=None),
                "max": max(values, default=None),
            }
            if paired:
                stats[role]["direct_lower_blocks"] = sum(v < 0 for v in values) if values else None
        report["summary"][metric] = stats
    return report


def archived_cpu(source, series):
    scores = recorded_scores(source)[series]
    arms = SERIES[series]
    require(scores[arms[0]].keys() == scores[arms[1]].keys(), "incomplete archive schedule")
    orders = {n: r["order"] for n, r in scores[arms[0]].items()}
    require(all(order == scores[arms[1]][n]["order"] for n, order in orders.items()), "archive orders disagree")
    return {
        "origin": "historical Gamma archive",
        "series": series,
        "rounds_sha256": ROUNDS_SHA256,
        **cpu_report(scores, orders, arms),
    }


def stock_worker(fixture):
    return {
        "worker": fixture["worker"],
        "instance": fixture["instance"],
        "relay_pid": fixture["pids"]["relay"],
        "workers": 2,
    }


def verify_stock_guest_inventory(facts, fixture):
    """All four identity fields must belong to a single guest capture."""
    lines = facts.splitlines()
    expected = {
        "boot": fixture["boot"],
        "release": fixture["release"].strip(),
        "machine": "aarch64",
        "config_sha256": fixture["guest_config_sha256"],
    }
    for key, value in expected.items():
        prefix = key + "="
        require(
            value and [line for line in lines if line.startswith(prefix)] == [prefix + value],
            f"stock guest inventory requires exactly one matching {key}",
        )


def stock_window(plan, fixture, row, warmup=None, handoff=None):
    """Join a stock invocation to its observed worker, boot, process lifetimes and client output."""
    phase = "warmup" if warmup is None else "scored"
    require(
        (row["phase"], row["block"], row["arm"]) == (phase, 1, "A") and plan["mode"] == "baseline",
        "wrong stock window",
    )
    build = fixture["mapped_relay_build"]
    require(
        build["source_revision"] in RUNTIME_REVS
        and re.fullmatch(r"[0-9a-f]{64}", build["worker_executable_sha256"])
        and build["worker_executable_sha256"] == fixture["cli_sha256"]
        and build["kernel_image_sha256"] == fixture["kernel_sha256"]
        and build["mapped_inode"] > 0
        and build["mapped_device"] >= 0,
        "unbound stock relay build",
    )
    expected_session = stock_worker(fixture)
    require(
        fixture["relay_workers"] == 2 and fixture["image_config"] == plan["image"] == IMAGE,
        "wrong stock workers or image",
    )
    births = {pid: fixture["birth_ticks"][role] for role, pid in fixture["pids"].items()}
    require(
        set(fixture["pids"]) == {"vmm", "relay"} and len(births) == 2 and min(births.values()) > 0,
        "missing process births",
    )
    for bound in ("before", "after"):
        require(
            row["relay_" + bound] == expected_session
            and row["kernel_" + bound]["boot"] == fixture["boot"]
            and row["service_" + bound] == fixture["id"],
            "stock worker, boot or service changed",
        )
        tasks = row[bound]["tasks"]
        require(
            len(tasks) == len(births) and {t["pid"]: t["birth_ticks"] for t in tasks} == births,
            "stock process birth changed",
        )
    start, end = row["client_epoch_ns"]
    require(
        0 < row["before"]["epoch_ns"] <= start < end <= row["after"]["epoch_ns"],
        "client outside host counter window",
    )
    if warmup is not None:
        require(
            warmup["after"]["epoch_ns"] < row["before"]["epoch_ns"],
            "scored host window overlaps or precedes warmup",
        )
    c = row["client"]
    require(
        row["started"]
        and row["exit_code"] == 0
        and json.loads(row["stdout"]) == c
        and c["errors"] in ([], None)
        and type(row["fresh_failed"]) is int
        and row["fresh_failed"] == 0
        and c["reopened"] == 0
        and (c["arrivals"], c["period_us"]) == (240, 25000),
        "unverified stock fresh-request outcome",
    )
    # The pinned client can drain fresh requests after the six-second bulk window.
    wall = row["client_wall_s"]
    bound_s = min(wall, (end - start) / 1e9)
    require(
        math.isfinite(wall)
        and 6 <= c["window_s"] <= bound_s
        and 0 < c["fresh_p95_us"] <= c["fresh_p99_us"] <= bound_s * 1e6
        and 0 <= c["dispatch_p95_us"] <= c["dispatch_max_us"] <= bound_s * 1e6
        and c["dispatch_p95_us"] <= c["fresh_p95_us"],
        "fresh or offered timing outside client invocation",
    )
    if plan["stock_window_version"] >= 3:
        require(complete_bulk_streams(c), f"incomplete stock {phase} bulk workload")
        fixed_bulk_rate(c)
        # The pinned client sorts 240 scheduled-arrival latencies. At indices
        # 227 and 237, at least 13 and 3 requests must reach the reported value.
        # Their last possible completion is the end of the invocation, including drain.
        bound_us = min(round(wall * 1e9), end - start) // 1000
        period_us = c["period_us"]
        require(
            c["fresh_p95_us"] <= bound_us - 12 * period_us
            and c["fresh_p99_us"] <= bound_us - 2 * period_us,
            "fixed-arrival percentile cannot fit its scheduled arrivals",
        )
    proof = {
        "phase": phase,
        "relay": build,
        "session": expected_session,
        "service_id": fixture["id"],
        "image_config": fixture["image_config"],
        "kernel_config_sha256": fixture["guest_config_sha256"],
        "boot": fixture["boot"],
        "client_epoch_ns": [start, end],
        "client_wall_s": wall,
        "offered_window_s": c["window_s"],
        "fresh": {
            "offered": c["arrivals"],
            "failed": row["fresh_failed"],
            "p95_us": c["fresh_p95_us"],
            "p99_us": c["fresh_p99_us"],
            "dispatch_p95_us": c["dispatch_p95_us"],
            "dispatch_max_us": c["dispatch_max_us"],
        },
        "stdout_sha256": sha(row["stdout"].encode()),
        "plan_sha256": sha(encoded(plan).encode()),
        "fixture_sha256": sha(encoded(fixture).encode()),
        "attempt_sha256": sha(encoded(row).encode()),
        "warmup_sha256": sha(encoded(warmup).encode()) if warmup is not None else None,
    }
    if plan["stock_window_version"] in (2, STOCK_WINDOW_VERSION):
        proof["guest_inventory_sha256"] = fixture["guest_inventory_sha256"]
    if plan["stock_window_version"] == STOCK_WINDOW_VERSION:
        # The service TX snapshots bracket the entire download client, including
        # setup and drain. Headers and retransmissions can increase the delta.
        dev = {"macvlan": "mppub0", "bridge": "eth0"}[plan["paths"]["A"]]
        tx_before = row["link_before"][dev]["tx_bytes"]
        tx_after = row["link_after"][dev]["tx_bytes"]
        payload = c["bytes"]
        require(
            all(type(count) is int and count >= 0 for count in (tx_before, tx_after, payload))
            and 0 < payload <= tx_after - tx_before,
            f"{dev} TX does not cover the completed bulk payload",
        )
        if warmup is not None:
            # Both clients used the same service interface and the same process lifetimes.
            require(tx_before >= warmup["link_after"][dev]["tx_bytes"],
                    f"{dev} tx_bytes decreased between warmup and scoring")
            previous = {(task["pid"], task["birth_ticks"]): task for task in warmup["after"]["tasks"]}
            for task in row["before"]["tasks"]:
                prior = previous[task["pid"], task["birth_ticks"]]
                for key in ("user_ticks", "system_ticks", "runnable_ticks"):
                    first, last = prior[key], task[key]
                    require(type(first) is int and type(last) is int and 0 <= first <= last,
                            f"PID {task['pid']} {key} invalid or decreased between warmup and scoring")
        require(isinstance(handoff, dict) and handoff.get("mode") == "baseline"
                and handoff.get("scopes") == [fixture["scope"]] and Path(fixture["scope"]).is_absolute()
                and all(isinstance(handoff.get(k), str) and handoff[k].strip() for k in ("owner", "reservation")),
                "missing initial stock handoff")
        opening, closing = row.get("admission"), row.get("admission_after")
        for obs in (handoff, opening, closing):
            require(isinstance(obs, dict) and all(obs.get(k) == handoff[k] for k in
                    ("owner", "reservation", "mode", "scopes", "starts_at", "expires_at")),
                    "stock admission missing or handoff changed")
            at = obs["observed_at_epoch"]
            require(type(at) in (float, int) and math.isfinite(at)
                    and stamp(obs["starts_at"]) <= at < stamp(obs["expires_at"]),
                    "invalid stock reservation observation")
            disk_expiry(obs.get("effective_disk_gate"), at)
        require(handoff["observed_at_epoch"] <= opening["observed_at_epoch"] <= start / 1e9
                and end / 1e9 <= closing["observed_at_epoch"]
                < stamp(opening["effective_disk_gate"]["expires_at"]),
                "disk clearance does not cover the stock client window")
        proof["admission"] = {"initial_sha256": sha(encoded(handoff).encode()), "opening": opening, "closing": closing}
    return proof


def pilot_cpu(directory):
    """Recompute from raw first attempts. Exclude warmups and keep incomplete blocks visible."""
    inputs = {}

    def read_bytes(name):
        data = (directory / name).read_bytes()
        inputs[name] = sha(data)
        return data

    def read(name):
        return json.loads(read_bytes(name))

    plan = read("plan.json")
    mode, paths = plan["mode"], plan["paths"]
    require(mode in ("baseline", "path"), "expected the stock baseline or path pilot")
    expected = {"A": "bridge", "B": "macvlan"} if mode == "path" else {"A": paths.get("A")}
    require(
        paths == expected
        and paths["A"] in ("bridge", "macvlan")
        and plan["source"] == RELAY_REV
        and plan["image"] == IMAGE
        and plan["client_sha256"] == CLIENT
        and (plan["vcpus"], plan["memory_mib"]) == (4, 4096),
        "wrong pilot path, source, fixture or VM budget",
    )
    warmup, groups = (plan["order"][phase] for phase in ("warmup", "scored"))
    if mode == "baseline":
        require(warmup == groups == ["A"], "wrong baseline schedule")
    else:
        require(
            sorted(groups) == ["AB", "BA"] and len(warmup) == 3 and set(warmup) == {"AB", "BA"},
            "wrong path schedule",
        )
    arms = tuple(expected)
    scores = {arm: {} for arm in arms}
    fixtures = read("fixtures.json") if (directory / "fixtures.json").is_file() else {}
    stock = json.loads((DATA / "index.json").read_text())
    require(not fixtures or fixtures.keys() == paths.keys(), "fixture scopes differ from the plan")
    for f in fixtures.values():
        require(
            f["cpus"] == 4
            and f["cpuset"] == "0-3"
            and f["relay_workers"] == 2
            and f["image_config"] == IMAGE
            and f["release"].strip() == "7.3.5-micropod"
            and f["kernel_sha256"] == stock["full_kernel_image_sha256"]
            and f["guest_config_sha256"] == stock["full_kernel_config_sha256"],
            "wrong stock fixture",
        )
        pids = f["pids"]
        require(set(pids) == {"vmm", "relay"} and len(set(pids.values())) == 2, "invalid process scopes")
    guest = "guest-A.txt"
    if mode == "baseline" and plan.get("stock_window_version") in (2, STOCK_WINDOW_VERSION) and (
        fixtures or (directory / guest).is_file()
    ):
        data = read_bytes(guest)
        if fixtures:
            verify_stock_guest_inventory(data.decode("utf-8"), fixtures["A"])
            require(
                inputs[guest] == fixtures["A"].get("guest_inventory_sha256"),
                "stock guest inventory digest differs",
            )
    if mode == "path" and fixtures:
        require(
            fixtures["A"]["cli_sha256"] == fixtures["B"]["cli_sha256"]
            and fixtures["A"]["boot"] != fixtures["B"]["boot"]
            and set(fixtures["A"]["pids"].values()).isdisjoint(fixtures["B"]["pids"].values()),
            "mismatched path fixtures",
        )
    attempts = {
        f"{phase}-{n}-{arm}.json": (phase, n, arm, order)
        for phase, orders in (("warmup", warmup), ("scored", groups))
        for n, order in enumerate(orders, 1)
        for arm in order
    }
    present = {p.name for phase in ("warmup", "scored") for p in directory.glob(f"{phase}-*.json")}
    require(present <= attempts.keys(), "unplanned attempt")
    failed = {}
    stock_attempts = {}
    for name, (phase, n, arm, order) in attempts.items():
        if name not in present:
            continue
        row = read(name)
        require((row["phase"], row["block"], row["arm"]) == (phase, n, arm), "wrong attempt identity")
        if not row["clean"]:
            failed[name] = {
                "started": row["started"],
                "error": row.get("error"),
                "fresh_failed": row.get("fresh_failed"),
            }
            if phase == "scored":
                client = row.get("client", {})
                scores[arm][n] = dict(
                    clean=False,
                    started=row["started"],
                    fresh_failed=row.get("fresh_failed"),
                    offered=client.get("arrivals"),
                    reopened=client.get("reopened"),
                    bulk_payload_bytes=client.get("bytes"),
                    seconds=client.get("window_s"),
                )
            continue
        require(
            row["started"] and row["exit_code"] == 0 and json.loads(row["stdout"]) == row["client"],
            "clean attempt lacks successful client output",
        )
        if mode == "baseline":
            stock_attempts[phase] = row
        if phase == "scored":
            dev = "eth0" if paths[arm] == "bridge" else "mppub0"
            raw = window(row, fixtures[arm]["pids"], "path-confirmation", arm, n, order, True)
            require(raw["cpu"] and set(raw["cpu"]) == {"before", "after"}, "missing process counters")
            raw["link"] = {stage: row[f"link_{stage}"][dev] for stage in ("before", "after")}
            require(
                all(raw["link"]["before"][k] == raw["link"]["after"][k] for k in ("rx_dropped", "tx_dropped")),
                "published link counters changed on clean attempt",
            )
            scores[arm][n] = measure(raw)
    completion_evidence = {}
    complete = (directory / "complete.json").exists()
    stopped = (directory / "stop.json").exists()
    require(not (complete and stopped), "conflicting completion and stop receipts")
    status = "incomplete" if present or fixtures else "plan only"
    stop = None
    if stopped:
        stop = read("stop.json")
        status = "stopped"
    if complete:
        final = read("complete.json")
        require(
            not failed and len(attempts) == len(present) == final["attempts"] == final["clean"],
            "completion disagrees with first attempts",
        )
        ratios = (
            [scores["B"][n]["mib_s"] / scores["A"][n]["mib_s"] for n in scores["A"]] if mode == "path" else []
        )
        recorded = final["paired_ratios"]
        require(
            len(recorded) == len(ratios)
            and all(math.isclose(a, b) for a, b in zip(recorded, ratios))
            and final["ratio_direction"] == ("direct / bridge" if mode == "path" else None),
            "completion disagrees with the scored path order",
        )
        status = "complete"
        if mode == "baseline":
            version = plan.get("stock_window_version")
            if "stock_window_version" not in plan and "stock_window" not in final:
                status = "unqualified legacy baseline"
            else:
                require(
                    type(version) is int and version in (1, 2, STOCK_WINDOW_VERSION) and "stock_window" in final,
                    "missing or unsupported stock window receipt",
                )
                warmup = stock_attempts["warmup"]
                handoff = read("admission.json") if version == STOCK_WINDOW_VERSION else None
                stock_window(plan, fixtures["A"], warmup, handoff=handoff)
                proof = stock_window(plan, fixtures["A"], stock_attempts["scored"], warmup, handoff)
                require(final["stock_window"] == proof, "stock completion differs from captured scored window")
                completion_evidence["stock_window"] = proof
                if version < STOCK_WINDOW_VERSION:
                    status = "unqualified legacy baseline"
    return {
        "pilot": mode,
        "paths": paths,
        "status": status,
        "attempts": {"planned": len(attempts), "recorded": len(present), "failed_or_stopped": failed},
        "stop": stop,
        "input_sha256": inputs,
        **completion_evidence,
        **cpu_report(scores, dict(enumerate(groups, 1)), arms, status == "complete"),
    }


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="mode", required=True)
    e = sub.add_parser("extract")
    e.add_argument("relay_checkout", type=Path)
    e.add_argument("new_directory", type=Path)
    r = sub.add_parser("replay")
    r.add_argument("--from-dir", type=Path, default=DATA)
    r.add_argument("--series", choices=SERIES)
    c = sub.add_parser("cpu-attribution", help="absolute stock cost or same-block direct minus bridge")
    src = c.add_mutually_exclusive_group()
    src.add_argument("--series", choices=PATH_SERIES)
    src.add_argument("--pilot-dir", type=Path, help="a single baseline or path pilot receipt directory")
    c.add_argument("--from-dir", type=Path, help="alternative archived input directory")
    args = p.parse_args()
    if args.mode == "extract":
        extract(args.relay_checkout, args.new_directory)
    elif args.mode == "cpu-attribution":
        if args.pilot_dir and args.from_dir:
            p.error("choose one pilot directory or one archived series")
        try:
            result = (
                pilot_cpu(args.pilot_dir)
                if args.pilot_dir
                else archived_cpu(args.from_dir or DATA, args.series or "path-confirmation")
            )
        except (OSError, KeyError, ValueError, TypeError) as exc:
            p.exit(1, f"Invalid CPU receipt: {exc}\n")
        print(json.dumps(result, indent=2, allow_nan=False))
    else:
        data = replay(args.from_dir)
        print(json.dumps(data[args.series] if args.series else data, indent=2, allow_nan=False))
