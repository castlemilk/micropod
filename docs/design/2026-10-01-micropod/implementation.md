# Native implementation

This uplift extends the existing SwiftUI macOS application and its `MenuBarExtra` panel. The generated mockups and gallery remain design references; operational screens use real `AppStore` inventory and existing runtime operations.

## Window and workloads

`MainPanelView` applies adaptive warm gray/graphite surfaces, restrained blue accents, shared typography, the native pod/terminal mark, and the original line-icon set. Its sidebar groups Workspace, Resources, Projects, and System while retaining the existing feature panes and command palette.

The new Workloads view combines containers, ephemeral sandbox VMs, and persistent microVMs. It groups by real project labels, supports search, type/state filters and sorting, and preserves namespaced selection across filtering. Container and machine routes open their corresponding existing inspectors, including their supported logs, metrics, terminal, files, and configuration panes. Narrow layouts use a separate detail view. Explicitly sampled backing-container IDs are excluded from the combined inventory to avoid counting a persistent VM twice.

CPU values represent consumed cores: the sampler's 100% equals one core. Memory values describe guest usage and exclude host/runtime overhead. Missing samples remain unavailable. Freshness and partial coverage are surfaced; the menu panel excludes stale samples and presents incomplete totals as lower bounds.

## Menu bar

The menu label uses the native monochrome brand mark, runtime health, and a count that includes persistent VMs. The 360 pt panel keeps a plain `VStack` root for reliable popover sizing, limits workload shortcuts to three and recent activity to two, and opens the exact workload inspector from each shortcut. It shows guest resources and separate measured cache budgets, with unavailable states instead of invented values.

Run and Open remain visible. Settings and the overflow menu expose runtime start/stop, image pull, commands, updates, and Quit. Stopping the runtime asks for confirmation when observed Apple workloads are running, including from the app menu, dashboard and command palette. The panel reports its visibility to the existing shared sampler; it adds no independent metrics poller.

## Cache behavior and boundaries

A shared `CacheStore` coalesces concurrent refreshes, throttles ordinary refreshes to a ten-second minimum interval, and performs manifest reads away from the main actor. Manual Refresh bypasses that freshness interval. Window and tray consume the same measured snapshot. Source failures remain visible and are distinguished from an empty cache.

Build-context inventory reads the existing manifests and reports logical retained content, its configured cap, file digests, and measured reuse across contexts. This inventory is read-only: active build pins belong to the Docker shim's process-local cache actor. Desktop deletion or per-context Keep would require a coordination API with that owner. Digest reuse does not establish physical APFS savings, and build-context bytes are not added to package-cache bytes.

Package-cache telemetry, global Keep, and reviewed cleanup are owned by the shared-filesystem daemon. Keep retains current and future chunks and pauses automatic eviction. Cleanup reviews identify eligible chunks, expire after five minutes, and are rechecked by the daemon before deletion. Keep or active mounts block cleanup; chunks created after the review are excluded. Missing or older daemon APIs produce an unavailable state. These controls do not implement per-workload cache pinning or new image/build-layer caching.

## Responsive behavior

Inventories fill the available pane and progressively reduce columns. Containers switches to a list/detail navigation flow below 880 pt of content width; MicroVMs uses an inspector sheet below 760 pt. Workload inspectors stay between 320 and 600 pt in split layouts. Width comes directly from bounded parent proposals, avoiding geometry measurement feedback loops.

Long image references, paths, digests, and configuration values wrap or truncate with full-value help and copy controls. Narrow inspector selectors use a menu; chart ranges and terminal controls also compact. Build, Compose, Settings, Overview, Storage, and Cache use capped reading widths. Resource tiles and environment cards reflow into fewer columns.

Attached sheets use minimum, ideal, and maximum sizes. Their long content scrolls while the primary action row stays fixed. Empty states reduce artwork or scroll in short viewports; operation history height is bounded to a fraction of the window. The 360 pt menu-bar panel retains its bounded native popover layout. Topology diagrams scroll horizontally below their 452 pt minimum diagram width.

The [responsive preview gallery](native/responsive/index.html) includes 129 native renders across 49 surfaces. Regression tests verify long-value wrapping, proposed compact sizes, actual primary-button bounds, and native search/filter/list bounds during repeated resizing. These renders are visual inspection artifacts, not pixel baselines. Storage previews can include read-only host measurements.

## Assets and verification status

The [2 October visual refinement](refinement.md) extends the same component family across all 14 workspace headers, inventory identity, state labels, resource readings, Cache/Storage surfaces and menu-bar budget meters. The native gallery includes light/dark sheets of the implemented components, and all 121 responsive previews have been refreshed. The full app regression run executed 124 release tests with one optional benchmark skipped and no failures; after the batched visual fixes, 39 focused release checks passed with one optional benchmark skipped.

`assets/logo/Micropod-uplift.svg` and `Micropod-uplift.icns` supply the packaging treatment; `scripts/make_icon.swift` regenerates the icon set. SwiftUI draws the small brand mark directly. The design directory includes 24 editable operational SVGs and their semantics, tokens, prompts, generated mockups, and native asset previews.

Asset XML, icon count, geometric bounds, and an AppKit-rendered light/dark icon sheet were checked. Native brand previews were reviewed at 16, 18, and 32 px heights. The native app builds successfully. All 102 targeted regression tests pass, covering workload mapping and repeated selection, image/type palette search, guest-metric semantics, runtime-stop confirmation, cache ownership rules, JSON value types, Unix socket round trips, filesystem sync, and native fitting-size/raster scenarios. Native renders cover all 14 workspace tabs at 720 × 460, 1040 × 700, and 1920 × 1080 pt, including dark mode at the minimum window size. Container panes render at 320/360/600 pt; MicroVM panes, forms, cleanup reviews, populated projects, and topology diagrams have separate compact/wide cases. The isolated debug app remained alive through six seconds of polling and terminated successfully.

The optimized release bundle is staged at `dist/Micropod.app` with its updated shared-cache daemon, other existing helpers, resource bundle and icon. Its ad-hoc code signature passes deep/strict verification, and the packaged app passes the isolated six-second launch/poll/quit smoke check. This is a local review build, not a published or notarized release. Changed Swift sources pass strict formatting lint, and the preview gallery's theme switch was checked in the browser.

The [native preview gallery](native/index.html) contains test-fixture component renders; it does not expose live user workloads. The subsequent [UI performance evaluation](performance.md) records desktop memory, responsiveness, model timings, bounded streaming and the release regression results. Those UI measurements do not establish guest VM/runtime improvements or cache hit speedups.
