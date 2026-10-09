import AppKit
import SwiftUI

/// All entry points reveal the app's one main scene. The native window is
/// observed rather than recreated, so minimized and hidden windows keep state.
@MainActor
final class MainWindowPresenter {
    static let shared = MainWindowPresenter()
    static let sceneID = "main-window"

    private weak var window: NSWindow?
    private var openWindow: (() -> Void)?
    private var closeObservation: NSObjectProtocol?
    private var attachmentID = UUID()
    private let center: NotificationCenter
    private let activate: () -> Void

    init(
        center: NotificationCenter = .default,
        activate: @escaping () -> Void = {
            NSApplication.shared.unhide(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    ) {
        self.center = center
        self.activate = activate
    }

    isolated deinit {
        if let closeObservation { center.removeObserver(closeObservation) }
    }

    func attach(to window: NSWindow, open: @escaping () -> Void) {
        openWindow = open
        guard self.window !== window else { return }
        if let closeObservation { center.removeObserver(closeObservation) }
        self.window = window
        let id = UUID()
        attachmentID = id
        closeObservation = center.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.attachmentID == id else { return }
                self.window = nil
            }
        }
    }

    /// Returns false before SwiftUI has supplied an opening action, allowing
    /// AppKit's ordinary first-launch behavior to continue.
    @discardableResult
    func show(open: (() -> Void)? = nil) -> Bool {
        if let open { openWindow = open }
        guard window != nil || openWindow != nil else { return false }
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            // Window (unlike WindowGroup) owns uniqueness even when repeated
            // requests arrive before its content attaches to a native window.
            openWindow?()
        }
        activate()
        return true
    }
}

@MainActor
final class MicropodApplicationDelegate: NSObject, NSApplicationDelegate {
    private let presenter: MainWindowPresenter

    override init() {
        presenter = .shared
        super.init()
    }

    init(presenter: MainWindowPresenter) {
        self.presenter = presenter
        super.init()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Dock activation and Launch Services reopening must target the main
        // window even when a Settings window or the tray is currently visible.
        !presenter.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// A single-instance SwiftUI scene, also usable by isolated native UI tests.
struct MainWindowScene<Content: View>: Scene {
    var title = "Micropod"
    var presenter: MainWindowPresenter = .shared
    @ViewBuilder var content: () -> Content

    var body: some Scene {
        Window(title, id: MainWindowPresenter.sceneID) {
            content().background(MainWindowPresentationBridge(presenter: presenter))
        }
    }
}

private struct MainWindowPresentationBridge: NSViewRepresentable {
    var presenter: MainWindowPresenter
    @Environment(\.openWindow) private var openWindow

    func makeNSView(context: Context) -> PresentationView {
        let view = PresentationView()
        view.windowDidChange = { [presenter, openWindow] window in
            guard let window else { return }
            presenter.attach(to: window) { openWindow(id: MainWindowPresenter.sceneID) }
        }
        return view
    }

    func updateNSView(_ view: PresentationView, context: Context) {
        view.windowDidChange = { [presenter, openWindow] window in
            guard let window else { return }
            presenter.attach(to: window) { openWindow(id: MainWindowPresenter.sceneID) }
        }
        view.windowDidChange?(view.window)
    }

    static func dismantleNSView(_ view: PresentationView, coordinator: ()) {
        view.windowDidChange = nil
    }

    final class PresentationView: NSView {
        var windowDidChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowDidChange?(window)
        }
    }
}
