import Foundation
import XCTest

@testable import MicropodCore
@testable import MicropodRuntimeHostKit

final class RuntimeCoordinatorSessionPolicyTests: XCTestCase {
    func testExistingJobsCanRenewDuringDrainButNeverCrossAClosedOrStartedAction() {
        var state = IsolatedRuntimeStatus(phase: "draining")
        state.runtimeRigAttempted = true
        state.runtimeActionStarted = false
        XCTAssertTrue(IsolatedRuntimeHostController.sessionMayContinue(state, gateClosed: false, taskActive: true))
        XCTAssertFalse(IsolatedRuntimeHostController.sessionMayContinue(state, gateClosed: true, taskActive: true))
        state.runtimeActionStarted = true
        XCTAssertFalse(IsolatedRuntimeHostController.sessionMayContinue(state, gateClosed: false, taskActive: true))
        state.runtimeActionStarted = nil
        XCTAssertFalse(IsolatedRuntimeHostController.sessionMayContinue(state, gateClosed: false, taskActive: true))
    }

    func testOnlyPositiveCancellationAllowsDataCleanupAndNeverAnUnsettledHandoff() {
        var state = IsolatedRuntimeStatus(phase: "blocked")
        XCTAssertFalse(IsolatedRuntimeHostController.sessionMayContinue(state, gateClosed: false, taskActive: false))
        state.runtimeCancelledBeforeAction = true
        XCTAssertTrue(IsolatedRuntimeHostController.sessionMayContinue(state, gateClosed: false, taskActive: false))
        state.runtimeRigAttempted = true
        XCTAssertFalse(IsolatedRuntimeHostController.sessionMayContinue(state, gateClosed: false, taskActive: false))
        state.runtimeRigAttempted = false
        XCTAssertFalse(IsolatedRuntimeHostController.sessionMayContinue(state, gateClosed: false, taskActive: true))
    }

    func testImmutableStagingCanKeepTheExistingPrivateDataPlaneAvailable() {
        var state = IsolatedRuntimeStatus(phase: "installing")
        state.action = .install
        state.runtimeActionStarted = false
        XCTAssertTrue(IsolatedRuntimeHostController.sessionMayContinue(state, gateClosed: false, taskActive: true))
        state.action = .restart
        XCTAssertFalse(IsolatedRuntimeHostController.sessionMayContinue(state, gateClosed: false, taskActive: true))
    }
}
