#!/usr/bin/env python3
"""Time containers on a verified running kernel, including paired runs from one physical Mac."""

import argparse
import concurrent.futures
import hashlib
import http.client
import json
import os
from pathlib import Path
import platform
import socket
import statistics
import subprocess
import sys
import time
from urllib.parse import urlsplit
import uuid


BOOT = "/proc/sys/kernel/random/boot_id"
CLASSES = {"aarch64": "arm64", "arm64": "arm64", "x86_64": "amd64", "amd64": "amd64"}


def fingerprint(value):
    return hashlib.sha256(str(uuid.UUID(value.strip())).encode()).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


class LocalConnection(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost", timeout=600)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.path)


def rpc(endpoint, method, payload):
    url = urlsplit(endpoint)
    if url.scheme == "unix" and not url.netloc and url.path.startswith("/"):
        conn = LocalConnection(url.path)
    elif url.scheme == "http" and url.hostname in {"127.0.0.1", "::1", "localhost"} and url.path in {"", "/"}:
        conn = http.client.HTTPConnection(url.hostname, url.port or 80, timeout=600)
    else:
        raise ValueError("Use an explicit local Micropod Connect HTTP or Unix endpoint")
    try:
        conn.request("POST", "/micropod.v1.ContainerService/" + method, json.dumps(payload),
                     {"Content-Type": "application/json", "Connect-Protocol-Version": "1"})
        response = conn.getresponse()
        body = response.read()
        require(response.status == 200, f"Micropod {method} returned HTTP {response.status}: {body[:250]!r}")
        return json.loads(body)
    finally:
        conn.close()


def in_allocation(args, receipt):
    def inspect():
        row = rpc(args.api, "GetContainer", {"id": args.allocation})
        require(row.get("id") == args.allocation and row.get("runtime") == "sandbox"
                and row.get("state", "").lower() == "running", "Select a running Micropod sandbox allocation")
        return {k: row.get(k) for k in ("id", "runtime", "state", "image", "createdAt")}

    def execute(argv):
        result = rpc(args.api, "Exec", {"id": args.allocation, "arguments": argv})
        require(int(result.get("exitCode", 0)) == 0, f"allocation exec failed: {result.get('error', '')[-400:]}")
        return result.get("output", "").strip()

    owner = inspect()
    parent = fingerprint(execute(["cat", BOOT]))
    receipt["allocation"] = owner
    receipt["owner_boot_sha256"] = parent
    if args.clock == "client":
        def runner(argv):
            response = rpc(args.api, "Exec", {"id": args.allocation, "arguments": argv})
            return subprocess.CompletedProcess(argv, int(response.get("exitCode", 0)),
                                               response.get("output", ""), response.get("error", ""))
        measure(args, receipt, runner=runner, read_parent=lambda: fingerprint(execute(["cat", BOOT])))
        require(receipt["boot_sha256"] == parent and inspect() == owner, "Micropod allocation changed")
        return

    # A single RPC encloses setup, timed work and teardown. Container launch times
    # use the allocation's monotonic clock and exclude transport back to the Mac.
    inner = ["python3", "-c", Path(__file__).read_text(), "--engine", "inner", "--socket", args.socket,
             "--image", args.image, "--rounds", str(args.rounds), "--clients", *map(str, args.clients)]
    result = json.loads(execute(inner))
    receipt["measurement"] = result
    require(result.get("passed") is True, result.get("error", "allocation measurement incomplete"))
    require(result["boot_sha256"] == parent == fingerprint(execute(["cat", BOOT])) and inspect() == owner,
            "Micropod allocation or kernel changed during measurement")


def measure(args, receipt, runner=None, read_parent=None):
    require(args.socket.startswith("/"), "The Docker socket must be an absolute path")
    docker = ["docker", "--host", "unix://" + args.socket]
    def cmd(argv, check=True):
        command = [*docker, *argv]
        r = runner(command) if runner else subprocess.run(command, capture_output=True, text=True, timeout=90)
        if check and r.returncode:
            raise ValueError(f"docker {argv[0]} exited {r.returncode}: {r.stderr[-350:]}")
        return r

    def server():
        data = json.loads(cmd(["info", "--format", "{{json .}}"]).stdout)
        require(data.get("ID"), "Docker did not report a daemon ID")
        return {k: data.get(k) for k in ("ID", "Name", "OperatingSystem", "Architecture", "ServerVersion",
                                         "KernelVersion", "NCPU", "MemTotal", "SecurityOptions")}

    initial = server()
    receipt["server"] = initial
    if args.engine in {"inner", "micropod"}:
        require("rootless" in str(initial["SecurityOptions"]).lower(), "Allocation engine did not report rootless Docker")
    if args.engine == "orbstack":
        require("orbstack" in (str(initial["Name"]) + str(initial["OperatingSystem"])).lower(), "Expected an OrbStack daemon")
    info = json.loads(cmd(["image", "inspect", args.image]).stdout)[0]
    image = info["Id"]
    require(CLASSES.get(initial["Architecture"]) == info["Architecture"], "Image architecture differs from daemon architecture")
    receipt.update(image_id=image, architecture=info["Architecture"], image_digests=info.get("RepoDigests", []))
    if read_parent is None and args.engine != "orbstack":
        read_parent = lambda: fingerprint(Path(BOOT).read_text())
    host_boot = read_parent() if read_parent else None
    cohort = uuid.uuid4().hex
    label = "io.micropod.kernel-bench=" + cohort
    options = ["--pull=never", "--label", label, "--cpus", "1", "--memory", "256m", "--network", "none"]
    owned = []
    try:
        for _ in range(2):
            name = "mp-kernel-" + uuid.uuid4().hex
            owned.append(name)
            cmd(["run", "-d", "--name", name, *options, image, "sleep", "90"])
        probes = []
        for name in owned:
            raw = cmd(["exec", name, "sh", "-ec", "cat " + BOOT + "; readlink /proc/self/ns/pid; "
                       "readlink /proc/self/ns/mnt; cat /sys/fs/cgroup/cpu.max; cat /sys/fs/cgroup/memory.max"]).stdout.splitlines()
            require(len(raw) == 5 and raw[3:] == ["100000 100000", "268435456"], "CPU or memory contract failed: " + repr(raw))
            probes.append((fingerprint(raw[0]), raw[1], raw[2]))
        kernel = probes[0][0]
        require(probes[1][0] == kernel and (host_boot is None or kernel == host_boot), "Kernel identity mismatch")
        require(probes[0][1] != probes[1][1] and probes[0][2] != probes[1][2], "Two live containers shared PID or mount namespaces")
        receipt.update(boot_sha256=kernel, namespaces=[p[1:] for p in probes], resource_contract="1 CPU / 256 MiB",
                       ownership_check="overlapping OrbStack containers" if host_boot is None else "Linux parent and overlapping containers")
    finally:
        for name in owned:
            cmd(["rm", "-f", name], check=False)

    def trial(_):
        token = uuid.uuid4().hex
        name = "mp-kernel-" + token
        script = 'cat "$1"; echo "OUT-$2"; echo "ERR-$2" >&2; exit 23'
        try:
            r = cmd(["run", "--rm", "--name", name, *options, image, "sh", "-c", script, "sh", BOOT, token], check=False)
            lines = r.stdout.splitlines()
            require(r.returncode == 23 and len(lines) == 2 and lines[1] == "OUT-" + token
                    and r.stderr.splitlines() == ["ERR-" + token], "exit code or output streams differed")
            require(fingerprint(lines[0]) == kernel, "container used a different kernel")
        except Exception:
            cmd(["rm", "-f", name], check=False)
            raise

    samples = []
    receipt["batches"] = samples
    for block in range(args.rounds):
        offset = block % len(args.clients)
        for n in args.clients[offset:] + args.clients[:offset]:
            start = time.perf_counter()
            with concurrent.futures.ThreadPoolExecutor(max_workers=n) as pool:
                futures = [pool.submit(trial, i) for i in range(n)]
                errors = [str(exc) for f in futures if (exc := f.exception()) is not None]
            samples.append(dict(round=block+1, clients=n, seconds=round(time.perf_counter()-start, 6),
                                passed=n-len(errors), errors=errors))
    require(not cmd(["ps", "-aq", "--filter", "label=" + label]).stdout.strip(), "Benchmark containers remain")
    require(server()["ID"] == initial["ID"], "Docker daemon identity changed")
    if host_boot:
        require(read_parent() == kernel, "Parent Linux kernel rebooted")
    receipt["p50_seconds"] = {str(n): statistics.median(complete) for n in args.clients
                              if (complete := [s["seconds"] for s in samples if s["clients"] == n and not s["errors"]])}
    require(all(not s["errors"] for s in samples), "Some measured containers failed validation")


def paired(args, receipt):
    require(platform.system() == "Darwin" and platform.machine() == "arm64", "Run the paired test on an Apple Silicon Mac")
    require(args.clock == "client", "Both engines in a pair use the Mac client's clock")
    receipt["hardware"] = {key: subprocess.check_output(["/usr/sbin/sysctl", "-n", key], text=True).strip()
                           for key in ("hw.model", "hw.ncpu", "hw.memsize")}
    require(not receipt["hardware"]["hw.model"].startswith("VirtualMac"), "Use a physical Mac for this pairing")
    rows = []
    receipt["blocks"] = rows
    identities = {}
    for block in range(args.rounds):
        order = ["micropod", "orbstack"]
        if block % 2:
            order.reverse()
        for engine in order:
            current = argparse.Namespace(**vars(args))
            current.engine, current.rounds = engine, 1
            offset = block % len(args.clients)
            current.clients = args.clients[offset:] + args.clients[:offset]
            row = dict(engine=engine, block=block + 1)
            rows.append(row)
            if engine == "micropod":
                in_allocation(current, row)
            else:
                current.socket = args.orbstack_socket
                measure(current, row)
            identity = (row["boot_sha256"], row["server"]["ID"], row["image_id"])
            require(identity == identities.setdefault(engine, identity), f"{engine} kernel, daemon or image changed")
            row["passed"] = True
    left, right = rows[:2]
    require(left["architecture"] == right["architecture"] == "arm64" and left["image_id"] == right["image_id"],
            "The two engines did not use the same native ARM64 image")
    require(left["boot_sha256"] != right["boot_sha256"] and left["server"]["ID"] != right["server"]["ID"],
            "Both clients reached the same Linux kernel or daemon")
    receipt["p50_seconds"] = {
        engine: {str(n): statistics.median(s["seconds"] for row in rows if row["engine"] == engine
                                          for s in row["batches"] if s["clients"] == n) for n in args.clients}
        for engine in identities
    }
    receipt["engine_resources"] = {r["engine"]: {key: r["server"][key] for key in ("NCPU", "MemTotal")}
                                   for r in (left, right)}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--engine", choices=["rig-pair", "micropod", "linux-docker", "orbstack", "inner"], required=True)
    p.add_argument("--socket", required=True, help="Docker Unix socket in the measured environment")
    p.add_argument("--clock", choices=["client", "guest"], default="client",
                   help="Time from the invoking client, or inside an owned Micropod allocation")
    p.add_argument("--orbstack-socket", help="Mac-local OrbStack socket for an interleaved physical rig comparison")
    p.add_argument("--api", help="Local Micropod Connect endpoint")
    p.add_argument("--allocation", help="ID of an existing Micropod rootless Docker sandbox")
    p.add_argument("--image", default="alpine:3.20", help="Already-pulled native Alpine image or digest")
    p.add_argument("--clients", nargs="+", type=int, default=[1, 4, 8, 16])
    p.add_argument("--rounds", type=int, default=5)
    p.add_argument("--json", type=Path)
    args = p.parse_args()
    if not (1 <= args.rounds <= 50 and all(1 <= n <= 64 for n in args.clients) and len(set(args.clients)) == len(args.clients)):
        p.error("Rounds must be 1..50 and distinct client levels 1..64")
    if args.engine in {"rig-pair", "micropod"} and not (args.api and args.allocation):
        p.error("Micropod requires --api and --allocation")
    if args.engine == "rig-pair" and not args.orbstack_socket:
        p.error("A physical pair requires --orbstack-socket")
    if args.clock == "guest" and args.engine != "micropod":
        p.error("The guest clock is available for an owned Micropod allocation")
    record = dict(profile=args.engine, measured_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                  system=platform.system(), arch=platform.machine(), clock=args.clock, image=args.image, rounds=args.rounds)
    try:
        if args.engine == "rig-pair":
            paired(args, record)
        elif args.engine == "micropod":
            in_allocation(args, record)
        else:
            measure(args, record)
        record["passed"] = True
    except Exception as exc:
        record.update(passed=False, error=str(exc))
    if args.json:
        args.json.write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps(record, separators=(",", ":")))
    # The outer Micropod client needs a failed inner receipt as well.
    return 0 if record["passed"] or args.engine == "inner" else 1


if __name__ == "__main__":
    sys.exit(main())
