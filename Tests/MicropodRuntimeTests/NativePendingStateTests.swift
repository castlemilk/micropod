import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

final class NativePendingStateTests: XCTestCase {
    func testOwnedAbsentContainerRemainsPendingForLogObservation() async throws {
        for kind in [ContainerLifecycleClaims.Kind.starting, .creating] {
            let claims = ContainerLifecycleClaims()
            let claim = await claims.claimIfIdle("absent", kind: kind)
            let state = try await NativePendingState.observe(
                id: "absent", claims: claims, unstarted: { _ in false },
                read: {
                    nil
                })
            XCTAssertEqual(state, kind == .starting ? "starting" : "created")
            XCTAssertTrue(NativeLogStreamer.isLive(state: state ?? ""))
            if let claim { await claims.finish(claim) }
        }
    }

    func testStartAdmissionDuringStoppedReadRetriesBeforeEndingLogs() async throws {
        let claims = ContainerLifecycleClaims()
        let state = try await NativePendingState.observe(
            id: "race", claims: claims, unstarted: { _ in false },
            read: {
                if await claims.kind(of: "race") == nil {
                    _ = await claims.claimIfIdle("race", kind: .starting)
                }
                return "stopped"
            })
        XCTAssertEqual(state, "starting")
        XCTAssertTrue(NativeLogStreamer.isLive(state: state ?? ""))
    }

    func testStartingIsDistinctFromCreatedAndRealStopped() {
        XCTAssertEqual(NativePendingState.state("stopped", starting: true, unstarted: true), "starting")
        XCTAssertEqual(NativePendingState.state("stopped", starting: false, unstarted: true), "created")
        XCTAssertEqual(NativePendingState.state("stopped", starting: false, unstarted: false), "stopped")
        XCTAssertEqual(NativePendingState.state("running", starting: true, unstarted: true), "running")
        XCTAssertEqual(NativePendingState.state("unknown", starting: true, unstarted: true), "unknown")
    }

    func testInspectPreservesFieldsAndNormalizesBothWireShapes() async throws {
        for body in [
            #"{"id":"job","status":{"state":"stopped","startedDate":"old"},"configuration":{"id":"job","labels":{"keep":"value"}}}"#,
            #"[{"id":"job","status":{"state":"stopped"},"configuration":{"id":"job","labels":{"keep":"value"}}}]"#,
        ] {
            let data = try await NativePendingState.normalizeInspect(Data(body.utf8)) { _, raw in
                NativePendingState.state(raw, starting: true, unstarted: false)
            }
            let object = try JSONSerialization.jsonObject(with: data)
            let row = (object as? [[String: Any]])?.first ?? (object as? [String: Any])
            let unwrapped = try XCTUnwrap(row)
            XCTAssertEqual((unwrapped["status"] as? [String: Any])?["state"] as? String, "starting")
            let labels = (unwrapped["configuration"] as? [String: Any])?["labels"] as? [String: String]
            XCTAssertEqual(labels, ["keep": "value"])
        }
    }

    func testPendingStartWaitIsNotTerminal() async throws {
        let outcome = try await ContainerExitWait.wait(id: "job", timeout: .zero, exitCodes: nil) { _, _ in "starting" }
        XCTAssertEqual(outcome, .init(exited: false, known: false, exitCode: nil, state: "starting"))
    }

    func testKnownExitWinsOverPendingSnapshot() async throws {
        let exits = ExitCodeRegistry()
        await exits.track(id: "job") { 7 }
        _ = await exits.await(id: "job", timeout: .seconds(2))
        let outcome = try await ContainerExitWait.wait(id: "job", timeout: .zero, exitCodes: exits) { _, _ in "starting"
        }
        XCTAssertEqual(outcome, .init(exited: true, known: true, exitCode: 7, state: "starting"))
    }
}
