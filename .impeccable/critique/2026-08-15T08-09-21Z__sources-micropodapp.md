---
target: Sources/MicropodApp
total_score: 24
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 2
p2_count: 2
p3_count: 1
timestamp: 2026-08-15T08-09-21Z
slug: sources-micropodapp
---
# Critique — Micropod (Sources/MicropodApp)

Design Health: 24/40 (Acceptable). Heuristics: 1:3, 2:3, 3:2, 4:2, 5:2, 6:3, 7:3, 8:2, 9:2, 10:2. n/a: none.

Design Specificity Verdict: functionally grounded, visually interchangeable. Content is unmistakably Micropod (kernel banner, compose translation copy, reclaimable metrics); chrome is stock SwiftUI with no brand tokens, no typographic voice, no in-app brand moment.

Strengths: activity feed (level-keyed, capped, deep-linked, only place batch partial failures report); command palette (grouped sections, arrow wrap, deep links); honest empty states + onboarding copy.

Priority Issues:
- P1 Destructive actions don't confirm: detail force-delete (ContainerDetailView.swift:107), image delete, all Dashboard prunes, Delete All (force) — while batch delete confirms (ContainersView.swift:198). Fix: one confirmation policy; two-step prune with what-will-be-removed.
- P1 Broken flows present as working UI: context-menu Delete sets confirmDeleteID never consumed (ContainersView.swift:237); pull failure message lies (ImagesView.swift:329); Dockerfile Choose… unreachable (BuildView.swift:144).
- P2 Logs toolbar overload + Inspect/Config ambiguity: 9 controls, Pause disabled when Follow off; 6-pane segmented control with near-synonym panes (ContainerDetailView.swift:9-13).
- P2 Palette truncates before filtering: containers.prefix(8) applied pre-query (CommandPaletteView.swift:200-234).
- P3 Visual identity absent: brand lives only in Dock icon; data typography is the habit, not the identity.

Persona Red Flags:
- Alex: palette unreachable past 8 containers; no name column, concatenated ports; one-click Stop All / Delete All (force).
- Jordan: Run sheet pre-fills alpine:latest with Detach/Init on; Rosetta unexplained; menu-bar 16x16 stop button.
- Sam: status pill same-color-on-12%-tint fails contrast; .tertiary data; 9pt kernel log; unlabeled search fields; 0 accessibility identifiers.
- Riley: no-confirm force deletes; prunes never say what will be removed; pull-error message lies; batch partial failures only in feed.

Minor: "Runtime running · 3 running" duplicate; equal-weight prune buttons; inconsistent prune naming; Environments statusless after tab switch; unvalidated Settings numbers; hardcoded 0.1.0; terminal pane promise mismatch; palette dismissal flakiness under automation.

Questions: identity as data typography vs brand layer; prune confirmation vs reclaimable-bytes-as-confirmation; palette launcher-vs-browser boundary.
