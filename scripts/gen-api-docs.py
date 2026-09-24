#!/usr/bin/env python3
"""Regenerate the GitHub Pages API documentation under landing/api/.

Sources of truth:
  - proto/micropod/v1/*.proto + vendored SandboxContext → OpenAPI via
    buf + protoc-gen-connect-openapi, and a self-contained proto
    reference via the pseudomuto-doc remote plugin (buf.gen.docs.yaml).
  - Sources/MicropodAPI/APIHandlers.swift → REST route table (the route
    cases are declarative; parsed here so docs can't drift).
  - .build/debug/MicropodMCP → tools/list over stdio JSON-RPC. If the
    binary is absent the committed mcp-tools.json is left in place, so
    docs can be regenerated on machines without the Swift toolchain.

Usage: scripts/gen-api-docs.py   (run from the repo root)
"""

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "landing" / "api"
HANDLERS = ROOT / "Sources" / "MicropodAPI" / "APIHandlers.swift"
MCP_BIN = ROOT / ".build" / "debug" / "MicropodMCP"

# Human descriptions for each REST route. Keyed by (method, path).
REST_DESCRIPTIONS = {
    ("GET", "/v1/health"): "Liveness probe.",
    ("GET", "/v1/usage"): "Disk usage report (containers, images, volumes).",
    ("GET", "/v1/system"): "Runtime status, versions, backend.",
    ("POST", "/v1/system/update"): "Check for runtime updates via the app control socket.",
    ("POST", "/v1/system/update/apply"): "Apply a pending runtime update.",
    ("GET", "/v1/system/update"): "Check for available runtime updates.",
    ("GET", "/v1/containers"): "List all containers.",
    ("POST", "/v1/containers"): "Run a container (create + start).",
    ("POST", "/v1/containers/create"): "Create a container without starting it.",
    ("POST", "/v1/containers/{id}/start"): "Start a stopped container.",
    ("POST", "/v1/containers/{id}/stop"): "Stop a running container.",
    ("POST", "/v1/containers/{id}/restart"): "Restart a container.",
    ("POST", "/v1/containers/{id}/kill"): "Force-kill a container.",
    ("DELETE", "/v1/containers/{id}"): "Delete a container (?force=true).",
    ("GET", "/v1/containers/{id}"): "Inspect a container.",
    ("GET", "/v1/containers/{id}/logs"): "Stream logs as SSE (?tail=N&boot=true).",
    ("GET", "/v1/containers/{id}/vsock/{port}"): "Raw duplex stream to a guest vsock port (native backend).",
    ("GET", "/v1/images"): "List local images.",
    ("POST", "/v1/images/pull"): "Pull an image; streams progress as SSE.",
    ("DELETE", "/v1/images/{ref}"): "Delete an image.",
    ("GET", "/v1/volumes"): "List volumes.",
    ("POST", "/v1/volumes"): "Create a named volume.",
    ("DELETE", "/v1/volumes/{name}"): "Delete a volume.",
    ("GET", "/v1/config/volumes"): "Read the shared volume-mount policy.",
    ("PUT", "/v1/config/volumes"): "Replace the volume-mount policy (partial bodies merge onto defaults).",
    ("GET", "/v1/networks"): "List networks.",
    ("POST", "/v1/networks"): "Create a network.",
    ("DELETE", "/v1/networks/{name}"): "Delete a network.",
    ("GET", "/v1/stats"): "Resource usage snapshot for running containers.",
    ("POST", "/v1/compose/up"): "docker-compose up from a compose file.",
    ("POST", "/v1/compose/down"): "docker-compose down.",
    ("POST", "/v1/exec"): "Run a command in a container; returns exit code + output.",
}

# First path parameter per resource (segments[2] in the handler).
PARAM_NAMES = {
    "containers": "id", "images": "ref", "volumes": "name",
    "networks": "name", "config": "section",
}
# Deeper params, keyed by (resource, segment index).
PARAM_OVERRIDES = {("containers", 4): "port"}

# Non-case routes handled before the switch in handleInner.
EXTRA_ROUTES = [
    {"method": "GET", "path": "/health",
     "description": "Liveness probe."},
    {"method": "GET", "path": "/metrics",
     "description": "Prometheus metrics (text format)."},
]

CASE_RE = re.compile(r'case \("(\w+)", \.(\w+)\)')
LITERAL_RE = re.compile(r'segments\[(\d+)\] == "([^"]+)"')
SET_RE = re.compile(r'\[([^\]]+)\]\.contains\(segments\[(\d+)\]\)')
COUNT_RE = re.compile(r'segments\.count == (\d+)')


def extract_rest_routes():
    """Parse the declarative route cases out of APIHandlers.swift.

    Case clauses may wrap (`case (...) \n where ...:`), so lines are
    joined until the clause terminates with a colon.
    """
    routes = []
    lines = HANDLERS.read_text().splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        m = CASE_RE.search(line)
        if not m:
            i += 1
            continue
        clause = line
        while not clause.rstrip().endswith(":") and i + 1 < len(lines):
            i += 1
            clause += " " + lines[i].strip()
        i += 1

        resource, method = m.group(1), m.group(2).upper()
        cond = clause[m.end():]
        count_m = COUNT_RE.search(cond)
        depth = int(count_m.group(1)) if count_m else 1
        literals = {int(idx): v for idx, v in LITERAL_RE.findall(cond)}
        sets = {int(idx): [s.strip().strip('"') for s in vals.split(",")]
                for vals, idx in SET_RE.findall(cond)}

        # segments[0] = "v1", segments[1] = resource, tails start at 2.
        # A `["a","b"].contains(segments[i])` set fans out into one row
        # per literal.
        paths = [[resource]]
        for idx in range(2, depth):
            if idx in literals:
                tail = [literals[idx]]
            elif idx in sets:
                tail = sets[idx]
            else:
                name = PARAM_OVERRIDES.get((resource, idx)) \
                    or (PARAM_NAMES.get(resource, "id") if idx == 2 else "arg")
                tail = ["{" + name + "}"]
            paths = [p + [t] for p in paths for t in tail]
        for p in paths:
            path = "/v1/" + "/".join(p)
            desc = REST_DESCRIPTIONS.get((method, path))
            if desc is None:
                print(f"warning: no description for {method} {path}",
                      file=sys.stderr)
            routes.append({"method": method, "path": path,
                           "description": desc or ""})
    return EXTRA_ROUTES + routes


def dump_mcp_tools():
    """Spawn the MCP binary and capture tools/list."""
    if not MCP_BIN.exists():
        print("note: MicropodMCP binary not built; keeping committed mcp-tools.json")
        return False
    rpc = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                    "clientInfo": {"name": "gen-api-docs", "version": "1"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
    ]
    proc = subprocess.run(
        [str(MCP_BIN)], input="\n".join(json.dumps(m) for m in rpc),
        capture_output=True, text=True, timeout=15)
    tools = None
    for line in proc.stdout.splitlines():
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        if msg.get("id") == 2 and "result" in msg:
            tools = msg["result"]["tools"]
    if tools is None:
        print("error: tools/list returned no result", file=sys.stderr)
        return False
    tools.sort(key=lambda t: t["name"])
    (OUT / "mcp-tools.json").write_text(json.dumps(tools, indent=2) + "\n")
    print(f"mcp-tools.json: {len(tools)} tools")
    return True


def git_version():
    """Latest tag minus the leading v — the spec's info.version."""
    tag = subprocess.run(
        ["git", "describe", "--tags", "--abbrev=0", "--match", "v*"],
        cwd=ROOT, capture_output=True, text=True).stdout.strip()
    return tag.lstrip("v") or None


def enrich_openapi(version):
    """Fill in document metadata the proto annotations don't carry.

    The plugin emits a bare `info` (package title + service comment); we add
    title/version/contact/license, the local-daemon server URL, and a link back
    to the explorer — same effect as gnostic's (document) option without a
    gnostic dependency leaking into the generated SDKs.
    """
    for spec in OUT.glob("micropod/v1/*.openapi.json"):
        doc = json.loads(spec.read_text())
        info = doc.setdefault("info", {})
        info["title"] = "Micropod API" if spec.stem == "api.openapi" else \
            f"micropod.v1 — {spec.stem.removesuffix('.openapi')} types"
        if version:
            info["version"] = version
        info["contact"] = {"name": "Micropod",
                           "url": "https://github.com/castlemilk/micropod"}
        info["license"] = {"name": "Apache-2.0",
                           "url": "https://github.com/castlemilk/micropod/blob/master/LICENSE"}
        doc["servers"] = [{"url": "http://localhost:45454",
                           "description": "Local Micropod daemon"}]
        doc["externalDocs"] = {
            "description": "API explorer",
            "url": "https://castlemilk.github.io/micropod/api/"}
        spec.write_text(json.dumps(doc, indent=2) + "\n")


def main():
    OUT.mkdir(parents=True, exist_ok=True)

    # 1. Protobuf-derived artifacts (openapi.json + proto-reference.html).
    buf = subprocess.run(
        ["buf", "generate", "--template", "buf.gen.docs.yaml"],
        cwd=ROOT, capture_output=True, text=True)
    if buf.returncode != 0:
        print(buf.stderr, file=sys.stderr)
        sys.exit("buf generate failed")
    print("openapi + proto-reference regenerated")

    enrich_openapi(git_version())

    # 2. REST routes extracted from the handler's route table.
    routes = extract_rest_routes()
    (OUT / "rest-routes.json").write_text(json.dumps(routes, indent=2) + "\n")
    print(f"rest-routes.json: {len(routes)} routes")

    # 3. MCP tool manifest from the live binary.
    dump_mcp_tools()


if __name__ == "__main__":
    main()
