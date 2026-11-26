"""Recalculate CI and transport results from completed Gamma receipts without starting either engine."""

import argparse
import hashlib
import json
import math
import tarfile
from collections import Counter, defaultdict
from itertools import pairwise
from pathlib import Path
from statistics import median


def read(folder, name):
    return json.loads((folder / name).read_bytes())


def check(test, message):
    if not test:
        raise ValueError(message)


def common(p):
    s = read(p, "status.json")
    check(s["complete"] and s["profile"] == read(p, "plan.json")["profile"], "study incomplete")
    cleanup = read(p, "cleanup.json")
    check(not cleanup["retained"] and not cleanup["errors"], "private VM cleanup incomplete")
    check(
        read(p, "verification.json") == {"baseline_files": 24, "extra_cleanup_errors": []},
        "baseline or cleanup failed",
    )
    check(read(p, "fixtures-before.json") == read(p, "fixtures-after.json"), "live fixtures changed")
    for arm in "AB":
        check(read(p, f"cleanup-jobs-{arm}.json")["cache_absent"], "missing guest cache retirement")
    if s["profile"] not in ("workers", "qos"):
        check(read(p, "orbstack-cleanup.json")["removed"], "peer cleanup incomplete")
    if (p / "sources.tar.gz").exists():
        with tarfile.open(p / "sources.tar.gz") as a:
            sums = {
                m.name: hashlib.sha256(a.extractfile(m).read()).hexdigest()
                for m in a.getmembers()
                if m.isfile()
            }
        check(sums == read(p, "plan.json")["sources"], "archived build inputs changed")
    return s["profile"]


def wave(row):
    jobs, probes = row["jobs"], row["fresh"]
    n = row["resident"]
    check(
        not row["errors"] and len(jobs) == len({j["product"] for j in jobs}) == n, "missing or duplicate job"
    )
    check(
        all(
            j["tests"] == 8
            and j["cpu_s"] > 0
            and j["artifact_bytes"] > 0
            and min(j[k] for k in ("compile", "vet", "link")) > 0
            for j in jobs
        ),
        "unverified job",
    )
    check(
        all(not q["error"] for q in probes) and {q["job"] for q in probes} == set(range(n)),
        "unverified service",
    )
    timestamps = [(j[k], step) for j in jobs for k, step in (("submitted_s", 1), ("build_done_s", -1))]
    active = peak = 0
    for _, delta in sorted(timestamps):
        active += delta
        peak = max(peak, active)
    check(0 < peak <= row["active_limit"] and active == 0, "invalid admission intervals")
    return peak


def ci(p):
    groups = defaultdict(list)
    artifacts = {"A": {}, "B": {}}
    for f in sorted(p.glob("wave-*.json")):
        r = read(p, f.name)
        peak = wave(r)
        for j in r["jobs"]:
            check(j["revision"] not in artifacts[r["arm"]], "duplicate revision")
            artifacts[r["arm"]][j["revision"]] = j["product"]
        groups[r["resident"], r["active_limit"], r["arm"]].append((r, peak))
    check(artifacts["A"] == artifacts["B"], "engines built different artifacts")
    result = []
    for (n, active, arm), samples in sorted(groups.items()):
        rows = [r for r, _ in samples]
        result.append(
            {
                "resident": n,
                "limit": active,
                "arm": arm,
                "waves": len(rows),
                "peak_build_requests": max(v for _, v in samples),
                "jobs": sum(len(r["jobs"]) for r in rows),
                "fresh": sum(len(r["fresh"]) for r in rows),
                "seconds": median(r["seconds"] for r in rows),
                "fresh_p95_ms": median(r["fresh_p95_ms"] for r in rows),
                "job_p95_ms_from_submission": median(
                    sorted(j["done_s"] * 1000 for j in r["jobs"])[math.ceil(n * 0.95) - 1] for r in rows
                ),
            }
        )
    memory = {}
    for arm in "AB":
        if (p / f"memory-{arm}.json").exists():
            rows = read(p, f"memory-{arm}.json")
            check(
                len(rows) == len({r["id"] for r in rows}) == max(g[0] for g in groups),
                "incomplete memory census",
            )
            check(all(r["events"]["oom"] == r["events"]["oom_kill"] == 0 for r in rows), "OOM event recorded")
            memory[arm] = {
                "containers": len(rows),
                "oom_events": 0,
                "largest_individual_peak_mib": max(r["peak_bytes"] for r in rows) / 2**20,
            }
    return {"paired_artifacts": len(artifacts["A"]), "rows": result, "memory": memory}


def churn_sample(r, all_ids):
    jobs, c = r["jobs"], r["client"]
    ids = {j["id"] for j in jobs}
    check(
        len(ids) == len(jobs) == r["running_ephemeral_at_barrier"] == r["resident_services"] == 32
        and ids == set(r["removed"])
        and ids.isdisjoint(all_ids),
        "missing ephemeral CI containers",
    )
    all_ids.update(ids)
    check(sorted(j["exit"] for j in jobs) == [0] * 30 + [1, 137], "unexpected CI exit")
    products = {
        s["revision"]: s["product"]
        for j in jobs
        for s in j["receipts"]
        if s["tests"] == 8 and min(s[k] for k in ("compile", "vet", "link")) > 0
    }
    check(len(products) == len(set(products.values())) == 60, "missing successful CI work")
    check(
        r["client_exit"] == 0
        and not c["errors"]
        and c["reopened"] == 0
        and c["arrivals"] == 240
        and len(c["per_stream_bytes"]) == c["published_ports"] == 32
        and min(c["per_stream_bytes"]) > 0
        and sum(c["per_stream_bytes"]) == c["bytes"],
        "TCP window failed",
    )
    return products


def check_retirement(p, arm):
    reuse = read(p, f"port-reuse-{arm}.json")
    check(
        reuse["closed"]
        and reuse["refused"]
        and reuse["retired"] != reuse["replacement"]
        and reuse["new_marker"] != reuse["old_marker"]
        and len(set(reuse["siblings"])) == 31,
        "port retirement failed",
    )


def churn(p):
    plan = read(p, "churn-plan.json")
    result = {}
    paired = {}
    for arm in "AB":
        rows = []
        all_ids = set()
        for b in range(len(plan["order"])):
            r = read(p, f"churn-{b}-{arm}.json")
            products = churn_sample(r, all_ids)
            if b in paired:
                check(paired[b] == products, "products differ across arms")
            else:
                paired[b] = products
            rows.append(r)
        check_retirement(p, arm)
        result[arm] = {
            "blocks": len(rows),
            "healthy_jobs": 30 * len(rows),
            "expected_failures": len(rows),
            "expected_cancellations": len(rows),
            "fresh_requests": 240 * len(rows),
            "bulk_mib_s": median(r["client"]["mib_s"] for r in rows),
            "fresh_p95_ms": median(r["client"]["fresh_p95_us"] / 1000 for r in rows),
            "last_job_s": median(r["last_job_s"] for r in rows),
            "provision_through_cleanup_s": median(r["provision_to_final_cleanup_s"] for r in rows),
            "slowest_stream_mib_s": min(
                min(r["client"]["per_stream_bytes"]) / 2**20 / r["client"]["window_s"] for r in rows
            ),
            "pre_idle_range": [min(r["pre_idle"] for r in rows), max(r["pre_idle"] for r in rows)],
        }
    a = [read(p, f"churn-{i}-A.json") for i in paired]
    b = [read(p, f"churn-{i}-B.json") for i in paired]
    ratios = [y["client"]["mib_s"] / x["client"]["mib_s"] for x, y in zip(a, b, strict=True)]
    result["b_over_a"] = {"paired_bulk_ratio": median(ratios), "b_bulk_wins": sum(r > 1 for r in ratios)}
    return result


def transport(p):
    import bridge
    from gamma_contrasts import paired_median_interval

    plan = read(p, "bridge-plan.json")
    profile = read(p, "plan.json")["profile"]
    descriptor_trial = profile == "grants"
    low_water = profile == "low-water"
    hardware = descriptor_trial or low_water
    if hardware:
        from low_level import service_memory

        service_memory(p, "A")
        size = 5 if descriptor_trial else 4
        sequence = [tuple(x) for x in plan["order"]]
        orders = [sequence[start : start + size] for start in range(0, len(sequence), size)]
        conditions = set(sequence)
        check(
            len(conditions) == size and all(set(block) == conditions for block in orders),
            "unbalanced hardware blocks",
        )
        for position in range(size):
            counts = Counter(block[position] for block in orders)
            check(set(counts) == conditions and set(counts.values()) == {2}, "unbalanced temporal positions")
        edges = Counter(edge for block in orders for edge in pairwise(block))
        check(len(edges) == size * (size - 1) and set(edges.values()) == {2}, "unbalanced carryover")
    if low_water:
        check(
            len(plan["order"]) == 32 and len({tuple(v) for v in plan["order"]}) == 4,
            "incomplete socket readiness schedule",
        )
    if descriptor_trial:
        check(
            len(plan["order"]) == 50 and len({tuple(v) for v in plan["order"]}) == 5,
            "incomplete descriptor schedule",
        )
    groups = defaultdict(list)
    blocks = defaultdict(dict)
    work = requests = 0
    for idx in range(len(plan["order"]) + 1):
        code = f"hv{idx:02}"
        r, jobs = read(p, f"transfer-{code}.json"), read(p, f"wave-{code}-A.json")
        bridge.validate(r)
        wave(jobs)
        lo, hi = r["transfer_relative_to_wave_s"]
        check(
            r["overlap_builds"]
            == [j["name"] for j in jobs["jobs"] if j["submitted_s"] < hi and j["build_done_s"] > lo]
            and r["overlap_builds"]
            and hi < jobs["seconds"],
            "missing concurrent CI",
        )
        work += len(jobs["jobs"])
        requests += len(jobs["fresh"])
        if r["fault"]:
            check(idx == len(plan["order"]), "unexpected fault order")
            if hardware:
                check((r["group"], r["store"]) == (8, "neon"), "wrong descriptor fault condition")
            if low_water:
                check(r["low_kib"] == 128, "socket fault condition")
            fault = {
                "healthy_before_release": len(r["delivery"]) - 2,
                "gate_release_ms": 1000 * r["healthy_finished_before_release"],
                "held_completed_ms": 1000 * r["delivery"][0]["seconds"],
                "reset_after_frames": r["reset_after_verified_frame"],
            }
            continue
        config = (r["path"], r.get("send_kib", 64))
        if hardware:
            config += (r["group"], r["store"])
        if low_water:
            config += (r["low_kib"],)
        order = plan["order"][idx]
        check(
            config == (tuple(order) if isinstance(order, list) else (order, 64)),
            "condition differs from plan",
        )
        raw = r["raw"]
        item = {
            "verified_mib_s": 256 / r["e2e_s"],
            "send_cpu_s_per_gib": 4 * raw["sender_cpu_ns"] / 1e9,
            "send_calls": sum(f["sends"] for f in raw["flows"]),
            "guest_grants": raw["grants"],
        }
        if hardware:
            item.update(
                data_exits=raw["data_exits"],
                max_group=raw["max_group"],
                guest_ms_per_gib=4 * raw["vcpu_ns"] / 1e6,
                polls=raw["polls"],
                overlapping_builds=len(r["overlap_builds"]),
                wave_fresh_p95_ms=jobs["fresh_p95_ms"],
                wave_seconds=jobs["seconds"],
            )
        if low_water:
            item.update(
                effective_low_bytes=r["effective_low_bytes"][0],
                short_writes=sum(f["short_writes"] for f in raw["flows"]),
                would_block=sum(f["would_block"] for f in raw["flows"]),
            )
        groups[config].append(item)
        blocks[idx // (5 if descriptor_trial else 4)][config] = item
    result = {"jobs": work, "fresh": requests, "fault": fault, "medians": {}}

    def label(config):
        return "_".join(map(str, config))

    for config, samples in groups.items():
        result["medians"][label(config)] = {k: median(z[k] for z in samples) for k in samples[0]}
    if len(groups) == 4 or descriptor_trial:
        result["blocks"] = len(blocks)
        result["comparisons"] = {}
        pairs = [
            (("mapped", 64), ("mapped", 512)),
            (("staged", 64), ("staged", 512)),
            (("staged", 512), ("mapped", 512)),
        ]
        metrics = ["verified_mib_s", "send_cpu_s_per_gib", "send_calls"]
        if descriptor_trial:
            check(all(set(row) == set(groups) for row in blocks.values()), "incomplete descriptor block")
            modes = [(0, "scalar"), (1, "scalar"), (8, "scalar"), (1, "neon"), (8, "neon")]
            pairs = [
                (("mapped", 512, *modes[i]), ("mapped", 512, *modes[j]))
                for i, j in ((0, 1), (0, 2), (0, 3), (0, 4), (1, 2), (1, 3), (2, 4), (3, 4))
            ]
            metrics.extend(["guest_ms_per_gib", "data_exits"])
        if low_water:
            check(all(set(row) == set(groups) for row in blocks.values()), "incomplete socket block")
            legacy, vector = ("mapped", 512, 0, "scalar"), ("mapped", 512, 8, "neon")
            pairs = [
                (legacy + (0,), legacy + (128,)),
                (vector + (0,), vector + (128,)),
                (legacy + (0,), vector + (128,)),
                (legacy + (128,), vector + (128,)),
            ]
            metrics.extend(["polls", "data_exits", "guest_ms_per_gib"])
        for a, b in pairs:
            key = f"{label(a)}_to_{label(b)}"
            result["comparisons"][key] = {}
            for metric in metrics:
                ratios = [r[b][metric] / r[a][metric] for r in blocks.values()]
                result["comparisons"][key][metric] = {
                    "median_ratio": median(ratios),
                    "higher": sum(v > 1 for v in ratios),
                }
                if hardware:
                    result["comparisons"][key][metric]["bootstrap_ci95"] = paired_median_interval(ratios)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", type=Path)
    folder = parser.parse_args().folder.resolve()
    profile = common(folder)
    assess = {
        "ci": ci,
        "smoke": ci,
        "churn": churn,
        "qos": churn,
        "workers": churn,
        "bridge": transport,
        "buffers": transport,
        "grants": transport,
        "low-water": transport,
    }
    if profile in ("kernel", "file-peer"):
        from low_level import file_peer, kernel

        assess.update({"kernel": kernel, "file-peer": file_peer})
    if profile == "fanout":
        from fanout_ci import assess as assess_fanout

        assess["fanout"] = assess_fanout
    if profile in ("link-peer", "link-route", "link-steering"):
        from published_link_results import peer_run, route_run, steering_run

        assess.update({"link-peer": peer_run, "link-route": route_run, "link-steering": steering_run})
    print(json.dumps(assess[profile](folder), indent=2))
