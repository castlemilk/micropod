# Rust build-out with rust-anything

Status: **documentation and proposed evaluation only**. Research date: 19 November 2026. Read-only source inspection; no tool installation, migration, runtime launch, benchmark run or production mutation was performed.

[Research index](README.md) · [Existing state](existing-state.md) · [Reconciled roadmap](roadmap.md) · [OrbStack investigation](craft-anything-investigation.md) · [Benchmark plan](benchmark-plan.md)

Core implementation contracts: [container platform priorities](core-container-platform.md), [native build platform and Buildx](build-platform.md), [OCI/runc equivalence](runtime-compatibility.md), and [cache/VirtioFS behavior](cache-and-filesystem.md).

## Recommendation

Use rust-anything as a bounded **characterization and port-validation workflow** for one profiled, importable Go unit, or use its methodology with an explicitly maintained Swift-to-C test adapter. Keep SwiftUI, Apple framework integration, XPC, runtime ownership and the existing public contracts in their present implementation until measurements justify a particular replacement. The tool does not provide a hypervisor, Linux kernel, container engine, VirtioFS backend or automatic code translator.

The strongest near-term deliverable is a source-pinned evaluation with a declared go/no-go result. A Rust rewrite is not itself an optimization. In particular, this repository's example speedups are upstream results for search/string workloads, not measurements of Micropod, OrbStack, filesystem sharing or virtualization.

The product work comes first: complete native build ownership and Buildx interoperability, OCI/runc execution, and correct cache/VirtioFS behavior. Micropod can provide a native BuildService while reusing its current Apple BuildKit-backed builder or a qualified upstream service; upstream runc/containerd can provide the complete Linux execution path. Neither requires a Rust rewrite. Kubernetes qualification follows these contracts and is not a prerequisite for a useful build/runtime implementation slice.

## Source identity and verified tool capabilities

| Item | Observed value | Evidence |
|---|---|---|
| rust-anything revision | `98adbe29003a69783c727146d0c3fe637b174102` | [Commit](https://github.com/erkamyaman/rust-anything/commit/98adbe29003a69783c727146d0c3fe637b174102) |
| Package version/toolchain | `1.5.1`, Rust edition `2024`, minimum declared Rust `1.97` | [Cargo.toml](https://github.com/erkamyaman/rust-anything/blob/98adbe29003a69783c727146d0c3fe637b174102/Cargo.toml) |
| License | MIT, copyright 2026 Erkam Yaman | [LICENSE](https://github.com/erkamyaman/rust-anything/blob/98adbe29003a69783c727146d0c3fe637b174102/LICENSE) |
| Delivery | Rust CLI, stdio MCP server, agent skill; `setup` changes supported agent configuration and creates backups | [README](https://github.com/erkamyaman/rust-anything/blob/98adbe29003a69783c727146d0c3fe637b174102/README.md), [install](https://github.com/erkamyaman/rust-anything/blob/98adbe29003a69783c727146d0c3fe637b174102/docs/install.md) |
| Supported unit languages | TypeScript/JavaScript, Python, C, Go, Ruby, Java. PHP and C# have limited whole-app preview support | [Language enum and dispatch](https://github.com/erkamyaman/rust-anything/blob/98adbe29003a69783c727146d0c3fe637b174102/src/lang/mod.rs) |
| Swift support | No Swift entry in `Lang`, extension discovery, bridge implementation or profiler dispatch | [Language source](https://github.com/erkamyaman/rust-anything/blob/98adbe29003a69783c727146d0c3fe637b174102/src/lang/mod.rs), [profile dispatch](https://github.com/erkamyaman/rust-anything/blob/98adbe29003a69783c727146d0c3fe637b174102/src/profile.rs) |
| Go bridge | Generated Go wrapper calling Rust through cgo, with generated wire representation; the Rust replay driver explicitly enables `CGO_ENABLED=1` | [Go harness](https://github.com/erkamyaman/rust-anything/blob/98adbe29003a69783c727146d0c3fe637b174102/src/harness_go.rs) |
| Go profiling | A `go test` workload with CPU profiling, not arbitrary running daemon attachment | [profile.rs](https://github.com/erkamyaman/rust-anything/blob/98adbe29003a69783c727146d0c3fe637b174102/src/profile.rs) |
| Validation status | Upstream calls Go unit porting verified on Go's `path` package; its profiler is listed as fixture-tested; MCP server is fixture-tested | [STATUS.md](https://github.com/erkamyaman/rust-anything/blob/98adbe29003a69783c727146d0c3fe637b174102/docs/STATUS.md) |
| Micropod revision inspected | `54980012eb47b458a7f7e1def616d3fa95c970a2` | [Commit](https://github.com/castlemilk/micropod/commit/54980012eb47b458a7f7e1def616d3fa95c970a2) |

The workflow skill was read in full: [skills/rust-anything/SKILL.md](https://github.com/erkamyaman/rust-anything/blob/98adbe29003a69783c727146d0c3fe637b174102/skills/rust-anything/SKILL.md). The task here is investigation and documentation, not an instruction to start whole-app migration. The skill's whole-app approval sequence therefore does not prevent completing this audit.

## Concrete compatibility with the code already in Micropod

1. **The host is a substantial Swift application.** Its SwiftPM package declares Swift 6.2, macOS 26, app/CLI/API/Docker shim/shared-filesystem/benchmark/runtime-host products and Containerization `0.42.0`. This is not an empty runtime project. Existing `MicropodRuntime`, `MicropodCore` and UI should be the extension points. [Manifest](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Package.swift)

2. **The Linux helper has a portability contract that conflicts with the default Go bridge.** It is a static Linux ARM64 Go executable, built with `CGO_ENABLED=0`, used for file operations, watches and an idle process even inside distroless workloads. The source is Linux-only `package main`, with unexported command helpers. rust-anything's generated Go driver imports a package and enables cgo for its Rust wrapper. Pointing the tool at the current guest directory is not a drop-in migration. A pure importable unit must first be extracted, or a separate CLI characterization adapter must be written. [Guest entry point](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/guest/main.go), [static build](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/scripts/build_guest.sh), [Go driver](https://github.com/erkamyaman/rust-anything/blob/98adbe29003a69783c727146d0c3fe637b174102/src/harness_go.rs)

3. **Host sharing already uses native mechanisms.** `ChunkHash.swift` uses CryptoKit SHA256; `SharedViewSync` uses APFS `clonefile`, atomic rename, per-file content hashes and a last-exchanged map; `FSEventsWatcher` wraps macOS FSEvents. Rust alone will not remove OS event-delivery latency, filesystem I/O or cross-VM round trips, and replacing a native cryptographic implementation is not a grounded first optimization. Profile enumeration, hash reads, batching and invalidation before selecting a port. [ChunkHash](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodSharedFS/ChunkHash.swift), [sync](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodSharedFS/SharedViewSync.swift), [watcher](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodSharedFS/FSEventsWatcher.swift)

4. **The guest watch path is a real candidate for investigation, not a proven hotspot.** `watch.go` reads Linux inotify events into a 64 KiB buffer, uses unsafe pointer decoding, tracks watches and emits JSON lines; modifications to the same file are coalesced within 50 ms. The runtime/syscall layer and live mutable state make blindly recording generated calls inappropriate. A pure function for event decoding/normalization and planning watch changes is a narrower potential boundary, after its contract and baseline have been extracted. [watch.go](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/guest/watch.go)

5. **Benchmarks already exist.** `MicropodBench`, `bench-runtimes`, `bench-compose`, `bench-shim` and API contention tasks are present. Extend these with machine-readable source/toolchain/environment metadata and a controlled OrbStack adapter instead of replacing them. The Taskfile also still contains two `cli` entries; resolve the existing catalog issue before trusting task enumeration. Source presence does not prove recent real-device results. [Taskfile](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Taskfile.yml)

6. **The build backend already exists indirectly.** `ImageService.build` invokes `container build`, whose upstream implementation uses a BuildKit builder utility VM. Inventory the installed CLI/builder-shim/BuildKit and supported interfaces before adding another daemon. Native job ownership, structured progress, session grants, cancellation and outputs belong in Micropod even when upstream performs the solve. BuildKit's worker and executor integration contracts are version-tied Go interfaces; rust-anything does not generate a compatible worker. [Current build service](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodCore/Services/ImageService.swift), [Apple builder commands](https://github.com/apple/container/blob/main/docs/command-reference.md), [pinned worker interface](https://github.com/moby/buildkit/blob/c64bdcd1e0946854757ebb9580518ddf38490011/worker/worker.go).

## Fix the concrete source defects before choosing a port

These repairs have direct source evidence and belong to their existing build/runtime/cache owners. They are not reasons to begin a broad language migration:

| Existing path | Repair and qualification before performance comparison |
|---|---|
| Build-context hashing and extraction | Preserve the effective source semantics: executable modes, normalized ownership, PAX paths/links, duplicate-member ordering and source-specific ignore behavior. Version old keys and make hashing/materialization agree. [BuildContextCache](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodDockerShim/BuildContextCache.swift) |
| SharedView per-file clone fallback | Propagate clone success out of the nested closure so it does not fall through into reading and rewriting the entire file; measure avoided I/O before replacing the planner or hash implementation. [SharedView](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodSharedFS/SharedView.swift) |
| Chunk ingestion and reads | Fail incomplete ingestion, produce digest/chunks/length from one coherent input, verify decoded bytes against the requested digest and distinguish zero-byte files from deletion. Preserve an explicit compatibility plan for existing representations. [ChunkStore](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodSharedFS/ChunkStore.swift) |
| Docker and runtime translation | Repair exec user decoding, lost stdin, requested signals, fractional CPU and dropped tmpfs/ulimit/entrypoint semantics; prove effective guest behavior. Replaying a silently dropped field is not a correct characterization target. [Runtime reconciliation](runtime-compatibility.md) |
| Build result and cache administration | Return actual output descriptors, implement owned cancellation and real backend prune, and separate source overlap from solver hits or physical storage savings. [Build-platform reconciliation](build-platform.md), [cache reconciliation](cache-and-filesystem.md) |

After those contracts are corrected and covered, profile complete build and runtime operations. Source snapshots, solver/layer cache, mutable package/compiler mounts, image/unpacked roots and host/guest filesystem caches need separate warm-state receipts. A recorder must not bless an old context-key collision, clone fallthrough or partial chunk publication as behavior to preserve.

## Suggested Rust boundaries

These are design recommendations, not claims about missing or slow code.

| Boundary | First decision | How rust-anything helps | Extra proof required |
|---|---|---|---|
| Build-source canonicalization or content-verification unit | Correct the contract in the existing implementation first; consider Rust only if profiling identifies a material remaining cost | The host path is Swift, so a bespoke differential adapter is needed; the tool supplies a methodology rather than a native Swift bridge | Archive/metadata semantics, bounded decoding, digest verification, mutation races, publication and compatibility with the selected frontend |
| Pure guest event decoder/normalization planner | Candidate only if profiling shows material CPU/allocations | Extract an importable Go package with exported pure functions; record inputs and outputs; generate a Rust comparison bridge | Inotify binary layout, truncated buffers, overflow, lifecycle, Linux architectures, safe decoding and real watch end-to-end tests |
| Pure host sync planner or manifest reconciliation | Candidate if Swift profiler attributes material time to its algorithm | No native Swift support; build a small bespoke differential adapter using the same record/diff methodology | Foundation/Unicode/path semantics, file IDs, case behavior, ordering and lost-event recovery; do not claim native tool gate covers Swift |
| Guest filesystem copy/read/write service | Keep initially | CLI recordings can inform fixtures, but full OS side effects need a dedicated test harness | Permissions, symlinks, non-UTF8 names, quotas, ENOSPC, interruption, durability and distroless packaging |
| Host network/port-forward data plane | Consider only after packet-path profiling | New Rust code needs contract tests; it is not a supported direct Swift port | UDP/TCP half-close, backpressure, cancellation, IP families, DNS/VPN, host sleep and existing forwarding behavior |
| UI, Apple Virtualization/Rosetta, XPC, updater ownership | Keep in Swift | Not supported by the tool and not an established bottleneck | Existing integration and release qualification remain the authoritative gates |
| BuildKit worker/executor integration | Reuse upstream first; replace only a measured or required boundary | Tool replay can assist a pure extracted unit, but cannot supply solver/worker/session compatibility | Snapshot/content/lease integration, exact RUN/Exec semantics, complete build/runtime gates and version-pinned Go interfaces |
| BuildKit, runc/containerd and optional Moby | Integrate maintained upstream components | This tool is not a reason to reimplement their contracts | Pin versions, lifecycle/security/resource compatibility, licenses and image/cache interoperability |
| Downstream Kubernetes | Qualify after core build/runtime/storage behavior | No prerequisite for the first Rust experiment or core replacement milestone | Preserve the established component contracts in real cluster workflows |

## IPC and FFI choices

For a coarse component whose crash should not crash Micropod, prefer an optional separately supervised executable using a versioned Unix-domain protocol on macOS and the selected guest transport inside Linux. Define maximum frame sizes, request IDs, protocol-version negotiation, bounded queues, cancellation and resource ownership. Keep mutations out of automatic retries; query/reconcile uncertain outcomes. Test the overhead before retaining another daemon: a permanently idle Rust process could worsen the product's idle-resource goal.

For a pure, CPU-bound synchronous operation where IPC consumes the benefit, consider a small C ABI library called from Swift: fixed-width scalars, byte slices with explicit lengths, opaque handles, paired allocation/free functions, explicit error codes and no panic crossing the ABI. Do not expose Rust-owned layout or Swift objects as the stable contract. Keep unsafe conversion localized and audited. This binding is project work; rust-anything has no Swift bridge. The Rustonomicon explains that C ABI signatures and pointer validity require correct manual contracts. [Official Rust FFI guide](https://doc.rust-lang.org/nomicon/ffi.html)

Treat the generated Go/cgo bridge as an experiment adapter first. Shipping it into the current helper changes the `CGO_ENABLED=0` assumption. The Go tool requires a C cross-compiler for cgo cross-compilation and excludes `import "C"` files when cgo is disabled. If a Rust guest helper is justified, prove a standalone static executable on actual distroless images; do not assume a musl target or static-library flag alone proves the complete artifact static. [Official cgo documentation](https://pkg.go.dev/cmd/cgo), [current build](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/scripts/build_guest.sh)

## Applying the workflow

The useful order from the pinned skill is `profile → analyze → bridge → record → port → build → diff → bench → shadow → gate`. An engineer/agent writes the Rust; generated bindings are not the implementation. The toolkit benchmarks bridge overhead, supports additional input corpora, records source fingerprints and exposes old/shadow/new rollout modes. [Workflow](https://github.com/erkamyaman/rust-anything/blob/98adbe29003a69783c727146d0c3fe637b174102/docs/how-it-works.md)

Suggested evaluation commands below are a future recipe, not commands run in this investigation. Paths and unit IDs labelled proposed do not exist in the audited source. Read the pinned skill and inspect generated output before loading it into an agent.

```bash
# In an isolated checkout of the pinned tool; local install root, no global agent setup.
cargo install --locked --path /path/to/rust-anything --root /path/to/evaluation-tools
/path/to/evaluation-tools/bin/rust-anything doctor

# Inspect the supported guest subproject, not the mixed Swift repository as a whole.
rust-anything analyze /path/to/micropod/guest --lang go --json

# Only after extracting and testing a pure package; these names are proposed.
rust-anything profile /path/to/micropod/guest --lang go -- \
  go test -run '^$' -bench BenchmarkNormalize -benchmem ./internal/watchplan
rust-anything bridge /path/to/micropod/guest <unit-id-from-analyze>
rust-anything record <generated-crate> --inputs <reviewed-input-corpus.jsonl>
# Write src/port.rs; preserve the public contract.
rust-anything build <generated-crate>
rust-anything diff <generated-crate> --json
rust-anything bench <generated-crate> --json
rust-anything gate <generated-crate> --json
```

First verify the toolchain requirement from the pinned manifest. Prefer an explicit project-local MCP declaration over `setup` if only this experiment needs the server; the documented stdio command is `rust-anything mcp`. Use the exact tool revision and Cargo lockfile as part of every result identity. Tool binaries and transitive dependencies need their own license/security inventory; the tool's MIT license does not establish licenses of all output dependencies. If source or skill content is copied, retain the required MIT copyright/permission notice. Link-and-pin integration is enough for initial documentation; vendoring the full tool is unnecessary.

## What the gate does not establish

The upstream documentation explicitly limits equivalence to recorded observations. It does not prove absence of races, correctness under load, timing, memory use, network/database side effects or signal behavior. Its handling of nondeterminism can introduce wildcards or unordered comparisons. Review those allowances and disallow wildcards for file contents, protocol sequence, ownership, exit codes, persistence checks and security decisions. Do not run record or shadow against a live mutation path: both invoke code repeatedly, and shadow can execute two implementations. Use pure decisions or isolated disposable resources. [Limits](https://github.com/erkamyaman/rust-anything/blob/98adbe29003a69783c727146d0c3fe637b174102/docs/how-it-works.md#what-it-cant-catch)

Do not mechanically preserve an existing bug merely because a recorder captured it. Specify intended fixes independently and distinguish known differences from accidental divergences. Do not treat a C undefined-behavior case accepted by an upstream comparator as evidence of safe behavior for a new parser.

The general Buildx and OCI/runc replacement gates require every required semantic row to pass. A pure-function diff, an explicit unsupported response or a successful specialized isolated-CI profile cannot substitute for that coverage. Guest-observed resource/security enforcement, BuildKit sessions, actual outputs, cache leases and restart/cancellation behavior remain independent acceptance obligations.

## Measurable first experiment

Proposed, adjustable acceptance policy, not measured performance:

- Pin Micropod and tool revisions, runtime/kernel/macOS/CPU versions, power mode, workload, fixture hashes and CPU limit. Separate ARM64 native from Rosetta, isolated-VM from shared-kernel, and cold from warm cache runs.
- Establish a material bottleneck first. If the candidate accounts for less than approximately 15% of the target operation's CPU/wall budget, prioritize the actual bottleneck. A 2× improvement in a 10%-of-total component yields only about 5.3% end-to-end speedup, before bridge overhead.
- Compare current implementation, optimized current-language implementation and Rust with equivalent semantics and concurrency. Test one thread and matched multi-core settings separately; distinguish algorithm/batching changes from language changes.
- Require zero unexplained fixture mismatches; exact protocol/persistence/ownership tests; bounded memory, file descriptors and tasks; cancellation and crash recovery; actual distroless Linux execution if the guest changes.
- Target at least 15% improvement in a designated end-to-end p95 or at least 20% CPU-time reduction at matched throughput, with confidence intervals excluding no improvement. No more than 5% regression in the explicitly chosen secondary latency/throughput budget, and no statistically supported idle-energy/resource regression. If noise is too large, report inconclusive rather than passing.
- Keep the current path as a selectable rollback until real-workload acceptance passes. Do not combine the experiment with VM architecture changes, kernel updates or data migrations; attribution would be lost.

## Ticket-ready phased plan

| Proposed work | Effort range | Depends on | Acceptance |
|---|---:|---|---|
| Pin/review rust-anything and define supported use | 1–2 engineer-days | Reconciled architecture inventory | Versioned workflow doc, MIT provenance, Swift/cgo limitations, reproducible local tool environment |
| Profile existing paths and select one candidate | 2–4 days | Existing benchmark harness and controlled Mac/Linux fixtures | Attribution, existing-language alternative, explicit candidate or no-go result |
| Extract pure characterization boundary | 2–4 days | Evidence of bottleneck | Existing behavior and error semantics preserved; deterministic importable unit; real edge-case corpus |
| Implement Rust comparison prototype | 3–6 days | Recorded baseline, approved component contract | `diff` and tool gate pass; interface overhead measured; no generated wrapper assumed correct by inspection alone |
| Qualify complete workload and decide | 3–5 days | Prototype | Matching resource limits, confidence intervals, fault tests, explicit ship/keep-old/inconclusive decision |
| Production packaging/rollout only if justified | 3–5 days | Positive comparison and lifecycle design | Signed artifact, static guest proof if needed, existing CI/Cuttlefish behavior, rollback and release receipts |

These estimates are planning ranges for the evaluation and one bounded component, not a commitment to OrbStack parity or a whole-app rewrite. A no-go after profiling is a successful outcome if it prevents an unnecessary migration.

## Exact staged runbook for a future isolated evaluation

The commands below were checked against the pinned `src/main.rs` argument declarations; they have **not** been executed. Stage A needs a build environment with Rust 1.97 or newer. Stage B needs a Linux environment and the **proposed** `guest/internal/watchplan` package and `BenchmarkNormalize` benchmark first added through the normal review process. Their absence is an explicit prerequisite, not a reason to bypass a failed command. The generated driver cannot directly call the existing unexported `package main` functions.

For original-code recording, the pinned Go harness declares its generated driver's module as `<target-module>/rust-anything-driver`, requires the target module and locally replaces it with the source directory. This places the proposed `internal/watchplan` import beneath the permitted parent import-path prefix; an `internal` package is not categorically unsupported. It remains necessary to run a real compile smoke for this extracted package: the original driver must compile during `record`, and the Rust wrapper/driver must compile and replay during `build`/`diff`. Source inspection of the module naming does not establish those gates have passed. [Generated module and driver construction](https://github.com/erkamyaman/rust-anything/blob/98adbe29003a69783c727146d0c3fe637b174102/src/harness_go.rs)

### Stage A: pin the tool and source, inspect the plan

```bash
set -euo pipefail
MICROPOD_EVAL_ROOT="$PWD/micropod-rust-evaluation"
mkdir -p "$MICROPOD_EVAL_ROOT/evidence"
git clone https://github.com/erkamyaman/rust-anything.git "$MICROPOD_EVAL_ROOT/rust-anything"
git -C "$MICROPOD_EVAL_ROOT/rust-anything" checkout --detach 98adbe29003a69783c727146d0c3fe637b174102
git clone https://github.com/castlemilk/micropod.git "$MICROPOD_EVAL_ROOT/micropod"
git -C "$MICROPOD_EVAL_ROOT/micropod" checkout --detach 54980012eb47b458a7f7e1def616d3fa95c970a2
cargo install --locked --path "$MICROPOD_EVAL_ROOT/rust-anything" --root "$MICROPOD_EVAL_ROOT/tools"
RUST_ANYTHING_BIN="$MICROPOD_EVAL_ROOT/tools/bin/rust-anything"
"$RUST_ANYTHING_BIN" --version > "$MICROPOD_EVAL_ROOT/evidence/tool-version.txt"
rustc --version --verbose > "$MICROPOD_EVAL_ROOT/evidence/rustc.txt"
go version > "$MICROPOD_EVAL_ROOT/evidence/go.txt"
"$RUST_ANYTHING_BIN" analyze "$MICROPOD_EVAL_ROOT/micropod/guest" --lang go --json > "$MICROPOD_EVAL_ROOT/evidence/initial-analysis.json"
# Optional diagnostics; a nonzero result must be inspected (missing agents may be irrelevant to CLI-only use).
"$RUST_ANYTHING_BIN" doctor --json > "$MICROPOD_EVAL_ROOT/evidence/doctor.json"
```

An installed tool can also show its proposed agent-config edits without applying them: `rust-anything setup --agent codex --dry-run --json`. For this experiment use the CLI directly unless agent registration has an identified benefit. Do not auto-detect the language from Micropod's mixed-language top-level tree.

### Stage B: an extracted pure planner, then comparison

Suggested contract: a pure `Normalize(batch string) (string, error)` fixture facade in the new importable Go package. Its serialized input includes prior watch state, raw event bytes encoded losslessly and an explicit clock; its output contains normalized events, next state and proposed watch changes. No function in this facade touches the filesystem, invokes syscalls or reads wall time. Canonical fixture encoding is an evaluation adapter; the production boundary and its encoding costs must be evaluated separately. Extract and validate the old behavior before implementing Rust. The existing `watch.go` still owns live watch registration and side effects during the experiment.

```bash
test -f "$MICROPOD_EVAL_ROOT/micropod/guest/internal/watchplan/plan.go"
test -f "$MICROPOD_EVAL_ROOT/evidence/watch-inputs.jsonl"
"$RUST_ANYTHING_BIN" analyze "$MICROPOD_EVAL_ROOT/micropod/guest" --lang go --json > "$MICROPOD_EVAL_ROOT/evidence/extracted-analysis.json"
"$RUST_ANYTHING_BIN" profile "$MICROPOD_EVAL_ROOT/micropod/guest" --lang go --json -- \
  go test -run '^$' -bench '^BenchmarkNormalize$' -benchmem \
  -o "$MICROPOD_EVAL_ROOT/evidence/watchplan-tool-profile.test" ./internal/watchplan \
  > "$MICROPOD_EVAL_ROOT/evidence/profile-output.log" 2>&1
# Independent raw-profile collection; the tool's temporary cpu.pprof is not retained.
(
  cd "$MICROPOD_EVAL_ROOT/micropod/guest"
  go test -run '^$' -bench '^BenchmarkNormalize$' -benchmem -count=1 -timeout=5m \
    -cpuprofile="$MICROPOD_EVAL_ROOT/evidence/watchplan-cpu.pprof" \
    -o "$MICROPOD_EVAL_ROOT/evidence/watchplan-raw-profile.test" ./internal/watchplan \
    > "$MICROPOD_EVAL_ROOT/evidence/watchplan-raw-profile.log" 2>&1
)
# Verify internal/watchplan is the unit ID reported by extracted-analysis.json.
"$RUST_ANYTHING_BIN" bridge "$MICROPOD_EVAL_ROOT/micropod/guest" internal/watchplan \
  --out "$MICROPOD_EVAL_ROOT/watchplan-rs" --name micropod-watchplan-evaluation
"$RUST_ANYTHING_BIN" record "$MICROPOD_EVAL_ROOT/watchplan-rs" --count 0 \
  --inputs "$MICROPOD_EVAL_ROOT/evidence/watch-inputs.jsonl"
# Implement watchplan-rs/src/port.rs using the recorded contract, then:
"$RUST_ANYTHING_BIN" build "$MICROPOD_EVAL_ROOT/watchplan-rs"
"$RUST_ANYTHING_BIN" diff "$MICROPOD_EVAL_ROOT/watchplan-rs" --json > "$MICROPOD_EVAL_ROOT/evidence/diff.json"
"$RUST_ANYTHING_BIN" bench "$MICROPOD_EVAL_ROOT/watchplan-rs" --min-ms 2000 --json > "$MICROPOD_EVAL_ROOT/evidence/unit-benchmark.json"
"$RUST_ANYTHING_BIN" gate "$MICROPOD_EVAL_ROOT/watchplan-rs" --json > "$MICROPOD_EVAL_ROOT/evidence/tool-gate.json"
```

**Profile output is a log, not a JSON artifact.** At this revision, `profile --json` launches `go test` through `process::status`, which preserves inherited stdout/stderr, and then emits its JSON report. Redirecting stdout to `profile.json` would mix benchmark text with the report. Keep `profile-output.log` verbatim. Any derived JSON needs a validated extractor that identifies exactly one complete report, checks the pinned report schema, rejects ambiguous/truncated output and retains the source log; alternatively qualify a tool change that separates workload output from machine-readable output. Do not describe a renamed mixed-output file as valid JSON. [Profile implementation](https://github.com/erkamyaman/rust-anything/blob/98adbe29003a69783c727146d0c3fe637b174102/src/profile.rs), [subprocess stream behavior](https://github.com/erkamyaman/rust-anything/blob/98adbe29003a69783c727146d0c3fe637b174102/src/process.rs)

The tool writes Go's `cpu.pprof` into a temporary work directory and removes that directory after successful profiling. The separate `go test` invocation above preserves its own raw profile and matching test binary under the evaluation's evidence directory, from the correct guest-module working directory. It is a second invocation with its own log and must not be presented as the exact raw sample underlying the tool's report. The explicit `-o` destinations also keep retained test binaries out of the source checkout. These commands remain **unexecuted**, and both profile artifacts require content validation and hashing when collected. [Profile lifecycle](https://github.com/erkamyaman/rust-anything/blob/98adbe29003a69783c727146d0c3fe637b174102/src/profile.rs), [Go test output flags](https://pkg.go.dev/cmd/go#hdr-Test_packages)

The `bridge` subcommand has **no `--lang` option** at this revision; its language is detected from the supplied Go subproject root. `--from-tests` records TS/JS and Python calls, not Go tests: generate the Go fixture corpus explicitly. Each input line has the tool's shape `{"fn":"Normalize","args":["<serialized fixture>"]}`. The proposed facade must define the inner fixture schema before collection. `--count 0` disables the regular generated-case loop; the recorder still attempts to add semantic traps. Inspect the actual recorded cases and error counts. The reviewed corpus must deliberately include both valid event sequences and malformed/truncated boundaries so that generic malformed strings do not dominate the experiment. Keep a correctness corpus and a representative performance corpus distinct, with explicit weights: speed at rejecting arbitrary strings is not watch throughput. The built-in mixed-corpus benchmark remains diagnostic; use a separate workload harness for the production gate. [Recording implementation](https://github.com/erkamyaman/rust-anything/blob/98adbe29003a69783c727146d0c3fe637b174102/src/harness.rs) `bench --min-ms` controls minimum sample time, not statistical significance or complete product readiness.

Do not run `shadow` against live filesystem mutations. For this pure unit a generated shadow may compare decisions, but it must never apply both old and new watch plans. A proposed feature selector such as `MICROPOD_WATCH_PLANNER=go|rust` must default to `go`, be exposed as a capability/version in diagnostics, and restore `go` without data-format migration. This selector does not exist in current source.

### Baseline receipt and separate release gate

Every experiment should emit a machine-readable manifest with at least: experiment ID; timestamp; Micropod baseline and candidate commits; rust-anything commit; Go/Rust/linker versions; platform/CPU/macOS/Linux kernel; artifact SHA256; runtime backend; filesystem/share type; cold/warm definition; fixture/corpus hash; worker count and CPU/memory limits; warmups/repeats/order; power and thermal state; exact command; raw output locations; and unmeasured fields explicitly null. Retain both current-language and Rust artifacts. Record prototype changes that alter batching or algorithm independently of language.

Use two independent outcomes: **semantic gate** (replay, fuzz/property tests, error codes, event ordering and lifecycle) and **performance gate** (CPU, memory, wall latency distributions, FDs and wakeups under a matched end-to-end workload). Add separate crash/cancellation/restart/durability receipts for a process or persistence boundary. `rust-anything gate` supplies part of the semantic gate; it cannot replace these tests. A unit-speed win with a product regression is a no-go. A clean rollback, explicit unsupported condition or insufficient statistical evidence is recorded honestly instead of counted as a pass.
