import Foundation
import XCTest

@testable import MicropodRuntime

final class SandboxDiskCacheTests: XCTestCase {
    func testConcurrentColdReadersGetOneCompleteDisk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SandboxDiskCache(root: root)
        let disk = root.appendingPathComponent("images/alpine.ext4")
        let complete = Data("complete disk".utf8)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    try await cache.materialize(at: disk) { tmp in
                        // A second producer makes this test fail even if it writes identical bytes.
                        try FileManager.default.createDirectory(
                            at: root.appendingPathComponent("producer"), withIntermediateDirectories: false)
                        try Data("partial".utf8).write(to: tmp)
                        await Task.yield()
                        try complete.write(to: tmp)
                    }
                    XCTAssertEqual(try Data(contentsOf: disk), complete)
                }
            }
            try await group.waitForAll()
        }
        try await cache.materialize(at: disk) { _ in XCTFail("warm hit unpacked again") }
    }

    func testFailedProducerLeavesDiskAvailableForRetry() async throws {
        struct UnpackFailed: Error {}
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let cache = SandboxDiskCache(root: root)
        let disk = root.appendingPathComponent("initfs-alpine.ext4")
        do {
            try await cache.materialize(at: disk) { tmp in
                try Data("partial".utf8).write(to: tmp)
                throw UnpackFailed()
            }
            XCTFail("expected an unpack error")
        } catch is UnpackFailed {}
        XCTAssertFalse(fm.fileExists(atPath: disk.path))
        try await cache.materialize(at: disk) { tmp in
            XCTAssertFalse(fm.fileExists(atPath: tmp.path))
            try Data("complete".utf8).write(to: tmp)
        }
        XCTAssertEqual(try Data(contentsOf: disk), Data("complete".utf8))
    }
}
