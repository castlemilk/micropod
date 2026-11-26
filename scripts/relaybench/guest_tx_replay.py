"""Replay the jumbo segmentation and fq flow-limit observations without a guest or network."""
import argparse
import hashlib
import json
import re
from itertools import product
from statistics import median

from gamma_contrasts import GIB, MIB, ROOT, percentile, read_receipt, stream_rates

DIRECTORY = ROOT / "docs/benchmarks/2026-11-21"
ARCHIVES = {
    "jumbo": ("gamma-vnic.json.gz", "2d20e203cc135a4a86828b8b365fc7885b225b9b452c276ad1f761fd97556b8f"),
    "fq": ("gamma-mixed-scheduler.json.gz", "9e3b184de862aafacff47312878441e940d030e8cfc8342c0e479d064f4724c8"),
}


def check(valid, diagnostic):
    if not valid:
        raise ValueError(diagnostic)


def paired_pct(ratios):
    changes = [100 * (r - 1) for r in ratios]
    # Six common blocks give only 46,656 ordered bootstrap resamples.
    replicates = [median(block) for block in product(changes, repeat=len(changes))]
    return {"n": len(ratios), "median_pct": median(changes), "increases": sum(r > 1 for r in ratios),
            "bootstrap_95_pct": [percentile(replicates, q) for q in (.025, .975)]}


def mtu_links(snapshot):
    return {kind: int(re.search(pattern, snapshot, re.M)[1]) for kind, pattern in {
        "eth0": r"^\d+: eth0: .*? mtu (\d+)\b", "mpci0": r"^\d+: mpci0: .*? mtu (\d+)\b",
        "veth": r"^\d+: veth\w+@eth0: .*? mtu (\d+)\b"}.items()}


def jumbo(archive):
    records = archive["raw"]
    probe = ROOT / "scripts/profile_vnic.bt"
    probe_hash = hashlib.sha256(probe.read_bytes()).hexdigest()
    check(probe_hash == archive["sources_sha256"]["scripts/profile_vnic.bt"], "probe source hash")
    profiles = {}
    for name, mtu in (("stock", 1500), ("jumbo", 9000)):
        prefix = f"bpf-{name}-exact/"
        profile = {k: v for obj in records[prefix + "maps"] if obj["type"] in ("hist", "map")
                   for k, v in obj["data"].items()}
        links = mtu_links(records[prefix + "before"])
        check(links == mtu_links(records[prefix + "after"]) and all(n == mtu for n in links.values()), "MTU readbacks")
        client = records[prefix + "bulk.json"]
        check(records[prefix + "status"] == 0 and not records[prefix + "bulk.err"]
              and not records[prefix + "trace.err"] and client["bytes"] == 6 * GIB
              and client["reopened_connections"] == 0 and client["streams"] == 32, "profiled client")
        calls, segments, sent = (sum(profile[k].values()) for k in ("@tx_calls", "@tx_segments", "@tx_bytes"))
        check(sum(row["count"] for row in profile["@tx_size"]) == calls, "call histogram vs per-CPU map")
        profiles[name] = {"mtu_before_and_after": links, "eth0_xmit_calls": calls,
                          "eth0_gso_segments_or_one": segments, "eth0_skb_bytes": sent,
                          "skb_bytes_per_reported_segment": sent / segments,
                          "reported_segments_per_tx_call": segments / calls, "skb_bytes_per_tx_call": sent / calls,
                          "per_cpu_gso_segments_or_one": profile["@tx_segments"],
                          "per_cpu_tx_bytes": profile["@tx_bytes"], "per_cpu_tx_calls": profile["@tx_calls"],
                          "service_retransmit_events": profile["@tcp_retransmits"], "client": client}
    bursts = []
    for block in range(1, 7):
        arms = {}
        for name in ("control", "trial"):
            prefix = f"mtu-screen/{block}-{name}"
            raw = records[prefix + ".json"]
            check(records[prefix + ".status"] == 0 and not records[prefix + ".err"]
                  and raw["parallel_streams"] == 32 and raw["parallel_barrier"] and raw["requests"] == 100
                  and len(raw["parallel_bursts_mib_s"]) == 3
                  and median(raw["parallel_bursts_mib_s"]) == raw["parallel_mib_s"], "matched burst")
            arms[name] = {k: raw[k] for k in ("parallel_bursts_mib_s", "parallel_mib_s", "fresh_p95_us", "fresh_p99_us")}
        bursts.append(arms)
    return {"stable_id": "229.01", "recording_source_base": archive["parent_commit"],
            "archive_revision": "4f887ba5d28f47fa37d4bd0a2d89cd0914d74754",
            "probe_sha256": probe_hash, "image": archive["image"], "profiled_6gib": profiles,
            "burst_screen_separate": bursts, "paired_burst_mib_s": paired_pct([
                x["trial"]["parallel_mib_s"] / x["control"]["parallel_mib_s"] for x in bursts]),
            "interpretation": "Bytes per reported TX segment barely changed. The driver trace counts sk_buff length "
                              "at guest eth0 divided by sum(max(gso_segs,1)); it is device-wide and does not establish "
                              "MSS, on-wire frame size, or the distribution of individual segment sizes. Separate private "
                              "workers and one profiled transfer per arm leave causal attribution open. The six-block "
                              "burst screen is distinct from the profiled transfers; idle fresh tails are not loaded tails."}


def qdisc_counters(snapshot, expected_nic_limit):
    headers = re.findall(r"^qdisc fq (\w+): .*?limit (\d+)p flow_limit (\d+)p", snapshot, re.M)
    check(headers == [("8001", "10000", str(expected_nic_limit)), ("8002", "10000", "100")], "fq policy readback")
    traffic = re.findall(r"^ Sent (\d+) bytes (\d+) pkt \(dropped (\d+),", snapshot, re.M)
    check(len(traffic) == 2, "NIC/service qdisc snapshots")
    matches = re.findall(r"\bflows_plimit (\d+)", snapshot.split("qdisc fq 8002:")[0])
    check(len(matches) == 1, "NIC per-flow drop counter")
    return {"nic_flow_limit_drops": int(matches[0]), "nic_packets": int(traffic[0][1]),
            "nic_drops": int(traffic[0][2]), "service_qdisc_bytes": int(traffic[1][0]),
            "service_qdisc_packets": int(traffic[1][1]), "service_qdisc_drops": int(traffic[1][2]),
            "service_retransmitted_segments": int(re.search(r"^service_tcp Tcp:RetransSegs (\d+)$", snapshot, re.M)[1])}


def fq(archive):
    records = archive["records"]
    blocks = []
    for block in range(8):
        pair = {}
        for arm, limit in (("ordinary", 100), ("f256", 256)):
            prefix = f"flow-limit/{block}-{arm}"
            raw = records[prefix + ".json"]
            check(raw["arrivals"] == 240 and raw["period_us"] == 25000 and raw["streams"] == 32
                  and not records[prefix + ".err"], "client workload")
            stream_rates(raw, raw["window_s"], raw["mib_s"])
            errors = raw["errors"] or []
            check(all('/id"' in e for e in errors), "fresh vs bulk error attribution")
            clean = not errors and raw["reopened"] == 0
            before, after = (qdisc_counters(records[prefix + s], limit) for s in (".qbefore", ".qafter"))
            delta = {k: after[k] - before[k] for k in before}
            check(all(n >= 0 for n in delta.values()) and delta["service_qdisc_bytes"] > 0, "counter reset")
            pair[arm] = {"begin_epoch_ns": records[prefix + ".before"]["epoch_ns"], "clean": clean,
                         "meets_75ms_and_delivery": clean and raw["fresh_p95_us"] <= 75000,
                         "original_socket_reopens": raw["reopened"], "failed_fresh": len(errors),
                         "offered_fresh": raw["arrivals"], "mib_s": raw["mib_s"], "scored_bytes": raw["bytes"],
                         "fresh_p95_ms": raw["fresh_p95_us"] / 1000, "fresh_p99_ms": raw["fresh_p99_us"] / 1000,
                         "whole_invocation": delta, "retransmitted_segments_per_service_qdisc_gib":
                             delta["service_retransmitted_segments"] * GIB / delta["service_qdisc_bytes"]}
        blocks.append(pair)
    common = [b for b in blocks if all(row["clean"] for row in b.values())]
    summary = {k: paired_pct([b["f256"][k] / b["ordinary"][k] for b in common])
               for k in ("mib_s", "retransmitted_segments_per_service_qdisc_gib")}
    for arm in ("ordinary", "f256"):
        rows = [b[arm] for b in blocks]
        summary[arm] = {"attempted": len(rows), "clean": sum(x["clean"] for x in rows),
                        "delivery_and_tail_pass": sum(x["meets_75ms_and_delivery"] for x in rows),
                        "all_fresh_errors": sum(x["failed_fresh"] for x in rows),
                        "all_offered_fresh": sum(x["offered_fresh"] for x in rows),
                        "nic_per_flow_drops_each": [x["whole_invocation"]["nic_flow_limit_drops"] for x in rows],
                        "clean_median_p95_ms": median(x["fresh_p95_ms"] for x in rows if x["clean"]),
                        "clean_median_p99_ms": median(x["fresh_p99_ms"] for x in rows if x["clean"])}
    summary["both_pass_delivery_and_tail"] = sum(all(x["meets_75ms_and_delivery"] for x in b.values()) for b in blocks)
    return {"stable_id": "231.08", "recording_source_base": "692ace081c989f80fb2bce27a5a13af13098b77c",
            "archive_revision": "816121afd30fba52bda7828418cd963d4216166b",
            "fixed_client_sha256": archive["sha256"]["fixed-client"], "platform": archive["platform"],
            "full_invocation_units": "Retransmitted TCP segments divided by bytes through the service qdisc / 2^30. "
                                     "This is not payload GiB or a packet-loss ratio. Counters include warmup and drain.",
            "blocks": blocks, "summary": summary,
            "interpretation": "256 eliminated the observed NIC per-flow drops. Client failures and >75 ms fresh tails "
                              "persisted. Select no policy for the revised worker from this historical comparison."}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trial", choices=ARCHIVES)
    mode = parser.parse_args().trial
    name, sha = ARCHIVES[mode]
    receipt = read_receipt(DIRECTORY / name, sha)
    report = jumbo(receipt) if mode == "jumbo" else fq(receipt)
    print(json.dumps({"date": "2026-11-24", "evidence_tier": "offline replay of archived VM observations",
                      "archive": name, "archive_sha256": sha,
                      "paired_interval": "Median within-block change. Nearest-rank 2.5th and 97.5th percentiles "
                                         "of every ordered paired bootstrap resample of the complete blocks.",
                      **report}, indent=2, allow_nan=False))
