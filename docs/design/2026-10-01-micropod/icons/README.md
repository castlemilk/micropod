# Micropod iconography

An original, project-local set of 24 operational pictograms for the Micropod desktop app and menu bar panel. These are editable SVG source assets, independent of the generated concept images.

- Canvas: `24 × 24` SVG user units.
- Stroke: `1.75` user units; round caps and joins.
- Paint: `fill="none"`, `stroke="currentColor"`.
- Minimum painted margin: `2` user units on all sides, including half the stroke width.
- Preferred sizes: 20 or 24 px in the desktop app; 16–18 px in the compact menu bar panel. The small sizes still require a native rendering review before shipping.
- Light ink: `#2A2D32`; dark ink: `#D8DCE3`; Micropod accent: `#0A84FF`.

## Files

`manifest.json` supplies each filename, accessible label, intended meaning, and a proposed native SF Symbol fallback. Every SF Symbol name is **unverified**: check availability in SF Symbols and against the app’s minimum macOS version before integration.

`contact-sheet.svg` embeds all 24 icons and displays each in both light and dark treatments. It is self-contained and has no external asset dependency. The fonts use system fallbacks. `contact-sheet.png` is a macOS AppKit render of that sheet, visually reviewed at 28px icon size.

## Usage

Use each icon for its meaning in the manifest. Pair the cache variants with text until they become familiar. Keep semantic state color on the status indicator and label, rather than coloring an entire toolbar row. Use `play`, `stop`, and `restart` for workload actions, `cache-clean` for a reviewable reclamation flow, and `download` for an image pull or export.

Inline the SVG when the UI needs `currentColor`. An SVG referenced through an `<img>` tag does not inherit CSS color from its parent. The source includes an accessible title; remove that title and set `aria-hidden="true"` if a neighboring control label already names the action. For icon-only controls, name the control itself and provide a tooltip.

For a native SwiftUI or AppKit implementation, either convert the project SVGs into template PDF assets or use a verified SF Symbol fallback. The menu bar status icon belongs to the brand asset set; these pictograms are for controls and navigation.

## Validation

The accompanying `validation.json` records XML parsing, icon count, required SVG properties, and analytic geometric bounds with a half-stroke margin. All 24 icons were also rendered by macOS AppKit and visually reviewed at 28px in the light and dark contact sheet; no clipping or inconsistent strokes were observed. Cache variants need labels for recognition. Small 16–18px operational sizes, template integration, VoiceOver behavior, and SF Symbol runtime availability remain unverified. Review small-size rendering in the actual macOS application before integration.

## Provenance

Geometry was authored for this project using conventional line-icon construction. No library asset was copied. The design is deliberately compatible with the weight and restraint of native macOS controls.
