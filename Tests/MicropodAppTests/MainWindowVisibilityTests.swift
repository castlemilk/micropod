import AppKit
import XCTest

@testable import MicropodApp

/// Script native window state without ordering, minimizing, or hiding any
/// actual user window. Notifications exercise the observer's real lifecycle.
@MainActor
final class MainWindowVisibilityTests: XCTestCase {
    func testMinimizationOcclusionAndOrderingChangeVisibility() async {
        let center = NotificationCenter()
        var reports: [Bool] = []
        let coordinator = MainWindowVisibilityObserver.Coordinator(
            center: center, isApplicationHidden: { false },
            onVisibilityChange: { _, visible in reports.append(visible) })
        defer { coordinator.stop() }
        let window = makeWindow()
        coordinator.attach(to: window)
        await flushMainQueue()
        XCTAssertEqual(reports, [true])

        window.testMiniaturized = true
        center.post(name: NSWindow.didMiniaturizeNotification, object: window)
        await flushMainQueue()
        XCTAssertEqual(reports.last, false)

        window.testMiniaturized = false
        center.post(name: NSWindow.didDeminiaturizeNotification, object: window)
        await flushMainQueue()
        XCTAssertEqual(reports.last, true)

        window.testOccluded = true
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        await flushMainQueue()
        XCTAssertEqual(reports.last, false)

        window.testOccluded = false
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        await flushMainQueue()
        XCTAssertEqual(reports.last, true)

        window.testVisible = false
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        await flushMainQueue()
        XCTAssertEqual(reports, [true, false, true, false, true, false])
    }

    func testApplicationHideAndUnhideWithNotificationsCoalesced() async {
        let center = NotificationCenter()
        var hidden = false
        var reports: [Bool] = []
        let coordinator = MainWindowVisibilityObserver.Coordinator(
            center: center, isApplicationHidden: { hidden },
            onVisibilityChange: { _, visible in reports.append(visible) })
        defer { coordinator.stop() }
        let window = makeWindow()
        coordinator.attach(to: window)
        await flushMainQueue()

        hidden = true
        center.post(name: NSApplication.didHideNotification, object: nil)
        center.post(name: NSApplication.didChangeOcclusionStateNotification, object: nil)
        await flushMainQueue()
        XCTAssertEqual(reports, [true, false])

        hidden = false
        center.post(name: NSApplication.didUnhideNotification, object: nil)
        await flushMainQueue()
        XCTAssertEqual(reports, [true, false, true])
    }

    func testClosingWindowReportsHiddenBeforeNativeStateChanges() async {
        let center = NotificationCenter()
        var reports: [Bool] = []
        let coordinator = MainWindowVisibilityObserver.Coordinator(
            center: center, isApplicationHidden: { false },
            onVisibilityChange: { _, visible in reports.append(visible) })
        defer { coordinator.stop() }
        let window = makeWindow()
        coordinator.attach(to: window)
        await flushMainQueue()
        center.post(name: NSWindow.willCloseNotification, object: window)
        await flushMainQueue()
        XCTAssertEqual(reports, [true, false])
        XCTAssertTrue(window.isVisible, "willClose arrives before AppKit updates visibility")
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        await flushMainQueue()
        XCTAssertEqual(reports, [true, false])
    }

    func testWindowMigrationAndDismantlingRemoveOldObservers() async {
        let center = NotificationCenter()
        var reports: [(UUID, Bool)] = []
        let coordinator = MainWindowVisibilityObserver.Coordinator(
            center: center, isApplicationHidden: { false },
            onVisibilityChange: { id, visible in reports.append((id, visible)) })
        let first = makeWindow()
        let second = makeWindow()
        coordinator.attach(to: first)
        await flushMainQueue()
        coordinator.attach(to: second)
        await flushMainQueue()
        center.post(name: NSWindow.willCloseNotification, object: first)
        await flushMainQueue()
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.0, coordinator.windowID)
        XCTAssertEqual(reports.first?.1, true)

        MainWindowVisibilityObserver.dismantleNSView(
            MainWindowVisibilityObserver.VisibilityView(), coordinator: coordinator)
        await flushMainQueue()
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports.last?.0, coordinator.windowID)
        XCTAssertEqual(reports.last?.1, false)
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: second)
        center.post(name: NSApplication.didUnhideNotification, object: nil)
        await flushMainQueue()
        XCTAssertEqual(reports.count, 2)
    }

    private func makeWindow() -> VisibilityTestWindow {
        _ = NSApplication.shared
        let window = VisibilityTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func flushMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

@MainActor
private final class VisibilityTestWindow: NSWindow {
    var testVisible = true
    var testMiniaturized = false
    var testOccluded = false

    override var isVisible: Bool { testVisible }
    override var isMiniaturized: Bool { testMiniaturized }
    override var occlusionState: NSWindow.OcclusionState { testOccluded ? [] : [.visible] }
}
