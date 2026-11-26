import Containerization
import ContainerizationOCI
import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// The sandbox boots exactly the vminit its pin names: the linked
/// Containerization release's tag, verified by digest, never whatever the
/// tag or another vminit in the store resolves to today.
final class SandboxVMInitTests: XCTestCase {
    private let repository = "ghcr.io/apple/containerization/vminit"
    private let pinned = SandboxVM.pinnedVMInit.digest
    private let substituted = "sha256:" + String(repeating: "ab", count: 32)
    private var tmp: URL!

    override func setUp() {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vminit-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func image(_ reference: String, digest: String) throws -> Containerization.Image {
        Containerization.Image(
            description: .init(
                reference: reference, descriptor: Descriptor(mediaType: MediaTypes.index, digest: digest, size: 306)),
            contentStore: try LocalContentStore(path: tmp.appendingPathComponent("content")))
    }

    /// `linkedContainerizationVersion` is the version Package.swift pins.
    func testLinkedVersionMatchesPackageSwift() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let text = try String(contentsOf: package, encoding: .utf8)
        XCTAssertTrue(
            text.contains(
                #"containerization.git", exact: "\#(SandboxVM.linkedContainerizationVersion)""#),
            "Package.swift pins another Containerization release than SandboxVM.linkedContainerizationVersion")
    }

    /// The pin records the linked release's tag and the digest it named,
    /// together; the pull names the digest alone.
    func testPinRecordsTheLinkedTagWithItsDigest() {
        let pin = SandboxVM.pinnedVMInit
        XCTAssertEqual(pin.repository, repository)
        XCTAssertEqual(pin.tag, SandboxVM.linkedContainerizationVersion)
        XCTAssertTrue(SandboxVM.VMInitPin.isDigest(pin.digest), pin.digest)
        XCTAssertEqual(
            SandboxVM.defaultVMInitReference,
            "\(repository):\(SandboxVM.linkedContainerizationVersion)@\(pin.digest)")
        XCTAssertEqual(pin.pullReference, "\(repository)@\(pin.digest)")
        XCTAssertEqual(try SandboxVM.VMInitPin(parsing: SandboxVM.defaultVMInitReference), pin)
    }

    func testAReferenceWithoutADigestIsRefused() {
        for raw in [
            "\(repository):0.42.0", repository, "\(repository):0.42.0@sha256:abc",
            "\(repository)@sha256:" + String(repeating: "AB", count: 32), "@\(pinned)", "\(repository)@\(pinned)@x",
        ] {
            XCTAssertThrowsError(try SandboxVM.VMInitPin(parsing: raw), raw) { error in
                XCTAssertTrue("\(error)".contains("must be pinned by digest"), "\(raw): \(error)")
            }
        }
        let untagged = try? SandboxVM.VMInitPin(parsing: "\(repository)@\(pinned)")
        XCTAssertEqual(untagged?.tag, nil)
        XCTAssertEqual(untagged?.reference, "\(repository)@\(pinned)")
        // A Docker Hub short name is normalized like every other sandbox image.
        XCTAssertEqual(try? SandboxVM.VMInitPin(parsing: "vminit:1@\(pinned)").repository, "docker.io/library/vminit")
    }

    /// Runs boot the compiled pin, or an override that is itself pinned.
    func testRunsBootThePinOrAPinnedOverride() throws {
        XCTAssertEqual(try SandboxVM.vminitPin(environment: [:]), SandboxVM.pinnedVMInit)
        XCTAssertEqual(try SandboxVM.vminitPin(environment: ["MICROPOD_SANDBOX_VMINIT": ""]), SandboxVM.pinnedVMInit)
        let other = "\(repository):0.47.0@\(substituted)"
        XCTAssertEqual(try SandboxVM.vminitPin(environment: ["MICROPOD_SANDBOX_VMINIT": other]).digest, substituted)
        XCTAssertThrowsError(try SandboxVM.vminitPin(environment: ["MICROPOD_SANDBOX_VMINIT": "\(repository):0.47.0"]))
    }

    /// Only the digest selects a stored image: the pinned tag with another
    /// digest, or another vminit release, is never booted in its place.
    func testStoredVMInitMatchesByDigestOnly() {
        let pin = SandboxVM.pinnedVMInit
        let retagged = (reference: "\(repository):0.42.0", digest: substituted)
        let newer = (reference: "\(repository):0.47.0", digest: "sha256:" + String(repeating: "cd", count: 32))
        let byDigest = (reference: pin.pullReference, digest: pinned)
        XCTAssertNil(SandboxVM.storedVMInit([retagged, newer], pin: pin))
        XCTAssertNil(SandboxVM.storedVMInit([], pin: pin))
        XCTAssertEqual(SandboxVM.storedVMInit([newer, retagged, byDigest], pin: pin), pin.pullReference)
        XCTAssertEqual(
            SandboxVM.storedVMInit([(reference: "\(repository):0.42.0", digest: pinned)], pin: pin),
            "\(repository):0.42.0")
    }

    func testAStoredPinnedImageIsUsedWithoutAPull() async throws {
        let stored = try image("\(repository):0.42.0", digest: pinned)
        let pulled = VMInitRecorder()
        let chosen = try await SandboxVM.verifiedVMInit(
            pin: SandboxVM.pinnedVMInit, list: { [stored] },
            pull: { reference in
                await pulled.add(reference)
                throw MicropodError.message("unexpected pull")
            },
            remove: { _ in }, progress: { _ in })
        XCTAssertEqual(chosen.digest, pinned)
        let pulls = await pulled.values
        XCTAssertEqual(pulls, [])
    }

    /// A registry fake that answers the pinned digest with another image (as
    /// a moved tag or a hostile registry would) is refused, and its image is
    /// removed from the store; the pull itself names only the digest.
    func testARegistryServingAnotherDigestIsRefused() async throws {
        let retagged = try image("\(repository):0.42.0", digest: substituted)
        let pulls = VMInitRecorder()
        let removed = VMInitRecorder()
        let fake = try image(SandboxVM.pinnedVMInit.pullReference, digest: substituted)
        do {
            _ = try await SandboxVM.verifiedVMInit(
                pin: SandboxVM.pinnedVMInit, list: { [retagged] },
                pull: { reference in
                    await pulls.add(reference)
                    return fake
                },
                remove: { await removed.add($0) }, progress: { _ in })
            XCTFail("a substituted vminit was accepted")
        } catch {
            XCTAssertTrue("\(error)".contains("vminit digest mismatch"), "\(error)")
            XCTAssertTrue("\(error)".contains(substituted), "\(error)")
        }
        let pulled = await pulls.values
        let deleted = await removed.values
        XCTAssertEqual(pulled, [SandboxVM.pinnedVMInit.pullReference])
        XCTAssertEqual(deleted, [SandboxVM.pinnedVMInit.pullReference])
    }

    func testAPullCarryingThePinnedDigestIsAccepted() async throws {
        let good = try image(SandboxVM.pinnedVMInit.pullReference, digest: pinned)
        let chosen = try await SandboxVM.verifiedVMInit(
            pin: SandboxVM.pinnedVMInit, list: { [] }, pull: { _ in good }, remove: { _ in }, progress: { _ in })
        XCTAssertEqual(chosen.digest, pinned)
    }

    /// `sandbox setup` against the registry fake fails, and leaves no initfs
    /// built from what it was sent.
    func testSetupFailsWhenTheRegistryServesAnotherDigestUnderTheTag() async throws {
        let sandboxRoot = tmp.appendingPathComponent("sandbox")
        let kernel = tmp.appendingPathComponent("Image")
        try Data("micropod-kernel".utf8).write(to: kernel)
        let fake = try image(SandboxVM.pinnedVMInit.pullReference, digest: substituted)
        let unpacked = VMInitRecorder()
        let source = SandboxVM.VMInitSource(
            list: { [] }, pull: { _ in fake }, remove: { _ in },
            unpack: { image, _ in await unpacked.add(image.digest) })
        do {
            _ = try await SandboxVM.setupStandalone(
                kernelSource: kernel, vminitReference: nil, sandboxRoot: sandboxRoot, environment: [:],
                legacyAppSupport: tmp.appendingPathComponent("no-apple"), hvfLayout: nil, packagedExecutable: nil,
                vminitSource: source, progress: { _ in })
            XCTFail("setup accepted a substituted vminit")
        } catch {
            XCTAssertTrue("\(error)".contains("vminit digest mismatch"), "\(error)")
        }
        let unpacks = await unpacked.values
        XCTAssertEqual(unpacks, [])
        let initfs = (try FileManager.default.contentsOfDirectory(atPath: sandboxRoot.path)).filter {
            $0.contains("initfs")
        }
        XCTAssertEqual(initfs, [])
    }

    /// Without `--vminit` (the CLI passes nil), setup prepares the vminit
    /// runs will boot: MICROPOD_SANDBOX_VMINIT's, not the built-in pin.
    func testSetupWithoutAReferencePreparesTheVMInitRunsBoot() async throws {
        let sandboxRoot = tmp.appendingPathComponent("sandbox")
        let kernel = tmp.appendingPathComponent("Image")
        try Data("micropod-kernel".utf8).write(to: kernel)
        let override = "\(repository):0.47.0@\(substituted)"
        let pin = try SandboxVM.VMInitPin(parsing: override)
        let served = try image(pin.pullReference, digest: substituted)
        let pulled = VMInitRecorder()
        let unpacked = VMInitRecorder()
        let source = SandboxVM.VMInitSource(
            list: { [] },
            pull: { reference in
                await pulled.add(reference)
                return served
            }, remove: { _ in },
            unpack: { image, path in
                await unpacked.add(image.digest)
                try Data("initfs".utf8).write(to: path)
            })
        _ = try await SandboxVM.setupStandalone(
            kernelSource: kernel, vminitReference: nil, sandboxRoot: sandboxRoot,
            environment: ["MICROPOD_SANDBOX_VMINIT": override],
            legacyAppSupport: tmp.appendingPathComponent("no-apple"), hvfLayout: nil, packagedExecutable: nil,
            vminitSource: source, progress: { _ in })
        let pulls = await pulled.values
        XCTAssertEqual(pulls, [pin.pullReference])
        let unpacks = await unpacked.values
        XCTAssertEqual(unpacks, [substituted])
    }

    func testSetupRefusesAnUnpinnedVMInitBeforeStagingAnything() async throws {
        let sandboxRoot = tmp.appendingPathComponent("sandbox")
        let kernel = tmp.appendingPathComponent("Image")
        try Data("micropod-kernel".utf8).write(to: kernel)
        let source = SandboxVM.VMInitSource(
            list: { [] }, pull: { _ in throw MicropodError.message("unexpected pull") }, remove: { _ in },
            unpack: { _, _ in })
        do {
            _ = try await SandboxVM.setupStandalone(
                kernelSource: kernel, vminitReference: "\(repository):0.42.0", sandboxRoot: sandboxRoot,
                environment: [:], legacyAppSupport: tmp.appendingPathComponent("no-apple"), hvfLayout: nil,
                packagedExecutable: nil, vminitSource: source, progress: { _ in })
            XCTFail("setup accepted a tag-only vminit")
        } catch {
            XCTAssertTrue("\(error)".contains("must be pinned by digest"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandboxRoot.appendingPathComponent("kernels").path))
    }
}

/// Collects values from `@Sendable` closures under test.
actor VMInitRecorder {
    private(set) var values: [String] = []
    func add(_ value: String) { values.append(value) }
}
