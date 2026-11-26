#!/usr/bin/env python3
"""Compare terminal behavior of Micropod and stock Docker on an explicit engine."""
import argparse
import array
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import shutil
import signal
import subprocess
import sys
import tempfile
import termios
from threading import Barrier
import time
from uuid import uuid4

from qualify_docker_exec import AttachedExec, TTY_COMMAND, reap, winsize

TIMEOUT = 12
SIGNAL_COMMAND = """
test -t 0 && test -t 1 && test -t 2 || exit 81
stty -echo isig
trap 'printf "guest interrupt\\n"; exit 42' INT
printf 'ready\\n'
while :; do read -r a || :; done
"""


def terminal_modes(fd):
    # Darwin processes any pending input when queried for readable bytes.
    fcntl.ioctl(fd, termios.FIONREAD, array.array("i", [0]), True)
    return termios.tcgetattr(fd)


class ObservedTerminal(AttachedExec):
    def __init__(self, process, master, observer):
        super().__init__(process, master, (16384, 8192))
        self.observer = observer
        self.final_modes = None

    def observe_exit(self):
        if self.process.poll() is None:
            raise RuntimeError("Terminal restoration was sampled before CLI exit")
        if self.final_modes is None:
            self.final_modes = terminal_modes(self.observer.fileno())
            self.observer.close()

    def finish(self, until, expected_exit):
        # Keep a slave open while the CLI exits. Otherwise a last-close reset
        # could hide the client leaving the user's terminal in raw mode.
        self.pump(lambda: self.process.stderr.fileno() not in self.readers, until, "waiting for CLI exit")
        self.process.wait(timeout=max(0, until - time.monotonic()))
        self.observe_exit()
        super().finish(until, expected_exit)


@contextmanager
def cooked_terminal(command, env, size=(31, 97), stdout=None):
    master, slave = pty.openpty()
    with os.fdopen(master, "rb", buffering=0) as controller, os.fdopen(slave, "rb", buffering=0) as observer:
        initial = terminal_modes(slave)
        if not (initial[3] & termios.ICANON and initial[3] & termios.ECHO):
            raise RuntimeError("Fixture did not start with a cooked terminal")
        winsize(slave, size)
        process = subprocess.Popen(command, stdin=slave, stdout=slave if stdout is None else stdout, stderr=subprocess.PIPE,
                                   env=env, start_new_session=True, bufsize=0)
        try:
            yield ObservedTerminal(process, controller.fileno(), observer), initial
        finally:
            reap(process)


def raw(io):
    flags = termios.tcgetattr(io.master)
    if flags[3] & (termios.ECHO | termios.ICANON | termios.ISIG) or flags[1] & termios.OPOST:
        raise RuntimeError("Local terminal still processes echo, signals, input lines, or output")


def restored(io, initial):
    io.observe_exit()
    if io.final_modes != initial:
        raise RuntimeError("Client exited with different host terminal attributes")


def observer_control(env):
    with cooked_terminal([sys.executable, "-B", "-c", "import tty; tty.setraw(0)"], env) as (io, initial):
        io.finish(time.monotonic() + TIMEOUT, 0)
        if io.final_modes == initial or io.final_modes[3] & termios.ICANON:
            raise RuntimeError("Observer missed a client which exited in raw mode")
        return {"exited_in_raw_mode_detected": True}


def interactive(prefix, env, name):
    command = [*prefix, "exec", "-it", name, "/bin/sh", "-c", TTY_COMMAND]
    with cooked_terminal(command, env) as (io, initial):
        end = time.monotonic() + TIMEOUT
        io.expect_line(b"initial 31 97", end)
        io.expect_line(b"tty stderr", end)
        raw(io)
        io.send(b"hello from CI\n", end)
        io.expect_line(b"tty input hello from CI", end)
        winsize(io.master, (42, 113))
        limit = min(time.monotonic() + 4, end)
        notifications = 1
        io.process.send_signal(signal.SIGWINCH)
        retry_at = time.monotonic() + 0.5
        while True:
            io.send(b"size\n", limit)
            result = io.line(limit)
            if result == b"size 42 113":
                break
            if result != b"size 31 97" or time.monotonic() >= limit:
                raise RuntimeError(f"Live resize returned {result!r}")
            if time.monotonic() >= retry_at:
                io.process.send_signal(signal.SIGWINCH)
                notifications += 1
                retry_at = time.monotonic() + 0.5
            time.sleep(0.025)
        io.send(b"\x04", end)
        io.expect_line(b"tty eof", end)
        io.finish(end, 37)
        restored(io, initial)
        return {"initial": [31, 97], "resized": [42, 113], "guest_exit": 37,
                "bytes": len(io.stdout), "resize_notifications": notifications, "host_terminal_restored": True}


def interrupt(prefix, env, name):
    with cooked_terminal([*prefix, "exec", "-it", name, "sh", "-c", SIGNAL_COMMAND], env) as (io, initial):
        end = time.monotonic() + TIMEOUT
        io.expect_line(b"ready", end)
        io.send(b"\x03", end)
        io.expect_line(b"guest interrupt", end)
        io.finish(end, 42)
        restored(io, initial)
        return {"guest_exit": 42, "host_terminal_restored": True}


def terminate_host(prefix, env, name):
    with cooked_terminal([*prefix, "exec", "-it", name, "sh", "-c", SIGNAL_COMMAND], env) as (io, initial):
        end = time.monotonic() + TIMEOUT
        io.expect_line(b"ready", end)
        raw(io)
        io.process.send_signal(signal.SIGTERM)
        io.process.wait(timeout=TIMEOUT)
        if io.process.returncode not in (143, -signal.SIGTERM):
            raise RuntimeError(f"Host signal produced status {io.process.returncode}")
        restored(io, initial)
        return {"host_exit": io.process.returncode, "host_terminal_restored": True}


def broken_output(prefix, env, name):
    read_fd, write_fd = os.pipe()
    os.close(read_fd)
    script = 'IFS= read -r line; printf "%s" "$line"'
    try:
        with cooked_terminal([*prefix, "exec", "-it", name, "sh", "-c", script], env, stdout=write_fd) as (io, initial):
            end = time.monotonic() + TIMEOUT
            while termios.tcgetattr(io.master)[3] & termios.ICANON:
                if io.process.poll() is not None or time.monotonic() >= end:
                    raise RuntimeError("Client never entered raw mode before the output pipe closed")
                time.sleep(0.01)
            raw(io)
            os.write(io.master, b"broken output\n")
            io.process.wait(timeout=max(0, end - time.monotonic()))
            if io.process.returncode not in (141, -signal.SIGPIPE):
                raise RuntimeError(f"Broken output pipe produced status {io.process.returncode}")
            restored(io, initial)
            return {"host_exit": io.process.returncode, "host_terminal_restored": True}
    finally:
        os.close(write_fd)


def nonterminal(prefix, env, name):
    def run(flags, script, *args):
        return subprocess.run([*prefix, "exec", *flags, name, "sh", "-c", script, "sh", *args],
                              env=env, capture_output=True, input=b"", timeout=TIMEOUT)
    p = run(["-t"], r"stty -onlcr; printf '\001\000\000\000\000\000\000\001\377'; printf '\376' >&2; exit 26")
    expected = b"\x01" + bytes(6) + b"\x01\xff\xfe"
    if (p.returncode, p.stdout, p.stderr) != (26, expected, b""):
        raise RuntimeError(f"Raw PTY output was {(p.returncode, p.stdout, p.stderr)!r}")
    p = run(["-it"], "printf should-never-run")
    if not p.returncode or p.stdout or not p.stderr:
        raise RuntimeError(f"Non-terminal stdin with -it returned {(p.returncode,p.stdout,p.stderr)!r}")
    return {"raw_pty_bytes_hex": expected.hex(), "tty_only_exit": 26, "nonterminal_rejected": True}


def guest_flags(prefix, env, name):
    flags = ["--json", "--no-color", "--cli", "guest-argument", "--", "-it"]
    p = subprocess.run([*prefix, "exec", name, "sh", "-c", 'printf "<%s>" "$@"', "sh", *flags],
                       env=env, capture_output=True, timeout=TIMEOUT)
    want = "".join(f"<{flag}>" for flag in flags).encode()
    if (p.returncode, p.stdout, p.stderr) != (0, want, b""):
        raise RuntimeError(f"Guest argv changed: {(p.returncode,p.stdout,p.stderr)!r}")
    return {"guest_argv": flags}


def detached_tty(prefix, env, name):
    marker = "/tmp/mp-tty-" + uuid4().hex
    script = 'test -t 1 && printf ready > "$1"'
    p = subprocess.run([*prefix, "exec", "-dit", name, "sh", "-c", script, "sh", marker],
                       env=env, capture_output=True, stdin=subprocess.DEVNULL, timeout=TIMEOUT)
    if (p.returncode, p.stdout, p.stderr) != (0, b"", b""):
        raise RuntimeError(f"Detached TTY acknowledgement: {(p.returncode, p.stdout, p.stderr)!r}")
    end = time.monotonic() + TIMEOUT
    while time.monotonic() < end:
        q = subprocess.run([*prefix, "exec", name, "cat", marker], capture_output=True, env=env, timeout=TIMEOUT)
        if (q.returncode, q.stdout, q.stderr) == (0, b"ready", b""):
            return {"acknowledged": True, "guest_tty": True}
        time.sleep(0.025)
    raise RuntimeError("Detached guest did not observe its terminal")


def concurrent_terminals(prefix, env, names):
    ready = Barrier(len(names))
    script = """stty -echo
printf 'ready %s ' "$1"; stty size
IFS= read -r word
printf 'finished %s %s\n' "$1" "$word" >&2
exit "$2" """
    def one(item):
        index, name = item
        size = 30 + index, 88 + index
        tag = f"job-{index}"
        code = 20 + index
        cmd = [*prefix, "exec", "-it", name, "sh", "-c", script, "sh", tag, str(code)]
        with cooked_terminal(cmd, env, size) as (io, initial):
            end = time.monotonic() + TIMEOUT
            io.expect_line(f"ready {tag} {size[0]} {size[1]}".encode(), end)
            raw(io)
            ready.wait(timeout=max(0, end - time.monotonic()))
            io.send(f"input-{index}\n".encode(), end)
            io.expect_line(f"finished {tag} input-{index}".encode(), end)
            io.finish(end, code)
            restored(io, initial)
            return {"guest": tag, "initial_size": size, "exit": code}
    begin = time.monotonic()
    with ThreadPoolExecutor(max_workers=len(names)) as pool:
        jobs = list(pool.map(one, enumerate(names)))
    return {"jobs": jobs, "wall_ms": round(1000 * (time.monotonic() - begin), 3)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--hvf-root", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--image", default="alpine:3.23")
    args = parser.parse_args()
    if args.output.exists() or not args.host.startswith("unix:///") or not Path(args.host[7:]).is_socket():
        parser.error("Choose a fresh receipt and an explicit live Unix socket")
    docker = shutil.which("docker")
    if not docker:
        parser.error("Stock Docker CLI is missing")
    recording = {"endpoint": args.host, "binary": str(args.cli.resolve(strict=True)),
                 "sha256": hashlib.sha256(args.cli.read_bytes()).hexdigest(), "cases": {}}
    name = "mp-tty-" + uuid4().hex[:14]
    label = "io.micropod.tty=" + name
    with tempfile.TemporaryDirectory(prefix="mp-tty-") as scratch:
        env = dict(os.environ, DOCKER_HOST=args.host, DOCKER_CONFIG=scratch, DOCKER_CLI_HINTS="false", HOME=scratch, CFFIXED_USER_HOME=scratch,
                   MICROPOD_HVF_ROOT=str(args.hvf_root or Path(scratch)/"hvf"),
                   MICROPOD_DEFAULT_RUNTIME="hvf" if args.hvf_root else "docker", MICROPOD_RUNTIME="cli",
                   MICROPOD_CONTAINER_CLI_PATH=str(Path(scratch)/"unused-apple"),
                   MICROPOD_RUNTIMES_CONFIG=str(Path(scratch)/"runtimes.json"), MICROPOD_NO_UPDATE_NOTIFIER="1", NO_COLOR="1")
        for key in ("DOCKER_CONTEXT", "DOCKER_API_VERSION"):
            env.pop(key, None)
        recording["observer_control"] = observer_control(env)
        def host(*argv):
            return subprocess.check_output([docker, *argv], env=env, timeout=TIMEOUT)
        try:
            names = [f"{name}-{i}" for i in range(8)]
            recording["containers"] = [
                host("run", "--detach", "--pull=never", "--name", item, "--label", label, "--cpus", "1", "--memory", "128m",
                     "--entrypoint", "/bin/sleep", args.image, "360").decode().strip() for item in names
            ]
            target = names[0]
            for client, prefix in (("docker", [docker]), ("micropod", [str(args.cli.resolve())])):
                cases = [("interactive", interactive), ("guest_signal", interrupt), ("nonterminal", nonterminal), ("argv", guest_flags),
                         ("detached_tty", detached_tty)]
                if client == "micropod":
                    cases.append(("host_signal", terminate_host))
                    cases.append(("broken_output", broken_output))
                row = recording["cases"][client] = {}
                for case, run in cases:
                    try:
                        row[case] = {"passed": True, **run(prefix, env, target)}
                    except Exception as error:
                        row[case] = {"passed": False, "error": repr(error)}
                try:
                    row["eight_terminals"] = {"passed": True, **concurrent_terminals(prefix, env, names)}
                except Exception as error:
                    row["eight_terminals"] = {"passed": False, "error": repr(error)}
        finally:
            ids = host("ps", "-aq", "--filter", "label=" + label).decode().split()
            if ids:
                host("rm", "-f", *ids)
            recording["removed"] = len(ids)
            recording["remaining"] = host("ps", "-aq", "--filter", "label=" + label).decode().split()
            args.output.write_text(json.dumps(recording, indent=2) + "\n")
    if recording["remaining"] or any(not item["passed"] for row in recording["cases"].values() for item in row.values()):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
