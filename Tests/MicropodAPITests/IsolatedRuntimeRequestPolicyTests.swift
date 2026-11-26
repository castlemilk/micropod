import XCTest

@testable import MicropodAPI

final class IsolatedRuntimeRequestPolicyTests: XCTestCase {
    func testPrivateDataCannotRetargetAnEngineOrInvokeLifecycleThroughProcedureAliases() {
        for method in ["ListRuntimes", "SetDefaultRuntime", "UpdateRuntime", "ApplyUpdate"] {
            for service in ["SystemService", "ContainerService"] {
                XCTAssertFalse(IsolatedRuntimeRequestPolicy.allows("/api/micropod.v1.\(service)/\(method)"))
            }
        }
        for path in [
            "/v1/runtimes", "/v1/runtimes/docker", "/v1/system/runtime/start", "/v1/system/runtime/stop",
            "/v1/system/update/apply",
        ] {
            XCTAssertFalse(IsolatedRuntimeRequestPolicy.allows(path), path)
        }
        // The rig's aliases: SetRigMode writes the default runtime as
        // SetDefaultRuntime does; the machine's payload and lifecycle.
        for method in [
            "GetRigMode", "SetRigMode", "GetHVFUpdateStatus", "ApplyHVFUpdate", "RollbackHVFUpdate", "ControlMachine",
        ] {
            for service in ["RigService", "SystemService"] {
                XCTAssertFalse(
                    IsolatedRuntimeRequestPolicy.allows("/api/micropod.v1.\(service)/\(method)"), "\(service)/\(method)"
                )
            }
        }
        for path in ["/v1/rig/mode", "/v1/rig/hvf/update", "/v1/rig/hvf/update/rollback", "/v1/rig/hvf/link-socket"] {
            XCTAssertFalse(IsolatedRuntimeRequestPolicy.allows(path), path)
        }
        for path in [
            "/api/micropod.v1.RigService/GetRigHealth", "/api/micropod.v1.RigService/GetMachineStatus",
            "/v1/rig/health", "/v1/rig/modes",
            "/api/micropod.v1.SystemService/Ping", "/api/micropod.v1.SystemService/GetSystem",
            "/api/micropod.v1.ContainerService/CreateContainer", "/v1/managed/cli", "/v1/managed/maintenance",
        ] {
            XCTAssertTrue(IsolatedRuntimeRequestPolicy.allows(path), path)
        }
    }
}
