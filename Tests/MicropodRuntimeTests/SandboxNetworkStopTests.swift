import Synchronization
import XCTest
import vmnet

@testable import MicropodRuntime

final class SandboxNetworkStopTests: XCTestCase {
    func testConcurrentWaitersShareOneConfirmedStop() {
        let stop = SandboxNetworkStopConfirmation()
        let calls = Mutex(0)
        let errors = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            do {
                try stop.stop { complete in
                    calls.withLock { $0 += 1 }
                    DispatchQueue.global().async { complete(.VMNET_SUCCESS) }
                    return .VMNET_SUCCESS
                }
            } catch { errors.withLock { $0 += 1 } }
        }
        XCTAssertEqual(calls.withLock { $0 }, 1)
        XCTAssertEqual(errors.withLock { $0 }, 0)
    }

    func testLateCallbackSettlesTimeoutWithoutReplayingStop() throws {
        let stop = SandboxNetworkStopConfirmation(timeout: .milliseconds(0))
        var callback: (@Sendable (vmnet_return_t) -> Void)?
        XCTAssertThrowsError(
            try stop.stop { complete in
                callback = complete
                return .VMNET_SUCCESS
            })
        callback?(.VMNET_SUCCESS)
        try stop.stop { _ in
            XCTFail("stop was replayed")
            return .VMNET_FAILURE
        }
    }

    func testRefusedStopCannotBecomeSuccessful() {
        let stop = SandboxNetworkStopConfirmation(timeout: .milliseconds(0))
        var callback: (@Sendable (vmnet_return_t) -> Void)?
        XCTAssertThrowsError(
            try stop.stop { complete in
                callback = complete
                return .VMNET_FAILURE
            })
        callback?(.VMNET_SUCCESS)
        XCTAssertThrowsError(
            try stop.stop { _ in
                XCTFail("refused stop was replayed")
                return .VMNET_SUCCESS
            })
    }
}
