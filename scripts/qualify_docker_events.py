#!/usr/bin/env python3
"""Check live Docker and Compose event streams, replay filters and disconnect through a selected engine."""

import argparse
from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
from tempfile import TemporaryDirectory
import threading
import time

from qualify_docker_restart import LABEL, Qualification, require


class Stream:
    def __init__(self, fixture, args):
        self.events = []
        self.received = []
        self.error = None
        self.stderr = ""
        self.changed = threading.Condition()
        self.process = subprocess.Popen([*fixture.cli, *args], env=fixture.env, start_new_session=True, stdin=subprocess.DEVNULL,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()

    def read(self):
        try:
            for line in self.process.stdout:
                arrival = {"wall_ns": time.time_ns(), "monotonic_ns": time.monotonic_ns(), "line": line.removesuffix("\n")}
                with self.changed:
                    self.received.append(arrival)
                    event = json.loads(line)
                    if not isinstance(event, dict):
                        raise ValueError("Docker event is not a JSON object")
                    self.events.append(event)
                    self.changed.notify_all()
        except ValueError as err:
            self.error = str(err)
        finally:
            with self.changed:
                self.changed.notify_all()

    def await_event(self, predicate):
        with self.changed:
            if not self.changed.wait_for(lambda: any(map(predicate, self.events)) or self.error, timeout=8):
                raise RuntimeError(f"Timed out waiting for a live event. Received {self.events!r}")
            require(not self.error, f"Invalid event stream. {self.error}")

    def close(self):
        # Docker may exec a Compose plugin that still holds the streaming socket.
        try:
            os.killpg(self.process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(self.process.pid, signal.SIGKILL)
            self.process.wait(timeout=5)
        self.reader.join(timeout=3)
        require(not self.reader.is_alive(), "Docker event reader did not terminate")
        self.process.stdout.close()
        stderr_fd = self.process.stderr.fileno()
        os.set_blocking(stderr_fd, False)
        try:
            self.stderr = os.read(stderr_fd, 8192).decode(errors="replace")
        except BlockingIOError:
            pass
        self.process.stderr.close()

    def close_and_record(self, report, name):
        close_error = None
        try:
            self.close()
        except Exception as error:
            close_error = str(error)
        with self.changed:
            report[name] = {"pid": self.process.pid, "returncode": self.process.returncode, "stderr": self.stderr,
                            "parse_error": self.error, "close_error": close_error, "rows": self.events.copy(),
                            "received": self.received.copy(), **event_order_evidence(self.events)}


def listeners(fixture):
    return int(fixture.docker("info", "--format", "{{.NEventsListener}}", timeout=5).stdout)


def await_listeners(fixture, predicate, streams=()):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        for stream in streams:
            if stream.process.poll() is not None:
                raise RuntimeError(f"Event subscription exited. {stream.process.stderr.read().strip()}")
        value = listeners(fixture)
        if predicate(value):
            return value
        time.sleep(0.075)
    raise RuntimeError(f"Event listener count did not reach the expected value. Last observed {value}")


def stamp(ns):
    sec, nanos = divmod(ns, 1_000_000_000)
    return f"{sec}.{nanos:09d}"


def event_order_evidence(rows):
    regressions, duplicates, seen = [], [], {}
    for index, row in enumerate(rows):
        fingerprint = hashlib.sha256(json.dumps(row, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        action = row.get("Action", row.get("action"))
        if fingerprint in seen:
            actor = row.get("Actor")
            actor = actor if isinstance(actor, dict) else {}
            attributes = actor.get("Attributes")
            attributes = attributes if isinstance(attributes, dict) else {}
            duplicates.append({"first_index": seen[fingerprint], "index": index, "action": action,
                               "actor_id": actor.get("ID", row.get("id")), "time_nano": row.get("timeNano"),
                               "exec_id": attributes.get("execID"), "sha256": fingerprint})
        else:
            seen[fingerprint] = index
        if index:
            previous = rows[index - 1]
            left, right = previous.get("timeNano"), row.get("timeNano")
            if isinstance(left, int) and isinstance(right, int) and left > right:
                regressions.append({"first_index": index - 1, "index": index, "first_action": previous.get("Action"),
                                    "action": action, "first_time_nano": left, "time_nano": right, "delta_ns": right - left})
    return {"timestamp_regressions": regressions, "duplicate_rows": duplicates}


def checked_engine_rows(rows, cid, project):
    for row in rows:
        attrs = row["Actor"]["Attributes"]
        require(row["Type"] == "container" and row["Actor"]["ID"] == cid and row["scope"] == "local",
                "Received an event for a different object or scope")
        require(attrs[LABEL] == project and attrs["com.docker.compose.service"] == "job"
                and attrs["com.docker.compose.project"] == project, "Actor labels did not identify this service")
        require(row["time"] == row["timeNano"] // 1_000_000_000 and row["timeNano"] > 0, "Invalid event timestamp")
        if row["Action"] == "die":
            require(attrs["exitCode"] == "0", f"Graceful service exit reported {attrs['exitCode']}")
    duplicates = event_order_evidence(rows)["duplicate_rows"]
    require(not duplicates, f"The stream repeated an event. {duplicates!r}")
    return [row["Action"] for row in rows]


def lifecycle(actions):
    relevant = [action for action in actions if action in {"start", "die", "stop", "destroy"}]
    require(len(relevant) == 7 and relevant[0] == relevant[3] == "start" and relevant[-1] == "destroy"
            and set(relevant[1:3]) == set(relevant[4:6]) == {"die", "stop"}, f"Lifecycle actions {actions}")


def checked_exec(rows):
    observed = {}
    for row in rows:
        action, _, command = row["Action"].partition(": ")
        if action not in ("exec_create", "exec_start", "exec_die"):
            continue
        attrs = row["Actor"]["Attributes"]
        exec_id = attrs.get("execID", "")
        require(re.fullmatch("[0-9a-f]{64}", exec_id), "Invalid exec event ID")
        observed.setdefault(exec_id, []).append((action, command, attrs.get("exitCode")))
    commands = {}
    for events in observed.values():
        require([action for action, _, _ in events] == ["exec_create", "exec_start", "exec_die"],
                f"Incomplete exec lifecycle {events}")
        command = events[0][1]
        require(command == events[1][1], "Exec start recorded a different command")
        commands.setdefault(command, []).append(events[-1][2])
    for expected in (0, 23):
        require(commands.get(f"sh -c exit {expected}") == [str(expected)], f"Missing exec exit {expected}")
    return len(observed)


def replay_window(rows, timestamps_regressed):
    if timestamps_regressed:
        # Event time is wall clock. Keep both sides of the inversion in the
        # comparison and continue to verify lifecycle order on the live rows.
        stamp_values = [row["timeNano"] for row in rows]
        return min(stamp_values), max(stamp_values), 4
    first_start = next(row["timeNano"] for row in rows if row["Action"] == "start")
    return first_start + 1, rows[-1]["timeNano"] - 1, 3


def qualify(fixture, diagnostics=None):
    if diagnostics is None:
        diagnostics = {}
    fixture.compose_file.write_text(json.dumps({"services": {"job": {
        "image": fixture.image, "network_mode": "none", "labels": {LABEL: fixture.key},
        "entrypoint": ["sh", "-ec"],
        "command": ["trap 'rm -f /tmp/events-ready; exit 0' TERM; touch /tmp/events-ready; sleep 90 & wait"],
    }}}))
    fixture.compose_touched = True
    fixture.compose("create", "--pull", "never")
    cid = fixture.inspect(fixture.compose("ps", "-a", "-q", "job").stdout.strip())["Id"]
    diagnostics["container"] = cid
    base_count = listeners(fixture)
    filters = ["--filter", "type=container", "--filter", f"container={cid[:12]}",
               "--filter", f"label={LABEL}={fixture.key}"]
    expires = str(int(time.time()) + 25)
    with ExitStack() as stack:
        engine = Stream(fixture, ["events", *filters, "--until", expires, "--format", "{{json .}}"])
        stack.callback(engine.close_and_record, diagnostics, "engine")
        compose = Stream(fixture, ["compose", "-p", fixture.key, "-f", str(fixture.compose_file),
                                   "events", "--json", "--until", expires, "job"])
        stack.callback(compose.close_and_record, diagnostics, "compose")
        active_count = await_listeners(fixture, lambda value: value >= base_count + 2, [engine, compose])
        for expected_exit in (23, 0):
            fixture.compose("start", "job")
            deadline = time.monotonic() + 5
            while fixture.docker("exec", cid, "test", "-f", "/tmp/events-ready", check=False).returncode:
                require(time.monotonic() < deadline, "Service did not install its graceful-stop handler")
                time.sleep(0.05)
            executed = fixture.docker("exec", cid, "sh", "-c", f"exit {expected_exit}", check=False)
            require(executed.returncode == expected_exit, f"Exec returned {executed.returncode}")
            fixture.compose("stop", "--timeout", "3", "job")
        fixture.compose("down", "--timeout", "3")
        engine.await_event(lambda event: event.get("Action") == "destroy")
        compose.await_event(lambda event: event.get("action") == "destroy")
    for stream in ("engine", "compose"):
        require(diagnostics[stream]["close_error"] is None, f"Could not close {stream} events. {diagnostics[stream]['close_error']}")
    close_start = time.monotonic()
    require(time.time() < int(expires) - 3, "The clients did not disconnect before the server deadline")
    final_count = listeners(fixture)
    while final_count > base_count and time.time() < int(expires) + 3:
        time.sleep(0.125)
        final_count = listeners(fixture)
    released_s = time.monotonic() - close_start
    observed_release_time = time.time()
    require(final_count <= base_count, "Timed subscriptions were not released by the server")
    engine_actions = checked_engine_rows(engine.events, cid, fixture.key)
    lifecycle(engine_actions)
    exec_count = checked_exec(engine.events)
    require(engine_actions[0] == "create" and engine_actions.count("create") == 1,
            "The subscription with --until did not replay the existing create event")
    for row in compose.events:
        require(row["service"] == "job" and row["id"] == cid, "Compose reported another service or container")
    require(not diagnostics["compose"]["duplicate_rows"], "The Compose stream repeated an event")
    compose_actions = [row["action"] for row in compose.events]
    lifecycle(compose_actions)

    lower, upper, expected_count = replay_window(engine.events, diagnostics["engine"]["timestamp_regressions"])
    diagnostics["replay_bounds"] = {"since_ns": lower, "until_ns": upper}
    bounds = ["--since", stamp(lower), "--until", stamp(upper)]
    replay = fixture.docker("events", *filters, *bounds, "--filter", "event=start", "--filter", "event=die",
                            "--format", "{{json .}}", timeout=10)
    replay_rows = [json.loads(line) for line in replay.stdout.splitlines()]
    diagnostics["replay_engine"] = replay_rows
    checked_engine_rows(replay_rows, cid, fixture.key)
    wanted = [row for row in engine.events if lower <= row["timeNano"] <= upper and row["Action"] in {"start", "die"}]
    require(replay_rows == wanted and len(wanted) == expected_count, "Bounded replay disagreed with the original live events")
    exec_replay = fixture.docker("events", *filters, *bounds, "--filter", "event=exec_create",
                                 "--filter", "event=exec_start", "--filter", "event=exec_die",
                                 "--format", "{{json .}}", timeout=10)
    exec_rows = [json.loads(line) for line in exec_replay.stdout.splitlines()]
    require(exec_rows == [row for row in engine.events if row["Action"].startswith("exec_")],
            "Exec event filters did not reproduce the live exec records")
    excluded = fixture.docker("events", "--since", stamp(lower), "--until", stamp(upper),
                              "--filter", f"container={cid}", "--filter", f"label={LABEL}=absent-{fixture.key}",
                              "--format", "{{json .}}", timeout=10)
    require(not excluded.stdout.strip(), "An event matched an unrelated label")
    return {"container": cid, "listener_counts": [base_count, active_count, final_count],
            "listener_release_seconds": round(released_s, 4), "released_before_deadline": observed_release_time < int(expires) - 1,
            "live_engine": engine.events, "live_compose": compose.events, "bounded_replay": replay_rows,
            "completed_execs": exec_count, "replayed_exec_events": len(exec_rows),
            "excluded_label_count": 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    endpoint = parser.add_mutually_exclusive_group(required=True)
    endpoint.add_argument("--host")
    endpoint.add_argument("--context")
    parser.add_argument("--image", default="alpine:3.23")
    args = parser.parse_args()
    with TemporaryDirectory(prefix="micropod-events-") as work:
        fixture = Qualification(Path(work), args, prefix="mp-events-")
        diagnostics = {"fixture": fixture.key}
        result, cleanup, failure, cleanup_failure = {}, None, None, None
        try:
            result = qualify(fixture, diagnostics)
        except (Exception, KeyboardInterrupt) as error:
            failure = {"type": type(error).__name__, "message": str(error)}
        finally:
            try:
                cleanup = fixture.cleanup(diagnose=failure is not None)
            except Exception as error:
                cleanup_failure = {"type": type(error).__name__, "message": str(error)}
        payload = {**result, "cleanup": cleanup, "diagnostics": diagnostics}
        if failure is not None:
            payload["failure"] = failure
        if cleanup_failure is not None:
            payload["cleanup_failure"] = cleanup_failure
        print(json.dumps(payload, indent=2))
        for error in (failure, cleanup_failure):
            if error is not None:
                print(error["message"], file=sys.stderr)
        return int(failure is not None or cleanup_failure is not None)


if __name__ == "__main__":
    raise SystemExit(main())
