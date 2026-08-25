---
name: micropod
description: Use the Micropod container manager — the Apple `container` runtime via its MCP server, HTTP API, connect-go API, or Docker Engine API shim. Use for running/managing containers and docker-compose stacks, worker orchestration (e.g. cuttlefish), and disposable test containers (real Testcontainers/Ryuk via the shim).
---

# Micropod

Micropod is a macOS desktop manager + API surface for Apple's `container`
runtime (the OCI engine from github.com/apple/container — **not** Docker).
Four programmatic surfaces exist:

| Surface | How to run | When to use |
|---|---|---|
| **MCP server** (STDIO JSON-RPC 2.0, 21 tools) | `task mcp` or `dist/micropod-mcp` | Claude/agent-driven work; the richest surface |
| **HTTP API** (Swift, JSON) | `task api` → http://127.0.0.1:45454 | curl/scripts; SSE logs, compose up/down |
| **connect-go API** (Go, protobuf) | `task api-go` → http://127.0.0.1:45454 | Go programs (cuttlefish, tests); gRPC/Connect/gRPC-Web |
| **Docker Engine shim** (Swift) | `task shim` → unix `~/.micropod/docker.sock` + tcp :45455 | Unmodified Docker clients: docker-py, Testcontainers, Ryuk |

CLI override: set `MICROPOD_CONTAINER_CLI_PATH` (default `/usr/local/bin/container`)
so all surfaces can be pointed at a mock (`Tests/MicropodIntegrationTests/Support/mock-container`)
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

## Docker Engine shim (Testcontainers drop-in)

`task shim` runs `micropod-docker-shim` (`Sources/MicropodDockerShim`): a
Docker Engine HTTP API backed by MicropodCore, listening on unix socket
`~/.micropod/docker.sock` AND tcp `:45455` (all interfaces, so in-VM
containers reach it at the bridge `192.168.64.1:45455`).

Point any Docker client at it:

```bash
curl --unix-socket ~/.micropod/docker.sock http://localhost/_ping
DOCKER_HOST=unix://$HOME/.micropod/docker.sock python my_testcontainers_suite.py
```

Surface: `_ping`/`version`/`info`/`auth`/`events`, images
(pull NDJSON progress/list/inspect/tag/delete/prune), containers
(list+filters/create/inspect/start/stop/kill/rm/wait/logs stdcopy/stats/
archive put+get/prune), exec (create + 101-upgrade hijack with stdcopy
framing / detach / inspect), networks + volumes CRUD. Speaks real Docker
protocol details: versioned client paths (`/v1.24/…` stripped), keep-alive +
pipelined-response ordering, chunked request bodies, `Expect: 100-continue`,
dockerd-style rejection of unknown list filters, 409 on name conflicts,
case-insensitive `force=True` flags.

**Ryuk interception**: creating an image whose name contains
`testcontainers/ryuk` strips docker.sock bind mounts, injects
`DOCKER_HOST=tcp://192.168.64.1:<port>`, and publishes 8080/tcp. A real ryuk
container then reaps labeled resources through the shim (validated with
testcontainers-python + `PostgresContainer("postgres:16-alpine")`: SQL
roundtrip, session-disconnect reap, zero leftovers, repeated runs).

State: created-container memory (names/labels/env/ports/AutoRemove) persists
to `~/.micropod/shim-state.json`, reloaded + pruned on restart; stopped
AutoRemove containers left while down are reaped at boot. Env overrides:
`MICROPOD_SHIM_SOCKET`, `MICROPOD_SHIM_TCP_PORT` (45455), `MICROPOD_SHIM_BRIDGE`
(192.168.64.1), `MICROPOD_SHIM_STATE`, `MICROPOD_CLI_PATH`. Full env
(incl. `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`) passes through to pulls.

Tests: `swift test --filter MicropodDockerShimTests` (57, in-process against
mock CLI incl. hijack framing + parser edge cases); `task e2e-real` runs
`RealShimTests` (real runtime + real ryuk reap; gate `MICROPOD_REAL_E2E=1`).
Shim reports ApiVersion 1.44 / serverVersion 27.3.1 / Os linux.

Known gap: docker API `HostConfig.Memory` is honored (`--memory`), CPU limits
(`NanoCpus`) are NOT mapped — set cpus via the HTTP/MCP `cpus` field or
`container run --cpus` directly until wired.

## Synchronized file shares (no subscription)

Docker Desktop gates this behind Pro. Apple runtime already gives you
**virtual file shares** — every bind mount is VirtioFS, near-native speed.
Micropod adds the **synchronized** layer that Docker charges for:

- **What it does**: host directory → content-addressed chunk store (SHA256 /
  256 KiB) + APFS `clonefile` per-container views (isolated writes, shared
  blocks, cheap CoW). The shim auto-rewrites directory `Binds` through the
  daemon when `micropod-sharedfs` is running; otherwise falls back to plain
  virtiofs.
- **Run it**: `task share-daemon` or `micropod share daemon` (socket at
  `~/micropod/share-cache/socket`, cache at `~/micropod/share-cache/`).
  Then any `micropod run -v ~/proj:/app` or shim `HostConfig.Binds` bind
  whose host path is a directory is served from a cloned view.
  Explicit management: `micropod share mount <src>`, `list`, `inspect <id>`,
  `sync <id>` (flush view writes back to src), `unmount <id>`, `gc`.
- **Live updates**: `FSEvents` watches the source; out-of-date views can
  be refreshed via `micropod share sync` or re-cloned via `refresh`. Shim
  views are synced on `unmount` (container delete) automatically.
- **Trade-off vs Docker Pro**: views are per-container isolated — two
  containers mounting the same host dir do NOT see each other's live writes
  without an overlay mount (would need root). Host→container propagation is
  near-live (FSEvents), container→host is on `sync`/delete. This covers
  PHP/JS-style trees where `node_modules` churn per container is the pain
  point — the dedup win, not the cross-container live-write case which
  would require a root overlay mount.

## Running at scale

Measured facts to plan around (M-series, Apple runtime 1.2.2):

- **Per-container cost**: default config is 4 CPUs / 1 GiB (guest sees
  `memoryLimitBytes` 1 GiB). An idle alpine VM uses ~4–5 MB *guest* memory /
  1 process, but each container is its own Virtualization.framework XPC
  process at ~330 MB *host* RSS (incl. shared framework pages) — budget
  ~300 MB × parallel containers of host RAM, with dedupe improving that
  somewhat. Right-size real workloads with `HostConfig.Memory`.
- **Throughput**: boot ≈ 0.9–1.0 s each and partially serialized — 10
  concurrent full lifecycles ≈ 1.4 s/container wall-clock. Boots are
  CPU-bound and degrade with machine load (an ML eval at ~200% CPU spiked
  starts to 2.7 s+). Start sizing for CI fleets: physical cores ÷ 2 as a
  sane concurrency default.
- **Ports**: unpinned host ports get OS-ephemeral allocation at create time.
  For large fleets prefer explicit port ranges per suite to avoid collisions
  with other host services.
- **Disk hygiene** (this bit hard once): pull with
  `--platform linux/arm64` — all-variant pulls cost ~9x (three test images
  ate 27 GB before pinning). Watch `container system df`, prune images
  (`container image delete --all` wipes everything — re-pull pinned), and
  remember snapshots live under
  `~/Library/Application Support/com.apple.container/`. A full host disk
  degrades the runtime catastrophically (multi-second starts, silent rm
  failures) well before Docker Desktop's fixed-size disk file notices.
- **Cleanup**: testcontainers/ryuk covers its own sessions (per session-id
  label; pre-pull `testcontainers/ryuk:0.8.1`, the pinned version). For
  non-testcontainers fleets use `HostConfig.AutoRemove` (shim reaps on die
  and re-reaps stopped AutoRemove containers missed while it was down) or
  run-scoped labels + filtered DELETE sweeps. `shim-state.json` self-prunes
  against the live runtime on shim boot.
- **Event granularity**: shim events are a 500 ms poll-diff — sub-500 ms
  containers compress into one synthetic create+die pair, exit codes default
  to 0. Never assert tighter than 500 ms on event timing.
- **Readiness reality** (cached images): alpine-class ~1 s to running;
  postgres:16-alpine ready for SQL in ~7–20 s through testcontainers (wait
  strategy included). First-ever pulls are network-bound and slow.
- **Surface choice at scale**: shim for unmodified docker tooling;
  connect-go for Go services (no docker-shape translation, streaming);
  HTTP API for scripts; MCP for agents. All surfaces can run concurrently
  against the same runtime — they share one `container` CLI and its apiserver.

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
At scale the micro-VM model is a feature here: per-worker kernel isolation
means a misbehaving job can't take out siblings or the host, idle workers
cost ~4 MB guest memory (~330 MB host RSS each), and worker `stop` is a fast
VM kill (~180 ms) with no TERM-handling hangs. Cap per-worker resources at
create (`cpus`/`memory` fields) since docker-API CPU limits aren't mapped
through the shim yet.

### 2. Testcontainers / disposable test DBs (REAL, via the shim)

Start the shim once, then run unmodified testcontainers suites:

```bash
cd ~/projects/micropod && task shim &        # unix ~/.micropod/docker.sock + tcp :45455
# any python test:
DOCKER_HOST=unix://$HOME/.micropod/docker.sock pytest tests/
```

```python
from testcontainers.postgres import PostgresContainer
with PostgresContainer("postgres:16-alpine") as pg:   # READY in ~7-20s, real ryuk cleanup
    psycopg2.connect(pg.get_connection_url().replace("postgresql+psycopg2://", "postgresql://"))
```

Pre-pull the images once (testcontainers' ryuk pin is `testcontainers/ryuk:0.8.1`):

```bash
curl -X POST --unix-socket ~/.micropod/docker.sock \
  'http://localhost/images/create?fromImage=testcontainers/ryuk:0.8.1'
```

Notes: testcontainers-python's deprecated `testcontainers.postgres` module
returns a SQLAlchemy-dialect URL (`postgresql+psycopg2://…`) — strip the
`+psycopg2` for plain psycopg2.

Parallel fleets: each pytest-xdist worker gets its own ryuk session label
automatically, so reaping stays scoped per worker. Concurrency ceiling is
boot serialization (~1.4 s/container at 10-way) — size workers to
cores ÷ 2 and pre-pull the full image matrix once in CI before fanning out.
Without the shim, the manual fallback works: `POST /v1/containers` → poll
exec probe (`pg_isready`) → connect on published port → `DELETE ?force=true`
in teardown.

### 3. Compose on the Apple runtime

Micropod translates docker-compose.yml (networks, volumes, dependency-ordered
starts, `service_healthy` readiness, profiles, pull-if-missing). Notable
differences vs Docker: no native restart policies (compose `restart:` only
works via the shim's supervisor when the stack is driven through the docker
API); the runtime's own `stop` burns the full grace (the shim's fast stop
avoids it for docker-API clients). Pull-if-missing means cached images start
fast (postgres:16 compose ready in ~3–5 s on this box).

## Notes / gotchas

- `container copy` from tmpfs-mounted paths hangs on the Apple runtime v1.2.2
  (use bind mounts or plain containers for copy).
- Network names must be lowercase.
- `container stats` is slow (~2.4 s) — don't call it in hot loops.
- The runtime footprint lives in `~/Library/Application Support/com.apple.container/`
  (snapshots dominate); the Storage tab shows real per-bucket sizes + prunes.
- Container `start` costs ~0.9–1.0s and that is the FLOOR: each container
  is its own micro-VM (VM create + kernel boot + DHCP lease + virtiofs
  rootfs attach + init). Docker Desktop's ~0.2s start is a process spawn in
  ONE warm shared Linux VM — faster start, weaker isolation. Don't chase
  start latency in the shim (single CLI call, ≈15ms overhead); the micro-VM
  fixed boot cost is the isolation price. Where the model wins instead:
  stop 183ms vs 2345ms, create 80 vs 354ms, warm exec 77 vs 96ms, whole
  lifecycle 1.4s vs 3.4s. Image size doesn't affect start (CoW snapshot
  mount). Measure interleaved A/B — the machine's background load (ML evals,
  headroom proxy) can spike Apple's CPU-bound VM boot to 2.7s+ transiently.
- The runtime does NOT report exit codes for stopped containers (neither
  `container list` nor `inspect`) — the shim assumes 0 unless an event
  captured one. Don't build exit-code assertions on `container` CLI output.
- SIGTERM is UNDELIVERABLE on runtime 1.2.2: `container kill --signal TERM`
  is a silent no-op, and PID 1's signals are shielded even from
  `exec kill -TERM 1` inside the container. Graceful stop is impossible;
  the shim executes `stop` as the runtime's atomic instant-stop (~180ms)
  regardless of the requested grace — docker `-t` values are accepted but
  ignored. `container stop --time N` otherwise burns the full N seconds
  unconditionally (state stays "running" and list/exec serialize behind it).
- `container exec` on a stopped container errors immediately ("is not
  running"), and the runtime emits no events — the shim synthesizes
  create/start/die/destroy by 500 ms list-polling (quiescent when idle).
- The runtime's `kill` accepts `--signal` (default KILL); only KILL has any
  effect. The shim also supervises docker restart policies (always /
  unless-stopped / on-failure + MaximumRetryCount, exponential backoff)
  because the runtime has none.
- Shim internals worth knowing: `NWListener` cannot listen on unix sockets
  (EINVAL) — the unix path uses a raw BSD socket accept loop; exec children
  are killed on client disconnect; ryuk's Go client uses filter key `"labels"`
  (plural) and versioned paths — both were shim bugs found the hard way
  (ryuk once deleted every container when an unknown filter key was treated
  as match-all; unknown filters are now rejected like dockerd).
- The shim is unauthenticated (dev tool): tcp :45455 binds all interfaces.
- Images are content-addressed per-variant by the runtime; the shim derives
  Docker-style `sha256:` IDs deterministically (stable within a run).
