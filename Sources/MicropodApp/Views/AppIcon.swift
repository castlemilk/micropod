import AppKit
import SwiftUI

/// Iconography: every action icon in the app is an SF Symbol. SF Symbols
/// render reliably in every SwiftUI container (buttons, menus, alerts, list
/// rows, toolbar, navigation bars) on every macOS version, with automatic
/// light/dark + tint. The shadcn/lucide rasterized set in Resources/icons/ is
/// retained only for the full-illustration brand artwork in `EmptyStateArtwork`
/// (hero panels, empty states).
enum AppIconStore {
    /// Cached template masks of the full brand illustrations (dashboard hero,
    /// empty states). Action icons no longer go through here.
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [String: NSImage] = [:]

    /// Loads a brand illustration (full artwork from `Resources/brandbrain`).
    /// Returns nil for non-brand icon names — action icons go through SF Symbols.
    static func brand(_ name: String) -> NSImage? {
        if name.hasPrefix("dashboard") || name.hasSuffix("-empty") || name.hasPrefix("onboarding") {
            // served below
        } else {
            return nil
        }
        lock.lock()
        if let cached = cache[name] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let url =
            Bundle.micropodResources.url(forResource: name, withExtension: "png", subdirectory: "brandbrain")
            ?? Bundle.micropodResources.url(forResource: name, withExtension: "svg", subdirectory: "brandbrain")
        guard let url, let image = NSImage(contentsOf: url),
            let tiff = image.tiffRepresentation,
            let source = NSBitmapImageRep(data: tiff)
        else { return nil }
        let w = source.pixelsWide, h = source.pixelsHigh
        guard
            let alpha = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)
        else { return nil }
        for y in 0..<h {
            for x in 0..<w {
                guard let c = source.colorAt(x: x, y: y) else { continue }
                let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
                alpha.setColor(NSColor(calibratedWhite: 1, alpha: min(1, max(0, 1 - lum))), atX: x, y: y)
            }
        }
        let out = NSImage(size: NSSize(width: w, height: h))
        out.addRepresentation(alpha)
        out.isTemplate = true
        lock.lock()
        cache[name] = out
        lock.unlock()
        return out
    }
}

/// Single source of truth: semantic icon name → SF Symbol name. Add new
/// actions here. Buttons use `Image(systemName: AppIcon.sfName(for:))`
/// directly; this guarantees icons render in buttons, menus, dialogs,
/// toolbar, list rows, anywhere SwiftUI is asked to show them.
struct AppIcon {
    /// Loads a brand illustration (full artwork from `Resources/brandbrain`).
    /// Kept here so the file is the single icon surface; action icons go
    /// through SF Symbols via `sfName(for:)`.
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [String: NSImage] = [:]

    static func brand(_ name: String) -> NSImage? {
        if !name.hasPrefix("dashboard") && !name.hasSuffix("-empty") && !name.hasPrefix("onboarding") {
            return nil
        }
        lock.lock()
        if let cached = cache[name] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let url =
            Bundle.micropodResources.url(forResource: name, withExtension: "png", subdirectory: "brandbrain")
            ?? Bundle.micropodResources.url(forResource: name, withExtension: "svg", subdirectory: "brandbrain")
        guard let url, let image = NSImage(contentsOf: url),
            let tiff = image.tiffRepresentation,
            let source = NSBitmapImageRep(data: tiff)
        else { return nil }
        let w = source.pixelsWide, h = source.pixelsHigh
        guard
            let alpha = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)
        else { return nil }
        for y in 0..<h {
            for x in 0..<w {
                guard let c = source.colorAt(x: x, y: y) else { continue }
                let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
                alpha.setColor(NSColor(calibratedWhite: 1, alpha: min(1, max(0, 1 - lum))), atX: x, y: y)
            }
        }
        let out = NSImage(size: NSSize(width: w, height: h))
        out.addRepresentation(alpha)
        out.isTemplate = true
        lock.lock()
        cache[name] = out
        lock.unlock()
        return out
    }

    static let map: [String: String] = [
        // Lifecycle
        "start": "play.fill",
        "stop": "stop.fill",
        "restart": "arrow.clockwise",
        "kill": "xmark.octagon",
        "runtime": "powerplug.fill",
        "power": "power.circle",
        "runtimestart": "play.fill",

        // Data actions
        "pull": "arrow.down.circle",
        "push": "arrow.up.circle",
        "delete": "trash",
        "deleteall": "trash.slash",
        "prune": "trash.slash",
        "duplicate": "plus.square.on.square",
        "edit": "pencil",
        "create": "plus",
        "save": "square.and.arrow.down",
        "saveup": "arrow.up.square",
        "clear": "eraser",
        "refresh": "arrow.clockwise",
        "build": "hammer",
        "installkernel": "arrow.down.circle",

        // Resource actions
        "copy": "doc.on.doc",
        "tag": "tag",
        "details": "info.circle",
        "view": "eye",
        "import": "arrow.down.doc",
        "export": "arrow.up.doc",
        "choosefile": "arrow.down.doc",
        "choosedest": "arrow.up.doc",
        "send": "paperplane",
        "detach": "xmark.circle",

        // Auth
        "login": "key",
        "logout": "rectangle.portrait.and.arrow.right",

        // Compose
        "composeup": "arrow.up.circle",
        "composedown": "arrow.down.circle",

        // Settings / nav
        "settings": "gearshape",
        "quit": "power.circle",
        "showall": "square.grid.2x2",
        "palette": "command",

        // Filesystem containers
        "storage": "externaldrive",
        "compose": "square.stack.3d.up",
        "composefwd": "square.stack.3d.up",
    ]

    static func sfName(for name: String) -> String {
        Self.map[name] ?? name
    }

    let name: String
    var size: CGFloat = 14

    var body: some View {
        Image(systemName: AppIcon.sfName(for: name))
            .font(.system(size: size))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A button label: SF Symbol icon + text. Renders everywhere — buttons,
/// menus, dialogs, toolbar, list rows, navigation links.
struct IconLabel: View {
    let title: String
    let icon: String
    var fallback: String = "questionmark"

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: AppIcon.sfName(for: icon))
        }
    }
}

/// Menu items — same as IconLabel now (kept as a distinct type so call
/// sites document intent; SF Symbols render identically in menus).
typealias MenuItemIconLabel = IconLabel
