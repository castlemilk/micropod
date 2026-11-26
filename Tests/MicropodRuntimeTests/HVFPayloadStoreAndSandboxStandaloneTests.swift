import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

final class HVFPayloadStoreAndSandboxStandaloneTests: XCTestCase {
    private var tmp: URL!

    override func setUp() {
        tmp = URL(fileURLWithPath: "/tmp/mp23-\(UUID().uuidString.prefix(8).lowercased())")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Committed payloads are read-only.
        try? HVFPayloadStore.removeTree(tmp)
    }

    private func makeFakeBundle(name: String, tag: String, appLayout: Bool) throws -> URL {
        let fm = FileManager.default
        let base = tmp.appendingPathComponent(name)
        let binDir = appLayout ? base.appendingPathComponent("Contents/MacOS") : base
        let resDir = appLayout ? base.appendingPathComponent("Contents/Resources") : base
        let toolsDir = resDir.appendingPathComponent(appLayout ? "micropod-oci-tools" : "tools")
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: toolsDir.appendingPathComponent("runner/bin"), withIntermediateDirectories: true)

        let vmm = binDir.appendingPathComponent("micropod-vmm")
        try Data("#!/bin/sh\necho \(tag)\n".utf8).write(to: vmm)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vmm.path)
        try Data("kernel-\(tag)".utf8).write(to: resDir.appendingPathComponent(appLayout ? "vmlinux-hvf" : "Image"))
        try Data("initrd-\(tag)".utf8).write(to: resDir.appendingPathComponent("mp-hvf-init.cpio"))
        try Data("#!/bin/sh\n# start \(tag)\n".utf8).write(to: toolsDir.appendingPathComponent("runner/start.sh"))
        try Data("job-\(tag)".utf8).write(to: toolsDir.appendingPathComponent("runner/bin/job"))
        return base
    }

    func testHVFPayloadStoreStageVerifyPendingRollbackAndPrune() async throws {
        let root = tmp.appendingPathComponent("hvf-root")
        let layout = HVFMachineLayout(root: root)
        let appV1 = try makeFakeBundle(name: "Micropod-v1.app", tag: "v1", appLayout: true)
        let dirV2 = try makeFakeBundle(name: "bundle-v2", tag: "v2", appLayout: false)
        let dirV3 = try makeFakeBundle(name: "bundle-v3", tag: "v3", appLayout: false)

        // Stage v1 from .app bundle: staged, not booted.
        let m1 = try HVFPayloadStore.stage(
            from: .directory(appV1), version: "0.14.0", revision: "111111111111", layout: layout,
            verifySignature: false)
        XCTAssertEqual(m1.version, "0.14.0")
        XCTAssertEqual(m1.digests.count, 5)
        let v1Dir = layout.versionsDirectory.appendingPathComponent("0.14.0-111111111111")
        XCTAssertEqual(HVFPayloadStore.status(layout: layout).stagedPath, HVFMachineLayout.canonicalPath(v1Dir.path))
        XCTAssertNil(HVFPayloadStore.status(layout: layout).currentPath, "staging never moves current")
        XCTAssertEqual(layout.activePayloadRoot, root.standardizedFileURL)
        try HVFPayloadStore.verify(payloadDirectory: v1Dir)

        // v1 verified and running (what a passed activation leaves).
        try HVFPayloadStore.atomicSymlink(destination: "versions/0.14.0-111111111111", at: layout.currentLink)
        try HVFPayloadStore.atomicSymlink(destination: "versions/0.14.0-111111111111", at: layout.knownGoodLink)
        unlink(layout.stagedLink.path)
        try FileManager.default.createDirectory(at: layout.runDirectory, withIntermediateDirectories: true)
        let lock = try XCTUnwrap(try HVFFileLock.acquire(layout.supervisorLock, wait: .zero))
        defer { lock.release() }
        let v1Canonical = HVFMachineLayout.canonicalPath(layout.activePayloadRoot.path)
        try HVFMachineState(
            phase: .running, supervisorPID: getpid(), loadedPayloadPath: v1Canonical,
            loadedPayloadVersion: "0.14.0", loadedPayloadRevision: "111111111111"
        ).save(to: layout.state)
        XCTAssertFalse(HVFPayloadStore.status(layout: layout).updatePending)

        // Stage v2 while supervisor is live — must succeed without mutating v1 and flag updatePending
        let m2 = try HVFPayloadStore.stage(
            from: .directory(dirV2), version: "0.15.0", revision: "222222222222", layout: layout,
            verifySignature: false)
        XCTAssertEqual(m2.version, "0.15.0")
        let st = HVFPayloadStore.status(layout: layout)
        XCTAssertTrue(st.updatePending)
        XCTAssertEqual(st.runningVersion, "0.14.0")
        XCTAssertEqual(st.current?.version, "0.14.0", "v1 still boots")
        XCTAssertEqual(st.staged?.version, "0.15.0")
        XCTAssertEqual(st.knownGood?.version, "0.14.0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: v1Canonical + "/micropod-vmm"))

        // Tamper detection: committed payloads are read-only, and a changed asset fails verification.
        let stagedDir = try XCTUnwrap(st.stagedPath.map { URL(fileURLWithPath: $0) })
        let stagedKernel = stagedDir.appendingPathComponent("Image")
        let originalKernel = try Data(contentsOf: stagedKernel)
        XCTAssertThrowsError(try Data("tampered".utf8).write(to: stagedKernel), "read-only")
        XCTAssertEqual(chmod(stagedDir.path, 0o755), 0)
        XCTAssertEqual(chmod(stagedKernel.path, 0o644), 0)
        try Data("tampered".utf8).write(to: stagedKernel)
        XCTAssertThrowsError(try HVFPayloadStore.verify(payloadDirectory: stagedDir))
        try originalKernel.write(to: stagedKernel)
        try HVFPayloadStore.verify(payloadDirectory: stagedDir)

        // Stage v3 and verify prune protects current and known-good (v1, also running) and staged (v3).
        _ = try HVFPayloadStore.stage(
            from: .directory(dirV3), version: "0.16.0", revision: "333333333333", layout: layout,
            verifySignature: false)
        let prunedWhileRunning = try HVFPayloadStore.pruneVersions(layout: layout, keep: 1)
        XCTAssertEqual(prunedWhileRunning, ["0.15.0-222222222222"], "replaced while staged, never booted")

        // Release supervisor lock: v1 is still current and known-good, so it stays.
        lock.release()
        XCTAssertEqual(try HVFPayloadStore.pruneVersions(layout: layout, keep: 1), [])

        // Already on known-good: rollback changes nothing, however often it is repeated.
        let rolled = try await HVFPayloadStore.rollback(layout: layout)
        XCTAssertEqual(rolled.action, .noop)
        XCTAssertEqual(rolled.toVersion, "0.14.0 (0.14.0-111111111111)")
        XCTAssertEqual(HVFPayloadStore.status(layout: layout).current?.version, "0.14.0")
    }

    func testSandboxResolvesStandaloneAndHVFWithoutAppleContainer() throws {
        let fm = FileManager.default
        let sbxRoot = tmp.appendingPathComponent("sandbox-root")
        let missingApple = tmp.appendingPathComponent("missing-apple-container")
        let hvfRoot = tmp.appendingPathComponent("hvf-fallback")
        try fm.createDirectory(at: hvfRoot, withIntermediateDirectories: true)
        try Data("hvf-kernel".utf8).write(to: hvfRoot.appendingPathComponent("Image"))

        // 1. With no com.apple.container and no standalone sandbox kernel, falls back to Micropod's HVF kernel
        let hvfResolved = SandboxVM.resolveKernel(
            environment: [:], sandboxRoot: sbxRoot, legacyAppSupport: missingApple,
            hvfLayout: HVFMachineLayout(root: hvfRoot))
        XCTAssertEqual(hvfResolved?.origin, .hvfFallback)
        let statusHVF = SandboxVM.assetStatus(
            environment: [:], sandboxRoot: sbxRoot, legacyAppSupport: missingApple,
            hvfLayout: HVFMachineLayout(root: hvfRoot))
        XCTAssertTrue(statusHVF.standaloneReady)
        XCTAssertEqual(statusHVF.contentOrigin, .standalone)

        // 2. Standalone ~/.micropod/sandbox/kernels/default.kernel-arm64 wins over legacy com.apple.container
        let legacyApple = tmp.appendingPathComponent("legacy-apple")
        try fm.createDirectory(at: legacyApple.appendingPathComponent("kernels"), withIntermediateDirectories: true)
        try Data("apple-kernel".utf8).write(to: legacyApple.appendingPathComponent("kernels/default.kernel-arm64"))
        // Staged (and recorded) by setup: an unrecorded file there is not trusted.
        let standaloneSource = tmp.appendingPathComponent("standalone.kernel")
        try Data("standalone-kernel".utf8).write(to: standaloneSource)
        try SandboxVM.stageStandaloneKernel(
            explicit: standaloneSource, sandboxRoot: sbxRoot, environment: [:], legacyAppSupport: legacyApple,
            hvfLayout: HVFMachineLayout(root: hvfRoot), packagedExecutable: nil, progress: { _ in })

        let standalone = SandboxVM.resolveKernel(
            environment: [:], sandboxRoot: sbxRoot, legacyAppSupport: legacyApple,
            hvfLayout: HVFMachineLayout(root: hvfRoot))
        XCTAssertEqual(standalone?.origin, .standalone)

        // 3. Explicit MICROPOD_SANDBOX_KERNEL wins over everything
        let customKernel = tmp.appendingPathComponent("custom.kernel")
        try Data("custom".utf8).write(to: customKernel)
        let envWin = SandboxVM.resolveKernel(
            environment: ["MICROPOD_SANDBOX_KERNEL": customKernel.path], sandboxRoot: sbxRoot,
            legacyAppSupport: legacyApple, hvfLayout: HVFMachineLayout(root: hvfRoot))
        XCTAssertEqual(envWin?.origin, .envOverride)
    }

    func testRuntimeModeAliasesAndAutoEnableInstalledHVF() async throws {
        XCTAssertEqual(EngineRegistry.canonicalName("container"), "hvf")
        XCTAssertEqual(EngineRegistry.canonicalName("containers"), "hvf")
        XCTAssertEqual(EngineRegistry.canonicalName("isolated"), "sandbox")
        XCTAssertEqual(EngineRegistry.canonicalName("microvm"), "sandbox")
        XCTAssertEqual(RuntimeMode(engineName: "hvf"), .container)
        XCTAssertEqual(RuntimeMode(engineName: "sandbox"), .sandbox)
        XCTAssertNil(RuntimeMode(engineName: "apple"))

        // An installed HVF root auto-enables hvf without requiring `runtime enable hvf`
        let hvfRoot = tmp.appendingPathComponent("installed-hvf")
        let layout = HVFMachineLayout(root: hvfRoot)
        let bundle = try makeFakeBundle(name: "installed-bundle", tag: "v1", appLayout: false)
        _ = try HVFPayloadStore.stage(
            from: .directory(bundle), version: "0.14.0", revision: "abcdef123456", layout: layout,
            verifySignature: false)
        try Data(repeating: 0, count: 2048).write(to: layout.disk)
        XCTAssertFalse(HVFMachineClient(layout: layout).status().installed, "a staged payload is not installed yet")
        // The activation boots and probes it (a machine stand-in here), then makes it current.
        let machine = FakeUpdateMachine(layout: layout)
        let activated = try await HVFPayloadStore.activate(
            layout: layout,
            environment: HVFUpdateEnvironment(machine: machine, drain: FakeDrain(), probe: FakeProbe(machine: machine)))
        XCTAssertEqual(activated.action, .activated)

        let cfgURL = tmp.appendingPathComponent("runtimes.json")
        let reg = EngineRegistry(
            environment: [
                "MICROPOD_RUNTIMES_CONFIG": cfgURL.path,
                "MICROPOD_HVF_ROOT": hvfRoot.path,
                "MICROPOD_DEFAULT_RUNTIME": "container",
            ],
            sandbox: SandboxEngine(root: tmp.appendingPathComponent("sbx")))
        XCTAssertEqual(reg.defaultName, "hvf")
        XCTAssertEqual(reg.activeMode, .container)
        XCTAssertTrue(reg.isEnabled("hvf"))
    }
}
