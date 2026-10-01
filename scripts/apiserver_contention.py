#!/usr/bin/env python3
"""Apiserver contention load: a cuttlefish-shaped workload against a MicropodAPI.

Each worker round does what one CI attempt does to the runtime:
  CreateVolume (a fresh workspace volume, formatted by the apiserver under its
  volumes lock), RunContainer with cache clones of the goldens plus the
  workspace attached, WaitContainer until it exits, DeleteContainer,
  DeleteVolume. Meanwhile pollers call ListContainers, GetContainer (on a
  running worker container) and ListVolumes, the way the agent's watchdog,
  exit waits and disk manager do.

Prints per-RPC latency (p50/p95/max) and failures by code, and writes the same
as JSON (--out). Run it against a scratch API, never the shared :45454 one:

  MICROPOD_API_PORT=45491 .build/debug/MicropodAPI &
  python3 scripts/apiserver_contention.py --base http://127.0.0.1:45491

Everything it creates is named <prefix>-* and removed at the end (also on
Ctrl-C). Stdlib only.
"""

import argparse
import json
import random
import statistics
import sys
import threading
import time
import urllib.error
import urllib.request
from collections import defaultdict

SERVICES = {
    "ListContainers": "ContainerService",
    "GetContainer": "ContainerService",
    "RunContainer": "ContainerService",
    "WaitContainer": "ContainerService",
    "DeleteContainer": "ContainerService",
    "ListVolumes": "VolumeService",
    "CreateVolume": "VolumeService",
    "DeleteVolume": "VolumeService",
}


class Recorder:
    def __init__(self):
        self.lock = threading.Lock()
        self.latency = defaultdict(list)
        self.failures = defaultdict(lambda: defaultdict(int))
        self.examples = {}

    def add(self, rpc, seconds, code):
        with self.lock:
            self.latency[rpc].append(seconds)
            if code != "ok":
                self.failures[rpc][code] += 1
                self.examples.setdefault((rpc, code), None)

    def example(self, rpc, code, message):
        with self.lock:
            if self.examples.get((rpc, code)) is None:
                self.examples[(rpc, code)] = message[:240]

    def summary(self):
        out = {}
        with self.lock:
            for rpc, values in sorted(self.latency.items()):
                ordered = sorted(values)
                p95 = ordered[min(len(ordered) - 1, int(len(ordered) * 0.95))]
                out[rpc] = {
                    "count": len(values),
                    "failed": dict(self.failures[rpc]),
                    "p50_ms": round(statistics.median(ordered) * 1000),
                    "p95_ms": round(p95 * 1000),
                    "max_ms": round(ordered[-1] * 1000),
                }
            out["_examples"] = {f"{r}/{c}": m for (r, c), m in self.examples.items() if m}
        return out


class API:
    def __init__(self, base, recorder):
        self.base = base.rstrip("/")
        self.recorder = recorder

    def call(self, rpc, body, timeout=180, record=True):
        url = f"{self.base}/api/micropod.v1.{SERVICES[rpc]}/{rpc}"
        data = json.dumps(body).encode()
        request = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
        started = time.monotonic()
        code, payload, message = "ok", None, ""
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                payload = json.loads(response.read() or b"{}")
        except urllib.error.HTTPError as error:
            try:
                detail = json.loads(error.read() or b"{}")
            except ValueError:
                detail = {}
            code = detail.get("code", f"http_{error.code}")
            message = detail.get("message", "")
        except Exception as error:  # timeouts, resets
            code, message = "client_" + type(error).__name__, str(error)
        took = time.monotonic() - started
        if record:
            self.recorder.add(rpc, took, code)
            if code != "ok":
                self.recorder.example(rpc, code, message)
        return code, payload, message


def poller(api, rpc, hz, stop, active):
    period = 1.0 / hz
    while not stop.is_set():
        started = time.monotonic()
        if rpc == "GetContainer":
            with active["lock"]:
                ids = list(active["ids"])
            if ids:
                api.call(rpc, {"id": random.choice(ids)}, timeout=60)
        else:
            api.call(rpc, {}, timeout=60)
        stop.wait(max(0.0, period - (time.monotonic() - started)))


def worker(api, args, index, active, errors):
    for round_ in range(args.rounds):
        ws = f"{args.prefix}-ws-{index}-{round_}"
        name = f"{args.prefix}-c-{index}-{round_}"
        code, _, message = api.call("CreateVolume", {"name": ws, "size": args.ws_size})
        if code != "ok":
            errors.append(f"{name}: CreateVolume {code}: {message[:160]}")
            continue
        goldens = [f"{args.prefix}-gold-{g}" for g in range(args.goldens)]
        volumes = [f"{ws}:/ws"] + [f"{g}:/cache/{i}" for i, g in enumerate(goldens)]
        run = {
            "image": args.image,
            "name": name,
            "detach": True,
            "volumes": volumes,
            "labels": {"com.micropod.cache.clone": ",".join(goldens), "dev.micropod.load": args.prefix},
            "arguments": ["sh", "-c", f"dd if=/dev/zero of=/fill bs=1M count={args.fill_mb} 2>/dev/null; sync; sleep {args.sleep}"],
        }
        code, _, message = api.call("RunContainer", run)
        if code != "ok":
            errors.append(f"{name}: RunContainer {code}: {message[:200]}")
        else:
            with active["lock"]:
                active["ids"].add(name)
            deadline = time.monotonic() + 180
            while time.monotonic() < deadline:
                code, payload, message = api.call("WaitContainer", {"id": name, "timeoutSeconds": 30}, timeout=60)
                if code == "ok" and payload.get("exited"):
                    break
                if code != "ok":
                    errors.append(f"{name}: WaitContainer {code}: {message[:160]}")
                    time.sleep(0.5)
            with active["lock"]:
                active["ids"].discard(name)
        code, _, message = api.call("DeleteContainer", {"id": name, "force": True})
        if code not in ("ok", "not_found"):
            errors.append(f"{name}: DeleteContainer {code}: {message[:160]}")
        code, _, message = api.call("DeleteVolume", {"name": ws})
        if code not in ("ok", "not_found"):
            errors.append(f"{ws}: DeleteVolume {code}: {message[:160]}")


def cleanup(api, prefix):
    _, listed, _ = api.call("ListContainers", {}, record=False)
    for container in (listed or {}).get("containers", []):
        if container.get("id", "").startswith(prefix + "-"):
            api.call("DeleteContainer", {"id": container["id"], "force": True}, record=False)
    _, volumes, _ = api.call("ListVolumes", {}, record=False)
    for volume in (volumes or {}).get("volumes", []):
        name = volume.get("id") or volume.get("name", "")
        if name.startswith(prefix + "-"):
            api.call("DeleteVolume", {"name": name}, record=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", required=True, help="MicropodAPI base URL (a scratch port, not :45454)")
    parser.add_argument("--workers", type=int, default=3)
    parser.add_argument("--rounds", type=int, default=2)
    parser.add_argument("--goldens", type=int, default=2)
    parser.add_argument("--image", default="docker.io/library/alpine:3")
    parser.add_argument("--ws-size", default="300G", help="workspace volume size (the apiserver formats it under its volumes lock)")
    parser.add_argument("--golden-size", default="32G")
    parser.add_argument("--fill-mb", type=int, default=256, help="MiB written to the container rootfs (a heavier delete)")
    parser.add_argument("--sleep", type=float, default=2)
    parser.add_argument("--poll-hz", type=float, default=5, help="per poller")
    parser.add_argument("--prefix", default="xpcload")
    parser.add_argument("--out", help="write the summary JSON here")
    args = parser.parse_args()
    if args.base.rstrip("/").endswith(":45454"):
        sys.exit("refusing to load the shared :45454 API; start a scratch MicropodAPI on another port")

    recorder = Recorder()
    api = API(args.base, recorder)
    setup = API(args.base, Recorder())
    cleanup(setup, args.prefix)
    for g in range(args.goldens):
        code, _, message = setup.call("CreateVolume", {"name": f"{args.prefix}-gold-{g}", "size": args.golden_size})
        if code != "ok" and "already exists" not in message:
            sys.exit(f"golden create failed: {code} {message}")

    stop = threading.Event()
    active = {"lock": threading.Lock(), "ids": set()}
    errors = []
    pollers = [
        threading.Thread(target=poller, args=(api, rpc, args.poll_hz, stop, active), daemon=True)
        for rpc in ("ListContainers", "GetContainer", "ListVolumes")
    ]
    workers = [threading.Thread(target=worker, args=(api, args, i, active, errors)) for i in range(args.workers)]
    started = time.monotonic()
    try:
        for thread in pollers + workers:
            thread.start()
        for thread in workers:
            thread.join()
    finally:
        stop.set()
        for thread in pollers:
            thread.join(timeout=70)
        cleanup(setup, args.prefix)

    summary = recorder.summary()
    summary["_wall_seconds"] = round(time.monotonic() - started, 1)
    summary["_worker_errors"] = errors
    print(f"{'rpc':<16}{'count':>7}{'p50 ms':>9}{'p95 ms':>9}{'max ms':>9}  failed")
    for rpc, row in summary.items():
        if rpc.startswith("_"):
            continue
        failed = ", ".join(f"{code}×{n}" for code, n in row["failed"].items()) or "-"
        print(f"{rpc:<16}{row['count']:>7}{row['p50_ms']:>9}{row['p95_ms']:>9}{row['max_ms']:>9}  {failed}")
    print(f"wall {summary['_wall_seconds']}s; worker errors: {len(errors)}")
    for line in errors[:12]:
        print("  " + line)
    for key, message in summary["_examples"].items():
        print(f"  e.g. {key}: {message}")
    if args.out:
        with open(args.out, "w") as handle:
            json.dump(summary, handle, indent=2)


if __name__ == "__main__":
    main()
