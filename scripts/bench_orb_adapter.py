#!/usr/bin/env python3
"""Compare the Micropod Docker adapter and the Docker CLI on one OrbStack socket."""
import argparse
import concurrent.futures
import http.client
import json
import os
import random
import socket
import statistics
import struct
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

IMAGE = "ghcr.io/containerd/busybox:1.36@sha256:907ca53d7e2947e849b839b1cd258c98fd3916c60f2e6e70c30edbf741ab6754"


class Endpoint(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost", timeout=30)
        self.path = str(path)

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.path)

    def request_bytes(self, method, path, expect=200):
        try:
            self.request(method, "/v1.43" + path)
            response = self.getresponse()
            body = response.read()
            if response.status != expect:
                raise ValueError(f"{method} {path}: HTTP {response.status} {body[:200]!r}")
            return body
        finally:
            self.close()


def command(argv, env, limit=90):
    r = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, env=env, timeout=limit)
    if r.returncode:
        raise ValueError(f"{Path(argv[0]).name} {argv[1]}: exit {r.returncode} {r.stderr[-450:]}")
    return r.stdout.strip()


def streams(data):
    outputs = {1: b"", 2: b""}
    while data:
        if len(data) < 8 or data[0] not in outputs or data[1:4] != bytes(3):
            raise ValueError("invalid Docker log frame")
        length = struct.unpack(">I", data[4:8])[0]
        if len(data) < length + 8:
            raise ValueError("truncated Docker log frame")
        outputs[data[0]] += data[8:8+length]
        data = data[8+length:]
    return outputs


def job(client, docker, micropod, sock, env, image_id):
    nonce = uuid.uuid4().hex
    name = "mp-bench-" + nonce
    path = "/containers/" + name
    api = Endpoint(sock).request_bytes
    common = ["--name", name, "--label", "micropod.bench=" + nonce, "--network", "none",
              "--cpus", "1", "--memory", "64m", IMAGE, "sh", "-c",
              f'echo out-{nonce}; echo err-{nonce} >&2; exit 23']
    if client == "micropod":
        # The stock CLI's option parser requires an explicit boundary for guest flags.
        common.insert(common.index(IMAGE), "--")
        argv = [micropod, "run", "--runtime", "docker", *common]
    elif client == "micropod-transport":
        argv = [micropod, "unix://" + str(sock), "run", name, nonce, IMAGE]
    else:
        argv = [*docker, "run", "-d", *common]
    started = time.perf_counter()
    try:
        command(argv, env)
        launch = time.perf_counter() - started
        waited = json.loads(api("POST", path + "/wait"))
        info = json.loads(api("GET", path + "/json"))
        if (waited["StatusCode"] != 23 or info["State"]["ExitCode"] != 23 or info["Image"] != image_id
                or info["Config"]["Labels"]["micropod.bench"] != nonce
                or info["HostConfig"]["NanoCpus"] != 1000000000 or info["HostConfig"]["Memory"] != 64 << 20
                or info["HostConfig"]["NetworkMode"] != "none"):
            raise ValueError("guest exit, labels, image identity or limits differ")
        logs = streams(api("GET", path + "/logs?stdout=1&stderr=1"))
        if logs != {1: f"out-{nonce}\n".encode(), 2: f"err-{nonce}\n".encode()}:
            raise ValueError("guest streams differ")
        if client == "micropod":
            remove = [micropod, "rm", "--force", name]
        elif client == "micropod-transport":
            remove = [micropod, "unix://" + str(sock), "rm", name]
        else:
            remove = [*docker, "rm", "--force", name]
        removed_at = time.perf_counter()
        command(remove, env)
        removed = time.perf_counter() - removed_at
        api("GET", path + "/json", expect=404)
        return dict(launch_s=round(launch, 6), remove_s=round(removed, 6))
    except Exception:
        # This run exclusively owns the random name.
        subprocess.run([*docker, "rm", "-f", name], capture_output=True, timeout=30)
        raise


def block(client, n, docker, micropod, sock, env, image_id):
    started = time.perf_counter()
    jobs = []
    with concurrent.futures.ThreadPoolExecutor(n) as pool:
        futures = [pool.submit(job, client, docker, micropod, sock, env, image_id) for _ in range(n)]
        for future in futures:
            try:
                jobs.append(future.result())
            except Exception as exc:
                jobs.append({"error": str(exc)})
    return dict(client=client, clients=n, wall_s=round(time.perf_counter()-started, 6),
                passed=sum("error" not in x for x in jobs), jobs=jobs)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--micropod", required=True, help="production CLI or explicitly selected transport benchmark driver")
    ap.add_argument("--client", choices=["micropod", "micropod-transport"], default="micropod")
    ap.add_argument("--socket", type=Path, required=True)
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--expect-os", default="orbstack", help="required substring of the Docker server OS")
    ap.add_argument("--clients", nargs="+", type=int, default=[1, 4, 8, 16])
    ap.add_argument("--json", type=Path, required=True)
    args = ap.parse_args()
    host = "unix://" + str(args.socket)
    docker = ["docker", "--host", host]
    env = dict(os.environ)
    api = Endpoint(args.socket).request_bytes
    engine = json.loads(api("GET", "/info"))
    if not args.expect_os or args.expect_os.lower() not in engine["OperatingSystem"].lower():
        raise ValueError("wrong Docker endpoint")
    command([*docker, "pull", IMAGE], env, 180)
    image_id = command([*docker, "image", "inspect", "--format", "{{.Id}}", IMAGE], env)
    data = dict(engine={k: engine[k] for k in ("OperatingSystem", "Architecture", "NCPU", "MemTotal", "ServerVersion")},
                image=IMAGE, image_id=image_id, commit=os.getenv("GITHUB_SHA"), build=os.getenv("BENCH_BUILD"),
                warmups=[], blocks=[], summary=[])
    def save():
        temp = args.json.with_suffix(".tmp")
        temp.write_text(json.dumps(data, indent=2) + "\n")
        temp.replace(args.json)
    rng = random.Random(20261119)
    with tempfile.TemporaryDirectory() as tmp:
        cfg = Path(tmp) / "runtimes.json"
        cfg.write_text(json.dumps({"default": "docker", "engines": {"docker": {"enabled": True, "endpoint": host},
                       "apple": {"enabled": False}, "sandbox": {"enabled": False}}}))
        env["MICROPOD_RUNTIMES_CONFIG"] = str(cfg)
        available = []
        for client in ["docker", args.client]:
            r = block(client, 1, docker, args.micropod, args.socket, env, image_id)
            data["warmups"].append(r)
            if r["passed"] == 1:
                available.append(client)
            print(json.dumps(r), flush=True)
            save()
        for n in args.clients:
            for i in range(args.rounds):
                rng.shuffle(available)
                for client in available:
                    r = block(client, n, docker, args.micropod, args.socket, env, image_id)
                    r["block"] = i+1
                    data["blocks"].append(r)
                    print(f'{client} x{n}: {r["passed"]}/{n} in {r["wall_s"]:.3f}s', flush=True)
                    save()
        for client in available:
            for n in args.clients:
                rows = [r for r in data["blocks"] if r["client"] == client and r["clients"] == n]
                if all(r["passed"] == n for r in rows):
                    times = [r["wall_s"] for r in rows]
                    data["summary"].append(dict(client=client, clients=n, median_s=statistics.median(times),
                                                min_s=min(times), max_s=max(times), blocks=len(times)))
        save()
        print("MP_RESULT " + json.dumps(data["summary"]), flush=True)
        print("MP_BLOCKS " + json.dumps([{k: v for k, v in b.items() if k != "jobs"} for b in data["blocks"]]), flush=True)
        for r in data["summary"]:
            group = [b for b in data["blocks"] if (b["client"], b["clients"]) == (r["client"], r["clients"])]
            passes = [j for b in group for j in b["jobs"] if "error" not in j]
            r["per_job_launch_p50_s"] = statistics.median(j["launch_s"] for j in passes)
            r["per_job_remove_p50_s"] = statistics.median(j["remove_s"] for j in passes)
        save()
        print("MP_PHASES " + json.dumps(data["summary"]), flush=True)
        return int(len(available) != 2 or any(r["passed"] != r["clients"] for r in data["blocks"]))


if __name__ == "__main__":
    raise SystemExit(main())
