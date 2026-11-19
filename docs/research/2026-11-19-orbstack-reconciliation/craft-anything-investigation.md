# Craft Anything for an evidence-led OrbStack investigation

**Status: source audit completed on 19 November 2026; native investigation and benchmarks not executed.** This document records inspected public source and a proposed investigation workflow. No third-party application, dependency installer, or capture script was executed. `craft-anything-cli` was not found on this environment's PATH; no Craft Anything MCP tools were exposed. The available host is Linux, so the macOS observations below remain a defined qualification step. **Every command and tool invocation below is staged guidance, not an execution record.**

Related documents: [overview](README.md), [existing implementation](existing-state.md), [reconciled roadmap](roadmap.md), [benchmark protocol](benchmark-plan.md), [Rust build workflow](rust-anything-buildout.md), and [proposed evidence template](EVIDENCE-TEMPLATE.json).

## Recommendation

Use Craft Anything as the investigation ledger and controlled observation tool for OrbStack's user-facing behavior. Keep Micropod's implementation and performance harness in Micropod's repository. Craft Anything can organize reproducible evidence and generate reports; it is not a virtual-machine runtime, a proven reconstruction of OrbStack, or a substitute for native benchmark instrumentation.

The repository is an actual Rust application with a desktop GUI, CLI, and MCP server. It contains no `SKILL.md` in the inspected tree. Do not describe it as an installed agent skill. The useful implementation is the explicit distinction between observations, deterministic derivations, hypotheses, unknowns, and evidence-backed findings. A clean-room specification can then be passed to the build owner without copying proprietary implementation details or product assets.

## Pinned repository and inspected implementation

Repository: [storytold/craft-anything](https://github.com/storytold/craft-anything).

Commit: [`bbfd5177f0501fbef384fee69937cbef91329a2e`](https://github.com/storytold/craft-anything/commit/bbfd5177f0501fbef384fee69937cbef91329a2e), the current default-branch commit returned during this audit. Commit timestamp: 2026-11-19 00:06:09 UTC. The workspace declares version `0.6.1`, Rust edition `2024`, minimum Rust `1.97`, and license `MIT OR Apache-2.0`. These are source declarations, not confirmation that a corresponding release binary was installed or tested.

| Source | What the source establishes |
|---|---|
| [README](https://github.com/storytold/craft-anything/blob/bbfd5177f0501fbef384fee69937cbef91329a2e/README.md) | Early-alpha product, Study → Build → Check → Ready workflow; app, CLI and MCP share one engine; builder and inspection are distinct. |
| [Cargo.toml](https://github.com/storytold/craft-anything/blob/bbfd5177f0501fbef384fee69937cbef91329a2e/Cargo.toml) | Workspace version/toolchain/license, internal crate boundaries, pinned `craft-libs` git dependencies and a vendored graphics patch. |
| [Clean-room allowlist](https://github.com/storytold/craft-anything/blob/bbfd5177f0501fbef384fee69937cbef91329a2e/crates/engine/src/clean_room.rs) | Which engine tools are permitted when `--clean-room` is selected. Native file/decompiler tools require Deep mode. |
| [Investigation tools](https://github.com/storytold/craft-anything/blob/bbfd5177f0501fbef384fee69937cbef91329a2e/crates/engine/src/tools/investigation_tools.rs) | Structured brief, plan, hypotheses, findings, handoff; findings require existing evidence IDs; revision checks protect plan/finding updates. |
| [Evidence types](https://github.com/storytold/craft-anything/blob/bbfd5177f0501fbef384fee69937cbef91329a2e/crates/evidence/src/lib.rs) | Content-derived IDs; confidence, authority, subject, environment, limitations, coverage, location and evidence links. |
| [Session tools](https://github.com/storytold/craft-anything/blob/bbfd5177f0501fbef384fee69937cbef91329a2e/crates/engine/src/tools/session_tools.rs) | JSON bundle import/export with record-integrity checks; export reports unloaded evidence; unknown-question records. |
| [Report tools](https://github.com/storytold/craft-anything/blob/bbfd5177f0501fbef384fee69937cbef91329a2e/crates/engine/src/tools/report_tools.rs) | Markdown and self-contained HTML generated from findings and evidence; optional atomic writes to absolute paths. |
| [Native UI tools](https://github.com/storytold/craft-anything/blob/bbfd5177f0501fbef384fee69937cbef91329a2e/crates/engine/src/tools/apple_runtime.rs) | Read a running app's accessibility tree by PID, optionally capture a screenshot; scripted UI observation; macOS/Windows host gating. |
| [Window capture](https://github.com/storytold/craft-anything/blob/bbfd5177f0501fbef384fee69937cbef91329a2e/crates/engine/src/tools/window_tools.rs) | `native_window_capture` starts a program and closes it afterward. It must not be treated as a passive screenshot operation. |
| [CLI implementation](https://github.com/storytold/craft-anything/blob/bbfd5177f0501fbef384fee69937cbef91329a2e/apps/craft-anything-cli/src/main.rs) | `commands`, `capabilities`, `--project`, `--clean-room`, `mcp --restricted`, JSON tool arguments and report export command contracts. |

The license is permissive, but the repository separately excludes ArtCraft marks from the code license and lists assets under their own licenses. Using the tool does not grant rights to OrbStack's code, assets or branding. See [NOTICE](https://github.com/storytold/craft-anything/blob/bbfd5177f0501fbef384fee69937cbef91329a2e/NOTICE), [MIT license](https://github.com/storytold/craft-anything/blob/bbfd5177f0501fbef384fee69937cbef91329a2e/LICENSE-MIT), and [asset attribution](https://github.com/storytold/craft-anything/blob/bbfd5177f0501fbef384fee69937cbef91329a2e/ATTRIBUTION.md). Avoid a dependency on the GUI; pin the CLI release or source plus lockfile for investigation reproducibility.

## Important limitations discovered

1. **Clean room is an application policy, not an OS sandbox.** The allowlist limits Craft Anything's own tools. Builders act with their own permissions. A project using an external agent therefore needs an appropriate workspace and the agent's existing sandbox; the mode label alone does not prove confinement. The repository documents different enforcement coverage for different agent adapters.
2. **Tool existence is not native qualification.** The [tool-status page](https://github.com/storytold/craft-anything/blob/bbfd5177f0501fbef384fee69937cbef91329a2e/docs/tool-status.md) records Apple static verification against synthetic Mach-O/plist inputs and runtime tools not executed in that audit. No result there establishes complete OrbStack analysis.
3. **The README is less precise than deeper status documentation.** It says the Codex adapter has not been verified on a real install; [docs/codex.md](https://github.com/storytold/craft-anything/blob/bbfd5177f0501fbef384fee69937cbef91329a2e/docs/codex.md) records a narrow live resume smoke test on 14 November 2026. That verifies session continuation, not a complete reconstruction or GUI/performance result. Cite the exact scope, not an unqualified “works with Codex.”
4. **Web captures need one persistent session.** Separate `web-site-open` and `web-site-capture` CLI processes do not share the browser. The tool-status documentation explicitly requires a persistent MCP session, the app, or the rebuild workflow.
5. **Native UI reading needs native prerequisites.** `runtime_ui_read` requires macOS/Windows. The macOS screenshot path needs existing Screen Recording permission; missing permission becomes a limitation, not an automatic prompt. Accessibility and helper execution also need qualification. Its tool declares execution/UI effects, so normal consent handling still applies.
6. **Do not use auto-launch-and-close capture on an active runtime.** `native_window_capture` closes the process it launched. Inspect an already running dedicated test instance with `runtime_ui_read`, and reserve lifecycle scenarios for an isolated test account with known workload ownership.
7. **Evidence hashes prove integrity, not truth.** A hash cannot validate an analyst's inference. Keep the source authority and claim type explicit. In the evidence crate, the `clean_room` environment field still has a comment describing built-in versus external decompiler use; preserve the actual tool list/mode and collection provenance in an additional run manifest rather than treating that boolean as legal or methodological certification.
8. **Large exports require a completeness check.** `core_evidence_export` reports `not_loaded`. Archive the entire `.cany` project or explicitly load/export all records; do not assume a JSON bundle includes the entire stored investigation when that value is nonzero.

## OrbStack facts to carry into the reconciled roadmap

The distinctions below are essential because they change Micropod's design and ticket dependencies.

| Claim | Evidence status and engineering consequence |
|---|---|
| OrbStack uses one Linux kernel for the Docker engine and ordinary Linux machines | Explicitly vendor-documented. Its “machines” are not independent VMs. Match user-visible distro behavior separately from kernel-isolation requirements. [Architecture](https://docs.orbstack.dev/architecture) |
| OrbStack's isolated machines provide a separate guest kernel | False under its documented security model. Isolation removes host integrations but retains the shared kernel. Micropod's independently isolated microVM mode is a distinct capability, not something to delete for parity. [Isolated machines](https://docs.orbstack.dev/machines/isolated) |
| OrbStack is just `Virtualization.framework` with a small Swift wrapper | Not established. OrbStack's own May 2024 account says version 1.6 rewrote its virtualization stack. The exact current low-level host API composition is not proved by the public architecture page. Do not turn a guessed mechanism into a mandatory implementation ticket. [Filesystem/virtualization rewrite](https://orbstack.dev/blog/fast-filesystem) |
| VirtioFS alone gives OrbStack-equivalent mounts | Not established. The public material describes a base protocol plus custom caching and reduced crossing overhead. Qualify metadata coherence, notifications and durable writes before optimizing. A mount existing is not parity. [Architecture](https://docs.orbstack.dev/architecture), [filesystem blog](https://orbstack.dev/blog/fast-filesystem) |
| Dynamic memory means configuring a balloon device | Not established. The vendor describes tracking guest RAM use and returning excess to macOS; the implementation is unspecified. Measure host physical footprint and pressure after workload release rather than inferring reclaim from guest `free`. [Dynamic memory](https://orbstack.dev/blog/dynamic-memory) |
| The advertised idle CPU and historical benchmarks are current measured acceptance baselines | They are vendor claims and historical results. The benchmark methodology page identifies August 2023 product versions and an M1 Max host. Re-run contemporary binaries on matched conditions. [Efficiency](https://docs.orbstack.dev/efficiency), [benchmarks](https://docs.orbstack.dev/benchmarks) |
| An 8 TB `data.img` consumes 8 TB on disk | False: the FAQ describes a sparse logical image. Track logical capacity, allocated blocks, APFS clone/snapshot sharing and actual reclaim separately. A large sparse maximum also avoids requiring online capacity growth early. [FAQ](https://docs.orbstack.dev/faq) |
| Intel translation on Apple Silicon is equivalent to an x86 Linux kernel | False. Apple's VZ documentation describes Intel user binaries within an ARM Linux VM. Keep native ARM, translated amd64 and Intel-host support in separate test lanes. The current Apple page also distinguishes older Rosetta installation from macOS 27 integrated translation. [Apple documentation](https://developer.apple.com/documentation/virtualization/running-intel-binaries-in-linux-vms) |

No analysis of the proprietary OrbStack binary was performed. Public issue reporters' guesses about linked frameworks or undocumented internals were not promoted to facts. A later binary investigation, if needed and permitted, should be a separately scoped Deep-mode effort and should not contaminate the clean-room build specification.

## Concrete investigation workflow

### 1. Freeze identities and define questions

Create one investigation project per OrbStack version/OS/hardware lane. Record exact binary version/build, host model/CPU/RAM, macOS build, filesystem, power mode, runtime settings, image digests and fixture commits. Record the Micropod source commit independently. A report cannot use “latest” as its identity.

Start with bounded questions, for example:

- Which lifecycle transitions are visible when Docker, Kubernetes and a Linux distro run concurrently?
- What behavior do published TCP/UDP ports, local DNS, SSH and host filesystem integration expose?
- How are conflicting ports, denied shares, low disk space, translated programs and host sleep handled?
- Which resource curves differ between trusted shared-kernel development and isolated CI execution?
- Which differences are actually caused by Micropod's current implementation rather than by differing workloads or cache state?

### 2. Check the reviewed installation and create the ledger

These commands are verified against the pinned CLI source, but were not run in this environment:

```sh
craft-anything-cli --version
craft-anything-cli --clean-room capabilities
craft-anything-cli --clean-room commands
craft-anything-cli --clean-room --project /absolute/audit/orbstack.cany \
  core-brief-write --json @/absolute/audit/brief.json
```

Example `brief.json` uses the actual `BriefParams` fields:

```json
{
  "question": "Which observable OrbStack behaviors should Micropod match, and which current Micropod components already satisfy them?",
  "purpose": "Interoperability, performance evaluation, and an independent implementation plan",
  "targets": ["https://docs.orbstack.dev/architecture", "versioned OrbStack test instance", "pinned Micropod source"],
  "constraints": ["Use public documentation and user-visible behavior", "Label vendor claims separately from measured outcomes", "No production runtime lifecycle actions", "Keep all raw measurement identities"],
  "done_when": "Every required capability has evidence, a Micropod mapping, a falsifiable gap or an explicit unknown, and an acceptance test"
}
```

Use `core_investigation_show` to get the current revision before `core_plan_update`; pass `based_on_revision` when updating. Leave unobserved claims as hypotheses or unknowns, not settled findings.

### 3. Capture public documentation and visible product behavior

For documentation captures, use a persistent session:

```sh
craft-anything-cli --clean-room --project /absolute/audit/orbstack.cany \
  mcp --restricted --allow-web --allow-capture
```

Within that session, use `web_site_open`, then `web_site_capture` with an absolute `output_directory`. Capture the observed page URL, access time, visible-text evidence and version applicability. Public documentation establishes what the vendor says; it does not independently establish runtime behavior.

For the native app, use the app/MCP's normal consent flow on the dedicated macOS test instance. Call `runtime_ui_read` with its known PID, `screenshot: true`, `accessibility: true` and a bounded `max_nodes`. Do not guess element identifiers: inspect the resulting tree before defining a walkthrough. `runtime_ui_walkthrough_record` records exact steps and their actual outcomes; a missing element or denied permission is an incomplete observation.

Capture the supported journeys: fresh app → runtime readiness; image pull/run/logs/exec/exit; Compose services; mount edits and notification delivery; named volume browsing; machine create/exec/SSH/stop; Kubernetes enable/readiness/ingress; resource limit changes; failure and recovery screens. Save screenshots and step outcomes as evidence, while omitting credentials, unrelated projects and private logs.

### 4. Use a separate harness for quantitative measurements

Craft Anything's UI similarity or completion score is not a virtualization benchmark. Follow the [benchmark protocol](benchmark-plan.md) using explicit native tools and Micropod-owned fixtures for CPU time, wakeups, memory footprint, allocated disk blocks, I/O latency, Docker API behavior and network throughput. Save raw results, not only summary charts.

For each trial preserve elapsed time source, start/end readiness definitions, exit status, workload correctness checks, cache policy, repetition number, warmup, hardware/OS/product settings and all product-process accounting. Run one contender at a time in randomized blocks. Include default-user settings as one lane and resource-matched settings as another. Keep native ARM and translated amd64 separate. Compare speed only at equal observable semantics and durability. Report dispersion and uncertainty; a noisy or insufficient trial set is inconclusive.

Suggested experiment families:

| Experiment | What it resolves |
|---|---|
| 0, 1, 10, 25 short-lived containers and distro processes | Fixed/per-workload overhead and the point where shared-kernel density becomes beneficial. |
| Allocate, touch, release memory; repeat after idle and host pressure | Guest free memory versus host physical reclaim, reclaim delay, swap/compression side effects. |
| File create/stat/readdir/rename/delete storms and atomic save | Metadata performance and notification correctness; re-evaluate missed events separately from throughput. |
| `fsync`/database durability and failure recovery | Whether apparent gains are caused by weaker persistence semantics. |
| Cold boot, warm boot, API activation, first container and first useful response | Actual user wait boundaries rather than process-exists timing. |
| TCP, UDP, DNS, local domains, VPN/split DNS, sleep/wake | Fast paths plus ordinary development connectivity and recovery. |
| Container exit/attach/wait, Compose and Kubernetes readiness | End-to-end compatibility; a speedup cannot compensate for wrong status or API results. |

### 5. Convert evidence into findings and a build specification

Use `core_hypothesis_record` for mechanism guesses; include the prediction that would refute them. Use `core_unknown_add` for missing facts and identify the probe that could settle each. Use `core_finding_record` only with actual existing evidence IDs and the correct `observed`, `derived` or `inferred` confidence. A documented vendor claim should say “the vendor documents X,” not “we measured X.”

Example sidecar evidence-index row for this source-only audit (this is **not** a native Craft Anything evidence record and must not be passed directly to its importer):

```json
{
  "record_id": "DOC-ORB-001",
  "claim_type": "vendor_documentation",
  "statement": "OrbStack's architecture documentation says its Linux machines share a kernel and are not independent VMs.",
  "source_url": "https://docs.orbstack.dev/architecture",
  "accessed_date": "2026-11-19",
  "collector": "public-source web retrieval",
  "craft_evidence_id": null,
  "confidence_in_documented_claim": "observed",
  "independent_runtime_verification": "not_performed",
  "version_applicability": "unversioned documentation; qualify against selected binary",
  "follow_up": "Record guest kernel identities and the user-visible machine lifecycle on a dedicated test installation."
}
```

Start a new sidecar from [EVIDENCE-TEMPLATE.json](EVIDENCE-TEMPLATE.json) for each source record or experiment. Keep `execution_status` as `planned` until collection actually occurs, and retain nulls for unknown identities or results. The template is project-owned bookkeeping, not the Craft Anything import schema.

For an actual capture, use the engine-returned evidence ID and keep the native fields `subject`, `operation`, `params`, `result`, `confidence`, `authority`, `environment`, `limitations`, `coverage`, `locations` and `links`. A performance adapter must build valid evidence through the pinned evidence crate (or a validated equivalent), include raw measurement hashes/paths and preserve the tool's own environment. Do not label an external CSV as a natively captured Craft record. Hash validation does not replace correct classification.

Three distinct examples:

- **Observation:** “In trial 12, a Mac-side rename became visible to the guest watcher after the recorded delay”; cite that exact run, workload checks and instrument resolution.
- **Vendor claim:** “The architecture page describes dynamic file caching”; cite the page and access date, with independent runtime verification marked absent.
- **Hypothesis:** “Avoiding duplicate metadata work may reduce Micropod's bind-mount latency”; predict fewer metadata round trips and lower paired-run latency without stale reads or missing events. Until measured, do not record the mechanism as an observed fact.

A finding should link to a Micropod source path/commit, current issue or PR, capability status, missing behavior, acceptance fixture and candidate implementation seam. Status vocabulary should be explicit: source-present, unit-tested, native-qualified, delivered, partial, proposed, superseded, unknown. This avoids calling an existing source type “complete” or generating another duplicate implementation ticket.

Export the report after evidence collection:

```sh
craft-anything-cli --clean-room --project /absolute/audit/orbstack.cany \
  report --out /absolute/audit/orbstack-investigation.md
craft-anything-cli --clean-room --project /absolute/audit/orbstack.cany \
  report --html --out /absolute/audit/orbstack-investigation.html
craft-anything-cli --clean-room --project /absolute/audit/orbstack.cany \
  core-evidence-export --json '{"path":"/absolute/audit/evidence.json","overwrite":false}'
```

Retain the `.cany` project alongside the export and check `not_loaded`. Source links and raw benchmark paths belong in the final Micropod report even when Craft Anything emits its own evidence IDs. Do not generate fake `ev_…` IDs or claim this runbook is an already populated native evidence project.

## Recommended documentation package

| Document | Responsibility |
|---|---|
| [README.md](README.md) | Scope, audit date, pinned inputs, evidence status and navigation. |
| [existing-state.md](existing-state.md) | Current Micropod source, tests and native evidence; distinguish a declared interface from working behavior. |
| [roadmap.md](roadmap.md) | Requirement and issue reconciliation, canonical work owners, remaining gaps, dependencies and architecture decisions. Preserve the isolated backend while evaluating whether a trusted shared-kernel backend is justified. |
| This document | Craft Anything qualification, public-source investigation, command contracts and the proposed handoff. A later populated investigation should add inputs, outputs, state transitions, error conditions and observable security boundaries. |
| [EVIDENCE-TEMPLATE.json](EVIDENCE-TEMPLATE.json) | Proposed sidecar provenance and experiment fields. It is an unpopulated template, not a native Craft Anything evidence bundle or a completed observation. |
| [benchmark-plan.md](benchmark-plan.md) | Workload fixtures, compared lanes, raw-result index, correctness gates, uncertainty and reproduction commands. |
| [rust-anything-buildout.md](rust-anything-buildout.md) | Bounded implementation slices, existing Rust integration points, dependencies, regression checks and rollback. Language choice must follow the measured problem. |

Archive each future native investigation's `.cany` project, source manifest, captures, raw measurements and generated reports together. These future run artifacts supplement this source audit; the presence of a plan or template does not establish that a capture occurred.

## Backlog consequences

Apply these dispositions through the canonical items in the [reconciled roadmap](roadmap.md), using the source and test status in [existing-state.md](existing-state.md).

- Replace “prototype vfkit AND implement a native VZ backend” as unconditional sequential work with one comparative backend spike, unless repository gaps independently justify both.
- Preserve independent-kernel isolation as a first-class existing or retained capability. A trusted shared VM can be an additional profile, not a silent replacement for Cuttlefish workload isolation.
- Define machine and runtime semantics before choosing a home-grown PID 1 or system-container supervisor. The public product behavior does not require duplicating an undocumented custom init.
- Change VirtioFS/cache tickets to measurement-plus-correctness work against existing sharing implementation; separate notification repair from cache throughput and UID/path mapping.
- Change dynamic-memory and disk-growth tickets into capability investigations before hard commitments. Supported VZ APIs and host behavior must be established on the supported OS matrix.
- Attach the benchmark baseline first, but avoid turning vendor numbers into guarantees. Set performance targets after the first valid matched runs, with explicit correctness and resource budgets.
- Add a bounded Craft investigation/tool-qualification item only if not already covered by the reconciliation epic. Deliverable: actual `.cany` ledger + reports + raw source/measurement manifest on a dedicated macOS instance. This source-audit document is ready now; that native capture is not.

## Research checks performed

- GitHub connector fetched the repository metadata, current default-branch commit, full recursive tree (not truncated), and the source files linked above at the pinned commit.
- Source schemas were examined for CLI invocation, mode allowlist, native observation effects, evidence validation, report generation and session persistence.
- Primary OrbStack architecture, isolated-machine, FAQ, efficiency and benchmark pages plus its memory/filesystem engineering posts were read. Apple translation documentation was checked to avoid conflating user-space translation with full x86 virtualization.
- No local build, package install, GUI run, macOS capture, OrbStack benchmark, proprietary binary inspection or external issue change by the Craft source-inspection subtask was performed by this research task.

## Completion gate for the native follow-up

The investigation is ready for implementation handoff when each accepted behavior links to a real source or observation, each runtime result identifies its product version and host, each measurement retains raw data and correctness outcomes, and each proposed change maps to an existing Micropod capability or a canonical gap in [roadmap.md](roadmap.md). Open questions remain explicit. Native qualification and outperformance claims cannot be closed by this source audit.
