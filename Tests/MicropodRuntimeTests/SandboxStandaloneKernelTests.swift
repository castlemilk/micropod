import Containerization
import ContainerizationOCI
import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// A standalone sandbox boots Micropod's own kernel. The com.apple.container
/// kernel is used only with MICROPOD_LEGACY_APPLE=1, and `sandbox setup`
/// never copies it into the standalone store.
final class SandboxStandaloneKernelTests: XCTestCase {
    private var tmp: URL!
    private var sandboxRoot: URL { tmp.appendingPathComponent("sandbox") }
    private var apple: URL { tmp.appendingPathComponent("com.apple.container") }
    private var hvfRoot: URL { tmp.appendingPathComponent("hvf") }
    private let appleBytes = Data("apple-container-kernel-6.18".utf8)
    private let micropodBytes = Data("micropod-hvf-kernel-7.3.5".utf8)

    override func setUp() {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sbx-kernel-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Apple's layout: a versioned kernel and the `default.kernel-arm64` link to it.
    private func installAppleKernel() throws {
        let kernels = apple.appendingPathComponent("kernels")
        try FileManager.default.createDirectory(at: kernels, withIntermediateDirectories: true)
        try appleBytes.write(to: kernels.appendingPathComponent("vmlinux-6.18.35-197"))
        try FileManager.default.createSymbolicLink(
            atPath: kernels.appendingPathComponent("default.kernel-arm64").path,
            withDestinationPath: "vmlinux-6.18.35-197")
    }

    private func installMicropodKernel() throws {
        try FileManager.default.createDirectory(at: hvfRoot, withIntermediateDirectories: true)
        try micropodBytes.write(to: hvfRoot.appendingPathComponent("Image"))
    }

    /// What `sandbox setup` did before: a copy of Apple's kernel, linked as
    /// the standalone default, with no source record.
    private func seedStoreWithAppleCopy() throws {
        let kernels = sandboxRoot.appendingPathComponent("kernels")
        try FileManager.default.createDirectory(at: kernels, withIntermediateDirectories: true)
        try appleBytes.write(to: kernels.appendingPathComponent("vmlinux-arm64"))
        try FileManager.default.createSymbolicLink(
            atPath: kernels.appendingPathComponent("default.kernel-arm64").path, withDestinationPath: "vmlinux-arm64")
    }

    private func resolve(_ environment: [String: String] = [:]) -> (url: URL, origin: SandboxVM.AssetOrigin)? {
        SandboxVM.resolveKernel(
            environment: environment, sandboxRoot: sandboxRoot, legacyAppSupport: apple,
            hvfLayout: HVFMachineLayout(root: hvfRoot), packagedExecutable: nil)
    }

    private func stage(_ explicit: URL? = nil, _ environment: [String: String] = [:]) throws {
        try SandboxVM.stageStandaloneKernel(
            explicit: explicit, sandboxRoot: sandboxRoot, environment: environment, legacyAppSupport: apple,
            hvfLayout: HVFMachineLayout(root: hvfRoot), packagedExecutable: nil, progress: { _ in })
    }

    private var stagedBytes: Data? {
        try? Data(contentsOf: sandboxRoot.appendingPathComponent("kernels/default.kernel-arm64"))
    }

    func testMicropodsKernelIsPreferredOverApples() throws {
        try installAppleKernel()
        try installMicropodKernel()
        let resolved = try XCTUnwrap(resolve())
        XCTAssertEqual(resolved.origin, .hvfFallback)
        XCTAssertEqual(try Data(contentsOf: resolved.url), micropodBytes)
    }

    func testApplesKernelIsUsedOnlyWithTheLegacyFlag() throws {
        try installAppleKernel()
        XCTAssertNil(resolve())
        XCTAssertNil(resolve(["MICROPOD_LEGACY_APPLE": "0"]))
        let legacy = try XCTUnwrap(resolve(["MICROPOD_LEGACY_APPLE": "1"]))
        XCTAssertEqual(legacy.origin, .legacyApple)
        XCTAssertEqual(try Data(contentsOf: legacy.url), appleBytes)
    }

    /// With the Apple kernel present, status never reports it as the
    /// sandbox's kernel unless asked to.
    func testStatusDoesNotReportTheAppleKernelWhenItIsPresent() throws {
        try installAppleKernel()
        try installMicropodKernel()
        let status = SandboxVM.assetStatus(
            environment: [:], sandboxRoot: sandboxRoot, legacyAppSupport: apple,
            hvfLayout: HVFMachineLayout(root: hvfRoot), packagedExecutable: nil)
        XCTAssertEqual(status.kernelOrigin, .hvfFallback)
        XCTAssertNotEqual(status.kernelOrigin, .legacyApple)
        XCTAssertTrue(status.standaloneReady)
        XCTAssertEqual(status.vminit, SandboxVM.defaultVMInitReference)

        try FileManager.default.removeItem(at: hvfRoot)
        let bare = SandboxVM.assetStatus(
            environment: [:], sandboxRoot: sandboxRoot, legacyAppSupport: apple,
            hvfLayout: HVFMachineLayout(root: hvfRoot), packagedExecutable: nil)
        XCTAssertEqual(bare.kernelOrigin, .missing)
        XCTAssertFalse(bare.standaloneReady)
    }

    func testSetupStagesMicropodsKernelAndRecordsItsSource() throws {
        try installAppleKernel()
        try installMicropodKernel()
        try stage()
        XCTAssertEqual(stagedBytes, micropodBytes)
        let record = try XCTUnwrap(SandboxVM.kernelSource(sandboxRoot: sandboxRoot))
        XCTAssertEqual(record.origin, "hvf")
        XCTAssertEqual(record.path, hvfRoot.appendingPathComponent("Image").resolvingSymlinksInPath().path)
        XCTAssertEqual(record.sha256, try HVFPayloadStore.sha256File(hvfRoot.appendingPathComponent("Image")))
        XCTAssertEqual(resolve()?.origin, .standalone)
        let status = SandboxVM.assetStatus(
            environment: [:], sandboxRoot: sandboxRoot, legacyAppSupport: apple,
            hvfLayout: HVFMachineLayout(root: hvfRoot), packagedExecutable: nil)
        XCTAssertEqual(status.kernelSource, record)
    }

    /// Before, setup copied the Apple kernel here as the "standalone" one.
    func testSetupNeverCopiesTheAppleKernelAndSaysWhatItNeeds() throws {
        try installAppleKernel()
        XCTAssertThrowsError(try stage()) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("Micropod's own HVF kernel"), message)
            XCTAssertTrue(message.contains(HVFMachineLayout(root: hvfRoot).kernel.path), message)
            XCTAssertTrue(message.contains("micropod machine install"), message)
            XCTAssertTrue(message.contains("--kernel"), message)
            XCTAssertTrue(message.contains("MICROPOD_LEGACY_APPLE=1"), message)
        }
        XCTAssertNil(stagedBytes)
        // Not even when legacy booting is allowed: that boots it in place.
        XCTAssertThrowsError(try stage(nil, ["MICROPOD_LEGACY_APPLE": "1"]))
        XCTAssertNil(stagedBytes)
    }

    func testSetupRefusesAnExplicitAppleKernelOrACopyOfIt() throws {
        try installAppleKernel()
        let inPlace = apple.appendingPathComponent("kernels/default.kernel-arm64")
        XCTAssertThrowsError(try stage(inPlace)) { XCTAssertTrue("\($0)".contains("com.apple.container kernel")) }
        let copy = tmp.appendingPathComponent("copied-kernel")
        try appleBytes.write(to: copy)
        XCTAssertThrowsError(try stage(copy)) { XCTAssertTrue("\($0)".contains("com.apple.container kernel")) }
        XCTAssertNil(stagedBytes)

        let own = tmp.appendingPathComponent("own-kernel")
        try Data("a-kernel-the-user-built".utf8).write(to: own)
        try stage(own)
        XCTAssertEqual(stagedBytes, Data("a-kernel-the-user-built".utf8))
        XCTAssertEqual(SandboxVM.kernelSource(sandboxRoot: sandboxRoot)?.origin, "explicit")
    }

    /// A store an earlier setup seeded from com.apple.container is Apple's
    /// kernel, not a standalone one: runs skip it, and setup replaces it.
    func testAnAppleCopyInTheStandaloneStoreIsReplaced() throws {
        try installAppleKernel()
        try installMicropodKernel()
        try seedStoreWithAppleCopy()
        XCTAssertEqual(resolve()?.origin, .hvfFallback)
        // The legacy flag allows Apple's kernel as the last resort, never
        // ahead of Micropod's: an unrecorded copy ranks after it too.
        XCTAssertEqual(resolve(["MICROPOD_LEGACY_APPLE": "1"])?.origin, .hvfFallback)
        try FileManager.default.removeItem(at: hvfRoot.appendingPathComponent("Image"))
        XCTAssertEqual(resolve(["MICROPOD_LEGACY_APPLE": "1"])?.origin, .legacyApple)
        try installMicropodKernel()

        try stage()
        XCTAssertEqual(stagedBytes, micropodBytes)
        XCTAssertEqual(SandboxVM.kernelSource(sandboxRoot: sandboxRoot)?.origin, "hvf")
        XCTAssertEqual(resolve()?.origin, .standalone)
    }

    func testAnAppleCopyIsRemovedEvenWithNoMicropodKernelToReplaceIt() throws {
        try installAppleKernel()
        try seedStoreWithAppleCopy()
        XCTAssertThrowsError(try stage())
        XCTAssertNil(stagedBytes)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sandboxRoot.appendingPathComponent("kernels/vmlinux-arm64").path))
        XCTAssertNil(resolve())
    }

    /// A kernel staged and recorded by setup is kept. One with no record is
    /// not proven to be anything but a copy of Apple's, so it is never booted
    /// ahead of Micropod's kernel, and setup asks to stage one it can record.
    func testOnlyARecordedKernelCountsAsStandalone() throws {
        try installAppleKernel()
        let kernels = sandboxRoot.appendingPathComponent("kernels")
        try FileManager.default.createDirectory(at: kernels, withIntermediateDirectories: true)
        let custom = Data("custom-kernel".utf8)
        try custom.write(to: kernels.appendingPathComponent("default.kernel-arm64"))
        XCTAssertNil(resolve(), "unrecorded, and no Micropod kernel to fall back to")
        XCTAssertThrowsError(try stage()) { XCTAssertTrue("\($0)".contains("no record"), "\($0)") }
        XCTAssertEqual(stagedBytes, custom, "kept for the operator to restage")

        let explicit = tmp.appendingPathComponent("Image-custom")
        try custom.write(to: explicit)
        try stage(explicit)
        XCTAssertEqual(SandboxVM.kernelSource(sandboxRoot: sandboxRoot)?.origin, "explicit")
        XCTAssertEqual(resolve()?.origin, .standalone)
        try stage()
        XCTAssertEqual(stagedBytes, custom, "a recorded kernel is kept")
    }

    /// The byte compare with Apple's install proves nothing once that
    /// install changed: a copy an earlier setup made of an older Apple
    /// kernel is still not booted ahead of Micropod's, and setup replaces it.
    func testAnAppleCopyIsNotBootedAfterApplesKernelChanged() throws {
        try seedStoreWithAppleCopy()  // the copy of 6.18; Apple's install now has none
        try installMicropodKernel()
        XCTAssertEqual(resolve()?.origin, .hvfFallback)
        XCTAssertEqual(resolve()?.url.lastPathComponent, "Image")
        try stage()
        XCTAssertEqual(stagedBytes, micropodBytes)
        XCTAssertEqual(resolve()?.origin, .standalone)
    }

    /// A record vouches only for the file it was written for: one replaced
    /// since (an older CLI copying Apple's kernel over it) is not trusted.
    func testARecordThatNoLongerMatchesTheStagedKernelIsNotTrusted() throws {
        try installAppleKernel()
        try installMicropodKernel()
        try stage()
        XCTAssertEqual(resolve()?.origin, .standalone)
        let staged = sandboxRoot.appendingPathComponent("kernels/vmlinux-arm64")
        try FileManager.default.removeItem(at: staged)
        try appleBytes.write(to: staged)
        XCTAssertNotNil(SandboxVM.kernelSource(sandboxRoot: sandboxRoot), "the record is still there")
        XCTAssertEqual(resolve()?.origin, .hvfFallback)
        try stage()
        XCTAssertEqual(stagedBytes, micropodBytes)
        XCTAssertEqual(resolve()?.origin, .standalone)
        // A record from before the stat fields still verifies by digest.
        var record = try XCTUnwrap(SandboxVM.kernelSource(sandboxRoot: sandboxRoot))
        record.size = nil
        record.inode = nil
        record.modifiedNanoseconds = nil
        try JSONEncoder().encode(record).write(to: SandboxVM.kernelSourceURL(sandboxRoot: sandboxRoot))
        XCTAssertEqual(resolve()?.origin, .standalone)
    }

    /// The `vmlinux-hvf` shipped in the app (or beside a standalone CLI) is
    /// Micropod's kernel too, before any machine is installed.
    func testThePackagedKernelIsMicropodsOwn() throws {
        let app = tmp.appendingPathComponent("Micropod.app/Contents")
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        let cli = app.appendingPathComponent("MacOS/micropod-cli")
        try Data().write(to: cli)
        try micropodBytes.write(to: app.appendingPathComponent("Resources/vmlinux-hvf"))
        let packaged = SandboxVM.micropodKernel(
            environment: [:], hvfLayout: HVFMachineLayout(root: hvfRoot), packagedExecutable: cli)
        XCTAssertEqual(packaged, app.appendingPathComponent("Resources/vmlinux-hvf").resolvingSymlinksInPath())

        let flat = tmp.appendingPathComponent("dist")
        try FileManager.default.createDirectory(at: flat, withIntermediateDirectories: true)
        try Data().write(to: flat.appendingPathComponent("micropod"))
        try micropodBytes.write(to: flat.appendingPathComponent("vmlinux-hvf"))
        XCTAssertEqual(
            SandboxVM.micropodKernel(
                environment: [:], hvfLayout: HVFMachineLayout(root: hvfRoot),
                packagedExecutable: flat.appendingPathComponent("micropod")),
            flat.appendingPathComponent("vmlinux-hvf").resolvingSymlinksInPath())
        XCTAssertNil(
            SandboxVM.micropodKernel(
                environment: [:], hvfLayout: HVFMachineLayout(root: hvfRoot), packagedExecutable: nil))
    }

    /// The whole setup with a registry fake that serves the pinned digest.
    func testSetupStagesTheKernelAndThePinnedInitfs() async throws {
        try installAppleKernel()
        try installMicropodKernel()
        let content = try LocalContentStore(path: tmp.appendingPathComponent("content"))
        let pinned = Containerization.Image(
            description: .init(
                reference: SandboxVM.pinnedVMInit.pullReference,
                descriptor: Descriptor(mediaType: MediaTypes.index, digest: SandboxVM.pinnedVMInit.digest, size: 306)),
            contentStore: content)
        let source = SandboxVM.VMInitSource(
            list: { [] }, pull: { _ in pinned }, remove: { _ in },
            unpack: { _, path in try Data("initfs".utf8).write(to: path) })
        let status = try await SandboxVM.setupStandalone(
            kernelSource: nil, vminitReference: SandboxVM.defaultVMInitReference, sandboxRoot: sandboxRoot,
            environment: [:], legacyAppSupport: apple, hvfLayout: HVFMachineLayout(root: hvfRoot),
            packagedExecutable: nil, vminitSource: source, progress: { _ in })
        XCTAssertEqual(status.kernelOrigin, .standalone)
        XCTAssertEqual(status.kernelSource?.origin, "hvf")
        XCTAssertTrue(status.standaloneReady)
        let initfs = sandboxRoot.appendingPathComponent(
            "initfs-\(SandboxVM.pinnedVMInit.digest.replacingOccurrences(of: ":", with: "-")).ext4")
        XCTAssertEqual(status.initfsPaths, [initfs.path])
        XCTAssertEqual(try Data(contentsOf: initfs), Data("initfs".utf8))
    }
}
