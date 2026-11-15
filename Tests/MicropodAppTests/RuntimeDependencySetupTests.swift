import AppKit
import MicropodCore
import SwiftUI
import Vision
import XCTest

@testable import MicropodApp

@MainActor
final class RuntimeDependencySetupTests: XCTestCase {
    func testMissingRuntimeActionsStayVisibleAtCompactWidthsInLightAndDark() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(dependencies: AppDependencies(client: ContainerCLIClient(executableURL: missing)))
        await store.refreshSystemStatus(force: true)
        XCTAssertEqual(store.runtimeDependencyStatus.state, .missingCLI)
        for scheme in [ColorScheme.light, .dark] {
            let recorder = Recorder()
            let controller = NSHostingController(
                rootView: RuntimeDependencyActions(store: store)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, scheme)
                    .overlayPreferenceValue(FormActionBounds.self) { anchors in
                        GeometryReader { geometry in recorder.capture(anchors, in: geometry) }
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    })
            controller.sizingOptions = []
            let size = NSSize(width: 320, height: 280)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentViewController = controller
            window.setContentSize(size)
            window.orderBack(nil)
            defer { window.orderOut(nil) }
            controller.view.layoutSubtreeIfNeeded()
            controller.view.display()
            for id in ["runtime.getInstaller", "runtime.recheck"] {
                let bounds = try XCTUnwrap(recorder.frames[id], id)
                XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: -1, dy: -1).contains(bounds), id)
                XCTAssertGreaterThan(bounds.height, 15, id)
                XCTAssertGreaterThan(bounds.width, 60, id)
            }
            let rep = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
            controller.view.cacheDisplay(in: controller.view.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            let recognize = VNRecognizeTextRequest()
            recognize.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: try XCTUnwrap(rep.cgImage)).perform([recognize])
            let text = recognize.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
            XCTAssertTrue(text.contains("Get Apple container"), text)
            XCTAssertTrue(text.contains("Check Again"), text)
            let name = scheme == .dark ? "dark" : "light"
            try png.write(
                to: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "micropod-dependency-setup-\(name).png"))
        }
    }

    private final class Recorder {
        var frames: [String: CGRect] = [:]
        func capture(_ anchors: [String: Anchor<CGRect>], in geometry: GeometryProxy) -> Color {
            frames = anchors.mapValues { geometry[$0] }
            return .clear
        }
    }
}
