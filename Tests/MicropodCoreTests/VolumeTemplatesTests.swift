import Darwin
import XCTest

@testable import MicropodCore

/// `VolumeTemplates` keeps one pre-formatted image per (size, journal) and
/// hands out its path while it still matches its manifest; anything missing
/// or changed is rebuilt.
final class VolumeTemplatesTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("volume-templates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Stands in for the apiserver's format: a sparse image of `bytes` with
    /// an ext4 superblock magic, counting how often it was asked.
    private actor FakeFormatter {
        private(set) var calls = 0
        let bytes: Int64
        let magic: Bool
        init(bytes: Int64 = 64 << 20, magic: Bool = true) {
            self.bytes = bytes
            self.magic = magic
        }
        func format(_ path: String) throws {
            calls += 1
            let fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { close(fd) }
            guard ftruncate(fd, bytes) == 0 else { throw CocoaError(.fileWriteUnknown) }
            var block = [UInt8](repeating: 0x11, count: 4096)
            if magic {
                block[0x38] = 0x53
                block[0x39] = 0xEF
            }
            guard pwrite(fd, block, block.count, 1024) == block.count else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    private func key(_ size: String = "136g", journal: String? = nil) throws -> VolumeTemplates.Key {
        var opts = ["size": size]
        if let journal { opts["journal"] = journal }
        return try XCTUnwrap(VolumeTemplates.Key(driverOpts: opts))
    }

    func testKeysCoverSizeAndJournalOnly() throws {
        XCTAssertEqual(try key("136G").description, "ext4-136g")
        XCTAssertEqual(try key("64g", journal: "ordered").description, "ext4-64g-journal-ordered")
        XCTAssertEqual(VolumeTemplates.Key(driverOpts: [:])?.description, "ext4-default")
        XCTAssertNil(
            VolumeTemplates.Key(driverOpts: ["size": "64g", "inodes": "1000"]), "an option a template ignores")
        XCTAssertNil(VolumeTemplates.Key(driverOpts: ["size": "../64g"]), "nothing that could escape the root")
        XCTAssertEqual(try key("300G").driverOpts, ["size": "300g"])
        XCTAssertEqual(VolumeTemplates.Key(driverOpts: [:])?.driverOpts, [:])
    }

    /// Built once, then reused, by this process and by the next one.
    func testTemplateIsBuiltOnceAndReused() async throws {
        let formatter = FakeFormatter()
        let templates = VolumeTemplates(root: dir)
        let first = try await templates.template(for: key()) { try await formatter.format($0) }
        let again = try await templates.template(for: key()) { try await formatter.format($0) }
        XCTAssertEqual(first, again)
        let fresh = try await VolumeTemplates(root: dir).template(for: key()) { try await formatter.format($0) }
        XCTAssertEqual(fresh, first, "a new process verifies the manifest and digest instead of rebuilding")
        let calls = await formatter.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(VolumeClone.fileLength(atPath: first), 64 << 20)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first + ".json"))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".") }, [],
            "no build file left behind")
    }

    /// Concurrent creates of a new size share one format.
    func testConcurrentCallersShareOneBuild() async throws {
        let formatter = FakeFormatter()
        let templates = VolumeTemplates(root: dir)
        let key = try self.key()
        let paths = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask { try await templates.template(for: key) { try await formatter.format($0) } }
            }
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        XCTAssertEqual(paths.count, 1)
        let calls = await formatter.calls
        XCTAssertEqual(calls, 1)
    }

    /// A template written to after it was built (its head changed) is not
    /// handed out: it is rebuilt.
    func testCorruptTemplateIsRebuilt() async throws {
        let formatter = FakeFormatter()
        let templates = VolumeTemplates(root: dir)
        let path = try await templates.template(for: key()) { try await formatter.format($0) }
        let fd = open(path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var junk = [UInt8](repeating: 0xFF, count: 512)
        XCTAssertEqual(pwrite(fd, &junk, junk.count, 8192), 512)
        close(fd)

        _ = try await VolumeTemplates(root: dir).template(for: key()) { try await formatter.format($0) }
        _ = try await templates.template(for: key()) { try await formatter.format($0) }
        let calls = await formatter.calls
        XCTAssertEqual(calls, 2, "rebuilt once, by the first caller to notice")
        XCTAssertTrue(VolumeTemplates.matchesFully(path, try XCTUnwrap(VolumeTemplates.readManifest(path))))
    }

    func testMissingTemplateIsRebuilt() async throws {
        let formatter = FakeFormatter()
        let templates = VolumeTemplates(root: dir)
        let path = try await templates.template(for: key()) { try await formatter.format($0) }
        XCTAssertEqual(unlink(path), 0)
        _ = try await templates.template(for: key()) { try await formatter.format($0) }
        let calls = await formatter.calls
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    /// A format that does not produce an ext4 image is refused, and nothing
    /// is left under the template's name.
    func testNonExt4BuildIsRefused() async throws {
        let formatter = FakeFormatter(magic: false)
        do {
            _ = try await VolumeTemplates(root: dir).template(for: key()) { try await formatter.format($0) }
            XCTFail("an image without an ext4 superblock must not become a template")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not an ext4 image"), "\(error)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testEachSizeHasItsOwnTemplate() async throws {
        let formatter = FakeFormatter()
        let templates = VolumeTemplates(root: dir)
        let a = try await templates.template(for: key("64g")) { try await formatter.format($0) }
        let b = try await templates.template(for: key("136g")) { try await formatter.format($0) }
        let c = try await templates.template(for: key("136g", journal: "ordered")) { try await formatter.format($0) }
        XCTAssertEqual(Set([a, b, c]).count, 3)
        let calls = await formatter.calls
        XCTAssertEqual(calls, 3)
    }

    /// The provisioned size a templated volume reports is the one it was
    /// asked for, not its placeholder's.
    func testTemplatedVolumeReportsItsProvisionedSize() throws {
        let entry = try JSONDecoder().decode(
            VolumeListEntry.self,
            from: Data(
                #"{"id":"ws","configuration":{"name":"ws","driver":"local","format":"ext4","source":"/nope","#
                    .utf8)
                + Data(
                    #""sizeInBytes":1048576,"labels":{"com.micropod.volume.provisioned-bytes":"146028888064"}}}"#.utf8
                ))
        XCTAssertEqual(ModelMapper.volume(from: entry).sizeBytes, 146_028_888_064)
    }
}
