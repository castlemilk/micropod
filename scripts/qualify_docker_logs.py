#!/usr/bin/env python3
"""Qualify verbose stock Docker streams on an explicit Linux engine endpoint."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import statistics
import struct
import subprocess
from tempfile import TemporaryDirectory
import time
from types import SimpleNamespace

from qualify_docker_exec import engine_response
from qualify_docker_restart import LABEL, Qualification, require


LIMIT = 40
MIB = 1 << 20


def block(stream):
    prefix = stream.encode() + b"-binary"
    suffix = b"\0\x01\x7f\r\n"
    return prefix + b"a" * (2048 - len(prefix) - len(suffix)) + suffix


def shell_bytes(data):
    return "'" + "".join(f"\\{byte:03o}" for byte in data) + "'"


def workload():
    return r"""
test "$$" -eq 1 && test ! -t 0 && test -z "$(cat)"
generation=1
if test -f /tmp/mp-log-generation; then
    read -r old < /tmp/mp-log-generation
    generation=$((old + 1))
fi
printf '%s\n' "$generation" > /tmp/mp-log-generation
printf 'stdout-generation=%s\n' "$generation"
printf 'stderr-generation=%s\n' "$generation" >&2
emit() {
    printf "$1" > /tmp/mp-log-chunk
    for i in 1 2 3 4 5 6 7 8 9; do
        cat /tmp/mp-log-chunk /tmp/mp-log-chunk > /tmp/mp-log-next
        mv /tmp/mp-log-next /tmp/mp-log-chunk
    done
    n=$2
    while test "$n" -gt 0; do
        cat /tmp/mp-log-chunk
        n=$((n - 1))
        if test "$generation" -eq 1; then sleep 0.02; fi
    done
    rm /tmp/mp-log-chunk
}
if test "$generation" -eq 1; then out=16; err=8; sleep 0.35; else out=2; err=1; fi
""" + f"emit {shell_bytes(block('stdout'))} \"$out\"\nemit {shell_bytes(block('stderr'))} \"$err\" >&2\nexit 23"


def expected(stream, generations):
    digest = hashlib.sha256()
    size = 0
    data = block(stream) * (MIB // len(block(stream)))
    for generation in generations:
        marker = f"{stream}-generation={generation}\n".encode()
        digest.update(marker)
        count = (16 if stream == "stdout" else 8) if generation == 1 else (2 if stream == "stdout" else 1)
        for _ in range(count):
            digest.update(data)
        size += len(marker) + MIB * count
    return {"bytes": size, "sha256": digest.hexdigest()}


def evidence(path):
    with path.open("rb") as source:
        return {"bytes": path.stat().st_size, "sha256": hashlib.file_digest(source, "sha256").hexdigest()}


def capture(fixture, work, stage, args, code=0, while_running=None):
    stdout, stderr = work / (stage + ".stdout"), work / (stage + ".stderr")
    begin = time.monotonic_ns()
    with stdout.open("wb") as out, stderr.open("wb") as err:
        with subprocess.Popen([*fixture.cli, *args], env=fixture.env, stdin=subprocess.DEVNULL, stdout=out, stderr=err) as client:
            try:
                if while_running:
                    while_running(client)
                status = client.wait(timeout=LIMIT)
                require(status == code, f"{stage} exit was {status}, expected {code}")
            finally:
                if client.poll() is None:
                    client.kill()
    end = time.monotonic_ns()
    return {"exit": status, "elapsed_ms": (end - begin) / 1e6, "stdout": evidence(stdout), "stderr": evidence(stderr)}


def validate_streams(result, generations):
    for stream in ("stdout", "stderr"):
        want = expected(stream, generations)
        require(result[stream] == want, f"{stream}: expected {want!r}, observed {result[stream]!r}")


def read_log_snapshot(response, first, stage_started):
    digests = [hashlib.sha256(), hashlib.sha256()]
    counts = [0, 0]
    next_pause = 256 << 10
    header = first
    while header:
        require(len(header) == 8, "truncated Docker log frame header")
        stream, size = struct.unpack(">B3xI", header)
        require(stream in (1, 2) and size <= 1 << 20, "invalid Docker log frame")
        data = response.read(size)
        require(len(data) == size, "truncated Docker log frame")
        digests[stream - 1].update(data)
        counts[stream - 1] += size
        if sum(counts) >= next_pause:
            next_pause += 256 << 10
            time.sleep(0.015)
        header = response.read(8)
    return {name: {"bytes": count, "sha256": digest.hexdigest()}
            for name, count, digest in zip(("stdout", "stderr"), counts, digests)} | {
                "elapsed_ms": (time.monotonic_ns() - stage_started) / 1e6}


def verbose(fixture, work, report):
    name = fixture.key + "-large"
    common = ["--pull=never", "--network=none", "--label", f"{LABEL}={fixture.key}"]

    def short_during_verbose(client):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            state = fixture.docker("container", "inspect", "--format", "{{.State.Running}}", name, check=False)
            if state.returncode == 0 and state.stdout.strip() == "true" and (work / "run.stdout").stat().st_size >= MIB:
                break
            require(client.poll() is None, "verbose job exited before concurrent short job")
            time.sleep(0.01)
        else:
            raise RuntimeError("verbose job never started")
        sent = (work / "run.stdout").stat().st_size
        begin = time.monotonic_ns()
        short = fixture.docker("run", "--rm", *common, fixture.image, "/bin/sh", "-ec", "echo concurrent-short")
        require(short.stdout == "concurrent-short\n", short.stdout)
        report["concurrent_short"] = {"elapsed_ms": (time.monotonic_ns() - begin) / 1e6, "stdout": short.stdout,
                                     "overlapped": client.poll() is None, "producer_stdout_advanced": (work / "run.stdout").stat().st_size > sent}
        require(report["concurrent_short"]["overlapped"] and report["concurrent_short"]["producer_stdout_advanced"],
                "short job did not overlap advancing verbose output")

    report["run"] = capture(fixture, work, "run", ("run", "--name", name, *common, fixture.image, "/bin/sh", "-ec", workload()),
                            23, short_during_verbose)
    validate_streams(report["run"], [1])
    first = fixture.inspect(name)
    require(first["State"]["ExitCode"] == 23 and not first["State"]["Running"], "verbose job exit was not preserved")
    report["default_log_config"] = first["HostConfig"]["LogConfig"]
    require(report["default_log_config"]["Type"] == "json-file", "unexpected default logging driver")
    report["logs"] = capture(fixture, work, "logs", ("logs", name))
    validate_streams(report["logs"], [1])

    # Pin the original reader before restarting. The attached replacement has
    # an independent cursor; replay after it exits contains both generations.
    with engine_response(fixture.cli[-1], "GET", f"/containers/{name}/logs?stdout=true&stderr=true") as response:
        started = time.monotonic_ns()
        prefix = response.read(8)
        with ThreadPoolExecutor(max_workers=1) as readers:
            slow = readers.submit(read_log_snapshot, response, prefix, started)
            report["attached_start"] = capture(fixture, work, "start", ("start", "-a", name), 23)
            validate_streams(report["attached_start"], [2])
            second = fixture.inspect(name)
            require(first["Id"] == second["Id"] and first["State"]["StartedAt"] != second["State"]["StartedAt"],
                    "retained start did not replace the process")
            fixture.docker("restart", "--timeout=0", name)
            wait = fixture.docker("wait", name).stdout.strip()
            third = fixture.inspect(name)
            require(wait == "23" and third["Id"] == first["Id"] and third["State"]["StartedAt"] != second["State"]["StartedAt"],
                    "managed restart changed the container identity or exit")
            report["restart_exit"] = int(wait)
            report["retained_logs"] = capture(fixture, work, "retained", ("logs", name))
            validate_streams(report["retained_logs"], [1, 2, 3])
            report["slow_open_at_remove"] = not slow.done()
            fixture.docker("rm", name)
            report["slow_original"] = slow.result(timeout=LIMIT)
    validate_streams(report["slow_original"], [1])
    require(report["slow_open_at_remove"], "slow reader finished before the removal control")
    require(fixture.docker("logs", name, check=False).returncode != 0, "removed container logs remain available")
    report["removed"] = True


def churn(fixture, count):
    flags = ("run", "--rm", "--pull=never", "--network=none", "--label", f"{LABEL}={fixture.key}", fixture.image)
    fixture.docker(*flags, "/bin/true")
    samples = []
    for _ in range(count):
        begin = time.monotonic_ns()
        result = fixture.docker(*flags, "/bin/true")
        require(not result.stdout and not result.stderr, "quiet start unexpectedly emitted bytes")
        samples.append((time.monotonic_ns() - begin) / 1e6)
    return {"samples_ms": samples, "median_ms": statistics.median(samples)}


def unsupported_configs(fixture):
    checks = []
    for flag, value, error in (("--log-driver", "none", "unsupported"), ("--log-driver", "local", "unsupported"),
                               ("--log-opt", "max-size=10m", "max-size"), ("--log-opt", "mode=non-blocking", "mode")):
        result = fixture.docker("create", "--pull=never", "--network=none", "--label", f"{LABEL}={fixture.key}",
                                flag, value, fixture.image, "/bin/true", check=False)
        require(result.returncode != 0 and error in result.stderr and not fixture.ids(), result.stderr)
        checks.append({"flag": flag, "value": value, "exit": result.returncode, "stderr": result.stderr})
    return checks


def native_devices(fixture, work):
    missing = work / "empty-dev"
    missing.mkdir()
    regular = work / "regular-dev"
    regular.mkdir()
    (regular / "null").touch()
    cases = {
        "custom_shm": (("--tmpfs", "/dev/shm:size=1m"), None),
        "replaced_dev_tmpfs": (("--tmpfs", "/dev:mode=755"), "Permission denied"),
        "empty_dev_bind": (("--mount", f"type=bind,source={missing},target=/dev"), "No such file or directory"),
        "invalid_dev_null": (("--mount", f"type=bind,source={regular},target=/dev"), "not the null device"),
    }
    report = {}
    for name, (flags, expected_error) in cases.items():
        args = ("run", "--rm", "--pull=never", "--network=none", "--label", f"{LABEL}={fixture.key}", *flags, fixture.image,
                "/bin/sh", "-ec", 'test -z "$(cat)"; printf "dev-ok\\r\\n"; printf "dev-err\\r\\n" >&2; exit 23')
        result = subprocess.run([*fixture.cli, *args], env=fixture.env, stdin=subprocess.DEVNULL, capture_output=True, timeout=LIMIT)
        if expected_error is None:
            require((result.returncode, result.stdout, result.stderr) == (23, b"dev-ok\r\n", b"dev-err\r\n"), repr(result))
        else:
            require(result.returncode == 125 and not result.stdout and b"/dev/null" in result.stderr
                    and expected_error.encode() in result.stderr, repr(result))
        report[name] = {"exit": result.returncode, "stdout_hex": result.stdout.hex(), "stderr_hex": result.stderr.hex()}
    return report


def plain_scratch(fixture, image):
    result = fixture.docker("run", "--rm", "--read-only", "--pull=never", "--network=none", "--label", f"{LABEL}={fixture.key}",
                            "-e", "GODEBUG=containermaxprocs=0,updatemaxprocs=0", image)
    data = json.loads(result.stdout)
    require(not result.stderr and (data["pid"], data["uid"], data["gid"], data["cwd"]) == (1, 1234, 5678, "/fixture"), repr(data))
    require(data["args"] == ["probe", "from image", "default arg", ""] and data["env"] == "image env" and data["launcher_dirs"] == 1,
            repr(data))
    fds = data["fds"]
    require(fds["0"] == "/dev/null" and fds["1"].startswith("pipe:[") and fds["2"].startswith("pipe:[") and fds["1"] != fds["2"],
            repr(data))
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--workspace", required=True, type=Path)
    parser.add_argument("--image", required=True)
    parser.add_argument("--scratch-image", help="preloaded static non-root scratch conformance image")
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--churn", type=int, default=0)
    parser.add_argument("--churn-only", action="store_true")
    parser.add_argument("--native-config", action="store_true")
    args = parser.parse_args()
    require(args.host.startswith("unix://") and Path(args.host[7:]).is_socket(), "provide an explicit local Docker socket")
    require(not args.out.exists(), "choose a fresh receipt path")
    require(0 <= args.churn <= 100 and (not args.churn_only or args.churn), "invalid churn request")
    report = {"passed": False}
    with TemporaryDirectory(prefix="mp-verbose-logs-", dir=args.workspace) as scratch:
        fixture = Qualification(Path(scratch), SimpleNamespace(host=args.host, context=None, image=args.image), prefix="mp-verbose-")
        fixture.env.update(DOCKER_CONFIG=scratch, DOCKER_CLI_HINTS="false", TERM="xterm")
        report["scope"] = fixture.key
        try:
            report["version"] = fixture.docker("version", "--format", "{{.Client.Version}} {{.Server.Version}}").stdout.strip()
            report["image"] = fixture.docker("image", "inspect", "--format", "{{.Id}} {{.Architecture}}", args.image).stdout.strip()
            if not args.churn_only:
                verbose(fixture, Path(scratch), report)
            if args.native_config:
                report["rejected_log_configs"] = unsupported_configs(fixture)
                report["device_mounts"] = native_devices(fixture, Path(scratch))
            if args.scratch_image:
                report["plain_scratch"] = plain_scratch(fixture, args.scratch_image)
            if args.churn:
                report["churn"] = churn(fixture, args.churn)
            report["passed"] = True
        except Exception as error:
            report["error"] = str(error)
            raise
        finally:
            try:
                report["cleanup"] = {"owned_ids": fixture.ids(), **fixture.cleanup()}
            finally:
                with args.out.open("x") as handle:
                    json.dump(report, handle, indent=2)
                    handle.write("\n")


if __name__ == "__main__":
    main()
