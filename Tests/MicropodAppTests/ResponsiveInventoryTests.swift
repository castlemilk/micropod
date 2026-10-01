import AppKit
import MicropodCore
import SwiftUI
import XCTest

@testable import MicropodApp

/// Exercises native minimum-size proposals with identifiers and metadata that
/// previously forced headers and action buttons beyond compact pane bounds.
final class ResponsiveInventoryTests: XCTestCase {
    @MainActor
    func testDetailSheetsAcceptMinimumWidthAndHeightWithLongMetadata() {
        let store = makeRunningStore(client: AppTestCLI.makeFailing())
        let image = makeImage()
        let network = makeNetwork()
        let volume = makeVolume()
        var container = Micropod_V1_Container()
        container.id = String(repeating: "attached-workload-", count: 15)
        container.state = "running"
        container.networks = [network.id]
        container.ipv4Address = "192.168.100.200"
        store.containers = [container]
        store.volumes = [volume]

        assertFits(ImageDetailSheet(store: store, image: image), in: CGSize(width: 320, height: 260))
        assertFits(NetworkDetailSheet(store: store, network: network), in: CGSize(width: 320, height: 260))
        assertFits(VolumeDetailSheet(store: store, volume: volume), in: CGSize(width: 320, height: 260))
    }

    @MainActor
    func testInventoryFormsAcceptCompactSheetProposal() {
        let store = makeRunningStore(client: AppTestCLI.makeFailing())
        let proposal = CGSize(width: 320, height: 300)
        assertFits(PullImageSheet(store: store, onPull: { _ in }), in: proposal)
        assertFits(TagImageSheet(store: store, image: makeImage()), in: proposal)
        assertFits(CreateNetworkSheet(store: store), in: proposal)
        assertFits(CreateVolumeSheet(store: store), in: proposal)
        assertFits(RegistryLoginSheet(store: store), in: proposal)
        assertFits(
            PullProgressSheet(
                store: store, reference: String(repeating: "long-registry-reference/", count: 20), opID: UUID()),
            in: proposal)
    }

    @MainActor
    func testCopyRowsKeepFullValuesWithoutDemandingIdentifierWidth() {
        let row = InventoryCopyRow(
            label: "Label " + String(repeating: "long-key-", count: 15),
            value: "/" + String(repeating: "very-long-unbroken-source-path/", count: 30))
        for width in [CGFloat(220), 320, 660] {
            assertFits(row, in: CGSize(width: width, height: 100))
        }
    }

    @MainActor
    func testInventoryRowsAcceptCompactWidthWithLongNames() {
        let proposal = CGSize(width: 320, height: 90)
        assertFits(ImageRowView(image: makeImage(), isExpanded: .constant(false)), in: proposal)
        assertFits(NetworkRowView(network: makeNetwork()), in: proposal)
        assertFits(VolumeRowView(volume: makeVolume()), in: proposal)

        var container = Micropod_V1_Container()
        container.id = String(repeating: "long-workload-name-", count: 20)
        container.image = String(repeating: "registry.example.com/nested-path/", count: 20)
        container.state = "running"
        for width in [CGFloat(320), 660, 820, 1200] {
            let layout = ContainerColumnLayout.compute(visible: Set(ContainerSortKey.allCases), width: width)
            assertFits(
                ContainerRowView(container: container, stats: nil, layout: layout), in: CGSize(width: width, height: 90)
            )
        }
    }

    @MainActor
    func testContainersPaneKeepsNativeControlsInsideBoundsWhileResizing() {
        let store = makeRunningStore(client: AppTestCLI.makeFailing())
        store.containers = (0..<5).map { index in
            var container = Micropod_V1_Container()
            container.id = "workload-\(index)-" + String(repeating: "long-identifier-", count: 20)
            container.image = String(repeating: "registry.example.com/nested-path/", count: 20)
            container.state = "running"
            return container
        }
        let hosting = NSHostingView(rootView: ContainersView(store: store))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 420),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        for size in [
            NSSize(width: 660, height: 420), NSSize(width: 820, height: 620),
            NSSize(width: 1200, height: 780), NSSize(width: 660, height: 420),
        ] {
            window.setContentSize(size)
            hosting.frame = NSRect(origin: .zero, size: size)
            for _ in 0..<3 {
                hosting.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            let descendants = allSubviews(of: hosting)
            let searchFields = descendants.compactMap { $0 as? NSTextField }.filter {
                $0.placeholderString == "Search"
            }
            XCTAssertFalse(searchFields.isEmpty, "Container search must stay available at \(size)")
            for field in searchFields {
                let rect = hosting.convert(field.bounds, from: field)
                XCTAssertGreaterThanOrEqual(rect.minX, -0.5, "Search left edge at \(size)")
                XCTAssertLessThanOrEqual(rect.maxX, size.width + 0.5, "Search right edge at \(size)")
            }
            let filters = descendants.compactMap { $0 as? NSSegmentedControl }
            XCTAssertFalse(filters.isEmpty, "Container filters must stay available at \(size)")
            for filter in filters {
                let rect = hosting.convert(filter.bounds, from: filter)
                XCTAssertGreaterThanOrEqual(rect.minX, -0.5, "Filter left edge at \(size)")
                XCTAssertLessThanOrEqual(rect.maxX, size.width + 0.5, "Filter right edge at \(size)")
                XCTAssertEqual(
                    filter.bounds.intersection(filter.visibleRect).width, filter.bounds.width, accuracy: 0.5,
                    "Every filter segment must remain visible at \(size)")
            }
            for scroll in descendants.compactMap({ $0 as? NSScrollView }).filter({ !$0.isHidden }) {
                // Sidebar Lists extend AppKit scroll chrome outside their
                // SwiftUI frame. visibleRect incorporates ancestor clipping.
                let rect = hosting.convert(scroll.contentView.visibleRect, from: scroll.contentView)
                XCTAssertGreaterThanOrEqual(rect.minX, -0.5, "List viewport left edge at \(size)")
                XCTAssertLessThanOrEqual(rect.maxX, size.width + 0.5, "List viewport right edge at \(size)")
                XCTAssertGreaterThanOrEqual(
                    rect.width, min(320, size.width / 2),
                    "The inventory must retain a usable visible pane at \(size)")
            }
        }
    }

    @MainActor
    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allSubviews(of: $0) }
    }

    @MainActor
    private func assertFits<Content: View>(
        _ content: Content, in proposal: CGSize, file: StaticString = #filePath, line: UInt = #line
    ) {
        let controller = NSHostingController(rootView: content.environment(\.locale, Locale(identifier: "en")))
        let fitted = controller.sizeThatFits(in: proposal)
        XCTAssertTrue(fitted.width.isFinite && fitted.height.isFinite, file: file, line: line)
        XCTAssertGreaterThan(fitted.width, 0, file: file, line: line)
        XCTAssertGreaterThan(fitted.height, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(fitted.width, proposal.width + 0.5, file: file, line: line)
        XCTAssertLessThanOrEqual(fitted.height, proposal.height + 0.5, file: file, line: line)
    }

    private func makeImage() -> Micropod_V1_Image {
        var image = Micropod_V1_Image()
        image.id = String(repeating: "a", count: 64)
        image.names = [String(repeating: "registry.example.com/nested-organization/", count: 8) + "image:latest"]
        image.digest = "sha256:" + String(repeating: "a", count: 64)
        image.createdAt = "2026-10-01T01:23:45.000000Z"
        image.sizeBytes = 268_435_456
        return image
    }

    private func makeNetwork() -> Micropod_V1_Network {
        var network = Micropod_V1_Network()
        network.id = String(repeating: "long-network-name-", count: 15)
        network.plugin = String(repeating: "network-plugin-", count: 15)
        network.mode = "internal"
        network.ipv4Subnet = "192.168.100.0/24"
        network.ipv4Gateway = "192.168.100.1"
        network.labels = [String(repeating: "label-key-", count: 15): String(repeating: "label-value-", count: 30)]
        return network
    }

    private func makeVolume() -> Micropod_V1_Volume {
        var volume = Micropod_V1_Volume()
        volume.id = String(repeating: "long-volume-name-", count: 15)
        volume.driver = String(repeating: "volume-driver-", count: 15)
        volume.format = "ext4"
        volume.source = "/" + String(repeating: "very-long-directory-name/", count: 30)
        volume.createdAt = "2026-10-01T01:23:45.000000Z"
        volume.sizeBytes = 268_435_456
        volume.labels = [String(repeating: "label-key-", count: 15): String(repeating: "label-value-", count: 30)]
        return volume
    }
}
