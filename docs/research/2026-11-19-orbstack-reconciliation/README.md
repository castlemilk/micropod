# OrbStack investigation and Micropod reconciliation

**19 November 2026 · Source audit and implementation plan.** Tracker: [#180](https://github.com/castlemilk/micropod/issues/180).

Micropod already has much of the infrastructure proposed by the original roadmap. The practical path is to extend and qualify those components, repair concrete correctness gaps, then use measured workload evidence to decide whether a shared-kernel engine or selected Rust component is worth adding. Preserve independent-VM isolation as a distinct product capability.

This package reconciles **86 original research items**, **40 existing roadmap issues** and **14 focused new issues**. It includes source-pinned runbooks for using Craft Anything to investigate OrbStack and rust-anything to evaluate bounded implementation changes. It contains **no newly measured performance results**, native OrbStack captures, installed tool integration or runtime changes.

## Read in this order

| Document | Purpose |
|---|---|
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

1. **Existing foundation:** RuntimeEngine/EngineRegistry, native Apple transport, direct sandbox VZ, Docker socket/shim, machine commands, Rosetta selection, VirtioFS/SharedFS, APFS clones/checkpoints, networking and k3s are already present. Recreating these would duplicate work. See [source inventory](existing-state.md).
2. **New architecture:** A multi-distro shared Linux kernel is a new trust profile. OrbStack documents that even its isolated machines share that kernel. Add such a mode only through [#183](https://github.com/castlemilk/micropod/issues/183) and preserve Micropod's independent VMs. [Vendor architecture](https://docs.orbstack.dev/architecture), [isolated machines](https://docs.orbstack.dev/machines/isolated).
3. **Concrete current gaps:** Buildx gRPC/session support [#149](https://github.com/castlemilk/micropod/issues/149); live filesystem correctness [#93](https://github.com/castlemilk/micropod/issues/93)/[#161](https://github.com/castlemilk/micropod/issues/161); sandbox UDP/IPv6 forwarding [#174](https://github.com/castlemilk/micropod/issues/174); automatic domains/HTTPS [#185](https://github.com/castlemilk/micropod/issues/185)/[#186](https://github.com/castlemilk/micropod/issues/186); mounted reverse filesystem [#164](https://github.com/castlemilk/micropod/issues/164); persistent Kubernetes lifecycle [#187](https://github.com/castlemilk/micropod/issues/187).
4. **Deterministic source bug:** K8sService.status uses a substring match that accepts `NotReady` as `Ready`. [#179](https://github.com/castlemilk/micropod/issues/179) defines structured-condition parsing and negative cases. This is static proof of the code defect, not a claimed live reproduction.
5. **Existing owners:** #89 is completed, #90 remains the workload-continuity owner, #93 retains notification work, and #162 is its duplicate. Open #135/#176/#177/#178/#193 are not merged or installed capabilities. Do not recreate their storage/cancellation/update changes.
6. **Performance evidence:** Existing scripts hide some first failures, mix readiness/memory scopes and contain destructive fixed-name cleanup. Repair the measurement contract in [#182](https://github.com/castlemilk/micropod/issues/182) before claiming an improvement. Historical repository medians and OrbStack's August 2023 vendor benchmark are not contemporary comparative results.

## How the two requested tools fit

**Craft Anything:** use its ledger to record product behavior, vendor claims, explicit unknowns, evidence and findings. Read a known running test app's UI; the auto window-capture command launches and closes its target. Use persistent MCP for web captures, and check export completeness. Quantitative performance measurements remain in Micropod's own instrumented harness. [Investigation runbook](craft-anything-investigation.md), [#181](https://github.com/castlemilk/micropod/issues/181).

**rust-anything:** use profiling and characterization around one measured Go unit before writing a Rust comparison implementation. It has no Swift adapter. Its cgo bridge differs from Micropod's static `CGO_ENABLED=0` guest build, so it is initially an experiment adapter. Replay does not prove cancellation, concurrency, crash recovery or durability. A candidate event planner is only a proposal until profiling justifies it. [Build-out runbook](rust-anything-buildout.md), [#184](https://github.com/castlemilk/micropod/issues/184).

Neither tool supplies a VMM, Docker runtime or turnkey OrbStack implementation. Linking and pinning the tools is the documented integration here; no vendored tool code or production dependency was added.

## Recommended first implementation slice

Land the small structured-readiness repair; finish the existing cancellation/volume/update work under its current owners; qualify live notifications; repair benchmark validity and collect a versioned baseline. Then prioritize Buildx and the file/network/Kubernetes user journeys. Use those results to decide shared-kernel density and the first Rust experiment. Every performance experiment has a predeclared semantic gate, matched baseline, resource budget and rollback.
