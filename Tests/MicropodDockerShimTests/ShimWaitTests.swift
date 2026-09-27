import Foundation
import XCTest

@testable import MicropodCore
@testable import MicropodDockerShim
@testable import MicropodRuntime

/// `POST /containers/{id}/wait` against scripted runtime answers: a container
/// that vanishes ends the wait at once, whatever shape the backend gives its
/// not-found, and a runtime that cannot inspect the container fails the wait
/// after a bounded run of failures instead of polling forever.
final class ShimWaitTests: XCTestCase {
    /// `ContainerServing` whose `inspect` replays a script: each call takes
    /// the next step and the last step repeats. Nothing else is scripted.
    final actor ScriptedInspect: ContainerServing {
        enum Step: Sendable {
            case state(String)
            case fail(MicropodError)
        }

        private let id: String
        private let script: [Step]
        private(set) var inspectCalls = 0

        init(id: String, _ script: [Step]) {
            self.id = id
            self.script = script
        }

        func inspect(_ id: String) async throws -> Data {
            let step = script[min(inspectCalls, script.count - 1)]
            inspectCalls += 1
            switch step {
            case .state(let state):
                let entry: [String: Any] = [
                    "id": self.id,
                    "configuration": ["id": self.id],
                    "status": ["state": state, "startedDate": "2026-09-26T00:00:00Z"],
                ]
                return try JSONSerialization.data(withJSONObject: [entry])
            case .fail(let error):
                throw error
            }
        }

        func list() async throws -> [Micropod_V1_Container] { [] }
        func create(_ request: ContainerRunRequest) async throws -> String { throw MicropodError.message("unused") }
        func run(_ request: ContainerRunRequest) async throws -> String { throw MicropodError.message("unused") }
        func exec(_ request: ContainerExecRequest) async throws -> String { throw MicropodError.message("unused") }
        func start(_ id: String) async throws {}
        func stop(_ id: String, timeout: Int) async throws {}
        func restart(_ id: String) async throws {}
        func stopAll() async throws {}
        func kill(_ id: String, signal: String) async throws {}
        func delete(_ id: String, force: Bool) async throws {}
        func deleteAll(force: Bool) async throws {}
        func prune() async throws -> String { "" }
        func export(_ id: String, to outputPath: String) async throws {}
        func copy(from: String, to: String) async throws {}
    }

    private var stateDirs: [URL] = []

    override func tearDown() async throws {
        for dir in stateDirs { try? FileManager.default.removeItem(at: dir) }
    }

    /// A runtime id the shim passes straight through (no list resolution).
    private func runtimeID() -> String { UUID().uuidString.lowercased() }

    private func shim(
        _ containers: ScriptedInspect, configure: (inout ShimConfig) -> Void = { _ in }
    ) throws -> ShimTestSupport.MockShim {
        let shim = try ShimTestSupport.makeMockShim(
            extraEnv: [:], containers: containers, configure: configure)
        stateDirs.append(shim.stateDir)
        return shim
    }

    private func waitBody(_ response: RawHTTPClient.Response) throws -> [String: Any] {
        XCTAssertEqual(response.status, 200)
        let text = String(decoding: response.body, as: UTF8.self)
        guard let body = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw XCTFailure("wait body is not a JSON object: \(text)")
        }
        return body
    }

    // MARK: - Not-found classification

    func testIsNotFoundReadsEveryBackendsShape() {
        // Native backend: its own inspect miss, and the apiserver's XPC error
        // for a container that is gone (the autoremove path logs this one).
        XCTAssertTrue(Router.isNotFound(NativeContainerService.containerNotFound("cf-attempt-1")))
        XCTAssertTrue(Router.isNotFound(MicropodError.message("notFound: container with ID cf-attempt-1 not found")))
        // CLI backend: the coded line and cause, the bare 1.3.1 phrasing, the mock.
        XCTAssertTrue(
            Router.isNotFound(
                MicropodError.cliFailure(
                    command: "container delete x", exitCode: 1,
                    stderr:
                        "Error: internalError: \"failed to delete container\" (cause: \"notFound: \"container with ID x not found\"\")"
                )))
        XCTAssertTrue(
            Router.isNotFound(
                MicropodError.cliFailure(
                    command: "container inspect x", exitCode: 1, stderr: "Error: container not found: x\n")))
        XCTAssertTrue(
            Router.isNotFound(
                MicropodError.cliFailure(
                    command: "container inspect x", exitCode: 1, stderr: "Error: no such container: x\n")))
        // Outages are not absences.
        XCTAssertFalse(Router.isNotFound(MicropodError.transport("connection interrupted")))
        XCTAssertFalse(Router.isNotFound(MicropodError.cliTimeout(command: "container inspect x")))
        XCTAssertFalse(Router.isNotFound(MicropodError.message("internalError: failed to bootstrap container")))
    }

    // MARK: - Wait

    /// The live hang: the container is deleted while `/wait` polls it and the
    /// native backend answers its own not-found, which the shim used to read
    /// as a transient error and retry every 200 ms forever.
    func testWaitEndsWhenTheNativeBackendReportsTheContainerGone() throws {
        let id = runtimeID()
        let containers = ScriptedInspect(
            id: id,
            [.state("running"), .state("running"), .fail(NativeContainerService.containerNotFound(id))])
        let shim = try shim(containers) { $0.waitPollInterval = .milliseconds(20) }

        let started = Date()
        let response = try shim.raw().request("POST", "/containers/\(id)/wait", timeout: 8)
        let body = try waitBody(response)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the wait must end promptly")
        XCTAssertEqual(body["StatusCode"] as? Int, 0)
        XCTAssertNil(body["Error"], "a vanished container is not a failed wait: \(body)")
    }

    /// Every inspect fails with an outage: the wait fails after the
    /// configured run of consecutive failures, with Docker's `Error.Message`
    /// body and a non-zero code — never a phantom exit 0, never a hang.
    func testWaitFailsAfterABoundedRunOfInspectFailures() async throws {
        let id = runtimeID()
        let containers = ScriptedInspect(
            id: id, [.state("running"), .fail(.transport("connection interrupted"))])
        let shim = try shim(containers) {
            $0.waitPollInterval = .milliseconds(20)
            $0.waitInspectFailureLimit = 3
        }

        let response = try shim.raw().request("POST", "/containers/\(id)/wait", timeout: 8)
        let body = try waitBody(response)
        XCTAssertNotEqual(body["StatusCode"] as? Int, 0, "\(body)")
        let message = (body["Error"] as? [String: Any])?["Message"] as? String
        XCTAssertTrue(
            message?.contains("connection interrupted") == true, "Docker's Error.Message names the cause: \(body)")
        // The first inspect succeeded; exactly the limit failed after it.
        let calls = await containers.inspectCalls
        XCTAssertEqual(calls, 4)
        try await Task.sleep(for: .milliseconds(200))
        let later = await containers.inspectCalls
        XCTAssertEqual(later, calls, "the wait stops polling once it has failed")
    }

    /// Slow failures (each inspect takes its full timeout) are bounded by the
    /// failure window rather than the count.
    func testWaitFailsOnceInspectFailuresOutlastTheWindow() throws {
        let id = runtimeID()
        let containers = ScriptedInspect(
            id: id, [.state("running"), .fail(.cliTimeout(command: "container inspect \(id)"))])
        let shim = try shim(containers) {
            $0.waitPollInterval = .milliseconds(50)
            $0.waitInspectFailureLimit = 10_000
            $0.waitInspectFailureWindow = .milliseconds(300)
        }

        let started = Date()
        let response = try shim.raw().request("POST", "/containers/\(id)/wait", timeout: 8)
        let body = try waitBody(response)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertNotNil((body["Error"] as? [String: Any])?["Message"] as? String, "\(body)")
    }

    /// The live corruption: the docker CLI exits (its start was refused)
    /// while its `/wait` still polls. The wait used to go on polling, then
    /// write its body to the departed client's fd — by then the next
    /// client's, which read `{"StatusCode":0}` ahead of its own response
    /// ("Unsolicited response", "malformed HTTP version"). A wait whose
    /// client has gone stops polling and writes nothing.
    func testAWaitWhoseClientDisconnectedStopsPollingAndWritesNothing() async throws {
        let id = runtimeID()
        // Running for 25 polls, then an exit to report.
        let containers = ScriptedInspect(
            id: id, Array(repeating: .state("running"), count: 25) + [.state("stopped")])
        let shim = try shim(containers) { $0.waitPollInterval = .milliseconds(20) }

        let leaving = shim.raw()
        try leaving.connectForHijack()
        try leaving.writeRaw(
            Data(
                ("POST /containers/\(id)/wait?condition=next-exit HTTP/1.1\r\nHost: d\r\n"
                    + "Content-Length: 0\r\n\r\n").utf8))
        let head = try leaving.readUntil(timeout: 5) { $0.range(of: Data("\r\n\r\n".utf8)) != nil }
        XCTAssertTrue(String(decoding: head, as: UTF8.self).hasPrefix("HTTP/1.1 200"), "the wait's headers come first")
        leaving.close()
        try await Task.sleep(for: .milliseconds(150))

        // The next client: the shim's accept(2) hands it the lowest free fd,
        // the one the departed wait's connection had.
        let next = shim.raw()
        try next.connectForHijack()
        let pollsAtDisconnect = await containers.inspectCalls
        // Well past the poll at which the script reports the exit.
        try await Task.sleep(for: .milliseconds(1_200))
        let polls = await containers.inspectCalls
        XCTAssertLessThanOrEqual(
            polls - pollsAtDisconnect, 1, "the wait must stop polling once its client has gone")
        XCTAssertLessThan(polls, 26, "the wait must never reach the scripted exit")

        let unsolicited = String(decoding: try next.readUntil(timeout: 0.3) { !$0.isEmpty }, as: UTF8.self)
        XCTAssertTrue(unsolicited.isEmpty, "the next client must not receive the departed wait's body: \(unsolicited)")
        try next.writeRaw(Data("GET /_ping HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n".utf8))
        let ping = try RawHTTPClient.parseResponse(try next.readUntilClose(timeout: 5))
        XCTAssertEqual(ping.status, 200)
        XCTAssertEqual(String(decoding: ping.body, as: UTF8.self), "OK\n")
    }

    /// dockerd answers a wait on a container it does not have with 404,
    /// before any headers.
    func testWaitOnAContainerThatIsAlreadyGoneIs404() throws {
        let id = runtimeID()
        let containers = ScriptedInspect(id: id, [.fail(NativeContainerService.containerNotFound(id))])
        let shim = try shim(containers)

        let response = try shim.raw().request("POST", "/containers/\(id)/wait", timeout: 8)
        XCTAssertEqual(response.status, 404, String(decoding: response.body, as: UTF8.self))
    }
}
