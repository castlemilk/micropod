import Darwin
import XCTest

@testable import MicropodCore

/// `PayloadReclaimer` moves the free of a large image out of the call that
/// retires it: a second name before the runtime unlinks the original, or a
/// rename for files this process owns, and one background queue that
/// unlinks the last name.
final class PayloadReclaimerTests: XCTestCase {

    private var dir: URL!
    private var root: URL!
    private var reclaimer: PayloadReclaimer!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-\(UUID().uuidString)", isDirectory: true)
        root = dir.appendingPathComponent("reclaim", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        reclaimer = PayloadReclaimer(root: root, enabled: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func file(_ name: String, bytes: Int = 64 << 10) throws -> String {
        let path = dir.appendingPathComponent(name).path
        try Data(repeating: 0x5a, count: bytes).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func links(_ path: String) -> Int {
        var info = Darwin.stat()
        return stat(path, &info) == 0 ? Int(info.st_nlink) : 0
    }

    private func reclaimNames() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    }

    /// The runtime removed the original (a successful delete): the staged
    /// name is the file's last, and the background queue frees it.
    func testStagedFileIsFreedInTheBackgroundOnceTheOriginalIsGone() throws {
        let image = try file("rootfs.ext4")
        let stage = try XCTUnwrap(reclaimer.stage(image))
        XCTAssertEqual(links(image), 2, "the stage adds a name, not a copy")

        XCTAssertEqual(unlink(image), 0, "what the apiserver's bundle removal does")
        XCTAssertEqual(links(stage.link), 1, "the data survives under the staged name")

        reclaimer.settle(stage)
        reclaimer.drain()
        XCTAssertEqual(reclaimNames(), [])
        let s = reclaimer.snapshot()
        XCTAssertEqual(s.queued, 1)
        XCTAssertEqual(s.freed, 1)
        XCTAssertEqual(s.pending, 0)
        XCTAssertGreaterThan(s.bytes, 0)
    }

    /// The runtime refused (the volume is attached, the container still
    /// runs): the original keeps its name and its data, and the staged name
    /// goes at once without queueing anything.
    func testRefusedRemovalDropsTheStagedNameAndKeepsTheFile() throws {
        let image = try file("volume.img")
        let stage = try XCTUnwrap(reclaimer.stage(image))

        reclaimer.settle(stage)
        XCTAssertEqual(links(image), 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: image)).count, 64 << 10)
        XCTAssertEqual(reclaimNames(), [])
        XCTAssertEqual(reclaimer.snapshot().queued, 0)
        XCTAssertEqual(reclaimer.snapshot().released, 1)
    }

    /// A rename over the original (a cache commit replacing its golden)
    /// leaves the name in place but pointing at another file: the previous
    /// file's staged name is its last, so it is queued.
    func testReplacedOriginalIsFreedInTheBackground() throws {
        let golden = try file("golden.img")
        let next = try file("next.img", bytes: 1 << 10)
        let stage = try XCTUnwrap(reclaimer.stage(golden))

        XCTAssertEqual(rename(next, golden), 0)
        reclaimer.settle(stage)
        reclaimer.drain()

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: golden)).count, 1 << 10, "the new golden stays")
        XCTAssertEqual(reclaimNames(), [])
        XCTAssertEqual(reclaimer.snapshot().freed, 1)
    }

    /// Only a plain, singly-linked file is staged: a second name for a file
    /// that already has several could keep data alive past its owner's
    /// intent, and a directory or a missing path has nothing to stage.
    func testStageRefusesWhatItCannotSafelyName() throws {
        XCTAssertNil(reclaimer.stage(dir.appendingPathComponent("missing").path))
        XCTAssertNil(reclaimer.stage(dir.path))
        let image = try file("linked.img")
        XCTAssertEqual(link(image, dir.appendingPathComponent("other-name").path), 0)
        XCTAssertNil(reclaimer.stage(image))
        let symlink = dir.appendingPathComponent("symlink").path
        XCTAssertEqual(Darwin.symlink(image, symlink), 0)
        XCTAssertNil(reclaimer.stage(symlink))
    }

    /// `MICROPOD_RECLAIM=off` (or `enabled: false`): nothing is staged or
    /// retired, so every caller frees inline exactly as before.
    func testDisabledReclaimerLeavesEverythingToTheCaller() throws {
        let off = PayloadReclaimer(root: root, enabled: false)
        let image = try file("rootfs.ext4")
        XCTAssertNil(off.stage(image))
        XCTAssertFalse(off.retire(image))
        XCTAssertEqual(links(image), 1)
        XCTAssertEqual(off.sweep(), 0)
    }

    func testEnvironmentSwitch() {
        setenv("MICROPOD_RECLAIM", "off", 1)
        XCTAssertFalse(PayloadReclaimer.enabledByEnvironment)
        unsetenv("MICROPOD_RECLAIM")
        XCTAssertTrue(PayloadReclaimer.enabledByEnvironment)
    }

    /// A file this process owns (a deleted container's cache clone) is
    /// renamed out of its directory at once and freed later.
    func testRetireMovesTheFileOutAndFreesItLater() throws {
        let clone = try file("npm.img")
        XCTAssertTrue(reclaimer.retire(clone))
        XCTAssertFalse(FileManager.default.fileExists(atPath: clone), "gone from its directory immediately")
        reclaimer.drain()
        XCTAssertEqual(reclaimNames(), [])
        XCTAssertEqual(reclaimer.snapshot().freed, 1)
        XCTAssertFalse(reclaimer.retire(clone), "a missing file is the caller's to report")
    }

    /// Names a dead process left behind are freed by the next one's sweep.
    func testSweepFreesWhatAPreviousProcessLeft() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["a-rootfs.ext4", "b-volume.img"] {
            try Data(repeating: 1, count: 4096).write(to: root.appendingPathComponent(name))
        }
        XCTAssertEqual(reclaimer.sweep(), 2)
        reclaimer.drain()
        XCTAssertEqual(reclaimNames(), [])
    }

    /// A root on another volume cannot take a link or a rename: the stage is
    /// refused rather than turned into a copy.
    func testRootOnAnotherVolumeIsRefused() throws {
        let devfs = PayloadReclaimer(root: URL(fileURLWithPath: "/dev"), enabled: true)
        let image = try file("rootfs.ext4")
        XCTAssertNil(devfs.stage(image))
        XCTAssertFalse(devfs.retire(image))
        XCTAssertTrue(FileManager.default.fileExists(atPath: image))
    }

    /// `VolumeClone.removeClones` retires each clone image through the
    /// shared reclaimer: the clone dir is gone when the call returns.
    func testRemoveClonesRetiresCloneImages() async throws {
        let clones = dir.appendingPathComponent("clones", isDirectory: true)
        let sharedRoot = dir.appendingPathComponent("shared-reclaim", isDirectory: true)
        setenv("MICROPOD_VOLUME_CLONE_ROOT", clones.path, 1)
        setenv("MICROPOD_RECLAIM_ROOT", sharedRoot.path, 1)
        defer {
            unsetenv("MICROPOD_VOLUME_CLONE_ROOT")
            unsetenv("MICROPOD_RECLAIM_ROOT")
        }
        let jobDir = clones.appendingPathComponent("job-7", isDirectory: true)
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 1 << 20).write(to: jobDir.appendingPathComponent("npm.img"))
        try Data(repeating: 3, count: 1 << 20).write(to: jobDir.appendingPathComponent("go-mod.img"))

        await VolumeClone.removeClones(containerID: "job-7")

        XCTAssertFalse(FileManager.default.fileExists(atPath: jobDir.path))
        PayloadReclaimer.shared.drain()
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: sharedRoot.path)) ?? [], [])
    }
}
