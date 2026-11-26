#!/usr/bin/env python3
"""Exercise Docker PID 1 console streams through an explicit Linux engine socket."""

import argparse
from contextlib import ExitStack
import hashlib
import json
from pathlib import Path
import signal
import socket
import struct
import tarfile
from tempfile import TemporaryDirectory
import time
from types import SimpleNamespace

from qualify_docker_exec import attached, engine_response, winsize
from qualify_docker_restart import LABEL, Qualification, require


LIMIT = 20
BOOT = r"""
test "$$" = 1 && test -t 0 && test -t 1 && test -t 2
test "$(tty)" != 'not a tty'
test "$(id -u):$(id -g)" = 1234:1234
test "$(pwd -P)" = /tmp && test "$MP_PID1_ENV" = 'value with spaces'
test "$0" = pid1-entry && test "$1" = 'argument with spaces'
stty -echo
printf 'early-prompt>'
while IFS= read -r line; do
    case "$line" in
        size) printf 'size '; stty size ;;
        *) printf 'line=%s\n' "$line"; printf 'merged-stderr\n' >&2 ;;
    esac
done
printf 'terminal-eof\n'
exit 37
"""
RETAINED = r"""
test "$$" = 1
stty -echo
p=/tmp/mp-pid1-generation
count=0
if test -f "$p"; then read -r count < "$p"; fi
count=$((count + 1))
printf '%s\n' "$count" > "$p"
printf 'start=%s\n' "$count"
while IFS= read -r line; do
    case "$line" in
        quit) printf 'quitting=%s\n' "$count"; exit 29 ;;
        *) printf 'generation=%s input=%s\n' "$count" "$line" ;;
    esac
done
exit 38
"""


def docker_run(fixture, name, flags, command, *args):
    return [*fixture.cli, "run", "--pull=never", "--network=none", "--name", name,
            "--label", f"{LABEL}={fixture.key}", *flags, fixture.image, command, *args]


def initial_console(fixture):
    name = fixture.key + "-initial"
    command = docker_run(fixture, name, ("--rm", "-it", "-u", "1234:1234", "-w", "/tmp",
                                         "-e", "MP_PID1_ENV=value with spaces"),
                         "/bin/sh", "-ec", BOOT, "pid1-entry", "argument with spaces")
    with attached(command, env=fixture.env, size=(31, 97)) as io:
        until = time.monotonic() + LIMIT
        io.pump(lambda: io.stdout.endswith(b"early-prompt>"), until, "waiting for a short, unterminated PID 1 prompt")
        require(io.stdout == b"early-prompt>" and not io.stderr, f"Unexpected startup bytes. {io.status()}")
        row = fixture.inspect(name)
        require(row["Config"]["Tty"] and row["Config"]["OpenStdin"], f"Missing interactive config. {row!r}")
        io.read_offset = len(io.stdout)
        io.send(b"bytes with spaces\n", until)
        io.expect_line(b"line=bytes with spaces", until)
        io.expect_line(b"merged-stderr", until)
        with engine_response(fixture.cli[-1], "POST", f"/containers/{name}/resize?h=49&w=131"):
            pass
        io.send(b"size\n", until)
        io.expect_line(b"size 49 131", until)
        winsize(io.master, (42, 113))
        while True:
            io.process.send_signal(signal.SIGWINCH)
            io.send(b"size\n", until)
            result = io.line(until)
            if result == b"size 42 113":
                break
            require(result == b"size 49 131", f"Unexpected resize state {result!r}")
        io.send(b"\x04", until)
        io.expect_line(b"terminal-eof", until)
        io.finish(until, 37)
        require(io.read_offset == len(io.stdout), f"Unexpected bytes after terminal EOF. {io.status()}")
    require(fixture.docker("inspect", name, check=False).returncode != 0, "Auto-remove retained the interactive container")
    return {"early_prompt": True, "pid": 1, "uid": 1234, "gid": 1234, "exit": 37, "removed": True,
            "cli_resize": [42, 113], "api_resize": [49, 131]}


def pipe_console(fixture):
    payload = bytes(range(256)) * 2048 + b"\x00\xfftail"
    name = fixture.key + "-pipe"
    script = r"""
test "$$" = 1 && test ! -t 0 && test ! -t 1 && test ! -t 2
printf 'out-ready\n'
printf 'err-ready\n' >&2
cat
printf 'out-eof\n'
printf 'err-eof\n' >&2
exit 23
"""
    command = docker_run(fixture, name, ("--rm", "-i"), "/bin/sh", "-ec", script)
    with attached(command, env=fixture.env, limits=(len(payload) + 128, 128)) as io:
        until = time.monotonic() + LIMIT
        io.expect_line(b"out-ready", until)
        io.send(payload, until, eof=True)
        io.finish(until, 23, b"out-ready\n" + payload + b"out-eof\n", b"err-ready\nerr-eof\n")
    return {"bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest(), "exit": 23}


def read_frame(response):
    header = response.read(8)
    if not header:
        return None
    require(len(header) == 8, "Attach frame header was truncated")
    stream, size = struct.unpack(">B3xI", header)
    require(stream in (1, 2) and size < 65536, f"Invalid attach frame {stream}: {size}")
    payload = response.read(size)
    require(len(payload) == size, "Attach frame payload was truncated")
    return stream, payload


def half_close_console(fixture):
    host = fixture.cli[-1]
    name = fixture.key + "-half-close"
    script = r"""
IFS= read -r first
sleep 0.2
printf 'delayed=%s\n' "$first"
printf 'delayed-stderr\n' >&2
IFS= read -r second
printf 'reused=%s\n' "$second"
exit 46
"""
    config = {"Image": fixture.image, "Cmd": ["/bin/sh", "-ec", script], "OpenStdin": True,
              "AttachStdin": True, "AttachStdout": True, "AttachStderr": True, "StdinOnce": False,
              "Labels": {LABEL: fixture.key}, "HostConfig": {"NetworkMode": "none"}}
    with engine_response(host, "POST", f"/containers/create?name={name}", body=config, expected_status=201):
        pass
    path = f"/containers/{name}/attach?stream=true&stdin=true&stdout=true&stderr=true"
    with engine_response(host, "POST", path, with_socket=True) as (response, peer):
        peer.sendall(b"first\n")
        peer.shutdown(socket.SHUT_WR)
        fixture.docker("start", name)
        sent = {1: b"", 2: b""}
        while not all(sent.values()):
            frame = read_frame(response)
            require(frame is not None, "Half-close lost delayed PID 1 output")
            stream, data = frame
            sent[stream] += data
        with engine_response(host, "POST", path, with_socket=True) as (_, second):
            second.sendall(b"second\n")
            second.shutdown(socket.SHUT_WR)
            while (frame := read_frame(response)) is not None:
                stream, data = frame
                sent[stream] += data
        require(sent == {1: b"delayed=first\nreused=second\n", 2: b"delayed-stderr\n"},
                f"Half-close changed stdin or output {sent!r}")
    require(fixture.inspect(name)["State"]["ExitCode"] == 46, "Half-close lost PID 1 exit code")
    return {"prestart_stdin_half_close": True, "delayed_streams": True, "stdin_reused": True, "exit": 46}


def retained_console(fixture, report):
    name = fixture.key + "-retained"
    created = fixture.docker("run", "--detach", "-it", "--pull=never", "--network=none", "--name", name,
                             "--label", f"{LABEL}={fixture.key}", fixture.image, "/bin/sh", "-ec", RETAINED)
    cid = created.stdout.strip()
    require(fixture.inspect(name)["Id"] == cid, "Retained console identity differs")
    until = time.monotonic() + LIMIT
    with ExitStack() as clients:
        output = clients.enter_context(attached([*fixture.cli, "attach", "--no-stdin", name],
                                                env=fixture.env, size=(31, 97)))
        input_ = clients.enter_context(attached([*fixture.cli, "attach", "--detach-keys", "ctrl-x,ctrl-y", name],
                                                env=fixture.env, size=(31, 97)))
        for i in range(6):
            marker = f"generation=1 input=shared-{i}".encode()
            input_.send(f"shared-{i}\n".encode(), until)
            input_.pump(lambda: marker in input_.stdout, until, "waiting for the controlling attachment")
            ready_by = min(until, time.monotonic() + 0.25)
            try:
                output.pump(lambda: marker in output.stdout, ready_by, "waiting for the second attachment")
            except RuntimeError:
                if i == 5:
                    raise
                continue
            break
        input_.send(b"\x18\x19", until)
        input_.pump(lambda: not input_.readers, until, "waiting for stock keyboard detach")
        input_.process.wait(timeout=max(0, until - time.monotonic()))
        still_running = fixture.inspect(name)["State"]["Running"]
        sibling_attached = output.process.poll() is None
        report["detach"] = {"status": input_.process.returncode, "stderr": input_.stderr.decode(errors="replace"),
                            "stderr_hex": input_.stderr.hex(), "container_running": still_running,
                            "sibling_attached": sibling_attached}
        require(still_running and sibling_attached,
                "Detaching one client stopped the retained process or its sibling attachment")
        with attached([*fixture.cli, "attach", name], env=fixture.env, size=(36, 101)) as reattached:
            reattached.send(b"quit\n", until)
            reattached.finish(until, 29)
            require(b"quitting=1" in reattached.stdout, f"Reattach lost final output. {reattached.status()}")
        output.finish(until, 29)
        require(b"quitting=1" in output.stdout, f"Read-only attachment lost final output. {output.status()}")
    stopped = fixture.inspect(name)
    require(stopped["State"]["ExitCode"] == 29, "Retained wait and inspect disagree")

    with attached([*fixture.cli, "start", "-ai", name], env=fixture.env, size=(33, 112)) as io:
        until = time.monotonic() + LIMIT
        io.expect_line(b"start=2", until)
        io.send(b"quit\n", until)
        io.expect_line(b"quitting=2", until)
        io.finish(until, 29)
    row = fixture.inspect(name)
    require(row["Id"] == cid and row["State"]["StartedAt"] != stopped["State"]["StartedAt"]
            and row["Config"]["Tty"] and row["Config"]["OpenStdin"], "Start lost retained terminal config or identity")

    fixture.docker("start", name)
    with attached([*fixture.cli, "attach", name], env=fixture.env, size=(31, 97)) as old:
        until = time.monotonic() + LIMIT
        old.send(b"old-client\n", until)
        old.pump(lambda: b"generation=3 input=old-client" in old.stdout, until, "waiting for old generation")
        fixture.docker("restart", "--timeout=0", name, timeout=LIMIT)
        old.finish(until, 137)
        with attached([*fixture.cli, "attach", name], env=fixture.env, size=(31, 97)) as current:
            current.send(b"new-client\n", until)
            current.pump(lambda: b"generation=4 input=new-client" in current.stdout, until, "waiting for replacement")
            current.send(b"quit\n", until)
            current.finish(until, 29)
        require(b"start=4" not in old.stdout and b"new-client" not in old.stdout,
                "An attachment crossed a managed restart")
    log = fixture.docker("logs", name).stdout
    require(all(log.count(f"start={generation}\n") == 1 for generation in range(1, 5)) and "quitting=4\n" in log,
            f"Retained console log lost a generation. {log!r}")
    with engine_response(fixture.cli[-1], "GET", f"/containers/{name}/archive?path=/") as response:
        with tarfile.open(fileobj=response, mode="r|") as archive:
            runtime_mounts = [member.name for member in archive
                              if any(part.startswith(".micropod-pid1-") for part in member.name.split("/"))]
    require(not runtime_mounts, f"Console mount remained in the retained writable layer {runtime_mounts!r}")
    return {"id": cid, "detach_cli_status": input_.process.returncode, "concurrent": True,
            "reattached_exit": 29, "restarted_exit": 29, "restart_previous_exit": 137,
            "generations": 4, "writable_layer_archive_clean": True}


def scratch_console(fixture, image):
    cases = {}
    for label, flags, term in (("default", [], "xterm"), ("empty_term", ["-e", "TERM="], "")):
        # The static probe uses Go. Its own runtime can keep cpu.max open.
        # Disable that optional reader so its descriptor check has a strict baseline.
        result = fixture.docker("run", "--rm", "-t", "--read-only", "--pull=never", "--network=none",
                                "--label", f"{LABEL}={fixture.key}",
                                "-e", "GODEBUG=containermaxprocs=0,updatemaxprocs=0", *flags, image, timeout=LIMIT)
        require(not result.stderr, f"Scratch PID 1 emitted stderr. {result.stderr!r}")
        data = json.loads(result.stdout)
        require((data["pid"], data["uid"], data["gid"], data["cwd"]) == (1, 1234, 5678, "/fixture"),
                f"Scratch PID 1 config changed. {data!r}")
        require(data["args"] == ["probe", "from image", "default arg", ""]
                and data["env"] == "image env" and data["term_set"] and data["term"] == term,
                f"Scratch PID 1 did not inherit image argv/env. {data!r}")
        require(data["launcher_dirs"] == 1 and all(data["fds"][str(fd)].startswith("/dev/pts/") for fd in range(3)),
                f"Scratch PID 1 failed its descriptor check. {data!r}")
        cases[label] = data
    return cases


def ordinary_and_rejections(fixture, workspace):
    result = fixture.docker("run", "--rm", "--pull=never", "--network=none", "--label", f"{LABEL}={fixture.key}",
                            fixture.image, "/bin/sh", "-ec",
                            'test "$$" = 1; test ! -t 0; printf "stdout\\n"; printf "stderr\\n" >&2; exit 41',
                            check=False, timeout=LIMIT)
    require((result.returncode, result.stdout, result.stderr) == (41, "stdout\n", "stderr\n"),
            f"Ordinary foreground output changed. {result!r}")
    with TemporaryDirectory(prefix=fixture.key, dir=workspace) as scratch:
        invalid = Path(scratch) / "invalid"
        invalid.write_bytes(b"\x00\x01invalid executable format\x00")
        invalid.chmod(0o755)
        failures = {}
        for label, path, code in (
            ("missing", "/this-command-does-not-exist", 127),
            ("non_executable", "/etc/alpine-release", 126),
            ("bad_format", "/run/invalid-pid1-format", 126),
        ):
            flags = []
            if label == "bad_format":
                flags = ["--mount", f"type=bind,source={invalid},target={path},readonly"]
            out = fixture.docker("run", "--rm", "-t", "--pull=never", "--network=none",
                                 "--label", f"{LABEL}={fixture.key}", *flags, fixture.image, path,
                                 check=False, timeout=LIMIT)
            require(out.returncode == code, f"{label} returned {out.returncode}. {out.stdout!r} {out.stderr!r}")
            failures[label] = code
    return {"exit": 41, "launch_errors": failures}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--workspace", required=True, type=Path)
    parser.add_argument("--image", required=True)
    parser.add_argument("--scratch-image", help="preloaded static PID 1 conformance image")
    parser.add_argument("--case", action="append", choices=("initial", "pipe", "half_close", "retained", "ordinary", "readonly_scratch"),
                        help="run only the selected cases; repeat to select several")
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    require(args.host.startswith("unix://") and Path(args.host[7:]).is_socket(), "Provide a live explicit Unix socket")
    require(not args.out.exists(), "Choose a fresh receipt path")
    report = {"passed": False}
    with TemporaryDirectory(prefix="mp-pid1-proof-") as scratch:
        fixture = Qualification(Path(scratch), SimpleNamespace(host=args.host, context=None, image=args.image),
                                prefix="mp-pid1-")
        fixture.env.update(DOCKER_CONFIG=scratch, DOCKER_CLI_HINTS="false", TERM="xterm")
        try:
            report["client_server_version"] = fixture.docker("version", "--format", "{{.Client.Version}} {{.Server.Version}}").stdout.strip()
            report["image_identity"] = fixture.docker("image", "inspect", "--format", "{{.Id}} {{.Architecture}}", args.image).stdout.strip()
            report["scope"] = fixture.key
            cases = {
                "initial": lambda: initial_console(fixture),
                "pipe": lambda: pipe_console(fixture),
                "half_close": lambda: half_close_console(fixture),
                "retained": lambda: retained_console(fixture, report),
                "ordinary": lambda: ordinary_and_rejections(fixture, args.workspace),
            }
            if args.scratch_image:
                cases["readonly_scratch"] = lambda: scratch_console(fixture, args.scratch_image)
            for case in args.case or cases:
                require(case in cases, f"Case {case} requires --scratch-image")
                report[case] = cases[case]()
            report["passed"] = True
        except Exception as error:
            report["error"] = str(error)
            raise
        finally:
            try:
                report["cleanup"] = {"owned_container_ids": fixture.ids(), **fixture.cleanup()}
            except Exception as error:
                report["passed"] = False
                report["cleanup_error"] = str(error)
                raise
            finally:
                with args.out.open("x") as out:
                    json.dump(report, out, indent=2)
                    out.write("\n")


if __name__ == "__main__":
    main()
