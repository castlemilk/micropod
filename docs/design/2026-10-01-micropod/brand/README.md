# Brand assets

- `app-icon.png`: built-in imagegen raster app-icon concept, with neutral presentation background. It is a visual reference, not a packaged macOS `.icns`.
- `app-tile.svg`: editable vector tile concept with exact geometry.
- `mark-blue.svg`, `mark-white.svg`: explicit-color marks for light/dark surfaces.
- `mark-template.svg`: tintable monochrome template (`currentColor`); use as a menu-bar template mask.
- `wordmark-light.svg`, `wordmark-dark.svg`: system-font lockups; text remains editable and depends on the host font. Outline it before distributing outside the app.

The original Micropod pod outline, three internal bars and forward chevron are retained. This vector treatment redraws the existing identity with clearer spacing; it is not a pixel trace of the raster concept. Use the native icon pipeline to create optimized menu-bar masks and `.icns` assets, and visually check 16/18/32px sizes before adoption.

All files are sibling concept assets. Existing production brand assets were not replaced.
