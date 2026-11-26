"""Replay the revised Gamma baseline and the historical Micropod side of the holdout."""
import hashlib
import json
import math
from pathlib import Path
from statistics import median
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
sys.path.insert(0, str(ROOT / "scripts/relaybench"))
from gamma_contrasts import IMAGE, VM, process_work, read_receipt, stream_rates, vm_rows
from peer_verdict import ARCHIVE_SHA

BASELINE = HERE.parent / "20261124T090510Z-local-d0y_1j57/baseline/receiver"


def pinned(name, digest):
    raw = (BASELINE / name).read_bytes()
    if hashlib.sha256(raw).hexdigest() != digest:
        raise ValueError("unexpected input: " + name)
    return json.loads(raw)


def metrics(client, host):
    streams = stream_rates(client, client["window_s"], client["mib_s"])
    result = dict(mib_s=streams["mib_s"], p95_ms=client["fresh_p95_us"] / 1000,
                  p99_ms=client["fresh_p99_us"] / 1000, hottest_stream_uplift_pct=streams["extra_pct"])
    result["slowest_quarter_share_pct"] = 100 * sum(sorted(client["per_stream_bytes"])[:8]) / client["bytes"]
    if host["relay"]["sample_seconds"] != host["vmm"]["sample_seconds"]:
        raise ValueError("process counters must share one bracket")
    for process in ("relay", "vmm"):
        part = host[process]
        result[process + "_cores"] = part["cpu_s"] / part["sample_seconds"]
        for key in ("cpu_s_per_gib", "wait_s_per_s", "runnable_s_per_s"):
            result[process + "_" + key] = part[key]
    for key in ("cores", "cpu_s_per_gib", "wait_s_per_s", "runnable_s_per_s"):
        result["total_" + key] = result["relay_" + key] + result["vmm_" + key]
    result["bracket_over_score"] = host["vmm"]["sample_seconds"] / client["window_s"]
    return result


def replay():
    archive = read_receipt(VM, ARCHIVE_SHA)
    row = pinned("scored-1-A.json", "926c67e7ef43b03f4b0a27af61d81c2780043697f062b2de1e635671c34b6b79")
    fixture = pinned("fixtures.json", "a1179b22de0ce593838884d2d4e35d849572b49be88f580760714ed489b13c6b")["A"]
    plan = pinned("plan.json", "bbc37629eb9e3f690523653169c3e9bb4a4b3f150c8d9d9c3c0f68853e2cad13")
    status = pinned("status.json", "f076f421fe07b2f580cb69345b7ac528c1f4744af0d05e703eaf39f07849e98e")
    if not (fixture["image_config"] == archive["binaries"]["image_config"] == IMAGE
            and plan["tool_sha256"]["fixed"] == archive["binaries"]["client"]
            and status["scored_clean"] == 1 and status["local_vm_idle_and_delivery_qualified"]
            and status["socket_evidence"] == "route" and status["accepted_socket_reno_verified"] is False):
        raise ValueError("workload identity or baseline qualification changed")
    client = json.loads(row["stdout"])
    if not (row["clean"] and client == row["client"] and client["streams"] == 32 and client["arrivals"] == 240
            and client["period_us"] == 25000 and not client["errors"] and client["reopened"] == 0):
        raise ValueError("unclean or different baseline client")
    host = {proc: process_work(row["before"], row["after"], pid, client["bytes"])
            for proc, pid in fixture["pids"].items()}
    current = metrics(client, host)
    records = archive["phases"]["grace-holdout"]["runs"]["confirm-micropod"]
    rows = {r["round"]: r for r in vm_rows(archive) if r["arm"] == "confirm-micropod"}
    if len(rows) != 16 or not all(r["clean"] for r in rows.values()):
        raise ValueError("incomplete historical Micropod holdout")
    previous = {i: metrics(records[str(i)]["client"], r) for i, r in rows.items()}
    best = max(previous, key=lambda i: previous[i]["mib_s"])
    fastest = previous[best]
    factors = dict(host_cpu_service=current["total_cores"] / fastest["total_cores"],
                   bytes_per_cpu_s=fastest["total_cpu_s_per_gib"] / current["total_cpu_s_per_gib"],
                   bracket_over_score=current["bracket_over_score"] / fastest["bracket_over_score"])
    if not math.isclose(math.prod(factors.values()), current["mib_s"] / fastest["mib_s"], rel_tol=1e-12):
        raise ValueError("host work decomposition does not reproduce receiver throughput")
    summary = {}
    for k, v in current.items():
        values = [r[k] for r in previous.values()]
        summary[k] = dict(old_min=min(values), old_median=median(values), old_max=max(values),
                          old_fastest=fastest[k], current=v)
    return dict(historical_fastest_round=best, throughput_factors_vs_historical_fastest=factors,
                historical_rounds=len(rows), current_scored_rounds=1, metrics=summary)


if __name__ == "__main__":
    print(json.dumps(replay(), indent=2, allow_nan=False))
