"""Replay cgroup CPU throttling when only the fresh destination moves to the sibling."""
import hashlib
import json
from pathlib import Path
from statistics import median

from gamma_contrasts import ROOT, paired_median_interval, read_receipt, stream_rates

ARCHIVE = ROOT / "docs/benchmarks/2026-11-21/gamma-published-scheduling.json.gz"
SHA = "4ba4e71da88a7196bf132151f30c54c3c091e8fd7eeaac30ba98f689397dfe30"


def cpu_counts(cgroup):
    if cgroup["cpu.max"].strip() != "100000 100000" or cgroup["cpu.weight"].strip() != "100":
        raise ValueError("one-CPU service configuration changed")
    stat = dict(line.split() for line in cgroup["cpu.stat"].splitlines())
    pressure = cgroup["cpu.pressure"].splitlines()[0].split()
    if pressure[0] != "some" or not pressure[-1].startswith("total="):
        raise ValueError("CPU pressure counter missing")
    return {**{k: int(stat[k]) for k in ("nr_periods", "nr_throttled", "throttled_usec", "usage_usec")},
            "some_stall_usec": int(pressure[-1].split("=")[1])}


def observation(records, index, arm):
    key = f"{index}-{arm}."
    if records[key + "status"].strip() != "0" or records[key + "error"].strip():
        raise ValueError("missing completion")
    bulk, fresh = records[key + "roles"].split()
    if {bulk, fresh} - {"a", "b"} or ((bulk == fresh) != (arm == "same")):
        raise ValueError("unexpected endpoint identity")
    deltas = {}
    for service in ("a", "b"):
        before, after = [cpu_counts(records[key+point][service]["cgroup"]) for point in ("before", "after")]
        delta = {k: after[k] - v for k, v in before.items()}
        if min(delta.values()) < 0 or delta["nr_throttled"] > delta["nr_periods"]:
            raise ValueError("inconsistent cgroup sampling bracket")
        deltas[service] = delta
    c = records[key + "json"]
    if (c["mode"], c["streams"], c["fresh"]["iterations"], c["fresh"]["incomplete_phase_samples"],
        c["reopened_connections"]) != ("mixed", 32, 240, 0, 0):
        raise ValueError("incomplete workload")
    stream_rates({"bytes": c["overlap_bytes"], "per_stream_bytes": c["overlap_bytes_per_stream"]},
                 c["overlap_s"], c["overlap_mib_s"])
    return dict(bulk=bulk, fresh=fresh, cgroup_delta=deltas,
                fresh_cgroup_throttled=deltas[fresh]["nr_throttled"] > 0,
                verified_fresh=240, bulk_reopens=0, bulk_bytes=c["overlap_bytes"],
                elapsed_s=c["overlap_s"], mib_s=c["overlap_mib_s"],
                p95_ms=c["fresh"]["complete_ns"]["p95"] / 1e6, p99_ms=c["fresh"]["complete_ns"]["p99"] / 1e6)


def replay():
    archive = read_receipt(ARCHIVE, SHA)
    raw = archive["experiments"]["sibling"]
    suffixes = ("json", "roles", "error", "before", "after", "status", "load")
    if set(raw) != {f"{i}-{arm}.{s}" for i in range(1, 9) for arm in ("same", "sibling") for s in suffixes}:
        raise ValueError("unexpected attempted population")
    rows = []
    for i in range(1, 9):
        row = {arm: observation(raw, i, arm) for arm in ("same", "sibling")}
        if row["same"]["bulk"] != row["sibling"]["bulk"]:
            raise ValueError("bulk service changed across arms")
        rows.append(dict(block=i, order=["same", "sibling"] if i % 2 else ["sibling", "same"], **row))
    summary = {}
    for arm in ("same", "sibling"):
        samples = [r[arm] for r in rows]
        summary[arm] = {k: median(s[k] for s in samples) for k in ("mib_s", "p95_ms", "p99_ms")}
        summary[arm].update(fresh_cgroup_throttled_rounds=sum(s["fresh_cgroup_throttled"] for s in samples),
                            within_75ms=sum(s["p95_ms"] <= 75 for s in samples), verified_fresh=8 * 240)
    effects = {}
    for metric in ("mib_s", "p95_ms", "p99_ms"):
        changes = [100 * (r["sibling"][metric] / r["same"][metric] - 1) for r in rows]
        effects[metric] = dict(median_pct=median(changes), ci95_pct=paired_median_interval(changes),
                               lower_rounds=sum(x < 0 for x in changes))
    summary["both_fresh_cgroups_unthrottled_and_sibling_lower_p95"] = [
        r["block"] for r in rows if all(not r[a]["fresh_cgroup_throttled"] for a in ("same", "sibling"))
        and r["sibling"]["p95_ms"] < r["same"]["p95_ms"]]
    return dict(direction="237.06", archive=ARCHIVE.name, archive_sha256=SHA,
                archive_commit="47a01af326b712ed25482b86fa1de569f020d73a",
                baseline_release=archive["hardware"]["baseline_release"],
                image_config_sha256=archive["image"]["config_sha256"],
                workload_client_sha256=archive["hardware"]["binaries_sha256"]["timed_client_default"],
                original_driver="sibling.sh", original_driver_sha256="e409d5d6b584f839b067fc3f2cd41ad632c81ab097df3089df2d5e624ad15a2a",
                replay_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                method="Eight alternating pairs, one warm VM, two running one-CPU services with the same image. "
                       "Only the fresh destination moves. The two services alternate bulk/idle roles across blocks. "
                       "240 closed-loop fresh replies, 32 original bulk streams per attempt. Percent intervals resample "
                       "whole blocks 10,000 times with seed 7317. Cgroup sampling brackets the invocation. "
                       "The active services can use two quotas when split. This is not fixed combined CPU demand. "
                       "Same-service counters also include bulk work. A pressure total is not a request latency.",
                rows=rows, summary=summary, paired=effects)


if __name__ == "__main__":
    print(json.dumps(replay(), indent=2, allow_nan=False))
