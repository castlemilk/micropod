import Foundation
import XCTest

final class MandatoryFixtureTests: XCTestCase {
    func testMissingExecutableFailsInsteadOfSkipping() {
        XCTAssertThrowsError(try requireFixtureExecutable(URL(fileURLWithPath: "/missing/fixture"), name: "API")) {
            error in
            XCTAssertTrue(error is MandatoryFixtureError)
            XCTAssertFalse(error is XCTSkip)
            XCTAssertTrue(String(describing: error).contains("prerequisite"))
        }
    }

    func testMissingMockFailsInsteadOfSkipping() {
        XCTAssertThrowsError(try MockContainerCLI.makeClient(script: URL(fileURLWithPath: "/missing/mock"))) { error in
            XCTAssertTrue(error is MandatoryFixtureError)
            XCTAssertFalse(error is XCTSkip)
            XCTAssertTrue(String(describing: error).contains("mock container CLI"))
        }
    }

    func testDirectoryIsNotAnExecutableFixture() {
        XCTAssertThrowsError(try requireFixtureExecutable(FileManager.default.temporaryDirectory, name: "directory"))
    }

    func testCheckedInMockIsExecutable() throws {
        try requireFixtureExecutable(MockContainerCLI.scriptURL, name: "mock container CLI")
    }

    func testPrematureExitFailsWithStatusBeforeProbing() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/false")
        try process.run()
        addTeardownBlock { await process.stopBounded() }
        let deadline = ContinuousClock.now + .seconds(2)
        while process.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(process.isRunning)
        var probes = 0
        do {
            try await waitForMandatoryFixture(process, name: "failed fixture", timeout: .seconds(1)) {
                probes += 1
                return true
            }
            XCTFail("Exited fixture must not pass readiness")
        } catch {
            XCTAssertTrue(error is MandatoryFixtureError)
            XCTAssertTrue(String(describing: error).contains("status=1"))
            XCTAssertEqual(probes, 0)
        }
    }

    func testReadinessTimeoutFailsWithoutSkipping() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        addTeardownBlock { await process.stopBounded() }
        do {
            try await waitForMandatoryFixture(
                process, name: "unready fixture", timeout: .milliseconds(30), pollInterval: .milliseconds(5)
            ) { false }
            XCTFail("Unready fixture must fail")
        } catch {
            XCTAssertTrue(error is MandatoryFixtureError)
            XCTAssertFalse(error is XCTSkip)
            XCTAssertTrue(String(describing: error).contains("readiness timed out"))
        }
        await process.stopBounded()
        XCTAssertFalse(process.isRunning)
    }

    func testReadyLiveFixturePasses() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        addTeardownBlock { await process.stopBounded() }
        try await waitForMandatoryFixture(process, name: "ready fixture", timeout: .seconds(1)) { true }
        await process.stopBounded()
        XCTAssertFalse(process.isRunning)
    }

    func testProbeReturningReadyAfterDeadlineFails() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        addTeardownBlock { await process.stopBounded() }
        do {
            try await waitForMandatoryFixture(process, name: "late fixture", timeout: .milliseconds(10)) {
                try? await Task.sleep(for: .milliseconds(30))
                return true
            }
            XCTFail("Late readiness must fail")
        } catch {
            XCTAssertTrue(error is MandatoryFixtureError)
            XCTAssertTrue(String(describing: error).contains("readiness timed out"))
        }
    }

    func testExitDuringProbeCannotBeMaskedByReadyResponse() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        addTeardownBlock { await process.stopBounded() }
        do {
            try await waitForMandatoryFixture(process, name: "exiting fixture", timeout: .seconds(2)) {
                await process.stopBounded(grace: .seconds(1))
                return true
            }
            XCTFail("A dead owned child must fail even when a probe says ready")
        } catch {
            XCTAssertTrue(error is MandatoryFixtureError)
            XCTAssertTrue(String(describing: error).contains("exited during readiness"))
        }
    }

}
