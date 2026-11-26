"""Run the selected Micropod configuration and OrbStack on the same Gamma Mac."""

import argparse
import datetime
import gzip
import io
import json
import os
import re
import shutil
import signal
import sys
import tarfile
import tempfile
import time
from functools import partial
from pathlib import Path
from types import SimpleNamespace

from score import (
    CANDIDATE,
    CLIENT,
    HERE,
    SEED,
    SELECTION,
    WAIT,
    load,
    receiver,
    relay,
    require,
    score,
    verify_arms,
)

# The scorer adds the sibling fixture and the original peer verifier to sys.path.
# isort: split
import ambient as ambient_study
import local_admission
import local_qos
import local_terminal as terminal

SOCKET = Path.home() / ".orbstack/run/docker.sock"
DOCKER = ["docker", "--host", "unix://" + str(SOCKET)]


def archive_drivers(folder):
    root = receiver.ROOT.parent
    sources = set()
    for module in tuple(sys.modules.values()):
        path = getattr(module, "__file__", None)
        if path:
            source = Path(path).resolve()
            if source.suffix == ".py" and source.is_relative_to(root):
                sources.add(source)
    pins = load(folder / "plan.json")["driver_sha256"]
    by_name = {source.name: source for source in sources}
    for name, expected in pins.items():
        require(terminal.digest(by_name[name]) == expected, f"{name} changed since admission")
    with (
        (folder / "drivers.tar.gz").open("xb") as stream,
        gzip.GzipFile(fileobj=stream, mode="wb", mtime=0) as compressed,
        tarfile.open(fileobj=compressed, mode="w") as archive,
    ):
        for source in sorted(sources):
            data = source.read_bytes()
            entry = tarfile.TarInfo(str(source.relative_to(root)))
            entry.size = len(data)
            archive.addfile(entry, io.BytesIO(data))


class Admission(local_admission.Admission):
    def __init__(self, folder):
        super().__init__(folder)
        self.orb_id = None
        self.serving = False

    def observe(self, *, force=False):
        if not force and time.monotonic() - self.last_check < 2:
            return
        super().observe(force=force)
        running = [c["Id"] for c in local_admission.read_json(SOCKET, "/containers/json")]
        with (self.folder / "orb-activity.jsonl").open("a") as out:
            out.write(json.dumps({"time": terminal.now(), "running_ids": running}) + "\n")
        require(not running or running == [self.orb_id], "another OrbStack container is active")
        require(not self.serving or running == [self.orb_id], "OrbStack benchmark service stopped")


def orb_scope(root, workspace, admission):
    require(
        relay.command("orbctl", "config", "get", "cpu") == "4"
        and relay.command("orbctl", "config", "get", "memory_mib") == "4096",
        "OrbStack VM configuration differs",
    )
    processes = relay.command("ps", "-A", "-o", "pid=,comm=")
    pids = [
        line.split(None, 1)[0]
        for line in processes.splitlines()
        if line.endswith("/Contents/MacOS/OrbStack Helper")
    ]
    require(len(pids) == 1, "expected one live OrbStack helper")
    scope = root / "data/orb"
    scope.mkdir(parents=True)
    name = root.name + "-orb"
    label = "dev.micropod.benchmark=" + root.name
    require(
        not relay.command(*DOCKER, "ps", "-aq", "--filter", "label=" + label),
        "benchmark label already exists",
    )
    cid = terminal.invoke(
        *DOCKER,
        "create",
        "--pull=never",
        "--name",
        name,
        "--label",
        label,
        "--cidfile",
        root / "orb.cid",
        "--cpus",
        "4",
        "--memory",
        "1g",
        "--pids-limit",
        "512",
        "--mount",
        f"type=bind,src={workspace / 'probe'},dst=/mpcheck,readonly",
        "-p",
        "127.0.0.1::8080",
        terminal.SERVICE,
        "-listen",
        ":8080",
        "-marker",
        name,
    ).stdout.strip()
    require(
        re.fullmatch("[a-f0-9]{64}", cid) and (root / "orb.cid").read_text().strip() == cid,
        "invalid OrbStack container ID",
    )
    admission.orb_id = cid
    terminal.invoke(*DOCKER, "start", cid)
    address = relay.command(*DOCKER, "port", cid, "8080/tcp")
    for key, value in {"base": "orb", "name": name, "id": cid, "vmm": pids[0], "addr": address}.items():
        (scope / key).write_text(value + "\n")
    admission.peer_scopes = (scope,)
    admission.serving = True
    admission.check(force=True)
    return scope


def clean_orb(root, folder):
    label = "dev.micropod.benchmark=" + root.name
    ids = relay.command(*DOCKER, "ps", "-aq", "--no-trunc", "--filter", "label=" + label).splitlines()
    require(len(ids) <= 1, "ambiguous disposable OrbStack identity")
    cid = (root / "orb.cid").read_text().strip() if (root / "orb.cid").exists() else None
    if ids:
        require(
            (cid is None or ids == [cid])
            and relay.command(*DOCKER, "inspect", "--format", "{{.Name}}", ids[0])
            == "/" + root.name + "-orb",
            "refusing removal of an unrelated container",
        )
        cid = ids[0]
        terminal.invoke(*DOCKER, "rm", "-f", cid)
    require(
        not relay.command(*DOCKER, "ps", "-aq", "--filter", "label=" + label), "OrbStack cleanup incomplete"
    )
    terminal.save(folder / "orbstack-cleanup.json", {"id": cid, "removed": True, "label": label})


def study(folder, run, *, ambient=False):
    opts = terminal.parse_options(["--mode", "host-role", "--socket-evidence", "route", "--run"])
    files = terminal.fixture_files(opts)
    local_qos.signed_worker(files["build"])
    require(
        terminal.digest(files["cli"]) == CANDIDATE and terminal.digest(files["fixed"]) == CLIENT,
        "unselected inputs",
    )
    terminal.check_socket_evidence(files["kernel_config"], "route", check_inputs=False)
    identity = terminal.verify_service(files["netbench_image_tar"])
    terminal.check_archives(files)
    terminal.verify_cache()
    seed = ambient_study.SEED if ambient else SEED
    orders = ambient_study.schedule() if ambient else relay.plan(seed, 16)
    wait = 0 if ambient else WAIT
    terminal.save(
        folder / "plan.json",
        {
            "study": "Gamma disposable peer comparison",
            "host": relay.command("hostname"),
            "load_policy": "ambient" if ambient else "controlled",
            "seed": seed,
            "order": orders,
            "candidate": CANDIDATE,
            "process_type": "Standard",
            "relay_workers": 2,
            "vcpus": 4,
            "vm_memory_mib": 4096,
            "callback_events": 128,
            "read_bytes": 262144,
            "tools": dict(relay.HASHES, fixed=CLIENT),
            "min_free_gib": opts.min_free_gib,
            "idle_wait_seconds": wait,
            "idle_floor_pct": None if ambient else 90,
            "paired_idle_gap_pp_max": None if ambient else 5,
            "consecutive_idle_samples": 1 if ambient else 2,
            "socket_evidence": "route",
            "selected_from": str(SELECTION),
            "selected_from_sha256": terminal.digest(SELECTION),
            "image": identity,
            "orbstack_version": relay.command("orbctl", "version"),
            "started": terminal.now(),
            "driver_sha256": {
                path.name: terminal.digest(path)
                for path in map(
                    Path,
                    (
                        __file__,
                        receiver.__file__,
                        relay.__file__,
                        terminal.__file__,
                        local_admission.__file__,
                        HERE / "score.py",
                        ambient_study.__file__,
                    ),
                )
            },
        },
    )
    admission = Admission(folder)
    admission.check(force=True)
    runner = terminal.Run(opts, folder, admission)
    try:
        root = runner.root
        terminal.save(folder / "scope.json", {"scope": str(root)})
        workspace, oci, clients = terminal.stage(root, files)
        for name, sha in dict(relay.HASHES, fixed=CLIENT).items():
            require(terminal.digest(clients / name) == sha, f"wrong staged {name}")
        probe = workspace / "probe/netbench"
        shutil.copy2(files["role_probe"], probe)
        probe.chmod(0o755)
        require(terminal.digest(probe) == relay.host_role.GUEST_PROBE_SHA256, "guest probe changed")
        # The OrbStack engine is already warm. Start the service before the Micropod VM.
        b_scope = orb_scope(root, workspace, admission)
        a_scope, facts = runner.arm("a", 2, files, workspace, oci, process_type="Standard")
        args = SimpleNamespace(
            scope_a=a_scope,
            facts_a=facts,
            mode="host-role",
            build=files["build"],
            socket_evidence="route",
            out=folder,
            tools=clients,
        )
        shutil.copy2(files["build"], folder / "signed-runtime.json")
        admission.receiver_group = os.getpgrp()

        def inspect(arm):
            if arm == "A":
                return receiver.scope_fixture(args, "A", process_type="Standard")[0]
            return relay.inspect(b_scope, 4, True)

        arms = {arm: inspect(arm) for arm in "AB"}
        verify_arms(arms)
        terminal.save(folder / "fixtures-before.json", arms)
        archive_drivers(folder)
        docker = {"A": ["docker", "--host", "unix://" + arms["A"]["docker_socket"]], "B": DOCKER}
        for arm in "AB":
            receiver.path_pilot.single_service(relay, docker[arm], arms[arm]["id"])
        births = {arm: relay.identities(relay.snapshot(clients, f)) for arm, f in arms.items()}

        def guard():
            runner.guard()
            admission.check()

        if run:
            for phase, pairs in orders.items():
                for n, order in enumerate(pairs, 1):
                    previous = None
                    for arm in order:
                        f = arms[arm]
                        path = folder / f"{phase}-{n}-{arm}.json"
                        require(not path.exists(), "first attempt already exists")
                        row = {
                            "arm": arm,
                            "pair": n,
                            "phase": phase,
                            "clean": False,
                            "fresh_failed": None,
                            "fixed_sha256": CLIENT,
                        }
                        terminal.save(path, row)
                        try:
                            require(inspect(arm) == f, f"{arm} fixture changed before window")
                            previous = receiver.await_idle(
                                row,
                                previous,
                                ambient,
                                wait,
                                receiver.path_pilot.cpu_idle,
                                guard,
                                partial(terminal.save, path, row),
                            )
                            before = receiver.path_pilot.state(relay, docker[arm], f["id"])
                            admission.check(force=True)
                            runner.guard()
                            row["guard_before_ns"] = time.time_ns()
                            relay.attempt(clients, f, births[arm], row, guard)
                            runner.guard()
                            admission.check(force=True)
                            row["guard_after_ns"] = time.time_ns()
                            after = receiver.path_pilot.state(relay, docker[arm], f["id"])
                            row["interfaces_before"], row["interfaces_after"] = before, after
                            require(inspect(arm) == f, f"{arm} fixture changed during window")
                            c = relay.single_port_client(f, row)
                            if row["clean"]:
                                relay.checked_stream_rates(c, row["mib_s"])
                            require(phase != "warmup" or row["clean"], "dirty warmup")
                        except BaseException as exc:
                            row["error"] = str(exc) or type(exc).__name__
                            raise
                        finally:
                            terminal.save(path, row)
                        print(
                            f"{phase} {n}/{len(pairs)} {arm} {row['mib_s']:.1f} MiB/s, "
                            f"p95 {row['fresh_p95_us'] / 1000:.2f} ms, clean={row['clean']}",
                            flush=True,
                        )
        final = {arm: inspect(arm) for arm in "AB"}
        require(final == arms, "peer changed since preflight")
        terminal.save(folder / "fixtures-after.json", final)
        guard()
    finally:
        admission.serving = False
        try:
            clean_orb(runner.root, folder)
        finally:
            runner.cleanup()
        require(
            not runner.errors and not runner.contention and not runner.low.is_set(),
            "fixture cleanup or guard failed",
        )


def main():
    p = argparse.ArgumentParser(description=__doc__)
    action = p.add_mutually_exclusive_group(required=True)
    action.add_argument("--check", action="store_true")
    action.add_argument("--run", action="store_true")
    action.add_argument("--ambient", action="store_true", help="run the shorter as-found comparison")
    args = p.parse_args()
    for sig in (signal.SIGHUP, signal.SIGTERM):
        signal.signal(sig, terminal.exit_on_signal)
    stamp = datetime.datetime.now(datetime.UTC).strftime("%Y%m%dT%H%M%SZ")
    action_name = "ambient" if args.ambient else "run" if args.run else "check"
    folder = Path(tempfile.mkdtemp(prefix=f"{stamp}-{action_name}-", dir=HERE))
    print("Peer evidence:", folder, flush=True)
    status = {"complete": False, "action": action_name, "start": terminal.now()}
    try:
        with terminal.terminal_lock():
            study(folder, args.run or args.ambient, ambient=args.ambient)
        status["complete"] = True
    except (Exception, KeyboardInterrupt) as exc:  # noqa: BLE001 -- persist the terminal failure for replay
        status["error"] = str(exc) or type(exc).__name__
        print(status["error"], file=sys.stderr, flush=True)
    finally:
        status["end"] = terminal.now()
        terminal.save(folder / "status.json", status)
    if not status["complete"]:
        return 2
    if args.ambient:
        result = ambient_study.summarize(folder)
        terminal.save(folder / "ambient-summary.json", result)
        print(
            f"Ambient comparison completed with {result['common_clean_pairs']} common clean pairs.",
            flush=True,
        )
        return 0
    if args.run:
        verdict = score(folder)
        terminal.save(folder / "verdict.json", verdict)
        print(verdict["verdict"], verdict["median_ratio"], verdict["bootstrap_ci95"], flush=True)
        return 0 if not verdict["reasons"] else 1
    print("Both fixtures passed live preflight and cleanup.", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
