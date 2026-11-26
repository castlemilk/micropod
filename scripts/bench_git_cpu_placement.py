#!/usr/bin/env python3
"""Measure stock Git on the same Mac index across guest CPU affinity sets."""

import argparse
from contextlib import ExitStack
import json
import os
from pathlib import Path
from secrets import token_hex
import shutil
import statistics
import subprocess
import sys
from tempfile import TemporaryDirectory
import time


MODES = {"auto": None, "cpu0": {0}, "cpu1": {1}, "cpu01": {0, 1}, "cpu23": {2, 3}}
TREE_SHA = "d963fc6e9f0a6a636fb0819065d7184a05ac9f6c2c3828b0f69afaf6b30980bd"


def guest(mode):
    import bench_workspace_checkout as bench

    limits = bench.guest_limits(2, 1536)
    initial = os.sched_getaffinity(0)
    bench.require(initial == {0, 1, 2, 3}, f"unexpected available CPUs {initial}")
    if MODES[mode] is not None:
        os.sched_setaffinity(0, MODES[mode])
    allowed = os.sched_getaffinity(0)
    bench.require(allowed == (MODES[mode] or initial), "requested CPU set was not applied")
    tree = bench.GUEST_SOURCE
    args = ["git", "-c", f"safe.directory={tree}", "status", "--porcelain=v1", "--untracked-files=all"]
    before = bench.cpu_accounting()
    start = time.monotonic_ns()
    result = subprocess.run(args, cwd=tree, env=bench.guest_env(2), stdin=subprocess.DEVNULL,
                            capture_output=True, timeout=10)
    end = time.monotonic_ns()
    after = bench.cpu_accounting()
    bench.require(result.returncode == 0 and not result.stderr, f"unexpected stock Git result {result.returncode}")
    print(json.dumps({"mode": mode, "cpus": sorted(allowed), "limits": limits, "elapsed_ms": (end - start) / 1e6,
                      "cgroup_cpu_ms": (after["usage_usec"] - before["usage_usec"]) / 1e3,
                      "throttled_ms": (after["throttled_usec"] - before["throttled_usec"]) / 1e3,
                      "stdout_hex": result.stdout.hex(), "index_sha": bench.file_sha(tree / ".git/index")}))


def host(args, report):
    import bench_workspace_checkout as bench
    import bench_workspace_runner as runner
    from bench_workspace_edits import LABEL

    arms = {name: bench.Arm(name, sock, args.image) for name, sock in (("hvf", args.hvf_socket), ("orbstack", args.orbstack_socket))}
    accepted = bench.image_identity(args.image_manifest, [a.image_id for a in arms.values()])
    scope = "mp-git-cpu-" + token_hex(6)
    names = {engine: scope + "-" + engine for engine in arms}
    report.update(scope=scope, image=accepted, driver_sha=bench.file_sha(Path(__file__)), pairs=[], edits=[])
    args.cpus, args.memory_mib = 2, 1536
    with TemporaryDirectory(prefix=scope + "-", dir=args.workspace) as tmp:
        stage = Path(tmp)
        tree, head = runner.prepare_checkout(stage, args.source)
        report.update(source=runner.inventory(tree), head=head, index_sha=bench.file_sha(tree / ".git/index"))
        bench.require(report["source"]["files"] == 1058 and report["source"]["tree_sha256"] == TREE_SHA, "different checkout")
        shutil.copyfile(__file__, stage / Path(__file__).name)

        def sample(arm, mode, expected=b""):
            row = arm.json("exec", arm.id, "python3", "-B", "/checkout-ci/" + Path(__file__).name, "guest", mode, timeout=15)
            bench.require(row["stdout_hex"] == expected.hex() and row["index_sha"] == report["index_sha"], "wrong Git result or index")
            return row

        try:
            with ExitStack() as cleanup:
                for engine, arm in arms.items():
                    arm.start(cleanup, names[engine], stage, args, set(accepted.values()))
                    for mode in MODES:
                        sample(arm, mode)
                modes = tuple(MODES)
                # A Williams design for five conditions consists of five rotations
                # followed by their reverses. Alternate engine order within pairs.
                for r in range(10):
                    order = [(i + r) % 5 for i in (0, 1, 4, 2, 3)]
                    if r >= 5:
                        order.reverse()
                    for pos, i in enumerate(order):
                        engines = list(arms) if (r + pos) % 2 == 0 else list(reversed(arms))
                        row = {"round": r, "mode": modes[i], "order": engines, "samples": {}, "host_start_ns": time.monotonic_ns()}
                        for engine in engines:
                            row["samples"][engine] = sample(arms[engine], modes[i])
                        row["host_end_ns"] = time.monotonic_ns()
                        report["pairs"].append(row)
                path = tree / "main_linux.go"
                stat, original = path.stat(), path.read_bytes()
                try:
                    with path.open("r+b") as f:
                        f.write(bytes([original[0] ^ 1]))
                    os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
                    for engine, arm in arms.items():
                        for mode in MODES:
                            result = sample(arm, mode, b" M main_linux.go\n")
                            report["edits"].append({"engine": engine, "mode": mode, "stdout_hex": result["stdout_hex"]})
                finally:
                    with path.open("r+b") as f:
                        f.write(original[:1])
                    os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
                for arm in arms.values():
                    sample(arm, "auto")
                    arm.check_generation()
        finally:
            report["remaining"] = {eng: bench.call([*arm.docker, "ps", "-aq", "--filter", f"label={LABEL}={names[eng]}"],
                                                   timeout=10).stdout.decode().splitlines() for eng, arm in arms.items()}
    bench.require(not any(report["remaining"].values()) and not stage.exists(), "affinity fixture cleanup incomplete")
    summary = {}
    for engine in arms:
        by_mode = {mode: [p["samples"][engine] for p in report["pairs"] if p["mode"] == mode] for mode in MODES}
        summary[engine] = {mode: {k: statistics.median(s[k] for s in rows) for k in ("elapsed_ms", "cgroup_cpu_ms", "throttled_ms")}
                           for mode, rows in by_mode.items()}
        for mode, rows in by_mode.items():
            summary[engine][mode]["wins_over_auto"] = sum(s["elapsed_ms"] < ref["elapsed_ms"] for s, ref in zip(rows, by_mode["auto"]))
    report["medians"] = summary


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "guest":
        guest(sys.argv[2])
        return
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("hvf-socket", "orbstack-socket", "workspace", "source", "helpers", "image-manifest", "out"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--image", required=True)
    args = parser.parse_args()
    if (args.out.exists() or not args.hvf_socket.is_socket() or not args.orbstack_socket.is_socket()
            or args.hvf_socket.samefile(args.orbstack_socket) or not (args.source / "vendor/modules.txt").is_file()):
        parser.error("select two live local sockets, a vendored checkout and a new receipt")
    sys.path.insert(0, str(args.helpers))
    report = {"passed": False}
    try:
        host(args, report)
        report["passed"] = True
    except Exception as exc:
        report["failure"] = str(exc)
        raise
    finally:
        with args.out.open("x") as output:
            json.dump(report, output, indent=2)
            output.write("\n")


if __name__ == "__main__":
    main()
