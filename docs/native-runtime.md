# Native Runtime Backend

Micropod can talk to Apple's container runtime directly over XPC instead of
spawning a `container` process per operation. This document covers the
architecture, the wire protocol we reimplemented, version compatibility,
what stays on the CLI path, and how to test it.

## Why

Every `container` CLI invocation costs a process spawn + XPC round trip
(~15–80 ms measured). On hot paths — exec, logs, stats polling, lifecycle —
that dominates the actual work. The native backend keeps **one persistent
XPC connection** to `com.apple.container.apiserver` and issues the same
route calls the CLI does, so each op is a single XPC round trip with no
spawn, no argument parsing, and no output decoding.

It also unlocks things the CLI can't express:

- **Real exec exit codes** — `containerWait` returns the guest exit status
  directly; the CLI path had to infer success/failure.
- **Direct vminitd access** — the guest agent (gRPC over vsock :1024) is
  reachable via the `containerDial` XPC route, which hands back a host fd
  wired into the guest. Stats, signals, env, and process management without
  any CLI involvement.
- **A vsock bridge for Go/cuttlefish** — `GET /v1/containers/{id}/vsock/{port}`
  upgrades an HTTP connection into a raw duplex stream into the guest, so
  the Go apiserver and cuttlefish can run grpc-go against vminitd.

## Architecture

```
MicropodAPI / MicropodApp / DockerShim / CLI
        │
        ▼  (RuntimeBackendResolver — once at startup)
┌───────────────────┐     ┌────────────────────┐
│  native (auto)    │     │  cli (fallback)    │
│  MicropodRuntime  │     │  ContainerCLIClient│
│                   │     │                    │
│  APIServerClient ─┼─XPC─► container-apiserver│
│  XPCChannel       │     │  container spawn   │
│  NativeContainerService                     │
│  NativeLogStreamer│                         │
│  NativeStatsSampler                         │
│  GuestAgent ──────┼─fd──► vminitd :1024      │
│  (Containerization.Vminitd gRPC)            │
└───────────────────┘     └────────────────────┘
```

`RuntimeBackendResolver.resolve()` runs once at process start and returns a
`RuntimeServices` bundle (`containers`/`logs`/`stats` protocols + the raw
`APIServerClient` for the vsock bridge). Every consumer — `APIHandlers`, the
Docker shim `Router`, `AppDependencies`, `MicropodCLI` — takes the bundle,
so native and CLI are interchangeable at the protocol level.

### Backend selection

`MICROPOD_RUNTIME` controls the mode:

| value | behavior |
|-------|----------|
| `cli` | Always the CLI path. No XPC attempted. |
| `native` | Require native. Pings the apiserver; on failure logs a warning and falls back to CLI (the daemon may just be stopped). |
| unset / `auto` | Native if the `ping` handshake succeeds and reports a compatible version, else CLI. |

One special case: if `MICROPOD_CONTAINER_CLI_PATH` is set, `auto` stays on
CLI. An explicit CLI path means the caller deliberately chose a binary —
mock CLIs in the test suite, custom installs — and auto mode must not
silently bypass it. Only an explicit `MICROPOD_RUNTIME=native` overrides.

### Version gating

The `ping` route returns `apiServerVersion` (a banner like
`"container-apiserver version 1.3.1 (build: release, commit: a9a62e2)"` —
we extract the semver) and `apiServerCommit`. We accept `1.3.x` (verified
against installed `1.3.1`, commit `a9a62e2`). In `auto` mode an
unverified version falls back to CLI — the wire DTOs are versioned by us,
not versioned on the wire, so an unknown schema is a correctness risk
rather than a perf one. Explicit `MICROPOD_RUNTIME=native` proceeds
anyway with a stderr warning.

`GET /v1/system` reports the resolved backend (`backend`: `native`|`cli`)
plus `runtimeVersion`/`runtimeCommit` whenever the ping succeeded —
including on the version-gated CLI fallback, so you can see *why* the CLI
path was chosen.

## The XPC protocol

The apiserver speaks a simple protocol over `xpc_connection_t`:

- One `xpc_dictionary` per message. Key `route` carries a string like
  `"com.apple.container.apiserver.containerList"`.
- Payloads are JSON-Codable blobs under route-specific keys
  (`containers`, `id`, `containerConfig`, `exitCode`, `error`, …).
- File descriptors travel as `XPC_TYPE_FD` objects (stdio for exec,
  log handles for `containerLogs`, the vsock fd for `containerDial`).
- Replies carry either the result key(s) or `error` (a JSON
  `{"code":…,"message":…}` blob).

We hand-ported this (~`XPCChannel` + `APIServerProtocol` + `RuntimeDTOs`)
rather than linking `apple/container` because:

- Micropod pins Yams 5.x; `apple/container` needs 6.2.1.
- The full package pulls in containerization + grpc + nio for every
  product, when only `MicropodRuntime` needs it (and only for `Vminitd`).

The transport is `Sources/MicropodRuntime/XPCChannel.swift` — a Sendable
wrapper over `xpc_connection_t` with async/await replies, message
serialization matching Apple's `XPCMessage`/`XPCClient`, and fd passing.

### Routes used

| Route | Use |
|-------|-----|
| `ping` | version/commit handshake → backend selection |
| `containerList` | list (running/all/filtered) → `ContainerListEntry` transform |
| `containerState` | inspect — returns the managed container blob |
| `containerCreate` | create — `containerConfig` + `kernel` + `containerOptions` payloads |
| `containerBootstrap` | boot the VM for a stopped container |
| `containerStartProcess` | start the init process (`processId == containerId`) → flips state to `running` |
| `containerCreateProcess` + `containerStartProcess` + `containerWait` | exec — real exit codes, stdio via fd passing |
| `containerLogs` | returns `[containerLog, bootlog]` file handles — no `logs -f` spawn |
| `containerStop`, `containerKill`, `containerDelete` | lifecycle |
| `containerStats`, `containerDiskUsage` | cgroup stats, disk usage (also feeds `prune`) |
| `containerDial` | returns a host fd wired to a guest vsock port → vminitd, or the HTTP bridge |
| `containerExport`, `containerCopyIn/Out` | archive/copy |
| `getDefaultKernel` | host kernel DTO for `containerCreate` |
| `networkList` | `NetworkResource`s → builtin-network id for attachments |
| `volumeCreate`, `volumeInspect` | named-volume resolution for `-v` mounts |

A second XPC service, `com.apple.container.core.container-core-images`,
carries the image routes (`ImagesServiceClient`):

| Route | Use |
|-------|-----|
| `imageList` | local image lookup (normalized reference + annotation match) |
| `imagePull` | pull-if-missing, platform-scoped |
| `contentGet` | content-store path for a digest → OCI index/manifest/config decode |

### Native `create` / `run`

`create` reimplements the client side of `container create` (Apple's
`Utility.containerConfigFromFlags` + `Parser` semantics):

1. Load `~/.config/container/config.toml` defaults (cpus/memory/dns
   domain/registry domain).
2. Resolve the image — `imageList` match or `imagePull` (platform-scoped).
3. Walk index → manifest → config blob via `contentGet` for the OCI image
   config (env/entrypoint/cmd/user/workdir/stopSignal).
4. Build `initProcess` — Docker env merge semantics (image `K=V` entries,
   env files, request env; bare names inherit the host env only when
   present), entrypoint+argv merge, user/workdir, rlimits.
5. Mounts — tmpfs, virtiofs binds, named volumes via `volumeCreate`/
   `volumeInspect` (the `FSType` enum encodes `cache`/`sync` as nested
   case objects: `{"on":{}}`, `{"fsync":{}}`).
6. Networks — default attaches to the builtin network from `networkList`;
   `none` yields zero attachments.
7. `getDefaultKernel` for `SystemPlatform.current` (**linux/host-arch** —
   the server derives the init-image platform from it, so darwin here
   breaks the initfs lookup).
8. `containerCreate` with `autoRemove: false`.

`run` (detached only) = `create` + `containerBootstrap` +
`containerStartProcess(id, id)`; a failed bootstrap/start force-deletes
the container, matching the CLI.

Verified flag-for-flag against `container inspect` on CLI-created
containers (`NativeCreateIntegrationTests/testCLIvsNativeConfigParity`):
env/workdir/user/labels/mounts/ports/dns/caps/ulimits/shmSize/readOnly/
platform all produce identical stored configs.

**Gotchas found during bring-up** (all covered by tests):

- `dataNoCopy`-style payload reads return memory owned by the reply
  dictionary — `getDefaultKernel` must copy the bytes before returning,
  or `containerCreate` receives a dangling buffer (manifests as a
  `\0`-byte JSON decode error server-side).
- Memory units are *binary* (`64m` = 64 MiB, `mb`/`mib` equivalents —
  Apple's `Measurement.parse`), not decimal.
- Capabilities normalize to uppercase `CAP_*` (`ALL` passes through).
- `volumeInspect`'s reply is a flat `VolumeConfiguration`, not the
  `{id, configuration}` wrapper `container volume inspect` prints.
- Anonymous volumes (`-v /path`) get a UUID-hex name like the CLI.

### `prune` and `cp`

`prune` is client-side composition — `containerList(status: stopped)` →
`containerDiskUsage` → `containerDelete` — all native. `cp` parses
`id:/abs/path` refs exactly like `ContainerCopy` and drives
`containerCopyIn`/`containerCopyOut` directly.

### Cache-clone volumes and mount tuning

For CI-style workloads (cuttlefish jobs, package-manager caches) three
labels tune how `-v`/`--volume` mounts reach the VM:

- **`com.micropod.cache.clone=<vol1,vol2|*>`** — instead of attaching the
  named volume, its backing `.img` is APFS-`clonefile`d to
  `~/Library/Application Support/micropod/volume-clones/<id>/<vol>.img`
  (O(1) CoW, ~0.1 ms measured) and attached as a raw `.block` mount —
  identical server-side attach path, no volume-registry involvement.
  Each container gets the golden's content at ext4 speed with fully
  isolated writes; the golden is never touched. Clones are removed on
  `delete`/`deleteAll`/`prune` and on any create/run failure. The golden
  must already exist (`volumeInspect`, not get-or-create) — a typo'd
  name fails create rather than silently sharing a fresh volume.

- **`com.micropod.volume.sync=full|fsync|nosync`** — VZ disk-image sync
  mode on block/volume mounts. Clones default to `nosync` (scratch
  semantics: guest fsyncs never propagate to the host — right for
  ephemeral job volumes); named volumes default to `fsync` like the CLI.
- **`com.micropod.volume.cache=on|off|auto`** — VZ caching mode; `on`.

Clone lifecycle hardening:

- **Orphan sweep** — a cloning `create` or `prune` removes clone dirs
  whose container no longer exists (raw `container delete`, crashed
  runtime). Dirs younger than 60s are skipped so an in-flight create's
  dir can't be swept by a concurrent create before `containerCreate`
  registers it. `MICROPOD_VOLUME_CLONE_ROOT` overrides the clone root.
- **Golden in use** — if a running container still has a golden attached
  read-write, cloning proceeds but logs a warning to stderr: the clone
  is crash-consistent (journal replay on first mount), not a clean
  snapshot. Quiesce or stop the golden's consumer first.

Labels flow through the docker shim's `Labels` → `ContainerRunRequest`
unchanged, so `docker run --label com.micropod.cache.clone=ci-golden
-v ci-golden:/go/pkg/mod …` works end-to-end with no shim changes. Under
the CLI backend the label is ignored and the golden attaches directly —
safe for a single job, unsafe for concurrent RW attaches (nothing
guards multi-attach server-side), so treat clones as a native-only
feature.

### Volume policy — managing this without labels

The same knobs are exposed as a persisted **`VolumePolicy`** so app/API/
MCP users get clone fan-out without passing labels. One JSON file —
`~/Library/Application Support/micropod/volume-policy.json` — is read by
`NativeContainerService` at *every* create, so a change in the app is
live for the API server, docker shim, and MCP immediately (no restarts).
`MICROPOD_VOLUME_POLICY` overrides the path.

```json
{
  "cloneMode": "labels | goldens | all",
  "goldenVolumes": ["ci-golden"],
  "jobsOnly": false,
  "sync": "full | fsync | nosync",   // optional — absent = per-mount default
  "cache": "on | off | auto"
}
```

- `labels` (default) — only containers carrying
  `com.micropod.cache.clone` clone; everything else attaches directly.
- `goldens` — mounts of volumes named in `goldenVolumes` auto-clone.
- `all` — every named-volume mount auto-clones.
- `jobsOnly` — the policy applies only to `com.cuttlefish.job` /
  `com.micropod.job` containers; per-container labels still always apply.
- `sync` unset → named volumes `fsync`, clones `nosync`.

Precedence is always **container label > policy > mount default**.

Surfaces:

- **App** — Settings → "Volume Caching": clone-mode picker, golden list
  (with existing-volume suggestions), jobs-only toggle, sync/cache
  pickers. Saves on change.
- **HTTP API** — `GET /v1/config/volumes` returns the policy;
  `PUT /v1/config/volumes` replaces it (partial bodies merge onto
  defaults; bad enum values → 400). Response includes the label names
  for discoverability.
- **MCP** — `volume_policy` prints the current policy;
  `volume_policy_set` mutates it (`mode=`, `goldens=a,b`, `jobsOnly=`,
  `sync=` incl. `default`, `cache=`). Only provided fields change.

Example — CI golden fan-out for cuttlefish:

```sh
# 1. Prewarm once
container volume create ci-golden
docker run --rm -v ci-golden:/cache my-image sh -c 'go mod download …'

# 2. Policy: clone the golden for job containers only
curl -X PUT localhost:8080/v1/config/volumes -d '{
  "cloneMode": "goldens", "goldenVolumes": ["ci-golden"], "jobsOnly": true
}'
#    (or MCP: volume_policy_set mode=goldens goldens=ci-golden jobsOnly=true)

# 3. Jobs just mount it — no labels needed
docker run --label com.cuttlefish.job=$JOB_ID -v ci-golden:/go/pkg/mod …
```

Each job lands a fresh APFS clone (~0.1 ms), writes stay isolated, the
golden is never attached RW by two containers at once, and clones are
swept with the container. Policy changes apply to *new* creates only —
already-running containers keep their mounts.

### Operations that stay on the CLI

- Interactive / TTY `create`/`run`/`exec` — needs a real pty wired
  through `ProcessIO`; native exec is pipe-based.
- Non-detached `run` — attaches stdio and waits on the init process;
  the CLI owns that `ProcessIO` flow.

`NativeContainerService` delegates these to an internal `ContainerService`
(CLI) so the `ContainerServing` contract stays whole.

## vminitd over vsock

Every container VM runs `vminitd` as PID 1 — a gRPC server on vsock port
1024 implementing `SandboxContext` (`proto/com/apple/containerization/
sandbox/v3/SandboxContext.proto`, vendored from `apple/containerization`
0.42.0, matching installed `vminit:0.42.0`).

`containerDial(id, port)` returns a host fd connected to that port. On the
Swift side, `GuestAgent` wraps it in `Containerization.Vminitd` (the only
symbol we import from `apple/containerization`), giving typed access to
`statistics`, `getenv`, `waitProcess`, `kill(pid, signal)`, etc.

**fd ownership gotcha:** `Vminitd` stores the raw fd, not the `FileHandle`.
The handle returned by `dial` must be retained for the client's lifetime —
`GuestConnection` does this, closing the gRPC client before the fd.

### The HTTP bridge for Go / cuttlefish

`GET /v1/containers/{id}/vsock/{port}` on MicropodAPI responds `200` then
pumps bytes both ways between the HTTP connection and the dialed fd —
effectively a `net.Conn` into the guest. Go side:

- `api/internal/vsockdial` — dials the bridge, returns `net.Conn`
  (base URL from `MICROPOD_API_URL`, default `http://127.0.0.1:45454`).
- `api/internal/guestclient` — wraps it in `grpc.ClientConn` +
  `sandboxv3.SandboxContextClient` (generated from the vendored proto via
  buf into `sdk/go/gen/com/apple/containerization/sandbox/v3`).

That's how cuttlefish (or any Go consumer) reaches guest-agent RPCs
without XPC — it just needs the MicropodAPI base URL.

## exec semantics

Native `exec` creates anonymous pipes, passes the write ends as
`stdout`/`stderr` fd objects in `containerCreateProcess`, starts the
process, and waits on `containerWait` for the real exit code.

Output draining is deliberately **not** EOF-bound: the runtime helper's
fd can be inherited by unrelated processes spawned while it's open, which
postpones EOF indefinitely (observed live — a transient `docker` process
held our write end). Instead we:

1. Drain nonblockingly while the process runs.
2. After `containerWait` returns, keep draining up to 3 s (Apple's own
   CLI bounds its post-exit wait the same way).
3. Stop early after 300 ms of quiet — in-flight bytes arrive within
   milliseconds, so a typical exec adds ~0.3 s instead of 3.

Nonzero exit codes map to `MicropodError.cliFailure` with the guest's
stderr, preserving CLI-compatible error behavior. `execDetailed` exposes
the full `ContainerExecResult` (output/error/exitCode) to callers that
need the code — the MicropodAPI exec endpoint surfaces it as
`exit_code` in `ExecResponse`.

## Logging

`containerLogs` returns two file handles: index 0 is the container's
stdout/stderr log, index 1 is the boot/kernel log. `NativeLogStreamer`
keeps the requested handle open, tracks its own offset, and polls for
growth (~80 ms) — no `container logs -f` subprocess per stream.
`tail` applies to the initial backlog only; `boot: true` selects index 1.
Streaming stops when the container leaves `running` state.

## Stats

`containerStats` returns a cgroup-style snapshot per container
(memory usage/limit, CPU, pids, network, block I/O) mapped onto the
existing `ContainerStatsEntry`. `NativeStatsSampler` conforms to the same
`StatsSampling` protocol as the CLI sampler, so the UI/metrics path is
unchanged — each sample is one XPC call instead of a ~2.4 s
`container stats --no-stream` spawn.

## Protobuf/codegen

- `proto/com/apple/containerization/sandbox/v3/SandboxContext.proto` —
  vendored from containerization 0.42.0 (self-contained, `go_package`
  added).
- `proto/micropod/v1/api.proto` — `ExecResponse` gained `exit_code`.
- `buf generate` produces:
  - Go: `sdk/go/gen/com/…/sandboxv3` (+ connect stubs), `sdk/go/gen/micropod/v1`
    (+ grpc stubs).
  - Swift: `Sources/MicropodCore/Generated/` (micropod.v1 api.pb.swift;
    the sandbox stubs also land there, unused — `Vminitd` already carries
    its own generated client).

Regenerate after proto edits; never hand-edit generated files.

## Testing

- **Unit** (`Tests/MicropodRuntimeTests/RuntimeDTOTests.swift`): DTO
  decode against real 1.3.1 payload shapes, snapshot→`ContainerListEntry`
  transform (incl. the date-encoding asymmetry — XPC payloads use numeric
  dates, `--format json` uses ISO8601 strings), process-config patching,
  exec env append semantics, backend resolution modes.
- **Live** (`NativeRuntimeIntegrationTests.swift`, gated on
  `MICROPOD_REAL_E2E=1`): needs `container system start` + image pull.
  Covers ping/version, list parity with the CLI, exec output + real exit
  codes, env append, log tail, stats, sampler, native create +
  stop/start/kill/delete, raw vsock dial, and vminitd `getenv`/
  `statistics`. 11 tests, ~25 s.
- **Live create/run** (`NativeCreateIntegrationTests.swift`, same gate):
  23 tests, ~35 s. Detached-run lifecycle, failure cleanup (bad image,
  bad mount, duplicate name), env/workdir/user in-guest, entrypoint
  override via logs, labels/resources/dns/readOnly/caps/shmSize/ulimits
  in the stored config, tmpfs/bind/named-volume mounts, published-port
  config + real host→guest forwarding, `none` network, copy round-trip
  and ref validation, pull-if-missing (`hello-world`), native prune —
  plus a full `container inspect` parity diff against a CLI-created
  container with identical flags.
- **Live workloads** (`NativeWorkloadIntegrationTests.swift`, same gate):
  18 tests, ~35 s. Real images end-to-end: `postgres:16-alpine`
  (`pg_isready` + `psql select 42`), `nginx:alpine` over a published
  port (host→guest HTTP), `python:alpine` `http.server`, `alpine/git`
  image entrypoint, env-file, stdout/stderr separation, 200k-line exec
  output, concurrent execs and concurrent lifecycle, create-then-start,
  force-delete-running, restart config preservation, rejection of
  insufficient-memory/unknown-network creates, and cache-clone volumes:
  golden-content visibility, cross-clone + golden write isolation,
  `.block`/`nosync` config, clone-dir cleanup, missing-golden rejection.
- **Bench**: `MicropodBench` has a "Native backend vs CLI" section that
  runs matched ops through both paths and prints p50/p95/max/mean per
  side (list, inspect, exec, stats, 8× concurrent execs, run+delete
  cycle). It skips quietly when the apiserver isn't running.

## Performance expectations

Measured on an 18-core arm64 host against apiserver 1.3.1
(`MicropodBench`, p50):

| op | CLI path | native path | speedup |
|----|----------|-------------|---------|
| `container list` | ~16–30 ms | ~0.6–1 ms | ~25× |
| `container inspect` | ~17–27 ms | ~0.5–1.5 ms | ~25× |
| `stats` sample | ~2.1 s (fixed 2 s CLI window) | ~9–11 ms | ~200× |
| `exec` (echo) | ~50 ms | ~135 ms | ~0.4× (slower — see below) |
| `exec` ×8 concurrent | ~160–185 ms | ~355–470 ms | ~0.5× (same drain floor) |
| `run -d` + delete | ~850–890 ms | ~710–840 ms | ~1.1× (VM boot dominates) |
| cache mount: meta+IO workload¹ | virtiofs shared dir ~517 ms | ext4 volume ~178 ms; ext4 clone+nosync ~168 ms | ~3× over virtiofs |
| clonefile golden → clone | — | ~0.12 ms (256MB golden: ~0.13 ms) | O(1) CoW regardless of golden size |
| create+delete: clone vs plain volume | — | ~13.8 ms vs ~7.1 ms | clone adds ~7 ms (policy+list+inspect+copyfile) |
| clone create ×4 concurrent | — | ~43 ms wall (~11 ms each) | fan-out doesn't serialize |
| `logs -f` | one spawn per stream | file-offset polling, zero spawns | — |
| `stop`/`kill`/`delete` | spawn each | one XPC call each | ~15–25× spawn overhead removed |
| `cp` | spawn | `containerCopyIn/Out` round trips | ~15–25× |
| `prune` | spawn + list/delete spawns | same composition, zero spawns | ~15–25× |

¹ 500 small-file creates + full stat/read sweep + 64 MB write + `sync`
inside the mount — the metadata-heavy shape package-manager caches
produce. virtiofs pays a host round-trip per metadata op; ext4 virtio-blk
is guest-page-cached, and `nosync` additionally skips fsync→host.

Two notes on the numbers:

- **Stats is the headline win.** The CLI's `--no-stream` still samples
  CPU over a fixed 2 s window, so every sample costs ~2 s; the native
  path asks vminitd directly and returns in ~10 ms. For the app's poll
  loop this turns a 2 s+ subprocess per tick into an XPC call.
- **Exec is the one regression.** EOF on exec stdio pipes is unreliable
  (any process spawned while the apiserver holds the fd inherits a copy,
  so the pipe can stay open past process exit). The CLI bounds its EOF
  wait at 3 s; the native path drains with a 100 ms quiet window inside
  a 3 s cap, which puts a ~100 ms floor on every exec. Still correct —
  all output is captured — just slower than a spawn for trivial
  commands. Exec isn't on a hot polling path, so the trade is fine.

The wins compound where Micropod polls: stats sampling and log streams go
from subprocess-per-tick to fd/XPC-only. Concurrent lifecycle ops also
benefit — no process-spawn contention on top of the VM-boot contention.

## Failure/fallback matrix

- apiserver not running → `auto` resolves CLI; `native` warns + CLI.
- unknown apiserver version → CLI (`auto`); `native` proceeds anyway
  (explicit opt-in).
- image not local → `imagePull` (no timeout, same as the CLI).
- `run` failure after create → force-delete (same cleanup as the CLI).
- `containerDial` on a stopped container → runtime error (same as CLI
  `exec` on stopped).
- vsock bridge endpoint under the CLI backend → `501` (it's the only
  endpoint with no CLI equivalent — there is no `container dial` verb).
- TTY/interactive/non-detached flows → routed to the internal CLI
  service transparently.

## Known limitations / future work

- Exec/create/run TTY stays on CLI; non-detached `run` stays on CLI
  (both need `ProcessIO` semantics).
- No event subscription — `containerEvent` is declared in the route
  enum but has **no server handler at 1.3.1** (dead route). MicropodCore's
  poll-diff stays; revisit when the route is implemented upstream.
- Registry auth for `imagePull` rides on the apiserver's own credential
  handling — `insecure` is plumbed through but untested live.
- `--mount` structured syntax: `ContainerRunRequest` only carries the
  `-v`/`--tmpfs` forms today, so the `--mount type=…` parser branch
  (`Parser.mounts`) isn't ported.
