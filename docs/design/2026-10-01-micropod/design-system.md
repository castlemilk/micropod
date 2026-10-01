# Micropod design system

## Identity

The pod outline, terminal bars and forward chevron continue Micropod's existing identity. The refined vector preserves the three internal bars with clearer spacing at menu-bar sizes. Blue belongs to the app tile, selection and primary actions; the menu bar mark is a monochrome template.

Use the mark alone in the menu bar and at small sizes. Use the lowercase wordmark in documentation and the design kit. App window titles remain “Micropod”. Give the mark at least one quarter of its width in clear space. Minimum size: 16 pt for the template mark, 24 pt for the lockup. No badges inside the mark; runtime state belongs beside it.

The raster app icon is an imagegen concept. The SVG mark and app-tile concept are implementation masters with exact geometry. These are complementary treatments, not pixel-identical traces. Font-dependent wordmark SVGs use the host system font and need outlined typography before external distribution.

## Color

Use semantic tokens, never a raw hex value in a view. Dark mode uses graphite surfaces with a restrained cool-gray hierarchy. Light mode uses warm neutral canvas and white content. Brand blue stays #0A84FF; light-mode blue text/action uses a deeper tone for contrast.

| Token | Dark | Light | Purpose |
|---|---|---|---|
| canvas | #151719 | #F5F5F3 | Window background |
| sidebar | #1B1E22 | #ECEDEA | Navigation material fallback |
| surface | #1F2328 | #FFFFFF | Main content |
| elevated | #292E35 | #FFFFFF | Popovers and menus |
| separator | #3D4652 | #D7DBE0 | Decorative boundaries |
| controlBorder | #7C8999 | #858F9D | Essential control boundaries |
| textPrimary | #F3F5F7 | #1D242D | Primary labels |
| textSecondary | #B8C0CC | #4E5A69 | Supporting labels |
| textTertiary | #98A3B3 | #606B79 | Secondary metadata |
| accent | #0A84FF | #0067CF | Selection and primary action |
| onAccent | #FFFFFF | #FFFFFF | Filled action labels |
| accentText | #73B6FF | #0067CF | Links and selected text |
| success | #68D6A0 | #197548 | Running / successful |
| warning | #E6B65D | #8A5900 | Resource pressure / warning |
| danger | #FF8888 | #BA3038 | Failure / destructive |

Filled primary buttons use `actionFill` (#0067CF in both appearances) with white text, so small labels have sufficient contrast. Bright brand blue is reserved for graphic identity and decorative chart series. Color is always accompanied by a label, icon or pattern. Status colors never imply a chart series. CPU is blue, memory teal, inbound network lilac and outbound network amber; chart labels and legends remain readable with color disabled.

## Typography and measurements

Use system SF Pro through SwiftUI `.system`, with SF Mono for logs and identifiers. Do not bundle Apple's fonts. Use tabular digits on counters, tables and chart labels.

| Role | Size / weight | Usage |
|---|---|---|
| Window title | 13 / semibold | Native toolbar |
| Page title | 22 / semibold | Workloads, Cache |
| Section | 13 / semibold | Inspector sections |
| Body | 13 / regular | Table rows and actions |
| Metadata | 11 / regular | Image tags, freshness |
| Metric | 20 / medium, tabular | Resource strip |
| Log | 12 / regular, monospace | Live output |

Spacing: 4, 8, 12, 16, 24, 32 pt. Default content inset: 20 pt. Sidebar: 190–220 pt. Inspector: 320–400 pt. Table row: 40 pt, or 48 pt with secondary line. Toolbar control: 28 pt. Tray row: 44 pt. Dividers: 1 physical pixel. Small-control radius: 6 pt; panels: 10 pt; popover: 14 pt; native window uses the platform radius.

At narrow window widths, collapse the inspector into a detail destination and the sidebar into the platform sidebar toggle. Preserve selection and search. Do not compress all columns into unreadable labels. Favor native resizable split views over bespoke draggable layouts.

## Components

The operational SwiftUI implementations and native component sheets are documented in the [2 October refinement](refinement.md). Page headers, pictogram tiles, status badges, metric readings, static budget meters and selection placeholders share the same tokens across all workspace routes and the tray.

**Workload row.** Icon + name, explicit type, state dot + state text, cores, memory, port. Sort numeric columns by raw value. Stopped rows show em dashes instead of stale zero readings. Secondary engine metadata distinguishes Apple, Docker and sandbox without changing the primary name. Context menus expose type-appropriate lifecycle actions. Multi-selection shows a single action bar.

**Inspector.** Header keeps name, state and immediate actions visible. Overview, Logs, Metrics, Files and Terminal share persistent selection; the mockup shows a subset to fit. Port links open host endpoints. Copy controls expose the full address and identifier. A stopped ephemeral sandbox offers “Run again”.

**Resource strip.** Small current reading plus a sparkline, with sample age in the footer. CPU unit is cores. Memory denotes workload memory unless explicitly labeled host memory. Missing and stale data use labels, not misleading zeroes. No endlessly pulsing meters.

**Logs.** Timestamp and severity columns; warning/error accents; query highlighting; Live/Paused control; wrap, export and clear view in an overflow menu. Pausing stops autoscroll; describe whether ingestion continues. Preserve scroll position and selected text. Bound displayed history and provide export for longer sessions.

**Cache budget.** Show budget, usage, measurement basis and active protection. Build-context logical content and physically stored package chunks remain distinct. A budget is not a promise that active pinned work can be deleted. Explain over-cap state: “Active caches exceed the limit. Cleanup resumes when workloads finish.”

**Cache entry.** Path, project, last use, content size and In use/Kept/Unused state. “Keep cached” is proposed retention, separate from automatic in-use protection. Do not let a pin icon imply that the current backend already supports manual pinning.

**Cleanup review.** Preview candidate entries and exclusions before deletion. Exclude active mounts, active builds, manually kept entries and backing golden volumes. Show estimates as estimates; report actual reclaim after the operation. Deleting content must respect shared references. Generic volume prune must not bypass these protections.

**Tray.** Runtime status + count, CPU/memory, three meaningful workload shortcuts, separate cache budgets, one recent activity and Run/Open actions. Default width 360 pt. Tray clicks deep-link to the selected workload and tab. A runtime stop action belongs in the menu with explicit consequences, not beside every glance metric.

## Iconography

Original 24 pt outline icons use 1.75 pt strokes, round caps/joins and a 2 pt safe area. Display at 16–20 pt, optically align to text, use `currentColor`/template tint. Keep the brand mark out of navigation pictograms. Existing Lucide actions can remain during transition; avoid mixing filled and outlined variants within one context.

The SVG pack has a semantic manifest and suggested SF Symbol fallbacks. Those fallback names are marked unverified until checked against the target macOS SDK. Use built-in symbol rendering where native menu behavior requires it. Filled play/stop controls may use platform symbols if they improve 16 pt clarity; do not recolor status icons indiscriminately.

## State, accessibility and keyboard

Show Running, Stopped, Starting, Unavailable, Failed and Stale explicitly. Pending operations disable conflicting actions and show a compact progress state. Empty views offer Run, Pull or Import appropriate to the route. Errors explain the failed operation and a useful retry. A refresh failure preserves last known data with its age.

⌘K: commands/search. ⌘F: local filtering. Arrow keys: workload selection. Return: open detail. Escape: dismiss popover or leave search. ⌘O: open the main app from the tray when it has focus. New shortcuts must be wired and documented before release.

Use visible keyboard focus, descriptive accessible names, sufficiently large native hit regions, selectable logs and accessibility table semantics. Do not hide essential actions behind hover. Respect Increased Contrast, Reduce Transparency and Reduce Motion. Native semantic AppKit colors should adapt where possible; explicit token pairs are visual references.

## Performance contract

Use event-driven lifecycle updates where the runtime supports them; otherwise coalesce requests through existing services. Reuse the current visibility-aware sampler rather than creating separate polls for each component. A visible resource inspector may refresh at the existing five-second cadence; a closed tray should not keep chart subscriptions alive. Show the last successful sample's age.

Keep log buffers bounded, batch incoming lines, and avoid a full table redraw for every log or sparkline update. Cancel subscriptions on disappearance. Compute chunk inventories and storage summaries off the main actor, cache their snapshots, and invalidate on meaningful mutations. Avoid repeated filesystem walks in render paths.

These are implementation requirements, not achieved optimization claims. Validate idle CPU/energy with all surfaces closed; redraw count with a large inventory; log latency under load; safe cleanup under concurrent builds; and logical versus physical cache accounting on APFS.
