"""A recording HTTP/1.1 proxy in front of the MicropodAPI, for the replay test.

The gate points a MicropodMCP process at a Unix socket and a loopback port of
this proxy (MICROPOD_API_SOCK, MICROPOD_API_PORT) and the proxy forwards to
the real API. Every connection and every request (method, path, Content-Type,
time) is recorded. A rule can, for one route, break the exchange the way a
crashing daemon or a dying socket would:

  drop-after   forward the request, read the API's whole reply, then close the
               client's connection without a byte of it (the daemon acted;
               the reply was lost)
  drop-before  close the client's connection without forwarding (nothing
               reached the daemon)
  replay       forward the request twice (a client that resends) — the gate's
               own sabotage, so the "applied once" check can be seen to fail

Requests are read with their Content-Length body; the API's replies carry
Connection: close, so one connection is one exchange. A passed reply is
relayed as it arrives (a log stream does not end). Relayed to the API's TCP
port, a request's Host names that port, as the API's loopback guard expects.
"""

import os
import select
import socket
import threading
import time


def _read_request(conn, limit=8 << 20):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(65536)
        if not chunk:
            return None
        data += chunk
        if len(data) > limit:
            return None
    head, _, body = data.partition(b"\r\n\r\n")
    length = 0
    for line in head.split(b"\r\n")[1:]:
        k, _, v = line.partition(b":")
        if k.strip().lower() == b"content-length":
            length = int(v.strip() or 0)
    while len(body) < length:
        chunk = conn.recv(65536)
        if not chunk:
            break
        body += chunk
    return head, body


def _headers(head):
    lines = head.split(b"\r\n")
    method, path = (lines[0].split(b" ") + [b"", b""])[:2]
    hdrs = {}
    for line in lines[1:]:
        k, _, v = line.partition(b":")
        hdrs[k.strip().lower().decode(errors="replace")] = v.strip().decode(errors="replace")
    return method.decode(), path.decode(), hdrs


class Proxy:
    def __init__(self, name, listen, upstream, rules=None):
        """listen/upstream: ("unix", path) or ("tcp", port)."""
        self.name = name
        self.listen = listen
        self.upstream = upstream
        self.rules = dict(rules or {})
        self.requests = []
        self.connections = 0
        self.lock = threading.Lock()
        self.halt = False
        self.sock = None

    def _connect_upstream(self):
        kind, where = self.upstream
        if kind == "unix":
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(where)
        else:
            s = socket.create_connection(("127.0.0.1", where))
        s.settimeout(600)
        return s

    def _exchange(self, raw, client=None):
        """Sends raw upstream and returns the whole reply; with `client`, the
        reply is relayed to it as it arrives (a log stream never ends), until
        either side closes."""
        up = self._connect_upstream()
        try:
            up.sendall(raw)
            reply = b""
            watch = [up] + ([client] if client is not None else [])
            while True:
                ready, _, _ = select.select(watch, [], [], 600)
                if not ready:
                    break
                if client is not None and client in ready:
                    if not client.recv(65536):
                        break  # the client hung up
                if up in ready:
                    chunk = up.recv(65536)
                    if not chunk:
                        break
                    if client is None or len(reply) < 1 << 20:
                        reply += chunk
                    if client is not None:
                        client.sendall(chunk)
            return reply
        finally:
            up.close()

    def start(self):
        kind, where = self.listen
        if kind == "unix":
            try:
                os.unlink(where)
            except FileNotFoundError:
                pass
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.bind(where)
            os.chmod(where, 0o600)
        else:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(("127.0.0.1", where))
        s.listen(64)
        s.settimeout(0.2)
        self.sock = s
        threading.Thread(target=self._accept, daemon=True).start()
        return self

    def _accept(self):
        while not self.halt:
            try:
                conn, _ = self.sock.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            with self.lock:
                self.connections += 1
                cid = self.connections
            threading.Thread(target=self._serve, args=(conn, cid), daemon=True).start()

    def _serve(self, conn, cid):
        conn.settimeout(600)
        try:
            got = _read_request(conn)
            if got is None:
                return
            head, body = got
            method, path, hdrs = _headers(head)
            route = f"{method} {path.split('?')[0]}"
            action = self.rules.get(route, "pass")
            rec = {"proxy": self.name, "conn": cid, "t": round(time.time(), 6), "method": method, "path": path,
                   "contentType": hdrs.get("content-type", ""), "action": action, "bytes": len(body)}
            with self.lock:
                self.requests.append(rec)
            if self.upstream[0] == "tcp":
                # The API checks Host against its own loopback port: a request
                # relayed from the proxy's port must name the API's.
                lines = head.split(b"\r\n")
                lines = [lines[0]] + [(f"Host: 127.0.0.1:{self.upstream[1]}".encode() if ln.lower().startswith(b"host:")
                                       else ln) for ln in lines[1:]]
                head = b"\r\n".join(lines)
            raw = head + b"\r\n\r\n" + body
            if action == "drop-before":
                return
            reply = self._exchange(raw, client=conn if action == "pass" else None)
            rec["upstreamStatus"] = reply.split(b" ", 2)[1].decode(errors="replace") if reply[:5] == b"HTTP/" else ""
            if action == "replay":
                second = self._exchange(raw)
                rec["replayStatus"] = second.split(b" ", 2)[1].decode(errors="replace") if second[:5] == b"HTTP/" else ""
                conn.sendall(reply)
        except OSError as e:
            with self.lock:
                self.requests.append({"proxy": self.name, "conn": cid, "t": round(time.time(), 6), "error": str(e)})
        finally:
            try:
                conn.close()
            except OSError:
                pass

    def routes(self, route):
        with self.lock:
            return [r for r in self.requests if f"{r.get('method')} {str(r.get('path', '')).split('?')[0]}" == route]

    def snapshot(self):
        with self.lock:
            return {"connections": self.connections, "requests": list(self.requests)}

    def stop(self):
        self.halt = True
        try:
            self.sock.close()
        except OSError:
            pass
        if self.listen[0] == "unix":
            try:
                os.unlink(self.listen[1])
            except FileNotFoundError:
                pass
