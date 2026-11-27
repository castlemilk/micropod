import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// The cache policy's trust tier for containers that name none
/// (`defaultTrust`), and what a rig gets told about it.
final class HVFCacheTrustTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("hvf-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func rendered(_ policy: HVFMachineCachePolicy) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: policy.render()) as? [String: Any])
    }

    func testDefaultTrustIsAbsentUntilSetAndRenderedForTheGuest() throws {
        let shipped = HVFMachineCachePolicy()
        XCTAssertNil(shipped.defaultTrust)
        XCTAssertEqual(shipped.effectiveDefaultTrust, .trusted)
        XCTAssertNil(try rendered(shipped)["defaultTrust"], "the shipped default leaves the guest's default")
        XCTAssertNil(try rendered(shipped)["proxyUntrusted"])

        var rig = shipped
        rig.defaultTrust = .untrusted
        rig.proxyUntrusted = true
        let json = try rendered(rig)
        XCTAssertEqual(json["defaultTrust"] as? String, "untrusted")
        XCTAssertEqual(json["proxyUntrusted"] as? Bool, true)
        XCTAssertTrue(rig.summary.contains("untrusted by default"), rig.summary)

        // An explicit trusted is kept (and rendered), so the rig default
        // never replaces it.
        var explicit = shipped
        explicit.defaultTrust = .trusted
        let data = try JSONEncoder().encode(explicit)
        let decoded = try JSONDecoder().decode(HVFMachineCachePolicy.self, from: data)
        XCTAssertEqual(decoded.defaultTrust, .trusted)
        XCTAssertEqual(try rendered(explicit)["defaultTrust"] as? String, "trusted")
    }

    func testDockerSocketIsAbsentUntilSetRenderedForTheGuestAndNamedInTheSummary() throws {
        let shipped = HVFMachineCachePolicy()
        XCTAssertNil(shipped.dockerSocket)
        XCTAssertEqual(shipped.effectiveDockerSocket, .trusted)
        XCTAssertNil(try rendered(shipped)["dockerSocket"], "the shipped default leaves the guest's default")
        XCTAssertFalse(shipped.summary.contains("docker socket"), shipped.summary)

        var rig = shipped
        rig.defaultTrust = .untrusted
        rig.dockerSocket = .any
        XCTAssertEqual(try rendered(rig)["dockerSocket"] as? String, "any")
        XCTAssertEqual(try rendered(rig)["defaultTrust"] as? String, "untrusted", "cache trust is its own setting")
        XCTAssertTrue(rig.summary.contains("untrusted by default"), rig.summary)
        XCTAssertTrue(rig.summary.contains("docker socket for any container"), rig.summary)
        XCTAssertTrue(rig.summary.contains("still only read the dependency caches"), rig.summary)
        // The socket policy applies whatever the cache mode: it is said then too.
        rig.mode = .off
        XCTAssertTrue(rig.summary.hasPrefix("off; docker socket for any container"), rig.summary)

        let decoded = try JSONDecoder().decode(HVFMachineCachePolicy.self, from: JSONEncoder().encode(rig))
        XCTAssertEqual(decoded, rig)
        XCTAssertTrue(decoded.extra.isEmpty, "dockerSocket is a known key, not passed through as an unknown one")

        var explicit = shipped
        explicit.dockerSocket = .trusted
        XCTAssertEqual(try rendered(explicit)["dockerSocket"] as? String, "trusted")
        XCTAssertFalse(explicit.summary.contains("docker socket"), explicit.summary)
    }

    func testDefaultLimitsAreAbsentUntilSetRenderedForTheGuestAndNamedInTheSummary() throws {
        let shipped = HVFMachineCachePolicy()
        XCTAssertNil(shipped.defaultLimits)
        XCTAssertEqual(shipped.effectiveDefaultLimits, .job)
        XCTAssertNil(try rendered(shipped)["defaultLimits"], "the shipped default leaves the guest's default")
        XCTAssertFalse(shipped.summary.contains("limits"), shipped.summary)

        var rig = shipped
        rig.defaultLimits = HVFMachineCachePolicy.DefaultLimits.none
        XCTAssertEqual(try rendered(rig)["defaultLimits"] as? String, "none")
        XCTAssertNil(try rendered(rig)["dockerSocket"], "the socket policy is its own setting")
        XCTAssertTrue(rig.summary.contains("no default container limits"), rig.summary)
        rig.dockerSocket = .any
        XCTAssertTrue(rig.summary.contains("docker socket for any container"), rig.summary)
        XCTAssertTrue(rig.summary.contains("no default container limits"), rig.summary)

        let decoded = try JSONDecoder().decode(HVFMachineCachePolicy.self, from: JSONEncoder().encode(rig))
        XCTAssertEqual(decoded, rig)
        XCTAssertTrue(decoded.extra.isEmpty, "defaultLimits is a known key, not passed through as an unknown one")

        for raw in ["unlimited", "NONE", "docker", ""] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    HVFMachineCachePolicy.self, from: Data(#"{"defaultLimits":"\#(raw)"}"#.utf8)), raw
            ) { error in
                XCTAssertTrue("\(error)".contains("job or none"), "\(error)")
            }
        }
    }

    func testAnUnknownDockerSocketIsRefused() {
        for raw in ["everyone", "ANY", "untrusted", ""] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    HVFMachineCachePolicy.self, from: Data(#"{"dockerSocket":"\#(raw)"}"#.utf8)), raw
            ) { error in
                XCTAssertTrue("\(error)".contains("trusted or any"), "\(error)")
            }
        }
    }

    func testAnUnknownDefaultTrustIsRefused() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(HVFMachineCachePolicy.self, from: Data(#"{"defaultTrust":"semi"}"#.utf8))
        ) { error in
            XCTAssertTrue("\(error)".contains("trusted or untrusted"), "\(error)")
        }
    }

    private func install(_ layout: HVFMachineLayout, policy: HVFMachineCachePolicy? = nil) throws {
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        var config = HVFMachineConfig()
        config.cache = policy
        try config.save(to: layout.config)
    }

    private func trust(_ layout: HVFMachineLayout) throws -> HVFMachineCachePolicy.Trust? {
        try HVFMachineConfig.load(from: layout.config).effectiveCachePolicy.defaultTrust
    }

    /// A rig is often its owner's development machine too, and Cuttlefish
    /// names the tier of every container it creates: nothing changes the
    /// standard machine's default by itself. `machine install` only hints.
    func testARigsStandardMachineKeepsTheShippedDefaultAndGetsAHint() throws {
        let layout = HVFMachineLayout(root: HVFMachineLayout.standardRoot(home: home))
        try install(layout)
        let before = try Data(contentsOf: layout.config)
        XCTAssertEqual(
            HVFMachineCachePolicy.rigDefaultTrustHint(layout: layout, home: home, isRig: { _ in true }),
            HVFMachineCachePolicy.rigDefaultTrustHint)
        XCTAssertNil(try trust(layout), "the hint never writes machine.json")
        XCTAssertEqual(try Data(contentsOf: layout.config), before)
        XCTAssertTrue(HVFMachineCachePolicy.rigDefaultTrustHint.contains("--default-trust untrusted"))
    }

    func testTheRigHintIsOnlyForAStandardRigMachineWithoutASetting() throws {
        let standard = HVFMachineLayout(root: HVFMachineLayout.standardRoot(home: home))
        var untrusted = HVFMachineCachePolicy()
        untrusted.defaultTrust = .untrusted
        try install(standard, policy: untrusted)
        XCTAssertNil(HVFMachineCachePolicy.rigDefaultTrustHint(layout: standard, home: home, isRig: { _ in true }))
        XCTAssertEqual(try trust(standard), .untrusted, "an explicit setting is the owner's")

        let throwaway = HVFMachineLayout(root: home.appendingPathComponent("throwaway"))
        try install(throwaway)
        XCTAssertNil(HVFMachineCachePolicy.rigDefaultTrustHint(layout: throwaway, home: home, isRig: { _ in true }))

        let devHome = home.appendingPathComponent("dev")
        let developer = HVFMachineLayout(root: HVFMachineLayout.standardRoot(home: devHome))
        try install(developer)
        XCTAssertNil(HVFMachineCachePolicy.rigDefaultTrustHint(layout: developer, home: devHome, isRig: { _ in false }))

        let absent = HVFMachineLayout(root: home.appendingPathComponent("never-installed"))
        XCTAssertNil(HVFMachineCachePolicy.rigDefaultTrustHint(layout: absent, home: home, isRig: { _ in true }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.config.path))
    }
}
