"""Sample the worker's own runc commands and observe their exits using Linux pidfds."""

import json
import os
import re
import select
import sys
import time
from pathlib import Path


def main():
    tick = 10**9 // os.sysconf("SC_CLK_TCK")
    offset = time.time_ns() - time.clock_gettime_ns(time.CLOCK_BOOTTIME)
    polls, calls, active, seen = [], [], {}, set()
    with select.epoll() as poll:
        poll.register(sys.stdin.fileno(), select.EPOLLIN | select.EPOLLHUP)
        print('{"ready":true}', flush=True)
        previous = time.monotonic_ns()
        try:
            while True:
                for fd, _ in poll.poll(0.004):
                    if fd == sys.stdin.fileno():
                        print(
                            json.dumps(
                                {
                                    "calls": calls,
                                    "tick_ns": tick,
                                    "poll_intervals_ns": polls,
                                    "clock_error_ns": abs(
                                        time.time_ns() - time.clock_gettime_ns(time.CLOCK_BOOTTIME) - offset
                                    ),
                                }
                            ),
                            flush=True,
                        )
                        return
                    row = active.pop(fd)
                    row["end_ns"] = time.time_ns()
                    calls.append(row)
                    poll.unregister(fd)
                    os.close(fd)
                now = time.monotonic_ns()
                polls.append(now - previous)
                previous = now
                for entry in os.scandir("/proc"):
                    if not entry.name.isdigit() or entry.name in seen:
                        continue
                    path = Path(entry.path)
                    try:
                        comm = (path / "comm").read_bytes().strip()
                        if comm != b"runc":
                            continue
                        words = (path / "cmdline").read_bytes().split(b"\0")
                        ident = next((v.decode() for v in words if re.fullmatch(rb"[0-9a-f]{64}", v)), None)
                        op = next((v.decode() for v in words if v in (b"create", b"start", b"delete")), None)
                        if not ident or not op:
                            continue
                        # Field 22 is start time since boot in clock ticks. An exit wakes the poller
                        # even when /proc/PID has already disappeared.
                        stat = (path / "stat").read_bytes().rsplit(b") ", 1)[1].split()
                        # runc also forks processes that briefly inherit its command line. Count the
                        # original command launched by the containerd shim, once per operation.
                        parent_comm = (Path("/proc") / stat[1].decode() / "comm").read_bytes().strip()
                        if not parent_comm.startswith(b"containerd-shim"):
                            continue
                        born = offset + int(stat[19]) * tick
                        fd = os.pidfd_open(int(entry.name))
                    except (FileNotFoundError, ProcessLookupError, PermissionError):
                        continue
                    seen.add(entry.name)
                    active[fd] = {
                        "container": ident,
                        "pid": int(entry.name),
                        "operation": op,
                        "begin_ns": born,
                        "observed_ns": time.time_ns(),
                    }
                    poll.register(fd, select.EPOLLIN)
        finally:
            for fd in active:
                os.close(fd)


if __name__ == "__main__":
    main()
