#!/usr/bin/env python3
"""End-to-end validation of the Micropod MCP server (JSON-RPC 2.0 over STDIO).

Drives .build/debug/micropod-mcp against the stateful mock container CLI and
asserts every tool's response. Exits non-zero on the first failed check.

Usage: scripts/mcp_e2e.py [--cli PATH] [--state-dir DIR]
  --cli       the container CLI executable (default: mock in Tests/)
  --state-dir where the mock keeps state (default: fresh temp dir)
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
MOCK = ROOT / "Tests" / "MicropodIntegrationTests" / "Support" / "mock-container"

checks = []
failures = []


def check(name, condition, detail=""):
    checks.append(name)
    status = "PASS" if condition else "FAIL"
    print(f"  [{status}] {name}" + (f" — {detail}" if detail and not condition else ""))
    if not condition:
        failures.append(name)


def rpc(binary, state_dir, cli_path, requests):
    """Send newline-delimited JSON-RPC requests, return list of response dicts."""
    env = dict(os.environ)
    env["MICROPOD_CONTAINER_CLI_PATH"] = cli_path
    env["MICROPOD_MOCK_STATE_DIR"] = state_dir
    # Isolate the volume-policy file so policy tool calls don't touch
    # the developer's real config.
    env["MICROPOD_VOLUME_POLICY"] = os.path.join(state_dir, "policy.json")
    payload = "".join(json.dumps(r) + "\n" for r in requests)
    proc = subprocess.run(
        [str(binary)], input=payload, capture_output=True, text=True, env=env, timeout=60)
    responses = []
    for line in proc.stdout.splitlines():
        if line.strip():
            responses.append(json.loads(line))
    return responses, proc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cli", default=str(MOCK))
    ap.add_argument("--state-dir", default=None)
    args = ap.parse_args()

    binary = ROOT / ".build" / "debug" / "MicropodMCP"
    if not binary.exists():
        print(f"MCP binary not found at {binary}; run `swift build` first")
        return 1

    state_dir = args.state_dir or tempfile.mkdtemp(prefix="micropod-mcp-e2e-")

    print("== initialize")
    (responses, _) = rpc(binary, state_dir, args.cli, [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                    "clientInfo": {"name": "e2e", "version": "0"}}}])
    check("initialize returns protocolVersion",
          responses and responses[0].get("result", {}).get("protocolVersion") == "2024-11-05")

    print("== tools/list")
    (responses, _) = rpc(binary, state_dir, args.cli, [
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}])
    tools = (responses[0].get("result", {}).get("tools", []) if responses else [])
    names = [t.get("name") for t in tools]
    expected = {"status", "list_containers", "start", "stop", "restart", "kill", "delete",
                "run", "exec", "logs", "stats", "inspect",
                "list_images", "list_volumes", "list_networks",
                "pull", "push", "df", "compose_up", "compose_down", "compose_ps",
                "share_mount", "share_unmount", "share_list", "share_sync", "share_gc",
                "build_cache_stats", "volume_policy", "volume_policy_set",
                "update_check", "update_status", "update_apply"}
    check("all 32 tools advertised", set(names) == expected, f"got {sorted(names)}")

    def call(tool_id, tool, **arguments):
        (responses, _) = rpc(binary, state_dir, args.cli, [
            {"jsonrpc": "2.0", "id": tool_id, "method": "tools/call",
             "params": {"name": tool, "arguments": arguments}}])
        if not responses:
            return {}
        result = responses[0].get("result", {})
        content = result.get("content", [])
        text = "".join(c.get("text", "") for c in content if c.get("type") == "text")
        return {"text": text, "isError": result.get("isError", False), "raw": responses[0]}

    print("== status")
    r = call(3, "status")
    check("status reports runtime + versions",
          "running" in r["text"] and "cli 1.2.3" in r["text"], r["text"])

    print("== run")
    r = call(4, "run", image="nginx:1.27", name="e2e-box")
    check("run starts a container", r["text"].startswith("Started mpc-"), r["text"])

    print("== list_containers")
    r = call(5, "list_containers")
    check("list_containers shows the new container",
          "e2e-box" in r["text"] or "mpc-" in r["text"], r["text"])

    print("== pull")
    r = call(6, "pull", reference="redis:7")
    check("pull completes", "Pulled" in r["text"] and not r["isError"], r["text"])

    print("== df")
    r = call(7, "df")
    check("df reports categories",
          "Containers:" in r["text"] and "Images:" in r["text"] and "Volumes:" in r["text"], r["text"])

    print("== compose_up")
    compose_dir = pathlib.Path(tempfile.mkdtemp(prefix="micropod-compose-e2e-"))
    compose = compose_dir / "docker-compose.yml"
    compose.write_text("""
name: e2estack
services:
  web:
    image: nginx:1.27
  db:
    image: postgres:16
    depends_on: [web]
    volumes:
      - pgdata:/var/lib/postgresql/data
volumes:
  pgdata:
networks:
  front:
""")
    r = call(8, "compose_up", path=str(compose))
    check("compose_up completes", "Compose up complete" in r["text"] and not r["isError"], r["text"])

    print("== list_containers after compose")
    r = call(9, "list_containers")
    lines = [l for l in r["text"].splitlines() if l]
    check("compose containers present", len(lines) >= 3, r["text"])

    print("== stop + delete")
    r = call(10, "stop", id="e2e-box")
    check("stop succeeds", "Stopped" in r["text"] and not r["isError"], r["text"])
    r = call(11, "restart", id="e2e-box")
    check("restart succeeds", "Restarted" in r["text"] and not r["isError"], r["text"])
    r = call(12, "exec", id="e2e-box", command="echo mcp-exec-ok")
    check("exec returns output", "ok" in r["text"] and not r["isError"], r["text"])
    r = call(13, "stats")
    check("stats lists the running container", "mpc-" in r["text"], r["text"])
    r = call(14, "list_networks")
    check("list_networks shows the compose network", "front" in r["text"], r["text"])
    r = call(15, "compose_ps", name="e2estack")
    check("compose_ps lists the stack", "nginx:1.27" in r["text"], r["text"])
    r = call(16, "compose_down", name="e2estack")
    check("compose_down tears down", "Tore down" in r["text"] and not r["isError"], r["text"])
    r = call(17, "list_volumes")
    check("list_volumes works", not r["isError"], r["text"])
    r = call(18, "delete", id="e2e-box")
    check("delete succeeds", "Deleted" in r["text"] and not r["isError"], r["text"])

    print("== virtualFS tools (no daemon in e2e env: graceful errors + local stats)")
    os.environ["MICROPOD_SHAREDFS_SOCKET"] = os.path.join(
        tempfile.mkdtemp(prefix="micropod-no-share-"), "no-socket")
    r = call(19, "share_list")
    check("share_list without daemon is a clean error",
          r["isError"] and "not running" in r["text"], r["text"])
    r = call(20, "share_gc")
    check("share_gc without daemon is a clean error",
          r["isError"] and "not running" in r["text"], r["text"])
    empty_cache = tempfile.mkdtemp(prefix="micropod-empty-bcache-")
    r = call(21, "build_cache_stats", path=empty_cache)
    check("build_cache_stats reads any root without a daemon",
          "entries: 0" in r["text"] and not r["isError"], r["text"])

    print("== volume policy tools")
    r = call(90, "volume_policy_set", mode="goldens", goldens="ci-golden", sync="nosync")
    check("volume_policy_set saves", "cloneMode=goldens" in r["text"] and "sync=nosync" in r["text"],
          r["text"])
    r = call(91, "volume_policy")
    check("volume_policy reflects the write",
          "cloneMode: goldens" in r["text"] and "ci-golden" in r["text"], r["text"])
    r = call(92, "volume_policy_set", mode="bogus")
    check("volume_policy_set rejects bad mode", r["isError"] and "labels|goldens|all" in r["text"],
          r["text"])

    print("== unknown tool")
    (responses, _) = rpc(binary, state_dir, args.cli, [
        {"jsonrpc": "2.0", "id": 99, "method": "tools/call",
         "params": {"name": "definitely_not_a_tool", "arguments": {}}}])
    check("unknown tool is rejected",
          responses and responses[0].get("error", {}).get("code") == -32601)

    print(f"\n{len(checks) - len(failures)}/{len(checks)} checks passed")
    if failures:
        print(f"FAILED: {failures}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
