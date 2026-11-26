import Darwin
import Foundation
import MicropodCore
import XCTest

@testable import MicropodAPI

/// The API's Unix sockets: only the owner's private socket skips the
/// request guard, a socket that cannot be served is never advertised, and
/// a directory created for it is private.
final class PrivateSocketTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        // Short: sun_path holds 104 bytes.
        dir = URL(fileURLWithPath: "/tmp/mp-ps-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func server() -> HTTPServer {
        HTTPServer(port: 45454) { _ in .json(200, ["ok": true]) }
    }

    /// The status line of a POST sent with a Host that names no port.
    private func post(_ path: String, host: String = "localhost") async throws -> String {
        try await withCheckedThrowingContinuation { done in
            DispatchQueue.global().async {
                done.resume(
                    with: Result {
                        let fd = try RuntimeUnixSocket.connect(path, expectedUID: getuid())
                        defer { close(fd) }
                        try RuntimeUnixSocket.timeout(fd, seconds: 3)
                        let head =
                            "POST /api/micropod.v1.SystemService/Ping HTTP/1.1\r\nHost: \(host)\r\n"
                            + "Content-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
                        try RuntimeUnixSocket.write(Data(head.utf8), to: fd)
                        var out = Data()
                        var buffer = [UInt8](repeating: 0, count: 4096)
                        while true {
                            let n = Darwin.read(fd, &buffer, buffer.count)
                            guard n > 0 else { break }
                            out.append(contentsOf: buffer.prefix(n))
                        }
                        return String(decoding: out, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
                    })
            }
        }
    }

    private func mode(_ path: String) -> mode_t {
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0, path)
        return info.st_mode & 0o777
    }

    func testOnlyTheOwnerSocketSkipsTheRequestGuard() async throws {
        let server = server()
        defer { server.stop() }
        let owner = dir.appendingPathComponent("api.sock").path
        let managed = dir.appendingPathComponent("internal.sock").path
        try await server.startPrivateSocket(path: owner, admission: .ownerOnly)
        try await server.startPrivateSocket(path: managed)
        XCTAssertEqual(mode(owner), 0o600)
        XCTAssertEqual(mode(managed), 0o600)

        let fromOwner = try await post(owner)
        XCTAssertEqual(fromOwner, "HTTP/1.1 200 OK")
        // The managed runtime's internal socket relays its gateway's callers:
        // it keeps the guard every TCP request gets.
        let unguarded = try await post(managed)
        XCTAssertEqual(unguarded, "HTTP/1.1 403 Forbidden")
        let guarded = try await post(managed, host: "localhost:45454")
        XCTAssertEqual(guarded, "HTTP/1.1 200 OK")
    }

    func testASocketThatCannotBeServedIsLoggedAndNotAdvertised() async throws {
        let path = dir.appendingPathComponent("api.sock").path
        // Something that is not this user's socket already holds the path.
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data("not a socket".utf8)))
        let logged = LockedLines()
        let server = server()
        defer { server.stop() }
        let advertised = await MicropodAPI.startOwnerSocket(server, path: path, log: { logged.append($0) })
        XCTAssertNil(advertised, "a failed bind is not advertised")
        XCTAssertEqual(logged.lines.count, 1)
        XCTAssertTrue(logged.lines[0].contains("unix://\(path) failed"), logged.lines[0])
        XCTAssertEqual(
            try String(contentsOfFile: path, encoding: .utf8), "not a socket", "the foreign file is left alone")

        let tooLong = dir.appendingPathComponent(String(repeating: "s", count: 120) + ".sock").path
        let unbound = await MicropodAPI.startOwnerSocket(server, path: tooLong, log: { logged.append($0) })
        XCTAssertNil(unbound)
        XCTAssertEqual(logged.lines.count, 2)
    }

    func testTheOwnerSocketDirectoryIsCreatedPrivate() async throws {
        let previous = umask(0o022)
        defer { umask(previous) }
        let fresh = dir.appendingPathComponent("home/.micropod")
        let path = fresh.appendingPathComponent("api.sock").path
        let server = server()
        defer { server.stop() }
        let advertised = await MicropodAPI.startOwnerSocket(server, path: path, log: { XCTFail($0) })
        XCTAssertEqual(advertised, path)
        XCTAssertEqual(mode(fresh.path), 0o700, "created private, whatever the umask")
        XCTAssertEqual(mode(fresh.deletingLastPathComponent().path), 0o700, "so are missing parents")
        XCTAssertEqual(mode(path), 0o600)
        let answered = try await post(path)
        XCTAssertEqual(answered, "HTTP/1.1 200 OK")

        // An existing directory keeps the mode its owner gave it.
        let shared = dir.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(shared.path, 0o755), 0)
        let other = HTTPServer(port: 45454) { _ in .json(200, [:]) }
        defer { other.stop() }
        let sharedSocket = shared.appendingPathComponent("api.sock").path
        let kept = await MicropodAPI.startOwnerSocket(other, path: sharedSocket, log: { XCTFail($0) })
        XCTAssertEqual(kept, sharedSocket)
        XCTAssertEqual(mode(shared.path), 0o755)
    }
}

final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ line: String) { lock.withLock { stored.append(line) } }
    var lines: [String] { lock.withLock { stored } }
}
