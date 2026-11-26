#!/usr/bin/env python3
"""Compare immutable mounted jobs with Linux and Darwin Git directories."""

import argparse
from contextlib import ExitStack
import json
import os
from pathlib import Path
import shutil
import signal
import statistics
import sys
import tempfile
import time
from uuid import uuid4

import bench_workspace_checkout as bench
import bench_workspace_edits as edits
import bench_workspace_runner as runner


LAYOUTS = ("host-git", "private-git")
ENGINES = ("hvf", "orbstack")
SAMPLE = "main_linux.go"
ENTRYPOINT = "pinned-checkout-job.sh"
DRIVER = "bench_mounted_git_job.py"
TRACE_FIELDS = ("category", "label", "key", "value", "t_rel")


def job_key(item):
    return "/".join(item)


class Job(bench.Arm):
    def start_job(self, cleanup, name, stage, args, accepted_ids, layout):
        cleanup.callback(edits.remove_probe, self.docker, name, settle=1)
        extra = ["--tmpfs", f"{bench.GUEST_SOURCE}/.git:rw,nosuid,nodev,noexec,size=128m,mode=0700"]
        response = bench.call([*self.docker, "run", "--detach", "--rm", "--name", name,
                               "--label", f"{edits.LABEL}={name}", "--pull=never", "--network", "none",
                               "--cpus", str(args.cpus), "--memory", f"{args.memory_mib}m", "--mount",
                               bench.bind_mount(stage), *(extra if layout == "private-git" else []),
                               "--entrypoint", "/bin/sh", args.image, "-ec", "exec sleep 900"], timeout=45)
        self.id = response.stdout.decode().strip()
        bench.require(bench.CONTAINER_ID.fullmatch(self.id), "invalid job container ID")
        self.container = self.read_container()
        row = self.container
        bench.require(row["Id"] == self.id and row["Name"] == "/" + name and row["State"]["Running"] is True
                      and row["Config"]["Labels"].get(edits.LABEL) == name and row["Image"] in accepted_ids
                      and row["HostConfig"]["NetworkMode"] == "none", "job did not run the pinned offline image")

    def guest(self, *mode, timeout=120):
        return self.json("exec", self.id, "python3", "-B", str(bench.GUEST_ROOT / DRIVER), "--guest",
                         *map(str, mode), timeout=timeout)


def guest_prepare(layout, cpus, mem, commit):
    root = bench.GUEST_ROOT
    bundle = root / runner.BUNDLE_NAME
    init_ns = 0
    bundle_identity = None
    if layout == "private-git":
        # Unbundle reads this file directly from the read-only share. Its transfer, unpack,
        # and first tracked-file scan are all within this guest wall clock.
        started = time.monotonic_ns()
        bench.call(["/bin/sh", root / ENTRYPOINT, "--immutable", bench.GUEST_SOURCE,
                    bundle, commit, "--", "/bin/true"],
                   env=bench.git_env(), timeout=180)
        init_ns = time.monotonic_ns() - started
        bundle_identity = {"size": bundle.stat().st_size, "sha256": bench.file_sha(bundle)}
    source_stat = bench.GUEST_SOURCE.stat()
    index_stat = (bench.GUEST_SOURCE / ".git/index").stat()
    bench.require((source_stat.st_dev != index_stat.st_dev) == (layout == "private-git"), "unexpected index mount")
    return {"init_ns": init_ns, "bundle": bundle_identity, "source_device": source_stat.st_dev,
            "index_device": index_stat.st_dev, "entrypoint_sha256": bench.file_sha(root / ENTRYPOINT),
            **runner.guest_prepare(cpus, mem)}


def guest_trace():
    env = bench.git_env()
    with tempfile.TemporaryDirectory(prefix="mounted-git-trace-") as tmp:
        trace = Path(tmp) / "git.jsonl"
        env["GIT_TRACE2_EVENT"] = str(trace)
        start = time.monotonic_ns()
        status = bench.git(["status", "--porcelain=v1", "--untracked-files=all"], bench.GUEST_SOURCE, env)
        elapsed = time.monotonic_ns() - start
        events = [json.loads(line) for line in trace.read_bytes().splitlines()]
    bench.require(not status, "the trace fixture was dirty")
    return {"status": status.decode(), "status_ns": elapsed,
            "trace2": [{key: row[key] for key in TRACE_FIELDS if key in row}
                       for row in events if row["event"] in ("data", "region_leave")],
            "git_build": bench.call(["git", "--version", "--build-options"], env=env).stdout.decode()}


def run_ci(job, cpus, expected_sha):
    start = time.monotonic_ns()
    result = bench.Arm.guest(job, "build", cpus, "", timeout=300)
    host_ns = time.monotonic_ns() - start
    bench.require(result["main_sha256"] == expected_sha, "build used a different pinned file")
    return {**result, "host_ns": host_ns}


def measure(args, stage, result):
    started = time.monotonic_ns()
    source, head = runner.prepare_checkout(stage, args.source)
    inventory = runner.inventory(source)
    common_preparation_ns = time.monotonic_ns() - started
    main = source / SAMPLE
    original = main.read_bytes()
    original_sha = bench.sha(original)
    bench.require(original.count(runner.MESSAGE.encode()) == 1, "runner revision check changed")
    bundle = stage / runner.BUNDLE_NAME
    started = time.monotonic_ns()
    bench.git(["bundle", "create", bundle, "refs/heads/main"], source, bench.git_env())
    bundle_pack_ns = time.monotonic_ns() - started
    bundle_identity = {"size": bundle.stat().st_size, "sha256": bench.file_sha(bundle)}
    shutil.copy2(args.entrypoint, stage / ENTRYPOINT)
    helper_sha = bench.file_sha(stage / ENTRYPOINT)
    shutil.copy2(__file__, stage / DRIVER)
    shutil.copy2(runner.__file__, stage / Path(runner.__file__).name)
    shutil.copy2(edits.__file__, stage / Path(edits.__file__).name)
    result.update(preparation={"common_source_ns": common_preparation_ns, "bundle_pack_ns": bundle_pack_ns,
                               "bundle": bundle_identity}, source=inventory, commit=head, entrypoint_sha256=helper_sha,
                  cold={}, prime_trace={}, pairs=[], supported_profile="read-only immutable pinned worktree")

    sockets = dict(zip(ENGINES, (args.hvf_socket, args.orbstack_socket)))
    jobs = {(engine, layout): Job(engine, sockets[engine], args.image) for layout in LAYOUTS for engine in ENGINES}
    sections = (("hvf", "host-git"), ("orbstack", "private-git"),
                ("orbstack", "host-git"), ("hvf", "private-git"))
    identity = bench.image_identity(args.image_manifest, [job.image_id for job in jobs.values()])
    result["image"] = identity
    host_git = {p: bench.file_sha(source / ".git" / p) for p in ("index", "HEAD", "config")}
    scope = "mp-mounted-git-" + uuid4().hex[:16]
    with ExitStack() as cleanup:
        primes = set()
        envs = {}
        for engine, layout in sections:
            job = jobs[engine, layout]
            batch_key = job_key((engine, layout))
            total_started = time.monotonic_ns()
            job.start_job(cleanup, f"{scope}-{engine}-{layout}", stage, args, set(identity.values()), layout)
            launched = time.monotonic_ns()
            prep = job.guest("prepare", layout, args.cpus, args.memory_mib, head, timeout=180)
            ready = time.monotonic_ns()
            expected_bundle = bundle_identity if layout == "private-git" else None
            bench.require(prep["head"] == head and prep["tree"] == inventory and prep["bundle"] == expected_bundle
                          and prep["entrypoint_sha256"] == helper_sha
                          and not any(prep["cache_initial_entries"].values()), "job was not cold at the expected revision")
            envs[batch_key] = prep
            try:
                prime = run_ci(job, args.cpus, original_sha)
            except Exception:
                result["failed_cell"] = batch_key
                try:
                    result["failed_cell_inspect"] = job.read_container()
                    memory = bench.call([*job.docker, "exec", job.id, "cat", "/sys/fs/cgroup/memory.events",
                                         "/sys/fs/cgroup/memory.peak", "/proc/meminfo"], timeout=10)
                    result["failed_cell_memory"] = memory.stdout.decode()
                except Exception as error:
                    result["diagnostic_error"] = str(error)
                raise
            overhead = bundle_pack_ns if layout == "private-git" else 0
            result["cold"][batch_key] = {
                "container": job.id, "prepare": prep, "first_ci": prime, "container_start_ns": launched - total_started,
                "prepare_wall_ns": ready - launched, "first_ci_wall_ns": ready - total_started + prime["host_ns"],
                "with_bundle_pack_ns": ready - total_started + prime["host_ns"] + overhead,
            }
            primes.add(prime["binary_sha256"])
            result["prime_trace"][batch_key] = job.guest("trace")
        bench.require(len(primes) == 1, "first builds produced different binary bytes")
        reference = next(iter(envs.values()))
        fields = ("limits", "versions", "tools_sha256", "go_env")
        bench.require(all(all(prep[k] == reference[k] for k in fields) for prep in envs.values()),
                      "guest jobs used different tools or limits")
        for pair in range(args.pairs):
            order = sections[pair % len(sections):] + sections[:pair % len(sections)]
            if (pair // len(sections)) % 2:
                order = order[::-1]
            samples = {job_key(item): run_ci(jobs[item], args.cpus, original_sha) for item in order}
            bench.require({row["binary_sha256"] for row in samples.values()} == primes,
                          "warm build differs from its prime")
            result["pairs"].append({"pair": pair + 1, "order": [job_key(item) for item in order],
                                    "jobs": samples})
        bench.require(all(bench.file_sha(source / ".git" / p) == sha for p, sha in host_git.items()),
                      "a job changed the host repository metadata")
        bench.require(runner.inventory(source) == inventory, "the pinned worktree changed")
        for job in jobs.values():
            job.check_generation()
    result["median_ms"] = {
        job_key(item): {
            "guest_sum": statistics.median(b["jobs"][job_key(item)]["sum_ns"]
                                            for b in result["pairs"]) / 1e6,
            "guest_git": statistics.median(b["jobs"][job_key(item)]["phase_ns"]["git_status"]
                                            for b in result["pairs"]) / 1e6,
            "host_wall": statistics.median(b["jobs"][job_key(item)]["host_ns"]
                                            for b in result["pairs"]) / 1e6,
        } for item in sections
    }
    result["complete"] = True


def main():
    if sys.argv[1:2] == ["--guest"]:
        action, *rest = sys.argv[2:]
        if action == "prepare":
            layout, cpus, memory, commit = rest
            result = guest_prepare(layout, int(cpus), int(memory), commit)
        elif action == "trace":
            result = guest_trace()
        else:
            raise ValueError(action)
        print(json.dumps(result))
        return

    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("hvf-socket", "orbstack-socket", "source", "workspace", "out", "entrypoint", "image-manifest"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--pairs", type=int, choices=range(1, 9), default=4)
    args = parser.parse_args()
    args.cpus, args.memory_mib = 2, 1536
    if args.out.exists():
        parser.error("choose a fresh output file")
    for socket in (args.hvf_socket, args.orbstack_socket):
        if not socket.is_absolute() or not socket.is_socket():
            parser.error("select two live explicit engine sockets")
    if args.hvf_socket.samefile(args.orbstack_socket):
        parser.error("choose distinct engines")
    for key in ("DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH", "DOCKER_API_VERSION"):
        os.environ.pop(key, None)
    signal.signal(signal.SIGTERM, edits.interrupted)
    result = {"complete": False}
    try:
        with tempfile.TemporaryDirectory(prefix="mounted-git-", dir=args.workspace) as tmp:
            measure(args, Path(tmp), result)
    except BaseException as exc:
        result["error"] = str(exc)
        raise
    finally:
        with args.out.open("x") as out:
            json.dump(result, out, indent=2)
            out.write("\n")


if __name__ == "__main__":
    main()
