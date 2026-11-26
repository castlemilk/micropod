import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// The cache policy's trust tier for containers that name none
/// (`defaultTrust`) and its rig auto-configuration.
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

    func testTheRigsStandardMachineBecomesUntrustedByDefaultOnce() throws {
        let layout = HVFMachineLayout(root: HVFMachineLayout.standardRoot(home: home))
        try install(layout)
        let note = try HVFMachineCachePolicy.applyRigDefaultTrust(layout: layout, home: home, isRig: { _ in true })
        XCTAssertEqual(note, HVFMachineCachePolicy.rigDefaultTrustNote)
        XCTAssertEqual(try trust(layout), .untrusted)
        XCTAssertNil(try HVFMachineCachePolicy.applyRigDefaultTrust(layout: layout, home: home, isRig: { _ in true }))
    }

    func testRigAutoConfigurationKeepsAnExplicitSettingAndOtherMachines() throws {
        let standard = HVFMachineLayout(root: HVFMachineLayout.standardRoot(home: home))
        var trusted = HVFMachineCachePolicy()
        trusted.defaultTrust = .trusted
        try install(standard, policy: trusted)
        XCTAssertNil(try HVFMachineCachePolicy.applyRigDefaultTrust(layout: standard, home: home, isRig: { _ in true }))
        XCTAssertEqual(try trust(standard), .trusted, "an explicit setting is the user's")

        let throwaway = HVFMachineLayout(root: home.appendingPathComponent("throwaway"))
        try install(throwaway)
        XCTAssertNil(
            try HVFMachineCachePolicy.applyRigDefaultTrust(layout: throwaway, home: home, isRig: { _ in true }))
        XCTAssertNil(try trust(throwaway), "a throwaway root is never changed")

        let developer = HVFMachineLayout(root: HVFMachineLayout.standardRoot(home: home))
        try install(developer)
        XCTAssertNil(
            try HVFMachineCachePolicy.applyRigDefaultTrust(layout: developer, home: home, isRig: { _ in false }))
        XCTAssertNil(try trust(developer), "a developer's machine keeps the shipped default")

        let absent = HVFMachineLayout(root: home.appendingPathComponent("never-installed"))
        XCTAssertNil(try HVFMachineCachePolicy.applyRigDefaultTrust(layout: absent, home: home, isRig: { _ in true }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.config.path))
    }
}
