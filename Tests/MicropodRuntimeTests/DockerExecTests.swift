import Darwin
import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

final class DockerExecTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/mp-exec-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testDetachedHVFExecReturnsLaunchSuccessForAnAlreadyExitedProcess() async throws {
        let engine = HVFEngine(root: root)
        let layout = engine.machine.layout
        try HVFMachineState(phase: .running, supervisorPID: getpid()).save(to: layout.state)
        let lock = try XCTUnwrap(HVFFileLock.acquire(layout.supervisorLock, wait: .zero))
        defer { lock.release() }
        let server = try DockerExecFixture(
            path: layout.dockerSocket.path, startReply: Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8))

        let result = try await engine.execDetailed(
            ContainerExecRequest(
                containerID: "web", arguments: ["sh", "-c", "exit 37"], detach: true,
                workdir: "/work", env: ["CI=1"]))

        XCTAssertEqual(result, ContainerExecResult(output: "", error: "", exitCode: 0))
        let requests = try server.requests()
        XCTAssertEqual(
            requests.map(\.line),
            [
                "POST /v1.44/containers/web/exec HTTP/1.1", "POST /v1.44/exec/exec-fixture/start HTTP/1.1",
            ])
        let create = try XCTUnwrap(requests.first).json()
        XCTAssertEqual(create["Cmd"] as? [String], ["sh", "-c", "exit 37"])
        XCTAssertEqual(create["Env"] as? [String], ["CI=1"])
        XCTAssertEqual(create["WorkingDir"] as? String, "/work")
        XCTAssertEqual(create["AttachStdin"] as? Bool, false)
        XCTAssertEqual(create["AttachStdout"] as? Bool, false)
        XCTAssertEqual(create["AttachStderr"] as? Bool, false)
        let start = try XCTUnwrap(requests.last).json()
        XCTAssertEqual(start["Detach"] as? Bool, true)
        XCTAssertEqual(start["Tty"] as? Bool, false)

        // The fixture finishes before acknowledging start. An explicit inspection
        // can still read its exit code after the adapter has returned success.
        let inspection = try await engine.machine.docker.request("GET", "/exec/exec-fixture/json")
        XCTAssertEqual((try inspection.json() as? [String: Int])?["ExitCode"], 37)
    }

    func testDetachedDockerExecAcceptsJSONAcknowledgement() async throws {
        let path = root.appendingPathComponent("docker.sock").path
        let server = try DockerExecFixture(path: path, startReply: DockerExecFixture.json("200 OK", "{}"))
        let result = try await DockerEngine(endpoint: path).exec(
            ContainerExecRequest(containerID: "web", arguments: ["true"], detach: true))
        XCTAssertEqual(result, "")
        XCTAssertEqual(try server.requests().count, 2)
    }

    func testDetachedExecPropagatesStartRejectionFromAnOlderGuest() async throws {
        let path = root.appendingPathComponent("docker.sock").path
        let reply = DockerExecFixture.json("400 Bad Request", #"{"message":"unsupported Docker option Detach"}"#)
        let server = try DockerExecFixture(path: path, startReply: reply)

        do {
            _ = try await DockerEngine(endpoint: path).exec(
                ContainerExecRequest(containerID: "web", arguments: ["true"], detach: true))
            XCTFail("A rejected start must throw")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "invalid_argument")
            XCTAssertTrue(error.localizedDescription.contains("unsupported Docker option Detach"))
        }
        XCTAssertEqual(try server.requests().count, 2)
    }

    func testDetachedExecRejectsAttachedResponsesWithoutWaitingForEOF() async throws {
        let replies = [
            "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.docker.raw-stream\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Type: Application/Vnd.Docker.Multiplexed-Stream; charset=binary\r\n\r\n",
        ]
        for (index, reply) in replies.enumerated() {
            let path = root.appendingPathComponent("docker-\(index).sock").path
            let server = try DockerExecFixture(path: path, startReply: Data(reply.utf8), holdStartOpen: true)
            do {
                _ = try await DockerEngine(endpoint: path).exec(
                    ContainerExecRequest(containerID: "web", arguments: ["true"], detach: true))
                XCTFail("An attached stream must not be treated as a detached start")
            } catch {
                XCTAssertEqual(ConnectCodeMapping.code(for: error), "unimplemented")
                XCTAssertTrue(error.localizedDescription.contains("returned an attached stream"))
            }
            XCTAssertTrue(server.clientClosedStart, "The adapter should close the connection after the headers")
            XCTAssertEqual(try server.requests().count, 2)
        }
    }

    func testAttachedExecStillCollectsBothStreamsAndInspectsTheExitCode() async throws {
        let path = root.appendingPathComponent("docker.sock").path
        let reply =
            Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: tcp\r\n\r\n".utf8)
            + Data([1, 0, 0, 0, 0, 0, 0, 3]) + Data("out".utf8)
            + Data([2, 0, 0, 0, 0, 0, 0, 4]) + Data("err\n".utf8)
        let server = try DockerExecFixture(path: path, startReply: reply)

        let result = try await DockerEngine(endpoint: path).execDetailed(
            ContainerExecRequest(containerID: "web", arguments: ["sh"]))

        XCTAssertEqual(result, ContainerExecResult(output: "out", error: "err\n", exitCode: 37))
        let requests = try server.requests()
        XCTAssertEqual(
            requests.map(\.line),
            [
                "POST /v1.43/containers/web/exec HTTP/1.1", "POST /v1.43/exec/exec-fixture/start HTTP/1.1",
                "GET /v1.43/exec/exec-fixture/json HTTP/1.1",
            ])
        let create = try XCTUnwrap(requests.first).json()
        XCTAssertEqual(create["AttachStdin"] as? Bool, false)
        XCTAssertEqual(create["AttachStdout"] as? Bool, true)
        XCTAssertEqual(create["AttachStderr"] as? Bool, true)
    }
}

/// A local Unix socket with only the endpoints needed for the exec exchange.
private final class DockerExecFixture: @unchecked Sendable {
    struct Request {
        let line: String
        let body: Data

        func json() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
    }

    private let queue = DispatchQueue(label: "docker-exec-fixture")
    private let listener: any DispatchSourceRead
    private let startReply: Data
    private let holdStartOpen: Bool
    private var received: [Request] = []
    private var failure: Error?
    private var closedStart = false

    var clientClosedStart: Bool { queue.sync { closedStart } }

    func requests() throws -> [Request] {
        try queue.sync {
            if let failure { throw failure }
            return received
        }
    }

    init(path: String, startReply: Data, holdStartOpen: Bool = false) throws {
        self.startReply = startReply
        self.holdStartOpen = holdStartOpen
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(fd)
            throw error
        }
        listener = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        listener.setCancelHandler { Darwin.close(fd) }
        listener.setEventHandler { [weak self] in self?.respond(to: fd) }
        listener.activate()
    }

    deinit { listener.cancel() }

    private func respond(to listener: Int32) {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSIGPIPE: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size))
        do {
            let request = try Self.read(from: fd)
            received.append(request)
            let reply: Data
            switch request.line.split(separator: " ").dropFirst().first?.split(separator: "/").last {
            case "exec": reply = Self.json("201 Created", #"{"Id":"exec-fixture"}"#)
            case "start": reply = startReply
            case "json": reply = Self.json("200 OK", #"{"ExitCode":37}"#)
            default: reply = Self.json("404 Not Found", #"{"message":"unexpected request"}"#)
            }
            try FileHandle(fileDescriptor: fd).write(contentsOf: reply)
            if holdStartOpen, reply == startReply {
                var byte: UInt8 = 0
                closedStart = Darwin.read(fd, &byte, 1) == 0
            }
        } catch {
            failure = error
        }
    }

    private static func read(from fd: Int32) throws -> Request {
        var request = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        let separator = Data("\r\n\r\n".utf8)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            guard count > 0 else { throw CocoaError(.fileReadCorruptFile) }
            request.append(contentsOf: bytes.prefix(count))
            guard let boundary = request.range(of: separator) else { continue }
            let headers = String(decoding: request[..<boundary.lowerBound], as: UTF8.self)
                .components(separatedBy: "\r\n")
            let length =
                headers.first { $0.lowercased().hasPrefix("content-length:") }?
                .split(separator: ":", maxSplits: 1).last.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
            let end = boundary.upperBound + length
            guard request.count >= end else { continue }
            return Request(line: headers[0], body: Data(request[boundary.upperBound..<end]))
        }
    }

    static func json(_ status: String, _ body: String) -> Data {
        Data(
            "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
                .utf8)
    }
}
