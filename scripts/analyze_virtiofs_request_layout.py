#!/usr/bin/env python3
"""Match a traced stock Git request to the scatterlists Linux sent to virtio."""

import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import re


LINE = re.compile(r"^\s*.*?-(\d+)\s+(?:\([^)]*\)\s*)?\[\d+\]\s+\S+\s+"
                  r"(\d+)\.(\d+):\s+(\w+):\s*(.*)$")
SEND = re.compile(r"connection (\d+) req (\d+) opcode (\d+) \((?:FUSE_)?(\w+)\) len (\d+)")
END = re.compile(r"connection (\d+) req (\d+) len (\d+) error (-?\d+)")
ENQUEUE = re.compile(r".* key=(0x[0-9a-f]+) unique=(\d+) op=(\d+)$")
SUBMIT = re.compile(r".* key=(0x[0-9a-f]+) out=(\d+) in=(\d+)$")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def analyze(run, directory, expected, lookup_fallback=False):
    capture = run["capture"]
    sample = run["traced_sample"]
    info = capture["capture"]
    fields = dict(line.split("=", 1) for line in (directory / ".trace-started").read_text().splitlines())
    require(run["passed"] and capture["complete"] and info["clock"] == "mono", "incomplete Git trace")
    require(fields["token"] == info["token"] and fields["workspace_compact_requests"] == expected
            and fields["workspace_async_release"] == "Y" and fields["workspace_inline_completion"] == "N",
            "unexpected transport settings or capture token")
    require(fields["boot_id"] == sample["clock"]["boot_id"] and sample["clock"]["offset_ns"] == 0
            and sample["affinity"] == sample["initial_affinity"], "guest clock or CPU placement changed")
    raw = (directory / ".trace-events").read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    require(digest == capture["raw_files_sha256"][".trace-events"], "raw event checksum differs")
    pid = run["git_fuse"]["kernel_git_pid"]
    connection = str(info["connection"])
    start, finish = sample["clock"]["now_ns"], sample["finish_ns"]
    requests, completed = {}, {}
    key, active = None, None
    for line in raw.decode().splitlines():
        match = LINE.fullmatch(line)
        if not match:
            continue
        task, seconds, fraction, event, body = match.groups()
        body = body.strip()
        stamp = int(seconds) * 1_000_000_000 + int(fraction.ljust(9, "0"))
        if event == "fuse_request_end" and (m := END.fullmatch(body)) and m[1] == connection:
            completed[int(m[2])] = int(m[4])
        if int(task) != pid or not start - 1_000 <= stamp <= finish:
            continue
        if event == "fuse_request_send" and (m := SEND.fullmatch(body)) and m[1] == connection:
            unique = int(m[2])
            require(unique not in requests, "duplicate request ID")
            requests[unique] = {"opcode": int(m[3]), "name": m[4], "segments": []}
        elif event == "mp_sg_enqueue" and (m := ENQUEUE.fullmatch(body)):
            key, active = m[1], requests.get(int(m[2]))
            if active is not None:
                require(active["opcode"] == int(m[3]), "enqueue opcode disagrees with FUSE")
        elif event == "mp_sg_submit" and (m := SUBMIT.fullmatch(body)) and key == m[1] and active is not None:
            active["segments"].append((int(m[2]), int(m[3])))
            active, key = None, None

    counts = defaultdict(Counter)
    retries = Counter()
    unmatched = Counter()
    for unique, row in requests.items():
        name, segments = row["name"], row["segments"]
        if unique not in completed or not segments:
            unmatched[name] += 1
            continue
        if len(segments) > 1:
            retries[name] += len(segments) - 1
        readable, writable = segments[-1]
        counts[name][f"{readable}+{writable}"] += 1

    for name in ("LOOKUP", "OPEN", "READ"):
        observed = counts[name]
        packed = expected == "Y" and not (name == "LOOKUP" and lookup_fallback)
        prefix = 1 if packed else 2
        fixed = f"{prefix}+{prefix}"
        if name == "READ":
            good = sum(n for shape, n in observed.items()
                       if shape.startswith(f"{prefix}+") and int(shape.split("+")[1]) >= 2)
        else:
            good = observed[fixed]
        require(good >= run["source"]["files"], f"insufficient {name} layout evidence: {dict(observed)}")
    return {"mode": expected, "lookup_fallback": lookup_fallback, "raw_sha256": digest,
            "git_pid": pid, "files": run["source"]["files"],
            "connection": connection, "shape_readable_plus_writable": dict(counts),
            "unmatched_sends_or_incomplete_replies": unmatched, "repeat_submissions": retries}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--raw", type=Path, required=True)
    parser.add_argument("--expected", choices=("N", "Y"), required=True)
    parser.add_argument("--lookup-fallback", action="store_true",
                        help="Require the first candidate's ordinary LOOKUP layout in its enabled trace")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    result = analyze(json.loads(args.run.read_bytes()), args.raw, args.expected, args.lookup_fallback)
    with args.out.open("x") as out:
        json.dump(result, out, indent=2)
        out.write("\n")


if __name__ == "__main__":
    main()
