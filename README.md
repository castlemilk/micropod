# Micropod

A native macOS desktop manager for Apple's `container` runtime (the OCI
container engine from [github.com/apple/container](https://github.com/apple/container)).
Built with SwiftUI + Swift 6, data models in protobuf, and an MCP server for
agent-driven container management.

## What it does

- **Containers** — list/start/stop/kill/delete/prune, live logs, stats
  (CPU/mem/net, 5 s sampling), file explorer (copy in/out), config + inspect
  JSON, and an interactive PTY terminal (`container exec -it`) with real job
  control via a C shim (`setsid` + `TIOCSCTTY`).
- **Images** — pull/push with live BuildKit progress, verbose list (per-variant
  size/platform), tag, save/load, delete/prune, Dockerfile **builds**
  (multi-stage, build args, platform, cache mounts).
- **Volumes & Networks** — create (incl. sized volumes), delete, prune,
  inspect.
- **Compose** — import a `docker-compose.yml`, preview the translated plan,
  then up/down. `container` has no native compose; Micropod translates it:
  networks, named volumes, builds, dependency-ordered starts, and real
  healthcheck-based readiness probes. Save environments for one-click up/down.
- **Registry** — login/logout/list creds.
- **Menu bar** — running-container count, quick stop-all/start-runtime, and a
  dashboard glance.
- **MCP server** — STDIO JSON-RPC 2.0 (`tools/call`: status, list_containers,
  start/stop/kill/delete, run, pull/push, inspect, logs, df, compose_up).

## Architecture

```
proto/micropod/v1/        protobuf models (curated views + compose spec)
Sources/MicropodCore/     CLI client, DTOs, model mapper, services (actors)
Sources/MicropodApp/      SwiftUI app (store + views)
Sources/MicropodMCP/      MCP STDIO server
Sources/MicropodSharedFS/ incremental host-dir -> block-volume sync
Sources/CPtyShim/         C PTY shim for interactive terminals
Tests/MicropodCoreTests/  JSON fixture decoding, progress parsing, compose plan
Tests/MicropodIntegrationTests/  end-to-end tests against a mock `container` CLI
scripts/mock-container    stateful mock of the Apple `container` CLI
```

- All CLI interaction is typed `ContainerCommand` invocations against
  `/usr/local/bin/container` (override with `MICROPOD_CONTAINER_CLI_PATH`);
  short commands run to completion (temp-file capture — no pipe deadlock),
  long-lived ones stream through pipes.
- Proto models are the single source of truth shared by the app and the MCP
  server (`swiftprotoc`, `Visibility=public`).

## Build & test

```sh
task           # debug build (regenerates protos)
task test      # unit tests
task lint      # swift-format lint
task package   # dist/Micropod.app + micropod-mcp
task validate  # full deep validation (below)
task e2e-real  # real-runtime e2e (runs actual containers)
task bench     # performance benchmark (real runtime)
```

Requires the Apple `container` CLI at `/usr/local/bin/container` (v1.2.x) for
runtime features; the app still builds/runs without it.

## Validation

`task validate` runs four layers:

1. **Unit tests** — DTO decoding against real CLI fixtures, progress parsing,
   compose plan ordering.
2. **Integration tests** — every service (system, containers, images, volumes,
   networks, registries, stats, logs, compose) driven end-to-end against
   `Tests/MicropodIntegrationTests/Support/mock-container`, a stateful mock of
   the Apple CLI. Each test gets an isolated state dir, so lifecycle
   (run → list → start/stop/kill → delete), resource tracking (stats deltas,
   `system df` growing with volumes/containers), compose up/down (networks +
   volumes + containers created then torn down), and streaming (build/pull
   progress, log follow) are all exercised without touching a real runtime.
3. **MCP e2e** — `scripts/mcp_e2e.py` drives the built MCP server over STDIO
   against the mock and asserts every tool's response (13/13).
4. **App smoke** — `scripts/app_smoke.sh` launches the app binary (real CLI by
   default), verifies it survives several poll cycles, then quits it.

Real-device regression fixtures live in
`Tests/MicropodIntegrationTests/Fixtures/` (captured live `container list` +
`image list --verbose` output) so the DTOs cannot silently drift from the real
CLI again.

This harness already caught four production bugs: `FileHandle(forWritingTo:)`
not creating capture files (every CLI call failed), `clientAvailable` only
checked at launch, `NetworkAttachment.options` typed `[String: String]` (real
output has `"mtu": 1280`), and the MCP `logs` tool using `--follow`
unconditionally (hung on stopped containers).

### Real-runtime e2e (`task e2e-real`)

`Tests/MicropodIntegrationTests/RealRuntimeTests.swift` runs **full real
containers** on the Apple runtime when `MICROPOD_REAL_E2E=1` (14 tests):

- **Lifecycle** — pull `alpine:3.20` with progress, run with env/labels/init,
  list, exec, log tail, stats sampling, stop/start/delete.
- **Full run flags** — user, dns, dns_search, cap_add/drop, tmpfs, read-only,
  init, workdir/env exec, file copy + rootfs export round-trips (on plain
  containers), exit-code transition.
- **Volumes & networks** — sized + labelled volumes, internal networks with
  subnets + labels, cross-container L3 connectivity (ping by IP).
- **Images** — pull, tag, save, inspect, delete.
- **Build** — real `container build` from Dockerfiles (multi-stage, build
  args, targets, no_cache), then run the built image.
- **Compose** — full-surface stack: env_file + `.env` interpolation, user,
  dns, caps, tmpfs, shm, read-only, init, ports, networks, named volumes,
  `service_healthy` readiness with real timing, `stop_grace_period` honored
  on down — verified in-container via inspect, then complete teardown.

Every resource carries a per-run namespace (containers, volumes, networks,
images) and cleanup force-deletes exactly what the suite created — never
prunes or touches anything else. Verified zero leftovers after every run.

The suite has surfaced real runtime behavior the mock couldn't: `volume create
-s` (not `--size`), `variant.platform` as an object, BuildKit progress line
format, lowercase-only network names, `mode: "hostOnly"` for internal
networks, foreground-run stdout semantics, kill reporting `stopped`,
`docker.io/` name normalization, pretty-printed inspect JSON with escaped
slashes, YAML 1.1 `yes`→bool coercion, the ~8s follow-replay delay, and two
Apple runtime v1.2.2 quirks:

- **`container copy` from a tmpfs mount path hangs** and wedges the container
  (subsequent stop/delete hang until the runtime is restarted and its VM
  processes killed). The app now enforces timeouts on every CLI call so a
  wedged runtime can never hang the app.
- **`container stats` wedges** while such a container is alive — the
  `StatsSampler` treats it as a transient error and retries.

## Compose support

Micropod translates `docker-compose.yml` onto the Apple runtime:

- services: image / build (context, dockerfile, args, target, platform),
  depends_on (ordering + `condition: service_healthy` readiness probes),
  ports (short + long syntax, host_ip), environment + env_file + `.env`
  interpolation (`${VAR}`, `${VAR:-default}`, `$VAR`), volumes (short + long
  syntax: named, bind, tmpfs, read_only), entrypoint, command, user, labels,
  dns/dns_search, cap_add/cap_drop, ulimits, tmpfs, shm_size, read_only, init,
  tty/stdin_open, cpus/mem_limit + deploy.resources.limits, healthcheck
  (test/interval/timeout/retries/start_period), working_dir, restart,
  stop_grace_period, container_name
- volumes: driver, driver_opts (size maps to `volume create -s`), labels,
  external
- networks: internal, external, driver_opts, labels, ipam subnet/subnet_v6

Fields the Apple runtime cannot express (`privileged`, `extra_hosts`,
`stop_signal`) are parsed and surfaced, not silently dropped.

## Docker parity

Grounded against `container` CLI v1.2.2 (`task e2e-real` verifies the whole
surface on the real runtime):

| Capability | Docker | Apple `container` | Micropod |
|---|---|---|---|
| run/create/start/stop/kill/rm/ps/inspect/exec/logs/cp/export/stats/prune | ✅ | ✅ | ✅ |
| restart | ✅ | — (compose it) | ✅ app + MCP |
| image build/pull/push/ls/tag/rmi/save/load/inspect/prune | ✅ | ✅ | ✅ |
| volume create/ls/rm/inspect/prune | ✅ | ✅ | ✅ |
| network create/ls/rm/inspect/prune | ✅ | ✅ | ✅ |
| compose up/down, ps, logs, profiles, pull-policy | ✅ | — | up/down ✅, **ps/compose_down/exec via MCP**, profiles ✅, pull-if-missing ✅ |
| compose: extends / multi-file / secrets / restart policy | ✅ | — | roadmap (restart policy not expressible) |
| commit / diff / top / events / rename / image history / network connect / `docker search` | ✅ | ❌ not in CLI | — |

Everything Micropod exposes is exercised end-to-end by the mock suite
(`task validate`) and the real-runtime suite (`task e2e-real`), so parity
claims stay verified rather than aspirational.

## UI roadmap

A rich, phased UI plan — command palette, global search, activity feed,
multi-select batch actions, sortable container table, log viewer tooling,
stats history charts, image variants, network topology, compose step
visualization + profiles selector, YAML editor, machine/VM surface, themes,
empty states, and cross-cutting polish — lives in
[`docs/UI-ROADMAP.md`](docs/UI-ROADMAP.md) with effort/dependency/priority
detail for every item.

## Performance

`task bench` (`Sources/MicropodBench`) validates performance against the
real runtime with pass/fail budgets. Measured on arm64 · 12 cores ·
macOS 26.5 (Apple `container` v1.2.2), 2026-08-15 — 18/18 checks pass:

| Path | p50 | p95 | Notes |
|---|---|---|---|
| CLI round-trips (status/df/list/images/volumes/networks) | ~260 ms | ~270 ms | dominated by Process spawn + apiserver |
| `stats --no-stream` | 2.4 s | 2.8 s | known runtime cost (budgeted 3.5 s) |
| **Decode + map per poll** | **0.06 ms** | 0.08 ms | app CPU cost is negligible |
| Poll cycle e2e (list → decode → map) | 262 ms | 366 ms | the 3 s app poller spends <9% of its cycle |
| Logs follow throughput | **~242k lines/s** | — | live-stream pipeline keeps up trivially |
| `container run` (alpine cached) | 2.4 s | 2.4 s | VM bootstrap dominates |
| stop+start (restart) | 13.9 s | 14.4 s | runtime burns the full 10 s stop grace (docker parity) |
| MCP `tools/call` over stdio | ~257 ms | ~275 ms | JSON-RPC overhead ≈ 0.04 ms |
| Decode+map, 100 containers | 2.7 ms | 2.8 ms | |
| Decode+map, 1000 containers | 25.9 ms | 27.8 ms | scales linearly, UI stays smooth |

Budgets flag regressions (thresholds in `Sources/MicropodBench/main.swift`);
sections are load-aware — the runtime degrades under heavy VM churn, so
benchmarks run against a quiet runtime and self-clean every container they
create.

## Local HTTP API

`task api` (`Sources/MicropodAPI`) runs a dependency-free HTTP/1.1 JSON API
over the same MicropodCore services the app and MCP use — programmatic access
for scripts and tools. Docker-shaped routes:

```
GET  /health                      liveness
GET  /v1/system                   runtime status + disk usage
GET  /v1/containers               list containers (JSON projection)
POST /v1/containers               run a container {image,name,env,ports,volumes,labels,...}
POST /v1/containers/create        create without starting (docker create)
POST /v1/containers/{id}/start|stop|restart|kill
DELETE /v1/containers/{id}?force=true
GET  /v1/containers/{id}/logs?tail=N    SSE event stream (text/event-stream)
GET  /v1/images | POST /v1/images/pull {reference} | DELETE /v1/images/{ref}
GET  /v1/volumes | POST /v1/volumes {name,size} | DELETE /v1/volumes/{name}
GET  /v1/networks | POST /v1/networks {name,internal,subnet} | DELETE /v1/networks/{name}
GET  /v1/stats                     latest resource snapshot
POST /v1/compose/up {path,profiles} | POST /v1/compose/down {name}
POST /v1/exec {id,command,workdir}
```

Configuration: `MICROPOD_API_PORT` (default 45454), `MICROPOD_CONTAINER_CLI_PATH`.
Covered end-to-end by `MicropodAPITests` (spawns the server against the mock
CLI and drives the whole surface over URLSession, including the SSE stream).

## Docker Engine shim

`task shim` (`Sources/MicropodDockerShim`) exposes a Docker Engine HTTP API on
a unix socket plus a TCP port, backed by the same MicropodCore services. This
is what makes micropod work with Testcontainers and other Docker-API clients:

```
curl --unix-socket ~/.micropod/docker.sock http://localhost/_ping
DOCKER_HOST=unix://$HOME/.micropod/docker.sock <docker-api-client> ...
```

- **Listeners**: unix socket at `~/.micropod/docker.sock` and TCP on
  `127.0.0.1:45455` (all interfaces), so containers inside the runtime VM can
  reach it via the host bridge.
- **Surface**: `_ping`, `/version`, `/info`, `/auth`, `/events`, images
  (pull/list/inspect/tag/delete/prune), containers (list/create/inspect/
  start/stop/restart/kill/rm/wait/logs/stats/archive put+get/prune), exec
  (create/start with stdcopy hijack or detach/inspect), networks and volumes
  (list/create/delete/prune). Versioned client paths (`/v1.24/...`) are
  accepted; unknown list filters are rejected like real dockerd, so reapers
  can't accidentally match everything.
- **Ryuk interception**: creating an image containing `testcontainers/ryuk`
  strips any docker.sock bind mount, injects
  `DOCKER_HOST=tcp://<bridge>:45455` into the container's env, and ensures
  `8080/tcp` is published. A real ryuk container then connects back to the
  shim over the VM bridge and reaps labeled resources — verified end to end:
  session filter ACK → victim deleted → bystander untouched → self-reap.
- **Exit codes**: the Apple runtime does not report exit codes for stopped
  containers; the shim reports 0 for them unless an event captured one.
- **Protocol hardening**: chunked request bodies are decoded, `Expect:
  100-continue` gets an interim response (Go SDK archive PUTs), keep-alive
  connections with pipelined-response ordering, unknown list filters are
  rejected like dockerd, name conflicts return 409, SIGTERM/SIGINT exit
  cleanly (killing live exec children), and exec children are killed when
  the client disconnects.
- **Restart policies**: the runtime has none, so the shim supervises
  `always` / `unless-stopped` / `on-failure` (+ `MaximumRetryCount`) with
  exponential backoff that resets after 10s of stable running.
- **Fast stop**: the runtime burns the full grace unconditionally and SIGTERM
  can never be delivered (runtime 1.2.2: `kill --signal TERM` is a no-op and
  PID 1's signals are shielded even from inside the container), so `stop` is
  executed as the runtime's atomic instant-stop — docker's graceful-stop is
  unimplementable, and every grace second would be pure latency.
- **Restart persistence**: created-container memory (names, labels, env,
  ports, AutoRemove) is snapshotted to `~/.micropod/shim-state.json`
  (`MICROPOD_SHIM_STATE`), reloaded on boot, pruned against the live runtime,
  and stopped AutoRemove containers left over from a down shim are reaped.
- **Proxies**: the shim passes its full environment (incl. `HTTP_PROXY` /
  `HTTPS_PROXY` / `NO_PROXY`) through to the `container` CLI, so image pulls
  honor proxy settings.
- **Drop-in validated**: a full `testcontainers-python` +
  `PostgresContainer("postgres:16-alpine")` run against
  `DOCKER_HOST=unix://~/.micropod/docker.sock` — image inspect (Docker-shaped,
  slash-containing references), ryuk session over the bridge, log-based wait
  strategy, published-port SQL (`SELECT version()`, table roundtrip) and
  post-session ryuk reap (zero containers left). Repeat runs verified.
- **Performance** (`task bench-shim`, same conditions): API latency p50 —
  ping 1.1ms / list 29ms / inspect 27ms vs Docker Desktop 17/161/5ms;
  lifecycle p50 — create 80ms, start 892ms, exec 77ms, stop 183ms, rm 136ms
  (full roundtrip 1.4s vs Docker 3.4s, which pays a 2.3s stop grace).
- **Tests**: `MicropodDockerShimTests` (53 tests) drives the whole surface
  in-process against the mock CLI — parser (chunked/pipelined/versioned
  paths), filters, ryuk interception, stdcopy framing, lifecycle, hijacked
  exec, events, AutoRemove, keep-alive/pipelining, state persistence. `task
  e2e-real` adds `RealShimTests`: a real runtime end-to-end including a real
  ryuk reaper session (victim reaped, bystander untouched).

Configuration: `MICROPOD_SHIM_SOCKET` (default `~/.micropod/docker.sock`),
`MICROPOD_SHIM_TCP_PORT` (default 45455), `MICROPOD_SHIM_BRIDGE`
(default `192.168.64.1`), `MICROPOD_CLI_PATH`.

## Volume materialization (`micropod-sharedfs`)

Incrementally mirrors a host directory into a **block-backed** volume, shipping
only what changed since the last sync.

```sh
micropod-sharedfs sync --src ~/projects/app --volume app-src --dest /workspace
micropod-sharedfs invalidate --src ~/projects/app --volume app-src   # force a full re-ship
```

**Why.** On this runtime a virtiofs bind mount is ~32x slower than a block
volume for the small-file writes CI does (8000-file create/walk/read/delete:
~190 ms on a block volume vs ~6.3 s over virtiofs; Docker Desktop's named volume
is 270 ms and its bind mount 3.95 s). Copying a whole tree in on every run would
give most of that back, so only the diff is shipped — over a tar through
`container cp`, never a second bind mount.

Measured on a 4805-file tree (real 800-file / 96 MB repo in parentheses):

| | |
|---|---|
| first sync | 2.6 s (1.67 s) |
| one file changed | ~1.25 s (1.15 s) |
| nothing changed | **~195 ms, no container started** |

Change detection is a manifest of size/mtime/mode/digest per path; a file whose
stat signature matches keeps its recorded digest and is never re-read, so a
no-op sync is a stat walk. A file rewritten with identical bytes (a checkout, an
idempotent codegen step) does not ship.

Honest scope: materializing a *source tree* buys ~2–3x on access, not 32x —
that figure is small-file **writes**, i.e. the cache pattern, which is already
served by putting caches on block volumes. A sync costs ~1.2 s, so it pays off
for a job doing heavy I/O over the tree, not for one that reads it once.

**Constraints this design works around:**

- **Block volumes are exclusive** — the runtime attaches one to a single running
  VM; a second concurrent mount fails to bootstrap with "The storage device
  attachment is invalid". The helper container is therefore gone before anything
  else mounts the volume, and concurrent syncs of one volume are serialized with
  an `flock` (kernel-released, so a crashed sync cannot wedge the volume). A
  helper orphaned by a crash is labelled and reaped on the next run.
- **Writes need an in-guest `sync`** before the helper is removed — removing it
  tears down the VM and anything still in the guest page cache is lost, silently.
- **A recreated volume invalidates the history.** The manifest records a volume
  fingerprint; if it no longer matches, the next sync re-ships everything rather
  than reporting "up to date" against an empty volume. The fingerprint is
  second-granular, so a delete-and-recreate inside one second needs
  `invalidate`.
- `.git`, `.build` and friends are excluded by default (`--exclude` adds more);
  symlinks are recorded as links, never followed.

Tests: `MicropodSharedFSTests` (48) cover the scanner, manifest diff, store,
materializer and lock against a fake runtime.

## connect-go API (Go)

Protobuf-defined service in `proto/micropod/v1/api.proto` (regenerated by
`task proto` with `buf`): the `MicropodService` RPCs — system, containers
(CRUD + lifecycle + SSE log stream), images (list/pull-stream/delete), volumes,
networks, stats, exec. Bindings live in `api/gen` (`micropodv1connect`).
The server (`task api-go`, `api/cmd/micropod-apiserver`) serves Connect, gRPC
and gRPC-Web on 127.0.0.1:45454; a client example (`micropod-ctl`) and a full
connect/client server test suite (`cd api && go test ./...`) are included.

## Agent skills

A complete agent skill (`micropod`) for using the MCP server, HTTP API and
connect-go API — including recipes for cuttlefish-style worker orchestration
and testcontainers/Ryuk-style disposable test containers — lives at
[`docs/agent/micropod-skill.md`](docs/agent/micropod-skill.md) and is
installed to `~/.claude/skills/micropod`. The MCP server is registered in
Claude Code config (`~/.claude.json` → `mcpServers.micropod`).

## Compose startup benchmark

`task bench-compose` (`scripts/bench_compose_startup.sh`) starts an identical
postgres:16 compose stack via Micropod's compose pipeline (Apple runtime,
real healthcheck readiness) vs Docker Desktop (`up -d --wait`), reporting
wall time to ready. On this box Micropod was **~3–4 s** per run (cached
image); Docker Desktop's daemon was unstable under load and could not
complete a run (the script reports FAIL for that column and continues).

## MCP

```jsonc
{
  "mcpServers": {
    "micropod": { "command": "/path/to/dist/micropod-mcp" }
  }
}
```

## CLI

`micropod` is a single-binary CLI over the same MicropodCore services the app and
MCP server use — full lifecycle, images, volumes, networks, registry, compose,
plus debug/monitor tooling the other surfaces don't have.

```console
$ task cli -- status            # runtime + version info (also: version)
$ micropod ps -a                # containers (-s adds CPU/mem columns, --json for JSON)
$ micropod run --name web -p 8080:80 -e FOO=bar nginx sleep 300   # docker-ish flags
$ micropod logs web -f          # stream container logs (--boot for boot log)
$ micropod exec web sh -c 'echo hi'
$ micropod top                  # live per-container CPU/mem/net monitor
$ micropod watch                # state-transition event feed (--json = NDJSON)
$ micropod doctor               # runtime diagnostics: probe latency, version skew,
                                #   crashed containers, port conflicts, disk, apiserver errors
$ micropod system logs --last 5m --level error   # backing apiserver logs
$ micropod compose up ./stack   # dependency-ordered compose up with health probes
$ micropod df                   # disk usage by category (+ reclaimable)
```

Global flags: `--json` (machine-readable), `--cli <path>` / `MICROPOD_CONTAINER_CLI_PATH`
(runtime override), `--no-color`. Exit codes: `0` ok, `1` failure (doctor exits non-zero
on failed checks), `2` usage error. Install via `task install` (ships to
`~/.local/bin/micropod` alongside `micropod-mcp`).
