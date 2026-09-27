import Foundation
import XCTest

@testable import MicropodDockerShim

/// `ShimConnection` over a raw fd, driven through socket pairs: once a
/// connection is closed nothing more is written through it — its fd number
/// may by then name another client's socket (the kernel hands the lowest free
/// number to the next accept), and a late response written there corrupts
/// that client's HTTP stream (live: the docker CLI printed "Unsolicited
/// response received on idle HTTP channel" and failed on `malformed HTTP
/// version "{\"StatusCode\":0}HTTP/1.1"`).
final class ShimConnectionTests: XCTestCase {
    private var opened: [Int32] = []

    override func tearDown() {
        for fd in opened { Darwin.close(fd) }
        opened = []
    }

    /// A connected AF_UNIX stream pair, closed at tearDown unless handed to a
    /// connection (`adopt: false`), which owns and closes its own end.
    private func socketPair(adopt: Bool = true) throws -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        for fd in fds {
            var one: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        opened.append(fds[1])
        if adopt { opened.append(fds[0]) }
        return (fds[0], fds[1])
    }

    /// Bytes already waiting on `fd`, read without blocking; empty if none.
    private func pending(_ fd: Int32) -> Data {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buffer, buffer.count, MSG_DONTWAIT)
            if n <= 0 { return out }
            out.append(contentsOf: buffer[0..<n])
        }
    }

    private let lateBody = Data(#"{"StatusCode":0}"#.utf8)

    func testAWriteAfterCloseIsRefusedAndSendsNothing() async throws {
        let (server, client) = try socketPair(adopt: false)
        let connection = ShimConnection(fileDescriptor: server)
        let before = await connection.write(Data("HTTP/1.1 200 OK\r\n\r\n".utf8))
        XCTAssertEqual(before, .ok)

        connection.close()
        let after = await connection.write(lateBody)
        XCTAssertEqual(after, .failed, "a closed connection refuses writes")
        XCTAssertEqual(String(decoding: pending(client), as: UTF8.self), "HTTP/1.1 200 OK\r\n\r\n")
    }

    /// Close is serialised with writes: a write queued before the close
    /// either completes on the connection's own socket or is refused — and a
    /// long poll learns of the close through `onClose`.
    func testCloseRunsCloseHandlersOnceAndRefusesQueuedWrites() async throws {
        let (server, client) = try socketPair(adopt: false)
        let connection = ShimConnection(fileDescriptor: server)
        let closes = Counter()
        connection.onClose { closes.increment() }

        let body = lateBody
        async let raced = connection.write(body)
        connection.close()
        connection.close()
        let status = await raced
        XCTAssertTrue(connection.isClosed)
        XCTAssertEqual(closes.value, 1, "close handlers run exactly once")
        let received = pending(client)
        switch status {
        case .ok: XCTAssertEqual(received, lateBody, "a write that went out went to its own client")
        case .failed: XCTAssertTrue(received.isEmpty)
        }

        // Registered after the close: runs at once.
        connection.onClose { closes.increment() }
        XCTAssertEqual(closes.value, 2)
    }

    /// The serve thread may be between recv(2) calls when a handler closes
    /// the connection: the fd stays this connection's (shut down, reading
    /// EOF) until the thread detaches, so its next recv cannot read another
    /// client's bytes.
    func testTheFdIsHeldUntilTheReaderDetaches() async throws {
        let (server, _) = try socketPair(adopt: false)
        let socket = try XCTUnwrap(identity(of: server))
        let connection = ShimConnection(fileDescriptor: server, readerAttached: true)
        connection.close()
        // Queued behind the close: once it answers, a release would be done.
        _ = await connection.write(Data())
        XCTAssertEqual(identity(of: server), socket, "released while the reader may still recv on it")
        var byte: UInt8 = 0
        XCTAssertEqual(recv(server, &byte, 1, MSG_DONTWAIT), 0, "the reader sees end-of-stream")

        connection.readerDetached()
        _ = await connection.write(Data())
        // The number no longer names this socket: free, or already another's.
        XCTAssertNotEqual(identity(of: server), socket, "released once the reader has detached")
    }

    /// The socket `fd` names (device and inode), nil for a free number.
    private func identity(of fd: Int32) -> String? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }

    /// The fd number of a closed connection is taken by the next socket; the
    /// closed connection's late write must not land on it, and must not have
    /// shut it down either.
    func testALateBodyNeverReachesTheSocketThatInheritedTheFdNumber() async throws {
        let (server, _) = try socketPair(adopt: false)
        let connection = ShimConnection(fileDescriptor: server)
        connection.close()
        // Queued behind the close on the connection's write queue: once it
        // has answered, the close has released the fd.
        let queued = await connection.write(Data())
        XCTAssertEqual(queued, .failed)

        // Another client's socket takes the freed number, as the shim's next
        // accept(2) does.
        var inheritor: (fd: Int32, peer: Int32)?
        for _ in 0..<64 where inheritor == nil {
            let (a, b) = try socketPair()
            if a == server { inheritor = (a, b) } else if b == server { inheritor = (b, a) }
        }
        guard let inheritor else {
            throw XCTSkip("fd \(server) was taken by another thread; the reuse could not be arranged")
        }

        let late = await connection.write(lateBody)
        XCTAssertEqual(late, .failed)
        let leaked = pending(inheritor.peer)
        XCTAssertTrue(
            leaked.isEmpty,
            "the late body reached the fd's new owner: \(String(decoding: leaked, as: UTF8.self))")

        // The new owner's socket is intact in both directions.
        XCTAssertEqual(Darwin.send(inheritor.peer, "ping", 4, 0), 4)
        XCTAssertEqual(String(decoding: pending(inheritor.fd), as: UTF8.self), "ping")
        XCTAssertEqual(Darwin.send(inheritor.fd, "pong", 4, 0), 4)
        XCTAssertEqual(String(decoding: pending(inheritor.peer), as: UTF8.self), "pong")
    }

    /// A client can leave while a handler is still on its way to the hijack
    /// (an `/attach` awaiting its container lookup, an exec start launching
    /// its process). The hijack must not reopen the closed connection: it
    /// stays closed, refuses the 101, and hands back an inbound stream that
    /// has already ended.
    func testAHijackAfterCloseLeavesTheConnectionClosed() async throws {
        let (server, client) = try socketPair(adopt: false)
        let connection = ShimConnection(fileDescriptor: server)
        connection.close()

        let inbound = connection.beginHijack()
        XCTAssertTrue(connection.isClosed, "the hijack reopened a closed connection")
        XCTAssertFalse(connection.isHijacking)
        let upgraded = await connection.write(Data("HTTP/1.1 101 UPGRADED\r\n\r\n".utf8))
        XCTAssertEqual(upgraded, .failed, "a closed connection refuses the 101")
        XCTAssertTrue(pending(client).isEmpty)
        var yielded = 0
        for await _ in inbound { yielded += 1 }
        XCTAssertEqual(yielded, 0, "the inbound stream of a closed connection has ended")
    }

    /// The same race once the fd number has been handed to the next client:
    /// neither the hijack's 101 and output nor its eventual close may reach
    /// the socket that inherited the number.
    func testAHijackAfterCloseNeverReachesTheSocketThatInheritedTheFdNumber() async throws {
        let (server, _) = try socketPair(adopt: false)
        let connection = ShimConnection(fileDescriptor: server)
        connection.close()
        // Queued behind the close: once it answers, the fd has been released.
        _ = await connection.write(Data())

        var inheritor: (fd: Int32, peer: Int32)?
        for _ in 0..<64 where inheritor == nil {
            let (a, b) = try socketPair()
            if a == server { inheritor = (a, b) } else if b == server { inheritor = (b, a) }
        }
        guard let inheritor else {
            throw XCTSkip("fd \(server) was taken by another thread; the reuse could not be arranged")
        }

        _ = connection.beginHijack()
        let upgraded = await connection.write(Data("HTTP/1.1 101 UPGRADED\r\n\r\n".utf8))
        XCTAssertEqual(upgraded, .failed)
        let output = await connection.write(lateBody)
        XCTAssertEqual(output, .failed)
        // The attached process's writer closes the connection when it ends.
        connection.close()
        _ = await connection.write(Data())

        let leaked = pending(inheritor.peer)
        XCTAssertTrue(
            leaked.isEmpty,
            "the hijack wrote to the fd's new owner: \(String(decoding: leaked, as: UTF8.self))")
        // The new owner's socket was neither shut down nor released.
        XCTAssertEqual(Darwin.send(inheritor.peer, "ping", 4, 0), 4)
        XCTAssertEqual(String(decoding: pending(inheritor.fd), as: UTF8.self), "ping")
        XCTAssertEqual(Darwin.send(inheritor.fd, "pong", 4, 0), 4)
        XCTAssertEqual(String(decoding: pending(inheritor.peer), as: UTF8.self), "pong")
    }
}

/// A thread-safe tally for close-handler assertions.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
