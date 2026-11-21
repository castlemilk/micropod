#!/usr/bin/env python3
"""Summarize the chosen intervals in a macOS profile_vm_scheduler NDJSON trace."""

import argparse
from collections import Counter, defaultdict
import json
import sys


def summarize(stream, begin_ns=None, end_ns=None):
    header = json.loads(next(stream))
    if header["tick_numer"] <= 0 or header["tick_denom"] <= 0 or header["levels"] != len(header["level_names"]):
        raise ValueError("invalid CPU levels or Mach timebase")
    seconds_per_tick = header["tick_numer"] / header["tick_denom"] / 1e9
    groups = defaultdict(Counter)
    process = Counter()
    previous = None
    intervals = skipped = 0
    seconds = 0.0
    for line in stream:
        current = json.loads(line)
        before, previous = previous, current
        if before is None:
            continue
        if current["birth_ticks"] != before["birth_ticks"]:
            raise ValueError("VM process changed during the recording")
        if begin_ns is not None and before["epoch_ns"] < begin_ns:
            continue
        if end_ns is not None and current["epoch_ns"] > end_ns:
            continue
        elapsed = (current["monotonic_ns"] - before["monotonic_ns"]) / 1e9
        if elapsed <= 0:
            raise ValueError("non-increasing sample clock")
        intervals += 1
        seconds += elapsed
        skipped += current["skipped_threads"]
        if intervals == 1:
            skipped += before["skipped_threads"]
        for k in ("cpu", "runnable", "legacy", "background", "utility", "default", "initiated", "interactive"):
            field = k + "_ticks"
            process[k] += (current[field] - before[field]) * seconds_per_tick
        old_threads = {t["id"]: t for t in before["threads"]}
        for new in current["threads"]:
            old = old_threads.get(new["id"])
            if old is None or old["group"] != new["group"]:
                continue
            group = groups[new["group"]]
            # TH_STATE_RUNNING includes running and runnable threads. Integrating
            # sampled state estimates eligibility; CPU residence uses kernel counters.
            group["eligible"] += elapsed * ((old["state"] == 1) + (new["state"] == 1)) / 2
            first_levels, last_levels = old["level_cpu_ticks"], new["level_cpu_ticks"]
            if len(first_levels) != header["levels"] or len(last_levels) != header["levels"]:
                raise ValueError("CPU-level count changed during capture")
            for level, (first, last) in enumerate(zip(first_levels, last_levels)):
                group[level] += (last - first) * seconds_per_tick
    if intervals == 0:
        raise ValueError("no complete sample interval in the requested window")
    result = {}
    measured_cpu = 0.0
    for name, group in groups.items():
        level_seconds = [group[level] for level in range(header["levels"])]
        cpu = sum(level_seconds)
        measured_cpu += cpu
        result[name] = {
            "cpu_s_per_s": cpu / seconds,
            "estimated_wait_s_per_s": (group["eligible"] - cpu) / seconds,
            "cpu_fraction_by_level": [s / cpu if cpu else None for s in level_seconds],
        }
    qos = {k: v / process["cpu"] if process["cpu"] else None for k, v in process.items() if k not in ("cpu", "runnable")}
    return {
        "pid": header["pid"],
        "level_names": header["level_names"],
        "intervals": intervals,
        "seconds": seconds,
        "cpu_s_per_s": process["cpu"] / seconds,
        "runnable_wait_s_per_s": (process["runnable"] - process["cpu"]) / seconds,
        "qos_cpu_fractions": qos,
        "matched_thread_cpu_fraction": measured_cpu / process["cpu"] if process["cpu"] else None,
        "skipped_thread_observations": skipped,
        "threads": result,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", nargs="?", type=argparse.FileType("r"), default=sys.stdin)
    parser.add_argument("--begin-ns", type=int, help="inclusive workload start as Unix epoch nanoseconds")
    parser.add_argument("--end-ns", type=int, help="inclusive workload end as Unix epoch nanoseconds")
    args = parser.parse_args()
    if args.begin_ns is not None and args.end_ns is not None and args.begin_ns >= args.end_ns:
        parser.error("the workload must end after it begins")
    try:
        result = summarize(args.trace, args.begin_ns, args.end_ns)
    except (KeyError, ValueError, StopIteration) as error:
        parser.exit(1, f"Could not summarize this VM trace: {error}\n")
    json.dump(result, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
