#!/usr/bin/env python3
"""Compare two stock Docker endpoints and the warm Micropod ci run path on one Mac."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import ctypes
from datetime import datetime, timezone
import hashlib
import itertools
import json
import os
from pathlib import Path
import platform
import random
import shutil
import statistics
import subprocess
import sys
import threading
import time
import uuid

from bench_live_kernel import exported_config_digest, require


IMAGE = "alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc"
CONFIG = "sha256:ab3fe4defd29ba6231229a4d41440ac8bde8218e85870e53876277faa24b35c4"
MIC, ORB, NATIVE = ARMS = ("micropod-stock", "orbstack-stock", "micropod-ci-run")
WIDTHS = (1, 16)
FLAGS = ("--platform", "linux/arm64", "--pull=never", "--network", "none", "--cpus", "1", "--memory", "256m")
BOOT = "/proc/sys/kernel/random/boot_id"
FIXTURE = """set -eu
token=$1
read -r boot < /proc/sys/kernel/random/boot_id
[ "$boot" = "$CONTROL_BOOT" ] || exit 70
read -r quota period < /sys/fs/cgroup/cpu.max
[ "$quota" = "$period" ] && [ "$quota" -gt 0 ] || exit 71
read -r memory < /sys/fs/cgroup/memory.max
[ "$memory" = 268435456 ] || exit 72
set -- /sys/class/net/*
[ "$#" = 1 ] && [ "$1" = /sys/class/net/lo ] || exit 73
echo "OUT-$token"
echo "ERR-$token" >&2
exit 23"""
IDLE_FLOOR = 90.0
IDLE_GAP = 5.0


def schedule(seed, cycles):
    rng = random.Random(seed)
    rows = []
    for _ in range(cycles):
        orders = list(itertools.permutations(ARMS))
        rng.shuffle(orders)
        for order in orders:
            block = len(rows) // len(WIDTHS) + 1
            for clients in (WIDTHS if block % 2 else WIDTHS[::-1]):
                rows.append(dict(block=block, clients=clients, order=list(order if clients == 1 else order[::-1])))
    return rows


def argv(arm, docker, micropod, sockets, label, token):
    prefix = ([micropod, "ci", "run", "--existing-worker-only"] if arm == NATIVE else
              [docker, "--host", "unix://" + str(sockets[arm]), "run", "--rm"])
    return [*prefix, *FLAGS, "--label", label, "--env", "CONTROL_BOOT", IMAGE, "sh", "-c", FIXTURE, "sh", token]


def command(args, env):
    p = subprocess.run(args, env=env, capture_output=True, timeout=30)
    require(p.returncode == 0, f"{args[0]} {args[1]} exited {p.returncode}: {p.stderr[-500:].decode(errors='replace')}")
    return p.stdout.decode().strip()


def stock_client(path, env):
    data = Path(path).read_bytes()
    require(b"path\tgithub.com/docker/cli/cmd/docker\n" in data, "Expected the stock Docker CLI executable")
    return dict(path=path, sha256=hashlib.sha256(data).hexdigest(), version=command([path, "--version"], env))


def host_model():
    buf = ctypes.create_string_buffer(128)
    size = ctypes.c_size_t(len(buf))
    require(ctypes.CDLL(None).sysctlbyname(b"hw.model", buf, ctypes.byref(size), None, 0) == 0,
            "Cannot read the Apple hardware model")
    return buf.value.decode()


def cpu_idle():
    # Darwin HOST_CPU_LOAD_INFO returns four 32-bit tick counters, with idle at index 2.
    lib = ctypes.CDLL(None)
    port = lib.mach_host_self()
    def ticks():
        values = (ctypes.c_uint32 * 4)()
        count = ctypes.c_uint32(len(values))
        require(lib.host_statistics(port, 3, values, ctypes.byref(count)) == 0 and count.value == 4,
                "Missing host CPU interval counters")
        return list(values)
    try:
        before = ticks()
        time.sleep(1)
        delta = [(b-a) % 2**32 for a,b in zip(before, ticks())]
        require(sum(delta) > 0, "Host CPU counters did not advance")
        return round(100 * delta[2] / sum(delta), 2)
    finally:
        lib.mach_port_deallocate(ctypes.c_uint.in_dll(lib, "mach_task_self_").value, port)


def batch(arm, width, token, build, env):
    # Threads and command vectors exist before release. Stop at the last client exit, before validation.
    def release():
        nonlocal start
        start = time.monotonic_ns()

    start = None
    gate = threading.Barrier(width + 1, action=release)

    def job(index, args):
        gate.wait()
        begin = time.monotonic_ns()
        try:
            outcome = subprocess.run(args, env=env, capture_output=True, timeout=90)
        except (OSError, subprocess.TimeoutExpired) as error:
            outcome = error
        return index, begin, time.monotonic_ns(), outcome

    commands = [build(arm, f"{token}-{i}") for i in range(width)]
    with ThreadPoolExecutor(max_workers=width) as pool:
        jobs = [pool.submit(job, i, args) for i, args in enumerate(commands)]
        gate.wait()
        results = [f.result() for f in jobs]
    rows = []
    for index, begin, end, outcome in results:
        key = f"{token}-{index}"
        row = dict(job=index, ok=False, client_ms=round((end - begin) / 1e6, 3))
        if isinstance(outcome, Exception):
            row.update(error=type(outcome).__name__, detail=getattr(outcome, "strerror", "90 s"))
        else:
            row.update(exit=outcome.returncode, ok=(outcome.returncode == 23 and
                       outcome.stdout == f"OUT-{key}\n".encode() and outcome.stderr == f"ERR-{key}\n".encode()))
            if not row["ok"]:
                row.update(stdout=outcome.stdout[-500:].decode(errors="replace"),
                           stderr=outcome.stderr[-500:].decode(errors="replace"))
        rows.append(row)
    return dict(arm=arm, clients=width, batch_ms=round((max(row[2] for row in results) - start) / 1e6, 3), jobs=rows)


def spread(samples):
    if samples:
        return dict(n=len(samples), median=statistics.median(samples), min=min(samples), max=max(samples))
    return dict(n=0, median=None, min=None, max=None)


def paired(groups, candidate):
    pairs = []
    for group in groups:
        if not group.get("finished"):
            continue
        samples = {b["arm"]: b for b in group["batches"]}
        ref, peer = samples[MIC], samples[candidate]
        if not all(j["ok"] for b in (ref, peer) for j in b["jobs"]):
            continue
        if abs(ref["idle_before_pct"] - peer["idle_before_pct"]) > IDLE_GAP:
            continue
        a, b = ref["batch_ms"], peer["batch_ms"]
        pairs.append(dict(block=group["block"], reference_ms=a, candidate_ms=b, delta_ms=round(b-a, 3),
                          ratio=round(b/a, 5)))
    return dict(reference=MIC, candidate=candidate, pairs=pairs,
                spread={k: spread([p[k] for p in pairs]) for k in ("reference_ms", "candidate_ms", "delta_ms", "ratio")})


def summarize(r):
    plan = r["schedule"]
    result = {}
    for width in WIDTHS:
        groups = [g for g in r["groups"] if g["clients"] == width]
        result[str(width)] = dict(planned_pairs=sum(g["clients"] == width for g in plan),
                                  stock_docker=paired(groups, ORB), native_ci=paired(groups, NATIVE))
    batches = [b for group in r["groups"] for b in group["batches"]]
    counts = {}
    for phase, items, planned in (("timed", batches, sum(g["clients"] * 3 for g in plan)),
                                  ("warmup", r["warmups"], sum(WIDTHS) * 2)):
        jobs = [job for b in items for job in b["jobs"]]
        counts[phase] = dict(planned=planned, attempted=len(jobs), failed=sum(not j["ok"] for j in jobs),
                             unattempted=planned-len(jobs))
        counts[phase]["by_arm"] = {arm: dict(
            attempted=sum(len(b["jobs"]) for b in items if b["arm"] == arm),
            failed=sum(not j["ok"] for b in items if b["arm"] == arm for j in b["jobs"])) for arm in ARMS}
    counts["boot_probes"] = dict(planned=2, attempted=len(r["probes"]), failed=sum(not p["ok"] for p in r["probes"]))
    return dict(widths=result, counts=counts)


def resources(cpu, memory_mib, info):
    require((cpu, memory_mib) == (4, 4096), "Configured VM budget must be four vCPUs and 4096 MiB")
    require(info["NCPU"] == 4 and 0.90 * 2**32 <= info["MemTotal"] <= 2**32, "Effective VM budget mismatch")
    require(info["Architecture"] in ("aarch64", "arm64") and info["CgroupVersion"] == "2", "Need ARM64 and cgroup v2")


def local_state(home, sockets):
    state = dict(micropod_session=(home / "session.json").is_file(), stopped_marker=(home / "stopped").is_file(),
                 sockets={k: {"path": str(p), "present": p.is_socket()} for k, p in sockets.items()})
    if (home / "worker.json").is_file():
        config = json.loads((home / "worker.json").read_text())
        state["micropod_config"] = {k: config[k] for k in ("cpus", "memoryMiB", "worker")}
    return state


def live(args, r, home, sockets, checkpoint):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("DOCKER_", "MICROPOD_CI_"))}
    docker = str(Path(shutil.which(args.docker) or args.docker).resolve(strict=True))
    micropod = str(Path(shutil.which(args.micropod) or args.micropod).resolve(strict=True))
    # ci run execs docker via PATH. Pin that lookup even when --docker is an absolute opt/bin symlink.
    docker_dir = Path(shutil.which(args.docker) or args.docker).absolute().parent
    env.update(MICROPOD_CI_HOME=str(home), MICROPOD_CI_ENGINE="docker", LC_ALL="C",
               PATH=str(docker_dir) + os.pathsep + os.defpath)
    require(Path(shutil.which("docker", path=env["PATH"]) or "/").resolve() == Path(docker), "ci run would use another docker")
    require(platform.system() == "Darwin" and platform.machine() == "arm64", "Need one Apple Silicon Mac")
    require(all(p.is_socket() for p in sockets.values()) and not sockets[MIC].samefile(sockets[ORB]), "Need distinct live sockets")
    r["admission_idle_pct"] = cpu_idle()
    require(r["admission_idle_pct"] >= IDLE_FLOOR, "Host below the CPU idle floor at admission")
    def socket_ids():
        stats = {arm: p.stat() for arm, p in sockets.items()}
        return {arm: [s.st_dev, s.st_ino] for arm, s in stats.items()}
    pinned = socket_ids()
    orbctl = shutil.which("orbctl")
    require(orbctl, "orbctl is required to check OrbStack status and its configured budget")
    drivers = {arm: [docker, "--host", "unix://" + str(p)] for arm, p in sockets.items()}
    def cli(arm, *options):
        return command([*drivers[arm], *options], env)
    def info(arm):
        source = json.loads(cli(arm, "info", "--format", "{{json .}}"))
        return {k: source[k] for k in ("ID", "Name", "OperatingSystem", "Architecture", "ServerVersion",
                                        "KernelVersion", "NCPU", "MemTotal", "CgroupVersion")}
    def quiet():
        require(socket_ids() == pinned, "Endpoint changed since admission")
        command([orbctl, "status"], env)  # 0 running, 1 stopped, 2 starting
        for arm in drivers:
            require(not cli(arm, "ps", "-q"), f"{arm} has running containers")
    quiet()
    help_text = command([micropod, "ci", "help"], env)
    require("--existing-worker-only" in help_text, "This micropod CLI lacks existing-worker-only support")
    r["clients"] = dict(docker=stock_client(docker, env),
                        micropod=dict(path=micropod, sha256=hashlib.sha256(Path(micropod).read_bytes()).hexdigest(),
                                      version=help_text.splitlines()[0]))
    status = json.loads(command([micropod, "ci", "status"], env))
    require(status["engine"] == "docker" and status["endpoint"] == drivers[MIC][2], "Unexpected Micropod worker endpoint")
    r["micropod_worker"] = {key: status[key] for key in ("worker", "instance", "boot", "daemon")}
    servers = {arm: info(arm) for arm in drivers}
    require(status["daemon"] == servers[MIC]["ID"] and servers[MIC]["ID"] != servers[ORB]["ID"], "Wrong or shared daemon")
    require("orbstack" in (servers[ORB]["Name"] + servers[ORB]["OperatingSystem"]).lower(), "Expected OrbStack daemon")
    r["engines"] = servers
    r["socket_ids"] = pinned
    r["host"] = dict(model=host_model(), macos=platform.mac_ver()[0])
    config = r["local"]["micropod_config"]
    require(config["worker"].lower() == status["worker"].lower(), "Worker manifest and daemon disagree")
    budgets = {MIC: [config["cpus"], config["memoryMiB"]],
               ORB: [int(command([orbctl, "config", "get", key], env)) for key in ("cpu", "memory_mib")]}
    r["configured_cpu_mib"] = budgets
    r["orbstack_version"] = command([orbctl, "version"], env)
    for arm in drivers:
        resources(*budgets[arm], servers[arm])
    require(max(x["MemTotal"] for x in servers.values()) / min(x["MemTotal"] for x in servers.values()) <= 1.05,
            "Usable memory differs by more than 5%")
    for arm in drivers:
        img = json.loads(cli(arm, "image", "inspect", IMAGE))[0]
        require(img["Os"] == "linux" and img["Architecture"] == "arm64" and any(
            ref.rsplit("@", 1)[-1] == IMAGE.split("@")[1] for ref in (img.get("RepoDigests") or [])),
            f"{arm} lacks the pinned ARM64 image")
        cfg = exported_config_digest(drivers[arm], img["Id"], "arm64", env)
        require(cfg == CONFIG, f"{arm} native image config differs from the pinned digest")
        r.setdefault("image_evidence", {})[arm] = dict(local_id=img["Id"], config=cfg, repo_digests=img["RepoDigests"])
        version = json.loads(cli(arm, "version", "--format", "{{json .}}"))
        r.setdefault("docker_versions", {})[arm] = {"client": version["Client"], "server": version["Server"]}
    for key in ("Version", "GitCommit", "Os", "Arch"):
        require(r["docker_versions"][MIC]["client"][key] == r["docker_versions"][ORB]["client"][key],
                f"Docker client {key} changed between endpoints")
    label = "io.micropod.launch-control=" + r["run"]
    def build(arm, token):
        return argv(arm, docker, micropod, sockets, label, token)

    boots = {}
    def idle():
        quiet()
        value = cpu_idle()
        require(value >= IDLE_FLOOR, f"CPU idle {value}% below {IDLE_FLOOR}%")
        return value

    def reap():
        require(socket_ids() == pinned, "Endpoint changed before cleanup")
        leftover = False
        for arm in drivers:
            ids = cli(arm, "ps", "-aq", "--filter", "label=" + label).split()
            if ids:
                leftover = True
                r.setdefault("residual_containers", []).append(dict(arm=arm, ids=ids))
                cli(arm, "rm", "-f", *ids)
        require(not leftover, "Benchmark containers remained after --rm")

    def sample(arm, width, token, bucket):
        r["stage"] = dict(arm=arm, clients=width, batch=token)
        cpu = idle()
        area = ORB if arm == ORB else MIC
        row = batch(arm, width, token, build, dict(env, CONTROL_BOOT=boots[area]))
        bucket.append(dict(idle_before_pct=cpu, **row))
        checkpoint()
        reap()
        quiet()
        return all(j["ok"] for j in row["jobs"])

    try:
        for arm in drivers:
            r["stage"] = dict(arm=arm, batch="boot-probe")
            idle()
            probe = dict(arm=arm, ok=False)
            r["probes"].append(probe)
            value = cli(arm, "run", "--rm", *FLAGS, "--label", label, IMAGE, "cat", BOOT)
            boots[arm] = str(uuid.UUID(value))
            probe.update(ok=True, boot=boots[arm])
        require(boots[MIC] == status["boot"].lower() and boots[MIC] != boots[ORB], "Unexpected or shared guest boot")
        for width in WIDTHS:
            for arm in ((MIC, ORB) if width == 1 else (ORB, MIC)):
                require(sample(arm, width, f"warm-{width}", r["warmups"]), f"{arm} failed prewarm at width {width}")
        for planned in r["schedule"]:
            group = dict(**planned, batches=[], finished=False)
            r["groups"].append(group)
            for arm in group["order"]:
                sample(arm, group["clients"], f'b{group["block"]}-{group["clients"]}', group["batches"])
            idle_samples = [b["idle_before_pct"] for b in group["batches"]]
            group["idle_gap_pp"] = round(max(idle_samples) - min(idle_samples), 3)
            group["finished"] = True
            checkpoint()
        require(servers == {arm: info(arm) for arm in drivers}, "Daemon identity or resources changed during measurement")
        r["identities_rechecked"] = True
        r.pop("stage")
    except BaseException:
        try:
            reap()
        except (ValueError, OSError, subprocess.SubprocessError) as cleanup_error:
            r["cleanup_error"] = str(cleanup_error)
        raise


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("mode", choices=("plan", "check", "run"))
    p.add_argument("--worker-home", type=Path, default=Path.home()/".micropod/ci")
    p.add_argument("--orbstack-socket", type=Path, default=Path.home()/".orbstack/run/docker.sock")
    p.add_argument("--docker", default="docker")
    p.add_argument("--micropod", default="micropod")
    p.add_argument("--seed", type=int, default=20261122)
    p.add_argument("--cycles", type=int, default=1, help="each cycle uses all six arm orders")
    p.add_argument("--slot-released", action="store_true", help="operator holds the dedicated slot after the published-TCP retest")
    p.add_argument("--output", type=Path, help="new JSON receipt path; required for run")
    args = p.parse_args()
    if args.cycles < 1 or (args.mode == "run" and args.output is None):
        p.error("Need positive cycles and a new --output path for live runs")
    if args.output:
        with args.output.open("x"):
            pass
    home = args.worker_home.expanduser().resolve()
    sockets = {MIC: home / "docker.sock", ORB: args.orbstack_socket.expanduser().resolve()}
    r = dict(workload="apple-stock-docker-launch-v1", run=uuid.uuid4().hex, mode=args.mode,
             at=datetime.now(timezone.utc).isoformat(), image=IMAGE, arm64_config=CONFIG,
             harness_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
             fixture_sha256=hashlib.sha256(FIXTURE.encode()).hexdigest(), flags=list(FLAGS),
             seed=args.seed, schedule=schedule(args.seed, args.cycles), groups=[], warmups=[], probes=[],
             idle_floor_pct=IDLE_FLOOR, max_idle_gap_pp=IDLE_GAP, slot_released=args.slot_released)
    def checkpoint():
        if args.output:
            tmp = args.output.with_name(args.output.name + "." + r["run"] + ".tmp")
            tmp.write_text(json.dumps(r, indent=2) + "\n")
            tmp.replace(args.output)
    try:
        r["state"] = "planned"
        if args.mode != "plan":
            r["local"] = local_state(home, sockets)
            if args.mode == "check" and shutil.which(args.docker):
                docker = str(Path(shutil.which(args.docker)).resolve())
                r["local"]["stock_docker"] = stock_client(docker, os.environ)
            require(r["local"]["micropod_session"] and all(v["present"] for v in r["local"]["sockets"].values()),
                    "Dedicated session and both documented sockets must already exist")
            r["state"] = "local-paths-present"
        if args.mode == "run":
            require(args.slot_released, "Dedicated slot release after published-TCP retest is required")
            r["state"] = "running"
            checkpoint()
            live(args, r, home, sockets, checkpoint)
            r["state"] = "complete"
            # Keep the scheduled denominators even when a job or a pair's idle match fails.
            for data in summarize(r)["widths"].values():
                if any(len(data[k]["pairs"]) != data["planned_pairs"] for k in ("stock_docker", "native_ci")):
                    r["state"] = "complete-with-exclusions"
    except (OSError, ValueError, KeyError, subprocess.SubprocessError, KeyboardInterrupt) as e:
        r["state"] = "failed" if r["probes"] else "blocked"
        r["error"] = str(e) or type(e).__name__
    r["summary"] = summarize(r)
    checkpoint()
    if not args.output:
        print(json.dumps(r, indent=2))
    else:
        print(r["state"], args.output, r.get("error", ""))
    return 0 if r["state"] in ("planned", "local-paths-present", "complete") else 1


if __name__ == "__main__":
    sys.exit(main())
