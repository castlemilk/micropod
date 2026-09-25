import MicropodCore
import XCTest

/// Spawns the built MicropodAPI binary against the mock CLI and drives it
/// over HTTP (Foundation URLSession) — the full HTTP surface.
final class MicropodAPITests: XCTestCase {
    private var server: Process!
    private var baseURL: URL!
    private var stateDir: URL!

    override func setUp() async throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("micropod-api-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try await launchServer()
    }

    override func tearDown() async throws {
        server?.terminate()
        try? FileManager.default.removeItem(at: stateDir)
    }

    /// Spawns the built binary against the mock CLI on a fresh port and waits
    /// for `/health`. `extraEnvironment` reaches the mock too (the CLI client
    /// forwards the server's environment), so tests can flip mock modes.
    private func launchServer(extraEnvironment: [String: String] = [:]) async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/MicropodIntegrationTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
        let binary = root.appendingPathComponent(".build/debug/MicropodAPI")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("MicropodAPI binary not built")
        }

        let port = UInt16.random(in: 45500...45999)
        baseURL = URL(string: "http://127.0.0.1:\(port)")!

        server = Process()
        server.executableURL = binary
        server.environment = ProcessInfo.processInfo.environment.merging(
            [
                "MICROPOD_CONTAINER_CLI_PATH": MockContainerCLI.scriptURL.path,
                "MICROPOD_MOCK_STATE_DIR": stateDir.path,
                "MICROPOD_API_PORT": String(port),
                "MICROPOD_VOLUME_POLICY": stateDir.appendingPathComponent("policy.json").path,
            ]
            .merging(extraEnvironment) { _, new in new }
        ) { _, new in new }
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()

        // Wait for /health.
        for _ in 0..<40 {
            if let data = try? await URLSession.shared.data(from: baseURL.appendingPathComponent("health")).0,
                String(data: data, encoding: .utf8)?.contains("ok") == true
            {
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw XCTSkip("API server did not come up")
    }

    /// Replaces the running server with one whose mock CLI emulates a stopped
    /// runtime (`MICROPOD_MOCK_RUNTIME_STOPPED=1`, see `Support/mock-container`).
    private func relaunchServerWithStoppedRuntime() async throws {
        server.terminate()
        server.waitUntilExit()
        try await launchServer(extraEnvironment: ["MICROPOD_MOCK_RUNTIME_STOPPED": "1"])
    }

    private func json(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertTrue([200, 201].contains(status), "\(method) \(path) returned \(status)")
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Same as `json` but returns the status — for expected-error paths.
    private func jsonStatus(_ method: String, _ path: String, body: [String: Any]? = nil) async throws
        -> (Int, [String: Any])
    {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }

    func testVolumePolicyEndpoints() async throws {
        let initial = try await json("GET", "v1/config/volumes")
        XCTAssertEqual(initial["cloneMode"] as? String, "labels")
        XCTAssertEqual(initial["cache"] as? String, "on")
        XCTAssertNil(initial["sync"])

        // Full update round-trips.
        let updated = try await json(
            "PUT", "v1/config/volumes",
            body: [
                "cloneMode": "goldens", "goldenVolumes": ["ci-golden"],
                "jobsOnly": true, "sync": "nosync", "cache": "auto",
            ])
        XCTAssertEqual(updated["cloneMode"] as? String, "goldens")
        XCTAssertEqual((updated["goldenVolumes"] as? [String]) ?? [], ["ci-golden"])
        XCTAssertEqual(updated["jobsOnly"] as? Bool, true)
        XCTAssertEqual(updated["sync"] as? String, "nosync")

        // Persisted — a second GET sees it (the runtime reads the same file).
        let reloaded = try await json("GET", "v1/config/volumes")
        XCTAssertEqual(reloaded["cloneMode"] as? String, "goldens")

        // Partial body merges onto defaults.
        let partial = try await json("PUT", "v1/config/volumes", body: ["cloneMode": "labels"])
        XCTAssertEqual(partial["cloneMode"] as? String, "labels")
        XCTAssertNil(partial["sync"])

        // Bad enum values are rejected with a useful error.
        let (badStatus, badBody) = try await jsonStatus(
            "PUT", "v1/config/volumes", body: ["cloneMode": "bogus"])
        XCTAssertEqual(badStatus, 400)
        XCTAssertTrue((badBody["error"] as? String ?? "").contains("cloneMode"))

        // Non-JSON body is rejected.
        var raw = URLRequest(url: baseURL.appendingPathComponent("v1/config/volumes"))
        raw.httpMethod = "PUT"
        raw.httpBody = Data("hello".utf8)
        let (_, rawResponse) = try await URLSession.shared.data(for: raw)
        XCTAssertEqual((rawResponse as? HTTPURLResponse)?.statusCode, 400)
    }

    func testFullAPISurface() async throws {
        // Health
        let health = try await json("GET", "health")
        XCTAssertEqual(health["status"] as? String, "ok")

        // System
        let system = try await json("GET", "v1/system")
        XCTAssertEqual(system["status"] as? String, "running")
        XCTAssertEqual(system["cliVersion"] as? String, "1.2.3")

        // Run + list
        let run = try await json(
            "POST", "v1/containers",
            body: ["image": "nginx:1.27", "name": "api-web", "env": ["API=1"]])
        let id = run["id"] as? String ?? ""
        XCTAssertFalse(id.isEmpty)

        let list = try await json("GET", "v1/containers")
        let containers = list["containers"] as? [[String: Any]] ?? []
        let mine = containers.first { $0["id"] as? String == id }
        XCTAssertEqual(mine?["state"] as? String, "running")
        XCTAssertEqual(mine?["image"] as? String, "nginx:1.27")
        XCTAssertFalse((mine?["ipv4Address"] as? String ?? "").isEmpty)

        // Create without start
        let created = try await json(
            "POST", "v1/containers/create", body: ["image": "alpine:3.20", "name": "api-created"])
        let createdID = created["id"] as? String ?? ""
        let afterCreate = try await json("GET", "v1/containers")
        let createdEntry = (afterCreate["containers"] as? [[String: Any]] ?? [])
            .first { $0["id"] as? String == createdID }
        XCTAssertEqual(createdEntry?["state"] as? String, "created", "create must not start the container")

        // Lifecycle
        _ = try await json("POST", "v1/containers/\(id)/stop")
        let stopped = try await json("GET", "v1/containers")
        XCTAssertEqual(
            (stopped["containers"] as? [[String: Any]])?.first { $0["id"] as? String == id }?["state"] as? String,
            "stopped")
        _ = try await json("POST", "v1/containers/\(id)/restart")
        let restarted = try await json("GET", "v1/containers")
        XCTAssertEqual(
            (restarted["containers"] as? [[String: Any]])?.first { $0["id"] as? String == id }?["state"] as? String,
            "running")

        // Exec
        let exec = try await json("POST", "v1/exec", body: ["id": id, "command": "echo api-ok"])
        XCTAssertTrue((exec["output"] as? String)?.contains("ok") ?? false)

        // Volumes
        _ = try await json("POST", "v1/volumes", body: ["name": "api-vol", "size": "20M"])
        let volumes = try await json("GET", "v1/volumes")
        let volume = (volumes["volumes"] as? [[String: Any]])?.first { $0["id"] as? String == "api-vol" }
        XCTAssertEqual(volume?["sizeBytes"] as? UInt64, 20_971_520)

        // Networks
        _ = try await json("POST", "v1/networks", body: ["name": "api-net", "subnet": "10.88.0.0/24"])
        let networks = try await json("GET", "v1/networks")
        let network = (networks["networks"] as? [[String: Any]])?.first { $0["id"] as? String == "api-net" }
        XCTAssertEqual(network?["ipv4Subnet"] as? String, "10.88.0.0/24")

        // Images
        _ = try await json("POST", "v1/images/pull", body: ["reference": "redis:7"])
        let images = try await json("GET", "v1/images")
        XCTAssertTrue(
            (images["images"] as? [[String: Any]])?.contains { ($0["names"] as? [String])?.contains("redis:7") == true }
                ?? false)

        // Stats
        let stats = try await json("GET", "v1/stats")
        let statEntries = stats["containers"] as? [[String: Any]] ?? []
        XCTAssertTrue(statEntries.contains { $0["id"] as? String == id })

        // Compose up
        let composeDir = stateDir.appendingPathComponent("compose")
        try FileManager.default.createDirectory(at: composeDir, withIntermediateDirectories: true)
        try """
        name: apistack
        services:
          web:
            image: nginx:1.27
        """.write(
            to: composeDir.appendingPathComponent("docker-compose.yml"), atomically: true, encoding: .utf8)
        let up = try await json(
            "POST", "v1/compose/up", body: ["path": composeDir.appendingPathComponent("docker-compose.yml").path])
        XCTAssertEqual(up["name"] as? String, "apistack")

        // Cleanup
        _ = try await json("DELETE", "v1/containers/\(id)")
        _ = try await json("DELETE", "v1/containers/\(createdID)")
        _ = try await json("DELETE", "v1/volumes/api-vol")
        _ = try await json("DELETE", "v1/networks/api-net")
    }

    func testSSELogsStream() async throws {
        _ = try await json(
            "POST", "v1/containers",
            body: ["image": "nginx:1.27", "name": "api-logs", "arguments": ["echo", "api-boot"]])

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/containers/api-logs/logs"))
        request.httpMethod = "GET"
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(
            (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")

        var collected = ""
        for try await line in bytes.lines.prefix(4) {
            collected += line + "\n"
        }
        XCTAssertTrue(collected.contains("data: mock log line"), "SSE events: \(collected)")
    }
    /// Connect server-streams end with an EndStream frame (flag 0x02). The
    /// server must not close the socket until that frame has been flushed —
    /// connect-go otherwise fails the stream with "protocol error: unexpected
    /// EOF". Streams a container that has already stopped so the backlog is
    /// finite and the trailer is the very last thing on the wire.
    func testConnectStreamEndFrameIsDelivered() async throws {
        let run = try await json(
            "POST", "v1/containers",
            body: ["image": "nginx:1.27", "name": "api-endframe", "arguments": ["echo", "api-boot"]])
        let id = run["id"] as? String ?? ""
        XCTAssertFalse(id.isEmpty)
        _ = try await json("POST", "v1/containers/\(id)/stop")

        let payload = try JSONSerialization.data(withJSONObject: ["id": id, "tail": 5])
        var request = URLRequest(
            url: baseURL.appendingPathComponent("api/micropod.v1.ContainerService/StreamContainerLogs"))
        request.httpMethod = "POST"
        request.setValue("application/connect+json", forHTTPHeaderField: "Content-Type")
        request.httpBody = ConnectFrames.envelope(payload, flags: 0)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        XCTAssertEqual(http?.statusCode, 200)
        XCTAssertEqual(http?.value(forHTTPHeaderField: "Content-Type"), "application/connect+json")

        let parsed = ConnectFrames.parse(data)
        XCTAssertEqual(parsed.trailing, 0, "response ended mid-frame with \(parsed.trailing) stray bytes")
        let dataFrames = parsed.frames.filter { $0.flags == 0 }
        XCTAssertGreaterThanOrEqual(dataFrames.count, 1, "expected at least one LogChunk data frame")
        for frame in dataFrames {
            let chunk = try JSONSerialization.jsonObject(with: frame.payload) as? [String: Any]
            XCTAssertTrue(
                (chunk?["text"] as? String ?? "").contains("mock log line"),
                "unexpected LogChunk: \(String(decoding: frame.payload, as: UTF8.self))")
        }
        guard let last = parsed.frames.last else {
            return XCTFail("no complete frames in a \(data.count)-byte body")
        }
        XCTAssertEqual(last.flags, 0x02, "last frame must be the EndStream trailer, got flags \(last.flags)")
        let trailer = String(decoding: last.payload, as: UTF8.self)
        XCTAssertTrue(trailer == "{}" || trailer.contains("\"error\""), "EndStream body: \(trailer)")
    }

    /// `Ping` is the millisecond liveness probe for detection and health
    /// ticks: status, live backend, versions — no `df`. `GetSystem` carries
    /// the same `runtimeBackend` alongside its disk usage.
    func testPingRunning() async throws {
        let (status, ping) = try await jsonStatus("POST", "api/micropod.v1.SystemService/Ping", body: [:])
        XCTAssertEqual(status, 200)
        XCTAssertEqual(ping["status"] as? String, "running")
        XCTAssertEqual(ping["runtimeBackend"] as? String, "cli")
        XCTAssertEqual(ping["cliVersion"] as? String, "1.2.3")
        XCTAssertFalse((ping["apiServerVersion"] as? String ?? "").isEmpty, "Ping: \(ping)")

        let (systemStatus, system) = try await jsonStatus(
            "POST", "api/micropod.v1.SystemService/GetSystem", body: [:])
        XCTAssertEqual(systemStatus, 200)
        let snapshotStatus = system["status"] as? [String: Any]
        XCTAssertEqual(snapshotStatus?["status"] as? String, "running")
        XCTAssertEqual(snapshotStatus?["runtimeBackend"] as? String, "cli")
        XCTAssertNotNil(system["diskUsage"], "GetSystem on a running runtime includes disk usage")

        let rest = try await json("GET", "v1/system")
        XCTAssertEqual(rest["runtimeBackend"] as? String, "cli")
        XCTAssertNotNil(rest["diskUsage"])
    }

    /// A stopped runtime is a status, not an error — and it must be reported
    /// fast: the CLI answers "unregistered" immediately, so neither `Ping`
    /// nor `GetSystem` may sit out a 15 s CLI ceiling or fall over on `df`.
    /// Runtime-backed RPCs, by contrast, are `unavailable` (503), so clients
    /// know to back off rather than treat the outage as a server bug.
    func testPingReportsStoppedRuntimeFast() async throws {
        try await relaunchServerWithStoppedRuntime()

        let clock = ContinuousClock()
        let started = clock.now
        let (status, ping) = try await jsonStatus("POST", "api/micropod.v1.SystemService/Ping", body: [:])
        let elapsed = started.duration(to: clock.now)
        XCTAssertEqual(status, 200, "Ping: \(ping)")
        XCTAssertEqual(ping["status"] as? String, "stopped")
        XCTAssertEqual(ping["runtimeBackend"] as? String, "cli")
        XCTAssertEqual(ping["cliVersion"] as? String, "1.2.3", "the CLI version is still known offline")
        XCTAssertLessThan(elapsed, .seconds(2), "Ping took \(elapsed) against a stopped runtime")

        let (systemStatus, system) = try await jsonStatus(
            "POST", "api/micropod.v1.SystemService/GetSystem", body: [:])
        XCTAssertEqual(systemStatus, 200, "GetSystem: \(system)")
        let snapshotStatus = system["status"] as? [String: Any]
        XCTAssertEqual(snapshotStatus?["status"] as? String, "stopped")
        XCTAssertEqual(snapshotStatus?["runtimeBackend"] as? String, "cli")
        XCTAssertNil(system["diskUsage"], "no df totals for a stopped runtime: \(system)")

        let (restStatus, rest) = try await jsonStatus("GET", "v1/system")
        XCTAssertEqual(restStatus, 200, "GET /v1/system: \(rest)")
        XCTAssertEqual(rest["status"] as? String, "stopped")
        XCTAssertEqual(rest["runtimeBackend"] as? String, "cli")
        XCTAssertNil(rest["diskUsage"])

        // Runtime-backed RPC → unavailable, with the proper reason phrase.
        let port = UInt16(baseURL.port ?? 0)
        let body = "{}"
        let request =
            "POST /api/micropod.v1.ContainerService/ListContainers HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(port)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n" + body
        let response = try await Task.detached { try RawHTTP.exchange(port: port, request: request) }.value
        let statusLine = response.components(separatedBy: "\r\n").first ?? ""
        XCTAssertEqual(statusLine, "HTTP/1.1 503 Service Unavailable", "raw response:\n\(response)")
        XCTAssertTrue(response.contains("\"code\":\"unavailable\""), "raw response:\n\(response)")
    }

    /// URLSession hides the reason phrase, so read the status line off the
    /// socket: a Connect validation failure must be `400 Bad Request`, not
    /// `400 Unknown`. (The 503 path is covered by
    /// `testPingReportsStoppedRuntimeFast` via the mock's stopped mode.)
    func testConnectErrorStatusLineCarriesReasonPhrase() async throws {
        let port = UInt16(baseURL.port ?? 0)
        let body = "{}"
        let request =
            "POST /api/micropod.v1.ContainerService/StartContainer HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(port)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n" + body
        let response = try await Task.detached { try RawHTTP.exchange(port: port, request: request) }.value
        let statusLine = response.components(separatedBy: "\r\n").first ?? ""
        XCTAssertEqual(statusLine, "HTTP/1.1 400 Bad Request", "raw response:\n\(response)")
        XCTAssertTrue(response.contains("\"code\":\"invalid_argument\""), "raw response:\n\(response)")
    }
}

/// Connect envelope framing for the tests — [flags:1][length:4 big-endian][payload].
enum ConnectFrames {
    struct Frame {
        let flags: UInt8
        let payload: Data
    }

    static func envelope(_ payload: Data, flags: UInt8) -> Data {
        let length = UInt32(payload.count)
        var out = Data([flags])
        out.append(contentsOf: [
            UInt8(length >> 24), UInt8((length >> 16) & 0xff), UInt8((length >> 8) & 0xff), UInt8(length & 0xff),
        ])
        out.append(payload)
        return out
    }

    /// Splits a response body into complete frames. `trailing` is the number
    /// of bytes left after the last complete frame — non-zero means the
    /// connection was cut mid-frame.
    static func parse(_ data: Data) -> (frames: [Frame], trailing: Int) {
        var frames: [Frame] = []
        var offset = data.startIndex
        while data.endIndex - offset >= 5 {
            let flags = data[offset]
            let length =
                Int(data[offset + 1]) << 24 | Int(data[offset + 2]) << 16
                | Int(data[offset + 3]) << 8 | Int(data[offset + 4])
            let start = offset + 5
            guard data.endIndex - start >= length else { break }
            frames.append(Frame(flags: flags, payload: Data(data[start..<(start + length)])))
            offset = start + length
        }
        return (frames, data.endIndex - offset)
    }
}

/// Minimal blocking HTTP/1.1 exchange over a POSIX socket, for tests that
/// need the raw status line (reason phrase) URLSession does not expose.
enum RawHTTP {
    static func exchange(port: UInt16, request: String) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }

        let bytes = Array(request.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBufferPointer { send(fd, $0.baseAddress! + sent, bytes.count - sent, 0) }
            guard n > 0 else { throw POSIXError(.EPIPE) }
            sent += n
        }

        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            out.append(buffer, count: n)
        }
        return String(decoding: out, as: UTF8.self)
    }
}
