"""Reconcile six retained Go-splice/ordinary pairs against uplink traffic and VMM work."""
import hashlib
import json
import re
from pathlib import Path
from statistics import median

from gamma_contrasts import GIB, clean_client, process_delta, stream_rates
from guest_tx_replay import ARCHIVES, DIRECTORY, check, paired_pct, read_receipt

ARM_NAMES = ("ordinary", "splice")


def nic_counts(snapshot):
    headers = re.findall(r"^qdisc fq (\w+): root .*?limit (\d+)p flow_limit (\d+)p", snapshot, re.M)
    check(headers == [('8001', '10000', '100'), ('8002', '10000', '100')], "NIC and service qdiscs")
    counts = re.findall(r"^ Sent (\d+) bytes (\d+) pkt \(dropped (\d+),", snapshot, re.M)
    check(len(counts) == 2, "device send counters")
    return tuple(map(int, counts[0]))


def replay():
    name, digest = ARCHIVES["fq"]
    archive = read_receipt(DIRECTORY / name, digest)
    records = archive["records"]
    pid = int(records["vmm.pid"])
    pairs = []
    for block in range(6):
        pair = {}
        for arm in ARM_NAMES:
            prefix = f"extra/{block}-{arm}"
            client = records[prefix + ".json"]
            check(clean_client(client) and client["arrivals"] == 240 and client["period_us"] == 25000
                  and client["streams"] == 32 and not records[prefix + ".err"], "incomplete fixed-rate attempt")
            stream_rates(client, client["window_s"], client["mib_s"])
            before, after = (records[prefix+s] for s in (".before", ".after"))
            cost = process_delta(before, after, pid)
            first, last = (nic_counts(records[prefix+s]) for s in (".qbefore", ".qafter"))
            sent, packets, drops = (end - start for start, end in zip(first, last))
            check(sent >= client["bytes"] > 0 and packets > 0 and drops >= 0 and cost["wait_s"] >= 0,
                  "inconsistent counters")
            check(cost["sample_seconds"] >= client["window_s"], "observer shorter than scoring")
            pair[arm] = dict(start_epoch_ns=before["epoch_ns"], scored_body_bytes=client["bytes"],
                             mib_s=client["mib_s"], fresh_p95_ms=client["fresh_p95_us"]/1000,
                             fresh_p99_ms=client["fresh_p99_us"]/1000, bulk_reopens=client["reopened"],
                             fresh_errors=len(client["errors"] or []), nic_first=first, nic_last=last,
                             nic_sent_bytes=sent, nic_packets=packets, nic_drops=drops, process=cost,
                             vmm_cpu_s_per_nic_gib=cost["cpu_s"]/(sent/GIB),
                             vmm_wait_thread_s_per_nic_gib=cost["wait_s"]/(sent/GIB))
        pairs.append(pair)
    metrics = ("mib_s", "fresh_p95_ms", "fresh_p99_ms", "vmm_cpu_s_per_nic_gib", "vmm_wait_thread_s_per_nic_gib")
    changes = {k: paired_pct([b["splice"][k]/b["ordinary"][k] for b in pairs]) for k in metrics}
    summaries = {}
    for arm in ARM_NAMES:
        summaries[arm] = {k: median(b[arm][k] for b in pairs) for k in metrics}
        summaries[arm]["all_nic_drops"] = [b[arm]["nic_drops"] for b in pairs]
        summaries[arm]["delivery_and_75ms"] = sum(b[arm]["fresh_p95_ms"] <= 75 for b in pairs)
    return dict(direction="234.01", date="2026-11-24", tier="offline replay of historical VM observations",
                source_base="692ace081c989f80fb2bce27a5a13af13098b77c",
                archive_commit="816121afd30fba52bda7828418cd963d4216166b", archive=name, archive_sha256=digest,
                splice_binary_sha256=archive["sha256"]["splice"], fixed_client_sha256=archive["sha256"]["fixed-client"],
                platform=archive["platform"], vmm_pid=pid, fixture_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                method="One contrast, ordinary container ingress versus guest TCP splice forwarder. "
                       "VMM process observations and device-wide NIC qdisc deltas bracket each invocation. "
                       "NIC-accounted GiB includes headers, retransmissions and background traffic. The archive "
                       "does not identify full-invocation application bytes or guest forwarder CPU. "
                       "95% percentile intervals use all ordered bootstrap resamples of six paired blocks.",
                pairs=pairs, medians=summaries, paired_change_pct=changes)


if __name__ == "__main__":
    print(json.dumps(replay(), indent=2, allow_nan=False))
