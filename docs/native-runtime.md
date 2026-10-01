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
        ▼  (RuntimeBackendResolver at startup; MicropodAPI re-resolves lazily)
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

`RuntimeBackendResolver.resolve()` runs at process start and returns a
`RuntimeServices` bundle (`containers`/`logs`/`stats`/`volumes` protocols,
the raw `APIServerClient` for the vsock bridge, and the native backend's
`ExitCodeRegistry`). Every consumer — `APIHandlers`, the Docker shim
`Router`, `AppDependencies`, `MicropodCLI` — takes the bundle, so native
and CLI are interchangeable at the protocol level. `MicropodAPI` keeps its
bundle in a `RuntimeHolder` so it can move from CLI to native without a
restart ([Backend hot-swap](#backend-hot-swap-micropodapi)); the other
consumers resolve once.

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
path was chosen. On the Connect API, `SystemService.Ping` and `GetSystem`
carry the live backend as `runtime_backend`.

### Backend hot-swap (MicropodAPI)

A `MicropodAPI` started before `container system start` resolves to CLI
under `auto` and would otherwise stay there, spawning a process per call
and never recording exit codes. It holds its bundle in a `RuntimeHolder`
and re-resolves lazily instead:

- `Ping` and `GetSystem` re-resolve before answering, at most once per
  10 s, with a 2 s ping ceiling so the caller is never held for long.
- A request that fails with an XPC transport error answers `unavailable`
  and then forces a re-resolve in the background, ignoring the interval.
- A native result swaps `containers`/`logs`/`stats`/`api`/`volumes` in one
  step and logs `micropod: runtime backend cli -> native (apiserver
  reachable)` to stderr. Requests already in flight finish on the bundle
  they started with; `runtime_backend` reports the new backend from the
  next call.
- Native is final while its XPC connection lives. When the connection is
  invalidated (the apiserver was unregistered, e.g. `container system
  stop`), the backend becomes replaceable again and the next re-resolve
  picks a fresh native connection or falls back to CLI.
- Concurrent callers share one in-flight resolution. A CLI result never
  replaces a CLI bundle, so `MICROPOD_RUNTIME=cli` and an explicit
  `MICROPOD_CONTAINER_CLI_PATH` under `auto` (the mock-CLI tests) still pin
  CLI for good.

Each native bundle owns its own `ExitCodeRegistry`. Containers started
before a swap have no registry entry, so `WaitContainer` reports their exit
with `known: false`.

### Transport errors → `unavailable`

`XPCConnection` reports every transport-level failure (a reply of error
type: connection interrupted, connection invalid, no reply) as
`MicropodError.transport`. An interrupted connection (apiserver restart)
recovers on the next send, as XPC does for launchd services. An
*invalidated* one never recovers, so the connection's event handler latches
it and every later call fails fast with `connection invalidated` instead of
waiting out the response timeout.

`ConnectCodeMapping` (MicropodCore) is the single error → Connect code
table used by the Connect mount:

| Error | Code |
|---|---|
| XPC transport failure, runtime-down CLI text (`apiserver is not running`, `not registered with launchd`, …), missing CLI | `unavailable` |
| CLI call over its ceiling | `deadline_exceeded` |
| stalled image pull | `aborted` |
| operation with no implementation on this backend | `unimplemented` |
| upstream `notFound:` / `invalidArgument:` / `exists:` (`alreadyExists:`) / `failedPrecondition:` … prefixes | the matching snake_case code |
| a `container` CLI failure, from the first `Error:` line of its stderr (verified against `container` 1.3.1) | `Error: <code>: "…"` reads through the same prefix table; `Error: internalError: "…" (cause: "<code>: …")` reads the cause (`container delete <missing>` prints `internalError: "failed to delete container" (cause: "notFound: "container with ID x not found"")` → `not_found`); the CLI's bare duplicate-id lines — `container create`: `Error: container already exists: x`, `container run`: `Error: container with id x already exists` — are `already_exists`. The error message keeps its "`cmd` failed (exit N): …" wrapper. `container exec` failures, and those of an attached `container run` (REST `detach: false`; Connect always runs detached), are never classified from stderr (it is the guest's; `execDetailed` reports exit code and text instead) |
| anything else | `internal` |

The REST facade answers `503` for transport errors. Clients should treat
`unavailable` as "back off and `Ping`", never as a server bug.

### Reads under contention

container-apiserver (1.3.x) answers reads from the same actors and locks
its writes hold:

- **Volume writes block every volume read.** A volume create formats its
  ext4 image on the `VolumesService` actor, under the volumes lock: 8 s
  for the default 512 GiB, minutes when several queue on a loaded host.
  `volumeInspect` and `volumeList` wait for all of it. A volume delete
  holds the volumes lock while it waits for the containers lock.
- **Container deletes block every container read.** A container delete
  (and an exit with auto-remove) runs `launchctl bootout` and removes the
  bundle synchronously on the `ContainersService` actor. So does
  `containerDiskUsage`'s walk. `containerList` and `containerStats` wait
  meanwhile.

On a CI rig these waits passed 10 s: creates failed with `XPC timeout for
com.apple.container.apiserver/volumeInspect` or `…/containerList`. Every
caller sent its own request and sent it again after its timeout. The late
replies were dropped, and the queue only grew.

`APIServerClient` now sends `containerList`, `volumeInspect`, `volumeList`
and `networkList` through `SharedReads` (`APIServerReads.swift`):

- **Single flight.** Identical reads in flight share one request.
  Container lists are keyed by their filters.
- **Callers give up, the request doesn't.** A caller waits for its
  `ReadPolicy` budget. The request waits up to 60 s, and callers that
  arrive meanwhile join it.
- **Read your writes.** Every write route invalidates what it may change
  once it settles. That includes a write that failed or timed out, since
  it may still land:
  - container lifecycle routes, including `containerWait` returning,
    invalidate container lists;
  - `volumeCreate` and `volumeDelete` invalidate volume lists and that one
    volume;
  - network create and delete invalidate network lists.

  A request sent before the write is neither joined nor remembered after it.
- **At most 4 requests in flight per route.** A queued request whose
  callers all gave up is dropped unsent.

| Policy | Budget | Answer may be | Used by |
|---|---|---|---|
| `live` (default) | 10 s | in flight or new | one-off reads, `startTracked`'s existence check |
| `patient` | 45 s | in flight or new | a write's own pre-checks: create's container list, clone and commit guards, volume lookups for mounts |
| `polling` | 10 s | ≤ 250 ms old; ≤ 30 s old if the budget runs out | `ListContainers`, `GetContainer` / exit waits, log-follow liveness, stats and volume lists |

`get(id:)` under `polling` is answered from the shared full list, so N
containers' exit waits and log follows cost at most four `containerList`s a
second, not N times their poll rate. A container missing from that list is
looked up directly: absence from a recent list is no proof that it is gone.

Two reads avoid the apiserver's locks altogether:

- **Volume configurations for mounts and clones** (`volumeConfig`,
  `getOrCreateVolume`) are remembered for 10 minutes. A volume's name,
  format and backing image never change while it exists. `volumeCreate`'s
  own reply seeds the entry, and every use checks that the backing image
  still exists. A clone of a golden therefore no longer waits behind other
  jobs' workspace volume formats.
- **`diskUsage(id:)`** walks `<appRoot>/containers/<id>` in-process (same
  measure as the apiserver). It falls back to the route when the app root
  is unknown.

**Observability.**

- `/metrics`, on MicropodAPI and the Docker shim, adds
  `micropod_apiserver_requests_total`:
  - `method="xpc"` rows per route and status (`504` = timed out), with
    latency in `…_request_duration_microseconds_total`;
  - `method="read"` rows with `status` = `sent`, `joined`, `remembered`,
    `stale`, `budget_exceeded`, `dropped`.
- Calls of 5 s or more log one line per route per 30 s:
  `micropod: apiserver volumeCreate answered after 120.2s (+4 more slow since, worst 125.6s)`.

**Load test.** `task apiserver-contention` runs
`scripts/apiserver_contention.py` against a scratch MicropodAPI. It runs
cuttlefish-shaped rounds in parallel with list, get and volume-list
pollers. A round creates a workspace volume, runs a container with cache
clones, waits for it, then deletes the container and the volume.

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
| `containerWait` (`processId == containerId`) | init-process exit code for the [exit-code registry](#exit-codes-waitcontainer-and-getcontainer), registered before `containerStartProcess` |
| `containerCreateProcess` + `containerStartProcess` + `containerWait` | exec — real exit codes, stdio via fd passing |
| `containerLogs` | returns `[containerLog, bootlog]` file handles — no `logs -f` spawn |
| `containerStop`, `containerKill`, `containerDelete` | lifecycle |
| `containerStats`, `containerDiskUsage` | cgroup stats, disk usage (also feeds `prune`) |
| `containerDial` | returns a host fd wired to a guest vsock port → vminitd, or the HTTP bridge |
| `containerExport`, `containerCopyIn/Out` | archive/copy |
| `getDefaultKernel` | host kernel DTO for `containerCreate` |
| `networkList` | `NetworkResource`s → builtin-network id for attachments |
| `volumeCreate`, `volumeInspect` | named-volume resolution for `-v` mounts |
| `volumeList`, `volumeDelete` | `NativeVolumeService` list/delete (the Connect `VolumeService` hot path — no `container volume` spawns) |

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
   A local image counts only if it holds the requested platform: its
   index lists the platform and `contentGet` finds that platform's
   manifest and config blobs. A pull pinned to one platform stores the
   whole index but only that platform's blobs, so a platform the index
   lists can still be absent. As in `ClientImage.fetch`, a blob that is
   `notFound` means "pull that platform"; any other `contentGet` failure
   fails the create. With `no_pull` (`RunContainerRequest.no_pull`) an
   absent image or platform fails `not_found` (`image X not present
   locally for linux/arm64`) instead of pulling: `imagePull` has no
   timeout, so callers that need a bounded create pull with `PullImage`
   under their own deadline and create again.
3. Walk index → manifest → config blob via `contentGet` for the OCI image
   config (env/entrypoint/cmd/user/workdir/stopSignal). Step 2 already
   read it, so the create reads each blob once.
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

`run` (detached only) = `create` + `containerBootstrap` + register the
exit-code waiter + `containerStartProcess(id, id)`; `start` does the same
for a created container. A failed bootstrap/start force-deletes the
container, matching the CLI.

A start whose `containerBootstrap` or `containerStartProcess` answers
`notFound: container with ID <id> not found` is looked into before the error
is returned. The apiserver answers bootstrap, startProcess and wait that way
only when the id is missing from its container table, which
`containerCreate` fills under the service lock before replying; a delete of
the id empties it. A created container stays `stopped` until startProcess
runs, so a plain `container delete` or a prune can take it between bootstrap
and startProcess. That is where the live defect-4 start failed: bootstrap
succeeded, then `containerStartProcess` and the exit-code waiter's
`containerWait` answered `notFound`. The apiserver keeps no tombstones, so an
id that never existed gets the same answer. After such an answer the
container is looked up again:

- **Not listed:** the start fails `not_found` at once and logs it; a real
  deletion is never retried or masked. The error says the container was
  deleted before it could start only when this process created it (`run`,
  or a native `create` recorded in `UnstartedCreates`, held until a start of
  the id has run or it is deleted or pruned, capped at 4096 ids). For any
  other id it says only that the runtime does not list it.
- **Still listed** (the id was deleted and created again in between): the
  whole start is retried after 50, 150 and 400 ms, each retry logged; a
  second bootstrap of a bootstrapped container is a no-op. After the last
  step the `notFound` stands.

A failed create removes exactly the clone images it placed, whatever the
failure: the clone directory is keyed by container id, so any other image
under it belongs to the create that won the name (a replay of the same
request, possibly already running on that image), and a replayed create
must not destroy the winner's clones. Each clone is placed with
`renamex_np(RENAME_EXCL)` under its volume's lock: the duplicate-id list
check is a snapshot, so a replay that lost the race can reach the clone
step after the winner placed — and started writing — its image; the
placement then fails `already_exists` instead of renaming a pristine
image over the winner's live block device, and a create that fails on its
second volume unlinks only the first one it placed (`CloneVolume`, whose
destination is the empty image the runtime just made, still replaces).
The lock is the one `DeleteVolume` and `volume prune` hold, so the golden
cannot be removed between the inspect and the clonefile.

Creates of the same id are mutually exclusive in the process
(`InFlightCreates.withExclusive`, a per-id FIFO async mutex like
`VolumeLocks`): the whole create — list check, orphan sweep, stale-dir
reclaim, clone placement, `containerCreate` and the failure cleanup — runs
under it, so a create is the *sole placer* under `<root>/<id>` for its
whole duration. A replay of the same request waits for the winner: if the
winner succeeded, the replay's list check answers `already_exists` before
it places or reclaims anything; if the winner failed, the replay finds the
dir the loser already cleaned and proceeds as a genuine create. A failed
`run` cleans up (delete + clone dir) under the same mutex — but the window
between `createNative` returning and the failed start's cleanup taking the
mutex is outside it: a replay of the id in that window is answered
`already_exists` for a container that is about to be deleted, and its
adopt path then finds `not_found`; inherent to the CLI's own run semantics
(create, start, delete on failure), not to the mutex.

The container name and every named volume are clone-path components
(`<cloneRoot>/<id>/<volume>.img`) and reach the clone-dir lifecycle —
orphan sweep, stale-dir reclaim, placement, failure removal — before the
runtime validates them, so the runtime's own grammars are enforced three
times over: at the API edge (Connect `invalid_argument`, REST 400) for
`CreateContainer`/`RunContainer` names and named volumes and for
`CloneVolume`/`CommitVolumeClone` names; by `createNative` before the
mutex and before any filesystem or XPC work; and inside every `VolumeClone`
function that builds a path from an id or a volume name, none of which
touches the filesystem for an unsafe one. A container id must match the
runtime's container-ID grammar, `[A-Za-z0-9][A-Za-z0-9_.-]{0,62}`
(`VolumeClone.requireSafeComponent`; `container` 1.3.1 takes 63 characters
and refuses 64+). A volume name must match the runtime's volume grammar,
`^[A-Za-z0-9][A-Za-z0-9_.-]*$` — the same characters with no cap of its
own (`container volume create` takes a 64-character name) — bounded only
by the filename limit. The clone `<name>.img` is placed through a staging
file beside it, `.<name>.img.tmp-<8 hex>`, 18 bytes longer than the name
(`VolumeClone.stagingOverhead`, derived from the format `tempPath` emits),
and that name must fit `NAME_MAX` (255 on APFS): 237 characters
(`VolumeClone.requireSafeVolumeName`, `maxVolumeNameLength`). A longer
name would pass every guard and then fail inside the placement with `File
name too long`, as `internal` rather than `invalid_argument`. The
container-id cap is deliberately not applied to volume names: a plain
`-v <name>:/x` attach of a long name (cuttlefish's
`cf-cache-<project>-<node>-<path>-<key>` volumes have no length bound)
reaches the CLI as it always did. Without the grammars, a name such as
`../../com.apple.container/volumes/<golden>` would make the stale-dir
reclaim unlink the golden's own `volume.img`. Both grammars are ASCII, as
the runtime's are (`container` 1.3.1 refuses `café` as a container id and
as a volume name); the Docker shim's `DockerNaming.isRuntimeValid` is the
container-id predicate, so a Docker name outside it is aliased to a
sanitised runtime name rather than passed through to that refusal. A dir
under the clone root whose name is outside the id grammar — only a
pre-guard build or a hand can put one there — is never a path this code
builds: the orphan sweep leaves it in place and says so on stderr. A
refusal's message echoes the value, so the Connect error body escapes every
control character (an unparseable 400 would reach a connect-go client as
`internal`).

A create that dies with its process (not one that fails — that cleans up)
leaves a clone dir with no container behind it. Finding no container of
its id in the list, a create reclaims such a dir whatever its age, so the
retry is not refused `already_exists` for a container that never was (the
Cuttlefish adopt path would then hit `not_found`); the mutex is what makes
that safe — without it a slow create being replayed could have its clones
unlinked by the reclaim. Residual: a create of the same id in flight in
*another* process on the same clone root is indistinguishable from a dead
one and its dir would be reclaimed — the orphan grace (below) does not
cover that case for the create's own id.

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

### `PullImage` pulls the host platform

`PullImage` still runs `container image pull`. With no `--platform` that
command fetches and unpacks every platform in the image index. For
`busybox:1.36.1` that was 52 blobs and 9 snapshots (about 10 GiB
allocated), and a pull took 42 s p50 through Connect on a loaded rig.
Only one of those snapshots is ever run, because create defaults to
`linux/<host arch>`.

A pull with no `platform` (unset or empty) now uses the same default:
`--platform linux/arm64` on Apple silicon. This covers the Connect
`PullImage`, `POST /v1/images/pull` (which now takes an optional
`platform`), the Docker shim, the MCP tool, compose and the
`micropod image pull` CLI, because all of them call `ImageService.pull`.
The same busybox pull then fetched 4 blobs and wrote 1 snapshot
(1.1 GiB), and took 10.6 s p50 in the same window. A platform the caller
sends is passed through unchanged, so a job pinned to `linux/amd64`
pulls `linux/amd64`. Containerization's `Platform` equality treats
`arm64` and `arm64/v8` as the same platform, so `linux/arm64` matches
index entries written either way.

An image with no host variant still pulls as it did before. On an arm64
host there are two cases, both in containerization 0.42.0, the version
`container` 1.3.1 ships:

- A single-manifest `amd64` image fails the pinned import with
  `does not support required platforms`.
- An index with no `arm64` entry imports, then fails the unpack with
  `unsupported platform linux/arm64`.

When a pull used the default and its output shows either message, it
emits `<ref> has no linux/arm64 variant; pulling every platform it has`
and retries once with no `--platform`. The CLI prints the error as it
exits, so `ContainerCLIClient.stream` now waits (up to 500 ms) for both
pipes to close before it finishes. Before, a fast exit could end the
stream before its last lines were delivered.

The retry leaves the store as the unpinned pull did, so creates behave
as before: no platform still fails on such an image, and
`platform: linux/amd64` finds its variant local, even under `no_pull`.
A platform the caller sent is never widened, and no other failure
triggers the retry. For a single-manifest image the pinned attempt
downloads the layers before it is refused, so that pull fetches them
twice.

Callers see a change only when they create a multi-arch image for a
non-host platform. A pull with no platform still stores the whole index,
which lists every variant, but it stores only the host variant's
manifest, config and layers. Create checks for those blobs (step 2 of
native `create`), so the other variants count as not local:

- Without `no_pull`, the create pulls the requested platform first, as
  `container run --platform` does. `docker pull alpine` followed by
  `docker run --platform linux/amd64 alpine` works as it did before, but
  the run now pays for that pull.
- With `no_pull`, the create is `not_found` with `image X not present
  locally for linux/amd64`.

To avoid both, send `PullImage` the same `platform` as `CreateContainer`
(step 3 of the Go pattern below). The CLI backend already behaved this
way: `container image list` reports only variants whose blobs are
stored, and `container create` pulls a missing platform itself.

### `prune` and `cp`

`prune` is client-side composition — `containerList(status: stopped)` →
`containerDiskUsage` → `containerDelete` — all native. The runtime lists a
created, never-started container as `stopped`, just like an exited one, so
`prune` skips a container with no start date created in the last five
minutes: a prune landing between a client's create and its start (the
Connect `CreateContainer` → `StartContainer` pair, `docker run`) would
otherwise fail that start `not_found`. The next prune after the grace takes
an abandoned create. Docker's own `container prune` removes `created`
containers at once; the grace is a deliberate, bounded departure from that.
Only the native backend applies it: the CLI backend's `prune` (always used
by the MCP server, and by the app, the shim and the API when the native
backend is unavailable) runs `container prune`, which deletes never-started
containers too. `cp` parses
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

- **Clone dir goes with the container** — `delete`, `deleteAll` and
  `prune` remove the deleted containers' clone dirs on both backends
  (`VolumeClone.removeClones` in MicropodCore, each image under its
  volume's lock; the CLI backend diffs `container list` before/after a
  bulk delete). The runtime's ids are its names, so a stale dir would
  otherwise be inherited by the next container of that name and
  `CommitVolumeClone` would promote a dead container's bytes. On both
  backends the dir is removed only after the runtime's delete succeeded,
  so a container already removed by a raw `container delete` (the CLI
  answers `not_found`, from its `(cause: "notFound: …")`) keeps its clone
  dir until the next orphan sweep (below) takes it — and a same-name
  container created in between cannot promote it, as `CommitVolumeClone`
  requires the container to mount the clone.
- **Orphan sweep** — a cloning `create` or `prune` removes clone dirs
  whose container no longer exists (raw `container delete`, crashed
  runtime). Dirs younger than 60s are skipped so an in-flight create's
  dir can't be swept by a concurrent create before `containerCreate`
  registers it — except the dir of the sweeping create's own id, which
  no other create in the process can be placing under (the per-id create
  mutex, above).
  `MICROPOD_VOLUME_CLONE_ROOT` overrides the clone root.
- **Volume prune under the locks** — `volume prune` runs holding every
  volume's lock (sorted acquisition), so it never removes a golden's
  directory between a commit's checks and its rename. `CloneVolume`
  holds the source's and the new name's locks (sorted) and a cloning
  create holds each golden's lock across inspect + clonefile, so a prune
  can take away neither a golden nor a half-made clone volume under
  them. What no lock changes: goldens attached only through clone mounts
  look *unattached* to `container volume prune`, so an operator prune
  removes every cache golden — retire goldens with `DeleteVolume`, not
  with prune.
- **Golden in use** — if a running (or still stopping) container has a
  golden attached read-write, a clone *mount* at create proceeds but logs
  a warning to stderr: the clone is crash-consistent (journal replay on
  first mount), not a clean snapshot. Quiesce or stop the golden's
  consumer first. The `CloneVolume` RPC is stricter and refuses (below).
- **Commit locks** — every clone image is removed under its volume's
  in-process lock (`VolumeLocks`), the same lock `CommitVolumeClone` and
  `DeleteVolume` take, so a delete never unlinks a clone mid-commit.

Labels flow through the docker shim's `Labels` → `ContainerRunRequest`
unchanged, so `docker run --label com.micropod.cache.clone=ci-golden
-v ci-golden:/go/pkg/mod …` works end-to-end with no shim changes. Under
the CLI backend the label is ignored and the golden attaches directly;
the [multi-attach guard](#read-write-multi-attach-guard) then refuses a
second concurrent job instead of letting two VMs share one ext4 image.
Treat clones as a native-only feature.

### `CloneVolume` and `CommitVolumeClone`

Two Connect RPCs (`VolumeService`) turn the clone machinery into an
explicit golden-volume workflow: goldens are never attached, every job
mounts a clone, and a successful job's clone becomes the next golden.
Both backends of `MicropodAPI` implement them (the file work is the same
`VolumeClone` code; only list/create/delete differ). The Go apiserver
implements `CloneVolume` and answers `unimplemented` for
`CommitVolumeClone`, because it never creates per-container clones.

- **`CloneVolume{source, name, size?, labels}`** creates `name` (size
  defaults to the source's provisioned size, labels gain
  `com.micropod.clone-of=<source>`), then APFS-clones the source's
  `volume.img` over the new volume's image through a temp file + rename.
  O(1) regardless of size; the two images share blocks until written.
  `not_found` when the source does not exist; `failed_precondition` while
  a running or stopping container has the source attached read-write (the
  clone would be crash-consistent); `invalid_argument` for `source ==
  name`. A failed copy deletes the half-made volume, so an empty image never
  masquerades as a cache under the new name.
- **`CommitVolumeClone{container_id, volume}`** promotes the container's
  clone (`volume-clones/<container>/<volume>.img`) to be the volume's
  backing image. Under the volume's lock it requires the container to be
  `stopped` (`stopping` is not stopped: the VM may still be flushing)
  and the volume not attached read-write to a running or stopping
  container (`failed_precondition`); a missing container, clone or
  volume is `not_found`, and so is a clone the container's configuration
  does not mount (no mount whose source is the clone's path): a file left
  under the id by an earlier container of that name — a raw `container
  delete` keeps the dir, and a same-name container created directly on
  the golden inherits it — is never promoted; only the container that
  mounts a clone can. It then fsyncs the clone, makes a CoW twin next
  to the golden, fsyncs it, `rename(2)`s it over `volume.img` and fsyncs
  the directory. Readers see the old image or the new one, never a partial
  one. The clone itself stays where the container's configuration points,
  so the container is still startable and its clone goes with it on
  delete. Staging files a crashed commit left behind are swept on the next
  commit. Concurrent commits to one volume are serialised; the last one
  wins. The response carries the promoted image's `allocated_bytes`.
  `StartContainer` does not take the volume's lock, so the `stopped` check
  cannot hold a restart off: do not restart the container while its commit
  is in flight, or the promoted image may be a crash-consistent copy of a
  clone that was being written.
- **`Volume.allocated_bytes`** is `st_blocks × 512` of the backing image:
  real usage, where `size_bytes` is the provisioned (sparse) size. A fresh
  clone reports its source's full allocation (APFS counts shared extents),
  so golden and clone figures overlap and must not be summed.

Fixed-size ext4 images only grow; a golden that fills up shows as ENOSPC
inside the cache path. Size goldens generously at creation (`size`), and
evict or re-create them from the client side.

### Read-write multi-attach guard

An Apple named volume is an ext4 image attached to the VM as a block
device, and the runtime does not stop two containers from attaching the
same image read-write. That corrupts it. Both backends now refuse
a direct (non-clone) attach of a named volume that a running or stopping
container holds read-write, with `failed_precondition` and a message
naming the volume and the holder:

```
failedPrecondition: volume 'ws' is attached read-write to running container 'job-41'
```

Clone mounts are exempt (they never touch the golden). The check reads
the container list; if that call fails the create fails with its error
(`unavailable` when the runtime is not answering) rather than reasoning
from an empty list. A replayed create of an existing container gets the
runtime's duplicate-id refusal (`already_exists`), never a guard error
naming the caller as the holder of its own volumes.
`MICROPOD_ALLOW_MULTI_ATTACH=1` restores the old behaviour: attach anyway
and log a warning to stderr.

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
curl -X PUT http://127.0.0.1:45454/v1/config/volumes -H 'Content-Type: application/json' -d '{
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

`ExecRequest.arguments` is the argv, passed through verbatim
(`["sh", "-c", "echo a  b"]` keeps its quoting and double space). The older
`command` string is split on whitespace and is used only when `arguments`
is empty; a request with neither is `invalid_argument`.

## Exit codes, `WaitContainer` and `GetContainer`

Apple's `ContainerSnapshot` has no exit-code field: a stopped container is
`{state: "stopped", startedDate, networks}`. The only source is the
`containerWait` route, answered by the container's runtime helper, which
exists only while the container does. So the native backend keeps an
**exit-code registry** (`ExitCodeRegistry`, one per native bundle):

1. `run`/`start` call `containerBootstrap`, then register a detached
   waiter task (`containerWait(id, id)`), then `containerStartProcess`. The
   helper's `ExitWaiter` accepts pre-registered waiters and replays a
   cached status, so a container that exits within milliseconds of
   starting still reports its code.
2. The waiter records `{exit_code, exited_at}`. A waiter that fails
   (transport error) or outlives the 2 h ceiling records an *unknown*
   code.
3. `DeleteContainer` (and prune) cancel the waiter and drop the entry. A
   restart re-registers, so an old run's code is never reported for a new
   one.

Readers never block on XPC in the request path:

- **`GetContainer`** returns one container (`not_found` when absent) with
  `exit_code` filled from the registry; `ListContainers` does the same.
- **`WaitContainer{id, timeout_seconds}`** waits up to `timeout_seconds`
  (0 → 30, capped at 300). A container the registry tracks parks on it and
  wakes the moment its exit is recorded, re-reading the runtime state every
  1 s as a safety net; any other (the CLI backend, CLI-created containers,
  ones started before a restart, a wait that beat `track`, or an entry whose
  waiter aged out) has its runtime state polled every 150 ms. A registry
  code returns at once as `{exited: true, known: true, exit_code}`, even if
  the snapshot has not flipped to `stopped` yet.
  `running`, `stopping` and `created` are non-terminal. Any other state
  (`stopped`, or `unknown` when the container vanished mid-wait) returns
  `exited: true, known: false`. A failed inspect alone never counts as
  vanished: the wait re-lists, so a runtime that stops answering mid-wait
  fails the call `unavailable` instead of reporting a false exit. When the
  timeout elapses first it returns `exited: false`, and the caller
  re-issues. An unknown id is `not_found` up front.

`known: false` is expected for containers this API process did not start
(the shim, the app, the CLI, before a backend swap or an API restart), on
the CLI backend, and after the 2 h ceiling. Callers must treat it as
"exited, code unavailable", never as success. The Go apiserver has no
registry: its `WaitContainer` polls `container inspect` and always
reports `known: false`.

## Logging

`containerLogs` returns two file handles: index 0 is the container's
stdout/stderr log, index 1 is the boot/kernel log. `NativeLogStreamer`
keeps the requested handle open, tracks its own offset, and drains new
bytes every 80 ms — no `container logs -f` subprocess per stream.
`tail` applies to the initial backlog only; `boot: true` selects index 1.

- **Stop signal.** A recorded exit code in the exit-code registry, or a
  runtime state that is neither `running` nor `stopping` (a stopping
  container is still writing its tail). The registry is consulted on
  every quiet tick; the runtime state is checked after the backlog, then
  250 ms after the latest bytes, backing off ×2 to 1 s while the stream
  stays quiet.
- **Final drain.** After the stop signal the file is drained once more
  before the stream ends, so bytes written between the last tick and the
  exit are delivered. A stream opened on an already-stopped container
  returns the whole backlog and ends cleanly.
- **Lines.** Output is split on `\n`; empty lines are dropped, and stdout
  and stderr arrive merged (the log file does not separate them). A final
  fragment without a newline is emitted when the stream ends.
- **Resuming.** `StreamLogsRequest.skip_lines` drops that many lines from
  the start of the stream (after `tail`), so a client re-opening after a
  transport error gets only lines it has not seen.

The Connect mount waits for the final frame to be written before closing
the connection, so connect-go clients see the EndStream frame and a clean
`stream.Err() == nil` rather than `unexpected EOF`.

## Stats

`containerStats` returns a cgroup-style snapshot per container
(memory usage/limit, CPU, pids, network, block I/O) mapped onto the
existing `ContainerStatsEntry`. `NativeStatsSampler` conforms to the same
`StatsSampling` protocol as the CLI sampler, so the UI/metrics path is
unchanged — each sample is one XPC call instead of a ~2.4 s
`container stats --no-stream` spawn. `GetStatsRequest.ids` restricts a
snapshot to the named containers; the native sampler then skips the
`containerList` call and asks `containerStats` for those ids only.

## Protobuf/codegen

- `proto/com/apple/containerization/sandbox/v3/SandboxContext.proto` —
  vendored from containerization 0.42.0 (self-contained, `go_package`
  added).
- `proto/micropod/v1/api.proto` — `ExecResponse` gained `exit_code`.
- `proto/micropod/v1/{container,volume,system}.proto` — the Go-client
  additions: `GetContainer`, `WaitContainer`, `Ping`, `CloneVolume`,
  `CommitVolumeClone`, `RunContainerRequest` entrypoint/platform/
  workdir/user/`no_pull`, `ExecRequest.arguments`,
  `StreamLogsRequest.skip_lines`, `GetStatsRequest.ids`,
  `Volume.allocated_bytes`, `SystemStatus.runtime_backend`.
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
- **Unit, Connect-client hardening**: in `MicropodRuntimeTests`,
  `ExitCodeRegistryTests` (fast waiter, restart supersedes, delete
  cancels, ceiling or a throwing waiter → unknown), `NativeLogStreamerTests`
  (final drain, backlog of an already-stopped container, registry stop
  signal, state-check backoff, `stopping` still followed),
  `RuntimeHolderTests` (rate limit, CLI → native swap then no re-resolve,
  `force`, shared in-flight resolution, invalidated native re-resolved),
  `NativeCreateGuardsTests` (`no_pull` names image and platform, a failed
  create removes only the clones it placed, placement waits for the
  volume lock, same-id creates are mutually exclusive and the id is
  released on a throw), `ImageEnsureTests` (a scripted images service
  holding a host-only pull: a platform the index lists without its blobs
  is pulled for that platform, or `not_found` naming it under `no_pull`;
  the stored platform resolves with no pull; a non-`notFound` read
  failure propagates) and `StatsSamplingIDsTests`;
  in `MicropodCoreTests`, `ConnectCodeMappingTests` (transport and
  runtime-down → `unavailable`), `SystemStatusStoppedTests`,
  `VolumeCloneTests` (clonefile, atomic commit, staging sweep, per-volume
  locks) and `ImagePullPlatformTests` (a scripted CLI: no or empty
  platform pins `linux/<host arch>`, a given one passes through, both
  missing-platform failures retry once unpinned, a given platform or any
  other failure is not retried) and `ContainerCLIClientTests` (450 short
  processes streamed at once all deliver the line they print at exit).
- **API, mock CLI** (`MicropodAPITests`, `VolumeDeleteLockTests`): the
  Connect surface end-to-end against the spawned `MicropodAPI` binary:
  `Ping` running and stopped (fast), `GetContainer`, `WaitContainer`
  (stopped, running → timeout, unknown id, vanished mid-wait, runtime
  stopped mid-wait → `unavailable`), `RunContainer` argv for
  entrypoint/platform/workdir/user, `no_pull` without an `image pull`,
  the `image pull` platform for `PullImage` and the REST pull (host when
  unset, the given value when set), `Exec` argv, `skip_lines`, `GetStats`
  ids, `CloneVolume` (clone, source in use), `CommitVolumeClone` (no clone, running container,
  promotion), the multi-attach guard and its replay exemption,
  delete-vs-commit serialisation, Connect error reason phrases and the
  EndStream frame (flag `0x02`) on server streams.
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
| `exec` (echo) | ~50 ms | ~10–45 ms² | ~1.1–5× (see below) |
| `exec` ×8 concurrent | ~160–185 ms | ~355–470 ms² | ~0.5× (measured with the old drain floor) |
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

² The single `exec` row is 15 live `execDetailed` calls against a shared
apiserver after O15 (EOF-ended collection); the ×8 row predates it.

Two notes on the numbers:

- **Stats is the headline win.** The CLI's `--no-stream` still samples
  CPU over a fixed 2 s window, so every sample costs ~2 s; the native
  path asks vminitd directly and returns in ~10 ms. For the app's poll
  loop this turns a 2 s+ subprocess per tick into an XPC call.
- **Exec ends on EOF.** Native exec used to drain with a 100 ms quiet
  window after the exit (~135 ms p50 for `echo`), because EOF on the
  stdio pipes seldom arrived: `XPCMessage.set(key:value: FileHandle)`
  handed `xpc_fd_create` an extra `dup` it never closed, but
  `xpc_fd_create` dups the fd itself, so every exec leaked a write end
  of each pipe in this process. Without that leak (and with the pipes
  close-on-exec) EOF lands within ~0.2 ms of `containerWait`, and
  `ExecOutputCollector` returns on it. A pipe some other holder keeps
  open still ends after a 25 ms quiet drain following the exit, inside
  ProcessIO's 3 s cap.

The wins compound where Micropod polls: stats sampling and log streams go
from subprocess-per-tick to fd/XPC-only. Concurrent lifecycle ops also
benefit — no process-spawn contention on top of the VM-boot contention.

## Failure/fallback matrix

- apiserver not running → `auto` resolves CLI; `native` warns + CLI.
  `MicropodAPI` re-resolves on `Ping`/`GetSystem` (≤ once per 10 s) and
  swaps to native once the apiserver answers.
- apiserver stops or restarts under a native `MicropodAPI` → calls fail
  `unavailable`; an invalidated connection fails fast and triggers a
  re-resolve; `Ping` answers `status: "stopped"` meanwhile.
- unknown apiserver version → CLI (`auto`); `native` proceeds anyway
  (explicit opt-in).
- image not local, or its index lists the platform but the platform's
  blobs are not stored → `imagePull` of that platform (no timeout, same
  as the CLI), or `not_found` with `no_pull`.
- `PullImage` with no platform on an image without a `linux/<host arch>`
  variant → one retry with no `--platform` (every platform, the old
  behaviour); a given platform fails as the CLI does.
- `run` failure after create → force-delete (same cleanup as the CLI).
- exit code not recorded (container not started by this API process,
  CLI backend, 2 h ceiling) → `WaitContainer` `known: false`.
- second read-write attach of a named volume → `failed_precondition`
  (`MICROPOD_ALLOW_MULTI_ATTACH=1` warns instead).
- `CommitVolumeClone` on a `running`/`stopping` container or an attached
  golden → `failed_precondition`, golden untouched.
- `containerDial` on a stopped container → runtime error (same as CLI
  `exec` on stopped).
- vsock bridge endpoint under the CLI backend → `501` (it's the only
  endpoint with no CLI equivalent — there is no `container dial` verb).
- TTY/interactive/non-detached flows → routed to the internal CLI
  service transparently.

## Using it from Go (cuttlefish)

cuttlefish's macOS agent runs job attempts through the Connect API with
the Go SDK (`github.com/castlemilk/micropod/sdk/go`) instead of `docker`
against the shim. The pattern, for any Go job runner:

1. **Detect.** `Ping` at `http://127.0.0.1:45454/api` (the Swift server's
   mount; the Go apiserver serves the same RPCs at the root). Use the
   Connect path only when `status == "running"` and `runtime_backend ==
   "native"`: on `cli` there are no exit codes and no clones.
2. **Clients.** Build every client with
   `WithConnectOptions(connect.WithProtoJSON())`. Unary reads get
   `WithTimeout` then `WithRetry` with an `Idempotent` allow-list (`Ping`,
   `GetSystem`, `ListContainers`, `GetContainer`, `GetStats`,
   `ListVolumes`, …). `WaitContainer` is a long poll: the server keeps
   polling for the full `timeout_seconds`, so call it from a client without
   `WithTimeout` (or keep `timeout_seconds` below the client deadline).
   Mutations get a per-call deadline and no retry. Streams get neither and
   run under the attempt's context.
3. **Create.** `CreateContainer{no_pull: true, entrypoint, platform,
   memory, volumes, labels}`. Always send `memory`: otherwise the
   runtime's `config.toml` default applies (1 GiB out of the box). Cache
   volumes are goldens mounted through `com.micropod.cache.clone=<golden,…>`,
   so the job writes to a private clone. On `not_found`, `PullImage` under a bounded context, then create
   once more. Give `PullImage` the create's `platform`; with none it
   pulls only `linux/<host arch>`. On `deadline_exceeded`/`unavailable`,
   do not re-send: `GetContainer` the name, then adopt it or
   `DeleteContainer{force}`.
4. **Run.** `StartContainer`, then concurrently `WaitContainer` (re-issued
   while `exited: false`) and `StreamContainerLogs`. If the log stream
   drops with `unavailable`, `Ping` until the API is back and re-open with
   `skip_lines` = lines received so far. `GetStats{ids: [id]}` samples just
   this container.
5. **Exit code.** `known: true` → `exit_code`. `known: false` means the
   code is unavailable: report a failure, never success.
6. **Commit caches.** After a successful run, `CommitVolumeClone{
   container_id, volume}` per cloned golden, off the critical path.
   `failed_precondition`/`not_found` just mean "keep the previous golden".
   Seed a new cache key from the nearest golden with `CloneVolume`. Size
   goldens at creation (images only grow).
7. **Clean up.** Wait for the commits, then `DeleteContainer{force}`,
   which also removes the container's clones and its exit-code entry.

Workspace-style volumes that jobs mount read-write directly are protected
by the multi-attach guard across processes. Within one process, serialise
writers yourself so the second job waits instead of failing
`failed_precondition`.

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
