import MicropodCore
import XCTest

/// Regression coverage for real `container list --all --format json` output
/// captured from a live macOS 26 runtime (2026-08-12).
final class RealCLIFixtureTests: XCTestCase {
    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/real-container-list.json")
    }

    private var imageFixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/real-image-list.json")
    }

    func testRealContainerListDecodesEndToEnd() throws {
        let data = try Data(contentsOf: fixtureURL)
        let containers = try MicropodJSON.decodeArray(
            ContainerListEntry.self, from: data, context: "real fixture")

        XCTAssertEqual(containers.count, 2)
        XCTAssertEqual(containers.map(\.id), ["buildkit", "greenveil-nutrients-31567931656-1"])

        // The second container carries an int-typed "mtu" network option,
        // which used to crash decoding (options was [String: String]).
        let live = containers[1]
        XCTAssertEqual(live.status.state, "running")
        XCTAssertEqual(live.configuration.networks?.first?.network, "default")
        if case .number(let mtu) = live.configuration.networks?.first?.options?["mtu"] {
            XCTAssertEqual(mtu, 1280)
        } else {
            XCTFail(
                "expected numeric mtu option, got \(String(describing: live.configuration.networks?.first?.options?["mtu"]))"
            )
        }
    }

    func testRealFixtureMapsThroughModelMapper() throws {
        let data = try Data(contentsOf: fixtureURL)
        let entries = try MicropodJSON.decodeArray(
            ContainerListEntry.self, from: data, context: "real fixture")
        let mapped = entries.map(ModelMapper.container(from:))

        XCTAssertEqual(mapped[0].state, "stopped")
        XCTAssertEqual(mapped[1].state, "running")
        XCTAssertEqual(mapped[1].networks, ["default"])
        XCTAssertFalse(mapped[1].ipv4Address.isEmpty, "running container should carry its IP")
        XCTAssertEqual(mapped[0].labels["com.apple.container.plugin"], "builder", "labels survive mapping")
    }

    func testRealImageListDecodesObjectPlatform() throws {
        // Real `container image list --verbose` emits variant.platform as an
        // object (older CLI builds emitted a "linux/amd64" string).
        let data = try Data(contentsOf: imageFixtureURL)
        let images = try MicropodJSON.decodeArray(
            ImageListEntry.self, from: data, context: "real image fixture")

        XCTAssertFalse(images.isEmpty)
        let alpine = images.first { $0.configuration.name?.contains("alpine") == true }
        XCTAssertNotNil(alpine)
        XCTAssertEqual(alpine?.variants.first?.platform?.architecture, "amd64")
        XCTAssertEqual(alpine?.variants.first?.platform?.os, "linux")

        let mapped = alpine.map(ModelMapper.image(from:))
        XCTAssertEqual(mapped?.variants.first?.architecture, "amd64")
        XCTAssertEqual(mapped?.variants.first?.os, "linux")
    }

    func testLegacyStringPlatformStillDecodes() throws {
        let json = """
            [{"configuration":{"creationDate":"2026-04-16T23:53:24Z","descriptor":{"digest":"sha256:abc","mediaType":"application/vnd.oci.image.index.v1+json","size":1},"name":"legacy:1"},"id":"legacy","variants":[{"config":{"architecture":"arm64","os":"linux"},"digest":"sha256:abc","platform":"linux/arm64","size":3454976}]}]
            """
        let images = try MicropodJSON.decodeArray(
            ImageListEntry.self, from: Data(json.utf8), context: "legacy fixture")
        let mapped = ModelMapper.image(from: images[0])
        XCTAssertEqual(mapped.variants[0].os, "linux")
        XCTAssertEqual(mapped.variants[0].architecture, "arm64")
    }
}
