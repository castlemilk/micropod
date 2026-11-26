import Darwin
import Foundation
import MicropodCore
import XCTest

@testable import MicropodMCP

/// The cache and rig tools, driven through the server's JSON-RPC entry
/// point against a fake API daemon.
final class CacheToolsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        // Short: a Unix socket path must fit in 104 bytes.
        directory = URL(fileURLWithPath: "/tmp/mpmcp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var socketPath: String { directory.appendingPathComponent("api.sock").path }

    private func makeServer(tcpPort: Int = 1, socketTimeoutSeconds: Int = 5, longCallSeconds: Int? = nil)
        -> MCPServer
    {
        let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/usr/bin/false"))
        let api = LocalAPI(
            socketPath: socketPath, baseURL: URL(string: "http://127.0.0.1:\(tcpPort)")!,
            socketTimeoutSeconds: socketTimeoutSeconds, httpTimeout: 5,
            longCallSeconds: longCallSeconds ?? socketTimeoutSeconds)
        return MCPServer(
            client: client,
            system: SystemService(client: client),
            containers: ContainerService(client: client),
            images: ImageService(client: client),
            volumes: VolumeService(client: client),
            networks: NetworkService(client: client),
            statsSampler: StatsSampler(client: client),
            logStreamer: LogStreamer(client: client),
            compose: ComposeService(client: client),
            sharedFS: nil,
            api: api)
    }

    private struct ToolReply {
        var text: String
        var isError: Bool
    }

    private func call(_ server: MCPServer, _ tool: String, _ arguments: [String: Any]) async throws -> ToolReply {
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": 7, "method": "tools/call",
            "params": ["name": tool, "arguments": arguments],
        ]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let handled = await server.handle(line: line)
        let reply = try XCTUnwrap(handled)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any], "\(object)")
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return ToolReply(
            text: content.compactMap { $0["text"] as? String }.joined(), isError: result["isError"] as? Bool ?? false)
    }

    // MARK: cache_prune

    func testPruneIsADryRunUnlessApplyIsTrue() async throws {
        let fake = try FakeLocalAPI(unixSocket: socketPath)
        defer { fake.stop() }
        let server = makeServer()
        let calls: [[String: Any]] = [["dry_run": true], [:], ["dry_run": "true"], ["apply": false]]
        for arguments in calls {
            let reply = try await call(server, "cache_prune", arguments)
            XCTAssertFalse(reply.isError, "\(arguments): \(reply.text)")
        }
        XCTAssertEqual(fake.requests.count, calls.count)
        for (request, arguments) in zip(fake.requests, calls) {
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.path, "/v1/caches/prune")
            XCTAssertEqual(request.json["dryRun"] as? Bool, true, "\(arguments)")
            XCTAssertNil(request.json["maxBytes"], "\(arguments)")
        }
        XCTAssertEqual(fake.evictions, 0)
    }

    func testPruneApplyCarriesTypedSelectors() async throws {
        let fake = try FakeLocalAPI(unixSocket: socketPath)
        defer { fake.stop() }
        let server = makeServer()
        var reply = try await call(server, "cache_prune", ["apply": true, "max_bytes": 1000])
        XCTAssertFalse(reply.isError, reply.text)
        reply = try await call(
            server, "cache_prune",
            [
                "apply": "yes", "max_bytes": "20g", "older_than_secs": "14d", "scope": "proj", "tool": "go",
                "partial_go_build": false,
            ])
        XCTAssertFalse(reply.isError, reply.text)
        reply = try await call(server, "cache_prune", ["apply": true, "all": true])
        XCTAssertFalse(reply.isError, reply.text)

        let requests = fake.requests.map(\.json)
        guard requests.count == 3 else { return XCTFail("\(requests.count) requests, want 3") }
        XCTAssertEqual(requests[0]["dryRun"] as? Bool, false)
        XCTAssertEqual((requests[0]["maxBytes"] as? NSNumber)?.uint64Value, 1000)
        XCTAssertEqual(requests[1]["dryRun"] as? Bool, false)
        XCTAssertEqual((requests[1]["maxBytes"] as? NSNumber)?.uint64Value, 20 << 30)
        XCTAssertEqual((requests[1]["olderThanSecs"] as? NSNumber)?.int64Value, 14 * 86400)
        XCTAssertEqual(requests[1]["scope"] as? String, "proj")
        XCTAssertEqual(requests[1]["tool"] as? String, "go")
        XCTAssertEqual(requests[1]["partialGoBuild"] as? Bool, false)
        XCTAssertEqual(requests[2]["dryRun"] as? Bool, false)
        XCTAssertEqual(requests[2]["all"] as? Bool, true)
        XCTAssertEqual(fake.evictions, 3)
    }

    func testPruneRefusesAmbiguousOrMistypedCallsBeforeAnyRequest() async throws {
        let fake = try FakeLocalAPI(unixSocket: socketPath)
        defer { fake.stop() }
        let server = makeServer()
        let refused: [([String: Any], String)] = [
            (["apply": true], "pass all: true to confirm"),
            (["apply": true, "partial_go_build": true], "pass all: true to confirm"),
            (["dry_run": false], "pass apply: true to evict"),
            (["dry_run": true, "apply": true], "contradict"),
            (["dry_run": "maybe"], "dry_run must be a boolean"),
            (["apply": 1], "apply must be a boolean"),
            (["max_bytes": true], "max_bytes must be a size"),
            (["max_bytes": 0, "apply": true], "max_bytes must be positive"),
            (["older_than_secs": "fortnight"], "older_than_secs must be a duration"),
            (["dryrun": false], "unknown argument 'dryrun'"),
        ]
        for (arguments, expected) in refused {
            let reply = try await call(server, "cache_prune", arguments)
            XCTAssertTrue(reply.isError, "\(arguments)")
            XCTAssertTrue(reply.text.contains(expected), "\(arguments): \(reply.text)")
        }
        XCTAssertEqual(fake.requests.count, 0, "a refused call sends nothing")
    }

    // MARK: cache_policy_set

    func testPolicySetSendsOnlyTheNamedSettingsAsTheirTypes() async throws {
        let fake = try FakeLocalAPI(unixSocket: socketPath)
        defer { fake.stop() }
        let server = makeServer()
        var reply = try await call(server, "cache_policy_set", ["shared_l0": true])
        XCTAssertFalse(reply.isError, reply.text)
        reply = try await call(
            server, "cache_policy_set",
            [
                "shared_l0": "false", "max_bytes": "50g", "max_age_days": "14", "go_proxy": "off",
                "npm_registry": "http://10.43.0.1:5555/npm", "default_scope": "none", "mode": "auto",
            ])
        XCTAssertFalse(reply.isError, reply.text)

        let requests = fake.requests
        XCTAssertEqual(requests.map(\.method), ["PUT", "PUT"])
        XCTAssertEqual(requests.map(\.path), ["/v1/caches/policy", "/v1/caches/policy"])
        guard requests.count == 2 else { return }
        XCTAssertEqual(requests[0].json.count, 1)
        XCTAssertEqual(requests[0].json["sharedL0"] as? Bool, true)
        let second = requests[1].json
        XCTAssertEqual(second["sharedL0"] as? Bool, false)
        XCTAssertEqual((second["maxBytes"] as? NSNumber)?.uint64Value, 50 << 30)
        XCTAssertEqual((second["maxAgeDays"] as? NSNumber)?.intValue, 14)
        XCTAssertEqual(second["goProxy"] as? String, "", "off clears the proxy")
        XCTAssertEqual(second["npmRegistry"] as? String, "http://10.43.0.1:5555/npm")
        XCTAssertEqual(second["defaultScope"] as? String, "", "none: only containers naming a scope")
        XCTAssertEqual(second["mode"] as? String, "auto")
    }

    /// `""` for a URL or the default scope is the earlier clear, not an
    /// omission: it is sent, alone or beside another setting.
    func testPolicySetSendsAnEmptyURLAsAClear() async throws {
        let fake = try FakeLocalAPI(unixSocket: socketPath)
        defer { fake.stop() }
        let server = makeServer()
        var reply = try await call(server, "cache_policy_set", ["go_proxy": "", "shared_l0": true])
        XCTAssertFalse(reply.isError, reply.text)
        reply = try await call(server, "cache_policy_set", ["npm_registry": ""])
        XCTAssertFalse(reply.isError, reply.text)
        reply = try await call(server, "cache_policy_set", ["default_scope": "", "go_proxy": NSNull()])
        XCTAssertFalse(reply.isError, reply.text)
        let bodies = fake.requests.map(\.json)
        guard bodies.count == 3 else { return XCTFail("\(bodies.count) requests, want 3") }
        XCTAssertEqual(bodies[0]["goProxy"] as? String, "")
        XCTAssertEqual(bodies[0]["sharedL0"] as? Bool, true)
        XCTAssertEqual(bodies[1].count, 1)
        XCTAssertEqual(bodies[1]["npmRegistry"] as? String, "")
        XCTAssertEqual(bodies[2].count, 1, "null still means omitted: \(bodies[2])")
        XCTAssertEqual(bodies[2]["defaultScope"] as? String, "")
    }

    func testPolicySetNeverTurnsAnOmittedOrMistypedSettingIntoAWrite() async throws {
        let fake = try FakeLocalAPI(unixSocket: socketPath)
        defer { fake.stop() }
        let server = makeServer()
        let refused: [([String: Any], String)] = [
            ([:], "nothing was written"),
            (["shared_l0": ""], "nothing was written"),
            (["shared_l0": "maybe"], "shared_l0 must be a boolean"),
            (["shared_l0": 1], "shared_l0 must be a boolean"),
            (["shared_LO": true], "unknown argument 'shared_LO'"),
            (["mode": "bogus"], "Unknown mode 'bogus'"),
            (["max_bytes": "plenty"], "max_bytes must be a size"),
            (["max_age_days": 1.5], "max_age_days must be an integer"),
        ]
        for (arguments, expected) in refused {
            let reply = try await call(server, "cache_policy_set", arguments)
            XCTAssertTrue(reply.isError, "\(arguments)")
            XCTAssertTrue(reply.text.contains(expected), "\(arguments): \(reply.text)")
        }
        XCTAssertEqual(fake.requests.count, 0)
    }

    // MARK: ids and queries

    func testExplainRefusesIdsThatWouldRewriteTheRequestLine() async throws {
        let fake = try FakeLocalAPI(unixSocket: socketPath)
        defer { fake.stop() }
        let server = makeServer()
        for id in ["a b", "a?b", "a#b", "a\u{1}b", "a\r\nX-Evil: 1", "a/b", "../../v1/caches/prune", "..", "a\\b"] {
            let reply = try await call(server, "cache_explain", ["id": id])
            XCTAssertTrue(reply.isError, id)
            XCTAssertTrue(reply.text.contains("is not a valid id"), "\(id): \(reply.text)")
        }
        let missing = try await call(server, "cache_explain", [:])
        XCTAssertEqual(missing.text, "cache_explain requires id")
        XCTAssertEqual(fake.requests.count, 0)

        for id in ["web-1", "my.box_2", "0123abcdef"] {
            let reply = try await call(server, "cache_explain", ["id": id])
            XCTAssertFalse(reply.isError, reply.text)
        }
        XCTAssertEqual(
            fake.requests.map(\.path),
            ["/v1/caches/explain/web-1", "/v1/caches/explain/my.box_2", "/v1/caches/explain/0123abcdef"])
        XCTAssertEqual(try LocalAPI.pathSegment("ü:x", name: "id"), "%C3%BC%3Ax", "anything else is encoded")
    }

    func testDedupeBucketsAreATypedBoundedInteger() async throws {
        let fake = try FakeLocalAPI(unixSocket: socketPath)
        defer { fake.stop() }
        let server = makeServer()
        for bad: Any in [300, 0, "many", true] {
            let reply = try await call(server, "cache_dedupe", ["buckets": bad])
            XCTAssertTrue(reply.isError, "\(bad)")
        }
        _ = try await call(server, "cache_dedupe", ["buckets": "32"])
        _ = try await call(server, "cache_dedupe", [:])
        XCTAssertEqual(fake.requests.map(\.path), ["/v1/caches/dedupe?buckets=32", "/v1/caches/dedupe?buckets=16"])
    }

    // MARK: update_hvf_rollback

    func testRollbackSendsForceOnlyWhenAskedAndReportsADeferralAsAnError() async throws {
        let fake = try FakeLocalAPI(unixSocket: socketPath)
        defer { fake.stop() }
        let server = makeServer()
        var reply = try await call(server, "update_hvf_rollback", [:])
        XCTAssertFalse(reply.isError, reply.text)
        reply = try await call(server, "update_hvf_rollback", ["force": true])
        XCTAssertFalse(reply.isError, reply.text)
        reply = try await call(server, "update_hvf_rollback", ["force": "maybe"])
        XCTAssertTrue(reply.isError, reply.text)
        XCTAssertEqual(fake.requests.map(\.json.count), [0, 1])
        XCTAssertEqual(fake.requests.last?.json["force"] as? Bool, true)

        // The daemon answers a deferral with 409 and its detail as `error`.
        fake.reply("/v1/rig/hvf/update/rollback", status: 409)
        reply = try await call(server, "update_hvf_rollback", [:])
        XCTAssertTrue(reply.isError, "a deferred rollback changed nothing: \(reply.text)")
    }

    // MARK: Transport

    /// Nothing is resent, so a call whose route replies only when the work
    /// is done waits the long deadline; ordinary calls keep the short one.
    func testLongCallsWaitForASlowReplyAndShortOnesDoNot() async throws {
        let fake = try FakeLocalAPI(unixSocket: socketPath, behavior: .respondAfter(seconds: 2))
        let tcp = try FakeLocalAPI(tcpLoopback: .respond)
        defer {
            fake.stop()
            tcp.stop()
        }
        let server = makeServer(tcpPort: tcp.port, socketTimeoutSeconds: 1, longCallSeconds: 6)
        let pulled = try await call(server, "pull", ["reference": "alpine:3.20", "runtime": "hvf"])
        XCTAssertFalse(pulled.isError, pulled.text)
        let pruned = try await call(server, "cache_prune", ["dry_run": true])
        XCTAssertFalse(pruned.isError, pruned.text)
        let policy = try await call(server, "cache_policy", [:])
        XCTAssertTrue(policy.isError, "a 2 s reply to a 1 s call: \(policy.text)")
        XCTAssertTrue(policy.text.contains("It was not resent"), policy.text)
        XCTAssertEqual(fake.requests.map(\.path), ["/v1/images/pull", "/v1/caches/prune", "/v1/caches/policy"])
        XCTAssertEqual(tcp.requests.count, 0)
    }

    /// A daemon that took the request and then went quiet may be applying
    /// it: the server must report that, not resend over TCP.
    func testMutationsAreSentOnceWhenTheSocketTakesThemAndNeverAnswers() async throws {
        let socket = try FakeLocalAPI(unixSocket: socketPath, behavior: .stall)
        let tcp = try FakeLocalAPI(tcpLoopback: .respond)
        defer {
            socket.stop()
            tcp.stop()
        }
        let server = makeServer(tcpPort: tcp.port, socketTimeoutSeconds: 1)
        let mutations: [(String, [String: Any])] = [
            ("cache_prune", ["apply": true, "all": true]),
            ("cache_policy_set", ["shared_l0": true]),
            ("runtime_mode", ["mode": "sandbox"]),
            ("update_hvf_rollback", [:]),
        ]
        for (index, (tool, arguments)) in mutations.enumerated() {
            let reply = try await call(server, tool, arguments)
            XCTAssertTrue(reply.isError, "\(tool): \(reply.text)")
            XCTAssertTrue(reply.text.contains("It was not resent"), "\(tool): \(reply.text)")
            XCTAssertEqual(socket.requests.count, index + 1, "\(tool) reached the socket exactly once")
            XCTAssertEqual(tcp.requests.count, 0, "\(tool) was replayed over TCP")
        }
        XCTAssertEqual(
            socket.requests.map(\.path),
            ["/v1/caches/prune", "/v1/caches/policy", "/v1/rig/mode", "/v1/rig/hvf/update/rollback"])
    }

    /// A socket nobody listens on refused the connection before a byte
    /// was written, so loopback HTTP may carry the request — once.
    func testLoopbackHTTPCarriesARequestTheSocketRefused() async throws {
        // A stale socket file: bound, never listened on, then closed.
        let stale = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try RuntimeUnixSocket.address(socketPath)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        Darwin.close(stale)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        let tcp = try FakeLocalAPI(tcpLoopback: .respond)
        defer { tcp.stop() }
        let server = makeServer(tcpPort: tcp.port, socketTimeoutSeconds: 1)
        let reply = try await call(server, "cache_prune", ["apply": true, "scope": "proj"])
        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertEqual(tcp.requests.count, 1)
        XCTAssertEqual(tcp.requests.first?.path, "/v1/caches/prune")
        XCTAssertEqual(tcp.requests.first?.json["scope"] as? String, "proj")
        XCTAssertEqual(tcp.evictions, 1)
    }

    func testExchangeTellsARefusedConnectionFromALostReply() async throws {
        let missing = directory.appendingPathComponent("none.sock").path
        guard case .notSent = await LocalAPI.exchange(missing, "GET", "/v1/caches", nil, timeoutSeconds: 1) else {
            return XCTFail("a missing socket sends nothing")
        }
        let stalled = try FakeLocalAPI(unixSocket: socketPath, behavior: .stall)
        defer { stalled.stop() }
        let lost = await LocalAPI.exchange(socketPath, "POST", "/v1/caches/prune", Data("{}".utf8), timeoutSeconds: 1)
        XCTAssertEqual(lost, .lost("no reply came within 1 s"))
        XCTAssertEqual(stalled.requests.count, 1)
    }
}
