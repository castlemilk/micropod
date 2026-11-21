# Performance qualification and benchmark reconciliation

Status: **proposed methodology and source audit only**. Research date: 19 November 2026. No benchmark, runtime restart, cluster creation, application installation, live-rig drain or fault injection was performed for this report. The historical figures in the repository remain historical results; this document does not establish that Micropod currently outperforms OrbStack.

[Research index](README.md) · [Existing state](existing-state.md) · [Reconciled roadmap](roadmap.md) · [OrbStack investigation](craft-anything-investigation.md) · [Rust build-out](rust-anything-buildout.md)

Core specifications: [container platform priorities](core-container-platform.md), [native build platform and Buildx](build-platform.md), [OCI/runc equivalence](runtime-compatibility.md), and [cache/VirtioFS contracts](cache-and-filesystem.md).

## Decision to make

Establish reproducible product baselines first, then select optimizations from measured costs. Compare the existing Micropod backends before funding another backend. An improvement should preserve required behavior, reduce a measured cost at the complete-workload boundary, and retain an operational rollback. A short Rust function benchmark, a cached API response or a vendor claim cannot establish the overall result.

The primary qualification order is **complete build workflows, OCI/runc execution semantics, then cache and filesystem correctness/performance**. Kubernetes is a downstream consumer and a later product lane; cluster readiness is not a prerequisite for proving Buildx, runtime or VirtioFS behavior. The general replacement milestone requires every required row in the build and runtime compatibility matrices to pass. An explicitly narrower isolated-CI profile can be measured and released on its own terms, but an unsupported required feature cannot be counted as passing the full replacement gate.

Inventory the installed Apple `container` builder before adding a comparison backend: the current Micropod `container build` path already reaches a BuildKit-backed utility VM. A native Micropod BuildService can reuse that builder or a qualified upstream BuildKit integration. Record backend/session/version identity and total owned builder cost; adding a new control API does not prove a new solver or executor, and launching a second builder can invalidate idle and cache comparisons. [Build-platform reconciliation](build-platform.md), [Apple builder commands](https://github.com/apple/container/blob/main/docs/command-reference.md).

All Micropod source findings below refer to commit [`54980012eb47b458a7f7e1def616d3fa95c970a2`](https://github.com/castlemilk/micropod/commit/54980012eb47b458a7f7e1def616d3fa95c970a2). The source already has runtime, Docker-shim, Kubernetes and app benchmark entry points, plus historical performance reports. Extend and repair that infrastructure. The evidence gap is a contemporary, controlled OrbStack comparison and stronger validity checks, not a complete absence of benchmark code. [Task definitions](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Taskfile.yml), [historical performance](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/docs/performance.md)

## Compare modes with declared isolation and resources

OrbStack documents one Linux kernel shared by its containers and Linux machines. Its isolated-machine mode removes host integrations but still shares that kernel. Therefore, an isolated Micropod VM and an OrbStack machine are different isolation products. Keep this distinction visible in every result. [OrbStack architecture](https://docs.orbstack.dev/architecture), [isolated-machine security model](https://docs.orbstack.dev/machines/isolated)

| Comparison lane | Intended question | Required disclosure |
| --- | --- | --- |
| Per-workload VM isolation | How efficient are Micropod's current sandbox and Apple-container paths for independently isolated jobs? | Fresh VM versus reused VM, VM CPU/memory allocation, guest workload quota, runtime ownership and host sharing policy |
| Trusted shared-kernel development | Can a proposed shared-VM Micropod backend achieve competitive density for trusted workloads? | Mark the Micropod candidate unavailable until implemented; compare against versioned OrbStack and Docker configurations with the same workload semantics |
| Product developer workflow | How quickly does an installed product complete a native build, Buildx/Bake, Docker run or Compose task? | Builder selection, isolation, source/session/export behavior, caching and integration defaults remain visible; this is a product comparison, not a controlled attribution to a hypervisor or language |
| Downstream Kubernetes workflow | How efficiently do qualified build/runtime/storage components support build-to-deploy and cluster operation? | Keep distribution/version/add-ons and inherited component costs visible; this lane does not replace the core compatibility gates |
| Component experiment | Does a particular existing-language or Rust change improve the measured bottleneck? | Same backend, algorithm, fixtures, transport, build mode and quotas; distinguish unit speed from end-to-end speed |

Run native ARM64 and translated AMD64 in separate lanes. Record the exact translation configuration and guest architecture. Intel-host support, where actually available, is a separate qualification lane. For CPU limits, record both the workload quota and the total VM resources: setting the same container quota does not necessarily make hypervisor overhead or total physical allocation equal.

Resource matching has two useful views: equal workload limits, which exposes runtime overhead; and equal total host budget, which exposes completed work per unit of machine capacity. Publish both where relevant. Do not force a kernel-isolation comparison into a single efficiency leaderboard.

The original BENCH-002 adapter coverage remains OrbStack, Docker Desktop, Colima and Rancher Desktop. A Docker-compatible endpoint can reuse the workload client, but each adapter still needs explicit daemon identity, version/backend/resource discovery, lifecycle ownership and fresh/warm preparation. API connectivity alone is not an independently qualified product adapter. Record unavailable comparator lanes rather than substituting another daemon behind the current context.

## Repair the existing harness before using it for claims

These are source findings, not newly observed runtime failures. They are concrete changes to attach to the existing benchmark/qualification work rather than reasons to discard the existing scripts.

| Existing entry point | Finding at the pinned source | Required repair or qualification |
| --- | --- | --- |
| `scripts/bench_runtimes.py` | `timed()` catches any failure, retries and restarts the clock. The first failure and its time disappear. | Preserve every attempt and outcome; do not retry an uncertain mutation automatically. If a retry is authorized after reconciliation, report its latency separately and include first-attempt failures in reliability results. |
| Same | `api_run()` only rejects a nonzero exit code when `known` is true. It does not require a completed wait or a known exit status. | Require authoritative completion and known exit status before counting a successful job. Report unknown, timeout and nonzero exit as distinct outcomes. Reconcile the owned resource before cleanup. |
| Same | Uses mutable image tags; prepares Go modules through Micropod even when selecting another backend; unconditionally deletes fixed machine name `bench-go`; optional Shuru setup downloads a toolchain into a fixed checkpoint. | Digest-pin images/toolchains; make preparation explicit and outside timed sections; create unique, journaled resources; refuse collisions; clean only resources created by this run. Avoid hidden cross-product warm-up. |
| Same | Rotating interleaved runtime rounds and raw sample JSON already exist, but fan-out runs each backend in sequence; subprocess execution lacks an explicit timeout. | Preserve useful interleaving; randomize or balance fan-out order; add bounded execution, failure receipts and per-job outcomes; add environment manifests and complete timing boundaries. |
| `scripts/bench_shim_vs_docker.py` | The phase labelled `exec start` actually creates a new exec and starts it. Summary JSON discards raw samples. Its concurrency row is one wall-clock observation with `n` equal to thread count. | Split exec-create from exec-start, preserve raw samples, and record independent concurrency rounds and per-job latency. Thread count is concurrency, not sample count. |
| Same | Missing/invalid baseline returns success; missing metric rows are skipped; printed concurrency errors do not themselves fail the run; baseline policy only compares p50 with a 20% tolerance. | Fail required checks closed; require matching schema, settings and metrics; propagate errors; compare distributions and reliability. A 20% p50-only guardrail is not evidence of improved tail latency. |
| Same | Keeper names are fixed; keeper setup occurs before its cleanup `try`; each lifecycle lacks its own cleanup guard; explicit CPU/memory limits are absent. | Unique run-owned names, cleanup journal and bounded final reconciliation; matched resource limits; validate returned exec output and exit code as well as elapsed time. |
| `scripts/bench_runtime.sh` | Measures Apple runtime service start/list readiness against Docker application start/info readiness. It stops services, uses wall-clock timestamps, excludes the Micropod GUI but counts Docker UI processes, and sums RSS. | Separate service-ready and product-ready tests; use monotonic timing; inventory comparable process groups; include GUI consistently; report RSS only as RSS, not unique physical memory. Its current idle implementation does not actually collect the optional energy sample described in the header. |
| `scripts/bench_k8s.sh` | Micropod `k8s up` can reuse its existing cluster, while kind is deleted and recreated under fixed name `bench-k8s`. Guest `MemTotal-MemAvailable` is compared with Docker stats. It passes `--no-metallb` before testing a LoadBalancer. | Run fresh-to-fresh and warm-to-warm lanes with owned clusters, explicit distribution/version/add-ons, equivalent memory scopes, and a declared LB configuration. Readiness timeout must fail; test the app endpoint after nodes and required system pods are ready. |
| `Sources/MicropodBench/main.swift` | Real-runtime timing and synthetic decode tests already exist. Cleanup deletes every container with the shared `micropod-bench` prefix, including another run's resource; final cleanup is scheduled in an unawaited `Task`. | Keep component tests distinct from runtime scale tests; use exact ownership labels/IDs and awaited reconciliation. Preserve interrupted-run evidence for a separate explicit recovery operation. |

Source: [runtime comparison script](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/scripts/bench_runtimes.py), [shim script](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/scripts/bench_shim_vs_docker.py), [runtime footprint script](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/scripts/bench_runtime.sh), [Kubernetes script](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/scripts/bench_k8s.sh), [app benchmark](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodBench/main.swift).

## Manifest before measurement

Each run should emit a versioned manifest, raw samples, correctness outcomes and an ownership journal. Unknown values remain null; they must not be inferred from the checkout or a release page. Required identity groups:

- **Host:** model, chip, physical/logical CPU counts, RAM, macOS version/build, APFS volume and free space, filesystem case sensitivity, power source/mode, thermal conditions, background workloads and measurement tools.
- **Artifacts:** Micropod baseline/candidate source commits, dirty-tree state, build mode/toolchain, installed app/CLI/API/helper version and SHA256, signed bundle identity, actual Apple runtime package/framework versions, guest kernel/init/helper hashes; installed builder-shim/BuildKit/frontend, runc/containerd and client versions where used. Source, release qualification and installed binary are separate facts.
- **Comparators:** installed OrbStack/Docker versions/builds; Docker endpoint/context and resolved engine identity; configured backend, VM resources, sharing/caching mode, CPU architecture and translation. The presence of a Docker CLI does not identify its daemon.
- **Workloads:** OCI index and resolved platform-image digests, repository fixture commits, lockfiles, dataset/tree shape and hashes, Compose/Helm/Kubernetes versions, storage type, network settings and declared readiness/output oracle.
- **Experiment:** run ID, backend and isolation lane, exact argv/environment allowlist, warm/cold definitions, workload/VM limits, concurrency, measurement order/seed, warmups/repeats, deadlines, acceptance thresholds and all output hashes.

The repository's v0.13.9 qualification manifest identifies source `262b8f96f3dd1629a76181c2e97965cc5a6c1dde`, distinct from this audit's source commit. That file is qualification evidence; it does not prove that a given Mac has adopted the release. Capture installed identity separately. [Qualification manifest](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/docs/qualified-releases/v0.13.9.json), [release qualification policy](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/docs/release-qualification.md)

Suggested raw-sample fields are `run_id`, `round`, `backend`, `phase`, `start_monotonic_ns`, `duration_ns`, `success`, `exit_code`, `outcome_known`, `deadline`, `owned_resource_id`, `bytes`, `operations`, `cpu_ns`, `memory_scope`, and `evidence_path`. Keep schema validation separate from a performance verdict. Redact credentials and private paths from public artifacts while retaining stable fixture identifiers.

## Timing definitions

| Metric | Start | End | Separate dimensions |
| --- | --- | --- | --- |
| Service cold start | Request to start an already installed, stopped service | Authenticated API readiness plus a successful inventory probe | Image cache remains declared; no image pull or installation is hidden |
| Product ready | User-visible app/CLI launch action | First required workflow can succeed | GUI, service and guest readiness timestamps separately |
| Complete build | Native API or actual Docker/Buildx/Bake request | Solve plus every requested export completes with validated immutable outputs | Context preparation/transfer, session setup, source resolution, RUN, snapshot/diff, export and local-load-to-runnable spans |
| Fresh workload | Create/run request | First verified guest output or application response | Create, VM boot, exec dispatch and app-ready spans |
| Existing-workload exec | Exec request against a ready workload | Verified output and authoritative exit status | Client process startup, transport and execution separately |
| Complete job | User-equivalent request | Known exit status, result validation and required resource teardown | Also report time-to-result and teardown independently |
| Filesystem visibility | Producer commits the specified operation | Consumer observes the required bytes/metadata/event | Notification latency differs from polling visibility and durable persistence |
| Downstream Kubernetes ready | Fresh cluster creation request | Nodes, required system pods, DNS and fixture service succeed | Warm resume measured separately; all charts/images pinned; core build/runtime gates reported independently |
| Cancellation recovery | Cancellation/deadline delivered | Owned work has a proven terminal state and required leases/receipts reconcile | A caller returning quickly does not prove the guest stopped |

Use one monotonic clock for host-visible intervals. Do not subtract guest and host wall clocks as if synchronized. For cross-boundary tracing use calibrated synchronization or explicit request/response spans and report uncertainty.

“Cold” must name what is cold: app/service, guest VM, image unpack, dependency cache, compiler cache, guest page cache or host page cache. Warm runs should not be presented as cold starts. Do not globally purge host caches or stop shared runtimes to manufacture cold results; use a dedicated test host and an explicit reset protocol. Where page-cache reset cannot be proved, label it uncontrolled.

### Record cache state by layer

| Layer | Required state evidence and test distinctions |
| --- | --- |
| Source/context snapshots | Input tree/ignore/frontend identity, retained extraction or snapshot hit, transferred bytes, semantic metadata edits, gzip/local/Git/named-source path and mutation policy |
| BuildKit solver/layer cache | Builder/cache namespace, frontend/base/platform identities, cache import/export refs and modes; cold, no-change, independent-stage and targeted invalidation outcomes |
| Mutable package/compiler mounts | Cache ID, ownership, toolchain/platform and sharing/locking state; distinguish empty, warmed, restored and concurrent-writer cases |
| Image blobs and unpacked roots | Registry/index/platform digest, compressed blob hit, verified unpack/realization hit, fresh template versus clone and writable-layer preparation |
| Host/guest filesystem caches | Share mode, metadata/content generations, notification state, host/guest page-cache control and first versus repeated traversal |

`--no-cache` is not proof that the builder, image content, package directories or host page cache are cold. BuildKit cache exports also do not automatically transfer `RUN --mount=type=cache` contents. Report source reuse, solver reuse, package-cache effects, digest overlap, physical clone sharing and reclaimed host bytes separately. Live-reference and busy-prune tests must establish that fast eviction preserves running jobs and outputs. [Cache contracts](cache-and-filesystem.md), [Dockerfile cache mounts](https://docs.docker.com/reference/dockerfile/#run---mounttypecache).

## Workload matrix and correctness oracles

| Area | Minimum workload set | Measure and validate |
| --- | --- | --- |
| Build platform | Actual `docker build`, `buildx build`, Bake, Compose build and native BuildService; multi-stage/named contexts; secrets/SSH; cache restore; multi-platform; load/push/archive/local outputs; SBOM/provenance | Correct builder selection and session grants, structured progress/cancellation, source correctness, immutable descriptors and runnable output; cold/no-change/source-edit/dependency-edit/concurrent-related-build cases |
| OCI/runc execution | Bundle/config, create/start/exec/kill/delete, terminals/signals, users/mounts/namespaces, rootful/rootless, cgroups/security, events/restart | Reference-versus-candidate effective guest state; required controls cannot disappear; known exits and ordered ownership; resource enforcement demonstrated before resource-matched speed claims |
| Cache administration | Source and solver reuse, package-cache locking, image realization, concurrent prune, interrupted publication and restart | Correct keys, integrity, live references, bounded accounting and actual reclamation; no successful no-op prune or false cache-hit result |
| Lifecycle/API | Empty command, stdout/stderr stream, short service, list/inspect at 0/1/10/100 workloads | p50/p95, failure/timeout rate, known exits, cache freshness, cancellation, repeated create/start/stop/delete |
| Developer builds | Pinned Go vet/test; representative Node dependency/install/test; a Compose service stack | Warm/cold dependency and compiler caches separately; output/artifact correctness; wall time and aggregate CPU; external downloads excluded or separately metered |
| Density/concurrency | 0/1/10/25 workloads, then the host's agreed capacity limit; concurrency 1/2/4/8 and saturation | Throughput, per-job and batch latency, queueing, fairness, peak/recovered memory, retained VM/process/FD growth |
| Mac-to-Linux files | Metadata traversal, small-file create/stat/readdir/unlink, large sequential I/O, random I/O and atomic editor save | Separate first traversal from repeated traversal; compare bytes, permissions, symlinks, rename, case behavior, UID/GID mapping and notifications |
| Linux-to-Mac/volumes | Browse, read, atomic edit, concurrent writers, open-then-unlink, restart and recovery | Explicit supported consistency contract; stale reads/conflicts, fsync and rename durability, no lost accepted writes; measure allocated storage and reclaim separately from sparse logical size |
| Networking | Guest/host/local service, DNS, localhost forwarding, simultaneous connections, VPN/DNS change, sleep/wake | Latency/throughput plus reachability, endpoint ownership, stale rules, reconnect behavior and bounded cleanup |
| Downstream Kubernetes | Pinned small cluster and charts, build-to-deploy loop, service access and persistent-volume restart | Product-default and equivalent-distribution lanes after core qualification; control-plane cost, node/pod/service readiness, DNS, storage and LB correctness |
| Idle/energy | App closed/open, no workloads, one idle workload, Kubernetes idle, post-burst settled state | Time series of whole-product CPU, wakeups, threads, FDs, host memory and energy; telemetry overhead measured separately |
| Failure handling | Client cancellation, guest/helper/API termination, transport loss, full disk and restart during an owned operation | Existing authority/admission invariants, no duplicate work, no false known success, no foreign cleanup, crash consistency and recoverable receipts |

File throughput must be reported with the applicable correctness mode. A cache that wins by serving stale data, dropping change events or acknowledging non-durable writes does not pass a workload requiring stronger semantics. Watch testing should include rename chains, create/delete storms, queue overflow, rescans, Unicode and non-UTF-8 names where supported, and simultaneous host/guest edits.

Keep resource metrics precise. Summed RSS can double-count shared pages and is not interchangeable with macOS physical footprint, guest memory used or VM reservation. Report each with its scope, plus host pressure/compression/swap. For storage distinguish logical size, allocated blocks, clone/snapshot sharing and bytes actually reclaimed. For energy use a supported host measurement method for the selected OS, record its privilege/tool prerequisites and measurement scope, and treat Activity Monitor's energy estimate separately from whole-machine watts or joules.

OrbStack's published benchmark page describes August 2023 tests on an M1 Max, not the binaries selected for this investigation. It also explicitly limits its process-group energy estimate. Use that material to select useful workloads, not as contemporary measured acceptance values. [Vendor methodology](https://docs.orbstack.dev/benchmarks)

## Execution, statistics and release gates

1. **Repair and qualify the harness.** Add fixture tests for incomplete waits, missing baselines, failed attempts, cleanup ownership and sample accounting. These tests protect the measurement itself. Run one bounded smoke workload on a disposable local environment before collecting performance data.
2. **Freeze the comparison.** Select installed versions, fixture digests, isolation lanes, settings, timing boundaries and thresholds before looking at results. Run baseline and candidate release builds. Do not compare a debug Swift binary with an optimized release binary.
3. **Collect balanced blocks.** Warm each declared warm lane explicitly; rotate or randomize baseline/candidate order. Repeat across multiple sessions. Avoid running competing runtime workloads concurrently during idle/energy tests; do not stop somebody else's work to obtain a quiet host.
4. **Retain all outcomes.** Report failure, timeout and unknown-outcome counts alongside successful latency. Retries, outliers and interrupted rounds remain in the raw data. Predeclare exclusions for unrelated host interference; preserve both included and excluded observations with reasons.
5. **Size samples to the claim.** A small smoke run establishes operability only. Start with enough independent blocks to estimate variance, then choose repetitions for the target effect. Hundreds of cheap lifecycle samples can support a useful p95 estimate; three expensive build runs cannot establish a stable tail. Report confidence intervals and avoid p99 claims from tiny samples.
6. **Evaluate the complete workload.** Publish p50/p95, uncertainty, completed work per second, CPU, memory, energy and errors. Bootstrap or another declared method must respect paired blocks and session correlation. A batch of ten simultaneous jobs is one batch-wall observation, not ten independent wall samples.
7. **Make a scoped decision.** Set budgets after the first valid baseline. For a component experiment, the [Rust plan](rust-anything-buildout.md) proposes explicit improvement/regression gates; those are proposals, not achieved results. Declare keep-current, ship-candidate, or inconclusive. Keep a negative result as evidence.

Semantic compatibility, concurrency, performance, cancellation, crash recovery and durability are separate gates. A semantic replay tool cannot certify the others. A performance win cannot waive existing managed-runtime ownership, admission or workload-preserving maintenance rules. The source documents these controls; this plan does not authorize bypassing them or operating a shared Cuttlefish rig. [Managed runtime and admission model](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/docs/isolated-runtime-design.md)

Generate a required-feature coverage report before declaring Buildx or runc equivalence. Passing a specialized profile or returning an honest unsupported error is useful intermediate evidence, but neither completes a required row of the general replacement profile. Qualify the complete request-to-guest-to-output path: route recognition, typed API coverage and upstream component presence alone do not establish resource enforcement, session correctness or durable outcomes. Fix the concrete context-key, clone-fallback, chunk-integrity and request-translation defects identified in the sibling audits before using their affected paths to claim faster correct behavior.

Before rollout, retain the old backend/component behind an explicit versioned feature selector, verify rollback on test-owned data, and preserve artifacts and manifests for both paths. Changes to persistent formats require their own compatibility and recovery plan. Benchmark success is not release qualification or installed adoption.

## Deliverables for the next implementation slice

- A repaired runner with schema-validated manifests, immutable fixtures, unique ownership, bounded operations and truthful failure accounting.
- Buildx/native-build and OCI/runc coverage reports with actual client, guest and output receipts; separate downstream Kubernetes qualification.
- Baseline reports for current Micropod modes, then a contemporary OrbStack/Docker comparison with isolation and settings disclosed.
- A bottleneck attribution report separating VM boot, client/process overhead, API/cache behavior, guest execution, sharing, networking and idle polling.
- One optimization experiment selected from that evidence, with correctness receipts, raw measurements, scoped conclusions and a tested rollback.
- A public comparison only after independently reproducible runs. Phrase results as specific workload/version/configuration findings; do not generalize one fast API route or warm exec into universal product superiority.

No runtime command in the existing benchmark scripts was executed during this audit. Their names above identify work to qualify, not approval to run their present mutating behavior against an installed or shared environment.
