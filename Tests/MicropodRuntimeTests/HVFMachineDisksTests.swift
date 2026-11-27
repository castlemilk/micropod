import Darwin
import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// `micropod machine disk grow` without a VM: sizes read from the image and
/// its ext4 superblock, and every refusal made before anything is cloned.
/// The grow itself (a maintenance boot, kills at each step) is exercised on a
/// throwaway machine.
final class HVFMachineDisksTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = URL(fileURLWithPath: "/tmp/mpdisk-t-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private var layout: HVFMachineLayout { HVFMachineLayout(root: root) }

    /// A sparse image of `bytes` whose superblock says `fsBytes` (4 KiB blocks).
    private func image(_ url: URL, bytes: UInt64, fsBytes: UInt64) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var sb = [UInt8](repeating: 0, count: 1024)
        func put32(_ value: UInt64, at offset: Int) {
            for i in 0..<4 { sb[offset + i] = UInt8((value >> (8 * UInt64(i))) & 0xff) }
        }
        sb[0x38] = 0x53
        sb[0x39] = 0xEF
        put32(fsBytes / 4096, at: 0x04)
        put32(2, at: 0x18)
        try handle.seek(toOffset: 1024)
        handle.write(Data(sb))
        try handle.truncate(atOffset: bytes)
    }

    func testSizesReadTheImageAndItsFilesystem() throws {
        try image(layout.disk, bytes: 64 << 30, fsBytes: 32 << 30)
        let sizes = try XCTUnwrap(HVFMachineDisks.sizes(.os, layout: layout))
        XCTAssertEqual(sizes.imageBytes, 64 << 30)
        XCTAssertEqual(sizes.filesystemBytes, 32 << 30)
        XCTAssertTrue(sizes.filesystemBehind, "an image larger than its filesystem is a grow that did not finish")
        XCTAssertLessThan(sizes.allocatedBytes ?? .max, 1 << 20, "the image is sparse")
        XCTAssertNil(HVFMachineDisks.sizes(.cache, layout: layout), "no cache disk")
        let notExt4 = root.appendingPathComponent("plain")
        FileManager.default.createFile(atPath: notExt4.path, contents: Data(count: 4096))
        XCTAssertNil(HVFMachineDisks.ext4Bytes(notExt4))
    }

    func testGrowRefusesBeforeAnythingIsCloned() async throws {
        try image(layout.disk, bytes: 32 << 30, fsBytes: 32 << 30)
        try FileManager.default.createDirectory(at: layout.tools, withIntermediateDirectories: true)
        let leftover = root.appendingPathComponent(".grow-0000-disk.ext4")
        FileManager.default.createFile(atPath: leftover.path, contents: nil)
        func refusal(_ targets: [HVFMachineDisks.Disk: UInt64]) async -> String {
            do {
                try await HVFMachineDisks.grow(targets, layout: layout) { _ in }
                return "grew"
            } catch {
                return String(describing: error)
            }
        }
        let shrink = await refusal([.os: 16 << 30])
        XCTAssertTrue(shrink.contains("never shrunk"), shrink)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path), "an interrupted grow's clone stays")
        let noCache = await refusal([.cache: 16 << 30])
        XCTAssertTrue(noCache.contains("no cache disk"), noCache)
        let noTools = await refusal([.os: 48 << 30])
        XCTAssertTrue(noTools.contains("no e2fsprogs"), noTools)
        XCTAssertEqual(HVFMachineDisks.sizes(.os, layout: layout)?.imageBytes, 32 << 30, "nothing was changed")
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(entries.contains { $0.hasPrefix(".grow-") }, "\(entries)")
        let same = await refusal([.os: 32 << 30])
        XCTAssertEqual(same, "grew", "a size equal to the disk's is nothing to do")
    }
}
