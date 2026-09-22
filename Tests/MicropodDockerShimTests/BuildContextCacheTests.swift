import Foundation
import MicropodCore
import MicropodSharedFS
import XCTest

@testable import MicropodDockerShim

/// Minimal ustar builder: stock metadata, caller-controlled names, mtimes
/// and order so tree-hash determinism is testable.
enum TarBuilder {
    static func file(name: String, content: Data, mtime: UInt32 = 1_700_000_000) -> Data {
        header(name: name, size: content.count, mtime: mtime, typeflag: 0x30, linkname: "")
            + padded(content)
    }

    static func dir(name: String, mtime: UInt32 = 1_700_000_000) -> Data {
        header(name: name, size: 0, mtime: mtime, typeflag: 0x35, linkname: "")
    }

    static func symlink(name: String, target: String) -> Data {
        header(name: name, size: 0, mtime: 1_700_000_000, typeflag: 0x32, linkname: target)
    }

    static func gnuLongFile(longName: String, shortName: String, content: Data) -> Data {
        let nameData = Data((longName + "\0").utf8)
        return header(name: "././@LongLink", size: nameData.count, mtime: 0, typeflag: 0x4C, linkname: "")
            + padded(nameData)
            + file(name: shortName, content: content)
    }

    static func paxHeader(entries: String) -> Data {
        let content = Data(entries.utf8)
        return header(name: "pax-header", size: content.count, mtime: 0, typeflag: 0x78, linkname: "")
            + padded(content)
    }

    static func archive(_ parts: Data...) -> Data {
        archive(parts)
    }

    static func archive(_ parts: [Data]) -> Data {
        var out = Data()
        for part in parts { out.append(part) }
        out.append(Data(repeating: 0, count: 1024))
        return out
    }

    private static func header(
        name: String, size: Int, mtime: UInt32, typeflag: UInt8, linkname: String
    ) -> Data {
        var h = Data(repeating: 0, count: 512)
        func put(_ string: String, at offset: Int, length: Int) {
            let bytes = Array(string.utf8.prefix(length))
            h.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
        put(name, at: 0, length: 100)
        put("0000644", at: 100, length: 8)
        put("0000000", at: 108, length: 8)
        put("0000000", at: 116, length: 8)
        put(String(format: "%011o", size), at: 124, length: 12)
        put(String(format: "%011o", mtime), at: 136, length: 12)
        h[156] = typeflag
        put(linkname, at: 157, length: 100)
        put("ustar", at: 257, length: 6)
        put("00", at: 263, length: 2)
        // Checksum over the header with the chksum field blanked.
        var sum = 0
        for i in 0..<512 { sum += (i >= 148 && i < 156) ? 32 : Int(h[i]) }
        put(String(format: "%06o", sum), at: 148, length: 8)
        return h
    }

    private static func padded(_ data: Data) -> Data {
        var out = data
        let remainder = data.count % 512
        if remainder != 0 { out.append(Data(repeating: 0, count: 512 - remainder)) }
        return out
    }
}

final class BuildContextCacheTests: XCTestCase {
    // MARK: - Tree-hash determinism

    func testTreeHashDeterministic() throws {
        let tar = TarBuilder.archive(
            TarBuilder.file(name: "a.txt", content: Data("hello".utf8)),
            TarBuilder.dir(name: "sub"),
            TarBuilder.file(name: "sub/b.txt", content: Data("world".utf8)))
        XCTAssertEqual(
            try BuildContextHasher.treeHash(tarData: tar),
            try BuildContextHasher.treeHash(tarData: tar))
    }

    func testTreeHashIgnoresOrderAndMtime() throws {
        let a = TarBuilder.archive(
            TarBuilder.file(name: "a.txt", content: Data("hello".utf8), mtime: 100),
            TarBuilder.file(name: "b.txt", content: Data("world".utf8), mtime: 100))
        let b = TarBuilder.archive(
            TarBuilder.file(name: "b.txt", content: Data("world".utf8), mtime: 999_999),
            TarBuilder.file(name: "a.txt", content: Data("hello".utf8), mtime: 999_999))
        XCTAssertEqual(
            try BuildContextHasher.treeHash(tarData: a),
            try BuildContextHasher.treeHash(tarData: b))
    }

    func testTreeHashChangesOnAnyByte() throws {
        let a = TarBuilder.archive(TarBuilder.file(name: "a.txt", content: Data("hello".utf8)))
        let b = TarBuilder.archive(TarBuilder.file(name: "a.txt", content: Data("hallo".utf8)))
        let c = TarBuilder.archive(TarBuilder.file(name: "b.txt", content: Data("hello".utf8)))
        let ha = try BuildContextHasher.treeHash(tarData: a)
        XCTAssertNotEqual(ha, try BuildContextHasher.treeHash(tarData: b))
        XCTAssertNotEqual(ha, try BuildContextHasher.treeHash(tarData: c))
        XCTAssertEqual(ha.count, 64, "sha256 hex digest")
    }

    func testTreeHashSymlinkAndDir() throws {
        let a = TarBuilder.archive(TarBuilder.symlink(name: "link", target: "a.txt"))
        let b = TarBuilder.archive(TarBuilder.symlink(name: "link", target: "b.txt"))
        XCTAssertNotEqual(
            try BuildContextHasher.treeHash(tarData: a),
            try BuildContextHasher.treeHash(tarData: b))
    }

    func testTreeHashSkipsPaxHeaders() throws {
        let file = TarBuilder.file(name: "a.txt", content: Data("hello".utf8))
        let plain = TarBuilder.archive(file)
        let withPax = TarBuilder.archive(
            TarBuilder.paxHeader(entries: "11 mtime=123\n"), file)
        XCTAssertEqual(
            try BuildContextHasher.treeHash(tarData: plain),
            try BuildContextHasher.treeHash(tarData: withPax))
    }

    func testTreeHashGnuLongName() throws {
        let long = String(repeating: "d/", count: 30) + "file.txt"
        let a = TarBuilder.archive(
            TarBuilder.gnuLongFile(longName: long, shortName: "truncated", content: Data("x".utf8)))
        let b = TarBuilder.archive(
            TarBuilder.gnuLongFile(
                longName: long + ".other", shortName: "truncated", content: Data("x".utf8)))
        // Parses (no throw) and keys on the long name, not the truncated one.
        XCTAssertNotEqual(
            try BuildContextHasher.treeHash(tarData: a),
            try BuildContextHasher.treeHash(tarData: b))
    }

    func testTreeHashRejectsGarbage() {
        XCTAssertThrowsError(try BuildContextHasher.treeHash(tarData: Data()))
        XCTAssertThrowsError(
            try BuildContextHasher.treeHash(tarData: Data(repeating: 0xFF, count: 512)))
        // Truncated: header claims 100 content bytes but the padded block
        // is cut short (file() has no end marker; drop into the content).
        var truncated = TarBuilder.file(name: "a.txt", content: Data(repeating: 1, count: 100))
        truncated.removeLast(400)
        XCTAssertThrowsError(try BuildContextHasher.treeHash(tarData: truncated))
    }

    // MARK: - Cache semantics

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bctx-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func contextFixture(_ dir: URL, files: [String: String]) throws -> URL {
        let context = dir.appendingPathComponent("context", isDirectory: true)
        try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
        for (name, content) in files {
            try Data(content.utf8).write(to: context.appendingPathComponent(name))
        }
        return context
    }

    private func tarOf(files: [String: String]) -> Data {
        var parts: [Data] = []
        for name in files.keys.sorted() {
            parts.append(TarBuilder.file(name: name, content: Data(files[name]!.utf8)))
        }
        return TarBuilder.archive(parts)
    }

    func testStoreCheckoutRoundtrip() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = BuildContextCache(root: dir.appendingPathComponent("cache"))
        let context = try contextFixture(dir, files: ["a.txt": "hello", "b.txt": "world"])
        let tar = tarOf(files: ["a.txt": "hello", "b.txt": "world"])
        let hashed = try BuildContextHasher.treeManifest(tarData: tar)
        let hash = hashed.treeHash
        XCTAssertEqual(
            hashed.files.map(\.path).sorted(), ["a.txt", "b.txt"],
            "manifest vends the file list the store persists")

        let miss = await cache.checkout(treeHash: hash, dest: dir.appendingPathComponent("miss"))
        XCTAssertFalse(miss)
        await cache.store(treeHash: hash, contextDir: context, tarBytes: 100, files: hashed.files)
        let stats = await cache.stats()
        XCTAssertEqual(stats.entries, 1)

        // The retained entry carries a chunk-addressed manifest.
        let manifestData = try Data(
            contentsOf: dir.appendingPathComponent("cache/\(hash)/manifest.json"))
        let manifest = try JSONDecoder().decode(BuildManifest.self, from: manifestData)
        XCTAssertEqual(manifest.treeHash, hash)
        XCTAssertEqual(Set(manifest.files.map(\.path)), ["a.txt", "b.txt"])
        XCTAssertTrue(manifest.files.allSatisfy { $0.sha256.count == 64 })

        let dest = dir.appendingPathComponent("hit")
        let __hit2 = await cache.checkout(treeHash: hash, dest: dest)
        XCTAssertTrue(__hit2)
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("a.txt")), Data("hello".utf8))
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("b.txt")), Data("world".utf8))
        await cache.release(hash)
    }

    func testLRUEvictsOldestFirst() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 100-byte files under a 150-byte cap: two entries never coexist.
        let big = String(repeating: "x", count: 100)
        let cache = BuildContextCache(
            root: dir.appendingPathComponent("cache"), maxBytes: 150)
        let ctxA = try contextFixture(dir.appendingPathComponent("a"), files: ["f": big])
        let hashA = try BuildContextHasher.treeHash(tarData: tarOf(files: ["f": big]))
        await cache.store(treeHash: hashA, contextDir: ctxA, tarBytes: 100)
        let __hit3 = await cache.checkout(treeHash: hashA, dest: dir.appendingPathComponent("hit-a"))
        XCTAssertTrue(__hit3)
        await cache.release(hashA)

        let other = String(repeating: "y", count: 100)
        let ctxB = try contextFixture(dir.appendingPathComponent("b"), files: ["f": other])
        let hashB = try BuildContextHasher.treeHash(tarData: tarOf(files: ["f": other]))
        await cache.store(treeHash: hashB, contextDir: ctxB, tarBytes: 100)

        let evicted = await cache.checkout(treeHash: hashA, dest: dir.appendingPathComponent("hit-a2"))
        XCTAssertFalse(evicted, "oldest entry must be evicted")
        let __hit4 = await cache.checkout(treeHash: hashB, dest: dir.appendingPathComponent("hit-b"))
        XCTAssertTrue(__hit4)
        await cache.release(hashB)
    }

    func testInUseEntriesSurviveEviction() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = String(repeating: "x", count: 100)
        let cache = BuildContextCache(
            root: dir.appendingPathComponent("cache"), maxBytes: 150)
        let ctxA = try contextFixture(dir.appendingPathComponent("a"), files: ["f": big])
        let hashA = try BuildContextHasher.treeHash(tarData: tarOf(files: ["f": big]))
        await cache.store(treeHash: hashA, contextDir: ctxA, tarBytes: 100)
        let __hit5 = await cache.checkout(treeHash: hashA, dest: dir.appendingPathComponent("use-a"))
        XCTAssertTrue(__hit5)

        // Over cap, but A is pinned: the *new* unpinned entry pays instead.
        let other = String(repeating: "y", count: 100)
        let ctxB = try contextFixture(dir.appendingPathComponent("b"), files: ["f": other])
        let hashB = try BuildContextHasher.treeHash(tarData: tarOf(files: ["f": other]))
        await cache.store(treeHash: hashB, contextDir: ctxB, tarBytes: 100)
        let pinned = await cache.checkout(treeHash: hashA, dest: dir.appendingPathComponent("use-a2"))
        XCTAssertTrue(pinned, "pinned entry must survive")
        await cache.release(hashA)
        await cache.release(hashA)

        // Unpinned now: the next store evicts it.
        let third = String(repeating: "z", count: 100)
        let ctxC = try contextFixture(dir.appendingPathComponent("c"), files: ["f": third])
        let hashC = try BuildContextHasher.treeHash(tarData: tarOf(files: ["f": third]))
        await cache.store(treeHash: hashC, contextDir: ctxC, tarBytes: 100)
        let gone = await cache.checkout(treeHash: hashA, dest: dir.appendingPathComponent("use-a3"))
        XCTAssertFalse(gone)
    }

    func testEnsureManifestBackfillsOnce() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = BuildContextCache(root: dir.appendingPathComponent("cache"))
        let context = try contextFixture(dir, files: ["a.txt": "hello"])
        let tar = tarOf(files: ["a.txt": "hello"])
        let hashed = try BuildContextHasher.treeManifest(tarData: tar)
        // Simulate a legacy-shaped entry (retained before manifests
        // existed) by removing the sidecar, then backfill on HIT.
        await cache.store(treeHash: hashed.treeHash, contextDir: context, tarBytes: 100)
        let manifestURL = dir.appendingPathComponent("cache/\(hashed.treeHash)/manifest.json")
        try FileManager.default.removeItem(at: manifestURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path))
        await cache.ensureManifest(treeHash: hashed.treeHash, files: hashed.files, tarBytes: 100)
        let manifest = try JSONDecoder().decode(
            BuildManifest.self, from: Data(contentsOf: manifestURL))
        XCTAssertEqual(manifest.files.map(\.path), ["a.txt"])
        // Second call never overwrites (first writer wins).
        await cache.ensureManifest(treeHash: hashed.treeHash, files: [], tarBytes: 0)
        let again = try JSONDecoder().decode(
            BuildManifest.self, from: Data(contentsOf: manifestURL))
        XCTAssertEqual(again.files.map(\.path), ["a.txt"])
    }

    func testDisabledCacheIsNoOp() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = BuildContextCache(
            root: dir.appendingPathComponent("cache"), disabled: true)
        let context = try contextFixture(dir, files: ["a.txt": "hello"])
        await cache.store(treeHash: String(repeating: "a", count: 64), contextDir: context, tarBytes: 10)
        let stats = await cache.stats()
        XCTAssertEqual(stats.entries, 0)
        let disabledHit = await cache.checkout(
            treeHash: String(repeating: "a", count: 64), dest: dir.appendingPathComponent("x"))
        XCTAssertFalse(disabledHit)
    }

    // MARK: - Build request flags

    func testBuildFactoryPullFlag() {
        let without = ContainerBuildRequest(contextDirectory: "/tmp/ctx")
        XCTAssertFalse(ContainerCommandFactory.build(without).arguments.contains("--pull"))
        var with = ContainerBuildRequest(contextDirectory: "/tmp/ctx")
        with.pull = true
        let args = ContainerCommandFactory.build(with).arguments
        XCTAssertTrue(args.contains("--pull"), "args were \(args)")
        XCTAssertEqual(args.last, "/tmp/ctx", "context stays the final argv")
    }
}
