from contextlib import contextmanager
import json
import signal
import socket
import subprocess
import sys
from threading import Event
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

from qualify_docker_exec import LABEL, UnixHTTP, attached, engine_response, start_detached_with_event, winsize


class AttachedExecTests(unittest.TestCase):
    def test_pipe_drains_both_outputs_before_eof(self):
        command = [sys.executable, "-c", """
import sys
sys.stdout.buffer.write(b'x' * 131072)
sys.stdout.buffer.flush()
sys.stderr.buffer.write(b'y' * 131072)
sys.stderr.buffer.flush()
sys.stdout.buffer.write(sys.stdin.buffer.read())
sys.exit(19)
"""]
        payload = bytes(range(256)) * 1025
        expected = b"x" * 131072 + payload
        with attached(command, limits=(len(expected), 131072)) as session:
            until = time.monotonic() + 5
            session.send(payload, until, eof=True)
            session.finish(until, 19, expected, b"y" * 131072)

    def test_pty_initial_size_live_size_and_normalized_output(self):
        command = [sys.executable, "-c", r"""
import os
import sys
assert os.isatty(0) and os.isatty(1) and not os.isatty(2)
size = os.get_terminal_size(0)
print(f'{size.lines} {size.columns}\r', flush=True)
assert sys.stdin.buffer.readline() == b'size\n'
size = os.get_terminal_size(1)
print(f'{size.lines} {size.columns}\r', flush=True)
sys.exit(7)
"""]
        with attached(command, size=(31, 97)) as session:
            until = time.monotonic() + 5
            session.expect_line(b"31 97", until)
            winsize(session.master, (42, 113))
            session.send(b"size\n", until)
            session.expect_line(b"42 113", until)
            session.finish(until, 7)
            self.assertEqual(session.stdout, b"31 97\r\n42 113\r\n")

    def test_output_cap_kills_and_reaps_child(self):
        command = [sys.executable, "-c", "import time; print('x' * 100, flush=True); time.sleep(60)"]
        with self.assertRaisesRegex(RuntimeError, "stdout exceeded 64 bytes"):
            with attached(command, limits=(64, 64)) as session:
                session.finish(time.monotonic() + 5, 0)
        self.assertEqual(session.process.returncode, -signal.SIGKILL)
        self.assertTrue(session.process.stdout.closed)

    def test_timeout_kills_and_reaps_child(self):
        command = [sys.executable, "-c", "import time; time.sleep(60)"]
        with self.assertRaisesRegex(RuntimeError, "Timed out waiting for stdout"):
            with attached(command) as session:
                session.expect_line(b"ready", time.monotonic() + 0.1)
        self.assertEqual(session.process.returncode, -signal.SIGKILL)
        self.assertTrue(session.process.stdin.closed)


class DetachedExecEventTests(unittest.TestCase):
    cid = "a" * 64
    key = "test-fixture"
    marker = key + "-detached"

    def setUp(self):
        self.reader, self.sender = socket.socketpair()
        self.addCleanup(self.reader.close)
        self.addCleanup(self.sender.close)
        self.read_started = Event()
        self.second_read = Event()
        self.closed = Event()
        self.read_count = 0

    @contextmanager
    def event_stream(self, host, method, path, *, with_socket):
        self.assertEqual((host, method), ("unix:///test.sock", "GET"))
        self.assertTrue(with_socket)
        uri = urlsplit(path)
        self.assertEqual(uri.path, "/events")
        query = parse_qs(uri.query)
        self.assertNotIn("since", query)
        filters = json.loads(query["filters"][0])
        self.assertEqual(filters["event"], {"exec_create": True})
        self.assertEqual(filters["container"], {self.cid: True})
        with self.reader.makefile("rb") as stream:
            def tracked_readline(size):
                self.read_started.set()
                line = stream.readline(size)
                self.read_count += 1
                if self.read_count == 2:
                    self.second_read.set()
                return line

            try:
                yield SimpleNamespace(readline=tracked_readline), self.reader
            finally:
                self.closed.set()

    def emit(self, exec_id, suffix):
        event = {"Action": "exec_create: /bin/sh -ec script sh " + suffix,
                 "Actor": {"ID": self.cid, "Attributes": {LABEL: self.key, "execID": exec_id}}}
        self.sender.sendall(json.dumps(event).encode() + b"\n")

    def begin(self, docker, *, timeout=1):
        fixture = SimpleNamespace(cli=["docker", "--host", "unix:///test.sock"], key=self.key, docker=docker)
        with patch("qualify_docker_exec.engine_response", self.event_stream):
            return start_detached_with_event(fixture, self.cid, "script", self.marker, timeout=timeout)

    def test_reads_new_event_while_stock_cli_is_active(self):
        def docker(*args, timeout):
            self.assertEqual(args[:2], ("exec", "--detach"))
            self.assertEqual(args[-1], self.marker)
            self.assertEqual(timeout, 1)
            self.assertTrue(self.read_started.wait(0.5))
            self.emit("b" * 64, "/tmp/" + self.marker)
            self.emit("c" * 64, self.marker)
            self.assertTrue(self.second_read.wait(0.5))
            return SimpleNamespace(stdout="", stderr="")

        self.assertEqual(self.begin(docker), "c" * 64)
        self.assertTrue(self.closed.is_set())

    def test_cli_timeout_unblocks_and_joins_reader(self):
        def docker(*args, timeout):
            self.assertTrue(self.read_started.wait(0.5))
            raise subprocess.TimeoutExpired(args, timeout)

        with self.assertRaises(subprocess.TimeoutExpired):
            self.begin(docker)
        self.assertEqual(self.read_count, 1)
        self.assertTrue(self.closed.is_set())

    def test_event_eof_closes_subscription(self):
        def docker(*args, timeout):
            self.sender.shutdown(socket.SHUT_WR)
            return SimpleNamespace(stdout="", stderr="")

        with self.assertRaisesRegex(RuntimeError, "Did not receive a bounded exec_create event"):
            self.begin(docker)
        self.assertTrue(self.closed.is_set())

    def test_event_deadline_unblocks_and_joins_reader(self):
        def docker(*args, timeout):
            return SimpleNamespace(stdout="", stderr="")

        with self.assertRaisesRegex(RuntimeError, "Timed out waiting for the detached exec_create event"):
            self.begin(docker, timeout=0.05)
        self.assertEqual(self.read_count, 1)
        self.assertTrue(self.closed.is_set())

    def test_event_socket_can_interrupt_connection_close_response(self):
        response = b"HTTP/1.1 200 OK\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n\r\n"
        self.sender.sendall(response)
        connection = UnixHTTP("/test.sock")
        connection.connect = lambda: setattr(connection, "sock", self.reader)
        with patch("qualify_docker_exec.UnixHTTP", return_value=connection):
            with engine_response("unix:///test.sock", "GET", "/events", with_socket=True) as (events, peer):
                self.assertIsNone(connection.sock)
                peer.shutdown(socket.SHUT_RDWR)
                self.assertEqual(events.readline(), b"")
        self.assertEqual(peer.fileno(), -1)


if __name__ == "__main__":
    unittest.main()
