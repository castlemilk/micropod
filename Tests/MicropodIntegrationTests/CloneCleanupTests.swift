import MicropodCore
import XCTest

/// The CLI backend's container delete/deleteAll/prune remove the clone dirs
/// of the containers they delete — the same `VolumeClone.removeClones` the
/// native backend uses, under the same per-volume lock — and prune sweeps
/// orphaned dirs. A volume prune holds every volume's lock so it cannot
/// remove a golden's directory under a `CommitVolumeClone`. Exercised
/// against the mock CLI with the clone root pointed into the test's dir.
final class CloneCleanupTests: XCTestCase {
    private var stateDir: URL!
    private var cloneRoot: URL!

    override func setUpWithError() throws {
        cloneRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("clone-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cloneRoot, withIntermediateDirectories: true)
        setenv("MICROPOD_VOLUME_CLONE_ROOT", cloneRoot.path, 1)
    }

    override func tearDown() {
        unsetenv("MICROPOD_VOLUME_CLONE_ROOT")
        if let stateDir { MockContainerCLI.cleanUp(stateDir) }
        if let cloneRoot { try? FileManager.default.removeItem(at: cloneRoot) }
    }

    private func writeClone(container id: String, volume: String) throws {
        let url = cloneRoot.appendingPathComponent("\(id)/\(volume).img")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("clone-of-\(volume)".utf8).write(to: url)
    }

    private func cloneDirExists(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: cloneRoot.appendingPathComponent(id).path)
    }

    /// Every argv the mock received, one line per call (see `Support/mock-container`).
    private func cliCalls() -> [String] {
        let url = stateDir.appendingPathComponent("calls.log")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    func testDeleteAllRemovesOnlyTheDeletedContainersClones() async throws {
        let (client, dir) = try MockContainerCLI.makeClient()
        stateDir = dir
        let containers = ContainerService(client: client)
        let running = try await containers.run(ContainerRunRequest(image: "nginx:1.27", name: "keep", detach: true))
        let stopped = try await containers.run(ContainerRunRequest(image: "nginx:1.27", name: "gone", detach: true))
        try await containers.stop(stopped)
        try writeClone(container: running, volume: "g")
        try writeClone(container: stopped, volume: "g")

        // Without force the CLI keeps running containers — so must their clones.
        try await containers.deleteAll(force: false)
        XCTAssertFalse(cloneDirExists(stopped), "the deleted container's clone dir survives")
        XCTAssertTrue(cloneDirExists(running), "a running container's clone dir was removed")
        let listed1 = try await containers.list().map(\.id)
        XCTAssertEqual(listed1, [running])

        try await containers.deleteAll(force: true)
        XCTAssertFalse(cloneDirExists(running))
        let listed2 = try await containers.list().map(\.id)
        XCTAssertEqual(listed2, [])
    }

    func testPruneRemovesStoppedContainersClonesAndSweepsOrphans() async throws {
        let (client, dir) = try MockContainerCLI.makeClient()
        stateDir = dir
        let containers = ContainerService(client: client)
        let running = try await containers.run(ContainerRunRequest(image: "nginx:1.27", name: "keep", detach: true))
        let stopped = try await containers.run(ContainerRunRequest(image: "nginx:1.27", name: "gone", detach: true))
        try await containers.stop(stopped)
        try writeClone(container: running, volume: "g")
        try writeClone(container: stopped, volume: "g")
        // A dir left by a raw `container delete` long ago, and one a create
        // in flight may own (younger than the grace period).
        try writeClone(container: "ghost", volume: "g")
        try FileManager.default.setAttributes(
            [.creationDate: Date().addingTimeInterval(-(VolumeClone.orphanGrace + 60))],
            ofItemAtPath: cloneRoot.appendingPathComponent("ghost").path)
        try writeClone(container: "young", volume: "g")

        _ = try await containers.prune()

        XCTAssertFalse(cloneDirExists(stopped), "the pruned container's clone dir survives")
        XCTAssertFalse(cloneDirExists("ghost"), "an old orphan survives the sweep")
        XCTAssertTrue(cloneDirExists(running), "a running container's clone dir was removed")
        XCTAssertTrue(cloneDirExists("young"), "a dir inside the grace period was swept")
        let listed3 = try await containers.list().map(\.id)
        XCTAssertEqual(listed3, [running])
    }

    /// The CLI delete itself is not serialised with commits, but the clone
    /// removal is: while a commit holds the volume's lock the clone file
    /// stays, and it goes once the lock is released.
    func testDeleteRemovesTheCloneUnderTheVolumeLock() async throws {
        let (client, dir) = try MockContainerCLI.makeClient()
        stateDir = dir
        let containers = ContainerService(client: client)
        let id = try await containers.run(ContainerRunRequest(image: "nginx:1.27", name: "locked", detach: true))
        try writeClone(container: id, volume: "g")
        let clone = cloneRoot.appendingPathComponent("\(id)/g.img").path

        let held = Gate()
        let release = Gate()
        let holder = Task {
            await VolumeLocks.shared.withLock("g") {
                await held.open()
                await release.wait()
            }
        }
        await held.wait()

        let deletion = Task { try await containers.delete(id, force: true) }
        for _ in 0..<100 where !cliCalls().contains(where: { $0.hasPrefix("delete ") }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(cliCalls().contains { $0.hasPrefix("delete ") }, "\(cliCalls())")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(FileManager.default.fileExists(atPath: clone), "clone unlinked while its volume's lock was held")

        await release.open()
        try await deletion.value
        await holder.value
        XCTAssertFalse(cloneDirExists(id))
        let listed4 = try await containers.list().map(\.id)
        XCTAssertEqual(listed4, [])
    }

    /// `volume prune` runs under every volume's lock, so it can neither
    /// remove a golden's directory between a commit's checks and its rename
    /// nor take away a freshly promoted golden.
    func testVolumePruneWaitsForEveryVolumeLock() async throws {
        let (client, dir) = try MockContainerCLI.makeClient()
        stateDir = dir
        let volumes = VolumeService(client: client)
        try await volumes.create(name: "g")
        try await volumes.create(name: "h")

        let held = Gate()
        let release = Gate()
        let holder = Task {
            await VolumeLocks.shared.withLock("h") {
                await held.open()
                await release.wait()
            }
        }
        await held.wait()

        let pruning = Task { try await volumes.prune() }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(
            cliCalls().contains { $0.hasPrefix("volume prune") },
            "prune reached the CLI while a volume's lock was held: \(cliCalls())")

        await release.open()
        _ = try await pruning.value
        await holder.value
        XCTAssertTrue(cliCalls().contains { $0.hasPrefix("volume prune") }, "\(cliCalls())")
        let listed5 = try await volumes.list().map(\.id)
        XCTAssertEqual(listed5, [])
        // Every lock is free again.
        let free = await VolumeLocks.shared.withLocks(["g", "h"]) { true }
        XCTAssertTrue(free)
    }
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
