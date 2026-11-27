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

    func testExplicitManagedSelectionPrecedesDiscoveredExternalCLI() {
        let managed = URL(fileURLWithPath: "/managed/bin/container")
        XCTAssertEqual(
            ContainerExecutableLocator.resolve(
                environment: ["PATH": "/custom/bin", "MICROPOD_RUNTIME_CONTEXT": "managed"],
                managedExecutable: { managed }, isExecutable: { _ in true }),
            managed)
        XCTAssertFalse(
            ContainerCLIClient(executableURL: URL(fileURLWithPath: "/custom/bin/container")).usesManagedLifecycle)
    }

    func testInstallingManagedRuntimeDoesNotRetargetExistingClientsOrConfiguredRig() {
        let managed = URL(fileURLWithPath: "/managed/bin/container")
        XCTAssertEqual(
            ContainerExecutableLocator.resolve(
                environment: [:], defaultDirectories: ["/legacy/bin"], managedExecutable: { managed },
                hasConfiguredRig: { false }, isExecutable: { $0 == "/legacy/bin/container" }
            ).path,
            "/legacy/bin/container")
        XCTAssertEqual(
            ContainerExecutableLocator.resolve(
                environment: [:], defaultDirectories: [],
                managedExecutable: {
                    XCTFail("An unavailable prior runtime must not silently switch stores")
                    return managed
                }, hasConfiguredRig: { true }, isExecutable: { _ in false }
            ).path,
            "/usr/local/bin/container")
        XCTAssertEqual(
            ContainerExecutableLocator.resolve(
                environment: [:], defaultDirectories: [], managedExecutable: { managed },
                hasConfiguredRig: { false }, isExecutable: { _ in false }), managed)
    }

    func testExplicitContextsFailClosedAndPrivateServiceUsesOnlyManagedSelection() {
        for context in ["existing", "managed", "misspelled"] {
            let resolved = ContainerExecutableLocator.resolve(
                environment: ["MICROPOD_RUNTIME_CONTEXT": context], defaultDirectories: [],
                managedExecutable: { nil }, hasConfiguredRig: { false }, isExecutable: { _ in false })
            XCTAssertNotEqual(resolved.path, "/managed/bin/container")
            if context == "existing" { XCTAssertEqual(resolved.path, "/usr/local/bin/container") }
            if context == "managed" { XCTAssertTrue(resolved.path.contains("missing-managed-runtime")) }
            if context == "misspelled" { XCTAssertTrue(resolved.path.contains("invalid-context")) }
        }
        let managed = URL(fileURLWithPath: "/managed/bin/container")
        XCTAssertEqual(
            ContainerExecutableLocator.resolve(
                environment: ["MICROPOD_ISOLATED_RUNTIME": "1"], defaultDirectories: ["/legacy/bin"],
                managedExecutable: { managed }, hasConfiguredRig: { true }, isExecutable: { _ in true }), managed)
    }

    /// Every `ContainerCLIClient.executableURL` resolves, several times per
    /// API request, and resolving built `ProcessInfo.environment` (the
    /// whole environment as a dictionary, ~20 µs) each time: a quarter of a
    /// B25 listing. The live lookup reads only what `resolve` uses.
    func testTheLiveLookupReadsOnlyWhatResolveUsesAndIsCheap() {
        let names = ["MICROPOD_CONTAINER_CLI_PATH", "MICROPOD_RUNTIME_CONTEXT", "MICROPOD_ISOLATED_RUNTIME", "PATH"]
        let full = ProcessInfo.processInfo.environment
        XCTAssertEqual(ContainerExecutableLocator.lookupEnvironment(), full.filter { names.contains($0.key) })
        XCTAssertEqual(ContainerExecutableLocator.resolve(), ContainerExecutableLocator.resolve(environment: full))

        setenv("MICROPOD_CONTAINER_CLI_PATH", "/opt/explicit/container", 1)
        let explicit = ContainerExecutableLocator.resolve()
        unsetenv("MICROPOD_CONTAINER_CLI_PATH")
        XCTAssertEqual(explicit.path, "/opt/explicit/container", "the live environment, not a snapshot")
        XCTAssertNil(LiveEnvironment.value("MICROPOD_CONTAINER_CLI_PATH"))

        // Cost is compared with the dictionary it replaced, in this process,
        // rather than with a wall-clock bound: an unqualified `resolve()`
        // also walks PATH and reads the rig configuration when no CLI is
        // installed (a hosted CI runner), which no bound for this Mac fits.
        // With an explicit path both sides return before any of that, so
        // the difference is the environment alone.
        setenv("MICROPOD_CONTAINER_CLI_PATH", "/opt/explicit/container", 1)
        defer { unsetenv("MICROPOD_CONTAINER_CLI_PATH") }
        func fastest(_ body: () -> URL) -> Duration {
            let clock = ContinuousClock()
            return (0..<7).map { _ in
                clock.measure { for _ in 0..<500 { XCTAssertEqual(body().path, "/opt/explicit/container") } }
            }.min()!
        }
        let dictionary = fastest {
            ContainerExecutableLocator.resolve(environment: ProcessInfo.processInfo.environment)
        }
        let live = fastest { ContainerExecutableLocator.resolve() }
        XCTAssertLessThan(live * 2, dictionary, "500 live resolutions took \(live), \(dictionary) with the dictionary")
    }
}
