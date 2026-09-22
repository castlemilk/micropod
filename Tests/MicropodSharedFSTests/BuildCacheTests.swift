import XCTest

@testable import MicropodSharedFS

/// Build-context manifests: per-file chunk-store digests that make
/// cross-context sharing measurable without touching any content.
final class BuildCacheTests: XCTestCase {
    private func entry(_ root: URL, hash: String, files: [(String, String, UInt64)]) throws {
        let dir = root.appendingPathComponent(hash, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = BuildManifest(
            treeHash: hash,
            files: files.map { BuildFileEntry(path: $0.0, sha256: $0.1, size: $0.2) },
            tarBytes: 1000)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
    }

    func testSharedBytesCountsMultiEntryDigestsOnce() {
        let a = BuildManifest(
            treeHash: String(repeating: "a", count: 64),
            files: [
                BuildFileEntry(path: "Dockerfile", sha256: "d1", size: 100),
                BuildFileEntry(path: "app.go", sha256: "a1", size: 500),
            ], tarBytes: 1000)
        let b = BuildManifest(
            treeHash: String(repeating: "b", count: 64),
            files: [
                BuildFileEntry(path: "Dockerfile", sha256: "d1", size: 100),
                BuildFileEntry(path: "other.go", sha256: "b1", size: 700),
            ], tarBytes: 1200)
        // d1 shared (counted once at 100); a1/b1 unique.
        XCTAssertEqual(BuildCacheStore.sharedBytes(manifests: [a, b]), 100)
        XCTAssertEqual(BuildCacheStore.sharedBytes(manifests: [a]), 0)
        XCTAssertEqual(a.contentBytes, 600)
    }

    func testScanReadsManifestsAndSkipsGarbage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bcache-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try entry(root, hash: String(repeating: "a", count: 64), files: [("f.txt", "h1", 42)])
        // Non-digest directory + corrupt manifest must be skipped, not crash.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("notahash", isDirectory: true),
            withIntermediateDirectories: true)
        let bad = root.appendingPathComponent(String(repeating: "b", count: 64), isDirectory: true)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: bad.appendingPathComponent("manifest.json"))

        let (manifests, stats) = BuildCacheStore.scan(root: root)
        XCTAssertEqual(manifests.count, 1)
        XCTAssertEqual(manifests.first?.files.first?.path, "f.txt")
        XCTAssertEqual(stats.entries, 1)
        XCTAssertEqual(stats.contentBytes, 42)
        XCTAssertEqual(stats.sharedBytes, 0)
    }

    func testScanEmptyRootIsZero() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bcache-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, stats) = BuildCacheStore.scan(root: root)
        XCTAssertEqual(stats.entries, 0)
        XCTAssertEqual(stats.contentBytes, 0)
        XCTAssertEqual(stats.sharedBytes, 0)
    }
}
