import Darwin
import Foundation
import Synchronization
import XCTest

@testable import MicropodSharedFS

final class SharedViewBuildTests: XCTestCase {
    private func fixture() throws -> (root: URL, source: URL, view: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return (root, source, root.appendingPathComponent("view", isDirectory: true))
    }

    func testFilteredCloneAndCopyPreserveMetadataAndUseOnePathPerFile() throws {
        for forceCopy in [false, true] {
            let (_, source, view) = try fixture()
            try Data("ignored\n".utf8).write(to: source.appendingPathComponent(".syncignore"))
            let ignored = source.appendingPathComponent("ignored")
            try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: false)
            try Data("excluded".utf8).write(to: ignored.appendingPathComponent("nested"))
            let command = source.appendingPathComponent("command")
            let bytes = Data("#!/bin/sh\nexit 0\n".utf8)
            try bytes.write(to: command)
            let attribute = "com.micropod.test"
            let mtime = Date(timeIntervalSince1970: 1_600_000_001)
            XCTAssertEqual(setxattr(command.path, attribute, "value", 5, 0, 0), 0)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o751, .modificationDate: mtime], ofItemAtPath: command.path)
            try FileManager.default.createSymbolicLink(
                atPath: source.appendingPathComponent("link").path, withDestinationPath: "command")
            let calls = Mutex((attempts: 0, copies: 0))
            let files = SharedFileOperations(
                clone: { src, dst in
                    calls.withLock { $0.attempts += 1 }
                    return !forceCopy && SharedFileOperations.native.clone(src, dst)
                },
                copy: { src, dst in
                    calls.withLock { $0.copies += 1 }
                    try SharedFileOperations.native.copy(src, dst)
                })
            try SharedView.build(source: source, root: view, files: files)
            let counts = calls.withLock { $0 }
            XCTAssertEqual(counts.attempts, 3)
            XCTAssertEqual(counts.copies, forceCopy ? 3 : 0)
            let output = view.appendingPathComponent("command")
            XCTAssertEqual(try Data(contentsOf: output), bytes)
            let attrs = try FileManager.default.attributesOfItem(atPath: output.path)
            XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o751)
            XCTAssertEqual(attrs[.modificationDate] as? Date, mtime)
            var xattr = [UInt8](repeating: 0, count: 5)
            XCTAssertEqual(getxattr(output.path, attribute, &xattr, xattr.count, 0, 0), 5)
            XCTAssertEqual(String(decoding: xattr, as: UTF8.self), "value")
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: view.appendingPathComponent("link").path),
                "command")
            XCTAssertFalse(FileManager.default.fileExists(atPath: view.appendingPathComponent("ignored").path))
            try Data("modified".utf8).write(to: output)
            XCTAssertEqual(try Data(contentsOf: command), bytes)
        }
    }

    func testFailedStagingAndDestinationCollisionPreserveBothTrees() throws {
        let (root, source, view) = try fixture()
        let input = source.appendingPathComponent("file")
        try Data("source".utf8).write(to: input)
        let fail = SharedFileOperations(
            clone: { _, _ in false },
            copy: { _, dst in
                try Data("partial".utf8).write(to: dst)
                throw POSIXError(.ENOSPC)
            })
        XCTAssertThrowsError(try SharedView.build(source: source, root: view, files: fail))
        XCTAssertFalse(FileManager.default.fileExists(atPath: view.path))
        try FileManager.default.createDirectory(at: view, withIntermediateDirectories: false)
        let other = view.appendingPathComponent("other")
        try Data("pre-existing".utf8).write(to: other)
        XCTAssertThrowsError(try SharedView.build(source: source, root: view))
        XCTAssertThrowsError(try SharedView.build(source: source, root: view, files: fail, replacing: true))
        XCTAssertEqual(try Data(contentsOf: other), Data("pre-existing".utf8))
        XCTAssertEqual(try Data(contentsOf: input), Data("source".utf8))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["source", "view"])
        XCTAssertThrowsError(try SharedView.build(source: source, root: source.appendingPathComponent("nested/view")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("nested").path))
    }

    func testConcurrentCreatorsPublishOneWholeView() async throws {
        let (root, source, view) = try fixture()
        let other = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        for src in [source, other] {
            for name in ["one", "two"] {
                try Data(src.lastPathComponent.utf8).write(to: src.appendingPathComponent(name))
            }
        }
        let winners = try await withThrowingTaskGroup(of: String?.self, returning: [String].self) { group in
            for src in [source, other] {
                group.addTask {
                    do {
                        try SharedView.build(source: src, root: view)
                        return src.lastPathComponent
                    } catch let error as POSIXError where error.code == .EEXIST { return nil }
                }
            }
            var winners: [String] = []
            for try await winner in group { if let winner { winners.append(winner) } }
            return winners
        }
        XCTAssertEqual(winners.count, 1)
        for name in ["one", "two"] {
            XCTAssertEqual(try String(contentsOf: view.appendingPathComponent(name), encoding: .utf8), winners.first)
        }
    }

    func testRefreshKeepsMountedRootAndRollsBackFailedPublication() throws {
        let (_, source, view) = try fixture()
        for name in ["a", "obsolete", "z"] { try Data("old".utf8).write(to: source.appendingPathComponent(name)) }
        try SharedView.build(source: source, root: view)
        let directory = open(view.path, O_DIRECTORY | O_RDONLY)
        XCTAssertGreaterThanOrEqual(directory, 0)
        defer { close(directory) }
        for name in ["a", "new", "z"] { try Data("changed".utf8).write(to: source.appendingPathComponent(name)) }
        try FileManager.default.removeItem(at: source.appendingPathComponent("obsolete"))
        let blocked = view.appendingPathComponent("z")
        XCTAssertEqual(chflags(blocked.path, UInt32(UF_IMMUTABLE)), 0)
        defer { _ = chflags(blocked.path, 0) }
        XCTAssertThrowsError(try SharedView.build(source: source, root: view, files: .native, replacing: true))
        XCTAssertEqual(try Data(contentsOf: view.appendingPathComponent("a")), Data("old".utf8))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: view.path)), ["a", "obsolete", "z"])
        XCTAssertEqual(chflags(blocked.path, 0), 0)
        try SharedView.build(source: source, root: view, files: .native, replacing: true)
        var before = stat()
        var after = stat()
        XCTAssertEqual(fstat(directory, &before), 0)
        XCTAssertEqual(lstat(view.path, &after), 0)
        XCTAssertEqual(before.st_ino, after.st_ino)
        let file = openat(directory, "new", O_RDONLY)
        XCTAssertGreaterThanOrEqual(file, 0)
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        XCTAssertEqual(try handle.readToEnd(), Data("changed".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: view.appendingPathComponent("obsolete").path))
    }

    func testIgnoredDescendantsStayExcludedAcrossCoalescedAndDirectNotifications() throws {
        let (_, source, view) = try fixture()
        try Data("ignored\n".utf8).write(to: source.appendingPathComponent(".dockerignore"))
        let excluded = source.appendingPathComponent("ignored/file")
        try FileManager.default.createDirectory(
            at: excluded.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("first".utf8).write(to: excluded)
        try SharedView.build(source: source, root: view)
        var sync = try SharedViewSync(source: source, view: view)
        try Data("second".utf8).write(to: excluded)
        XCTAssertEqual(try sync.synchronize(changedPath: source.path, fromView: false), [])
        XCTAssertEqual(try sync.synchronize(changedPath: excluded.path, fromView: false), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: view.appendingPathComponent("ignored").path))
    }

    func testCLISharedMountSyncAndUnmount() async throws {
        let (root, source, _) = try fixture()
        let socket = "/tmp/mp-share-" + UUID().uuidString
        let daemon = try SharedFSDaemon(cacheRoot: root.appendingPathComponent("cache"))
        let server = SharedFSServer(socketPath: socket, daemon: daemon)
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socket)
        }
        // NWListener.start is asynchronous. Fail promptly if the OS rejects
        // binding the socket, before spawning a client with its own timeout.
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: socket), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard FileManager.default.fileExists(atPath: socket) else {
            throw SharedFSError.invalidResponse("SharedFS failed to bind its private test socket.")
        }
        let cli = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("micropod")
        func share(_ args: [String]) throws -> String {
            let process = Process()
            process.executableURL = cli
            process.arguments = ["share"] + args
            var environment = ProcessInfo.processInfo.environment
            environment["MICROPOD_SHAREDFS_SOCKET"] = socket
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = try output.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            guard process.terminationStatus == 0 else { throw SharedFSError.invalidResponse(text) }
            return text
        }
        try Data("*.skip".utf8).write(to: source.appendingPathComponent(".syncignore"))
        try Data("ignored".utf8).write(to: source.appendingPathComponent("file.skip"))
        let mounted = try share(["mount", source.path, "--shared"])
        let mounts = try await daemon.list()
        let info = try XCTUnwrap(mounts.first)
        XCTAssertTrue(mounted.contains(info.id.value))
        XCTAssertTrue(try share(["inspect", info.id.value]).contains(info.viewPath))
        let view = URL(fileURLWithPath: info.viewPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: view.appendingPathComponent("file.skip").path))
        try Data("new".utf8).write(to: view.appendingPathComponent("new"))
        _ = try share(["sync", info.id.value])
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("new")), Data("new".utf8))
        _ = try share(["unmount", info.id.value])
        XCTAssertFalse(FileManager.default.fileExists(atPath: view.path))
    }

    func testRestartedDaemonCanMountWithoutDeletingAnEarlierView() async throws {
        let (root, source, _) = try fixture()
        let cache = root.appendingPathComponent("cache")
        var firstDaemon: SharedFSDaemon? = try SharedFSDaemon(cacheRoot: cache)
        let first = try await firstDaemon!.mountShared(src: source, readonly: false)
        firstDaemon = nil
        let retained = URL(fileURLWithPath: first.viewPath).appendingPathComponent("retained")
        try Data("old view".utf8).write(to: retained)
        let secondDaemon = try SharedFSDaemon(cacheRoot: cache)
        let second = try await secondDaemon.mountShared(src: source, readonly: false)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.viewPath + "/retained"))
        try await secondDaemon.unmount(id: second.id)
        XCTAssertEqual(try Data(contentsOf: retained), Data("old view".utf8))
    }
}
