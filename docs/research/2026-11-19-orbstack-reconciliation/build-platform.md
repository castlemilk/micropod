# Micropod build platform: Buildx compatibility and native ownership

**Priority:** core container platform, before expanded Kubernetes features. **Evidence date:** 19 November 2026. This is source inspection and an implementation specification; no builder was installed, started, modified or benchmarked.

Micropod source was rechecked at [`54980012eb47b458a7f7e1def616d3fa95c970a2`](https://github.com/castlemilk/micropod/commit/54980012eb47b458a7f7e1def616d3fa95c970a2). Upstream implementation references are pinned to BuildKit [`c64bdcd1e0946854757ebb9580518ddf38490011`](https://github.com/moby/buildkit/commit/c64bdcd1e0946854757ebb9580518ddf38490011) and Buildx [`f4edce01b6e6677f5e832e92029c7c61fca28859`](https://github.com/docker/buildx/commit/f4edce01b6e6677f5e832e92029c7c61fca28859). Those are inspected source identities, not production version selections.

## Product outcome

Micropod should own a complete build service: lifecycle, request model, scheduling, source transfer, progress, credentials, execution, persistent cache, outputs and recovery. Users should be able to use both Micropod's native CLI/API/UI/MCP and unmodified Docker/Buildx/Compose clients against that service. The replacement target includes ordinary existing build workflows without `DOCKER_BUILDKIT=0` or manual workaround scripts.

The implementation can reuse upstream BuildKit. Building a native Micropod service does not require reimplementing the Dockerfile frontend, graph solver and cache formats. A separate future decision can replace a measured backend component or client surface. A full independent BuildKit-compatible implementation would additionally own protocol compatibility, LLB operations, Dockerfile/frontend behavior, solver cache invalidation, snapshots, exporters and version maintenance; it is substantially larger than exposing another build command. [Docker build architecture](https://docs.docker.com/build/concepts/overview/), [BuildKit protocol](https://github.com/moby/buildkit/blob/c64bdcd1e0946854757ebb9580518ddf38490011/api/services/control/control.proto).

### Distinguish the layers

| Layer | Contract to own or preserve |
|---|---|
| Buildx client | Builder selection, build flags, Bake orchestration, image tools and client-side session participants |
| BuildKit control service | Solve, progress/status, bidirectional session, worker discovery, disk usage/prune and build history |
| Frontend and solver | Dockerfile or other frontend to LLB graph, dependency scheduling, cache lookup and invalidation |
| Worker | Snapshot/cache/content references, source resolution, exporters, leases, platforms and executor selection |
| Executor | Run/exec semantics, mounts, user/cwd/env, signals, terminal, networking, limits and authoritative completion |
| Micropod product service | Authenticated ownership, native API, admission, durable job state, UI/MCP progress, placement and cleanup |

The pinned [worker interface](https://github.com/moby/buildkit/blob/c64bdcd1e0946854757ebb9580518ddf38490011/worker/worker.go) and [executor interface](https://github.com/moby/buildkit/blob/c64bdcd1e0946854757ebb9580518ddf38490011/executor/executor.go) demonstrate the integration boundary. A native worker is not merely an executable substituted for `runc`; it must preserve snapshots, reference lifetimes, execution and exported results together.

## What exists, and what it actually proves

| Source | Current behavior | Remaining work |
|---|---|---|
| [ImageService](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodCore/Services/ImageService.swift#L348-L350) | Builds delegate to a typed `container build` command and stream parsed text. Nonzero command exit is observed by the inner progress stream. | Native durable build jobs, structured progress and results, complete option/session model, end-to-end cancellation |
| [ContainerBuildRequest and command factory](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodCore/CLI/ContainerCommand.swift) | Context directory, Dockerfile, tags, args, target, one platform string, no-cache, limits, pull and labels | Named/remote sources, sessions, exporters, cache backend options, attestations, multiple platforms, entitlements and policy |
| [Image API](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/proto/micropod/v1/image.proto) | The inspected ImageService proto exposes list, pull and delete | A first-class versioned BuildService; do not confuse the Swift internal build method with a complete public build API |
| [Shim imageBuild](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodDockerShim/Handlers.swift#L665-L850) | Whole-body tar context, retained extraction, `container build` delegation and NDJSON progress | BuildKit transport/session paths, streaming/bounded ingestion, precise result identity and cancellation propagation |
| Same | Gzip contexts bypass the hash gate; `.dockerignore` is removed on the assumption the client already filtered; repeated `t` values are collapsed by the query representation | Source-type-aware filtering and canonical context identity across all supported clients; repeatable tags and error behavior |
| Same | Absolute Dockerfile values are accepted; extraction delegates to system tar; manifest parse errors fall back to extraction | Explicit allowed-source boundary and safe archive semantics; this observation alone is not a proven filesystem escape |
| Same | Outer `AsyncStream` is produced by a detached task without a visible termination binding in this function; final `aux.ID` is the first tag | End-to-end disconnect tests, bounded buffering, job ownership and actual result digest; the inner service's cancellation hook alone does not prove the outer stream cancels it |
| [buildPrune](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodDockerShim/Handlers.swift#L907-L915) | Ignores the request and returns an empty result with zero reclaimed bytes | Real backend routing, supported filters and truthful accounting; a successful no-op is not prune parity |
| [BuildContextHasher](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodDockerShim/BuildContextCache.swift#L40-L177) | Keys sorted kind/path/content-or-link entries; ignores modes/ownership; skips PAX headers | Semantically correct immutable source snapshots, versioned keys and migration/invalidation of old entries |
| [BuildCacheStore](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodSharedFS/BuildCache.swift) | Records per-file digest overlap and retained context content bytes | Distinguish content overlap from actual shared APFS extents or BuildKit solver-cache hits |

### Reuse the existing Apple builder where its contract is suitable

Apple's official `container` documentation identifies `container build` as a BuildKit-backed build and provides `container builder start/status/stop/delete`. Its builder is already a utility VM. Therefore the current Micropod path is an indirect BuildKit integration, not a platform with no builder at all. [Apple command reference](https://github.com/apple/container/blob/main/docs/command-reference.md), [resource usage](https://github.com/apple/container/blob/main/docs/resource-usage.md).

First inventory the **installed** Apple CLI, builder-shim image, embedded BuildKit, supported protocol, image store, filesystem-sync interface, runtime account and persistence locations. Current upstream documentation does not prove which features are available in that installation. Prefer a supported endpoint/integration into the existing builder when it meets the required contract. If it does not, define a Micropod-managed, pinned BuildKit service and migrate cache/ownership explicitly. Starting a second builder blindly increases idle cost and fragments caches.

Apple published a build-filesystem symlink containment advisory fixed in `container` 1.2.0. Treat that as evidence for fixed-version checks and negative source-boundary tests, not evidence that the inspected Micropod installation is affected. [Apple advisory](https://github.com/apple/container/security/advisories/GHSA-2v2q-4q35-h585).

## Delivery architecture

### 1. A native, owned build service

Define a versioned request with immutable source references, Dockerfile/frontend identity, target/platforms, build arguments, labels, cache imports/exports, output specifications, session-granted secrets/SSH, entitlements and resource limits. Separate credentials from serializable request data. A host pathname is not an adequate source identity across a dedicated runtime account or remote client.

Each build needs an owner, request ID, selected builder/worker, source/operation digest, cache leases and durable terminal result. Proposed states are queued, resolving, running, exporting, completed, failed, cancelling, cancelled and outcome-unknown. Preserve structured vertex events, warnings and output descriptors; bound log storage and slow-client queues. Reconnection observes the same job rather than resubmitting an uncertain mutation. Decide explicitly whether a caller disconnect cancels or detaches an authorized job; accidental continuation is a defect.

The service should support concurrent builds with fair resource admission and coalesced immutable source/image acquisition. A builder restart must reconcile jobs and leases before reporting readiness. Installed component updates reuse existing runtime ownership and maintenance contracts.

### 2. Buildx protocol compatibility as a product acceptance gate

A remote driver endpoint is a useful first integration, but it does not prove that default `docker build`, `docker compose build` or Bake selects that endpoint correctly. The pinned Buildx Docker driver uses an HTTP hijack for **`/grpc` with `h2c`**, plus a separate **`/session` hijack** carrying protocol metadata. It also inspects worker labels when determining capabilities. Routing plain JSON over those paths is insufficient, and fabricated worker labels can advertise unsupported behavior. [Pinned driver](https://github.com/docker/buildx/blob/f4edce01b6e6677f5e832e92029c7c61fca28859/driver/docker/driver.go).

Implement and qualify both the managed remote-builder route and the promised Docker-endpoint route. Cover upgrade handshakes, HTTP/2 framing, metadata, bidirectional flow control, cancellation and resource ownership. Builder registration and context selection should be reversible and scoped. Test a declared client/version window and pin frontend versions for reproducibility. [Remote driver](https://docs.docker.com/build/builders/drivers/remote/), [driver behavior](https://docs.docker.com/build/builders/drivers/).

Native Micropod clients should use the same job and capability model. They may replace the need to install Buildx for Micropod-native workflows; interoperability remains necessary for existing scripts and CI.

### 3. Correct source and context semantics

The current hash omits file modes, so identical bytes at the same path with different executable bits receive the same key. Ignoring PAX headers can omit effective paths, link targets and other extraction semantics. Sorting duplicate-path entries can erase the archive ordering that determines the final extracted tree. These are source-derived identity defects/risk cases requiring regression fixtures before using that cache as authoritative input.

Canonicalize the **effective, normalized build source**, preserving all metadata that affects the selected frontend's behavior. Do not indiscriminately include mtimes if the reference frontend intentionally ignores them. Define mode/ownership normalization, links, extended metadata, duplicate member rules, directory entries, Unicode/byte names and unsupported archive types. Version the key schema and invalidate incompatible old cache entries.

Use streaming ingestion with limits on compressed bytes, expanded bytes, member count, path depth and queues. Hash parsing and extraction must agree; an unrecognized semantic extension must be handled consistently or rejected, not silently hash one interpretation and execute another. Constrain file requests and extracted paths to granted roots, including symlink races. A frozen snapshot should prevent edits during transfer from producing an incoherent build source.

Test local directory, stdin tar, gzip tar, Git URL with pinned revision, remote tar, empty context, named contexts and alternate/stdin Dockerfiles. Filtering must follow the source/client boundary: `.dockerignore`, Dockerfile-specific ignore files, negation and named contexts cannot all be treated as a prefiltered legacy tar. [Context semantics](https://docs.docker.com/build/concepts/context/).

### 4. Session identity, credentials and entitlements

BuildKit sessions carry more than logs. The host must supply authorized source files, registry authentication, secret mounts and SSH agent operations to the correct build. Bind session identity to user/job/builder and capability grants; deny cross-session reuse, stale sessions and ungranted host paths. Use the existing registry/Keychain owner #151 and handle dedicated runtime account access deliberately.

Secrets and SSH are temporary session resources. Do not convert them into build arguments, copy them into retained contexts, or persist them in build history. Revoke them on completion/cancellation. Host-network, insecure execution and device entitlements need explicit supported policy; rejection must be visible before side effects where feasible. [Build secrets](https://docs.docker.com/build/building/secrets/), [control protocol entitlements/session](https://github.com/moby/buildkit/blob/c64bdcd1e0946854757ebb9580518ddf38490011/api/services/control/control.proto).

### 5. Outputs, platforms and cache protocols

Outputs include registry push, local image load, OCI/image archives and filesystem artifacts. Record immutable descriptors and exporter metadata; a tag is not an image ID. Preserve indexes, config, layer media types and attestations through import/export. Loading a result into Micropod and running it is a separate acceptance step from a successful push. Multi-platform execution must distinguish native workers, cross-compilation and translation, and advertise only qualified combinations. [Multi-platform builds](https://docs.docker.com/build/building/multi-platform/), [attestation storage](https://docs.docker.com/build/metadata/attestations/).

Define inline, local and registry cache interoperability first, including min/max modes, independent import/export refs, compression and OCI media types. Optional GHA/S3/Azure integrations have separate version/authentication support. Concurrent writers need deliberate namespace/publication rules; a mutable cache ref cannot promise transactionally merged history. Keep cache lookup, cache import failure and cache export failure visible in status/results. [Cache backends](https://docs.docker.com/build/cache/backends/).

Distinguish **source snapshot cache**, **solver/layer cache**, **mutable package cache mounts**, **image blobs/unpacked snapshots**, and **host/guest filesystem caches**. `RUN --mount=type=cache` contents are builder-local and are not automatically transferred by `--cache-to/--cache-from`; package cache restoration requires its own mechanism. Its sharing modes, locking and eviction semantics must remain correct under concurrent builds. [Dockerfile cache mounts](https://docs.docker.com/reference/dockerfile/#run---mounttypecache).

BuildKit DiskUsage/Prune and Docker-facing prune must connect to the actual cache owner. Cross-tier leases, trust scopes, accounting and host-space recovery belong to the cache/filesystem workstream; the build service supplies the live references. Report cache-record sizes separately from host-exclusive reclaimed APFS bytes. [Garbage collection](https://docs.docker.com/build/cache/garbage-collection/).

### 6. Native worker and execution optimization

Start with a qualified upstream OCI/containerd execution path and the existing Apple builder as reference options. A custom worker is justified by measured cost or a required isolation contract. Define how BuildKit immutable/mutable refs become guest mounts; how snapshots commit, diff and export; and how cancellation releases process, VM, network and cache leases. A VM-per-step design may discard useful warm state; a reused trusted builder changes the isolation domain. Measure both rather than assuming either is universally faster.

The upstream worker/executor interfaces are Go contracts tied to a selected BuildKit revision. A separate Rust service can implement a measured lower-level boundary behind a versioned protocol, but rust-anything does not generate a BuildKit worker or supply OCI semantics. The native executor must pass the runtime-equivalence suite for users, mounts, signals, limits, seccomp/capabilities and exit status. A fast `RUN echo` is insufficient acceptance.

## Required compatibility matrix

| Workflow family | Required fixtures and outcome |
|---|---|
| Clients | `docker build`, `docker buildx build`, `buildx bake`, `docker compose build` and native Micropod requests select the intended builder; no legacy-builder environment override |
| Builder lifecycle | Create/inspect/bootstrap/stop/remove, restart and concurrent requests preserve owned state and useful caches |
| Dockerfile/frontend | Multi-stage targets, external pinned frontend, args, labels, COPY/ADD modes/links, network and mount semantics; invalid options fail honestly |
| Sources | Local, Git, remote/stdin tar, empty and named contexts; ignore variants, metadata-only edits, link changes and mutation during transfer |
| Sessions | Private registries/Git, required/optional secrets, SSH, locked/denied credential provider, expiry and concurrent tenant isolation |
| Platforms | ARM64, qualified amd64 translation/native node, index assembly, cross-compile args, mixed-platform failure and correct runtime selection |
| Outputs | Local load/run, registry pull/run by digest, OCI archive round trip, filesystem output, provenance/SBOM preservation and requested-output failure |
| Cache behavior | Unchanged/touch-only hit, content/mode/arg/base/frontend/platform miss where appropriate, independent-stage reuse, remote restore, cache-mount locking and prune while busy |
| Failure handling | Disconnect/cancel in source transfer, RUN and export; builder/host-service restart; disk full; corrupted cache; unknown export result reconciled without duplicate publication |
| Product cost | Cold useful build, no-change rebuild, one-source edit, dependency edit, platform change, concurrent related builds, post-burst idle, bytes transferred/written and complete cleanup |

Bake is a graph of build targets rather than another single Dockerfile flag. Test HCL/JSON/Compose input, target inheritance/overrides and concurrent shared-source behavior using actual Buildx clients. [Bake reference](https://docs.docker.com/build/bake/).

Every row required by the selected general-purpose replacement profile must pass before calling it Buildx-equivalent. An unsupported row remains an open compatibility gap; printing a capability error is better than silent behavior, but does not complete that target. Separate specialized profiles can intentionally support a narrower contract if their product description is explicit.

## Ticket decomposition under #149

| Stable planning key | Deliverable |
|---|---|
| BUILD_SERVICE | Owned native BuildService and installed-builder integration |
| BUILD_PROTOCOL | Full Buildx/Docker transport, builder selection and Compose/Bake compatibility |
| BUILD_CONTEXT | Semantically correct, bounded source transfer and context identity |
| BUILD_SESSION | Job-scoped file/auth/secret/SSH sessions and entitlements |
| BUILD_OUTPUT | Multi-platform output, image-store and attestation interoperability |
| BUILD_CACHE_PROTOCOL | Solver cache import/export, real disk-usage/prune and cache-mount distinction |
| BUILD_WORKER | Profile-driven native worker/executor with runtime-equivalence gates |

#149 is the build-platform parent; #150 retains image-store ownership, #151 credentials, #182 benchmark validity, and runtime/cache workstreams own their underlying semantics. The first useful vertical slice is a real Buildx build through the selected owned builder with correct source transfer, structured progress, cancellation and a runnable loaded image. Then add the matrix features without losing that vertical acceptance. Kubernetes is a later consumer of these results.

## Filed implementation issues

| Issue | Work package | Priority |
|---|---|---|
| [#195](https://github.com/castlemilk/micropod/issues/195) | Build platform: own native build jobs and reuse or migrate the installed BuildKit builder | P0 |
| [#196](https://github.com/castlemilk/micropod/issues/196) | Build platform: qualify Buildx transports, builder selection, Bake and Compose compatibility | P0 |
| [#197](https://github.com/castlemilk/micropod/issues/197) | Build platform: make context identity semantically correct and source ingestion bounded | P0 |
| [#198](https://github.com/castlemilk/micropod/issues/198) | Build platform: scope file, credential, secret and SSH sessions to owned jobs | P0 |
| [#199](https://github.com/castlemilk/micropod/issues/199) | Build platform: preserve multi-platform outputs, image loading and attestations | P0 |
| [#200](https://github.com/castlemilk/micropod/issues/200) | Build platform: implement solver-cache interoperability and truthful usage/prune APIs | P0 |
| [#208](https://github.com/castlemilk/micropod/issues/208) | Build platform: qualify a measured native worker/executor against upstream BuildKit | P1 |

These issues are part of the [core platform program](core-container-platform.md) and [tracker #180](https://github.com/castlemilk/micropod/issues/180). Required compatibility remains a release gate; source findings are not executed qualification results.
