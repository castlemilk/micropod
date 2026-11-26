import Darwin
import Foundation
import Synchronization
import XCTest

@testable import MicropodRuntime

final class DockerTCPConnectionTests: XCTestCase {
    func testNumericIPv4ReturnsBlockingDescriptor() throws {
        let listener = try LoopbackListener(family: AF_INET)
        try assertConnected(host: "127.0.0.1", listener: listener)
    }

    func testNumericIPv6ReturnsBlockingDescriptor() throws {
        let listener: LoopbackListener
        do {
            listener = try LoopbackListener(family: AF_INET6)
        } catch let error as POSIXError where error.code == .EAFNOSUPPORT || error.code == .EADDRNOTAVAIL {
            throw XCTSkip("IPv6 loopback is unavailable")
        }
        try assertConnected(host: "::1", listener: listener)
    }

    func testHostnameCanReachIPv4Loopback() throws {
        let listener = try LoopbackListener(family: AF_INET)
        try assertConnected(host: "localhost", listener: listener)
    }

    func testDeadlineBoundsAStalledHostnameLookup() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let started = ContinuousClock.now
        let timeout = Duration.milliseconds(80)
        XCTAssertThrowsError(
            try DockerTCPConnection.connect(host: "fixture.test", port: 1234, timeout: timeout, cancellation: nil) {
                _, _ in
                entered.signal()
                _ = release.wait(timeout: .now() + .seconds(2))
                return []
            }
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
        let elapsed = ContinuousClock.now - started
        XCTAssertEqual(entered.wait(timeout: .now()), .success)
        XCTAssertGreaterThanOrEqual(elapsed, timeout)
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testCancellingAStalledHostnameLookupReturnsBeforeTheLookup() throws {
        let cancellation = SocketBox()
        let entered = expectation(description: "resolver started")
        let finished = expectation(description: "connection returned")
        let release = DispatchSemaphore(value: 0)
        let result = Mutex<Result<Int32, Error>?>(nil)
        defer { release.signal() }

        DispatchQueue.global().async {
            let connected = Result {
                try DockerTCPConnection.connect(
                    host: "fixture.test", port: 1234, timeout: .seconds(3), cancellation: cancellation
                ) { _, _ in
                    entered.fulfill()
                    _ = release.wait(timeout: .now() + .seconds(2))
                    return []
                }
            }
            result.withLock { $0 = connected }
            finished.fulfill()
        }
        wait(for: [entered], timeout: 1)
        cancellation.cancel()
        wait(for: [finished], timeout: 0.6)

        switch try XCTUnwrap(result.withLock { $0 }) {
        case .success(let fd):
            Darwin.close(fd)
            XCTFail("A cancelled connection opened a socket")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testPendingLoopbackConnectHonorsDeadlineAndCancellation() throws {
        let listener = try LoopbackListener(family: AF_INET)
        var queued: [Int32] = []
        defer { for fd in queued { Darwin.close(fd) } }
        let timeout = Duration.milliseconds(60)
        var stalled = false
        // Fill this private listener's accept queue without assuming its exact capacity.
        for _ in 0..<8 {
            let started = ContinuousClock.now
            do {
                queued.append(
                    try DockerTCPConnection.connect(
                        host: "127.0.0.1", port: listener.port, timeout: timeout, cancellation: nil))
            } catch {
                guard error.localizedDescription.contains("timed out") else { throw error }
                let elapsed = ContinuousClock.now - started
                XCTAssertGreaterThanOrEqual(elapsed, timeout)
                XCTAssertLessThan(elapsed, .seconds(1))
                stalled = true
                break
            }
        }
        guard stalled else { throw XCTSkip("Could not saturate the loopback listener") }

        let cancellation = SocketBox()
        let entered = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let result = Mutex<Result<Int32, Error>?>(nil)
        let port = listener.port
        DispatchQueue.global().async {
            entered.signal()
            let connected = Result {
                try DockerTCPConnection.connect(
                    host: "127.0.0.1", port: port, timeout: .seconds(2), cancellation: cancellation)
            }
            result.withLock { $0 = connected }
            finished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + .seconds(1)), .success)
        let waiting = finished.wait(timeout: .now() + .milliseconds(25))
        cancellation.cancel()
        XCTAssertEqual(waiting, .timedOut)
        if waiting == .timedOut {
            XCTAssertEqual(finished.wait(timeout: .now() + .milliseconds(600)), .success)
        }
        switch try XCTUnwrap(result.withLock { $0 }) {
        case .success(let fd):
            Darwin.close(fd)
            XCTFail("Cancelled pending connection returned a socket")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    private func assertConnected(host: String, listener: LoopbackListener) throws {
        let fd = try DockerTCPConnection.connect(
            host: host, port: listener.port, timeout: .seconds(1), cancellation: nil)
        defer { Darwin.close(fd) }
        let openFlags = fcntl(fd, F_GETFL)
        XCTAssertGreaterThanOrEqual(openFlags, 0)
        XCTAssertEqual(openFlags & O_NONBLOCK, 0)
        XCTAssertEqual(fcntl(fd, F_GETFD) & FD_CLOEXEC, FD_CLOEXEC)
        var ready = pollfd(fd: listener.fd, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(Darwin.poll(&ready, 1, 1_000), 1)
        guard ready.revents & Int16(POLLIN) != 0 else { return }
        let peer = Darwin.accept(listener.fd, nil, nil)
        XCTAssertGreaterThanOrEqual(peer, 0)
        if peer >= 0 { Darwin.close(peer) }
    }
}

private final class LoopbackListener {
    let fd: Int32
    let port: UInt16

    init(family: Int32) throws {
        let socket = Darwin.socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard socket >= 0 else { throw Self.error() }
        do {
            let assignedPort: UInt16
            if family == AF_INET {
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
                try Self.bindAndReadBack(&address, socket: socket)
                assignedPort = UInt16(bigEndian: address.sin_port)
            } else {
                var address = sockaddr_in6()
                address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                address.sin6_family = sa_family_t(AF_INET6)
                address.sin6_addr = in6addr_loopback
                try Self.bindAndReadBack(&address, socket: socket)
                assignedPort = UInt16(bigEndian: address.sin6_port)
            }
            guard Darwin.listen(socket, 1) == 0 else { throw Self.error() }
            fd = socket
            port = assignedPort
        } catch {
            Darwin.close(socket)
            throw error
        }
    }

    deinit { Darwin.close(fd) }

    private static func bindAndReadBack<T>(_ address: inout T, socket: Int32) throws {
        var length = socklen_t(MemoryLayout<T>.size)
        try withUnsafeMutablePointer(to: &address) { address in
            try address.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                guard Darwin.bind(socket, address, length) == 0 else { throw error() }
                guard getsockname(socket, address, &length) == 0 else { throw error() }
            }
        }
    }

    private static func error() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
