import AppKit
import MicropodCore
import SwiftUI
import XCTest

@testable import MicropodApp

/// Exercise each sheet's proposed minimum size and verify the primary action
/// remains inside the visible content, rather than below its scroll viewport.
@MainActor
final class ResponsiveFormTests: XCTestCase {
    func testCompactSheetsFitAndKeepPrimaryActionsVisible() throws {
        let store = makeRunningStore(client: AppTestCLI.makeFailing())
        defer { store.stopPollers() }
        var spec = Micropod_V1_ComposeSpec()
        spec.name = "A-development-environment-with-a-long-name"
        let environment = EnvironmentsView.SavedEnvironment(
            id: spec.name, spec: spec, yamlURL: nil,
            binURL: URL(fileURLWithPath: "/tmp/micropod-responsive-test.spec.bin"))

        for scheme in [ColorScheme.light, .dark] {
            let size = NSSize(width: 420, height: 320)
            try assertFitsAndActionVisible(
                RunContainerSheet(store: store), size: size, scheme: scheme,
                actionID: "runContainer.run", name: "run")
            try assertFitsAndActionVisible(
                ComposeEditorSheet(store: store, environment: environment, initialYAML: ""),
                size: size, scheme: scheme, actionID: "composeEditor.saveAndUp", name: "compose-editor")
            try assertFitsAndActionVisible(
                OnboardingTourView(store: store), size: size, scheme: scheme,
                actionID: "onboarding.finish", name: "onboarding")
        }
    }

    func testCompactProjectViewsKeepActionsVisibleWithLongContent() throws {
        let store = makeRunningStore(client: AppTestCLI.makeFailing())
        defer { store.stopPollers() }
        var spec = Micropod_V1_ComposeSpec()
        spec.name = "Development"
        spec.path = "/tmp/micropod-responsive-test/a-long-project-path/compose.yml"
        spec.services = (1...24).map { index in
            var service = Micropod_V1_ComposeServiceSpec()
            service.name = "service-\(index)-with-a-long-name"
            service.image = "ghcr.io/example/long-image-name:development"
            return service
        }
        for scheme in [ColorScheme.light, .dark] {
            let size = NSSize(width: 660, height: 400)
            try assertFitsAndActionVisible(
                BuildView(store: store), size: size, scheme: scheme,
                actionID: "build.start", name: "build")
            try assertFitsAndActionVisible(
                ComposeView(store: store, initialSpec: spec), size: size, scheme: scheme,
                actionID: "compose.up", name: "compose")
        }
    }

    private func assertFitsAndActionVisible<Content: View>(
        _ content: Content, size: NSSize, scheme: ColorScheme, actionID: String, name: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let recorder = ActionFrameRecorder()
        let controller = NSHostingController(
            rootView:
                content.environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: "en"))
                .overlayPreferenceValue(FormActionBounds.self) { anchors in
                    GeometryReader { geometry in
                        recorder.capture(anchors, in: geometry)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                })
        controller.sizingOptions = []
        let fitted = controller.sizeThatFits(in: size)
        XCTAssertLessThanOrEqual(fitted.width, size.width + 1, "\(name) width", file: file, line: line)
        XCTAssertLessThanOrEqual(fitted.height, size.height + 1, "\(name) height", file: file, line: line)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentViewController = controller
        window.setContentSize(size)
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        controller.view.layoutSubtreeIfNeeded()
        controller.view.display()
        controller.view.layoutSubtreeIfNeeded()

        let actionFrame = try XCTUnwrap(
            recorder.frames[actionID], "\(name) primary action bounds unavailable", file: file, line: line)
        let contentFrame = CGRect(origin: .zero, size: size).insetBy(dx: -1, dy: -1)
        XCTAssertGreaterThan(actionFrame.width, 10, "\(name) action width", file: file, line: line)
        XCTAssertGreaterThan(actionFrame.height, 10, "\(name) action height", file: file, line: line)
        XCTAssertTrue(contentFrame.contains(actionFrame), "\(name) action must stay visible", file: file, line: line)
        XCTAssertLessThanOrEqual(
            contentFrame.maxY - actionFrame.midY, 70,
            "\(name) primary action should remain in the bottom action row", file: file, line: line)

    }

    /// Capturing these resolved anchors does not update SwiftUI state. The
    /// test can inspect the button's native layout after a synchronous render.
    private final class ActionFrameRecorder {
        var frames: [String: CGRect] = [:]

        func capture(_ anchors: [String: Anchor<CGRect>], in geometry: GeometryProxy) -> Color {
            frames = anchors.mapValues { geometry[$0] }
            return .clear
        }
    }
}
