---
name: micropod
description: Use the Micropod container manager — the Apple `container` runtime via its MCP server, HTTP API, or connect-go API. Use for running/managing containers and docker-compose stacks, worker orchestration (e.g. cuttlefish), and disposable test containers (testcontainers/Ryuk-style).
---

# Micropod

Micropod is a macOS desktop manager + API surface for Apple's `container`
runtime (the OCI engine from github.com/apple/container — **not** Docker).
Three programmatic surfaces exist:

| Surface | How to run | When to use |
|---|---|---|
| **MCP server** (STDIO JSON-RPC 2.0, 21 tools) | `task mcp` or `dist/micropod-mcp` | Claude/agent-driven work; the richest surface |
| **HTTP API** (Swift, JSON) | `task api` → http://127.0.0.1:45454 | curl/scripts; SSE logs, compose up/down |
| **connect-go API** (Go, protobuf) | `task api-go` → http://127.0.0.1:45454 | Go programs (cuttlefish, tests); gRPC/Connect/gRPC-Web |

CLI override: set `MICROPOD_CONTAINER_CLI_PATH` (default `/usr/local/bin/container`)
so all three surfaces can be pointed at a mock (`Tests/MicropodIntegrationTests/Support/mock-container`)
for tests without a real runtime.

## MCP server

Register in Claude Code (project `.mcp.json` or user config):

```json
{
  "mcpServers": {
    "micropod": { "command": "/Users/benebsworth/projects/micropod/dist/micropod-mcp" }
  }
}
```

Tools: `status`, `list_containers`, `start`, `stop`, `restart`, `kill`,
`delete`, `run`, `exec`, `logs`, `stats`, `inspect`, `list_images`,
`list_volumes`, `list_networks`, `pull`, `push`, `df`,
`compose_up` (path + optional profiles), `compose_down`, `compose_ps`.

Example tools/call (JSON-RPC over stdin/stdout):
```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"compose_up","arguments":{"path":"/abs/path/docker-compose.yml"}}}
```

## HTTP API (curl)

```
GET  /health
GET  /v1/system                          runtime status + disk usage
GET  /v1/containers                      list containers
POST /v1/containers                      run {"image","name","env","ports","volumes","labels",...}
POST /v1/containers/create               create without starting
POST /v1/containers/{id}/start|stop|restart|kill
DELETE /v1/containers/{id}?force=true
GET  /v1/containers/{id}/logs?tail=N     SSE stream (text/event-stream)
GET  /v1/images | POST /v1/images/pull {"reference"} | DELETE /v1/images/{ref}
GET  /v1/volumes | POST /v1/volumes {"name","size"} | DELETE /v1/volumes/{name}
GET  /v1/networks | POST /v1/networks {"name","subnet","internal"} | DELETE /v1/networks/{name}
GET  /v1/stats
POST /v1/compose/up {"path","profiles"} | POST /v1/compose/down {"name"}
POST /v1/exec {"id","command","workdir"}
```

Example: `curl -s -X POST -d '{"image":"postgres:16","name":"pg"}' http://127.0.0.1:45454/v1/containers`

## connect-go API (Go)

Generated bindings in `api/gen/micropod/v1` + `micropodv1connect`. The server
(`task api-go`) implements `MicropodService`; a ready-made client CLI is
`api/cmd/micropod-ctl` (`micropod-ctl list-containers`, `run`, `pull`, `stats`).

```go
import (
    micropodv1 "micropod/api/gen/micropod/v1"
    "micropod/api/gen/micropod/v1/micropodv1connect"
)
client := micropodv1connect.NewMicropodServiceClient(http.DefaultClient, "http://127.0.0.1:45454")
res, err := client.ListContainers(ctx, connect.NewRequest(&micropodv1.Empty{}))
```

## Recipes

### 1. Cuttlefish worker orchestration

Spawn a worker container per job, label it for the job, watch its logs live,
and clean it up when the job ends. Concurrency-safe: unique names per job.

```bash
# spawn (MCP)
tools/call run  {"image":"ghcr.io/.../worker:latest","name":"cf-worker-<jobid>","labels":{"com.cuttlefish.job":"<jobid>"},"env":["JOB_ID=<jobid>"],"init":true,"arguments":["--job","<jobid>"]}
# watch logs (HTTP SSE)
curl -N http://127.0.0.1:45454/v1/containers/cf-worker-<jobid>/logs?tail=100
# status
tools/call list_containers   →  grep the job label
# cleanup
DELETE /v1/containers/cf-worker-<jobid>?force=true   (or MCP delete)
```

A Ryuk-style reaper can poll `GET /v1/containers` every N seconds and force-
delete containers whose labels mark them ephemeral (e.g. `com.cuttlefish.job`
set + a TTL label) — mirroring how Ryuk reaps test containers in Docker.

### 2. Testcontainers / disposable test DBs (Ryuk-style)

For tests needing a real postgres/redis:

1. **Start**: `POST /v1/containers` with a unique name
   (`pg-test-<uuid>`), `memory`/`env` as needed.
2. **Wait for readiness**: poll `POST /v1/exec {"id":<name>,"command":"<pg_isready path or probe>"}`
   until exit 0, or use a compose stack via `POST /v1/compose/up` (Micropod's
   compose runs real healthcheck readiness probes before reporting up).
3. **Use**: connect on the published port (compose `ports` or `--publish`).
4. **Guaranteed cleanup**: `DELETE /v1/containers/<name>?force=true` in a
   `defer`/teardown; a testcontainers-style reaper loop deletes any container
   whose label `com.micropod.ephemeral` is set after TTL.

Readiness probe for the official postgres image (root exec):
`/usr/lib/postgresql/16/bin/pg_isready -U postgres`.

### 3. Compose on the Apple runtime

Micropod translates docker-compose.yml (networks, volumes, dependency-ordered
starts, `service_healthy` readiness, profiles, pull-if-missing). Notable
differences vs Docker: no native restart policies; `container stop` burns the
full grace; pull-if-missing means cached images start fast (postgres:16
compose ready in ~3–5 s on this box).

## Notes / gotchas

- `container copy` from tmpfs-mounted paths hangs on the Apple runtime v1.2.2
  (use bind mounts or plain containers for copy).
- Network names must be lowercase.
- `container stats` is slow (~2.4 s) — don't call it in hot loops.
- The runtime footprint lives in `~/Library/Application Support/com.apple.container/`
  (snapshots dominate); the Storage tab shows real per-bucket sizes + prunes.
