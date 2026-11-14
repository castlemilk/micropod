import Foundation
import XCTest

@testable import MicropodCore

final class ContainerExecutableLocatorTests: XCTestCase {
    func testExplicitMissingOverrideDoesNotSubstituteAnotherInstallation() {
        let url = ContainerExecutableLocator.resolve(
            environment: ["MICROPOD_CONTAINER_CLI_PATH": "/custom/missing", "PATH": "/opt/bin"],
            managedExecutable: {
                XCTFail("An explicit override must not inspect managed selection")
                return nil
            },
            isExecutable: { _ in true })
        XCTAssertEqual(url.path, "/custom/missing")
    }

    func testSearchesOfficialAndHomebrewLocationsBeforeAbsolutePATHEntries() {
        let installed: Set<String> = ["/opt/homebrew/bin/container", "/tools/bin/container"]
        let url = ContainerExecutableLocator.resolve(
            environment: ["PATH": "/tools/bin"], managedExecutable: { nil }, isExecutable: installed.contains)
        XCTAssertEqual(url.path, "/opt/homebrew/bin/container")
    }

    func testIgnoresRelativeAndEmptyPATHEntries() {
        let url = ContainerExecutableLocator.resolve(
            environment: ["PATH": ":.:relative:/custom/bin"], defaultDirectories: [],
            managedExecutable: { nil },
            isExecutable: { _ in true })
        XCTAssertEqual(url.path, "/custom/bin/container")
    }

    func testExecutableDirectoryIsNotAContainerInstallation() throws {
        let client = ContainerCLIClient(executableURL: FileManager.default.temporaryDirectory)
        XCTAssertFalse(client.isAvailable())
    }

    func testDiscoversInstallationAndRemovalWithoutCachingMissingResult() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("container")
        let resolve = {
            ContainerExecutableLocator.resolve(
                environment: ["PATH": directory.path], defaultDirectories: [], managedExecutable: { nil })
        }
        XCTAssertEqual(resolve().path, "/usr/local/bin/container")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        XCTAssertEqual(resolve().path, "/usr/local/bin/container", "A non-executable file is not an installation")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        XCTAssertEqual(resolve(), executable)
        try FileManager.default.removeItem(at: executable)
        XCTAssertEqual(resolve().path, "/usr/local/bin/container")
    }

    func testManagedSelectionPrecedesDiscoveredExternalCLI() {
        let managed = URL(fileURLWithPath: "/managed/bin/container")
        XCTAssertEqual(
            ContainerExecutableLocator.resolve(
                environment: ["PATH": "/custom/bin"], managedExecutable: { managed }, isExecutable: { _ in true }),
            managed)
        XCTAssertFalse(
            ContainerCLIClient(executableURL: URL(fileURLWithPath: "/custom/bin/container")).usesManagedLifecycle)
    }
}
