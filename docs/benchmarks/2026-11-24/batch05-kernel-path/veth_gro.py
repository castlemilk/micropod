"""Reconstruct the service-veth GRO crossover from its original VM measurements."""
import hashlib
import json
import math
import sys
from pathlib import Path
from statistics import median

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "scripts/relaybench"))
from gamma_contrasts import paired_median_interval, percentile, read_receipt

ARCHIVE = ROOT / "docs/benchmarks/2026-11-21/gamma-vnic.json.gz"
SHA = "2d20e203cc135a4a86828b8b365fc7885b225b9b452c276ad1f761fd97556b8f"
DRIVER = "9029f59ace7da117a76a023f758f4e9d9c2b64d49a7345babd2d7047f6dabf61"
SETTER = "55eca9b42e6fb01a27ea97993645934c5d52dcff50054691c0c74aada4ed14ef"
CLIENT = "6e2531ef4bed59edd55144630a7bff68a3e1f63fae606d276a4cf3913a48abbd"


def require(ok, reason):
    if not ok:
        raise ValueError(reason)


def score(raw, prefix, arm, peer):
    require(raw[prefix + ".state"].splitlines() == [peer, "generic-receive-offload: " + arm],
            "missing effective GRO readback")
    require(raw[prefix + ".status"] == 0 and raw[prefix + ".err"] is None, "dirty first attempt")
    c = raw[prefix + ".json"]
    phases = c["stream_phases"]
    require(len(phases) == c["streams"] == 32 and c["transfers_per_stream"] == 1 and
            c["warm"] is False and c["first_response_barrier"] is True and
            c["bytes"] == 32 * 8 * 2**20 and c["unexpected_reconnects"] == c["initial_connection_mismatches"] == 0,
            "incomplete burst or changed workload")
    for p in phases:
        require(0 < p["connected_us"] <= p["request_written_us"] <= p["first_header_us"]
                <= p["first_body_complete_us"] <= p["complete_us"] <= c["elapsed_us"], "invalid phase timing")
    rate = c["bytes"] * 1e6 / (2**20 * c["elapsed_us"])
    require(math.isclose(rate, c["mib_s"], rel_tol=1.5e-5), "throughput check failed")
    return dict(raw_key=prefix, mib_s=c["mib_s"], bytes=c["bytes"], elapsed_us=c["elapsed_us"],
                completed_streams=len(phases), reopens=c["unexpected_reconnects"],
                header_p95_ms=percentile([p["first_header_us"] for p in phases], .95) / 1000,
                body_done_p95_ms=percentile([p["complete_us"] for p in phases], .95) / 1000,
                body_done_p99_ms=percentile([p["complete_us"] for p in phases], .99) / 1000)


def main():
    data = read_receipt(ARCHIVE, SHA)
    r = data["raw"]
    for name, expected in (("ablate.sh", DRIVER), ("vnic-action.sh", SETTER)):
        require(hashlib.sha256(data["experiment_drivers"][name].encode()).hexdigest() == expected,
                "original setting or order driver changed")
    require(data["binaries_sha256"]["netbench-shapes"] == CLIENT, "historical client identity changed")
    require(r["relay.boot"]["cpus"] == 4 and r["relay.limits"]["cpu.max"] == "400000 100000"
            and r["relay.limits"]["pids.max"] == "512" and r["relay.limits"]["memory.max"] == "1073741824",
            "service budget mismatch")
    prefix = "ablation/gro-"
    expected = {f"{prefix}{i}-{k}.{s}" for i in range(6) for k in ("off", "on")
                for s in ("json", "status", "state", "err")}
    require({k for k in r if k.startswith(prefix)} == expected, "incomplete or extra attempts")
    peer = "vethe8c758f6"
    require(f"{peer}@if2:" in r["relay.state"] and "master mpci0" in r["relay.state"] and
            r["ablation/restored"] == f"{peer}\ngeneric-receive-offload: off", "wrong bridge peer or restoration")
    rows = []
    for i in range(6):
        row = {"block": i, "order": ["off","on"] if i % 2 == 0 else ["on","off"]}
        for arm in row["order"]:
            row[arm] = score(r, f"{prefix}{i}-{arm}", arm, peer)
        rows.append(row)
    metrics = {}
    for k in ("mib_s","header_p95_ms","body_done_p95_ms","body_done_p99_ms"):
        changes = [100 * (p["on"][k] / p["off"][k] - 1) for p in rows]
        metrics[k] = dict(control_median=median(p["off"][k] for p in rows),
                          candidate_median=median(p["on"][k] for p in rows),
                          paired_median_pct=median(changes), paired_bootstrap_95_pct=paired_median_interval(changes),
                          candidate_higher=sum(x > 0 for x in changes))
    return dict(direction="231.01", evidence="offline replay of archived VM first attempts", archive=ARCHIVE.name,
                sha256=SHA, source_parent=data["parent_commit"], archive_revision="4f887ba5d28f47fa37d4bd0a2d89cd0914d74754",
                original_driver_sha256=DRIVER, original_setter_sha256=SETTER, client_sha256=CLIENT,
                image=data["image"], relay_binary=data["binaries_sha256"]["relay"],
                guest_boot=r["relay.boot"]["boot"], metrics=metrics, blocks=rows,
                limitations="Burst-only workload. Phase quantiles are across 32 simultaneous 8 MiB transfers from "
                            "one launch; p99 is the maximum. No concurrent short GETs, NIC loss counter deltas, "
                            "process CPU/GiB or runnable time in these arms. Six alternating blocks, non-randomized.")

if __name__ == "__main__":
    print(json.dumps(main(), indent=2, allow_nan=False))
