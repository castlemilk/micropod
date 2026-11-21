# OrbStack investigation and Micropod reconciliation

**19 November 2026 · Source audit and implementation plan.** Tracker: [#180](https://github.com/castlemilk/micropod/issues/180).

**The primary roadmap is now the build platform, full Linux OCI/runc compatibility, and cache/VirtioFS correctness and performance.** Kubernetes is a downstream integration. The follow-up audit found substantial gaps behind existing interfaces, so code presence is not treated as completed compatibility. Extend the useful Micropod foundations, fix concrete defects, and qualify upstream-backed execution before selecting measured custom worker or Rust optimizations. Preserve independent-VM isolation as a distinct capability.

This package reconciles **86 original research items**, **40 existing roadmap issues** and **14 focused initial issues**, followed by **21 detailed core-platform issues (#195–215)**. It includes source-pinned runbooks for using Craft Anything to investigate OrbStack and rust-anything to evaluate bounded implementation changes. It contains **no newly measured performance results**, native OrbStack captures, installed tool integration or runtime changes.

## Read in this order

| Document | Purpose |
|---|---|
| [Core container platform](core-container-platform.md) | Authoritative revised priorities, architecture, delivery sequence and 21 implementation tickets |
| [Build platform](build-platform.md) | Native BuildService, Buildx/Compose/Bake, sessions, sources, exporters and BuildKit integration |
| [Runtime equivalence](runtime-compatibility.md) | Full Linux target, Docker/OCI/runc/containerd contracts, concrete gaps and conformance |
| [Cache and filesystem](cache-and-filesystem.md) | Context/solver/package/image caches, integrity, leases, APFS clones and VirtioFS coherence |
| [Core backlog JSON](core-backlog.json) | Detailed implementation scopes, acceptance criteria and actual dependency issue numbers |
| [Existing state](existing-state.md) | 24 pinned implementation references, the 40 issue dispositions, current ownership and concrete gaps |
| [Roadmap](roadmap.md) | All 86 original rows, correct issue mapping, phase dependencies and acceptance boundaries |
| [Craft Anything investigation](craft-anything-investigation.md) | Reviewed capabilities, exact staged commands, evidence capture, hypotheses and independent build specification |
| [rust-anything build-out](rust-anything-buildout.md) | Supported Go workflow, Swift/cgo limitations, extraction/characterization, experiment and rollout gates |
| [Benchmark plan](benchmark-plan.md) | Existing harness defects, equivalent comparison lanes, identities, timing, correctness, energy and statistics |
| [Crosswalk JSON](roadmap-crosswalk.json) | Machine-readable original rows and actual issue dispositions |
| [Evidence template](EVIDENCE-TEMPLATE.json) | Proposed sidecar provenance/experiment record; not the native Craft importer schema |

## Pinned identities and evidence boundary

| Subject | Inspected revision | What is established |
|---|---|---|
| Micropod | [`54980012eb47b458a7f7e1def616d3fa95c970a2`](https://github.com/castlemilk/micropod/commit/54980012eb47b458a7f7e1def616d3fa95c970a2) | Source/tree and selected tests/docs; current default branch was unchanged at final source refresh |
| Craft Anything | [`bbfd5177f0501fbef384fee69937cbef91329a2e`](https://github.com/storytold/craft-anything/commit/bbfd5177f0501fbef384fee69937cbef91329a2e) | Application/CLI/MCP source, evidence and capture contracts; declared v0.6.1/Rust 1.97 |
| rust-anything | [`98adbe29003a69783c727146d0c3fe637b174102`](https://github.com/erkamyaman/rust-anything/commit/98adbe29003a69783c727146d0c3fe637b174102) | Migration/characterization CLI/MCP/skill source; declared v1.5.1/Rust 1.97 |
| OrbStack | Public vendor documentation and engineering posts | Published behavior/claims; installed binary and contemporary benchmark remain unmeasured |

The audit environment is Linux. The two tools were not installed or executed; native macOS runtime tests and benchmarks were not run. Tool commands are staged recipes, with prerequisites identified. Source presence, tests present in the tree, author-reported PR measurements, signed release metadata and physical installed qualification are different evidence classes.

## Findings that change the implementation plan

1. **The build product is larger than a gRPC route.** #149 now owns a complete native BuildService and compatible Docker/Buildx/Compose/Bake workflows. The current code delegates through Apple's BuildKit-backed builder; inspect and reuse its supported contract before adding another owner. Sources, sessions, progress, cancellation, multi-platform outputs and cache administration all need explicit implementation. [Build audit](build-platform.md).
2. **A Docker socket does not establish runtime equivalence.** The source has concrete exec-user, attach-stdin, requested-signal, resource-translation and exit-outcome gaps. #147 and #201–207 define the complete Linux compatibility target and differential gates. A required unsupported feature blocks replacement completion. [Runtime audit](runtime-compatibility.md).
3. **Caching has correctness defects and separate layers.** Context keys omit relevant semantic metadata; a per-file clone success falls through into copying; chunk ingestion can return partial results; context byte accounting changes basis. #197 and #209–215 cover fixes, ownership, image reuse, mutable caches and metadata indexing. [Cache audit](cache-and-filesystem.md).
4. **VirtioFS optimization needs a supported control surface.** Direct Apple VZ shares, synchronized SharedFS views, immutable build sources and guest-native writable volumes have different semantics. #93/#160–168 remain their existing owners; measure metadata, copies, notifications, durability and actual storage effects before claiming custom caching or zero-copy behavior. [Filesystem design](cache-and-filesystem.md).
5. **Execution topology serves the compatibility contract.** #146/#183 cover Linux containerd/runc inside explicit trusted builder, project or isolated-job domains. A global shared-distro VM is not a prerequisite. Optional sharing must preserve the separately qualified isolated profile. [Core architecture](core-container-platform.md).
6. **Performance evidence is still missing.** #182 repairs the comparison harness and puts complete build, runtime and filesystem workloads first. Historical repository figures and vendor benchmarks are not contemporary comparative results. [Benchmark plan](benchmark-plan.md).
7. **Current owners remain authoritative.** #89 is completed; #90 owns workload continuity, #66 exit status, and #93 notifications. Open #135/#176/#177/#178 are not merged capabilities. #193 is closed without merge and folded into #178. Kubernetes readiness #179 can land independently; #187/#188 are downstream integrations. [Source and ownership inventory](existing-state.md).

## How the two requested tools fit

**Craft Anything:** use its ledger to record product behavior, vendor claims, explicit unknowns, evidence and findings. Read a known running test app's UI; the auto window-capture command launches and closes its target. Use persistent MCP for web captures, and check export completeness. Quantitative performance measurements remain in Micropod's own instrumented harness. [Investigation runbook](craft-anything-investigation.md), [#181](https://github.com/castlemilk/micropod/issues/181).

**rust-anything:** use profiling and characterization around one measured Go unit before writing a Rust comparison implementation. It has no Swift adapter. Its cgo bridge differs from Micropod's static `CGO_ENABLED=0` guest build, so it is initially an experiment adapter. Replay does not prove cancellation, concurrency, crash recovery or durability. A candidate event planner is only a proposal until profiling justifies it. [Build-out runbook](rust-anything-buildout.md), [#184](https://github.com/castlemilk/micropod/issues/184).

Neither tool supplies a VMM, Docker runtime or turnkey OrbStack implementation. Linking and pinning the tools is the documented integration here; no vendored tool code or production dependency was added.

## Recommended first implementation slice

Start installed-builder inventory and the compatibility/benchmark harness alongside the concrete context, process-control, clone, chunk-integrity and accounting repairs. Deliver one complete build-to-run flow through the native API and real Buildx clients, including private dependencies, cancellation, a runnable loaded result and correct warm-cache reuse. Expand that path to the full runtime/export/cache matrix, then optimize the measured filesystem, snapshot and worker costs. Kubernetes consumes the qualified platform later.

The 86 original research identities remain traceable. The [core program](core-container-platform.md) supersedes the initial ordering; it does not assert that any of the new implementation issues are already complete.
