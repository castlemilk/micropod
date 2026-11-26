#!/usr/bin/env python3
"""procwatch.py WATCHFILE OUT [INTERVAL_MS]: a process-spawn census.

Polls, every INTERVAL_MS (default 1), the children (and their children, three
levels down) of every process named in WATCHFILE, through libproc's
proc_listchildpids: no DTrace, no root. WATCHFILE holds one "label pid" per
line and is re-read every 50 ms, so the gate can add the MicropodMCP
processes it starts. Every process first seen under a watched pid is written
to OUT (JSON lines) with its path and argv as soon as it is seen, and again
when it is gone with how long it was seen; the polling cadence itself (sample
count, mean and worst gap) is written every second and at exit, so a reader
can tell how short a child could have been and still be missed.

A child shorter than one polling gap can be missed: the gate calibrates the
census against a process it spawns children from (known count, 20 ms each)
and refuses to call a zero count a pass unless that calibration saw them all.
"""

import ctypes
import ctypes.util
import json
import signal
import struct
import sys
import time

libproc = ctypes.CDLL(ctypes.util.find_library("proc") or "/usr/lib/libproc.dylib", use_errno=True)
libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
libproc.proc_listchildpids.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
libproc.proc_listchildpids.restype = ctypes.c_int
libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
libproc.proc_pidpath.restype = ctypes.c_int
libc.sysctl.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_uint, ctypes.c_void_p,
                        ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
CTL_KERN, KERN_PROCARGS2 = 1, 49
BUF = (ctypes.c_int * 4096)()
PATHBUF = ctypes.create_string_buffer(4096)


def children(pid):
    """The pids of pid's children (proc_listchildpids returns their count)."""
    n = libproc.proc_listchildpids(pid, BUF, ctypes.sizeof(BUF))
    return [p for p in BUF[: min(n, 4096)] if p > 0] if n > 0 else []


def path(pid):
    n = libproc.proc_pidpath(pid, PATHBUF, 4096)
    return PATHBUF.value.decode(errors="replace") if n > 0 else None


def argv(pid):
    mib = (ctypes.c_int * 3)(CTL_KERN, KERN_PROCARGS2, pid)
    size = ctypes.c_size_t(0)
    if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0 or size.value == 0:
        return None
    buf = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0:
        return None
    raw = buf.raw[: size.value]
    argc = struct.unpack_from("i", raw, 0)[0]
    rest = raw[4:]
    end = rest.find(b"\0")
    rest = rest[end:].lstrip(b"\0")
    parts = rest.split(b"\0")
    return [p.decode(errors="replace") for p in parts[:argc]]


def read_watch(path_):
    out = {}
    try:
        with open(path_) as f:
            for line in f:
                parts = line.split()
                if len(parts) == 2 and parts[1].isdigit():
                    out[int(parts[1])] = parts[0]
    except OSError:
        pass
    return out


def main():
    watchfile, outpath = sys.argv[1], sys.argv[2]
    interval = float(sys.argv[3]) / 1000 if len(sys.argv) > 3 else 0.001
    out = open(outpath, "a", buffering=1)
    stop = {"now": False}

    def halt(*_):
        stop["now"] = True

    signal.signal(signal.SIGTERM, halt)
    signal.signal(signal.SIGINT, halt)
    watched = read_watch(watchfile)
    seen = {}  # pid -> record
    samples, gaps, last, max_gap, gap_sum = 0, 0, None, 0.0, 0.0
    reread = time.monotonic()
    beat = time.monotonic()
    out.write(json.dumps({"event": "start", "t": time.time(), "intervalMs": interval * 1000,
                          "watched": {str(k): v for k, v in watched.items()}}) + "\n")
    while not stop["now"]:
        now = time.monotonic()
        if last is not None:
            g = now - last
            gap_sum += g
            gaps += 1
            max_gap = max(max_gap, g)
        last = now
        if now - reread > 0.05:
            new = read_watch(watchfile)
            if new != watched:
                out.write(json.dumps({"event": "watch", "t": time.time(),
                                      "watched": {str(k): v for k, v in new.items()}}) + "\n")
            watched = new
            reread = now
        present = set()
        for wpid, label in list(watched.items()):
            frontier = [(wpid, 0)]
            while frontier:
                parent, depth = frontier.pop()
                for c in children(parent):
                    present.add(c)
                    if c not in seen:
                        rec = {"event": "child", "t": time.time(), "watched": label, "watchedPid": wpid,
                               "pid": c, "ppid": parent, "depth": depth + 1, "path": path(c), "argv": argv(c)}
                        seen[c] = {"first": now, "rec": rec, "polls": 0}
                        out.write(json.dumps(rec) + "\n")
                    elif seen[c]["polls"] < 50:
                        # Seen between fork and exec, a child still shows
                        # its parent's image: follow it until it execs.
                        seen[c]["polls"] += 1
                        p = path(c)
                        if p and p != seen[c]["rec"]["path"]:
                            seen[c]["rec"].update(path=p, argv=argv(c))
                            out.write(json.dumps({"event": "exec", "t": time.time(), "pid": c,
                                                  "watched": label, "path": p,
                                                  "argv": seen[c]["rec"]["argv"]}) + "\n")
                    if depth < 2:
                        frontier.append((c, depth + 1))
        for pid in [p for p in seen if p not in present and not seen[p].get("gone")]:
            seen[pid]["gone"] = True
            r = seen[pid]["rec"]
            out.write(json.dumps({"event": "gone", "t": time.time(), "pid": pid, "watched": r["watched"],
                                  "seenMs": round((now - seen[pid]["first"]) * 1000, 2)}) + "\n")
        samples += 1
        if now - beat > 1.0:
            out.write(json.dumps({"event": "beat", "t": time.time(), "samples": samples,
                                  "meanGapMs": round(gap_sum / gaps * 1000, 3) if gaps else None,
                                  "maxGapMs": round(max_gap * 1000, 3)}) + "\n")
            beat = now
        time.sleep(interval)
    out.write(json.dumps({"event": "stop", "t": time.time(), "samples": samples,
                          "meanGapMs": round(gap_sum / gaps * 1000, 3) if gaps else None,
                          "maxGapMs": round(max_gap * 1000, 3), "children": len(seen)}) + "\n")
    out.close()


if __name__ == "__main__":
    main()
