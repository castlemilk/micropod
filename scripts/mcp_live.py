#!/usr/bin/env python3
"""Live validation of a Micropod MCP server against the real machine.

One persistent stdio session, like a real client, driving every tool family
against the real container runtime, the API daemon (:45454), the running
app's updater and the metrics history it records:
- sandbox_run: plain, exit codes, overlay mounts, expose_host, ports,
  allow_hosts, secrets
- checkpoints
- the micropod.json trust gate
- a sandbox container end to end (run/list/exec/logs/inspect/stop/delete)
- update_status/check
- metrics_history
- machines

  scripts/mcp_live.py                        # .build/debug/MicropodMCP
  MCP=~/.local/bin/micropod-mcp scripts/mcp_live.py   # what the plugin runs
  OFFLINE=1 scripts/mcp_live.py              # skip example.com / postman-echo

It changes the machine only transiently. It creates and deletes one sandbox
and one checkpoint (both `mcp-live-<pid>`), and asks the app to check for
updates. The secrets check sends a random token to postman-echo.com.
sandbox_run needs the micropod CLI (MICROPOD_CLI, ~/.local/bin/micropod or
/usr/local/bin/micropod).
"""
import http.server
import json
import os
import select
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MCP = os.environ.get("MCP", f"{ROOT}/.build/debug/MicropodMCP")
OFFLINE = os.environ.get("OFFLINE") == "1"
results = []


class Session:
    def __init__(self, cwd=None, env=None):
        self.proc = subprocess.Popen([MCP], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     text=True, bufsize=1, cwd=cwd, env={**os.environ, **(env or {})})
        self.next_id = 0

    def request(self, method, params=None, timeout=300):
        self.next_id += 1
        msg = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            msg["params"] = params
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()
        deadline = time.time() + timeout
        while time.time() < deadline:
            ready, _, _ = select.select([self.proc.stdout], [], [], 1)
            if not ready:
                continue
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("MCP server exited: " + self.proc.stderr.read()[-500:])
            reply = json.loads(line)
            if reply.get("id") == self.next_id:
                return reply
        raise TimeoutError(f"{method} timed out")

    def call(self, tool, timeout=300, **arguments):
        reply = self.request("tools/call", {"name": tool, "arguments": arguments}, timeout=timeout)
        result = reply.get("result", {})
        text = "".join(c.get("text", "") for c in result.get("content", []))
        return text, bool(result.get("isError")) or "error" in reply

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=10)


def check(name, ok, detail=""):
    results.append((name, bool(ok)))
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + ("" if ok else f"\n         {detail[:400]}"))


def section(title):
    print(f"\n== {title}")


s = Session()
section("protocol")
init = s.request("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                "clientInfo": {"name": "live-validation", "version": "0"}})
check("initialize", init.get("result", {}).get("protocolVersion") == "2024-11-05", json.dumps(init))
info = init.get("result", {}).get("serverInfo", {})
check(f"serverInfo: {info.get('name')} {info.get('version')}", info.get("name") == "micropod" and info.get("version"),
      json.dumps(init))
s.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
tools = {t["name"] for t in s.request("tools/list").get("result", {}).get("tools", [])}
check(f"tools/list: {len(tools)} tools", len(tools) == 51, str(sorted(tools)))
for t in ["metrics_history", "sandbox_run", "sandbox_checkpoints", "sandbox_checkpoint_create",
          "sandbox_checkpoint_delete", "machine_stats", "machine_logs", "update_status", "update_check"]:
    check(f"advertises {t}", t in tools)

section("system")
text, err = s.call("status")
check("status: runtime running", not err and "running" in text.lower(), text)
text, err = s.call("runtimes")
check("runtimes: sandbox engine available", not err and "sandbox" in text, text)

section("updates (the app's Sparkle updater over app-control)")
text, err = s.call("update_status")
check("update_status reports 0.11.1, not stuck 'checking'",
      not err and "0.11.1" in text and "checking" not in text.lower(), text)
text, err = s.call("update_check")
check("update_check accepted", not err, text)
for _ in range(20):
    time.sleep(1.5)
    text, err = s.call("update_status")
    if "checking" not in text.lower():
        break
check("check settles to up to date", not err and ("uptodate" in text.lower().replace(" ", "").replace("_", "")
                                                   or "up to date" in text.lower() or "idle" in text.lower()), text)

section("metrics history (recorded by the app)")
text, err = s.call("metrics_history", range="15m")
check("system history: points + sparklines", not err and "all containers:" in text and "points at 10s" in text
      and "cpu" in text and any(c in text for c in "▁▂▃▄▅▆▇█"), text)
text, err = s.call("metrics_history", range="7d")
check("7d range reads a coarser tier", not err and ("points at 900s" in text or "no history" in text), text)
text, err = s.call("list_containers")
running = [line.split()[0] for line in text.splitlines() if " running" in line or "\trunning" in line]
if running:
    cid = running[0]
    text, err = s.call("metrics_history", id=cid, range="1h")
    check(f"per-container history ({cid[:24]})", not err and f"container {cid}" in text, text)
text, err = s.call("metrics_history", id="definitely-not-a-container", range="1h")
check("unknown container: 'no history', not an error", not err and "no history" in text, text)
text, err = s.call("metrics_history", range="soon")
check("bad range is an error", err and "range" in text, text)

section("sandbox_run (the CLI's micro-VMs)")
text, err = s.call("sandbox_run", command="echo hello-from-mcp; uname -m; cat /etc/os-release | head -1")
check("plain run", not err and "hello-from-mcp" in text and "aarch64" in text and "exit 0" in text, text)
text, err = s.call("sandbox_run", command="exit 7")
check("exit code surfaces", "exit 7" in text, text)

work = tempfile.mkdtemp(prefix="mcp-live-", dir=os.path.expanduser("~/.micropod"))
open(os.path.join(work, "host.txt"), "w").write("original\n")
text, err = s.call("sandbox_run", command="cat /w/host.txt; echo changed > /w/host.txt; cat /w/host.txt",
                   mounts=f"{work}:/w")
check("overlay mount: guest sees + changes its copy", not err and "original" in text and "changed" in text, text)
check("overlay mount: host file untouched", open(os.path.join(work, "host.txt")).read() == "original\n")


class Hello(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"host-says-hi")

    def log_message(self, *a):
        pass


srv = http.server.HTTPServer(("127.0.0.1", 18461), Hello)
threading.Thread(target=srv.serve_forever, daemon=True).start()
text, err = s.call("sandbox_run", command="wget -q -T 5 -O - http://host.micropod.internal:18461/",
                   expose_host="18461")
check("expose_host: guest reaches a host loopback port", not err and "host-says-hi" in text, text)
srv.shutdown()

seen = {}


def poll_port():
    for _ in range(60):
        try:
            with urllib.request.urlopen("http://127.0.0.1:18462/", timeout=1) as r:
                seen["body"] = r.read().decode()
                return
        except Exception:
            time.sleep(0.25)


poller = threading.Thread(target=poll_port)
poller.start()
text, err = s.call("sandbox_run", ports="18462:8080",
                   command="for i in 1 2 3 4 5 6 7 8; do printf 'HTTP/1.0 200 OK\\r\\n\\r\\nport-ok' | nc -l -p 8080 -w 1; done; true")
poller.join()
check("ports: host 127.0.0.1:18462 → guest :8080", seen.get("body") == "port-ok", f"{seen} / {text}")

if OFFLINE:
    print("  (OFFLINE=1: skipping allow_hosts and secrets, which need example.com / postman-echo.com)")
if not OFFLINE:
    text, err = s.call("sandbox_run", allow_net="true", allow_hosts="example.com",
                       command="wget -q -T 8 -O /dev/null https://example.com && echo allowed-ok; "
                               "wget -q -T 8 -O /dev/null https://www.google.com 2>&1 | head -1")
    check("allow_hosts: allowed host works", "allowed-ok" in text, text)
    check("allow_hosts: other hosts refused (403)", "403" in text, text)

    token = f"mcp-live-{os.getpid()}"
    s2 = Session(env={"MCP_LIVE_TOKEN": token})
    s2.request("initialize", {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "v", "version": "0"}})
    text, err = s2.call("sandbox_run", allow_net="true", secrets="TOKEN=MCP_LIVE_TOKEN@postman-echo.com",
                        command='echo "guest=$TOKEN"; wget -q -T 10 -O - --header "Authorization: Bearer $TOKEN" '
                                'https://postman-echo.com/get | tr "," "\\n" | grep -o "Bearer [^\\"]*"')
    s2.close()
    check("secrets: guest only sees a placeholder", "guest=micropod_secret_" in text and token not in text.split("Bearer")[0], text)
    check("secrets: upstream received the real value", f"Bearer {token}" in text, text)

section("checkpoints")
name = f"mcp-live-{os.getpid()}"
text, err = s.call("sandbox_checkpoint_create", name=name, command="echo kept > /root/marker")
check("checkpoint_create", not err and "saved" in text, text)
text, err = s.call("sandbox_checkpoints")
check("checkpoints lists it", not err and name in text, text)
text, err = s.call("sandbox_run", **{"from": name}, command="cat /root/marker")
check("run from checkpoint keeps its disk", not err and "kept" in text, text)
text, err = s.call("sandbox_checkpoint_delete", name=name)
check("checkpoint_delete", not err, text)
text, err = s.call("sandbox_checkpoints")
check("gone after delete", name not in text, text)

section("micropod.json trust gate, through MCP")
repo = tempfile.mkdtemp(prefix="mcp-trust-")
json.dump({"mounts": ["/etc:/hostetc:ro"], "expose_host": [45454]}, open(os.path.join(repo, "micropod.json"), "w"))
s3 = Session(cwd=repo)
s3.request("initialize", {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "v", "version": "0"}})
text, err = s3.call("sandbox_run", command="ls /hostetc | head -1")
s3.close()
check("an untrusted micropod.json can't grant host access", err and "micropod sandbox trust" in text
      and "mount /etc:/hostetc:ro" in text, text)

section("sandbox containers via run(runtime: sandbox) — the shared daemon")
text, err = s.call("run", image="alpine:3.20", runtime="sandbox", name=f"mcp-live-{os.getpid()}",
                   command="echo booted-for-mcp; sleep 300")
check("run on the sandbox runtime", not err and "Started" in text, text)
sid = f"mcp-live-{os.getpid()}"
text, err = s.call("list_containers")
check("list_containers shows the sandbox", sid in text, text[-600:])
text, err = s.call("exec", id=sid, command="echo exec-ok")
check("exec reaches the sandbox", not err and "exec-ok" in text, text)
text, err = s.call("logs", id=sid, lines="5")
check("logs reach the sandbox", not err and "booted-for-mcp" in text, text)
text, err = s.call("exec", id=sid, command="exit 3")
check("exec failure surfaces its exit code", err and "exit 3" in text, text)
text, err = s.call("inspect", id=sid)
check("inspect reaches the sandbox", not err and '"runtime" : "sandbox"' in text, text)
text, err = s.call("stop", id=sid)
check("stop reaches the sandbox", not err and "[sandbox]" in text, text)
text, err = s.call("delete", id=sid)
check("delete removes the sandbox", not err, text)

section("machines")
text, err = s.call("list_machines")
check("list_machines", not err, text)
text, err = s.call("machine_stats")
check("machine_stats (none running is fine)", not err, text)

s.close()
shutil.rmtree(work, ignore_errors=True)
shutil.rmtree(repo, ignore_errors=True)
failed = [n for n, ok in results if not ok]
print(f"\n{len(results) - len(failed)}/{len(results)} passed" + (f" — FAILED: {', '.join(failed)}" if failed else ""))
sys.exit(1 if failed else 0)
