# Micropod brand

The current native treatment preserves Micropod's pod outline, three internal bars, and terminal chevron. It is editable vector geometry; the app and menu bar draw the same identity directly in SwiftUI.

## Current assets

- `Micropod-uplift.svg` — editable 1024 × 1024 app tile master, with white geometry on a blue gradient and transparent outer margins.
- `Micropod-uplift.icns` — macOS icon set generated from that master, covering the standard 16–1024 pixel representations.
- `Sources/MicropodApp/Views/BrandMark.swift` — native `MicropodGlyph` and `BrandMark` drawing code. The menu bar uses the monochrome glyph; the window and tray header use the blue tile.
- `docs/design/2026-10-01-micropod/brand/` — additional vector lockups, the imagegen raster concept, and native raster previews.

`scripts/package_app.sh` selects `Micropod-uplift.icns` first and installs it into the app bundle as `Micropod.icns`. The previous icon remains a fallback. If neither `.icns` exists, packaging runs the vector generator.

## Regenerate the icon

Run from the repository root on macOS:

```sh
swift scripts/make_icon.swift /tmp/micropod-icon-build
cp /tmp/micropod-icon-build/Micropod.icns assets/logo/Micropod-uplift.icns
```

`scripts/make_icon.swift` loads `Micropod-uplift.svg` with AppKit, draws exact pixel dimensions into bitmap representations, and calls macOS `iconutil`. An optional second argument selects another vector source. The native SwiftUI mark is authored separately with the same geometry; keep it aligned when changing the SVG master.

## Previous exploration

`Micropod.icns`, `exploration-1.png`, and `exploration-2.png` are the earlier BrandBrain explorations and are preserved. They were generated with the `logo-exploration` flow against the local BrandBrain backend using OpenAI `gpt-image-1`; session `flow_session_ad86b0b40587`.

The new imagegen mockups are design references. The packaged app tile and native glyph use the editable vector treatment, rather than raster mockup artwork.
