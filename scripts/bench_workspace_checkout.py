#!/usr/bin/env python3
"""Compare offline Git, Go build and Go test on the same host-mounted checkout."""

import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import ExitStack
from copy import copy
import csv
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time
from uuid import uuid4


ROOT = Path(__file__).resolve().parents[1]
SOURCE_NAMES = ("files.go", "go.mod", "go.sum", "guest_test.go", "idle.go", "main.go", "watch.go")
TEST_NAMES = (
    "TestListStatTypes", "TestMkdirRemoveRenameCopyChmod", "TestWatchMissingPath",
    "TestWatchReportsChangesRecursivelyAndFast", "TestWriteReadAppendModeParents",
)
PACKAGE = "github.com/castlemilk/micropod/guest"
USAGE_START = "usage: micropod-guest "
USAGE_END = (
    "idle | read PATH [--max N] | write PATH [--append] [--mode OCTAL] [--parents] | "
    "stat PATH | list DIR | mkdir PATH [--parents] | rm PATH [--recursive] | mv FROM TO | "
    "cp FROM TO [--recursive] | chmod OCTAL PATH | watch PATH [--recursive]"
)
IMAGE_ID = re.compile(r"sha256:[0-9a-f]{64}")
CONTAINER_ID = re.compile(r"[0-9a-f]{64}")
GIT_ID = re.compile(r"[0-9a-f]{40}")
BOOT_ID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")
GUEST_ROOT = Path("/checkout-ci")
GUEST_SOURCE = GUEST_ROOT / "source"
GUEST_LOCAL = Path("/tmp/micropod-checkout-ci")
GUEST_BUILD_CACHE = GUEST_LOCAL / "build-cache"
GUEST_MODULE_CACHE = GUEST_LOCAL / "module-cache"
GUEST_PRODUCT = GUEST_LOCAL / "micropod-guest"
PHASES = ("git_status", "go_build", "go_test")
BATCH_LEAD_NS = 3_000_000_000
GO_ENV_KEYS = ("GOOS", "GOARCH", "GOARM64", "CGO_ENABLED", "GOTOOLCHAIN", "GOFLAGS",
               "GOMODCACHE", "GOCACHE", "GOPROXY", "GOSUMDB")


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def file_sha(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def source_hashes(source):
    return {name: file_sha(source / name) for name in SOURCE_NAMES}


def call(args, *, cwd=None, env=None, timeout=30, exit_code=0):
    result = subprocess.run(args, capture_output=True, stdin=subprocess.DEVNULL, cwd=cwd, env=env, timeout=timeout)
    if result.returncode != exit_code:
        combined = (result.stdout[-1500:] + b"\n" + result.stderr[-2000:]).decode(errors="replace").strip()
        command = " ".join(map(str, args[:2]))
        raise RuntimeError(f"{command} exited {result.returncode}: {combined}")
    return result


def git_env():
    return {key: value for key, value in os.environ.items() if not key.startswith("GIT_")} | {
        "LC_ALL": "C", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0",
    }


def guest_env(cpus):
    # Cache paths live in the container, away from the shared Mac cache.
    env = {key: value for key, value in git_env().items() if not key.startswith(("GO", "CGO_"))}
    return env | {
        "GOENV": "off", "GOWORK": "off", "GOTOOLCHAIN": "local",
        "GOFLAGS": f"-trimpath -p={cpus}", "CGO_ENABLED": "0", "GOMAXPROCS": str(cpus),
        "GOOS": "linux", "GOARCH": "arm64", "GOARM64": "v8.0",
        "GOPROXY": "off", "GOSUMDB": "off", "GOTELEMETRY": "off",
        "GOCACHE": str(GUEST_BUILD_CACHE), "GOMODCACHE": str(GUEST_MODULE_CACHE),
        "GOPATH": str(GUEST_LOCAL / "gopath"), "TMPDIR": str(GUEST_LOCAL),
    }


def job_cpu_limit(text):
    try:
        value = Decimal(text)
    except InvalidOperation as error:
        raise argparse.ArgumentTypeError("--job-cpus requires a decimal number") from error
    if (not value.is_finite() or not Decimal("0.01") <= value <= 8
            or value * 100_000 != (value * 100_000).to_integral_value()):
        raise argparse.ArgumentTypeError("--job-cpus must be 0.01–8 in whole microseconds of a 100000 µs period")
    return value.normalize()


def git(args, source, env):
    return call(["git", "-c", f"safe.directory={source}", *args], cwd=source, env=env).stdout


def edit_main(original, variant):
    target = USAGE_START.encode()
    require(original.count(target) == 1, "production guest's usage string changed")
    return original.replace(target, target + f"[checkout-ci-{variant}] ".encode(), 1) if variant else original


def expected_usage(variant):
    revision = f"[checkout-ci-{variant}] " if variant else ""
    return f"micropod-guest: EINVAL: {USAGE_START}{revision}{USAGE_END}\n".encode()


def replace_main(source, content):
    staging = source.parent / "edited-go-source"
    staging.write_bytes(content)
    staging.chmod(0o644)
    staging.replace(source / "main.go")


def stage_checkout(directory):
    source = directory / "source"
    source.mkdir()
    for name in SOURCE_NAMES:
        (source / name).write_bytes((ROOT / "guest" / name).read_bytes())
        (source / name).chmod(0o644)
    shutil.copyfile(Path(__file__), directory / "driver.py")
    env = git_env() | {
        "GIT_AUTHOR_NAME": "Micropod CI", "GIT_AUTHOR_EMAIL": "ci@example.invalid",
        "GIT_COMMITTER_NAME": "Micropod CI", "GIT_COMMITTER_EMAIL": "ci@example.invalid",
        "GIT_AUTHOR_DATE": "2026-01-01T00:00:00Z", "GIT_COMMITTER_DATE": "2026-01-01T00:00:00Z",
    }
    git(["init", "--quiet", "--template=", "--object-format=sha1", "--initial-branch=main"], source, env)
    git(["add", "--", *SOURCE_NAMES], source, env)
    git(["-c", "commit.gpgSign=false", "commit", "--quiet", "-m", "Production guest file helper"], source, env)
    head = git(["rev-parse", "HEAD"], source, env).decode().strip()
    require(GIT_ID.fullmatch(head), "fixture Git commit has an unexpected identity")
    return source, head


def verify_tests(output):
    events = [json.loads(line) for line in output.splitlines()]
    expected = Counter(TEST_NAMES)
    runs = Counter(event["Test"] for event in events if event.get("Action") == "run")
    passes = Counter(event["Test"] for event in events if event.get("Action") == "pass" and event.get("Test"))
    package_passes = [event.get("Package") for event in events if event.get("Action") == "pass" and not event.get("Test")]
    require(runs == passes == expected and package_passes == [PACKAGE]
            and not any(event.get("Action") in ("skip", "fail") or "(cached)" in event.get("Output", "")
                        for event in events),
            f"unexpected Go test results: {dict(runs)} ran, {dict(passes)} passed")
    return sorted(passes)


def guest_limits(cpus, memory_mib, *, job_local=False):
    root = Path("/sys/fs/cgroup")
    if (root / "cpu.max").is_file():
        quota, period = map(int, (root / "cpu.max").read_text().split())
        memory = int((root / "memory.max").read_text())
    else:
        cpu_root = root / "cpu"
        if not cpu_root.is_dir():
            cpu_root = root / "cpu,cpuacct"
        quota = int((cpu_root / "cpu.cfs_quota_us").read_text())
        period = int((cpu_root / "cpu.cfs_period_us").read_text())
        memory = int((root / "memory/memory.limit_in_bytes").read_text())
    require(period > 0 and quota == cpus * period and memory == memory_mib << 20,
            "guest cgroup limits differ from the requested CPU or memory budget")
    devices = Path("/proc/net/dev").read_text().splitlines()[2:]
    interfaces = sorted(row.split(":", 1)[0].strip() for row in devices)
    require(interfaces == ["lo"], f"guest network is not offline: {interfaces}")
    rows = [line.split() for line in Path("/proc/self/mountinfo").read_text().splitlines()]
    if job_local:
        (root,) = [row for row in rows if row[4] == "/"]
        mounts = [Path(row[4]) for row in rows if row[4] != "/"]
        require("rw" in root[5].split(",") and not any(
            path.is_relative_to(mount) or mount.is_relative_to(path)
            for path in (GUEST_ROOT, GUEST_LOCAL) for mount in mounts),
            "checkout or cache has a separate mount on its writable root")
    else:
        mounts = [row for row in rows if row[4] == str(GUEST_ROOT)]
        require(len(mounts) == 1 and "ro" in mounts[0][5].split(","), "checkout is missing its read-only bind")
    return {"cpu_quota_us": quota, "cpu_period_us": period, "memory_bytes": memory,
            "network_interfaces": interfaces, "source_read_only": not job_local}


def guest_prepare(cpus, memory_mib, cpu_limit=None, *, job_local=False):
    limits = guest_limits(cpus if cpu_limit is None else cpu_limit, memory_mib, job_local=job_local)
    GUEST_LOCAL.mkdir()
    GUEST_BUILD_CACHE.mkdir()
    GUEST_MODULE_CACHE.mkdir()
    initial_entries = {"build": len(list(GUEST_BUILD_CACHE.iterdir())),
                       "module": len(list(GUEST_MODULE_CACHE.iterdir()))}
    require(not any(initial_entries.values()), "guest cache was not initially empty")
    env = guest_env(cpus)
    versions = {
        "go": call(["go", "version"], env=env).stdout.decode().strip(),
        "git": call(["git", "--version"], env=env).stdout.decode().strip(),
        "python": sys.version.split()[0],
    }
    require(re.fullmatch(r"go version go[\d.]+ linux/arm64", versions["go"]), "Go toolchain is not Linux ARM64")
    tooldir = Path(call(["go", "env", "GOTOOLDIR"], env=env).stdout.decode().strip())
    tools = {"go": Path(shutil.which("go")), "git": Path(shutil.which("git")),
             "compile": tooldir / "compile", "link": tooldir / "link", "python": Path(sys.executable)}
    effective = json.loads(call(
        ["go", "env", "-json", *GO_ENV_KEYS], cwd=GUEST_SOURCE, env=env,
    ).stdout)
    require(effective == {key: env[key] for key in GO_ENV_KEYS}, "guest Go environment differs from the requested policy")
    return {"versions": versions, "tools_sha256": {name: file_sha(path) for name, path in tools.items()},
            "go_env": effective, "limits": limits, "driver_sha256": file_sha(Path(__file__)),
            "cache_initial_entries": initial_entries, "boot_id": Path("/proc/sys/kernel/random/boot_id").read_text().strip()}


def cpu_accounting():
    root = Path("/sys/fs/cgroup")
    if (root / "cpu.max").exists():
        counters = dict(line.split() for line in (root / "cpu.stat").read_text().splitlines())
        return {key: int(counters[key]) for key in ("usage_usec", "nr_periods", "nr_throttled", "throttled_usec")}
    cpu = root / "cpu"
    if not cpu.is_dir():
        cpu = root / "cpu,cpuacct"
    account = root / "cpuacct/cpuacct.usage"
    if not account.exists():
        account = cpu / "cpuacct.usage"
    counters = dict(line.split() for line in (cpu / "cpu.stat").read_text().splitlines())
    return {"usage_usec": int(account.read_text()) // 1000, "nr_periods": int(counters["nr_periods"]),
            "nr_throttled": int(counters["nr_throttled"]), "throttled_usec": int(counters["throttled_time"]) // 1000}


def guest_build(cpus, variant, priming, *, account_cpu=False):
    env = guest_env(cpus)
    GUEST_PRODUCT.unlink(missing_ok=True)
    outputs, timings = {}, {}
    commands = {
        "git_status": ["git", "-c", f"safe.directory={GUEST_SOURCE}", "status", "--porcelain=v1", "--untracked-files=all"],
        "go_build": ["go", "build", "-buildvcs=false", "-o", str(GUEST_PRODUCT), "."],
        "go_test": ["go", "test", "-buildvcs=false", "-json", "-count=1", "."],
    }
    before = cpu_accounting() if account_cpu else {}
    for phase, command in commands.items():
        start = time.monotonic_ns()
        outputs[phase] = call(command, cwd=GUEST_SOURCE, env=env, timeout=(150 if priming else 45)).stdout
        end = time.monotonic_ns()
        timings[phase] = {"start_ns": start, "end_ns": end, "elapsed_ns": end - start}
    accounting = {}
    if account_cpu:
        after = cpu_accounting()
        delta = {key: after[key] - value for key, value in before.items()}
        require(all(value >= 0 for value in delta.values()), "checkout cgroup counters went backwards")
        accounting["cpu_cgroup"] = {"before": before, "after": after, "delta": delta}
    expected_status = b" M main.go\n" if variant else b""
    require(outputs["git_status"] == expected_status, f"unexpected Git status {outputs['git_status']!r}")
    tests = verify_tests(outputs["go_test"])
    readback = call([str(GUEST_PRODUCT), "read", "go.mod"], cwd=GUEST_SOURCE, env=env).stdout
    require(readback == (GUEST_SOURCE / "go.mod").read_bytes(), "built CLI did not return exact module bytes")
    # Calling the real CLI without a command exercises its compiled usage constant.
    usage = call([str(GUEST_PRODUCT)], cwd=GUEST_SOURCE, env=env, timeout=10, exit_code=1)
    require(usage.stdout == b"" and usage.stderr == expected_usage(variant),
            f"built CLI did not report the expected source revision: {usage.stderr!r}")
    require(not any(GUEST_MODULE_CACHE.iterdir()), "the local module unexpectedly fetched dependencies")
    return {
        "phase_timings": timings,
        "scored_ns": sum(value["elapsed_ns"] for value in timings.values()),
        "git_head": git(["rev-parse", "HEAD"], GUEST_SOURCE, env).decode().strip(),
        "git_status": outputs["git_status"].decode(),
        "source_sha256": source_hashes(GUEST_SOURCE),
        "artifact_sha256": file_sha(GUEST_PRODUCT),
        "cli_readback_sha256": sha(readback),
        "cli_usage_sha256": sha(usage.stderr),
        "tests": tests, **accounting,
    }


def guest_clock():
    boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    require(BOOT_ID.fullmatch(boot), "invalid guest boot identity")
    try:
        rows = Path("/proc/self/timens_offsets").read_text().splitlines()
    except FileNotFoundError:
        offset = 0
    else:
        (monotonic,) = [row.split() for row in rows if row.split()[:1] == ["monotonic"]]
        _, seconds, nanos = monotonic
        require(0 <= int(nanos) < 10**9, "invalid guest monotonic clock offset")
        offset = int(seconds) * 10**9 + int(nanos)
    return {"boot_id": boot, "offset_ns": offset, "now_ns": time.monotonic_ns()}


def guest_batch(cpus, variant, priming, cpu_limit, memory_mib, gate_ns, boot_id, offset_ns):
    limits = guest_limits(cpu_limit, memory_mib)
    clock = guest_clock()
    require(clock["boot_id"] == boot_id and clock["offset_ns"] == offset_ns,
            "checkout job did not share the batch guest clock")
    ready = clock["now_ns"]
    require(ready < gate_ns, "checkout job did not reach the guest start barrier")
    now = ready
    while now < gate_ns:
        time.sleep((gate_ns - now) / 1e9)
        now = time.monotonic_ns()
    result = guest_build(cpus, variant, priming, account_cpu=True)
    require(guest_limits(cpu_limit, memory_mib) == limits, "checkout job resource limits changed during the batch")
    return {**result, "limits": limits, "barrier": {"boot_id": boot_id, "offset_ns": offset_ns,
            "ready_ns": ready, "start_ns": now, "gate_ns": gate_ns}}


def docker_cli(socket):
    return ["docker", "--host", "unix://" + str(socket)]


def image_identity(path, observed):
    ids = set(observed)
    require(ids and all(isinstance(identity, str) and IMAGE_ID.fullmatch(identity) for identity in ids),
            "expected valid Docker image digests")
    if path is None:
        require(len(ids) == 1, "engines reported different image IDs; pass the per-platform OCI --image-manifest")
        return {"image_id": next(iter(ids))}
    manifest_bytes = path.read_bytes()
    manifest = json.loads(manifest_bytes)
    config_id = (manifest.get("config") or {}).get("digest", "")
    manifest_id = "sha256:" + sha(manifest_bytes)
    require(manifest.get("schemaVersion") == 2 and manifest.get("layers") and isinstance(config_id, str)
            and IMAGE_ID.fullmatch(config_id)
            and ids <= {config_id, manifest_id}, "image IDs do not match the same per-platform OCI manifest")
    return {"config_digest": config_id, "manifest_digest": manifest_id}


def bind_mount(directory, target=GUEST_ROOT, *, read_only=True):
    stream = io.StringIO()
    fields = ["type=bind", "source=" + str(directory), "target=" + str(target)]
    if read_only:
        fields.append("readonly")
    csv.writer(stream, lineterminator="").writerow(fields)
    return stream.getvalue()


class Arm:
    def __init__(self, name, socket, image):
        self.name = name
        self.socket = socket
        self.docker = docker_cli(socket)
        self.engine = self.json("info", "--format", "{{json .}}")
        require((self.engine.get("ServerVersion") == "micropod" if name == "hvf"
                 else self.engine.get("OperatingSystem") == "OrbStack"),
                f"{name} does not identify the expected Docker endpoint")
        details = self.json("image", "inspect", "--format", "{{json .}}", image)
        require(details.get("Os") == "linux" and details.get("Architecture") == "arm64",
                f"{name} toolchain image is not Linux ARM64")
        self.image_id = details.get("Id")

    def json(self, *args, timeout=30):
        return json.loads(call([*self.docker, *args], timeout=timeout).stdout)

    def start(self, stack, name, stage, args, accepted_ids, *, extra_mounts=()):
        from bench_workspace_edits import LABEL, remove_probe

        period = getattr(args, "job_cpu_period_us", None)
        cpu_flags = ["--cpus", str(args.cpus)]
        if period is not None:
            quota = args.cpus * period
            require(quota == int(quota) and quota >= 1000, "per-job quota must be at least 1000 whole microseconds")
            cpu_flags = ["--cpu-period", str(period), "--cpu-quota", str(int(quota))]
        stack.callback(remove_probe, self.docker, name, settle=1)
        mounts = [bind_mount(stage)] if stage is not None else []
        mounts.extend(extra_mounts)
        boot = call([*self.docker, "run", "--detach", "--rm", "--name", name, "--label", f"{LABEL}={name}",
                     "--pull=never", "--network", "none", *cpu_flags, "--memory", f"{args.memory_mib}m",
                     *(arg for mount in mounts for arg in ("--mount", mount)),
                     "--entrypoint", "/bin/sh", args.image,
                     "-ec", "exec sleep 900"], timeout=45)
        self.id = boot.stdout.decode().strip()
        require(CONTAINER_ID.fullmatch(self.id), f"{self.name} returned an invalid container identity")
        self.container = self.read_container()
        row = self.container
        require(row["Id"] == self.id and row["Name"] == "/" + name and row["State"]["Running"] is True
                and row["Config"]["Labels"].get(LABEL) == name and row["Image"] in accepted_ids
                and row["HostConfig"]["NetworkMode"] == "none", f"{self.name} did not run the owned offline image")

    def read_container(self):
        (row,) = self.json("inspect", "--type", "container", self.id)
        return row

    def guest(self, *mode, timeout=120):
        return self.json("exec", self.id, "python3", str(GUEST_ROOT / "driver.py"), "--guest",
                         *map(str, mode), timeout=timeout)

    def check_generation(self):
        row = self.read_container()
        require(row["Id"] == self.id and row["State"]["Running"] is True
                and row["State"]["StartedAt"] == self.container["State"]["StartedAt"],
                f"{self.name} checkout container changed generation")


def attest_run(result, commit, source, variant):
    expected_status = " M main.go\n" if variant else ""
    require(result["git_head"] == commit and result["source_sha256"] == source
            and result["cli_readback_sha256"] == source["go.mod"] and result["tests"] == list(TEST_NAMES)
            and result["cli_usage_sha256"] == sha(expected_usage(variant)) and result["git_status"] == expected_status
            and re.fullmatch(r"[a-f0-9]{64}", result["artifact_sha256"]),
            "guest checkout result does not match the host fixture")
    phases = [result["phase_timings"][stage] for stage in PHASES]
    require(all(p["start_ns"] > 0 and p["elapsed_ns"] == p["end_ns"] - p["start_ns"] > 0 for p in phases)
            and all(a["end_ns"] <= b["start_ns"] for a, b in zip(phases, phases[1:]))
            and result["scored_ns"] == sum(p["elapsed_ns"] for p in phases),
            "guest returned invalid phase timing")


def prepare_job(arm, driver, go_version, cpus, memory, *quota):
    context = arm.guest("prepare", cpus, memory, *quota)
    require(context["driver_sha256"] == driver, f"{arm.name} did not execute the staged driver")
    if go_version:
        require(context["versions"]["go"] == f"go version go{go_version} linux/arm64",
                f"{arm.name} did not execute Go {go_version}")
    return context


def compare_edits(pairs, source, original, baseline, names, warm_sha, measure):
    seen_artifacts = {warm_sha}
    blocks = []
    for index in range(pairs):
        order = names if index % 2 == 0 else names[::-1]
        if index:
            replace_main(source, original)
        variant = f"{index + 1:04d}"
        block = {"pair": index + 1, "edit": variant, "order": {"warm": order, "incremental": order[::-1]}}
        for phase, phase_order in block["order"].items():
            revision = variant if phase == "incremental" else ""
            expected = dict(baseline)
            if revision:
                changed = edit_main(original, revision)
                replace_main(source, changed)
                expected["main.go"] = sha(changed)
            block[phase] = {name: measure(name, revision, expected) for name in phase_order}
            artifacts = {sample["artifact_sha256"] for sample in block[phase].values()}
            require(len(artifacts) == 1, f"pair {index + 1} produced different {phase} binaries")
            product = artifacts.pop()
            if revision:
                require(product not in seen_artifacts, "incremental edit did not produce a distinct binary")
                seen_artifacts.add(product)
            else:
                require(product == warm_sha, "warm build did not reproduce the primed binary")
        blocks.append(block)
    return blocks


def batch_timing(jobs):
    edges = Counter()
    by_phase = {}
    for phase in PHASES:
        clocks = [job["phase_timings"][phase] for job in jobs]
        for clock in clocks:
            edges[clock["start_ns"]] += 1
            edges[clock["end_ns"]] -= 1
        by_phase[phase] = max(0, min(clock["end_ns"] for clock in clocks)
                              - max(clock["start_ns"] for clock in clocks))
    active = peak = overlap = 0
    previous = first = min(edges)
    for stamp, change in sorted(edges.items()):
        if stamp > previous:
            peak = max(peak, active)
            if active == len(jobs):
                overlap += stamp - previous
        active += change
        previous = stamp
    require(overlap > 0, "checkout batch did not overlap all jobs during measured work")
    return {"start_ns": first, "end_ns": previous, "makespan_ns": previous - first,
            "peak_scored_parallelism": peak, "all_jobs_overlap_ns": overlap, "all_jobs_overlap_by_phase_ns": by_phase}


def measure_batch(workers, contexts, cleanup, policy, commit, expected, variant, *, priming=False):
    clock = workers[0].guest("clock", policy.go_parallelism)
    boot, offset, now = (clock[key] for key in ("boot_id", "offset_ns", "now_ns"))
    require(BOOT_ID.fullmatch(boot) and type(offset) is int and type(now) is int and now > 0
            and all(context["boot_id"] == boot for context in contexts), "checkout batch changed guest clock or boot")
    gate = now + BATCH_LEAD_NS
    jobs = [None] * len(workers)
    with ThreadPoolExecutor(max_workers=len(workers), thread_name_prefix="checkout-ci") as pool:
        active = {}
        try:
            for index, worker in enumerate(workers):
                active[pool.submit(worker.guest, "batch", policy.go_parallelism, variant, "prime" if priming else "timed",
                                   policy.cpus, policy.memory_mib, gate, boot, offset,
                                   timeout=360 if priming else 150)] = index
            for future in as_completed(active):
                index = active[future]
                result = future.result()
                attest_run(result, commit, expected, variant)
                stamp = result["barrier"]
                require(stamp["boot_id"] == boot and stamp["offset_ns"] == offset and stamp["gate_ns"] == gate
                        and now <= stamp["ready_ns"] < gate <= stamp["start_ns"]
                        <= result["phase_timings"]["git_status"]["start_ns"],
                        f"checkout job {index + 1} missed the common guest start barrier")
                require(result["limits"] == contexts[index]["limits"],
                        f"checkout job {index + 1} ran with different cgroup limits")
                jobs[index] = {**result, "job": index + 1, "container_id": workers[index].id}
        except BaseException:
            for future in active:
                future.cancel()
            # Stop owned guests before joining threads whose Docker execs might
            # otherwise wait for an entire failed batch to finish.
            cleanup.close()
            raise
    artifacts = {job["artifact_sha256"] for job in jobs}
    require(len(artifacts) == 1, "checkout jobs produced different binaries in one engine")
    return {**batch_timing(jobs), "artifact_sha256": artifacts.pop(), "guest_boot_id": boot,
            "guest_monotonic_offset_ns": offset, "gate_ns": gate, "jobs": jobs}


def run_batches(args, stage, source, original, arms, image, evidence):
    names = tuple(arms)
    policy = copy(args)
    policy.cpus = args.job_cpus if args.job_cpus is not None else Decimal(args.cpus)
    policy.memory_mib = args.job_memory_mib if args.job_memory_mib is not None else args.memory_mib
    policy.go_parallelism = math.ceil(policy.cpus)
    evidence.update(jobs_per_engine=args.jobs, cpus=str(policy.cpus), memory_mib=policy.memory_mib,
                    go_parallelism=policy.go_parallelism)
    scope = uuid4().hex
    workers = {name: [copy(arm) for _ in range(args.jobs)] for name, arm in arms.items()}
    contexts = {name: [] for name in names}
    with ExitStack() as cleanup:
        group_cleanup = {name: cleanup.enter_context(ExitStack()) for name in names}
        for name in names:
            for index, worker in enumerate(workers[name], 1):
                worker.start(group_cleanup[name], f"mp-checkout-{scope}-{name}-{index:02d}", stage, policy,
                             set(image.values()))
                context = prepare_job(worker, evidence["driver_sha256"], args.go_version,
                                      policy.go_parallelism, policy.memory_mib, policy.cpus)
                requested = getattr(policy, "job_cpu_period_us", None)
                if requested is not None:
                    require(context["limits"]["cpu_period_us"] == requested,
                            "guest cgroup did not apply the requested period")
                require(not any(context["cache_initial_entries"].values()), "checkout job did not get a fresh cache")
                contexts[name].append({**context, "job": index, "container_id": worker.id})
            require(len({context["boot_id"] for context in contexts[name]}) == 1,
                    f"{name} checkout jobs ran in different guests")
            evidence["arms"][name] = {"jobs": contexts[name], "image_id": arms[name].image_id,
                                       "engine": {field: arms[name].engine.get(field) for field in
                                                  ("Name", "OperatingSystem", "ServerVersion", "NCPU", "MemTotal")}}
        all_jobs = [context for name in names for context in contexts[name]]
        require(len({context["container_id"] for context in all_jobs}) == len(all_jobs),
                "checkout jobs did not get distinct container IDs")
        require(len({context["boot_id"] for context in all_jobs}) == len(names),
                "measurement arms did not run in distinct guests")
        require(all(all(context[key] == all_jobs[0][key] for key in ("versions", "tools_sha256", "go_env", "limits"))
                    for context in all_jobs), "jobs did not run the same tools, Go settings and limits")

        commit = evidence["fixture_git_commit"]
        baseline = evidence["fixture_source_sha256"]

        def measure(name, variant, expected, *, priming=False):
            return measure_batch(workers[name], contexts[name], group_cleanup[name], policy,
                                 commit, expected, variant, priming=priming)

        def prime(name):
            limit = getattr(args, "prime_jobs", None) or args.jobs
            if limit == args.jobs:
                return measure(name, "", baseline, priming=True)
            begin = time.monotonic_ns()
            groups = []
            for first in range(0, args.jobs, limit):
                span = slice(first, first + limit)
                batch = measure_batch(workers[name][span], contexts[name][span], group_cleanup[name],
                                      policy, commit, baseline, "", priming=True)
                for job in batch["jobs"]:
                    job["job"] += first
                groups.append(batch)
            digests = {group["artifact_sha256"] for group in groups}
            require(len(digests) == 1, "cold preparation groups produced different binaries")
            return {"artifact_sha256": digests.pop(), "max_parallel_jobs": limit, "groups": groups,
                    "host_wall_ns": time.monotonic_ns() - begin}

        evidence["priming"] = {name: prime(name) for name in names}
        warm = {result["artifact_sha256"] for result in evidence["priming"].values()}
        require(len(warm) == 1, "warm priming binaries differ")
        warm_sha = warm.pop()
        evidence["warm_artifact_sha256"] = warm_sha
        evidence["pairs"] = compare_edits(args.pairs, source, original, baseline, names, warm_sha, measure)
        for name in names:
            for worker in workers[name]:
                worker.check_generation()

    evidence["summary"] = {
        phase: {
            "median_makespan_ms": {
                name: statistics.median(block[phase][name]["makespan_ns"] for block in evidence["pairs"]) / 1e6
                for name in names
            },
            "paired_hvf_over_orbstack": [block[phase]["hvf"]["makespan_ns"] / block[phase]["orbstack"]["makespan_ns"]
                                         for block in evidence["pairs"]],
        }
        for phase in ("warm", "incremental")
    }
    evidence["completed_utc"] = datetime.now(timezone.utc).isoformat()
    evidence["timing_scope"] = {
        "clock": "guest CLOCK_MONOTONIC nanoseconds with verified boot ID and namespace offset",
        "makespan_ns": "first Git status start through last Go test finish in the same engine",
        "scored_ns": "per job, sum of Git status, Go build and uncached Go test subprocess durations",
        "all_jobs_overlap_ns": "time with all workers simultaneously in a measured subprocess",
        "warm_state": "one unscored prime per fresh isolated guest-local build cache, retained across batches",
        "incremental_state": "first batch after an atomic host-only main.go edit with a unique revision per pair",
        "source": "real Micropod guest file helper with its five Linux tests, in one read-only host Git checkout",
    }
    return evidence


def run(args, stage):
    source, commit = stage_checkout(stage)
    original = (source / "main.go").read_bytes()
    baseline = source_hashes(source)
    driver = file_sha(stage / "driver.py")
    arm_names = ("orbstack", "hvf")
    arms = {name: Arm(name, sock, args.image) for name, sock in zip(arm_names, (args.orbstack_socket, args.hvf_socket))}
    image = image_identity(args.image_manifest, [arm.image_id for arm in arms.values()])
    evidence = {"image": {"reference": args.image, **image}, "fixture_git_commit": commit,
                "fixture_source_sha256": baseline, "driver_sha256": driver, "cpus": args.cpus,
                "memory_mib": args.memory_mib, "arms": {}, "pairs": []}
    if getattr(args, "jobs", 1) > 1:
        return run_batches(args, stage, source, original, arms, image, evidence)
    scope = uuid4().hex
    with ExitStack() as stack:
        for name, arm in arms.items():
            arm.start(stack, f"mp-checkout-{scope}-{name}", stage, args, set(image.values()))
            context = prepare_job(arm, driver, args.go_version, args.cpus, args.memory_mib)
            evidence["arms"][name] = {**context, "container_id": arm.id, "image_id": arm.image_id,
                                       "engine": {field: arm.engine.get(field) for field in
                                                  ("Name", "OperatingSystem", "ServerVersion", "NCPU", "MemTotal")}}
        first, second = (evidence["arms"][name] for name in arm_names)
        require(all(first[key] == second[key] for key in ("versions", "tools_sha256", "go_env", "limits")),
                "engines did not run the same tools, Go settings and limits")
        require(first["boot_id"] != second["boot_id"], "measurement arms did not run in distinct guests")

        primed = {}
        for name, arm in arms.items():
            primed[name] = arm.guest("build", args.cpus, "", "prime", timeout=360)
            attest_run(primed[name], commit, baseline, "")
        warm_sha = primed["hvf"]["artifact_sha256"]
        require(warm_sha == primed["orbstack"]["artifact_sha256"], "warm priming binaries differ")
        evidence["warm_artifact_sha256"] = warm_sha

        def measure(name, revision, expected):
            sample = arms[name].guest("build", args.cpus, revision, "timed", timeout=150)
            attest_run(sample, commit, expected, revision)
            return sample

        evidence["pairs"] = compare_edits(args.pairs, source, original, baseline, arm_names, warm_sha, measure)
        for arm in arms.values():
            arm.check_generation()

    evidence["summary"] = {
        phase: {
            "median_ms": {name: statistics.median(block[phase][name]["scored_ns"] for block in evidence["pairs"]) / 1e6
                          for name in arm_names},
            "paired_hvf_over_orbstack": [block[phase]["hvf"]["scored_ns"] / block[phase]["orbstack"]["scored_ns"]
                                         for block in evidence["pairs"]],
        }
        for phase in ("warm", "incremental")
    }
    evidence["completed_utc"] = datetime.now(timezone.utc).isoformat()
    evidence["timing_scope"] = {
        "clock": "guest monotonic nanoseconds",
        "scored_ns": "sum of complete Git status, Go build and uncached Go test subprocess durations",
        "warm_state": "one identical unscored prime per arm on a fresh guest-local build cache",
        "incremental_state": "first build after an atomic host-only main.go edit with a unique source revision per pair",
        "source": "real Micropod guest file helper with its five Linux tests, in one read-only host Git checkout",
    }
    return evidence


def main():
    from bench_workspace_edits import interrupted

    signal.signal(signal.SIGTERM, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    for flag in ("hvf-socket", "orbstack-socket", "workspace", "out"):
        parser.add_argument("--" + flag, required=True, type=Path)
    parser.add_argument("--image", required=True, help="matched preloaded Linux ARM64 image with go, git and python3")
    parser.add_argument("--image-manifest", type=Path, help="OCI platform manifest if image ID formats differ")
    parser.add_argument("--go-version", help="expected exact Go version, e.g. 1.26.11")
    parser.add_argument("--pairs", type=int, default=4)
    parser.add_argument("--cpus", type=int, default=2)
    parser.add_argument("--memory-mib", type=int, default=1024)
    parser.add_argument("--jobs", type=int, default=1, help="Simultaneous checkout jobs per engine (default 1)")
    parser.add_argument("--prime-jobs", type=int,
                        help="Maximum simultaneous cold-cache jobs per engine. Timed waves still use --jobs.")
    parser.add_argument("--job-cpus", type=job_cpu_limit,
                        help="CPU quota per concurrent job, e.g. 0.5. Defaults to --cpus")
    parser.add_argument("--job-memory-mib", type=int,
                        help="Memory limit per concurrent job in MiB. Defaults to --memory-mib")
    parser.add_argument("--job-cpu-period-us", type=int, help="CFS period per concurrent job in microseconds")
    args = parser.parse_args()
    if not 2 <= args.pairs <= 16 or args.pairs % 2:
        parser.error("--pairs requires an even count between 2 and 16")
    if not 1 <= args.cpus <= 8 or not 512 <= args.memory_mib <= 8192:
        parser.error("use 1–8 CPUs and 512–8192 MiB per isolated container")
    if not 1 <= args.jobs <= 32:
        parser.error("--jobs must be between 1 and 32")
    if args.prime_jobs is not None and not 1 <= args.prime_jobs <= args.jobs:
        parser.error("--prime-jobs must be between 1 and --jobs")
    if args.jobs == 1 and any(v is not None for v in (args.job_cpus, args.job_memory_mib, args.job_cpu_period_us)):
        parser.error("per-job settings require --jobs greater than 1")
    if args.job_cpu_period_us is not None:
        if not 1000 <= args.job_cpu_period_us <= 1000000:
            parser.error("--job-cpu-period-us must be between 1000 and 1000000")
        quota = (args.job_cpus or args.cpus) * args.job_cpu_period_us
        if quota != int(quota) or quota < 1000:
            parser.error("per-job quota must be at least 1000 whole microseconds")
    if args.job_memory_mib is not None and not 1 <= args.job_memory_mib <= 8192:
        parser.error("--job-memory-mib must be between 1 and 8192")
    if args.out.exists():
        parser.error("--out must be a new receipt path")
    for attr in ("hvf_socket", "orbstack_socket"):
        socket = getattr(args, attr)
        if not socket.is_absolute() or not socket.is_socket():
            parser.error("both endpoints must be absolute paths to Unix sockets")
    if args.hvf_socket.samefile(args.orbstack_socket):
        parser.error("the two endpoints must differ")
    for key in ("DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_TLS", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH", "DOCKER_API_VERSION"):
        os.environ.pop(key, None)
    with tempfile.TemporaryDirectory(prefix="checkout-ci-", dir=args.workspace.resolve(strict=True)) as directory:
        report = run(args, Path(directory))
    with args.out.open("x") as file:
        json.dump(report, file, indent=2)
        file.write("\n")


if __name__ == "__main__":
    if sys.argv[1:2] == ["--guest"]:
        _, _, command, cpus, *rest = sys.argv
        if command == "prepare":
            result = guest_prepare(int(cpus), int(rest[0]), Decimal(rest[1]) if len(rest) > 1 else None)
        elif command == "build":
            result = guest_build(int(cpus), rest[0], rest[1] == "prime")
        elif command == "clock":
            result = guest_clock()
        elif command == "batch":
            variant, phase, quota, memory, gate, boot, offset = rest
            result = guest_batch(int(cpus), variant, phase == "prime", Decimal(quota), int(memory),
                                 int(gate), boot, int(offset))
        else:
            raise ValueError("unknown guest command")
        print(json.dumps(result))
    else:
        main()
