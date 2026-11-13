import Foundation
import MicropodCore
import MicropodRuntime
import XCTest

@testable import MicropodAPI

final class ManagedRuntimeControlRouteTests: XCTestCase {
    private func handlers(
        control: @escaping @Sendable (String) async throws -> IsolatedRuntimeStatus
    ) async -> APIHandlers {
        let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/usr/bin/false"))
        let services = await RuntimeBackendResolver.resolveApple(
            client: client, environment: ["MICROPOD_RUNTIME": "cli"])
        return APIHandlers(
            client: client, system: SystemService(client: client), images: ImageService(client: client),
            networks: NetworkService(client: client), compose: ComposeService(client: client),
            runtime: RuntimeHolder(initial: services, resolve: { services }, managedSelectionPresent: { false }),
            managedControl: control)
    }

    private func request(_ method: HTTPMethod, _ path: String) -> HTTPRequest {
        HTTPRequest(method: method, path: path, query: [:], body: Data(), headers: ["content-type": "application/json"])
    }

    func testStatusReadsHelperWithoutDesktopApp() async throws {
        let api = await handlers { command in
            XCTAssertEqual(command, "operation")
            var status = IsolatedRuntimeStatus(phase: "recoveryRequired", message: "Verify retained operation")
            status.error = "Previous response was lost"
            return status
        }
        guard case .json(let code, let body) = await api.handle(request(.get, "/v1/system/runtime")) else {
            return XCTFail("Missing runtime status response")
        }
        XCTAssertEqual(code, 200)
        XCTAssertEqual(body["phase"] as? String, "recoveryRequired")
        XCTAssertEqual(body["error"] as? String, "Previous response was lost")
    }

    func testRefusedMutationReturnsConflictWithoutReplay() async throws {
        let calls = Calls()
        let api = await handlers { command in
            await calls.record(command)
            throw MicropodError.message("Current work prevents stopping the runtime")
        }
        guard case .json(let code, let body) = await api.handle(request(.post, "/v1/system/runtime/stop")) else {
            return XCTFail("Missing refused operation response")
        }
        XCTAssertEqual(code, 409)
        XCTAssertEqual(body["error"] as? String, "Current work prevents stopping the runtime")
        let recorded = await calls.commands
        XCTAssertEqual(recorded, ["stop"])
    }

    func testUnknownMutationCannotReachHelper() async throws {
        let api = await handlers { _ in
            XCTFail("An unknown HTTP operation reached the helper")
            return IsolatedRuntimeStatus()
        }
        guard case .json(let code, _) = await api.handle(request(.post, "/v1/system/runtime/session")) else {
            return XCTFail("Missing invalid operation response")
        }
        XCTAssertEqual(code, 400)
    }

    private actor Calls {
        var commands: [String] = []
        func record(_ command: String) { commands.append(command) }
    }
}
