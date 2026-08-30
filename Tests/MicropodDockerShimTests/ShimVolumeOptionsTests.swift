import XCTest

@testable import MicropodDockerShim

/// `docker volume create` carries size and labels that the Apple runtime can
/// only receive as `-s` / `--label` / `--opt` argv. These pin the mapping —
/// dropping any of it silently produces an unlabelled, default-sized volume,
/// which is how a CI cache ends up unfilterable and out of space mid-build.
final class ShimVolumeOptionsTests: XCTestCase {
    private let fallback = "64g"

    func testNoDriverOptsUsesConfiguredDefaultSize() {
        let (size, options) = Router.volumeCreateOptions(nil, defaultSize: fallback)
        XCTAssertEqual(size, fallback)
        XCTAssertTrue(options.isEmpty)
    }

    func testEmptyDriverOptsUsesConfiguredDefaultSize() {
        let (size, options) = Router.volumeCreateOptions([:], defaultSize: fallback)
        XCTAssertEqual(size, fallback)
        XCTAssertTrue(options.isEmpty)
    }

    func testBareSizeKeyOverridesDefault() {
        let (size, options) = Router.volumeCreateOptions(["size": "10g"], defaultSize: fallback)
        XCTAssertEqual(size, "10g")
        XCTAssertTrue(options.isEmpty)
    }

    /// `--opt o=size=10g` is the mount-option spelling compose files use.
    func testMountStyleSizeIsExtractedFromO() {
        let (size, options) = Router.volumeCreateOptions(["o": "size=10g"], defaultSize: fallback)
        XCTAssertEqual(size, "10g")
        XCTAssertTrue(options.isEmpty, "size= must not be forwarded as an --opt")
    }

    /// Everything in `o` that is not `size=` still has to reach the runtime.
    func testMountStyleSizeKeepsSiblingOptions() {
        let (size, options) = Router.volumeCreateOptions(
            ["o": "noatime,size=10g,nodev"], defaultSize: fallback)
        XCTAssertEqual(size, "10g")
        XCTAssertEqual(options, ["o=noatime,nodev"])
    }

    func testUnknownDriverOptsAreForwardedVerbatim() {
        let (size, options) = Router.volumeCreateOptions(
            ["type": "ext4", "device": "/dev/disk1"], defaultSize: fallback)
        XCTAssertEqual(size, fallback, "an unrelated opt must not drop the default size")
        XCTAssertEqual(options, ["device=/dev/disk1", "type=ext4"])
    }

    func testOptionsAreDeterministicallyOrdered() {
        // Dictionary iteration order is unstable; argv must not be.
        let opts = ["zeta": "1", "alpha": "2", "mid": "3"]
        let first = Router.volumeCreateOptions(opts, defaultSize: fallback).options
        for _ in 0..<25 {
            XCTAssertEqual(Router.volumeCreateOptions(opts, defaultSize: fallback).options, first)
        }
        XCTAssertEqual(first, ["alpha=2", "mid=3", "zeta=1"])
    }
}
