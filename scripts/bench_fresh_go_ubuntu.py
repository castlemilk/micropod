#!/usr/bin/env python3
"""Measure warm Go commands directly on an ARM Ubuntu kernel, with and without a current output."""

import argparse
import hashlib
import json
import os
import platform
import shutil
import statistics
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from bench_package_caches import MODULE, VERSION, Fixture, command, stores
from ci_profile_guest import go_tools


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(out, levels, rounds, modes):
    release = platform.freedesktop_os_release()
    if release["ID"] != "ubuntu" or platform.machine() != "aarch64" or Path("/.dockerenv").exists():
        raise ValueError("Run directly on an ARM64 Ubuntu VM or physical machine")
    with tempfile.TemporaryDirectory(prefix="micropod-raw-go-") as root:
        root = Path(root)
        fixture = Fixture(root)
        caches = stores(root / "shared")
        seed = fixture.workspace("seed")
        command(
            ["go", "mod", "download", MODULE + "@" + VERSION], seed, fixture.environment(caches, seed=True)
        )
        fixture.go_sum = (seed / "go.sum").read_bytes()
        env = fixture.environment(caches)
        env["GOFLAGS"] = "-trimpath -p=2"
        build = fixture.argv("go")
        response, cold = command(build, seed, env)
        fixture.verify_output("go", seed, env)
        output_hash = sha(seed / "app")
        archive = caches["go-mod-cache"] / "cache/download" / MODULE / "@v" / (VERSION + ".zip")
        inode = archive.stat().st_ino
        if sha(archive) != fixture.zip_digest:
            raise ValueError("The seeded module archive differs from the fixture")
        tools = Path(command(["go", "env", "GOTOOLDIR"], seed, env)[0].stdout.strip())
        bindir = Path(command(["go", "env", "GOROOT"], seed, env)[0].stdout.strip()) / "bin"
        out.update(
            os=release["PRETTY_NAME"],
            kernel=platform.release(),
            architecture=platform.machine(),
            boot=Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
            cpus=len(os.sched_getaffinity(0)),
            memory_kib=int(Path("/proc/meminfo").read_text().splitlines()[0].split()[1]),
            go_version=command(["go", "version"], seed, env)[0].stdout.strip(),
            tool_sha256={p.name: sha(p) for p in (bindir / "go", tools / "compile", tools / "link")},
            output_sha256=output_hash,
            go_sum=fixture.go_sum.decode(),
            module_sha256=fixture.zip_digest,
            rounds=rounds,
            clients=levels,
            cold_seconds=cold,
            cold_tools=go_tools(response.stderr),
            batches=[],
        )
        # Observe real execs separately. A version query by the Go driver is not a compile or link.
        tap = root / "observe"
        tap.write_text("""#!/bin/sh
case "$2" in -V|-V=*) ;; *)
    case "$1" in */compile|*/asm|*/link) echo "${1##*/}" >> "$TOOL_LOG" ;; esac ;;
esac
exec "$@"
""")
        tap.chmod(0o755)
        probe = fixture.workspace("tool-proof")
        probe_env = dict(env, TOOL_LOG=str(root / "tools.log"))
        proof = []
        for clear in (True, True, False):
            if clear:
                (probe / "app").unlink(missing_ok=True)
            Path(probe_env["TOOL_LOG"]).write_text("")
            command([*build[:2], "-toolexec=" + str(tap), *build[2:]], probe, probe_env)
            events = Path(probe_env["TOOL_LOG"]).read_text().splitlines()
            observed = {
                "compile": events.count("compile"),
                "asm": events.count("asm"),
                "link": events.count("link"),
            }
            proof.append(observed)
            fixture.verify_output("go", probe, env)
        if proof[1] != {"compile": 0, "asm": 0, "link": 1} or any(proof[2].values()):
            raise ValueError(f"Actual tool invocation controls failed: {proof}")
        out["tool_exec_control"] = proof

        for rep in range(rounds):
            for n in levels if rep % 2 == 0 else levels[::-1]:
                for mode in modes if rep % 2 == 0 else modes[::-1]:
                    start = time.monotonic()
                    work = [fixture.workspace(f"{rep}-{n}-{mode}-{i}") for i in range(n)]
                    if mode == "output":
                        for path in work:
                            shutil.copy2(seed / "app", path / "app")
                    prepared = time.monotonic()
                    with ThreadPoolExecutor(max_workers=n) as workers:
                        rows = list(workers.map(lambda path: command(build, path, env), work))
                    elapsed = time.monotonic() - prepared
                    counts = [go_tools(p.stderr) for p, _ in rows]
                    expected = {"compile": 0, "asm": 0, "link": int(mode == "source")}
                    if any(c != expected for c in counts):
                        raise ValueError(f"Expected {expected} for {mode} raw jobs: {counts}")
                    for path in work:
                        fixture.verify_output("go", path, env)
                        if sha(path / "app") != output_hash:
                            raise ValueError("Go products differ across isolated native workspaces")
                        shutil.rmtree(path)
                    out["batches"].append(
                        {
                            "round": rep + 1,
                            "clients": n,
                            "mode": mode,
                            "seconds": elapsed,
                            "prepare_s": prepared - start,
                            "go_seconds": [duration for _, duration in rows],
                            "links": n * expected["link"],
                        }
                    )
        if inode != archive.stat().st_ino or sha(archive) != fixture.zip_digest:
            raise ValueError("The offline module archive changed during the jobs")
        out["median_s"] = {
            mode: {
                n: statistics.median(
                    b["seconds"] for b in out["batches"] if b["mode"] == mode and b["clients"] == n
                )
                for n in levels
            }
            for mode in modes
        }
        out["passed"] = True


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--clients", type=int, nargs="+", default=[16, 32])
    p.add_argument("--rounds", type=int, default=5)
    p.add_argument("--modes", choices=["source", "output"], nargs="+", default=["source", "output"])
    args = p.parse_args()
    if (
        not 1 <= args.rounds <= 50
        or len(set(args.clients)) != len(args.clients)
        or any(n < 1 or n > 64 for n in args.clients)
    ):
        p.error("Use unique concurrency levels from 1 to 64 and 1–50 rounds")
    receipt = {"passed": False}
    try:
        run(receipt, args.clients, args.rounds, args.modes)
    finally:
        print(json.dumps(receipt))
