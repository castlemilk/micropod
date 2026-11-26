"""Correlate each verified HTTP response with socket syscalls and runnable waits in the private Linux guest."""
import argparse
import gzip
import json
import re
from bisect import bisect_right
from collections import Counter, defaultdict
from pathlib import Path

from qualify import require
from sibling_results import read, verified
from sibling_trace import check_stats

LINE = re.compile(r"^\s*.*?-(\d+)\s+(?:\([^)]*\)\s+)?\[\d+\]\s+\S+\s+(\d+)\.(\d+):\s+(.*)$")
ENTER = re.compile(r"^(?:sys_)?(readv?|writev?)\(.*?\bfd:\s*(0x[0-9a-f]+|\d+)[,)]")
EXIT = re.compile(r"^(?:sys_)?(readv?|writev?) -> (0x[0-9a-f]+)")
SWITCH = re.compile(r"\bprev_comm=(.*?) prev_pid=(\d+).*?\bprev_state=(\S+).*?\bnext_comm=(.*?) next_pid=(\d+)")
WAKE = re.compile(r"\bcomm=(.*?) pid=(\d+)\b")


def decode(folder, tag, pairs):
    names = {}
    for p in pairs:
        for role, prefix in (("client", "mcli"), ("server", "msvc")):
            a = p[role]
            require(a.get("comm") == f"{prefix}{p['index']:02}" and a["comm"] not in names and
                    a["pid"] in a["tids"] and a["fd"] >= 0, "missing trace actor")
            names[a["comm"]] = (p["index"], role, a["fd"])
    owners = {}
    path = folder / (tag + ".ftrace.gz")
    # sched_switch and sched_wakeup expose task names and global guest IDs in the same event.
    with gzip.open(path, "rt") as trace:
        for line in trace:
            if "sched_switch:" in line and (s := SWITCH.search(line)):
                found = ((s[1], s[2]), (s[4], s[5]))
            elif "sched_wakeup:" in line and (w := WAKE.search(line)):
                found = ((w[1], w[2]),)
            else:
                continue
            for comm, tid in found:
                if comm in names:
                    require(owners.setdefault(int(tid), names[comm]) == names[comm], "global trace thread reused")
    require(set(owners.values()) == set(names.values()), "traced roles missing from guest scheduler")
    stats = read(folder, tag + "-trace-stats.json")
    entries = check_stats(stats)
    io = defaultdict(list)
    waits = defaultdict(list)
    pending, runnable = {}, {}
    events = Counter()
    with gzip.open(path, "rt") as trace:
        for line in trace:
            if line.startswith("#") or not line.strip():
                continue
            m = LINE.match(line)
            require(m is not None, "unrecognized trace record: " + line[:180])
            pid, sec, sub, body = m.groups()
            tid = int(pid)
            ns = int(sec) * 10**9 + int(sub.ljust(9, "0"))
            if body.startswith("sched_wakeup:"):
                who = int(WAKE.search(body)[2])
                require(who in owners, "scheduler wake filter differs")
                runnable.setdefault(who, ns)
                events["wake"] += 1
            elif body.startswith("sched_switch:"):
                s = SWITCH.search(body)
                require(s is not None, "invalid switch record")
                prev, state, nxt = int(s[2]), s[3], int(s[5])
                require(prev in owners or nxt in owners, "scheduler switch filter differs")
                if nxt in runnable:
                    start = runnable.pop(nxt)
                    require(start <= ns, "guest trace clock reversed")
                    waits[nxt].append((start, ns))
                if prev in owners and state.startswith("R"):
                    runnable.setdefault(prev, ns)
                events["switch"] += 1
            elif m := ENTER.match(body):
                op, fd = m[1], int(m[2], 0)
                require(tid in owners and owners[tid][2] == fd and tid not in pending, "socket syscall filter differs")
                pending[tid] = (op, ns)
                events["enter"] += 1
            elif m := EXIT.match(body):
                require(tid in owners, "syscall exit filter differs")
                events["exit"] += 1
                if tid in pending:
                    op, start = pending.pop(tid)
                    require(op == m[1] and start <= ns, "syscall boundary differs")
                    n = int(m[2], 16)
                    if 0 < n < 2**63:
                        index, role, _ = owners[tid]
                        io[index, role, op.removesuffix("v")].append((start, ns, tid, n))
            else:
                raise ValueError("unrecognized enabled kernel event: " + body[:150])
    require(sum(events.values()) == entries and all(events[k] for k in ("wake", "switch", "enter", "exit")),
            f"trace count differs: {events}, expected {entries}")
    tids = defaultdict(list)
    for tid, (index, role, _) in owners.items():
        tids[index, role].append(tid)
    return io, waits, tids


def boundaries(calls, count, message_bytes, first):
    ends, total = [], 0
    for entered, exited, tid, n in calls:
        total += n
        ends.append(total)
    require(total == count * message_bytes and message_bytes > 0, "socket byte streams differ")
    return [calls[bisect_right(ends, i * message_bytes + (0 if first else message_bytes - 1))] for i in range(count)]


def wait_index(intervals):
    merged = []
    for start, end in sorted(intervals):
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(end, merged[-1][1]))
        else:
            merged.append((start, end))
    return [v[1] for v in merged], merged


def overlap(index, start, end):
    ends, intervals = index
    i = bisect_right(ends, start)
    total = 0
    while i < len(ends) and intervals[i][0] < end:
        a, b = intervals[i]
        total += min(end, b) - max(start, a)
        i += 1
    return total


def split_pair(p, io, waits, tids, rows, cut_us):
    i = p["index"]
    row = rows[i]["receipt"]
    require(row["window"]["local"] == p["client"]["local"] == p["server"]["remote"] and
            row["window"]["remote"] == p["server"]["local"] == p["client"]["remote"], "trace socket differs from HTTP")
    count = len(row["samples"])
    edges = {}
    width = {}
    for sender, receiver in (("client", "server"), ("server", "client")):
        writes, reads = io[i, sender, "write"], io[i, receiver, "read"]
        total = sum(v[3] for v in writes)
        require(total and total % count == 0, f"partial {sender} stream for pair {i}, {total} bytes over {count} HTTP calls")
        width[sender] = total // count
        edges[sender, "write"] = boundaries(writes, count, width[sender], True)
        edges[receiver, "read"] = boundaries(reads, count, width[sender], receiver == "client")
    by_tid = {t: wait_index(waits[t]) for r in ("client", "server") for t in tids[i, r]}
    any_thread = {r: wait_index(x for t in tids[i, r] for x in waits[t]) for r in ("client", "server")}
    buckets = {"all": Counter(), "tail": Counter()}
    for k, sample in enumerate(row["samples"]):
        cw = edges["client", "write"][k][0]
        sr = edges["server", "read"][k]
        sw = edges["server", "write"][k][0]
        cr = edges["client", "read"][k]
        total = sample["total_ns"]
        require(cw <= sr[1] <= sw <= cr[1] and cr[1] - cw <= total + 1500,
                f"syscall chain outside application window for pair {i}, request {k}")
        parts = {"calls": 1, "total_ns": total, "request_delivery_ns": sr[1] - cw, "server_ns": sw - sr[1],
                 "reply_delivery_ns": cr[1] - sw, "outside_syscalls_ns": total - (cr[1] - cw),
                 "server_reader_wait_ns": overlap(by_tid[sr[2]], cw, sr[1]),
                 "client_reader_wait_ns": overlap(by_tid[cr[2]], sw, cr[1]),
                 "server_any_wait_ns": overlap(any_thread["server"], cw, sr[1]),
                 "client_any_wait_ns": overlap(any_thread["client"], sw, cr[1])}
        buckets["all"].update(parts)
        if total >= round(cut_us * 1000):
            buckets["tail"].update(parts)
    return {"index": i, "wire_bytes": width, **buckets}


def phases(folder, tag, rows, cutoff):
    block = int(tag.split("-")[1])
    pairs = read(folder, tag + "-actors.json")
    require([p["index"] for p in pairs] == [block % 8, 8 + (block + 1) % 8], "unplanned trace selection")
    io, waits, tids = decode(folder, tag, pairs)
    return {role: split_pair(p, io, waits, tids, rows, cutoff)
            for role, p in zip(("building", "http_only"), pairs)}


def summarize(folders):
    groups = defaultdict(Counter)
    waves = {}
    for f in folders:
        run = verified(f)
        require(run["plan"].get("socket_sched_trace") and run["plan"].get("builders") == 8, "unverified traced CI run")
        for block in range(run["plan"]["rounds"]):
            tag = f"same-{block}-all-A"
            keyed = read(f, tag + "-phases.json")
            for source, result in keyed.items():
                for bucket in ("all", "tail"):
                    groups[source, bucket].update(result[bucket])
            waves[f.name + "/" + tag] = keyed
    require(all(v["calls"] > 0 for v in groups.values()), "no traced requests in a pooled cohort")
    return {"runs": [f.name for f in folders], "waves": waves,
            "groups": {f"{role}-{bucket}": {"calls": v["calls"], "mean_us": v["total_ns"] / v["calls"] / 1000,
                       "fraction_of_elapsed": {k.removesuffix("_ns"): x / v["total_ns"] for k, x in v.items()
                                               if k.endswith("_ns") and k != "total_ns"}}
                       for (role, bucket), v in groups.items()}}


if __name__ == "__main__":
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("folders", nargs="+", type=Path)
    print(json.dumps(summarize(args.parse_args().folders), indent=2))
