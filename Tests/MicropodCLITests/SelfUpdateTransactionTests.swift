import Darwin
import Foundation
import MicropodCore
import XCTest

@testable import MicropodCLI
@testable import MicropodRuntime

/// `micropod update cli` installs a release all or nothing: the CLI, MCP and
/// API binaries and the HVF payload are staged and checked before anything
/// installed is replaced, and a failed replacement puts every binary back.
final class SelfUpdateTransactionTests: XCTestCase {
    private var base: URL!
    private var hvfRoot: URL!

    override func setUp() {
        let tag = UUID().uuidString.prefix(8).lowercased()
        base = URL(fileURLWithPath: "/tmp/mpsu-\(tag)")
        hvfRoot = URL(fileURLWithPath: "/tmp/mpsu-\(tag)-hvf")
    }

    override func tearDown() {
        for dir in [base, hvfRoot] {
            guard let dir else { continue }
            // Undo the immutable flag and the read-only payloads before removing.
            if let walker = FileManager.default.enumerator(atPath: dir.path) {
                while let relative = walker.nextObject() as? String {
                    let path = dir.appendingPathComponent(relative).path
                    _ = chflags(path, 0)
                    var info = stat()
                    if lstat(path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK { _ = chmod(path, 0o755) }
                }
            }
            _ = chmod(dir.path, 0o755)
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private var install: URL { base.appendingPathComponent("bin") }
    private var app: URL { base.appendingPathComponent("Micropod.app") }
    private var hvf: HVFMachineLayout { HVFMachineLayout(root: hvfRoot) }
    private let machO = Data([0xCF, 0xFA, 0xED, 0xFE])

    /// A standalone install (CLI, MCP and API beside it) and a release app
    /// that carries all three and, unless `withHVF` is false, an HVF payload.
    private func fixture(withHVF: Bool = true) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: install, withIntermediateDirectories: true)
        for name in ["micropod", "micropod-mcp-bin", "micropod-api-bin", "micropod-docker-shim", "micropod-sharedfs"] {
            try (machO + Data("old \(name)".utf8)).write(to: install.appendingPathComponent(name))
        }
        let macOS = app.appendingPathComponent("Contents/MacOS")
        let resources = app.appendingPathComponent("Contents/Resources")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: resources.appendingPathComponent("micropod-oci-tools/runner"), withIntermediateDirectories: true)
        var executables = ["micropod-cli", "MicropodMCP", "MicropodAPI", "micropod-docker-shim", "micropod-sharedfs"]
        if withHVF {
            executables.append("micropod-vmm")
            try Data("kernel-new".utf8).write(to: resources.appendingPathComponent("vmlinux-hvf"))
            try Data("initrd-new".utf8).write(to: resources.appendingPathComponent("mp-hvf-init.cpio"))
            try Data("#!/bin/sh\n".utf8).write(
                to: resources.appendingPathComponent("micropod-oci-tools/runner/start.sh"))
        }
        for name in executables {
            let url = macOS.appendingPathComponent(name)
            try (machO + Data("new \(name)".utf8)).write(to: url)
            XCTAssertEqual(chmod(url.path, 0o755), 0)
        }
        // An installed flat HVF machine to keep in step.
        let flat = HVFMachinePayload(directory: hvfRoot, isVersioned: false)
        try fm.createDirectory(at: flat.tools.appendingPathComponent("runner"), withIntermediateDirectories: true)
        try Data("old vmm".utf8).write(to: flat.vmm)
        XCTAssertEqual(chmod(flat.vmm.path, 0o755), 0)
        try Data("kernel-old".utf8).write(to: flat.kernel)
        try Data("initrd-old".utf8).write(to: flat.initrd)
        try Data("#!/bin/sh\n".utf8).write(to: flat.tools.appendingPathComponent("runner/start.sh"))
    }

    private let checks = SelfUpdate.ReleaseChecks(
        signedByRelease: { _ in true }, reportedVersion: { _ in "micropod 9.9.9\n" }, hvfEntitlement: false)

    private func installRelease() throws {
        let files = SelfUpdate.installedFiles(cli: install.appendingPathComponent("micropod"))
        XCTAssertEqual(
            files.map(\.bundled),
            ["micropod-cli", "MicropodMCP", "MicropodAPI", "micropod-docker-shim", "micropod-sharedfs"])
        try SelfUpdate.installRelease(
            from: app, version: try XCTUnwrap(ReleaseVersion("9.9.9")), revision: nil, files: files, hvf: hvf,
            checks: checks, progress: { _ in })
    }

    private func installed(_ name: String) throws -> String {
        String(decoding: try Data(contentsOf: install.appendingPathComponent(name)).dropFirst(4), as: UTF8.self)
    }

    private func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: install.path).filter { $0.contains(".update-") }
    }

    func testEverythingIsReplacedAndTheHVFPayloadIsStagedNotActivated() throws {
        try fixture()
        try installRelease()
        XCTAssertEqual(try installed("micropod"), "new micropod-cli")
        XCTAssertEqual(try installed("micropod-mcp-bin"), "new MicropodMCP")
        XCTAssertEqual(try installed("micropod-api-bin"), "new MicropodAPI", "the API server updates too")
        XCTAssertEqual(try installed("micropod-api-bin.bak"), "old micropod-api-bin")
        XCTAssertEqual(try installed("micropod-docker-shim"), "new micropod-docker-shim", "and the Docker shim")
        XCTAssertEqual(try installed("micropod-sharedfs"), "new micropod-sharedfs")
        XCTAssertEqual(try leftovers(), [])
        let status = HVFPayloadStore.status(layout: hvf)
        XCTAssertEqual(status.staged?.version, "9.9.9")
        XCTAssertEqual(status.current?.origin, HVFPayloadManifest.flatOrigin, "the flat install stays current")
        XCTAssertEqual(status.knownGoodPath, status.currentPath)
        XCTAssertTrue(status.updatePending)
        XCTAssertEqual(
            try String(contentsOf: hvf.kernel, encoding: .utf8), "kernel-old", "nothing boots the release yet")
    }

    /// A daemon started from a file the update replaced keeps the old
    /// release in memory: the update names it.
    func testAProcessStillRunningAReplacedBinaryIsNamed() throws {
        try fixture()
        let shim = install.appendingPathComponent("micropod-docker-shim")
        try FileManager.default.removeItem(at: shim)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: shim)
        let process = Process()
        process.executableURL = shim
        process.arguments = ["30"]
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }
        let messages = UpdateFlagLog()
        let files = SelfUpdate.installedFiles(cli: install.appendingPathComponent("micropod"))
        try SelfUpdate.installRelease(
            from: app, version: try XCTUnwrap(ReleaseVersion("9.9.9")), revision: nil, files: files, hvf: hvf,
            checks: checks, progress: { messages.append($0) })
        XCTAssertTrue(
            messages.lines.contains { $0.contains("restart micropod-docker-shim (pid \(process.processIdentifier))") },
            "\(messages.lines)")
        XCTAssertEqual(try installed("micropod-docker-shim"), "new micropod-docker-shim")
    }

    func testAReleaseWithoutTheHVFPayloadInstallsNothing() throws {
        try fixture(withHVF: false)
        XCTAssertThrowsError(try installRelease()) { error in
            XCTAssertTrue(error.localizedDescription.contains("carries no HVF runtime payload"), "\(error)")
        }
        XCTAssertEqual(try installed("micropod"), "old micropod")
        XCTAssertEqual(try installed("micropod-mcp-bin"), "old micropod-mcp-bin")
        XCTAssertEqual(try installed("micropod-api-bin"), "old micropod-api-bin")
        XCTAssertEqual(try leftovers(), [])
        XCTAssertNil(HVFPayloadStore.status(layout: hvf).staged)
    }

    func testAFailedHVFStageFailsTheUpdate() throws {
        try fixture()
        // Another payload transaction holds the lock: the stage is refused.
        let holder = open(hvf.updateLock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(holder, 0)
        defer { close(holder) }
        XCTAssertEqual(flock(holder, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try installRelease()) { error in
            XCTAssertTrue(error.localizedDescription.contains("in progress"), "\(error)")
        }
        XCTAssertEqual(try installed("micropod"), "old micropod")
        XCTAssertEqual(try installed("micropod-api-bin"), "old micropod-api-bin")
        XCTAssertEqual(try leftovers(), [])
    }

    func testAFailedReplacementPutsEveryBinaryBackAndDropsTheHVFStage() throws {
        try fixture()
        // The last replacement fails: an immutable file cannot be renamed over.
        let api = install.appendingPathComponent("micropod-api-bin")
        XCTAssertEqual(chflags(api.path, UInt32(UF_IMMUTABLE)), 0)
        XCTAssertThrowsError(try installRelease())
        XCTAssertEqual(try installed("micropod"), "old micropod", "restored")
        XCTAssertEqual(try installed("micropod-mcp-bin"), "old micropod-mcp-bin", "restored")
        XCTAssertEqual(try installed("micropod-api-bin"), "old micropod-api-bin")
        XCTAssertEqual(try leftovers(), [])
        XCTAssertNil(HVFPayloadStore.status(layout: hvf).staged, "no payload staged for a release that did not install")
    }

    func testNoHVFMachineMeansNoHVFRequirement() throws {
        try fixture(withHVF: false)
        try FileManager.default.removeItem(at: hvfRoot)
        try installRelease()
        XCTAssertEqual(try installed("micropod"), "new micropod-cli")
        XCTAssertFalse(FileManager.default.fileExists(atPath: hvfRoot.path), "nothing created")
    }

    func testHVFExitCodesTellARetryFromAFailure() {
        XCTAssertEqual(UpdateCommands.hvfExitCode(.activated), 0)
        XCTAssertEqual(UpdateCommands.hvfExitCode(.noop), 0)
        XCTAssertEqual(UpdateCommands.hvfExitCode(.deferred), 75)
        XCTAssertEqual(UpdateCommands.hvfExitCode(.rolledBack), 1)
        XCTAssertEqual(UpdateCommands.hvfExitCode(.failedRollback), 1)
        XCTAssertEqual(UpdateCommands.hvfExitCode(.failed), 1)
    }

    /// For `update hvf rollback`, reaching known-good is the success.
    func testARollbackThatReachedKnownGoodExitsZero() {
        XCTAssertEqual(UpdateCommands.hvfRollbackExitCode(.rolledBack), 0)
        XCTAssertEqual(UpdateCommands.hvfRollbackExitCode(.noop), 0)
        XCTAssertEqual(UpdateCommands.hvfRollbackExitCode(.deferred), 75)
        XCTAssertEqual(UpdateCommands.hvfRollbackExitCode(.failedRollback), 1)
        XCTAssertEqual(UpdateCommands.hvfRollbackExitCode(.failed), 1)
    }

    func testTheStatusLineNamesTheStagedVersionWhilePending() {
        let current = HVFPayloadManifest(version: "0.14.0")
        let staged = HVFPayloadManifest(version: "0.15.0")
        var status = HVFPayloadStatus(
            currentPath: "/r/versions/a", previousPath: nil, stagedPath: "/r/versions/b",
            knownGoodPath: "/r/versions/a",
            current: current, previous: nil, staged: staged, knownGood: current, runningPath: "/r/versions/a",
            runningVersion: "0.14.0", runningRevision: nil, updatePending: true, availableVersions: ["a", "b"])
        XCTAssertEqual(
            UpdateCommands.hvfStatusLine(status),
            "HVF runtime — running 0.14.0, 0.15.0 staged (update pending: `micropod update hvf apply`)")
        status.lastActivationFailure = "GET /micropod/caches answered HTTP 500"
        XCTAssertEqual(
            UpdateCommands.hvfStatusLine(status),
            "HVF runtime — running 0.14.0, 0.15.0 staged (update pending: `micropod update hvf apply`; its last "
                + "apply failed: GET /micropod/caches answered HTTP 500)")
        status.lastActivationFailure = nil
        status.updatePending = false
        status.staged = nil
        XCTAssertEqual(UpdateCommands.hvfStatusLine(status), "HVF runtime — 0.14.0 (running 0.14.0)")
    }
}

private final class UpdateFlagLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ line: String) { lock.withLock { stored.append(line) } }
    var lines: [String] { lock.withLock { stored } }
}
