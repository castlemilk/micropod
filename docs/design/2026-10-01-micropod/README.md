# Micropod — design kit and native uplift

A native workspace for containers, microVMs and the work they reuse. This pack contains imagegen mockups, a small design system, original SVG pictograms and a refined version of the existing pod/terminal identity.

The generated concept screens use illustrative data. The uplift is now implemented in the existing SwiftUI app. See the native previews and implementation notes for the completed behavior and cache ownership boundaries.

## Open the kit

- [Design kit](index.html): visual gallery, light/dark tokens, logo variants and iconography.
- [Native previews](native/index.html): implemented window, tray, cache and compact layouts with isolated test fixtures.
- [Responsive layouts](native/responsive/index.html): all workspace tabs, inspectors and sheets at compact and wide sizes.
- [Visual refinement](refinement.md): shared native components and their adoption across every workspace.
- [UI performance evaluation](performance.md): measured memory, responsiveness, inventory benchmarks and retention budgets.
- [Implementation notes](implementation.md): actual behavior, cache boundaries and validation.
- [Design system](design-system.md): component rules, interaction and performance requirements.
- [Tokens](tokens/tokens.json): portable values for implementation.
- [Swift reference](tokens/MicropodDesignTokens.swift): an implementation starting point, outside the app target.
- [Icon pack](icons/README.md): 24 original, tintable SVG pictograms and a semantic manifest.
- [Generation prompts](prompts.json): exact imagegen prompts and output provenance.

## Product direction

**Workloads first.** A project-grouped list puts state, CPU, memory and ports beside each container or persistent VM. Selecting a workload opens logs, metrics, files or terminal in an inspector without losing the list. Keep dedicated Containers and MicroVMs filters for precise actions.

**The menu bar is a glance and a shortcut.** Runtime health, running count, three useful workload rows and two cache budgets fit in one popover. Row clicks open that workload's inspector. The main app handles detailed investigation.

**Cache is understandable.** Build contexts, package chunks and clone-backed cache volumes have separate accounting. Budgets, recent use and protection explain retention. Proposed “Keep cached” and “Review cleanup” controls make automatic caching inspectable.

**Native and quiet.** Keep the existing blue pod identity. Use macOS typography, compact tables, restrained translucency, outline icons, visible focus and status labels alongside color. Resource charts communicate changes without perpetual animation.

## Existing foundation and proposed additions

| Area | Already present | Proposed by this concept |
|---|---|---|
| Workloads | Container table, independent Machines view, inspector tabs, command palette | Unified cross-engine overview, project grouping, persistent selection across surfaces |
| Logs | Follow/pause, filtering, export, bounded 1,000-line buffer | Inspector placement and stronger timestamp/level hierarchy |
| Menu bar | Runtime health, resources, busy containers, activity and quick actions | Persistent VM coverage, workload shortcuts and cache budgets |
| Build contexts | Hash manifests, reuse, 5 GiB default LRU budget, active-build protection | First-class visual inventory and configurable retention |
| Shared chunks | Deduplication, 10 GiB default cap, active-view protection during cap enforcement | Desktop telemetry integration and package cache inventory |
| Cache controls | Runtime storage prunes and golden-volume configuration | Manual keep controls and cache-specific cleanup preview protecting active mounts and base volumes |
| Efficiency | Reduced polling when hidden, bounded logs | Explicit sampling freshness, visibility-aware chart subscriptions and measured redraw budgets |

Apple-engine containers already use isolated microVMs. “MicroVM” in the concept table refers to a separately managed persistent machine. Ephemeral sandbox workloads need their own type and a “Run again” action rather than a restart promise.

## Honest resource and cache numbers

The sample workload table totals **5 running / 6 total**, **0.42 CPU cores** and **1,328 MiB ≈ 1.30 GiB**. CPU expresses consumed cores; 100% in existing per-workload telemetry represents one core, not the entire host. Proposed VM aggregation needs a compatible source before implementation.

Sample cache values are **24 retained contexts**, **1.8 / 5 GiB context content**, **3.2 / 10 GiB stored package chunks**, **7 active mounts**, and **640 MiB content reused across contexts**. Context content is logical, and reused content is not physical disk saved. Package rows may share chunks and do not add up to stored bytes. Real physical reclamation must be measured after deletion, particularly with APFS clones.

Do not label the shim's one-second API response cache hit rate as build reuse. Persisted build hit-rate and time-saved telemetry are future work. Remote cache described in runner specs is not presented as a shipped desktop feature.

Before wiring the proposed cleanup UI, unify protection across manual SharedFS GC and cap enforcement, and protect clone-backed cache goldens from generic volume prune. The current implementation has gaps in those paths; this pack defines the intended behavior, not a guarantee of today's cleanup.

## Implementation sequence

1. Adopt semantic colors/type and the refined brand in an isolated UI change.
2. Consolidate workload navigation and preserve inspector selection; retain type-specific lifecycle actions.
3. Add cache inventory DTOs and desktop IPC with explicit accounting units.
4. Implement and verify protected cleanup and retention before enabling its controls.
5. Measure window/tray redraws, hidden idle usage, log throughput and cache accounting on a real Mac.

Generated screens are visual references. The SVG files and token definitions are the deterministic implementation assets. AI-rendered small text may differ from the exact prompts; the documentation is authoritative.
