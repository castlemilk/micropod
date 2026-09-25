import MicropodCore
import XCTest

@testable import MicropodRuntime

/// Guards around native `create` that need no live runtime:
///  - a failed create removes exactly the clone images it placed — never a
///    clone the create that won a replayed name placed (and may be running
///    on) — and places each clone under its volume's lock;
///  - creates of the same id are mutually exclusive in the process for their
///    whole duration (`InFlightCreates.withExclusive`), so a create is the
///    sole placer under its id when it reclaims a stale clone dir;
///  - a container name outside the runtime's id grammar is refused
///    `invalid_argument` before the mutex and before any filesystem or XPC
///    work: the name is the clone dir's path component;
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

    /// Same-id creates are mutually exclusive for their whole duration: the
    /// second `withExclusive("job")` body does not start until the first
    /// ended, another id is not held up, and every waiter gets its turn.
    func testWithExclusiveSerialisesCreatesOfTheSameID() async throws {
        let creates = InFlightCreates()
        let events = Events()
        let firstStarted = Gate()
        let releaseFirst = Gate()

        let first = Task {
            await creates.withExclusive("job") {
                await events.record("first-start")
                await firstStarted.open()
                await releaseFirst.wait()
                await events.record("first-end")
            }
        }
        await firstStarted.wait()

        let second = Task {
            await creates.withExclusive("job") { await events.record("second-start") }
        }
        let third = Task {
            await creates.withExclusive("job") { await events.record("third-start") }
        }
        // Another id is independent of `job`.
        await creates.withExclusive("other") { await events.record("other-start") }
        try await Task.sleep(for: .milliseconds(200))
        let whileHeld = await events.list
        XCTAssertEqual(
            whileHeld, ["first-start", "other-start"], "a second create of `job` started while the first was in flight")

        await releaseFirst.open()
        await first.value
        await second.value
        await third.value
        let after = await events.list
        XCTAssertEqual(
            Array(after.prefix(3)), ["first-start", "other-start", "first-end"],
            "the replays' bodies run only after the winner's ended")
        XCTAssertEqual(Set(after.dropFirst(3)), ["second-start", "third-start"], "\(after)")
    }

    /// A create that throws releases its id — the failure path (clone
    /// removal) runs inside the body, so the next same-id create finds a
    /// clean dir — and the error reaches the caller.
    func testWithExclusiveReleasesTheIDWhenTheBodyThrows() async throws {
        let creates = InFlightCreates()
        struct Failed: Error {}
        do {
            try await creates.withExclusive("job") { throw Failed() }
            XCTFail("the body's error must propagate")
        } catch is Failed {
        }
        let ran = await creates.withExclusive("job") { true }
        XCTAssertTrue(ran, "the id is free once the throwing create ended")
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

    /// The container name is `<cloneRoot>/<name>`'s path component and
    /// reaches the clone-dir lifecycle (orphan sweep, stale-dir reclaim,
    /// placement, failure removal) before the runtime validates it. `create`
    /// and `run` refuse a name outside the runtime's id grammar as
    /// `invalid_argument` before the create mutex and before any filesystem
    /// or XPC work — there is no runtime behind this service, so a refusal
    /// that reached XPC would surface as something other than
    /// `invalid_argument`. The golden the traversal names — in the clone
    /// root's sibling store, as Apple's volume store sits next to micropod's
    /// under Application Support — survives, and nothing is placed.
    func testCreateRefusesATraversalNameBeforeAnyFilesystemWork() async throws {
        let cloneRoot = root.appendingPathComponent("micropod/volume-clones", isDirectory: true)
        let store = root.appendingPathComponent("com.apple.container/volumes/g", isDirectory: true)
        try FileManager.default.createDirectory(at: cloneRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let golden = store.appendingPathComponent("volume.img")
        try Data("golden".utf8).write(to: golden)
        setenv("MICROPOD_VOLUME_CLONE_ROOT", cloneRoot.path, 1)
        let traversal = "../../com.apple.container/volumes/g"
        XCTAssertEqual(
            cloneRoot.appendingPathComponent(traversal).appendingPathComponent("volume.img").standardizedFileURL.path,
            golden.path, "the traversal names the golden")

        let service = NativeContainerService(
            api: APIServerClient(service: "com.micropod.tests.no-such-apiserver"),
            cli: ContainerService(
                client: ContainerCLIClient(executableURL: root.appendingPathComponent("no-such-cli"))),
            images: ImagesServiceClient(service: "com.micropod.tests.no-such-images"))
        let cloneLabel = LabelSpec(key: "com.micropod.cache.clone", value: "g")
        for name in [traversal, "a/b", "..", "-job", String(repeating: "x", count: 64)] {
            let request = ContainerRunRequest(image: "nginx:1.27", name: name, volumes: ["g:/x"], labels: [cloneLabel])
            for verb in ["create", "run"] {
                do {
                    _ = try await verb == "create" ? service.create(request) : service.run(request)
                    XCTFail("\(verb) with name \(name.debugDescription) must be refused")
                } catch {
                    XCTAssertEqual(ConnectCodeMapping.code(for: error), "invalid_argument", "\(verb) \(name): \(error)")
                    XCTAssertTrue(error.localizedDescription.contains(name), "\(verb) \(name): \(error)")
                }
            }
        }
        // A named volume is a path component too (`<root>/<id>/<volume>.img`).
        do {
            _ = try await service.create(
                ContainerRunRequest(image: "nginx:1.27", name: "job", volumes: ["-g:/x"], labels: [cloneLabel]))
            XCTFail("a volume name outside the grammar must be refused")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "invalid_argument", "\(error)")
            XCTAssertTrue(error.localizedDescription.contains("-g"), "\(error)")
        }

        XCTAssertEqual(try Data(contentsOf: golden), Data("golden".utf8), "the golden's bytes survive")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.path), ["volume.img"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cloneRoot.path), [], "nothing was placed")
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

/// Ordered record of what happened, for asserting interleavings.
private actor Events {
    private(set) var list: [String] = []
    func record(_ event: String) { list.append(event) }
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
