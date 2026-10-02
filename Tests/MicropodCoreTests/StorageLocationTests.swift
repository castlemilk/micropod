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

    // MARK: - Drive discovery

    private func vol(
        _ name: String, at mount: String, format: String = "apfs", uuid: String? = nil,
        internal isInternalDisk: Bool = false, removable: Bool = false, free: Int64 = 100 << 30,
        total: Int64 = 500 << 30
    ) -> StorageLocation.Volume {
        StorageLocation.Volume(
            mountPoint: URL(fileURLWithPath: mount), name: name, format: format, availableBytes: free,
            totalBytes: total, isInternal: isInternalDisk, isRemovable: removable, uuid: uuid)
    }

    private func desc(
        _ v: StorageLocation.Volume, local: Bool = true, readOnly: Bool = false, root: Bool = false,
        image: Bool = false
    ) -> StorageLocation.VolumeDescriptor {
        StorageLocation.VolumeDescriptor(
            volume: v, isLocal: local, isReadOnly: readOnly, isRootFileSystem: root, isDiskImage: image)
    }

    func testClassificationKeepsDrivesAndHidesSystemBackupImageAndNetworkVolumes() {
        let home = vol("Macintosh HD - Data", at: "/System/Volumes/Data", uuid: "HOME", internal: true)
        let descriptors = [
            desc(vol("Macintosh HD", at: "/", internal: true), readOnly: true, root: true),
            desc(home),
            desc(vol("Preboot", at: "/System/Volumes/Preboot", internal: true)),
            desc(vol("Recovery", at: "/Volumes/Recovery", internal: true)),
            desc(vol("Backups of Ben's Mac", at: "/Volumes/Backups of Ben's Mac", uuid: "TM")),
            desc(vol("Installer", at: "/Volumes/Installer", uuid: "DMG"), image: true),
            desc(vol("share", at: "/Volumes/share", format: "smbfs", uuid: "NET"), local: false),
            desc(vol("Archive", at: "/Volumes/Archive", format: "exfat", uuid: "EXF")),
            desc(vol("Rig SSD", at: "/Volumes/Rig SSD", uuid: "SSD")),
            desc(vol("SD", at: "/Volumes/SD", uuid: "SDC", removable: true)),
            desc(vol("Rig SSD", at: "/Volumes/Rig SSD", uuid: "SSD")),  // reported twice
        ]
        let picked = StorageLocation.classify(descriptors, homeVolume: home.mountPoint)
        XCTAssertEqual(picked.map(\.name), ["Macintosh HD - Data", "Archive", "Rig SSD", "SD"])
        XCTAssertEqual(picked.map(\.kind), [.internal, .external, .external, .removable])
        XCTAssertNotNil(picked[1].unusableReason, "exFAT is listed but cannot hold the data")
        XCTAssertNil(picked[2].unusableReason)
        XCTAssertEqual(picked[2].defaultFolder.path, "/Volumes/Rig SSD/Micropod")
    }

    func testDiskImageMountPointsComeFromHdiutil() throws {
        let plist: [String: Any] = [
            "images": [
                ["system-entities": [["dev-entry": "/dev/disk9"], ["mount-point": "/Volumes/Installer/"]]],
                ["system-entities": [["mount-point": "/Volumes/Other"]]],
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        XCTAssertEqual(StorageLocation.parseDiskImageMountPoints(data), ["/Volumes/Installer", "/Volumes/Other"])
        XCTAssertEqual(StorageLocation.parseDiskImageMountPoints(Data("junk".utf8)), [])
    }

    func testSetTargetResolvesPathNameOrUUID() {
        let drives = [vol("Rig SSD", at: "/Volumes/Rig SSD", uuid: "ABCD-1234")]
        XCTAssertEqual(StorageLocation.resolveTarget("/Volumes/X/data", volumes: drives), "/Volumes/X/data")
        XCTAssertEqual(StorageLocation.resolveTarget("Rig SSD", volumes: drives), "/Volumes/Rig SSD/Micropod")
        XCTAssertEqual(StorageLocation.resolveTarget("rig ssd", volumes: drives), "/Volumes/Rig SSD/Micropod")
        XCTAssertEqual(StorageLocation.resolveTarget("abcd-1234", volumes: drives), "/Volumes/Rig SSD/Micropod")
        XCTAssertNil(StorageLocation.resolveTarget("Nope", volumes: drives))
    }

    func testConfigRemembersTheDriveByUUIDAndFollowsItsMountPoint() {
        let drive = vol("Rig SSD", at: "/Volumes/Rig SSD", uuid: "ABCD")
        let config = StorageLocation.Config.at(URL(fileURLWithPath: "/Volumes/Rig SSD/Micropod"), on: drive)
        XCTAssertEqual(config.volumeUUID, "ABCD")
        XCTAssertEqual(config.relativePath, "Micropod")
        // Remounted as "Rig SSD 1" (another volume took the name), then renamed.
        let moved = vol("Rig SSD", at: "/Volumes/Rig SSD 1", uuid: "abcd")
        XCTAssertEqual(config.resolvedRoot(mounted: [moved]), "/Volumes/Rig SSD 1/Micropod")
        XCTAssertEqual(config.resolvedRoot(mounted: []), "/Volumes/Rig SSD/Micropod", "unmounted: as recorded")
        // The internal disk keeps no volume identity.
        let internalDisk = vol("Data", at: "/System/Volumes/Data", uuid: "HOME", internal: true)
        XCTAssertNil(StorageLocation.Config.at(URL(fileURLWithPath: "/Users/me/x"), on: internalDisk).volumeUUID)
    }

    func testDisconnectedDriveAndRemountAreReportedAndRelinked() throws {
        // Data "moved" to a drive that was mounted at <root>/old-mount.
        let oldMount = root.appendingPathComponent("old-mount")
        let newMount = root.appendingPathComponent("new-mount")
        let target = oldMount.appendingPathComponent("Micropod")
        for (_, source, dest) in paths.trees(under: target) {
            try seed(dest)
            try FileManager.default.createDirectory(
                at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: dest)
        }
        try StorageLocation.saveConfig(
            .init(root: target.path, volumeUUID: "U1", volumeName: "Rig SSD", relativePath: "Micropod"), paths)

        let disconnected = StorageLocation.status(paths: paths, mounted: [])
        XCTAssertTrue(disconnected.driveDisconnected)
        XCTAssertTrue(disconnected.problems.first?.contains("Rig SSD is not connected") ?? false)

        // The drive comes back at another mount point.
        try FileManager.default.moveItem(at: oldMount, to: newMount)
        let drive = vol("Rig SSD", at: newMount.path, uuid: "U1")
        let remounted = StorageLocation.status(paths: paths, mounted: [drive])
        XCTAssertFalse(remounted.driveDisconnected)
        XCTAssertEqual(remounted.relinkTo, newMount.appendingPathComponent("Micropod").path)

        let relinked = try StorageLocation.relink(paths: paths, mounted: [drive])
        XCTAssertEqual(relinked.count, paths.trees(under: target).count)
        let after = StorageLocation.status(paths: paths, mounted: [drive])
        XCTAssertTrue(after.healthy, "\(after.problems)")
        XCTAssertNil(after.relinkTo)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: paths.containerAppRoot.appendingPathComponent("data").path))
    }

    func testMoveRefusesBeforeStoppingWhenTheDataDoesNotFit() async throws {
        try seed(paths.containerAppRoot)
        let control = Control()
        let target = root.appendingPathComponent("ext/micropod")
        do {
            try await StorageLocation.apply(
                root: target.path, migrate: true, paths: paths, control: { try await control($0) },
                estimate: { _ in Int64.max / 4 })
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("free"), "\(error)")
        }
        XCTAssertEqual(control.calls, [], "the runtime was never stopped")
        XCTAssertEqual(StorageLocation.requiredBytes(forData: 100 << 30), (100 << 30) + (10 << 30))
        XCTAssertEqual(StorageLocation.requiredBytes(forData: 1 << 30), (1 << 30) + (5 << 30))
    }
}
