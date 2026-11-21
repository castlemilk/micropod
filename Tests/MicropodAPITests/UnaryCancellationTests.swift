import Darwin
import Foundation
import MicropodCore
import XCTest

@testable import MicropodAPI

/// Replays what Gamma-128 showed on 2026-11-19: the agent's create gives up
/// at its deadline while the server-side create is still queued behind the
/// runtime, and minutes later the create reaches the runtime anyway, for an
/// attempt that has already failed.
///
/// The handler here stands in for the native create path: it waits
/// somewhere that does not observe cancellation (a volume lock, a reply it
/// is already waiting for), then reaches its dispatch point, which is where
/// the real path checks `Task.checkCancellation()` before `containerCreate`.
final class UnaryCancellationTests: XCTestCase {
    private var root: URL!
    private var socketPath: String { root.appendingPathComponent("api.sock").path }

    // The server answers on a private socket only; the port just names the
    // Host header its request guard accepts (localhost:45454).
    override func setUpWithError() throws {
        // Short, so the socket path fits sun_path.
        root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("uc-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static let createPath = "/api/micropod.v1.ContainerService/CreateContainer"

    /// The fake create's outcome as the Connect answer a handler gives.
    private static func answer(_ dispatched: Bool) -> HTTPResponse {
        dispatched
            ? .data(200, "application/json", Data(#"{"id":"c"}"#.utf8))
            : .data(499, "application/json", Data(#"{"code":"canceled"}"#.utf8))
    }

    /// The client gives up through `Connect-Timeout-Ms`; it is answered
    /// `deadline_exceeded` at the deadline, and the create, released later,
    /// stops at its dispatch point.
    func testDeadlineAnswersDeadlineExceededAndTheLateCreateNeverDispatches() async throws {
        let runtime = FakeCreatePath()
        let server = HTTPServer(port: 45454) { _ in Self.answer(await runtime.create()) }
        try await server.startPrivateSocket(path: socketPath)
        defer { server.stop() }

        let started = Date()
        let response = try await Self.exchange(
            socketPath, path: Self.createPath, headers: ["Connect-Timeout-Ms": "300"], hangUpAfter: nil)
        let waited = Date().timeIntervalSince(started)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 504"), response)
        XCTAssertTrue(response.contains(#""code":"deadline_exceeded""#), response)
        XCTAssertLessThan(waited, 5, "answered at the deadline, not when the runtime got to it")

        await runtime.release()  // "minutes later"
        try await runtime.waitUntilFinished()
        let counts = await runtime.counts
        XCTAssertEqual(counts.dispatched, 0, "a create nobody waits for must not reach the runtime")
        XCTAssertEqual(counts.stoppedBeforeDispatch, 1)
    }

    /// The client closes its connection (the agent's HTTP client cancelling
    /// a request), with no deadline header: same outcome.
    func testHangupCancelsTheHandlerBeforeDispatch() async throws {
        let runtime = FakeCreatePath()
        let server = HTTPServer(port: 45454) { _ in Self.answer(await runtime.create()) }
        try await server.startPrivateSocket(path: socketPath)
        defer { server.stop() }

        _ = try await Self.exchange(socketPath, path: Self.createPath, headers: [:], hangUpAfter: .milliseconds(200))
        try await Task.sleep(for: .milliseconds(200))
        await runtime.release()
        try await runtime.waitUntilFinished()
        let counts = await runtime.counts
        XCTAssertEqual(counts.dispatched, 0)
        XCTAssertEqual(counts.stoppedBeforeDispatch, 1)
    }

    /// The defect itself, with cancellation off (`MICROPOD_CANCEL_ON_HANGUP=off`
    /// behaves the same): the client is long gone, and the create still
    /// dispatches when the runtime gets to it.
    func testWithoutCancellationTheAbandonedCreateStillDispatches() async throws {
        let runtime = FakeCreatePath()
        let server = HTTPServer(port: 45454, cancellable: { _ in false }) { _ in Self.answer(await runtime.create()) }
        try await server.startPrivateSocket(path: socketPath)
        defer { server.stop() }

        _ = try await Self.exchange(
            socketPath, path: Self.createPath, headers: ["Connect-Timeout-Ms": "200"], hangUpAfter: .milliseconds(300))
        await runtime.release()
        try await runtime.waitUntilFinished()
        let counts = await runtime.counts
        XCTAssertEqual(counts.dispatched, 1, "the old behaviour: work for a caller that gave up")
    }

    /// A call that finishes inside its deadline is answered normally.
    func testAnAnswerInsideTheDeadlineIsDelivered() async throws {
        let runtime = FakeCreatePath()
        await runtime.release()
        let server = HTTPServer(port: 45454) { _ in Self.answer(await runtime.create()) }
        try await server.startPrivateSocket(path: socketPath)
        defer { server.stop() }

        let response = try await Self.exchange(
            socketPath, path: Self.createPath, headers: ["Connect-Timeout-Ms": "5000"], hangUpAfter: nil)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"), response)
        let counts = await runtime.counts
        XCTAssertEqual(counts.dispatched, 1)
    }

    func testOnlyUnaryConnectCallsAreCancellable() {
        func request(_ method: HTTPMethod, _ path: String, _ type: String) -> HTTPRequest {
            HTTPRequest(method: method, path: path, query: [:], body: Data(), headers: ["content-type": type])
        }
        XCTAssertTrue(UnaryCancellation.applies(request(.post, Self.createPath, "application/json")))
        XCTAssertTrue(UnaryCancellation.applies(request(.post, Self.createPath, "application/proto")))
        XCTAssertFalse(
            UnaryCancellation.applies(
                request(.post, "/api/micropod.v1.ContainerService/StreamContainerLogs", "application/connect+json")),
            "a server stream watches its own connection")
        XCTAssertFalse(UnaryCancellation.applies(request(.get, "/v1/containers/x/vsock/1024", "")), "a bridge")
        XCTAssertFalse(UnaryCancellation.applies(request(.post, "/v1/system/runtime", "application/json")))
    }

    func testConnectTimeoutHeaderParsing() {
        func deadline(_ value: String?) -> Duration? {
            UnaryCancellation.deadline(
                of: HTTPRequest(
                    method: .post, path: Self.createPath, query: [:], body: Data(),
                    headers: value.map { ["connect-timeout-ms": $0] } ?? [:]))
        }
        XCTAssertEqual(deadline("60000"), .milliseconds(60000))
        XCTAssertEqual(deadline(" 250 "), .milliseconds(250))
        XCTAssertNil(deadline(nil))
        XCTAssertNil(deadline(""))
        XCTAssertNil(deadline("-5"))
        XCTAssertNil(deadline("1.5"))
        XCTAssertNil(deadline("12345678901"), "more than ten digits")
        XCTAssertNil(deadline("٣٠٠"), "only ASCII digits")
    }

    /// Writes one request and reads the response; with `hangUpAfter`, closes
    /// the connection that long after writing instead of reading.
    private static func exchange(
        _ socket: String, path: String, headers: [String: String], hangUpAfter: Duration?
    ) async throws -> String {
        try await withCheckedThrowingContinuation { done in
            DispatchQueue.global().async {
                done.resume(
                    with: Result {
                        let fd = try RuntimeUnixSocket.connect(socket, expectedUID: getuid())
                        defer { close(fd) }
                        try RuntimeUnixSocket.timeout(fd, seconds: 10)
                        var head =
                            "POST \(path) HTTP/1.1\r\nHost: localhost:45454\r\nContent-Type: application/json\r\n"
                        for (key, value) in headers { head += "\(key): \(value)\r\n" }
                        head += "Content-Length: 2\r\n\r\n{}"
                        try RuntimeUnixSocket.write(Data(head.utf8), to: fd)
                        if let hangUpAfter {
                            let c = hangUpAfter.components
                            usleep(useconds_t(c.seconds * 1_000_000 + c.attoseconds / 1_000_000_000_000))
                            return ""
                        }
                        var response = Data()
                        var bytes = [UInt8](repeating: 0, count: 4096)
                        while true {
                            let count = Darwin.read(fd, &bytes, bytes.count)
                            guard count >= 0 else { throw CocoaError(.fileReadUnknown) }
                            if count == 0 { break }
                            response.append(contentsOf: bytes.prefix(count))
                        }
                        return String(decoding: response, as: UTF8.self)
                    })
            }
        }
    }
}

/// A create that waits, without observing cancellation, until released, and
/// then either stops (its task was cancelled) or "dispatches".
private actor FakeCreatePath {
    struct Counts: Equatable {
        var dispatched = 0
        var stoppedBeforeDispatch = 0
    }
    private(set) var counts = Counts()
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var finished = 0
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    /// True when it dispatched.
    func create() async -> Bool {
        if !released {
            await withCheckedContinuation { waiters.append($0) }
        }
        defer {
            finished += 1
            finishWaiters.forEach { $0.resume() }
            finishWaiters = []
        }
        do {
            try Task.checkCancellation()
        } catch {
            counts.stoppedBeforeDispatch += 1
            return false
        }
        counts.dispatched += 1
        return true
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func waitUntilFinished() async throws {
        guard finished == 0 else { return }
        await withCheckedContinuation { finishWaiters.append($0) }
    }
}
