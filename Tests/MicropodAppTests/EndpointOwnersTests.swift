import Darwin
import Foundation
import XCTest

@testable import MicropodApp

/// `EndpointOwners` replaces `lsof` for agent ownership checks — it must find
/// exactly the listener, in-process, and never a connected client.
final class EndpointOwnersTests: XCTestCase {
    private func spawn(_ path: String, _ args: [String]) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = Pipe()  // keeps an `nc` client connected
        try p.run()
        return p
    }

    private func eventually(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    func testFindsUnixListenerButNotItsClient() throws {
        let path = "/tmp/mpowners-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let listener = try spawn("/usr/bin/nc", ["-lU", "-k", path])
        defer { listener.terminate() }
        XCTAssertTrue(
            eventually { EndpointOwners.unixListeners(path: path)?.contains(listener.processIdentifier) == true },
            "the listening nc must be found")

        let client = try spawn("/usr/bin/nc", ["-U", path])
        defer { client.terminate() }
        Thread.sleep(forTimeInterval: 0.3)
        let owners = try XCTUnwrap(EndpointOwners.unixListeners(path: path))
        XCTAssertTrue(owners.contains(listener.processIdentifier))
        XCTAssertFalse(owners.contains(client.processIdentifier), "a connected client is not an owner")
    }

    func testFindsTCPListenerOnItsPortOnly() throws {
        // Reserve-then-release an ephemeral port for the listener.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) }
        }
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        let port = UInt16(bigEndian: addr.sin_port)
        close(fd)

        let listener = try spawn("/usr/bin/python3", ["-m", "http.server", "\(port)", "--bind", "127.0.0.1"])
        defer { listener.terminate() }
        XCTAssertTrue(
            eventually { EndpointOwners.tcpListeners(port: port)?.contains(listener.processIdentifier) == true },
            "the listener on \(port) must be found")
        let other = try XCTUnwrap(EndpointOwners.tcpListeners(port: port == 1 ? 2 : 1))
        XCTAssertFalse(other.contains(listener.processIdentifier), "a different port must not match")
    }

    func testNobodyOnAFreshPathIsEmptyNotUnknown() {
        let owners = EndpointOwners.unixListeners(path: "/tmp/mpowners-none-\(UUID().uuidString).sock")
        XCTAssertEqual(owners, [], "an unbound path has no owners — and the scan itself must succeed")
    }

    /// The point of the change: answering takes milliseconds, not an lsof
    /// fork that blew its 10s bound at load average 100+.
    func testScanIsFast() {
        let start = Date()
        _ = EndpointOwners.tcpListeners(port: 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
    }
}
