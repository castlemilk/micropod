import AppKit
import SwiftUI

/// Persists and restores the main window frame via NSWindow's autosave
/// (name-scoped, survives relaunches). HIG: state persistence.
struct MainWindowFrameRestorer: NSViewRepresentable {
    static let autosaveName = "micropod.main-window"

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.setFrameAutosaveName(Self.autosaveName)
            if view.window?.frame.size.width == 0 {
                view.window?.setContentSize(NSSize(width: 1080, height: 700))
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Design tokens: spacing, radii, row heights, chart palette — the single
/// place for the app's visual rhythm (Phase 5 cross-cutting).
enum Tokens {
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let contentInset: CGFloat = 20
    }

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 10
        static let popover: CGFloat = 14
    }

    enum RowHeight {
        static let compact: CGFloat = 24
        static let standard: CGFloat = 28
        static let spacious: CGFloat = 36
    }

    enum Layout {
        static let sidebar: CGFloat = 200
        static let inspector: CGFloat = 360
        static let tableRow: CGFloat = 40
        static let trayWidth: CGFloat = 360
    }

    enum Typography {
        static let pageTitle = Font.system(size: 22, weight: .semibold)
        static let body = Font.system(size: 13)
        static let section = Font.system(size: 13, weight: .semibold)
        static let metadata = Font.system(size: 11)
        static let metric = Font.system(size: 20, weight: .medium).monospacedDigit()
        static let log = Font.system(size: 12, design: .monospaced)
    }

    enum Palette {
        static let canvas = adaptive(light: 0xF5F5F3, dark: 0x151719)
        static let sidebar = adaptive(light: 0xECEDEA, dark: 0x1B1E22)
        static let surface = adaptive(light: 0xFFFFFF, dark: 0x1F2328)
        static let elevated = adaptive(light: 0xFFFFFF, dark: 0x292E35)
        static let separator = adaptive(light: 0xD7DBE0, dark: 0x3D4652)
        static let controlBorder = adaptive(light: 0x858F9D, dark: 0x7C8999)
        // Native semantic labels follow Increased Contrast automatically.
        static let primary = Color(nsColor: .labelColor)
        static let secondary = Color(nsColor: .secondaryLabelColor)
        static let tertiary = adaptive(light: 0x606B79, dark: 0x98A3B3)
        static let accent = adaptive(light: 0x0067CF, dark: 0x0A84FF)
        static let accentText = adaptive(light: 0x0067CF, dark: 0x73B6FF)
        static let action = Color(red: 0, green: 103.0 / 255, blue: 207.0 / 255)
        static let success = adaptive(light: 0x197548, dark: 0x68D6A0)
        static let warning = adaptive(light: 0x8A5900, dark: 0xE6B65D)
        static let danger = adaptive(light: 0xBA3038, dark: 0xFF8888)
        static let selection = adaptive(light: 0xE4F0FF, dark: 0x163452)
        static let focus = adaptive(light: 0x0067CF, dark: 0x73B6FF)
    }

    enum Chart {
        static let cpu = adaptive(light: 0x0067CF, dark: 0x73B6FF)
        static let memory = adaptive(light: 0x127E71, dark: 0x65D2C3)
        static let networkRx = adaptive(light: 0x6D51B7, dark: 0xB7A6F7)
        static let networkTx = adaptive(light: 0x8A5900, dark: 0xE6B65D)
        static let diskRead = networkTx
        static let diskWrite = networkRx
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let value = isDark ? dark : light
                return NSColor(
                    srgbRed: Double((value >> 16) & 255) / 255,
                    green: Double((value >> 8) & 255) / 255,
                    blue: Double(value & 255) / 255, alpha: 1)
            })
    }
}
