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
    }

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
    }

    enum RowHeight {
        static let compact: CGFloat = 24
        static let standard: CGFloat = 28
        static let spacious: CGFloat = 36
    }

    /// Chart palette: semantic series colors used across stats charts.
    enum Chart {
        static let cpu = Color.accentColor
        static let memory = Color.blue
        static let networkRx = Color.green
        static let networkTx = Color.blue
        static let diskRead = Color.orange
        static let diskWrite = Color.purple
    }
}
