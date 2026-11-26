#!/usr/bin/env python3
"""Qualify Docker exec streaming and process options on an explicit Unix socket."""

import argparse
from concurrent.futures import Future
from contextlib import ExitStack, closing, contextmanager
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import select
import signal
import socket
import struct
import subprocess
import termios
from tempfile import TemporaryDirectory
from threading import Thread
import time
import tty
from urllib.parse import urlencode

from qualify_docker_restart import CONTAINER_ID, LABEL, Qualification, require
from qualify_engine_api import UnixHTTP


EXEC_TIMEOUT = 20
CHUNK = 65536

PIPE_COMMAND = r"""
test ! -t 0 && test ! -t 1 && test ! -t 2 || exit 81
printf 'stdout ready\n'
printf 'stderr ready\n' >&2
dd if=/dev/zero bs=65536 count=32 2>/dev/null
dd if=/dev/zero bs=65536 count=16 >&2 2>/dev/null
cat
printf 'stdout after eof\n'
printf 'stderr after eof\n' >&2
exit 23
"""

TTY_COMMAND = r"""
test -t 0 && test -t 1 && test -t 2 || exit 81
stty icanon eof '^D' -echo
printf 'initial '
stty size
printf 'tty stderr\n' >&2
while IFS= read -r line; do
    case "$line" in
        size) printf 'size '; stty size ;;
        *) printf 'tty input %s\n' "$line" ;;
    esac
done
printf 'tty eof\n'
exit 37
"""

CONCURRENT_COMMAND = r"""
printf 'ready %s\n' "$1"
IFS= read -r input
printf 'stdout %s %s\n' "$1" "$input"
printf 'stderr %s %s\n' "$1" "$input" >&2
exit "$2"
"""


def winsize(fd, size):
    rows, columns = size
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))


def evidence(data):
    return f"{len(data)} bytes, sha256={hashlib.sha256(data).hexdigest()}, tail={bytes(data[-160:])!r}"


class AttachedExec:
    """Drive both sides of PTY or pipe I/O with one deadline and bounded capture."""

    def __init__(self, process, master, limits):
        self.process = process
        self.master = master
        self.stdin = process.stdin.fileno() if master is None else master
        self.stdout_fd = process.stdout.fileno() if master is None else master
        self.stdout = bytearray()
        self.stderr = bytearray()
        self.readers = {self.stdout_fd: (self.stdout, limits[0]), process.stderr.fileno(): (self.stderr, limits[1])}
        self.read_offset = 0
        self.pending = memoryview(b"")
        for fd in [self.stdin, *self.readers]:
            os.set_blocking(fd, False)

    def status(self):
        return f"Docker exit {self.process.poll()}, stdout {evidence(self.stdout)}, stderr {evidence(self.stderr)}"

    def read(self, fd):
        output, limit = self.readers[fd]
        try:
            data = os.read(fd, min(CHUNK, limit - len(output) + 1))
        except BlockingIOError:
            return
        except OSError as error:
            if fd != self.master or error.errno != errno.EIO:
                raise
            # Linux PTYs report EIO after their last slave descriptor closes.
            data = b""
        if data:
            output.extend(data)
            if len(output) > limit:
                stream = "stdout" if fd == self.stdout_fd else "stderr"
                raise RuntimeError(f"Docker {stream} exceeded {limit} bytes. {self.status()}")
        else:
            del self.readers[fd]

    def pump(self, done, until, action):
        while not done():
            remaining = until - time.monotonic()
            if remaining <= 0:
                raise RuntimeError(f"Timed out {action}. {self.status()}")
            writers = [self.stdin] if self.pending else []
            if not self.readers and not writers:
                raise RuntimeError(f"Docker closed its streams while {action}. {self.status()}")
            readable, writable, _ = select.select(self.readers, writers, [], remaining)
            for fd in readable:
                self.read(fd)
            if writable:
                try:
                    sent = os.write(self.stdin, self.pending[:CHUNK])
                except BlockingIOError:
                    continue
                except BrokenPipeError as error:
                    raise RuntimeError(f"Docker closed stdin early. {self.status()}") from error
                self.pending = self.pending[sent:]

    def send(self, data, until, *, eof=False):
        self.pending = memoryview(data)
        self.pump(lambda: not self.pending, until, "sending stdin")
        if eof:
            self.process.stdin.close()

    def line(self, until):
        self.pump(lambda: self.stdout.find(b"\n", self.read_offset) >= 0, until, "waiting for stdout")
        end = self.stdout.index(b"\n", self.read_offset)
        line = bytes(self.stdout[self.read_offset:end])
        self.read_offset = end + 1
        return line.removesuffix(b"\r") if self.master is not None else line

    def expect_line(self, expected, until):
        observed = self.line(until)
        require(observed == expected, f"Expected line {expected!r}, got {observed[:160]!r}. {self.status()}")

    def finish(self, until, expected_exit, stdout=None, stderr=b""):
        self.pump(lambda: not self.readers, until, "draining Docker output")
        try:
            self.process.wait(timeout=max(0, until - time.monotonic()))
        except subprocess.TimeoutExpired as error:
            raise RuntimeError(f"Timed out waiting for Docker to exit. {self.status()}") from error
        require(self.process.returncode == expected_exit, f"Expected exit {expected_exit}. {self.status()}")
        for stream, actual, expected in (("stdout", self.stdout, stdout), ("stderr", self.stderr, stderr)):
            if expected is not None and actual != expected:
                raise RuntimeError(f"Docker {stream} differed. Expected {evidence(expected)}. {self.status()}")


def reap(process):
    try:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=5)
    finally:
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream is not None:
                stream.close()


@contextmanager
def attached(command, *, env=None, size=None, limits=(8192, 8192)):
    master = None
    with ExitStack() as cleanup:
        with ExitStack() as child_fds:
            child_io = subprocess.PIPE
            if size is not None:
                master, child_io = pty.openpty()
                cleanup.callback(os.close, master)
                child_fds.callback(os.close, child_io)
                tty.setraw(child_io)
                winsize(child_io, size)
            process = subprocess.Popen(command, env=env, start_new_session=True, stdin=child_io,
                                       stdout=child_io, stderr=subprocess.PIPE, bufsize=0)
            cleanup.callback(reap, process)
        yield AttachedExec(process, master, limits)


def docker_exec(fixture, cid, flags, script, *args, **options):
    return attached([*fixture.cli, "exec", *flags, cid, "/bin/sh", "-ec", script, "sh", *args],
                    env=fixture.env, **options)


def pipe_streams(fixture, cid):
    # All byte values, a non-aligned ending, and enough data to exceed pipe and socket buffers.
    data = bytes(range(256)) * 16384 + b"\x00\xfflast\r\n"
    stdout = b"stdout ready\n" + bytes(32 * CHUNK) + data + b"stdout after eof\n"
    stderr = b"stderr ready\n" + bytes(16 * CHUNK) + b"stderr after eof\n"
    with docker_exec(fixture, cid, ("-i",), PIPE_COMMAND, limits=(len(stdout) + 1024, len(stderr) + 1024)) as io:
        until = time.monotonic() + EXEC_TIMEOUT
        # The guest sends more than a pipe buffer to each output before reading stdin.
        io.expect_line(b"stdout ready", until)
        io.send(data, until, eof=True)
        io.finish(until, 23, stdout, stderr)

    with docker_exec(fixture, cid, ("-i",), "cat; printf 'empty eof\\n'") as io:
        until = time.monotonic() + EXEC_TIMEOUT
        io.send(b"", until, eof=True)
        io.finish(until, 0, b"empty eof\n")
    return {"stdin_bytes": len(data), "stdin_sha256": hashlib.sha256(data).hexdigest(),
            "stdout_bytes": len(stdout), "stderr_bytes": len(stderr), "exit_code": 23, "empty_stdin_exit_code": 0}


def plain_attached_streams(fixture, cid):
    marker = f"/tmp/{fixture.key}-release"
    command = r"""
test ! -t 0 && test ! -t 1 && test ! -t 2 || exit 81
if IFS= read -r unexpected; then exit 82; fi
printf 'plain stdout ready\n'
printf 'plain stderr ready\n' >&2
attempt=0
while ! test -f "$1"; do
    if [ "$attempt" -ge 600 ]; then exit 83; fi
    attempt=$((attempt + 1))
    sleep 0.05
done
printf 'plain stdout released\n'
printf 'plain stderr released\n' >&2
exit 41
"""
    started = time.monotonic()
    with docker_exec(fixture, cid, (), command, marker) as io:
        ready_by = started + 6
        io.expect_line(b"plain stdout ready", ready_by)
        stdout_ready = time.monotonic()
        stderr_ready_line = b"plain stderr ready\n"
        io.pump(lambda: len(io.stderr) >= len(stderr_ready_line), ready_by, "waiting for plain exec stderr")
        stderr_ready = time.monotonic()
        require(io.stderr == stderr_ready_line and io.process.poll() is None,
                f"Plain exec did not remain active after both readiness lines. {io.status()}")

        # A daemon buffering either stream cannot reach this release exec.
        released = fixture.docker("exec", cid, "/bin/sh", "-ec", 'test ! -e "$1"; : > "$1"', "sh", marker, timeout=5)
        require(not released.stdout and not released.stderr, "The release exec emitted unexpected output")
        marker_written = time.monotonic()
        io.finish(started + EXEC_TIMEOUT, 41, b"plain stdout ready\nplain stdout released\n",
                  b"plain stderr ready\nplain stderr released\n")
    finished = time.monotonic()

    missing = fixture.docker("exec", cid, f"{fixture.key}-missing-command", check=False, timeout=5)
    missing_detail = (missing.stdout + missing.stderr).lower()
    require(missing.returncode == 127 and "not found" in missing_detail,
            f"Missing command returned {missing.returncode}. {(missing.stdout + missing.stderr).strip()}")
    non_executable = f"/tmp/{fixture.key}-not-executable"
    fixture.docker("exec", cid, "/bin/sh", "-ec",
                   '''printf '%s\\n' '#!/bin/sh' 'exit 0' > "$1"; chmod 0600 "$1"''', "sh", non_executable, timeout=5)
    denied = fixture.docker("exec", cid, non_executable, check=False, timeout=5)
    denied_detail = (denied.stdout + denied.stderr).lower()
    require(denied.returncode == 126 and ("permission denied" in denied_detail or "not executable" in denied_detail),
            f"Non-executable command returned {denied.returncode}. {(denied.stdout + denied.stderr).strip()}")

    return {"stdout_ready_ms": round((stdout_ready - started) * 1000, 3),
            "stderr_ready_ms": round((stderr_ready - started) * 1000, 3),
            "marker_written_ms": round((marker_written - started) * 1000, 3),
            "finished_ms": round((finished - started) * 1000, 3),
            "exit_code": 41, "missing_command_exit_code": 127, "permission_denied_exit_code": 126}


@contextmanager
def engine_response(host, method, path, *, body=None, expected_status=200, with_socket=False):
    with closing(UnixHTTP(host.removeprefix("unix://"))) as connection, ExitStack() as transport:
        connection.timeout = 5
        peer = None
        if with_socket:
            connection.connect()
            # An HTTP Connection: close header transfers ownership of the
            # connection's socket to the response's buffered reader.
            peer = transport.enter_context(closing(connection.sock.dup()))
        payload = json.dumps(body) if body is not None else None
        headers = {"Content-Type": "application/json"} if body is not None else {}
        connection.request(method, "/v1.44" + path, payload, headers)
        with connection.getresponse() as response:
            if response.status != expected_status:
                detail = response.read(512).decode(errors="replace").strip()
                raise RuntimeError(f"Docker {method} {path} returned HTTP {response.status}. {detail}")
            yield (response, peer) if with_socket else response


def exec_create_event(events, fixture, cid, marker=None):
    for _ in range(64):
        line = events.readline(8193)
        require(0 < len(line) <= 8192, "Did not receive a bounded exec_create event")
        event = json.loads(line)
        actor = event["Actor"]
        attrs = actor["Attributes"]
        exec_id = attrs.get("execID", "")
        require(event["Action"].partition(":")[0] == "exec_create" and actor["ID"] == cid
                and attrs.get(LABEL) == fixture.key and CONTAINER_ID.fullmatch(exec_id),
                f"Unexpected exec_create event for the fixture. {event!r}")
        if marker is None or event["Action"].endswith(" sh " + marker):
            return exec_id
    raise RuntimeError("The exec_create event did not arrive within 64 fixture events")


def exec_inspect_row(host, cid, exec_id):
    with engine_response(host, "GET", f"/exec/{exec_id}/json") as response:
        data = response.read(8193)
    require(len(data) <= 8192, "ExecInspect response exceeded 8192 bytes")
    row = json.loads(data)
    require(row.get("ID") == exec_id and row.get("ContainerID") == cid, f"Unexpected exec identity. {row!r}")
    return row


def inspect_exec(host, cid, exec_id, *, running, exit_code=None):
    row = exec_inspect_row(host, cid, exec_id)
    require(row.get("Running") is running and (row.get("ProcessConfig") or {}).get("tty") is True
            and all(row.get(name) is True for name in ("OpenStdin", "OpenStdout", "OpenStderr"))
            and (running or row.get("ExitCode") == exit_code), f"Unexpected PTY exec inspect. {row!r}")
    return {"running": row["Running"], "exit_code": row.get("ExitCode")}


def size_line(prefix, size):
    return f"{prefix} {size[0]} {size[1]}".encode()


def tty_stream(fixture, cid):
    host = fixture.cli[-1]
    initial, resized, api_size = (31, 97), (42, 113), (49, 131)
    filters = {"type": {"container": True}, "container": {cid: True},
               "label": {f"{LABEL}={fixture.key}": True}, "event": {"exec_create": True}}
    query = urlencode({"since": int(time.time()) - 60, "filters": json.dumps(filters)})
    with engine_response(host, "GET", "/events?" + query) as events:
        with docker_exec(fixture, cid, ("-it",), TTY_COMMAND, size=initial) as io:
            until = time.monotonic() + EXEC_TIMEOUT
            io.expect_line(size_line("initial", initial), until)
            io.expect_line(b"tty stderr", until)
            exec_id = exec_create_event(events, fixture, cid)
            running = inspect_exec(host, cid, exec_id, running=True)
            io.send(b"input with spaces and \\backslash\n", until)
            io.expect_line(b"tty input input with spaces and \\backslash", until)

            path = f"/exec/{exec_id}/resize?" + urlencode({"h": api_size[0], "w": api_size[1]})
            with engine_response(host, "POST", path):
                pass
            io.send(b"size\n", until)
            io.expect_line(size_line("size", api_size), until)

            winsize(io.master, resized)
            resize_until = min(until, time.monotonic() + 5)
            while True:
                # The child has a private PTY and no controlling terminal in CI.
                # Notify the stock CLI, which makes the resize request.
                io.process.send_signal(signal.SIGWINCH)
                io.send(b"size\n", resize_until)
                observed = io.line(resize_until)
                if observed == size_line("size", resized):
                    break
                require(observed == size_line("size", api_size) and time.monotonic() < resize_until,
                        f"Expected live terminal size {resized}, got {observed!r}. {io.status()}")
                time.sleep(0.05)

            io.send(b"\x04", until)
            io.expect_line(b"tty eof", until)
            io.finish(until, 37)
            require(io.read_offset == len(io.stdout), f"Unexpected bytes after the PTY exit line. {io.status()}")
    finished = inspect_exec(host, cid, exec_id, running=False, exit_code=37)
    return {"exec_id": exec_id, "initial_rows_columns": initial, "cli_resize_rows_columns": resized,
            "api_resize_rows_columns": api_size, "ctrl_d_eof": True, "running_inspect": running, "finished_inspect": finished}


def repeated_execs(fixture, cid):
    until = time.monotonic() + EXEC_TIMEOUT
    statuses = (0, 17, 29, 0)
    with ExitStack() as clients:
        active = [clients.enter_context(docker_exec(fixture, cid, ("-i",), CONCURRENT_COMMAND, str(index), str(code)))
                  for index, code in enumerate(statuses)]
        for index, io in enumerate(active):
            io.expect_line(f"ready {index}".encode(), until)
        require(all(io.process.poll() is None for io in active), "A concurrent exec finished before all execs were ready")
        for index, io in enumerate(active):
            io.send(f"input-{index}\n".encode(), until, eof=True)
        for index, (io, code) in enumerate(zip(active, statuses)):
            io.finish(until, code, f"ready {index}\nstdout {index} input-{index}\n".encode(),
                      f"stderr {index} input-{index}\n".encode())

    repeated = (0, 19, 0)
    for index, code in enumerate(repeated):
        command = "printf 'repeat %s\\n' \"$1\"; exit \"$2\""
        with docker_exec(fixture, cid, (), command, str(index), str(code)) as io:
            io.finish(time.monotonic() + EXEC_TIMEOUT, code, f"repeat {index}\n".encode())
    return {"overlapping_exit_codes": statuses, "repeated_exit_codes": repeated}


ENV_REPORT = r"""
pwd -P
printf 'uid=%s gid=%s\n' "$(id -u)" "$(id -g)"
/usr/bin/env | grep '^MP_EXEC_' | LC_ALL=C sort
"""

BASE_ENV = ("MP_EXEC_KEEP=inherited", "MP_EXEC_OVERRIDE=original", "MP_EXEC_UNSET=container")
BASE_REPORT = "/usr\nuid=65534 gid=65534\n" + "\n".join(BASE_ENV) + "\n"
OVERRIDE_REPORT = ("/tmp\nuid=65534 gid=65534\nMP_EXEC_CLIENT_EMPTY=\nMP_EXEC_COPY=cli value=a\n"
                   "MP_EXEC_EMPTY=\nMP_EXEC_KEEP=inherited\nMP_EXEC_NEW=last=a\nMP_EXEC_OVERRIDE=last\n")


def raw_workdir_rejection(host, cid, cwd, code, detail):
    request = {"Cmd": ["/bin/pwd"], "WorkingDir": cwd, "AttachStdout": True, "AttachStderr": True}
    with engine_response(host, "POST", f"/containers/{cid}/exec", body=request, expected_status=201) as response:
        exec_id = json.loads(response.read(8193))["Id"]
    require(CONTAINER_ID.fullmatch(exec_id), "Invalid exec ID for working directory probe")
    payload = b'{"Detach":false,"Tty":false}'
    headers = (f"POST /v1.44/exec/{exec_id}/start HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\n"
               f"Upgrade: tcp\r\nContent-Type: application/json\r\nContent-Length: {len(payload)}\r\n\r\n")
    with closing(socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)) as connection:
        connection.settimeout(5)
        connection.connect(host.removeprefix("unix://"))
        connection.sendall(headers.encode() + payload)
        with connection.makefile("rb") as stream:
            status = stream.readline(8193)
            require(status.startswith(b"HTTP/1.1 101 "), f"Unexpected working directory upgrade. {status!r}")
            for _ in range(32):
                line = stream.readline(8193)
                require(0 < len(line) <= 8192, "Truncated working directory response headers")
                if line == b"\r\n":
                    break
            else:
                raise RuntimeError("Working directory response exceeded 32 headers")
            frame = stream.read(8)
            require(len(frame) == 8, "Truncated working directory error frame")
            channel, length = struct.unpack(">BxxxI", frame)
            require(channel == 1 and 0 < length <= 8192, f"Unexpected working directory frame. {frame!r}")
            message = stream.read(length).decode(errors="replace").strip()
            require(detail in message.lower() and not stream.read(1), f"Unexpected working directory error. {message!r}")
            if cwd.startswith("/"):
                require(cwd in message, f"Working directory error omitted {cwd!r}. {message!r}")
    row = exec_inspect_row(host, cid, exec_id)
    require(row["Running"] is False and row["ExitCode"] == code and row["Pid"] == 0,
            f"Working directory rejection inspect differed. {row!r}")
    return {"create_http_status": 201, "start_http_status": 101, "stream_channel": channel,
            "exit_code": code, "working_dir": cwd, "message": message}


def start_detached_with_event(fixture, cid, script, marker, *, timeout=5):
    filters = {"type": {"container": True}, "container": {cid: True}, "label": {f"{LABEL}={fixture.key}": True},
               "event": {"exec_create": True}}
    query = urlencode({"filters": json.dumps(filters)})
    with engine_response(fixture.cli[-1], "GET", "/events?" + query, with_socket=True) as (events, peer):
        observed = Future()

        def read_event():
            try:
                observed.set_result(exec_create_event(events, fixture, cid, marker))
            except Exception as error:
                observed.set_exception(error)

        reader = Thread(target=read_event, name="detached-exec-event", daemon=True)
        deadline = time.monotonic() + timeout
        reader.start()
        try:
            result = fixture.docker("exec", "--detach", "-w", "/tmp", "-e", "MP_EXEC_BACKGROUND=detached value",
                                    cid, "/bin/sh", "-ec", script, "sh", marker, timeout=timeout)
            require(result.stdout == result.stderr == "", "Detached CLI produced attached output")
            try:
                return observed.result(timeout=max(0, deadline - time.monotonic()))
            except TimeoutError as error:
                raise RuntimeError("Timed out waiting for the detached exec_create event") from error
        finally:
            if reader.is_alive():
                try:
                    peer.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            reader.join(timeout=1)
            require(not reader.is_alive(), "Detached event reader did not stop")


def detached_options(fixture, cid):
    host, marker = fixture.cli[-1], fixture.key + "-detached"
    script = r"""
printf '%s\n%s\n' "$(pwd -P)" "$MP_EXEC_BACKGROUND" >"$1.tmp"
mv "$1.tmp" "$1"
for attempt in $(seq 1 100); do
    test ! -e "$1.release" || exit 39
    sleep 0.1
done
exit 91
"""
    exec_id = start_detached_with_event(fixture, cid, script, marker)
    running = exec_inspect_row(host, cid, exec_id)
    require(running["Running"] and running["Pid"] > 0 and not any(running[name] for name in ("OpenStdin", "OpenStdout", "OpenStderr")),
            f"Detached exec was not running without streams. {running!r}")
    file = "/tmp/" + marker
    proof = fixture.exec(cid, 'for n in $(seq 1 50); do if [ -f "$1" ]; then cat "$1"; exit; fi; sleep 0.1; done; exit 92', file)
    require(proof == "/tmp\ndetached value", f"Detached process wrote unexpected content. {proof!r}")
    fixture.exec(cid, 'touch "$1.release"', file)
    until = time.monotonic() + 5
    while True:
        finished = exec_inspect_row(host, cid, exec_id)
        if finished["Running"] is False:
            break
        require(time.monotonic() < until, "Detached process did not exit after release")
        time.sleep(0.05)
    require(finished["ExitCode"] == 39, f"Detached exec returned the wrong exit status. {finished!r}")
    return {"exec_id": exec_id, "running_without_streams": True, "relative_file": proof.splitlines(), "exit_code": 39}


def exec_options(fixture, cid):
    fixture.env.update(MP_EXEC_COPY="cli value=a", MP_EXEC_CLIENT_EMPTY="")
    for key in ("MP_EXEC_UNSET", "MP_EXEC_NEW", "MP_EXEC_UNKNOWN", "TERM"):
        fixture.env.pop(key, None)
    flags = ("--workdir", "/tmp", "--env", "MP_EXEC_OVERRIDE=first", "-e", "MP_EXEC_OVERRIDE=last",
             "-e", "MP_EXEC_UNSET=temporary", "-e", "MP_EXEC_UNSET", "-e", "MP_EXEC_UNKNOWN",
             "-e", "MP_EXEC_EMPTY=", "-e", "MP_EXEC_COPY", "-e", "MP_EXEC_CLIENT_EMPTY",
             "-e", "MP_EXEC_NEW=first", "-e", "MP_EXEC_NEW=last=a", "-e", "MP_EXEC_NEW")
    base = fixture.docker("exec", "-w", "", cid, "/bin/sh", "-ec", ENV_REPORT, timeout=5)
    require(base.stdout == BASE_REPORT and base.stderr == "", f"Unexpected inherited process options. {base.stdout!r} {base.stderr!r}")
    plain = fixture.docker("exec", *flags, cid, "/bin/sh", "-ec", ENV_REPORT, timeout=5)
    require(plain.stdout == OVERRIDE_REPORT and plain.stderr == "", f"Unexpected exec options. {plain.stdout!r} {plain.stderr!r}")

    payload = b"exec options input\n"
    with docker_exec(fixture, cid, ("-i", *flags), ENV_REPORT + "cat\n") as io:
        until = time.monotonic() + EXEC_TIMEOUT
        io.send(payload, until, eof=True)
        io.finish(until, 0, OVERRIDE_REPORT.encode() + payload)

    terminal = 'test -t 0 && test -t 1 && test -t 2; printf "term=%s\\n" "$TERM"\n'
    tty_only = fixture.docker("exec", "-t", "-e", "TERM=vt100", *flags, cid, "/bin/sh", "-ec", terminal + ENV_REPORT, timeout=5)
    require(tty_only.stdout == "term=vt100\n" + OVERRIDE_REPORT and tty_only.stderr == "",
            f"Unexpected TTY-only process options. {tty_only.stdout!r} {tty_only.stderr!r}")
    with docker_exec(fixture, cid, ("-it", "-e", "TERM=vt100", *flags),
                     "stty -echo\n" + terminal + ENV_REPORT + 'IFS= read -r input; printf "%s\\n" "$input"\n', size=(30, 90)) as io:
        until = time.monotonic() + EXEC_TIMEOUT
        io.expect_line(b"term=vt100", until)
        io.send(payload, until)
        io.finish(until, 0, (b"term=vt100\n" + OVERRIDE_REPORT.encode() + payload).replace(b"\n", b"\r\n"))

    detached = detached_options(fixture, cid)
    rejections = {}
    for name, cwd, code, detail in (("relative", "relative", 128, "cwd must be an absolute path"),
                                     ("missing", "/tmp/" + fixture.key + "-missing", 127, "no such file or directory"),
                                     ("regular_file", "/etc/alpine-release", 127, "not a directory")):
        rejected = fixture.docker("exec", "-w", cwd, cid, "/bin/pwd", check=False, timeout=5)
        require(rejected.returncode == code and detail in rejected.stdout.lower() and rejected.stderr == "",
                f"Unexpected CLI result for {name} working directory. {rejected.returncode} {rejected.stdout!r} {rejected.stderr!r}")
        rejections[name] = raw_workdir_rejection(fixture.cli[-1], cid, cwd, code, detail)
    rejected = fixture.docker("exec", "-d", "-w", rejections["missing"]["working_dir"], cid,
                              "/bin/pwd", check=False, timeout=5)
    require(rejected.returncode == 1 and rejected.stdout == "" and "no such file or directory" in rejected.stderr.lower(),
            f"Unexpected detached cwd rejection. {rejected.returncode} {rejected.stdout!r} {rejected.stderr!r}")
    untouched = fixture.docker("exec", cid, "/bin/sh", "-ec", ENV_REPORT, timeout=5)
    require(untouched.stdout == BASE_REPORT and untouched.stderr == "", "Exec options changed the container's defaults")
    return {"process_modes": ["attached", "stdin", "tty", "stdin_and_tty", "detached"], "inherited": base.stdout.splitlines(),
            "overrides": plain.stdout.splitlines(), "detached": detached, "workdir_rejections": rejections,
            "detached_workdir_rejection_exit_code": rejected.returncode}


def qualify(fixture, result):
    version = json.loads(fixture.docker("version", "--format", "{{json .}}", timeout=10).stdout)
    result["docker"] = {"client_version": version["Client"]["Version"], "engine_version": version["Server"]["Version"],
                        "engine_api": version["Server"]["ApiVersion"]}
    image, = json.loads(fixture.docker("image", "inspect", fixture.image, timeout=10).stdout)
    result["image"] = {"reference": fixture.image, "id": image["Id"]}
    cid = fixture.docker("run", "--detach", "--rm", "--pull=never", "--network", "none", "--name", fixture.key,
                         "--label", f"{LABEL}={fixture.key}", "--workdir", "/usr", "--user", "65534:65534",
                         *(f"--env={entry}" for entry in BASE_ENV), "--entrypoint", "/bin/sleep", fixture.image, "120",
                         timeout=20).stdout.strip()
    row = fixture.inspect(fixture.key)
    require(row["Id"] == cid and row["State"]["Running"], "The named Alpine exec fixture did not start")
    result["container_id"] = cid
    for name, check in (("interactive_pty", tty_stream), ("stdin_eof_binary_backpressure", pipe_streams),
                        ("plain_attached_early_output", plain_attached_streams), ("concurrent_and_repeated_execs", repeated_execs),
                        ("exec_environment_and_workdir", exec_options)):
        try:
            result["checks"][name] = check(fixture, cid)
        except Exception as error:
            result["failures"][name] = f"{type(error).__name__}: {error}"


def interrupted(signum, _frame):
    raise KeyboardInterrupt(f"Received signal {signum}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, help="explicit unix:// Docker socket")
    parser.add_argument("--image", default=os.environ.get("MICROPOD_TEST_IMAGE", "alpine:3.23"), help="preloaded Alpine image")
    args = parser.parse_args()
    if not args.host.startswith("unix:///") or not Path(args.host[7:]).is_socket():
        parser.error("--host must identify a Unix socket")
    args.context = None
    signal.signal(signal.SIGTERM, interrupted)
    with TemporaryDirectory(prefix="micropod-exec-") as work:
        fixture = Qualification(Path(work), args, prefix="mp-exec-")
        # Isolate CLI settings and suppress optional Docker Debug hints on stderr.
        fixture.env.update(DOCKER_CONFIG=work, DOCKER_CLI_HINTS="false")
        for name in ("DOCKER_TLS", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH", "DOCKER_DEFAULT_PLATFORM", "DOCKER_CUSTOM_HEADERS"):
            fixture.env.pop(name, None)
        result = {"schema": 1, "target": {"host": args.host}, "run_id": fixture.key, "container_name": fixture.key,
                  "checks": {}, "failures": {}}
        try:
            qualify(fixture, result)
        except (Exception, KeyboardInterrupt) as error:
            result["failures"]["qualification"] = str(error) or type(error).__name__
        finally:
            try:
                cleanup = fixture.cleanup(diagnose=bool(result["failures"]))
                removed = fixture.docker("container", "inspect", fixture.key, check=False, timeout=5)
                require(removed.returncode != 0 and "no such container" in removed.stderr.lower(),
                        f"Could not confirm removal of {fixture.key}. {removed.stderr.strip()}")
                result["cleanup"] = {**cleanup, "container_name_removed": True}
            except Exception as error:
                result["failures"]["cleanup"] = str(error)
    result["passed"] = not result["failures"]
    print(json.dumps(result, indent=2))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
