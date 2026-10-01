import AppKit
import SwiftUI
import XCTest

@testable import MicropodApp

/// Measure the inspector's intrinsic layout so a fixed outer frame cannot
/// hide regressions that compress or truncate a long value instead of wrapping it.
@MainActor
final class ResponsiveInspectorTests: XCTestCase {
    func testLongIdentifierUsesVerticalSpaceAtCompactWidths() {
        let value = "ghcr.io/micropod-development/platform-services/api-gateway:feature-long-identifier"
        let compact = fittingSize(InspectorFieldRow(label: "Image", value: value), width: 320)
        let medium = fittingSize(InspectorFieldRow(label: "Image", value: value), width: 360)
        let wide = fittingSize(InspectorFieldRow(label: "Image", value: value), width: 900)

        XCTAssertEqual(compact.width, 320, accuracy: 0.5)
        XCTAssertEqual(medium.width, 360, accuracy: 0.5)
        XCTAssertGreaterThan(compact.height, wide.height + 10)
        XCTAssertGreaterThan(medium.height, wide.height + 10)
        XCTAssertLessThan(compact.height, 160, "A single field must not consume the whole compact inspector")
    }

    func testShortFieldStaysCompactAndSupportsBrowserAction() {
        let size = fittingSize(
            InspectorFieldRow(label: "Port", value: "8080:80/tcp", primaryAction: {}), width: 320)
        XCTAssertEqual(size.width, 320, accuracy: 0.5)
        XCTAssertGreaterThan(size.height, 12)
        XCTAssertLessThanOrEqual(size.height, 36)
    }

    func testUnbrokenDigestWrapsRatherThanExpandingInspector() {
        let digest = "sha256:" + String(repeating: "abc123de", count: 12)
        let compact = fittingSize(InspectorFieldRow(label: "Digest", value: digest), width: 320)
        let wide = fittingSize(InspectorFieldRow(label: "Digest", value: digest), width: 1100)
        XCTAssertEqual(compact.width, 320, accuracy: 0.5)
        XCTAssertGreaterThan(compact.height, wide.height + 10)
        XCTAssertLessThan(compact.height, 180)
    }

    private func fittingSize<Content: View>(_ view: Content, width: CGFloat) -> NSSize {
        let hosting = NSHostingView(rootView: view.frame(width: width))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 240)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize
    }
}
