# Micropod

A native macOS desktop manager for Apple's `container` runtime (the OCI
container engine from [github.com/apple/container](https://github.com/apple/container)).
Built with SwiftUI + Swift 6, data models in protobuf, and an MCP server for
agent-driven container management.

## What it does

- **Workspaces** — unified container and microVM inventory with project grouping,
  search, type/state filters and responsive inspectors. Shared light/dark
  components and original operational icons carry through all 14 views,
  attached sheets and the menu bar. See the [native design system](docs/design/2026-10-01-micropod/design-system.md)
  and [responsive preview gallery](docs/design/2026-10-01-micropod/native/responsive/index.html).
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
- **Kubernetes (opt-in)** — `micropod k8s enable && micropod k8s up` runs a full
  k3s cluster as one micro-VM: ~21 s to a Ready node, ~550 MB in use, MetalLB
  LoadBalancer IPs that route on the host's vmnet subnet (the part kind can't
  do on macOS), traefik ingress, and a host kubeconfig at
  `~/.micropod/k8s/kubeconfig`. See `docs/kubernetes.md`.
- **Cache** — measured retained build contexts and package-chunk budgets,
  package-cache Keep and reviewed cleanup with active-mount protection.
- **Menu bar** — running-workload count, workload shortcuts, measured guest
  resources, cache budgets and runtime actions.
- **Runtime setup** — missing-runtime detection, a signed managed installer under
  qualification, opt-in automatic startup, persistent manual stops and native
  readiness diagnostics. See [dependency management](docs/runtime-dependencies.md).
- **MCP server** — STDIO JSON-RPC 2.0 (`tools/call`: status, runtime_status, list_containers,
  start/stop/kill/delete, run, pull/push, inspect, logs, df, compose_up,
  share_mount/unmount/list/sync/gc, build_cache_stats, the HVF machine's caches
  and rig, sandboxes, telemetry). With the API daemon running it talks to it in
  binary Connect over one persistent connection on `api.sock` and starts no
  process of its own; sandboxes boot in the daemon. Without a daemon, the
  container, image, machine and sandbox tools drive the `container` CLI and
  `micropod sandbox` directly, as before.

## Architecture

```
proto/micropod/v1/        protobuf models (curated views + compose spec)
Sources/MicropodCore/     CLI client, DTOs, model mapper, services (actors)
Sources/MicropodApp/      SwiftUI app (store + views)
Sources/MicropodMCP/      MCP STDIO server
Sources/MicropodSharedFS/ chunk store, clonefile views, FSEvents watcher, daemon
Sources/CPtyShim/         C PTY shim for interactive terminals
Tests/MicropodCoreTests/  JSON fixture decoding, progress parsing, compose plan
Tests/MicropodIntegrationTests/  end-to-end tests against a mock `container` CLI
Tests/MicropodSharedFSTests/      shared-fs daemon tests (chunk store, views)
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
task ci        # Go + Node CI pipelines on micropod (below)
```

Every package carries the HVF runtime. Point `MICROPOD_HVF_DISTRIBUTION` at
the qualified payload directory (or `MICROPOD_VMM_DIR` at a built `vmm/`)
before running `task package`. It contains the entitled `micropod-vmm`,
`vmlinux-hvf`, `mp-hvf-init.cpio` and `micropod-oci-tools/`. The app and
standalone tarball carry the same runtime, and `task package` fails unless
`scripts/verify_release_payload.sh` passes on both. A local development
package without it needs `MICROPOD_PACKAGE_WITHOUT_HVF=1`, which CI refuses.
On a fresh machine, `micropod machine install --disk-image default`
discovers those bundled resources. Use `--disk-from <ext4>` to clone an
existing worker disk.

A hosted release must pin the HVF runtime; there is no release without it.
Dispatch the **HVF runtime** workflow (`.github/workflows/hvf-runtime.yml`)
on the release commit with the kernel's https URL and SHA-256. It builds the
VMM, initramfs and guest tools from that commit and uploads the
`micropod-hvf-runtime` artifact (`micropod-hvf-runtime.tgz`, the four entries
at its root); its summary names the run ID and archive digest. Pass them to
the release as `hvf_run_id` and `hvf_payload_sha256`, or set the repository
variables `MICROPOD_HVF_RUN_ID` and `MICROPOD_HVF_PAYLOAD_SHA256` for tag
builds. The release checks the source commit, archive digest, VMM signature
and hypervisor entitlement before packaging, then verifies the app, DMG and
tarball (`scripts/verify_release_payload.sh`, Developer ID included once
signed). Publishing a frozen qualification (`publication_version`) runs the
same verifier on the frozen DMG and tarball first. `micropod update cli`
updates the CLI, MCP, API, Docker shim and shared-filesystem binaries beside
it and stages the HVF payload; `micropod update hvf apply` activates it.

Sandboxes boot Micropod's own HVF kernel: the one `micropod sandbox setup`
staged and recorded, else the installed machine's, else the `vmlinux-hvf`
shipped with Micropod. The `com.apple.container` kernel is used only with
`MICROPOD_LEGACY_APPLE=1`. The sandbox `vminit` is pinned by digest;
`--vminit` and `MICROPOD_SANDBOX_VMINIT` take only `repo[:tag]@sha256:<digest>`. The [Gamma qualification report](docs/benchmarks/2026-11-26/workspace-reply-wait-and-native-network.md) records the tested package, Docker API coverage and CI timings.

Released Micropod 0.12.6 uses an externally installed Apple `container` CLI and
service. This branch adds an administrator-approved installer and dedicated
runtime account, with rig coordination. Physical qualification is pending under
[#89](https://github.com/castlemilk/micropod/issues/89). The app builds and runs
without the CLI. See [dependency management](docs/runtime-dependencies.md).

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
   against the mock and asserts every tool's response (22/22).
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
surface on the real runtime; performance re-validated on v1.3.1 — see
Performance):

| Capability | Docker | Apple `container` | Micropod |
|---|---|---|---|
| run/create/start/stop/kill/rm/ps/inspect/exec/logs/cp/export/stats/prune | ✅ | ✅ | ✅ |
| restart | ✅ | — (compose it) | ✅ app + MCP |
| image build/pull/push/ls/tag/rmi/save/load/inspect/prune | ✅ | ✅ | ✅ |
| volume create/ls/rm/inspect/prune | ✅ | ✅ | ✅ |
| network create/ls/rm/inspect/prune | ✅ | ✅ | ✅ |
| compose up/down, ps, logs, profiles, pull-policy | ✅ | — | up/down ✅, **ps/compose_down/exec via MCP**, profiles ✅, pull-if-missing ✅ |
| compose: extends / multi-file / secrets / restart policy | ✅ | — | roadmap (restart policy not expressible) |
| commit / diff / top / image history / network connect / `docker search` | ✅ | ❌ not in CLI | — |
| events / rename / healthcheck supervision / custom-network DNS | ✅ | — (no runtime primitives) | ✅ emulated in-shim |

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
real runtime with pass/fail budgets. Measured on arm64 · 18 cores ·
macOS 26.5.1 (Apple `container` v1.3.1), 2026-09-07 — 18/18 checks pass
(previous baseline 2026-08-15 on runtime v1.2.2 shown for comparison —
v1.3.1 is dramatically faster across the board):

| Path | p50 (v1.3.1) | p95 | v1.2.2 baseline | Notes |
|---|---|---|---|---|
| CLI round-trips (status/df/list/images/volumes/networks) | ~15–86 ms | ~16–91 ms | ~260 ms | Process spawn + apiserver much faster |
| `stats --no-stream` | 17 ms | 23 ms | 2.4 s | known runtime cost fixed upstream |
| **Decode + map per poll** | **0.05 ms** | 0.06 ms | 0.06 ms | app CPU cost still negligible |
| Poll cycle e2e (list → decode → map) | 17 ms | 20 ms | 262 ms | the 3 s app poller spends <1% of its cycle |
| Logs follow throughput | **~155k lines/s** | — | ~242k lines/s | live-stream pipeline keeps up trivially |
| `container run` (alpine cached) | 0.77 s | 0.77 s | 2.4 s | VM bootstrap much faster |
| stop+start (restart) | 11.9 s | 12.6 s | 13.9 s | runtime burns the full 10 s stop grace (docker parity) |
| MCP `tools/call` over stdio | ~26–33 ms | ~28–50 ms | ~257 ms | JSON-RPC overhead ≈ 0.04 ms |
| Decode+map, 100 containers | 4.2 ms | 5.5 ms | 2.7 ms | |
| Decode+map, 1000 containers | 36 ms | 40 ms | 26 ms | scales linearly, UI stays smooth |

Budgets flag regressions (thresholds in `Sources/MicropodBench/main.swift`);
sections are load-aware — the runtime degrades under heavy VM churn, so
benchmarks run against a quiet runtime and self-clean every container they
create.

## Container runtimes

Micropod drives five execution engines behind one API in this source tree. Pick one per
container (`RunContainerRequest.runtime`, `micropod run --runtime`) or set a
default; `ListContainers` merges every enabled engine and stamps each
container's `runtime`, and id-based calls route to the engine that owns it.

| engine | kind | what it is | notes |
|---|---|---|---|
| `hvf` | microvm | containerd and crun in a shared Hypervisor.framework machine | **the default on a fresh install**; set it up with `micropod setup`; enabled once installed |
| `apple` | vm | Apple container runtime — one micro-VM per container | the default on an existing install; **opt-in** on a fresh one (`micropod runtime enable apple`); volumes, networks, ports |
| `docker` | container | any Docker Engine socket (Docker Desktop, OrbStack, colima, `tcp://`) | **opt-in** so an existing Docker Desktop's containers don't appear until asked |
| `sandbox` | microvm | ephemeral in-process micro-VM booted from a clonefile of a cached rootfs | fastest boot; tcp ports, bind mounts; no named volumes; can't restart — run a new one |
| `ci` | container | one Micropod-owned Linux VM per trusted runner account | `micropod ci start` keeps the kernel, Docker engine, BuildKit and named volumes warm |

A fresh install defaults to `hvf`; an install that was already there keeps what it has. The first micropod
binary to run (the CLI, the app, the API, the MCP server or the Docker shim) decides once, before it writes
anything: with no `~/.micropod/runtimes.json` and a `~/.micropod` that is missing or empty it pins
`{"default": "hvf", "defaultOrigin": "fresh-install"}`, and otherwise `{"defaultOrigin": "existing-install"}`, which
keeps the Apple default. A runtimes.json that exists is never rewritten. On a fresh install the Apple runtime is
**opt-in**: nothing pings, polls or starts it, the app does not start the Docker shim (which fronts it), a call
that names it says `the Apple runtime is opt-in: micropod runtime enable apple`, and an id no enabled engine owns is
not found instead of being asked of Apple. `micropod runtime enable apple` turns it on, `micropod runtime use apple`
also makes it the default, and `MICROPOD_LEGACY_APPLE=1` enables it for one process. An existing install sees no
change. (With `MICROPOD_RUNTIMES_CONFIG` set, as in tests and CI, nothing is decided unless
`MICROPOD_INSTALL_ORIGIN=fresh|existing` says which.) No Apple or shim code is removed yet.

```
$ micropod runtime ls
NAME       KIND       AVAILABLE  ENABLED  VERSION  ENDPOINT / REASON
─────────  ─────────  ─────────  ───────  ───────  ─────────────────────────────────────────
  apple    vm         yes        opt-in   —        opt-in: `micropod runtime enable apple`
  docker   container  no         no       —        Docker socket not found
  sandbox  microvm    yes        yes      —        —
  ci       container  no         no       —        CI worker is stopped
* hvf      microvm    no         yes      —        not set up: `micropod setup`
default: hvf (chosen for a fresh install; `micropod runtime use <name>` changes it)
```

```bash
micropod runtime ls                        # availability, enabled, default
micropod runtime use sandbox               # default for new containers
micropod runtime enable docker
micropod runtime endpoint docker unix://$HOME/.orbstack/run/docker.sock
micropod run --runtime docker nginx
```

For trusted CI, `micropod ci endpoint` starts or joins the account's worker and prints its Docker URI.
`task ci` runs the Go and npm pipelines concurrently on that kernel. [CI worker operation and benchmarks](docs/ci-worker.md)

Same over the API (Connect `SystemService.ListRuntimes / SetDefaultRuntime /
UpdateRuntime`, REST `GET /v1/runtimes`, `PUT /v1/runtimes/default`,
`PATCH /v1/runtimes/{name}`), the SDKs, and the MCP tools `runtimes`,
`runtime_set_default`, `runtime_update` (+ `run`'s `runtime` argument).
Settings persist in `~/.micropod/runtimes.json`. `MICROPOD_DEFAULT_RUNTIME`
overrides the default per process. `Ping.features` includes `runtime` on
servers that honour the field.

On the Docker, CI and HVF runtimes, `micropod exec` streams binary stdout and stderr as the process runs and returns its exit code.
Use `micropod exec -i build-1 -- sha256sum < artifact.tar` to send a file on stdin.
Use `micropod exec -it build-1 sh` from a terminal for an interactive shell. The guest receives terminal resizes and control characters. With `-t`, its stdout and stderr share the PTY.
The Docker adapter negotiates API 1.43 through 1.47 and accepts an explicit `DOCKER_API_VERSION` pin.
`micropod machine help` lists the assets for the shared machine. `micropod machine docker-endpoint` prints the Unix socket for stock Docker clients.

Volumes and images route the same way: `micropod volume ls` and `micropod images` merge every enabled engine
that keeps its own (Docker, the CI worker, the hvf machine) and name the runtime once more than one is listed; `volume create`
and `pull` take `--runtime` or the default runtime; `volume rm`, `rmi`, `tag` and `image inspect` go to the engine
that has the name. The hvf guest engine lists, creates, inspects and removes volumes, and lists, inspects and pulls
(linux/arm64) images. With a tool bundle built from this tree (`ci/build-runner-tools.sh`) it also saves and loads
image archives: `micropod save --runtime hvf <ref> -o x.tar` and `micropod load --runtime hvf -i x.tar` (an unnamed
`load` stays Apple's), and removes and tags images: `micropod rmi` of a tag untags it, of an ID or a digest removes
the image once no container uses it (a multi-platform image from a registry included). Volume prune, volume sizes,
image prune, push and `micropod build` are refused as
unsupported, and micropod's network commands stay with Apple; stock Docker clients on
`micropod machine docker-endpoint` also get networks. `micropod machine status --json` reports the installed
bundle's `capabilities` (caches, `docker build`, BuildKit, the engine's Docker API range and commit, the
published-port path); `micropod machine buildkit-endpoint` prints the BuildKit socket for a remote `docker buildx`
builder, and fails when the tool bundle ships no `runner/bin/buildkitd`.

Dependency caches on the hvf machine are on by default. Every container created through the machine's Docker socket
gets shared Go module and build caches and npm, pnpm, yarn, pip, uv, cargo and corepack caches in one scope,
`default`, whatever uid it runs as. The machine-wide policy lives in `machine.json` (`cache`) and applies at once
while the machine runs:

```bash
micropod machine cache policy                          # show it
micropod machine cache policy --mode off               # no caches for anyone
micropod machine cache policy --tools go,npm --default-scope none --allow-scopes 'ci-*'
micropod run --runtime hvf --cache off golang:alpine -- go env GOCACHE   # this container only
micropod run --runtime hvf --cache-scope proj-a golang:alpine -- go build ./...
```

`--cache auto|off|<tools>` (`go`, `gomod`, `gobuild`, `npm`, `pnpm`, `yarn`, `yarnberry`, `pip`, `uv`, `cargo`,
`corepack`; `+tool` forces one on, `-tool` leaves one out) and `--cache-scope` become the labels
`io.micropod.cache` and `io.micropod.cache.scope`, which compose files and Testcontainers can set too; a label the
container already has wins. On other runtimes `--cache off` maps to `com.micropod.cache.shared=false` and a tool
list or scope is refused. The host renders the policy into `<root>/run/guest-config/cache-policy.json`, shared with
the guest as `mp-config` (read-only in the guest at `/run/micropod/host-config`).

Every container has a cache trust tier. A trusted one writes the stores it uses; an untrusted one
(`io.micropod.cache.trust=untrusted`) or a read-only one (`io.micropod.cache.readonly=1`) reads them warm through a
copy-on-write view and never writes them, through any path (auto-attached caches, `micropod-ci-scoped-*` volumes,
`docker cp`). A reader sees only the stores it uses, of its own scope: not the scope's other tools or another uid's
partition, and no alias volume of another scope. A container that names no tier gets the policy's `defaultTrust`:
trusted as shipped, so a plain `docker run` on your own machine warms the caches, on a host that runs Cuttlefish CI
too (Cuttlefish labels the tier of every container it creates); `micropod cache policy --default-trust untrusted`
makes unlabeled containers readers. A container may lower its tier; it may claim `trusted` under an untrusted
default only with the `io.micropod.cache.trust` label on the machine's own Docker socket, never with
`MICROPOD_CACHE_TRUST` in its environment (an orchestrator passes a job's `env:` through), and under that default
`MICROPOD_CACHE_SCOPE` names no scope either. A container created from inside another is never more trusted than its
creator. Whoever holds the machine's Docker socket is the host: it can name any tier and any scope, and every
`docker build` shares one BuildKit, whose `RUN --mount=type=cache` contents are keyed only by the id the Dockerfile
gives, so never hand that socket to untrusted code. A trusted container the host creates with
`-v /var/run/docker.sock:/var/run/docker.sock` (Testcontainers, compose or `docker build` in a CI step, Cuttlefish's
`dockerSocket: true`) gets the machine's Docker API on a socket of its own, which is not the host's: through it the
container sees and acts on only itself and the containers, networks and volumes it created there (plus the built-in
networks, the networks it is attached to and the volumes it mounts, which it may mount in what it creates but not
remove); every other job's are not there (404), though their names are still the machine's: creating a container,
network or volume of a name another job's holds is refused (409), so two jobs of the same compose project that run at
the same time on one machine need project names of their own (`-p` or `COMPOSE_PROJECT_NAME`); a network or volume it created
there is no other container's to join or mount, not even through the machine's own socket (409), and the engine's own routes
(`/micropod/*`: caches, metrics, traces, the BuildKit probe, which `GET /version` answers too) are refused (403). What it creates there is never more trusted than it is, gets
at most the container's own CPU, memory and process limits (a request for more, or for none, is lowered to them; at
most 256 such containers at a time, HTTP 409 past that), is in its cache scope (naming another is refused, HTTP 403, as is mounting another's alias volume, HTTP 400), may bind only paths inside the container's own binds
(read-only where it reaches them only read-only, as under a read-only bind nested in a writable one; anything else, the rest of the workspace included, is refused, HTTP 403;
the create, every start and a `docker cp` into it stopped decide this again by what the bind resolves to, against the running container's own
binds, so a bind of a renamed parent of one of its read-only binds, or of a symlink to one, is refused while it would reach it writable; a request
on its socket that needs this check while the container is not running is refused, HTTP 409; such a bind resolves
below what the running container binds, whatever symlink the path of its own bind runs through, and the host's own
start of the child while the container is stopped refuses one whose path does, HTTP 403), mounts a volume
the container was given read-only only read-only, and cannot be given a socket in turn. What it created there goes
with the container: its removal stops and removes those containers, then the networks and volumes it created there
(data included) once nothing uses them, so the next job of the same compose project finds the names free (an engine
start does the same for anything whose creator is gone; what cannot be removed at once, such as a container a `docker
cp` still holds, is tried again for about a quarter of an hour). Images and the BuildKit cache stay the machine's: a pull, build, load, tag or `rmi` through that
socket changes them for every job, which is one more reason only a trusted container gets one. A build itself is the
job's: on that socket another job's build's progress and frontend calls are not there, and the machine's build history
(`docker buildx history`: every build's args, logs and results) and its content are refused; a build under a ref
BuildKit already has (another job's, a finished one, one through the machine's BuildKit builder) is refused
(`AlreadyExists`), so knowing a ref does not reach that build's logs. A build ref there is at
most 64 bytes, and one socket has at most 256 builds running or finished in the last minute (more is refused,
`ResourceExhausted`). An untrusted or read-only
container, a container created from inside another, or one an untrusted default leaves unlabelled is refused such a bind
at create (HTTP 403); the Testcontainers reaper still gets only its session's cleanup socket, and one created through a
container's socket reaps only what that container created. As under Docker, every container has an empty `/.dockerenv`,
and a published port is also reachable from inside the machine at `10.88.0.1:<port>`, the default network's gateway,
whatever network the published container is on (and at its own network's gateway): that is where an in-container
Testcontainers dials a sibling's mapped port and its Ryuk reaper. A machine whose owner accepts that its jobs share
one engine can hand a container of any tier such a socket (`micropod cache policy --docker-socket any`; a container
made on one that binds `docker.sock` in turn, as a GitHub Actions runner's `container:` job does, then shares its
creator's), give containers that name no limit a Docker daemon's defaults instead of one CPU and 1 GiB
(`--default-limits none`), and admit work by `micropod machine capacity` (`RigService/GetMachineCapacity`: CPUs,
memory, containers by family, the guest's PSI, disk space, start latency and a recommended headroom, in one guest
request); both settings are the owner's, refused over loopback TCP. What that relaxes and what it does not, the
headroom formula, job families (`io.micropod.family`, `X-Micropod-Family`, `POST /micropod/families/prune`) and the
measurements are in [docs/shared-engine-rig.md](docs/shared-engine-rig.md). The gateway is the engine's own address, past the
rules that keep networks apart, so it relays only a container that shares a network with the published one (and could
reach it anyway) or belongs to the same job (the container holding the socket and what it created), at most 512
connections a port, 512 for any one job and 4096 in all; once one side of a relayed connection closes, the other is
closed after a minute without a byte. Nor does the machine itself connect into a container network: a connection one of its own
processes starts out through a network's bridge (a build's `ADD` URL or git context, an image pull, `docker login`,
whichever socket asked) is refused at once (no route to host), so only the relays, whose rule decided the peer, reach
a container from the machine. When the machine asked for its host config share, a policy file
the guest cannot read fails closed (untrusted by default), and no bind may reach the machine's own directory
(`~/.micropod/hvf` sits in the home-directory workspace): a bind source inside it is refused, and a bind that covers
it (`-v $HOME:/h`) shows an empty directory there, to `docker cp` as well; both are decided by the directory's identity when the bind
opens (every start), so a rename of it or of a directory above it made before then does not move it out from under the mask. `--allow-scopes` holds for scope labels and alias volumes alike.
With `--share-l0 on`, only the stores whose tools verify them on every read (Go modules, npm, pnpm) are shared
across scopes, the modules and packages of private projects included; maven, gradle, bun, playwright and every
other store stay per scope. A container an older engine created with such a store in scope `global` starts without
it (`shared-store-retired`) until it is recreated, and `micropod cache prune --scope global --tool maven` (and so on)
removes what is left there. `--go-proxy` and `--npm-registry` reach a container only while the proxy answers, at
create and at every start, never over its own, its image's or a mount's setting (a variable, a `.npmrc` registry, a
go env file's `GOPROXY`, or config files the container names itself), never into an untrusted one unless
`--proxy-untrusted on`, and the injected `GOPROXY` always ends in `|direct`. A setting a step writes after create (a
clone into a volume, a subproject's own `.npmrc`) is not seen. Maven's local repository has one writer at a time:
another container that uses it reads it copy-on-write (`micropod cache explain` says `reads`). BuildKit's state,
`RUN --mount=type=cache` contents included, lives on the OS disk with the image snapshots it refers to: it survives
restarts, and `machine install --replace-disk` starts it empty (the dependency stores on the cache disk survive).

An image the machine has answered for is on its OS disk: a `docker pull`, `docker load` or `docker build` (a
build's Solve, and a scheduler job's pull) answers only after the engine has synced the filesystem that holds
containerd's store, so a crash of the VMM afterwards leaves the image whole (and a host power loss, under the default
ordered flushes below, leaves it whole or, if it took the last flushes with it, gone, never broken). containerd
itself writes an unpacked layer's files without a sync: before this, an image pulled up to about 35 s before a crash
came back listed but broken (`exec format error`) and stayed broken through every pull. One whose pull,
load or build had not answered when the machine went down is gone after the restart, or whole: the engine's start
after an unclean stop removes what containerd committed after the last sync (snapshots, blobs whose file is
missing, the image records that name them, BuildKit's cache records made since), so the next pull unpacks it again.
A stop is never taken for a crash: the engine syncs once more as it stops, so the start after a `machine stop` removes
nothing. "After the last sync" is read off the guest's clock, which guest init never sets back in ordinary running (it
slews a backward correction from the host); only a host whose own clock is set back by half a second or more can make
a layer committed right after look older than it is.
The engine's metrics count the syncs (`image_syncs`, `image_sync_usec_total`), and `scripts/gates/records-crash.sh`
kills the VMM around each kind.

Each of the machine's disks orders its writes on the host: a guest journal commit is an `F_BARRIERFSYNC`
(micropod-vmm `--disk-flush barrier`, the default for both disks), so a host power loss or kernel panic loses at most
the last commits, in order. `osDiskFlush` in `machine.json` trades that ordering for speed on the OS disk alone. It is
opt-in; nothing sets it, and a restart applies it:

```json
{ "osDiskFlush": "fsync" }
```

micropod-vmm then runs with `--disk-flush-os fsync`: the OS disk's flushes are plain `fsync(2)`, which hands the data
to the drive in no guaranteed order. **A host power loss or kernel panic can corrupt the OS disk; recovery is
`micropod machine install --replace-disk`, which loses the images, containers and volumes on it.** The cache disk
keeps barrier ordering, so the dependency stores survive. A crash of the VMM alone (kill -9) is safe either way. What
it buys, measured on an 8 vCPU machine (create+start of `alpine true`, p50 of 40): 62.9 → 29.1 ms with caches off and
56.8 → 30.5 ms with them on, about 30 ms a container start, the same as `--disk-flush fsync` on both disks
(29.5 and 31.3 ms); an image sync costs 29 → 17 ms a pull and 61 → 27 ms a 16 MiB load. `osDiskFlush` also takes
`barrier` and `full` (`F_FULLFSYNC`), `extraArguments` may not carry `--disk-flush-os`, and `machine status` shows
the modes (`disk flush:`, `diskFlush` in `--json`): what the running VMM was launched with and, after an edit, what
the next start uses.

`machine.json` outlives a payload, and a micropod-vmm built before `--disk-flush-os` exits 2 on it. So before each
launch the supervisor asks the payload's own binary (`micropod-vmm --help`, which names every flag; the answer is kept
per file). A VMM that does not name the flag, after `micropod update hvf rollback` to an older payload say, or one
that does not answer, is started without it: the OS disk keeps the ordering both disks have (barrier unless
`extraArguments` carry `--disk-flush`), the supervisor log has a `WARNING: osDiskFlush fsync is not in effect: …`
line, and `machine status` says the same after the modes (`notInEffect` in `--json`, beside `configured`, what
`machine.json` asks for). An `osDiskFlush` that is not a mode refuses the next start, and the line says that instead
(`nextStartRefused`; `nextStart` is then absent).

Stock `docker build` with `DOCKER_HOST=$(micropod machine docker-endpoint)` works when the engine serves BuildKit on
its Docker socket (`machine status` says `docker build: ready (docker socket)`). For an older engine,
`micropod machine builder install` adds a docker context `micropod` on the machine's Docker socket and a remote
buildx builder `micropod-buildkit` on its BuildKit socket (the default builder of that context only), which loads
every build into the machine. Build with `BUILDX_BUILDER=micropod-buildkit docker --context micropod build …`: the
docker CLI hands `docker build` to buildx with `BUILDX_BUILDER=<context>` unless it is set, so without it buildx
picks the context's own builder and fails. `docker --context micropod buildx build …` works too, but buildx then
rewrites its current-builder file, forgetting a builder chosen without `--default` for another context. (buildx
gives each docker context an implicit builder of the same name, so the builder cannot be called `micropod`.)
Installing changes neither the current docker context nor the current builder; each build pays a tarball load and
leaves an `import-<date>` image record. `micropod machine builder rm` removes exactly those two (selecting the context
`micropod docker install --use` replaced first, when `micropod` is current). `micropod machine cache policy --register-buildx on` makes `machine start` install it when needed.

#### First run: `micropod setup`

`micropod setup` sets the machine up from local files, in five steps it reports one by one:

```
$ micropod setup
[1/5] runtime files   micropod-vmm, Image, mp-hvf-init.cpio, tools/ from /Applications/Micropod.app
[2/5] disk            cloned from /Applications/Micropod.app/Contents/Resources/hvf-base-disk.ext4
[3/5] cache disk      created (32 GiB sparse)
[4/5] start           running (engine micropod, Docker API 1.44–1.47)
[5/5] default runtime hvf
next: micropod docker install --use    micropod machine autostart on
```

- **runtime files** come from the app bundle the CLI belongs to, the extracted CLI tarball, or `--payload <Micropod.app
  or a directory>` (a directory holding `micropod-vmm`, `vmlinux-hvf`, `mp-hvf-init.cpio` and `micropod-oci-tools`;
  a payload version's `Image` and `tools/` work too). A development build needs `--payload`.
- **disk** is an APFS clone of `--disk-from <ext4>`, else of the package's base disk `hvf-base-disk.ext4`; a disk on
  another volume is copied (sparsely) instead. Only `--disk-image <ref>|default` downloads anything: it unpacks an OCI
  image (the default is `docker:29.9.3-dind`) into a fresh disk. Packages do not ship a base disk yet
  (`MICROPOD_HVF_BASE_DISK=<ext4> scripts/package_app.sh` adds one), so setup then says: `no base disk: this package
  ships none. Pass --disk-from <ext4> (a local image), or --disk-image default to download docker:29.9.3-dind from
  Docker Hub.`
- **cache disk**: 32 GiB sparse for a new machine (`--cache-disk-size`, `--no-cache-disk`).
- **start** boots it and waits for the Docker API (`--no-start` skips it).
- **default runtime**: hvf on a fresh install; an existing install keeps its default (`micropod runtime use hvf`).

Every source is checked (present, ext4, the VMM's hypervisor entitlement) before anything is written, and every
problem is reported at once. Re-running keeps what is there (`[2/5] disk  present, kept`). `--docker` adds the
docker context below and `--use` selects it; `--autostart` turns autostart on and lets launchd start the machine;
nothing is selected or loaded without them. `--dry-run` prints the plan, `--json` the steps. With no machine,
`micropod run alpine` says `the micropod machine is not set up (missing …): run micropod setup`; it never sets one
up on its own.

The API does the same with `RigService/SetupMachine {payload_path, disk_from, cache_disk_bytes, no_cache_disk,
start}` (local sources only; the reply lists the steps, `ok`, and the machine status), and the app's first run
offers it ("Set Up Machine", with "Choose Disk Image…" when the bundle has no base disk).
`scripts/e2e_first_run.sh` runs a fresh install's first run on throwaway machines.

#### Use the docker CLI

`micropod docker install` makes the stock docker CLI, compose and buildx work with the machine the way Docker
Desktop or OrbStack do, through a docker context named `micropod` on `<root>/run/docker.sock`:

```bash
micropod docker install            # create the context; the current context is left as it is
micropod docker install --use      # …and select it (the context it replaces is recorded)
docker run --rm alpine echo ok     # with --use; otherwise: docker --context micropod run …
docker compose up -d               # compose and buildx follow the context
docker build -t app .              # buildx's docker driver on the engine's own socket
micropod docker status             # CLI, context, selection, shell overrides, plugins, builder, sockets
micropod docker uninstall          # select the recorded context again (else default), remove what install made
```

```
docker context micropod -> unix:///Users/me/.micropod/hvf/run/docker.sock (created)
builder: the context's own builder (the engine builds on its Docker socket)
compose: 5.5.0    buildx: v0.37.2
current context: desktop-linux (unchanged; select with `micropod docker install --use` or `docker context use micropod`)
```

Nothing is written by hand: every change goes through the docker CLI (`MICROPOD_DOCKER_CLI`, else `docker` on
`PATH`), so `DOCKER_CONFIG` decides whose configuration changes, and the current context changes only with `--use`.
The context `--use` replaced is kept in `<root>/docker-wiring.json`; a second `--use` keeps it. A `micropod` context
that points somewhere else is refused, naming its endpoint (`--force` repoints it). None of the commands starts the
machine: start it with `micropod machine start` (or a `micropod run --runtime hvf …`); a selected context on a stopped
machine fails the way a stopped Docker Desktop does.

`--builder auto` (the default) adds no builder when the engine builds on its Docker socket (`machine status` says
`docker build: ready`), and the remote builder `micropod-buildkit` (as `micropod machine builder install`) when it
cannot; `--builder remote` always adds it, `--builder none` never. Problems that do not stop the command are `note:`
lines on stderr: `DOCKER_HOST` or `DOCKER_CONTEXT` set in the shell (docker ignores the selected context while either
is set), a compose or buildx plugin the CLI does not find (Homebrew installs them in
`/opt/homebrew/lib/docker/cli-plugins`, which the CLI searches only when `cliPluginsExtraDirs` in `config.json` names
it; `docker build` needs buildx, because the engine has no classic `/build`), a `credsStore` or `credHelpers` entry
whose `docker-credential-<name>` is not on `PATH` (a leftover `"credsStore": "desktop"` after removing Docker Desktop
breaks every pull), a docker CLI older than the engine's minimum Docker API 1.44, and a stopped machine. Without a
docker CLI, `install` fails and prints the `DOCKER_HOST` line to export instead.

Clients that ignore docker contexts and only try `/var/run/docker.sock` need a link there, which takes root:
`micropod docker install --system-socket` prints the `sudo ln -sfn …` command and what the link points at now
(Docker Desktop, OrbStack, …) and runs nothing; `uninstall` prints the `sudo rm` line when the link still leads here.
`scripts/e2e_docker_wiring.sh` runs all of it against a throwaway machine with a temporary `DOCKER_CONFIG`.

#### Start at login, stop at logout, and see the machine's state

`micropod machine autostart on` hands the machine to launchd: a per-user LaunchAgent runs `micropod machine serve
--link-socket` in the foreground, so launchd starts the machine at login and, at logout or shutdown, sends the
supervisor SIGTERM and waits for the guest to power off before it kills anything:

```bash
micropod machine autostart on            # load the job now (it starts the machine) and at every login
micropod machine autostart on --no-load  # write the LaunchAgent only; launchd loads it at the next login
micropod machine autostart status        # on/off, loaded, the program it runs, launchd's exit timeout
micropod machine autostart off           # unload it (stops the machine), then start the machine again outside launchd
```

```
autostart: on (launchd com.skunkworq.micropod.machine, loaded, program /Users/me/.local/bin/micropod, exit timeout 25 s)
```

The job (`~/Library/LaunchAgents/com.skunkworq.micropod.machine.plist`, recorded in `<root>/autostart.json`) has
`RunAtLoad`, `KeepAlive {Crashed: true}` (a `machine stop` or a supervisor that gave up after repeated crashes stays
down), `ExitTimeOut` = the machine's `shutdownTimeoutSeconds` + 15 s, and `ProcessType Interactive`; its log is
`<root>/logs/supervisor.log`. While it is loaded, `machine start`, `micropod run --runtime hvf …` and the API start the
machine with `launchctl kickstart`, so the machine launchd stops at logout is the one that runs; if the kickstart starts
nothing within 10 s, they fall back to the detached supervisor they launch without autostart. A root without
`autostart.json` never runs launchctl. Loading the job restarts a machine already running outside launchd, and
unloading it stops the machine, so `on` and `off` are deferred while containers run (`error: deferred: 2 running
container(s) on the machine; …`) unless `--force`. The program is `--program`, else `MICROPOD_CLI`, else
`~/.local/bin/micropod` for a CLI inside the app bundle, else the CLI's own path; `autostart status` says when it is
gone. Without autostart, the machine starts on demand from micropod and the API as before, and nothing stops it
cleanly at logout.

A root other than `~/.micropod/hvf` gets its own label (`com.skunkworq.micropod.machine.<8 hex digits of its path's
SHA-256>`) and is loaded into launchd only with `MICROPOD_AUTOSTART_ANY_ROOT=1`. `MICROPOD_LAUNCHCTL` names the
launchctl to run and `MICROPOD_LAUNCH_AGENTS_DIR` the directory for the plist, which is how the tests and
`scripts/e2e_machine_lifecycle.sh` keep away from your launchd and `~/Library/LaunchAgents`.

`micropod status` shows the machine first, read from the API's `RigService/GetMachineStatus` when an API answers for
the same machine root within two seconds and in-process otherwise; it pings the Apple runtime only when Apple is the
default or enabled (its lines then follow under `apple:`; `micropod system status` is the old command):

```
runtime:     hvf (default); also enabled: sandbox
machine:     running
engine:      micropod (Docker API 1.44–1.47)
containers:  1 running, 1 total
docker:      unix:///Users/me/.micropod/hvf/run/docker.sock (context micropod, selected)
cache disk:  mounted, 21.4 GiB free of 32.0 GiB
disk flush:  barrier (both disks)
update:      none (payload 0.9.2)
autostart:   on (loaded)
api:         running (/Users/me/.micropod/api.sock)
apple:       not enabled
```

The machine line also reads `starting`, `failed: <why>`, `stopped (on request)` or `not installed: missing … (micropod
setup)`. The docker line is read from the docker CLI's own files (no docker process runs), so it follows a `docker
context use` or `docker context rm` done since `micropod docker install`: `(context micropod; current context:
desktop-linux)`, `(docker context micropod was removed: …)`, or `(docker context micropod points at …, not this
machine: …)`; a `DOCKER_CONTEXT` or `DOCKER_HOST` in the shell counts as the docker CLI counts it. `GetMachineStatus` carries the same facts for any client: `readiness` and `failure_reason`, the
engine's version and API range, `containers_total` and `containers_running`, `disk_flush`, `cache_disk`, `autostart`,
`docker_endpoint` and the payload versions. It never boots the machine; while the machine runs it asks the guest
(one second each). `SetMachineAutostart {enabled, force}` turns the LaunchAgent on or off as the CLI does, and
`ControlMachine start` links the canonical Docker socket as `machine start` does.

The menu-bar panel shows a machine card (state and why it failed, engine, containers, cache disk, disk flush, an
"Update pending" badge, and Start, Stop or Restart) from those RPCs; a stop or restart the API defers asks first and
then forces. With hvf the default runtime, the header and the menu-bar dot follow the machine. Settings → Machine has
"Start the machine at login".

Sandbox VMs are owned by the process that boots them: long-lived sandbox
containers live in the API daemon; the CLI's `run --runtime sandbox` runs in
the foreground to completion. API sandboxes get a network unless labelled
`micropod.network=none`. The binary hosting them needs
`com.apple.security.virtualization` (`signing/micropod-cli.entitlements`).

`micropod sandbox run|checkpoint` is the CLI fast path for CI jobs and
untrusted code, with [shuru](https://github.com/superhq-ai/shuru)'s flags:

```bash
micropod sandbox run                                    # interactive shell (-it)
micropod sandbox run --mount .:/w -w /w node:22 -- npm test   # guest writes never reach the host
micropod sandbox run --mount .:/w:rw --allow-host-writes ...  # …unless asked twice
micropod sandbox run -p 8080:80 nginx                   # forward host 127.0.0.1:8080 → guest :80
micropod sandbox run --expose-host 5432 ...             # guest reaches host.micropod.internal:5432
micropod sandbox run --allow-net --allow-host registry.npmjs.org --allow-host '*.github.com' ...
micropod sandbox run --allow-net --secret API_KEY=OPENAI_API_KEY@api.openai.com ...
```

Offline by default (`--net`/`--allow-net` to attach, `--dns-resolver` to
pick DNS). `--allow-host` sends all egress through a host-side proxy that
refuses every other host — the VM has no route to the internet of its own.
Any networked sandbox (and a shuru VM likewise) can still reach services on
this Mac that listen on all interfaces (`*:port`), as a Docker container
can. micropod's own API and shim are not reachable. For untrusted code,
bind host services to 127.0.0.1 or stay offline.
`--secret` gives the guest a random placeholder; the proxy swaps in the
real value only in request heads bound for the listed hosts, so the
credential never enters the VM. A `micropod.json` (shuru.json's shape:
`cpus`, `memory`, `disk_size`, `allow_net`, `ports`, `mounts`, `command`,
`env`, `secrets`, `network.allow`) supplies defaults; checkpoints reuse a
prepared disk. The MCP server exposes `sandbox_run` and the checkpoint
tools. Benchmarks: `task bench-runtimes` (sandbox vs apple vs machine vs
docker, CLI and API — see [docs/performance.md](docs/performance.md));
live engine matrix through a real API daemon: `task e2e-runtimes`.

### Programmable sandboxes (SDK)

`SandboxService` turns a sandbox into a long-lived environment you drive
from code. You boot it once, then run and stream processes in it, move files
in and out, watch paths inside the guest, and checkpoint it. The TypeScript
SDK wraps it in a `Sandbox` class with shuru's method names:

```ts
import { Sandbox } from "@micropod/sdk";

const sb = await Sandbox.start({
  image: "node:22",
  mounts: { "./app": "/workspace" },           // guest writes stay in the sandbox
  allowNet: true,
  network: { allow: ["registry.npmjs.org"] },
  secrets: {
    NPM_TOKEN: { from: "NPM_TOKEN", hosts: ["registry.npmjs.org"] },
    GH_TOKEN: { command: ["./mint-token.sh"], hosts: ["api.github.com"] },  // re-minted before expiry
  },
  exposeHost: [5432],                          // host.micropod.internal:5432
});
const { stdout, exitCode } = await sb.exec("npm ci && npm test", { cwd: "/workspace" });

const dev = await sb.spawn("npm run dev", { cwd: "/workspace" });
dev.on("stdout", (chunk) => process.stdout.write(chunk));
await sb.watch("/workspace/dist", (e) => console.log(e.event, e.path));
await sb.writeFile("/workspace/.env", "DEBUG=1\n");
await sb.checkpoint("deps-installed");         // saves the disk, stops the VM
const again = await Sandbox.start({ from: "deps-installed" });
```

The RPCs are `StartSandbox`, `StartProcess`/`StreamProcess`/
`WriteProcessStdin`/`SignalProcess`, file operations (`ReadFile`,
`WriteFile`, `ListDir`, `StatPath`, `MakeDir`, `RemovePath`, `RenamePath`,
`CopyPath`, `ChmodPath`), `WatchPath`, and `CheckpointSandbox`/
`ListCheckpoints`/`DeleteCheckpoint`. The Go and Swift SDKs get them as
generated clients.

- **Processes** start from the sandbox's own env, user and working
  directory. Output streams live, and anything emitted before a stream
  opens is replayed.
- **File operations, watches and idling** run on `micropod-guest`, a static
  helper (`guest/`, Go) shared read-only into each sandbox. They need
  nothing from the image, so distroless images work. They run inside the
  container, so they see its mounts and tmpfs, as the image's user.
  Watches use inotify, so they're immediate and see every write.

`RunContainerRequest.sandbox` brings the same controls to the generic
container API: `expose_host`, `allow_hosts`, `secrets` and `dns_resolvers`.

**The API never runs host commands.** A command secret runs in the caller's
process: the SDK runs it before start and again a minute before expiry,
then pushes the value with `UpdateSandboxSecret`. The command prints the
value or `{"version":1,"value":…,"expires_at":…}`. Past its `expires_at`,
requests fail closed instead of sending the placeholder upstream.
`task e2e-sdk` runs the SDK against a scratch daemon.

A `micropod.json` is untrusted until you say otherwise. Keys that grant host
access are refused until you review the file and run
`micropod sandbox trust`: mounts, ports, `expose_host`, networking, and
secrets (which can run host commands). Editing the file revokes the trust.
A cloned repository can't open the sandbox up on its own.

## Storage location

Container images, volumes, VMs and sandbox data can live on any local APFS
volume, such as an external drive on a rig whose internal disk is full:
`micropod storage set /Volumes/External/micropod --migrate`, or **Settings →
Storage Location**. The default paths become symlinks, so every
`container system start` follows them. Keep the drive connected. See
[docs/storage-location.md](docs/storage-location.md).

Use `micropod storage dev-volume plan --projects "$HOME/projects"` to plan a
separate APFS workspace for repositories and shared npm, pnpm and Go caches. The CLI can
migrate and restore the trees, preserve hard links and reapply volume indexing
settings. [Development volumes and live-rig benchmarks](docs/development-volume.md).

## Metrics history

The app records resource usage for every container, machine and the
system as a whole into `~/.micropod/metrics.sqlite`: every 5 s while its
window is open, every 30 s otherwise. It's rolled up as it's written:

| resolution | kept for |
|---|---|
| 10 s | 3 h |
| 1 min | 48 h |
| 15 min | 30 days |

Old points are pruned by age. A container's or machine's history is
deleted with it, including deletions made outside Micropod.

`MICROPOD_METRICS_DB` names another database. Without it, a process whose
`MICROPOD_API_SOCK` names a socket keeps `metrics.sqlite` beside that socket
(an API started for a throwaway root never opens the rig's database); with
the socket at its default that is the same `~/.micropod/metrics.sqlite`. A
socket in a directory other users may write (directly in `/tmp`) gets its own
database in your temporary directory (`$TMPDIR/micropod-metrics/`) instead.

- **In the app:** the dashboard, container and machine graphs open with
  that history, and add 6 h, 24 h and 7 d windows.
- **API:** `SystemService.GetMetricsHistory` (kind + id + range) returns
  averages and peaks at the finest resolution that covers the range.
- **MCP:** the `metrics_history` tool.
- **CLI:** `micropod metrics [id] [--range 24h] [--machine]` prints per
  metric the peak, average and latest value, plus a sparkline.

## Updates

The app checks for updates at launch and hourly (Sparkle, EdDSA-signed
appcast) and downloads them in the background. A downloaded update shows
as a banner ("Restart to Update"), in the menu bar, in Settings, and as a
notification. It installs on quit, or by itself once you've been away for
10 minutes, the app isn't frontmost, and nothing is running. A restart
briefly stops the app's agents (Docker shim, API), and in-flight jobs
would notice. `micropod update [status|check|apply]` and the MCP
`update_*` tools drive the same updater.

**The CLI and MCP server update with the app.** The app bundle carries
them (`Contents/MacOS/micropod-cli`, `Contents/MacOS/MicropodMCP`), signed
and notarized along with the app. At every launch the app links
`~/.local/bin/micropod` and `~/.local/bin/micropod-mcp` to them, keeping a
copy that was there before as `<name>.pre-app.bak`. So Sparkle updating the
app updates both, and a DMG install gets the CLI and MCP server with no
extra step (add `~/.local/bin` to `PATH`). Settings → Updates turns the
linking off.

A **standalone** install (a copy from the release tarball, a headless
machine) updates itself with `micropod update cli`:
- It reads the same appcast and downloads the release DMG.
- It checks the DMG against Sparkle's EdDSA key, the one the app trusts.
- It takes `micropod-cli` and `MicropodMCP` from the signed app inside and
  requires micropod's Developer ID signature on both.
- It swaps them in atomically and keeps `.bak` copies.

After interactive commands, a standalone CLI mentions a newer release once
a day (checked in the background, never blocking a command). Scripts, CI,
`--json` and `MICROPOD_NO_UPDATE_NOTIFIER=1` suppress it.
`micropod update` shows both versions and where the CLI comes from.

## Local HTTP API

`task api` (`Sources/MicropodAPI`) runs an HTTP/1.1 and HTTP/2 (h2c) JSON, Connect and gRPC API
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

The same process serves the typed Connect API under `/api` (see
[connect-go API](#connect-go-api-go)).

**Listeners and request admission.** The API is unauthenticated and can launch
privileged containers with host bind mounts, so it listens on loopback only
(`127.0.0.1:45454` and `[::1]:45454`) and refuses, before any handler runs:

- a `Host` other than `127.0.0.1:<port>`, `localhost:<port>` or `[::1]:<port>`
  → `403` (DNS rebinding);
- an `Origin` outside the CORS allowlist (`MICROPOD_API_CORS_ORIGINS`, default
  the hosted docs plus any localhost origin) → `403`;
- a `POST` (and a `PUT`/`PATCH`/`DELETE` with a body) whose `Content-Type` is
  not `application/json`, `application/connect+json`, `application/proto` or
  `application/grpc[+proto]` → `415`. None of these is CORS-safelisted, so a
  web page cannot send one without a preflight.

REST calls therefore name the type even without a body:

```bash
curl -X POST -H 'Content-Type: application/json' http://127.0.0.1:45454/v1/containers/web/stop
curl -X DELETE 'http://127.0.0.1:45454/v1/containers/web?force=true'   # no body: no type needed
```

`Ping` (and `GET /v1/system`) list the optional `RunContainer` fields the
server honours in `features` (`cap_add`, `cap_drop`, `rosetta`, `privileged`).

**Connections.** Loopback TCP and the owner's socket keep a connection open
after a reply framed by `Content-Length` (HTTP/1.1 persistence, pipelining
included), so a client such as Go's `net/http` or URLSession pays one dial for
many calls. A reply says `Connection: close` and the server closes instead
when the request asked to close, is HTTP/1.0 without `Connection: keep-alive`,
carries both `Transfer-Encoding` and `Content-Length`,
or was refused before a handler ran (bad framing, the admission checks above);
when 256 connections are already kept; or once the server is stopping.
Streams (`text/event-stream`, Connect server streams), the vsock bridge and
managed-runtime relays are delimited by the close that ends them, as before —
unless a stream's request sends `X-Micropod-Stream-Framing: chunked` on a
connection that may persist: its body then comes in chunked transfer coding,
ends with the zero-length chunk, and the connection serves the next request
(the MCP server does this; a client that never sends the header sees no
change). `StreamLogsRequest.no_follow` sends the tail and ends the stream.
A kept connection with no request for `MICROPOD_API_KEEPALIVE_IDLE_MS`
(default 120000, longer than Go's 90 s idle timeout) is closed without a
reply. Inside a request, `MICROPOD_API_READ_IDLE_TIMEOUT_MS` (30000) of
silence or `MICROPOD_API_READ_DEADLINE_MS` (120000) in total answers `408`;
on a kept connection those clocks start at the next request's first byte. The
managed runtime's internal socket answers one request per connection, because
its gateway checks a caller's capability on the first request head only.

### Transports: socket or TCP, HTTP/1.1 or HTTP/2, Connect or gRPC

Every route and RPC is served on both listeners, in every combination below,
by the same handlers behind the same admission checks.

| | Use it when | Notes |
|---|---|---|
| Owner socket `~/.micropod/api.sock` | your own processes on this Mac (CLI, MCP, agents, scripts) | `0600`, this user's only; no `Host`/`Origin`/`Content-Type` checks (no browser can reach it); fastest (no TCP stack) |
| Loopback TCP `127.0.0.1:45454` | tools that only speak TCP, browsers (the docs explorer), other local users' tools | every request must name `Host: 127.0.0.1:45454` (or `localhost`/`[::1]`), pass the Origin allowlist and the Content-Type rule |
| HTTP/1.1 (default) | every existing client: CLI, MCP, Cuttlefish, SDK defaults, curl | keep-alive and pipelining; streams close-delimited (or chunked on request) |
| HTTP/2 (h2c, prior knowledge) | many concurrent calls over one connection, gRPC tooling | detected from the connection's first bytes on the same socket and port; no TLS, no `Upgrade: h2c` |
| Connect (`/api/micropod.v1.<Service>/<Method>`) | connect-go, connect-es, the Swift SDK, plain `curl` with JSON | unary over either HTTP version; server streams as Connect envelopes |
| gRPC (`application/grpc`, `+proto`, `+json`) | grpc-go and any stock gRPC client, grpcurl, buf curl | HTTP/2 only; bare `/micropod.v1.<Service>/<Method>` paths and `/api/...`; `grpc-timeout` honoured; `grpc.health.v1.Health` Check and Watch; no reflection (use the protos) and no compression |

HTTP/2 is served only to a connection whose first bytes are the h2c preface,
on the owner socket and loopback TCP; the managed runtime's internal socket
stays HTTP/1.1 (one request per connection), and `MICROPOD_API_HTTP2=0` turns
it off (a preface then gets HTTP/1.1's `505`). `curl --http2` (the HTTP/1.1
`Upgrade: h2c` dance, removed from HTTP/2 by RFC 9113) gets a plain HTTP/1.1
answer. The guest vsock bridge (`GET /v1/containers/{id}/vsock/{port}`)
takes over its connection as raw bytes, so it needs HTTP/1.1: over HTTP/2 the
stream is reset with `HTTP_1_1_REQUIRED` before anything is dialled.

Over HTTP/2 each request gets the HTTP/1.1 server's own checks: `:authority`
is the `Host` the guard reads (a `host` field that disagrees is a `400`), and
`host`, `origin`, `content-type`, `content-length` and `grpc-timeout` may
appear once. gRPC statuses are the Connect error codes the handlers return
(`not_found` → `NOT_FOUND`, …), refusals included: a foreign `:authority` is
`PERMISSION_DENIED`, a closed runtime admission `UNAVAILABLE`, a method no
service declares `UNIMPLEMENTED` (answered from the headers alone), a gRPC
head the server refuses outright (a repeated `content-type`, a scheme that is
not `http`) `INVALID_ARGUMENT`. Bounds
(`Sources/MicropodAPI/HTTP2/HTTP2Limits.swift`): 100 concurrent streams and
100 handlers in flight per connection, 256 per listener (a stream the client
resets still holds its handler until it returns; mutations are never cut half
way; a handler that has answered holds no place while a slow client takes the
answer, up to 4 MiB of unsent answers per connection), 64 KiB of
headers (once the client acknowledged the server's SETTINGS), 64 MiB per
request body, 128 MiB buffered per connection, NIO's flood limits
(CONTINUATION, RST_STREAM rapid reset, empty DATA, PING/SETTINGS at 6000 per
10 s — a grpc-go log flood peaks below 900), the HTTP/1.1 request deadlines
(RST_STREAM CANCEL), a 120 s write-stall deadline per stream, GOAWAY after
`MICROPOD_API_KEEPALIVE_IDLE_MS` without a stream, and at most 64 HTTP/2
connections per listener, each holding one of the 256 kept-connection places
until its socket is closed. A client that stopped reading its socket is cut
off without a GOAWAY (none could reach it): after 120 s in which it took none
of the bytes waiting for it, or 5 s after the server's side closed. A slow
reader that keeps taking bytes is not, and neither is a connection with
nothing to send.
A health `Watch` does not count as a stream there: a connection with nothing
but Watches on it gets the idle GOAWAY, and the client watches again on its
next connection. A client that ends its side after its requests (`nc -N`) is
answered, then gets GOAWAY and the close.

```bash
# REST and Connect over h2c
curl --http2-prior-knowledge --unix-socket ~/.micropod/api.sock http://localhost/v1/system
curl --http2-prior-knowledge -H 'Content-Type: application/json' -d '{}' \
    http://127.0.0.1:45454/api/micropod.v1.SystemService/Ping

# gRPC: grpcurl and buf curl, with the protos (no reflection)
buf build -o /tmp/micropod.binpb
grpcurl -plaintext -protoset /tmp/micropod.binpb -d '{}' 127.0.0.1:45454 micropod.v1.SystemService/Ping
grpcurl -plaintext -protoset /tmp/micropod.binpb -d '{"id":"web","tail":5,"no_follow":true}' \
    unix://$HOME/.micropod/api.sock micropod.v1.ContainerService/StreamContainerLogs
buf curl --http2-prior-knowledge --protocol grpc --schema /tmp/micropod.binpb -d '{}' \
    http://127.0.0.1:45454/micropod.v1.SystemService/Ping
```

```go
// grpc-go with the generated stubs in sdk/go/gen (unix:// or host:port)
conn, _ := grpc.NewClient("unix://"+os.Getenv("HOME")+"/.micropod/api.sock",
    grpc.WithTransportCredentials(insecure.NewCredentials()))
ping, err := micropodv1.NewSystemServiceClient(conn).Ping(ctx, &micropodv1.Empty{})

// The Go SDK: HTTP/1.1 Connect by default; opt into h2c, gRPC, the socket
client := micropod.NewClient("http://localhost/api",
    micropod.WithUnixSocket(os.Getenv("HOME")+"/.micropod/api.sock"), micropod.WithGRPC())
```

Pick the owner socket for anything running as you, and stay on HTTP/1.1
Connect unless you need what HTTP/2 adds: at one call at a time it is as fast
or faster (B25: Ping, `ListContainers(8)`, `GetCacheStatus` p95 under 1 ms
on the socket); HTTP/2 pays a socketpair hop inside the API and shines with
many concurrent calls on one connection or with stock gRPC tooling.
`scripts/h2-interop.sh` runs grpc-go, connect-go, curl, grpcurl and buf curl
against a throwaway API (`--machine` adds a throwaway hvf machine, server
streams and a log-flood soak).

Configuration: `MICROPOD_API_PORT` (default 45454), `MICROPOD_CONTAINER_CLI_PATH`,
`MICROPOD_RUNTIME` (`auto`/`native`/`cli`), `MICROPOD_ALLOW_MULTI_ATTACH=1`
(warn instead of refusing a second read-write attach of a named volume).
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

- **Listeners**: unix socket at `~/.micropod/docker.sock`, TCP on
  `127.0.0.1:45455`, and TCP on each vmnet gateway present on the host (the
  address guests reach the host at: `192.168.65.1` for the current default
  network, plus one per custom network) — never every interface. Gateways
  come from the runtime's network list and are followed as bridges come up
  (a gateway exists only while a guest is attached) and networks are
  deleted; a gateway listener only admits peers inside its network. The TCP
  listeners refuse browser requests (any `Origin` or `Sec-Fetch-*` header)
  and hosts other than IP literals, `localhost`/`*.localhost` and `docker`
  (DNS rebinding) with `403`. The unix socket is not reachable from a
  browser and has no such check.
- **Surface**: `_ping`, `/version`, `/info`, `/auth`, `/events`, images
  (pull/list/inspect/tag/delete/prune), `POST /build` (legacy builder),
  containers (list/create/inspect/
  start/stop/restart/kill/rm/wait/logs/stats/archive put+get/prune), exec
  (create/start with stdcopy hijack or detach/inspect), networks and volumes
  (list/create/delete/prune). Versioned client paths (`/v1.24/...`) are
  accepted; unknown list filters are rejected like real dockerd, so reapers
  can't accidentally match everything.
- **Ryuk interception** (generalised to any DinD client): any container
  bind-mounting `docker.sock` gets the bind stripped and
  `DOCKER_HOST=tcp://<gateway>:45455` (the container's network gateway)
  injected into its env, since the Apple
  runtime cannot pass a unix socket through virtiofs as a working socket.
  Ryuk additionally gets `8080/tcp` published. This is what lets the
  cuttlefish runner (which mounts `/var/run/docker.sock` for DinD task
  builds) work unchanged against the shim: `DOCKER_HOST=unix://~/.micropod/docker.sock`
  on the host, TCP over the VM bridge inside. A real ryuk container then
  connects back to the shim and reaps labeled resources — verified end to
  end: session filter ACK → victim deleted → bystander untouched →
  self-reap — plus a non-Ryuk DinD create test.
- **Read-through cache**: `list`/`inspect`/`images` are cached in memory
  (model + encoded-body tiers, 1 s TTL) with synchronous invalidation on
  every mutation through the shim and events-loop invalidation on observed
  transitions — warm `list` 39→2.5 ms, `images` 13→1.9 ms, out-of-band
  changes visible <1 s. `MICROPOD_SHIM_CACHE_DISABLE=1` opts out.
- **Concurrency**: the CLI client and all stateless services
  (`ContainerCLIClient`, container/image/volume/network/registry/machine/
  system compose/log services) are structs, so concurrent API calls run their
  CLI processes in parallel instead of queueing on an actor mailbox
  (`SystemService` keeps its CLI-version cache behind a lock that never spans
  an await). Independent reads are fetched concurrently (`/info` lists
  containers + images in parallel; `status()` races system-status against the
  cached version). Only genuinely stateful services stay actors
  (`StatsSampler` CPU deltas, `TerminalService` sessions).
- **Exit codes**: the Apple runtime does not report exit codes for stopped
  containers; the shim reports 0 for them unless an event captured one.
  Exec follows Docker/runc conventions: missing binary → 127, permission
  denied → 126 (recovered from the runtime's start-failure text), genuine
  exits pass through. Failing `container` CLI calls behind streams
  (pull/push/build) surface as errors instead of silent success.
- **Names & labels**: Docker-accepted container names the runtime rejects
  (>63 bytes, leading `_` — e.g. testcontainers' `reaper_<session>`) are
  deterministically aliased (`<prefix>-<hash>`, stable across restarts) with
  transparent lookup; `docker ps` shows the alias. `rename` is emulated as
  a state alias + tombstone (the runtime has no rename; compose recreate
  needs it). Network label *keys* are lowercased (the runtime rejects
  uppercase; containers/volumes accept it and stay exact). Missing images
  report Docker-shaped 404 `No such image` so clients' pull-on-demand flows
  (testcontainers Ryuk bootstrap) work unchanged.
- **Healthchecks**: the runtime has none — the shim supervises `Healthcheck`
  create bodies itself (exec probes on interval/timeout/retries/start-period
  cadence, Docker starting/healthy/unhealthy states in `State.Health`), so
  `depends_on: condition: service_healthy` and `docker compose --wait` work.
- **Custom networks**: subnets are allocated deterministically from 10.x
  when omitted (Apple auto-allocated ranges have no inter-container L3/DNS),
  and each network gets a managed `/etc/hosts` bind-mounted read-only into
  member containers (Docker name, ids, compose service, aliases; refreshed
  as membership churns) — plain `postgres`-style service DNS works.
- **TCP transport**: the shim serves TCP over BSD sockets (not
  Network.framework, whose `cancel()` is a no-op on live connections), so
  hijacked-stream EOF reliably terminates `docker start -a` / `logs -f`.
- **Events**: the hub emits create/start/die (with exit code)/destroy with
  Docker-shaped fields; containers absorbed as pre-existing-but-never-started
  are recorded `created` (the runtime reports them `stopped`), and fast
  exits during an in-flight attach are deferred, never dropped — so legacy
  API<1.30 clients waiting on `/events` (docker 26 `start -a`) terminate.
  Subscriptions are removed on disconnect, so idle subscribers can't pin
  the poll loop awake.
- **Resource hygiene**: `logs -f` kills its Apple CLI child when the stream
  ends (Apple's follow never exits on its own); exec/attach session pipes
  are closed deterministically at end-of-life; abandoned attach parks
  expire after 2 minutes. No Task, thread, fd, or child growth under
  sustained load.
- **Protocol hardening**: chunked request bodies are decoded, `Expect:
  100-continue` gets an interim response (Go SDK archive PUTs), keep-alive
  connections with pipelined-response ordering, unknown list filters are
  rejected like dockerd, name conflicts return 409, SIGTERM/SIGINT exit
  cleanly (killing live exec children), and exec children are killed when
  the client disconnects. HEAD responses omit their body (a body on HEAD
  desynchronizes keep-alive clients), and container IPs are reported without
  the runtime's CIDR suffix (`192.168.64.7/24` → `192.168.64.7`), which the
  Docker CLI refuses to parse in `docker port`/`inspect`.
- **docker build**: `POST /build` stages the uploaded context and delegates
  to `container build`, streaming progress back as buildkit-style NDJSON.
  Staging is content-addressed: the tar's file tree is hashed
  (paths + bytes, mtime-insensitive) and identical rebuilds reuse the
  retained extraction via an APFS `clonefile` (no-change rebuild of a 100 MB
  context: staging ~0.3 s instead of ~1.1 s; `touch`-only changes still hit).
  Retained contexts live under `~/.micropod/builds/cache`, LRU-capped
  (`MICROPOD_BUILD_CACHE_MAX_BYTES`, default 5 GiB, in-use builds pin;
  `MICROPOD_BUILD_CACHE_DISABLE=1` opts out). Misses stream the body
  straight into `tar`'s stdin (no intermediate `.tar` write).   Query
  passthrough covers `dockerfile`/`t`/`target`/`platform`/`buildargs`/
  `labels`/`nocache` plus `pull` (base refresh), `memory`, and `cpus`
  (raise above the 2-CPU builder default for heavy compiles).
  Use the legacy builder (`DOCKER_BUILDKIT=0 docker build …` /
  `docker compose build`): the CLI's BuildKit mode speaks gRPC (`POST /grpc`),
  which the shim does not proxy. Three runtime quirks are worked around:
  the extracted context must live under `$HOME` (the container CLI's file
  provider silently drops subdirectory contents for paths outside the home
  tree — `/tmp` and `/var/folders` contexts come out with empty dirs), the
  context's `.dockerignore` is stripped after extraction (the Docker CLI
  already applied it client-side, avoiding a second filtering pass), and
  large chunked uploads are parsed only
  once complete (waiting on the terminal `0\r\n\r\n` chunk / Content-Length
  keeps multi-hundred-MB uploads O(N) instead of O(N²)). Validated with
  real Go builds: `cuttlefish` `docker compose build controlplane` (~130MB
  context, full `go build`) and `runner`.
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
- **Performance** (`task bench-shim`, Apple `container` v1.3.1 vs Docker
  Desktop 29.7.2, 2026-09-07): API latency p50 — ping 0.4ms / list 14ms /
  inspect 14ms vs Docker Desktop 2.6/53/3ms (inspect stays a CLI round-trip;
  dockerd answers from memory);
  lifecycle p50 — create 32ms, start 541ms, exec 72ms, stop 80ms, rm 83ms
  (full roundtrip 0.8s vs Docker 2.8s, which pays a 2.2s stop grace).
  10-way concurrent lifecycles: 10.0s wall (was 18.4s before the
  struct-concurrency + create-fast-path work) vs Docker 3.5s — the remainder
  is Apple-runtime VM-start serialisation, not shim overhead.
- **Tests**: `MicropodDockerShimTests` (53 tests) drives the whole surface
  in-process against the mock CLI — parser (chunked/pipelined/versioned
  paths), filters, ryuk interception, stdcopy framing, lifecycle, hijacked
  exec, events, AutoRemove, keep-alive/pipelining, state persistence. `task
  e2e-real` adds `RealShimTests`: a real runtime end-to-end including a real
  ryuk reaper session (victim reaped, bystander untouched).

Configuration: `MICROPOD_SHIM_SOCKET` (default `~/.micropod/docker.sock`),
`MICROPOD_SHIM_TCP_PORT` (default 45455), `MICROPOD_SHIM_BRIDGE` (pins the
in-VM address instead of resolving each network's vmnet gateway),
`MICROPOD_CLI_PATH`.

## VirtualFS core (shares + build cache)

Docker Desktop's Pro-only **synchronized file shares** (cached host-directory
propagation) and **virtual file shares** (VirtioFS) are both reproduced without
a subscription — and both rest on one content-addressed substrate
(`Sources/MicropodSharedFS`, protobuf-free Swift, zero dependencies beyond
Foundation). Apple runtime already gives you VirtioFS for every bind mount
— Micropod adds the synchronized cache layer plus a content-addressed build
cache that speaks the same chunk-store addressing:

- **`micropod-sharedfs` daemon** (`task share-daemon`) — content-addressed
  chunk store (SHA256 / 256 KiB, dedup across views), APFS `clonefile`
  per-container views (writes isolated, reads share blocks), `FSEvents`
  host invalidation, write-back `sync` on unmount, `gc` of unreferenced
  chunks. Unix socket at `~/micropod/share-cache/socket`. Managed by
  launchd on install (`com.skunkworq.micropod-sharedfs`); every surface
  (shim, CLI, MCP) connects best-effort and falls back cleanly without it.
- **Build-context cache** — `POST /build` contexts are keyed by content
  tree-hash and retained under `~/.micropod/builds/cache` (LRU, 5 GiB,
  in-use pinning), each with a manifest of per-file chunk-store digests so
  sharing *between different contexts* is measurable (`shared-bytes`).
- **Automatic through the shim** — when `micropod-sharedfs` is running, every
  directory bind (`HostConfig.Binds` host path is a directory) is rewritten to
  its shared view; per-container views are tracked in `shim-state.json` and
  `sync`+`unmount` on container delete. Without the daemon, binds fall back
  to plain virtiofs.
- **CLI**: `micropod share mount <src> [--ro]`, `list`, `inspect <id>`,
  `sync <id>`, `unmount <id>`, `gc`, `daemon [--foreground]`;
  `micropod build-cache stats`, `inspect <hash-prefix>`.
- **MCP**: `share_mount`, `share_unmount`, `share_list`, `share_sync`,
  `share_gc`, `build_cache_stats` (27 tools total).
- **Validation**: `task ci-matrix` builds related Go/Node images and asserts
  context HITs, layer CACHED steps, mtime-proof re-hashing, and nonzero
  cross-context `shared-bytes`.

```sh
micropod share daemon &                  # or: task share-daemon
micropod share mount ~/myproj --ro       # optional explicit mount
micropod run -v ~/myproj:/app alpine ls /app   # shim auto-routes through shared view
```

Live writes in user space: every view and its source are watched with
`FSEvents` (file-level, 0.1s latency). Host edits are copied to all live
views sharing that source, and container writes are copied to the host and
then to sibling views — all per-file, hash-checked to avoid loops, and
backed by the chunk store for efficient block-level dedup. No root overlay
mount required; cross-container live sharing works through the host as a hub.
`--shared` mounts (`micropod share mount --shared` or `MICROPOD_SHAREDFS_LIVE=1`)
use a single shared view for the same source (all containers see the same
directory), while default per-container views keep writes isolated until
`sync`. `clonefile` dedup is the win for PHP/JS-style trees where
`node_modules` churn would otherwise copy per container.

#### How it works

```
Host src  ──FSEvents──►  Daemon  ──clonefile/ chunk──►  View(s)
   ▲                         │                              │
   └────────────── FSEvents ─┘◄── container writes ─────────┘
```

- **Chunk store** (`~/micropod/share-cache/chunks`, SHA256 / 256 KiB) dedups
  across all views. `gc` reclaims unreferenced blocks. Opt-in LZ4
  transcoding (`MICROPOD_SHAREDFS_TRANSCODE=1`) stores eligible blocks as
  self-describing frames under the same identity hashes: 2.7–5.9× density
  measured on Go build cache at full ingest speed, legacy files read
  through untouched.
- **Mount** tries APFS directory `clonefile` first (one syscall, CoW whole
  tree, respects `.dockerignore`/`.syncignore`), falling back to per-file
  `clonefile` with ignore filtering.
- **Live sync** is per-file, not full-tree re-clone. Each `FSEvents` file
  event copies only that file via `clonefile` (same volume) or chunk
  materialisation, hash-checked to avoid loops (temp files `.sb-*` ignored).
  Shared mounts are ref-counted — last `unmount` destroys the view.

#### Benchmarking

`task bench` covers the core runtime; `task bench-shim` covers the Docker
shim. For shared-fs:

```sh
task share-daemon &                     # start daemon
python3 /tmp/bench_sharedfs.py          # mount + live sync micro-benchmarks
```

Measured on M-series, APFS, daemon at `~/micropod/share-cache`
(2026-09-07 re-run — dir-clone fast path dominates; per-file fallback only
when `.dockerignore`/`.syncignore` forces filtering):

| Mount | Live sync host→view | view→host | Cross-container (host hub) |
|---|---|---|---|
| 10×1KB 28ms | 1KB ~100ms | 1KB ~85ms | ~100ms (FSEvents 0.1s latency dominates) |
| 100×1KB 26ms | 10KB ~100ms | 10KB ~85ms | — |
| 500×4KB 41ms (dir-clone) / 192ms (per-file w/ ignore) | 100KB ~100ms | 100KB ~85ms | — |
| 1000×1KB (was 4035ms per-file) | With dir-clone: 15ms/10 files, 106ms/100 files | | |

Shim overhead for a shared bind is one daemon mount (~30–40ms dir-clone)
instead of a CLI round-trip; plain directory binds without a cache label
stay on virtiofs (free, same as Docker's virtual file shares). Only
well-known cache paths (`/go/pkg/mod`, `~/.cache/go-build`, `~/.npm`,
`~/.cargo/registry`, … — extendable via `MICROPOD_SHIM_CACHE_PATHS` or the
`micropod.cache.sharedMounts` label) are routed through the daemon, so
cuttlefish-style DinD binds (`/var/run/docker.sock`, secrets dirs, inline
script files) pay no shared-fs cost: the socket is redirected to TCP (above)
and small host-dir/file binds stay on virtiofs.

## connect-go API (Go)

Protobuf-defined services in `proto/micropod/v1/*.proto` (regenerated by
`task proto` with `buf`), grouped one service per domain file:
ContainerService (CRUD + lifecycle + inspect/wait + log stream + stats +
exec), ImageService, VolumeService (incl. clone/commit), NetworkService,
ComposeService, SystemService. Bindings live in `sdk/go/gen`
(`micropodv1connect`); the Go SDK (`sdk/go`, `micropod.NewClient`) wraps
all six with retry, timeout and OpenTelemetry interceptors.

Two servers implement the contract. Both listen on 127.0.0.1:45454 and
[::1]:45454 (with the same Host / Content-Type / Origin admission), so run
one at a time:

| Server | Base URL | Wire | Backend |
|---|---|---|---|
| `MicropodAPI` (Swift, `task api`; what the app supervises) | `http://127.0.0.1:45454/api` | Connect unary + server streams, **proto-JSON only** | native XPC or `container` CLI ([docs/native-runtime.md](docs/native-runtime.md)) |
| `micropod-apiserver` (Go, `task api-go`, `api/cmd/micropod-apiserver`) | `http://127.0.0.1:45454` | Connect, gRPC, gRPC-Web; binary or JSON | `container` CLI only |

A client example (`micropod-ctl`) and a full connect/client server test
suite (`task api-go-test`) cover the Go server; `MicropodAPITests` drive the
Swift mount against the mock CLI.

Go client for the Swift server:

```go
import (
	"time"

	"connectrpc.com/connect"
	micropod "github.com/castlemilk/micropod/sdk/go"
	micropodv1 "github.com/castlemilk/micropod/sdk/go/gen/micropod/v1"
	"github.com/castlemilk/micropod/sdk/go/gen/micropod/v1/micropodv1connect"
)

// Replay only what is safe to repeat (see "Client rules" below). WaitContainer
// is a long poll that outlives this client's 10 s deadline: call it from a
// client without WithTimeout.
replayable := map[string]bool{
	micropodv1connect.SystemServicePingProcedure:              true,
	micropodv1connect.ContainerServiceListContainersProcedure: true,
	micropodv1connect.ContainerServiceGetContainerProcedure:   true,
	micropodv1connect.VolumeServiceListVolumesProcedure:       true,
}
policy := micropod.DefaultRetryPolicy()
policy.Idempotent = func(procedure string) bool { return replayable[procedure] }

client := micropod.NewClient("http://127.0.0.1:45454/api",
	micropod.WithConnectOptions(connect.WithProtoJSON()), // the Swift server decodes proto-JSON only
	micropod.WithTimeout(10*time.Second),                 // before WithRetry: one deadline across attempts
	micropod.WithRetry(policy),
)
ping, err := client.Ping(ctx, connect.NewRequest(&micropodv1.Empty{}))
// ping.Msg.Status: "running" | "stopped"; ping.Msg.RuntimeBackend: "native" | "cli"
```

What a job runner needs, beyond CRUD:

| RPC / field | Contract |
|---|---|
| `SystemService.Ping` | Cheap liveness (one XPC `ping` on native, one `container system status` on CLI, never `df`): `status` (`running`/`stopped`) and `runtime_backend` (`native`/`cli`). A stopped runtime is a status, never an error. `GetSystem` reports the same `status.runtime_backend` and answers `status: "stopped"` with empty disk usage instead of failing. |
| `ContainerService.GetContainer` | One container, `not_found` when absent. `exit_code` is filled from the native exit-code registry. |
| `ContainerService.WaitContainer{id, timeout_seconds}` | Server-side poll (default 30 s, cap 300 s) → `{exited, known, exit_code, state}`. `exited: false` means the timeout elapsed: call again. `known: true` only when the native backend recorded the exit; a container that is already stopped returns at once. The code can arrive while `state` is still `stopping`, and `CommitVolumeClone` needs `stopped`. Call `WaitContainer` from a client without `WithTimeout` (as the skill's [recipe 4](plugins/micropod/skills/micropod/SKILL.md#4-job-runner-in-go-connect-sdk-real-exit-codes-cloned-caches) does), or keep `timeout_seconds` below the client deadline; the server keeps polling for the full `timeout_seconds`. |
| `RunContainerRequest` `entrypoint`, `platform`, `workdir`, `user` | `docker run --entrypoint/--platform/--workdir/--user`. |
| `RunContainerRequest.no_pull` | A missing image (or one without the requested platform) is `not_found` naming the platform, instead of an unbounded server-side pull. Pull with `PullImage` under your own deadline, then create again. |
| `ExecRequest.arguments` | Verbatim argv; takes precedence over the whitespace-split `command`. |
| `StreamLogsRequest.skip_lines` | Re-open a log stream after a transport error without replaying the lines already delivered. |
| `GetStatsRequest.ids` | Sample only these containers (the native sampler skips the list call). |
| `ContainerStats.cpu_usage_usec` | Cumulative CPU time since start (µs, all cores), exact on every sample including the first (`cpu_percent` is a delta and reads 0 until a second sample). Native, CLI and Docker engines; 0 = not reported. |
| `ContainerStats.oom_kill_count` | Guest cgroup `memory.events` `oom_kill` (processes killed by the OOM killer since start). Native backend only; unset (proto3 `optional`) = not read, a set 0 = read and none. |
| `VolumeService.CloneVolume{source, name, size?, labels}` | New volume whose image is an APFS clone of the source's (O(1)). `failed_precondition` while the source is attached read-write to a running or stopping container. |
| `VolumeService.CommitVolumeClone{container_id, volume}` | Promote a stopped container's per-container clone to be the volume's image (fsync + atomic rename, serialised per volume). Returns `allocated_bytes`. Do not restart the container while its commit is in flight: `StartContainer` does not wait for the commit. Swift server only; the Go server answers `unimplemented` because it never creates clones. |
| `Volume.allocated_bytes` | Bytes the backing image really occupies (`st_blocks × 512`); `size_bytes` stays the provisioned size. |

Client rules:

- **Proto-JSON.** The Swift server decodes request bodies as proto-JSON
  and always answers `application/json`; a binary-protobuf body fails
  `invalid_argument`, and a binary client cannot decode the replies either.
  connect-go defaults to binary, so pass
  `WithConnectOptions(connect.WithProtoJSON())`.
- **Streams have no default deadline.** `WithTimeout` bounds unary calls
  only; `StreamContainerLogs`, `PullImage` and `ComposeUp` run until the
  caller's context ends or the server closes the stream with a Connect
  EndStream frame (`stream.Err() == nil` on a clean end).
- **Order interceptors.** `WithTimeout` before `WithRetry`; connect-go
  applies the first interceptor outermost, so reversed every attempt gets a
  fresh deadline.
- **Never replay a mutation.** The server cannot see a client give up: a
  `CreateContainer` that timed out client-side still completes. Leave
  `CreateContainer`, `RunContainer`, `CloneVolume` and `CommitVolumeClone`
  out of `RetryPolicy.Idempotent`; after `deadline_exceeded`/`unavailable`,
  `GetContainer` the name and adopt or delete it.
- **Codes.** `unavailable`: the runtime is not answering (XPC transport
  failure, runtime stopped, CLI missing), so back off and `Ping`.
  `not_found`: unknown container, volume or clone, or a missing image under
  `no_pull`. `failed_precondition`: wrong state (committing a container that
  is not `stopped`, a read-write volume already attached to a running
  container). `deadline_exceeded`: a CLI call hit its ceiling.

## Agent skills

The repo ships a **Claude Code plugin marketplace** — one command installs
the plugin, which registers the `micropod` MCP server (32 tools) and adds
the agent skill:

```
/plugin marketplace add castlemilk/micropod
/plugin install micropod@micropod
```

Outside Claude Code, the skill is at
[`plugins/micropod/skills/micropod/SKILL.md`](plugins/micropod/skills/micropod/SKILL.md)
— drop it into any agent's skills dir and register `micropod-mcp` in your
client's MCP config. `scripts/install.sh` also installs the skill to
`~/.claude/skills/micropod` alongside the app and binaries.

The skill covers the MCP tools, the Connect API (six `micropod.v1` domain
services), the `/v1/*` REST facade, the Docker Engine shim, and recipes for
cuttlefish-style worker orchestration + Testcontainers/Ryuk disposable test
containers. See [`docs/agent/micropod-skill.md`](docs/agent/micropod-skill.md).

## CI pipelines on micropod

The default `task ci` runs the Go and npm pipelines concurrently on a persistent Micropod Linux worker. The Go job runs vet, race tests, Testcontainers PostgreSQL and the built HTTP service. The npm job tests the package, runs the built image and verifies a source edit in a fresh build context. Each job cleans up its own containers and tags. The engine keeps downloaded layers and BuildKit package caches ready for the next job. [CI worker setup and measurements](docs/ci-worker.md)

`task ci-shim` exercises both pipelines against the isolated temporary Apple Docker shim, including its Ryuk redirection and legacy builder integration. The historical shim measurements were about 13 seconds for Go and 3.5 seconds for Node.

`task ci-matrix` (`ci/cache-matrix.sh`) validates the intelligent
build cache across a family of related builds — three Go services (two
sharing a dep set, one with its own) and three Node apps (same shape) —
reporting per build the context-cache HIT/MISS, the per-step CACHED/DONE
split parsed from the build log, and a run assertion on every image.
Deterministic checks: identical rebuilds HIT with layers CACHED,
touch-only rebuilds still HIT (mtime-proof tree hashing). Observed on a
cold-ish run: first Go service 3.5 s (fetches + compiles uuid) → sibling
with the same deps 1.7 s with zero shared layers (warm module/build
mounts), new dep set 2.5 s (genuine fetch); steady state ~1 s per rebuild.

## Compose startup benchmark
`task bench-compose` (`scripts/bench_compose_startup.sh`) starts an identical
postgres:16 compose stack via Micropod's compose pipeline (Apple runtime,
real healthcheck readiness) vs Docker Desktop (`up -d --wait`), reporting
wall time to ready. Warm runs on this box (2026-09-07, Apple `container`
v1.3.1 vs Docker Desktop 29.7.2): Micropod **~3.0 s**, Docker **~5.8–6.3 s**
(median of warm runs; cold first-pull excluded on both). The script is
portable to stock macOS (python3-based `timeout` fallback — macOS ships no
`timeout(1)`).

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
                                 #   crashed containers, port conflicts, native-arch,
                                 #   machine resources, disk, apiserver errors
$ micropod system logs --last 5m --level error   # backing apiserver logs
$ micropod compose up ./stack   # dependency-ordered compose up with health probes
$ micropod df                   # disk usage by category (+ reclaimable)
```

Global flags: `--json` (machine-readable), `--cli <path>` / `MICROPOD_CONTAINER_CLI_PATH`
(runtime override), `--no-color`. Exit codes: `0` ok, `1` failure (doctor exits non-zero
on failed checks), `2` usage error. Install via `task install` (ships to
`~/.local/bin/micropod` alongside `micropod-mcp`).
