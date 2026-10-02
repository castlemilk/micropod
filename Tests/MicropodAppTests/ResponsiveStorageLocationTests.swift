import AppKit
import SwiftUI
import XCTest

@testable import MicropodApp
@testable import MicropodCore

@MainActor
final class ResponsiveStorageLocationTests: XCTestCase {
    func testLongDriveNameAndPathWrapWithoutExpandingTheCard() {
        let name = "Development projects and virtual machines on a long named external drive"
        let volume = StorageLocation.Volume(
            mountPoint: URL(fileURLWithPath: "/Volumes/" + name + "/a-long-project-directory/retained-runtime-data"),
            name: name, format: "apfs", availableBytes: 128 << 30, totalBytes: 512 << 30,
            isInternal: false, isRemovable: false, formatDescription: "APFS (Case-sensitive)")
        for scheme in [ColorScheme.light, .dark] {
            let card = StorageDriveCard(volume: volume, isCurrent: false, isSelected: true, dataBytes: nil, select: {})
            let compact = fitted(card, scheme: scheme, width: 320)
            let wide = fitted(card, scheme: scheme, width: 900)
            XCTAssertLessThanOrEqual(compact.width, 320.5)
            XCTAssertLessThanOrEqual(wide.width, 900.5)
            XCTAssertGreaterThan(compact.height, wide.height + 25, "Long drive text must wrap instead of compressing")
            XCTAssertLessThan(compact.height, 480)
        }
    }

    func testUnsupportedRemovableDriveKeepsItsExplanationVisible() {
        let volume = StorageLocation.Volume(
            mountPoint: URL(fileURLWithPath: "/Volumes/Removable development backup"),
            name: "Removable development backup", format: "exfat", availableBytes: 8 << 30, totalBytes: 64 << 30,
            isInternal: false, isRemovable: true, formatDescription: "ExFAT")
        let card = StorageDriveCard(volume: volume, isCurrent: false, isSelected: false, dataBytes: nil, select: {})
        let compact = fitted(card, scheme: .light, width: 320)
        XCTAssertLessThanOrEqual(compact.width, 320.5)
        XCTAssertGreaterThan(compact.height, 110, "The APFS explanation and removable badge need visible rows")
        XCTAssertLessThan(compact.height, 360)
    }

    func testAllRelocationActionsKeepTheirNativeBoundsAtCompactWidths() throws {
        for width in [CGFloat(320), 560] {
            let recorder = ActionFrameRecorder()
            let actions = StorageLocationActions(
                working: false, canMove: true, canReset: true, hasOldData: true, move: {}, reset: {}, removeOld: {})
            let controller = NSHostingController(
                rootView:
                    actions
                    .overlayPreferenceValue(FormActionBounds.self) { anchors in
                        GeometryReader { geometry in recorder.capture(anchors, in: geometry) }
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    })
            controller.sizingOptions = []
            let size = NSSize(width: width, height: 120)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered,
                defer: false)
            window.contentViewController = controller
            window.setContentSize(size)
            window.orderBack(nil)
            defer { window.orderOut(nil) }
            controller.view.layoutSubtreeIfNeeded()
            controller.view.display()
            controller.view.layoutSubtreeIfNeeded()

            for id in ["storageLocation.move", "storageLocation.reset", "storageLocation.removeOld"] {
                let bounds = try XCTUnwrap(recorder.frames[id])
                XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: -1, dy: -1).contains(bounds), id)
                XCTAssertGreaterThan(bounds.width, 80, "\(id) must retain a readable native label")
                XCTAssertGreaterThan(bounds.height, 15, "\(id) must retain its native hit region")
            }
            let move = try XCTUnwrap(recorder.frames["storageLocation.move"])
            let reset = try XCTUnwrap(recorder.frames["storageLocation.reset"])
            if width == 320 {
                XCTAssertGreaterThan(abs(move.midY - reset.midY), 15, "Compact actions must stack")
            } else {
                XCTAssertEqual(move.midY, reset.midY, accuracy: 1, "Wide actions should share one row")
            }
        }
    }

    private func fitted<Content: View>(_ content: Content, scheme: ColorScheme, width: CGFloat) -> NSSize {
        NSHostingController(rootView: content.environment(\.colorScheme, scheme))
            .sizeThatFits(in: NSSize(width: width, height: 1000))
    }

    private final class ActionFrameRecorder {
        var frames: [String: CGRect] = [:]

        func capture(_ anchors: [String: Anchor<CGRect>], in geometry: GeometryProxy) -> Color {
            frames = anchors.mapValues { geometry[$0] }
            return .clear
        }
    }
}
