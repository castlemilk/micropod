import Foundation
import XCTest

@testable import MicropodCore

/// End-to-end validation of the Docker Engine shim against the REAL Apple
/// container runtime, including a REAL testcontainers/ryuk reaper session:
/// create → hijacked exec → wait → logs → ryuk filter ACK → disconnect →
/// labeled victim reaped through the shim while a bystander survives.
///
/// Run: MICROPOD_REAL_E2E=1 swift test --filter RealShimTests
@MainActor
final class RealShimTests: XCTestCase {
    private static let ryukImage = "testcontainers/ryuk:0.14.0"

    private var shimProcess: Process?
    private var socketPath: String = ""
    private var tcpPort: UInt16 = 45990
    private let client = ContainerCLIClient()
    private let containerService = ContainerService(client: ContainerCLIClient())

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["MICROPOD_REAL_E2E"] == "1" else {
            throw XCTSkip("set MICROPOD_REAL_E2E=1 to run real-runtime tests")
        }
        guard client.isAvailable() else { throw XCTSkip("`container` CLI not available") }
        try await withTimeout(seconds: 90) { try await Self.pullRyukIfNeeded() }
    }

    override func tearDown() async throws {
        shimProcess?.terminate()
        shimProcess?.waitUntilExit()
        if !socketPath.isEmpty { try? FileManager.default.removeItem(atPath: socketPath) }
        // Ryuk reaps labeled victims; clean the survivors ourselves.
        if let survivors = try? await containerService.list() {
            for container in survivors where container.id.hasPrefix("realshim-") {
                try? await containerService.delete(container.id, force: true)
            }
        }
    }

    private static func pullRyukIfNeeded() async throws {
        let images = try await ImageService(client: ContainerCLIClient()).list()
        guard !images.contains(where: { $0.names.contains(ryukImage) }) else { return }
        let stream = ImageService(client: ContainerCLIClient()).pull(ryukImage)
        for try await _ in stream {}
    }

    /// Spawns .build/debug/micropod-docker-shim with an isolated socket+port.
    private func launchShim() async throws {
        let binary = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/micropod-docker-shim")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("shim binary not built: \(binary.path)")
        }
        socketPath = "/tmp/rshim-\(UUID().uuidString.prefix(8).lowercased()).sock"
        let process = Process()
        process.executableURL = binary
        process.environment = [
            "MICROPOD_SHIM_SOCKET": socketPath,
            "MICROPOD_SHIM_TCP_PORT": "\(tcpPort)",
            "MICROPOD_SHIM_BRIDGE": "192.168.64.1",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        shimProcess = process

        let docker = HTTPOverUnix(socketPath: socketPath)
        var ready = false
        for _ in 0..<100 where !ready {
            if let response = try? docker.request("GET", "/_ping"), response.status == 200 {
                ready = true
            } else {
                usleep(100_000)
            }
        }
        XCTAssertTrue(ready, "shim never answered _ping")
    }

    func testRealLifecycleExecAndRyukReap() async throws {
        try await launchShim()
        let docker = HTTPOverUnix(socketPath: socketPath)
        let session = "reap-\(UUID().uuidString.prefix(6))"

        // Lifecycle: create → start → wait(0) → logs → delete.
        let victim = "realshim-\(session)-victim"
        let create = try docker.request(
            "POST", "/containers/create?name=\(victim)",
            body: Self.json([
                "Image": "alpine:3.20", "Cmd": ["sh", "-c", "echo boot; sleep 5"],
                "Labels": ["org.testcontainers.session-id": session],
            ]))
        XCTAssertEqual(create.status, 201, String(decoding: create.body, as: UTF8.self))

        XCTAssertEqual(try docker.request("POST", "/containers/\(victim)/start").status, 204)

        // Exec over hijack must produce stdcopy-framed stdout.
        let exec = try docker.request(
            "POST", "/containers/\(victim)/exec",
            body: Self.json(["Cmd": ["echo", "real-exec"], "AttachStdout": true]))
        XCTAssertEqual(exec.status, 201)
        let execID = try Self.field(exec.body, "Id")
        let (upgraded, framed) = try docker.hijack(
            "POST", "/exec/\(execID)/start", body: Data("{}".utf8))
        XCTAssertTrue(upgraded.contains("101"), upgraded)
        XCTAssertEqual(Self.frameType(framed), 1)
        XCTAssertEqual(Self.framePayload(framed), "real-exec\n")

        // Wait + logs.
        let wait = try docker.request("POST", "/containers/\(victim)/wait?condition=not-running")
        XCTAssertEqual(try Self.field(wait.body, "StatusCode"), "0")
        let logs = try docker.request("GET", "/containers/\(victim)/logs?stdout=1&tail=5")
        XCTAssertTrue(Self.framePayload(logs.body).contains("boot"))

        XCTAssertEqual(try docker.request("DELETE", "/containers/\(victim)?force=true").status, 204)

        // Ryuk: bystander (no label) + victim2 (labeled) + reaper via shim.
        let bystander = "realshim-\(session)-bystander"
        _ = try docker.request(
            "POST", "/containers/create?name=\(bystander)",
            body: Self.json(["Image": "alpine:3.20", "Cmd": ["sleep", "600"]]))
        XCTAssertEqual(try docker.request("POST", "/containers/\(bystander)/start").status, 204)

        let victim2 = "realshim-\(session)-victim2"
        _ = try docker.request(
            "POST", "/containers/create?name=\(victim2)",
            body: Self.json([
                "Image": "alpine:3.20", "Cmd": ["sleep", "600"],
                "Labels": ["org.testcontainers.session-id": session],
            ]))
        XCTAssertEqual(try docker.request("POST", "/containers/\(victim2)/start").status, 204)

        let reaper = "realshim-\(session)-reaper"
        let ryukCreate = try docker.request(
            "POST", "/containers/create?name=\(reaper)",
            body: Self.json([
                "Image": Self.ryukImage,
                "Labels": ["org.testcontainers": "true"],
                "Env": ["DOCKER_HOST=unix:///var/run/docker.sock"],
                "HostConfig": [
                    "Binds": ["/var/run/docker.sock:/var/run/docker.sock"],
                    "PortBindings": ["8080/tcp": [[:]]],
                ],
            ]))
        XCTAssertEqual(ryukCreate.status, 201, String(decoding: ryukCreate.body, as: UTF8.self))
        XCTAssertEqual(try docker.request("POST", "/containers/\(reaper)/start").status, 204)

        // Inspect must show the intercepted env + stripped bind.
        let inspect = try docker.request("GET", "/containers/\(reaper)/json")
        let env = try Self.arrayField(inspect.body, "Env", containerPath: "Config")
        XCTAssertTrue(
            env.contains("DOCKER_HOST=tcp://192.168.64.1:\(tcpPort)"), "env: \(env)")

        // Find the published 8080 port and run the reaper session.
        let portsJSON = try Self.portsField(inspect.body)
        let hostPortString = try XCTUnwrap(
            portsJSON["8080/tcp"]?.first?["HostPort"] as? String, "no published 8080")
        let hostPort = try XCTUnwrap(Int(hostPortString))
        let ack = try ryukSession(hostPort: hostPort, session: session)
        XCTAssertEqual(ack, "ACK")

        // After the session disconnects, ryuk reaps ONLY labeled resources.
        try await waitUntil(seconds: 45) {
            (try? await self.containerService.list())?.contains { $0.id == victim2 } == false
        }
        let survivors = try await containerService.list()
        XCTAssertFalse(
            survivors.contains { $0.id.contains(victim2) }, "victim2 must be reaped")
        XCTAssertTrue(
            survivors.contains { $0.id == bystander }, "bystander must survive the reap")
    }

    // MARK: - Helpers

    private func ryukSession(hostPort: Int, session: String) throws -> String {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(hostPort).bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }

        let filter = "labels=org.testcontainers.session-id=\(session)\r\n"
        _ = filter.withCString { Darwin.write(fd, $0, strlen($0)) }

        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        var buffer = [UInt8](repeating: 0, count: 256)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            guard poll(&pollFD, 1, 500) > 0 else { continue }
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            return String(decoding: buffer[0..<n], as: UTF8.self).trimmingCharacters(
                in: .whitespacesAndNewlines)
        }
        throw XCTFailureString("ryuk never ACKed")
    }

    private func waitUntil(seconds: TimeInterval, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CancellationError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    static func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    static func field(_ data: Data, _ key: String) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        if let value = object[key] as? String { return value }
        if let value = object[key] as? Int { return String(value) }
        throw XCTFailureString("missing or non-scalar field \(key)")
    }

    static func arrayField(_ data: Data, _ key: String, containerPath: String?) throws -> [String] {
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let scope =
            containerPath.map { path -> [String: Any] in
                (object[path] as? [String: Any]) ?? [:]
            } ?? object
        return (scope[key] as? [String]) ?? []
    }

    static func portsField(_ data: Data) throws -> [String: [[String: Any]]] {
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let network = object["NetworkSettings"] as! [String: Any]
        return (network["Ports"] as? [String: [[String: Any]]]) ?? [:]
    }

    static func frameType(_ data: Data) -> UInt8? {
        guard data.count >= 8 else { return nil }
        return data[data.startIndex]
    }

    static func framePayload(_ data: Data) -> String {
        guard data.count >= 8 else { return "" }
        let length =
            Int(data[data.startIndex + 4]) << 24 | Int(data[data.startIndex + 5]) << 16
            | Int(data[data.startIndex + 6]) << 8 | Int(data[data.startIndex + 7])
        let start = data.index(data.startIndex + 8, offsetBy: 0)
        let end = data.index(start, offsetBy: min(length, data.count - 8))
        return String(decoding: data[start..<end], as: UTF8.self)
    }
}

struct XCTFailureString: Error {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Unix-socket HTTP client with raw hijack support for real-runtime tests.
struct HTTPOverUnix {
    let socketPath: String

    struct Response {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private func connectFD() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            throw POSIXError(.ECONNREFUSED)
        }
        return fd
    }

    func request(
        _ method: String, _ path: String, body: Data? = nil, timeout: TimeInterval = 60
    ) throws -> Response {
        let fd = try connectFD()
        defer { Darwin.close(fd) }
        var request = "\(method) \(path) HTTP/1.1\r\nHost: d\r\nConnection: close\r\n"
        if let body { request += "Content-Length: \(body.count)\r\n" }
        request += "\r\n"
        try writeAll(fd, Data(request.utf8))
        if let body { try writeAll(fd, body) }

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(timeout)
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while Date() < deadline {
            guard poll(&pollFD, 1, 500) > 0 else { continue }
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            received.append(contentsOf: buffer[0..<n])
            if let headEnd = received.range(of: Data("\r\n\r\n".utf8)) {
                // A response without Content-Length is delimited by the close
                // (the shim streams `/wait`, `/events` and follow-logs that
                // way, so headers can go out before the body exists). Keep
                // reading until EOF rather than treating it as a zero-length
                // body — that read the wait result as empty.
                if let length = contentLength(received, headEnd) {
                    if received.count - headEnd.upperBound >= length { break }
                }
            }
        }
        return try Self.parse(received)
    }

    /// Sends an upgrade request; returns (head, raw bytes after head).
    func hijack(_ method: String, _ path: String, body: Data, timeout: TimeInterval = 30) throws
        -> (String, Data)
    {
        let fd = try connectFD()
        defer { Darwin.close(fd) }
        var request = "\(method) \(path) HTTP/1.1\r\nHost: d\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n"
        request += "Content-Length: \(body.count)\r\n\r\n"
        try writeAll(fd, Data(request.utf8))
        try writeAll(fd, body)

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(timeout)
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while Date() < deadline {
            guard poll(&pollFD, 1, 500) > 0 else { continue }
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            received.append(contentsOf: buffer[0..<n])
            if let headEnd = received.range(of: Data("\r\n\r\n".utf8)) {
                let rest = received.distance(from: headEnd.upperBound, to: received.endIndex)
                if rest >= 8 + 10 { break }  // frame + minimal payload
            }
        }
        guard let headEnd = received.range(of: Data("\r\n\r\n".utf8)) else {
            throw XCTFailureString("no head in hijack response")
        }
        let head = String(decoding: received[received.startIndex..<headEnd.lowerBound], as: UTF8.self)
        return (head, Data(received[headEnd.upperBound...]))
    }

    /// The declared body length, or nil when the response carries none and is
    /// therefore delimited by the connection closing.
    private func contentLength(_ data: Data, _ headEnd: Range<Data.Index>) -> Int? {
        let head = String(decoding: data[data.startIndex..<headEnd.lowerBound], as: UTF8.self)
        for line in head.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return nil
    }

    private func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var sent = 0
            while sent < raw.count {
                let n = send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                guard n > 0 else { throw POSIXError(.EIO) }
                sent += n
            }
        }
    }

    static func parse(_ data: Data) throws -> Response {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw XCTFailureString("no header terminator")
        }
        let head = String(decoding: data[data.startIndex..<headEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let status = Int(lines.first!.split(separator: " ")[1])!
        var headers = [String: String]()
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                headers[parts[0].lowercased()] =
                    parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return Response(status: status, headers: headers, body: Data(data[headEnd.upperBound...]))
    }
}
