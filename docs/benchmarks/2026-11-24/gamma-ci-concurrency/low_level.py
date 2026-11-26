"""Recompute the stock-worker artifact and CPU-placement trials from their evidence."""

import re
from collections import Counter
from statistics import median

from qualify import relay
from replay import check, check_retirement, churn_sample, read


def summary(blocks, pairs):
    conditions = sorted(blocks[0])
    check(all(sorted(block) == conditions for block in blocks), "unbalanced conditions")
    # Every condition occupies each temporal position once.
    for i in range(len(conditions)):
        check(sorted(list(r)[i] for r in blocks) == conditions, "unbalanced run order")
    result = {"blocks": len(blocks), "conditions": {}, "paired": {}}
    for key in conditions:
        rows = [block[key] for block in blocks]
        stats = {k: median(r[k] for r in rows) for k in rows[0]}
        stats.update(
            slowest_stream_mib_s=min(r["slowest_stream_mib_s"] for r in rows),
            fresh_p95_above_75ms=sum(r["fresh_p95_ms"] > 75 for r in rows),
            host_pre_idle_range=[min(r["pre_idle"] for r in rows), max(r["pre_idle"] for r in rows)],
        )
        result["conditions"][key] = stats
    for before, after in pairs:
        measures = {}
        for k in (
            "mib_s",
            "fresh_p95_ms",
            "last_job_s",
            "service_cpu_s_per_gib",
            "vmm_cpu_s_per_gib",
            "relay_cpu_s_per_gib",
        ):
            if k in blocks[0][before]:
                ratios = [b[after][k] / b[before][k] for b in blocks]
                measures[k] = {"median_ratio": median(ratios), "higher": sum(v > 1 for v in ratios)}
        result["paired"][f"{before}_to_{after}"] = measures
    return result


def service_memory(folder, arm):
    tenants = read(folder, f"tenants-{arm}-32.json")["tenants"]
    memory = read(folder, f"memory-{arm}.json")
    check(
        len(tenants) == len({t["port"] for t in tenants}) == len({t["cookie"] for t in tenants}) == 32,
        "unexpected published cohort",
    )
    check(
        len(memory) == 32
        and {m["id"] for m in memory} == {t["id"] for t in tenants}
        and len({m["cgroup"] for m in memory}) == 32
        and all(not (m["events"]["oom"] or m["events"]["oom_kill"]) for m in memory),
        "missing service or guest OOM",
    )


def window(r, seen_ids, affinity, build_slots=4, build_placement=None, build_scratch=None):
    products = churn_sample(r, seen_ids)
    for i, j in enumerate(r["jobs"]):
        expected = ("0-1", "2-3")[i % 2] if build_placement == "pairs" else affinity
        check(j["effective_cpu_list"] == expected, "wrong CPU placement")
        if build_placement:
            check(j["docker_cpu_list"] == j["cgroup_cpu_list"] == expected and j["cpu_max"] == "100000 100000",
                  "build container CPU set or bandwidth differs")
            if j["kind"] == "pass":
                mount = j["scratch_mount"]
                volume = build_scratch == "volume"
                check(mount["parent"] == ("/cache" if volume else "/tmp") and mount["filesystem"]
                      and min(mount["mount_id"], mount["volume_id"]) > 0
                      and (mount["mount_id"] == mount["volume_id"]) == volume, "wrong compiler scratch mount")
                stats = j["cpu_stat_delta"]
                check(set(stats) == {"nr_periods", "nr_throttled", "throttled_usec", "user_usec", "system_usec"}
                      and min(stats.values()) >= 0 and stats["user_usec"] > 0,
                      "missing build CPU throttling statistics")
    active = peak = 0
    for _, step in sorted(
        (j[key], delta) for j in r["jobs"] for key, delta in (("submitted_s", 1), ("finished_s", -1))
    ):
        active += step
        peak = max(peak, active)
    check(peak == build_slots and active == 0, "wrong CI concurrency")
    c = r["client"]
    return {
        "mib_s": c["mib_s"],
        "fresh_p95_ms": c["fresh_p95_us"] / 1000,
        "fresh_p99_ms": c["fresh_p99_us"] / 1000,
        "last_job_s": r["last_job_s"],
        "slowest_stream_mib_s": min(c["per_stream_bytes"]) / 2**20 / c["window_s"],
        "pre_idle": r["pre_idle"],
    }, products


def kernel(folder):
    import kernel_ci

    plan = read(folder, "kernel-plan.json")
    expected = set(kernel_ci.MODES)
    check(
        len(plan["order"]) == 4 and all(set(block) == expected for block in plan["order"]),
        "wrong study order",
    )
    check(
        plan["service_file_sha256"] == kernel_ci.BODY_SHA and plan["build_slots"] == 4,
        "wrong kernel trial inputs",
    )
    proof = read(folder, "sendfile-proof.json")
    for i, mode in enumerate(("memory", "file-copy", "file")):
        lines = (folder / f"guest-{2 + 2 * i:03}-trace-off.txt").read_text().splitlines()
        parsed = kernel_ci.trace_events(lines)
        check(proof[mode] == parsed, "trace returns do not match proof")
    check(
        not proof["memory"]["return_events"]
        and not proof["file-copy"]["return_events"]
        and kernel_ci.SIZE - 4096 <= proof["file"]["positive_bytes"] <= kernel_ci.SIZE,
        "wrong file fast path",
    )
    fixture = read(folder, "fixtures-before.json")["A"]
    irqs = plan["preflight_irqs"]
    cpu = plan["irq_cpu"]
    check(
        sum(irqs) > 0
        and irqs[cpu] / sum(irqs) >= 0.9
        and plan["other_cpus"] == ("1-3", "0,2-3", "0-1,3", "0-2")[cpu],
        "wrong interrupt CPU",
    )
    service_memory(folder, "A")
    check_retirement(folder, "A")
    blocks, ids = [], set()
    irq_totals = Counter()
    for i, conditions in enumerate(plan["order"]):
        block = {}
        for j, condition in enumerate(conditions):
            r = read(folder, f"churn-{4 * i + j}-A.json")
            v, _ = window(r, ids, plan["other_cpus"] if condition == "file-spare" else "0-3")
            a, b = r["counter_before"], r["counter_after"]
            ga, gb = a["guest"], b["guest"]
            check(
                ga["boot"] == gb["boot"] == fixture["boot"]
                and ga["driver"] == gb["driver"] == "virtio_net"
                and ga["ifindex"] == gb["ifindex"] == plan["guest_start"]["ifindex"],
                "changed virtio device",
            )
            check(
                all(
                    ga[k] == gb[k]
                    for k in ("rx_errors", "tx_errors", "rx_dropped", "tx_dropped", "tx_tx_timeouts")
                ),
                "virtio error or drop",
            )
            irq = [
                int(y) - int(x)
                for x, y in zip(ga["irq_counts"].split(","), gb["irq_counts"].split(","), strict=True)
            ]
            irq_totals.update(dict(enumerate(irq)))
            n = relay.invocation_bulk_bytes(r["client"], clean=True)
            check(
                len(a["service_cpu_usec"]) == len(b["service_cpu_usec"]) == 32
                and all(y >= x for x, y in zip(a["service_cpu_usec"], b["service_cpu_usec"], strict=True)),
                "service CPU counter regressed",
            )
            v["service_cpu_s_per_gib"] = (
                (sum(b["service_cpu_usec"]) - sum(a["service_cpu_usec"])) / 1e6 / (n / 2**30)
            )
            v["nic_tx_kicks_per_gib"] = (int(gb["tx_kicks"]) - int(ga["tx_kicks"])) / (n / 2**30)
            for role in ("vmm", "relay"):
                work = relay.process_work(
                    a["host"], b["host"], fixture["pids"][role], r["client"]["bytes"], invocation_bytes=n
                )
                v[role + "_cpu_s_per_gib"] = work["invocation_cpu_s_per_bulk_gib"]
            block[condition] = v
        blocks.append(block)
    output = summary(blocks, [("memory", "file"), ("file-copy", "file"), ("file", "file-spare")])
    output.update(
        preflight_irqs=irqs,
        timed_irqs=[irq_totals[i] for i in range(4)],
        sendfile=proof,
        healthy_jobs=480,
        intentional_failures=16,
        intentional_cancellations=16,
        fresh=3840,
    )
    return output


def file_peer(folder):
    import kernel_ci

    plan = read(folder, "file-peer-plan.json")
    baseline = read(folder, "fixtures-before.json")
    settings = read(folder, "plan.json")
    build_placement = settings.get("build_cpu_placement")
    build_scratch = settings.get("build_scratch")
    check(
        plan["build_slots"] in (4, 6, 8)
        and build_placement in (None, "shared", "pairs")
        and (build_scratch in ("root", "volume") if build_placement else build_scratch is None)
        and (not build_placement or re.fullmatch(r"[0-9a-f]{64}", plan.get("dispatch_sha256", "")))
        and plan["build_cpus"] == (["0-1", "2-3"] if build_placement == "pairs" else "0-3")
        and plan["service_file_sha256"] == kernel_ci.BODY_SHA
        and all(baseline[a]["cpus"] == 4 for a in "AB"),
        "wrong confirmation inputs",
    )
    for arm in "AB":
        service_memory(folder, arm)
        check_retirement(folder, arm)
    schedules = plan["order"]
    mixed = plan.get("mixed_artifacts", False)
    modes = kernel_ci.peer_modes(mixed)
    conditions = [arm + "-" + mode for arm in "AB" for mode in modes]
    check(len(schedules) == 4 and all(set(row) == set(conditions) for row in schedules), "wrong confirmation order")
    if "order_seed" in plan:
        check(schedules == kernel_ci.paired_order(conditions, plan["order_seed"]), "order differs from its seed")
    tenants = {arm: read(folder, f"tenants-{arm}-32.json")["tenants"] for arm in "AB"} if mixed else {}
    blocks, seen, paired_products = [], {"A": set(), "B": set()}, {}
    for i, row in enumerate(schedules):
        block = {}
        for condition in row:
            arm, mode = condition.split("-", 1)
            idx = i * 2 + modes.index(mode)
            r = read(folder, f"churn-{idx}-{arm}.json")
            block[condition], products = window(r, seen[arm], "0-3", plan["build_slots"], build_placement, build_scratch)
            if mixed:
                file_parity = modes.index(mode)
                names = [service["name"] + "\t" + ("file" if n % 2 == file_parity else "memory")
                         for n, service in enumerate(tenants[arm])]
                check(len(names) == 32 and names == read(folder, f"service-modes-{idx}-{arm}-before.json")
                      == read(folder, f"service-modes-{idx}-{arm}-after.json"), "mixed serving modes changed")
                block[condition]["provision_to_final_cleanup_s"] = r["provision_to_final_cleanup_s"]
                bytes_by_stream = r["client"]["per_stream_bytes"]
                for parity, kind in ((file_parity, "file"), (1 - file_parity, "memory")):
                    block[condition][kind + "_streams_mib_s"] = (
                        sum(bytes_by_stream[parity::2]) / 2**20 / r["client"]["window_s"]
                    )
            check(paired_products.setdefault(idx, products) == products, "engine artifacts differ")
        blocks.append(block)
    result = summary(
        blocks,
        [(a + "-" + modes[0], a + "-" + modes[1]) for a in "AB"]
        + [("B-" + mode, "A-" + mode) for mode in modes],
    )
    if mixed:
        result["mixed_services"] = {"file": 16, "memory": 16, "matched_windows": 8}
        for key in ("mib_s", "file_streams_mib_s", "memory_streams_mib_s", "fresh_p95_ms",
                    "last_job_s", "provision_to_final_cleanup_s"):
            values = {arm: [block[arm + "-" + mode][key] for block in blocks for mode in modes] for arm in "AB"}
            ratios = [a / b for a, b in zip(values["A"], values["B"], strict=True)]
            result["mixed_services"][key] = {"micropod": median(values["A"]), "orbstack": median(values["B"]),
                                             "median_ratio": median(ratios), "higher": sum(r > 1 for r in ratios)}
    result.update(
        paired_build_products=sum(map(len, paired_products.values())),
        fresh=3840,
        healthy_jobs=480,
        intentional_failures=16,
        intentional_cancellations=16,
    )
    return result
