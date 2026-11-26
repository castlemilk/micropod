"""Qualify wait, stdout/stderr and cleanup through an owned native Docker API."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack, contextmanager
import json
from pathlib import Path
import re
import secrets
import subprocess
import tempfile
from threading import Barrier
import time

from qualify import IMAGE, LABEL, local_admission, require, terminal


PROBE_LABEL = "io.micropod.bench.follow-lifecycle"
RECEIPT = "follow-lifecycle.json"
FAST_CODES = (0, 7, 12, 19, 23, 37)
GATED = '''printf 'ready-out\n'
printf 'ready-err\n' >&2
i=0
until [ -f /follow/release ]; do
    i=$((i+1))
    [ "$i" -lt 600 ] || exit 98
    sleep .05
done
printf 'final-out'
printf 'final-err' >&2
exit 43
'''
FAST = 'printf "%s" "$1"; printf "%s" "$2" >&2; exit "$3"'
KILL = "printf 'kill-ready\\n'; exec sleep 120"
MEMORY = ("grep -E '^(MemTotal|MemAvailable|Shmem|PageTables):' /proc/meminfo; "
          "grep '^oom_kill ' /proc/vmstat; cat /proc/pressure/memory")


@contextmanager
def api(sock, method, path, expected=(200,)):
    client = local_admission.LocalHTTP(sock)
    client.timeout = 25
    try:
        client.request(method, "/v1.47" + path)
        with client.getresponse() as response:
            require(response.status in expected, f"native Docker {method} {path} returned {response.status}")
            yield response
    finally:
        client.close()


def read_json(response):
    raw = response.read(128 * 1024 + 1)
    require(len(raw) <= 128 * 1024, "oversized native Docker lifecycle response")
    return json.loads(raw)


def owned(row, names, owner, token):
    cid = row["Id"]
    labels = row["Config"].get("Labels") or {}
    require(re.fullmatch(r"[a-f0-9]{64}", cid) is not None and row["Name"].lstrip("/") in names
            and labels.get(LABEL) == owner and labels.get(PROBE_LABEL) == token,
            "native lifecycle probe inventory has ambiguous ownership")
    return cid


def inspect(sock, ref, names, owner, token):
    require(re.fullmatch(r"[a-z0-9_-]+", ref) is not None, "unexpected lifecycle probe reference")
    with api(sock, "GET", f"/containers/{ref}/json", (200, 404)) as response:
        if response.status == 404:
            return None
        row = read_json(response)
    cid = owned(row, names, owner, token)
    require(ref in (cid, row["Name"].lstrip("/")), "native inspect returned a different container")
    return row


def flags(cohort, name, token, *, memory="64m", pids=32):
    return ["--name", name, "--pull=never", "--network", "none", "--memory", memory, "--cpus", "1",
            "--pids-limit", str(pids), "--cap-drop", "ALL", "--label", f"{LABEL}={cohort.owner}",
            "--label", f"{PROBE_LABEL}={token}"]


def frame(response):
    header = response.read(8)
    if not header:
        return None
    require(len(header) == 8 and header[0] in (1, 2) and header[1:4] == b"\0" * 3,
            "invalid native Docker multiplexed frame")
    length = int.from_bytes(header[4:], "big")
    require(0 < length <= 4096, "unexpected native lifecycle log frame size")
    data = response.read(length)
    require(len(data) == length, "truncated native Docker multiplexed frame")
    return ("stdout" if header[0] == 1 else "stderr"), data


def ready_frames(response, expected):
    values = {stream: bytearray() for stream in expected}
    while values != expected:
        entry = frame(response)
        require(entry is not None, "lifecycle log stream ended before its live ready marker")
        stream, data = entry
        require(stream in values, "unexpected lifecycle ready stream")
        values[stream].extend(data)
        require(expected[stream].startswith(values[stream]), "unexpected bytes before the lifecycle ready marker")
    return {stream: bytes(data).decode("ascii") for stream, data in values.items()}


def final_frames(response, expected):
    values = {"stdout": bytearray(), "stderr": bytearray()}
    while (entry := frame(response)) is not None:
        stream, data = entry
        values[stream].extend(data)
        require(expected[stream].startswith(values[stream]), "unexpected bytes after releasing the lifecycle probe")
    require(values == expected, "native lifecycle lost the final stdout or stderr bytes")
    return {stream: bytes(data).decode("ascii") for stream, data in values.items()}


def gated(cohort, sock, name, token, gate):
    launch = ["create", *flags(cohort, name, token), "--mount", f"type=bind,src={gate},dst=/follow,readonly",
              "--entrypoint", "/bin/sh", IMAGE, "-ec", GATED]
    cid = cohort.cmd(*launch, timeout=30)
    created = inspect(sock, cid, {name}, cohort.owner, token)
    require(created is not None and created["State"]["Status"] == "created", "probe was not inspected before start")
    wait_path = f"/containers/{cid}/wait?condition=next-exit"
    log_path = f"/containers/{cid}/logs?follow=1&stdout=1&stderr=1"
    with ExitStack() as clients:
        waits, ready = [], []
        for _ in range(2):
            response = clients.enter_context(api(sock, "POST", wait_path))
            waits.append(response)
            ready.append({"status": response.status, "host_unix_ns": time.time_ns()})
        streaming = clients.enter_context(api(sock, "GET", log_path))
        start = time.time_ns()
        cohort.cmd("start", cid, timeout=25)
        live = ready_frames(streaming, {"stdout": b"ready-out\n", "stderr": b"ready-err\n"})
        observed = time.time_ns()
        live_state = inspect(sock, cid, {name}, cohort.owner, token)["State"]
        require(live_state["Status"] == "running" and live_state["Running"] is True,
                "ready log did not come from a running gated container")
        with (gate / "release").open("xb") as release:
            release.write(b"finish\n")
        released = time.time_ns()
        final = final_frames(streaming, {"stdout": b"final-out", "stderr": b"final-err"})
        exits = [read_json(response) for response in waits]
    state = inspect(sock, cid, {name}, cohort.owner, token)["State"]
    require(exits == [{"StatusCode": 43}] * 2 and state["Status"] == "exited" and state["ExitCode"] == 43
            and ready[0]["host_unix_ns"] <= ready[1]["host_unix_ns"] <= start <= observed <= released,
            "native next-exit acknowledgments, output order or exit status differed")
    return {"id": cid, "name": name, "create_argv": launch, "wait_path": wait_path, "logs_path": log_path,
            "wait_headers": ready, "start_requested_unix_ns": start, "ready_observed_unix_ns": observed,
            "released_unix_ns": released, "running_state": live_state, "ready_output": live,
            "final_output": final, "wait_results": exits, "exit_state": state}


def fast_exits(cohort, names, token):
    launch = Barrier(len(names), timeout=10)

    def one(item):
        slot, name, code = item
        stdout, stderr = f"fast-out-{slot}", f"fast-err-{slot}"
        argv = ["run", "--rm", *flags(cohort, name, token), "--entrypoint", "/bin/sh", IMAGE,
                "-ec", FAST, "probe", stdout, stderr, str(code)]
        launch.wait()
        start = time.time_ns()
        result = terminal.invoke(*cohort.engine, *argv, check=False, timeout=30)
        return {"name": name, "argv": argv, "code": result.returncode, "stdout": result.stdout, "stderr": result.stderr,
                "host_started_unix_ns": start, "host_finished_unix_ns": time.time_ns()}

    with ThreadPoolExecutor(max_workers=len(names)) as pool:
        return list(pool.map(one, ((slot, name, code) for slot, (name, code) in
                                   enumerate(zip(names, FAST_CODES, strict=True)))))


def killed(cohort, sock, name, token):
    argv = ["run", "-d", *flags(cohort, name, token), "--entrypoint", "/bin/sh", IMAGE, "-ec", KILL]
    cid = cohort.cmd(*argv, timeout=30)
    with api(sock, "POST", f"/containers/{cid}/wait?condition=not-running") as response:
        with api(sock, "GET", f"/containers/{cid}/logs?follow=1&stdout=1") as logs:
            output = ready_frames(logs, {"stdout": b"kill-ready\n"})
        before = inspect(sock, cid, {name}, cohort.owner, token)["State"]
        require(before["Status"] == "running" and before["Running"] is True, "kill probe did not start")
        outcome = cohort.cmd("kill", cid, timeout=20)
        exit_result = read_json(response)
    state = inspect(sock, cid, {name}, cohort.owner, token)["State"]
    require(outcome == cid and exit_result == {"StatusCode": 137} and state["Status"] == "exited"
            and state["Running"] is False and state["ExitCode"] == 137 and state["OOMKilled"] is False,
            "native Docker kill/wait/inspect disagreed on the observed exit")
    return {"id": cid, "name": name, "argv": argv, "ready_output": output, "running_state": before,
            "kill_reply": outcome, "wait_result": exit_result, "exit_state": state}


def autodispose(cohort, sock, names, token):
    deadline = time.monotonic() + 5
    while True:
        present = [name for name in names if inspect(sock, name, set(names), cohort.owner, token) is not None]
        if not present:
            return list(names)
        require(time.monotonic() < deadline, f"foreground --rm left lifecycle containers: {present}")
        time.sleep(.025)


def memory(cohort):
    cid = cohort.jobs[cohort.count]["id"]
    argv = ["exec", cid, "/bin/sh", "-ec", MEMORY]
    try:
        result = terminal.invoke(*cohort.engine, *argv, check=False, timeout=10)
        return {"argv": argv, "code": result.returncode, "stdout": result.stdout, "stderr": result.stderr}
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"argv": argv, "error": str(error)}


def start_residents(cohort, names, token, receipt):
    deadline = time.monotonic() + 60

    def one(name):
        argv = ["run", "-d", *flags(cohort, name, token, memory="32m", pids=16), "--entrypoint", "/bin/sh",
                IMAGE, "-ec", "exec sleep 180"]
        record = {"name": name, "argv": argv, "host_started_unix_ns": time.time_ns()}
        left = deadline - time.monotonic()
        if left <= 0:
            return {**record, "error": "resident launch deadline exhausted"}
        try:
            result = terminal.invoke(*cohort.engine, *argv, check=False, timeout=min(18, left))
            return {**record, "code": result.returncode, "id": result.stdout.strip(), "stderr": result.stderr,
                    "host_finished_unix_ns": time.time_ns()}
        except (OSError, subprocess.TimeoutExpired) as error:
            return {**record, "error": str(error)}

    with ThreadPoolExecutor(max_workers=8) as pool:
        records = receipt["launches"] = list(pool.map(one, names))
    require(all(row.get("code") == 0 and re.fullmatch(r"[a-f0-9]{64}", row["id"]) for row in records),
            "additional resident containers did not all start")
    extras = [row["id"] for row in records]
    existing = [row["id"] for row in cohort.jobs]
    rows = json.loads(cohort.cmd("inspect", *existing, *extras, timeout=20))
    require([row["Id"] for row in rows] == existing + extras and len(set(existing + extras)) == 112,
            "112-container inventory differs from the owned resident IDs")
    for row, name in zip(rows[len(existing):], names, strict=True):
        require(owned(row, {name}, cohort.owner, token) == row["Id"]
                and row["HostConfig"]["Memory"] == 32 * 1024**2 and row["HostConfig"]["NetworkMode"] == "none",
                "additional resident escaped its private memory/network limits")
    receipt["inventory"] = [{"id": row["Id"], "name": row["Name"], "state": row["State"]} for row in rows]
    require(all(row["State"]["Running"] is True and row["State"]["Status"] == "running" for row in rows),
            "112 containers were not simultaneously resident")


def clean(cohort, sock, names, token):
    selector = ("ps", "-aq", "--no-trunc", "--filter", f"label={PROBE_LABEL}={token}")
    candidates = cohort.cmd(*selector, timeout=15).split()
    removed, prior_states = [], []
    for cid in candidates:
        require(re.fullmatch(r"[a-f0-9]{64}", cid) is not None, "ambiguous cleanup ID")
        row = inspect(sock, cid, names, cohort.owner, token)
        if row is not None:
            prior_states.append({"id": cid, "name": row["Name"], "state": row["State"]})
            with api(sock, "DELETE", f"/containers/{cid}?force=1", (204, 404)) as response:
                if response.status == 204:
                    removed.append(cid)
    require(not cohort.cmd(*selector, timeout=15) and all(
        inspect(sock, name, names, cohort.owner, token) is None for name in sorted(names)), "native lifecycle cleanup incomplete")
    return {"removed": removed, "before_removal": prior_states, "all_absent": True}


def check(folder, cohort, *, extra_residents=0):
    """Run an untimed qualification on the given disposable native worker only."""
    folder = Path(folder)
    scope = Path(json.loads((folder / "plan.json").read_bytes())["scope"]).resolve()
    locations = [Path(str(arg).removeprefix("unix://")).resolve() for arg in cohort.engine
                 if str(arg).startswith("unix://")]
    sock = scope / "a/docker.sock"
    require(cohort.arm == "A" and scope.parent == Path("/private/tmp") and scope.name == cohort.owner
            and re.fullmatch(r"mp-t-[a-z0-9_]{8}", scope.name) and locations == [sock] and sock.is_socket()
            and Path(cohort.work).resolve() == scope / "workspace", "wrong scope for native lifecycle qualification")
    require(type(extra_residents) is int and extra_residents in (0, 48), "expected zero or 48 additional residents")
    if extra_residents:
        config = json.loads((scope / "a/worker.json").read_bytes())
        require(config["memoryMiB"] == 4096 and config["diskGiB"] == 6 and len(cohort.jobs) == 64,
                "112-container check requires the existing private 4 GiB/6 GiB worker and 64 jobs")
    token = secrets.token_hex(6)
    stem = f"{cohort.owner}-follow-{token}"
    names = {f"{stem}-gate", f"{stem}-kill", *(f"{stem}-fast-{i}" for i in range(len(FAST_CODES)))}
    fast_names = [f"{stem}-fast-{i}" for i in range(len(FAST_CODES))]
    residents = [f"{stem}-resident-{i}" for i in range(extra_residents)]
    names.update(residents)
    receipt = {"scope": str(scope), "socket": str(sock), "owner": cohort.owner, "label": PROBE_LABEL,
               "token": token, "started_unix_ns": time.time_ns(), "complete": False}
    try:
        if residents:
            extra = receipt["residents"] = {"expected_total": 112}
            extra["memory_before"] = memory(cohort)
            start_residents(cohort, residents, token, extra)
            extra["memory_when_live"] = memory(cohort)
        with tempfile.TemporaryDirectory(prefix="follow-gate-", dir=cohort.work) as tmp:
            receipt["gated"] = gated(cohort, sock, f"{stem}-gate", token, Path(tmp))
        rows = receipt["foreground_exits"] = fast_exits(cohort, fast_names, token)
        require(all(row["code"] == code and row["stdout"] == f"fast-out-{slot}" and row["stderr"] == f"fast-err-{slot}"
                    for slot, (row, code) in enumerate(zip(rows, FAST_CODES, strict=True)))
                and max(row["host_started_unix_ns"] for row in rows) < min(row["host_finished_unix_ns"] for row in rows),
                "concurrent foreground Docker exit, log bytes or overlap differed")
        receipt["automatically_removed"] = autodispose(cohort, sock, fast_names, token)
        receipt["killed"] = killed(cohort, sock, f"{stem}-kill", token)
    except BaseException as error:
        receipt["error"] = str(error) or type(error).__name__
        raise
    finally:
        try:
            if residents:
                receipt["residents"]["memory_before_cleanup"] = memory(cohort)
            receipt["cleanup"] = clean(cohort, sock, names, token)
            receipt["complete"] = "error" not in receipt
        except Exception as error:
            receipt["cleanup_error"] = str(error)
            raise
        finally:
            receipt["finished_unix_ns"] = time.time_ns()
            terminal.save(folder / RECEIPT, receipt)
    return receipt
