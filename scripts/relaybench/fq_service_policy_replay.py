"""Replay two conditional service-qdisc contrasts from pinned private benchmark records."""
import argparse
import hashlib
import json
import re
from pathlib import Path
from statistics import median

from gamma_contrasts import ROOT, process_delta, read_receipt, stream_rates
from guest_tx_replay import paired_pct

SOURCES = ROOT / "docs/benchmarks/2026-11-21"
CONTROL = "control"
TRIAL = "trial"
MODES = {
    "pacing": {
        "id": "231.07", "archive": "gamma-mixed-scheduler.json.gz",
        "sha256": "9e3b184de862aafacff47312878441e940d030e8cfc8342c0e479d064f4724c8",
        "archive_revision": "816121afd30fba52bda7828418cd963d4216166b",
        "base": "692ace081c989f80fb2bce27a5a13af13098b77c",
        "names": ("nicoff", "bothoff"), "prefix": "extra", "samples": 6,
        "control": "Service fq pacing enabled with NIC fq pacing disabled.",
        "trial": "Service fq pacing disabled with NIC fq pacing still disabled.",
        "verdict": "Throughput rose in all six paired blocks. NIC fq drops rose in every block and only three "
                   "trials in each arm met the 75 ms guardrail. Reject pacing removal as a loss-safe tuning.",
        "next_check": "Retain service pacing in the revised stock worker baseline; compare two versus four workers "
                      "with both qdiscs fixed after the baseline qualifies.",
    },
    "quantum": {
        "id": "231.08", "archive": "gamma-mixed-path.json.gz",
        "sha256": "09ebe5510401244cd6d299c1d0cf6dd8f88b256bf14b8c2c14f6db3eff61b74a",
        "archive_revision": "692ace081c989f80fb2bce27a5a13af13098b77c",
        "base": "4f887ba5d28f47fa37d4bd0a2d89cd0914d74754",
        "names": ("nic64", "both64"), "prefix": "quantum", "samples": 5,
        "control": "Service fq quantum 3028 bytes with NIC fq quantum 65536 bytes.",
        "trial": "Service fq quantum 65536 bytes with NIC fq quantum still 65536 bytes.",
        "verdict": "The larger service quantum was slower in four of five pairs with more total NIC fq drops and "
                   "fewer p95 passes. The throughput interval spans zero. Leave the service quantum unchanged.",
        "next_check": "Use stock service quantum for the revised worker baseline, with separate readbacks at both "
                      "qdiscs. A revised-worker quantum trial would need its own qualified comparison.",
    },
}


def require(ok, message):
    if not ok:
        raise ValueError(message)


def qdiscs(snapshot):
    headers = re.findall(r"^qdisc fq .*$", snapshot, re.M)
    counters = re.findall(r"^ Sent (\d+) bytes (\d+) pkt \(dropped (\d+),", snapshot, re.M)
    require(len(headers) == len(counters) == 2, "Expected NIC and service fq counters")
    return headers, [dict(zip(("bytes", "packets", "dropped"), map(int, row))) for row in counters]


def read_attempt(records, prefix, mode, role):
    first, last = (".qbefore", ".qafter") if mode == "pacing" else (".before", ".after")
    headers, start = qdiscs(records[prefix + first])
    after_headers, stop = qdiscs(records[prefix + last])
    require(headers == after_headers, "qdisc setting changed during invocation")
    expected_service = "8002" if mode == "pacing" else "8003"
    require(headers[0].startswith("qdisc fq 8001:") and headers[1].startswith(f"qdisc fq {expected_service}:"),
            "unexpected qdisc identities")
    require((" nopacing " in headers[0]) == (mode == "pacing"), "unexpected NIC pacing")
    require((" nopacing " in headers[1]) == (mode == "pacing" and role == TRIAL), "unexpected service pacing")
    quanta = [re.search(r"\bquantum (\w+)", h)[1] for h in headers]
    expected = ["3028b", "3028b"] if mode == "pacing" else ["64Kb", "3028b" if role == CONTROL else "64Kb"]
    require(quanta == expected, "effective quanta disagree with assigned arm")
    work = [{key: b[key] - a[key] for key in a} for a, b in zip(start, stop)]
    require(all(v >= 0 for group in work for v in group.values()) and all(g["packets"] > 0 for g in work),
            "qdisc counter reset or inactive")
    sample = records[prefix + ".json"]
    require(sample["arrivals"] == 240 and sample["period_us"] == 25000 and sample["streams"] == 32,
            "unexpected offered workload")
    stream_rates(sample, sample["window_s"], sample["mib_s"])
    errors = sample["errors"] or []
    clean = not errors and sample["reopened"] == 0 and not records[prefix + ".err"]
    row = dict(arm=prefix, clean=clean, errors=errors, reopens=sample["reopened"], offered=sample["arrivals"],
               stderr=records[prefix + ".err"], bytes=sample["bytes"], window_s=sample["window_s"],
               mib_s=sample["mib_s"], fresh_p95_ms=sample["fresh_p95_us"] / 1000,
               fresh_p99_ms=sample["fresh_p99_us"] / 1000, passing_delivery_and_p95=clean and sample["fresh_p95_us"] <= 75000,
               qdisc_headers=headers, nic_bytes_at_start=start[0]["bytes"], nic_bytes_at_end=stop[0]["bytes"],
               nic_qdisc=work[0], service_qdisc=work[1],
               nic_drops_per_million_sent=work[0]["dropped"] * 1e6 / work[0]["packets"])
    if mode == "pacing":
        first, last = (records[prefix + ext] for ext in (".before", ".after"))
        require(len(first["tasks"]) == len(last["tasks"]) == 1, "unexpected number of sampled host processes")
        row["vm_process_whole_invocation"] = process_delta(first, last, first["tasks"][0]["pid"])
    return row


def replay(mode):
    spec = MODES[mode]
    archive = read_receipt(SOURCES / spec["archive"], spec["sha256"])
    require(spec["base"].startswith(archive["baseline_commit"]), "unexpected source base")
    records = archive["records"]
    if mode == "pacing":
        require(records["extra/nicoff.addr"] == records["extra/bothoff.addr"], "changed endpoint")
    attempts = []
    for block in range(spec["samples"]):
        pair = {}
        for role, name in zip((CONTROL, TRIAL), spec["names"]):
            prefix = f"{spec['prefix']}/{block}-{name}"
            pair[role] = read_attempt(records, prefix, mode, role)
        control, trial = pair[CONTROL], pair[TRIAL]
        require(control["qdisc_headers"][0] == trial["qdisc_headers"][0], "NIC config drifted")
        service = trial["qdisc_headers"][1].replace(" nopacing ", " ") if mode == "pacing" else (
            trial["qdisc_headers"][1].replace(" quantum 64Kb ", " quantum 3028b "))
        require(service == control["qdisc_headers"][1], "service qdisc changed another setting")
        first, last = sorted((CONTROL, TRIAL), key=lambda role: pair[role]["nic_bytes_at_start"])
        require(pair[first]["nic_bytes_at_end"] <= pair[last]["nic_bytes_at_start"], "overlapping counter ranges")
        pair["first"] = first
        attempts.append(pair)
    for name in spec["names"]:
        selected = [k for k in records if re.fullmatch(rf"{spec['prefix']}/[0-9]+-{name}\.json", k)]
        require(len(selected) == len(attempts), "unaccounted completed first attempt")
    clean = [pair for pair in attempts if pair[CONTROL]["clean"] and pair[TRIAL]["clean"]]
    summary = {"common_clean_pairs": len(clean), "attempted_pairs": len(attempts),
               "control_first_pairs": sum(p["first"] == CONTROL for p in attempts),
               "joint_tail_and_delivery_pass": sum(all(p[r]["passing_delivery_and_p95"] for r in (CONTROL, TRIAL)) for p in attempts),
               "paired_throughput_change": paired_pct([p[TRIAL]["mib_s"] / p[CONTROL]["mib_s"] for p in clean])}
    for role in (CONTROL, TRIAL):
        rows = [p[role] for p in attempts]
        good = [r for r in rows if r["clean"]]
        summary[role] = {k: median(r[k] for r in good) for k in ("mib_s", "fresh_p95_ms", "fresh_p99_ms",
                                                                  "nic_drops_per_million_sent")}
        summary[role].update(clean=len(good), p95_and_delivery_pass=sum(r["passing_delivery_and_p95"] for r in rows),
                             service_qdisc_drops=sum(r["service_qdisc"]["dropped"] for r in rows),
                             nic_qdisc_drops=sum(r["nic_qdisc"]["dropped"] for r in rows),
                             offered=sum(r["offered"] for r in rows), reopens=sum(r["reopens"] for r in rows))
    source = archive.get("sha256", archive.get("binaries"))
    return dict(date="2026-11-24", stable_direction=spec["id"], setting=mode, control=spec["control"], trial=spec["trial"],
                evidence_tier="Source/fixture replay of raw historical VM measurements; no new VM or peer timing.",
                source_archive=spec["archive"], source_sha256=spec["sha256"], archive_revision=spec["archive_revision"],
                recording_source_base=spec["base"], platform=archive["platform"], fixed_client_sha256=source["fixed-client"],
                analyzer_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                verdict=spec["verdict"], next_check=spec["next_check"],
                workload="32 original bulk sockets, 8 MiB bodies, 240 fresh requests at 40/s over six seconds.",
                method="Read both qdiscs before and after every invocation, require identical effective policy except the one "
                       "service setting, pair by recorded block and infer order from monotone disjoint NIC byte counters. "
                       "Exact percentile bootstrap of the paired median resamples entire clean blocks. "
                       "Drops are local fq counters over the complete invocation. p95/p99 are client-recorded fresh request "
                       "latencies from the scheduled arrival, summarized as medians of trials. Shared-host block variability "
                       "limits inference. These conditional controls differ from the revised stock control.",
                preliminary=("No additional nicoff/bothoff client attempts found in extra." if mode == "pacing" else
                             "The earlier quantum-first-readback setup has a stock observation and an unscored nic64 "
                             "before-readback, with no nic64 or both64 completed load. No pair from that setup."),
                summary=summary, attempts=attempts)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=MODES)
    args = parser.parse_args()
    print(json.dumps(replay(args.mode), indent=2, sort_keys=True))
