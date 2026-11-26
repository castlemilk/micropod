"""Compare per-vCPU state sampling cadences on the same CPU counters and client window."""
import argparse
from bisect import bisect_left, bisect_right
import gzip
import hashlib
import json
import math
from pathlib import Path
from statistics import median

from gamma_contrasts import ROOT, VM, read_receipt, stream_rates

ARCHIVE_SHA = "066cd4071f3f926a228d87310f6d7b6f361c38f07c7a8240aa09a57f03f201e4"
DATA = ROOT / "docs/benchmarks/2026-11-24/vcpu-cadence-inputs.json.gz"
DATA_SHA = "9b53caaf1b1228903d23be0696cf5e0a764d4e404629d4a6c390fc6dc4a401b0"
SOURCE_REV = "b30c57f8c97d112fb57dfd5588b6e8da9601e583"
ARMS = ("confirm-micropod", "confirm-orb")
BASE = "a3b561c6a97320d4ca9aff60885ae6393ccaa613"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def project(header, samples, client, expected_pid, expected_birth, vcpus):
    """Trim the original sampler format to a padded score window; preserve observations exactly."""
    if header["pid"] != expected_pid or header["levels"] != len(header["level_names"]):
        raise ValueError("wrong VM process or CPU levels")
    if not 1 <= header["levels"] or min(header["tick_numer"], header["tick_denom"]) <= 0:
        raise ValueError("invalid timebase")
    begin, end = client["begin_ns"], client["end_ns"]
    if begin >= end or not math.isclose((end-begin)/1e9, client["window_s"], rel_tol=0, abs_tol=1e-9):
        raise ValueError("client clock disagrees with score duration")
    stream_rates({"bytes": client["bytes"], "per_stream_bytes": client["per_stream_bytes"]},
                 client["window_s"], client["mib_s"])
    epochs = [s["epoch_ns"] for s in samples]
    monotonic = [s["monotonic_ns"] for s in samples]
    if any(a >= b for xs in (epochs, monotonic) for a, b in zip(xs, xs[1:])):
        raise ValueError("sample clocks did not advance")
    if any(s["birth_ticks"] != expected_birth for s in samples):
        raise ValueError("VM process birth changed")
    offsets = [wall - mono for wall, mono in zip(epochs, monotonic)]
    # end_ns anchors the monotonic client duration to the starting wall clock.
    # Pad the two boundaries by the observed wall/monotonic offset range and
    # one microsecond for the archived recorder's wall-clock quantization.
    drift = max(offsets) - min(offsets)
    if drift > 1_000_000:
        raise ValueError("wall/monotonic clocks separated by more than 1 ms")
    pad = drift + 1000
    lo = bisect_left(epochs, begin - pad) - 2
    hi = bisect_right(epochs, end + pad) + 1
    if lo < 0 or hi >= len(samples):
        raise ValueError("score window lacks enclosing sweeps")
    points, ids = [], None
    for s in samples[lo:hi+1]:
        threads = sorted((t for t in s["threads"] if t["group"] == "vcpu"), key=lambda t: t["id"])
        if len(threads) != vcpus or len({t["id"] for t in threads}) != vcpus:
            raise ValueError("missing or duplicate vCPU")
        current = [t["id"] for t in threads]
        if ids is not None and ids != current:
            raise ValueError("vCPU identity changed")
        ids = current
        ticks = [t["level_cpu_ticks"] for t in threads]
        if any(len(c) != header["levels"] or any(type(x) is not int or x < 0 for x in c) for c in ticks):
            raise ValueError("invalid CPU counters")
        if any(t["state"] not in range(1, 6) for t in threads):
            raise ValueError("unknown thread state")
        points.append([s["epoch_ns"], s["monotonic_ns"], [t["state"] for t in threads], ticks])
    return dict(pid=expected_pid, birth_ticks=expected_birth, thread_ids=ids, level_names=header["level_names"],
                tick_numer=header["tick_numer"], tick_denom=header["tick_denom"], clock_padding_ns=pad,
                points=points)


def score(capture, client):
    begin, end = client["begin_ns"], client["end_ns"]
    delta_ns = end - begin
    points = capture["points"]
    wall = [p[0] for p in points]
    mono = [p[1] for p in points]
    if any(a >= b for xs in (wall, mono) for a, b in zip(xs, xs[1:])):
        raise ValueError("sample clocks did not advance")
    pad = capture["clock_padding_ns"]
    # The sampler timestamps each sweep before enumerating threads. The
    # following sweep's start bounds the preceding counter read from above.
    outer_start = bisect_left(wall, begin - pad) - 2
    inner_start = bisect_right(wall, begin + pad)
    inner_end = bisect_left(wall, end - pad) - 2
    outer_end = bisect_right(wall, end + pad)
    if not 0 <= outer_start < inner_start < inner_end < outer_end < len(points):
        raise ValueError("score window lacks enclosing sweeps")
    ticks_to_ns = capture["tick_numer"] / capture["tick_denom"]
    # Both cadence arms retain these exact endpoints and CPU deltas.
    full = list(range(inner_start, inner_end+1))
    sparse = {
        "every_sample": full,
        "alternate_even": sorted({inner_start, inner_end, *full[::2]}),
        "alternate_odd": sorted({inner_start, inner_end, *full[1::2]}),
    }
    rows = []
    for j, tid in enumerate(capture["thread_ids"]):
        levels = [p[3][j] for p in points]
        if any(a > b for x, y in zip(levels, levels[1:]) for a, b in zip(x, y, strict=True)):
            raise ValueError("per-level CPU counter decreased")
        count = [sum(row) for row in levels]
        inner_cpu_ns = (count[inner_end]-count[inner_start]) * ticks_to_ns
        outer_cpu_ns = (count[outer_end]-count[outer_start]) * ticks_to_ns
        if inner_cpu_ns > delta_ns or outer_cpu_ns < inner_cpu_ns:
            raise ValueError("impossible CPU residence for one thread")
        scores = {}
        duration = mono[inner_end] - mono[inner_start]
        for arm, indices in sparse.items():
            gaps = [mono[b] - mono[a] for a, b in zip(indices, indices[1:])]
            eligible = sum(gap * ((points[a][2][j] == 1) + (points[b][2][j] == 1)) / 2
                           for a, b, gap in zip(indices, indices[1:], gaps))
            scores[arm] = dict(intervals=len(gaps), max_gap_ms=max(gaps)/1e6,
                               running_cpu_fraction=inner_cpu_ns/duration,
                               estimated_runnable_wait_fraction=(eligible-inner_cpu_ns)/duration,
                               estimated_nonrunnable_fraction=(duration-eligible)/duration)
        rows.append(dict(tid=tid, score_running_cpu_s_bounds=[inner_cpu_ns/1e9,
                                                               min(float(delta_ns), outer_cpu_ns)/1e9],
                         sample_estimates=scores))
    return dict(score_s=delta_ns/1e9, interior_s=(mono[inner_end]-mono[inner_start])/1e9,
                edge_padding_ns=pad, pid=capture["pid"], birth_ticks=capture["birth_ticks"], rows=rows)


def producer(raw_dir):
    source = read_receipt(VM, ARCHIVE_SHA)
    fixture = {}
    for arm in ARMS:
        for n in range(1, 5):
            key = f"{n}-{arm}"
            record = source["scheduling"]["grace-trace"][key]
            path = raw_dir / (key+".ndjson")
            client_bytes = path.with_suffix(".json").read_bytes()
            if json.loads(client_bytes) != record["work"]:
                raise ValueError("client differs from research archive")
            raw = path.read_bytes()
            header, *samples = [json.loads(s) for s in raw.splitlines()]
            projected = project(header, samples, record["work"], int(source["scopes"][arm]["vmm"]),
                                samples[0]["birth_ticks"], 4)
            times_and_states = [[p[0] - record["work"]["begin_ns"], *p[2]] for p in projected["points"]
                                if record["work"]["begin_ns"] <= p[0] <= record["work"]["end_ns"]]
            if (projected["thread_ids"] != record["thread_ids"] or times_and_states !=
                    [[sample[0], *[t[-1] for t in sample[1:]]] for sample in record["samples"]]):
                raise ValueError("state or identity differs from compressed historical record")
            fixture[key] = dict(raw_sha256=digest(raw), client_sha256=digest(client_bytes), capture=projected)
    return gzip.compress(json.dumps(fixture, sort_keys=True, separators=(",", ":")).encode(), mtime=0)


def replay():
    archive = read_receipt(VM, ARCHIVE_SHA)
    raw = DATA.read_bytes()
    if digest(raw) != DATA_SHA or not SOURCE_REV.startswith(archive["baseline_commit"]):
        raise ValueError("unrecognized source or input revision")
    fixtures = json.loads(gzip.decompress(raw))
    expected = {f"{i}-{a}" for a in ARMS for i in range(1,5)}
    if set(fixtures) != expected:
        raise ValueError("missing a first attempt")
    rows = {}
    for key in sorted(expected):
        c = archive["scheduling"]["grace-trace"][key]["work"]
        if c["streams"] != 32 or c["arrivals"] != 240 or c["period_us"] != 25_000:
            raise ValueError("wrong workload")
        scores = score(fixtures[key]["capture"], c)
        rows[key] = dict(**scores, mib_s=c["mib_s"], bytes=c["bytes"], fresh_p95_ms=c["fresh_p95_us"]/1000,
                         fresh_p99_ms=c["fresh_p99_us"]/1000, fresh_errors=len(c["errors"] or []),
                         bulk_reopens=c["reopened"], original_trace_sha256=fixtures[key]["raw_sha256"],
                         original_client_sha256=fixtures[key]["client_sha256"])
    results = {}
    for arm in ARMS:
        records = [r for key, r in rows.items() if key.endswith(arm)]
        deltas = []
        flipped = 0
        for record in records:
            for row in record["rows"]:
                estimates = row["sample_estimates"]
                def wait_minus_block(e):
                    return e["estimated_runnable_wait_fraction"]-e["estimated_nonrunnable_fraction"]
                baseline = estimates["every_sample"]
                thinned = [estimates[name] for name in ("alternate_even", "alternate_odd")]
                deltas.append(100*max(abs(e["estimated_runnable_wait_fraction"]-
                                          baseline["estimated_runnable_wait_fraction"]) for e in thinned))
                flipped += any(wait_minus_block(e)*wait_minus_block(baseline) < 0 for e in thinned)
        results[arm] = dict(attempts=len(records), clean=sum(not(r["fresh_errors"] or r["bulk_reopens"]) for r in records),
                            vcpu_windows=len(deltas), dominance_flips=flipped,
                            median_largest_phase_change_pp=median(deltas), maximum_phase_change_pp=max(deltas),
                            score_cpu_bounds_width_ms_range=[
                                f(1000*(r["score_running_cpu_s_bounds"][1]-r["score_running_cpu_s_bounds"][0])
                                  for sample in records for r in sample["rows"]) for f in (min,max)])
    differences = {}
    for i in range(1, 5):
        arms = [rows[f"{i}-{name}"] for name in ARMS]
        eligible = not any(arm["fresh_errors"] or arm["bulk_reopens"] for arm in arms)
        shares = [[sum(row["sample_estimates"][which]["estimated_nonrunnable_fraction"]
                       for row in arm["rows"]) for which in ("every_sample", "alternate_even", "alternate_odd")]
                  for arm in arms]
        differences[str(i)] = dict(common_clean=eligible, full_cadence_difference=shares[0][0]-shares[1][0],
                                   min_across_cadences=min(shares[0])-max(shares[1]),
                                   max_across_cadences=max(shares[0])-min(shares[1]))
    return dict(direction="228.02", replay_base=BASE, analyzer_sha256=digest(Path(__file__).read_bytes()),
                historical_source=SOURCE_REV, original_archive_sha256=ARCHIVE_SHA,
                compressed_inputs_sha256=digest(raw), profiler_source_sha256=digest(archive["sources"]["profile_vm_scheduler.c"].encode()),
                client_sha256=archive["binaries"]["profile_client"], study="grace-trace, four alternating diagnostic pairs, separate from grace-holdout",
                control="Every original Mach thread-state observation and per-level CPU counters, per vCPU, inside the score window.",
                change="Retain every other state observation, testing both starting offsets. Fix endpoints, thread IDs and CPU totals.",
                units="CPU bounds are seconds per individual vCPU over the whole client window. State shares are fractions of the "
                      "slightly shorter common interior interval. Percentage-point changes are absolute, per-vCPU changes in estimated wait.",
                limits="Mach state 1 includes executing and runnable. Only running time is obtained from cumulative per-level counters. "
                       "Runnable waiting and nonrunnable time are trapezoidal state estimates. Offsets between sampled wall and monotonic "
                       "clocks are checked and padded. Hidden within-gap transitions, or clock jumps that reverse between samples, cannot "
                       "be excluded. A nonrunnable state need not indicate network I/O. These diagnostic runs are not a peer holdout. "
                       "No statistical interval is inferred from deterministic replay and two sampling phases.",
                verdict="Thinning changes individual dominant off-CPU state in both engines. In all three jointly clean "
                        "diagnostic pairs the four Micropod vCPUs had higher aggregate estimated nonrunnable time, "
                        "including both thinning phases. Attribute exact stalls only with scheduler transitions plus a "
                        "score-bound guest and relay trace. State alone does not identify a blocked resource.",
                nonrunnable_micropod_minus_orbstack_thread_s_per_s=differences,
                summary=results, attempts=rows)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-originals", type=Path, help="compare existing original trace/client bytes with saved inputs")
    parser.add_argument("--trace", type=Path, help="opt-in analysis of one profile_vm_scheduler NDJSON file")
    parser.add_argument("--client", type=Path)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--birth", type=int)
    parser.add_argument("--vcpus", type=int)
    args = parser.parse_args()
    if any(x is not None for x in (args.trace,args.client,args.pid,args.birth,args.vcpus)):
        if not all((args.trace,args.client,args.pid,args.birth,args.vcpus)) or args.verify_originals:
            parser.error("supply one trace, its scored client, expected PID, birth ticks and vCPU count")
        client = json.loads(args.client.read_bytes())
        with args.trace.open() as f:
            result = score(project(json.loads(next(f)), [json.loads(line) for line in f], client,
                                   args.pid, args.birth, args.vcpus), client)
    else:
        if args.verify_originals and gzip.decompress(producer(args.verify_originals)) != gzip.decompress(DATA.read_bytes()):
            raise ValueError("private inputs differ from the retained raw traces")
        result = replay()
    print(json.dumps(result, indent=2, allow_nan=False))
