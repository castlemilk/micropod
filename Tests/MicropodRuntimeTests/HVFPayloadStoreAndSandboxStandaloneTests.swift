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
        try? FileManager.default.removeItem(at: tmp)
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

        // Stage v1 from .app bundle
        let m1 = try HVFPayloadStore.stage(
            from: .directory(appV1), version: "0.14.0", revision: "111111111111", layout: layout,
            verifySignature: false)
        XCTAssertEqual(m1.version, "0.14.0")
        XCTAssertEqual(m1.digests.count, 5)
        XCTAssertEqual(layout.vmm.deletingLastPathComponent().lastPathComponent, "0.14.0-111111111111")
        try HVFPayloadStore.verify(payloadDirectory: layout.activePayloadRoot)

        // Simulate a live supervisor holding supervisor.lock on v1
        try FileManager.default.createDirectory(at: layout.runDirectory, withIntermediateDirectories: true)
        let lock = try XCTUnwrap(try HVFFileLock.acquire(layout.supervisorLock, wait: .zero))
        defer { lock.release() }
        let v1Canonical = HVFMachineLayout.canonicalPath(layout.activePayloadRoot.path)
        try HVFMachineState(
            phase: .running, supervisorPID: getpid(), loadedPayloadPath: v1Canonical,
            loadedPayloadVersion: "0.14.0", loadedPayloadRevision: "111111111111"
        ).save(to: layout.state)

        // Stage v2 while supervisor is live — must succeed without mutating v1 and flag updatePending
        let m2 = try HVFPayloadStore.stage(
            from: .directory(dirV2), version: "0.15.0", revision: "222222222222", layout: layout,
            verifySignature: false)
        XCTAssertEqual(m2.version, "0.15.0")
        let st = HVFPayloadStore.status(layout: layout)
        XCTAssertTrue(st.updatePending)
        XCTAssertEqual(st.runningVersion, "0.14.0")
        XCTAssertEqual(st.current?.version, "0.15.0")
        XCTAssertEqual(st.previous?.version, "0.14.0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: v1Canonical + "/micropod-vmm"))

        // Tamper detection
        let currentKernel = layout.kernel
        let originalKernel = try Data(contentsOf: currentKernel)
        try Data("tampered".utf8).write(to: currentKernel)
        XCTAssertThrowsError(try HVFPayloadStore.verify(payloadDirectory: layout.activePayloadRoot))
        try originalKernel.write(to: currentKernel)
        try HVFPayloadStore.verify(payloadDirectory: layout.activePayloadRoot)

        // Stage v3 and verify prune protects current (v3), previous (v2), and live runningPath (v1)
        _ = try HVFPayloadStore.stage(
            from: .directory(dirV3), version: "0.16.0", revision: "333333333333", layout: layout,
            verifySignature: false)
        let prunedWhileRunning = HVFPayloadStore.pruneVersions(layout: layout, keep: 1)
        XCTAssertTrue(prunedWhileRunning.isEmpty, "v1 is running, v2 is previous, v3 is current — none may be pruned")

        // Release supervisor lock: now v1 is no longer running and can be pruned, and rollback switches back to v2
        lock.release()
        let prunedAfterStop = HVFPayloadStore.pruneVersions(layout: layout, keep: 1)
        XCTAssertEqual(prunedAfterStop, ["0.14.0-111111111111"])

        let rolled = try await HVFPayloadStore.rollback(layout: layout)
        XCTAssertEqual(rolled.action, .rolledBack)
        XCTAssertEqual(rolled.toVersion, "0.15.0")
        XCTAssertEqual(HVFPayloadStore.status(layout: layout).current?.version, "0.15.0")
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
        try fm.createDirectory(at: sbxRoot.appendingPathComponent("kernels"), withIntermediateDirectories: true)
        try Data("standalone-kernel".utf8).write(to: sbxRoot.appendingPathComponent("kernels/default.kernel-arm64"))

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

    func testRuntimeModeAliasesAndAutoEnableInstalledHVF() throws {
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
