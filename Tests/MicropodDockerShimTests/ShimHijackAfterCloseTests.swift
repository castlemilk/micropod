import Foundation
import XCTest

@testable import MicropodCore
@testable import MicropodDockerShim
@testable import MicropodRuntime

/// A client that leaves while its `/attach` is still resolving the container
/// must not be hijacked afterwards: by the time the handler gets to the
/// hijack its fd number may belong to the next client, which would then
/// receive the attach's `101 UPGRADED` — and lose its own socket when the
/// parked attach is closed.
final class ShimHijackAfterCloseTests: XCTestCase {
    /// `ContainerServing` whose `list` holds every caller until `release`,
    /// then answers with one container. Nothing else is scripted.
    final actor GatedList: ContainerServing {
        private let id: String
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(id: String) { self.id = id }

        func release() {
            released = true
            for waiter in waiters { waiter.resume() }
            waiters = []
        }

        func list() async throws -> [Micropod_V1_Container] {
            if !released {
                await withCheckedContinuation { waiters.append($0) }
            }
            var container = Micropod_V1_Container()
            container.id = id
            container.state = "stopped"
            container.image = "alpine:3.20"
            return [container]
        }

        func inspect(_ id: String) async throws -> Data { throw MicropodError.message("unused") }
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

    private var opened: [Int32] = []
    private var stateDirs: [URL] = []

    override func tearDown() async throws {
        for fd in opened { Darwin.close(fd) }
        opened = []
        for dir in stateDirs { try? FileManager.default.removeItem(at: dir) }
    }

    /// An unconnected TCP socket, closed at tearDown.
    private func tcpSocket() throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO) }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        opened.append(fd)
        return fd
    }

    private func connect(_ fd: Int32, port: UInt16) throws {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw POSIXError(POSIXError.Code(rawValue: errno) ?? .ECONNREFUSED) }
    }

    private func send(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        XCTAssertEqual(Darwin.send(fd, bytes, bytes.count, 0), bytes.count)
    }

    /// Everything that arrives on `fd` within `timeout` (up to EOF).
    private func received(_ fd: Int32, within timeout: TimeInterval) -> Data {
        var out = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 50) > 0 else { continue }
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            out.append(contentsOf: buffer[0..<n])
        }
        return out
    }

    /// A `/_ping` answer, read until its body (`OK`) is in.
    private func ping(_ fd: Int32) -> String {
        send(fd, "GET /_ping HTTP/1.1\r\nHost: d\r\n\r\n")
        var out = Data()
        let deadline = Date().addingTimeInterval(5)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline, !String(decoding: out, as: UTF8.self).hasSuffix("OK\n") {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 50) > 0 else { continue }
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            out.append(contentsOf: buffer[0..<n])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The socket `fd` names (device and inode), nil for a free number.
    private func identity(of fd: Int32) -> String? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }

    /// The shim's end of the connection whose client end is `client`: the
    /// shim runs in this process, so it is the fd here whose peer is
    /// `client`'s local address.
    private func shimSide(of client: Int32) async -> Int32? {
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(client, $0, &length)
            }
        }
        guard named == 0 else { return nil }
        let limit = min(getdtablesize(), 16384)
        for _ in 0..<100 {
            for fd in 0..<limit where fd != client {
                var peer = sockaddr_in()
                var peerLength = socklen_t(MemoryLayout<sockaddr_in>.size)
                let found = withUnsafeMutablePointer(to: &peer) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getpeername(fd, $0, &peerLength)
                    }
                }
                if found == 0, peer.sin_family == sa_family_t(AF_INET),
                    peer.sin_port == local.sin_port, peer.sin_addr.s_addr == local.sin_addr.s_addr
                {
                    return fd
                }
            }
            // Not accepted yet.
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    func testAnAttachWhoseClientLeftNeverReachesTheClientThatInheritedItsFd() async throws {
        let containerID = "mpfix-hijack-after-close"
        let backend = GatedList(id: containerID)
        let shim = try ShimTestSupport.makeMockShim(extraEnv: [:], containers: backend)
        stateDirs.append(shim.stateDir)

        let leaver = try tcpSocket()
        try connect(leaver, port: shim.port)
        let accepted = await shimSide(of: leaver)
        let leaverShimSide = try XCTUnwrap(accepted, "the shim never accepted the attach")
        let leaverSocket = try XCTUnwrap(identity(of: leaverShimSide))
        // Taken now, so they hold the lowest free numbers and the shim's next
        // accepts land on the number the leaver's connection frees.
        let candidates = try (0..<32).map { _ in try tcpSocket() }

        // A name, not a runtime id: the attach waits on the gated list.
        send(
            leaver,
            "POST /containers/\(containerID)/attach?stream=1&stdout=1&stderr=1 HTTP/1.1\r\n"
                + "Host: d\r\nContent-Length: 0\r\n\r\n")
        // The client leaves (its fd stays ours, so its number is not free).
        _ = Darwin.shutdown(leaver, SHUT_RDWR)
        for _ in 0..<250 where identity(of: leaverShimSide) == leaverSocket {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotEqual(
            identity(of: leaverShimSide), leaverSocket, "the shim never released the leaver's connection")

        // The next client takes the leaver's fd number.
        var inheritor: Int32?
        for candidate in candidates where inheritor == nil {
            try connect(candidate, port: shim.port)
            if await shimSide(of: candidate) == leaverShimSide { inheritor = candidate }
        }
        guard let inheritor else {
            throw XCTSkip("fd \(leaverShimSide) was taken elsewhere; the reuse could not be arranged")
        }
        XCTAssertTrue(ping(inheritor).hasPrefix("HTTP/1.1 200"))

        // The attach resolves its container and reaches the hijack.
        await backend.release()
        var parked: ShimConnection?
        for _ in 0..<250 where parked == nil {
            parked = AttachRegistry.shared.claim(containerID: containerID)
            if parked == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let attach = try XCTUnwrap(parked, "the attach was never parked")
        XCTAssertTrue(attach.isClosed, "the attach of a client that left was reopened")

        let unsolicited = received(inheritor, within: 0.5)
        XCTAssertTrue(
            unsolicited.isEmpty,
            "the inheritor received the attach's bytes: \(String(decoding: unsolicited, as: UTF8.self))")
        // Ending the attach must not end the inheritor's connection.
        attach.close()
        XCTAssertTrue(ping(inheritor).hasPrefix("HTTP/1.1 200"), "the inheritor's connection was shut down")
    }
}
