import MicropodCore
import XCTest

/// Spawns the built MicropodAPI binary against the mock CLI and drives it
/// over HTTP (Foundation URLSession) — the full HTTP surface.
final class MicropodAPITests: XCTestCase {
    private var server: Process!
    private var baseURL: URL!
    private var stateDir: URL!

    override func setUp() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/MicropodIntegrationTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
        let binary = root.appendingPathComponent(".build/debug/MicropodAPI")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("MicropodAPI binary not built")
        }

        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("micropod-api-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

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
            ]) { _, new in new }
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

    override func tearDown() async throws {
        server?.terminate()
        try? FileManager.default.removeItem(at: stateDir)
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
}
