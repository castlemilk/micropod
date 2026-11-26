#!/usr/bin/env python3
"""Time an HVF payload switchover from outside the product.

  switch_monitor.py --root MACHINE_ROOT --out FILE [--timeout SECONDS]

Reads the VMM pid from MACHINE_ROOT/run/state.json, arms a kqueue
EVFILT_PROC/NOTE_EXIT on it (so the exit instant is the kernel's, not the
next poll), writes FILE.ready, and waits. Once that VMM has exited it sends
GET /_ping to MACHINE_ROOT/run/docker.sock every 5 ms until one answers 200:
the first guest to answer after the old VMM is gone is the new one. FILE gets

  {"oldPid", "armedWall", "exitWall", "pingWall", "switchoverMs",
   "pingAttempts", "newPid", "newState"}

or {"error": ...} with exit status 1. This is the plan's measure: "old VMM
exit to the new guest answering _ping". It never signals anything.
"""

import argparse
import json
import os
import select
import socket
import sys
import time


def ping(path: str, timeout: float = 0.5) -> bool:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(path)
        s.sendall(b"GET /_ping HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n")
        head = s.recv(64)
        return head.startswith(b"HTTP/1.1 200") or head.startswith(b"HTTP/1.0 200")
    except OSError:
        return False
    finally:
        s.close()


def load_state(root: str) -> dict:
    with open(os.path.join(root, "run", "state.json"), encoding="utf-8") as f:
        return json.load(f)


def write(path: str, obj: dict) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, sort_keys=True)
    os.replace(tmp, path)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--timeout", type=float, default=240.0)
    a = ap.parse_args()
    sock = os.path.join(a.root, "run", "docker.sock")
    try:
        old = int(load_state(a.root)["vmmPID"])
    except (OSError, ValueError, KeyError, TypeError) as e:
        write(a.out, {"error": f"no running VMM recorded in state.json: {e}"})
        return 1
    kq = select.kqueue()
    ev = select.kevent(old, filter=select.KQ_FILTER_PROC, flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                       fflags=select.KQ_NOTE_EXIT)
    try:
        kq.control([ev], 0, 0)
    except OSError as e:
        write(a.out, {"error": f"cannot watch VMM pid {old}: {e}", "oldPid": old})
        return 1
    armed = time.time()
    write(a.out + ".ready", {"oldPid": old, "armedWall": armed})
    events = kq.control(None, 1, a.timeout)
    if not events:
        write(a.out, {"error": f"VMM pid {old} did not exit within {a.timeout} s", "oldPid": old, "armedWall": armed})
        return 1
    exit_mono, exit_wall = time.monotonic(), time.time()
    attempts = 0
    deadline = exit_mono + a.timeout
    answered = False
    while time.monotonic() < deadline:
        attempts += 1
        if ping(sock):
            answered = True
            break
        time.sleep(0.005)
    ping_mono, ping_wall = time.monotonic(), time.time()
    result = {"oldPid": old, "armedWall": armed, "exitWall": exit_wall, "pingAttempts": attempts}
    if not answered:
        result["error"] = f"no guest answered _ping within {a.timeout} s of the old VMM's exit"
        write(a.out, result)
        return 1
    result.update({"pingWall": ping_wall, "switchoverMs": round((ping_mono - exit_mono) * 1000, 1)})
    try:
        state = load_state(a.root)
        result["newPid"] = state.get("vmmPID")
        result["newState"] = {k: state.get(k) for k in ("phase", "startedAt", "readyAt", "loadedPayloadPath",
                                                        "supervisorPID")}
    except (OSError, ValueError) as e:
        result["newStateError"] = str(e)
    write(a.out, result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
