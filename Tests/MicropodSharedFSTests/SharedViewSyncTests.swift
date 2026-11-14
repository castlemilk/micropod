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
}
