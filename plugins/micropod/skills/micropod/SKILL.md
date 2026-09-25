---
name: micropod
description: Use the Micropod container manager — the Apple `container` runtime via its MCP server (32 tools), Connect/REST API on :45454, or Docker Engine API shim. Use for running/managing containers and docker-compose stacks, worker orchestration (e.g. cuttlefish), and disposable test containers (real Testcontainers/Ryuk via the shim).
---

# Micropod

Micropod is a macOS desktop manager + API surface for Apple's `container`
runtime (the OCI engine from github.com/apple/container — **not** Docker).
Programmatic surfaces, best first:

| Surface | How to reach it | When to use |
|---|---|---|
| **MCP server** (STDIO JSON-RPC 2.0, 32 tools) | `micropod-mcp` (installed to `~/.local/bin/`) | Claude/agent-driven work; the richest surface |
| **Connect API** (proto-JSON over POST) | `http://127.0.0.1:45454/api/micropod.v1.<Service>/<Method>` | Typed clients — TS/Go/Swift SDKs, or curl |
| **REST facade** (JSON) | `http://127.0.0.1:45454/v1/*` | Quick curl/scripts; SSE logs |
| **Docker Engine shim** | unix `~/.micropod/docker.sock` + tcp `:45455` | Unmodified Docker clients: docker-py, Testcontainers, Ryuk |
| **CLI** | `micropod` (installed to `~/.local/bin/`) | Interactive shell use |

Prerequisite: Micropod.app installed and running (it owns the daemon, the
:45454 API, and the shim). `curl -s http://127.0.0.1:45454/health` →
`{"status":"ok"}` is the readiness probe.

## MCP server (32 tools)

Config for any MCP client:

```json
{
  "mcpServers": {
    "micropod": { "command": "micropod-mcp" }
  }
}
```

(If `micropod-mcp` isn't on the client's PATH, use the absolute path
`$HOME/.local/bin/micropod-mcp`.)

Tools — **containers**: `list_containers`, `run`, `start`, `stop`,
`restart`, `kill`, `delete`, `inspect`, `exec`, `logs`, `stats`.
**images**: `list_images`, `pull`, `push`. **volumes**: `list_volumes`,
`volume_policy`, `volume_policy_set`. **networks**: `list_networks`.
**compose**: `compose_up` (path + optional profiles), `compose_down`,
`compose_ps`. **shared mounts**: `share_mount`, `share_unmount`,
`share_list`, `share_sync`, `share_gc`. **system**: `status`, `df`,
`build_cache_stats`, `update_check`, `update_status`, `update_apply`.

Example tools/call (JSON-RPC over stdin/stdout):

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"compose_up","arguments":{"path":"/abs/path/docker-compose.yml"}}}
```

## Connect API — the typed contract

The daemon's public API is `micropod.v1` over Connect (Connect/gRPC/gRPC-Web
on the same port), grouped one service per domain:

```
/api/micropod.v1.ContainerService/{ListContainers,RunContainer,CreateContainer,
  StartContainer,StopContainer,RestartContainer,KillContainer,DeleteContainer,
  StreamContainerLogs,GetStats,Exec}
/api/micropod.v1.ImageService/{ListImages,PullImage,DeleteImage}
/api/micropod.v1.VolumeService/{ListVolumes,CreateVolume,DeleteVolume,
  GetVolumePolicy,SetVolumePolicy}
/api/micropod.v1.NetworkService/{ListNetworks,CreateNetwork,DeleteNetwork}
/api/micropod.v1.ComposeService/{ComposeUp,ComposeDown}
/api/micropod.v1.SystemService/{GetSystem,GetUsage,CheckForUpdates,
  GetUpdateStatus,ApplyUpdate}
```

Unary calls are plain POST + JSON — no client library needed:

```bash
curl -s -X POST http://127.0.0.1:45454/api/micropod.v1.ContainerService/ListContainers \
  -H 'Content-Type: application/json' -d '{}'
```

Streaming RPCs (`PullImage`, `StreamContainerLogs`, `ComposeUp`) use Connect
envelope framing — use `Content-Type: application/connect+json` or an SDK.
`buf.validate` constraints are enforced server-side (`invalid_argument` on
bad input, e.g. empty required strings). Errors are Connect envelopes:
`{"code":"...","message":"..."}`.

The old monolithic prefix `/api/micropod.v1.MicropodService/<Method>` is a
kept alias — older SDKs keep working.

Interactive explorer + per-RPC samples in every language:
https://castlemilk.github.io/micropod/api/

### SDKs (recommended over raw HTTP)

TypeScript: `npm i @micropod/sdk` — `createMicropodClient(url)` returns one
flat client over all six services, with retry/timeout/OTel interceptors and
client-side protovalidate (`validate: false` opts out):

```ts
import { createMicropodClient } from "@micropod/sdk";
const client = createMicropodClient("http://localhost:45454");
const res = await client.listContainers({});
const ref  = await client.runContainer({ image: "alpine:3.20", name: "demo" });
```

Go: `github.com/castlemilk/micropod/sdk/go` — `micropod.NewClient` embeds all
six generated connect-go clients (methods promote flat):

```go
client := micropod.NewClient("http://127.0.0.1:45454",
    micropod.WithRetry(micropod.DefaultRetryPolicy()), micropod.WithOTel())
resp, err := client.ListContainers(ctx, connect.NewRequest(&micropodv1.Empty{}))
```

Swift: `MicropodSDK` SwiftPM package — `MicropodClient(baseURL:)` facade:

```swift
let client = MicropodClient(baseURL: URL(string: "http://localhost:45454")!)
let ref = try await client.run(.with { $0.image = "alpine:3.20" })
```

## REST facade (`/v1/*` — curl-friendly compat)

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
GET  /v1/volumes/policy | PUT same        mount policy (clone/sync/cache)
GET  /v1/networks | POST /v1/networks {"name","subnet","internal"} | DELETE /v1/networks/{name}
GET  /v1/stats | GET /v1/usage
POST /v1/compose/up {"path","profiles"} | POST /v1/compose/down {"name"}
POST /v1/exec {"id","command","workdir"}
GET  /v1/system/update | POST /v1/system/update | POST /v1/system/update/apply
```

## Docker Engine shim (Testcontainers drop-in)

The app supervises `micropod-docker-shim` (`Sources/MicropodDockerShim`): a
Docker Engine HTTP API on unix `~/.micropod/docker.sock` AND tcp `:45455`
(all interfaces, so in-VM containers reach it at the bridge
`192.168.64.1:45455`).

Point any Docker client at it:

```bash
curl --unix-socket ~/.micropod/docker.sock http://localhost/_ping
DOCKER_HOST=unix://$HOME/.micropod/docker.sock python my_testcontainers_suite.py
```

Surface: `_ping`/`version`/`info`/`auth`/`events`, images (pull NDJSON
progress/list/inspect/tag/delete/prune), containers (list+filters/create/
inspect/start/stop/kill/rm/wait/logs stdcopy/stats/archive put+get/prune),
exec (create + 101-upgrade hijack with stdcopy framing / detach / inspect),
networks + volumes CRUD. Speaks real Docker protocol details: versioned
client paths (`/v1.24/…` stripped), keep-alive + pipelined-response
ordering, chunked request bodies, `Expect: 100-continue`, dockerd-style
rejection of unknown list filters, 409 on name conflicts, case-insensitive
`force=True` flags.

**Ryuk interception**: creating an image whose name contains
`testcontainers/ryuk` strips docker.sock bind mounts, injects
`DOCKER_HOST=tcp://192.168.64.1:<port>`, and publishes 8080/tcp. A real ryuk
container then reaps labeled resources through the shim (validated with
testcontainers-python + `PostgresContainer("postgres:16-alpine")`: SQL
roundtrip, session-disconnect reap, zero leftovers, repeated runs).

State: created-container memory (names/labels/env/ports/AutoRemove) persists
to `~/.micropod/shim-state.json`, reloaded + pruned on restart; stopped
AutoRemove containers left while down are reaped at boot. Env overrides:
`MICROPOD_SHIM_SOCKET`, `MICROPOD_SHIM_TCP_PORT` (45455),
`MICROPOD_SHIM_BRIDGE` (192.168.64.1), `MICROPOD_SHIM_STATE`,
`MICROPOD_CLI_PATH`. Full env (incl. `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`)
passes through to pulls.

Shim reports ApiVersion 1.44 / serverVersion 27.3.1 / Os linux.

Known gap: docker API `HostConfig.Memory` is honored (`--memory`), CPU
limits (`NanoCpus`) are NOT mapped — set cpus via the Connect/MCP `cpus`
field or `container run --cpus` directly until wired.

## Synchronized file shares

Every bind mount is VirtioFS already — Micropod adds the **synchronized**
layer on top: host directory → content-addressed chunk store
(SHA256/256 KiB) + APFS `clonefile` per-container views (isolated writes,
shared blocks, cheap CoW). The shim auto-rewrites directory `Binds` through
the daemon when `micropod-sharedfs` is running; otherwise falls back to
plain virtiofs.

- Explicit management: `share_mount`/`share_list`/`share_sync`/
  `share_unmount`/`share_gc` MCP tools, or `micropod share <verb>` CLI.
- **Live writes**: views and sources are watched with file-level FSEvents —
  host edits propagate to live views, container writes go to the host then
  sibling views, hash-checked to avoid loops. `share_mount --shared` gives
  all containers one view (true shared writes); default per-container views
  isolate until `sync`.

### Intelligent shared cache

Content-addressed chunk store + GCS fallback for package-manager caches:
`~/.npm` tarballs, `/go/pkg/mod`, `/root/.cache/go-build`, `~/.cache/pip`.
Keyed by lockfile hash + toolchain version — same lockfile shares chunks
across repos. Auto-mounted on well-known container paths; `shared: true`
and `sharedMounts` cachePolicy override. Global LRU cap via
`RUNNER_CACHE_MAX_BYTES` (default 10 GB).

## Running at scale

Measured facts to plan around (M-series, Apple runtime 1.2.2):

- **Per-container cost**: default config is 4 CPUs / 1 GiB. An idle alpine
  VM uses ~4–5 MB *guest* memory, but each container is its own
  Virtualization.framework XPC process at ~330 MB *host* RSS — budget
  ~300 MB × parallel containers of host RAM.
- **Throughput**: boot ≈ 0.9–1.0 s each and partially serialized — 10
  concurrent lifecycles ≈ 1.4 s/container wall-clock. Boots are CPU-bound;
  size fleets to physical cores ÷ 2.
- **Ports**: unpinned host ports get OS-ephemeral allocation at create —
  prefer explicit port ranges per suite for large fleets.
- **Disk hygiene**: pull with `--platform linux/arm64` — all-variant pulls
  cost ~9×. Snapshots live under
  `~/Library/Application Support/com.apple.container/`; a full host disk
  degrades the runtime catastrophically.
- **Cleanup**: ryuk covers testcontainers sessions (pre-pull
  `testcontainers/ryuk:0.8.1`). Otherwise `HostConfig.AutoRemove` or
  run-scoped labels + filtered DELETE sweeps.
- **Event granularity**: shim events are a 500 ms poll-diff — never assert
  tighter timing; sub-500 ms containers compress into a create+die pair.
- **Readiness** (cached images): alpine ~1 s; postgres:16-alpine SQL-ready
  in ~7–20 s via testcontainers.
- **Surface choice**: shim for unmodified docker tooling; Connect for typed
  clients/streaming; `/v1/*` for quick curl; MCP for agents. All share the
  same runtime and can run concurrently.

## Recipes

### 1. Worker orchestration (cuttlefish-style)

Spawn a worker per job, label it, watch logs, clean up. Unique names per
job keep it concurrency-safe:

```bash
# spawn (MCP)
tools/call run  {"image":"ghcr.io/.../worker:latest","name":"cf-worker-<jobid>","labels":{"com.cuttlefish.job":"<jobid>"},"env":["JOB_ID=<jobid>"],"init":true,"arguments":["--job","<jobid>"]}
# watch logs (HTTP SSE)
curl -N http://127.0.0.1:45454/v1/containers/cf-worker-<jobid>/logs?tail=100
# cleanup
DELETE /v1/containers/cf-worker-<jobid>?force=true   (or MCP delete)
```

A Ryuk-style reaper can poll `GET /v1/containers` and force-delete
containers labelled ephemeral (job label + TTL). Micro-VM isolation is the
feature here: a misbehaving worker can't take out siblings, idle workers
cost ~330 MB host RSS, `stop` is a fast VM kill (~180 ms). Cap resources at
create (`cpus`/`memory`) since docker-API CPU limits aren't mapped yet.

### 2. Testcontainers / disposable test DBs (via the shim)

```bash
DOCKER_HOST=unix://$HOME/.micropod/docker.sock pytest tests/
```

```python
from testcontainers.postgres import PostgresContainer
with PostgresContainer("postgres:16-alpine") as pg:   # ready in ~7–20 s
    psycopg2.connect(pg.get_connection_url().replace("postgresql+psycopg2://", "postgresql://"))
```

Pre-pull the pinned ryuk image once (`testcontainers/ryuk:0.8.1`).
testcontainers-python returns a SQLAlchemy-dialect URL — strip `+psycopg2`
for plain psycopg2. pytest-xdist workers each get their own ryuk session
label; concurrency ceiling is boot serialization (~1.4 s/container at
10-way) — size workers to cores ÷ 2 and pre-pull the image matrix.

Without the shim: `POST /v1/containers` → poll exec probe (`pg_isready`) →
connect on published port → `DELETE ?force=true` in teardown.

### 3. Compose on the Apple runtime

`compose_up`/`ComposeUp` translate docker-compose.yml (networks, volumes,
dependency-ordered starts, `service_healthy` readiness, profiles,
pull-if-missing). Differences vs Docker: no native restart policies
(compose `restart:` only applies when driven through the shim's
supervisor); runtime `stop` burns the full grace — the shim's fast stop
avoids it for docker-API clients. Cached images make compose ready fast
(postgres:16 stack ~3–5 s).

## Notes / gotchas

- `container copy` from tmpfs-mounted paths hangs on runtime 1.2.2 — use
  bind mounts or plain containers for copy.
- Network names must be lowercase.
- `container stats` is slow (~2.4 s) — don't call it in hot loops.
- Container `start` costs ~0.9–1.0 s and that is the FLOOR: each container
  is its own micro-VM. Where the model wins instead: stop 183 ms vs 2345 ms,
  create 80 vs 354 ms, warm exec 77 vs 96 ms, whole lifecycle 1.4 s vs 3.4 s.
- The runtime does NOT report exit codes for stopped containers — the shim
  assumes 0 unless an event captured one.
- SIGTERM is UNDELIVERABLE on runtime 1.2.2 — `kill --signal TERM` is a
  silent no-op and PID 1's signals are shielded. Graceful stop is
  impossible; `stop` executes as instant-stop regardless of grace values.
- `exec` on a stopped container errors immediately; the runtime emits no
  events — the shim synthesizes create/start/die/destroy by 500 ms
  list-polling.
- The runtime's `kill` accepts `--signal`; only KILL has any effect.
- The shim is unauthenticated (dev tool): tcp :45455 binds all interfaces.
- Images are content-addressed per-variant; the shim derives Docker-style
  `sha256:` IDs deterministically.
