"""Replay Gamma's two published TCP receipts. This command performs no network or benchmark work."""
import argparse
import gzip
import hashlib
import json
import math
import random
from pathlib import Path
from statistics import median

ROOT = Path(__file__).resolve().parents[2]
RELAY = ROOT / "docs/benchmarks/2026-11-22/gamma-relay-workers.json.gz"
VM = ROOT / "docs/benchmarks/2026-11-21/gamma-vcpu-priority.json.gz"
IMAGE = "sha256:80996a25c9c753fcaf3f421a3f61557497b8ab539bdd68076074d181cfa71889"
MIB = 1 << 20
GIB = 1 << 30


def read_receipt(path, expected):
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError(f"unexpected receipt revision: {path.name}")
    return json.loads(gzip.decompress(data))


def percentile(values, fraction):
    return sorted(values)[math.ceil(len(values) * fraction) - 1]


def stream_rates(sample, seconds, reported_rate):
    """Compute whole-window stream extremes and the fixed-fastest redistribution sensitivity."""
    counts, total = sample["per_stream_bytes"], sample["bytes"]
    if (not isinstance(counts, list) or len(counts) != 32 or any(type(n) is not int or n <= 0 for n in counts)
            or type(total) is not int or total != sum(counts)):
        raise ValueError("expected 32 positive integer stream counts summing to the raw byte total")
    if any(type(v) not in (int, float) or not math.isfinite(v) or v <= 0 for v in (seconds, reported_rate)):
        raise ValueError("expected positive finite elapsed time and throughput")
    scale = 1 / (seconds * MIB)
    if not math.isclose(total * scale, reported_rate):
        raise ValueError("stream bytes and elapsed time disagree with reported throughput")
    equalized_bytes = len(counts) * max(counts)
    return dict(mib_s=total * scale, slowest_mib_s=min(counts) * scale, fastest_mib_s=max(counts) * scale,
                equalized_mib_s=equalized_bytes * scale, extra_mib_s=(equalized_bytes - total) * scale,
                extra_pct=100 * (equalized_bytes - total) / total)


def relay_rows(source, arrivals):
    rows = []
    for record in source:
        ok = record["ok"] if "ok" in record else record["status"] == 0
        row = dict(round=record["round"], arm=record["arm"], ports=record["ports"], clean=ok,
                   fresh_failed=0 if ok else None, runnable_s_per_s=None, wait_s_per_s=None,
                   cpu_s_per_gib=None, offered=arrivals)
        if ok:
            s = record["sample"]
            assert sum(s["per_stream_bytes"]) == s["bytes"] and len(s["per_stream_bytes"]) == 32
            assert min(s["per_stream_bytes"]) > 0 and min(s["fresh_ns"]) > 0
            assert s["ports"] == row["ports"] and len(s["fresh_ns"]) == arrivals
            assert sum(s["bulk_flows_per_owner"]) == 32 and s["client_buffer_kib"] == 512
            row.update(mib_s=s["bytes"] / MIB / (s["elapsed_ns"] / 1e9), arrivals=len(s["fresh_ns"]),
                       p95_ms=percentile(s["fresh_ns"], .95) / 1e6, p99_ms=percentile(s["fresh_ns"], .99) / 1e6)
            if "process_cpu_us" in s:
                row["cpu_s_per_gib"] = s["process_cpu_us"] / 1e6 / (s["bytes"] / GIB)
        else:
            row["error"] = record["error"]
        rows.append(row)
    return rows


def process_delta(before, after, pid):
    """Darwin absolute ticks. Runnable includes executing threads."""
    first = next(t for t in before["tasks"] if t["pid"] == pid)
    last = next(t for t in after["tasks"] if t["pid"] == pid)
    if (first["birth_ticks"] != last["birth_ticks"] or before["tick_numer"] != after["tick_numer"]
            or before["tick_denom"] != after["tick_denom"]):
        raise ValueError(f"counter identity changed for pid {pid}")
    user = last["user_ticks"] - first["user_ticks"]
    system = last["system_ticks"] - first["system_ticks"]
    cpu = user + system
    runnable = last["runnable_ticks"] - first["runnable_ticks"]
    seconds = (after["epoch_ns"] - before["epoch_ns"]) / 1e9
    if min(user, system, runnable) < 0 or seconds <= 0 or min(after["tick_numer"], after["tick_denom"]) <= 0:
        raise ValueError(f"invalid counter delta for pid {pid}")
    scale = after["tick_numer"] / after["tick_denom"] / 1e9
    return dict(cpu_s=cpu * scale, runnable_s=runnable * scale, wait_s=(runnable - cpu) * scale,
                sample_seconds=seconds)


def clean_client(c):
    stream_bytes = c.get("per_stream_bytes", [])
    return (c.get("streams") == 32 and c.get("arrivals") == 240 and c.get("period_us") == 25000
            and "errors" in c and c["errors"] in (None, []) and c.get("reopened") == 0
            and len(stream_bytes) == 32 and min(stream_bytes) > 0 and sum(stream_bytes) == c.get("bytes")
            and c.get("window_s", 0) >= 6 and c.get("mib_s", 0) > 0
            and math.isclose(c["bytes"] / MIB / c["window_s"], c["mib_s"]) and c.get("fresh_p95_us", 0) > 0
            and c.get("fresh_p99_us", 0) >= c["fresh_p95_us"])


def host_units(delta, count):
    return dict(cpu_s_per_gib=delta["cpu_s"] / (count / GIB),
                runnable_s_per_s=delta["runnable_s"] / delta["sample_seconds"],
                wait_s_per_s=delta["wait_s"] / delta["sample_seconds"])


def process_work(before, after, pid, payload_bytes):
    """Darwin host process work over the observer interval, per scored bulk byte."""
    if type(payload_bytes) is not int or payload_bytes <= 0:
        raise ValueError("process work needs a positive bulk byte count")
    delta = process_delta(before, after, pid)
    first, = (t for t in before["tasks"] if t["pid"] == pid)
    last, = (t for t in after["tasks"] if t["pid"] == pid)

    def hardware_delta(key):
        start, end = first.get(key), last.get(key)
        # Some observers omit PMCs or return zero for unsupported counters.
        if type(start) is int and type(end) is int and 0 <= start < end:
            return end - start
        return None

    instructions = hardware_delta("instructions")
    cycles = hardware_delta("cycles")
    return dict(**delta, **host_units(delta, payload_bytes),
                mean_host_cores=delta["cpu_s"] / delta["sample_seconds"],
                instructions_per_byte=instructions / payload_bytes if instructions else None,
                cycles_per_byte=cycles / payload_bytes if cycles else None,
                instructions_per_cycle=instructions / cycles if instructions and cycles else None)


def vm_rows(receipt):
    rows = []
    for arm, rounds in receipt["phases"]["grace-holdout"]["runs"].items():
        scope = receipt["scopes"][arm]
        assert scope["image"] == IMAGE
        for number, record in sorted(rounds.items(), key=lambda pair: int(pair[0])):
            c = record["client"]
            ok = clean_client(c)
            assert ok == record["clean"], (number, arm)
            # All bulk streams completed the identity warmup and transferred data.
            # The only subsequent /id calls belong to fresh requests in the pinned client.
            errors = c["errors"] or []
            assert len(c["per_stream_bytes"]) == 32 and min(c["per_stream_bytes"]) > 0
            assert all('/id"' in e for e in errors)
            row = dict(round=int(number), arm=arm, clean=ok, fresh_failed=len(errors), errors=errors, arrivals=c["arrivals"],
                       offered=c["arrivals"], reopened=c["reopened"], mib_s=c["mib_s"], p95_ms=c["fresh_p95_us"] / 1000,
                       p99_ms=c["fresh_p99_us"] / 1000)
            for role in ("vmm", "relay"):
                if role not in scope:
                    continue
                delta = process_delta(record["before"], record["after"], int(scope[role]))
                units = host_units(delta, c["bytes"])
                row[role] = {**delta, **units}
                if role == "vmm":
                    row.update(units)
            rows.append(row)
    return rows


def arm_summary(rows):
    clean = [r for r in rows if r["clean"]]
    metrics = ("mib_s", "p95_ms", "p99_ms", "cpu_s_per_gib", "runnable_s_per_s", "wait_s_per_s")
    stats = {k: median(r[k] for r in clean) if clean and all(r.get(k) is not None for r in clean) else None
             for k in metrics}
    return {**stats, "clean": len(clean), "attempts": len(rows),
            "planned_fresh": sum(r["offered"] for r in rows), "verified_fresh_in_clean": sum(r["arrivals"] for r in clean),
            "known_failed_requests": sum(r["fresh_failed"] or 0 for r in rows),
            "rounds_missing_request_count": [r["round"] for r in rows if r["fresh_failed"] is None]}


def paired_median_interval(ratios):
    if len(ratios) < 5:
        return None
    rng = random.Random(7317)
    draws = sorted(median(rng.choices(ratios, k=len(ratios))) for _ in range(10000))
    return [draws[250], draws[9749]]


def contrast(rows, left, right, ports=None):
    arms = {key: [r for r in rows if r["arm"] == key and (ports is None or r["ports"] == ports)]
            for key in (left, right)}
    clean = {key: {r["round"]: r for r in values if r["clean"]} for key, values in arms.items()}
    common = sorted(clean[left].keys() & clean[right].keys())
    ratios = [clean[right][n]["mib_s"] / clean[left][n]["mib_s"] for n in common]
    return dict(left=left, right=right, ports=ports, arms={k: arm_summary(v) for k, v in arms.items()},
                paired_rounds=common, paired_ratios=ratios, median_ratio=median(ratios),
                bootstrap_ci95=paired_median_interval(ratios), wins=sum(r > 1 for r in ratios))


def replay():
    rh = "82ceb6976075b8054e61524777d2da8302f19cce2552a1c07515668686c6c969"
    vh = "066cd4071f3f926a228d87310f6d7b6f361c38f07c7a8240aa09a57f03f201e4"
    relay, vm = read_receipt(RELAY, rh), read_receipt(VM, vh)
    main = relay_rows(relay["independent_client_confirmation"]["rounds"], 240)
    screen = relay_rows(relay["selection_screens"]["handoff_screen"]["rounds"], 80)
    budget = relay_rows(relay["selection_screens"]["four_worker_callback_screen"]["rounds"], 80)
    end_to_end = vm_rows(vm)
    factors = {}
    for ports in (1, 32):
        factors[f"distribution_{ports}"] = contrast(main, "baseline2", "candidate2", ports)
        factors[f"workers_{ports}"] = contrast(screen, "balanced2", "balanced4", ports)
        factors[f"workers_and_callback_{ports}"] = contrast(main, "baseline2", "candidate4", ports)
    factors["callback_1"] = contrast(budget, "candidate", "short", 1)
    factors["vm_peer_4"] = contrast(end_to_end, "confirm-orb", "confirm-micropod")
    factors["vcpu_4_vs_6"] = None
    traces = {}
    for key, block in vm["scheduling"]["grace-trace"].items():
        arm = key.split("-", 1)[1]
        valid = clean_client(block["work"])
        traces.setdefault(arm, []).append(dict(capture=key, clean=valid,
            vcpu_wait_s_per_s=block["summary"]["threads"]["vcpu"]["estimated_wait_s_per_s"]))
    return dict(host=relay["independent_client_confirmation"]["protocol"]["host"],
                source_sha256={RELAY.name: rh, VM.name: vh}, image_config_sha256=IMAGE,
                relay_confirmation=main, fixed_128_event_screen=screen, callback_screen=budget,
                vm_holdout=end_to_end, separate_vcpu_traces=traces, contrasts=factors)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.write_text(json.dumps(replay(), indent=2, allow_nan=False) + "\n")
