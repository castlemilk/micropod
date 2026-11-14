import Foundation
import XCTest

@testable import MicropodCore

final class ManagedRuntimeControlTests: XCTestCase {
    func testUnknownActionNeverReachesAuthority() async throws {
        do {
            _ = try await ManagedRuntimeControl.request("session") { _ in
                XCTFail("A lifecycle argument requested an API capability")
                return IsolatedRuntimeStatus()
            }
            XCTFail("An unsupported action was accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Unknown managed runtime action"))
        }
    }
    func testRestartSubmitsOnceWithoutDesktopApp() async throws {
        let calls = Requests()
        let result = try await ManagedRuntimeControl.request("restart") { request in
            await calls.append(request)
            var status = IsolatedRuntimeStatus(phase: "draining", message: "Waiting for current work")
            status.operation = request.operation
            status.action = request.action
            return status
        }
        let recorded = await calls.values
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.action, .restart)
        XCTAssertEqual(recorded.first?.operation, result.operation)
        XCTAssertEqual(result.phase, "draining")
    }

    func testRefusalFailsWithoutReplay() async throws {
        let calls = Requests()
        do {
            _ = try await ManagedRuntimeControl.request("stop") { request in
                await calls.append(request)
                var status = IsolatedRuntimeStatus(phase: "blocked", message: "Runtime request was refused")
                status.error = "A managed runtime operation is already running"
                return status
            }
            XCTFail("A refused stop must fail the CLI command")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("already running"))
        }
        let recorded = await calls.values
        XCTAssertEqual(recorded.count, 1)
    }

    func testOperationReportsRetainedFailureWithoutMutatingIt() async throws {
        let result = try await ManagedRuntimeControl.request("operation") { request in
            XCTAssertEqual(request.action, .status)
            var status = IsolatedRuntimeStatus(phase: "recoveryRequired", message: "Verify the retained operation")
            status.error = "Native readiness is unconfirmed"
            return status
        }
        XCTAssertEqual(result.error, "Native readiness is unconfirmed")
    }

    func testRecoveryVerifiesInsteadOfReplayingAction() async throws {
        let result = try await ManagedRuntimeControl.request("recover") { request in
            XCTAssertEqual(request.action, .verify)
            var status = IsolatedRuntimeStatus(phase: "recovering", message: "Verifying retained operation")
            status.action = .restart
            status.error = "Previous response was lost"
            return status
        }
        XCTAssertEqual(result.phase, "recovering")
    }

    private actor Requests {
        var values: [IsolatedRuntimeRequest] = []
        func append(_ value: IsolatedRuntimeRequest) { values.append(value) }
    }
}
