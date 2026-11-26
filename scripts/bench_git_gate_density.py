#!/usr/bin/env python3
"""Measure eight simultaneous Git checks with stock, parallel or CPU-pinned execution."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import selectors
import shutil
import statistics
import subprocess
import sys
from tempfile import TemporaryDirectory
import time
from uuid import uuid4


ROOT = Path("/checkout-ci")
TREE = ROOT / "source"
INDEX = TREE / ".git/index"
DRIVER = ROOT / "bench_git_gate_density.py"
HELPER = ROOT / "git_parallel_clean.py"
ENGINES = ("hvf", "orbstack")
JOBS, CPUS, MEMORY = 8, 0.5, 256
LABEL = "io.micropod.qa.git-gate-density"
TREE_SHA = "d963fc6e9f0a6a636fb0819065d7184a05ac9f6c2c3828b0f69afaf6b30980bd"


def git_env(bench):
    return bench.git_env() | {"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "safe.directory", "GIT_CONFIG_VALUE_0": str(TREE)}


def guest(action, slot, mode=""):
    import bench_workspace_checkout as bench

    env = git_env(bench)
    if action == "prepare":
        from git_parallel_clean import status

        limits = bench.guest_limits(CPUS, MEMORY)
        rows = [line.split() for line in Path("/proc/self/mountinfo").read_text().splitlines()]
        (mount,) = [row for row in rows if row[4] == str(INDEX)]
        bench.require("ro" in mount[5].split(","), "job has no read-only private index bind")
        result, used_parallel = status(TREE, 4, env)
        bench.require(used_parallel and result.returncode == 0 and not result.stdout and not result.stderr,
                      f"slot {slot} did not take the clean parallel path")
        info = INDEX.stat()
        print(json.dumps({"slot": slot, "limits": limits, "cpus": os.cpu_count(), "clock": bench.guest_clock(),
                          "index": {"device": info.st_dev, "inode": info.st_ino, "mount_id": mount[0],
                                    "mtime_ns": info.st_mtime_ns, "sha256": bench.file_sha(INDEX)},
                          "head": bench.call(["git", "-C", str(TREE), "rev-parse", "HEAD"], env=env).stdout.decode().strip(),
                          "git_version": bench.call(["git", "--version"], env=env).stdout.decode().strip(),
                          "git_sha256": bench.file_sha(Path(shutil.which("git"))), "python": sys.version.split()[0],
                          "helper_sha256": bench.file_sha(HELPER), "used_parallel": used_parallel}))
        return

    if mode == "cpu0":
        bench.require(os.sched_getaffinity(0) == {0, 1, 2, 3}, "status process started with a restricted CPU set")
        os.sched_setaffinity(0, {0})
        bench.require(os.sched_getaffinity(0) == {0}, "could not bind the status process to CPU 0")
    clock = bench.guest_clock()
    print(json.dumps({"slot": slot, "clock": clock}), flush=True)
    bench.require(sys.stdin.buffer.read(1) == b"g", "status worker did not receive the start gate")
    command = (["git", "-C", str(TREE), "--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all"]
               if mode != "helper" else [sys.executable, str(HELPER), "--workers", "4", str(TREE)])
    before = bench.cpu_accounting()
    start = time.monotonic_ns()
    result = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True, env=env, timeout=20, check=False)
    end = time.monotonic_ns()
    after = bench.cpu_accounting()
    print(json.dumps({"slot": slot, "mode": mode, "start_ns": start, "end_ns": end, "exit": result.returncode,
                      "stdout_hex": result.stdout.hex(), "stderr_hex": result.stderr.hex(), "allowed_cpus": sorted(os.sched_getaffinity(0)),
                      "cgroup_delta": {key: after[key] - value for key, value in before.items()}}), flush=True)


def ready_lines(processes):
    pending = [bytearray() for _ in processes]
    deadline = time.monotonic() + 12
    with selectors.DefaultSelector() as poll:
        for slot, proc in enumerate(processes):
            poll.register(proc.stdout, selectors.EVENT_READ, slot)
        while poll.get_map():
            keys = poll.select(max(0, deadline - time.monotonic()))
            if not keys:
                raise TimeoutError(f"status slots still preparing: {[key.data for key in poll.get_map().values()]}")
            for key, _ in keys:
                chunk = os.read(key.fd, 512)
                if not chunk:
                    out, err = processes[key.data].communicate(timeout=5)
                    raise RuntimeError(f"slot {key.data} did not signal readiness: {bytes(pending[key.data]) + out!r} {err!r}")
                buf = pending[key.data]
                buf.extend(chunk)
                if b"\n" in buf:
                    poll.unregister(key.fileobj)
                elif len(buf) > 512:
                    raise RuntimeError(f"invalid readiness line for slot {key.data}")
    return [json.loads(buf) for buf in pending]


def distribution(values):
    deciles = statistics.quantiles(values, n=10, method="inclusive")
    return {"count": len(values), "min": min(values), "p10": deciles[0], "p50": statistics.median(values),
            "p90": deciles[8], "max": max(values)}


def wave(arm, identities, mode, guest_clocks):
    import bench_workspace_checkout as bench

    launch = time.monotonic_ns()
    processes = []
    try:
        for slot, identity in enumerate(identities):
            processes.append(subprocess.Popen([*arm.docker, "exec", "-i", identity, "python3", "-B", str(DRIVER),
                                                "guest", "status", str(slot), mode], stdin=subprocess.PIPE,
                                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0))
        ready = ready_lines(processes)
        clocks = [row["clock"] for row in ready]
        bench.require([row["slot"] for row in ready] == list(range(JOBS)) and
                      all((row["boot_id"], row["offset_ns"]) == (clock["boot_id"], clock["offset_ns"])
                          for row, clock in zip(clocks, guest_clocks)), "status readiness did not match prepared guest slots")
        released = time.monotonic_ns()
        for proc in processes:
            proc.stdin.write(b"g")
            proc.stdin.close()
            proc.stdin = None
        release_complete = time.monotonic_ns()

        def finish(slot):
            proc = processes[slot]
            out, err = proc.communicate(timeout=22)
            host_finish = time.monotonic_ns()
            bench.require(proc.returncode == 0 and not err, f"status slot {slot} returned {proc.returncode}: {out!r} {err!r}")
            row = json.loads(out)
            bench.require(row["slot"] == slot and row["mode"] == mode and row["exit"] == 0
                          and not row["stdout_hex"] and not row["stderr_hex"]
                          and row["end_ns"] > row["start_ns"] >= clocks[slot]["now_ns"]
                          and all(value >= 0 for value in row["cgroup_delta"].values()), f"invalid status result: {row!r}")
            return row | {"guest_ms": (row["end_ns"] - row["start_ns"]) / 1e6,
                          "guest_ready_ns": clocks[slot]["now_ns"], "host_finish_ns": host_finish}

        with ThreadPoolExecutor(max_workers=JOBS) as workers:
            jobs = list(workers.map(finish, range(JOBS)))
        starts, ends = [row["start_ns"] for row in jobs], [row["end_ns"] for row in jobs]
        host_finish = max(row["host_finish_ns"] for row in jobs)
        bench.require(max(starts) < min(ends), f"eight statuses did not overlap on {arm.name}/{mode}: {jobs!r}")
        return {"host_launch_ns": launch, "host_release_ns": released, "host_release_done_ns": release_complete,
                "host_finish_ns": host_finish, "host_to_last_ms": (host_finish - released) / 1e6,
                "host_with_startup_ms": (host_finish - launch) / 1e6, "guest_to_last_ms": (max(ends) - min(starts)) / 1e6,
                "overlap_ms": (min(ends) - max(starts)) / 1e6, "start_skew_ms": (max(starts) - min(starts)) / 1e6,
                "job_guest_ms": distribution([row["guest_ms"] for row in jobs]), "jobs": jobs}
    finally:
        for proc in processes:
            if proc.poll() is None:
                proc.kill()
            proc.wait()
            for stream in (proc.stdin, proc.stdout, proc.stderr):
                if stream is not None:
                    stream.close()


def setup(args, workspace, report, arms):
    import bench_workspace_checkout as bench
    import bench_workspace_runner as runner

    begin = time.monotonic_ns()
    shared = workspace / "shared"
    private = workspace / "indices"
    shared.mkdir()
    private.mkdir()
    tree, head = runner.prepare_checkout(shared, args.source)
    fixture = runner.inventory(tree)
    bench.require(fixture["files"] == 1058 and fixture["tree_sha256"] == TREE_SHA, "not the archived vendored tree")
    shutil.copyfile(Path(__file__), shared / DRIVER.name)
    shutil.copyfile(args.helper, shared / HELPER.name)
    template = tree / ".git/index"
    old = template.stat()
    index_sha = bench.file_sha(template)
    copies = {}
    for name in ENGINES:
        copies[name] = []
        for slot in range(JOBS):
            path = private / f"{name}-{slot}"
            shutil.copyfile(template, path)
            os.utime(path, ns=(old.st_atime_ns, old.st_mtime_ns))
            copies[name].append(path)
    report.update(source=fixture, head=head, index_sha256=index_sha, index_mtime_ns=old.st_mtime_ns,
                  helper_sha256=bench.file_sha(args.helper), driver_sha256=bench.file_sha(Path(__file__)),
                  staging_ms=(time.monotonic_ns() - begin) / 1e6)
    identities, prepared = {}, {}
    for name, arm in arms.items():
        begin = time.monotonic_ns()

        def provision(slot):
            mounts = (bench.bind_mount(shared), bench.bind_mount(copies[name][slot], INDEX))
            container = bench.call([*arm.docker, "run", "--detach", "--pull=never", "--network", "none",
                                    "--name", f"{report['scope']}-{slot}", "--label", report["label"],
                                    "--cpus", str(CPUS), "--memory", f"{MEMORY}m", "--mount", mounts[0], "--mount", mounts[1],
                                    "--entrypoint", "/bin/sh", args.image, "-ec", "exec sleep 600"], timeout=20).stdout.decode().strip()
            bench.require(bench.CONTAINER_ID.fullmatch(container) is not None, f"invalid {name} container ID")
            metadata = arm.json("exec", container, "python3", "-B", str(DRIVER), "guest", "prepare", str(slot), timeout=20)
            return container, metadata

        with ThreadPoolExecutor(max_workers=JOBS) as workers:
            rows = list(workers.map(provision, range(JOBS)))
        identities[name], prepared[name] = map(list, zip(*rows))
        report["preparation"][name] = {"ids": identities[name], "jobs": prepared[name],
                                        "wall_ms": (time.monotonic_ns() - begin) / 1e6, "vm_cpus": arm.engine.get("NCPU")}
        indices = [row["index"] for row in prepared[name]]
        clocks = [row["clock"] for row in prepared[name]]
        bench.require(len(set(identities[name])) == len({(row["device"], row["inode"]) for row in indices}) == JOBS
                      and len({(row["boot_id"], row["offset_ns"]) for row in clocks}) == 1
                      and all(row["sha256"] == index_sha and row["mtime_ns"] == old.st_mtime_ns for row in indices)
                      and all(row["cpus"] == 4 and row["head"] == head and row["helper_sha256"] == report["helper_sha256"]
                              and row["used_parallel"] for row in prepared[name]), f"invalid independence or fixture on {name}")
    tools = {(row["git_version"], row["git_sha256"], row["python"]) for rows in prepared.values() for row in rows}
    bench.require(len(tools) == 1, "engines did not use identical Git and Python")
    return identities, {name: [row["clock"] for row in rows] for name, rows in prepared.items()}, [template, *copies["hvf"], *copies["orbstack"]]


def measure(args, workspace, report):
    import bench_workspace_checkout as bench

    arms = {}
    try:
        for name in ENGINES:
            arm = bench.Arm(name, getattr(args, name + "_socket"), args.image)
            bench.require(arm.engine.get("NCPU") == 4, f"{name} VM must report four CPUs")
            arms[name] = arm
            bench.require(not scoped_ids(arm, report["label"]), f"{name} unexpectedly has this run's label")
        report["image"] = bench.image_identity(args.image_manifest, [arm.image_id for arm in arms.values()])
        identities, clocks, indices = setup(args, workspace, report, arms)
        cells = [(engine, mode) for mode in ("stock", args.comparison) for engine in ENGINES]
        for name, mode in cells:
            report["warmup"][name + "/" + mode] = wave(arms[name], identities[name], mode, clocks[name])
        for slots in ((0, 1, 3, 2), (1, 2, 0, 3), (2, 3, 1, 0), (3, 0, 2, 1)):
            block = {"order": [], "waves": {}}
            report["rounds"].append(block)
            for slot in slots:
                name, mode = cells[slot]
                key = name + "/" + mode
                block["order"].append(key)
                block["waves"][key] = wave(arms[name], identities[name], mode, clocks[name])
        bench.require(all(bench.file_sha(index) == report["index_sha256"] and index.stat().st_mtime_ns == report["index_mtime_ns"]
                          for index in indices), "a job changed the host index bytes or mtime")
        summarize(report)
    finally:
        for name, arm in arms.items():
            try:
                ids = scoped_ids(arm, report["label"])
                if ids:
                    bench.call([*arm.docker, "rm", "--force", *ids], timeout=20)
                report["cleanup"][name] = {"removed": ids, "remaining": scoped_ids(arm, report["label"])}
            except Exception as error:
                report["cleanup"][name] = {"error": str(error)}
    bench.require(all(not row.get("error") and not row["remaining"] and len(row["removed"]) == JOBS
                      for row in report["cleanup"].values()), "density cleanup was incomplete")


def scoped_ids(arm, label):
    import bench_workspace_checkout as bench

    return bench.call([*arm.docker, "ps", "-aq", "--filter", "label=" + label], timeout=12).stdout.decode().splitlines()


def summarize(report):
    comparison = report["comparison"]
    names = [f"{engine}/{mode}" for engine in ENGINES for mode in ("stock", comparison)]
    cells = {name: [block["waves"][name] for block in report["rounds"]] for name in names}
    metrics = ("guest_to_last_ms", "host_to_last_ms", "host_with_startup_ms", "overlap_ms", "start_skew_ms")
    report["summary"] = {name: {"wave_median": {key: statistics.median(row[key] for row in rows) for key in metrics},
                                "guest_job_ms": distribution([job["guest_ms"] for row in rows for job in row["jobs"]]),
                                "job_cpu_usage_usec": distribution([job["cgroup_delta"]["usage_usec"] for row in rows for job in row["jobs"]]),
                                "job_cpu_throttled_usec": distribution([job["cgroup_delta"]["throttled_usec"] for row in rows for job in row["jobs"]])}
                         for name, rows in cells.items()}
    report["pairs"] = {}
    for engine in ENGINES:
        measures = {}
        for metric in metrics[:3]:
            deltas = [a[metric] - b[metric] for a, b in zip(cells[engine + "/stock"], cells[engine + "/" + comparison])]
            measures[metric] = {"median_saving_ms": statistics.median(deltas), comparison + "_wins": sum(value > 0 for value in deltas),
                                "saving_ms": deltas}
        report["pairs"][engine] = measures


def main():
    if sys.argv[1:2] == ["guest"]:
        action, slot, *rest = sys.argv[2:]
        guest(action, int(slot), *rest)
        return
    parser = argparse.ArgumentParser(description=__doc__)
    for flag in ("hvf-socket", "orbstack-socket", "workspace", "source", "helpers", "helper", "image-manifest", "out"):
        parser.add_argument("--" + flag, type=Path, required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--comparison", choices=("helper", "cpu0"), default="helper")
    args = parser.parse_args()
    if args.out.exists() or not args.hvf_socket.is_socket() or not args.orbstack_socket.is_socket() or args.hvf_socket.samefile(args.orbstack_socket):
        parser.error("use two explicit live sockets and a fresh receipt")
    if not (args.source / "vendor/modules.txt").is_file():
        parser.error("use the archived offline vendored checkout")
    for key in ("DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_TLS", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH", "DOCKER_API_VERSION"):
        os.environ.pop(key, None)
    os.environ["DOCKER_CLI_HINTS"] = "false"
    sys.path.insert(0, str(args.helpers))
    scope = "mp-git-density-" + uuid4().hex[:12]
    report = {"passed": False, "scope": scope, "label": LABEL + "=" + scope, "cpus_per_job": CPUS, "memory_mib": MEMORY,
              "jobs_per_wave": JOBS, "comparison": args.comparison, "preparation": {}, "warmup": {}, "rounds": [], "cleanup": {}}
    try:
        with TemporaryDirectory(prefix=scope + "-", dir=args.workspace) as temp:
            measure(args, Path(temp), report)
        report["workspace_removed"] = not Path(temp).exists()
        report["passed"] = True
    except Exception as error:
        report["failure"] = repr(error)
        raise
    finally:
        with args.out.open("x") as receipt:
            json.dump(report, receipt, indent=2)
            receipt.write("\n")


if __name__ == "__main__":
    main()
