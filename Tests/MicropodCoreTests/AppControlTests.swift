import Foundation
import XCTest

@testable import MicropodCore

/// Client-side contract for the app control socket: missing socket,
/// dead listener, and a real newline-JSON round-trip against a POSIX
/// stub listener that mimics the app's server.
final class AppControlTests: XCTestCase {

    private var socketPath: String!

    override func setUp() {
        super.setUp()
        socketPath =
            NSTemporaryDirectory()
            + "appctl-\(UUID().uuidString.prefix(8)).sock"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: socketPath)
        super.tearDown()
    }

    func testMissingSocketReportsUnreachable() async {
        let client = AppControlClient(socketPath: socketPath)
        XCTAssertFalse(client.isReachable)
        await XCTAssertThrowsErrorAsync(try await client.updateStatus()) { error in
            guard case AppControlError.unavailable = error else {
                XCTFail("expected unavailable, got \(error)")
                return
            }
        }
    }

    func testStaleSocketFileFailsFast() async {
        // A leftover file at the socket path with no listener must fail
        // quickly, not hang in NWConnection's retry loop.
        FileManager.default.createFile(atPath: socketPath, contents: nil)
        let client = AppControlClient(socketPath: socketPath)
        XCTAssertTrue(client.isReachable)
        let start = Date()
        await XCTAssertThrowsErrorAsync(try await client.updateStatus())
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testRoundTripAgainstStubServer() async throws {
        let stub = StubControlServer(path: socketPath) { request in
            [
                "id": request["id"] as? String ?? "",
                "ok": true,
                "result": ["state": "upToDate"],
            ]
        }
        try stub.start()
        defer { stub.stop() }

        let client = AppControlClient(socketPath: socketPath)
        let report = try await client.updateStatus()
        XCTAssertEqual(report["state"] as? String, "upToDate")
    }

    func testServerErrorSurfacesAsCallFailed() async throws {
        let stub = StubControlServer(path: socketPath) { _ in
            ["id": "x", "ok": false, "error": "unknown method: bogus"]
        }
        try stub.start()
        defer { stub.stop() }

        let client = AppControlClient(socketPath: socketPath)
        await XCTAssertThrowsErrorAsync(try await client.call("bogus")) { error in
            guard case AppControlError.callFailed(let message) = error else {
                XCTFail("expected callFailed, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("unknown method"))
        }
    }

    func testUnresponsiveListenerHitsTimeout() async throws {
        // A listener that accepts but never answers — the call must fail
        // within the client's timeout instead of hanging forever.
        let stub = StubControlServer(path: socketPath) { _ in nil }
        try stub.start()
        defer { stub.stop() }

        let client = AppControlClient(socketPath: socketPath, requestTimeout: 1)
        let start = Date()
        await XCTAssertThrowsErrorAsync(try await client.updateStatus()) { error in
            guard case AppControlError.unavailable(let message) = error else {
                XCTFail("expected unavailable, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("timed out"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }
}

/// Minimal unix-socket server speaking the app's wire protocol: one
/// JSON request line in, one JSON response line out. POSIX sockets —
/// deterministic in test hosts where NWListener state callbacks can lag.
private final class StubControlServer: @unchecked Sendable {
    private let path: String
    private let handler: ([String: Any]) -> [String: Any]?
    private var listenFD: Int32 = -1
    private var thread: Thread?

    /// `handler` returning nil leaves the connection open with no reply —
    /// the "wedged listener" shape.
    init(path: String, handler: @escaping ([String: Any]) -> [String: Any]?) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), $0, 104) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        guard
            withUnsafePointer(
                to: &addr,
                {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(listenFD, $0, len)
                    }
                }) == 0, listen(listenFD, 4) == 0
        else {
            throw POSIXError(.EIO)
        }
        let server = self
        thread = Thread {
            while true {
                let conn = accept(server.listenFD, nil, nil)
                if conn < 0 { return }
                server.serve(conn)
            }
        }
        thread?.start()
    }

    func stop() {
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    private func serve(_ conn: Int32) {
        defer { close(conn) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(conn, &chunk, chunk.count, 0)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.contains(0x0A) { break }
        }
        guard
            let request = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any]
        else { return }
        guard let response = handler(request) else {
            // Wedged-listener shape: hold the connection open so the
            // client's own timeout is what ends the exchange.
            Thread.sleep(forTimeInterval: 30)
            return
        }
        guard let body = try? JSONSerialization.data(withJSONObject: response)
        else { return }
        let line = body + Data("\n".utf8)
        line.withUnsafeBytes { ptr in
            _ = send(conn, ptr.baseAddress, ptr.count, 0)
        }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Any,
    _ verify: (Error) -> Void = { _ in },
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected throw", file: file, line: line)
    } catch {
        verify(error)
    }
}
