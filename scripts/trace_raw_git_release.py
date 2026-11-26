#!/usr/bin/env python3
"""Capture the exact mounted stock-Git path on a one-shot trace workspace."""

import argparse
from bisect import bisect_left
from collections import Counter, defaultdict
from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path
import re
from secrets import token_hex
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory
import time


DRIVER = Path("/checkout-ci/trace_raw_git_release.py")
TREE_SHA = "d963fc6e9f0a6a636fb0819065d7184a05ac9f6c2c3828b0f69afaf6b30980bd"
GIT_TASK = re.compile(r"^\s*git-\d+\s+(?:\([^)]*\)\s*)?\[")
CLOSE_ENTER = re.compile(r"^(.*\d+\.\d+:\s+)sys_close\(fd: (0x[0-9a-f]+|\d+)\)\s*$")
CLOSE_EXIT = re.compile(r"^(.*\d+\.\d+:\s+)sys_close -> (-?(?:0x[0-9a-f]+|\d+))\s*$")


def guest():
    import bench_workspace_checkout as bench

    tree = bench.GUEST_SOURCE
    limits = bench.guest_limits(2, 1536)
    index_sha = bench.file_sha(tree / ".git/index")
    setting = Path("/sys/module/virtiofs/parameters/workspace_async_release")
    before = bench.guest_clock()
    command = ["git", "-c", f"safe.directory={tree}", "status", "--porcelain=v1", "--untracked-files=all"]
    proc = subprocess.Popen(command, cwd=tree, env=bench.guest_env(2), stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        out, err = proc.communicate(timeout=10)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
    after = time.monotonic_ns()
    bench.require(proc.returncode == 0 and not out and not err, f"Git returned {proc.returncode}: {out!r} {err!r}")
    print(json.dumps({"container_git_pid": proc.pid, "clock": before, "finish_ns": after, "status_ms": (after - before["now_ns"]) / 1e6,
                      "stdout_hex": out.hex(), "stderr_hex": err.hex(), "exit": proc.returncode, "limits": limits,
                      "index_sha256": index_sha, "command": command, "mode": setting.read_text().strip() if setting.is_file() else None,
                      "kernel": os.uname().release}))


def characterize(capture, sample, text):
    import trace_proof as trace

    connection = capture["capture"]["connection"]
    clock = sample["clock"]
    trace.require(capture["capture"]["clock"] == "mono" and clock["offset_ns"] == 0
                  and clock["boot_id"] == capture["capture"]["boot_id"], "expected one monotonic guest clock")
    start, finish = clock["now_ns"], sample["finish_ns"]
    events = trace.parse_events(text)[0]
    lines = text.splitlines()
    sends, ends, git_opens = {}, {}, Counter()
    for event in events:
        if event.name == "fuse_request_send" and (match := trace.SEND.fullmatch(event.body)) and match[1] == connection:
            if not start - 1_000 <= event.ns <= finish:
                continue
            op = match[4].removeprefix("FUSE_")
            # The ftrace PID is in the kernel's namespace. Identify the content
            # reader by its Git task name and request count inside this one exec.
            if op == "OPEN" and GIT_TASK.match(lines[event.line - 1]):
                git_opens[event.pid] += 1
            sends[match[2]] = event, op
        elif event.name == "fuse_request_end" and (match := trace.END.fullmatch(event.body)) and match[1] == connection:
            ends[match[2]] = event, int(match[4])

    trace.require(git_opens and git_opens.most_common(1)[0][1] >= 1058, "trace did not identify the stock Git content reader")
    (pid, _), = git_opens.most_common(1)
    main_sends = sorted(event.ns for event, _ in sends.values() if event.pid == pid)
    close_enter = None
    closes = []
    for event in events:
        if event.pid == pid and start <= event.ns <= finish:
            if event.name == "sys_enter_close":
                close_enter = event
            elif event.name == "sys_exit_close" and close_enter is not None:
                closes.append((close_enter, event))
                close_enter = None
    close_lines = [event.line for event, _ in closes]
    timings, all_activity = defaultdict(list), defaultdict(list)
    errors = defaultdict(Counter)
    overlap, unpaired, other = Counter(), Counter(), Counter()
    inside_close, after_close, close_times = 0, 0, []
    for req, (event, op) in sends.items():
        if event.pid != pid:
            other[op] += 1
        if req not in ends:
            unpaired[op] += 1
            continue
        end, errno = ends[req]
        all_activity[op].append(end.ns - event.ns)
        if event.pid != pid:
            continue
        timings[op].append(end.ns - event.ns)
        if errno:
            errors[op][str(errno)] += 1
        # Use strictly interior timestamps because ftrace displays microseconds.
        if bisect_left(main_sends, end.ns) - bisect_left(main_sends, event.ns + 1) > 0:
            overlap[op] += 1
        if op == "RELEASE":
            close_index = bisect_left(close_lines, event.line) - 1
            if close_index >= 0 and event.line < closes[close_index][1].line:
                enter, leave = closes[close_index]
                inside_close += 1
                after_close += end.ns > leave.ns
                close_times.append(leave.ns - enter.ns)
    trace.require(len(all_activity["READ"]) >= 1058 and len(timings["OPEN"]) >= 1058 and len(all_activity["RELEASE"]) >= 1058,
                  "trace did not capture the Mac-author-index content scan")
    return {"kernel_git_pid": pid, "main_thread": {op: trace.distribution(values) for op, values in timings.items()},
            "all_threads_and_scoped_activity": {op: trace.distribution(values) for op, values in all_activity.items()},
            "other_threads_and_scoped_sends": dict(other), "main_errors": errors, "unpaired": dict(unpaired),
            "main_next_send_before_this_reply": dict(overlap),
            "close": {"captured_main_calls": len(closes), "release_sent_inside_call": inside_close,
                      "release_replied_after_close_returned": after_close, "calls_with_release": trace.distribution(close_times)}}


def analyze_capture(directory, token, sample):
    import trace_proof as trace

    started = trace.info(directory / ".trace-started", token)
    done = trace.info(directory / ".trace-done", token)
    event_file = directory / ".trace-events"
    trace.require(event_file.stat().st_size <= trace.CAPTURE_LIMIT, "capture exceeds analysis bound")
    names = (".trace-events", ".trace-stats", ".trace-observer.log")
    raw = {name: (directory / name).read_bytes() for name in names}
    # The syscall trace points have custom text renderers. Translate only these
    # two anchored forms to event names for the old parser and keep each line
    # number, timestamp and task unchanged. The original files stay intact.
    rows = []
    normalized = Counter()
    for row in raw[".trace-events"].decode().splitlines():
        if match := CLOSE_ENTER.fullmatch(row):
            row = f"{match[1]}sys_enter_close: fd={match[2]}"
            normalized["enter"] += 1
        elif match := CLOSE_EXIT.fullmatch(row):
            row = f"{match[1]}sys_exit_close: ret={match[2]}"
            normalized["exit"] += 1
        rows.append(row)
    text = "\n".join(rows)
    capture = trace.reconcile(started, done, text, raw[".trace-stats"].decode())
    capture["raw_files_sha256"] = {name: hashlib.sha256(data).hexdigest() for name, data in raw.items()}
    capture["normalized_close_lines"] = dict(normalized)
    trace.require(capture["complete"], f"incomplete FUSE trace: {capture['problems']!r}")
    return capture, characterize(capture, sample, text)


def reanalyze(argv):
    parser = argparse.ArgumentParser(description="Reconcile retained raw events without touching a worker")
    for name in ("prior", "raw", "observer", "out"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args(argv)
    sys.path.insert(0, str(args.observer))
    prior = json.loads(args.prior.read_bytes())
    sample = prior["traced_sample"]
    capture, metrics = analyze_capture(args.raw, prior["capture"]["capture"]["token"], sample)
    if capture["raw_files_sha256"] != prior["capture"]["raw_files_sha256"]:
        raise RuntimeError("retained trace differs from the initial receipt")
    with args.out.open("x") as output:
        json.dump({"trace_complete": True, "prior_failure": prior["failure"], "traced_sample": sample,
                   "capture": capture, "git_fuse": metrics}, output, indent=2)
        output.write("\n")


def host(args, report):
    import bench_workspace_checkout as bench
    import bench_workspace_runner as runner
    import trace_proof as trace
    from bench_workspace_edits import LABEL

    scope = "mp-raw-release-" + token_hex(6)
    token = token_hex(8)
    arm = bench.Arm(args.engine, args.socket, args.image)
    args.cpus, args.memory_mib = 2, 1536
    image = bench.image_identity(args.image_manifest, [arm.image_id])
    query = [*arm.docker, "ps", "-aq", "--filter", f"label={LABEL}={scope}"]
    with TemporaryDirectory(prefix=scope + "-", dir=args.workspace) as temporary:
        stage = Path(temporary)
        tree, head = runner.prepare_checkout(stage, args.source)
        fixture = runner.inventory(tree)
        bench.require(fixture["files"] == 1058 and fixture["tree_sha256"] == TREE_SHA, "different fixture")
        shutil.copyfile(Path(__file__), stage / DRIVER.name)
        initial = bench.file_sha(tree / ".git/index")
        report.update(scope=scope, image=image, source=fixture, head=head, index_sha256=initial,
                      driver_sha256=bench.file_sha(Path(__file__)), diagnostic_trace=args.trace)
        try:
            with ExitStack() as cleanup:
                arm.start(cleanup, scope, stage, args, set(image.values()))
                command = ["exec", arm.id, "python3", "-B", str(DRIVER), "guest"]
                report["warmup"] = [arm.json(*command, timeout=15) for _ in range(2)]
                sample = None
                if args.trace:
                    trace.require(not any(os.path.lexists(args.workspace / leaf) for leaf in trace.LEAVES), "trace workspace is not fresh")
                    trace.request(args.workspace, ".trace-start.request", token)
                    try:
                        trace.wait_for(args.workspace, ".trace-started", token, timeout=8)
                        sample = arm.json(*command, timeout=15)
                    finally:
                        if (args.workspace / ".trace-started").is_file() and not (args.workspace / ".trace-done").exists():
                            trace.request(args.workspace, ".trace-finished.request", token)
                            trace.wait_for(args.workspace, ".trace-done", token, timeout=10)
                        archive = args.out.parent / (args.out.stem + "-raw")
                        archive.mkdir()
                        for leaf in trace.LEAVES:
                            owned = args.workspace / leaf
                            if owned.is_file() and not owned.is_symlink():
                                shutil.copy2(owned, archive / leaf)
                                owned.unlink()
                    report["traced_sample"] = sample
                    report["capture"], report["git_fuse"] = analyze_capture(archive, token, sample)
                report["untraced_samples"] = [arm.json(*command, timeout=15) for _ in range(args.samples)]
                all_samples = report["warmup"] + report["untraced_samples"] + ([sample] if sample else [])
                bench.require(all(row["index_sha256"] == initial and row["mode"] == args.expected_mode for row in all_samples)
                              and bench.file_sha(tree / ".git/index") == initial, "changed Mac index or wrong kernel switch")
                arm.check_generation()
        finally:
            report["remaining"] = bench.call(query, timeout=10).stdout.decode().splitlines()
    bench.require(not report["remaining"] and not Path(temporary).exists(), "trace fixture did not clean up")


def main():
    if sys.argv[1:] == ["guest"]:
        guest()
        return
    if sys.argv[1:2] == ["reanalyze"]:
        reanalyze(sys.argv[2:])
        return
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("socket", "workspace", "source", "helpers", "observer", "image-manifest", "out"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--engine", choices=("hvf", "orbstack"), default="hvf")
    parser.add_argument("--image", required=True)
    parser.add_argument("--expected-mode", choices=("N", "Y"), default=None)
    parser.add_argument("--samples", type=int, choices=(4, 6), default=6)
    parser.add_argument("--trace", action="store_true")
    args = parser.parse_args()
    if args.out.exists() or not args.socket.is_socket() or not (args.source / "vendor/modules.txt").is_file():
        parser.error("use an explicit live endpoint, fresh receipt and archived vendored fixture")
    for key in ("DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_TLS", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH", "DOCKER_API_VERSION"):
        os.environ.pop(key, None)
    sys.path[:0] = [str(args.helpers), str(args.observer)]
    report = {"passed": False}
    try:
        host(args, report)
        report["passed"] = True
    except Exception as error:
        report["failure"] = repr(error)
        raise
    finally:
        with args.out.open("x") as output:
            json.dump(report, output, indent=2)
            output.write("\n")


if __name__ == "__main__":
    main()
