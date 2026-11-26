#!/usr/bin/env python3
"""Docker-socket interposer for the updater gate's "boots but fails the probe" payload.

  probefail_proxy.py --listen SOCK --upstream SOCK --watch-pid PID --log FILE

Started by probefail_vmm.sh (that payload's micropod-vmm) just before it execs
the real VMM, which then exposes the guest Docker API on --upstream instead of
the machine's run/docker.sock. This listens on run/docker.sock and forwards
every connection to the real guest unchanged, except GET [/v1.NN]/micropod/metrics,
which it answers 503: the guest boots and answers _ping (so the supervisor
reports it ready), and the activation's health probe fails on metrics.

Log lines: "fwd <status> <request line>" with the status the real guest sent
("no-answer" when it sent nothing), and "503 <request line> [current=<id>
known-good=<id> trial=<id>]" with the machine's payload links as they stood
at the moment the probe was refused.

It exits once PID (the VMM: the wrapper's pid, kept across exec) has exited, or
once its listening path is replaced by another socket, and only ever unlinks
the socket file it created itself. Every request line is logged to FILE.
"""

import argparse
import os
import socket
import sys
import threading
import time

LOCK = threading.Lock()


def log(f, msg: str) -> None:
    with LOCK:
        f.write(f"{time.time():.3f} {msg}\n")
        f.flush()


def pump(src: socket.socket, dst: socket.socket, first=None) -> None:
    """Copies src to dst; `first`, a list, receives the first bytes read."""
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            if first is not None and not first:
                first.append(data)
            dst.sendall(data)
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def bare_path(request_line: str) -> str:
    parts = request_line.split(" ")
    path = parts[1].split("?", 1)[0] if len(parts) > 1 else ""
    segments = path.lstrip("/").split("/", 1)
    if len(segments) == 2 and segments[0].startswith("v1."):
        path = "/" + segments[1]
    return path.rstrip("/")


def links(root: str) -> str:
    """Where the payload links point right now: 'current=<id> known-good=<id> trial=<id>'."""
    out = []
    for name in ("current", "known-good", "trial"):
        try:
            out.append(f"{name}={os.path.basename(os.readlink(os.path.join(root, name)))}")
        except OSError:
            out.append(f"{name}=none")
    return " ".join(out)


def handle(conn: socket.socket, upstream: str, logf, root: str) -> None:
    up = None
    try:
        conn.settimeout(15)
        head = b""
        while b"\r\n\r\n" not in head and len(head) < 65536:
            data = conn.recv(65536)
            if not data:
                return
            head += data
        line = head.split(b"\r\n", 1)[0].decode("latin-1")
        if line.startswith("GET ") and bare_path(line) == "/micropod/metrics":
            body = b'{"message":"B26 updater gate: this payload withholds /micropod/metrics"}'
            conn.sendall(b"HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\n"
                         b"Content-Length: %d\r\nConnection: close\r\n\r\n" % len(body) + body)
            log(logf, f"503 {line} [{links(root)}]")
            return
        up = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            up.connect(upstream)
        except OSError as e:
            log(logf, f"no-upstream {line} ({e})")
            return
        up.sendall(head)
        conn.settimeout(None)
        first = []
        back = threading.Thread(target=pump, args=(up, conn, first), daemon=True)
        back.start()
        pump(conn, up)
        back.join(timeout=60)
        # The guest's own status line: "fwd 200 GET /_ping ..." only when the real guest answered 200.
        status = first[0].split(b"\r\n", 1)[0].decode("latin-1").split(" ") if first else []
        log(logf, f"fwd {status[1] if len(status) > 1 else 'no-answer'} {line}")
    except OSError as e:
        log(logf, f"error {e}")
    finally:
        conn.close()
        if up is not None:
            up.close()


def watch(pid: int, path: str, inode: int, logf) -> None:
    reason = ""
    while not reason:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            reason = f"vmm pid {pid} exited"
        except PermissionError:
            pass
        try:
            if os.lstat(path).st_ino != inode:
                reason = f"{path} was replaced"
        except FileNotFoundError:
            reason = reason or f"{path} was removed"
        if not reason:
            time.sleep(0.2)
    try:
        if os.lstat(path).st_ino == inode:
            os.unlink(path)
    except OSError:
        pass
    log(logf, f"exit: {reason}")
    os._exit(0)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", required=True)
    ap.add_argument("--upstream", required=True)
    ap.add_argument("--watch-pid", type=int, required=True)
    ap.add_argument("--log", required=True)
    a = ap.parse_args()
    logf = open(a.log, "a", encoding="utf-8")
    try:
        os.unlink(a.listen)  # the supervisor removed it before this launch; only a stale file can be here
    except FileNotFoundError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(a.listen)
    srv.listen(64)
    inode = os.lstat(a.listen).st_ino
    root = os.path.dirname(os.path.dirname(os.path.abspath(a.listen)))  # <root>/run/docker.sock
    log(logf, f"listening on {a.listen} -> {a.upstream} for vmm pid {a.watch_pid} (proxy pid {os.getpid()})")
    threading.Thread(target=watch, args=(a.watch_pid, a.listen, inode, logf), daemon=True).start()
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn, a.upstream, logf, root), daemon=True).start()


if __name__ == "__main__":
    sys.exit(main())
