import Foundation
import XCTest

@testable import MicropodCore

/// D11: fresh vs existing, decided once and pinned in runtimes.json. Every
/// case passes its own home directory; none reads or writes the real one.
final class InstallOriginTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("origin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
    }

    private var micropod: URL { home.appendingPathComponent(".micropod") }
    private var config: URL { micropod.appendingPathComponent("runtimes.json") }

    private func pinned() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
    }

    func testAnEmptyHomePinsHvfAsAFreshInstall() throws {
        XCTAssertEqual(InstallOrigin.resolve(environment: [:], home: home), .pinned(.fresh))
        let object = try pinned()
        XCTAssertEqual(object["default"] as? String, "hvf")
        XCTAssertEqual(object["defaultOrigin"] as? String, "fresh-install")
        XCTAssertEqual(InstallOrigin.resolve(environment: [:], home: home), .kept(.fresh), "decided once")
    }

    func testAMicropodDirectoryWithOnlyFinderMetadataIsStillFresh() throws {
        try FileManager.default.createDirectory(at: micropod, withIntermediateDirectories: true)
        try Data().write(to: micropod.appendingPathComponent(".DS_Store"))
        XCTAssertEqual(InstallOrigin.resolve(environment: [:], home: home), .pinned(.fresh))
    }

    func testANonEmptyMicropodDirectoryPinsAnExistingInstallWithNoDefault() throws {
        try FileManager.default.createDirectory(
            at: micropod.appendingPathComponent("hvf"), withIntermediateDirectories: true)
        XCTAssertEqual(InstallOrigin.resolve(environment: [:], home: home), .pinned(.existing))
        let object = try pinned()
        XCTAssertNil(object["default"], "an existing install keeps the Apple default")
        XCTAssertEqual(object["defaultOrigin"] as? String, "existing-install")
    }

    func testAFileInPlaceOfTheMicropodDirectoryIsNotFresh() throws {
        try Data("x".utf8).write(to: micropod)
        let outcome = InstallOrigin.resolve(environment: [:], home: home)
        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(InstallOrigin.isEmptyOrMissing(micropod))
    }

    func testAnExistingRuntimesFileIsNeverRewritten() throws {
        try FileManager.default.createDirectory(at: micropod, withIntermediateDirectories: true)
        let before = Data(#"{"default": "sandbox", "engines": {}}"#.utf8)
        try before.write(to: config)
        XCTAssertEqual(InstallOrigin.resolve(environment: [:], home: home), .kept(nil))
        XCTAssertEqual(try Data(contentsOf: config), before)
        // Even an origin named in the environment does not rewrite it.
        XCTAssertEqual(
            InstallOrigin.resolve(environment: ["MICROPOD_INSTALL_ORIGIN": "fresh"], home: home), .kept(nil))
        XCTAssertEqual(try Data(contentsOf: config), before)
    }

    func testAnOverriddenConfigPathDecidesNothingUnlessAnOriginIsNamed() throws {
        let override = home.appendingPathComponent("elsewhere/runtimes.json")
        XCTAssertEqual(
            InstallOrigin.resolve(environment: ["MICROPOD_RUNTIMES_CONFIG": override.path], home: home), .skipped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: override.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: micropod.path), "nothing under the home either")

        // The home is not empty, but the named origin decides.
        try FileManager.default.createDirectory(
            at: micropod.appendingPathComponent("hvf"), withIntermediateDirectories: true)
        let environment = ["MICROPOD_RUNTIMES_CONFIG": override.path, "MICROPOD_INSTALL_ORIGIN": "fresh"]
        XCTAssertEqual(InstallOrigin.resolve(environment: environment, home: home), .pinned(.fresh))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: override)) as? [String: Any])
        XCTAssertEqual(object["default"] as? String, "hvf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path), "only the overridden path is written")

        let existing = home.appendingPathComponent("existing/runtimes.json")
        XCTAssertEqual(
            InstallOrigin.resolve(
                environment: ["MICROPOD_RUNTIMES_CONFIG": existing.path, "MICROPOD_INSTALL_ORIGIN": "existing"],
                home: home),
            .pinned(.existing))
    }

    func testAnUnknownOriginNameIsIgnored() {
        XCTAssertNil(InstallOrigin.named(in: ["MICROPOD_INSTALL_ORIGIN": "maybe"]))
        XCTAssertEqual(InstallOrigin.named(in: ["MICROPOD_INSTALL_ORIGIN": "fresh-install"]), .fresh)
        XCTAssertEqual(InstallOrigin.named(in: ["MICROPOD_INSTALL_ORIGIN": "Existing"]), .existing)
    }

    func testConcurrentResolversAgreeAndExactlyOnePins() throws {
        let lock = NSLock()
        nonisolated(unsafe) var all: [InstallOrigin.Outcome] = []
        let home = self.home!
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            let outcome = InstallOrigin.resolve(environment: [:], home: home)
            lock.withLock { all.append(outcome) }
        }
        XCTAssertEqual(all.filter { $0 == .pinned(.fresh) }.count, 1, "\(all)")
        XCTAssertEqual(all.filter { $0 == .kept(.fresh) }.count, 15, "\(all)")
        XCTAssertEqual(try pinned()["defaultOrigin"] as? String, "fresh-install")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: micropod.path).filter {
            $0 != "runtimes.json"
        }
        XCTAssertEqual(leftovers, [], "staged pins are removed")
    }
}
