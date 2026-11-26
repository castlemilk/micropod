"""Offline diagnostics for #232.01 direct ingress and #233.01 same-kernel container links."""
import argparse
import hashlib
import json
from pathlib import Path
from statistics import median

from gamma_contrasts import (IMAGE, MIB, ROOT, clean_client, paired_median_interval,
                             percentile, read_receipt, stream_rates)

DIRECTORY = ROOT / "docs/benchmarks/2026-11-21"
TARGET_US = 75_000
PATH_ARCHIVE = "gamma-mixed-path.json.gz"
PATH_SHA = "09ebe5510401244cd6d299c1d0cf6dd8f88b256bf14b8c2c14f6db3eff61b74a"
LINK_ARCHIVE = "gamma-direct-macvlan.json.gz"
LINK_SHA = "cc3b9e5c365383a3353423ce1f7fc443c8d858a1af24bb082117bcec24ffa976"


def summarize_times(values):
    return {"p95_us": percentile(values, .95), "p99_us": percentile(values, .99),
            "requests_above_75ms": sum(v > TARGET_US for v in values)}


def minimum_cut(segments, totals):
    """Smallest relative cut on a 1-basis-point grid that brings p95 within target."""
    def passes(bp):
        return percentile([10000 * t - bp * d for t, d in zip(totals, segments)], .95) <= 10000 * TARGET_US

    if not passes(10000):
        return None
    lo, hi = 0, 10000
    while lo < hi:
        mid = (lo + hi) // 2
        if passes(mid):
            hi = mid
        else:
            lo = mid + 1
    return lo


def trace_row(record):
    trace, fresh = record["trace"], record["fresh"]
    events = trace["fresh"]
    if (fresh["iterations"] != 160 or fresh["incomplete_phase_samples"] or len(events) != 160
            or trace["omitted_samples"] or record["reopened_connections"] or record["streams"] != 32):
        raise ValueError("incomplete trace or reopened bulk stream")
    stream_rates({"bytes": record["overlap_bytes"], "per_stream_bytes": record["overlap_bytes_per_stream"]},
                 record["overlap_s"], record["overlap_mib_s"])
    setup, wait, total = [], [], []
    last = 0
    for e in events:
        start, written, first, done = (e[k] for k in ("start_us", "written_us", "first_byte_us", "done_us"))
        if not last <= start <= written <= first <= done:
            raise ValueError("nonsequential trace or inverted fresh phase")
        last = done
        setup.append(written - start)
        wait.append(first - written)
        total.append(done - start)
    observed = summarize_times(total)
    # Independent timers in the Go client report quantiles in ns and timestamp phases in us.
    for key in ("p95", "p99"):
        if abs(observed[key + "_us"] - fresh["complete_ns"][key] / 1000) > 5:
            raise ValueError("reconstructed quantile disagrees with saved timing")
    out = {"requests": len(total), "bulk_reopens": record["reopened_connections"], "observed": observed,
           "historical_overlap_mib_s": record["overlap_mib_s"]}
    for name, segment in (("before_write", setup), ("write_to_first_byte", wait)):
        out[name] = {"after_removing_phase": summarize_times([t - d for t, d in zip(total, segment)]),
                     "minimum_phase_reduction_bp_to_pass": minimum_cut(segment, total)}
    return out


def phase_budget():
    raw = read_receipt(DIRECTORY / PATH_ARCHIVE, PATH_SHA)
    rows = {f"final-trace/{n}-{arm}.json": trace_row(raw["records"][f"final-trace/{n}-{arm}.json"])
            for n in range(1, 4) for arm in ("candidate", "direct")}
    return dict(direction="232.01", archive=PATH_ARCHIVE, archive_sha256=PATH_SHA, base=raw["baseline_commit"],
                trace_client_sha256=raw["binaries"]["netbench-trace"], release_sha256=raw["binaries"]["final"],
                image_sha256=raw["platform"]["image_sha256"], target_us=TARGET_US,
                population="Three archived closed-loop sets, release published and direct guest DNAT for the same "
                           "service. All 960 observed fresh requests and all six first-attempt windows retained.",
                interpretation="For each request, vary just one measured client phase while fixing every other "
                               "phase at its observed duration. The minimum is in basis points; null means even "
                               "full removal cannot pass. These are arithmetic sensitivities at fixed observations. "
                               "Demand, queueing and bulk throughput would change in a real system. Phase clocks "
                               "do not locate host vs guest work, and closed-loop arrivals differ between arms. "
                               "Three sequential sets supply no population uncertainty estimate.", rows=rows)


def link_sample(record):
    client = record["client"]
    if not record["valid"] or not clean_client(client):
        raise ValueError("missing clean original download or fresh-request receipt")
    stream_rates(client, client["window_s"], client["mib_s"])
    rates = sorted(n / (MIB * client["window_s"]) for n in client["per_stream_bytes"])
    return ({"mib_s": client["mib_s"], "slowest_eight_mib_s": sum(rates[:8]),
             "p95_us": client["fresh_p95_us"], "p99_us": client["fresh_p99_us"],
             "arrivals": client["arrivals"], "errors": len(client["errors"] or []),
             "bulk_reopens": client["reopened"]}, rates)


def link_budget():
    raw = read_receipt(DIRECTORY / LINK_ARCHIVE, LINK_SHA)
    series = {}
    for phase, group, kernel, direct, bridge in (
            ("matched", "workers", "full", "direct", "new"),
            ("confirmation", "workers", "full", "full-reno", "full-bridge"),
            ("kernel-holdout", "holdout_workers", "lazy", "lazy-reno", "lazy-bridge")):
        if set(raw["records"][phase]) != {str(i) for i in range(1, 13)}:
            raise ValueError("unexpected attempted block count")
        for arm in (direct, bridge):
            w = raw["records"][group][arm]
            state = w["state"]
            if (w["image"] != IMAGE or w["boot.json"]["cpus"] != 4 or state["release"] != raw["kernels"][kernel]["release"]
                    or [state[k] for k in ("cpu.max", "cpuset.cpus.effective", "memory.max", "pids.max")] !=
                    ["400000 100000", "0-3", "1073741824", "512"]
                    or ("mppub0" in state["interfaces"]) != (arm == direct)):
                raise ValueError("unmatched historical worker configuration")
        rows = []
        for i in range(1, 13):
            block = raw["records"][phase][str(i)]
            a, ax = link_sample(block["engines"][direct])
            b, bx = link_sample(block["engines"][bridge])
            rows.append({"round": i, "order": block["order"], "direct": a, "bridge": b,
                         "faster_stream_ranks": sum(x > y for x, y in zip(ax, bx)),
                         "bulk_ratio": a["mib_s"] / b["mib_s"],
                         "slowest_eight_ratio": a["slowest_eight_mib_s"] / b["slowest_eight_mib_s"]})
        ratios = [r["slowest_eight_ratio"] for r in rows]
        series[phase] = dict(kernel_image_sha256=raw["kernels"][kernel]["image_sha256"],
            bridge=bridge, direct=direct, attempts_per_arm=len(rows), common_clean=len(rows),
            bulk_wins=sum(r["bulk_ratio"] > 1 for r in rows),
            bulk_median_ratio=median(r["bulk_ratio"] for r in rows),
            slowest_eight_median_ratio=median(ratios), slowest_eight_paired_ci95=paired_median_interval(ratios),
            slowest_eight_wins=sum(x > 1 for x in ratios),
            all_32_ranks_faster=sum(r["faster_stream_ranks"] == 32 for r in rows),
            direct_p95_pass=sum(r["direct"]["p95_us"] <= TARGET_US for r in rows),
            bridge_p95_pass=sum(r["bridge"]["p95_us"] <= TARGET_US for r in rows),
            direct_faster_and_p95_pass=sum(r["bulk_ratio"] > 1 and r["direct"]["p95_us"] <= TARGET_US for r in rows),
            rows=rows)
    return dict(direction="233.01", archive=LINK_ARCHIVE, archive_sha256=LINK_SHA, base=raw["baseline_commit"],
                fixed_client_sha256=raw["sha256"]["fixed"], image_sha256=raw["image_config_sha256"],
                service_sha256=raw["service_sha256"], target_us=TARGET_US,
                population="All 12 attempted paired blocks of each same-kernel crossover. Each arm had 32 bulk "
                           "streams and 240 scheduled fresh requests spaced 25 ms apart. No pooling across builds.",
                interpretation="Compare the eight slowest streams in each arm by observed MiB/s. Sorted ranks "
                               "represent distributions, not repeated socket identities. Paired intervals resample "
                               "12 blocks 10,000 times with seed 7317. Rates and latency use the same raw round. "
                               "The all-round 75 ms criterion is retrospective. These shared-host archive contrasts "
                               "do not measure the revised build or confirm interface attribution at both boundaries.",
                series=series)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("direction", choices=("232.01", "233.01"))
    direction = parser.parse_args().direction
    report = (phase_budget if direction == "232.01" else link_budget)()
    report["replay_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    print(json.dumps(report, indent=2, allow_nan=False))
