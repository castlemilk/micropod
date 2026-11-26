"""Distinguish pending dispatch from a completed one-shot launchd worker."""
import re


def launch_fields(output):
    """Keep only the job's own status, excluding nested endpoint and environment values."""
    fields = {}
    for line in output.splitlines():
        if not line.startswith("\t") or line.startswith("\t\t"):
            continue
        name, separator, value = line[1:].partition(" = ")
        if separator and name in ("state", "runs", "pid", "last exit code", "last terminating signal"):
            fields.setdefault(name, value.strip())
    return fields


def worker_exit(fields):
    """Return evidence of completed execution while waiting for worker readiness."""
    if fields.get("state") not in ("exited", "not running"):
        return None
    runs = fields.get("runs", "")
    if not runs.isdecimal() or int(runs) == 0 or fields.get("pid", "0") != "0":
        return None

    sig = fields.get("last terminating signal", "")
    if re.fullmatch(r"(?:[1-9]\d*|SIG[A-Z0-9]+|[^:]+: [1-9]\d*)", sig):
        return f"signal {sig} after {runs} launchd run(s)"
    code = fields.get("last exit code", "")
    if re.fullmatch(r"-?\d+(?:\s*:\s*\S.*)?", code):
        return f"exit code {code} after {runs} launchd run(s)"
    return None
