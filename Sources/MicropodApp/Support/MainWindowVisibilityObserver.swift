import AppKit
import SwiftUI

/// A window's SwiftUI content remains mounted when minimized or occluded.
/// Observe native visibility so hidden windows can pause expensive UI work.
struct MainWindowVisibilityObserver: NSViewRepresentable {
    var onVisibilityChange: @MainActor (UUID, Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onVisibilityChange: onVisibilityChange)
    }

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.windowDidChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: VisibilityView, context: Context) {
        context.coordinator.onVisibilityChange = onVisibilityChange
    }

    static func dismantleNSView(_ nsView: VisibilityView, coordinator: Coordinator) {
        nsView.windowDidChange = nil
        coordinator.stop()
    }

    @MainActor
    final class VisibilityView: NSView {
        var windowDidChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowDidChange?(window)
        }
    }

    @MainActor
    final class Coordinator {
        let windowID = UUID()
        var onVisibilityChange: @MainActor (UUID, Bool) -> Void

        private let center: NotificationCenter
        private let isApplicationHidden: @MainActor () -> Bool
        private weak var window: NSWindow?
        private var observations: [NSObjectProtocol] = []
        private var lastReported: Bool?
        private var isClosing = false
        private var refreshScheduled = false
        private var isStopped = false

        init(
            center: NotificationCenter = .default,
            isApplicationHidden: @escaping @MainActor () -> Bool = { NSApplication.shared.isHidden },
            onVisibilityChange: @escaping @MainActor (UUID, Bool) -> Void
        ) {
            self.center = center
            self.isApplicationHidden = isApplicationHidden
            self.onVisibilityChange = onVisibilityChange
        }

        isolated deinit { removeObservations() }

        func attach(to window: NSWindow?) {
            guard !isStopped, self.window !== window else { return }
            removeObservations()
            self.window = window
            isClosing = false
            if let window {
                for name in [
                    NSWindow.didChangeOcclusionStateNotification,
                    NSWindow.didMiniaturizeNotification,
                    NSWindow.didDeminiaturizeNotification,
                    NSWindow.willCloseNotification,
                ] {
                    observations.append(
                        center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                            MainActor.assumeIsolated {
                                if name == NSWindow.willCloseNotification { self?.isClosing = true }
                                self?.scheduleRefresh()
                            }
                        })
                }
                for name in [
                    NSApplication.didHideNotification,
                    NSApplication.didUnhideNotification,
                    NSApplication.didChangeOcclusionStateNotification,
                ] {
                    observations.append(
                        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                            MainActor.assumeIsolated { self?.scheduleRefresh() }
                        })
                }
            }
            scheduleRefresh()
        }

        func stop() {
            guard !isStopped else { return }
            isStopped = true
            removeObservations()
            window = nil
            let callback = onVisibilityChange
            let id = windowID
            // Dismantling can happen inside a SwiftUI update. Deliver the
            // state change after that update, even if this object is released.
            DispatchQueue.main.async { callback(id, false) }
        }

        private func scheduleRefresh() {
            guard !refreshScheduled, !isStopped else { return }
            refreshScheduled = true
            // Coalesce native notifications and avoid publishing observable
            // store state during SwiftUI's layout/update callbacks.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isStopped else { return }
                self.refreshScheduled = false
                let visible =
                    self.window.map {
                        $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
                    } == true && !self.isClosing && !self.isApplicationHidden()
                guard self.lastReported != visible else { return }
                self.lastReported = visible
                self.onVisibilityChange(self.windowID, visible)
            }
        }

        private func removeObservations() {
            for observation in observations { center.removeObserver(observation) }
            observations.removeAll()
        }
    }
}
