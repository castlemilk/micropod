import AppKit
import SwiftUI
import XCTest

@testable import MicropodApp

@MainActor
final class ResponsiveSharedLayoutTests: XCTestCase {
    func testSharedHeaderStacksBeforeCompressingItsAction() {
        let content = ResponsiveRow {
            Text("An unusually long cache heading that must wrap in a small pane")
        } trailing: {
            Button("Review cleanup…") {}
        }
        let compact = fitted(content, width: 320, height: 300)
        let wide = fitted(content, width: 1100, height: 300)
        XCTAssertLessThanOrEqual(compact.width, 320.5)
        XCTAssertGreaterThan(compact.height, wide.height + 10)
        XCTAssertLessThan(compact.height, 140)
    }

    func testChartSelectorAcceptsNarrowInspectorWidth() {
        for width in [CGFloat(140), 280, 360] {
            let size = fitted(ChartTimeWindowPicker(window: .constant(.sevenDays)), width: width, height: 80)
            XCTAssertLessThanOrEqual(size.width, width + 0.5)
            XCTAssertLessThanOrEqual(size.height, 40)
            XCTAssertGreaterThan(size.height, 12)
        }
    }

    func testBatchActionBarDoesNotDemandAllActionWidths() {
        let content = SelectionActionBar(
            count: 125,
            actions: {
                Button("Start selected workloads") {}
                Button("Stop selected workloads") {}
                Button("Restart selected workloads") {}
                Button("Delete selected workloads") {}
            }, onDone: {})
        let size = fitted(content, width: 320, height: 70)
        XCTAssertLessThanOrEqual(size.width, 320.5)
        XCTAssertLessThanOrEqual(size.height, 70.5)
        XCTAssertGreaterThan(size.height, 30)
    }

    func testCacheSummaryUsesOneOrTwoFullWidthColumns() {
        let content = CacheSummaryLayout {
            Color.clear.frame(height: 80).frame(maxWidth: .infinity)
            Color.clear.frame(height: 100).frame(maxWidth: .infinity)
        }
        let compact = fitted(content, width: 320, height: 400)
        let wide = fitted(content, width: 1200, height: 400)
        XCTAssertEqual(compact.width, 320, accuracy: 0.5)
        XCTAssertEqual(compact.height, 180 + Tokens.Spacing.lg, accuracy: 0.5)
        XCTAssertEqual(wide.width, 1200, accuracy: 0.5)
        XCTAssertEqual(wide.height, 100, accuracy: 0.5)
    }

    func testPaletteAcceptsShortCompactWindow() {
        let store = makeRunningStore(client: AppTestCLI.makeFailing())
        let size = fitted(CommandPaletteView(store: store), width: 320, height: 240)
        XCTAssertLessThanOrEqual(size.width, 320.5)
        XCTAssertLessThanOrEqual(size.height, 240.5)
    }

    func testEmptyStateAcceptsShortViewport() {
        let size = fitted(
            EmptyStateView(
                title: "No environments",
                description: "Import an environment to run all the services in a local project.",
                actionTitle: "Import…", action: {}), width: 320, height: 180)
        XCTAssertLessThanOrEqual(size.width, 320.5)
        XCTAssertLessThanOrEqual(size.height, 180.5)
    }

    private func fitted<Content: View>(_ content: Content, width: CGFloat, height: CGFloat) -> NSSize {
        NSHostingController(rootView: content).sizeThatFits(in: NSSize(width: width, height: height))
    }
}
