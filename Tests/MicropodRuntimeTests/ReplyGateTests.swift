import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// `ReplyGate` is what makes XPC timeouts real: whichever of reply, timer
/// or cancellation lands first resumes the call, exactly once.
final class ReplyGateTests: XCTestCase {
    private func message(_ route: String) -> XPCMessage { XPCMessage(route: route) }

    func testReplyFirstWinsAndLateTimeoutIsDropped() async throws {
        let gate = ReplyGate()
        let reply = message("reply")
        let got = try await withCheckedThrowingContinuation { cont in
            gate.arm(cont)
            gate.finish { reply }
            gate.finish { throw MicropodError.message("late timeout") }
        }
        XCTAssertEqual(got.string(key: XPCMessage.routeKey), "reply")
    }

    func testTimeoutFirstWinsAndLateReplyIsDropped() async {
        let gate = ReplyGate()
        do {
            _ = try await withCheckedThrowingContinuation { cont in
                gate.arm(cont)
                gate.finish { throw MicropodError.message("XPC timeout for svc/route") }
                gate.finish { self.message("late reply") }
            }
            XCTFail("timeout should have won")
        } catch {
            XCTAssertTrue("\(error)".contains("XPC timeout"))
        }
    }

    /// onCancel runs before the continuation exists for an already-cancelled
    /// task: the early outcome must be parked and delivered on arm.
    func testOutcomeBeforeArmIsDeliveredOnArm() async {
        let gate = ReplyGate()
        gate.finish { throw CancellationError() }
        do {
            _ = try await withCheckedThrowingContinuation { cont in gate.arm(cont) }
            XCTFail("expected the parked cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    /// The bug this replaced: a timeout that never fired because the call
    /// waited for an uncancellable reply. A reply that never comes must not
    /// hold the caller past the timer.
    func testNeverAnsweredCallReturnsAtTimeout() async {
        let gate = ReplyGate()
        let started = ContinuousClock.now
        do {
            _ = try await withCheckedThrowingContinuation { cont in
                gate.arm(cont)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                    gate.finish { throw MicropodError.message("XPC timeout for svc/route") }
                }
                // No reply is ever delivered.
            }
            XCTFail("expected timeout")
        } catch {
            XCTAssertLessThan(started.duration(to: .now), .seconds(2))
        }
    }

    /// A timed-out runtime call is a deadline, not an internal error —
    /// clients retry `deadline_exceeded`, they don't for `internal`.
    func testTimeoutMapsToDeadlineExceeded() {
        let error = MicropodError.message(
            "deadlineExceeded: XPC timeout for com.apple.container.apiserver/containerStats")
        XCTAssertEqual(ConnectCodeMapping.code(for: error), "deadline_exceeded")
    }
}
