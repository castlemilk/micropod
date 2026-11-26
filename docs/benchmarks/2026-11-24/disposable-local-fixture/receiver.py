"""Score a disposable local service with the pinned receiver. Zero load without --run."""
import argparse
import ctypes
import hashlib
import http.client
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import time
import types
from statistics import median

ROOT = Path(__file__).resolve().parents[4]
KERNEL_STUDY = ROOT.parent / "kernel-path-20261122"
sys.path[:0] = [str(ROOT / "scripts/relaybench"), str(KERNEL_STUDY / "scripts")]
from local_idle import IdleTimeout, await_idle, record_idle
import gamma_pilot as relay
import gamma_path_pilot as path_pilot
import gamma_path_study as study


def write(file, value):
    tmp = file.with_suffix(".tmp")
    tmp.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")
    tmp.replace(file)


def add_socket_options(parser):
    parser.add_argument("--socket-evidence", choices=("controller", "route"), default="controller")
    parser.add_argument("--socket-config", type=Path, help="pinned guest configuration for route-only delivery")


def check_socket_options(args):
    if args.socket_evidence == "route":
        relay.require(args.socket_config is not None, "route-only delivery requires the pinned kernel config")
        config = args.socket_config.read_bytes()
        relay.require(hashlib.sha256(config).hexdigest() == path_pilot.CONFIG and
                      b"# CONFIG_INET_DIAG is not set" in config.splitlines(),
                      "route-only delivery requires the stock kernel without INET_DIAG")


def socket_results(method, fixtures, arms):
    confirmed = (method == "controller" and set(fixtures) == set(arms) and
                 all(f.get("accepted_socket_reno_verified") is True for f in fixtures.values()))
    return {"socket_evidence": method, "accepted_socket_reno_verified": confirmed}


def marker(address, name):
    if not re.fullmatch(r"127\.0\.0\.1:[1-9][0-9]{0,4}", address) or int(address.split(":")[1]) > 65535:
        raise ValueError("expected one numeric loopback host port")
    if not name:
        raise ValueError("missing service marker")
    con = http.client.HTTPConnection(address, timeout=3)
    try:
        con.request("GET", "/id")
        r = con.getresponse()
        if r.status != 200 or r.read(len(name.encode()) + 1) != name.encode():
            raise ValueError("published service returned a different marker")
    finally:
        con.close()


FIXED_WORKERS_REV = "5b8ea1a6a79d1741e521c080f968fcf04c591e68"
FIXED_BUILD_CONTROLS = {"read_bytes": 262144, "callback_events_by_workers": {"2": 128, "4": 128},
                        "compile_define": "MICROPOD_BENCH_FIXED_RELAY_BUDGET=1", "binary_selector_verified": True}


def bind_relay_controls(fixture, build, mapped, mode):
    rev = mapped["source_revision"]
    relay.require(rev == build["source_revision"] and
                  mapped["worker_executable_sha256"] == build["worker_executable_sha256"] ==
                  fixture["cli_sha256"] and mapped["mapped_inode"] > 0 and
                  mapped["kernel_image_sha256"] == relay.STOCK_KERNEL, "unbound relay or stock kernel")
    workers = fixture["relay_workers"]
    relay.require(type(workers) is int and workers in (2, 4), "unobserved data-worker count")
    driver_hash = build["source_sha256"]["Sources/CPublishedTCP/PublishedTCP.c"]
    if rev in study.RUNTIME_REVS:
        relay.require(driver_hash == "93d30bc14268a4d759d0ba2c79c6b4cae1665914f7699cdb799087b920f4b815",
                      "legacy relay source does not match its pinned blob")
        callback = 128 if workers == 2 else 24
    else:
        relay.require(mode == "workers" and rev == FIXED_WORKERS_REV and
                      driver_hash == "c877f1efe9b46a9e80385bf6f8b1a00add0b1671cf8d0d8d8ec02d2d0842990f" and
                      build.get("controlled_relay") == FIXED_BUILD_CONTROLS and fixture.get("callback_events") == 128,
                      "fixed-worker build needs the sealed selector and runtime callback proof")
        callback = 128
    for key, expected in (("callback_events", callback), ("read_bytes", 262144)):
        observed = fixture.get(key)
        relay.require(observed is None or type(observed) is int and observed == expected,
                      f"live {key} conflicts with the exact mapped relay build")
        fixture[key + "_origin"] = "session and mapped build" if observed is not None else "mapped build"
        fixture[key] = expected
    relay.require(callback == 128, "worker count also reduced the data callback budget to 24")
    fixture.update(kernel_image_sha256=mapped["kernel_image_sha256"], mapped_relay_build=mapped)


def abbreviated_kernel_facts(home, facts):
    live = json.loads(relay.command("curl", "--noproxy", "*", "-fsS", "--max-time", "3", "--unix-socket",
                                    str(home / "oci.sock"), "http://localhost/oci/v1/kernel"))
    lines = facts.splitlines()
    relay.require("ethtool_inventory=omitted_in_local_diagnostic" in lines, "missing diagnostic inventory marker")
    path_pilot.verify_stock_kernel(live, facts)
    devices = re.split(r"(?m)^virtio_nic=(\S+)$", facts)
    nics = devices[1::2]
    relay.require(nics and len(nics) == len(set(nics)), "missing or duplicate virtio NIC")
    for nic, detail in zip(nics, devices[2::2]):
        for queue in ("rx", "tx"):
            relay.require(re.search(rf"(?m)^/sys/class/net/{re.escape(nic)}/queues/{queue}-[0-9]+$", detail),
                          f"missing {queue} queue for {nic}")
    return live


def scope_fixture(args, arm, process_type=None):
    scope = getattr(args, "scope_" + arm.lower()).resolve()
    home = scope.parent.parent / (scope / "base").read_text().strip()
    docker = ["docker", "--host", "unix://" + str(home / "docker.sock")]
    vmm = int((scope / "vmm").read_text())
    relay_pid = int((scope / "relay").read_text())
    def scoped_command(*command):
        if command == ("ps", "-p", str(vmm), "-o", "comm="):
            buf = ctypes.create_string_buffer(4096)
            if ctypes.CDLL("/usr/lib/libproc.dylib").proc_pidpath(vmm, buf, len(buf)) <= 0:
                raise ValueError("VMM executable unavailable")
            return os.fsdecode(buf.value)
        if command == ("ps", "-p", str(relay_pid), "-o", "nice="):
            return str(os.getpriority(os.PRIO_PROCESS, relay_pid))
        if command == ("lsof", "-t", str(home / "worker.ext4")):
            return relay.command("lsof", "-nP", "-a", "-p", str(vmm), "-t", command[-1])
        return relay.command(*command)
    # Keep the original exported pilot, and change only the process observation
    # calls in this explicitly local invocation.
    inspect = types.FunctionType(relay.inspect.__code__, dict(relay.inspect.__globals__, command=scoped_command),
                                 relay.inspect.__name__, relay.inspect.__defaults__)
    inspect.__kwdefaults__ = relay.inspect.__kwdefaults__
    if process_type is None:
        want_workers = 2 if arm == "A" else 4
        fixture = inspect(scope, 4, False, worker_count=want_workers)
    else:
        relay.require(process_type in ("Standard", "Interactive"), "unrecognized launchd process type")
        want_workers = 2
        fixture = inspect(scope, 4, False, process_type=process_type)
        fixture["relay_nice"] = int(scoped_command("ps", "-p", str(relay_pid), "-o", "nice="))
    relay.require(fixture["relay_workers"] == want_workers, "live worker count differs from the requested arm")
    fixture["worker_disk_holder_check"] = "exact named VMM PID holds the worker disk"
    relay.require(fixture["route"] == relay.DIRECT_ROUTE, "different publication path")
    path_pilot.single_service(relay, docker, fixture["id"])
    raw = getattr(args, "facts_" + arm.lower()).read_bytes()
    if getattr(args, "abbreviated_inventory", False):
        relay.require(args.mode == "baseline" and process_type is None, "abbreviated inventory is baseline-only")
        boot = abbreviated_kernel_facts(home, raw.decode())
        fixture["nic_offload_readback"] = "unknown; abbreviated guest inventory"
    else:
        boot = path_pilot.kernel_facts(relay, home, raw.decode())
        fixture["nic_offload_readback"] = "TSO and GRO in guest inventory"
    fixture.update(boot=boot["boot"], guest_config_sha256=path_pilot.CONFIG,
                   guest_inventory_sha256=hashlib.sha256(raw).hexdigest(),
                   guest_reported_sched_ext="sched_ext" in boot)
    study.verify_stock_guest_inventory(raw.decode(), fixture)
    receipt = json.loads(args.build.read_text())
    accepted = set(study.RUNTIME_REVS)
    if args.mode == "workers":
        accepted.add(FIXED_WORKERS_REV)
    attest = types.FunctionType(path_pilot.live_attestation.__code__,
                                dict(path_pilot.live_attestation.__globals__, RUNTIME_REVS=accepted))
    mapped = attest(relay, fixture, receipt, path_pilot.STOCK)
    bind_relay_controls(fixture, receipt, mapped, args.mode)
    evidence = args.out / f"socket-{arm}-{time.time_ns()}"
    if args.socket_evidence == "route":
        import local_socket_route
        local_socket_route.observe(relay, docker, fixture, evidence.with_suffix(".json"))
    else:
        path_pilot.socket_proof(relay, docker, fixture, args.ss, evidence_path=evidence.with_suffix(".ss.txt"))
    fixture.update(socket_evidence=args.socket_evidence, accepted_socket_reno_verified=args.socket_evidence == "controller")
    fixture["births"] = relay.identities(relay.snapshot(args.tools, fixture))
    return fixture, docker


def equal_workers(fixtures):
    a, b = fixtures["A"], fixtures["B"]
    for key in ("image_config", "kernel_image_sha256", "guest_config_sha256", "cli_sha256",
                "engine_version", "cpus", "cpuset", "route", "service_env_sha256", "callback_events",
                "job_controls_sha256", "relay_nice", "read_bytes", "service_limits", "release"):
        relay.require(a[key] == b[key], f"worker arms differ in {key}")
    relay.require(a["read_bytes"] is not None, "missing relay read cap")
    relay.require(a["instance"] != b["instance"] and a["worker"] != b["worker"] and
                  set(a["pids"].values()).isdisjoint(b["pids"].values()), "worker fixtures share a VM/process")


def score(result, row, *, host_counters=True):
    c = json.loads(result.stdout)
    row["client"] = c
    start, end = row["client_start_ns"], row["client_end_ns"]
    relay.require(type(start) is int and type(end) is int and 0 < start < end, "invalid client timestamps")
    if host_counters:
        before = row.get("before", {}).get("epoch_ns")
        after = row.get("after", {}).get("epoch_ns")
        relay.require(type(before) is int and type(after) is int and 0 < before <= start < end <= after,
                      "host counter snapshots do not bracket the client invocation")
    elapsed = end - start
    relay.require(0 < c["window_s"] <= elapsed / 1e9, "invalid measured time")
    rate = study.fixed_bulk_rate(c)
    relay.require(math.isfinite(rate), "invalid bulk throughput")
    n = c["arrivals"]
    relay.require((n, c["period_us"], c["streams"]) == (240, 25000, 32), "workload differs")
    p95, p99 = c["fresh_p95_us"], c["fresh_p99_us"]
    # Fresh requests may finish during drain after the six-second bulk window.
    wall_us = elapsed // 1000
    good_tails = (0 < p95 <= p99 and p95 <= wall_us - 12 * 25000 and
                  p99 <= wall_us - 2 * 25000 and
                  0 <= c["dispatch_p95_us"] <= c["dispatch_max_us"] <= wall_us and
                  c["dispatch_p95_us"] <= p95)
    errors = c["errors"]
    known = isinstance(errors, list) or errors is None
    row.update(mib_s=rate, delivered_bytes=c["bytes"], reopened=c["reopened"], fresh_p95_us=p95,
               fresh_p99_us=p99, arrivals=n, fresh_failed=(
                   len(errors or []) if known and all('/id"' in e for e in errors or []) and
                   study.complete_bulk_streams(c) else None))
    if "fresh_p50_us" in c:
        row["fresh_p50_us"] = c["fresh_p50_us"]
    row["bulk_streams_with_bytes"] = sum(count > 0 for count in c["per_stream_bytes"])
    row["clean"] = result.returncode == 0 and good_tails and relay.clean_client(c) and study.complete_bulk_streams(c)


def add_idle_options(parser):
    parser.add_argument("--idle-wait-seconds", type=int, default=0, metavar="0..60",
                        help="maximum pre-client settling time for each controlled window")


def idle_policy(seconds):
    relay.require(type(seconds) is int and 0 <= seconds <= 60, "idle wait must be 0 through 60 seconds")
    return {"idle_wait_seconds": seconds,
            "idle_policy": "two consecutive qualifying samples" if seconds else "first observation"}


def run(args):
    check_socket_options(args)
    idle_plan = idle_policy(args.idle_wait_seconds)
    if args.tools is None:
        args.tools = Path("/private/tmp/mp-priority.b3sbI7ym" if args.mode == "baseline"
                          else "/private/tmp/mp-invocation-tools.F16fmn/tools")
    args.out.mkdir(parents=True, exist_ok=False)
    if not math.isfinite(args.min_free_gib) or args.min_free_gib <= 0:
        raise ValueError("supply the actual positive disk floor for this disposable fixture")
    checks = []
    def guard():
        available = shutil.disk_usage(args.disk_path).free
        checks.append({"at_ns": time.time_ns(), "available_bytes": available})
        relay.require(available >= args.min_free_gib * 2**30, "local free disk fell below the selected floor")
        return None

    fixtures, dockers, attempts, idles = {}, {}, [], {}
    endpoint_only = args.endpoint is not None
    relay.require(not endpoint_only or args.socket_evidence == "controller", "route-only delivery needs a complete VM fixture")
    socket_method = "endpoint-only" if endpoint_only else args.socket_evidence
    ambient_idle = endpoint_only or args.ambient_diagnostic
    relay.require(not ambient_idle or args.idle_wait_seconds == 0, "ambient runs require zero idle wait")
    diagnostic = ambient_idle or args.abbreviated_inventory
    if args.abbreviated_inventory and (endpoint_only or args.mode != "baseline"):
        raise ValueError("--abbreviated-inventory requires a full-scope baseline")
    if endpoint_only and (args.scope_a or args.scope_b or not args.marker or args.mode != "baseline"):
        raise ValueError("endpoint-only measurement needs one marker and baseline mode")
    if not endpoint_only and (not args.scope_a or not args.facts_a or not args.build):
        raise ValueError("full preflight needs --scope-a, --facts-a and --build")
    if args.mode == "workers" and (not args.scope_b or not args.facts_b or args.pairs < 4 or args.pairs % 2):
        raise ValueError("matched workers need fixture B and an even number of at least four pairs")
    orders = {"warmup": ["A"], "scored": ["A"]} if args.mode == "baseline" else relay.plan(args.seed, args.pairs)
    tools = dict(relay.HASHES)
    if args.mode == "workers":
        tools["fixed"] = relay.host_role.CLIENT_SHA256
    metadata = {"tool_sha256": tools, "mode": args.mode, "origin": "independent disposable local fixture", "host": platform.node(),
                "evidence": ("loopback endpoint only" if endpoint_only else
                             "local VM diagnostic with abbreviated guest NIC inventory" if args.abbreviated_inventory else
                             "ambient local VM diagnostic" if diagnostic else "local VM with stock idle gate"),
                "ambient_diagnostic": ambient_idle, "abbreviated_inventory": args.abbreviated_inventory,
                "socket_evidence": socket_method,
                "idle_floor_pct": 90, "paired_idle_gap_max_pp": 5, **idle_plan,
                "minimum_free_GiB": args.min_free_gib, "disk_path": str(args.disk_path.resolve()),
                "seed": args.seed, "order": orders, "source_revision": subprocess.check_output(
                    ["git", "-C", ROOT, "rev-parse", "HEAD"], text=True).strip(),
                "verifier_revision": subprocess.check_output(
                    ["git", "-C", KERNEL_STUDY, "rev-parse", "HEAD"], text=True).strip(),
                "verifier_sha256": relay.digest(Path(path_pilot.__file__)),
                "adapter_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    metadata["idle_verifier_sha256"] = relay.digest(Path(__file__).with_name("local_idle.py"))
    if socket_method == "route":
        metadata["route_verifier_sha256"] = relay.digest(Path(__file__).with_name("local_socket_route.py"))
    write(args.out / "plan.json", metadata)
    pending = True
    failure = failure_kind = None
    try:
        guard()
        for tool, expected in tools.items():
            if tool == "rusage" and endpoint_only:
                continue
            relay.require(relay.digest(args.tools / tool) == expected, f"unexpected {tool}")
        if endpoint_only:
            marker(args.endpoint, args.marker)
            fixtures["A"] = {"address": args.endpoint, "name": args.marker}
        else:
            for arm in ("AB" if args.mode == "workers" else "A"):
                fixtures[arm], dockers[arm] = scope_fixture(args, arm)
                (args.out / ("guest-" + arm + ".txt")).write_bytes(getattr(args, "facts_" + arm.lower()).read_bytes())
            if args.mode == "workers":
                equal_workers(fixtures)
        write(args.out / "fixtures.json", fixtures)
        if args.run:
            for phase, blocks in orders.items():
                for i, block in enumerate(blocks, 1):
                    for arm in block:
                        row = {"phase": phase, "pair": i, "arm": arm, "clean": False, "started": False}
                        attempts.append(row)
                        out = args.out / f"{phase}-{i}-{arm}.json"
                        write(out, row)
                        f = fixtures[arm]
                        try:
                            guard()
                            marker(f["address"], f["name"])
                            if not endpoint_only:
                                verified, _ = scope_fixture(args, arm)
                                relay.require(verified == f, "fixture changed since preflight")
                            await_idle(row, idles.get((phase, i)), ambient_idle, args.idle_wait_seconds,
                                       path_pilot.cpu_idle, guard, lambda: write(out, row))
                            idles[phase, i] = row["idle_pct"]
                            guard()
                            if not endpoint_only:
                                row["link_before"] = path_pilot.state(relay, dockers[arm], f["id"])
                                row["before"] = relay.snapshot(args.tools, f)
                                relay.require(relay.identities(row["before"]) == f["births"], "host process replaced")
                            row["client_arguments"] = ["http://" + f["address"], f["name"]]
                            row.update(started=True, client_start_ns=time.time_ns())
                            write(out, row)
                            result = relay.run_in_window([args.tools / "fixed", *row["client_arguments"]], guard, row)
                            row.update(client_end_ns=time.time_ns(), stdout=result.stdout, stderr=result.stderr,
                                       exit_code=result.returncode)
                            if not endpoint_only:
                                row["after"] = relay.snapshot(args.tools, f)
                            guard()
                            if not endpoint_only:
                                row["link_after"] = path_pilot.state(relay, dockers[arm], f["id"])
                                row["link_delta"] = path_pilot.change(row["link_before"], row["link_after"], "macvlan")
                                relay.require(relay.identities(row["after"]) == f["births"], "host process replaced")
                                verified, _ = scope_fixture(args, arm)
                                relay.require(verified == f, "fixture changed during measurement")
                            score(result, row, host_counters=not endpoint_only)
                            if args.mode == "workers":
                                client = relay.single_port_client(f, row)
                                if row["clean"]:
                                    relay.checked_stream_rates(client, row["mib_s"])
                                    relay.invocation_bulk_bytes(client, True)
                            if not endpoint_only:
                                relay.require(row["link_delta"]["mppub0"]["tx_bytes"] >= row["delivered_bytes"],
                                              "guest TX counter below receiver payload")
                                row["clean"] &= all(not rx[k] for rx in row["link_delta"].values()
                                                    for k in ("rx_dropped", "tx_dropped"))
                                whole = (relay.invocation_bulk_bytes(row["client"], row["clean"])
                                         if args.mode == "workers" else None)
                                row["host"] = {role: relay.process_work(row["before"], row["after"], pid,
                                                                        row["delivered_bytes"], invocation_bytes=whole)
                                               for role, pid in f["pids"].items()}
                        except BaseException as e:
                            row.update(clean=False, error=str(e))
                            raise
                        finally:
                            write(out, row)
                        if phase == "warmup":
                            relay.require(row["clean"], "warmup failed acceptance checks")
        pending = False
    except BaseException as error:
        failure = str(error) or type(error).__name__
        failure_kind = "host_idle_timeout" if isinstance(error, IdleTimeout) else None
        raise
    finally:
        scored = [r for r in attempts if r["phase"] == "scored"]
        summary = {"evidence": metadata["evidence"], "schedule_complete": not pending,
                   "results": {k: {"admission_attempts": len([r for r in scored if r["arm"] == k]),
                   "first_attempts": len([r for r in scored if r["arm"] == k and r["started"]]),
                   "clean": len([r for r in scored if r["arm"] == k and r["clean"]]),
                   "clean_median_MiB_s": median(valid) if (valid := [r["mib_s"] for r in scored
                                             if r["arm"] == k and r["clean"]]) else None}
                               for k in fixtures}}
        if args.mode == "workers" and scored and not pending and not diagnostic:
            by_pair = {(r["pair"], r["arm"]): r for r in scored}
            summary["screen"] = relay.screening_result(by_pair, orders["scored"])
        socket_report = socket_results(socket_method, fixtures, "AB" if args.mode == "workers" else "A")
        summary.update(socket_report, **idle_plan)
        write(args.out / "summary.json", summary)
        write(args.out / "disk.json", checks)
        write(args.out / "status.json", {"completed_schedule": not pending, "timed": args.run,
              "started": sum(r["started"] for r in attempts),
              "scored": len([r for r in attempts if r["phase"] == "scored" and r["started"]]),
              "scored_clean": len([r for r in attempts if r["phase"] == "scored" and r["clean"]]),
              "error": failure, "error_kind": failure_kind, "legacy_stock_qualification": False,
              **socket_report, **idle_plan,
              "ambient_diagnostic": ambient_idle, "abbreviated_inventory": args.abbreviated_inventory,
              "local_vm_idle_and_delivery_qualified": bool(scored) and not pending and not diagnostic and
              all(r["clean"] and r.get("idle_gate_passed") for r in attempts)})


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    add_socket_options(p)
    add_idle_options(p)
    p.add_argument("mode", choices=["baseline", "workers"])
    for name in ("scope-a", "scope-b", "facts-a", "facts-b", "build"):
        p.add_argument("--" + name, type=Path)
    p.add_argument("--tools", type=Path)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--disk-path", type=Path, required=True)
    p.add_argument("--min-free-gib", type=float, required=True)
    p.add_argument("--endpoint", help="baseline endpoint-only, loopback host:port, limited attribution")
    p.add_argument("--marker")
    p.add_argument("--ss", default="ss")
    p.add_argument("--pairs", type=int, default=4)
    p.add_argument("--seed", type=int, default=34199)
    p.add_argument("--run", action="store_true")
    p.add_argument("--ambient-diagnostic", action="store_true",
                   help="record host idle and results without admitting them as a stock-controlled VM study")
    p.add_argument("--abbreviated-inventory", action="store_true",
                   help="baseline diagnostic with boot, config and virtio queues but missing NIC offload readback")
    run(p.parse_args())
