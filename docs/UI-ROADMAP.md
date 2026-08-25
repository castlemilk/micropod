# Micropod UI Roadmap

The goal: a Docker Desktop–class desktop manager for the Apple `container`
runtime — dense but calm, keyboard-first, live-data-obsessed, and safe for
destructive actions. This roadmap is grounded in what already exists
(21 views, ~3k lines) and sequences work so each phase ships standalone value.

## Current state (what we're building on)

- **Shell**: menu-bar app (running count, quick actions) + tabbed main panel:
  Dashboard, Containers, Images, Volumes, Networks, Registries, Build,
  Compose, Environments, Settings.
- **Containers**: searchable/filterable list (running/stopped/all), context
  menu (start/stop/restart/kill/delete/copy ID), stop-all/delete-all/prune,
  detail pane with panes: config, logs (live follow), stats (**charts
  already exist** — CPU/mem history), files explorer, PTY terminal, inspect
  JSON, run sheet (full flag surface incl. ports, volumes, env, resources).
- **Dashboard**: runtime status card (kernel install CTA exists), disk usage
  card with per-category reclaimable + prune buttons, "no containers" state.
- **Compose**: import → plan preview (step count + service summary) →
  up/down with a run log; environments saved as `.spec.bin` with one-click
  up/down. Profiles + pull-policy just landed in the service layer (no UI).
- **Build**: context/Dockerfile pickers, tag/build-arg/target/platform
  fields, live progress log.
- **Settings**: polling intervals, menu-bar count, terminal shell, CLI
  version, app root.

**Missing today** (the roadmap below fixes these): command palette, global
search, activity feed, multi-select, sortable tables, image variants UI,
volume/network detail depth, compose step visualization + per-service logs,
notifications, themes, empty-state illustrations, keyboard shortcuts,
drag-drop, machine/VM surface.

---

## Design principles

1. **Live data first** — every list self-refreshes from the pollers
   (3–5s); no "Refresh" buttons; stale indicators where a snapshot is shown.
2. **Dense by default, calm by design** — monospaced data, tabular numbers,
   compact rows; destructive actions always gated (confirm dialogs, never
   one click).
3. **Keyboard-first** — every action reachable via ⌘K or a shortcut; tab
   navigation; type-to-filter everywhere.
4. **Fail visibly** — every CLI failure surfaces with the exact command +
   stderr, never a silent no-op (error chips, not alerts that block).
5. **Progressive disclosure** — advanced run/compose options behind
   collapsibles; the happy path is 2 clicks.
6. **Accessible & themeable** — full keyboard nav, reduced-motion support,
   Dark/Light/auto from day one of new surfaces.

---

## Phase 1 — Foundations & navigation

### 1.1 Command palette (⌘K) — ✅ shipped
**What**: fuzzy-searchable action palette covering everything the app can do.
**Details**:
- `⌘K` opens; typing filters across four sections: **Actions**
  (run container, pull image, prune, start runtime, install kernel, compose
  up/down), **Navigate** (every tab + selected resource jump), **Resources**
  (live container/image/volume/network rows — jumping selects them),
  **Settings** (polling, shell, appearance).
- Each row: icon, title, subtitle (e.g. image tag + size), optional badge
  (state dot for containers).
- Arrow keys + Enter; Esc closes; `⌘K` reopens with previous query.
- Runs on an `AppStore`-owned `CommandPaletteModel` that indexes resources
  from the existing store state (no new polling).
- **Effort**: M · **Depends on**: none (pure UI layer).

### 1.2 Global search (⇧⌘F) — ✅ shipped (resource search inside the palette)
**What**: cross-resource search with live results grouped by type.
**Details**: unified search bar in the toolbar; groups: Containers (state
dot + image), Images (tag + size), Volumes, Networks; Enter opens the first
result; each group capped at 8 with "see all in tab". Fuzzy matching on
id/name/tag/subnet with highlighted match spans.

### 1.3 Activity feed — ✅ shipped
**What**: a "what just happened" strip so long ops and errors never vanish.
**Details**:
- `AppStore` gains a bounded ring buffer (max 200) of `ActivityEntry`
  (timestamp, category, message, level, resource id).
- Every store action records: started/stopped/restarted/deleted container,
  pull/build/up/down with duration, prune summaries, errors with CLI stderr.
- UI: collapsible "Recent activity" section on the Dashboard (icons +
  relative time, click → jump to resource); an inline "last action" toast
  (1.5s) for completed ops.
- **Effort**: S–M · **Depends on**: none.

### 1.4 Tab badges + live counts — ✅ shipped
**What**: at-a-glance state counts without visiting tabs.
**Details**: Containers tab badge = running count (green); Images = count;
Volumes/Networks = counts; running badge pulses when a pull/build/up is in
flight. Derived from existing store arrays — zero new polling.

### 1.5 Multi-select batch actions — ✅ shipped
**What**: select N containers and act once.
**Details**: checkbox column (or ⇧/⌘-click rows) → toolbar appears with
count: Start, Stop, Restart, Kill, Delete (confirm dialog listing all
names), Copy IDs. Matches docker's `docker stop a b c` semantics. Keyboard:
`⇧⌘A` select all, `Esc` clear. AppStore gains batch methods wrapping the
existing per-id services (sequential, one error report per container).

### 1.6 Appearance & theme — ✅ shipped (theme picker)
**What**: native theming beyond the system default.
**Details**: Settings → Appearance: Auto/Light/Dark (drives
`preferredColorScheme`), accent color picker (maps to
`accentColor`), density (comfortable/compact row padding), font size for
logs/terminal. Store in `UserDefaultsKeys`. Reduced-motion respected.

### 1.7 Notifications — ✅ shipped
**What**: system notifications for long-running ops.
**Details**: completion + failure notifications for: image pull, build,
compose up/down, kernel install, prune (with reclaimed bytes). Opt-in per
category in Settings; notification click navigates to the resource.
`UNUserNotificationCenter` posts from `recordActivity` + the kernel-install
completion path (`MicropodNotifier`); pure classifier `notificationKind`
(Core, unit-tested) maps entries to categories; Settings has opt-in toggles
per category (pulls/builds/compose/prune/kernel). Builds now also record
activity, so they flow through the same channel.

### 1.8 Keyboard shortcuts reference — *P1*
**What**: discoverable shortcuts.
**Details**: `⌘1..9` tabs, `⌘N` run container, `⇧⌘P` pull image, `⌘K`
palette, `⇧⌘F` search, `⌘,` settings, `⌘R` refresh-all, `⌥⌘K` kill
selected, `⌘⏎` confirm dialog. A "Shortcuts" sheet in Help lists them all;
menus carry the key equivalents.

---

## Phase 2 — Data-rich resource views

### 2.1 Containers table — ✅ shipped
**What**: the list becomes a sortable, dense table (OrbStack-style).
**Details**:
- Columns: checkbox, state dot + ID, image (truncated, tooltip full), ports
  (chips `8080→80`), status/uptime, resources (CPU% + mem), created, IP,
  actions (inline stop/restart/terminal icons).
- Click header to sort; ⇧-click secondary; column picker (right-click
  header); widths draggable; selection preserved across refreshes by id.
- Shipped as a sortable header bar (click to sort, arrow toggles asc/desc,
  column picker to toggle Name/Image/State/Ports/CPU/Memory/Created) over
  data-dense rows: uptime, live CPU%/mem from the stats snapshot, ports
  chips, relative created. Sort/filter stays in the view over the store's
  live arrays.

### 2.2 Container detail overhaul — ✅ shipped
**What**: one inspector with a segmented top bar instead of pane jumping.
**Details**:
- Segments: **Overview** (state, image, ports, env, labels, mounts,
  resources, IP — copyable rows), **Logs**, **Stats**, **Files**,
  **Terminal**, **Config**, **Inspect** (pretty JSON).
- Overview (default pane): state, identity, networking, live CPU%/mem/PIDs
  from the stats snapshot, env, labels, mounts — every row copyable; port
  rows carry an open-in-browser `http://IP:port` action when running.
- Keep existing per-pane views as the segment bodies (already built —
  mostly re-plumbing + a shared inspector header).

### 2.3 Log viewer upgrade — ✅ shipped (search/highlight, wrap, pause, copy/save)
**What**: logs become a real tool.
**Details**: search field (match-highlight, Enter next/previous), follow
pause/resume button, wrap toggle, timestamps toggle, ANSI color rendering,
select-to-copy + "Copy selection"/"Copy all" buttons, "Save to file…"
(exporter sheet), font size stepper, monospace default. Live streaming
continues via the fixed `LogStreamer` (readabilityHandler) — no changes
needed below the view.

### 2.4 Stats depth — ✅ shipped
**What**: per-container resource history becomes rich.
**Details**:
- `AppStore`/`StatsSampler` keep a per-container history ring (last 300
  samples: cpu%, mem, net rx/tx, block r/w) — sampler already computes
  deltas; persist to memory only.
- ContainerStatsView gains net Rx/Tx (green/blue) and Disk read/write
  (orange/purple) overlaid rate series (KiB/s) alongside the existing
  CPU/mem charts with the shared time-window picker. Rates are computed
  from cumulative-counter deltas via pure `statsDeltas` (unit-tested) —
  which also fixed an integer-overflow trap the old inline math had.
- Dashboard: a "system" line chart (sum of CPU% + total mem across running
  containers).

### 2.5 Image variants & details — ✅ shipped
**What**: multi-arch images become explorable.
**Details**: list rows expand (chevron disclosure) to per-variant chips
(`linux/arm64 · 209 MB · digest:…`); detail sheet: metadata table (digest,
media type, created, size), labels/env/entrypoint/cmd from inspect JSON,
"Run…" quick action prefilled with the image, "Copy digest", tag manager
(add/remove tags inline — backed by existing tag/delete service).

### 2.6 Pull/build progress panel — ✅ shipped (Operations drawer)
**What**: long ops get a real progress surface.
**Details**: a persistent bottom "Operations" drawer listing active
pulls/builds/ups with per-op: animated stage progress (from parsed
`ProgressEvent` stages — parser already handles BuildKit lines), cancel
button (cancels the task → stream terminates via onTermination), queued
ops stack. Shipped as a persistent bottom **Operations drawer** in the main panel (collapsible): every pull/build/compose-up registers an `ActiveOperation` in a Core `OperationRegistry` (unit-tested) and streams live events + status + a cancel button; the pull sheet and build tab now render from the same registry, so the drawer, sheets, and activity feed stay in sync. Completed ops roll into the activity feed.

### 2.7 Volumes depth — ✅ shipped
**What**: volumes become inspectable resources.
**Details**: shipped as a double-click/context-menu detail sheet: relative
size bar vs the largest volume, driver/format/source (copyable), labels,
**mounted-by list** derived from the live container list via pure
`containersMounted(to:in:)` (unit-tested), and a delete flow that warns
when the volume is mounted by a running container.

### 2.8 Network topology — ✅ shipped
**What**: see the mesh, not just rows.
**Details**: shipped as a Networks List | Topology toggle — a static
bipartite graph (networks left, attached containers right, edges from each
container's `networks` array) rendered in a Canvas with tappable nodes.
Clicking a network opens a detail sheet (subnet/gateway/plugin/mode,
attached containers with IPs, delete with in-use warning) — also reachable
by double-clicking a list row.

### 2.9 Empty states & skeletons — ✅ shipped
**What**: every empty surface teaches instead of blankly existing.
**Details**: each tab gets an illustrated empty state with the *next action*
button (Containers: "Pull an image & run your first container" →
pull sheet; Images: "Pull from Docker Hub"; Volumes/Networks: create;
Compose: "Import docker-compose.yml"). Loading: skeleton shimmer rows (not
spinners) during first refresh; subsequent refreshes update in place.

---

## Phase 3 — Compose & build UX

### 3.1 Compose step visualization — ✅ shipped
**What**: the plan becomes a live pipeline, not a log.
**Details**:
- Plan preview renders the steps as a vertical stepper: `✓ Network front`
  `✓ Volume pgdata` `…` `● Started api (waiting for health)` — status
  icons (pending/running/success/failed), per-step expandable detail
  (the exact `container` command + stderr on failure).
- `up()` stream already yields per-step lines; the view parses them into
  per-step states (new `ComposePlanViewModel`), retry/fail step chips.
- Per-service logs: each service row gets a chevron revealing its live log
  stream (LogStreamer by container id) during/after up.

### 3.2 Profiles selector — ✅ shipped
**What**: surface the profile support that landed in the service layer.
**Details**: ComposeView reads all `profiles` across parsed services → a
chips row "Profiles: [debug] [staging]" (multi-toggle); up passes
`enabledProfiles` to `plan(spec:enabledProfiles:)` (already built);
profiled services show a dimmed "off (profile)" row in the summary.

### 3.3 YAML editor & validation — ✅ shipped
**What**: edit compose in-app instead of re-importing.
**Details**: shipped as the Environments tab's Edit… action — a monospaced
YAML editor with debounced live validation via `ComposeService.parse` (green
check / red inline error), Save + Save & Up, and rename-aware persistence
(spec.bin + `.yml` sidecar). New Core `composeYAML(from:)` serializer
round-trips parsed specs back to YAML for environments saved before the
sidecar existed (round-trip unit-tested).

### 3.4 Environment manager — ✅ shipped
**What**: environments become first-class objects.
**Details**: rename (safe: spec.name changeable in editor), duplicate
(save as copy), export/import `.spec.bin` via file panel, per-environment
last-run status + run count, delete confirm. Current flat list → card
list with meta row.

### 3.5 Build surface — ✅ shipped
**What**: Dockerfile editing + history.
**Details**: shipped as a Dockerfile editor disclosure (content wins via a
`Use editor content` toggle, written to `<context>/.micropod-Dockerfile`;
file picker loads content into it), a Recent builds history (tag/duration/
result, capped 20, persisted), and drag-drop of a context folder or
Dockerfile onto the tab to pre-fill. Build output already links to the
Operations drawer.

---

## Phase 4 — Runtime platform surface

### 4.1 Machine / VM management — ✅ shipped
**What**: the `container machine` + `system property` CLI surface the app
ignores today.
**Details**: Settings → Runtime: machine list (create/delete via CLI),
system properties (read + edit the safe ones), kernel version + config
status, `system dns` domains read-only list. Shipped as `MachineService` in Core (`machine list/create/delete` + `system
property list` via `--format json`, PropertyValue enum for scalars/numbers/
booleans) with mock coverage; Settings → Runtime shows machines
(create/delete, default protected) and a read-only grouped System Properties
view.

### 4.2 Long-op notifications wiring — *P1*
(details in 1.7; here: compose/build/pull specific copy, click-through
to the Operations drawer)

### 4.3 Onboarding tour — ✅ shipped
**What**: first-run becomes a guided 4-step flow (runtime status → kernel
install (exists) → pull a hello image → run your first container).
**Details**: shipped as `OnboardingTourView` (Open tour from the Dashboard's
First run card): four step cards (start runtime → install kernel → pull
alpine → run a container) with live store-driven status checks and
BrandBrain onboarding artwork (SF-symbol fallback), skippable; completion
writes `onboardingComplete`.

---

## Phase 5 — Cross-cutting polish

- **Design tokens**: ✅ `Tokens.swift` (spacing/radius/chart palette); applied
  to `EmptyStateView` as the reference surface, plus the operations drawer and
  onboarding tour — expand adoption with each new surface.
- **Accessibility**: ✅ labels added on topology nodes, palette rows, and
  the icon-only buttons across new surfaces (existing surfaces were already
  labelled); ⌘K focus + Esc dismiss exist; ✅ **reduced motion** — all
  implicit/explicit animations (palette scroll + transition, drawer expand,
  dashboard progress) gate on `accessibilityReduceMotion`.
- **Performance checklist**: ✅ Equatable/`@Observable` row-scoped updates;
  virtualized lists (`LazyVStack`/`Table`); chart history capped; ✅ pollers
  pause when hidden — both containers + stats pollers sleep instead of refresh
  while the window is invisible.
- **i18n-ready**: ✅ `String(localized:)` across all new surfaces' copy
  (onboarding, empty states, environments, build, operations, compose stepper,
  detail sheets, dashboard hero); ✅ `Localizable.xcstrings` catalog (148 keys)
  registered via `.process` and packaged into the app bundle
  (`Micropod_MicropodApp.bundle`); dynamic status strings remain runtime
  interpolated (English default) until migrated to format strings.
- **State persistence**: ✅ window frame (NSWindow frameAutosaveName), last
  tab (pre-existing), command-palette query history, build history, env run
  counts, containers column picker choices all persist; selected container
  survives via `selectedContainerID`.

---

## Prioritization quick-reference

| Priority | Ships | Items |
|---|---|---|
| **P0** | Phase 1 + 2.1–2.3 | ⌘K palette, global search, activity feed, tab badges, multi-select, themes, containers table, detail inspector, log viewer upgrade |
| **P1** | Phases 2.4–2.8, 3.1–3.3, 4.1 | stats history + dashboard chart, image variants, operations drawer, volume depth, network topology, compose stepper + profiles selector, YAML editor, notifications, machine/property surface |
| **P2** | Phases 2.9, 3.4–3.5, 4.3, 5 | empty states, environment manager, build editor + history, onboarding tour, tokens/accessibility/i18n/persistence |

**Fastest wins** (single-session, no new infra): 1.3 activity feed, 1.4 tab
badges, 1.8 shortcut reference, 2.9 empty states, 3.2 profiles selector.

## Where it plugs in

- `AppStore` is the single source of truth — new UI reads the same arrays;
  activity feed + batch actions are pure store additions.
- `StatsSampler` already computes CPU deltas; history ring = one struct in
  the store.
- `LogStreamer` follow streaming is fixed and reliable (readabilityHandler)
  — log tools build directly on it.
- `ProgressEvent.parse` handles BuildKit lines — the Operations drawer
  reuses it verbatim.
- Profiles/pull-policy already ship in `ComposeService` — 3.2 is UI only.
- Real-runtime e2e (`task e2e-real`) + mock suite (`task validate`) keep
  every new surface honest: services first, then UI on top of tested
  services.
