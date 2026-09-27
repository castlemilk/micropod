import Foundation
import XCTest

@testable import MicropodDockerShim

/// `/start` answers only once the runtime's start has settled: a start the
/// runtime refuses (the mock's `start-refusal` file, printed as the CLI's
/// `Error:` line) reaches the client as the start response — 409 for
/// `failedPrecondition`, the runtime's words — and a parked `docker run`
/// attach stream and a pending `/wait` end with it instead of hanging.
final class ShimStartSettleTests: XCTestCase {
    private var shim: ShimTestSupport.MockShim!

    override func setUp() async throws {
        shim = try ShimTestSupport.makeMockShim()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: shim.stateDir)
    }

    /// The RW multi-attach guard's refusal as the CLI prints it.
    private let guardRefusal =
        "failedPrecondition: \"volume 'ws' is attached read-write to running container 'job-41'\""

    /// container 1.3.1 refusing a second VM's attach of a volume image
    /// (captured live: `container start --attach` of a second container on
    /// a volume a running container holds).
    private let bootstrapRefusal =
        "failed to bootstrap container (cause: \"internalError: \"failed to bootstrap container "
        + "mpfix-ma-b (cause: \"unknown: \"Error Domain=VZErrorDomain Code=2 \"The storage device "
        + "attachment is invalid.\"\"\")\"\")"

    private func refuseStarts(with text: String) throws {
        try Data(text.utf8).write(to: shim.stateDir.appendingPathComponent("start-refusal"))
    }

    private func createContainer(_ name: String, autoRemove: Bool = false) throws -> String {
        let body: [String: Any] = [
            "Image": "alpine:3.20", "Cmd": ["sh", "-c", "echo hi"],
            "HostConfig": ["AutoRemove": autoRemove],
        ]
        let response = try shim.raw().request(
            "POST", "/containers/create?name=\(name)", body: ShimTestSupport.jsonBody(body),
            headers: [("Content-Type", "application/json")])
        XCTAssertEqual(response.status, 201, String(decoding: response.body, as: UTF8.self))
        let parsed = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
        return parsed["Id"] as! String
    }

    /// Hijacks `/attach` the way `docker run` does before it starts the
    /// container; returns the client holding the raw stream.
    private func attach(_ id: String) throws -> RawHTTPClient {
        let client = shim.raw()
        try client.connectForHijack()
        try client.writeRaw(
            Data(
                ("POST /containers/\(id)/attach?stream=1&stdout=1&stderr=1 HTTP/1.1\r\nHost: d\r\n"
                    + "Upgrade: tcp\r\nConnection: Upgrade\r\nContent-Length: 0\r\n\r\n").utf8))
        let head = try client.readUntil(timeout: 10) { $0.range(of: Data("\r\n\r\n".utf8)) != nil }
        XCTAssertTrue(String(decoding: head, as: UTF8.self).contains("101"), "attach must upgrade")
        return client
    }

    /// Issues `/wait` as the docker CLI does before `/start`: returns once
    /// the wait's headers are in (the CLI sends `/start` only then);
    /// `waited` resolves it to the wait's body once it ends.
    private func pendingWait(_ id: String, condition: String = "next-exit") async -> Task<Data?, Never> {
        let port = shim.port
        let (headers, headersIn) = AsyncStream<Void>.makeStream()
        let wait = Task.detached { () -> Data? in
            defer { headersIn.finish() }
            let client = RawHTTPClient(port: port)
            let terminator = Data("\r\n\r\n".utf8)
            guard (try? client.connectForHijack()) != nil,
                (try? client.writeRaw(
                    Data(
                        ("POST /containers/\(id)/wait?condition=\(condition) HTTP/1.1\r\nHost: d\r\n"
                            + "Connection: close\r\nContent-Length: 0\r\n\r\n").utf8))) != nil,
                let head = try? client.readUntil(timeout: 10, { $0.range(of: terminator) != nil }),
                head.range(of: terminator) != nil
            else { return nil }
            headersIn.yield()
            guard let rest = try? client.readUntilClose(timeout: 10),
                let response = try? RawHTTPClient.parseResponse(head + rest),
                response.status == 200
            else { return nil }
            return response.body
        }
        for await _ in headers { break }
        return wait
    }

    private func waited(_ wait: Task<Data?, Never>) async -> [String: Any]? {
        guard let body = await wait.value else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    private func message(_ response: RawHTTPClient.Response) -> String {
        let body = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        return body?["message"] as? String ?? String(decoding: response.body, as: UTF8.self)
    }

    private func waitError(_ body: [String: Any]?) -> String? {
        (body?["Error"] as? [String: Any])?["Message"] as? String
    }

    // MARK: - Refused starts

    func testAttachedStartTheRuntimeRefusesIs409AndEndsTheStreamAndTheWait() async throws {
        let id = try createContainer("settle-guard")
        let stream = try attach(id)
        let wait = await pendingWait(id)
        try refuseStarts(with: guardRefusal)

        let start = try shim.raw().request("POST", "/containers/\(id)/start")
        XCTAssertEqual(start.status, 409, message(start))
        XCTAssertTrue(message(start).contains("attached read-write to running container 'job-41'"), message(start))

        // The parked stream ends now, carrying nothing: the refusal was the
        // CLI's, not the container's output.
        let began = Date()
        let rest = try stream.readUntilClose(timeout: 8)
        XCTAssertLessThan(Date().timeIntervalSince(began), 5, "the attach stream must end with the refusal")
        XCTAssertFalse(String(decoding: rest, as: UTF8.self).contains("attached read-write"))

        let waited = await waited(wait)
        XCTAssertNotNil(waited, "the pending wait must end")
        XCTAssertNotEqual(waited?["StatusCode"] as? Int, 0, "\(String(describing: waited))")
        XCTAssertTrue(waitError(waited)?.contains("attached read-write") == true, "\(String(describing: waited))")
    }

    func testAttachedStartRefusedAtBootstrapIs500WithTheRuntimesMessage() async throws {
        let id = try createContainer("settle-bootstrap")
        let stream = try attach(id)
        let wait = await pendingWait(id)
        try refuseStarts(with: bootstrapRefusal)

        let start = try shim.raw().request("POST", "/containers/\(id)/start")
        XCTAssertEqual(start.status, 500, message(start))
        XCTAssertTrue(message(start).contains("The storage device attachment is invalid."), message(start))
        _ = try stream.readUntilClose(timeout: 8)
        let waited = await waited(wait)
        XCTAssertTrue(waitError(waited)?.contains("storage device attachment") == true, "\(String(describing: waited))")
    }

    func testDetachedStartTheRuntimeRefusesIs409() throws {
        let id = try createContainer("settle-detached")
        try refuseStarts(with: guardRefusal)

        let start = try shim.raw().request("POST", "/containers/\(id)/start")
        XCTAssertEqual(start.status, 409, message(start))
        XCTAssertTrue(message(start).contains("attached read-write"), message(start))
    }

    /// dockerd removes an AutoRemove container whose start failed, and the
    /// docker CLI (`run --rm`) waits for that removal after reporting the
    /// start error — so the wait has to end too.
    func testRefusedAutoRemoveStartRemovesTheContainerAndEndsTheWait() async throws {
        let id = try createContainer("settle-rm", autoRemove: true)
        let stream = try attach(id)
        let wait = await pendingWait(id)
        try refuseStarts(with: guardRefusal)

        let start = try shim.raw().request("POST", "/containers/\(id)/start")
        XCTAssertEqual(start.status, 409, message(start))
        _ = try stream.readUntilClose(timeout: 8)
        let waited = await waited(wait)
        XCTAssertTrue(waitError(waited)?.contains("attached read-write") == true, "\(String(describing: waited))")
        XCTAssertEqual(try shim.raw().request("GET", "/containers/\(id)/json").status, 404)
    }

    /// The retry after a refusal: `docker start -a` sends `/wait` before
    /// `/start`, so the new wait begins while the earlier refusal still
    /// stands. It must wait for the run the retried start makes, not end
    /// at once on the refusal (live: the container ran, and the CLI still
    /// printed "Error waiting for container: ... did not start").
    func testAWaitBeforeARetriedStartIgnoresTheEarlierRefusal() async throws {
        let id = try createContainer("settle-retry")
        let refusedStream = try attach(id)
        let refusedWait = await pendingWait(id)
        try refuseStarts(with: guardRefusal)
        let refused = try shim.raw().request("POST", "/containers/\(id)/start")
        XCTAssertEqual(refused.status, 409, message(refused))
        _ = try refusedStream.readUntilClose(timeout: 8)
        let refusedBody = await waited(refusedWait)
        XCTAssertTrue(
            waitError(refusedBody)?.contains("attached read-write") == true, "\(String(describing: refusedBody))")

        // Nothing has restarted it: a wait for it to be not running reports
        // the refusal that still stands rather than hanging.
        let standing = await waited(await pendingWait(id, condition: "not-running"))
        XCTAssertTrue(
            waitError(standing)?.contains("attached read-write") == true, "\(String(describing: standing))")

        // The holder is gone; the retry runs.
        try FileManager.default.removeItem(at: shim.stateDir.appendingPathComponent("start-refusal"))
        try Data("3".utf8).write(to: shim.stateDir.appendingPathComponent("attach-exit-code"))
        let stream = try attach(id)
        let wait = await pendingWait(id)
        let start = try shim.raw().request("POST", "/containers/\(id)/start")
        XCTAssertEqual(start.status, 204, message(start))
        let output = try stream.readUntilClose(timeout: 10)
        XCTAssertTrue(
            String(decoding: output, as: UTF8.self).contains("mock attached output from \(id)"),
            String(decoding: output, as: UTF8.self))

        let waitedBody = await waited(wait)
        XCTAssertEqual(waitedBody?["StatusCode"] as? Int, 3, "\(String(describing: waitedBody))")
        XCTAssertNil(waitedBody?["Error"], "\(String(describing: waitedBody))")
    }

    // MARK: - Starts that run

    /// The happy path keeps its semantics: 204, the run's output on the
    /// stream, the stream ending at exit, and the real exit code on the wait.
    func testAttachedStartThatRunsIs204AndStreamsTheRunAndItsExitCode() async throws {
        try Data("3".utf8).write(to: shim.stateDir.appendingPathComponent("attach-exit-code"))
        let id = try createContainer("settle-runs")
        let stream = try attach(id)
        let wait = await pendingWait(id)

        let start = try shim.raw().request("POST", "/containers/\(id)/start")
        XCTAssertEqual(start.status, 204, message(start))

        let output = try stream.readUntilClose(timeout: 10)
        var frames: [String] = []
        var rest = output
        while let frame = decodeFrame(rest) {
            frames.append(String(decoding: frame.payload, as: UTF8.self))
            rest = Data(rest.dropFirst(frame.consumed))
        }
        XCTAssertTrue(frames.joined().contains("mock attached output from \(id)"), "\(frames)")

        let waited = await waited(wait)
        XCTAssertEqual(waited?["StatusCode"] as? Int, 3, "\(String(describing: waited))")
        XCTAssertNil(waited?["Error"])
    }
}
