#!/usr/bin/env python3
"""Measure when a running container sees a host edit on a shared workspace."""

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import statistics
import subprocess
import sys
import tempfile
import time
from uuid import uuid4


CASES = ("size", "held", "replace", "unlink")
LABEL = "io.micropod.workspace-bench"
CONTAINER_ID = re.compile(r"[a-f0-9]{64}")


class EditProtocolError(RuntimeError):
    def __init__(self, message, **evidence):
        super().__init__(message)
        self.evidence = evidence


def edit_exit(message, child, output, **evidence):
    out, err = output
    stdout = (out or b"").decode(errors="replace")
    stderr = (err or b"").decode(errors="replace")
    if detail := (stderr or stdout).rstrip():
        message = f"{message}. {detail}"
    return EditProtocolError(message, kind="guest_exit", docker_exit_code=child.returncode,
                             stdout=stdout, stderr=stderr, **evidence)


def marker_data(path):
    try:
        return path.read_text()
    except FileNotFoundError:
        return ""


def wait_marker(path, child):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        data = marker_data(path)
        if data:
            return data
        if child.poll() is not None:
            # The final marker can appear between the read and the exit check.
            data = marker_data(path)
            if data:
                return data
            message = f"guest exited before {path.name}"
            try:
                output = child.communicate(timeout=2)
            except subprocess.TimeoutExpired as error:
                raise edit_exit(message, child, (error.stdout, error.stderr), marker=path.name,
                                output_incomplete=True) from error
            raise edit_exit(message, child, output, marker=path.name)
        time.sleep(0.0005)
    raise EditProtocolError(f"waiting for {path.name}", kind="marker_timeout", marker=path.name)


def apply_edit(path, case):
    if case == "replace":
        tmp = path.with_suffix(".new")
        tmp.write_bytes(b"revision")
        tmp.replace(path)
    elif case == "unlink":
        path.unlink()
    else:
        with path.open("r+b", buffering=0) as f:
            if case == "size":
                f.seek(0, os.SEEK_END)
            f.write(b"revision")


def check_host_edit(path, case):
    if case == "unlink":
        if os.path.lexists(path):
            raise EditProtocolError(f"host path {path.name} survived unlink", kind="host_edit_mismatch")
        return
    try:
        contents = path.read_bytes()
    except FileNotFoundError as error:
        raise EditProtocolError(f"host path {path.name} disappeared after edit", kind="host_edit_mismatch") from error
    if contents != (b"previousrevision" if case == "size" else b"revision"):
        raise EditProtocolError(f"host path {path.name} contains unexpected bytes after edit", kind="host_edit_mismatch")


def host_path_evidence(path, case, edited):
    evidence = {"path": str(path)}
    expected = (b"previousrevision" if case == "size" else b"revision") if edited else b"previous"
    try:
        info = path.lstat()
        evidence.update(present=True, device=info.st_dev, inode=info.st_ino, size=info.st_size)
        evidence["matches_expected"] = (
            not (edited and case == "unlink") and stat.S_ISREG(info.st_mode) and info.st_size == len(expected)
            and path.read_bytes() == expected
        )
    except FileNotFoundError:
        evidence.update(present=False, matches_expected=edited and case == "unlink")
    except OSError as error:
        evidence["error"] = str(error)
    return evidence


def remove_probe(docker, name, settle):
    deadline = time.monotonic() + 20

    def call(*args, **options):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"cleaning up {name}")
        try:
            return subprocess.run([*docker, *args], capture_output=True, text=True, timeout=remaining, **options)
        except subprocess.CalledProcessError as exc:
            raise RuntimeError(f"Docker {args[0]} failed during cleanup: {exc.stderr.strip()}") from exc

    def owned_id():
        rows = call("ps", "-a", "--no-trunc", "--filter", f"label={LABEL}={name}", "--format",
                    '{{.ID}}|{{.Names}}|{{.Label "' + LABEL + '"}}', check=True).stdout.splitlines()
        if not rows:
            return None
        parts = rows[0].split("|")
        if len(rows) != 1 or len(parts) != 3 or parts[1:] != [name, name] or not CONTAINER_ID.fullmatch(parts[0]):
            raise RuntimeError(f"Docker returned an unverified cleanup container for {name}")
        return parts[0]

    # A canceled Docker client can lose its create response before the container appears.
    quiet_until = time.monotonic() + settle
    while True:
        if id_ := owned_id():
            removed = call("rm", "-f", id_)
            if owned_id():
                raise RuntimeError(f"Docker retained {name} after force removal: {removed.stderr.strip()}")
        if time.monotonic() >= quiet_until:
            return
        time.sleep(0.1)


@contextmanager
def guest_probe(docker, name, directory, *args):
    cmd = [*docker, "run", "--rm", "--name", name, "--label", f"{LABEL}={name}", "--pull", "never",
           "--network", "none", "--mount", f"type=bind,src={directory},dst=/bench", "alpine:3.23",
           "/bench/probe", *args]
    child = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        yield child
    finally:
        failed = sys.exc_info()[0] is not None
        errors = []
        try:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=5)
        except Exception as exc:
            errors.append(f"reaping Docker client: {exc}")
        finally:
            child.stdout.close()
            child.stderr.close()
        try:
            remove_probe(docker, name, settle=1 if failed else 0)
        except Exception as exc:
            errors.append(f"removing Docker container: {exc}")
        if errors:
            raise RuntimeError(f"Cleanup failed for {name}. " + ". ".join(errors))


def measure_edits(docker, name, directory, rounds):
    samples = {case: [] for case in CASES}
    phase = "launch"
    path = None
    try:
        with guest_probe(docker, name, directory, "/bench", str(rounds)) as child:
            for i in range(rounds):
                for case in CASES:
                    path = directory / f"{case}-{i}"
                    phase = "wait_ready"
                    wait_marker(path.with_suffix(".ready"), child)
                    start = time.monotonic_ns()
                    apply_edit(path, case)
                    edited = time.monotonic_ns()
                    phase = "wait_done"
                    result = wait_marker(path.with_suffix(".done"), child)
                    acknowledged = time.monotonic_ns()
                    phase = "verify_host"
                    check_host_edit(path, case)
                    samples[case].append({"result": result, "host_ms": round((acknowledged - start) / 1_000_000, 3),
                                          "host_edit_ms": round((edited - start) / 1_000_000, 3),
                                          "after_edit_ack_ms": round((acknowledged - edited) / 1_000_000, 3)})
            phase = "finish"
            path = None
            try:
                out, err = child.communicate(timeout=10)
            except subprocess.TimeoutExpired as error:
                raise EditProtocolError("guest did not exit after all edit checks", kind="guest_exit_timeout",
                                         stdout=(error.stdout or b"").decode(errors="replace"),
                                         stderr=(error.stderr or b"").decode(errors="replace")) from error
            if child.returncode:
                raise edit_exit("guest exited after the last acknowledgement", child, (out, err))
    except EditProtocolError as error:
        failure = {
            "phase": phase, "message": str(error), "completed_checks": sum(map(len, samples.values())),
            "expected_checks": rounds * len(CASES), **error.evidence,
        }
        if path is not None:
            applied = phase in ("wait_done", "verify_host")
            failure.update(case=case, round=i, host_edit_returned=applied,
                           host_path=host_path_evidence(path, case, applied))
        return samples, failure
    return samples, None


def run(args, directory):
    probe = directory / "probe"
    shutil.copy2(args.probe, probe)
    probe.chmod(0o755)
    tree = directory / "tree"
    tree.mkdir()
    digest = hashlib.sha256()
    paths = hashlib.sha256()
    count = 512
    size = 0
    for i in range(count):
        folder = tree / f"pkg{i // 16:03}"
        folder.mkdir(exist_ok=True)
        source = f"package p\nfunc F{i}() int {{ return {i} }}\n".encode()
        path = folder / f"src{i:04}.go"
        path.write_bytes(source)
        digest.update(source)
        paths.update(path.relative_to(tree).as_posix().encode() + b"\0")
        size += len(source)
    for i in range(args.rounds):
        for case in CASES:
            target = directory / f"{case}-{i}"
            target.write_bytes(b"previous")
            past = time.time_ns() - 5_000_000_000
            os.utime(target, ns=(past, past))
    name = "mp-ws-" + uuid4().hex
    docker = ["docker", "--host", args.host]
    samples, edit_failure = measure_edits(docker, name, directory, args.rounds)
    median = {}
    for case, rows in samples.items():
        successful = [r["host_ms"] for r in rows if r["result"] == "observed"]
        median[case] = round(statistics.median(successful), 3) if successful else None
    with guest_probe(docker, name + "-scan", directory, "scan", "/bench/tree") as child:
        out, err = child.communicate(timeout=90)
        if child.returncode:
            raise RuntimeError((out, err))
        scans = json.loads(out)
        if [(r["pass"], r["scheduled_pause_ms"]) for r in scans] != [(1, 0), (2, 0), (3, 50)]:
            raise RuntimeError("workspace scan returned an unexpected pass sequence")
        if any(r["files"] != count or r["bytes"] != size or r["read_bytes"] != size or
               r["sha256"] != digest.hexdigest() or r["path_sha256"] != paths.hexdigest() for r in scans):
            raise RuntimeError("workspace scan returned different lexical paths, sizes or source bytes")
    result = {"samples": samples, "median_observed_ms": median, "scans": scans, "timing_scope": {
                "host_ms": "Host edit through host observation of the guest completion marker, including polling and guest validation",
                "host_edit_ms": "Host edit through return of the host file operation",
                "after_edit_ack_ms": "Return of the host file operation through host observation of the guest completion marker",
                "stat_ms": "Guest lexical directory walk and file stat",
                "read_ms": "Guest open, read and hash of every file in walk order",
            },
            "complete": edit_failure is None and all(r["result"] == "observed" for rows in samples.values() for r in rows)}
    if edit_failure is not None:
        result["edit_failure"] = edit_failure
    return result


def interrupted(signum, _frame):
    raise InterruptedError(f"received signal {signum}")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, help="Docker Unix endpoint")
    parser.add_argument("--workspace", type=Path, required=True, help="worker's configured host workspace")
    parser.add_argument("--probe", type=Path, required=True, help="Linux arm64 build of scripts/workspacebench/main.go")
    parser.add_argument("--rounds", type=int, default=5)
    args = parser.parse_args()
    if not 1 <= args.rounds <= 100:
        parser.error("rounds must be between 1 and 100")
    with tempfile.TemporaryDirectory(prefix="edit-", dir=args.workspace.resolve()) as work:
        result = run(args, Path(work))
    print(json.dumps(result))
    raise SystemExit(0 if result["complete"] else 1)
