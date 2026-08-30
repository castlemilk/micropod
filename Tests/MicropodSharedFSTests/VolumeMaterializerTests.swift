import XCTest

@testable import MicropodSharedFS

/// Records what a sync would have done to a container, and models the parts of
/// the container filesystem the materializer actually manipulates so the
/// resulting tree can be asserted on without a runtime.
///
/// An actor rather than a lock-guarded class: the protocol is async, and
/// NSLock is unavailable from async contexts under strict concurrency.
actor FakeVolumeOps: VolumeContainerOps {
    private(set) var startedHelpers: [String] = []
    private(set) var removedContainers: [String] = []
    private(set) var execs: [[String]] = []
    /// Where extracted tars land, so the shipped tree can be inspected.
    nonisolated let extractRoot: URL
    private var nextID = 0

    init(extractRoot: URL) {
        self.extractRoot = extractRoot
    }

    var helperStartCount: Int { startedHelpers.count }
    var removedCount: Int { removedContainers.count }
    private(set) var reapCalls: [String] = []
    /// Overridable so a test can model a volume that vanished or was replaced.
    var volumeFingerprint: String? = "fake-volume-v1"

    func setFingerprint(_ value: String?) { volumeFingerprint = value }

    func fingerprint(volume: String) async throws -> String? { volumeFingerprint }

    func reapStaleHelpers(volume: String) async { reapCalls.append(volume) }

    func startHelper(volume: String, mountPath: String) async throws -> String {
        startedHelpers.append(volume)
        nextID += 1
        return "fake-helper-\(nextID)"
    }

    func copyIn(hostPath: String, containerID: String, containerPath: String) async throws {
        // Stash the upload under the fake container's tree so a later
        // `tar -xf` exec finds it, mirroring the real flow.
        let target = fakePath(containerPath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: hostPath), to: target)
    }

    @discardableResult
    func exec(containerID: String, arguments: [String]) async throws -> String {
        execs.append(arguments)
        // Execute the handful of command shapes the materializer emits against
        // the fake tree, so assertions are about resulting files rather than
        // about command strings.
        if arguments.first == "mkdir", arguments.count >= 3 {
            try FileManager.default.createDirectory(
                at: fakePath(arguments[2]), withIntermediateDirectories: true)
            return ""
        }
        if arguments.first == "tar", arguments.count >= 5 {
            let archive = fakePath(arguments[2])
            let destination = fakePath(arguments[4])
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true)
            try Self.shell(["/usr/bin/tar", "-xf", archive.path, "-C", destination.path])
            return ""
        }
        if arguments.first == "rm" { return "" }
        if arguments.first == "sh", arguments.count >= 3 {
            let script = rewriteForFakeTree(arguments[2])
            try Self.shell(["/bin/sh", "-c", script])
            return ""
        }
        return ""
    }

    func remove(containerID: String) async {
        removedContainers.append(containerID)
    }

    /// Surfaces failures rather than swallowing them — a silently-failing
    /// prune in the fake would make a broken removal path look like a passing
    /// test.
    private static func shell(_ argv: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let detail = String(decoding: errorData, as: UTF8.self)
            fputs("[fake-ops] \(argv.joined(separator: " ")) -> \(process.terminationStatus): \(detail)\n", stderr)
            throw SharedFSError.containerCommandFailed(argv.joined(separator: " "), detail)
        }
    }

    /// Maps an absolute container path onto the fake tree.
    private nonisolated func fakePath(_ containerPath: String) -> URL {
        extractRoot.appendingPathComponent(
            containerPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    /// The emitted loops use absolute container paths; rebase them.
    private nonisolated func rewriteForFakeTree(_ script: String) -> String {
        script.replacingOccurrences(of: "'/", with: "'\(extractRoot.path)/")
    }
}

final class VolumeMaterializerTests: XCTestCase {
    private var tempRoot: URL!
    private var source: URL!
    private var ops: FakeVolumeOps!
    private var materializer: VolumeMaterializer!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("materializer-\(UUID().uuidString)")
        source = tempRoot.appendingPathComponent("src")
        let extractRoot = tempRoot.appendingPathComponent("container")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extractRoot, withIntermediateDirectories: true)
        ops = FakeVolumeOps(extractRoot: extractRoot)
        materializer = VolumeMaterializer(
            ops: ops,
            manifests: try ManifestStore(root: tempRoot.appendingPathComponent("manifests")))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func write(_ relative: String, _ contents: String) throws {
        let url = source.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url, options: .atomic)
    }

    private func shipped(_ relative: String) -> String? {
        let url = ops.extractRoot.appendingPathComponent("__micropod_sync")
            .appendingPathComponent(relative)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func testFirstSyncShipsEverything() async throws {
        try write("a.txt", "alpha")
        try write("pkg/b.txt", "bravo")

        let stats = try await materializer.sync(source: source, volume: "vol")

        XCTAssertFalse(stats.skipped)
        XCTAssertEqual(stats.filesShipped, 2)
        XCTAssertEqual(shipped("a.txt"), "alpha")
        XCTAssertEqual(shipped("pkg/b.txt"), "bravo")
    }

    /// The entire point: an unchanged tree must not start a container at all.
    func testUnchangedTreeSkipsEntirely() async throws {
        try write("a.txt", "alpha")
        _ = try await materializer.sync(source: source, volume: "vol")
        let helpersAfterFirst = await ops.helperStartCount

        let second = try await materializer.sync(source: source, volume: "vol")

        XCTAssertTrue(second.skipped)
        XCTAssertEqual(second.filesShipped, 0)
        let helpersAfterSecond = await ops.helperStartCount
        XCTAssertEqual(
            helpersAfterSecond, helpersAfterFirst,
            "a no-op sync must not pay for a container start")
    }

    func testOnlyChangedFileIsShipped() async throws {
        try write("a.txt", "alpha")
        try write("b.txt", "bravo")
        _ = try await materializer.sync(source: source, volume: "vol")

        try write("b.txt", "bravo-2")
        let stats = try await materializer.sync(source: source, volume: "vol")

        XCTAssertEqual(stats.filesShipped, 1, "only the modified file should ship")
        XCTAssertEqual(shipped("b.txt"), "bravo-2")
    }

    /// A file rewritten with identical bytes changes mtime but not content.
    /// Shipping it would be pure waste on every `git checkout`.
    func testTouchedButIdenticalFileIsNotShipped() async throws {
        try write("a.txt", "alpha")
        _ = try await materializer.sync(source: source, volume: "vol")

        // Rewrite the same bytes, then force a distinct mtime.
        try write("a.txt", "alpha")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(120)],
            ofItemAtPath: source.appendingPathComponent("a.txt").path)

        let stats = try await materializer.sync(source: source, volume: "vol")
        XCTAssertTrue(stats.skipped, "identical content must not ship on an mtime bump alone")
    }

    func testDeletedFileIsRemovedFromVolume() async throws {
        try write("a.txt", "alpha")
        try write("gone.txt", "bye")
        _ = try await materializer.sync(source: source, volume: "vol")
        XCTAssertEqual(shipped("gone.txt"), "bye")

        try FileManager.default.removeItem(at: source.appendingPathComponent("gone.txt"))
        let stats = try await materializer.sync(source: source, volume: "vol")

        XCTAssertEqual(stats.pathsRemoved, 1)
        XCTAssertNil(shipped("gone.txt"), "a deleted source file must not survive in the volume")
        XCTAssertEqual(shipped("a.txt"), "alpha", "unrelated files must be untouched")
    }

    /// The helper holds the volume exclusively, so failing to remove it would
    /// block every later container that mounts the same volume.
    func testHelperIsAlwaysRemoved() async throws {
        try write("a.txt", "alpha")
        _ = try await materializer.sync(source: source, volume: "vol")
        // The removal is fired from a defer'd detached task.
        try await Task.sleep(for: .milliseconds(200))
        let removed = await ops.removedCount
        let started = await ops.helperStartCount
        XCTAssertEqual(removed, started)
    }

    func testInvalidateForcesFullReship() async throws {
        try write("a.txt", "alpha")
        _ = try await materializer.sync(source: source, volume: "vol")
        let repeated = try await materializer.sync(source: source, volume: "vol")
        XCTAssertTrue(repeated.skipped)

        try materializer.invalidate(source: source, volume: "vol")
        let stats = try await materializer.sync(source: source, volume: "vol")

        XCTAssertFalse(stats.skipped)
        XCTAssertEqual(stats.filesShipped, 1)
    }

    /// Two volumes fed from one tree keep separate histories — sharing one
    /// would make the second volume's first sync a no-op and leave it empty.
    func testPerVolumeHistoryIsIndependent() async throws {
        try write("a.txt", "alpha")
        _ = try await materializer.sync(source: source, volume: "vol-one")

        let other = try await materializer.sync(source: source, volume: "vol-two")
        XCTAssertFalse(other.skipped)
        XCTAssertEqual(other.filesShipped, 1)
    }

    func testDestinationSubpathIsHonored() async throws {
        try write("a.txt", "alpha")
        _ = try await materializer.sync(source: source, volume: "vol", destination: "/workspace")

        let url = ops.extractRoot.appendingPathComponent("__micropod_sync/workspace/a.txt")
        XCTAssertEqual(
            String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self), "alpha")
    }
}

/// The safeguards that stop a sync from reporting success against a volume
/// that no longer holds what the history claims.
final class VolumeMaterializerSafetyTests: XCTestCase {
    private var tempRoot: URL!
    private var source: URL!
    private var ops: FakeVolumeOps!
    private var materializer: VolumeMaterializer!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("materializer-safety-\(UUID().uuidString)")
        source = tempRoot.appendingPathComponent("src")
        let extractRoot = tempRoot.appendingPathComponent("container")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extractRoot, withIntermediateDirectories: true)
        ops = FakeVolumeOps(extractRoot: extractRoot)
        materializer = VolumeMaterializer(
            ops: ops,
            manifests: try ManifestStore(root: tempRoot.appendingPathComponent("manifests")))
        try Data("alpha".utf8).write(to: source.appendingPathComponent("a.txt"), options: .atomic)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// The failure this exists to prevent: volume replaced, history kept, sync
    /// reports "up to date" while the volume is actually empty.
    func testReplacedVolumeForcesFullReship() async throws {
        _ = try await materializer.sync(source: source, volume: "vol")
        let unchanged = try await materializer.sync(source: source, volume: "vol")
        XCTAssertTrue(unchanged.skipped)

        await ops.setFingerprint("fake-volume-v2")

        let afterReplacement = try await materializer.sync(source: source, volume: "vol")
        XCTAssertFalse(
            afterReplacement.skipped,
            "a replaced volume must not be reported up to date")
        XCTAssertEqual(afterReplacement.filesShipped, 1)
    }

    func testMissingVolumeIsAnError() async throws {
        await ops.setFingerprint(nil)
        do {
            _ = try await materializer.sync(source: source, volume: "vol")
            XCTFail("syncing into a volume that does not exist must fail loudly")
        } catch {
            // Expected: silently creating or skipping would hide a typo'd
            // volume name until the job failed for an unrelated-looking reason.
        }
    }

    /// A helper left by a crashed sync holds the volume exclusively; the next
    /// sync must clear it or it will fail to bootstrap.
    func testStaleHelpersAreReapedBeforeStarting() async throws {
        _ = try await materializer.sync(source: source, volume: "vol")
        let reaped = await ops.reapCalls
        XCTAssertEqual(reaped, ["vol"])
    }

    func testNoOpSyncDoesNotReapOrStartAnything() async throws {
        _ = try await materializer.sync(source: source, volume: "vol")
        let reapsAfterFirst = await ops.reapCalls.count
        let startsAfterFirst = await ops.helperStartCount

        _ = try await materializer.sync(source: source, volume: "vol")

        let reapsAfterSecond = await ops.reapCalls.count
        let startsAfterSecond = await ops.helperStartCount
        XCTAssertEqual(reapsAfterSecond, reapsAfterFirst)
        XCTAssertEqual(startsAfterSecond, startsAfterFirst)
    }
}

final class VolumeSyncLockTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("locks-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSecondHolderIsRefusedWhileFirstIsAlive() throws {
        let first = try VolumeSyncLock(root: root, volume: "vol")
        XCTAssertThrowsError(
            try VolumeSyncLock(root: root, volume: "vol", timeout: .milliseconds(250)),
            "a block volume admits one writer at a time")
        withExtendedLifetime(first) {}
    }

    func testLockIsReleasedWhenHolderGoesAway() throws {
        do {
            let first = try VolumeSyncLock(root: root, volume: "vol")
            withExtendedLifetime(first) {}
        }
        // Must not throw: the previous holder is gone.
        let second = try VolumeSyncLock(root: root, volume: "vol", timeout: .milliseconds(500))
        withExtendedLifetime(second) {}
    }

    func testDifferentVolumesDoNotContend() throws {
        let one = try VolumeSyncLock(root: root, volume: "vol-a")
        let two = try VolumeSyncLock(root: root, volume: "vol-b", timeout: .milliseconds(250))
        withExtendedLifetime(one) {}
        withExtendedLifetime(two) {}
    }
}
