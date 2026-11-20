#!/usr/bin/env python3
"""Compare complete Go CI jobs in fresh containers and native Ubuntu workspaces."""

import argparse
import itertools
import json
import os
import re
import subprocess
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
from pathlib import Path

from bench_ci_startup import CGROUP_SAMPLE, WarmSession
from bench_fresh_go import GO_ENV
from ci_benchmark_store import DEFAULT_DB, store

TESTS = sorted(
    [
        "TestWriteReadAppendModeParents",
        "TestListStatTypes",
        "TestMkdirRemoveRenameCopyChmod",
        "TestWatchReportsChangesRecursivelyAndFast",
        "TestWatchMissingPath",
        "TestJobSpecPreservesPolicyAndRejectsSharedNamespaces",
        "TestWorkerPolicyWithinMeasuredAllocation",
    ]
)
JOB = r"""
set -eu
umask 022
mode=$1
suite=$2
test ! -e .ci-job-private
: > .ci-job-private
printf 'MP_ID %s %s\n' "$(cat /proc/sys/kernel/random/boot_id)" "${MP_RAW_ID:-$(hostname)}"
stamp() { printf 'MP_PHASE %s %s\n' "$1" "$(date +%s%N)"; }
stamp begin
if [ "$mode" = source ]; then
    go vet ./...
    stamp vet
    go test -count=1 -v ./...
    stamp tests
    product=$(mktemp)
    go build -trimpath -buildvcs=false -o "$product" .
    trap 'rm -f "$product"' EXIT
    stamp build
else
    sh "$suite/suite.sh" test "$suite"
    stamp tests
    product=$suite/product
fi
"$product" read go.mod > .ci-job-private
cmp go.mod .ci-job-private
printf 'MP_SHA %s\n' "$(sha256sum "$product" | cut -d" " -f1)"
stamp verified
"""

RAW = r"""
set -eu
root=$1
n=$2
mode=$3
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export PATH=/usr/local/go/bin:$PATH
export GOCACHE="$root/cache/build" GOMODCACHE="$root/cache/mod"
start=$(date +%s%N)
pids=()
for ((i=0; i<n; ++i)); do
    (
        dir=$(mktemp -d "$work/job-XXXXXXXXXXXX")
        cp -a --reflink=auto "$root/source/." "$dir/"
        cd "$dir"
        export MP_RAW_ID=${dir##*/}
        sh -ec "$4" sh "$mode" "$root/suite"
    ) > "$work/$i.log" 2>&1 &
    pids+=("$!")
done
failed=0
for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
for ((i=0; i<n; ++i)); do echo MP_RAW_JOB; cat "$work/$i.log"; done
if (( failed )); then exit 1; fi
rm -rf "$work"
trap - EXIT
echo "MP_RAW_NS $start $(date +%s%N)"
"""


def call(args, **kw):
    proc = subprocess.run(
        args, text=True, capture_output=True, check=False, timeout=450, **kw
    )
    if proc.returncode:
        raise RuntimeError(
            f"{args[0]} exited {proc.returncode}: {proc.stdout[-2500:]} {proc.stderr[-1200:]}"
        )
    return proc.stdout


def read_job(output, mode):
    passed = sorted(re.findall(r"^--- PASS: (Test\w+) \(", output, re.MULTILINE))
    times = {
        phase: int(stamp)
        for phase, stamp in re.findall(r"^MP_PHASE (\w+) (\d+)$", output, re.MULTILINE)
    }
    identity = re.search(r"^MP_ID ([\w-]+) ([\w-]+)$", output, re.MULTILINE)
    sha = re.search(r"^MP_SHA ([a-f0-9]{64})$", output, re.MULTILINE)
    expected = (
        ["begin", "vet", "tests", "build", "verified"]
        if mode == "source"
        else ["begin", "tests", "verified"]
    )
    if (
        passed != TESTS
        or not sha
        or not identity
        or list(times) != expected
        or "(cached)" in output
    ):
        raise ValueError("Incomplete live CI result: " + output[-2400:])
    return {
        "boot": identity[1],
        "job": identity[2],
        "sha256": sha[1],
        "phase_s": {
            b: (times[b] - times[a]) / 1e9 for a, b in itertools.pairwise(expected)
        },
        "tests": len(passed),
    }


def native_batch(session, mode, n, *, trace=False):
    command = JOB + (CGROUP_SAMPLE if trace else "")
    data, streams, wall = session.request(
        n, ["sh", "-ec", command, "sh", mode, "/micropod-ci-suite"]
    )
    if data["exit"] != 0 or len(data["results"]) != n:
        failed = [r["index"] for r in data["results"] if r["exit"]]
        evidence = [
            (
                streams[i]["stdout"][-1600:].decode(errors="replace"),
                streams[i]["stderr"][-800:].decode(errors="replace"),
            )
            for i in failed[:3]
        ]
        raise RuntimeError(
            f"CI batch failed: {data['exit']}, jobs {failed}, output {evidence}"
        )
    jobs = []
    for i, result in enumerate(data["results"]):
        row = read_job(streams[i]["stdout"].decode(), mode)
        if (
            result["index"] != i
            or result["exit"]
            or not result["id"].startswith(row["job"])
        ):
            raise ValueError("OCI job identity mismatch")
        if trace:
            output = streams[i]["stdout"].decode()
            counters = {
                key: int(value)
                for key, value in re.findall(
                    r"^(usage_usec|nr_throttled|throttled_usec|cpu_pressure_usec|io_pressure_usec|scheduler) (\d+)$",
                    output,
                    re.MULTILINE,
                )
            }
            if len(counters) != 6:
                raise ValueError(f"Missing guest counters: {counters}")
            row["cgroup"] = counters
            row["scheduler"] = counters["scheduler"]
            row["cpuset"] = re.search(r"^cpuset (\S+)", output, re.MULTILINE)[1]
            row["container"] = result["id"]
            row["ci_phases_ns"] = {
                "job " + phase: int(stamp)
                for phase, stamp in re.findall(
                    r"^MP_PHASE (\w+) (\d+)$", output, re.MULTILINE
                )
            }
        row["lifecycle"] = result
        jobs.append(row)
    return wall, jobs


def docker_batch(docker, common, image, mode, n):
    def job(_):
        out = call(
            [
                *docker,
                "run",
                "--rm",
                "--network",
                "none",
                "--pull=never",
                "--cpus",
                "1",
                "--memory",
                "1g",
                *common,
                "--entrypoint",
                "sh",
                image,
                "-ec",
                JOB,
                "sh",
                mode,
                "/micropod-ci-suite",
            ]
        )
        return read_job(out, mode)

    start = time.monotonic()
    with ThreadPoolExecutor(max_workers=n) as pool:
        rows = list(pool.map(job, range(n)))
    return time.monotonic() - start, rows


def raw_batch(raw, root, mode, n):
    out = call(
        [
            *raw,
            "sudo",
            "env",
            *[f"{k}={v}" for k, v in GO_ENV.items()],
            "bash",
            "-s",
            "--",
            root,
            str(n),
            mode,
            JOB,
        ],
        input=RAW,
    )
    chunks = out.split("MP_RAW_JOB\n")[1:]
    timing = re.search(r"^MP_RAW_NS (\d+) (\d+)$", out, re.MULTILINE)
    if not timing or len(chunks) != n:
        raise ValueError("Incomplete raw batch: " + out[-500:])
    return (int(timing[2]) - int(timing[1])) / 1e9, [
        read_job(output, mode) for output in chunks
    ]


def run(args):
    images = {"source": args.source_image, "suite": args.suite_image}
    handles = {"source": args.source_handle, "suite": args.suite_handle}
    raw = ["limactl", "shell", "--workdir", "/", "--", args.ubuntu]
    docker = ["docker", "--host", args.orbstack_endpoint]
    tag = uuid.uuid4().hex
    record = {
        "run": tag,
        "passed": False,
        "images": images,
        "handles": handles,
        "expected_tests": TESTS,
        "batches": [],
        "session_open_s": {},
    }
    common = []
    for vol, key in (("gobuild", "GOCACHE"), ("gomod", "GOMODCACHE")):
        path = "/cache/" + vol
        common += [
            "--mount",
            f"type=volume,src=micropod-ci-scoped-{args.scope}-{vol},dst={path},volume-nocopy",
            "-e",
            key + "=" + path,
        ]
    for key, value in GO_ENV.items():
        common.extend(["-e", key + "=" + value])
    seen = {k: set() for k in ("micropod", "orbstack", "ubuntu")}
    tools = 'go version; sha256sum "$(command -v go)"; uname -r; cat /proc/sys/kernel/random/boot_id'
    record["rig"] = {
        "micropod": json.loads(call([args.cli, "ci", "status"])),
        "orbstack": json.loads(call([*docker, "info", "--format", "{{json .}}"])),
    }
    record["rig"]["orbstack"] = {
        k: record["rig"]["orbstack"][k]
        for k in ("NCPU", "MemTotal", "KernelVersion", "ServerVersion", "ID")
    }
    record["rig"]["ubuntu"] = call(
        [
            *raw,
            "bash",
            "-ec",
            'export PATH=/usr/local/go/bin:$PATH; . /etc/os-release; echo "$PRETTY_NAME"; nproc; head -1 /proc/meminfo; '
            + tools,
        ]
    ).splitlines()
    record["rig"]["orbstack_tools"] = call(
        [
            *docker,
            "run",
            "--rm",
            "--network",
            "none",
            "--entrypoint",
            "sh",
            args.source_image,
            "-ec",
            tools,
        ]
    ).splitlines()
    record["rig"]["micropod_tools"] = call(
        [
            args.cli,
            "ci",
            "run",
            "--network",
            "none",
            "--entrypoint",
            "sh",
            args.source_image,
            "-ec",
            tools,
        ]
    ).splitlines()
    if (
        len(
            {
                record["rig"][k][-3].split()[0]
                for k in ("ubuntu", "orbstack_tools", "micropod_tools")
            }
        )
        != 1
    ):
        raise ValueError("Go toolchain executable differs")
    digest = None
    try:
        with ExitStack() as stack:
            sessions = {}
            for mode in images:
                start = time.monotonic()
                sessions[mode] = WarmSession(
                    args.cli, handles[mode], "runc", stack, backend="native"
                )
                record["session_open_s"][mode] = time.monotonic() - start
            modes = list(images)
            order = ["micropod", "orbstack", "ubuntu"]
            for rep in range(args.rounds + 1):
                for n in (
                    [1]
                    if rep == 0
                    else (args.clients if rep % 2 else args.clients[::-1])
                ):
                    for engine in order[rep % 3 :] + order[: rep % 3]:
                        for mode in modes[
                            :: 1 if (rep + order.index(engine)) % 2 == 0 else -1
                        ]:
                            if engine == "micropod":
                                wall, jobs = native_batch(sessions[mode], mode, n)
                            elif engine == "orbstack":
                                wall, jobs = docker_batch(
                                    docker, common, images[mode], mode, n
                                )
                            else:
                                wall, jobs = raw_batch(
                                    raw, args.ubuntu_workspace, mode, n
                                )
                            boot = record["rig"][
                                {
                                    "ubuntu": "ubuntu",
                                    "micropod": "micropod_tools",
                                    "orbstack": "orbstack_tools",
                                }[engine]
                            ][-1]
                            for job in jobs:
                                if (
                                    job["job"] in seen[engine]
                                    or job["boot"] != boot
                                    or (digest and job["sha256"] != digest)
                                ):
                                    raise ValueError(
                                        f"CI job identity or binary changed: {job}"
                                    )
                                seen[engine].add(job["job"])
                                digest = job["sha256"]
                            record["batches"].append(
                                {
                                    "engine": engine,
                                    "mode": mode,
                                    "clients": n,
                                    "round": rep,
                                    "seconds": wall,
                                    "jobs": jobs,
                                }
                            )
                            print(
                                f"{engine:8} {mode:6} {rep} x{n}: {wall:.3f}s",
                                flush=True,
                            )
            record["passed"] = True
    except Exception as error:
        record["error"] = str(error)
        raise
    finally:
        args.output.write_text(json.dumps(record) + "\n")
        store(args.database, tag, "go-ci-suite", record)


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--cli", default=os.getenv("MICROPOD_BIN", "micropod"))
    for flag in (
        "source-image",
        "suite-image",
        "source-handle",
        "suite-handle",
        "scope",
        "ubuntu-workspace",
    ):
        p.add_argument("--" + flag, required=True)
    p.add_argument("--ubuntu", required=True)
    p.add_argument(
        "--orbstack-endpoint",
        default="unix://" + str(Path.home() / ".orbstack/run/docker.sock"),
    )
    p.add_argument("--clients", type=int, nargs="+", default=[16, 32])
    p.add_argument("--rounds", type=int, default=3)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--database", type=Path, default=DEFAULT_DB)
    args = p.parse_args()
    if (
        not 1 <= args.rounds <= 30
        or len(set(args.clients)) != len(args.clients)
        or any(n < 1 or n > 64 for n in args.clients)
    ):
        p.error("Use 1–30 rounds and distinct client counts from 1–64")
    run(args)
