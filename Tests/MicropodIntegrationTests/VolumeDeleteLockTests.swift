import MicropodCore
import XCTest

/// `DeleteVolume` takes the same per-volume lock as `CommitVolumeClone`, so
/// a delete runs either before a commit's checks-and-rename section or after
/// it — never in between, where the commit would stage into a directory the
/// runtime is removing. Exercised on the CLI backend against the mock; the
/// native backend takes the lock the same way.
final class VolumeDeleteLockTests: XCTestCase {
    private var stateDir: URL!

    override func tearDown() {
        if let stateDir { MockContainerCLI.cleanUp(stateDir) }
    }

    func testDeleteWaitsForTheVolumeLock() async throws {
        let (client, dir) = try MockContainerCLI.makeClient()
        stateDir = dir
        let volumes = VolumeService(client: client)
        try await volumes.create(name: "g")

        // Hold `g`'s lock until released, as a commit in progress would.
        let held = Gate()
        let release = Gate()
        let holder = Task {
            await VolumeLocks.shared.withLock("g") {
                await held.open()
                await release.wait()
            }
        }
        await held.wait()

        let deletion = Task { try await volumes.delete("g") }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(
            cliCalls().contains { $0.hasPrefix("volume delete") },
            "delete reached the CLI while the volume's lock was held: \(cliCalls())")

        await release.open()
        try await deletion.value
        await holder.value
        XCTAssertTrue(cliCalls().contains { $0.hasPrefix("volume delete") }, "\(cliCalls())")
        let remaining = try await volumes.list().map(\.id)
        XCTAssertFalse(remaining.contains("g"), "\(remaining)")
    }

    /// Every argv the mock received, one line per call (see `Support/mock-container`).
    private func cliCalls() -> [String] {
        let url = stateDir.appendingPathComponent("calls.log")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
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
