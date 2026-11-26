"""One MicropodMCP process, newline-delimited JSON-RPC 2.0 over its stdio.

Every request and reply is appended to a JSONL transcript with its wall time,
so the receipt shows what the server was asked and what it answered, and the
census can attribute a child process to the tool call it happened during.
"""

import json
import queue
import subprocess
import threading
import time


class MCPError(Exception):
    pass


class MCPSession:
    def __init__(self, binary, env, transcript, stderr_path, client="b25-control-plane-gate"):
        self.transcript = open(transcript, "a")
        self.stderr = open(stderr_path, "a")
        self.proc = subprocess.Popen(
            [binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr, env=env, bufsize=0)
        self.pid = self.proc.pid
        self.lines = queue.Queue()
        self.next_id = 0
        threading.Thread(target=self._read, daemon=True).start()
        self.init = self.request("initialize", {
            "protocolVersion": "2024-11-05", "capabilities": {},
            "clientInfo": {"name": client, "version": "1"}})
        if "result" not in self.init:
            raise MCPError(f"initialize failed: {self.init}")
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def _read(self):
        for raw in iter(self.proc.stdout.readline, b""):
            line = raw.decode(errors="replace").strip()
            if line:
                self.lines.put(line)
        self.lines.put(None)

    def send(self, message):
        """Writes one message (a dict, or a raw line for malformed-input tests)."""
        self._log("send", message)
        line = message if isinstance(message, str) else json.dumps(message)
        self.proc.stdin.write((line + "\n").encode())
        self.proc.stdin.flush()

    def _log(self, direction, message):
        self.transcript.write(json.dumps({"t": round(time.time(), 6), "dir": direction, "msg": message}) + "\n")
        self.transcript.flush()

    def wait_reply(self, rid, timeout=180, what="request"):
        deadline = time.time() + timeout
        while True:
            left = deadline - time.time()
            if left <= 0:
                raise MCPError(f"{what}: no reply within {timeout}s")
            try:
                line = self.lines.get(timeout=left)
            except queue.Empty:
                raise MCPError(f"{what}: no reply within {timeout}s") from None
            if line is None:
                raise MCPError(f"{what}: MicropodMCP exited (status {self.proc.poll()})")
            try:
                reply = json.loads(line)
            except ValueError:
                self._log("recv-unparsed", line)
                continue
            self._log("recv", reply)
            if reply.get("id") == rid:
                return reply

    def request(self, method, params, timeout=180):
        self.next_id += 1
        rid = self.next_id
        self.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        return self.wait_reply(rid, timeout, method)

    def call(self, name, arguments, timeout=300):
        """tools/call → dict(error, text, parsed, rpcError, t0, t1)."""
        t0 = time.time()
        reply = self.request("tools/call", {"name": name, "arguments": arguments}, timeout=timeout)
        t1 = time.time()
        if "error" in reply:
            return {"error": True, "text": json.dumps(reply["error"]), "parsed": None, "rpcError": reply["error"],
                    "t0": t0, "t1": t1}
        result = reply.get("result") or {}
        text = "".join(c.get("text", "") for c in result.get("content") or [] if c.get("type") == "text")
        try:
            parsed = json.loads(text)
        except ValueError:
            parsed = None
        return {"error": bool(result.get("isError")), "text": text, "parsed": parsed, "rpcError": None,
                "t0": t0, "t1": t1}

    def close(self):
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        self.transcript.close()
        self.stderr.close()
