import Darwin
import Foundation
import MicropodCore
import SwiftProtobuf
import XCTest

@testable import MicropodMCP

/// How the MCP server talks to the API daemon: binary Connect on one
/// persistent connection, nothing resent, and no process started while a
/// daemon answers.
final class MCPWireTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/tmp/mpmw-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var socketPath: String { directory.appendingPathComponent("api.sock").path }

    /// Streams answer like the daemon's: a process exits 0, logs and pulls
    /// end; everything else gets an empty unary reply.
    private static let daemonLike: @Sendable (FakeLocalAPI.Request) -> FakeLocalAPI.Reply = { request in
        switch request.rpc {
        case "StreamProcess":
            return FakeLocalAPI.stream([
                Micropod_V1_ProcessEvent.with { $0.stdout = Data("hi\n".utf8) },
                Micropod_V1_ProcessEvent.with { $0.exitCode = 0 },
            ])
        case "StreamContainerLogs", "StreamMachineLogs", "PullImage":
            return FakeLocalAPI.stream([])
        case "StartSandbox":
            return FakeLocalAPI.unary(Micropod_V1_ContainerRef.with { $0.id = "sbx-1" })
        case "StartProcess":
            return FakeLocalAPI.unary(
                Micropod_V1_ProcessRef.with {
                    $0.id = "sbx-1"
                    $0.processID = "p1"
                })
        default:
            return .unary(Data())
        }
    }

    func testFiftyMixedToolCallsShareOneConnectionInBinaryProto() async throws {
        let fake = try FakeLocalAPI(unixSocket: socketPath)
        let tcp = try FakeLocalAPI(tcpLoopback: .respond)
        defer {
            fake.stop()
            tcp.stop()
        }
        let server = MCPTestServer.make(socketPath: socketPath, tcpPort: tcp.port)
        let tools: [(String, [String: Any])] = [
            ("cache_status", [:]), ("cache_policy", [:]), ("runtime_mode", [:]), ("rig_health", [:]),
            ("list_containers", [:]), ("list_images", [:]), ("list_volumes", [:]), ("runtimes", [:]),
            ("status", [:]), ("update_hvf_status", [:]),
        ]
        for round in 0..<5 {
            for (tool, arguments) in tools {
                let reply = try await MCPTestServer.call(server, tool, arguments)
                XCTAssertFalse(reply.isError, "round \(round) \(tool): \(reply.text)")
            }
        }
        XCTAssertEqual(fake.requests.count, 50)
        XCTAssertEqual(fake.connections, 1, "one persistent connection")
        XCTAssertEqual(Set(fake.requests.map(\.contentType)), ["application/proto"])
        XCTAssertTrue(fake.requests.allSatisfy { $0.method == "POST" && $0.path.hasPrefix("/api/micropod.v1.") })
        XCTAssertEqual(tcp.requests.count, 0)
    }

    func testStreamsReadToTheirEndKeepTheConnection() async throws {
        let fake = try FakeLocalAPI(unixSocket: socketPath)
        defer { fake.stop() }
        fake.respond { request in
            request.rpc == "StreamContainerLogs"
                ? FakeLocalAPI.stream(["a", "b"].map { line in Micropod_V1_LogChunk.with { $0.text = line } })
                : Self.daemonLike(request)
        }
        let server = MCPTestServer.make(socketPath: socketPath)
        for (tool, arguments) in [
            ("sandbox_run", ["command": "echo hi"]), ("logs", ["id": "web-1", "lines": 2]), ("cache_status", [:]),
            ("pull", ["reference": "busybox:1.36", "runtime": "hvf"]),
            ("sandbox_exec", ["id": "sbx-1", "command": "true"]),
        ] as [(String, [String: Any])] {
            let reply = try await MCPTestServer.call(server, tool, arguments)
            XCTAssertFalse(reply.isError, "\(tool): \(reply.text)")
        }
        let streams = fake.requests.filter { $0.contentType == "application/connect+proto" }.map(\.rpc)
        XCTAssertEqual(streams, ["StreamProcess", "StreamContainerLogs", "PullImage", "StreamProcess"])
        XCTAssertEqual(
            fake.connections, 1,
            "every stream ended in its last chunk and the connection was kept: \(fake.requests.map { "\($0.connection) \($0.rpc)" })"
        )
        XCTAssertTrue(
            try fake.requests.first { $0.rpc == "StreamContainerLogs" }!.message(Micropod_V1_StreamLogsRequest.self)
                .noFollow)
    }

    func testARequestLostAfterItWasWrittenIsReportedAndNotResent() async throws {
        let fake = try FakeLocalAPI(unixSocket: socketPath)
        let tcp = try FakeLocalAPI(tcpLoopback: .respond)
        defer {
            fake.stop()
            tcp.stop()
        }
        fake.respond { request in request.rpc == "Exec" ? .drop : .unary(Data()) }
        let server = MCPTestServer.make(socketPath: socketPath, tcpPort: tcp.port)
        let warm = try await MCPTestServer.call(server, "cache_policy", [:])
        XCTAssertFalse(warm.isError, warm.text)
        let reply = try await MCPTestServer.call(server, "exec", ["id": "web-1", "command": "echo once >> /out/x"])
        XCTAssertTrue(reply.isError, reply.text)
        XCTAssertTrue(reply.text.contains("It was not resent"), reply.text)
        XCTAssertEqual(fake.requests.filter { $0.rpc == "Exec" }.count, 1, "the daemon saw it exactly once")
        XCTAssertEqual(tcp.requests.count, 0, "never replayed over TCP")
        // The dead connection is replaced before the next call.
        let after = try await MCPTestServer.call(server, "cache_policy", [:])
        XCTAssertFalse(after.isError, after.text)
        XCTAssertEqual(fake.connections, 2)
    }

    /// A close-delimited stream that the API cuts off before its
    /// end-of-stream frame (it exited, or the runtime behind it did) is a
    /// lost call, never a pull that finished or a process killed at its
    /// deadline.
    func testAStreamCutOffBeforeItsEndIsReportedNotTakenForSuccess() async throws {
        let fake = try FakeLocalAPI(unixSocket: socketPath)
        defer { fake.stop() }
        fake.respond { request in
            switch request.rpc {
            case "PullImage":
                return .streamCutShort([
                    (try? Micropod_V1_ProgressLine.with { $0.line = "downloading" }.serializedData()) ?? Data()
                ])
            case "StreamProcess":
                return .streamCutShort([
                    (try? Micropod_V1_ProcessEvent.with { $0.stdout = Data("hi\n".utf8) }.serializedData()) ?? Data()
                ])
            default: return Self.daemonLike(request)
            }
        }
        let server = MCPTestServer.make(socketPath: socketPath, tcpPort: 1)
        let pull = try await MCPTestServer.call(server, "pull", ["reference": "alpine:latest"])
        XCTAssertTrue(pull.isError, pull.text)
        XCTAssertFalse(pull.text.contains("Pulled"), pull.text)
        XCTAssertTrue(pull.text.contains("end-of-stream"), pull.text)
        let exec = try await MCPTestServer.call(server, "sandbox_exec", ["id": "sbx-1", "command": "echo hi"])
        XCTAssertTrue(exec.isError, exec.text)
        XCTAssertFalse(exec.text.contains("killed after"), exec.text)
        XCTAssertEqual(fake.requests.filter { $0.rpc == "SignalProcess" }.count, 0, "nothing to kill")
    }

    func testAConnectionTheServerClosedWhileIdleIsReplacedBeforeSending() async throws {
        let fake = try FakeLocalAPI(unixSocket: socketPath)
        let tcp = try FakeLocalAPI(tcpLoopback: .respond)
        defer {
            fake.stop()
            tcp.stop()
        }
        let answered = LockedCount()
        fake.respond { _ in answered.next() == 1 ? .thenClose(Data()) : .unary(Data()) }
        let server = MCPTestServer.make(socketPath: socketPath, tcpPort: tcp.port)
        for _ in 0..<3 {
            let reply = try await MCPTestServer.call(server, "cache_policy_set", ["shared_l0": true])
            XCTAssertFalse(reply.isError, reply.text)
            // Idle long enough for the server's close to arrive.
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(fake.requests.count, 3, "each write was sent once, none lost")
        XCTAssertEqual(fake.connections, 2, "the closed connection was replaced, the new one kept")
        XCTAssertEqual(tcp.requests.count, 0)
    }

    func testLogsStreamOverTheSocketInConnectProto() async throws {
        let fake = try FakeLocalAPI(unixSocket: socketPath)
        let tcp = try FakeLocalAPI(tcpLoopback: .respond)
        defer {
            fake.stop()
            tcp.stop()
        }
        fake.respond { request in
            request.rpc == "StreamContainerLogs"
                ? FakeLocalAPI.stream(
                    ["one", "two", "three"].map { line in Micropod_V1_LogChunk.with { $0.text = line } })
                : .unary(Data())
        }
        let server = MCPTestServer.make(socketPath: socketPath, tcpPort: tcp.port)
        let reply = try await MCPTestServer.call(server, "logs", ["id": "web-1", "lines": 3])
        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertEqual(reply.text, "one\ntwo\nthree")
        let request = try XCTUnwrap(fake.requests.first)
        XCTAssertEqual(request.path, "/api/micropod.v1.ContainerService/StreamContainerLogs")
        XCTAssertEqual(request.contentType, "application/connect+proto")
        let asked = try request.message(Micropod_V1_StreamLogsRequest.self)
        XCTAssertEqual(asked.id, "web-1")
        XCTAssertEqual(asked.tail, 3)
        XCTAssertEqual(tcp.requests.count, 0, "nothing went over TCP while the socket served")
    }

    /// The tools that never had a daemon path (shares, app updates, policy
    /// files, k8s config, Apple's runtime helper and pushes) are not called:
    /// they touch this Mac's real state.
    static let localOnly: Set<String> = [
        "runtime_manage", "push", "volume_policy", "volume_policy_set", "compose_up", "compose_down", "share_mount",
        "share_unmount", "share_list", "share_sync", "share_gc", "build_cache_stats", "update_check", "update_status",
        "update_apply", "k8s_enable", "k8s_disable", "k8s_up", "k8s_down", "k8s_kubeconfig", "k8s_load_image",
        "k8s_images",
    ]

    func testEveryToolTheDaemonAnswersStartsNoProcessAndOnlyAMissingDaemonFallsBackToTheCLI() async throws {
        let log = directory.appendingPathComponent("spawned.log")
        let cli = directory.appendingPathComponent("cli")
        try "#!/bin/sh\necho \"$(basename \"$0\") $*\" >> '\(log.path)'\nexit 1\n".write(
            to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        setenv("MICROPOD_CLI", cli.path, 1)
        defer { unsetenv("MICROPOD_CLI") }

        let fake = try FakeLocalAPI(unixSocket: socketPath)
        fake.respond(Self.daemonLike)
        let server = MCPTestServer.make(socketPath: socketPath, cli: cli)
        var called: [String] = []
        for tool in MCPToolCatalog.tools where !Self.localOnly.contains(tool.name) {
            var arguments: [String: Any] = [:]
            for parameter in tool.parameters where parameter.required {
                if case .choice(let values) = parameter.kind {
                    arguments[parameter.name] = values[0]
                } else {
                    arguments[parameter.name] = parameter.name == "command" ? "true" : "b25"
                }
            }
            _ = try await MCPTestServer.call(server, tool.name, arguments)
            called.append(tool.name)
        }
        fake.stop()
        XCTAssertGreaterThan(called.count, 40)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: log.path),
            "spawned with a daemon up: \((try? String(contentsOf: log, encoding: .utf8)) ?? "")")
        XCTAssertEqual(
            Set(fake.requests.map(\.contentType)).subtracting(["application/proto", "application/connect+proto"]), [])

        // No daemon on the socket or the port: list_containers drives the CLI.
        try? FileManager.default.removeItem(atPath: socketPath)
        let standalone = MCPTestServer.make(socketPath: socketPath, cli: cli)
        _ = try await MCPTestServer.call(standalone, "list_containers", [:])
        let spawned = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        XCTAssertTrue(spawned.contains("cli list"), spawned)
        // A tool with no CLI path reports the missing daemon instead.
        let cache = try await MCPTestServer.call(standalone, "cache_status", [:])
        XCTAssertTrue(cache.isError)
        XCTAssertTrue(cache.text.contains("not reachable"), cache.text)
    }

    func testSandboxRunGoesThroughTheDaemonAndReportsTheExitFirst() async throws {
        let fake = try FakeLocalAPI(unixSocket: socketPath)
        defer { fake.stop() }
        fake.respond(Self.daemonLike)
        let server = MCPTestServer.make(socketPath: socketPath)
        let reply = try await MCPTestServer.call(
            server, "sandbox_run", ["command": "echo hi", "image": "alpine:3.20", "memory": 512, "allow_net": true])
        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertEqual(reply.text, "exit 0\nhi\n")
        XCTAssertEqual(fake.requests.map(\.rpc), ["StartSandbox", "StartProcess", "StreamProcess", "DeleteContainer"])
        let start = try fake.requests[0].message(Micropod_V1_StartSandboxRequest.self)
        XCTAssertEqual(start.image, "alpine:3.20")
        XCTAssertEqual(start.memoryMib, 512)
        XCTAssertEqual(start.cpus, 2, "the CLI's default")
        XCTAssertTrue(start.allowNet)
        XCTAssertTrue(start.command.isEmpty, "the sandbox idles; the command runs as a process")
        let process = try fake.requests[1].message(Micropod_V1_StartProcessRequest.self)
        XCTAssertEqual(process.command, ["/bin/sh", "-c", "echo hi"])

        // A checkpoint is kept only when the setup exited 0.
        let created = try await MCPTestServer.call(
            server, "sandbox_checkpoint", ["action": "create", "name": "env", "command": "true"])
        XCTAssertFalse(created.isError, created.text)
        XCTAssertTrue(fake.requests.contains { $0.rpc == "CheckpointSandbox" })
    }

    func testToolsListNamesEveryPlanToolWithTypedSchemas() async throws {
        let server = MCPTestServer.make(socketPath: nil)
        let listing = try await MCPTestServer.rpc(server, "tools/list")
        let tools = try XCTUnwrap((listing["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        let plan = [
            "cache_status", "cache_ls", "cache_explain", "cache_dedupe", "cache_prune", "cache_policy_set",
            "runtime_mode", "machine_status", "machine_control", "update_hvf_status", "update_hvf_apply",
            "update_hvf_rollback", "sandbox_run", "sandbox_exec", "sandbox_files", "sandbox_checkpoint",
            "sandbox_status", "telemetry_health", "telemetry_issues", "telemetry_traces",
        ]
        XCTAssertEqual(plan.filter { !names.contains($0) }, [])
        XCTAssertEqual(Set(names).count, names.count, "names are unique")
        for tool in tools {
            let name = tool["name"] as? String ?? "?"
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any], name)
            XCTAssertEqual(schema["type"] as? String, "object", name)
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false, name)
            let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]], name)
            for (property, spec) in properties {
                let types = (spec["type"] as? [String]) ?? [(spec["type"] as? String) ?? ""]
                XCTAssertTrue(
                    !types.isEmpty
                        && types.allSatisfy {
                            ["string", "boolean", "integer", "number", "array", "object"].contains($0)
                        },
                    "\(name).\(property): \(spec)")
                XCTAssertFalse((spec["description"] as? String ?? "").isEmpty, "\(name).\(property)")
                if types.contains("array") { XCTAssertNotNil(spec["items"] as? [String: Any], "\(name).\(property)") }
            }
            for required in schema["required"] as? [String] ?? [] {
                XCTAssertNotNil(properties[required], "\(name): required \(required)")
            }
        }
    }
}

/// A thread-safe counter.
final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
