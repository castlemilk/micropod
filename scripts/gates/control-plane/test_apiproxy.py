"""Self-test for apiproxy.py: python3 -B scripts/gates/control-plane/test_apiproxy.py

A small keep-alive upstream (Content-Length replies, a chunked stream, a
close-delimited stream) behind the proxy; each test drives the proxy with raw
bytes on one client connection and checks what was recorded and what the
upstream saw.
"""

import os
import socket
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from apiproxy import Proxy  # noqa: E402


class Upstream:
    """Answers each request on a connection in turn: /chunked as a chunked
    stream, /closing close-delimited, everything else with its path."""

    def __init__(self, path):
        self.path = path
        self.seen = []
        self.connections = 0
        self.lock = threading.Lock()
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(path)
        self.sock.listen(16)
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            with self.lock:
                self.connections += 1
            threading.Thread(target=self._serve, args=(conn,), daemon=True).start()

    def _serve(self, conn):
        buf = b""
        with conn:
            while True:
                while b"\r\n\r\n" not in buf:
                    chunk = conn.recv(65536)
                    if not chunk:
                        return
                    buf += chunk
                head, _, buf = buf.partition(b"\r\n\r\n")
                path = head.split(b" ")[1].decode()
                length = 0
                for line in head.split(b"\r\n")[1:]:
                    k, _, v = line.partition(b":")
                    if k.strip().lower() == b"content-length":
                        length = int(v)
                while len(buf) < length:
                    buf += conn.recv(65536)
                buf = buf[length:]
                with self.lock:
                    self.seen.append(path)
                if path == "/chunked":
                    conn.sendall(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
                                 b"3\r\none\r\n3\r\ntwo\r\n0\r\n\r\n")
                elif path == "/closing":
                    conn.sendall(b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nstream-bytes")
                    return
                else:
                    body = path.encode()
                    conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n" % len(body) + body)

    def stop(self):
        self.sock.close()


def request(path):
    return f"POST {path} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/proto\r\nContent-Length: 2\r\n\r\nhi".encode()


def read_reply(sock):
    """A Content-Length or chunked reply; b'' at EOF."""
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(65536)
        if not chunk:
            return buf
        buf += chunk
    head, _, rest = buf.partition(b"\r\n\r\n")
    if b"chunked" in head:
        while not rest.endswith(b"0\r\n\r\n"):
            rest += sock.recv(65536)
        return head + b"\r\n\r\n" + rest
    length = int([ln.split(b":")[1] for ln in head.split(b"\r\n") if ln.lower().startswith(b"content-length")][0])
    while len(rest) < length:
        rest += sock.recv(65536)
    return head + b"\r\n\r\n" + rest


class ProxyTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="mp-px-", dir="/tmp")
        self.up = Upstream(os.path.join(self.dir, "api.sock"))

    def tearDown(self):
        self.up.stop()

    def proxy(self, rules=None):
        p = Proxy("t", ("unix", os.path.join(self.dir, "px.sock")), ("unix", self.up.path), rules).start()
        self.addCleanup(p.stop)
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        c.settimeout(5)
        c.connect(os.path.join(self.dir, "px.sock"))
        self.addCleanup(c.close)
        return p, c

    def test_two_requests_on_one_client_connection_are_two_records_and_one_connection(self):
        p, c = self.proxy()
        for path in ("/a", "/b"):
            c.sendall(request(path))
            self.assertTrue(read_reply(c).endswith(path.encode()))
        snap = p.snapshot()
        self.assertEqual(snap["connections"], 1)
        self.assertEqual([(r["conn"], r["path"], r["contentType"]) for r in snap["requests"]],
                         [(1, "/a", "application/proto"), (1, "/b", "application/proto")])
        self.assertEqual(self.up.connections, 1, "one upstream connection carries both")

    def test_a_chunked_stream_is_relayed_whole_and_the_connection_kept(self):
        p, c = self.proxy()
        c.sendall(request("/chunked"))
        self.assertTrue(read_reply(c).endswith(b"3\r\none\r\n3\r\ntwo\r\n0\r\n\r\n"))
        c.sendall(request("/after"))
        self.assertTrue(read_reply(c).endswith(b"/after"))
        self.assertEqual(p.snapshot()["connections"], 1)

    def test_a_close_delimited_reply_closes_the_client_connection(self):
        p, c = self.proxy()
        c.sendall(request("/closing"))
        data = b""
        while True:
            chunk = c.recv(65536)
            if not chunk:
                break
            data += chunk
        self.assertTrue(data.endswith(b"stream-bytes"))

    def test_replay_sends_upstream_twice_and_answers_once(self):
        p, c = self.proxy({"POST /x": "replay"})
        c.sendall(request("/x"))
        self.assertTrue(read_reply(c).endswith(b"/x"))
        time.sleep(0.1)
        self.assertEqual(self.up.seen, ["/x", "/x"])
        self.assertEqual(len(p.routes("POST /x")), 1, "recorded as one client request")

    def test_drop_after_reaches_upstream_once_and_the_client_sees_eof(self):
        p, c = self.proxy({"POST /x": "drop-after"})
        c.sendall(request("/warm"))
        read_reply(c)
        c.sendall(request("/x"))
        self.assertEqual(c.recv(65536), b"", "no byte of the reply")
        time.sleep(0.1)
        self.assertEqual(self.up.seen, ["/warm", "/x"])

    def test_drop_before_never_reaches_upstream(self):
        p, c = self.proxy({"POST /x": "drop-before"})
        c.sendall(request("/x"))
        self.assertEqual(c.recv(65536), b"")
        time.sleep(0.1)
        self.assertEqual(self.up.seen, [])
        self.assertEqual(len(p.routes("POST /x")), 1)


if __name__ == "__main__":
    unittest.main()
