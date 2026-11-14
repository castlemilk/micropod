import Foundation
import XCTest

@testable import MicropodCore

@MainActor
final class ManagedRuntimeInstallerTests: XCTestCase {
    func testCorruptPackageCannotStageOrSelectARuntime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("corrupt.pkg")
        try Data("not a signed package".utf8).write(to: package)
        do {
            _ = try await ManagedRuntimeInstaller(root: root).prepare(package: package)
            XCTFail("Corrupt package accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("integrity")) }
        XCTAssertNil(try ManagedRuntimeLocation.selection(at: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("versions").path))
    }

    func testOfficialSignedPackageStagesWithoutChangingSelectedRuntime() async throws {
        guard let path = ProcessInfo.processInfo.environment["MICROPOD_APPLE_PACKAGE_TEST_PATH"] else {
            throw XCTSkip(
                "Set MICROPOD_APPLE_PACKAGE_TEST_PATH to exercise the official signed package without starting a runtime"
            )
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = ManagedRuntimeInstaller(root: root)
        let receipt = try await installer.prepare(package: URL(fileURLWithPath: path))
        XCTAssertEqual(receipt.files, AppleRuntimeRelease.payloadSHA256)
        try await installer.verify(receipt)
        XCTAssertNil(try ManagedRuntimeLocation.selection(at: root))
        let executable = root.appendingPathComponent("versions/" + receipt.selection.directoryName + "/bin/container")
        let version = try await ContainerCLIClient(executableURL: executable).run(.init(arguments: ["--version"]))
        XCTAssertTrue(version.contains("1.5.0"), version)
        let offline = ManagedRuntimeInstaller(root: root, download: { _ in throw URLError(.notConnectedToInternet) })
        let repaired = try await offline.prepare()
        XCTAssertNotEqual(receipt.selection.directoryName, repaired.selection.directoryName)
        try await offline.verify(repaired)
        XCTAssertNil(try ManagedRuntimeLocation.selection(at: root))
        if ProcessInfo.processInfo.environment["MICROPOD_MANAGED_ISOLATED_WORKLOAD"] == "1" {
            let id = "mp-accept-" + UUID().uuidString.lowercased()
            let output = try await ContainerCLIClient(executableURL: executable).run(
                .init(arguments: [
                    "run", "--rm", "--name", id, "--cpus", "1", "--memory", "256M",
                    "docker.io/library/alpine:3.19", "/bin/echo", "micropod-managed-package-ok",
                ]), timeout: .seconds(90))
            XCTAssertTrue(output.contains("micropod-managed-package-ok"), output)
            let containers = try await ContainerService(client: ContainerCLIClient(executableURL: executable)).list()
            XCTAssertFalse(containers.contains { $0.id == id }, "Acceptance container must remove itself")
        }
        try Data("tampered".utf8).write(to: executable)
        do {
            try await installer.verify(receipt)
            XCTFail("Tampered runtime accepted")
        } catch {}
    }

    func testCancellationBeforeStagingCannotSelectRuntime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task {
            try Task.checkCancellation()
            return try await ManagedRuntimeInstaller(root: root).prepare()
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled preparation succeeded")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertNil(try ManagedRuntimeLocation.selection(at: root))
    }

    func testOfflineDownloadWithoutCacheCannotSelectOrPartiallyInstallRuntime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = ManagedRuntimeInstaller(root: root, download: { _ in throw URLError(.notConnectedToInternet) })
        do {
            _ = try await installer.prepare()
            XCTFail("Offline download succeeded")
        } catch let error as URLError { XCTAssertEqual(error.code, .notConnectedToInternet) }
        XCTAssertNil(try ManagedRuntimeLocation.selection(at: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("versions").path))
        let staging = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("staging").path)
        XCTAssertTrue(staging.isEmpty)
    }

    func testPermissionDenialDoesNotInvokeDownloadOrChangeSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o500])
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let installer = ManagedRuntimeInstaller(
            root: root,
            download: { _ in
                XCTFail("Download began without a private staging directory")
                throw URLError(.unknown)
            })
        do {
            _ = try await installer.prepare()
            XCTFail("Read-only destination accepted")
        } catch {}
        XCTAssertNil(try ManagedRuntimeLocation.selection(at: root))
    }

    func testOfficialPinnedNetworkDownloadStagesAndCachesRuntime() async throws {
        guard ProcessInfo.processInfo.environment["MICROPOD_APPLE_NETWORK_TEST"] == "1" else {
            throw XCTSkip("Set MICROPOD_APPLE_NETWORK_TEST=1 for the pinned production downloader")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = ManagedRuntimeInstaller(root: root)
        let receipt = try await installer.prepare()
        try await installer.verify(receipt)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("packages/" + AppleRuntimeRelease.supported.packageSHA256 + ".pkg")
                    .path))
        XCTAssertNil(try ManagedRuntimeLocation.selection(at: root))
    }
}
