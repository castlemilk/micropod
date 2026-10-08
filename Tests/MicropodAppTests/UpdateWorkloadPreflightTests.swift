import Foundation
import MicropodCore
import XCTest

@testable import MicropodApp

@MainActor
final class UpdateWorkloadPreflightTests: XCTestCase {
    func testOnlyObservedTerminalStatesPass() {
        XCTAssertTrue(UpdateWorkloadPreflight.hasNoObservedWork(states: []))
        XCTAssertTrue(UpdateWorkloadPreflight.hasNoObservedWork(states: ["stopped", "exited"]))
        for state in ["running", "created", "starting", "stopping", "paused", "", "unknown", "STOPPED"] {
            XCTAssertFalse(UpdateWorkloadPreflight.hasNoObservedWork(states: ["stopped", state]), state)
        }
    }

    func testResponseFailureAndMalformedOrMissingStateFailClosed() throws {
        XCTAssertFalse(UpdateWorkloadPreflight.hasNoObservedWork(data: Data("{}".utf8), response: response(503)))
        XCTAssertFalse(UpdateWorkloadPreflight.hasNoObservedWork(data: Data("broken".utf8), response: response()))
        XCTAssertFalse(
            UpdateWorkloadPreflight.hasNoObservedWork(data: Data("{\"containers\":[{}]}".utf8), response: response()))
        XCTAssertFalse(
            UpdateWorkloadPreflight.hasNoObservedWork(
                data: Data("{\"error\":\"unavailable\"}".utf8), response: response()))
        XCTAssertFalse(
            UpdateWorkloadPreflight.hasNoObservedWork(
                data: Data("{}".utf8),
                response: URLResponse(url: endpoint, mimeType: nil, expectedContentLength: 2, textEncodingName: nil)))
        XCTAssertFalse(
            UpdateWorkloadPreflight.hasNoObservedWork(
                data: Data(repeating: 32, count: 1024 * 1024 + 1), response: response()))
    }

    func testSuccessfulEmptyAndTerminalResponses() throws {
        XCTAssertTrue(UpdateWorkloadPreflight.hasNoObservedWork(data: Data("{}".utf8), response: response()))
        var list = Micropod_V1_ListContainersResponse()
        var container = Micropod_V1_Container()
        container.state = "stopped"
        list.containers = [container]
        XCTAssertTrue(UpdateWorkloadPreflight.hasNoObservedWork(data: try list.jsonUTF8Data(), response: response()))
        container.state = "starting"
        list.containers = [container]
        XCTAssertFalse(UpdateWorkloadPreflight.hasNoObservedWork(data: try list.jsonUTF8Data(), response: response()))
    }

    func testConnectionTimeoutAndInterruptedReadsFailClosed() async {
        for failure in [URLError.timedOut, .cannotConnectToHost, .networkConnectionLost, .cancelled] {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FailedPreflightProtocol.self]
            configuration.httpAdditionalHeaders = ["X-Test-Failure": String(failure.rawValue)]
            let session = URLSession(configuration: configuration)
            let result = await UpdateWorkloadPreflight.readLocalAPI(session: session)
            session.invalidateAndCancel()
            XCTAssertFalse(result, String(describing: failure))
        }
    }

    func testLocalUncertaintyPreventsAPIRead() async {
        let store = makeObservedStore(client: AppTestCLI.makeFailing())
        var reads = 0
        store.clientAvailable = false
        let missingClient = await store.nothingRunning {
            reads += 1
            return true
        }
        XCTAssertFalse(missingClient)
        store.clientAvailable = true
        store.systemStatus = nil
        let missingRuntime = await store.nothingRunning {
            reads += 1
            return true
        }
        XCTAssertFalse(missingRuntime)
        var status = Micropod_V1_SystemStatus()
        status.status = "running"
        store.systemStatus = status
        store.lastRefreshError = "unavailable"
        let failedState = await store.nothingRunning {
            reads += 1
            return true
        }
        XCTAssertFalse(failedState)
        XCTAssertEqual(reads, 0)
    }

    func testUnavailableAPIBlocksEvenWithEmptyLocalSnapshot() async {
        let store = makeObservedStore(client: AppTestCLI.makeFailing())
        let idle = await store.nothingRunning { false }
        XCTAssertFalse(idle)
    }

    func testUnobservedLocalInventoryDoesNotAuthorizeRestart() async {
        let store = makeRunningStore(client: AppTestCLI.makeFailing())
        var reads = 0
        let idle = await store.nothingRunning {
            reads += 1
            return true
        }
        XCTAssertFalse(idle)
        XCTAssertEqual(reads, 0)
    }

    func testPendingOperationDuringAPIReadBlocksRestart() async {
        let store = makeObservedStore(client: AppTestCLI.makeFailing())
        let idle = await store.nothingRunning {
            _ = store.operationRegistry.begin("Pending container start", kind: .container)
            return true
        }
        XCTAssertFalse(idle)
    }

    func testJobAppearingDuringAPIReadBlocksRestart() async {
        let store = makeObservedStore(client: AppTestCLI.makeFailing())
        let idle = await store.nothingRunning {
            var job = Micropod_V1_Container()
            job.state = "starting"
            store.containers = [job]
            return true
        }
        XCTAssertFalse(idle)
    }

    func testConcurrentJobAdmissionWhileReadIsSuspendedBlocksRestart() async throws {
        let store = makeObservedStore(client: AppTestCLI.makeFailing())
        var reply: CheckedContinuation<Bool, Never>?
        let read = Task { @MainActor in
            await store.nothingRunning {
                await withCheckedContinuation { reply = $0 }
            }
        }
        try await waitUntil { reply != nil }
        var job = Micropod_V1_Container()
        job.state = "created"
        store.containers = [job]
        reply?.resume(returning: true)
        let idle = await read.value
        XCTAssertFalse(idle)
    }

    func testRuntimeFailureDuringAPIReadBlocksRestart() async {
        let store = makeObservedStore(client: AppTestCLI.makeFailing())
        let idle = await store.nothingRunning {
            store.lastRefreshError = "connection lost"
            return true
        }
        XCTAssertFalse(idle)
    }

    func testCancellationDoesNotAuthorizeRestart() async {
        let store = makeObservedStore(client: AppTestCLI.makeFailing())
        let task = Task { @MainActor in
            await store.nothingRunning {
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            }
        }
        let idle = await task.value
        XCTAssertFalse(idle)
    }

    func testFailedReadCanRecoverWithoutStoppingWork() async {
        let store = makeObservedStore(client: AppTestCLI.makeFailing())
        let failed = await store.nothingRunning { false }
        XCTAssertFalse(failed)
        let recovered = await store.nothingRunning { true }
        XCTAssertTrue(recovered)
    }

    private func makeObservedStore(client: ContainerCLIClient) -> AppStore {
        let store = makeRunningStore(client: client)
        store.recordObservedTransitions(from: [], to: [])
        return store
    }

    private var endpoint: URL { URL(string: "http://127.0.0.1:45454/")! }

    private func response(_ status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

private final class FailedPreflightProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let raw = Int(request.value(forHTTPHeaderField: "X-Test-Failure") ?? "") ?? URLError.unknown.rawValue
        client?.urlProtocol(self, didFailWithError: URLError(URLError.Code(rawValue: raw)))
    }
    override func stopLoading() {}
}
