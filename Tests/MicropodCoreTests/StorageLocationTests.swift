import Foundation
import XCTest

@testable import MicropodCore

final class StorageLocationTests: XCTestCase {
    private var root: URL!
    private var paths: StorageLocation.Paths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        paths = StorageLocation.Paths(home: home)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Records runtime stop/start calls in order.
    private final class Control: @unchecked Sendable {
        var calls: [Bool] = []
        func callAsFunction(_ start: Bool) async throws { calls.append(start) }
    }

    private final class StepRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [StorageLocation.Step] = []
        func add(_ step: StorageLocation.Step) { lock.withLock { recorded.append(step) } }
        var steps: [StorageLocation.Step] { lock.withLock { recorded } }
    }

    private func seed(_ url: URL, file: String = "data", contents: String = "x") throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url.appendingPathComponent(file))
    }

    func testConfigRoundTripsAndDefaultsToInternal() throws {
        XCTAssertNil(StorageLocation.loadConfig(paths).root)
        try StorageLocation.saveConfig(.init(root: "/Volumes/Ext/micropod"), paths)
        XCTAssertEqual(StorageLocation.loadConfig(paths).root, "/Volumes/Ext/micropod")
        try Data("not json".utf8).write(to: paths.configFile)
        XCTAssertNil(StorageLocation.loadConfig(paths).root, "an unreadable config reads as internal")
    }

    func testValidationRefusesRelativeUnmountedAndSelfNestedPaths() {
        XCTAssertEqual(StorageLocation.validate(root: "relative/dir", paths: paths), [.notAbsolute("relative/dir")])
        let unmounted = "/Volumes/NoSuchDrive-\(UUID().uuidString)/micropod"
        XCTAssertEqual(StorageLocation.validate(root: unmounted, paths: paths), [.volumeNotMounted(unmounted)])
        let nested = paths.micropodHome.appendingPathComponent("store").path
        XCTAssertEqual(StorageLocation.validate(root: nested, paths: paths), [.insideDefaultLocation(nested)])
        // A fresh directory on the (APFS) boot volume is fine.
        XCTAssertEqual(StorageLocation.validate(root: root.appendingPathComponent("ext").path, paths: paths), [])
    }

    func testApplyMigratesLinksKeepsOldDataAndRestartsRuntime() async throws {
        try seed(paths.containerAppRoot.appendingPathComponent("volumes"), contents: "golden")
        try seed(paths.micropodHome.appendingPathComponent("sandbox"), contents: "rootfs")
        let target = root.appendingPathComponent("ext/micropod")
        let control = Control()
        let recorder = StepRecorder()

        try await StorageLocation.apply(
            root: target.path, migrate: true, paths: paths, control: { try await control($0) },
            progress: { recorder.add($0) })

        XCTAssertEqual(control.calls, [false, true], "stop, then start")
        let fm = FileManager.default
        // The default paths are links into the new root, and the data came along.
        XCTAssertEqual(
            try fm.destinationOfSymbolicLink(atPath: paths.containerAppRoot.path),
            target.appendingPathComponent("container").path)
        XCTAssertEqual(
            try String(
                contentsOf: paths.containerAppRoot.appendingPathComponent("volumes/data"), encoding: .utf8), "golden")
        XCTAssertEqual(
            try String(
                contentsOf: target.appendingPathComponent("micropod/sandbox/data"), encoding: .utf8), "rootfs")
        // The originals are kept aside, not deleted.
        XCTAssertTrue(fm.fileExists(atPath: paths.containerAppRoot.path + StorageLocation.oldDataSuffix))
        XCTAssertEqual(StorageLocation.loadConfig(paths).root, target.standardizedFileURL.path)
        let steps = recorder.steps
        XCTAssertTrue(steps.contains(.stopRuntime) && steps.last == .startRuntime)

        let status = StorageLocation.status(paths: paths)
        XCTAssertTrue(status.healthy, "\(status.problems)")
        XCTAssertTrue(status.trees.first { $0.name == "container" }?.moved ?? false)

        // Applying again is a no-op that still bounces the runtime.
        try await StorageLocation.apply(
            root: target.path, migrate: true, paths: paths, control: { try await control($0) })
        XCTAssertEqual(control.calls, [false, true, false, true])

        XCTAssertEqual(try StorageLocation.removeOldData(paths: paths).count, 2)
        XCTAssertFalse(fm.fileExists(atPath: paths.containerAppRoot.path + StorageLocation.oldDataSuffix))
    }

    func testMissingVolumeIsReportedNotRecreated() async throws {
        try seed(paths.containerAppRoot, contents: "golden")
        let target = root.appendingPathComponent("ext/micropod")
        try await StorageLocation.apply(root: target.path, migrate: true, paths: paths, control: { _ in })
        // The drive goes away.
        try FileManager.default.removeItem(at: target)
        let status = StorageLocation.status(paths: paths)
        XCTAssertFalse(status.healthy)
        XCTAssertTrue(status.trees.first { $0.name == "container" }?.missing ?? false)
        XCTAssertTrue(status.problems.contains { $0.contains("not mounted") }, "\(status.problems)")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: target.path), "status never recreates the missing location")
    }

    func testFreshStartDoesNotCopyAndResetBringsDataBack() async throws {
        try seed(paths.containerAppRoot, contents: "golden")
        let target = root.appendingPathComponent("ext/micropod")
        try await StorageLocation.apply(root: target.path, migrate: false, paths: paths, control: { _ in })
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: target.appendingPathComponent("container/data").path),
            "a fresh start copies nothing")
        try seed(target.appendingPathComponent("container"), file: "new", contents: "made-on-ext")

        try await StorageLocation.reset(migrate: true, paths: paths, control: { _ in })
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: paths.containerAppRoot.path))
        XCTAssertEqual(
            try String(contentsOf: paths.containerAppRoot.appendingPathComponent("new"), encoding: .utf8),
            "made-on-ext")
        XCTAssertNil(StorageLocation.loadConfig(paths).root)
    }

    func testApplyRefusesAnInvalidRootBeforeStoppingAnything() async throws {
        let control = Control()
        do {
            try await StorageLocation.apply(
                root: "/Volumes/NoSuchDrive-\(UUID().uuidString)/x", migrate: true, paths: paths,
                control: { try await control($0) })
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue("\(error)".contains("not on a mounted volume"), "\(error)")
        }
        XCTAssertEqual(control.calls, [], "the runtime is never stopped for a bad path")
    }
}
