#!/usr/bin/env python3
"""Create-to-start latency for scripts/e2e_hvf_caches.sh section T7.

Talks to the Docker API on a unix socket (host side, so nothing depends on
container stdout). Each sample is POST /containers/create then POST start;
only those two calls are timed, wait and DELETE are not. The two
configurations alternate container by container (S8 showed that sequential
passes of the same configuration drift by more than the +10 ms gate).

  qlatency.py series <socket> <image> <n> <warmup> <off.json> <on.json> <out.json>
  qlatency.py first <socket> <image> <cfg.json> <out.json>

A cfg file is {"Labels": {...}, "Env": [...], "Binds": [...]} merged into the
create body. The output JSON is read back by the harness.
"""
import http.client
import json
import socket
import statistics
import sys
import time


class UnixConnection(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("docker", timeout=120)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(120)
        self.sock.connect(self.path)


def call(sock, method, url, body=None):
    conn = UnixConnection(sock)
    try:
        data = json.dumps(body).encode() if body is not None else None
        conn.request(method, "/v1.47" + url, body=data, headers={"Content-Type": "application/json"} if data else {})
        r = conn.getresponse()
        payload = r.read()
        return r.status, payload
    finally:
        conn.close()


def sample(sock, image, cfg):
    body = {"Image": image, "Cmd": ["true"], "Labels": dict(cfg.get("Labels", {})),
            "Env": list(cfg.get("Env", [])), "HostConfig": {"Binds": list(cfg.get("Binds", []))}}
    t0 = time.perf_counter()
    status, payload = call(sock, "POST", "/containers/create", body)
    t1 = time.perf_counter()
    if status != 201:
        raise RuntimeError(f"create {status}: {payload[:300]!r}")
    cid = json.loads(payload)["Id"]
    status, payload = call(sock, "POST", f"/containers/{cid}/start")
    t2 = time.perf_counter()
    if status != 204:
        raise RuntimeError(f"start {status}: {payload[:300]!r}")
    _, inspect = call(sock, "GET", f"/containers/{cid}/json")
    call(sock, "POST", f"/containers/{cid}/wait")
    call(sock, "DELETE", f"/containers/{cid}?force=1")
    return (t1 - t0) * 1000, (t2 - t0) * 1000, json.loads(inspect)


def pct(values, p):
    s = sorted(values)
    k = max(0, min(len(s) - 1, int(round(p / 100 * (len(s) - 1)))))
    return s[k]


def summary(values):
    return {"n": len(values), "p50": round(statistics.median(values), 2), "p95": round(pct(values, 95), 2),
            "max": round(max(values), 2)}


def main():
    mode = sys.argv[1]
    if mode == "series":
        sock, image, n, warm, off_path, on_path, out = sys.argv[2:9]
        off, on = json.load(open(off_path)), json.load(open(on_path))
        n, warm = int(n), int(warm)
        for _ in range(warm):
            sample(sock, image, off)
            sample(sock, image, on)
        series = {"off": [], "on": []}
        creates = {"off": [], "on": []}
        last = {}
        for _ in range(n):
            for key, cfg in (("off", off), ("on", on)):
                create, total, inspect = sample(sock, image, cfg)
                series[key].append(total)
                creates[key].append(create)
                last[key] = inspect
        result = {"image": image, "n": n, "warmup": warm,
                  "off": summary(series["off"]), "on": summary(series["on"]),
                  "create_off": summary(creates["off"]), "create_on": summary(creates["on"]),
                  "delta_p50": round(statistics.median(series["on"]) - statistics.median(series["off"]), 2),
                  "delta_p95": round(pct(series["on"], 95) - pct(series["off"], 95), 2),
                  "on_inspect": last.get("on", {}), "off_inspect": last.get("off", {})}
    elif mode == "first":
        sock, image, cfg_path, out = sys.argv[2:6]
        create, total, inspect = sample(sock, image, json.load(open(cfg_path)))
        result = {"image": image, "create_ms": round(create, 2), "total_ms": round(total, 2), "inspect": inspect}
    else:
        raise SystemExit("usage: qlatency.py series|first …")
    with open(out + ".tmp", "w") as f:
        json.dump(result, f)
    import os
    os.replace(out + ".tmp", out)


if __name__ == "__main__":
    main()
