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

    /// The create path places a container's clone exclusively: a clone that
    /// is already there belongs to the container that won a replayed create
    /// (and may be its live block device), so it is never renamed over. The
    /// refusal is `already_exists` and leaves no staging file behind.
    func testExclusiveCloneImageRefusesAnExistingTargetAndKeepsItsBytes() throws {
        try payload(seed: 9).write(to: URL(fileURLWithPath: path("golden.img")))
        let live = payload(seed: 10)
        try live.write(to: URL(fileURLWithPath: path("clone.img")))

        XCTAssertThrowsError(
            try VolumeClone.cloneImage(from: path("golden.img"), to: path("clone.img"), placement: .exclusive)
        ) { error in
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "already_exists", "\(error)")
            XCTAssertTrue(error.localizedDescription.contains(path("clone.img")), "\(error)")
        }
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: path("clone.img"))), live, "the winner's clone is untouched")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["clone.img", "golden.img"],
            "no staging file may survive a refused placement")
    }

    func testExclusiveCloneImagePlacesAFreshClone() throws {
        let golden = payload(seed: 11)
        try golden.write(to: URL(fileURLWithPath: path("golden.img")))

        try VolumeClone.cloneImage(from: path("golden.img"), to: path("clones/c2/golden.img"), placement: .exclusive)

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path("clones/c2/golden.img"))), golden)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: path("clones/c2")), ["golden.img"])
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

    // MARK: - removeClones / sweepOrphanClones (shared by the CLI and native container services)

    /// A container's clone dir goes with the container: every clone image,
    /// any staging file a crashed placement left, and the dir itself. Other
    /// containers' dirs are untouched.
    func testRemoveClonesDeletesTheContainerDirAndNothingElse() async throws {
        setenv("MICROPOD_VOLUME_CLONE_ROOT", dir.path, 1)
        defer { unsetenv("MICROPOD_VOLUME_CLONE_ROOT") }
        for name in ["job-1/npm.img", "job-1/go-mod.img", "job-1/.npm.img.tmp-dead0000", "job-2/npm.img"] {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }

        await VolumeClone.removeClones(containerID: "job-1")

        XCTAssertFalse(FileManager.default.fileExists(atPath: path("job-1")), "job-1's clone dir is gone")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: path("job-2")), ["npm.img"])
        // Idempotent: a container without a clone dir is a no-op.
        await VolumeClone.removeClones(containerID: "job-1")
        await VolumeClone.removeClones(containerID: "never-existed")
    }

    /// Each clone image is unlinked under its volume's lock, so a commit
    /// holding that lock finishes its rename before the file goes away.
    func testRemoveClonesWaitsForTheVolumeLock() async throws {
        setenv("MICROPOD_VOLUME_CLONE_ROOT", dir.path, 1)
        defer { unsetenv("MICROPOD_VOLUME_CLONE_ROOT") }
        try FileManager.default.createDirectory(atPath: path("job-3"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: path("job-3/npm.img")))

        let held = AsyncGate()
        let release = AsyncGate()
        let holder = Task {
            await VolumeLocks.shared.withLock("npm") {
                await held.open()
                await release.wait()
            }
        }
        await held.wait()

        let removal = Task { await VolumeClone.removeClones(containerID: "job-3") }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: path("job-3/npm.img")),
            "the clone was unlinked while its volume's lock was held")

        await release.open()
        await holder.value
        await removal.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("job-3")))
    }

    /// The orphan sweep removes clone dirs of containers that no longer
    /// exist — except dirs younger than the grace period, which may belong
    /// to a create that has not reached the runtime yet.
    func testSweepOrphanClonesKeepsLiveAndYoungDirs() async throws {
        setenv("MICROPOD_VOLUME_CLONE_ROOT", dir.path, 1)
        defer { unsetenv("MICROPOD_VOLUME_CLONE_ROOT") }
        for name in ["live", "ghost", "young"] {
            try FileManager.default.createDirectory(atPath: path(name), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: URL(fileURLWithPath: path("\(name)/npm.img")))
        }
        let old = Date().addingTimeInterval(-(VolumeClone.orphanGrace + 60))
        for name in ["live", "ghost"] {
            try FileManager.default.setAttributes([.creationDate: old], ofItemAtPath: path(name))
        }
        try Data("keep".utf8).write(to: URL(fileURLWithPath: path("stray-file")))

        await VolumeClone.sweepOrphanClones(live: ["live"])

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["live", "stray-file", "young"])
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

    /// `withLocks` holds every named lock for the body (a volume prune
    /// touches all volumes), acquiring them in sorted order so two holders
    /// of overlapping sets cannot deadlock, and queues behind any single
    /// holder of one of the names.
    func testWithLocksWaitsForEveryNameAndReleasesAll() async throws {
        let locks = VolumeLocks()
        let log = EventLog()

        let release = AsyncGate()
        let holder = Task {
            await locks.withLock("b") {
                await log.record("b-held")
                await release.wait()
                await log.record("b-released")
            }
        }
        await log.waitFor("b-held")

        let sweeper = Task {
            await locks.withLocks(["c", "a", "b", "a"]) { await log.record("all-held") }
        }
        try await Task.sleep(for: .milliseconds(100))
        var events = await log.events
        XCTAssertFalse(events.contains("all-held"), "ran while 'b' was held: \(events)")
        // "a" is already taken by the sweeper (sorted acquisition: a, then b
        // blocks), so a single-lock caller for "a" queues behind it …
        let aCaller = Task { await locks.withLock("a") { await log.record("a-ran") } }
        try await Task.sleep(for: .milliseconds(100))
        events = await log.events
        XCTAssertFalse(events.contains("a-ran"), "\(events)")

        await release.open()
        await holder.value
        await sweeper.value
        await aCaller.value
        events = await log.events
        XCTAssertEqual(events.firstIndex(of: "b-released")! < events.firstIndex(of: "all-held")!, true, "\(events)")
        XCTAssertEqual(events.firstIndex(of: "all-held")! < events.firstIndex(of: "a-ran")!, true, "\(events)")
        // … and every name is free again afterwards.
        let free = await locks.withLocks(["a", "b", "c"]) { true }
        XCTAssertTrue(free)
    }

    func testWithLocksReleasesEveryNameWhenTheBodyThrows() async throws {
        struct Boom: Error {}
        let locks = VolumeLocks()
        do {
            try await locks.withLocks(["p", "q"]) { throw Boom() }
            XCTFail("expected Boom")
        } catch is Boom {}
        let p = await locks.withLock("p") { true }
        let q = await locks.withLock("q") { true }
        XCTAssertTrue(p && q)
        let none = await locks.withLocks([]) { true }
        XCTAssertTrue(none, "an empty set is a plain call")
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
