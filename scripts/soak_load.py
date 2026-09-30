#!/usr/bin/env python3
"""Load for scripts/app_soak.sh: the request mix from the crash stacks —
concurrent log streams opened and dropped mid-stream, stats, list, get, exec.

Usage: soak_load.py <port> <seconds> <id,id,...>"""
import concurrent.futures as cf, http.client, json, random, sys, time

PORT = int(sys.argv[1]); SECS = int(sys.argv[2]); IDS = sys.argv[3].split(",")

def rpc(method, body):
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=30)
    c.request("POST", f"/api/micropod.v1.{method}", json.dumps(body), {"Content-Type": "application/json"})
    r = c.getresponse(); r.read(); c.close(); return r.status

def logs():
    # Open a follow stream, read a little, drop the connection mid-stream.
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    c.request("GET", f"/v1/containers/{random.choice(IDS)}/logs?tail=5")
    r = c.getresponse()
    try:
        r.read1(512) if hasattr(r, "read1") else r.read(512)
        time.sleep(random.uniform(0, 0.3))
    finally:
        c.close()
    return r.status

OPS = [
    lambda: logs(), lambda: logs(),
    lambda: rpc("ContainerService/GetStats", {}),
    lambda: rpc("ContainerService/ListContainers", {}),
    lambda: rpc("ContainerService/GetContainer", {"id": random.choice(IDS)}),
    lambda: rpc("ContainerService/Exec", {"id": random.choice(IDS), "arguments": ["echo", "x"]}),
    lambda: rpc("SystemService/Ping", {}),
]

def worker(_):
    n = errs = 0
    end = time.time() + SECS
    while time.time() < end:
        try:
            random.choice(OPS)(); n += 1
        except Exception:
            errs += 1
    return n, errs

with cf.ThreadPoolExecutor(16) as ex:
    res = list(ex.map(worker, range(16)))
print("requests", sum(r[0] for r in res), "client-errors", sum(r[1] for r in res))
