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
        server.terminate()
        server.waitUntilExit()
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
            // The CLI's `Error: exists: "…"` line is the runtime's own
            // duplicate-id refusal — `already_exists`, the answer a client
            // adopting the container it already created relies on.
            XCTAssertEqual(status, 409, "\(method) replay: \(body)")
            XCTAssertEqual(body["code"] as? String, "already_exists", "\(method): \(body)")
            XCTAssertTrue((body["message"] as? String ?? "").contains("dup"), "\(method): \(body)")
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
            "POST", "v1/containers", body: ["image": "nginx:1.27", "name": "api-commit-running", "volumes": ["g:/x"]])
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
        let run = try await json(
            "POST", "v1/containers", body: ["image": "nginx:1.27", "name": "api-commit-ok", "volumes": ["g:/x"]])
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
            "POST", "v1/containers", body: ["image": "nginx:1.27", "name": "api-delete-clones", "volumes": ["g:/x"]])
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
