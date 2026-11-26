"""Verify service fq timer-slack deferrals against application delivery in the original VM archive."""
import hashlib
import json
import re
import sys
from pathlib import Path
from statistics import median

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "scripts/relaybench"))
from gamma_contrasts import GIB, read_receipt, stream_rates
from guest_tx_replay import paired_pct

ARCHIVE = ROOT / "docs/benchmarks/2026-11-21/gamma-mixed-path.json.gz"
DIGEST = "09ebe5510401244cd6d299c1d0cf6dd8f88b256bf14b8c2c14f6db3eff61b74a"
ARMS = ("on", "slack")
COUNTS = ("bytes", "packets", "drops", "throttled")


def verify(ok, why):
    if not ok:
        raise ValueError(why)


def qdiscs(raw):
    result = {}
    for block in re.split(r"(?=^qdisc )", raw, flags=re.M)[1:]:
        header = block.splitlines()[0].strip()
        handle = header.split()[2]
        sent = re.search(r"^ Sent (\d+) bytes (\d+) pkt \(dropped (\d+),", block, re.M)
        throttled = re.search(r"^  gc .*?\bthrottled (\d+)\b", block, re.M)
        verify(header.startswith("qdisc fq ") and sent and throttled and handle not in result, "invalid fq counters")
        result[handle] = dict(header=header, **dict(zip(COUNTS, map(int, (*sent.groups(), throttled[1])))))
    return result


def attempt(records, block, arm):
    key = f"pacing/{block}-{arm}"
    before = qdiscs(records[key + ".before"])
    after = qdiscs(records[key + ".after"])
    verify(set(before) == {"800b:"} and set(after) == {"8001:", "800b:"}, "unexpected capture endpoints")
    service, end, nic = before["800b:"], after["800b:"], after["8001:"]
    slack = 10 if arm == "on" else 100
    verify(service["header"] == end["header"] and f"timer_slack {slack}us " in end["header"], "service slack changed")
    verify("timer_slack 10us " in nic["header"] and
           all(" nopacing " not in q["header"] and "quantum 3028b " in q["header"] for q in (end, nic)),
           "NIC settings or pacing changed")
    delta = {k: end[k] - service[k] for k in COUNTS}
    verify(min(delta.values()) >= 0 and delta["bytes"] > 0 and delta["packets"] > 0, "service counter reset")
    sample = records[key + ".json"]
    verify(sample["streams"] == 32 and sample["arrivals"] == 240 and sample["period_us"] == 25000, "offered load")
    rate = stream_rates(sample, sample["window_s"], sample["mib_s"])["mib_s"]
    clean = not sample["errors"] and not sample["reopened"] and not records[key + ".err"]
    return dict(key=key, service_before=service, service_after=end, nic_after=nic, service_delta=delta,
                deferrals_per_service_gib=delta["throttled"] / (delta["bytes"] / GIB),
                mib_s=rate, bulk_bytes=sample["bytes"], seconds=sample["window_s"], fresh_offers=sample["arrivals"],
                p95_ms=sample["fresh_p95_us"] / 1000, p99_ms=sample["fresh_p99_us"] / 1000,
                errors=sample["errors"], reopened=sample["reopened"], stderr=records[key + ".err"],
                clean=clean, passes=clean and sample["fresh_p95_us"] <= 75000)


def replay():
    archive = read_receipt(ARCHIVE, DIGEST)
    r = archive["records"]
    verify(r["pacing/limits"]["cpu.max"] == "400000 100000" and r["pacing/limits"]["visible_cpus"] == 4
           and r["pacing/limits"]["memory.max"] == "1073741824" and "congctl reno" in r["pacing/route"],
           "platform budget or route mismatch")
    script = r["fixtures/pacing-test.sh"]
    orders = {int(i): text.split() for i, text in re.findall(r"(\d+)\)order='([^']+)'", script)}
    verify(set(orders) == set(range(6)), "missing original arm order")
    expected = {f"pacing/{i}-{arm}.json" for i in orders for arm in ARMS}
    verify(expected == {k for k in r if re.fullmatch(r"pacing/\d+-(?:on|slack)\.json", k)}, "attempt inventory")
    blocks = []
    for i, order in sorted(orders.items()):
        pair = {arm: attempt(r, i, arm) for arm in ARMS}
        a, b = pair["on"], pair["slack"]
        first, second = sorted(ARMS, key=order.index)
        verify(pair[first]["service_after"]["bytes"] <= pair[second]["service_before"]["bytes"],
               "service counter order disagrees with original driver")
        verify(a["nic_after"]["header"] == b["nic_after"]["header"] and
               a["service_before"]["header"] == b["service_before"]["header"].replace("timer_slack 100us", "timer_slack 10us"),
               "another qdisc setting changed")
        blocks.append(dict(block=i, first=first, **pair))
    common = [b for b in blocks if all(b[arm]["clean"] for arm in ARMS)]
    summaries = {}
    for arm in ARMS:
        rows = [b[arm] for b in blocks]
        summaries[arm] = {k: median(r[k] for r in rows) for k in ("mib_s", "p95_ms", "p99_ms", "deferrals_per_service_gib")}
        summaries[arm].update(passes=sum(r["passes"] for r in rows), clean=sum(r["clean"] for r in rows),
                              fresh_offers=sum(r["fresh_offers"] for r in rows),
                              service_drops=sum(r["service_delta"]["drops"] for r in rows))
    paired = {k: paired_pct([b["slack"][k] / b["on"][k] for b in common]) for k in ("mib_s", "deferrals_per_service_gib")}
    return dict(date="2026-11-24", stable_id="231.07", evidence_tier="archived VM", source_revision="4f887ba5d28f47fa37d4bd0a2d89cd0914d74754",
                archive_revision="692ace081c989f80fb2bce27a5a13af13098b77c", archive_sha256=DIGEST,
                client_sha256=archive["binaries"]["fixed-client"], fixture_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                fixture_inputs={k: hashlib.sha256(r[k].encode()).hexdigest() for k in ("fixtures/pacing-test.sh", "fixtures/pacing-action")},
                image_sha256=archive["platform"]["image_sha256"], pairs=blocks, summaries=summaries,
                common_clean=len(common), common_passing=sum(all(b[arm]["passes"] for arm in ARMS) for b in blocks),
                paired=paired)


if __name__ == "__main__":
    print(json.dumps(replay(), indent=2))
