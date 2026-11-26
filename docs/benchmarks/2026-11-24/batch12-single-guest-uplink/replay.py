"""Replay one data worker on the primary or dedicated host-only guest NIC."""
import hashlib
import json
import math
from pathlib import Path
import re
from statistics import median
import sys

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "scripts/relaybench"))
from gamma_contrasts import paired_median_interval, percentile, read_receipt

ARCHIVE = ROOT / "docs/benchmarks/2026-11-21/gamma-vnic.json.gz"
ARCHIVE_SHA = "2d20e203cc135a4a86828b8b365fc7885b225b9b452c276ad1f761fd97556b8f"
DRIVERS = {
    "pilot.sh": "269e1dae3294a58d613d22e20269e9d8158b075f5c8b9e979e59679c14106039",
    "lanes.c": "3cdc77bc7338ac4068387b14e59809f538aee4137508391ef4a5c9df42ece5ed",
    "topology.py": "460d9e4685299c9aeb0f66eb9bf4f4715686f7642f0ccc8a80546377d8bdb272",
}
ARMS = ("split1", "private1")
ORDER = ["original", "split1", "split2", "split4", "private1", "private2", "private4"]


def check(condition, reason):
    if not condition:
        raise ValueError(reason)


def score(raw, key, warm):
    check(raw[key + ".status"] == 0 and raw[key + ".err"] is None, key + " failed")
    s = raw[key + ".json"]
    phases = s["stream_phases"]
    check(s["warm"] is warm and s["first_response_barrier"] is True and
          s["streams"] == len(phases) == 32 and s["transfers_per_stream"] == 1 and
          s["bytes"] == 32 * 8 * 2**20 and s["unexpected_reconnects"] == s["initial_connection_mismatches"] == 0,
          key + " changed workload or lost delivery")
    for p in phases:
        check(0 <= p["connected_us"] <= p["request_written_us"] <= p["first_header_us"]
              <= p["first_body_complete_us"] <= p["complete_us"] <= s["elapsed_us"], key + " invalid phases")
    rate = s["bytes"] / 2**20 * 1e6 / s["elapsed_us"]
    check(math.isclose(rate, s["mib_s"], rel_tol=0.000025), key + " rate disagrees with bytes and duration")
    return {"raw_key": key, "bytes": s["bytes"], "streams": s["streams"], "elapsed_us": s["elapsed_us"],
            "mib_s": rate, "header_p95_ms": percentile([p["first_header_us"] for p in phases], .95) / 1000,
            "body_complete_p95_ms": percentile([p["complete_us"] for p in phases], .95) / 1000}


def run():
    receipt = read_receipt(ARCHIVE, ARCHIVE_SHA)
    raw = receipt["raw"]
    for driver, digest in DRIVERS.items():
        check(hashlib.sha256(receipt["experiment_drivers"][driver].encode()).hexdigest() == digest, driver)
    pilot = receipt["experiment_drivers"]["pilot.sh"]
    for line in ('listen split1 "${p0[@]}"', 'listen private1 "${p1[@]}"',
                 'keys=(' + " ".join(ORDER) + ')', 'key=${keys[$(((i+r)%7))]}'):
        check(line in pilot, "changed link or rotation")
    state = raw["links.state"]
    primary_ip, port, pod = raw["links.target"].split()
    extra = next(line.split() for line in raw["links.extra"].splitlines() if line.startswith("eth1 "))
    dev, private_gateway, private_ip, private_port = extra
    primary_gateway = primary_ip.rsplit(".", 1)[0] + ".1"
    check(primary_ip == raw["links.boot"]["guestAddress"] and private_port == port and
          f"tcp dpt:{port} to:{pod}:8080" in state and
          f"default via {primary_gateway} dev eth0" in state and "master mpci0" in state, "lease or bridge changed")
    links = {}
    for arm, nic, gateway, ip in [(ARMS[0], "eth0", primary_gateway, primary_ip),
                                   (ARMS[1], dev, private_gateway, private_ip)]:
        mac = re.search(rf"^\d+: {nic}: [^\n]+?mtu 1500 qdisc pfifo_fast [^\n]*\n\s+link/ether ([\da-f:]+)", state, re.M)
        check(mac and f"dev {nic} scope link  src {ip}" in state, "missing interface identity")
        links[arm] = {"nic": nic, "mtu": 1500, "mac": mac[1], "gateway": gateway, "guest_ip": ip,
                      "guest_port": port, "listener": raw[f"lane-screen/{arm}.addr"]}
    inputs = {f"lane-screen/{i}-{arm}-{mode}.{suffix}" for i in range(6)
              for arm in ARMS for mode in ("warm", "fresh") for suffix in ("json", "status", "err")}
    found = {k for k in raw if re.match(r"lane-screen/\d+-(split1|private1)-", k)}
    check(found == inputs, "missing or extra trials")
    results = {}
    for mode in ("fresh", "warm"):
        pairs = []
        for i in range(6):
            rotation = ORDER[i:] + ORDER[:i]
            row = {"block": i, "relative_order": [arm for arm in rotation if arm in ARMS]}
            for arm in ARMS:
                row[arm] = score(raw, f"lane-screen/{i}-{arm}-{mode}", mode == "warm")
            pairs.append(row)
        summary = {}
        for field in ("mib_s", "header_p95_ms", "body_complete_p95_ms"):
            changes = [100 * (row[ARMS[1]][field] / row[ARMS[0]][field] - 1) for row in pairs]
            summary[field] = {
                "control_median": median(r[ARMS[0]][field] for r in pairs),
                "candidate_median": median(r[ARMS[1]][field] for r in pairs),
                "paired_median_pct": median(changes), "paired_bootstrap_95_pct": paired_median_interval(changes),
                "candidate_higher": sum(n > 0 for n in changes),
            }
        results[mode] = {"valid_pairs": len(pairs), "bytes_per_arm": sum(r[ARMS[0]]["bytes"] for r in pairs),
                         "summary": summary, "pairs": pairs}
    return {"direction": "229.01", "evidence": "archived VM receiver-delivered bytes",
            "archive": str(ARCHIVE.relative_to(ROOT)), "archive_sha256": ARCHIVE_SHA,
            "source_parent": receipt["parent_commit"], "source_driver_sha256": DRIVERS,
            "client_sha256": receipt["binaries_sha256"]["netbench-shapes"],
            "worker_binary_sha256": receipt["binaries_sha256"]["links"], "boot": raw["links.boot"],
            "service": {"name": raw["links.name"], "id": raw["links.id"], "address": pod,
                        "image": receipt["image"]},
            "listener_owners": 1, "data_workers": 1, "links": links, "results": results}


if __name__ == "__main__":
    print(json.dumps(run(), indent=2))
