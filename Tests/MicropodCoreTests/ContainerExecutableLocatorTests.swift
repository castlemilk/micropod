import Foundation
import XCTest

@testable import MicropodCore

final class ContainerExecutableLocatorTests: XCTestCase {
    func testExplicitMissingOverrideDoesNotSubstituteAnotherInstallation() {
        let url = ContainerExecutableLocator.resolve(
            environment: ["MICROPOD_CONTAINER_CLI_PATH": "/custom/missing", "PATH": "/opt/bin"],
            isExecutable: { _ in true })
        XCTAssertEqual(url.path, "/custom/missing")
    }

    func testSearchesOfficialAndHomebrewLocationsBeforeAbsolutePATHEntries() {
        let installed: Set<String> = ["/opt/homebrew/bin/container", "/tools/bin/container"]
        let url = ContainerExecutableLocator.resolve(
            environment: ["PATH": "/tools/bin"], isExecutable: installed.contains)
        XCTAssertEqual(url.path, "/opt/homebrew/bin/container")
    }

    func testIgnoresRelativeAndEmptyPATHEntries() {
        let url = ContainerExecutableLocator.resolve(
            environment: ["PATH": ":.:relative:/custom/bin"], defaultDirectories: [],
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
            ContainerExecutableLocator.resolve(environment: ["PATH": directory.path], defaultDirectories: [])
        }
        XCTAssertEqual(resolve().path, "/usr/local/bin/container")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        XCTAssertEqual(resolve().path, "/usr/local/bin/container", "A non-executable file is not an installation")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        XCTAssertEqual(resolve(), executable)
        try FileManager.default.removeItem(at: executable)
        XCTAssertEqual(resolve().path, "/usr/local/bin/container")
    }
}
