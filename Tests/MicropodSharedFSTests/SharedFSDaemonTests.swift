import XCTest

@testable import MicropodSharedFS

final class SharedFSDaemonTests: XCTestCase {
    func testMountBuildsAndExposesView() async throws {
        let src = try writeSourceTree()
        let daemon = try SharedFSDaemon(cacheRoot: cacheRoot("mount"))
        let info = try await daemon.mount(src: src, readonly: false)
        XCTAssertEqual(info.src, src.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(info.viewPath)/a.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(info.viewPath)/sub/b.txt"))
    }

    func testMountIsolatesPerContainerWrites() async throws {
        let src = try writeSourceTree()
        let daemon = try SharedFSDaemon(cacheRoot: cacheRoot("iso"))
        let a = try await daemon.mount(src: src, readonly: false)
        let b = try await daemon.mount(src: src, readonly: false)

        try "from-a".write(toFile: "\(a.viewPath)/marker.txt", atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(a.viewPath)/marker.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(b.viewPath)/marker.txt"))
    }

    func testRefreshRebuildsFromSource() async throws {
        let src = try writeSourceTree()
        let daemon = try SharedFSDaemon(cacheRoot: cacheRoot("refresh"))
        let info = try await daemon.mount(src: src, readonly: false)
        try "old".write(toFile: "\(info.viewPath)/a.txt", atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(info.viewPath)/a.txt"))

        // Modify the source AND change the file size so clonefile dedup
        // would otherwise hide the change.
        try "refreshed-payload".write(
            toFile: src.appendingPathComponent("a.txt").path, atomically: true, encoding: .utf8)
        // Wait for FSEvents to fire.
        try await Task.sleep(nanoseconds: 500_000_000)

        let refreshed = try await daemon.refresh(id: info.id)
        let data = try String(contentsOfFile: "\(refreshed.viewPath)/a.txt", encoding: .utf8)
        XCTAssertEqual(data, "refreshed-payload")
    }

    func testSyncCopiesWritesBackToSource() async throws {
        let src = try writeSourceTree()
        let daemon = try SharedFSDaemon(cacheRoot: cacheRoot("sync"))
        let info = try await daemon.mount(src: src, readonly: false)
        let newFile = "\(info.viewPath)/from-container.txt"
        try "hello-from-container".write(toFile: newFile, atomically: true, encoding: .utf8)

        let result = try await daemon.sync(id: info.id)
        XCTAssertTrue(result.synced.contains(src.appendingPathComponent("from-container.txt").path))
        let onDisk = try String(
            contentsOfFile: src.appendingPathComponent("from-container.txt").path,
            encoding: .utf8)
        XCTAssertEqual(onDisk, "hello-from-container")
    }

    func testListReturnsAllMounts() async throws {
        let src = try writeSourceTree()
        let daemon = try SharedFSDaemon(cacheRoot: cacheRoot("list"))
        let a = try await daemon.mount(src: src, readonly: false)
        let b = try await daemon.mount(src: src, readonly: false)
        let infos = try await daemon.list()
        XCTAssertEqual(infos.count, 2)
        XCTAssertTrue(infos.contains { $0.id == a.id })
        XCTAssertTrue(infos.contains { $0.id == b.id })
    }

    func testUnmountRemovesView() async throws {
        let src = try writeSourceTree()
        let daemon = try SharedFSDaemon(cacheRoot: cacheRoot("unmount"))
        let info = try await daemon.mount(src: src, readonly: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: info.viewPath))
        try await daemon.unmount(id: info.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: info.viewPath))
        let infos = try await daemon.list()
        XCTAssertTrue(infos.isEmpty)
    }

    // MARK: - helpers

    private func writeSourceTree() throws -> URL {
        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharedfs-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "alpha".write(
            toFile: src.appendingPathComponent("a.txt").path,
            atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: src.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "beta\n".write(
            toFile: src.appendingPathComponent("sub/b.txt").path,
            atomically: true, encoding: .utf8)
        return src
    }

    private func cacheRoot(_ tag: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharedfs-cache-\(tag)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
