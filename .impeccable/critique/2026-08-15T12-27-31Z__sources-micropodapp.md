---
target: Sources/MicropodApp
total_score: 32
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 0
p2_count: 1
p3_count: 1
timestamp: 2026-08-15T12-27-31Z
slug: sources-micropodapp
---
# Critique — Micropod (Sources/MicropodApp) — second pass

Design Health: 32/40 (Good, up from 24). Heuristics: 1:3, 2:3, 3:4, 4:3, 5:3, 6:4, 7:3, 8:4, 9:3, 10:2. n/a: none.

Key improvements verified: destructive confirmations everywhere (single delete, detail header, image delete, all prunes, Delete All), pull error now surfaces the real reason, palette filters before truncating, AX labels added across search fields/settings/menu bar, logs toolbar distilled (Follow=Pause, Inspect (JSON)), copy fixes, bundle version, Environments live state, contrast fixes, BrandMark identity moments, window min 720x460 + scrollable panes.

Regression found & fixed this pass: menu bar panel stopped opening (ScrollView root broke MenuBarExtra popover) — reverted to VStack, panel verified opening/rendering/dismissing.

Remaining: Settings inputs lack explicit identifiers (adjacent labels OK), global alert uses .constant binding, some prunes in menus/palette confirm via dedicated dialogs now, "Delete All Shown (N)" honest label under filters, palette empty-result crash fixed with guards.

New issues noted: NetworkRowView state dot never renders .gray (state string mismatch, low risk).
