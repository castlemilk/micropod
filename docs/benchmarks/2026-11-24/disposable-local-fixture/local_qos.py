"""Compare Standard and Interactive on two private Terminal-provisioned Micropod VMs (#228.01)."""
import argparse
import json
import math
import os
import platform
import shutil
import subprocess
import sys
import time
from pathlib import Path
from statistics import median

import receiver

relay = receiver.relay
role = relay.host_role
ROLES = {"A": "Standard", "B": "Interactive"}


def signed_worker(build_path):
    build = json.loads(build_path.read_text())
    path = Path(build["worker_executable"])
    relay.require(build["source_revision"] in receiver.study.RUNTIME_REVS and
                  build["signing"]["entitlements"]["com.apple.security.virtualization"] is True and
                  relay.digest(path) == build["worker_executable_sha256"], "unexpected signed stock runtime")
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", path], check=True)
    return build


def receiver_args(runner, files, workspace, oci, clients, folder, opts):
    signed_worker(files["build"])
    probe = workspace / "probe/netbench"
    shutil.copy2(files["role_probe"], probe)
    probe.chmod(0o755)
    relay.require(relay.digest(probe) == role.GUEST_PROBE_SHA256, "wrong guest network observer")
    argv = [sys.executable, "-B", Path(__file__).resolve(), "--build", files["build"], "--tools", clients,
            "--out", folder / "receiver", "--disk-path", runner.root, "--min-free-gib", opts.min_free_gib]
    arms = sorted(ROLES, key=lambda arm: ROLES[arm] != opts.host_role_first)
    launches = []
    order_file = folder / "launch-order.json"
    for arm in arms:
        process_type = ROLES[arm]
        letter = arm.lower()
        launch = {"arm": arm, "process_type": process_type, "start_monotonic_ns": time.monotonic_ns()}
        launches.append(launch)
        receiver.write(order_file, {"requested_first": opts.host_role_first, "launches": launches})
        scope, facts = runner.arm(letter, 2, files, workspace, oci, process_type=process_type)
        launch.update(ready_monotonic_ns=time.monotonic_ns(), guest_facts_sha256=relay.digest(facts))
        receiver.write(order_file, {"requested_first": opts.host_role_first, "launches": launches})
        argv.extend(["--scope-" + letter, scope, "--facts-" + letter, facts])
    return argv


def compare_fixtures(fixtures):
    a, b = fixtures["A"], fixtures["B"]
    for key in ("job_controls_sha256", "image_config", "kernel_image_sha256", "guest_config_sha256",
                "cli_sha256", "engine_version", "cpuset", "route", "service_env_sha256", "service_limits",
                "release", "vmm_executable", "guest_probe_sha256", "guest_probe_mount", "mapped_relay_build"):
        relay.require(a[key] == b[key], "host-role arms differ in " + key)
    for arm, f in fixtures.items():
        relay.require((f["cpus"], f["cpuset"], f["relay_workers"], f["callback_events"], f["read_bytes"]) ==
                      (4, "0-3", 2, 128, 262144), "different VM, worker count, callback or read cap")
        relay.require(f["guest_boot"] == f["boot"] and f["process_type"] == ROLES[arm] and
                      f["spawn_type"] == role.SPAWN_TYPES[ROLES[arm]] and f["route"] == relay.DIRECT_ROUTE and
                      f["kernel_image_sha256"] == relay.STOCK_KERNEL, "live role, boot, kernel or route mismatch")
        relay.require(set(f["pids"]) == {"relay", "vmm"} and len(set(f["pids"].values())) == 2 and
                      set(f["births"]) == set(f["pids"].values()), "missing independent relay or VMM birth")
    for key in ("instance", "worker", "guest_boot", "engine", "id", "name", "address"):
        relay.require(a[key] and b[key] and a[key] != b[key], "fixtures share " + key)
    relay.require(set(a["pids"].values()).isdisjoint(b["pids"].values()), "fixtures share host PIDs")


def measure(args, row, f, path, guard, previous_idle):
    guard()
    current, _ = receiver.scope_fixture(args, row["arm"], process_type=ROLES[row["arm"]])
    relay.require(current == f, "fixture changed before the attempt")
    receiver.await_idle(row, previous_idle, args.ambient_diagnostic, args.idle_wait_seconds, receiver.path_pilot.cpu_idle,
                        guard, lambda: receiver.write(path, row))
    row["guest_before"] = role.guest_sample(relay.command, f)
    relay.require(row["guest_before"]["boot"] == f["boot"], "guest replaced before client")
    row["before"] = relay.snapshot(args.tools, f)
    relay.require(relay.identities(row["before"]) == f["births"], "relay or VMM replaced before client")
    guard()
    row["client_arguments"] = ["http://" + f["address"], f["name"]]
    row.update(started=True, client_start_ns=time.time_ns())
    receiver.write(path, row)
    result = relay.run_in_window([args.tools / "fixed", *row["client_arguments"]], guard, row)
    row.update(client_end_ns=time.time_ns(), exit_code=result.returncode, stdout=result.stdout, stderr=result.stderr)
    row["after"] = relay.snapshot(args.tools, f)
    row["guest_after"] = role.guest_sample(relay.command, f)
    row["guest"] = role.guest_delta(row["guest_before"], row["guest_after"])
    relay.require(relay.identities(row["after"]) == f["births"] and row["guest_after"]["boot"] == f["boot"],
                  "guest or host process replaced during attempt")
    current, _ = receiver.scope_fixture(args, row["arm"], process_type=ROLES[row["arm"]])
    relay.require(current == f, "fixture changed during the attempt")
    guard()
    receiver.score(result, row)
    client = relay.single_port_client(f, row)
    if row["clean"]:
        relay.checked_stream_rates(client, row["mib_s"])
    whole = relay.invocation_bulk_bytes(client, row["clean"])
    if row["delivered_bytes"] > 0:
        row["host"] = {name: relay.process_work(row["before"], row["after"], pid, row["delivered_bytes"],
                                                invocation_bytes=whole) for name, pid in f["pids"].items()}
    delta = row["guest"]["delta"]
    relay.require(delta["tx_bytes"] >= row["delivered_bytes"], "service TX below delivered bulk bytes")
    row["clean"] &= not any(delta[key] for key in role.FAULT_COUNTERS)
    return row["idle_pct"]


def summarize(attempts, pairs, complete, *, ambient=False):
    rows = [r for r in attempts if r["phase"] == "scored"]
    result = {"schedule_complete": complete, "arms": {}}
    for arm in ROLES:
        admitted = [r for r in rows if r["arm"] == arm]
        clean = [r for r in admitted if r["clean"]]
        result["arms"][arm] = {"role": ROLES[arm], "admission_attempts": len(admitted),
                               "client_attempts": sum(r["started"] for r in admitted), "clean": len(clean),
                               "clean_median_MiB_s": median(r["mib_s"] for r in clean) if clean else None}
        if clean:
            result["arms"][arm]["clean_median_by_process"] = {
                proc: {key: median(r["host"][proc][key] for r in clean)
                       for key in ("cpu_s_per_gib", "invocation_cpu_s_per_bulk_gib", "runnable_s_per_s",
                                   "wait_s_per_s")}
                for proc in ("vmm", "relay")}
    if complete and not ambient:
        matched = {(r["pair"], r["arm"]): r for r in rows}
        decision = role.decision(matched, pairs)
        if any(r["clean"] and r["fresh_p95_us"] > 75000 for r in rows):
            decision["reasons"] = sorted(set(decision["reasons"]) | {"fresh p95 exceeded 75 ms"})
            decision["verdict"] = "reject"
        if all(r["clean"] for r in rows):
            ratios = [matched[n, "B"]["mib_s"] / matched[n, "A"]["mib_s"] for n in range(1, pairs + 1)]
            ci = relay.paired_median_interval(ratios)
            decision.update(paired_ratios=ratios, wins=sum(r > 1 for r in ratios),
                            median_paired_change_ci95_pct=[(v - 1) * 100 for v in ci] if ci else None)
        result["screen"] = decision
    return result


def run(args):
    receiver.check_socket_options(args)
    idle_plan = receiver.idle_policy(args.idle_wait_seconds)
    if args.ambient_diagnostic:
        relay.require(args.idle_wait_seconds == 0, "ambient diagnostics require zero idle wait")
        idle_plan.update(ambient_diagnostic=True, idle_policy="observe host idle before each client")
    relay.require(args.pairs >= 4 and args.pairs % 2 == 0 and math.isfinite(args.min_free_gib) and
                  args.min_free_gib >= 12, "need balanced >=4 pairs and a disk floor of at least 12 GiB")
    args.mode = "host-role"
    args.ss = "/mpcheck/ss"
    args.out.mkdir(exist_ok=False)
    roots = {str(args.disk_path.resolve()), str(args.out.resolve())}
    def guard():
        available = {}
        for name in sorted(roots):
            stat = os.statvfs(name)
            available[name] = stat.f_bavail * stat.f_frsize
        with (args.out / "disk.jsonl").open("a") as fp:
            fp.write(json.dumps({"at_ns": time.time_ns(), "available_bytes": available}) + "\n")
        relay.require(min(available.values()) >= args.min_free_gib * 2**30, "effective free disk below floor")
    schedule = relay.plan(args.seed, args.pairs)
    tools = {"fixed": role.CLIENT_SHA256, "rusage": relay.HASHES["rusage"]}
    plan = {"direction": "228.01", "evidence_tier": "local VM", "socket_evidence": args.socket_evidence,
            "arms": ROLES, "seed": args.seed, **idle_plan,
            "schedule": schedule, "min_free_gib": args.min_free_gib, "host_idle_pct_min": 90,
            "pair_idle_gap_pp_max": 5, "fresh_p95_us_max": 75000, "tool_sha256": tools,
            "host": platform.node(), "macos": platform.mac_ver()[0], "hardware_model": relay.command("sysctl", "-n", "hw.model"),
            "fixture_revision": relay.command("git", "-C", receiver.ROOT, "rev-parse", "HEAD"),
            "guest_verifier_revision": relay.command("git", "-C", receiver.KERNEL_STUDY, "rev-parse", "HEAD"),
            "driver_sha256": {p.name: relay.digest(p) for p in (Path(__file__), Path(receiver.__file__),
                                                                  Path(receiver.path_pilot.__file__),
                                                                  Path(__file__).with_name("local_terminal.py"))}}
    for name in ("local_idle.py", "local_socket_route.py") if args.socket_evidence == "route" else ("local_idle.py",):
        plan["driver_sha256"][name] = relay.digest(Path(__file__).with_name(name))
    if args.ambient_diagnostic:
        plan.update(evidence_tier="ambient local VM diagnostic", host_idle_pct_min=None, pair_idle_gap_pp_max=None)
    receiver.write(args.out / "plan.json", plan)
    attempts, fixtures = [], {}
    preflight_passed = False
    complete = False
    error = error_kind = None
    try:
        guard()
        build = signed_worker(args.build)
        receiver.write(args.out / "signed-runtime.json", build)
        for name, sha in tools.items():
            relay.require(relay.digest(args.tools / name) == sha, "unexpected " + name)
        for arm, process_type in ROLES.items():
            scope = getattr(args, "scope_" + arm.lower()).resolve()
            relay.require(scope == args.disk_path.resolve() / "data" / arm.lower(), "expected private local fixture")
            fixtures[arm], _ = receiver.scope_fixture(args, arm, process_type=process_type)
            shutil.copyfile(getattr(args, "facts_" + arm.lower()), args.out / ("guest-" + arm + ".txt"))
            receiver.write(args.out / "fixtures.json", fixtures)
        compare_fixtures(fixtures)
        preflight_passed = True
        if not args.run:
            return
        for phase, blocks in schedule.items():
            for pair, order in enumerate(blocks, 1):
                previous_idle = None
                for arm in order:
                    row = {"arm": arm, "phase": phase, "pair": pair, "clean": False, "started": False,
                           "fresh_failed": None, "fixed_sha256": tools["fixed"]}
                    attempts.append(row)
                    path = args.out / f"{phase}-{pair}-{arm}.json"
                    receiver.write(path, row)
                    try:
                        previous_idle = measure(args, row, fixtures[arm], path, guard, previous_idle)
                        if phase == "warmup":
                            relay.require(row["clean"], "warmup failed delivery or loss checks")
                    except BaseException as exc:
                        row.update(clean=False, error=str(exc) or type(exc).__name__)
                        raise
                    finally:
                        receiver.write(path, row)
        complete = True
    except BaseException as exc:
        error = str(exc) or type(exc).__name__
        error_kind = "host_idle_timeout" if isinstance(exc, receiver.IdleTimeout) else None
        raise
    finally:
        socket_report = receiver.socket_results(args.socket_evidence, fixtures, ROLES)
        receiver.write(args.out / "status.json", {"timing_requested": args.run, "error": error, "error_kind": error_kind,
                       "full_preflight_passed": preflight_passed,
                       "timed_first_attempts": sum(r["started"] for r in attempts), "scored_complete": complete,
                       **socket_report, **idle_plan})
        summary = summarize(attempts, args.pairs, complete, ambient=args.ambient_diagnostic)
        receiver.write(args.out / "summary.json", {**summary, **socket_report, **idle_plan})


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    receiver.add_socket_options(parser)
    receiver.add_idle_options(parser)
    for arg in ("scope-a", "scope-b", "facts-a", "facts-b", "build", "tools", "out", "disk-path"):
        parser.add_argument("--" + arg, type=Path, required=True)
    parser.add_argument("--min-free-gib", type=float, required=True)
    parser.add_argument("--seed", type=int, default=22801)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--ambient-diagnostic", action="store_true", help="record idle and omit the controlled verdict")
    run(parser.parse_args())
