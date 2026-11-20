#!/usr/bin/env python3
"""Time containers on a verified running kernel, including paired runs from one physical Mac."""

import argparse
import concurrent.futures
import hashlib
from functools import lru_cache
import http.client
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import re
import socket
import statistics
import subprocess
import sys
import tarfile
import tempfile
import time
from urllib.parse import urlsplit
import uuid


WORKLOAD = "docker-run-rm-kernel-streams-v1"
MAC_PEERS = ("orbstack", "docker-desktop", "colima")
# The original two ARM references precede the workload field. Accept only their published bytes.
LEGACY_UBUNTU = {
    "4633e3b775b54fd328ea6ff24bd1573f830bcf37291a9258341acf6b444d1fdd",
    "6d042e5ecdc4bf5d52e090d26df16a688f9fd2285e1b060a6418db8a983cbc63",
}
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


def rpc(endpoint, method, payload, service="ContainerService"):
    url = urlsplit(endpoint)
    if url.scheme == "unix" and not url.netloc and url.path.startswith("/"):
        conn = LocalConnection(url.path)
    elif url.scheme == "http" and url.hostname in {"127.0.0.1", "::1", "localhost"} and url.path in {"", "/"}:
        conn = http.client.HTTPConnection(url.hostname, url.port or 80, timeout=600)
    else:
        raise ValueError("Use an explicit local Micropod Connect HTTP or Unix endpoint")
    headers = {"Content-Type": "application/json", "Connect-Protocol-Version": "1"}
    authorization = os.environ.get("MICROPOD_BENCH_AUTHORIZATION")
    if authorization:
        require("\r" not in authorization and "\n" not in authorization, "Invalid Micropod authorization header")
        headers["Authorization"] = authorization
    try:
        conn.request("POST", f"/micropod.v1.{service}/{method}", json.dumps(payload), headers)
        response = conn.getresponse()
        body = response.read()
        if response.status != 200:
            raise ValueError(f"Micropod {method} returned HTTP {response.status}")
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

    status = rpc(args.api, "Ping", {}, service="SystemService")
    receipt["micropod_server"] = {k: status.get(k) for k in ("micropodVersion", "sourceRevision", "protocolVersion",
                                                               "apiServerVersion", "runtimeBackend", "defaultRuntime")}
    if args.expected_revision:
        require(status.get("sourceRevision", "").lower() == args.expected_revision.lower(),
                "The live Micropod server does not report the requested source revision")
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


@lru_cache(maxsize=32)
def image_config_digest(socket_path, image_id, architecture):
    # Classic dockerd returns the config digest as Id. The containerd store can return an
    # index digest there instead. Hash the actual native config from each local image once.
    with tempfile.TemporaryDirectory(prefix="micropod-image-") as temp:
        archive = str(Path(temp) / "image.tar")
        subprocess.run(["docker", "--host", "unix://" + socket_path, "image", "save", "-o", archive, image_id],
                       capture_output=True, check=True, timeout=180)
        with tarfile.open(archive) as tar:
            candidates = set()
            for entry in json.load(tar.extractfile("manifest.json")):
                data = tar.extractfile(entry["Config"]).read()
                config = json.loads(data)
                if config.get("architecture") == architecture and config.get("os") == "linux":
                    candidates.add("sha256:" + hashlib.sha256(data).hexdigest())
            require(len(candidates) == 1, "Expected one native OCI image config")
            return candidates.pop()


def measure(args, receipt, runner=None, read_parent=None):
    require(args.socket.startswith("/"), "The Docker socket must be an absolute path")
    docker = ["docker", "--host", "unix://" + args.socket]
    worker_cli = args.worker_cli if args.engine == "micropod-worker" else None
    receipt["timed_client"] = "micropod ci run" if worker_cli else "docker run --rm"
    def cmd(argv, check=True):
        if worker_cli and argv[:2] == ["run", "--rm"]:
            command = [worker_cli, "ci", "run", *argv[2:]]
        else:
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
    if args.engine == "docker-desktop":
        require("docker desktop" in str(initial["OperatingSystem"]).lower(), "Expected the Docker Desktop daemon")
    if args.engine == "colima":
        require(re.fullmatch(r"colima(?:-[a-zA-Z0-9._-]+)?", str(initial["Name"])), "Expected a Colima VM hostname")
    if args.engine in {"orbstack", "docker-desktop"}:
        app_name = "OrbStack" if args.engine == "orbstack" else "Docker"
        bundle = Path(f"/Applications/{app_name}.app/Contents/Info.plist")
        if bundle.is_file():
            with bundle.open("rb") as file:
                app = plistlib.load(file)
            receipt["mac_app_bundle"] = {k: app.get(k) for k in ("CFBundleShortVersionString", "CFBundleVersion")}
    if args.engine == "orbstack":
        require("orbstack" in (str(initial["Name"]) + str(initial["OperatingSystem"])).lower(), "Expected an OrbStack daemon")
    info = json.loads(cmd(["image", "inspect", args.image]).stdout)[0]
    image = info["Id"]
    require(CLASSES.get(initial["Architecture"]) == info["Architecture"], "Image architecture differs from daemon architecture")
    receipt.update(image_id=image, architecture=info["Architecture"], image_digests=info.get("RepoDigests", []))
    canonical = getattr(args, "worker_cli", None) or getattr(args, "canonical_images", False)
    if canonical:
        receipt.update(local_image_id=image, image_id=image_config_digest(args.socket, image, info["Architecture"]))
    if read_parent is None and args.engine not in MAC_PEERS:
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
                       ownership_check=f"overlapping {args.engine} containers" if host_boot is None else "Linux parent and overlapping containers")
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
                    and r.stderr.splitlines() == ["ERR-" + token],
                    f"expected exit 23 and one token per stream, got exit {r.returncode}, "
                    f"stdout={r.stdout[:220]!r}, stderr={r.stderr[:430]!r}")
            require(fingerprint(lines[0]) == kernel, "container used a different kernel")
        except Exception as cause:
            try:
                cmd(["rm", "-f", name], check=False)
            except (OSError, subprocess.TimeoutExpired) as cleanup:
                raise RuntimeError(f"{cause}; cleanup of {name} also failed: {cleanup}") from cause
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
            if args.engine != "inner":
                print(f"{args.engine} block {receipt.get('block', block + 1)} clients {n}: {n-len(errors)}/{n} "
                      f"in {samples[-1]['seconds']:.3f}s", file=sys.stderr, flush=True)
    receipt["p50_seconds"] = {str(n): statistics.median(complete) for n in args.clients
                              if (complete := [s["seconds"] for s in samples if s["clients"] == n and not s["errors"]])}
    remaining = cmd(["ps", "-aq", "--no-trunc", "--filter", "label=" + label]).stdout.split()
    if remaining:
        receipt["containers_remaining_at_verification"] = len(remaining)
        require(all(re.fullmatch(r"[0-9a-f]{64}", cid) for cid in remaining), "Unexpected Docker container ID")
        cmd(["rm", "-f", *remaining], check=False)
        receipt["containers_remaining_after_cleanup"] = len(cmd(["ps", "-aq", "--filter", "label=" + label]).stdout.split())
        raise ValueError("Benchmark containers remained after auto-removal")
    if args.package_image:
        from guest_cache_workload import measure_packages
        receipt["package_caches"] = {}
        measure_packages(cmd, args.package_image, info["Architecture"], kernel, fingerprint, args.clients, args.rounds,
                         receipt["package_caches"], warm_bytecode=getattr(args, "warm_bytecode", False))
        if canonical:
            packages = receipt["package_caches"]
            local_id = packages["image_id"]
            packages.update(local_image_id=local_id, image_id=image_config_digest(args.socket, local_id, info["Architecture"]))
    require(server()["ID"] == initial["ID"], "Docker daemon identity changed")
    if host_boot:
        require(read_parent() == kernel, "Parent Linux kernel rebooted")
    require(all(not s["errors"] for s in samples), "Some measured containers failed validation")


def reference_times(files, sample, clients, rounds):
    references = []
    for path in files:
        payload = path.read_bytes()
        ref = json.loads(payload)
        require(ref.get("workload") == WORKLOAD or hashlib.sha256(payload).hexdigest() in LEGACY_UBUNTU,
                f"{path.name} has an unknown workload")
        require(ref.get("profile") == "linux-docker" and ref.get("passed") is True and ref.get("system") == "Linux"
                and "ubuntu" in ref["server"]["OperatingSystem"].lower() and ref.get("clock", "client") == "client",
                f"{path.name} is not a completed Ubuntu client-clock reference")
        require(ref["architecture"] == sample["architecture"] == "arm64" and ref["image_id"] == sample["image_id"]
                and set(ref["image_digests"]).intersection(sample["image_digests"])
                and ref["resource_contract"] == sample["resource_contract"] and ref["rounds"] == rounds,
                f"{path.name} has different resources per container, image, architecture or repetitions")
        medians = {}
        for n in clients:
            batches = [b for b in ref["batches"] if b["clients"] == n]
            require(len(batches) == rounds and {b["round"] for b in batches} == set(range(1, rounds + 1))
                    and all(not b["errors"] and b["passed"] == n and math.isfinite(b["seconds"]) and b["seconds"] > 0
                            for b in batches), f"{path.name} lacks a complete series at {n} clients")
            medians[str(n)] = statistics.median(b["seconds"] for b in batches)
        require(all(r["boot_sha256"] != ref["boot_sha256"] for r in references),
                "Supply independently booted Ubuntu references")
        reference = dict(file=path.name, boot_sha256=ref["boot_sha256"], daemon=ref["server"]["ID"],
                         vcpus=ref["server"]["NCPU"], memory_bytes=ref["server"]["MemTotal"], median_seconds=medians)
        reference["same_reported_daemon_as"] = [r["file"] for r in references if r["daemon"] == reference["daemon"]]
        packages = ref.get("package_caches")
        if packages and "package_caches" in sample:
            require(packages.get("passed") is True and len(packages["blocks"]) == rounds and
                    all(packages[k] == sample["package_caches"][k] for k in
                        ("workload", "image_id", "script_sha256", "architecture", "resource_contract")),
                    f"{path.name} has a different package workload or toolchain")
            values = {t: {} for t in ("npm", "go")}
            for block in packages["blocks"]:
                require(block.get("same_payload_inodes") and block.get("empty_offline_controls"),
                        f"{path.name} did not validate offline cache reuse")
                for t in values:
                    for n in clients:
                        batches = [b for b in block["batches"] if b["tool"] == t and b["clients"] == n]
                        require(len(batches) == 1 and batches[0]["passed"] == n and not batches[0]["errors"]
                                and math.isfinite(batches[0]["seconds"]) and batches[0]["seconds"] > 0,
                                f"{path.name} has an incomplete {t} batch")
                        values[t].setdefault(str(n), []).append(batches[0]["seconds"])
            reference["package_seconds"] = {t: {n: statistics.median(times) for n, times in groups.items()}
                                            for t, groups in values.items()}
        references.append(reference)
    return references


def on_worker(args, row):
    binary = Path(args.worker_cli).resolve(strict=True)
    def status():
        return json.loads(subprocess.check_output([str(binary), "ci", "status"], text=True, timeout=10))
    before = status()
    require(before["endpoint"].startswith("unix:///"), "Expected a local Micropod socket")
    args.socket = before["endpoint"][7:]
    row["micropod_worker"] = dict(worker=before["worker"], instance=before["instance"],
                                  executable_sha256=hashlib.sha256(binary.read_bytes()).hexdigest())
    measure(args, row, read_parent=lambda: fingerprint(status()["boot"]))
    after = status()
    require(before == after and before["daemon"] == row["server"]["ID"], "Micropod worker changed during the block")


def paired(args, receipt):
    require(platform.system() == "Darwin" and platform.machine() == "arm64", "Run on an Apple Silicon Mac")
    require(args.clock == "client", "All engines use the requesting Mac's clock")
    sockets = {"orbstack": args.orbstack_socket, "docker-desktop": args.desktop_socket, "colima": args.colima_socket}
    primary = "micropod-worker" if args.worker_cli else "micropod"
    engines = [primary, *[name for name, path in sockets.items() if path]]
    receipt.update(macos=platform.mac_ver()[0], engines=engines, workload=WORKLOAD)
    hardware = json.loads(subprocess.check_output(
        ["/usr/sbin/system_profiler", "SPHardwareDataType", "-json"], text=True, timeout=30))["SPHardwareDataType"][0]
    receipt["hardware"] = {key: hardware.get(key) for key in
                           ("machine_model", "chip_type", "number_processors", "physical_memory")}
    require(re.match(r"^(?:Mac|iMac)", hardware.get("machine_model", "")), "Use a physical Mac for this pairing")
    rows = []
    receipt["blocks"] = rows
    identities = {}
    for block in range(args.rounds):
        offset = block % len(engines)
        order = engines[offset:] + engines[:offset]
        for engine in order:
            current = argparse.Namespace(**vars(args))
            current.engine, current.rounds = engine, 1
            offset = block % len(args.clients)
            current.clients = args.clients[offset:] + args.clients[:offset]
            row = dict(engine=engine, block=block + 1, host_load_before=os.getloadavg(),
                       started_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
            rows.append(row)
            if engine == "micropod-worker":
                on_worker(current, row)
            elif engine == "micropod":
                in_allocation(current, row)
            else:
                current.socket = sockets[engine]
                measure(current, row)
            identity = (row["boot_sha256"], row["server"]["ID"], row["image_id"], row["server"]["NCPU"],
                        row.get("micropod_server", {}).get("sourceRevision"))
            require(identity == identities.setdefault(engine, identity), f"{engine} kernel, daemon, build, CPU count or image changed")
            row["host_load_after"] = os.getloadavg()
            row["passed"] = True
    first = rows[:len(engines)]
    require(all(row["architecture"] == "arm64" and row["image_id"] == first[0]["image_id"] for row in first),
            "All engines must use the same native ARM64 image")
    require(len({r["boot_sha256"] for r in first}) == len(engines)
            and len({r["server"]["ID"] for r in first}) == len(engines),
            "Two clients reached the same Linux kernel or Docker daemon")
    receipt["p50_seconds"] = {
        engine: {str(n): statistics.median(s["seconds"] for row in rows if row["engine"] == engine
                                          for s in row["batches"] if s["clients"] == n) for n in args.clients}
        for engine in identities
    }
    receipt["engine_resources"] = {r["engine"]: {key: r["server"][key] for key in ("NCPU", "MemTotal")}
                                   for r in first}
    if args.worker_cli and args.orbstack_socket:
        base, peer = receipt["engine_resources"][primary], receipt["engine_resources"]["orbstack"]
        require(base["NCPU"] == peer["NCPU"] and abs(base["MemTotal"] / peer["MemTotal"] - 1) <= .05,
                "Worker and OrbStack need equal vCPU counts and RAM within 5%")
        receipt["worker_over_orbstack"] = {n: round(t / receipt["p50_seconds"]["orbstack"][n], 4)
                                          for n, t in receipt["p50_seconds"][primary].items()}
    if args.package_image:
        package_ids = {(r["package_caches"]["image_id"], r["package_caches"]["script_sha256"]) for r in rows}
        require(len(package_ids) == 1, "Package toolchain or workload differed between engines")
        receipt["package_median_seconds"] = {
            engine: {tool: {str(n): statistics.median(b["seconds"] for r in rows if r["engine"] == engine
                           for block in r["package_caches"]["blocks"] for b in block["batches"]
                           if b["clients"] == n and b["tool"] == tool) for n in args.clients} for tool in ("npm", "go")}
            for engine in engines}
    if args.ubuntu_reference:
        refs = reference_times(args.ubuntu_reference, first[0], args.clients, args.rounds)
        receipt["ubuntu_references"] = refs
        if args.package_image:
            receipt["package_ratio_vs_ubuntu"] = {
                engine: {tool: {n: {r["file"]: round(seconds / r["package_seconds"][tool][n], 4)
                                    for r in refs if "package_seconds" in r} for n, seconds in times.items()}
                         for tool, times in products.items()} for engine, products in receipt["package_median_seconds"].items()}
        receipt["vs_ubuntu"] = {engine: {
            n: {r["file"]: {"ratio": round(seconds / r["median_seconds"][n], 4),
                            "gap_ms": round((seconds - r["median_seconds"][n]) * 1000, 3),
                            "same_daemon_vcpus": receipt["engine_resources"][engine]["NCPU"] == r["vcpus"]}
                for r in refs} for n, seconds in medians.items()} for engine, medians in receipt["p50_seconds"].items()}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--engine", choices=["rig-matrix", "rig-pair", "micropod-worker", "micropod", "linux-docker", *MAC_PEERS, "inner"], required=True)
    p.add_argument("--socket", required=True, help="Docker Unix socket in the measured environment")
    p.add_argument("--clock", choices=["client", "guest"], default="client",
                   help="Time from the invoking client, or inside an owned Micropod allocation")
    p.add_argument("--worker-cli", help="Compare an active Micropod CI worker on its own native socket")
    p.add_argument("--orbstack-socket", help="Mac-local OrbStack socket for an interleaved physical rig comparison")
    p.add_argument("--desktop-socket", help="Local Docker Desktop socket for the physical rig matrix")
    p.add_argument("--colima-socket", help="Local Colima socket for the physical rig matrix")
    p.add_argument("--ubuntu-reference", type=Path, action="append", default=[],
                   help="Matched warm ARM64 Ubuntu receipt, repeat for independent allocations")
    p.add_argument("--expected-revision", help="Require the selected Micropod API server to report this full commit SHA")
    p.add_argument("--api", help="Local Micropod Connect endpoint")
    p.add_argument("--allocation", help="ID of an existing Micropod rootless Docker sandbox")
    p.add_argument("--image", default="alpine:3.20", help="Already-pulled native Alpine image or digest")
    p.add_argument("--package-image", help="Preloaded native OCI image with Go, npm, Node and Python for offline container jobs")
    p.add_argument("--warm-bytecode", action="store_true", help="Prime and retain the Python harness bytecode on both engines")
    p.add_argument("--clients", nargs="+", type=int, default=[1, 4, 8, 16])
    p.add_argument("--rounds", type=int, default=5)
    p.add_argument("--json", type=Path)
    args = p.parse_args()
    if args.warm_bytecode and (not args.package_image or args.engine not in {"rig-pair", "rig-matrix", "micropod-worker", "orbstack", "linux-docker"}):
        p.error("--warm-bytecode requires a local package workload")
    if not (1 <= args.rounds <= 50 and all(1 <= n <= 64 for n in args.clients) and len(set(args.clients)) == len(args.clients)):
        p.error("Rounds must be 1..50 and distinct client levels 1..64")
    if args.expected_revision and (args.engine not in {"rig-pair", "rig-matrix", "micropod"}
                                   or not re.fullmatch(r"[0-9a-fA-F]{40}", args.expected_revision)):
        p.error("Use --expected-revision with a Micropod profile and a full commit SHA")
    if args.engine == "micropod-worker" and (not args.worker_cli or any((args.orbstack_socket, args.desktop_socket, args.colima_socket))):
        p.error("A standalone worker requires --worker-cli and its own socket")
    if args.worker_cli and (args.engine not in {"rig-pair", "rig-matrix", "micropod-worker"} or args.api or args.allocation or args.expected_revision):
        p.error("Select a worker CLI or a qualified allocation for a rig comparison")
    if args.engine in {"rig-pair", "rig-matrix", "micropod"} and not args.worker_cli and not (args.api and args.allocation):
        p.error("Micropod requires --api and --allocation")
    if args.engine == "rig-pair" and not args.orbstack_socket:
        p.error("A physical pair requires --orbstack-socket")
    if args.engine == "rig-matrix" and not any((args.orbstack_socket, args.desktop_socket, args.colima_socket)):
        p.error("Supply at least one peer socket for the Apple Silicon matrix")
    if args.ubuntu_reference and args.engine not in {"rig-pair", "rig-matrix", "micropod-worker"}:
        p.error("Use Ubuntu references with the physical rig matrix")
    if args.package_image and args.clock == "guest":
        p.error("Package workspaces use the client clock")
    if args.clock == "guest" and args.engine != "micropod":
        p.error("The guest clock is available for an owned Micropod allocation")
    record = dict(profile=args.engine, workload=WORKLOAD, measured_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                  system=platform.system(), arch=platform.machine(), clock=args.clock, image=args.image, rounds=args.rounds)
    try:
        if args.engine in {"rig-pair", "rig-matrix", "micropod-worker"}:
            paired(args, record)
        elif args.engine == "micropod":
            in_allocation(args, record)
        else:
            measure(args, record)
        record["passed"] = True
    except Exception as exc:
        record.update(passed=False, error=str(exc))
    if args.json or args.engine in {"rig-pair", "rig-matrix"}:
        data = (json.dumps(record, indent=2) + "\n").encode()
        if args.json:
            args.json.write_bytes(data)
        if args.engine in {"rig-pair", "rig-matrix"}:
            from ci_benchmark_store import DEFAULT_DB, store_receipt
            store_receipt(DEFAULT_DB, "apple-pair", data)
    print(json.dumps(record, separators=(",", ":")))
    # The outer Micropod client needs a failed inner receipt as well.
    return 0 if record["passed"] or args.engine == "inner" else 1


if __name__ == "__main__":
    sys.exit(main())
