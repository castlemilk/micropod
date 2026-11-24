"""Collect a single guest TX diagnostic around the existing fixed-arrival client on Gamma."""
import argparse
import hashlib
import json
import platform
import subprocess
import time
from pathlib import Path

import bql_bounds
import fresh_samples
import gamma_pilot as pilot
import host_role


def verify_identity(event, identity, queue, object_sha):
    wanted = {"boot_id": identity["boot"], "interface": identity["interface"],
              "ifindex": int(identity["ifindex"]), "netns": int(identity["netns"][5:-1]), "queue": queue,
              "mac": identity["address"], "kernel": identity["kernel"], "driver": "virtio_net",
              "object_sha256": object_sha}
    for field, value in wanted.items():
        if type(event.get(field)) is not type(value) or event[field] != value:
            raise ValueError(f"guest TX trace {field} differs from the queue capture")


def read_event(stream, process, check, timeout=12):
    """The transport writes to a regular evidence file. A partial line is never a handshake."""
    deadline = time.monotonic() + timeout
    start = stream.tell()
    while time.monotonic() < deadline:
        check()
        stream.seek(start)
        line = stream.readline(65537)
        if len(line) > 65536:
            raise ValueError("oversize guest TX protocol record")
        if line.endswith(b"\n"):
            value = json.loads(line)
            if not isinstance(value, dict):
                raise ValueError("invalid guest TX protocol record")
            return value
        if process.poll() is not None:
            # The child can finish its final write after readline and before poll.
            stream.seek(start)
            if stream.readline(65537).endswith(b"\n"):
                continue
            raise ValueError("guest TX observer exited without a complete record")
        time.sleep(0.05)
    raise ValueError("guest TX observer did not respond in time")


def verify_sender(event, expected):
    sender = event.get("sender")
    if expected is None:
        if sender is not None:
            raise ValueError("unexpected sender probe in a queue-only capture")
        return
    if (not isinstance(sender, dict) or any(sender.get(k) != v for k, v in expected.items())
            or sender.get("local_port") != 8080
            or any(type(sender.get(k)) is not int or sender[k] <= 0
                   for k in ("tgid", "start_ticks", "netns_inode", "namespace_pid", "local_port"))):
        raise ValueError("sender does not identify the serving container task and TCP port")


def bracket(argv, directory, identity, queue, object_sha, check, measure, receipt, *, expected_sender=None):
    raw = directory / "guest-tx.jsonl"
    check()
    with raw.open("xb") as stdout, (directory / "guest-tx.stderr").open("xb") as stderr, raw.open("rb") as reader:
        process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=stdout, stderr=stderr)
        try:
            ready = read_event(reader, process, check)
            if ready.get("event") != "ready":
                raise ValueError("guest TX observer failed to arm")
            verify_identity(ready, identity, queue, object_sha)
            verify_sender(ready, expected_sender)
            if (any(type(ready.get(k)) is not int for k in ("start_monotonic_ns", "monotonic_ns", "deadline_monotonic_ns"))
                    or not 0 < ready["start_monotonic_ns"] <= ready["monotonic_ns"] < ready["deadline_monotonic_ns"]):
                raise ValueError("missing guest start clock")
            receipt["ready_host_monotonic_ns"] = time.monotonic_ns()
            def still_observing():
                window = check()
                if process.poll() is not None:
                    raise ValueError("guest TX observer exited during the client invocation")
                return window
            still_observing()
            measure(still_observing)
            receipt["client_done_host_monotonic_ns"] = time.monotonic_ns()
            still_observing()
            process.stdin.write(b"stop\n")
            process.stdin.flush()
            result = read_event(reader, process, check)
            process.wait(timeout=5)
            if reader.read(1) or process.returncode != 0 or result.get("event") != "result":
                raise ValueError("unexpected guest TX observer termination")
            verify_identity(result, identity, queue, object_sha)
            verify_sender(result, expected_sender)
            if result.get("sender") != ready.get("sender"):
                raise ValueError("sender process identity changed during capture")
            if (result.get("reason") != "stop" or result.get("complete") is not True
                    or type(result.get("monotonic_ns")) is not int
                    or not ready["monotonic_ns"] < result["monotonic_ns"] <= ready["deadline_monotonic_ns"]):
                raise ValueError("guest TX trace is incomplete or ended outside the requested handshake")
            if any(result.get(k) != ready.get(k) or type(ready.get(k)) is not int
                   for k in ("start_monotonic_ns", "deadline_monotonic_ns")):
                raise ValueError("guest TX observer changed its capture window")
            counts = result["counters"]
            for name in ("attempts", "attempted_bytes", "completed_calls", "tx_ok", "tx_busy", "tx_other",
                         "dql_charged_bytes", "read_errors", "overlaps", "boundary_crossings"):
                if type(counts.get(name)) is not int or counts[name] < 0:
                    raise ValueError("invalid guest TX counters")
            if (counts["attempts"] == 0 or counts["attempts"] != counts["completed_calls"]
                    or counts["completed_calls"] != counts["tx_ok"] + counts["tx_busy"] + counts["tx_other"]
                    or any(counts[k] for k in ("read_errors", "overlaps", "boundary_crossings"))):
                raise ValueError("guest TX call pairs or charge coverage incomplete")
            if expected_sender is not None:
                sender = result["sender_counters"]
                names = ("calls", "requested_bytes", "accepted_bytes", "full_calls", "short_calls", "zero_calls",
                         "error_calls", "read_errors", "oversized_returns")
                if (any(type(sender.get(k)) is not int or sender[k] < 0 for k in names)
                        or sender["calls"] != sum(sender[k] for k in ("full_calls", "short_calls", "zero_calls", "error_calls"))
                        or not 0 < sender["accepted_bytes"] <= sender["requested_bytes"]
                        or not (sender["full_calls"] or sender["short_calls"])
                        or sender["read_errors"] or sender["oversized_returns"]):
                    raise ValueError("inconsistent sender byte accounting")
            receipt["guest_result"] = result
        finally:
            try:
                process.stdin.close()
            except BrokenPipeError:
                pass
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            receipt["observer_exit_code"] = process.returncode
            receipt["observer_raw_sha256"] = pilot.digest(raw)


def collect(args, receipt):
    if platform.node().split(".")[0] != "Gamma-128GB":
        raise ValueError("this fixed-arrival diagnostic requires the scoped Gamma host")
    if not args.observer:
        raise ValueError("supply an already-authorized guest observer command after --")
    admission = host_role.check_window(args.fleet, args.release, [args.scope], time.time(), "guest-tx-trace")
    receipt["admission"] = admission
    previous = admission

    def check():
        nonlocal previous
        now = time.time()
        current = host_role.check_window(args.fleet, args.release, [args.scope], now, "guest-tx-trace")
        for key in ("owner", "reservation", "scopes", "starts_at", "expires_at"):
            if current[key] != admission[key]:
                raise ValueError("diagnostic handoff changed")
        if now >= previous["valid_until_epoch"]:
            raise ValueError("gap in continuous Gamma admission or effective disk clearance")
        previous = current
        return current

    def inspect():
        fixture = pilot.inspect(args.scope, 4, False, process_type="Interactive")
        if (fixture["callback_events"] != 128 or fixture["relay_workers"] != 2
                or fixture["read_bytes"] != 256 * 1024 or fixture["cpuset"] != "0-3"
                or fixture["route"] != pilot.DIRECT_ROUTE or fixture["kernel_image_sha256"] != pilot.STOCK_KERNEL
                or fixture["cli_sha256"] != args.relay_sha256):
            raise ValueError("unexpected relay build, worker count, kernel, route or budget")
        return fixture

    fixture = inspect()
    receipt["fixture"] = fixture
    queue_capture = bql_bounds.decode(args.queue_capture.read_bytes())
    identity = queue_capture["identity"]
    if identity["boot"] != fixture["guest_boot"] or identity["kernel"] != fixture["release"].strip():
        raise ValueError("queue capture differs from the verified service boot or kernel")
    receipt["queue_capture"] = queue_capture
    object_sha = pilot.digest(args.bpf_object)
    receipt["object_sha256"] = object_sha
    fixed = pilot.digest(args.tools / "fixed")
    if fixed not in (host_role.CLIENT_SHA256, fresh_samples.CLIENT_SHA256) or pilot.digest(args.tools / "rusage") != pilot.HASHES["rusage"]:
        raise ValueError("unrecognized offered client or process counter tool")
    row = {"fixed_sha256": fixed, "clean": False}
    receipt["attempt"] = row
    birth = pilot.identities(pilot.snapshot(args.tools, fixture))
    check()
    guest_before = host_role.guest_sample(pilot.command, fixture)
    receipt["guest_before"] = guest_before
    if guest_before["boot"] != fixture["guest_boot"]:
        raise ValueError("guest changed before the diagnostic")
    def service_cgroup():
        sample = json.loads(pilot.command("curl", "--noproxy", "*", "--max-time", "4", "-fsS", "--unix-socket",
                                         fixture["docker_socket"], "http://localhost/containers/" + fixture["id"]
                                         + "/stats?stream=false&micropod-cgroup=1"))
        group = sample.get("micropod_cgroup")
        if sample.get("id") != fixture["id"] or not isinstance(group, str) or not group.startswith("/") or group == "/":
            raise ValueError("running service has no verified workload cgroup")
        return group
    sender_cgroup = None if args.queue_only else service_cgroup()
    expected_sender = None
    if sender_cgroup is not None:
        arguments = b"-listen\0:8080\0-marker\0" + fixture["name"].encode() + b"\0"
        expected_sender = {"cgroup_v2": sender_cgroup, "args_sha256": hashlib.sha256(arguments).hexdigest()}
    def measure(still_observing):
        pilot.attempt(args.tools, fixture, birth, row, still_observing)
    cmd = args.observer[1:] if args.observer[:1] == ["--"] else args.observer
    if not cmd:
        raise ValueError("empty guest observer command")
    bracket(cmd, args.out, identity, queue_capture["tx_queue"], object_sha, check, measure, receipt,
            expected_sender=expected_sender)
    receipt["admission_after"] = check()
    guest_after = host_role.guest_sample(pilot.command, fixture)
    receipt["guest_after"] = guest_after
    receipt["guest_counter_delta"] = host_role.guest_delta(guest_before, guest_after)
    if inspect() != fixture:
        raise ValueError("fixture changed during the guest TX diagnostic")
    if sender_cgroup is not None and service_cgroup() != sender_cgroup:
        raise ValueError("service runtime cgroup changed during capture")
    client = pilot.single_port_client(fixture, row)
    receipt["receiver"] = {"invocation_body_bytes": pilot.invocation_bulk_bytes(client, row["clean"]),
                           "scored_body_bytes": client["bytes"], "client_clean": row["clean"]}
    if not row["clean"]:
        raise ValueError("fixed-arrival client recorded an incomplete or dirty first attempt")
    receipt["status"] = "diagnostic"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for field in ("scope", "release", "fleet", "queue-capture", "bpf-object", "tools", "out"):
        parser.add_argument("--" + field, required=True, type=Path)
    parser.add_argument("--relay-sha256", required=True, help="expected mapped relay build from the owner")
    parser.add_argument("--queue-only", action="store_true", help="explicitly omit service TCP send accounting")
    parser.add_argument("observer", nargs=argparse.REMAINDER, help="argv of the already-authorized guest observer transport")
    args = parser.parse_args()
    args.out.mkdir(mode=0o700, exist_ok=False)
    receipt = {"status": "incomplete", "mode": "guest-tx-trace"}
    try:
        collect(args, receipt)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as exc:
        receipt["error"] = str(exc)
        parser.exit(1, f"Guest TX diagnostic incomplete: {exc}\n")
    finally:
        pilot.save(args.out / "attempt.json", receipt)


if __name__ == "__main__":
    main()
