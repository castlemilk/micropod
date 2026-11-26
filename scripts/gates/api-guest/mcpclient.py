"""A minimal MCP client: one MicropodMCP process, newline-delimited JSON-RPC
2.0 over its stdin/stdout (the framing MicropodMCP speaks).

Every request and reply is appended to a JSONL transcript so a receipt shows
exactly what the server was asked and what it answered.
"""

import json
import queue
import subprocess
import threading
import time


class MCPError(Exception):
    pass


class MCPSession:
    def __init__(self, binary, env, transcript, stderr_path):
        self.transcript = open(transcript, "a")
        self.stderr = open(stderr_path, "a")
        self.proc = subprocess.Popen(
            [binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr, env=env, bufsize=0)
        self.lines = queue.Queue()
        self.next_id = 0
        threading.Thread(target=self._read, daemon=True).start()
        init = self.request("initialize", {
            "protocolVersion": "2024-11-05", "capabilities": {},
            "clientInfo": {"name": "b24-api-guest-gate", "version": "1"}})
        if "result" not in init:
            raise MCPError(f"initialize failed: {init}")
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def _read(self):
        for raw in iter(self.proc.stdout.readline, b""):
            line = raw.decode(errors="replace").strip()
            if line:
                self.lines.put(line)
        self.lines.put(None)

    def _send(self, message):
        self._log("send", message)
        self.proc.stdin.write((json.dumps(message) + "\n").encode())
        self.proc.stdin.flush()

    def _log(self, direction, message):
        self.transcript.write(json.dumps({"t": round(time.time(), 3), "dir": direction, "msg": message}) + "\n")
        self.transcript.flush()

    def request(self, method, params, timeout=180):
        self.next_id += 1
        rid = self.next_id
        self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        deadline = time.time() + timeout
        while True:
            left = deadline - time.time()
            if left <= 0:
                raise MCPError(f"{method}: no reply within {timeout}s")
            try:
                line = self.lines.get(timeout=left)
            except queue.Empty:
                raise MCPError(f"{method}: no reply within {timeout}s")
            if line is None:
                raise MCPError(f"{method}: MicropodMCP exited (status {self.proc.poll()})")
            try:
                reply = json.loads(line)
            except ValueError:
                self._log("recv-unparsed", line)
                continue
            self._log("recv", reply)
            if reply.get("id") == rid:
                return reply

    def call(self, name, arguments, timeout=180):
        """tools/call: (is_error, text, parsed JSON of the text or None)."""
        reply = self.request("tools/call", {"name": name, "arguments": arguments}, timeout=timeout)
        if "error" in reply:
            return True, json.dumps(reply["error"]), None
        result = reply.get("result") or {}
        text = "".join(c.get("text", "") for c in result.get("content") or [] if c.get("type") == "text")
        try:
            parsed = json.loads(text)
        except ValueError:
            parsed = None
        return bool(result.get("isError")), text, parsed

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
