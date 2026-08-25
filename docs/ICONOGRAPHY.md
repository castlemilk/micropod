# Micropod Iconography

All action/tab icons are **Lucide** (v1.33.0, ISC license — the shadcn icon
set), rasterized to 96px white-matte PNGs in `Resources/icons/` and rendered
as template-tinted glyphs. Tab glyphs were originally BrandBrain-generated;
action glyphs are Lucide for consistency at small sizes.

## Rendering

- `AppIcon` (Views/AppIcon.swift): draws the glyph as a `labelColor`-filled
  shape masked by the icon alpha — renders in every SwiftUI context and
  follows light/dark + tint automatically.
- `MenuItemIconLabel`: same icons in **menus** — menus map `Image(nsImage:)`
  to `NSMenuItem.image` (arbitrary views are dropped, so menu items must use
  this variant).
- SF Symbol fallbacks on every glyph (via `fallback:`) so a missing PNG
  degrades gracefully.

## Semantic map (icon name → Lucide glyph)

| Icon | Lucide | Used for |
|---|---|---|
| `start` | play | Start / Run |
| `stop` | square | Stop |
| `restart` | rotate-cw | Restart |
| `kill` | octagon-x | Kill (force stop) |
| `delete` | trash-2 | Delete |
| `deleteall` | list-x | Delete all shown |
| `prune` | broom | Prune / cleanup |
| `pull` | download | Pull / install |
| `push` | upload | Push |
| `build` | hammer | Build |
| `refresh` | refresh-cw | Refresh / retry |
| `copy` | copy | Copy (IDs, digests, JSON) |
| `tag` | tag | Tag |
| `details` | circle-help | Details |
| `import` | file-down | Import from file/tar |
| `export` | file-up | Export / save out |
| `choosefile` | file-input | Pick a file |
| `choosedest` | folder-input | Pick a destination |
| `duplicate` | copy-plus | Duplicate |
| `edit` | pencil | Edit |
| `create` | plus | Create (volume/network/machine) |
| `clear` | eraser | Clear |
| `send` | send | Terminal send |
| `detach` | circle-x | Terminal detach |
| `login` | key-round | Registry log in |
| `logout` | log-out | Log out |
| `composeup` | circle-arrow-up | Compose Up |
| `composedown` | circle-arrow-down | Compose Down |
| `save` | save | Save |
| `saveup` | square-arrow-up | Save & Up |
| `installkernel` | hard-drive-download | Install kernel |
| `power` | power | Power |
| `runtime` | square-power | Runtime toggle |
| `settings` | settings-2 | Settings |
| `quit` | power-off | Quit |
| `showall` | square-arrow-out-up-right | Show all |

Tab glyphs (BrandBrain): `containers images volumes networks registries
build compose environments storage dashboard files inspect logs stats
terminal settings`.

## Regenerating

```sh
# fetch: https://unpkg.com/lucide-static@1.33.0/icons/<glyph>.svg
# rasterize: NSImage SVG → 96px white-matte PNG with 10% inset (see git history
# for the script), drop into Sources/MicropodApp/Resources/icons/
```
