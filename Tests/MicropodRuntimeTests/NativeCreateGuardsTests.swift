import MicropodCore
import XCTest

@testable import MicropodRuntime

/// Guards around native `create` that need no live runtime:
///  - a failed create removes exactly the clone images it placed — never a
///    clone the create that won a replayed name placed (and may be running
///    on) — and places each clone under its volume's lock;
///  - one create per id per process is the sole placer, the only one that
///    may reclaim a stale clone dir;
///  - `no_pull` refuses a missing image with a `notFound:`-prefixed message
///    naming the platform, which the Connect table maps to `not_found`.
final class NativeCreateGuardsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-clone-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("MICROPOD_VOLUME_CLONE_ROOT", root.path, 1)
    }

    override func tearDown() {
        unsetenv("MICROPOD_VOLUME_CLONE_ROOT")
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// What `volumeInspect` answers for a golden backed by `image`.
    private func inspectReply(source image: URL) -> JSONValue {
        .object(["format": .string("ext4"), "source": .string(image.path)])
    }

    /// Two creates for the same id, two clone volumes: the replay places `a`
    /// first, then finds the winner's `b` in place (`already_exists`). Its
    /// failure removes exactly what it placed — `a` — and leaves the
    /// winner's `b`, with the winner's writes, and the dir alone.
    func testFailedCreateRemovesOnlyTheClonesItPlaced() async throws {
        let golden = root.appendingPathComponent("golden.img")
        try Data("golden".utf8).write(to: golden)
        var placed: [String] = []

        let a = try await NativeContainerService.placeClone(volume: "a", containerID: "job-1") {
            self.inspectReply(source: golden)
        }
        placed.append("a")
        XCTAssertEqual(a.clone, root.appendingPathComponent("job-1/a.img").path)
        XCTAssertEqual(a.format, "ext4")

        // The winner placed `b` and started writing into it.
        let winnersB = root.appendingPathComponent("job-1/b.img")
        try Data("winner-writes".utf8).write(to: winnersB)
        do {
            _ = try await NativeContainerService.placeClone(volume: "b", containerID: "job-1") {
                self.inspectReply(source: golden)
            }
            XCTFail("placing over the winner's clone must fail")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "already_exists", "\(error)")
        }

        // What `createNative`'s failure path does with its record.
        await VolumeClone.removeClones(containerID: "job-1", volumes: placed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.clone), "the replay's own clone is removed")
        XCTAssertEqual(try Data(contentsOf: winnersB), Data("winner-writes".utf8), "the winner's clone is untouched")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("job-1").path), ["b.img"],
            "no staging file left next to the winner's clone")
    }

    /// The clone is placed under the volume's lock — the one `DeleteVolume`
    /// and `volume prune` hold — so the golden cannot be removed between
    /// the inspect and the clonefile: neither happens while the lock is held.
    func testPlaceCloneWaitsForTheVolumeLock() async throws {
        let golden = root.appendingPathComponent("golden.img")
        try Data("golden".utf8).write(to: golden)
        let inspections = Counter()

        let held = Gate()
        let release = Gate()
        let holder = Task {
            await VolumeLocks.shared.withLock("cache") {
                await held.open()
                await release.wait()
            }
        }
        await held.wait()

        let goldenPath = golden.path
        let placing = Task {
            try await NativeContainerService.placeClone(volume: "cache", containerID: "job-2") {
                await inspections.bump()
                return .object(["format": .string("ext4"), "source": .string(goldenPath)])
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        let early = await inspections.count
        XCTAssertEqual(early, 0, "the golden was inspected while its volume's lock was held")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("job-2/cache.img").path))

        await release.open()
        await holder.value
        let placed = try await placing.value
        XCTAssertEqual(placed.clone, root.appendingPathComponent("job-2/cache.img").path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: placed.clone)), Data("golden".utf8))
        let late = await inspections.count
        XCTAssertEqual(late, 1)
    }

    /// One placer per id per process: the first `begin` admits, a second
    /// while the first is in flight does not, other ids are independent, and
    /// after `end` the id is free again.
    func testInFlightCreatesAdmitOneSolePlacerPerID() async {
        let registry = InFlightCreates()
        let first = await registry.begin("job-3")
        XCTAssertTrue(first)
        let second = await registry.begin("job-3")
        XCTAssertFalse(second, "a concurrent create of the same id is not the sole placer")
        let other = await registry.begin("job-4")
        XCTAssertTrue(other)
        await registry.end("job-3")
        let again = await registry.begin("job-3")
        XCTAssertTrue(again, "the id is free once its sole placer ended")
    }

    /// Two creates for the same id that both pass the duplicate-id list check
    /// each try to place `<root>/<id>/<vol>.img`. The second placement must
    /// fail `already_exists` and leave the first clone — possibly a running
    /// container's live block device — exactly as it was, never rename over it.
    func testCloneVolumeImageNeverReplacesAnExistingClone() throws {
        let golden = root.appendingPathComponent("golden.img")
        try Data("golden".utf8).write(to: golden)

        let placed = try NativeContainerService.cloneVolumeImage(
            source: golden.path, containerID: "job-9", volume: "cache")
        XCTAssertEqual(placed, root.appendingPathComponent("job-9/cache.img").path)
        // The winner started and wrote into its clone.
        try Data("winner-writes".utf8).write(to: URL(fileURLWithPath: placed))

        XCTAssertThrowsError(
            try NativeContainerService.cloneVolumeImage(source: golden.path, containerID: "job-9", volume: "cache")
        ) { error in
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "already_exists", "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: placed)), Data("winner-writes".utf8))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("job-9").path),
            ["cache.img"], "no staging file left next to the winner's clone")
    }

    func testNoPullRefusalNamesImageAndPlatformAsNotFound() {
        let error = ImagesServiceClient.notPresentLocally(
            reference: "ghost/none:1",
            platform: .object(["os": .string("linux"), "architecture": .string("arm64")]))
        XCTAssertEqual(
            error.localizedDescription, "notFound: image ghost/none:1 not present locally for linux/arm64")
        XCTAssertEqual(ConnectCodeMapping.code(for: error), "not_found")

        let variant = ImagesServiceClient.notPresentLocally(
            reference: "ghost/none:1",
            platform: .object([
                "os": .string("linux"), "architecture": .string("arm64"), "variant": .string("v8"),
            ]))
        XCTAssertTrue(variant.localizedDescription.hasSuffix("for linux/arm64/v8"), variant.localizedDescription)

        let anyPlatform = ImagesServiceClient.notPresentLocally(reference: "ghost/none:1", platform: nil)
        XCTAssertEqual(
            anyPlatform.localizedDescription, "notFound: image ghost/none:1 not present locally for any platform")
    }
}

private actor Counter {
    private(set) var count = 0
    func bump() { count += 1 }
}

/// One-shot async gate: `wait()` suspends until `open()`.
private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
