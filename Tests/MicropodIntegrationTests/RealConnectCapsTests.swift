import Foundation
import XCTest

/// Live Connect API coverage for `RunContainerRequest.cap_add` / `cap_drop` /
/// `rosetta` / `privileged` against the REAL Apple runtime, on both backends.
///
/// Gated behind `MICROPOD_REAL_E2E=1` (see `task e2e-real`). Each test
/// launches its own `.build/debug/MicropodAPI` on a random 127.0.0.1 port
/// (never the installed daemon on :45454) with `MICROPOD_RUNTIME` pinned,
/// and drives it with proto-JSON over HTTP exactly as Connect clients do.
/// Containers are named `mp-caps-test-<backend>-<purpose>-<random>` and
/// deleted by exact name, even on failure.
///
/// Run: MICROPOD_REAL_E2E=1 swift test --filter RealConnectCapsTests
final class RealConnectCapsTests: XCTestCase {
    private var server: Process?
    private var baseURL: URL!
    private var stateDir: URL!
    private var created: [String] = []

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MICROPOD_REAL_E2E"] == "1",
            "set MICROPOD_REAL_E2E=1 to run live runtime tests")
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-caps-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for name in created {
            // Exact-name deletes only — through the API, then the CLI as a
            // backstop in case the server already died.
            _ = try? await call("DeleteContainer", ["id": name, "force": true])
            let cli = Process()
            cli.executableURL = URL(fileURLWithPath: "/usr/local/bin/container")
            cli.arguments = ["delete", "--force", name]
            cli.standardOutput = FileHandle.nullDevice
            cli.standardError = FileHandle.nullDevice
            try? cli.run()
            cli.waitUntilExit()
        }
        created = []
        server?.terminate()
        server?.waitUntilExit()
        server = nil
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    // MARK: - Tests

    /// privileged via CreateContainer + StartContainer: dockerd comes up
    /// without any manual `/proc/sys` remount and `docker info` succeeds.
    func testPrivilegedDockerInDockerViaCreateStartNative() async throws {
        try await privilegedDind(backend: "native", viaCreate: true)
    }

    func testPrivilegedDockerInDockerViaCreateStartCLI() async throws {
        try await privilegedDind(backend: "cli", viaCreate: true)
    }

    /// cap_add ALL + privileged via RunContainer.
    func testCapAddAllPrivilegedDockerInDockerViaRunNative() async throws {
        try await privilegedDind(backend: "native", viaCreate: false)
    }

    func testCapAddAllPrivilegedDockerInDockerViaRunCLI() async throws {
        try await privilegedDind(backend: "cli", viaCreate: false)
    }

    /// rosetta + linux/amd64 runs an x86_64 userland.
    func testRosettaRunsAmd64ImageNative() async throws {
        try await rosettaAmd64(backend: "native")
    }

    func testRosettaRunsAmd64ImageCLI() async throws {
        try await rosettaAmd64(backend: "cli")
    }

    /// cap_drop is honoured on top of cap_add, and the names are normalised.
    func testCapDropAndCapAddShapeTheEffectiveSetNative() async throws {
        try await launch(backend: "native")
        let name = containerName("native", "capset")
        _ = try await call(
            "RunContainer",
            [
                "image": "alpine:3.20", "name": name, "capDrop": ["all"], "capAdd": ["net_admin"],
                "arguments": ["sleep", "300"],
            ])
        let (output, code) = try await exec(name, ["sh", "-c", "grep CapEff /proc/self/status"])
        XCTAssertEqual(code, 0, output)
        // Only CAP_NET_ADMIN (bit 12) survives drop ALL + add NET_ADMIN.
        XCTAssertTrue(output.contains("0000000000001000"), output)
    }

    // MARK: - Scenarios

    private func privilegedDind(backend: String, viaCreate: Bool) async throws {
        try await launch(backend: backend)
        let name = containerName(backend, viaCreate ? "dind-create" : "dind-run")
        let body: [String: Any] = [
            "image": "docker:dind", "name": name, "privileged": true, "capAdd": ["ALL"],
            "memory": "2g",
        ]
        if viaCreate {
            let ref = try await call("CreateContainer", body)
            XCTAssertEqual(ref["id"] as? String, name)
            _ = try await call("StartContainer", ["id": name])
        } else {
            let ref = try await call("RunContainer", body)
            XCTAssertEqual(ref["id"] as? String, name)
        }

        // The runtime left /proc/sys writable (no manual remount).
        let (mounts, _) = try await exec(name, ["sh", "-c", "cat /proc/sys/net/ipv4/ip_forward; mount | grep cgroup"])
        XCTAssertTrue(mounts.contains("cgroup2 (rw"), "cgroups must be writable: \(mounts)")

        var last = ""
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            let (output, code) = try await exec(name, ["docker", "info", "--format", "{{.ServerVersion}}"])
            if code == 0, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return
            }
            last = "exit \(code): \(output)"
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTFail("docker info never succeeded inside \(name) (\(backend)): \(last)")
    }

    private func rosettaAmd64(backend: String) async throws {
        try await launch(backend: backend)
        let name = containerName(backend, "rosetta")
        _ = try await call(
            "RunContainer",
            [
                "image": "alpine:3.20", "name": name, "platform": "linux/amd64", "rosetta": true,
                "arguments": ["sleep", "300"],
            ])
        let (output, code) = try await exec(name, ["uname", "-m"])
        XCTAssertEqual(code, 0, output)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "x86_64")
        let inspected = try await call("GetContainer", ["id": name])
        XCTAssertEqual(inspected["rosetta"] as? Bool, true, "\(inspected)")
        XCTAssertEqual(inspected["platform"] as? String, "linux/amd64", "\(inspected)")
    }

    // MARK: - Harness

    private func containerName(_ backend: String, _ purpose: String) -> String {
        let name = "mp-caps-test-\(backend)-\(purpose)-\(UUID().uuidString.prefix(8).lowercased())"
        created.append(name)
        return name
    }

    /// Launches the built MicropodAPI on a fresh loopback port with the
    /// backend pinned (`MICROPOD_RUNTIME`), against the real `container` CLI.
    private func launch(backend: String) async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = root.appendingPathComponent(".build/debug/MicropodAPI")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("MicropodAPI binary not built")
        }
        let port = UInt16.random(in: 46000...46499)
        baseURL = URL(string: "http://127.0.0.1:\(port)")!

        var environment = ProcessInfo.processInfo.environment
        // An explicit CLI path pins auto mode to CLI; the real binary is the
        // default, so drop any test override.
        environment.removeValue(forKey: "MICROPOD_CONTAINER_CLI_PATH")
        environment["MICROPOD_RUNTIME"] = backend
        environment["MICROPOD_API_PORT"] = String(port)
        environment["MICROPOD_VOLUME_POLICY"] = stateDir.appendingPathComponent("policy.json").path
        environment["MICROPOD_VOLUME_CLONE_ROOT"] = stateDir.appendingPathComponent("clones").path

        let process = Process()
        process.executableURL = binary
        process.environment = environment
        let log = stateDir.appendingPathComponent("api-\(backend).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        server = process

        for _ in 0..<60 {
            if let (data, _) = try? await URLSession.shared.data(from: baseURL.appendingPathComponent("health")),
                String(data: data, encoding: .utf8)?.contains("ok") == true
            {
                let ping = try await call("Ping", [:], service: "SystemService")
                XCTAssertEqual(ping["runtimeBackend"] as? String, backend, "\(ping)")
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        XCTFail("MicropodAPI test instance did not come up: \(output)")
        throw XCTSkip("API server did not come up")
    }

    @discardableResult
    private func call(_ method: String, _ body: [String: Any], service: String = "ContainerService")
        async throws -> [String: Any]
    {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/micropod.v1.\(service)/\(method)"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard status == 200 else {
            throw APIFailure(description: "\(method) → \(status): \(String(data: data, encoding: .utf8) ?? "")")
        }
        return json
    }

    private func exec(_ id: String, _ arguments: [String]) async throws -> (String, Int) {
        let response = try await call("Exec", ["id": id, "arguments": arguments])
        let output = (response["output"] as? String ?? "") + (response["error"] as? String ?? "")
        return (output, (response["exitCode"] as? Int) ?? 0)
    }

    private struct APIFailure: Error, CustomStringConvertible {
        let description: String
    }
}
