"""Replay quiet service HTTP and sibling bulk measurements. Reads two archived files."""
import json
from statistics import median

from gamma_contrasts import ROOT, read_receipt


ARCHIVES = ROOT / "docs/benchmarks/2026-11-21"
LATENCY = ("keepalive_p50_us", "keepalive_p95_us", "fresh_p50_us", "fresh_p95_us")


def paired(a, b):
    return {"micropod": median(a), "orb": median(b), "median_difference": median(x - y for x, y in zip(a, b)),
            "micropod_lower": sum(x < y for x, y in zip(a, b)), "ties": sum(x == y for x, y in zip(a, b)),
            "pairs": len(a)}


def main():
    native = read_receipt(ARCHIVES / "native-network.json.gz",
                          "e457d0da18c1b6812d71db160151e08d41c70a3c466cc945b5e4c7ee05ed4bb7")
    vnic = read_receipt(ARCHIVES / "gamma-vnic.json.gz",
                        "2d20e203cc135a4a86828b8b365fc7885b225b9b452c276ad1f761fd97556b8f")["raw"]
    result = {}
    for epoch in ("stock_docker_network", "pre_reuse_traffic"):
        result[epoch] = {}
        for engine, records in native[epoch].items():
            if len(records) != 6 or any(r["requests"] != 200 for r in records):
                raise ValueError("unexpected service sample count")
            result[epoch][engine] = {k: median(r[k] for r in records) for k in LATENCY}
    companion = {}
    for row in native["dns_crossover"]:
        if row["implementation"] in ("base", "orb"):
            key = (row["clients"], row["round"], row["implementation"])
            if key in companion or row["traffic"]["requests"] != 8:
                raise ValueError("duplicate or incomparable HTTP companion")
            companion[key] = row["traffic"]
    result["dns_companion"] = {}
    for clients in (1, 16, 32):
        result["dns_companion"][clients] = {}
        for metric in LATENCY:
            a, b = ([companion[clients, n, engine][metric] for n in range(1, 15)] for engine in ("base", "orb"))
            result["dns_companion"][clients][metric] = paired(a, b)
    result["sibling_mib_s"] = {}
    for mode, expected_bytes in (("bulk", 6 * 2**30), ("burst-fresh", 256 * 2**20)):
        rates = {}
        for engine in ("relay", "orb"):
            rates[engine] = []
            for n in range(6):
                key = f"siblings/{n}-{engine}-{mode}"
                row = vnic[key + ".json"]
                if vnic[key + ".status"] != 0 or row["bytes"] != expected_bytes or row["streams"] != 32:
                    raise ValueError("unclean sibling sample")
                faults = (row["reopened_connections"] if mode == "bulk" else
                          row["unexpected_reconnects"] + row["initial_connection_mismatches"])
                if faults:
                    raise ValueError("unexpected sibling reconnect")
                rates[engine].append(row["mib_s"])
        a, b = rates["relay"], rates["orb"]
        result["sibling_mib_s"][mode] = dict(paired(a, b), median_pct=median(100 * (x / y - 1) for x, y in zip(a, b)))
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
