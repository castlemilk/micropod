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
                // Never read or write the developer's real engine config.
                "MICROPOD_RUNTIMES_CONFIG": stateDir.appendingPathComponent("runtimes.json").path,
                // Deterministic engine availability: no real Docker daemon.
                "DOCKER_HOST": "unix:///nonexistent/docker.sock",
                // Clone images never leave the test's state dir — commit
                // tests pre-create `<root>/<container>/<volume>.img` here.
                "MICROPOD_VOLUME_CLONE_ROOT": stateDir.appendingPathComponent("clones").path,
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
        try await relaunchServer(extraEnvironment: ["MICROPOD_MOCK_RUNTIME_STOPPED": "1"])
    }

    /// Replaces the running server with one started under extra environment
    /// (mock modes are env-driven; the state directory is kept).
    private func relaunchServer(extraEnvironment: [String: String]) async throws {
        await server.stopBounded()
        try await launchServer(extraEnvironment: extraEnvironment)
    }

    /// Every argv the mock CLI has received so far, one line per call with
    /// each element `%q`-quoted (see `Support/mock-container`). The lines
    /// are the ground truth for "what did the server ask the CLI to do".
    private func mockCalls() -> [String] {
        let url = stateDir.appendingPathComponent("calls.log")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func json(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        // Every POST names a non-simple type, body or not (LocalRequestGuard).
        if body != nil || method == "POST" {
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
        let (status, data) = try await rawStatus(method, path, body: body)
        return (status, (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }

    /// The status and the raw body — for asserting that a body parses at all.
    private func rawStatus(_ method: String, _ path: String, body: [String: Any]? = nil) async throws
        -> (Int, Data)
    {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        // Every POST names a non-simple type, body or not (LocalRequestGuard).
        if body != nil || method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
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
        raw.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
        XCTAssertNotNil(statEntries.first { $0["id"] as? String == id }?["blockIoObserved"] as? Bool)

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

    /// A server-streaming request whose envelope length byte is >= 0x80
    /// (here 0xB8: a 184-byte PullImage message) is not valid UTF-8. The
    /// parser used to decode the whole request as UTF-8 and, on failure,
    /// wait for more bytes forever — the client hung to its deadline with no
    /// pull, no progress and no error. Both body framings must dispatch.
    func testServerStreamWith184ByteRequestBodyGetsResponse() async throws {
        let port = UInt16(baseURL.port ?? 0)
        func payload(_ reference: String) throws -> Data {
            var json = Data("{\"reference\":\"\(reference)\"}".utf8)
            json.append(Data(repeating: UInt8(ascii: " "), count: 184 - json.count))
            XCTAssertEqual(json.count, 184)
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: json))
            return json
        }
        func assertPullCompleted(_ body: Data, _ reference: String) {
            let frames = ConnectFrames.parse(body).frames
            XCTAssertEqual(frames.last?.flags, 0x02, "PullImage must end with EndStream: \(frames.count) frames")
            XCTAssertEqual(frames.last.map { String(decoding: $0.payload, as: UTF8.self) }, "{}")
            XCTAssertTrue(
                mockCalls().contains { $0.hasPrefix("image pull ") && $0.hasSuffix(" \(reference)") },
                "\(mockCalls())")
        }

        // Content-Length framing (URLSession).
        let lengthRef = "pin/regress-length:1"
        let envelope = ConnectFrames.envelope(try payload(lengthRef), flags: 0)
        XCTAssertEqual(envelope[4], 0xB8)
        var request = URLRequest(url: baseURL.appendingPathComponent("api/micropod.v1.ImageService/PullImage"))
        request.httpMethod = "POST"
        request.setValue("application/connect+json", forHTTPHeaderField: "Content-Type")
        request.httpBody = envelope
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        assertPullCompleted(data, lengthRef)

        // Chunked framing (what Go's http client sends for a streaming
        // body), split across writes so the head and body arrive in pieces.
        let chunkedRef = "pin/regress-chunked:1"
        let chunkedEnvelope = ConnectFrames.envelope(try payload(chunkedRef), flags: 0)
        var wire = Data(
            ("POST /api/micropod.v1.ImageService/PullImage HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
                + "Content-Type: application/connect+json\r\nTransfer-Encoding: chunked\r\n\r\n").utf8)
        wire.append(Data("5\r\n".utf8))
        wire.append(chunkedEnvelope.prefix(5))
        wire.append(Data("\r\n\(String(184, radix: 16))\r\n".utf8))
        wire.append(chunkedEnvelope.dropFirst(5))
        wire.append(Data("\r\n0\r\n\r\n".utf8))
        let raw = try await Task.detached { [wire] in
            try RawHTTP.exchange(port: port, bytes: wire, pieces: 7)
        }.value
        let headEnd = try XCTUnwrap(raw.range(of: Data("\r\n\r\n".utf8)))
        XCTAssertTrue(
            String(decoding: raw[..<headEnd.lowerBound], as: UTF8.self).hasPrefix("HTTP/1.1 200"),
            String(decoding: raw, as: UTF8.self))
        assertPullCompleted(Data(raw[headEnd.upperBound...]), chunkedRef)
    }

    /// Malformed framing is answered (400/413), not waited on.
    func testMalformedRequestsAreAnsweredNotAwaited() async throws {
        let port = UInt16(baseURL.port ?? 0)
        let cases: [(String, String)] = [
            ("POST /v1/containers HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: nope\r\n\r\n", "400"),
            (
                "POST /v1/containers HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 999999999999\r\n\r\n",
                "413"
            ),
            (
                "POST /v1/containers HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n",
                "400"
            ),
            ("TRACE /v1/containers HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n", "405"),
        ]
        for (request, status) in cases {
            let raw = try await Task.detached { try RawHTTP.exchange(port: port, request: request) }.value
            XCTAssertTrue(raw.hasPrefix("HTTP/1.1 \(status) "), "\(request.debugDescription) -> \(raw)")
        }
    }

    /// A client that sends half a request and goes quiet gets 408 instead of
    /// holding the connection.
    func testStalledRequestTimesOut() async throws {
        try await relaunchServer(extraEnvironment: ["MICROPOD_API_READ_IDLE_TIMEOUT_MS": "300"])
        let port = UInt16(baseURL.port ?? 0)
        let request =
            "POST /v1/containers HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\n"
            + "Content-Length: 100\r\n\r\n{\"image\""
        let started = Date()
        let raw = try await Task.detached { try RawHTTP.exchange(port: port, request: request) }.value
        XCTAssertTrue(raw.hasPrefix("HTTP/1.1 408 Request Timeout"), raw)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertFalse(mockCalls().contains { $0.hasPrefix("run ") || $0.hasPrefix("create ") }, "\(mockCalls())")
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

    // MARK: Cross-site / DNS-rebinding admission (LocalRequestGuard)

    /// One raw exchange with full control over Host / Origin / Content-Type;
    /// returns the status code and the raw response.
    private func rawExchange(
        _ method: String = "POST", path: String = "/api/micropod.v1.SystemService/Ping",
        host: String? = nil, contentType: String? = "application/json", origin: String? = nil,
        body: String = "{}"
    ) async throws -> (Int, String) {
        let port = UInt16(baseURL.port ?? 0)
        var request = "\(method) \(path) HTTP/1.1\r\n"
        request += "Host: \(host ?? "127.0.0.1:\(port)")\r\n"
        if let contentType { request += "Content-Type: \(contentType)\r\n" }
        if let origin { request += "Origin: \(origin)\r\n" }
        request += "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        let raw = try await Task.detached { [request] in try RawHTTP.exchange(port: port, request: request) }.value
        let statusLine = raw.components(separatedBy: "\r\n").first ?? ""
        let code = Int(statusLine.split(separator: " ").dropFirst().first ?? "") ?? 0
        return (code, raw)
    }

    /// The review's live repro: a no-preflight `text/plain` cross-site Ping
    /// (with a rebinding Host) returned 200. Now: 403 for a foreign Host or
    /// Origin, 415 for a CORS-simple Content-Type, 200 for real clients.
    func testCrossSiteSimpleRequestsAreRefused() async throws {
        let port = UInt16(baseURL.port ?? 0)
        var (code, raw) = try await rawExchange(
            host: "evil.example", contentType: "text/plain", origin: "http://evil.example")
        XCTAssertEqual(code, 403, raw)
        XCTAssertTrue(raw.contains("HTTP/1.1 403 Forbidden"), raw)
        XCTAssertTrue(raw.contains("permission_denied"), raw)

        (code, raw) = try await rawExchange(contentType: "text/plain", origin: "http://evil.example")
        XCTAssertEqual(code, 403, raw)
        XCTAssertFalse(raw.lowercased().contains("access-control-allow-origin"), raw)

        (code, raw) = try await rawExchange(contentType: "text/plain")
        XCTAssertEqual(code, 415, raw)
        XCTAssertTrue(raw.contains("HTTP/1.1 415 Unsupported Media Type"), raw)

        (code, raw) = try await rawExchange(contentType: "application/x-www-form-urlencoded", body: "a=b")
        XCTAssertEqual(code, 415, raw)

        // Rebinding: same-origin to the attacker's name, so no Origin at all.
        (code, raw) = try await rawExchange(host: "evil.example:\(port)")
        XCTAssertEqual(code, 403, raw)
        (code, raw) = try await rawExchange(
            "GET", path: "/v1/containers", host: "evil.example:\(port)", contentType: nil, body: "")
        XCTAssertEqual(code, 403, "reads are rebinding targets too: \(raw)")

        // A body-less POST is still a CORS-simple request.
        (code, raw) = try await rawExchange(path: "/v1/containers/x/kill", contentType: nil, body: "")
        XCTAssertEqual(code, 415, raw)

        // Nothing reached a handler: the mock CLI was never asked to act.
        XCTAssertFalse(mockCalls().contains { $0.contains("kill") }, "\(mockCalls())")
    }

    func testLegitimateClientsStillPass() async throws {
        let port = UInt16(baseURL.port ?? 0)
        for host in ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"] {
            let (code, raw) = try await rawExchange(host: host)
            XCTAssertEqual(code, 200, "\(host): \(raw)")
        }
        var (code, raw) = try await rawExchange(contentType: "application/json; charset=utf-8")
        XCTAssertEqual(code, 200, raw)
        (code, raw) = try await rawExchange("GET", path: "/health", contentType: nil, body: "")
        XCTAssertEqual(code, 200, raw)
        // `curl -X DELETE` sends no Content-Type; browsers always preflight DELETE.
        (code, raw) = try await rawExchange("DELETE", path: "/v1/containers/nope", contentType: nil, body: "")
        XCTAssertNotEqual(code, 415, raw)
        XCTAssertNotEqual(code, 403, raw)

        // The docs explorer (allowlisted origin) and local dev servers.
        (code, raw) = try await rawExchange(origin: "https://castlemilk.github.io")
        XCTAssertEqual(code, 200, raw)
        XCTAssertTrue(raw.contains("Access-Control-Allow-Origin: https://castlemilk.github.io"), raw)
        (code, raw) = try await rawExchange(origin: "http://localhost:3000")
        XCTAssertEqual(code, 200, raw)
        (code, raw) = try await rawExchange(
            "OPTIONS", contentType: nil, origin: "https://castlemilk.github.io", body: "")
        XCTAssertEqual(code, 204, raw)
        XCTAssertTrue(raw.contains("Access-Control-Allow-Private-Network: true"), raw)
        (code, raw) = try await rawExchange("OPTIONS", contentType: nil, origin: "http://evil.example", body: "")
        XCTAssertEqual(code, 403, raw)
    }

    /// Dual-stack loopback: `http://localhost:45454` (docs, SDK examples)
    /// may resolve to ::1 first.
    func testIPv6LoopbackListener() async throws {
        let port = baseURL.port ?? 0
        let url = URL(string: "http://[::1]:\(port)/health")!
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("ok"))
    }

    // MARK: GetContainer / WaitContainer

    /// `GetContainer` is a one-container inspect; `WaitContainer` on a
    /// container that has already stopped returns at once with
    /// `exited: true`. The CLI backend has no exit-code registry, so
    /// `known` stays false (proto-JSON omits the default) and no exit code
    /// is fabricated.
    func testGetContainerAndWaitStopped() async throws {
        let run = try await json(
            "POST", "v1/containers",
            body: ["image": "nginx:1.27", "name": "api-wait-stopped", "arguments": ["true"]])
        let id = run["id"] as? String ?? ""
        XCTAssertFalse(id.isEmpty)
        _ = try await json("POST", "v1/containers/\(id)/stop")

        let (getStatus, container) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/GetContainer", body: ["id": id])
        XCTAssertEqual(getStatus, 200, "GetContainer: \(container)")
        XCTAssertEqual(container["id"] as? String, id)
        XCTAssertEqual(container["state"] as? String, "stopped")
        XCTAssertEqual(container["image"] as? String, "nginx:1.27")
        XCTAssertNil(container["exitCode"], "no registry on the CLI backend → no exit code: \(container)")

        let clock = ContinuousClock()
        let started = clock.now
        let (waitStatus, wait) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/WaitContainer",
            body: ["id": id, "timeoutSeconds": 1])
        let elapsed = started.duration(to: clock.now)
        XCTAssertEqual(waitStatus, 200, "WaitContainer: \(wait)")
        XCTAssertEqual(wait["exited"] as? Bool, true, "WaitContainer: \(wait)")
        XCTAssertEqual(wait["known"] as? Bool ?? false, false, "WaitContainer: \(wait)")
        XCTAssertEqual(wait["state"] as? String, "stopped")
        XCTAssertNil(wait["exitCode"], "exit_code must stay at its default when unknown")
        XCTAssertLessThan(elapsed, .seconds(2), "an already-stopped container must not wait out the timeout")
    }

    /// A running container is non-terminal: `WaitContainer` polls until
    /// `timeout_seconds` and then reports `exited: false` with the live state.
    func testWaitContainerRunningTimesOut() async throws {
        let run = try await json(
            "POST", "v1/containers",
            body: ["image": "nginx:1.27", "name": "api-wait-running"])
        let id = run["id"] as? String ?? ""
        XCTAssertFalse(id.isEmpty)

        let clock = ContinuousClock()
        let started = clock.now
        let (status, wait) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/WaitContainer",
            body: ["id": id, "timeoutSeconds": 1])
        let elapsed = started.duration(to: clock.now)
        XCTAssertEqual(status, 200, "WaitContainer: \(wait)")
        XCTAssertEqual(wait["exited"] as? Bool ?? false, false, "WaitContainer: \(wait)")
        XCTAssertEqual(wait["known"] as? Bool ?? false, false)
        XCTAssertEqual(wait["state"] as? String, "running")
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(900), "must honour timeout_seconds")
        XCTAssertLessThan(elapsed, .seconds(4), "must return promptly after the deadline")

        _ = try await json("POST", "v1/containers/\(id)/stop")
        _ = try await json("DELETE", "v1/containers/\(id)")
    }

    /// Unknown ids are `not_found` for both RPCs — never a silent
    /// `exited: true`, and never a 30 s wait.
    func testWaitContainerUnknownId() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let (waitStatus, wait) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/WaitContainer", body: ["id": "ghost-container"])
        let elapsed = started.duration(to: clock.now)
        XCTAssertEqual(waitStatus, 404, "WaitContainer: \(wait)")
        XCTAssertEqual(wait["code"] as? String, "not_found", "WaitContainer: \(wait)")
        XCTAssertLessThan(elapsed, .seconds(3), "an unknown id must fail fast, not wait out the default timeout")

        let (getStatus, get) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/GetContainer", body: ["id": "ghost-container"])
        XCTAssertEqual(getStatus, 404, "GetContainer: \(get)")
        XCTAssertEqual(get["code"] as? String, "not_found", "GetContainer: \(get)")

        // Validation still applies: a negative timeout is a caller error.
        let (badStatus, bad) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/WaitContainer",
            body: ["id": "ghost-container", "timeoutSeconds": -1])
        XCTAssertEqual(badStatus, 400, "WaitContainer: \(bad)")
        XCTAssertEqual(bad["code"] as? String, "invalid_argument")
    }

    /// A runtime that stops answering mid-wait fails the call `unavailable`,
    /// never a false `exited: true`: callers treat `known: false` as a failed
    /// job, and the container may well still be running. The failed poll
    /// ends the wait at once rather than sitting out `timeout_seconds`.
    func testWaitContainerRuntimeStopsMidWaitIsUnavailable() async throws {
        let run = try await json(
            "POST", "v1/containers",
            body: ["image": "nginx:1.27", "name": "api-wait-outage"])
        let id = run["id"] as? String ?? ""
        XCTAssertFalse(id.isEmpty)

        let clock = ContinuousClock()
        let started = clock.now
        let wait = try startWait(id: id, timeoutSeconds: 10)
        try await Task.sleep(for: .milliseconds(500))
        try Data().write(to: stateDir.appendingPathComponent("runtime-stopped"))
        let (status, data) = try await wait.value
        let elapsed = started.duration(to: clock.now)
        let body = try decodeObject(data)

        XCTAssertEqual(status, 503, "WaitContainer: \(body)")
        XCTAssertEqual(body["code"] as? String, "unavailable", "WaitContainer: \(body)")
        XCTAssertLessThan(elapsed, .seconds(5), "an outage must end the wait, not sit out timeout_seconds")
    }

    /// A container removed mid-wait while the runtime keeps answering is
    /// terminal: `exited: true, known: false` with `state: "unknown"`.
    func testWaitContainerVanishedMidWaitIsExited() async throws {
        let run = try await json(
            "POST", "v1/containers",
            body: ["image": "nginx:1.27", "name": "api-wait-vanished"])
        let id = run["id"] as? String ?? ""
        XCTAssertFalse(id.isEmpty)

        let clock = ContinuousClock()
        let started = clock.now
        let wait = try startWait(id: id, timeoutSeconds: 10)
        try await Task.sleep(for: .milliseconds(500))
        let (deleteStatus, deleted) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/DeleteContainer", body: ["id": id, "force": true])
        XCTAssertEqual(deleteStatus, 200, "DeleteContainer: \(deleted)")
        let (status, data) = try await wait.value
        let elapsed = started.duration(to: clock.now)
        let body = try decodeObject(data)

        XCTAssertEqual(status, 200, "WaitContainer: \(body)")
        XCTAssertEqual(body["exited"] as? Bool, true, "WaitContainer: \(body)")
        XCTAssertEqual(body["known"] as? Bool ?? false, false, "WaitContainer: \(body)")
        XCTAssertEqual(body["state"] as? String, "unknown", "WaitContainer: \(body)")
        XCTAssertLessThan(elapsed, .seconds(5), "a vanished container must end the wait")
    }

    /// Issues `WaitContainer` in the background so the test can change the
    /// runtime under it. The task captures only the (Sendable) request and
    /// yields the raw status and body; decode with `decodeObject`.
    private func startWait(id: String, timeoutSeconds: Int) throws -> Task<(Int, Data), any Error> {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("api/micropod.v1.ContainerService/WaitContainer"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["id": id, "timeoutSeconds": timeoutSeconds])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return Task.detached { [request] in
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
    }

    private func decodeObject(_ data: Data) throws -> [String: Any] {
        (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: RunContainer fields / no_pull / Exec argv / skip_lines / stats ids

    /// The proto's `entrypoint`, `platform`, `workdir` and `user` reach the
    /// CLI verbatim — a task package pins `--platform`, an inline script
    /// overrides the entrypoint — and `arguments` follow the image untouched.
    func testRunContainerPassesEntrypointPlatformWorkdirUser() async throws {
        let (status, ref) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/RunContainer",
            body: [
                "image": "nginx:1.27", "name": "api-run-fields",
                "entrypoint": "/bin/sh", "platform": "linux/arm64",
                "workdir": "/w", "user": "1000:1000",
                "arguments": ["-c", "true"],
            ])
        XCTAssertEqual(status, 200, "RunContainer: \(ref)")
        let id = ref["id"] as? String ?? ""
        XCTAssertFalse(id.isEmpty)

        guard let line = mockCalls().last(where: { $0.hasPrefix("run ") }) else {
            return XCTFail("no `run` invocation recorded: \(mockCalls())")
        }
        XCTAssertTrue(line.contains(" --entrypoint /bin/sh "), line)
        XCTAssertTrue(line.contains(" --platform linux/arm64 "), line)
        XCTAssertTrue(line.contains(" --workdir /w "), line)
        XCTAssertTrue(line.contains(" --user 1000:1000 "), line)
        XCTAssertTrue(line.hasSuffix(" nginx:1.27 -c true"), "image then argv must end the line: \(line)")

        // The runtime saw the same values.
        let (getStatus, container) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/GetContainer", body: ["id": id])
        XCTAssertEqual(getStatus, 200, "GetContainer: \(container)")
        XCTAssertEqual(container["platform"] as? String, "linux/arm64")

        // A malformed platform is a caller error, not a CLI failure.
        let (badStatus, bad) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/RunContainer",
            body: ["image": "nginx:1.27", "platform": "arm64"])
        XCTAssertEqual(badStatus, 400, "RunContainer: \(bad)")
        XCTAssertEqual(bad["code"] as? String, "invalid_argument")
    }

    /// `no_pull` turns "image absent locally" into `not_found` *before* the
    /// CLI is spawned — the CLI would otherwise pull with no timeout. The
    /// message names the platform so the caller knows which variant to
    /// fetch, and an image present only for another platform is equally
    /// `not_found` (never a silent pull for the missing variant).
    /// `cap_add` / `cap_drop` / `rosetta` / `privileged` reach the CLI argv on
    /// both RunContainer and CreateContainer (+ StartContainer), normalised
    /// to `CAP_*`; unknown capability names fail `invalid_argument` before the
    /// CLI is ever asked.
    func testRunAndCreateCarryCapabilitiesRosettaAndPrivileged() async throws {
        let (runStatus, run) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/RunContainer",
            body: [
                "image": "alpine:3.20", "name": "api-caps-run", "capAdd": ["net_admin"],
                "capDrop": ["CAP_NET_RAW"], "rosetta": true, "platform": "linux/amd64",
            ])
        XCTAssertEqual(runStatus, 200, "RunContainer: \(run)")
        let (createStatus, created) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/CreateContainer",
            body: ["image": "docker:dind", "name": "api-caps-create", "privileged": true, "capAdd": ["SYS_ADMIN"]])
        XCTAssertEqual(createStatus, 200, "CreateContainer: \(created)")
        let id = created["id"] as? String ?? ""
        let (startStatus, started) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/StartContainer", body: ["id": id])
        XCTAssertEqual(startStatus, 200, "StartContainer: \(started)")

        let calls = mockCalls()
        let runCall = " " + (calls.first { $0.hasPrefix("run ") && $0.contains("api-caps-run") } ?? "") + " "
        for want in [
            " --cap-add CAP_NET_ADMIN ", " --cap-drop CAP_NET_RAW ", " --rosetta ", " --platform linux/amd64 ",
        ] {
            XCTAssertTrue(runCall.contains(want), "run argv missing \(want): \(runCall)")
        }
        let createCall = " " + (calls.first { $0.hasPrefix("create ") && $0.contains("api-caps-create") } ?? "") + " "
        for want in [" --cap-add ALL ", " --read-only-path NONE ", " --masked-path NONE "] {
            XCTAssertTrue(createCall.contains(want), "create argv missing \(want): \(createCall)")
        }
        XCTAssertFalse(createCall.contains("CAP_SYS_ADMIN"), "privileged subsumes cap_add: \(createCall)")

        // GetContainer reflects the Rosetta flag the runtime recorded.
        let inspected = try await json(
            "POST", "api/micropod.v1.ContainerService/GetContainer", body: ["id": run["id"] as? String ?? ""])
        XCTAssertEqual(inspected["rosetta"] as? Bool, true, "\(inspected)")

        for body: [String: Any] in [
            ["image": "alpine:3.20", "name": "api-caps-bad", "capAdd": ["NET_ADMINN"]],
            ["image": "alpine:3.20", "name": "api-caps-bad", "capDrop": ["SYS-ADMIN"]],
            // Whitespace is an invalid name on both servers (the proto pattern).
            ["image": "alpine:3.20", "name": "api-caps-bad", "capAdd": [" NET_ADMIN"]],
            ["image": "alpine:3.20", "name": "api-caps-bad", "capAdd": ["NET_ADMIN\n"]],
            // Contradictions the runtime would resolve to "every capability".
            ["image": "alpine:3.20", "name": "api-caps-bad", "privileged": true, "capDrop": ["ALL"]],
            ["image": "alpine:3.20", "name": "api-caps-bad", "capAdd": ["ALL"], "capDrop": ["all"]],
        ] {
            for rpc in ["RunContainer", "CreateContainer"] {
                let (status, error) = try await jsonStatus(
                    "POST", "api/micropod.v1.ContainerService/\(rpc)", body: body)
                XCTAssertEqual(status, 400, "\(rpc) \(body): \(error)")
                XCTAssertEqual(error["code"] as? String, "invalid_argument")
            }
        }
        XCTAssertFalse(mockCalls().contains { $0.contains("api-caps-bad") }, "invalid caps never reach the CLI")
    }

    /// The runtime applies --cap-drop before --cap-add, so `privileged` (an
    /// ALL grant) must not swallow named drops: ALL expands to every
    /// capability except the dropped ones.
    func testPrivilegedCapDropReallyDrops() async throws {
        let (status, body) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/CreateContainer",
            body: ["image": "docker:dind", "name": "api-caps-privdrop", "privileged": true, "capDrop": ["net_raw"]])
        XCTAssertEqual(status, 200, "CreateContainer: \(body)")
        let call = " " + (mockCalls().first { $0.hasPrefix("create ") && $0.contains("api-caps-privdrop") } ?? "") + " "
        XCTAssertFalse(call.contains(" --cap-add ALL "), call)
        XCTAssertFalse(call.contains(" --cap-add CAP_NET_RAW "), call)
        XCTAssertTrue(call.contains(" --cap-add CAP_SYS_ADMIN "), call)
        XCTAssertTrue(call.contains(" --cap-add CAP_CHECKPOINT_RESTORE "), call)
        XCTAssertTrue(call.contains(" --cap-drop CAP_NET_RAW "), call)
        XCTAssertTrue(call.contains(" --read-only-path NONE --masked-path NONE "), call)
    }

    /// Clients detect the optional RunContainer fields from Ping (and the
    /// REST system read) instead of sending them to a server that would
    /// silently drop them.
    /// A client that drops a follow-log stream must end the follower. The
    /// mock's `logs --follow` hangs (as Apple's does) and emits nothing
    /// after the backlog, so no write can fail — only hang-up detection
    /// ends it. Before the fix the follower (and, on the native backend,
    /// an open log fd plus a liveness poll a second) lived until the
    /// container stopped.
    func testDroppedLogStreamEndsTheFollower() async throws {
        try await relaunchServer(extraEnvironment: ["MICROPOD_MOCK_FOLLOW_HANG": "1"])
        let created = try await json("POST", "v1/containers", body: ["image": "alpine"])
        let id = try XCTUnwrap(created["id"] as? String)
        func followers() -> Int {
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-axo", "args="]
            let pipe = Pipe()
            ps.standardOutput = pipe
            try? ps.run()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            ps.waitUntilExit()
            return out.split(separator: "\n").filter {
                $0.contains(MockContainerCLI.scriptURL.path) && $0.contains("logs") && $0.contains(id)
            }.count
        }

        let port = UInt16(baseURL.port ?? 0)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        let request = "GET /v1/containers/\(id)/logs?tail=2 HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n"
        _ = request.withCString { write(fd, $0, strlen($0)) }

        var sawFollower = false
        for _ in 0..<50 where !sawFollower {
            sawFollower = followers() > 0
            if !sawFollower { try await Task.sleep(for: .milliseconds(100)) }
        }
        XCTAssertTrue(sawFollower, "the stream should have started a follower")
        close(fd)

        var remaining = followers()
        for _ in 0..<50 where remaining > 0 {
            try await Task.sleep(for: .milliseconds(100))
            remaining = followers()
        }
        XCTAssertEqual(remaining, 0, "dropping the stream must end the follower")
    }

    /// Engine management over Connect + REST: listing, validation, and
    /// routing refusals for unknown/disabled/unavailable engines.
    func testRuntimeEngineManagement() async throws {
        let list = try await json("POST", "api/micropod.v1.SystemService/ListRuntimes", body: [:])
        let runtimes = try XCTUnwrap(list["runtimes"] as? [[String: Any]])
        XCTAssertEqual(runtimes.map { $0["name"] as? String }, ["apple", "docker", "sandbox"])
        XCTAssertEqual(list["default"] as? String, "apple")
        XCTAssertEqual(runtimes[1]["available"] as? Bool ?? false, false)
        XCTAssertEqual(runtimes[1]["reason"] as? String, "Docker socket not found")

        let ping = try await json("POST", "api/micropod.v1.SystemService/Ping", body: [:])
        XCTAssertEqual(ping["defaultRuntime"] as? String, "apple")

        // Unavailable engines can't become the default; the default can't be disabled.
        let (setStatus, setBody) = try await jsonStatus(
            "POST", "api/micropod.v1.SystemService/SetDefaultRuntime", body: ["name": "docker"])
        XCTAssertEqual(setStatus, 412)
        XCTAssertEqual(setBody["code"] as? String, "failed_precondition", "\(setBody)")
        let (_, disable) = try await jsonStatus(
            "POST", "api/micropod.v1.SystemService/UpdateRuntime", body: ["name": "apple", "enabled": false])
        XCTAssertEqual(disable["code"] as? String, "failed_precondition")
        let (_, badEndpoint) = try await jsonStatus(
            "POST", "api/micropod.v1.SystemService/UpdateRuntime", body: ["name": "docker", "endpoint": "ftp://x"])
        XCTAssertEqual(badEndpoint["code"] as? String, "invalid_argument")

        // Enabling persists and shows up in both surfaces.
        let enabled = try await json(
            "POST", "api/micropod.v1.SystemService/UpdateRuntime", body: ["name": "docker", "enabled": true])
        let docker = (enabled["runtimes"] as? [[String: Any]])?.first { $0["name"] as? String == "docker" }
        XCTAssertEqual(docker?["enabled"] as? Bool, true)
        let rest = try await json("GET", "v1/runtimes")
        XCTAssertEqual(
            ((rest["runtimes"] as? [[String: Any]])?.first { $0["name"] as? String == "docker" })?["enabled"] as? Bool,
            true)

        // Routing refusals.
        let (_, unknown) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/RunContainer", body: ["image": "alpine", "runtime": "nope"])
        XCTAssertEqual(unknown["code"] as? String, "failed_precondition", "\(unknown)")
        let (_, unavailable) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/RunContainer", body: ["image": "alpine", "runtime": "docker"])
        XCTAssertEqual(unavailable["code"] as? String, "failed_precondition", "\(unavailable)")
        let (restStatus, _) = try await jsonStatus("POST", "v1/containers", body: ["image": "alpine", "runtime": 5])
        XCTAssertEqual(restStatus, 400, "a non-string runtime is a bad request")
    }

    /// Containers carry the engine that owns them.
    func testContainersReportRuntime() async throws {
        let created = try await json("POST", "v1/containers", body: ["image": "alpine"])
        let id = try XCTUnwrap(created["id"] as? String)
        let list = try await json("POST", "api/micropod.v1.ContainerService/ListContainers", body: [:])
        let owned = (list["containers"] as? [[String: Any]])?.first { $0["id"] as? String == id }
        XCTAssertEqual(owned?["runtime"] as? String, "apple", "\(list)")
    }

    func testPingAdvertisesFeatures() async throws {
        let ping = try await json("POST", "api/micropod.v1.SystemService/Ping", body: [:])
        XCTAssertEqual(
            ping["features"] as? [String], ["cap_add", "cap_drop", "rosetta", "privileged", "runtime"], "\(ping)")
        let system = try await json("GET", "v1/system")
        XCTAssertEqual(system["features"] as? [String], ["cap_add", "cap_drop", "rosetta", "privileged", "runtime"])
    }

    /// Legacy REST: a mistyped capability list or flag is a 400, never a
    /// silently empty list / false.
    func testRESTRejectsMistypedSecurityFields() async throws {
        for body: [String: Any] in [
            ["image": "alpine:3.20", "name": "api-rest-bad", "capAdd": ["NET_ADMIN", 5]],
            ["image": "alpine:3.20", "name": "api-rest-bad", "capDrop": "NET_RAW"],
            ["image": "alpine:3.20", "name": "api-rest-bad", "privileged": "yes"],
            ["image": "alpine:3.20", "name": "api-rest-bad", "rosetta": 1],
            ["image": "alpine:3.20", "name": "api-rest-bad", "privileged": true, "capDrop": ["ALL"]],
            ["image": "alpine:3.20", "name": "api-rest-bad", "capAdd": ["\tNET_ADMIN"]],
        ] {
            let (status, error) = try await jsonStatus("POST", "v1/containers", body: body)
            XCTAssertEqual(status, 400, "\(body): \(error)")
        }
        XCTAssertFalse(mockCalls().contains { $0.contains("api-rest-bad") }, "mistyped fields never reach the CLI")

        let (status, run) = try await jsonStatus(
            "POST", "v1/containers",
            body: ["image": "alpine:3.20", "name": "api-rest-good", "capAdd": ["NET_ADMIN"], "privileged": false])
        XCTAssertEqual(status, 201, "\(run)")
        XCTAssertTrue(mockCalls().contains { $0.contains("api-rest-good") && $0.contains("--cap-add CAP_NET_ADMIN") })
    }

    func testCreateNoPullMissingImageIsNotFound() async throws {
        let (status, body) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/CreateContainer",
            body: ["image": "ghost/none:1", "noPull": true, "name": "api-nopull"])
        XCTAssertEqual(status, 404, "CreateContainer: \(body)")
        XCTAssertEqual(body["code"] as? String, "not_found")
        let message = body["message"] as? String ?? ""
        XCTAssertTrue(message.contains("ghost/none:1"), message)
        XCTAssertTrue(message.contains("linux/"), "the message names the platform: \(message)")

        var calls = mockCalls()
        XCTAssertFalse(calls.contains { $0.hasPrefix("image pull") }, "no_pull must never pull: \(calls)")
        XCTAssertFalse(
            calls.contains { ($0.hasPrefix("create ") || $0.hasPrefix("run ")) && $0.contains("ghost/none:1") },
            "the CLI must not be asked to create (it would pull): \(calls)")
        XCTAssertTrue(calls.contains { $0.hasPrefix("image list") }, "presence is a list check: \(calls)")

        // Same request without no_pull still goes through (the mock's
        // `create` succeeds for any image, like the CLI's implicit pull).
        let (plainStatus, plain) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/CreateContainer",
            body: ["image": "ghost/none:1", "name": "api-nopull-plain"])
        XCTAssertEqual(plainStatus, 200, "CreateContainer without no_pull: \(plain)")

        // Once the image is local (mock pull registers linux/arm64 only),
        // no_pull creates normally …
        _ = try await json("POST", "v1/images/pull", body: ["reference": "ghost/none:1"])
        let (okStatus, created) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/CreateContainer",
            body: ["image": "ghost/none:1", "noPull": true, "name": "api-nopull"])
        XCTAssertEqual(okStatus, 200, "CreateContainer with the image present: \(created)")
        XCTAssertFalse((created["id"] as? String ?? "").isEmpty)

        // … but asking for a platform the local copy lacks is not_found,
        // naming that platform.
        let (variantStatus, variant) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/CreateContainer",
            body: ["image": "ghost/none:1", "noPull": true, "platform": "linux/amd64"])
        XCTAssertEqual(variantStatus, 404, "CreateContainer for a missing variant: \(variant)")
        XCTAssertEqual(variant["code"] as? String, "not_found")
        XCTAssertTrue((variant["message"] as? String ?? "").contains("linux/amd64"), "\(variant)")

        calls = mockCalls()
        XCTAssertEqual(
            calls.filter { $0.hasPrefix("image pull") }.count, 1,
            "only the explicit PullImage may pull: \(calls)")
    }

    /// A pull with no platform fetches only the host's (`linux/<host arch>`,
    /// the platform CreateContainer defaults to), not every platform in the
    /// index. A given platform reaches the CLI verbatim. Both the Connect
    /// `PullImage` stream and the REST pull go through the same default.
    func testPullImageDefaultsPlatformToHost() async throws {
        #if arch(arm64)
            let host = "linux/arm64"
        #else
            let host = "linux/amd64"
        #endif

        func connectPull(_ payload: [String: Any]) async throws {
            var request = URLRequest(
                url: baseURL.appendingPathComponent("api/micropod.v1.ImageService/PullImage"))
            request.httpMethod = "POST"
            request.setValue("application/connect+json", forHTTPHeaderField: "Content-Type")
            request.httpBody = ConnectFrames.envelope(
                try JSONSerialization.data(withJSONObject: payload), flags: 0)
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let last = ConnectFrames.parse(data).frames.last
            XCTAssertEqual(last?.flags, 0x02, "PullImage must end with EndStream")
            XCTAssertEqual(last.map { String(decoding: $0.payload, as: UTF8.self) }, "{}", "PullImage failed")
        }
        func pullLine(for reference: String) -> String {
            mockCalls().last { $0.hasPrefix("image pull ") && $0.hasSuffix(" \(reference)") } ?? ""
        }

        try await connectPull(["reference": "pin/connect-unset:1"])
        XCTAssertTrue(pullLine(for: "pin/connect-unset:1").contains(" --platform \(host) "), "\(mockCalls())")

        try await connectPull(["reference": "pin/connect-set:1", "platform": "linux/amd64"])
        let connectSet = pullLine(for: "pin/connect-set:1")
        XCTAssertTrue(connectSet.contains(" --platform linux/amd64 "), connectSet)
        XCTAssertEqual(connectSet.components(separatedBy: "--platform").count, 2, connectSet)

        _ = try await json("POST", "v1/images/pull", body: ["reference": "pin/rest-unset:1"])
        XCTAssertTrue(pullLine(for: "pin/rest-unset:1").contains(" --platform \(host) "), "\(mockCalls())")

        _ = try await json(
            "POST", "v1/images/pull", body: ["reference": "pin/rest-set:1", "platform": "linux/amd64"])
        let restSet = pullLine(for: "pin/rest-set:1")
        XCTAssertTrue(restSet.contains(" --platform linux/amd64 "), restSet)
        XCTAssertEqual(restSet.components(separatedBy: "--platform").count, 2, restSet)
    }

    /// `arguments` is a verbatim argv — an element with embedded spaces
    /// stays one element. `command` keeps its split-on-spaces behaviour for
    /// old clients, and a request with neither is a caller error.
    func testExecArgumentsVerbatim() async throws {
        let run = try await json(
            "POST", "v1/containers", body: ["image": "nginx:1.27", "name": "api-exec-argv"])
        let id = run["id"] as? String ?? ""
        XCTAssertFalse(id.isEmpty)

        let (status, exec) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/Exec",
            body: ["id": id, "arguments": ["sh", "-c", "echo a  b"]])
        XCTAssertEqual(status, 200, "Exec: \(exec)")
        let argvLine = mockCalls().last { $0.hasPrefix("exec ") } ?? ""
        XCTAssertTrue(
            argvLine.hasSuffix(" \(id) sh -c echo\\ a\\ \\ b"),
            "argv must reach the CLI verbatim (%q-quoted in the log): \(argvLine)")

        let (legacyStatus, legacy) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/Exec",
            body: ["id": id, "command": "echo hi"])
        XCTAssertEqual(legacyStatus, 200, "Exec(command): \(legacy)")
        let legacyLine = mockCalls().last { $0.hasPrefix("exec ") } ?? ""
        XCTAssertTrue(legacyLine.hasSuffix(" \(id) echo hi"), legacyLine)

        // When both are set, arguments win — command is the compatibility field.
        let (bothStatus, _) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/Exec",
            body: ["id": id, "command": "echo ignored", "arguments": ["true"]])
        XCTAssertEqual(bothStatus, 200)
        let bothLine = mockCalls().last { $0.hasPrefix("exec ") } ?? ""
        XCTAssertTrue(bothLine.hasSuffix(" \(id) true"), bothLine)

        let (badStatus, bad) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/Exec", body: ["id": id])
        XCTAssertEqual(badStatus, 400, "Exec with neither command nor arguments: \(bad)")
        XCTAssertEqual(bad["code"] as? String, "invalid_argument")
        XCTAssertTrue((bad["message"] as? String ?? "").contains("command"), "\(bad)")
    }

    /// `skip_lines` lets a client re-open a log stream after a transport
    /// error without replaying lines it already has: the first N lines are
    /// dropped server-side and the stream still ends cleanly. A skip past
    /// the end of the backlog yields no data frames — not an error.
    func testStreamLogsSkipLines() async throws {
        // The mock's follow appends one extra line after the backlog by
        // default; a stopped container's stream is the backlog alone.
        try await relaunchServer(extraEnvironment: ["MICROPOD_MOCK_FOLLOW_LINES": "0"])
        let run = try await json(
            "POST", "v1/containers",
            body: ["image": "nginx:1.27", "name": "api-skip-lines", "arguments": ["echo", "api-boot"]])
        let id = run["id"] as? String ?? ""
        XCTAssertFalse(id.isEmpty)
        _ = try await json("POST", "v1/containers/\(id)/stop")

        func stream(_ payload: [String: Any]) async throws -> (frames: [ConnectFrames.Frame], status: Int) {
            var request = URLRequest(
                url: baseURL.appendingPathComponent("api/micropod.v1.ContainerService/StreamContainerLogs"))
            request.httpMethod = "POST"
            request.setValue("application/connect+json", forHTTPHeaderField: "Content-Type")
            request.httpBody = ConnectFrames.envelope(
                try JSONSerialization.data(withJSONObject: payload), flags: 0)
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            let parsed = ConnectFrames.parse(data)
            XCTAssertEqual(parsed.trailing, 0)
            return (parsed.frames, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        // Baseline: tail 3 → exactly three lines.
        let all = try await stream(["id": id, "tail": 3])
        XCTAssertEqual(all.status, 200)
        XCTAssertEqual(all.frames.filter { $0.flags == 0 }.count, 3, "baseline backlog")

        let skipped = try await stream(["id": id, "tail": 3, "skipLines": 2])
        XCTAssertEqual(skipped.status, 200)
        let dataFrames = skipped.frames.filter { $0.flags == 0 }
        XCTAssertEqual(dataFrames.count, 1, "skip_lines: 2 of 3 lines leaves one: \(dataFrames.count)")
        let chunk = try JSONSerialization.jsonObject(with: dataFrames.first?.payload ?? Data()) as? [String: Any]
        XCTAssertEqual(chunk?["text"] as? String, "mock log line 3 from \(id)")
        XCTAssertEqual(skipped.frames.last?.flags, 0x02, "stream must still end with the EndStream frame")
        XCTAssertEqual(String(decoding: skipped.frames.last?.payload ?? Data(), as: UTF8.self), "{}")

        let overshoot = try await stream(["id": id, "tail": 3, "skipLines": 10])
        XCTAssertEqual(overshoot.status, 200)
        XCTAssertEqual(overshoot.frames.filter { $0.flags == 0 }.count, 0, "nothing left after the skip")
        XCTAssertEqual(overshoot.frames.last?.flags, 0x02)
        XCTAssertEqual(String(decoding: overshoot.frames.last?.payload ?? Data(), as: UTF8.self), "{}")

        // Negative skips are a caller error (rejected before any stream opens).
        var bad = URLRequest(
            url: baseURL.appendingPathComponent("api/micropod.v1.ContainerService/StreamContainerLogs"))
        bad.httpMethod = "POST"
        bad.setValue("application/connect+json", forHTTPHeaderField: "Content-Type")
        bad.httpBody = ConnectFrames.envelope(
            try JSONSerialization.data(withJSONObject: ["id": id, "skipLines": -1]), flags: 0)
        let (badData, badResponse) = try await URLSession.shared.data(for: bad)
        let badBody = String(decoding: badData, as: UTF8.self)
        XCTAssertEqual((badResponse as? HTTPURLResponse)?.statusCode, 400, "StreamContainerLogs: \(badBody)")
        XCTAssertTrue(badBody.contains("\"invalid_argument\""), badBody)
    }

    /// `GetStats{ids}` samples only the requested containers; an empty list
    /// keeps the old "every running container" behaviour, and unknown ids
    /// simply contribute nothing.
    func testGetStatsIdsFilter() async throws {
        let a =
            try await json("POST", "v1/containers", body: ["image": "nginx:1.27", "name": "api-stats-a"])["id"]
            as? String ?? ""
        let b =
            try await json("POST", "v1/containers", body: ["image": "nginx:1.27", "name": "api-stats-b"])["id"]
            as? String ?? ""
        XCTAssertFalse(a.isEmpty)
        XCTAssertFalse(b.isEmpty)

        func ids(of response: [String: Any]) -> [String] {
            ((response["snapshot"] as? [String: Any])?["containers"] as? [[String: Any]] ?? [])
                .compactMap { $0["id"] as? String }
        }

        let (status, filtered) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/GetStats", body: ["ids": [a]])
        XCTAssertEqual(status, 200, "GetStats: \(filtered)")
        XCTAssertEqual(ids(of: filtered), [a], "exactly the requested container: \(filtered)")
        XCTAssertFalse(((filtered["snapshot"] as? [String: Any])?["sampledAt"] as? String ?? "").isEmpty)

        let (allStatus, all) = try await jsonStatus("POST", "api/micropod.v1.ContainerService/GetStats", body: [:])
        XCTAssertEqual(allStatus, 200)
        XCTAssertTrue(Set(ids(of: all)).isSuperset(of: [a, b]), "empty ids = everything: \(all)")

        let (bothStatus, both) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/GetStats", body: ["ids": [b, a, "ghost"]])
        XCTAssertEqual(bothStatus, 200)
        XCTAssertEqual(Set(ids(of: both)), [a, b], "unknown ids contribute nothing: \(both)")

        let (noneStatus, none) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/GetStats", body: ["ids": ["ghost"]])
        XCTAssertEqual(noneStatus, 200, "GetStats for unknown ids is empty, not an error: \(none)")
        XCTAssertEqual(ids(of: none), [])

        for id in [a, b] {
            _ = try await json("POST", "v1/containers/\(id)/stop")
            _ = try await json("DELETE", "v1/containers/\(id)")
        }
    }

    // MARK: Volumes: CloneVolume / CommitVolumeClone / RW multi-attach guard

    /// `source` of a volume as the API reports it (the mock backs every
    /// volume with a real image file under the state dir).
    private func volumeSource(_ name: String) async throws -> String {
        let (status, list) = try await jsonStatus("POST", "api/micropod.v1.VolumeService/ListVolumes", body: [:])
        XCTAssertEqual(status, 200, "ListVolumes: \(list)")
        let volume = (list["volumes"] as? [[String: Any]])?.first { $0["id"] as? String == name }
        let source = volume?["source"] as? String ?? ""
        XCTAssertFalse(source.isEmpty, "volume \(name) has no source: \(list)")
        return source
    }

    /// Where the server expects container `id`'s clone of `volume`
    /// (`MICROPOD_VOLUME_CLONE_ROOT/<id>/<volume>.img`).
    private func clonePath(container id: String, volume: String) -> URL {
        stateDir.appendingPathComponent("clones/\(id)/\(volume).img")
    }

    private func writeClone(container id: String, volume: String, marker: Data) throws {
        let url = clonePath(container: id, volume: volume)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try marker.write(to: url)
    }

    /// Flips a mock container's recorded state without going through the
    /// CLI — the only way to observe transitional states like `stopping`.
    private func setMockState(_ id: String, to state: String) throws {
        let url = stateDir.appendingPathComponent("containers.json")
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        let rewritten = lines.map { line -> String in
            guard line.contains("\"id\":\"\(id)\"") else { return line }
            return line.replacingOccurrences(
                of: #""state":"[a-z]+""#, with: "\"state\":\"\(state)\"", options: .regularExpression)
        }
        try rewritten.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// `CloneVolume` creates the new volume (size defaulting to the source's
    /// provisioned size, plus a `com.micropod.clone-of` label) and clonefiles
    /// the golden image over its backing file; the golden is never touched,
    /// and both volumes report real allocated bytes.
    func testCloneVolumeCopiesTheGoldenImage() async throws {
        _ = try await json("POST", "v1/volumes", body: ["name": "g", "size": "20M"])
        let goldenSource = try await volumeSource("g")
        XCTAssertTrue(goldenSource.hasPrefix(stateDir.path), "the mock backs volumes with real files: \(goldenSource)")
        let marker = Data("golden-marker-\(UUID().uuidString)".utf8)
        try marker.write(to: URL(fileURLWithPath: goldenSource))

        let (status, clone) = try await jsonStatus(
            "POST", "api/micropod.v1.VolumeService/CloneVolume",
            body: ["source": "g", "name": "c", "labels": ["cuttle.kind=cache"]])
        XCTAssertEqual(status, 200, "CloneVolume: \(clone)")
        XCTAssertEqual(clone["id"] as? String, "c")
        XCTAssertEqual(clone["sizeBytes"] as? String, "20971520", "size defaults to the source's: \(clone)")
        let cloneSource = clone["source"] as? String ?? ""
        XCTAssertFalse(cloneSource.isEmpty, "\(clone)")
        XCTAssertNotEqual(cloneSource, goldenSource)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: cloneSource)), marker, "the clone carries the golden's bytes")
        XCTAssertGreaterThan(UInt64(clone["allocatedBytes"] as? String ?? "0") ?? 0, 0, "\(clone)")
        let labels = clone["labels"] as? [String: String] ?? [:]
        XCTAssertEqual(labels["cuttle.kind"], "cache", "\(clone)")
        XCTAssertEqual(labels["com.micropod.clone-of"], "g", "\(clone)")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: goldenSource)), marker, "the golden is untouched")

        let createLine = mockCalls().last { $0.hasPrefix("volume create") } ?? ""
        XCTAssertTrue(createLine.contains(" -s 20971520 "), "provisioned size in bytes: \(createLine)")
        XCTAssertTrue(createLine.contains(" --label com.micropod.clone-of=g "), createLine)
        XCTAssertTrue(createLine.hasSuffix(" c"), createLine)

        // Both are listed; `allocatedBytes` is real usage, `sizeBytes` the provisioned size.
        let (listStatus, list) = try await jsonStatus("POST", "api/micropod.v1.VolumeService/ListVolumes", body: [:])
        XCTAssertEqual(listStatus, 200)
        let volumes = list["volumes"] as? [[String: Any]] ?? []
        for name in ["g", "c"] {
            let entry = volumes.first { $0["id"] as? String == name }
            XCTAssertNotNil(entry, "\(name) missing from \(list)")
            XCTAssertGreaterThan(
                UInt64(entry?["allocatedBytes"] as? String ?? "0") ?? 0, 0, "\(String(describing: entry))")
        }
        let rest = try await json("GET", "v1/volumes")
        let restEntry = (rest["volumes"] as? [[String: Any]])?.first { $0["id"] as? String == "c" }
        XCTAssertGreaterThan(restEntry?["allocatedBytes"] as? UInt64 ?? 0, 0, "\(rest)")

        // An explicit size wins over the source's.
        let (sizedStatus, sized) = try await jsonStatus(
            "POST", "api/micropod.v1.VolumeService/CloneVolume", body: ["source": "g", "name": "c2", "size": "40M"])
        XCTAssertEqual(sizedStatus, 200, "CloneVolume with size: \(sized)")
        XCTAssertEqual(sized["sizeBytes"] as? String, "41943040", "\(sized)")

        // An unknown source is not_found — and nothing was created for it.
        let (missingStatus, missing) = try await jsonStatus(
            "POST", "api/micropod.v1.VolumeService/CloneVolume", body: ["source": "ghost", "name": "c3"])
        XCTAssertEqual(missingStatus, 404, "CloneVolume: \(missing)")
        XCTAssertEqual(missing["code"] as? String, "not_found")
        XCTAssertTrue((missing["message"] as? String ?? "").contains("ghost"), "\(missing)")
        XCTAssertFalse(mockCalls().contains { $0.hasPrefix("volume create") && $0.hasSuffix(" c3") }, "\(mockCalls())")

        // Validation mirrors the proto: both names are required.
        let (badStatus, bad) = try await jsonStatus(
            "POST", "api/micropod.v1.VolumeService/CloneVolume", body: ["source": "g"])
        XCTAssertEqual(badStatus, 400, "CloneVolume: \(bad)")
        XCTAssertEqual(bad["code"] as? String, "invalid_argument")

        // A volume cannot be cloned onto itself — rejected before anything
        // is created or clonefiled.
        let (selfStatus, selfClone) = try await jsonStatus(
            "POST", "api/micropod.v1.VolumeService/CloneVolume", body: ["source": "g", "name": "g"])
        XCTAssertEqual(selfStatus, 400, "CloneVolume onto itself: \(selfClone)")
        XCTAssertEqual(selfClone["code"] as? String, "invalid_argument")
        XCTAssertEqual(
            mockCalls().filter { $0.hasPrefix("volume create") && $0.hasSuffix(" g") }.count, 1,
            "only the golden's own create: \(mockCalls())")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: goldenSource)), marker, "the golden is untouched")
    }

    /// A golden attached read-write to a running container would yield a
    /// crash-consistent clone — `CloneVolume` refuses with
    /// `failed_precondition` naming that container, and creates nothing.
    /// A `stopping` writer still has the image attached (and may be flushing
    /// it), so it counts as a writer too.
    func testCloneVolumeSourceInUseIsFailedPrecondition() async throws {
        _ = try await json("POST", "v1/volumes", body: ["name": "g"])
        let run = try await json(
            "POST", "v1/containers", body: ["image": "nginx:1.27", "name": "api-golden-writer", "volumes": ["g:/x"]])
        let id = run["id"] as? String ?? ""
        XCTAssertFalse(id.isEmpty)

        let (status, body) = try await jsonStatus(
            "POST", "api/micropod.v1.VolumeService/CloneVolume", body: ["source": "g", "name": "c"])
        XCTAssertEqual(status, 412, "CloneVolume: \(body)")
        XCTAssertEqual(body["code"] as? String, "failed_precondition")
        let message = body["message"] as? String ?? ""
        XCTAssertTrue(message.contains("g") && message.contains(id), "names the volume and the writer: \(message)")
        XCTAssertFalse(mockCalls().contains { $0.hasPrefix("volume create") && $0.hasSuffix(" c") }, "\(mockCalls())")

        try setMockState(id, to: "stopping")
        let (stoppingStatus, stopping) = try await jsonStatus(
            "POST", "api/micropod.v1.VolumeService/CloneVolume", body: ["source": "g", "name": "c"])
        XCTAssertEqual(stoppingStatus, 412, "CloneVolume while the writer is stopping: \(stopping)")
        XCTAssertEqual(stopping["code"] as? String, "failed_precondition")
        let stoppingMessage = stopping["message"] as? String ?? ""
        XCTAssertTrue(
            stoppingMessage.contains(id) && stoppingMessage.contains("stopping"),
            "names the stopping writer: \(stoppingMessage)")
        XCTAssertFalse(mockCalls().contains { $0.hasPrefix("volume create") && $0.hasSuffix(" c") }, "\(mockCalls())")

        // Once the writer is stopped the golden is quiescent and clonable.
        _ = try await json("POST", "v1/containers/\(id)/stop")
        let (okStatus, clone) = try await jsonStatus(
            "POST", "api/micropod.v1.VolumeService/CloneVolume", body: ["source": "g", "name": "c"])
        XCTAssertEqual(okStatus, 200, "CloneVolume after stop: \(clone)")
        XCTAssertEqual(clone["id"] as? String, "c")
    }

    /// Attaching a named volume that a running container already has
    /// read-write is refused before the CLI is spawned — Apple named volumes
    /// are ext4 block images with no multi-attach protection. The message
    /// names the volume and the running container; host-path bind mounts are
    /// unaffected; `MICROPOD_ALLOW_MULTI_ATTACH=1` restores the old behaviour.
    func testCreateContainerVolumeAttachedRWIsFailedPrecondition() async throws {
        _ = try await json("POST", "v1/volumes", body: ["name": "v"])
        let a = try await json(
            "POST", "v1/containers", body: ["image": "nginx:1.27", "name": "api-attach-a", "volumes": ["v:/x"]])
        let aID = a["id"] as? String ?? ""
        XCTAssertFalse(aID.isEmpty)

        for method in ["RunContainer", "CreateContainer"] {
            let (status, body) = try await jsonStatus(
                "POST", "api/micropod.v1.ContainerService/\(method)",
                body: ["image": "nginx:1.27", "name": "api-attach-b", "volumes": ["v:/y"]])
            XCTAssertEqual(status, 412, "\(method): \(body)")
            XCTAssertEqual(body["code"] as? String, "failed_precondition", "\(method): \(body)")
            let message = body["message"] as? String ?? ""
            XCTAssertTrue(
                message.contains("'v'") && message.contains(aID), "\(method) must name volume and holder: \(message)")
        }
        XCTAssertFalse(
            mockCalls().contains { ($0.hasPrefix("run ") || $0.hasPrefix("create ")) && $0.contains("api-attach-b") },
            "the CLI must never be asked to attach: \(mockCalls())")

        // A host directory is a bind mount, not a volume — never guarded.
        let (bindStatus, bind) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/RunContainer",
            body: ["image": "nginx:1.27", "name": "api-attach-bind", "volumes": ["\(stateDir.path):/host"]])
        XCTAssertEqual(bindStatus, 200, "RunContainer with a bind mount: \(bind)")

        // A stopped holder releases the volume.
        _ = try await json("POST", "v1/containers/\(aID)/stop")
        let (okStatus, ok) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/RunContainer",
            body: ["image": "nginx:1.27", "name": "api-attach-b", "volumes": ["v:/y"]])
        XCTAssertEqual(okStatus, 200, "RunContainer after the holder stopped: \(ok)")

        // Opt-out: the operator takes responsibility for multi-attach.
        try await relaunchServer(extraEnvironment: ["MICROPOD_ALLOW_MULTI_ATTACH": "1"])
        let (allowedStatus, allowed) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/RunContainer",
            body: ["image": "nginx:1.27", "name": "api-attach-c", "volumes": ["v:/z"]])
        XCTAssertEqual(allowedStatus, 200, "RunContainer under MICROPOD_ALLOW_MULTI_ATTACH=1: \(allowed)")
    }

    /// A create replayed under a name that is already running (a client
    /// retrying after a lost reply) must get the runtime's `already_exists`
    /// answer, not a multi-attach refusal naming that container as the
    /// holder of its own volumes. The runtime's container ids are their
    /// names, so the guard stands aside for a holder whose id is the
    /// requested name — the mock's name-is-id mode reproduces that.
    func testCreateContainerReplayedNameIsNotRefusedAsItsOwnHolder() async throws {
        try await relaunchServer(extraEnvironment: ["MICROPOD_MOCK_NAME_IS_ID": "1"])
        _ = try await json("POST", "v1/volumes", body: ["name": "v"])
        let first = try await json(
            "POST", "v1/containers", body: ["image": "nginx:1.27", "name": "dup", "volumes": ["v:/x"]])
        XCTAssertEqual(first["id"] as? String, "dup", "name-is-id mode: \(first)")

        for method in ["CreateContainer", "RunContainer"] {
            let callsBefore = mockCalls().count
            let (status, body) = try await jsonStatus(
                "POST", "api/micropod.v1.ContainerService/\(method)",
                body: ["image": "nginx:1.27", "name": "dup", "volumes": ["v:/y"]])
            XCTAssertNotEqual(status, 412, "\(method) replay refused as its own holder: \(body)")
            XCTAssertNotEqual(body["code"] as? String, "failed_precondition", "\(method): \(body)")
            // The CLI's duplicate-id refusal is a bare `Error:` line (the
            // mock prints the real texts: `container already exists: dup`
            // for create, `container with id dup already exists` for run)
            // — `already_exists`, the answer a client adopting the container
            // it already created relies on.
            XCTAssertEqual(status, 409, "\(method) replay: \(body)")
            XCTAssertEqual(body["code"] as? String, "already_exists", "\(method): \(body)")
            let message = body["message"] as? String ?? ""
            XCTAssertTrue(
                message.contains(
                    method == "CreateContainer"
                        ? "Error: container already exists: dup" : "Error: container with id dup already exists"),
                "\(method): \(body)")
            // The guard stood aside: the CLI was asked, and it is the CLI's
            // duplicate-name answer that comes back.
            XCTAssertTrue(
                mockCalls().dropFirst(callsBefore).contains {
                    ($0.hasPrefix("run ") || $0.hasPrefix("create ")) && $0.contains(" --name dup ")
                },
                "\(method) replay must reach the CLI: \(mockCalls())")
        }

        // Any other name attaching the same volume is still refused, naming `dup`.
        let (status, body) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/RunContainer",
            body: ["image": "nginx:1.27", "name": "other", "volumes": ["v:/y"]])
        XCTAssertEqual(status, 412, "RunContainer under another name: \(body)")
        XCTAssertEqual(body["code"] as? String, "failed_precondition")
        XCTAssertTrue((body["message"] as? String ?? "").contains("'dup'"), "names the holder: \(body)")
    }

    /// `CommitVolumeClone` is `not_found` for an unknown container, for a
    /// container that has no clone of the volume, and for a volume that does
    /// not exist — the golden is never touched in any of those cases.
    func testCommitVolumeCloneWithoutCloneIsNotFound() async throws {
        _ = try await json("POST", "v1/volumes", body: ["name": "g"])
        let goldenSource = try await volumeSource("g")
        let goldenBefore = try Data(contentsOf: URL(fileURLWithPath: goldenSource))
        let run = try await json("POST", "v1/containers", body: ["image": "nginx:1.27", "name": "api-commit-noclone"])
        let id = run["id"] as? String ?? ""
        XCTAssertFalse(id.isEmpty)
        _ = try await json("POST", "v1/containers/\(id)/stop")

        let (status, body) = try await jsonStatus(
            "POST", "api/micropod.v1.VolumeService/CommitVolumeClone", body: ["containerId": id, "volume": "g"])
        XCTAssertEqual(status, 404, "CommitVolumeClone without a clone: \(body)")
        XCTAssertEqual(body["code"] as? String, "not_found")
        XCTAssertTrue((body["message"] as? String ?? "").contains("clone"), "\(body)")

        let (ghostStatus, ghost) = try await jsonStatus(
            "POST", "api/micropod.v1.VolumeService/CommitVolumeClone", body: ["containerId": "ghost", "volume": "g"])
        XCTAssertEqual(ghostStatus, 404, "CommitVolumeClone for an unknown container: \(ghost)")
        XCTAssertEqual(ghost["code"] as? String, "not_found")

        // A clone of a volume that does not exist cannot be promoted.
        try writeClone(container: id, volume: "nope", marker: Data("orphan".utf8))
        let (noVolumeStatus, noVolume) = try await jsonStatus(
            "POST", "api/micropod.v1.VolumeService/CommitVolumeClone", body: ["containerId": id, "volume": "nope"])
        XCTAssertEqual(noVolumeStatus, 404, "CommitVolumeClone for an unknown volume: \(noVolume)")
        XCTAssertEqual(noVolume["code"] as? String, "not_found")
        XCTAssertTrue((noVolume["message"] as? String ?? "").contains("nope"), "\(noVolume)")

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: goldenSource)), goldenBefore, "golden untouched")

        let (badStatus, bad) = try await jsonStatus(
            "POST", "api/micropod.v1.VolumeService/CommitVolumeClone", body: ["containerId": id])
        XCTAssertEqual(badStatus, 400, "CommitVolumeClone: \(bad)")
        XCTAssertEqual(bad["code"] as? String, "invalid_argument")
    }

    /// A clone may only be promoted once its container has fully stopped:
    /// `running` and `stopping` are both `failed_precondition` (a stopping
    /// container may still be flushing the image), and the golden stays as
    /// it was.
    func testCommitVolumeCloneRunningIsFailedPrecondition() async throws {
        _ = try await json("POST", "v1/volumes", body: ["name": "g"])
        let goldenSource = try await volumeSource("g")
        let goldenBefore = try Data(contentsOf: URL(fileURLWithPath: goldenSource))
        let run = try await json(
            "POST", "v1/containers",
            body: [
                "image": "nginx:1.27", "name": "api-commit-running", "volumes": ["g:/x"],
                "labels": ["com.micropod.cache.clone": "g"],
            ])
        let id = run["id"] as? String ?? ""
        XCTAssertFalse(id.isEmpty)
        try writeClone(container: id, volume: "g", marker: Data("dirty".utf8))

        for state in ["running", "stopping"] {
            try setMockState(id, to: state)
            let (status, body) = try await jsonStatus(
                "POST", "api/micropod.v1.VolumeService/CommitVolumeClone", body: ["containerId": id, "volume": "g"])
            XCTAssertEqual(status, 412, "CommitVolumeClone while \(state): \(body)")
            XCTAssertEqual(body["code"] as? String, "failed_precondition", "\(state): \(body)")
            XCTAssertTrue((body["message"] as? String ?? "").contains(state), "\(state): \(body)")
            XCTAssertEqual(
                try Data(contentsOf: URL(fileURLWithPath: goldenSource)), goldenBefore,
                "golden untouched while \(state)")
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: clonePath(container: id, volume: "g").path), "the clone is kept")
    }

    /// The happy path: a stopped container's clone replaces the golden's
    /// backing image atomically; the response reports the promoted image's
    /// allocated bytes. A golden that another container has attached
    /// read-write — running or still `stopping` — is not replaceable
    /// underneath it.
    func testCommitVolumeCloneStoppedPromotesTheClone() async throws {
        _ = try await json("POST", "v1/volumes", body: ["name": "g", "size": "20M"])
        let goldenSource = try await volumeSource("g")
        // The clone label makes the mock list the container with a `block`
        // mount of `<clone root>/<id>/g.img` — as the native backend's create
        // records it — which is what entitles the container to promote it.
        let run = try await json(
            "POST", "v1/containers",
            body: [
                "image": "nginx:1.27", "name": "api-commit-ok", "volumes": ["g:/x"],
                "labels": ["com.micropod.cache.clone": "g"],
            ])
        let id = run["id"] as? String ?? ""
        XCTAssertFalse(id.isEmpty)
        _ = try await json("POST", "v1/containers/\(id)/stop")
        let marker = Data("promoted-\(UUID().uuidString)".utf8)
        try writeClone(container: id, volume: "g", marker: marker)

        let (status, body) = try await jsonStatus(
            "POST", "api/micropod.v1.VolumeService/CommitVolumeClone", body: ["containerId": id, "volume": "g"])
        XCTAssertEqual(status, 200, "CommitVolumeClone: \(body)")
        XCTAssertGreaterThan(UInt64(body["allocatedBytes"] as? String ?? "0") ?? 0, 0, "\(body)")
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: goldenSource)), marker, "the golden now carries the clone's bytes"
        )
        let goldenDir = URL(fileURLWithPath: goldenSource).deletingLastPathComponent()
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: goldenDir.path), ["volume.img"],
            "no temp file left behind")
        let (listStatus, list) = try await jsonStatus("POST", "api/micropod.v1.VolumeService/ListVolumes", body: [:])
        XCTAssertEqual(listStatus, 200)
        let golden = (list["volumes"] as? [[String: Any]])?.first { $0["id"] as? String == "g" }
        XCTAssertEqual(
            golden?["sizeBytes"] as? String, "20971520", "provisioned size is unchanged: \(String(describing: golden))")

        // The clone diverges from the golden again, so a refused commit below
        // is provably not a rename.
        try writeClone(container: id, volume: "g", marker: Data("dirty-\(UUID().uuidString)".utf8))

        // The golden is attached read-write elsewhere: no rename underneath it.
        let writer = try await json(
            "POST", "v1/containers", body: ["image": "nginx:1.27", "name": "api-commit-writer", "volumes": ["g:/y"]])
        let writerID = writer["id"] as? String ?? ""
        let (busyStatus, busy) = try await jsonStatus(
            "POST", "api/micropod.v1.VolumeService/CommitVolumeClone", body: ["containerId": id, "volume": "g"])
        XCTAssertEqual(busyStatus, 412, "CommitVolumeClone with the golden in use: \(busy)")
        XCTAssertEqual(busy["code"] as? String, "failed_precondition")
        XCTAssertTrue((busy["message"] as? String ?? "").contains(writerID), "\(busy)")
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: goldenSource)), marker, "no rename under a running writer")

        // Nor while that writer is `stopping`: its block image is still
        // attached and being flushed, so a rename would orphan its writes.
        try setMockState(writerID, to: "stopping")
        let (stoppingStatus, stopping) = try await jsonStatus(
            "POST", "api/micropod.v1.VolumeService/CommitVolumeClone", body: ["containerId": id, "volume": "g"])
        XCTAssertEqual(stoppingStatus, 412, "CommitVolumeClone with the golden's writer stopping: \(stopping)")
        XCTAssertEqual(stopping["code"] as? String, "failed_precondition")
        let stoppingMessage = stopping["message"] as? String ?? ""
        XCTAssertTrue(
            stoppingMessage.contains(writerID) && stoppingMessage.contains("stopping"),
            "names the stopping writer: \(stoppingMessage)")
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: goldenSource)), marker, "no rename under a stopping writer")

        // The promoted bytes belong to the golden, not to the container.
        _ = try await json("DELETE", "v1/containers/\(id)")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: goldenSource)), marker)
    }

    /// Only the container that mounts a clone can promote it. A clone file
    /// under a container's id that the container's configuration does not
    /// mount is a leftover — the dir a raw `container delete` left behind,
    /// inherited by a same-name container created directly on the golden —
    /// and `CommitVolumeClone` answers `not_found` for it, leaving both the
    /// golden and the file alone.
    func testCommitVolumeCloneRequiresTheContainerToMountTheClone() async throws {
        _ = try await json("POST", "v1/volumes", body: ["name": "g"])
        let goldenSource = try await volumeSource("g")
        let goldenBefore = try Data(contentsOf: URL(fileURLWithPath: goldenSource))
        // No clone label: the container attaches the golden directly.
        let run = try await json(
            "POST", "v1/containers",
            body: ["image": "nginx:1.27", "name": "api-commit-unmounted", "volumes": ["g:/x"]])
        let id = run["id"] as? String ?? ""
        XCTAssertFalse(id.isEmpty)
        _ = try await json("POST", "v1/containers/\(id)/stop")
        try writeClone(container: id, volume: "g", marker: Data("stale".utf8))

        let (status, body) = try await jsonStatus(
            "POST", "api/micropod.v1.VolumeService/CommitVolumeClone", body: ["containerId": id, "volume": "g"])
        XCTAssertEqual(status, 404, "CommitVolumeClone of a clone the container does not mount: \(body)")
        XCTAssertEqual(body["code"] as? String, "not_found")
        let message = body["message"] as? String ?? ""
        XCTAssertTrue(message.contains("mount") && message.contains(id), "\(body)")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: goldenSource)), goldenBefore, "golden untouched")
        XCTAssertEqual(
            try Data(contentsOf: clonePath(container: id, volume: "g")), Data("stale".utf8), "the file is left alone")
    }

    /// A container id or volume name is a clone-path component
    /// (`<clone root>/<id>/<volume>.img`) and reaches the clone-dir lifecycle
    /// before the runtime validates it, so the API edge enforces the
    /// runtime's id grammar before dispatch: Connect answers 400
    /// `invalid_argument` naming the field, REST answers 400, the CLI is
    /// never asked, nothing is placed, and the golden a traversal name points
    /// at — `<clone root>/../golden-store/volume.img` here — survives.
    func testTraversalNamesAreInvalidArgumentBeforeDispatch() async throws {
        let store = stateDir.appendingPathComponent("golden-store", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let goldenImage = store.appendingPathComponent("volume.img")
        try Data("golden".utf8).write(to: goldenImage)
        _ = try await json("POST", "v1/volumes", body: ["name": "g"])
        let traversal = "../golden-store"
        let callsBefore = mockCalls().count

        let create: [String: Any] = [
            "image": "nginx:1.27", "name": traversal, "volumes": ["g:/x"],
            "labels": ["com.micropod.cache.clone": "g"],
        ]
        for method in ["CreateContainer", "RunContainer"] {
            let (status, body) = try await jsonStatus(
                "POST", "api/micropod.v1.ContainerService/\(method)", body: create)
            XCTAssertEqual(status, 400, "\(method): \(body)")
            XCTAssertEqual(body["code"] as? String, "invalid_argument", "\(method): \(body)")
            XCTAssertTrue((body["message"] as? String ?? "").hasPrefix("name:"), "\(method): \(body)")
        }
        for path in ["v1/containers", "v1/containers/create"] {
            let (status, body) = try await jsonStatus("POST", path, body: create)
            XCTAssertEqual(status, 400, "\(path): \(body)")
            XCTAssertTrue((body["error"] as? String ?? "").contains(traversal), "\(path): \(body)")
        }
        // A named volume is a path component too.
        let badVolume: [String: Any] = ["image": "nginx:1.27", "name": "job", "volumes": ["-g:/x"]]
        let (volumeStatus, volume) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/CreateContainer", body: badVolume)
        XCTAssertEqual(volumeStatus, 400, "\(volume)")
        XCTAssertEqual(volume["code"] as? String, "invalid_argument", "\(volume)")
        XCTAssertTrue((volume["message"] as? String ?? "").hasPrefix("volumes:"), "\(volume)")
        let (restVolumeStatus, restVolume) = try await jsonStatus("POST", "v1/containers", body: badVolume)
        XCTAssertEqual(restVolumeStatus, 400, "\(restVolume)")
        XCTAssertTrue((restVolume["error"] as? String ?? "").contains("-g"), "\(restVolume)")

        for (body, field) in [
            (["source": "g", "name": traversal], "name"),
            (["source": traversal, "name": "c"], "source"),
        ] {
            let (status, reply) = try await jsonStatus("POST", "api/micropod.v1.VolumeService/CloneVolume", body: body)
            XCTAssertEqual(status, 400, "CloneVolume \(field): \(reply)")
            XCTAssertEqual(reply["code"] as? String, "invalid_argument", "CloneVolume \(field): \(reply)")
            XCTAssertTrue((reply["message"] as? String ?? "").hasPrefix("\(field):"), "CloneVolume \(field): \(reply)")
        }
        for (body, field) in [
            (["containerId": traversal, "volume": "g"], "containerId"),
            (["containerId": "job", "volume": traversal], "volume"),
        ] {
            let (status, reply) = try await jsonStatus(
                "POST", "api/micropod.v1.VolumeService/CommitVolumeClone", body: body)
            XCTAssertEqual(status, 400, "CommitVolumeClone \(field): \(reply)")
            XCTAssertEqual(reply["code"] as? String, "invalid_argument", "CommitVolumeClone \(field): \(reply)")
            XCTAssertTrue(
                (reply["message"] as? String ?? "").hasPrefix("\(field):"), "CommitVolumeClone \(field): \(reply)")
        }
        // A refused value is echoed in the message. A control character in
        // it must not break the body: connect-go reads an unparseable 400
        // as `internal`, so the client would see `internal` for precisely
        // the inputs the guard refuses.
        for (path, body, field) in [
            ("api/micropod.v1.ContainerService/CreateContainer", ["image": "nginx:1.27", "name": "a\u{0}b"], "name"),
            (
                "api/micropod.v1.ContainerService/CreateContainer",
                ["image": "nginx:1.27", "name": "job", "volumes": ["a\tb:/x"]], "volumes"
            ),
            ("api/micropod.v1.VolumeService/CloneVolume", ["source": "g", "name": "a\u{1f}b"], "name"),
        ] as [(String, [String: Any], String)] {
            let (status, data) = try await rawStatus("POST", path, body: body)
            let text = String(decoding: data, as: UTF8.self).debugDescription
            XCTAssertEqual(status, 400, "\(path) \(field): \(text)")
            let reply = try XCTUnwrap(
                try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                "\(path) \(field): the body must parse: \(text)")
            XCTAssertEqual(reply["code"] as? String, "invalid_argument", "\(path) \(field): \(reply)")
            XCTAssertTrue((reply["message"] as? String ?? "").hasPrefix("\(field):"), "\(path) \(field): \(reply)")
        }

        let later = mockCalls().dropFirst(callsBefore)
        XCTAssertFalse(
            later.contains { call in
                ["run ", "create ", "volume create", "volume delete", "delete "].contains { call.hasPrefix($0) }
            }, "a refused request reached the CLI: \(later)")
        XCTAssertEqual(try Data(contentsOf: goldenImage), Data("golden".utf8), "the golden's bytes survive")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.path), ["volume.img"])
        let cloneRoot = stateDir.appendingPathComponent("clones").path
        XCTAssertEqual(
            (try? FileManager.default.contentsOfDirectory(atPath: cloneRoot)) ?? [], [], "nothing was placed")
    }

    /// The id grammar's 63-character cap is the runtime's *container-id*
    /// rule; its volume grammar has no cap of its own (`container` 1.3.1
    /// creates a 64-character volume) and cuttlefish's cache volumes
    /// (`cf-cache-<project>-<node>-<path>-<key>`) have no length bound. A
    /// 64-character volume name passes every edge: `CreateContainer` on
    /// Connect and REST (the CLI is asked, with the volume), `CloneVolume`
    /// (the clone is made) and `CommitVolumeClone` (past the grammar to the
    /// clone check, `not_found`); `CloneVolume` takes the longest name the
    /// grammar admits (237). One past the filename limit (the clone's
    /// staging file `.<name>.img.tmp-<8 hex>` must fit `NAME_MAX`: 238, and
    /// 252) is `invalid_argument`/400 naming the field, and the CLI is never
    /// asked.
    func testLongVolumeNamesReachTheCLI() async throws {
        let long = String(repeating: "v", count: 64)
        let longest = String(repeating: "w", count: 237)
        _ = try await json("POST", "v1/volumes", body: ["name": long])

        let created = try await json(
            "POST", "api/micropod.v1.ContainerService/CreateContainer",
            body: ["image": "nginx:1.27", "name": "job-connect", "volumes": ["\(long):/x"]])
        let connectID = created["id"] as? String ?? ""
        XCTAssertFalse(connectID.isEmpty, "\(created)")
        let rest = try await json(
            "POST", "v1/containers/create",
            body: ["image": "nginx:1.27", "name": "job-rest", "volumes": ["\(long):/x"]])
        XCTAssertFalse((rest["id"] as? String ?? "").isEmpty, "\(rest)")
        for name in ["job-connect", "job-rest"] {
            let call = mockCalls().first { $0.hasPrefix("create ") && $0.contains(" --name \(name) ") } ?? ""
            XCTAssertTrue(
                call.contains(" --volume \(long):/x "), "\(name): the CLI was asked, with the volume: \(call)")
        }

        let (cloneStatus, clone) = try await jsonStatus(
            "POST", "api/micropod.v1.VolumeService/CloneVolume", body: ["source": long, "name": "c-\(long)"])
        XCTAssertEqual(cloneStatus, 200, "CloneVolume: \(clone)")
        XCTAssertEqual(clone["id"] as? String, "c-\(long)", "\(clone)")
        let (longestStatus, longestClone) = try await jsonStatus(
            "POST", "api/micropod.v1.VolumeService/CloneVolume", body: ["source": long, "name": longest])
        XCTAssertEqual(longestStatus, 200, "CloneVolume: \(longestClone)")
        XCTAssertEqual(longestClone["id"] as? String, longest, "\(longestClone)")
        try setMockState(connectID, to: "stopped")
        let (commitStatus, commit) = try await jsonStatus(
            "POST", "api/micropod.v1.VolumeService/CommitVolumeClone",
            body: ["containerId": connectID, "volume": long])
        XCTAssertEqual(commitStatus, 404, "past the grammar to the clone check: \(commit)")
        XCTAssertEqual(commit["code"] as? String, "not_found", "\(commit)")
        XCTAssertTrue((commit["message"] as? String ?? "").contains("clone"), "\(commit)")

        let callsBefore = mockCalls().count
        for tooLong in [longest + "x", String(repeating: "x", count: 252)] {
            let count = tooLong.count
            let create: [String: Any] = ["image": "nginx:1.27", "name": "job-2", "volumes": ["\(tooLong):/x"]]
            for (path, body, field) in [
                ("api/micropod.v1.ContainerService/CreateContainer", create, "volumes"),
                ("api/micropod.v1.ContainerService/RunContainer", create, "volumes"),
                ("api/micropod.v1.VolumeService/CloneVolume", ["source": long, "name": tooLong], "name"),
                ("api/micropod.v1.VolumeService/CloneVolume", ["source": tooLong, "name": "c2"], "source"),
                (
                    "api/micropod.v1.VolumeService/CommitVolumeClone", ["containerId": connectID, "volume": tooLong],
                    "volume"
                ),
            ] as [(String, [String: Any], String)] {
                let (status, reply) = try await jsonStatus("POST", path, body: body)
                XCTAssertEqual(status, 400, "\(count) \(path) \(field): \(reply)")
                XCTAssertEqual(reply["code"] as? String, "invalid_argument", "\(count) \(path) \(field): \(reply)")
                XCTAssertTrue(
                    (reply["message"] as? String ?? "").hasPrefix("\(field):"), "\(count) \(path) \(field): \(reply)")
            }
            let (restStatus, restReply) = try await jsonStatus("POST", "v1/containers", body: create)
            XCTAssertEqual(restStatus, 400, "\(count): \(restReply)")
            XCTAssertTrue((restReply["error"] as? String ?? "").contains(tooLong), "\(count): \(restReply)")
        }
        let later = mockCalls().dropFirst(callsBefore)
        XCTAssertFalse(
            later.contains { call in ["run ", "create ", "volume create"].contains { call.hasPrefix($0) } },
            "a refused request reached the CLI: \(later)")
    }

    /// `DeleteContainer` of a missing id on the CLI backend is `not_found`:
    /// the mock prints the real CLI's `internalError: … (cause: "notFound:
    /// …")` text, which the classifier reads through to the cause.
    func testDeleteMissingContainerIsNotFound() async throws {
        let (status, body) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/DeleteContainer", body: ["id": "ghost", "force": true])
        XCTAssertEqual(status, 404, "DeleteContainer of a missing id: \(body)")
        XCTAssertEqual(body["code"] as? String, "not_found", "\(body)")
        let message = body["message"] as? String ?? ""
        XCTAssertTrue(
            message.contains("(cause: \"notFound: \"container with ID ghost not found\"\")"), "\(body)")
    }

    /// `DeleteContainer` on the CLI backend removes the container's clone
    /// dir like the native backend does. Without that, a later container
    /// reusing the name (the runtime's ids are its names) would inherit the
    /// dead container's clone and `CommitVolumeClone` would promote stale
    /// bytes over the golden. After the delete a second commit is `not_found`
    /// and the golden keeps what the first commit promoted; another
    /// container's clone dir is untouched.
    func testDeleteContainerRemovesItsCloneDir() async throws {
        _ = try await json("POST", "v1/volumes", body: ["name": "g"])
        let goldenSource = try await volumeSource("g")
        let run = try await json(
            "POST", "v1/containers",
            body: [
                "image": "nginx:1.27", "name": "api-delete-clones", "volumes": ["g:/x"],
                "labels": ["com.micropod.cache.clone": "g"],
            ])
        let id = run["id"] as? String ?? ""
        XCTAssertFalse(id.isEmpty)
        let other = try await json(
            "POST", "v1/containers", body: ["image": "nginx:1.27", "name": "api-delete-clones-other"])
        let otherID = other["id"] as? String ?? ""
        _ = try await json("POST", "v1/containers/\(id)/stop")
        let marker = Data("promoted-\(UUID().uuidString)".utf8)
        try writeClone(container: id, volume: "g", marker: marker)
        try writeClone(container: otherID, volume: "g", marker: Data("other".utf8))

        let (status, body) = try await jsonStatus(
            "POST", "api/micropod.v1.VolumeService/CommitVolumeClone", body: ["containerId": id, "volume": "g"])
        XCTAssertEqual(status, 200, "CommitVolumeClone: \(body)")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: goldenSource)), marker)

        let (deleteStatus, deleted) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/DeleteContainer", body: ["id": id, "force": true])
        XCTAssertEqual(deleteStatus, 200, "DeleteContainer: \(deleted)")
        let (listStatus, list) = try await jsonStatus(
            "POST", "api/micropod.v1.ContainerService/ListContainers", body: [:])
        XCTAssertEqual(listStatus, 200)
        let listed = (list["containers"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        XCTAssertFalse(listed.contains(id), "the container is gone: \(listed)")
        let cloneDir = stateDir.appendingPathComponent("clones/\(id)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloneDir.path), "clone dir survives the delete")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: clonePath(container: otherID, volume: "g").path),
            "another container's clone dir is untouched")

        // Same id, now a name nothing owns: nothing stale is left to promote.
        let (againStatus, again) = try await jsonStatus(
            "POST", "api/micropod.v1.VolumeService/CommitVolumeClone", body: ["containerId": id, "volume": "g"])
        XCTAssertEqual(againStatus, 404, "CommitVolumeClone after delete: \(again)")
        XCTAssertEqual(again["code"] as? String, "not_found")
        XCTAssertTrue((again["message"] as? String ?? "").contains("not found"), "\(again)")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: goldenSource)), marker, "golden untouched")
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

extension Process {
    /// SIGTERM, then SIGKILL after `grace`, and return once the child is
    /// gone. Never `waitUntilExit()`: it has been seen to miss the exit of an
    /// already-reaped server and hang the whole suite (no child left, the
    /// test parked in -[NSConcreteTask waitUntilExit]).
    func stopBounded(grace: Duration = .seconds(5)) async {
        guard isRunning else { return }
        terminate()
        let deadline = ContinuousClock.now + grace
        while isRunning, kill(processIdentifier, 0) == 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if isRunning, kill(processIdentifier, 0) == 0 { kill(processIdentifier, SIGKILL) }
    }
}

/// Minimal blocking HTTP/1.1 exchange over a POSIX socket, for tests that
/// need the raw status line (reason phrase) URLSession does not expose.
enum RawHTTP {
    static func exchange(port: UInt16, request: String) throws -> String {
        String(decoding: try exchange(port: port, bytes: Data(request.utf8)), as: UTF8.self)
    }

    /// Sends `bytes` (split into `pieces` separate writes, a few ms apart,
    /// so the server sees partial reads) and returns everything received
    /// until the server closes.
    static func exchange(port: UInt16, bytes: Data, pieces: Int = 1) throws -> Data {
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

        let bytes = Array(bytes)
        let pieceSize = max(1, (bytes.count + max(1, pieces) - 1) / max(1, pieces))
        var sent = 0
        while sent < bytes.count {
            let end = min(bytes.count, sent + pieceSize)
            while sent < end {
                let n = bytes.withUnsafeBufferPointer { send(fd, $0.baseAddress! + sent, end - sent, 0) }
                guard n > 0 else { throw POSIXError(.EPIPE) }
                sent += n
            }
            if pieces > 1 { usleep(5000) }
        }

        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            out.append(buffer, count: n)
        }
        return out
    }
}
