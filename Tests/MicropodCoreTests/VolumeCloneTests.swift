import XCTest

@testable import MicropodCore

/// `VolumeClone` is the file-level half of clone-backed volumes: an APFS
/// clonefile of a golden image, and the fsync + atomic-rename promotion of
/// a container's clone back over the golden. `VolumeLocks` serialises the
/// promotion against the container delete that removes clone images.
final class VolumeCloneTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("volume-clone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A pseudo-random, incompressible payload so identical bytes prove a
    /// real copy (or CoW clone), not a coincidence of zero-filled images.
    private func payload(seed: UInt8, count: Int = 1 << 20) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var state = UInt32(seed) &+ 1
        for index in bytes.indices {
            state = state &* 1_664_525 &+ 1_013_904_223
            bytes[index] = UInt8(truncatingIfNeeded: state >> 24)
        }
        return Data(bytes)
    }

    private func path(_ name: String) -> String {
        dir.appendingPathComponent(name).path
    }

    // MARK: - cloneImage

    func testCloneImageProducesIdenticalBytesAndAllocatedBlocks() throws {
        let golden = payload(seed: 1)
        try golden.write(to: URL(fileURLWithPath: path("golden.img")))

        try VolumeClone.cloneImage(from: path("golden.img"), to: path("clones/c1/golden.img"))

        let cloned = try Data(contentsOf: URL(fileURLWithPath: path("clones/c1/golden.img")))
        XCTAssertEqual(cloned.count, golden.count)
        XCTAssertEqual(cloned, golden)
        XCTAssertGreaterThan(VolumeClone.allocatedBytes(atPath: path("clones/c1/golden.img")), 0)
        XCTAssertGreaterThanOrEqual(
            VolumeClone.allocatedBytes(atPath: path("golden.img")), UInt64(golden.count),
            "st_blocks × 512 covers the written bytes")
    }

    func testCloneImageReplacesAnExistingTargetAndLeavesNoTempFile() throws {
        try payload(seed: 2).write(to: URL(fileURLWithPath: path("golden.img")))
        try Data("stale".utf8).write(to: URL(fileURLWithPath: path("clone.img")))

        try VolumeClone.cloneImage(from: path("golden.img"), to: path("clone.img"))

        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: path("clone.img"))), payload(seed: 2))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["clone.img", "golden.img"])
    }

    func testCloneImageMissingSourceThrowsAndCreatesNothing() {
        XCTAssertThrowsError(try VolumeClone.cloneImage(from: path("absent.img"), to: path("out/clone.img")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("out/clone.img")))
    }

    // MARK: - commit

    func testCommitReplacesGoldenAtomicallyAndReportsAllocatedBytes() throws {
        let before = payload(seed: 3)
        let after = payload(seed: 4)
        try before.write(to: URL(fileURLWithPath: path("golden.img")))
        try FileManager.default.createDirectory(atPath: path("clones/job-1"), withIntermediateDirectories: true)
        try after.write(to: URL(fileURLWithPath: path("clones/job-1/golden.img")))

        let allocated = try VolumeClone.commit(
            clonePath: path("clones/job-1/golden.img"), goldenPath: path("golden.img"))

        XCTAssertGreaterThan(allocated, 0)
        XCTAssertGreaterThanOrEqual(allocated, UInt64(after.count))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path("golden.img"))), after)
        // The container's clone stays where its configuration points (it is
        // removed with the container); the golden is a CoW twin of it.
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path("clones/job-1/golden.img"))), after)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["clones", "golden.img"],
            "no temp file may survive a commit")
    }

    func testCommitMissingCloneThrowsAndLeavesGoldenUntouched() throws {
        let before = payload(seed: 5)
        try before.write(to: URL(fileURLWithPath: path("golden.img")))

        XCTAssertThrowsError(
            try VolumeClone.commit(clonePath: path("clones/ghost/golden.img"), goldenPath: path("golden.img")))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path("golden.img"))), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["golden.img"])
    }

    func testCommitMissingGoldenDirectoryThrows() throws {
        try payload(seed: 6).write(to: URL(fileURLWithPath: path("clone.img")))
        XCTAssertThrowsError(
            try VolumeClone.commit(clonePath: path("clone.img"), goldenPath: path("no-such-dir/golden.img")))
    }

    /// A crash between staging and rename leaves `.golden.img.tmp-*` next to
    /// the golden; the next commit sweeps such leftovers — and only those,
    /// the sweep is keyed to this golden's staging prefix.
    func testCommitSweepsStagingLeftByACrashedCommit() throws {
        try payload(seed: 7).write(to: URL(fileURLWithPath: path("golden.img")))
        try FileManager.default.createDirectory(atPath: path("clones/job-2"), withIntermediateDirectories: true)
        let after = payload(seed: 8)
        try after.write(to: URL(fileURLWithPath: path("clones/job-2/golden.img")))
        try Data("stale".utf8).write(to: URL(fileURLWithPath: path(".golden.img.tmp-dead0000")))
        try Data("stale".utf8).write(to: URL(fileURLWithPath: path(".golden.img.tmp-cafe1111")))
        try Data("keep".utf8).write(to: URL(fileURLWithPath: path(".other.img.tmp-00000000")))

        _ = try VolumeClone.commit(clonePath: path("clones/job-2/golden.img"), goldenPath: path("golden.img"))

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path("golden.img"))), after)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
            [".other.img.tmp-00000000", "clones", "golden.img"],
            "stale staging files for this golden are swept; other names are untouched")
    }

    // MARK: - allocatedBytes / clone paths

    func testAllocatedBytesOfMissingFileIsZero() {
        XCTAssertEqual(VolumeClone.allocatedBytes(atPath: path("nope.img")), 0)
    }

    func testClonePathIsUnderTheOverriddenRoot() throws {
        setenv("MICROPOD_VOLUME_CLONE_ROOT", dir.path, 1)
        defer { unsetenv("MICROPOD_VOLUME_CLONE_ROOT") }
        XCTAssertEqual(VolumeClone.cloneRoot.path, dir.path)
        XCTAssertEqual(
            VolumeClone.clonePath(containerID: "job-7", volume: "npm").path,
            dir.appendingPathComponent("job-7/npm.img").path)

        XCTAssertEqual(VolumeClone.clonedVolumes(containerID: "job-7"), [])
        try FileManager.default.createDirectory(atPath: path("job-7"), withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: path("job-7/npm.img")))
        try Data().write(to: URL(fileURLWithPath: path("job-7/go-mod.img")))
        try Data().write(to: URL(fileURLWithPath: path("job-7/notes.txt")))
        XCTAssertEqual(VolumeClone.clonedVolumes(containerID: "job-7"), ["go-mod", "npm"])
    }

    // MARK: - VolumeLocks

    func testVolumeLocksSerialisePerNameAndRunOtherNamesConcurrently() async throws {
        let locks = VolumeLocks()
        let log = EventLog()

        // Hold "a" until released.
        let release = AsyncGate()
        let holder = Task {
            await locks.withLock("a") {
                await log.record("a-held")
                await release.wait()
                await log.record("a-released")
            }
        }
        await log.waitFor("a-held")

        // A second "a" must queue behind the holder …
        let contender = Task {
            await locks.withLock("a") { await log.record("a-second") }
        }
        // … while "b" proceeds immediately.
        await locks.withLock("b") { await log.record("b-ran") }
        await log.waitFor("b-ran")
        try await Task.sleep(for: .milliseconds(100))
        var events = await log.events
        XCTAssertFalse(events.contains("a-second"), "second holder ran while the lock was held: \(events)")

        await release.open()
        await holder.value
        await contender.value
        events = await log.events
        XCTAssertEqual(events.firstIndex(of: "a-released")! < events.firstIndex(of: "a-second")!, true, "\(events)")
    }

    func testVolumeLocksReleaseWhenTheBodyThrows() async throws {
        struct Boom: Error {}
        let locks = VolumeLocks()
        do {
            try await locks.withLock("x") { throw Boom() }
            XCTFail("expected Boom")
        } catch is Boom {}
        // Still acquirable — the failed body released it.
        let ran = await locks.withLock("x") { true }
        XCTAssertTrue(ran)
    }
}

private actor EventLog {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
    func waitFor(_ event: String) async {
        while !events.contains(event) {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
