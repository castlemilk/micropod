#!/usr/bin/env python3
"""Benchmark the micropod Docker shim against Docker Desktop.

Usage:
    python3 scripts/bench_shim_vs_docker.py unix:///~/.micropod/docker.sock shim \
        [--json out.json] [--baseline bench/baseline.json]

    python3 scripts/bench_shim_vs_docker.py unix:///var/run/docker.sock docker \
        --json bench/docker.json

Measures API latency (ping/version/list/images/inspect/df/stats), full
container lifecycle (create/start/exec create+start/stop/rm), and 10-way
concurrent lifecycle throughput using identical docker-py clients against
both engines.

--json writes machine-readable results for regression tracking; --baseline
loads a previous --json output and reports p50 deltas (exit 1 if any p50
regresses more than 20%).
"""

import argparse
import json
import statistics
import sys
import threading
import time
import uuid

import docker

N_API = 30
N_LIFECYCLE = 10
N_CONCURRENT = 10
REGRESSION_TOLERANCE = 0.20  # p50 may regress up to 20% before failing


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


RESULTS = {}  # label -> {"p50_ms","p95_ms","min_ms","max_ms","n"}


def row(label, samples):
    p50, p95, lo, hi = stats_ms(samples)
    RESULTS[label] = {
        "p50_ms": round(p50, 3), "p95_ms": round(p95, 3),
        "min_ms": round(lo, 3), "max_ms": round(hi, 3), "n": len(samples),
    }
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
    row("system df", [timed(api.df) for _ in range(N_API)])
    row("info", [timed(api.info) for _ in range(N_API)])


def one_lifecycle_full(api, name):
    timings = {}
    timings["create"] = timed(
        lambda: api.create_container("alpine:3.20", ["sleep", "60"], name=name)
    )
    start = time.perf_counter()
    api.start(name)
    timings["start"] = time.perf_counter() - start
    timings["exec create"] = timed(lambda: api.exec_create(name, ["echo", "bench"]))
    timings["exec start"] = timed(lambda: _exec_start_only(api, name))
    timings["logs"] = timed(lambda: list(api.logs(name, stream=False)))
    timings["stop"] = timed(lambda: api.stop(name, timeout=2))
    timings["rm"] = timed(lambda: api.remove_container(name, force=True))
    return timings


def _exec_start_only(api, name):
    exe = api.exec_create(name, ["echo", "bench"])
    api.exec_start(exe)


def lifecycle(api, label):
    print(f"-- Container lifecycle (n={N_LIFECYCLE}, alpine:3.20)", flush=True)
    phases = {}
    roundtrips = []
    for i in range(N_LIFECYCLE):
        name = f"bench-{label}-{uuid.uuid4().hex[:8]}"
        start = time.perf_counter()
        timings = one_lifecycle_full(api, name)
        roundtrips.append(time.perf_counter() - start)
        for phase, seconds in timings.items():
            phases.setdefault(phase, []).append(seconds)
    for phase in ["create", "start", "exec create", "exec start", "logs", "stop", "rm"]:
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
            one_lifecycle_full(api, name)
        except Exception as exc:  # noqa: BLE001
            errors.append(f"{name}: {exc}")

    start = time.perf_counter()
    threads = [threading.Thread(target=worker, args=(i,)) for i in range(N_CONCURRENT)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    wall = time.perf_counter() - start
    RESULTS["concurrent wall (s)"] = {"p50_ms": round(wall * 1000, 1), "n": N_CONCURRENT,
                                      "errors": len(errors)}
    print(f"  {N_CONCURRENT}x create+start+exec+stop+rm in {wall:.2f}s "
          f"({wall / N_CONCURRENT * 1000:.0f}ms/container, {len(errors)} errors)", flush=True)
    for error in errors[:5]:
        print(f"    ERROR {error}", flush=True)


def compare_baseline(path):
    try:
        baseline = json.load(open(path))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"baseline: could not load {path}: {exc}")
        return 0
    base = baseline.get("results", baseline)
    print(f"\n== Baseline comparison ({baseline.get('label', path)}) ==")
    regressions = []
    for label, cur in sorted(RESULTS.items()):
        old = base.get(label)
        if not old or "p50_ms" not in old or "p50_ms" not in cur:
            continue
        delta = (cur["p50_ms"] - old["p50_ms"]) / old["p50_ms"] * 100 if old["p50_ms"] else 0
        flag = "  REGRESSED" if delta > REGRESSION_TOLERANCE * 100 else ""
        print(f"  {label:<34} {old['p50_ms']:8.1f} -> {cur['p50_ms']:8.1f}ms  ({delta:+.0f}%){flag}")
        if flag:
            regressions.append(label)
    if regressions:
        print(f"\n{len(regressions)} p50 regression(s) beyond {REGRESSION_TOLERANCE:.0%}")
        return 1
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("base_url")
    parser.add_argument("label", nargs="?", default="engine")
    parser.add_argument("--json", dest="json_path")
    parser.add_argument("--baseline", dest="baseline_path")
    args = parser.parse_args()

    base_url = args.base_url.replace("~", __import__("os").path.expanduser("~"))
    api = docker.APIClient(base_url=base_url, timeout=120)
    print(f"== {args.label} ({base_url}) ==", flush=True)

    keepers = [f"bench-{args.label}-keeper-{i}" for i in range(3)]
    for name in keepers:
        api.create_container("alpine:3.20", ["sleep", "600"], name=name)
        api.start(name)
    try:
        api_latency(api, keepers)
        lifecycle(api, args.label)
        concurrent(api, args.label)
    finally:
        for name in keepers:
            try:
                api.remove_container(name, force=True)
            except Exception:  # noqa: BLE001
                pass

    if args.json_path:
        payload = {"label": args.label, "base_url": base_url,
                   "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"), "results": RESULTS}
        with open(args.json_path, "w") as fh:
            json.dump(payload, fh, indent=2)
        print(f"\nwrote {args.json_path}")

    if args.baseline_path:
        sys.exit(compare_baseline(args.baseline_path))


if __name__ == "__main__":
    main()
