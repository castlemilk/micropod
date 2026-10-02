# Native visual refinement — 2 October 2026

This pass carries the existing generated design system through the operational app. The blue pod identity, graphite/warm-neutral surfaces, SF typography and original outline pictograms remain the visual foundation.

## Review and changes

The initial review compared the generated component board and workload/cache/tray concepts with the native render gallery. Workloads and Cache had the clearest hierarchy, while several older routes still opened with a count or a form. Overview repeated the app identity with an unrelated illustration. Storage used different card chrome and warning colors, and the tray showed cache budgets only as text.

All 14 workspace routes now use a common page-header component. Overview has a route title and compact native runtime actions. Inventory rows and inspectors use the generated container, microVM, image and resource pictograms. Sidebar selection has consistent semantic text colors. Cache and Storage share token-backed section surfaces and static budget meters, including real zero-width empty states. The tray uses the same icons and meters without adding a sampler.

## Implemented component family

The reusable source lives in [WorkspaceComponents.swift](../../../Sources/MicropodApp/Views/WorkspaceComponents.swift) and [PanelCard.swift](../../../Sources/MicropodApp/Views/PanelCard.swift).

| Component | Use |
| --- | --- |
| `WorkspacePageHeader` | Route icon, title, secondary metadata and native trailing actions; actions stack when space is limited |
| `WorkspaceIconTile` | Cached original pictogram on a restrained semantic tint |
| `WorkspaceStatusBadge` | Labeled state; compact dot-and-text form for dense rows |
| `WorkspaceMetric` | Current reading and optional availability detail, using tabular digits |
| `WorkspaceBudgetMeter` | Static, bounded measured ratio with an accessible value; caller owns zero-cap semantics |
| `WorkspaceSelectionPlaceholder` | Quiet inspector guidance using the operational icon family |
| `PanelCard` | Consistent section title, optional icon/subtitle, spacing and surface |

The [light component sheet](native/components-light.png) and [dark component sheet](native/components-dark.png) render these actual SwiftUI components with explicitly illustrative values. These are native reference assets, not generated images of proposed controls.

## Behavior and performance boundaries

Native buttons, menus, focus, shortcuts, search fields, selection, destructive confirmations and cache protection remain in place. Existing breakpoints, bounded lists/output and visibility-aware tasks continue to own layout and sampling. Icons reuse the existing decode cache; meters are two static shapes with no timer or animation. No new font, raster illustration, shadow layer or polling subscription is added by this pass.

The responsive gallery and tray previews are refreshed from isolated native fixtures. Native inactive preview windows can render system button chrome differently from a foreground window. Storage renders may include read-only host measurements. The preceding [performance evaluation](performance.md) records the earlier optimization round; it is not a frame-rate guarantee for every interaction.

## Verification

The full app release run executed 124 tests with one optional performance benchmark skipped and no failures. One batched render review found and corrected faint container/environment metadata, duplicate polling labels, uneven summary surfaces and wasted metric columns. A confirmation run executed 39 focused release checks with one optional benchmark skipped and no failures. It includes the responsive matrix, native button/search bounds, tray fitting, shared components and existing inventory/store performance guards. The populated tray fits at approximately 575 pt tall, within its 640 pt regression bound.

All 121 responsive previews, the native window/tray captures and the two component sheets have been refreshed. The visual review used one inspection pass and one confirmation pass. Changed Swift sources pass strict formatting lint.

The final keyboard review found that opening the command palette could leave typing directed at the page underneath. Focus now waits for the overlay's native field to be installed. A native regression verifies transfer of the window's field editor from an existing search field, separately from foreground app activation. The final focused release run passed all 15 focus, search, shared-layout and store-performance checks.

The rebuilt `dist/Micropod.app` passes deep/strict signature verification and the isolated six-second launch/poll/termination smoke check. A separate temporary copy with its update feed disabled passed foreground keyboard checks: ⌘F filters the inventory, ⌘K receives typing without a mouse click, Return selects the matching workload and opens its inspector, and Escape dismisses the focused palette. No runtime workload was started or stopped.

## Post-refinement performance guard

The [final foreground sample](performance/refinement-foreground.json) matches the rebuilt app binary (`da59719911ce53025ee7e1a8ba282a2883d6c540fc73c7eb7519fc72ed5986b3`). Each route used 1,000 fixture workloads, a four-second warm-up, a five-second sample and one round, after builds and interactive checks had stopped. Both processes were confirmed active. These short runs finished before the app's delayed startup update check; the Sparkle automatic-check preference was also disabled.

| Route | Steady physical footprint | Peak physical footprint | Peak resident memory | CPU, one core = 100% | Main-actor ping p95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Workloads | 134.9 MiB | 134.9 MiB | 207.8 MiB | 0.60% | 0.406 ms |
| Overview | 150.8 MiB | 340.1 MiB | 219.7 MiB | 0.60% | 0.297 ms |

Steady footprints remain close to the earlier optimized observations (approximately 134 MiB for Workloads and 150 MiB for Overview). Overview still has a transient launch/history-processing peak. This is a short regression guard, not a frame-rate measurement, a precise speed comparison, or a long-running leak test. No real guest, build or cache workload was exercised.

## v0.12.0 release alignment

The release pass applies the same card and metric components to Files and Stats inspectors and the Image, Volume and Network detail sheets. The newly integrated storage-location picker keeps native drive distinctions while sharing semantic colors, state badges, static meters, wrapping text and adaptive actions. Long drive names and paths fit compact cards; all three relocation buttons stack at 320 pt and retain their native bounds.

The gallery now contains 129 renders across 49 surfaces. Eight additional pure fixtures show current internal, selected external and unsupported removable drives, plus narrow/wide relocation actions. These previews do not discover drives or move data. All existing workspace, inspector, sheet, menu-bar and component captures were refreshed from the final sources. The changed compact inspectors and drive controls received a visual inspection.

The final focused debug run passed 224 checks with two optional benchmarks skipped and no failures. Coverage includes all native responsive matrices, long-value wrapping and action bounds; forced post-mutation machine/cache refreshes and shutdown cancellation; bounded raw/log/terminal output; cache protection; and current runtime/storage compatibility. The raw-stream overflow test now waits for its isolated producer to be reaped before consumption, avoiding a fixed-delay scheduling assumption while retaining the explicit error and 4 MiB bound. Strict Swift formatting passes.

The local v0.12.0 package passes deep/strict signature verification and the isolated six-second launch/poll/shutdown smoke check. Its app executable SHA-256 is `1fe206a5911bd9a062ab9470c0a643b5f91e3f5cdbb44855fcb0927046327609`; the published Developer ID build will have its own signature and hash.

The [release foreground guard](performance/release-foreground.json) used that package, 1,000 isolated workloads, a four-second warm-up and five-second samples. Workloads measured 150.2 MiB physical footprint (163.8 MiB peak), 0.59% of one CPU core and 0.343 ms main-actor ping p95. Overview's short sample ended at 352.1 MiB (370.1 MiB peak) and 5.12% CPU, prompting a [longer Overview check](performance/release-overview-longer.json). The 20-second check settled at 164.9 MiB (377.2 MiB peak), 0.70% CPU and 0.290 ms ping p95. A temporary copy removed the updater feed and used a separate bundle identifier and renewed ad-hoc signature for that longer run; executable code was unchanged. Both processes were confirmed active. These observations distinguish startup peaks from settled memory; they are not frame-rate or long-running leak guarantees.
