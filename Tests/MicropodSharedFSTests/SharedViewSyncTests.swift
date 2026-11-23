import Darwin
import Foundation
import XCTest

@testable import MicropodSharedFS

final class SharedViewSyncTests: XCTestCase {
    private func fixture() throws -> (URL, URL, SharedViewSync) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let view = root.appendingPathComponent("view")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "alpha".write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try SharedView.build(source: source, root: view)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return (source, view, try SharedViewSync(source: source, view: view))
    }

    func testDelayedInitialSourceEventPreservesNewViewWrite() throws {
        let (source, view, initial) = try fixture()
        var sync = initial
        try "container-write".write(to: view.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try sync.synchronize(changedPath: source.path, fromView: false), [])
        XCTAssertEqual(try String(contentsOf: view.appendingPathComponent("a.txt"), encoding: .utf8), "container-write")
        XCTAssertEqual(try sync.synchronize(changedPath: view.path, fromView: true), ["a.txt"])
        XCTAssertEqual(
            try String(contentsOf: source.appendingPathComponent("a.txt"), encoding: .utf8), "container-write")
    }

    func testCopiedViewEchoCannotOverwriteNewerSourceWrite() throws {
        let (source, view, initial) = try fixture()
        var sync = initial
        try "host-first".write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try sync.synchronize(changedPath: source.path, fromView: false)
        try "host-second".write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try sync.synchronize(changedPath: view.path, fromView: true), [])
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("a.txt"), encoding: .utf8), "host-second")
        _ = try sync.synchronize(changedPath: source.path, fromView: false)
        XCTAssertEqual(try String(contentsOf: view.appendingPathComponent("a.txt"), encoding: .utf8), "host-second")
    }

    func testSourceWriteBetweenCloneAndWatcherRegistrationStillPropagates() throws {
        let (source, view, _) = try fixture()
        try "after-clone".write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        var sync = try SharedViewSync(source: source, view: view)
        XCTAssertEqual(try sync.synchronize(changedPath: source.path, fromView: false), ["a.txt"])
        XCTAssertEqual(try String(contentsOf: view.appendingPathComponent("a.txt"), encoding: .utf8), "after-clone")
    }

    func testStagingNotificationCannotPublishAnUncommittedSnapshot() throws {
        let (source, view, initial) = try fixture()
        var sync = initial
        let staging = view.appendingPathComponent(".sharedfs-uncommitted")
        try "partial snapshot".write(to: staging, atomically: true, encoding: .utf8)
        XCTAssertEqual(try sync.synchronize(changedPath: staging.path, fromView: true), [])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: source.appendingPathComponent(staging.lastPathComponent).path))
    }

    func testOldSourceDirectoryEventPreservesNewViewFileAndDeletionPropagates() throws {
        let (source, view, initial) = try fixture()
        var sync = initial
        try "new".write(to: view.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: view.appendingPathComponent("a.txt"))
        _ = try sync.synchronize(changedPath: source.path, fromView: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: view.appendingPathComponent("new.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: view.appendingPathComponent("a.txt").path))
        XCTAssertEqual(try sync.synchronize(changedPath: view.path, fromView: true), ["a.txt", "new.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("a.txt").path))
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("new.txt"), encoding: .utf8), "new")
    }

    func testNestedDirectoryEventIgnoresUnreadableSiblingAndPropagatesRenameInBothDirections() throws {
        try XCTSkipIf(geteuid() == 0, "Root can traverse mode-000 directories")
        let (source, view, initial) = try fixture()
        var sync = initial
        let fm = FileManager.default
        for (origin, destination, fromView) in [(source, view, false), (view, source, true)] {
            let folder = origin.appendingPathComponent("work")
            let peer = destination.appendingPathComponent("work")
            let sibling = fromView ? "work-view-only" : "work-source-only"
            let blocked = origin.appendingPathComponent(sibling)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.createDirectory(at: blocked, withIntermediateDirectories: true)
            try "outside this event".write(
                to: blocked.appendingPathComponent("external"), atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
            let first = fromView ? "two" : "one"
            let last = fromView ? "three" : "two"
            let old = folder.appendingPathComponent(first)
            let new = folder.appendingPathComponent(last)
            try "edited \(first)".write(to: old, atomically: true, encoding: .utf8)
            XCTAssertEqual(try sync.synchronize(changedPath: folder.path, fromView: fromView), ["work/" + first])
            try fm.moveItem(at: old, to: new)
            XCTAssertEqual(
                try sync.synchronize(changedPath: folder.path, fromView: fromView),
                ["work/" + first, "work/" + last].sorted())
            XCTAssertEqual(
                try String(contentsOf: peer.appendingPathComponent(last), encoding: .utf8), "edited \(first)")
            XCTAssertFalse(fm.fileExists(atPath: peer.appendingPathComponent(first).path))
            XCTAssertFalse(fm.fileExists(atPath: destination.appendingPathComponent(sibling + "/external").path))
        }
    }

    func testRemovedSubtreeDropsOnlyItsTrackedDescendantsAndCanBeRecreatedFromThePeer() throws {
        let (source, view, _) = try fixture()
        let fm = FileManager.default
        let nested = ["pkg/first", "pkg/deep/a", "pkg/deep/b"]
        let sibling = "pkg-old/first"
        for root in [source, view] {
            for name in nested + [sibling] {
                let file = root.appendingPathComponent(name)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try name.write(to: file, atomically: true, encoding: .utf8)
            }
        }
        var sync = try SharedViewSync(source: source, view: view)
        try fm.removeItem(at: source.appendingPathComponent("pkg"))
        XCTAssertEqual(
            try sync.synchronize(changedPath: source.appendingPathComponent("pkg").path, fromView: false),
            nested.sorted())
        for name in nested {
            XCTAssertFalse(fm.fileExists(atPath: view.appendingPathComponent(name).path))
        }
        XCTAssertEqual(try String(contentsOf: view.appendingPathComponent(sibling), encoding: .utf8), sibling)
        XCTAssertEqual(
            try sync.synchronize(changedPath: source.appendingPathComponent("pkg").path, fromView: false), [])

        let fresh = "pkg/deep/recreated"
        let input = view.appendingPathComponent(fresh)
        try "new content".write(to: input, atomically: true, encoding: .utf8)
        XCTAssertEqual(try sync.synchronize(changedPath: input.path, fromView: true), [fresh])
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent(fresh), encoding: .utf8), "new content")
        try fm.removeItem(at: view.appendingPathComponent("pkg"))
        XCTAssertEqual(
            try sync.synchronize(changedPath: view.appendingPathComponent("pkg").path, fromView: true), [fresh])
        XCTAssertFalse(fm.fileExists(atPath: source.appendingPathComponent(fresh).path))
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent(sibling), encoding: .utf8), sibling)
    }
}
