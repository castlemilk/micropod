#!/usr/bin/env python3
"""Profile a release app against isolated inventory fixtures, without real VMs.

Stats intentionally fail: mock inventories must never reconcile the user's
persisted metrics. Control pings cross the main actor, so latency catches UI
stalls. RSS is resident memory, not macOS physical footprint.
"""
import argparse
import hashlib
import json
import os
import pathlib
import re
import signal
import socket
import statistics
import subprocess
import tempfile
import time


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int((len(ordered) - 1) * fraction))]


def process_sample(pid):
    line = subprocess.check_output(
        ["/bin/ps", "-p", str(pid), "-o", "rss=", "-o", "time="], text=True
    ).strip().split()
    minutes, seconds = line[1].split(":")
    return int(line[0]) / 1024, int(minutes) * 60 + float(seconds)


def fixture(directory, count):
    entries = []
    for index in range(count):
        name = f"service-{index:05d}"
        entries.append({
            "id": name,
            "configuration": {
                "id": name, "creationDate": "2026-10-01T00:00:00Z",
                "image": {"reference": "docker.io/library/alpine:latest"},
                "labels": {"com.docker.compose.project": f"project-{index % 25:02d}",
                           "com.docker.compose.service": name},
                "resources": {"cpus": 2, "memoryInBytes": 1073741824},
                "networks": [{"network": "default", "options": {}}],
                "publishedPorts": [{"hostPort": 10000 + index, "containerPort": 8080,
                                    "protocol": "tcp", "hostIP": "127.0.0.1"}],
            },
            "status": {"state": "running", "networks": []},
        })
    (directory / "containers.json").write_text(json.dumps(entries))
    (directory / "status.json").write_text(json.dumps({"status": "running"}))
    cli = directory / "container"
    cli.write_text('''#!/bin/sh
case "$1 $2" in
  "system status") exec /bin/cat "$MICROPOD_PROFILE_DIR/status.json" ;;
  "system property") echo '{}' ;;
  "list --all") exec /bin/cat "$MICROPOD_PROFILE_DIR/containers.json" ;;
  "stats "*) exit 1 ;;
  *) echo '[]' ;;
esac
''')
    cli.chmod(0o755)
    return cli


def run_case(app, count, tab, duration, activation_helper=None, footprint=False):
    with tempfile.TemporaryDirectory(prefix="micropod-ui-") as name:
        directory = pathlib.Path(name)
        cli = fixture(directory, count)
        env = os.environ.copy()
        env.update({
            "MICROPOD_PROFILE_DIR": name,
            "MICROPOD_CONTAINER_CLI_PATH": str(cli),
            "MICROPOD_RUNTIME": "cli", "MICROPOD_ENGINES": "apple",
            "MICROPOD_AGENTS_DISABLED": "1",
            "MICROPOD_APP_CONTROL_SOCKET": str(directory / "control.sock"),
            "MICROPOD_AGENT_RUN_DIR": str(directory / "run"),
            "MICROPOD_SHIM_SOCKET": str(directory / "docker.sock"),
            "MICROPOD_SHAREDFS_SOCKET": str(directory / "sharedfs.sock"),
        })
        log = (directory / "app.log").open("wb")
        launched = time.monotonic()
        process = subprocess.Popen([
            str(app), "-cli.manageLinks", "NO", "-SUEnableAutomaticChecks", "NO",
            "-lastTab", tab, "-pollIntervalContainers", "3", "-pollIntervalStats", "5",
            "-onboardingComplete", "YES",
        ], env=env, stdout=log, stderr=log)
        try:
            control = socket.socket(socket.AF_UNIX)
            control.settimeout(15)
            deadline = launched + 30
            while True:
                if process.poll() is not None:
                    raise RuntimeError("app exited during launch")
                try:
                    control.connect(env["MICROPOD_APP_CONTROL_SOCKET"])
                    break
                except (FileNotFoundError, ConnectionRefusedError):
                    if time.monotonic() >= deadline:
                        raise RuntimeError("control socket unavailable")
                    time.sleep(0.05)
            def ping():
                start = time.monotonic()
                control.sendall(b'{"id":"profile","method":"ping"}\n')
                response = bytearray()
                while not response.endswith(b"\n"):
                    data = control.recv(4096)
                    if not data:
                        raise RuntimeError("control socket closed")
                    response.extend(data)
                assert json.loads(response)["result"]["pong"]
                return (time.monotonic() - start) * 1000
            first_ping = ping()
            launch_ready = time.monotonic() - launched
            activation = None
            if activation_helper:
                activation = json.loads(subprocess.check_output(
                    [str(activation_helper), str(process.pid)], text=True))
            time.sleep(4)  # initial inventory and SwiftUI warm-up
            memory_start, cpu_start = process_sample(process.pid)
            started = time.monotonic()
            latencies, memory = [], [memory_start]
            while time.monotonic() - started < duration:
                latencies.append(ping())
                memory.append(process_sample(process.pid)[0])
                time.sleep(0.1)
            memory_end, cpu_end = process_sample(process.pid)
            elapsed = time.monotonic() - started
            result = {
                "count": count, "tab": tab, "duration_seconds": round(elapsed, 3),
                "socket_ready_seconds": round(launch_ready, 3),
                "first_main_actor_ping_ms": round(first_ping, 3),
                "rss_start_mib": round(memory_start, 2), "rss_end_mib": round(memory_end, 2),
                "rss_peak_mib": round(max(memory), 2),
                "cpu_seconds": round(cpu_end - cpu_start, 3),
                "cpu_percent_one_core": round((cpu_end - cpu_start) / elapsed * 100, 2),
                "ping_count": len(latencies),
                "main_actor_ping_p50_ms": round(statistics.median(latencies), 3),
                "main_actor_ping_p95_ms": round(percentile(latencies, 0.95), 3),
                "main_actor_ping_max_ms": round(max(latencies), 3),
            }
            if activation:
                result["activation"] = activation
            if footprint:
                summary = subprocess.check_output(
                    ["/usr/bin/vmmap", "-summary", str(process.pid)], text=True,
                    stderr=subprocess.STDOUT)
                for label, key in [("Physical footprint", "physical_footprint_mib"),
                                   ("Physical footprint (peak)", "physical_footprint_peak_mib")]:
                    match = re.search(re.escape(label) + r":\s+([\d.]+)([KMG])", summary)
                    if match:
                        units = {"K": 1 / 1024, "M": 1, "G": 1024}
                        result[key] = round(float(match[1]) * units[match[2]], 2)
            return result
        finally:
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--counts", type=int, nargs="+", default=[10, 1000])
    parser.add_argument("--tabs", nargs="+", default=["workloads", "dashboard"])
    parser.add_argument("--duration", type=float, default=10)
    parser.add_argument("--rounds", type=int, default=2)
    parser.add_argument("--foreground", action="store_true")
    parser.add_argument("--footprint", action="store_true")
    args = parser.parse_args()
    report = {"binary_sha256": hashlib.sha256(args.app.read_bytes()).hexdigest(),
              "app": str(args.app.resolve()), "fixture_stats_disabled": True,
              "host": subprocess.check_output(["/usr/bin/sw_vers"], text=True).strip(),
              "results": []}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="micropod-profiler-") as support:
        helper = None
        if args.foreground:
            helper = pathlib.Path(support) / "activate"
            subprocess.check_call([
                "clang", "-fobjc-arc", "-framework", "AppKit",
                str(pathlib.Path(__file__).with_name("profile_ui_activation.m")), "-o", str(helper),
            ])
        for iteration in range(args.rounds):
            for count in args.counts:
                for tab in args.tabs:
                    result = run_case(args.app, count, tab, args.duration, helper, args.footprint)
                    result["round"] = iteration + 1
                    report["results"].append(result)
                    args.output.write_text(json.dumps(report, indent=2) + "\n")
                    print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
