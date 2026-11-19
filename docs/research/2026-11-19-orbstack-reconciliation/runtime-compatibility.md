# Runtime replacement: OCI and runc-equivalent execution

**Priority:** foundational build/container work, ahead of Kubernetes feature expansion. **Audit date:** 19 November 2026. Micropod `master` was rechecked and remains [`54980012eb47b458a7f7e1def616d3fa95c970a2`](https://github.com/castlemilk/micropod/commit/54980012eb47b458a7f7e1def616d3fa95c970a2). This is source inspection and an implementation contract, not a completed conformance or runtime test. No workload was started, no host was changed, and no benchmark was run.

## Product objective

Micropod must execute the Linux workloads and automation that users currently entrust to Docker/containerd/runc, with correct results, resource controls, isolation policy, cancellation and recovery. A successful `docker run alpine true` or an OCI image import does not establish this replacement capability. The release milestone is a versioned, comprehensive target-profile matrix whose required cases pass. Reporting a required feature as unsupported is an honest intermediate state, **not completion of the replacement milestone**.

Use the existing Swift control plane and independent microVM engines as useful components. Add or integrate a complete Linux runtime execution path inside the selected VM trust domain when that is the fastest reliable route to compatibility. A guest can host upstream containerd/runc for a single build, job group or trusted development domain; full Linux behavior does not require putting every CI job into one global VM. Keep the existing independently isolated profile available.

## Four contracts that must not be conflated

| Contract | What callers require | What passing it does not establish |
|---|---|---|
| Docker Engine API | Versioned create/inspect/exec/attach/wait/kill, networks, volumes, events, errors, Compose/Testcontainers behavior | An OCI bundle runtime, BuildKit protocol, or runc executable replacement |
| OCI Runtime Specification | Apply a Linux bundle/config, separate create from start, expose correct state, send signals and clean owned resources; enforce requested configuration | Docker API endpoints or all runc extensions |
| runc CLI and implementation behavior | If a binary drop-in is claimed: command/flag compatibility, root/state/log/console sockets, exec/update/pause/resume/features and optional extensions | macOS host namespaces or arbitrary host-device access |
| containerd Runtime v2 | Shim bootstrap for the pinned containerd version, task RPCs, stdio/rootfs lifecycle, ordered task/exec events, reconnection and cleanup | A complete Docker daemon or image/snapshot manager |

The OCI specification requires the requested environment to be applied or creation to fail; missing fields cannot be silently discarded at the OCI boundary. Docker's API is different: its documented schema permits unknown extension properties. Preserve that forward-compatible handling while validating **known semantic fields in the API version Micropod advertises**. A supported Docker security/resource field cannot disappear during translation and still count as parity. [OCI lifecycle](https://github.com/opencontainers/runtime-spec/blob/20f948a4a944629335518533250dd719fedd73f2/runtime.md), [Docker API](https://docs.docker.com/reference/api/engine/version/v1.44/), [runc commands](https://github.com/opencontainers/runc/blob/b7dc1304ed9e18f14e626dc06374043b12cf355f/man/runc.8.md), [containerd shim contract](https://github.com/containerd/containerd/blob/8abc4c7d223bf3da36f0d1c43ea39bc2aa1e2eca/docs/runtime-v2.md).

## What the current code proves—and what remains

| Evidence at the pinned source | Finding | Required response |
|---|---|---|
| [DockerTypes.swift L1–4, L102–130](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodDockerShim/DockerTypes.swift#L1-L130) | The types identify themselves as an API v1.44 subset. HostConfig models only selected controls; standard fields such as SecurityOpt, PidsLimit, CPU quota/period, devices and PID/IPC/user namespace modes are absent from that type. | Build a versioned field inventory and translate or explicitly refuse known requested semantics before create. Validate requested versus effective configuration. |
| [Handlers.swift L1324–1410](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodDockerShim/Handlers.swift#L1324-L1410) | Create decodes into that subset and responds with an empty Warnings array. | Do not present lost standard controls as a successful equivalent create. Cover both payload validation and response/error behavior. |
| [Handlers.swift L1540–1580](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodDockerShim/Handlers.swift#L1540-L1580) | NanoCpus is converted to Double, but tmpfs option values are discarded and negative/unlimited ulimits are skipped. Memory is rounded to MiB. | Preserve semantic controls through every adapter; distinguish unsupported backend capability from malformed input. |
| [NativeContainerService.swift L571–610](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodRuntime/NativeContainerService.swift#L571-L610), [container.proto L154–158](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/proto/micropod/v1/container.proto#L154-L158) | The API promises fractional CPUs; native create applies `Int` conversion and emits VM CPU/memory settings plus empty sysctls. | Separate vCPU provisioning from guest CPU quota. A 0.5 CPU request must not become 0 vCPUs or silently become a whole-CPU cap. Add guest cgroup enforcement and effective-value reporting. |
| [NativeConfigBuilder.swift L114–174](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodRuntime/NativeConfigBuilder.swift#L114-L174), [Handlers.swift L1582–1624](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodDockerShim/Handlers.swift#L1582-L1624) | Process/image defaults are implemented, but the Docker empty-entrypoint reset becomes nil and falls back to image entrypoint. Native bare environment names inherit host values, whereas Docker API semantics differ. | Differential fixtures for absent/empty/reset entrypoint, argv boundaries, environment removal/inheritance and image/request precedence. Keep CLI shorthand semantics separate from Docker JSON semantics. |
| [HijackedExec.swift L16–37](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodDockerShim/HijackedExec.swift#L16-L37) | Exec User is decoded as a nested object, while Docker specifies a string such as `1000:1000`. | Fix the standard string form and malformed-input handling; prove effective UID/GID in the guest. |
| [HijackedAttach.swift L20–38](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodDockerShim/HijackedAttach.swift#L20-L38) | Attach/start ordering has substantial handling, but inbound stdin is deliberately drained and discarded. | Implement duplex attach with explicit stdin EOF, detach and reconnect semantics. Interactive users must not have their input silently lost. |
| [Handlers.swift L1837–1873](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodDockerShim/Handlers.swift#L1837-L1873) | Docker kill dispatch selects `KILL` rather than forwarding the requested signal. Pause/unpause/update/resize have no implementation in the inspected dispatch switch. | Complete signal semantics and the declared lifecycle/resource/terminal operations; do not advertise an API operation based on a recognized route token. |
| [NativeContainerService.swift L146–194](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodRuntime/NativeContainerService.swift#L146-L194), [ExitCodeRegistry.swift](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodRuntime/ExitCodeRegistry.swift) | Native start registers a waiter before process start and tracks authoritative/unknown exits with generations. This is valuable existing work. | Extend it through durable restart/reconnect and every public interface; do not recreate an unrelated exit registry. |
| [EventsHub.swift L4–7, L484–500](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodDockerShim/EventsHub.swift#L484-L500) | Docker events are synthesized by periodic snapshots, and the exit handler still falls back to zero when a code is absent. | Keep #66 authoritative for exit correctness; require durable ordered events and known outcomes. Polling reconciliation alone cannot represent every short intermediate event. |
| [ShimState.swift L591–716](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodDockerShim/ShimState.swift#L591-L716) | Create metadata and shared views are persisted; the shown persisted schema does not include exit history or exec task state. | Reconcile durable process identity, terminal outcomes and event cursors after shim/API restarts. Persistence of create metadata is not whole-task durability. |
| [DockerTypes.swift L69–100](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodDockerShim/DockerTypes.swift#L69-L100), [Handlers.swift L1520–1537](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodDockerShim/Handlers.swift#L1520-L1537) | Host and none are classified with default-network names; create passes custom attachments. Network connect/disconnect is explicitly unimplemented. | Qualify host/none and network-namespace modes against actual effective guest networking; implement named/multiple attachment and mutation where required. #74 remains the API network-selection owner. |
| [container.proto L214–223, L290–296](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/proto/micropod/v1/container.proto#L214-L296), [SandboxVM.swift L107–115](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodRuntime/SandboxVM.swift#L107-L115) | Privileged means a microVM-scoped capability/path change, not host-device passthrough. A constrained rootless-Docker sandbox profile already exists. | Preserve that distinction; build rootless and privileged profile tests without silently broadening host access. |

These are source findings, not newly observed production failures. Several historical code comments discuss earlier runtime versions; the current behavior must be qualified against installed dependency identities rather than inheriting those anecdotes as current evidence.

## Required compatibility matrix

Use three result columns for every case: reference Linux runc; Micropod Linux-runtime profile; native microVM profile. The Linux-runtime profile is the route to complete required Linux behavior; the native profile must either achieve the same observable contract or expose a deliberate supported-profile boundary. Required cases remain release blockers when unsupported.

| Domain | Mandatory test dimensions | Observable oracle |
|---|---|---|
| Bundle/config and features | Spec version; rootfs readonly; annotations; valid/invalid fields; requested capabilities; preflight errors; supported feature discovery | Effective guest state matches config; no program runs during create; rejected create leaves no published workload or owned leaks |
| Lifecycle | create/start/state/kill/delete, duplicate IDs, invalid transitions, concurrent operations, start failure, abandoned calls | State machine and errors match the chosen contract; one authoritative operation owner; no ghost late starts |
| Process | Image entrypoint/cmd, empty reset, argv quoting, environment precedence/removal, working directory, user/group/supplementary groups, umask, rlimits | Guest-produced structured report confirms effective values, byte boundaries and expected nonzero status |
| Exec and terminals | Non-TTY stdout/stderr framing, stdin and half-close, PTY, initial size/resize, raw bytes, detach keys, disconnect and multiple sessions | Exact byte streams where deterministic, terminal dimensions and process state, bounded buffers, no deadlock |
| Signals and PID 1 | Named/numeric signals, custom stop signal/grace, signal traps, process groups, init reaping, orphan/zombie cleanup | Expected handler/trap output and exit status; distinguish client disconnect from explicit process cancellation |
| CPU/cgroups v2 | Fractional quota/period, weight, cpuset, host vCPU allocation, live updates, pids.max, freeze/thaw and delegation | cgroup files and competing workload measurements agree with requested effective controls; no zero-vCPU conversion |
| Memory and I/O | memory.max/high, swap policy, OOM event/exit, bounded accounting, IO weights/limits, ulimits including unlimited | Enforcement and reported counters agree; other workloads and supervisor remain responsive |
| Filesystems/mounts | bind/rbind, propagation, tmpfs size/mode, readonly root and recursive readonly, proc/sys/dev setup, masked/readonly paths, UID/GID mappings, symlinks, idmapped mount capability | Guest mountinfo and behavior match; readonly/size/permission controls cannot be dropped; no path escape |
| Namespaces and networking | PID/IPC/UTS/mount/net/user/cgroup/time availability; create/join; shared-domain semantics; host/none/container modes | Namespace identity, reachability and denial outcomes match the declared Linux execution domain |
| Privilege/security | Capabilities, no_new_privs, seccomp modes, supported LSM policy, device rules, sysctls and hooks | Positive and negative probes demonstrate enforcement; unsupported required protections block the profile |
| Rootless | subordinate UID/GID mapping, user namespaces, cgroup delegation, rootless storage/networking, teardown | Works without unintended privilege escalation or host grants; resource and filesystem behavior remains declared |
| Task durability/events | Start-before-exit order, exec identity, OOM distinction, wait before/after exit, restart/reconnect, deleted-ID reuse, exactly owned cleanup | Known exit never becomes guessed success; event cursor/reconciliation produces consistent state without lost ownership |
| runc extensions | update, pause/resume, events/ps, feature query; checkpoint/restore if included in declared replacement profile | Each declared extension has a direct fixture. CRIU process checkpointing is distinct from disk clones and VZ VM snapshots |

The scope comes from the pinned [OCI process/config](https://github.com/opencontainers/runtime-spec/blob/20f948a4a944629335518533250dd719fedd73f2/config.md), [Linux config](https://github.com/opencontainers/runtime-spec/blob/20f948a4a944629335518533250dd719fedd73f2/config-linux.md), [feature query](https://github.com/opencontainers/runtime-spec/blob/20f948a4a944629335518533250dd719fedd73f2/features.md) and [runc command inventory](https://github.com/opencontainers/runc/blob/b7dc1304ed9e18f14e626dc06374043b12cf355f/man/runc.8.md). Actual kernel capabilities, runc build options and LSM support must be recorded. A rootless configuration is not equivalent to rootful execution merely because the same bundle starts.

## Runtime architecture and delivery path

### A. Make the existing adapters truthful immediately

Add a request-to-effective-config report with an API version, execution profile and capability revision. Preserve fields in typed models, validate known standard controls, and refuse unsatisfied required controls before mutation. Use the existing registry and managed ownership mechanisms. Fix the deterministic user/entrypoint/env/tmpfs/ulimit/signal/CPU translation problems as small changes, with differential fixtures. These improvements do not depend on Kubernetes or a new global shared VM.

### B. Provide a complete Linux execution domain using maintained upstream components

For the general Linux compatibility profile, pin a guest kernel, containerd, runc and associated libraries with verified artifact provenance and a compatibility manifest. Use upstream OCI execution inside a VM whose trust domain is explicit: one job, one build project, or one opted-in trusted development environment. Integrate through the existing host/guest transport and ownership layer, with a well-defined process supervisor and durable task store.

If Micropod exposes itself as a containerd runtime, implement the Runtime v2 task service for the exact selected containerd version. Recent upstream revisions describe both legacy bootstrap and a newer protocol; a hard-coded shim executable name or an old handshake is insufficient. Separate shim boot/connection lifetime from the runtime engine and from the workload lifetime. Preserve rootfs mount ownership, FIFO/console behavior and mandatory event order. [Pinned containerd design](https://github.com/containerd/containerd/blob/8abc4c7d223bf3da36f0d1c43ea39bc2aa1e2eca/docs/runtime-v2.md).

Linux “host” refers to the execution domain's Linux kernel. Joining `--pid=host` or `--network=host` does not mean joining macOS namespaces. Two independent microVMs cannot directly share a Linux namespace. A workload requiring namespace sharing therefore needs a shared Linux execution domain; that selection must be explicit and reflected in resource/isolation reporting. Device and hook paths similarly resolve within a defined guest/control scope. Do not reinterpret an untrusted guest hook as arbitrary macOS execution.

### C. Bring native execution to the same workload contract where useful

The native VZ/Apple path may have performance advantages for some workloads. Keep it, measure it, and complete the supported profile rather than claiming universal equivalence prematurely. Native adapters should pass the same process/lifecycle/correctness fixtures. Distinguish implementation limitations from user-request errors. A native profile may be appropriate for isolated CI, while complex shared-namespace and rootless workflows use the Linux runtime profile.

Do not assume that a Rust reimplementation of runc is required to replace the user workflow. Upstream runc supplies a reference and a practical execution path; selected Micropod host/guest components can later be optimized with Rust if measured evidence justifies it. Maintaining an independent OCI runtime adds security, kernel-compatibility and regression obligations, and must be an explicit product investment.

## Differential qualification harness

Build this as an extension of #182's measurement/correctness infrastructure, with runtime-specific ownership and fixtures. It must produce an input digest, expected contract, requested/effective configuration, source and installed artifact identities, guest observations, raw event/stdio records, exit/error result and cleanup receipt for every case.

1. Pin runc, OCI spec, containerd, kernel/config and rootfs digests. Prefer the same guest kernel/rootfs when isolating adapter semantics; disclose unavoidable differences.
2. Run deterministic configuration fixtures against reference runc and each candidate profile. Compare normalized invariants, not incidental PIDs, timestamps or random names.
3. Use upstream runtime-tools as one input, not a blanket certification. Its documented validation targets a runtime CLI; a Micropod API needs a correctly defined adapter, and the test suite's feature/spec coverage must be reconciled with the chosen version. Pin the [runtime-tools revision](https://github.com/opencontainers/runtime-tools/blob/bd3b0bd00f44e15f0f1ff4130c61dbea1b1c56cc/README.md).
4. Add Micropod-specific cross-boundary cases: client cancellation before dispatch and after uncertain send; API/helper/shim death; guest death; late responses; independent owner changes; runtime restart; reused identifiers; unmount/cleanup interruption. Keep existing #176 and #90 owners.
5. Separate deterministic configuration checks, Linux integration, native Mac qualification and end-to-end Docker/Compose/Testcontainers suites. Mock wire tests cannot qualify kernel enforcement.
6. Reject false successes. Missing events, unknown exit status, swallowed input, ignored standard security controls and failed cleanup are result categories that fail required coverage. Preserve failure evidence and avoid automatically retrying an uncertain mutation.
7. After correctness passes, benchmark matched create-to-ready, exec-to-known-exit, signal-to-terminal, cancellation-to-reconciled-state and 1/10/50/100-workload density. Include p95, CPU, reclaimed host footprint, FDs and reliability. A faster client return is not faster completion if guest work remains unknown.

Record workload resources, VM resources and host overhead separately. The performance contract cannot substitute VM CPU count for Linux scheduler quota, or sum RSS and call it unique physical memory. Tests should prove resource-control effects before using them to claim a fair comparison.

## Work breakdown and existing ownership

The detailed candidate tickets accompany this document in the reconciliation workflow. They are intentionally runtime work packages, not another generic “runc support” checkbox:

| Key | Work package | Existing owners to extend |
|---|---|---|
| RT_CONTRACT | Versioned OCI/Docker capability contract and complete known-field translation | #136, #147 |
| RT_GUEST | Linux runc/containerd execution profile and task-service integration | #146, #141, #145, #183 |
| RT_PROCESS | Exec/attach/PTY/signals and process-configuration semantics | #147, #141 |
| RT_LIFECYCLE | Durable task identity, authoritative exits and ordered events | #66, #141, #176, #90 |
| RT_RESOURCES | Fractional CPU, cgroup v2, limits and live resource control | #136, #158 |
| RT_ISOLATION | Mount, namespace, privilege and rootless equivalence | #145, #154, #160, #165, #74 |
| RT_CONFORMANCE | Pinned differential conformance and real workload release gate | #182, #147 |

Kubernetes can consume these contracts once they exist. It is not a prerequisite for runtime parity. A release claiming replacement of the selected Linux workload profile must pass all required matrix rows; unsupported rows remain explicit blocking work until the product scope is deliberately revised.

## Source identities and verification boundary

- Micropod: `54980012eb47b458a7f7e1def616d3fa95c970a2`.
- OCI runtime-spec inspected main: `20f948a4a944629335518533250dd719fedd73f2`.
- runc inspected main: `b7dc1304ed9e18f14e626dc06374043b12cf355f`.
- containerd inspected main: `8abc4c7d223bf3da36f0d1c43ea39bc2aa1e2eca`.
- runtime-tools inspected master: `bd3b0bd00f44e15f0f1ff4130c61dbea1b1c56cc`.

These upstream commits are review references, not an instruction to ship unreleased main branches. Implementation chooses supported release artifacts and records exact versions. No runc test, native runtime, Docker fixture, kernel probe or performance measurement was executed during this source audit.

## Filed implementation issues

| Issue | Work package | Priority |
|---|---|---|
| [#201](https://github.com/castlemilk/micropod/issues/201) | [Runtime parity] Preserve known Docker/OCI semantics through every request adapter | P0 |
| [#202](https://github.com/castlemilk/micropod/issues/202) | [Runtime parity] Integrate a complete Linux runc/containerd execution profile | P0 |
| [#203](https://github.com/castlemilk/micropod/issues/203) | [Runtime parity] Complete exec, interactive attach, terminal and signal behavior | P0 |
| [#204](https://github.com/castlemilk/micropod/issues/204) | [Runtime parity] Persist authoritative task outcomes and ordered lifecycle events | P0 |
| [#205](https://github.com/castlemilk/micropod/issues/205) | [Runtime parity] Enforce cgroup v2 resources and preserve fractional CPU limits | P0 |
| [#206](https://github.com/castlemilk/micropod/issues/206) | [Runtime parity] Complete mount, namespace, privilege and rootless contracts | P0 |
| [#207](https://github.com/castlemilk/micropod/issues/207) | [Runtime parity] Add differential runc and Docker workload conformance gates | P0 |

These issues are part of the [core platform program](core-container-platform.md) and [tracker #180](https://github.com/castlemilk/micropod/issues/180). Required compatibility remains a release gate; source findings are not executed qualification results.
