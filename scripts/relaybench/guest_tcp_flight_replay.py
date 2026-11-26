"""Replay effective service TCP controls in two independent archived VM crossovers."""
import argparse
import hashlib
import json
from pathlib import Path
from statistics import median

from gamma_contrasts import GIB, IMAGE, ROOT, clean_client, paired_median_interval, process_delta, read_receipt, stream_rates

ARCHIVES = ROOT / "docs/benchmarks/2026-11-21"
CASES = {
    "cubic": ("gamma-vm-scheduling.json.gz", "29f33979ca570117e54addabfe07aecb452ab23af7f0b9e039c996dbb9611e51"),
    "flight": ("gamma-vnic.json.gz", "2d20e203cc135a4a86828b8b365fc7885b225b9b452c276ad1f761fd97556b8f"),
}


def require(test, message):
    if not test:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def service_limits(state):
    keys = ["cpu.max", "cpuset.cpus.effective", "memory.max", "pids.max"]
    require([state[k] for k in keys] == ["400000 100000", "0-3", "1073741824", "512"], "service budget changed")


def changes(rows, keys):
    summary = {}
    for key in keys:
        a = [row["control"][key] for row in rows]
        b = [row["candidate"][key] for row in rows]
        require(min(a) > 0, f"zero denominator for {key}")
        pct = [100 * (y / x - 1) for x, y in zip(a, b)]
        summary[key] = dict(control_median=median(a), candidate_median=median(b), candidate_higher=sum(p > 0 for p in pct),
                            paired_median_pct=median(pct), paired_bootstrap_ci95_pct=paired_median_interval(pct))
    return summary


def cubic(source):
    scope = source["scopes"]["lab-20"]
    require(scope["vm"].startswith('4 ') and "7.3.5-micropod-cc" in scope["vm"] and
            scope["boot-policy"].splitlines()[:2] == ["2", "20000"] and scope["image"] == IMAGE, "scope mismatch")
    proofs = scope["controller_proofs"]
    routes = []
    for cc in ("reno", "cubic"):
        proof = proofs[cc]
        service_limits(proof["state"])
        route = proof["route"]
        require(proof["accepted_socket"] == cc == route["Congctl"] and route["Dst"]["Mask"] == "/////w==",
                "missing accepted-socket and host-route proof")
        routes.append({k: v for k, v in route.items() if k not in ("Src", "Congctl")})
    require(routes[0] == routes[1], "other route difference")
    series = source["records"]["guest-screen"]
    require(set(series) == {str(i) for i in range(1, 9)}, "incomplete first attempts")
    rows, identities = [], None
    for i in range(1, 9):
        block = series[str(i)]
        row = {"block": i, "relative_order": [k for k in block["order"] if k.startswith("lab-20_")]}
        for label, cc in (("control", "reno"), ("candidate", "cubic")):
            r = block["engines"]["lab-20_" + cc]
            c = r["client"]
            require(c["arrivals"] == 240 and c["period_us"] == 25000 and c["streams"] == 32
                    and clean_client(c) == r["valid"], "invalid offering or clean status")
            stream_rates(c, c["window_s"], c["mib_s"])
            before, after = r["before"], r["after"]
            tasks = [(t["pid"], t["birth_ticks"]) for t in before["tasks"]]
            require(len(tasks) == 2 and (identities is None or tasks == identities), "VM or relay process changed")
            identities = tasks
            data = dict(clean=r["valid"], mib_s=c["mib_s"], bytes=c["bytes"], p95_ms=c["fresh_p95_us"]/1000,
                        p99_ms=c["fresh_p99_us"]/1000, arrivals=c["arrivals"], reopens=c["reopened"],
                        fresh_errors=len(c["errors"] or []))
            require(all('/id"' in err for err in c["errors"] or []), "unexpected bulk error")
            gib = c["bytes"] / GIB
            for (pid, _), role in zip(tasks, ("vmm", "relay")):
                d = process_delta(before, after, pid)
                data[role+"_cpu_s_per_scored_gib"] = d["cpu_s"] / gib
                data[role+"_runnable_s_per_s"] = d["runnable_s"] / d["sample_seconds"]
                data[role+"_wait_s_per_s"] = d["wait_s"] / d["sample_seconds"]
            for k in ("irq", "NET_RX", "NET_TX"):
                delta = r["irqafter"][k] - r["irqbefore"][k]
                require(delta >= 0, "counter reset")
                data[k+"_per_scored_gib"] = delta / gib
            row[label] = data
        rows.append(row)
    common = [r for r in rows if r["control"]["clean"] and r["candidate"]["clean"]]
    qualifying = [r for r in common if max(r[k]["p95_ms"] for k in ("control", "candidate")) <= 75]
    order_gains = {}
    for first in ("lab-20_reno", "lab-20_cubic"):
        group = [r for r in common if r["relative_order"][0] == first]
        order_gains[first] = dict(blocks=len(group), median_pct=median(
            100 * (r["candidate"]["mib_s"] / r["control"]["mib_s"] - 1) for r in group))
    return dict(direction="231.07", archive_revision="b30c57f8c97d112fb57dfd5588b6e8da9601e583", source_revision="7a4eb51a04b51f6332ed49561b3dd0bb42ffacd9",
                kernel_image_sha256=source["sha256"]["cubic_kernel"], image_sha256=scope["image"],
                client_sha256=source["sha256"]["fixed_go_client"], driver_sha256=sha(source["files"]["screen.py"].encode()),
                fixture="One four-vCPU warm VM. Two otherwise matched services with distinct source addresses. "
                        "Fixed two deferred polls and 20 us GRO flush; change accepted-socket Reno to CUBIC. "
                        "32 warm bulk streams, 240 fixed arrivals six seconds, both using the same port per service.",
                control_route=proofs["reno"]["route"], candidate_route=proofs["cubic"]["route"],
                limits="Eight rotated multi-arm blocks; bootstrap resamples seven jointly clean blocks 10000 times, seed 7317. "
                       "Whole-invocation CPU and guest IRQ/softirq deltas divided by scored payload. "
                       "Counted interrupts and NET_RX/NET_TX entries are not work time. No per-arm interface drop snapshots. "
                       "Distinct services and endpoint ports remain a possible confound. Timing was acquired on the historical guest.",
                verdict="CUBIC is a candidate for independent matched confirmation with 20 us GRO already fixed. "
                        "It gained throughput in 6/7 clean pairs and met the p95 gate 8/8, but increased IRQs per scored GiB. "
                        "This screened condition was selected from a larger sweep and is not a stock or peer result.",
                next_check="Keep Reno on the revised stock baseline. Isolate only the controller on the same qualified "
                           "kernel and polling policy, independently verify accepted sockets, drops and per-process CPU.",
                common_clean_and_75ms=dict(blocks=[r["block"] for r in qualifying],
                    throughput=changes(qualifying, ["mib_s"])["mib_s"]),
                relative_order_on_common_clean=order_gains,
                clean_pairs=len(common), clean_p95_passes={k:sum(r[k]["clean"] and r[k]["p95_ms"] <= 75 for r in rows)
                                                           for k in ("control", "candidate")},
                paired=changes(common, ["mib_s", "p95_ms", "p99_ms", "vmm_cpu_s_per_scored_gib",
                    "relay_cpu_s_per_scored_gib", "irq_per_scored_gib", "NET_RX_per_scored_gib", "NET_TX_per_scored_gib"]),
                rows=rows)


def tcp_fields(text, prefix):
    lines = [s.split()[1:] for s in text.splitlines() if s.startswith(prefix + ":")]
    require(len(lines) == 2, "unexpected kernel counter format")
    return dict(zip(lines[0], map(int, lines[1]), strict=True))


def service_counters(raw):
    snmp = tcp_fields(raw["/proc/net/snmp"], "Tcp")
    ext = tcp_fields(raw["/proc/net/netstat"], "TcpExt")
    link, = [s.split(":")[1].split() for s in raw["/proc/net/dev"].splitlines() if s.lstrip().startswith("eth0:")]
    return dict(out_segments=snmp["OutSegs"], retrans_segments=snmp["RetransSegs"], timeouts=ext["TCPTimeouts"],
                loss_probes=ext["TCPLossProbes"], spurious_rtos=ext["TCPSpuriousRTOs"], listen_drops=ext["ListenDrops"],
                tx_bytes=int(link[8]), tx_drops=int(link[11]), rx_drops=int(link[3]))


def flight(source):
    raw = source["raw"]
    service_limits(raw["flight/limits"])
    require("sha256:"+source["image"] == IMAGE, "different service image")
    keys = ("reno20ss128", "flight256")
    stages = ("control", "candidate")
    for name in keys:
        statuses = {key for key in raw if key.startswith("flight/") and key.endswith(f"-{name}.mixed.status")}
        require(statuses == {f"flight/{i}-{name}.mixed.status" for i in range(8)}, "unexpected attempted block count")
    probes = {}
    for arm, name in zip(stages, keys):
        maps = {}
        for line in raw[f"flight/{name}.probe"].splitlines():
            entry = json.loads(line)
            if entry["type"] == "map":
                maps.update(entry["data"])
        require(set(maps["@clamp"]) == ({"256"} if arm == "candidate" else {"4294967295"}), "unexpected socket clamp")
        peak = maps["@peak_cwnd"]
        require((peak == 256 if arm == "candidate" else peak > 256), "ceiling not exercised")
        require(set(maps["@initial_ssthresh"]) == {"2147483647"}, "initial slow-start threshold changed")
        probes[arm] = maps
    rows = []
    for i in range(8):
        order = ["reno20ss128", "flight64", "flight128", "flight256"]
        rotated = [order[(i+j if i < 4 else i-j) % 4] for j in range(4)]
        row = dict(block=i, relative_order=[a for a in rotated if a in keys])
        states = []
        for arm, name in zip(stages, keys):
            p = f"flight/{i}-{name}."
            state = raw[p+"state"]
            require(state in raw[p+"cache"] and "rto_min lock 20ms congctl reno" in state and
                    ("cwnd lock 256" in state) == (arm == "candidate"), "wrong gateway route")
            states.append(state.replace("cwnd lock 256 ", ""))
            b, c = raw[p+"burst"], raw[p+"mixed"]
            require(raw[p+"burst.status"] == raw[p+"mixed.status"] == 0 and
                    c["fresh"]["incomplete_phase_samples"] == c["reopened_connections"] == 0 and
                    c["fresh"]["iterations"] == 160 and c["streams"] == b["parallel_streams"] == 32 and
                    b["parallel_barrier"] and len(b["parallel_bursts_mib_s"]) == 3, "invalid burst/mixed attempts")
            stream_rates(dict(per_stream_bytes=c["overlap_bytes_per_stream"], bytes=c["overlap_bytes"]),
                         c["overlap_s"], c["overlap_mib_s"])
            before, after = [service_counters(raw[p+k]) for k in ("before", "after")]
            delta = {k: after[k] - before[k] for k in before}
            require(min(delta.values()) >= 0 and delta["out_segments"] > 0, "counter reset")
            row[arm] = dict(route=state, counters=delta, retrans_per_1000_out=1000*delta["retrans_segments"]/delta["out_segments"],
                            mib_s=c["overlap_mib_s"], mixed_s=c["overlap_s"], mixed_bytes=c["overlap_bytes"],
                            fresh=c["fresh"]["iterations"], reopens=c["reopened_connections"],
                            p95_ms=c["fresh"]["complete_ns"]["p95"]/1e6, p99_ms=c["fresh"]["complete_ns"]["p99"]/1e6)
        require(states[0] == states[1], "route changed beyond congestion-window ceiling")
        rows.append(row)
    return dict(direction="231.08", archive_revision="4f887ba5d28f47fa37d4bd0a2d89cd0914d74754", source_revision=source["parent_commit"], image_sha256=source["image"],
                client_sha256=source["binaries_sha256"]["netbench-shapes"],
                original_driver_sha256=sha(source["experiment_drivers"]["flight.sh"].encode()),
                socket_probe_sha256=sha(source["experiment_drivers"]["flight.bt"].encode()),
                fixture="One four-CPU service and Reno gateway route with 20 ms retransmission floor. "
                        "Uncapped TCP control versus locked 256-segment congestion-window ceiling. Kernel socket clamp "
                        "proved on a separate pre-timing diagnostic after refreshing destination metrics. 8 rotated blocks, "
                        "three synchronized bursts and 32 established streams overlapping 160 closed-loop fresh requests per arm per block.",
                limits="Intervals use 10000 whole-block bootstrap resamples with seed 7317. TCP counters bracket full burst and mixed invocations. OutSegs and RetransSegs are service-namespace "
                       "segments. Retransmission is not a direct packet-loss measurement; the scored mixed interval is a subset. "
                       "No end-to-end packet drop instrument or host CPU/runnable samples in these arms.",
                verdict="The verified 256-segment cap cut retransmissions per 1000 outgoing segments, but throughput fell "
                        "in all eight pairs. The unconstrained arm already met the historical 75 ms p95 threshold in all eight.",
                next_check="Keep the uncapped throughput control. Test a ceiling separately only when targeting a stricter "
                           "tail/recovery objective with an open-loop workload and explicitly measured delivery.",
                probes=probes, paired=changes(rows, ["mib_s","p95_ms","p99_ms","retrans_per_1000_out"]),
                all_attempt_deltas={arm:{k:sum(r[arm]["counters"][k] for r in rows) for k in rows[0][arm]["counters"]}
                                    for arm in stages},
                passes_75ms={arm:sum(r[arm]["p95_ms"] <= 75 for r in rows) for arm in stages}, rows=rows)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("case", choices=CASES)
    mode = parser.parse_args().case
    name, digest = CASES[mode]
    source = read_receipt(ARCHIVES/name, digest)
    result = (cubic if mode == "cubic" else flight)(source)
    print(json.dumps(dict(date="2026-11-24", tier="Offline replay of raw historical VM measurements",
                          archive=name, archive_sha256=digest, script_sha256=sha(Path(__file__).read_bytes()), **result),
                     indent=2, allow_nan=False))
