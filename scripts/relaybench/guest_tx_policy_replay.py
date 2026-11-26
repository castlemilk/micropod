"""Reconstruct historical fixed-ceiling and root-qdisc comparisons from their distinct workloads."""
import argparse
import hashlib
import json
import math
from pathlib import Path
from statistics import median

from gamma_contrasts import GIB, MIB, ROOT, paired_median_interval, read_receipt, stream_rates

ARCHIVE = ROOT / "docs/benchmarks/2026-11-21/gamma-published-scheduling.json.gz"
ARCHIVE_SHA = "4ba4e71da88a7196bf132151f30c54c3c091e8fd7eeaac30ba98f689397dfe30"
HERE = Path(__file__).resolve().parent


def require(ok, message):
    if not ok:
        raise ValueError(message)


def fresh(receipt, requests):
    require(receipt["mode"] == "fresh" and receipt["iterations"] == requests and
            receipt["incomplete_phase_samples"] == 0, "missing fresh responses")
    return {key + "_ms": receipt["complete_ns"][key] / 1e6 for key in ("p95", "p99")}


def bql_arm(records, arm, prefix):
    ceiling = 524288 if arm == "bql512" else 1879048192
    require(records[prefix + ".setup"].strip() == f"limit_max={ceiling}", "wrong queue readback")
    require(records[prefix + ".status"].strip() == "0" and not records[prefix + ".err"].strip(), "failed client")
    row = records[prefix + ".json"]
    require(row["mode"] == "mixed" and row["streams"] == 32 and row["reopened_connections"] == 0,
            "bulk continuity failure")
    stream_rates({"bytes": row["overlap_bytes"], "per_stream_bytes": row["overlap_bytes_per_stream"]},
                 row["overlap_s"], row["overlap_mib_s"])
    return dict(ceiling_bytes=ceiling, mib_s=row["overlap_mib_s"], bytes=row["overlap_bytes"],
                elapsed_s=row["overlap_s"], fresh_completed=160, reopens=0, **fresh(row["fresh"], 160))


def qdisc_arm(records, arm, prefix):
    kind = "pfifo_fast" if arm == "restore" else "fq_codel"
    applied, device = records[prefix + ".setup"].splitlines()
    require(applied == "applied" and json.loads(device)["kind"] == kind, "wrong root qdisc")
    require(records[prefix + ".status"].strip() == "0" and not records[prefix + ".fresh.err"].strip()
            and not records[prefix + ".bulk.err"].strip(), "failed client")
    row = records[prefix + ".bulk"]
    require(row["streams"] == 32 and row["reopened_connections"] == 0 and row["bytes"] == 6 * GIB and
            row["iterations"] == 24 and math.isclose(row["mib_s"], row["bytes"] / MIB / row["elapsed_s"]),
            "bulk throughput/continuity mismatch")
    return dict(kind=kind, mib_s=row["mib_s"], bytes=row["bytes"], elapsed_s=row["elapsed_s"],
                setup_us=json.loads(device)["us"], fresh_completed=240, reopens=0,
                **fresh(records[prefix + ".fresh"], 240))


def profile(records, arm, mode):
    kind = "fq_codel" if arm == "fq_codel" else "pfifo_fast"
    samples = records[arm + (".samples" if mode == "bql" else ".queue")]
    expected = 1700 if mode == "bql" else 360
    require(len(samples) == expected and all(s["kind"] == kind for s in samples), "profile coverage/identity")
    active = []
    for prev, curr in zip(samples, samples[1:]):
        a, b = [s["stats"]["Basic"]["Bytes"] for s in (prev, curr)]
        require(b >= a and curr["us"] > prev["us"], "profile continuity")
        if b > a:
            active.append(curr)
    require(active, "no qdisc transmit progress")
    deltas = [s["stats"]["Queue"]["Drops"] for s in samples]
    require(all(b >= a for a, b in zip(deltas, deltas[1:])), "drop counter reset")
    backlog = [s["stats"]["Queue"]["Backlog"] for s in active]
    result = dict(kind=kind, samples=expected, intervals_with_tx_progress=len(active), qdisc_drop_delta=deltas[-1]-deltas[0],
                  nonzero_backlog_ends=sum(x > 0 for x in backlog), max_backlog_bytes=max(backlog))
    if mode == "bql":
        ceiling = 524288 if arm == "bql512" else 1879048192
        require(all(set(s["bql"]) == {"limit", "inflight", "limit_max"} and s["bql"]["limit_max"] == ceiling
                    and min(s["bql"].values()) >= 0 for s in samples), "BQL readback changed or missing")
        result.update(verified_ceiling_bytes=ceiling, at_ceiling_ends=sum(s["bql"]["limit"] == ceiling for s in active),
                      max_dynamic_limit_bytes=max(s["bql"]["limit"] for s in active),
                      max_inflight_bytes=max(s["bql"]["inflight"] for s in active))
    return result


def run(mode):
    d = read_receipt(ARCHIVE, ARCHIVE_SHA)
    records = d["experiments"][mode]
    bql = mode == "bql"
    arms = ("bqldefault", "bql512") if bql else ("restore", "fq_codel")
    numbers = range(8) if bql else range(1,7)
    rows = []
    for arm in arms:
        expected = {f"{n}-{arm}.status" for n in numbers}
        actual = {name for name in records if name.split("-")[0].isdigit() and name.endswith(f"-{arm}.status")}
        require(actual == expected, "attempt population mismatch")
    for n in numbers:
        obs = {arm: (bql_arm if bql else qdisc_arm)(records, arm, f"{n}-{arm}") for arm in arms}
        if bql:
            sequence = ["bqldefault", "bql128", "bql512", "bql2048"]
            order = [sequence[(n+offset)%4] for offset in (0,1,3,2)]
            order = [arm for arm in order if arm in arms]
        else:
            order = sorted(arms, key=lambda a: obs[a]["setup_us"])
        rows.append(dict(block=n, order=order, **obs))
    summary = {arm: {k: median(r[arm][k] for r in rows) for k in ("mib_s", "p95_ms", "p99_ms")} for arm in arms}
    for arm in arms:
        summary[arm].update(clean=len(rows), p95_at_most_75ms=sum(r[arm]["p95_ms"] <= 75 for r in rows),
                            fresh_completed=sum(r[arm]["fresh_completed"] for r in rows), reopens=0)
    effects = {}
    for key in ("mib_s", "p95_ms", "p99_ms"):
        changes = [100 * (r[arms[1]][key] / r[arms[0]][key] - 1) for r in rows]
        effects[key] = dict(median_pct=median(changes), ci95_pct=paired_median_interval(changes),
                            higher=sum(x>0 for x in changes))
    result = dict(date="2026-11-24", direction="231.08", tier="offline raw replay of archived VM measurements",
                  source=ARCHIVE.name, archive_sha256=ARCHIVE_SHA, archive_revision="47a01af326b712ed25482b86fa1de569f020d73a",
                  study_baseline=d["hardware"]["baseline_release"], linux=d["guest_profile"].splitlines()[0],
                  image=d["image"]["config_sha256"], interface="eth0", analysis_base="a3b561c6a97320d4ca9aff60885ae6393ccaa613",
                  analyzer_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  workload=("32 warm downloads with 160 closed-loop fresh HTTP connections. The eight numbered "
                            "blocks rotated four settings; use stock and 512 KiB only. Each arm has a separate "
                            "200-fresh diagnostic with 1,700 queue samples." if bql else
                            "32 streams delivering a fixed 6 GiB; a second process starts 240 closed-loop fresh "
                            "requests 40 ms after starting the bulk client. The workloads may finish at different times. "
                            "Six blocks rotate three root qdiscs; compare only stock and fq_codel. One separately "
                            "instrumented run per arm supplies 360 queue observations."),
                  method="Use median within-block percentage changes and 10,000 whole-block bootstrap draws with seed 7317. "
                         "Progress samples are endpoints of adjacent qdisc reads that have increasing bytes. Samples are "
                         "correlated and do not establish duration at a queue depth. Queue samples and drop deltas came "
                         "from separate instrumented runs. Transport loss, NIC drops and per-process CPU in scored arms "
                         "are unmeasured. Historical eth0 and workloads differ from the revised eth1 four-vCPU stock.",
                  control=arms[0], candidate=arms[1], rows=rows, summary=summary, paired=effects,
                  separate_profiles={arm: profile(records, arm, mode) for arm in arms})
    if bql:
        result.update(driver_sha256="50de20df747a492c478de4e65ba8258bdbc04b59a4b2f1ea0853f6355460099e",
                      client_path_hash_at_reconciliation="253c465424c2ba9f77083714db2e2591d96ab55fbe0a0767e33902ec15ae0036",
                      verdict="The verified 512 KiB ceiling frequently bound the dynamic limit on this guest. "
                              "Retain stock for loss-free bulk throughput. The later eth1 candidate remains "
                              "a separate reliability hypothesis with no common clean throughput pair.",
                      future_readback={name: hashlib.sha256((HERE / name).read_bytes()).hexdigest()
                                       for name in ("bql_capture.sh", "bql_bounds.py", "test_bql_bounds.py")})
    else:
        result.update(driver_sha256="1d1bbba868b7f2cc8bb96cb8ad01ff59859f263b009536f2928d28bfbf539a32",
                      client_path_hash_at_reconciliation="bbda57ec8e4e5d2fe0ec7c195285a9fe82b5d8ca0e89c73e57cb97e86df1e21a",
                      verdict="Replacing pfifo_fast with fq_codel did not consistently protect fresh tails or reduce "
                              "observed backlog. Retain stock. If repeated, align queue occupancy sampling with the "
                              "scored interval and compare distributions over independent runs.")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("bql", "qdisc"))
    print(json.dumps(run(parser.parse_args().mode), indent=2, allow_nan=False))
