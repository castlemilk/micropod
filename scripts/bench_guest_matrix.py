#!/usr/bin/env python3
"""Measure and validate short-lived guests on the engines running on one host."""
import argparse
import concurrent.futures
import hashlib
import json
import os
import platform
import plistlib
import random
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

MIB = 1 << 20
IMAGE = "alpine:3.20"
HOME = Path.home()
SOCKETS = {
    "docker-engine": Path("/var/run/docker.sock"),
    "micropod-shim": HOME / ".micropod/docker.sock",
    "docker-desktop": HOME / ".docker/run/docker.sock",
    "orbstack": HOME / ".orbstack/run/docker.sock",
    "colima": HOME / ".colima/default/docker.sock",
}
MAC_ENGINES = ["micropod-sandbox", "apple-container", "micropod-shim", "docker-desktop", "orbstack", "colima"]
LINUX_ENGINES = ["docker-engine", "podman"]
CASES = ("lifecycle", "gzip-8m", "bind-read-write")
ZERO_HASH = hashlib.sha256(bytes(8 * MIB)).hexdigest()
BIND_DATA = hashlib.shake_256(b"micropod guest matrix").digest(MIB)
BIND_HASH = hashlib.sha256(BIND_DATA).hexdigest()
FINGERPRINT = ('printf "GUEST=%s/%s/%s\\n" "$(uname -m)" "$(cat /etc/alpine-release)" '
               '"$(sha256sum /bin/busybox | cut -d\' \' -f1)"')


def call(argv, cwd, timeout=90):
    return subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, cwd=cwd, timeout=timeout,
                          text=True, errors="replace")


def atomic_save(path, data):
    staged = path.with_suffix(path.suffix + ".tmp")
    staged.write_text(json.dumps(data, indent=2) + "\n")
    staged.replace(path)


def guest(engine, work, image, script, bind=None):
    tag = "mp-bench-" + uuid.uuid4().hex
    micropod = os.environ.get("MICROPOD") or shutil.which("micropod") or "/Applications/Micropod.app/Contents/MacOS/micropod-cli"
    mounts = ["-v", str(bind) + ":/fixture"] if bind else []
    clean = None
    if engine == "micropod-sandbox":
        argv = [micropod, "sandbox", "run", "-c", "1", "-m", "256", "--timeout", "60", *mounts,
                image, "--"]
    elif engine == "apple-container":
        argv = ["container", "run", "--rm", "--name", tag, "-c", "1", "-m", "256M", *mounts, image]
        clean = ["container", "delete", "--force", tag]
    else:
        docker = ["podman"] if engine == "podman" else ["docker", "--host", "unix://" + str(SOCKETS[engine])]
        argv = [*docker, "run", "--rm", "--name", tag, "--cpus", "1", "--memory", "256m",
                "--network", "none", *mounts, image]
        clean = [*docker, "rm", "--force", tag]
    start = time.perf_counter()
    try:
        result = call([*argv, "sh", "-ec", script], work)
    except subprocess.TimeoutExpired:
        if clean:
            call(clean, work, 15)
        raise
    elapsed = time.perf_counter() - start
    if clean and result.returncode not in (0, 23):
        call(clean, work, 15)
    return result, elapsed


def error_text(result):
    detail = (result.stderr + "\n" + result.stdout).strip().replace(str(HOME), "~")
    return f"exit {result.returncode}: {detail[-700:]}"


def server_identity(engine, work):
    if engine == "podman":
        r = call(["podman", "info", "--format", "json"], work, 15)
        if r.returncode:
            raise ValueError(error_text(r))
        info = json.loads(r.stdout)
        host = info["host"]
        return {"engine": "podman", "version": info["version"].get("Version"), "arch": host.get("arch"),
                "runtime": host.get("ociRuntime", {}).get("name"), "cgroup": host.get("cgroupVersion"),
                "rootless": host.get("security", {}).get("rootless")}
    docker = ["docker", "--host", "unix://" + str(SOCKETS[engine])]
    r = call([*docker, "info", "--format", "{{json .}}"], work, 12)
    if r.returncode:
        raise ValueError(error_text(r))
    info = json.loads(r.stdout)
    keys = ("Name", "OperatingSystem", "ServerVersion", "Architecture", "NCPU", "MemTotal", "KernelVersion")
    identity = {key: info.get(key) for key in keys}
    labels = (str(identity["OperatingSystem"]) + " " + str(identity["Name"])).lower()
    if engine == "docker-engine":
        ver = call([*docker, "version", "--format", "{{json .Server}}"], work, 12)
        if ver.returncode:
            raise ValueError(error_text(ver))
        vendor = json.loads(ver.stdout).get("Platform", {}).get("Name", "")
        if "docker engine" not in vendor.lower():
            raise ValueError(f"unexpected Docker Engine server: {vendor}")
        identity["platform"] = vendor
        return identity
    tokens = {"micropod-shim": ("micropod", "apple container"), "docker-desktop": ("docker desktop", "docker-desktop"),
              "orbstack": ("orbstack",), "colima": ("colima",)}
    if not any(t in labels for t in tokens[engine]):
        raise ValueError(f"unexpected server for {engine}: {labels}")
    return identity


def host_metadata(work):
    data = {}
    for name, app in [("micropod", "Micropod"), ("docker-desktop", "Docker"), ("orbstack", "OrbStack")]:
        path = Path("/Applications") / (app + ".app") / "Contents/Info.plist"
        if path.is_file():
            with path.open("rb") as f:
                plist = plistlib.load(f)
            data[name] = {"version": plist.get("CFBundleShortVersionString"), "build": plist.get("CFBundleVersion")}
    for name, argv in [("apple-container", ["container", "--version"]), ("docker-client", ["docker", "--version"]),
                       ("colima", ["colima", "version"])]:
        if shutil.which(argv[0]):
            r = call(argv, work, 10)
            if r.returncode == 0 and r.stdout.strip():
                data[name] = r.stdout.strip().splitlines()[0]
    if platform.system() == "Darwin":
        profile = call(["system_profiler", "SPHardwareDataType", "-json"], work, 15)
        if profile.returncode == 0:
            hw = json.loads(profile.stdout)["SPHardwareDataType"][0]
            data["hardware"] = {k: hw.get(k) for k in ("machine_model", "chip_type", "physical_memory")}
    return data


def identify(engine, work, image):
    r, _ = guest(engine, work, image, FINGERPRINT)
    matches = re.findall(r"^GUEST=([^\s]+/[^\s]+/[a-f0-9]{64})\s*$", r.stdout, re.M)
    if r.returncode != 0 or len(matches) != 1:
        raise ValueError(error_text(r))
    return matches[0]


def trial(engine, case, work, image):
    tag = uuid.uuid4().hex
    with tempfile.TemporaryDirectory(dir=work) as tmp:
        folder = Path(tmp)
        script = ""
        if case == "gzip-8m":
            script = ("dd if=/dev/zero of=/tmp/mp.input bs=1048576 count=8 2>/dev/null; "
                      "gzip -c /tmp/mp.input >/tmp/mp.gz; gzip -dc /tmp/mp.gz >/tmp/mp.output; "
                      f'test "$(sha256sum /tmp/mp.output | cut -d\' \' -f1)" = {ZERO_HASH}; ')
        elif case == "bind-read-write":
            (folder / "input").write_bytes(BIND_DATA)
            script = (f'test "$(sha256sum /fixture/input | cut -d\' \' -f1)" = {BIND_HASH}; '
                      f'printf "{tag}" > /fixture/result; ')
        script += f'echo OUT-{tag}; echo ERR-{tag} >&2; exit 23'
        result, elapsed = guest(engine, work, image, script, folder if case == "bind-read-write" else None)
        stdout, stderr = result.stdout.splitlines(), result.stderr.splitlines()
        if (result.returncode != 23 or (stdout + stderr).count(f"OUT-{tag}") != 1
                or (stdout + stderr).count(f"ERR-{tag}") != 1):
            raise ValueError(error_text(result))
        if case == "bind-read-write" and (folder / "result").read_bytes() != tag.encode():
            raise ValueError("guest write did not reach its host bind")
        return {"seconds": round(elapsed, 6), "separate_streams": f"OUT-{tag}" in stdout and f"ERR-{tag}" in stderr}


def clean_failure(exc):
    return f"{type(exc).__name__}: {exc}".replace(str(HOME), "~")[:900]


def batch(engine, case, clients, work, image):
    started = time.perf_counter()
    outcomes = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=clients) as pool:
        futures = [pool.submit(trial, engine, case, work, image) for _ in range(clients)]
        for future in futures:
            try:
                outcomes.append(future.result())
            except (OSError, ValueError, subprocess.SubprocessError) as exc:
                outcomes.append({"error": clean_failure(exc)})
    return {"engine": engine, "case": case, "clients": clients, "wall_s": round(time.perf_counter()-started, 6),
            "passed": sum("error" not in x for x in outcomes), "jobs": outcomes}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", required=True, type=Path)
    parser.add_argument("--engines", nargs="+", choices=MAC_ENGINES + LINUX_ENGINES,
                        default=MAC_ENGINES if platform.system() == "Darwin" else LINUX_ENGINES)
    parser.add_argument("--scale-cases", nargs="+", choices=CASES, default=list(CASES),
                        help="cases to run at all client counts; other cases run at one client")
    parser.add_argument("--clients", type=int, nargs="+", default=[1, 4, 8, 16])
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--image", default=IMAGE, help="Alpine tag or digest, identical for all engines")
    parser.add_argument("--seed", type=int, default=20261119)
    args = parser.parse_args()
    if not (1 <= args.rounds <= 50 and all(1 <= n <= 64 for n in args.clients)):
        parser.error("rounds must be 1..50 and clients 1..64")
    args.json.parent.mkdir(parents=True, exist_ok=True)
    rng = random.Random(args.seed)
    data = dict(scale_cases=args.scale_cases, host_os=platform.system(), kernel=platform.release(),
                started_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), macos=platform.mac_ver()[0],
                arch=platform.machine(), cpus=os.cpu_count(), image=args.image, resource_request="1 vCPU, 256 MiB",
                seed=args.seed, rounds=args.rounds, clients=args.clients, engines={}, warmups=[], blocks=[], summary=[])
    ready = {}
    args.engines = list(dict.fromkeys(args.engines))
    args.clients = list(dict.fromkeys(args.clients))
    with tempfile.TemporaryDirectory(prefix="mp-guest-matrix-") as tmp:
        work = Path(tmp).resolve()
        data["software"] = host_metadata(work)
        data["start_load"] = list(os.getloadavg())
        data["network"] = "offline fixture; sandbox, Docker and Podman disable networking, Apple container uses its default"
        data["guest_groups"] = {}
        for engine in args.engines:
            try:
                if engine in SOCKETS and not SOCKETS[engine].is_socket():
                    raise FileNotFoundError(f"{engine} socket absent")
                server = server_identity(engine, work) if engine in SOCKETS or engine == "podman" else None
                identity = identify(engine, work, args.image)
                data["engines"][engine] = {"guest": identity, "server": server}
                data["guest_groups"].setdefault(identity, []).append(engine)
                ready[engine] = []
            except (OSError, ValueError, subprocess.SubprocessError) as exc:
                data["engines"][engine] = {"unavailable": clean_failure(exc)}
            print(engine, data["engines"][engine], flush=True)
            atomic_save(args.json, data)
        for case in CASES:
            for engine in ready:
                row = batch(engine, case, 1, work, args.image)
                data["warmups"].append(row)
                if row["passed"] == 1:
                    ready[engine].append(case)
                atomic_save(args.json, data)
            for clients in (args.clients if case in args.scale_cases else [1]):
                for block in range(1, args.rounds + 1):
                    order = [e for e in ready if case in ready[e]]
                    rng.shuffle(order)
                    for engine in order:
                        row = batch(engine, case, clients, work, args.image)
                        row["load_after"] = list(os.getloadavg())
                        row["block"] = block
                        data["blocks"].append(row)
                        print(f'{engine} {case} x{clients} {block}/{args.rounds}: {row["passed"]}/{clients} in {row["wall_s"]:.3f}s', flush=True)
                        atomic_save(args.json, data)
    for engine, cases in ready.items():
        for case in cases:
            for n in (args.clients if case in args.scale_cases else [1]):
                rows = [r for r in data["blocks"] if (r["engine"], r["case"], r["clients"]) == (engine, case, n)]
                success = [r["wall_s"] for r in rows if r["passed"] == n]
                s = dict(engine=engine, case=case, clients=n, passed_blocks=len(success), total_blocks=len(rows))
                if len(success) == args.rounds:
                    median = statistics.median(success)
                    s.update(p50_wall_s=round(median, 6), min_wall_s=min(success), max_wall_s=max(success),
                             jobs_per_second=round(n / median, 3))
                data["summary"].append(s)
    data["comparability"] = "Compare rows within one guest_groups fingerprint; includes BusyBox digest, Alpine release and guest architecture."
    atomic_save(args.json, data)
    print(f"Receipt: {args.json.resolve()}")
    return 0 if ready and all(r["passed"] == r["clients"] for r in data["blocks"] + data["warmups"]) else 1


if __name__ == "__main__":
    sys.exit(main())
