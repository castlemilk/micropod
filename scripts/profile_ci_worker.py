#!/usr/bin/env python3
"""Profile fresh Go containers and prepared Go processes on the same warm CI kernel."""
import argparse
from bisect import bisect_left, bisect_right
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import threading
import time
import uuid

from bench_live_kernel import image_config_digest
from ci_benchmark_store import DEFAULT_DB, store

ROOT = Path(__file__).resolve().parent
GUEST = (ROOT / "ci_profile_guest.py").read_text()
FIXTURE = (ROOT / "bench_package_caches.py").read_text()


def command(args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=180, **kwargs).stdout


def profile(args, record, trace):
    cli = [str(args.micropod.resolve()), "ci"]
    status = json.loads(command([*cli, "status"]))
    docker = ["docker", "--host", status["endpoint"]]
    image = json.loads(command([*docker, "image", "inspect", args.image]))[0]
    if image["Os"] != "linux" or image["Architecture"] != "arm64":
        raise ValueError("A native ARM64 Linux Go/Node/Python image is required")
    image_id = image["Id"]
    info = json.loads(command([*docker, "info", "--format", "{{json .}}"]))
    record.update(worker=status, image=image_id, rounds=args.rounds, clients=args.clients,
                  image_config_digest=image_config_digest(status["endpoint"].removeprefix("unix://"), image_id, image["Architecture"]),
                  kernel=info["KernelVersion"], kernel_trace=args.kernel_trace,
                  cli_sha256=hashlib.sha256(args.micropod.read_bytes()).hexdigest(),
                  guest_script_sha256=hashlib.sha256(GUEST.encode()).hexdigest(),
                  workload_sha256=hashlib.sha256(FIXTURE.encode()).hexdigest(),
                  host_load=os.getloadavg(), batches=[], samples=[])
    scope = "profile-" + uuid.uuid4().hex
    prefix = "micropod-ci-scoped-" + scope + "-"
    label = "io.micropod.profile=" + scope
    base = ["--pull=never", "--network", "none", "--label", label]
    cached = [*cli, "run", "--cache", "npm", "--cache", "go", "--cache-scope", scope]
    start = time.perf_counter()

    def one(op, count=1, mode="overlay"):
        job_id = uuid.uuid4().hex
        flags = ["--cpus", "1", "--memory", "1g"] if op != "raw" else []
        extra = ["--scratch-mib", "256"] if mode == "tmpfs" else []
        if mode == "bytecode":
            extra += ["--cache", "python"]
        t = time.perf_counter()
        row = json.loads(command([*cached, *extra, *base, "--label", "io.micropod.profile.job=" + job_id, *flags, image_id, "python3", "-c", GUEST,
                                  op, FIXTURE, json.dumps(lock), str(count)]))
        row.update(job=job_id, client_start_s=t-start, client_s=time.perf_counter()-t)
        if row["boot"].lower() != status["boot"].lower():
            raise ValueError("The worker kernel changed")
        return row

    def read_samples(stream, ready, errors):
        try:
            for line in stream:
                sample = json.loads(line)
                sample["client_s"] = time.perf_counter() - start
                record["samples"].append(sample)
                ready.set()
        except Exception as error:
            errors.append(str(error))
            ready.set()

    lock = None
    with ExitStack() as cleanup:
        for store_name in ("npm", "gomod", "gobuild", "pycache"):
            name = prefix + store_name
            if command([*docker, "volume", "create", "--label", label, name]).strip() != name:
                raise ValueError("Could not create fixture volume")
            cleanup.callback(command, [*docker, "volume", "rm", name])
        events = record["docker_events"] = []
        event_errors = []
        event_process = subprocess.Popen([*docker, "events", "--since", str(int(time.time())),
            "--filter", "type=container", "--filter", "label=" + label, "--format", "{{json .}}"],
            stdout=subprocess.PIPE, text=True)

        def read_events():
            try:
                for line in event_process.stdout:
                    event = json.loads(line)
                    job = event["Actor"]["Attributes"].get("io.micropod.profile.job")
                    if job and event["Action"] in {"create", "start", "die", "destroy"}:
                        events.append(dict(job=job, action=event["Action"], engine_ns=event["timeNano"],
                                           client_s=time.perf_counter()-start))
            except Exception as error:
                event_errors.append(str(error))

        event_reader = threading.Thread(target=read_events, daemon=True)
        event_reader.start()
        def finish_events():
            event_process.terminate()
            event_process.wait(timeout=5)
            event_reader.join(timeout=5)
            event_process.stdout.close()

        cleanup.callback(finish_events)
        seed = record["seed"] = one("seed")
        lock = seed["lock"]
        # Prime bytecode for the same immutable image and the same imports as a measured job.
        record["bytecode_prime"] = one("job", mode="bytecode")
        record["bytecode_before"] = one("bytecode-audit", mode="bytecode")
        monitor_flags = ["--privileged", "--tmpfs", "/trace"] if args.kernel_trace else ["--cap-drop", "ALL"]
        with subprocess.Popen([*docker, "run", "--rm", "-i", "--read-only", *monitor_flags, *base,
                               image_id, "python3", "-u", "-c", GUEST, "monitor",
                               *(["--kernel-trace"] if args.kernel_trace else [])],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as monitor:
            errors, ready = [], threading.Event()
            reader = threading.Thread(target=read_samples, args=(monitor.stdout, ready, errors), daemon=True)
            reader.start()
            try:
                if not ready.wait(15) or errors:
                    raise ValueError("Guest counters unavailable: " + str(errors))
                for block in range(args.rounds):
                    levels = args.clients[block % len(args.clients):] + args.clients[:block % len(args.clients)]
                    for clients in levels:
                        modes = ["overlay", "tmpfs", "bytecode", "raw"]
                        offset = block % len(modes)
                        for mode in modes[offset:] + modes[:offset]:
                            begin = time.perf_counter()
                            if mode == "raw":
                                rows = [one("raw", clients)]
                                wall = rows[0]["build_s"]
                            else:
                                with ThreadPoolExecutor(max_workers=clients) as pool:
                                    rows = list(pool.map(lambda _: one("job", mode=mode), range(clients)))
                                wall = time.perf_counter() - begin
                            batch = {"round": block+1, "clients": clients, "mode": mode, "seconds": wall,
                                     "begin_s": begin-start, "end_s": time.perf_counter()-start, "jobs": rows}
                            record["batches"].append(batch)
                            print(f"{mode} {clients} jobs in {wall:.3f}s", flush=True)
            finally:
                monitor.stdin.close()
                monitor.wait(timeout=20)
                reader.join(timeout=5)
            if monitor.returncode or errors or reader.is_alive():
                raise RuntimeError("Kernel sampling did not complete")
        record["bytecode_after"] = one("bytecode-audit", mode="bytecode")
        if record["bytecode_before"]["bytecode"] != record["bytecode_after"]["bytecode"]:
            raise ValueError("Warm jobs duplicated or replaced a shared bytecode file")
        audit = record["audit"] = one("audit")
        if audit["inodes"] != seed["inodes"] or audit["sizes"] != seed["sizes"]:
            raise ValueError("Offline jobs changed the package payload identities or cache size")
    if event_errors:
        raise ValueError("Engine event stream failed: " + str(event_errors))
    by_job = {}
    for event in events:
        by_job.setdefault(event["job"], {})[event["action"]] = event["engine_ns"]
    for batch in record["batches"]:
        for job in batch["jobs"]:
            stamps = by_job.get(job["job"], {})
            if not {"create", "start", "die", "destroy"} <= stamps.keys():
                raise ValueError("Incomplete Docker lifecycle for measured job " + job["job"])
            job["engine_phase_s"] = {
                "create_to_start": (stamps["start"] - stamps["create"]) / 1e9,
                "start_to_die": (stamps["die"] - stamps["start"]) / 1e9,
                "die_to_destroy": (stamps["destroy"] - stamps["die"]) / 1e9}
    if json.loads(command([*cli, "status"])) != status:
        raise ValueError("Worker identity changed during profile")
    record["median_s"] = {
        m: {n: statistics.median(b["seconds"] for b in record["batches"] if b["clients"] == n and b["mode"] == m)
            for n in args.clients} for m in ("overlay", "tmpfs", "bytecode", "raw")}
    add_kernel_deltas(record)
    trace.extend(make_trace(record))


def add_kernel_deltas(record):
    """Count only between two kernel samples taken inside the timed workload."""
    samples = record["samples"]
    times = [s["client_s"] for s in samples]
    for batch in record["batches"]:
        first = bisect_left(times, batch["begin_s"])
        end = bisect_right(times, batch["end_s"])
        if end - first < 2:
            continue
        start, stop = samples[first], samples[end - 1]
        def delta(a, b):
            return {name: b[name] - a[name] for name in a.keys() & b.keys()}
        batch["kernel_delta"] = {
            "sampled_s": stop["client_s"] - start["client_s"],
            "samples": end - first,
            "tracepoints": delta(start.get("tracepoints", {}), stop.get("tracepoints", {})),
            "vm": delta(start["vm"], stop["vm"]),
            "pressure_us": {r: delta(start["pressure_us"][r], stop["pressure_us"][r]) for r in stop["pressure_us"]},
            "disk": {d: delta(start["disk"][d], stop["disk"][d]) for d in start["disk"].keys() & stop["disk"].keys()},
        }


def make_trace(record):
    """Keep guest stage durations on the guest clock, anchored to receipt of Docker's start event."""
    events = {}
    for e in record["docker_events"]:
        events.setdefault(e["job"], {})[e["action"]] = e
    trace = []
    for b in record["batches"]:
        for slot, j in enumerate(b["jobs"], start=1):
            trace.append(dict(name=f"{b['mode']} / {b['clients']} Go jobs", ph="X", pid=1, tid=slot,
                              ts=round(j["client_start_s"]*1e6), dur=round(j["client_s"]*1e6),
                              args={k: j[k] for k in ("build_s", "workspace_s", "verify_s", "cpu_stat")}))
            lifecycle = events[j["job"]]
            start = lifecycle["start"]
            for first, last, name in (("create", "start", "Create to start"), ("start", "die", "Running"),
                                      ("die", "destroy", "Remove")):
                interval = lifecycle[last]["engine_ns"] - lifecycle[first]["engine_ns"]
                trace.append(dict(name=name, ph="X", pid=3, tid=slot, ts=round(start["client_s"]*1e6 +
                                  (lifecycle[first]["engine_ns"] - start["engine_ns"])/1000),
                                  dur=round(interval/1000), args={"job": j["job"]}))
            for first, last, name in (("python_entry_ns", "build_start_ns", "Harness and workspace"),
                                      ("build_start_ns", "build_finish_ns", "Go build"),
                                      ("build_finish_ns", "job_finish_ns", "Verify and clean workspace")):
                trace.append(dict(name=name, ph="X", pid=4, tid=slot,
                                  ts=round(start["client_s"]*1e6+(j[first]-start["engine_ns"])/1000),
                                  dur=round((j[last]-j[first])/1000), args={"job": j["job"]}))
    for s in record["samples"]:
        counters = {
            "Guest memory (KiB)": s["memory_kib"],
            "Guest cumulative CPU ticks": dict(zip(("user","nice","system","idle","iowait","irq","softirq","steal"), s["cpu_ticks"])),
            "Kernel tracepoints": s.get("tracepoints", {}),
            "Pressure stall time (microseconds)": {k: v["some"] for k, v in s["pressure_us"].items()},
        }
        for device, values in s["disk"].items():
            counters["Block I/O – " + device] = values
        for name, values in counters.items():
            if values:
                trace.append(dict(name=name, ph="C", pid=2, tid=1, ts=round(s["client_s"]*1e6), args=values))
    return trace


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--micropod", type=Path, default=ROOT.parent / ".build/release/micropod")
    p.add_argument("--image", required=True)
    p.add_argument("--clients", nargs="+", type=int, default=[1, 4, 8, 16, 32])
    p.add_argument("--rounds", type=int, default=3)
    p.add_argument("--out", required=True, type=Path)
    p.add_argument("--database", type=Path)
    p.add_argument("--kernel-trace", action="store_true", help="Collect tracepoint counts inside a private guest tracefs instance")
    args = p.parse_args()
    if not 1 <= args.rounds <= 50 or len(set(args.clients)) != len(args.clients) or any(n < 1 or n > 64 for n in args.clients):
        p.error("Use 1–50 rounds and distinct concurrency levels from 1 to 64")
    args.out.mkdir(parents=True, exist_ok=True)
    run = uuid.uuid4().hex
    record = {"run": run, "passed": False}
    trace = []
    try:
        profile(args, record, trace)
        record["passed"] = True
    except Exception as e:
        record["error"] = str(e)
        raise
    finally:
        (args.out / (run + ".json")).write_text(json.dumps(record) + "\n")
        (args.out / (run + ".trace.json")).write_text(json.dumps({"traceEvents": trace}) + "\n")
        store(args.database or DEFAULT_DB, run, "go-kernel-profile", record)


if __name__ == "__main__":
    main()
