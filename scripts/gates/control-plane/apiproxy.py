"""A recording HTTP/1.1 proxy in front of the MicropodAPI, for the wire and replay tests.

The gate points a MicropodMCP process at a Unix socket and a loopback port of
this proxy (MICROPOD_API_SOCK, MICROPOD_API_PORT) and the proxy forwards to
the real API. Every client connection and every request (connection, method,
path, Content-Type, time) is recorded. A rule can, for one route, break the
exchange the way a crashing daemon or a dying socket would:

  drop-after   forward the request, read the API's whole reply, then close the
               client's connection without a byte of it (the daemon acted;
               the reply was lost)
  drop-before  close the client's connection without forwarding (nothing
               reached the daemon)
  replay       forward the request twice (a client that resends) — the gate's
               own sabotage, so the "applied once" check can be seen to fail

Connections persist as the API's do: each client connection has one upstream
connection, and a request follows the previous one's reply on both. A reply is
delimited by its Content-Length, by chunked transfer coding (a stream the
client asked to keep), or by the close that ends it (a stream that was not);
after a close-delimited reply, or one saying Connection: close, both
connections close. Replies are relayed as they arrive (a log stream need not
end). Relayed to the API's TCP port, a request's Host names that port, as the
API's loopback guard expects.
"""

import os
import select
import socket
import threading
import time

LIMIT = 8 << 20  # a request head and body this proxy will hold


class Closed(Exception):
    """The peer closed before a whole message arrived."""


class Conn:
    """A socket with a read buffer."""

    def __init__(self, sock):
        self.sock = sock
        self.buf = b""

    def fill(self):
        chunk = self.sock.recv(65536)
        if not chunk:
            raise Closed()
        self.buf += chunk

    def until(self, marker):
        while marker not in self.buf:
            if len(self.buf) > LIMIT:
                raise Closed()
            self.fill()
        head, _, self.buf = self.buf.partition(marker)
        return head

    def take(self, n):
        while len(self.buf) < n:
            self.fill()
        out, self.buf = self.buf[:n], self.buf[n:]
        return out


def _fields(head):
    lines = head.split(b"\r\n")
    hdrs = {}
    for line in lines[1:]:
        k, _, v = line.partition(b":")
        hdrs[k.strip().lower().decode(errors="replace")] = v.strip().decode(errors="replace")
    return lines[0], hdrs


def _read_request(c):
    """(head, body) of the next request on c, or None when it closed between requests."""
    try:
        head = c.until(b"\r\n\r\n")
    except Closed:
        return None
    _, hdrs = _fields(head)
    length = int(hdrs.get("content-length") or 0)
    body = c.take(length) if length else b""
    return head, body


def _headers(head):
    first, hdrs = _fields(head)
    method, path = (first.split(b" ") + [b"", b""])[:2]
    return method.decode(), path.decode(), hdrs


class Reply:
    """One reply read from upstream, piece by piece: `pieces()` yields its
    bytes as they arrive; afterwards `keep` says whether the connection may
    carry another request."""

    def __init__(self, up):
        self.up = up
        self.status = ""
        self.keep = False
        self.data = b""  # the first MiB, for the record

    def pieces(self):
        head = self.up.until(b"\r\n\r\n") + b"\r\n\r\n"
        first, hdrs = _fields(head[:-4])
        parts = first.split(b" ", 2)
        self.status = parts[1].decode(errors="replace") if len(parts) > 1 else ""
        closing = "close" in hdrs.get("connection", "").lower() or first.startswith(b"HTTP/1.0")
        yield self._keep(head)
        if hdrs.get("transfer-encoding", "").lower() == "chunked":
            while True:
                line = self.up.until(b"\r\n")
                size = int(line.split(b";")[0].strip() or b"0", 16)
                if size == 0:
                    # The last chunk, then trailer fields up to an empty line.
                    trailer = b""
                    while True:
                        field = self.up.until(b"\r\n")
                        trailer += field + b"\r\n"
                        if not field:
                            break
                    yield self._keep(line + b"\r\n" + trailer)
                    self.keep = not closing
                    return
                yield self._keep(line + b"\r\n" + self.up.take(size + 2))
        elif "content-length" in hdrs:
            left = int(hdrs["content-length"] or 0)
            if self.up.buf:
                part, self.up.buf = self.up.buf[:left], self.up.buf[left:]
                left -= len(part)
                yield self._keep(part)
            while left > 0:
                chunk = self.up.sock.recv(min(65536, left))
                if not chunk:
                    raise Closed()
                left -= len(chunk)
                yield self._keep(chunk)
            self.keep = not closing
        else:
            # Delimited by the close that ends it.
            if self.up.buf:
                part, self.up.buf = self.up.buf, b""
                yield self._keep(part)
            while True:
                chunk = self.up.sock.recv(65536)
                if not chunk:
                    return
                yield self._keep(chunk)

    def _keep(self, piece):
        if len(self.data) < 1 << 20:
            self.data += piece
        return piece

    def read_all(self):
        for _ in self.pieces():
            pass
        return self.data


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
        return Conn(s)

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

    def _record(self, rec):
        with self.lock:
            self.requests.append(rec)

    def _serve(self, conn, cid):
        conn.settimeout(600)
        client = Conn(conn)
        up = None
        try:
            while True:
                got = _read_request(client)
                if got is None:
                    return
                head, body = got
                method, path, hdrs = _headers(head)
                route = f"{method} {path.split('?')[0]}"
                action = self.rules.get(route, "pass")
                rec = {"proxy": self.name, "conn": cid, "t": round(time.time(), 6), "method": method, "path": path,
                       "contentType": hdrs.get("content-type", ""), "action": action, "bytes": len(body)}
                self._record(rec)
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
                if up is None:
                    up = self._connect_upstream()
                up.sock.sendall(raw)
                reply = Reply(up)
                if action == "drop-after":
                    data = reply.read_all()
                    rec["upstreamStatus"] = reply.status
                    return
                if action == "replay":
                    first = reply.read_all()
                    rec["upstreamStatus"] = reply.status
                    if not reply.keep:
                        up.sock.close()
                        up = self._connect_upstream()
                    up.sock.sendall(raw)
                    second = Reply(up)
                    second.read_all()
                    rec["replayStatus"] = second.status
                    conn.sendall(first)
                    if not second.keep:
                        return
                    continue
                if not self._relay(reply, client):
                    return
                rec["upstreamStatus"] = reply.status
                if not reply.keep:
                    return
        except (OSError, Closed) as e:
            self._record({"proxy": self.name, "conn": cid, "t": round(time.time(), 6), "error": repr(e)})
        finally:
            for s in (conn, up.sock if up else None):
                try:
                    if s:
                        s.close()
                except OSError:
                    pass

    def _relay(self, reply, client):
        """Relays the reply as it arrives; False when the client hung up."""
        for piece in reply.pieces():
            client.sock.sendall(piece)
            # A client gone while a long reply streams ends it.
            ready, _, _ = select.select([client.sock], [], [], 0)
            if ready:
                try:
                    chunk = client.sock.recv(65536, socket.MSG_PEEK)
                except OSError:
                    return False
                if not chunk:
                    return False
        return True

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
