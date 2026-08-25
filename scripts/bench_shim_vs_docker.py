#!/usr/bin/env python3
"""Benchmark the micropod Docker shim against Docker Desktop.

Usage:
    python3 scripts/bench_shim_vs_docker.py unix:///~/.micropod/docker.sock shim
    python3 scripts/bench_shim_vs_docker.py unix:///var/run/docker.sock docker

Measures API latency (ping/version/list/images), full container lifecycle
(create/start/exec/stop/rm), and 10-way concurrent lifecycle throughput using
identical docker-py clients against both engines.
"""

import statistics
import sys
import threading
import time
import uuid

import docker

N_API = 30
N_LIFECYCLE = 10
N_CONCURRENT = 10


def pct(samples, p):
    ordered = sorted(samples)
    index = min(int(len(ordered) * p), len(ordered) - 1)
    return ordered[index]


def stats_ms(samples):
    return (
        statistics.median(samples) * 1000,
        pct(samples, 0.95) * 1000,
        min(samples) * 1000,
        max(samples) * 1000,
    )


def row(label, samples):
    p50, p95, lo, hi = stats_ms(samples)
    print(f"  {label:<34} p50={p50:8.1f}ms  p95={p95:8.1f}ms  min={lo:8.1f}  max={hi:8.1f}", flush=True)


def timed(fn):
    start = time.perf_counter()
    fn()
    return time.perf_counter() - start


def api_latency(api, keep_alive_containers):
    print(f"-- API latency (n={N_API}) with {len(keep_alive_containers)} running containers", flush=True)
    row("ping", [timed(api.ping) for _ in range(N_API)])
    row("version", [timed(api.version) for _ in range(N_API)])
    row("containers/json?all=1", [timed(lambda: api.containers(all=True)) for _ in range(N_API)])
    row("images/json", [timed(api.images) for _ in range(N_API)])
    row("inspect container", [
        timed(lambda: api.inspect_container(keep_alive_containers[0])) for _ in range(N_API)
    ])


def one_lifecycle(api, name):
    """create → start → exec → stop → rm, returns dict of phase timings."""
    timings = {}
    timings["create"] = timed(
        lambda: api.create_container("alpine:3.20", ["sleep", "60"], name=name)
    )
    start = time.perf_counter()
    api.start(name)
    timings["start"] = time.perf_counter() - start

    def run_exec():
        exe = api.exec_create(name, ["echo", "bench"])
        api.exec_start(exe)

    timings["exec echo"] = timed(run_exec)
    timings["stop"] = timed(lambda: api.stop(name, timeout=2))
    timings["rm"] = timed(lambda: api.remove_container(name, force=True))
    return timings


def lifecycle(api, label):
    print(f"-- Container lifecycle (n={N_LIFECYCLE}, alpine:3.20)", flush=True)
    phases = {}
    roundtrips = []
    for i in range(N_LIFECYCLE):
        name = f"bench-{label}-{uuid.uuid4().hex[:8]}"
        start = time.perf_counter()
        timings = one_lifecycle(api, name)
        roundtrips.append(time.perf_counter() - start)
        for phase, seconds in timings.items():
            phases.setdefault(phase, []).append(seconds)
    for phase in ["create", "start", "exec echo", "stop", "rm"]:
        row(phase, phases[phase])
    row("FULL roundtrip", roundtrips)


def concurrent(api, label):
    print(f"-- {N_CONCURRENT} concurrent lifecycles (wall clock)", flush=True)
    errors = []
    barrier = threading.Barrier(N_CONCURRENT)

    def worker(index):
        name = f"bench-{label}-c{index}-{uuid.uuid4().hex[:6]}"
        try:
            barrier.wait()
            one_lifecycle(api, name)
        except Exception as exc:  # noqa: BLE001
            errors.append(f"{name}: {exc}")

    start = time.perf_counter()
    threads = [threading.Thread(target=worker, args=(i,)) for i in range(N_CONCURRENT)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    wall = time.perf_counter() - start
    print(f"  {N_CONCURRENT}x create+start+exec+stop+rm in {wall:.2f}s "
          f"({wall / N_CONCURRENT * 1000:.0f}ms/container, {len(errors)} errors)", flush=True)
    for error in errors[:5]:
        print(f"    ERROR {error}", flush=True)


def main():
    base_url = sys.argv[1].replace("~", __import__("os").path.expanduser("~"))
    label = sys.argv[2] if len(sys.argv) > 2 else "engine"
    api = docker.APIClient(base_url=base_url, timeout=120)
    print(f"== {label} ({base_url}) ==", flush=True)

    keepers = [f"bench-{label}-keeper-{i}" for i in range(3)]
    for name in keepers:
        api.create_container("alpine:3.20", ["sleep", "600"], name=name)
        api.start(name)
    try:
        api_latency(api, keepers)
        lifecycle(api, label)
        concurrent(api, label)
    finally:
        for name in keepers:
            try:
                api.remove_container(name, force=True)
            except Exception:  # noqa: BLE001
                pass


if __name__ == "__main__":
    main()
