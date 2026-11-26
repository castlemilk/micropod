"""Measure the parent virtio-net queue around the selected real published-TCP client."""

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from datetime import UTC, datetime
from functools import partial
from pathlib import Path
from statistics import median
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent
sys.path[:0] = [
    str(HERE.parent / "gamma-local-peer"),
    str(HERE.parent / "disposable-local-fixture"),
    str(HERE.parents[3] / "scripts/relaybench"),
]
import local_qos
import local_terminal as terminal
from run import Admission
from score import CANDIDATE, CLIENT, SELECTION, load, receiver, relay, require


def capture(folder, shared, step, guard):
    request_ns = time.time_ns()
    (shared / f"request-{step}").touch(exist_ok=False)
    target = shared / f"sample-{step}"
    deadline = time.monotonic() + 15
    while not target.is_file():
        guard()
        if time.monotonic() > deadline:
            log = (shared / "observer.log").read_text() if (shared / "observer.log").exists() else "no log"
            raise TimeoutError(f"guest NIC sample {step} unavailable: {log}")
        time.sleep(0.05)
    raw = target.read_text()
    received_ns = time.time_ns()
    (folder / f"guest-{step}.txt").write_text(raw)
    return {"request_ns": request_ns, "received_ns": received_ns, "values": parse_sample(raw)}


def parse_sample(raw):
    values = dict(re.findall(r"(?m)^([a-z_0-9]+)=([^\n]+)$", raw))
    driver = dict(re.findall(r"(?m)^\s*([a-z_0-9]+):\s*(\d+)\s*$", raw))
    for key in ("tx_kicks", "tx0_kicks", "rx_kicks", "tx_tx_timeouts"):
        values[key] = int(driver[key])
    for key in (
        "queues",
        "ifindex",
        "tx_bytes",
        "rx_bytes",
        "tx_packets",
        "tx_dropped",
        "rx_dropped",
        "tx_errors",
        "rx_errors",
        "tx_timeout",
    ):
        values[key] = int(values[key])
    require(
        values["driver"] == "virtio_net"
        and values["queues"] == 1
        and values["tx_kicks"] == values["tx0_kicks"],
        "unexpected queue or inconsistent TX kick readback",
    )
    return values


def counters(first, last, fixture, service, row):
    a, b = (sample["values"] for sample in (first, last))
    require(
        first["received_ns"]
        <= row["before"]["epoch_ns"]
        <= row["client_spawn_start_ns"]
        < row["client_reaped_ns"]
        <= row["after"]["epoch_ns"]
        <= last["request_ns"],
        "bad timing brackets",
    )
    require(
        a["boot"] == b["boot"] == fixture["boot"]
        and a["ifindex"] == b["ifindex"] == int(service["iflink"])
        and a["netns"] == b["netns"] != service["netns"]
        and a["address"] == b["address"],
        "parent identity or network namespace changed",
    )
    numeric = (
        "tx_kicks",
        "rx_kicks",
        "tx_packets",
        "tx_bytes",
        "rx_bytes",
        "tx_timeout",
        "tx_tx_timeouts",
        "rx_dropped",
        "tx_dropped",
        "tx_errors",
        "rx_errors",
    )
    delta = {k: b[k] - a[k] for k in numeric}
    require(
        all(v >= 0 for v in delta.values()) and delta["tx_kicks"] and delta["tx_packets"],
        "counters reset or inactive NIC",
    )
    client = relay.single_port_client(fixture, row)
    total = relay.invocation_bulk_bytes(client, row["clean"])
    require(total and delta["tx_bytes"] >= total, "parent interface did not carry the delivered payload")
    for role, pid in fixture["pids"].items():
        work = relay.process_work(row["before"], row["after"], pid, client["bytes"], invocation_bytes=total)
        require(work == row["host"][role], f"host {role} counters differ")
    gib = total / 2**30
    return {
        "delta": delta,
        "delivered_bytes": total,
        "tx_kicks_per_delivered_gib": delta["tx_kicks"] / gib,
        "mib_s": client["mib_s"],
        "fresh_p95_ms": client["fresh_p95_us"] / 1000,
        "vmm_cpu_s_per_delivered_gib": row["host"]["vmm"]["invocation_cpu_s_per_bulk_gib"],
        "total_cpu_s_per_delivered_gib": sum(
            h["invocation_cpu_s_per_bulk_gib"] for h in row["host"].values()
        ),
    }


def medians(rows):
    return {
        k: median(r[k] for r in rows)
        for k in (
            "tx_kicks_per_delivered_gib",
            "mib_s",
            "fresh_p95_ms",
            "vmm_cpu_s_per_delivered_gib",
            "total_cpu_s_per_delivered_gib",
        )
    }


def replay(folder):
    plan = load(folder / "plan.json")
    cleanup = load(folder / "cleanup.json")
    require(
        load(folder / "status.json")["complete"] and not cleanup["retained"] and not cleanup["errors"],
        "incomplete worker measurement",
    )
    require(
        plan["warmups"] == 1
        and plan["measured_windows"] == 4
        and plan["client_sha256"] == CLIENT
        and plan["selected_cli"] == CANDIDATE
        and plan["selection_sha256"] == terminal.digest(SELECTION),
        "unexpected worker plan",
    )
    data = load(folder / "fixture.json")
    fixture, service = data["fixture"], data["service_link"]
    require(
        fixture["cli_sha256"] == CANDIDATE
        and fixture["process_type"] == "Standard"
        and fixture["relay_workers"] == 2
        and fixture["cpus"] == 4
        and fixture["callback_events"] == 128
        and fixture["read_bytes"] == 262144
        and fixture["route"] == relay.DIRECT_ROUTE,
        "changed selected fixture",
    )
    measured = []
    previous = 0
    for i in range(5):
        row = load(folder / f"client-{i}.json")
        before, after = row["nic_before"], row["nic_after"]
        require(
            previous
            <= before["request_ns"]
            <= before["received_ns"]
            < after["request_ns"]
            <= after["received_ns"],
            "nonsequential NIC observations",
        )
        previous = after["received_ns"]
        require(
            row["index"] == i
            and row["phase"] == ("warmup" if i == 0 else "measured")
            and row["fixed_sha256"] == CLIENT
            and row["exit_code"] == 0
            and row["clean"]
            and relay.clean_client(relay.single_port_client(fixture, row))
            and row["idle_gate_passed"]
            and len(row["idle_observations"]) >= 2
            and all(s["eligible"] and s["idle_pct"] >= 90 for s in row["idle_observations"][-2:]),
            "client, first-attempt order or idle gate changed",
        )
        require(
            relay.identities(row["before"])
            == relay.identities(row["after"])
            == {int(pid): birth for pid, birth in fixture["births"].items()},
            "process changed",
        )
        for step, sample in ((2 * i, before), (2 * i + 1, after)):
            require(
                sample["values"] == parse_sample((folder / f"guest-{step}.txt").read_text()),
                "NIC readback differs",
            )
        result = counters(before, after, fixture, service, row)
        require(result == row["metrics"], "saved client metrics differ from counter deltas")
        if i:
            measured.append(result)
    return medians(measured)


def experiment(folder):
    opts = terminal.parse_options(["--mode", "host-role", "--socket-evidence", "route", "--run"])
    files = terminal.fixture_files(opts)
    local_qos.signed_worker(files["build"])
    require(
        terminal.digest(files["cli"]) == CANDIDATE and terminal.digest(files["fixed"]) == CLIENT,
        "wrong build",
    )
    terminal.verify_cache()
    terminal.verify_service(files["netbench_image_tar"])
    terminal.check_archives(files)
    admission = Admission(folder)
    admission.check(force=True)
    runner = terminal.Run(opts, folder, admission)
    try:
        root = runner.root
        terminal.save(folder / "scope.json", {"scope": str(root)})
        workspace, oci, clients = terminal.stage(root, files)
        shared = workspace / "nic-observations"
        shared.mkdir()
        shutil.copy2(HERE / "guest-sample.sh", shared / "observer.sh")
        with (oci / "runner/fixture-facts.sh").open("a") as startup:
            startup.write(
                '\nsh "$MICROPOD_ENGINE_WORKSPACE/nic-observations/observer.sh" </dev/null '
                '>"$MICROPOD_ENGINE_WORKSPACE/nic-observations/observer.log" 2>&1 &\n'
            )
        probe = workspace / "probe"
        shutil.copy2(files["role_probe"], probe / "netbench")
        subprocess.run(
            [
                "go",
                "build",
                "-p",
                "2",
                "-trimpath",
                "-buildvcs=false",
                "-o",
                probe / "service-link",
                HERE / "service-link.go",
            ],
            check=True,
            env=dict(
                os.environ, GOOS="linux", GOARCH="arm64", CGO_ENABLED="0", GOPROXY="off", GOTOOLCHAIN="local"
            ),
        )
        plan = {
            "host": relay.command("hostname"),
            "warmups": 1,
            "measured_windows": 4,
            "idle_floor_pct": 90,
            "client_sha256": CLIENT,
            "selected_cli": CANDIDATE,
            "selection_sha256": terminal.digest(SELECTION),
            "files": {
                p.name: terminal.digest(p)
                for p in (
                    Path(__file__),
                    HERE / "guest-sample.sh",
                    HERE / "service-link.go",
                    probe / "service-link",
                    probe / "netbench",
                    files["ethtool"],
                )
            },
        }
        terminal.save(folder / "plan.json", plan)
        scope, facts = runner.arm("a", 2, files, workspace, oci, process_type="Standard")
        args = SimpleNamespace(
            scope_a=scope,
            facts_a=facts,
            mode="host-role",
            build=files["build"],
            socket_evidence="route",
            out=folder,
            tools=clients,
        )

        def inspect():
            return receiver.scope_fixture(args, "A", process_type="Standard")

        fixture, docker = inspect()
        selected = load(SELECTION)["A"]
        for key in (
            "cli_sha256",
            "kernel_image_sha256",
            "process_type",
            "relay_workers",
            "read_bytes",
            "callback_events",
            "route",
            "service_limits",
            "cpus",
            "image_config",
            "service_env_sha256",
        ):
            require(fixture[key] == selected[key], f"changed selected control {key}")

        def service_link():
            return json.loads(relay.command(*docker, "exec", fixture["id"], "/mpcheck/service-link"))

        service = service_link()
        require(
            service["address"] == receiver.path_pilot.state(relay, docker, fixture["id"])["mppub0"]["mac"],
            "service MAC mismatch",
        )
        terminal.save(folder / "fixture.json", {"fixture": fixture, "service_link": service})
        birth = relay.identities(relay.snapshot(clients, fixture))
        admission.receiver_group = os.getpgrp()

        def guard():
            runner.guard()
            admission.check()

        summaries = []
        for index in range(5):
            path = folder / f"client-{index}.json"
            row = {
                "phase": "warmup" if index == 0 else "measured",
                "arm": "A",
                "index": index,
                "clean": False,
                "fixed_sha256": CLIENT,
            }
            terminal.save(path, row)
            try:
                receiver.await_idle(
                    row,
                    None,
                    False,
                    180,
                    receiver.path_pilot.cpu_idle,
                    guard,
                    partial(terminal.save, path, row),
                )
                row["nic_before"] = capture(folder, shared, 2 * index, guard)
                guard()
                relay.attempt(clients, fixture, birth, row, guard)
                row["nic_after"] = capture(folder, shared, 2 * index + 1, guard)
                require(row["clean"], "dirty client")
                relay.checked_stream_rates(relay.single_port_client(fixture, row), row["mib_s"])
                row["metrics"] = counters(row["nic_before"], row["nic_after"], fixture, service, row)
                guard()
            finally:
                terminal.save(path, row)
            if index:
                summaries.append(row["metrics"])
            print(
                f"{row['phase']} {index}: {row['mib_s']:.0f} MiB/s, "
                f"{row['metrics']['tx_kicks_per_delivered_gib']:.1f} TX kicks/GiB",
                flush=True,
            )
        require(inspect()[0] == fixture and service_link() == service, "fixture changed")
        return medians(summaries)
    finally:
        runner.cleanup()
        require(
            not runner.errors and not runner.contention and not runner.low.is_set(),
            "fixture cleanup or guard failed",
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--run", action="store_true")
    group.add_argument("--replay", type=Path)
    options = parser.parse_args()
    if options.replay:
        print(json.dumps(replay(options.replay), indent=2))
        sys.exit(0)
    for sig in (signal.SIGHUP, signal.SIGTERM):
        signal.signal(sig, terminal.exit_on_signal)
    folder = Path(tempfile.mkdtemp(prefix=datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ-link-"), dir=HERE))
    print(folder, flush=True)
    status = {"complete": False, "started": terminal.now()}
    try:
        with terminal.terminal_lock():
            summary = experiment(folder)
        terminal.save(folder / "summary.json", summary)
        status["complete"] = True
    except (Exception, KeyboardInterrupt) as exc:
        status["error"] = str(exc) or type(exc).__name__
        raise
    finally:
        terminal.save(folder / "status.json", dict(status, ended=terminal.now()))
