#!/usr/bin/env python3
"""Small measuring helpers for scripts/gates/updater.sh. Each prints one value.

  gate.py exe PID                     canonical path of PID's executable (proc_pidpath), or "none"
  gate.py lock-held FILE              "yes" when another process holds FILE's flock exclusively
  gate.py manifest-diff WANT GOT      "same <n>" or "differs: ..." (sha256 per path, both directions)
  gate.py cache-inventory SOCK        "<digest> <gomod:yes|no> <b26-gate-scope:yes|no>" of GET /micropod/caches
  gate.py busy-ports PORT...          the ports something already listens on (or binds) on 127.0.0.1
  gate.py in-order FILE OFFSET PAT... "yes" when each substring appears after the previous one,
                                       reading FILE from byte OFFSET; else "no: <first missing>"
  gate.py count FILE OFFSET PAT       lines containing PAT after byte OFFSET
  gate.py json FILE EXPR              EXPR evaluated over the JSON document `d` ("absent" if unreadable)
  gate.py mtime FILE                  st_mtime as a float, or "none"
  gate.py measure FILE KEY JSON|@PATH appends {"key": KEY, "value": ...} to FILE (a JSON file with @)
"""

import ctypes
import fcntl
import hashlib
import json
import os
import socket
import sys


def exe(pid: str) -> str:
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
        buf = ctypes.create_string_buffer(4096)
        n = libproc.proc_pidpath(int(pid), buf, ctypes.c_uint32(4096))
        if n <= 0:
            return "none"
        return os.path.realpath(buf.value.decode())
    except (OSError, ValueError):
        return "none"


def lock_held(path: str) -> str:
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return "no-file"
    try:
        fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
    except BlockingIOError:
        return "yes"
    finally:
        os.close(fd)  # closing drops a shared lock this probe took
    return "no"


def parse_manifest(path: str) -> dict:
    out = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            digest, _, name = line.partition("  ")
            out[name.strip()] = digest.strip().lower()
    return out


def manifest_diff(want: str, got: str) -> str:
    try:
        w, g = parse_manifest(want), parse_manifest(got)
    except OSError as e:
        return f"differs: unreadable ({e})"
    if not w:
        return "differs: the expected manifest is empty"
    missing = sorted(set(w) - set(g))
    extra = sorted(set(g) - set(w))
    changed = sorted(k for k in set(w) & set(g) if w[k] != g[k])
    if not (missing or extra or changed):
        return f"same {len(w)}"
    return "differs: " + "; ".join(
        f"{label} {len(items)} ({', '.join(items[:3])})" for label, items in
        (("missing", missing), ("extra", extra), ("changed", changed)) if items)


def http_get(sock: str, path: str, timeout: float = 15.0) -> bytes:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(sock)
    s.sendall(f"GET {path} HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n".encode())
    data = b""
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        data += chunk
    s.close()
    head, _, body = data.partition(b"\r\n\r\n")
    if not head.startswith(b"HTTP/1.1 200"):
        raise OSError(head.split(b"\r\n", 1)[0].decode("latin-1"))
    if b"transfer-encoding: chunked" in head.lower():
        out, rest = b"", body
        while rest:
            size_line, _, rest = rest.partition(b"\r\n")
            size = int(size_line.split(b";")[0], 16)
            if size == 0:
                break
            out, rest = out + rest[:size], rest[size + 2:]
        body = out
    return body


def cache_inventory(sock: str) -> str:
    """The e2e's inventory digest: policy digest, scopes and their stores, and
    (scope, kind, unit, files, bytes) per unit; timestamps and locks left out."""
    try:
        d = json.loads(http_get(sock, "/micropod/caches"))
    except (OSError, ValueError) as e:
        return f"unavailable ({e})"
    units = sorted((u.get("scope"), u.get("kind"), u.get("unit"), u.get("files"), u.get("bytes"))
                   for u in d.get("units") or [])
    scopes = {k: sorted(v) for k, v in (d.get("scopes") or {}).items()}
    inventory = {"policy": d.get("policyDigest"), "scopes": scopes, "units": units}
    digest = hashlib.sha256(json.dumps(inventory, sort_keys=True).encode()).hexdigest()[:16]
    gomod = any("gomod" in kinds for kinds in scopes.values())
    return f"{digest} gomod:{'yes' if gomod else 'no'} b26-gate-scope:{'yes' if 'b26gate' in scopes else 'no'}"


def busy_ports(ports) -> str:
    """A port is busy when something accepts on it, or it cannot be bound even
    with SO_REUSEADDR (so TIME_WAIT leftovers of an earlier run do not count)."""
    busy = []
    for p in ports:
        c = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        c.settimeout(0.5)
        try:
            listening = c.connect_ex(("127.0.0.1", int(p))) == 0
        finally:
            c.close()
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind(("127.0.0.1", int(p)))
            bindable = True
        except OSError:
            bindable = False
        finally:
            s.close()
        if listening or not bindable:
            busy.append(str(p))
    return " ".join(busy)


def tail(path: str, offset: str) -> str:
    with open(path, "rb") as f:
        f.seek(int(offset))
        return f.read().decode("utf-8", "replace")


def in_order(path: str, offset: str, patterns) -> str:
    try:
        text = tail(path, offset)
    except OSError as e:
        return f"no: unreadable ({e})"
    at = 0
    for p in patterns:
        i = text.find(p, at)
        if i < 0:
            return f"no: {p!r} missing"
        at = i + len(p)
    return "yes"


def count(path: str, offset: str, pattern: str) -> str:
    try:
        return str(sum(1 for line in tail(path, offset).splitlines() if pattern in line))
    except OSError:
        return "0"


def json_expr(path: str, expr: str) -> str:
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
    except (OSError, ValueError):
        return "absent"
    try:
        return str(eval(expr, {"d": d}))  # expressions come from the harness itself
    except Exception as e:  # noqa: BLE001 - report, never crash the harness
        return f"error({type(e).__name__}: {e})"


def mtime(path: str) -> str:
    try:
        return repr(os.stat(path).st_mtime)
    except OSError:
        return "none"


def measure(path: str, key: str, value: str) -> str:
    if value.startswith("@"):
        try:
            with open(value[1:], encoding="utf-8") as f:
                parsed = json.load(f)
        except (OSError, ValueError) as e:
            parsed = {"error": f"unreadable {value[1:]}: {e}"}
    else:
        try:
            parsed = json.loads(value)
        except ValueError:
            parsed = value
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps({"key": key, "value": parsed}, sort_keys=True) + "\n")
    return ""


def main(argv) -> int:
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, args = argv[1], argv[2:]
    table = {
        "exe": lambda: exe(args[0]),
        "lock-held": lambda: lock_held(args[0]),
        "manifest-diff": lambda: manifest_diff(args[0], args[1]),
        "cache-inventory": lambda: cache_inventory(args[0]),
        "busy-ports": lambda: busy_ports(args),
        "in-order": lambda: in_order(args[0], args[1], args[2:]),
        "count": lambda: count(args[0], args[1], args[2]),
        "json": lambda: json_expr(args[0], args[1]),
        "mtime": lambda: mtime(args[0]),
        "measure": lambda: measure(args[0], args[1], args[2]),
    }
    if cmd not in table:
        print(__doc__, file=sys.stderr)
        return 2
    out = table[cmd]()
    if out:
        print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
