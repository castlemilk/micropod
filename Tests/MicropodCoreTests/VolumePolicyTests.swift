import XCTest

@testable import MicropodCore

final class VolumePolicyTests: XCTestCase {

    private var policyPath: String!

    override func setUp() {
        super.setUp()
        policyPath = NSTemporaryDirectory() + "vp-\(UUID().uuidString).json"
        setenv("MICROPOD_VOLUME_POLICY", policyPath, 1)
    }

    override func tearDown() {
        unsetenv("MICROPOD_VOLUME_POLICY")
        try? FileManager.default.removeItem(atPath: policyPath)
        super.tearDown()
    }

    // MARK: - Defaults / decode

    func testStandardDefaults() {
        let p = VolumePolicy.standard
        XCTAssertEqual(p.cloneMode, .labels)
        XCTAssertEqual(p.goldenVolumes, [])
        XCTAssertFalse(p.jobsOnly)
        XCTAssertNil(p.sync)
        XCTAssertEqual(p.cache, .on)
    }

    func testPartialDecodeFallsBackToDefaults() throws {
        let p = try JSONDecoder().decode(VolumePolicy.self, from: Data(#"{"cloneMode":"all"}"#.utf8))
        XCTAssertEqual(p.cloneMode, .all)
        XCTAssertEqual(p.cache, .on)
        XCTAssertNil(p.sync)
    }

    func testInvalidEnumFailsDecode() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(VolumePolicy.self, from: Data(#"{"cloneMode":"bogus"}"#.utf8)))
        XCTAssertThrowsError(
            try JSONDecoder().decode(VolumePolicy.self, from: Data(#"{"sync":"bogus"}"#.utf8)))
        XCTAssertThrowsError(
            try JSONDecoder().decode(VolumePolicy.self, from: Data(#"{"cache":"bogus"}"#.utf8)))
    }

    func testRoundTrip() throws {
        let p = VolumePolicy(
            cloneMode: .goldens, goldenVolumes: ["a", "b"], jobsOnly: true, sync: .nosync, cache: .auto)
        let decoded = try JSONDecoder().decode(VolumePolicy.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(decoded, p)
    }

    // MARK: - cloneSet

    func testCloneLabelAlwaysWins() {
        let p = VolumePolicy(cloneMode: .labels)
        XCTAssertEqual(p.cloneSet(labels: ["com.micropod.cache.clone": "x, y"]), ["x", "y"])
    }

    func testLabelModeWithoutLabelClonesNothing() {
        XCTAssertTrue(VolumePolicy.standard.cloneSet(labels: [:]).isEmpty)
    }

    func testGoldensMode() {
        let p = VolumePolicy(cloneMode: .goldens, goldenVolumes: ["ci-golden"])
        XCTAssertEqual(p.cloneSet(labels: [:]), ["ci-golden"])
    }

    func testAllModeWildcard() {
        let p = VolumePolicy(cloneMode: .all)
        XCTAssertEqual(p.cloneSet(labels: [:]), ["*"])
    }

    func testJobsOnlyGatesPolicyButNotLabels() {
        let p = VolumePolicy(cloneMode: .all, jobsOnly: true)
        XCTAssertTrue(p.cloneSet(labels: [:]).isEmpty)
        XCTAssertEqual(p.cloneSet(labels: ["com.cuttlefish.job": "42"]), ["*"])
        XCTAssertEqual(p.cloneSet(labels: ["com.micropod.job": "1"]), ["*"])
        // Explicit clone label still applies to a non-job container.
        XCTAssertEqual(p.cloneSet(labels: ["com.micropod.cache.clone": "g"]), ["g"])
    }

    // MARK: - sync / cache precedence

    func testSyncLabelBeatsPolicyBeatsFallback() {
        let p = VolumePolicy(sync: .nosync)
        XCTAssertEqual(p.syncCase(labels: ["com.micropod.volume.sync": "full"], fallback: "fsync"), "full")
        XCTAssertEqual(p.syncCase(labels: [:], fallback: "fsync"), "nosync")
        XCTAssertEqual(VolumePolicy.standard.syncCase(labels: [:], fallback: "fsync"), "fsync")
    }

    func testSyncLabelAliases() {
        let p = VolumePolicy.standard
        XCTAssertEqual(p.syncCase(labels: ["com.micropod.volume.sync": "none"], fallback: "fsync"), "nosync")
        XCTAssertEqual(p.syncCase(labels: ["com.micropod.volume.sync": "bogus"], fallback: "fsync"), "fsync")
    }

    func testCacheLabelBeatsPolicy() {
        let p = VolumePolicy(cache: .off)
        XCTAssertEqual(p.cacheCase(labels: ["com.micropod.volume.cache": "auto"]), "auto")
        XCTAssertEqual(p.cacheCase(labels: [:]), "off")
        XCTAssertEqual(VolumePolicy(cache: .on).cacheCase(labels: ["com.micropod.volume.cache": "uncached"]), "off")
    }

    // MARK: - Store

    func testStoreLoadMissingFileIsStandard() {
        XCTAssertEqual(VolumePolicyStore.load(), .standard)
    }

    func testStoreLoadCorruptFileIsStandard() throws {
        try Data("not json".utf8).write(to: URL(fileURLWithPath: policyPath))
        XCTAssertEqual(VolumePolicyStore.load(), .standard)
    }

    func testStoreRoundTrip() throws {
        let p = VolumePolicy(cloneMode: .goldens, goldenVolumes: ["g1"], jobsOnly: true, sync: .full, cache: .auto)
        try VolumePolicyStore.save(p)
        XCTAssertEqual(VolumePolicyStore.load(), p)
    }
}
