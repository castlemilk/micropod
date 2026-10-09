import AppKit
import XCTest

@testable import MicropodApp

/// Exercise native presentation without moving or minimizing any user window.
@MainActor
final class MainWindowPresenterTests: XCTestCase {
    func testRepeatedOpenReusesTheExistingMainWindow() {
        var opens = 0
        var activations = 0
        let presenter = MainWindowPresenter(activate: { activations += 1 })
        let window = makeWindow()
        presenter.attach(to: window) { opens += 1 }
        for _ in 0..<20 { XCTAssertTrue(presenter.show()) }
        XCTAssertEqual(opens, 0)
        XCTAssertEqual(window.frontRequests, 20)
        XCTAssertEqual(activations, 20)
    }

    func testOpenRestoresAMinimizedMainWindow() {
        let presenter = MainWindowPresenter(activate: {})
        let window = makeWindow()
        window.minimized = true
        presenter.attach(to: window) { XCTFail("Minimization must not create a window") }
        presenter.show()
        XCTAssertEqual(window.restoreRequests, 1)
        XCTAssertEqual(window.frontRequests, 1)
        XCTAssertFalse(window.minimized)
    }

    func testOpenReusesAHiddenWindowAndActivatesTheApp() {
        var activations = 0
        let presenter = MainWindowPresenter(activate: { activations += 1 })
        let window = makeWindow()
        presenter.attach(to: window) { XCTFail("Hidden windows must be reused") }
        presenter.show()
        XCTAssertEqual(window.frontRequests, 1)
        XCTAssertEqual(activations, 1)
    }

    func testClosingMainWindowReopensTheSceneAndThenReusesIt() {
        let center = NotificationCenter()
        let presenter = MainWindowPresenter(center: center, activate: {})
        let original = makeWindow()
        let replacement = makeWindow()
        var opens = 0
        let open = { [presenter] in
            opens += 1
            presenter.attach(to: replacement) { XCTFail("Reopened window must be reused") }
        }
        presenter.attach(to: original, open: open)
        center.post(name: NSWindow.willCloseNotification, object: original)
        presenter.show()
        presenter.show()
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(original.frontRequests, 0)
        XCTAssertEqual(replacement.frontRequests, 1)
    }

    func testUnrelatedWindowCloseDoesNotForgetMainWindow() {
        let center = NotificationCenter()
        let presenter = MainWindowPresenter(center: center, activate: {})
        let main = makeWindow()
        let settings = makeWindow()
        presenter.attach(to: main) { XCTFail("Closing Settings must not open a window") }
        center.post(name: NSWindow.willCloseNotification, object: settings)
        presenter.show()
        XCTAssertEqual(main.frontRequests, 1)
        XCTAssertEqual(settings.frontRequests, 0)
    }

    func testDockAndAlreadyRunningReopenRevealMainEvenWithOtherVisibleWindows() {
        let presenter = MainWindowPresenter(activate: {})
        let window = makeWindow()
        presenter.attach(to: window) { XCTFail("Reopen must reuse the main window") }
        let delegate = MicropodApplicationDelegate(presenter: presenter)
        for visible in [false, true, true] {
            XCTAssertFalse(delegate.applicationShouldHandleReopen(.shared, hasVisibleWindows: visible))
        }
        XCTAssertEqual(window.frontRequests, 3)
    }

    func testInitialReopenWithoutSceneActionKeepsOrdinaryLaunchBehavior() {
        let presenter = MainWindowPresenter(activate: { XCTFail("No scene is available yet") })
        let delegate = MicropodApplicationDelegate(presenter: presenter)
        XCTAssertTrue(delegate.applicationShouldHandleReopen(.shared, hasVisibleWindows: false))
    }

    func testClosingMainWindowKeepsTheMenuBarAppRunning() {
        let delegate = MicropodApplicationDelegate(presenter: MainWindowPresenter(activate: {}))
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
    }

    private func makeWindow() -> PresentationTestWindow {
        _ = NSApplication.shared
        let window = PresentationTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}

@MainActor
private final class PresentationTestWindow: NSWindow {
    var minimized = false
    var frontRequests = 0
    var restoreRequests = 0

    override var isMiniaturized: Bool { minimized }

    override func deminiaturize(_ sender: Any?) {
        restoreRequests += 1
        minimized = false
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        frontRequests += 1
    }
}
