import Darwin
import Foundation
import MicropodCore
import XCTest

@testable import MicropodMCP

/// The cache and rig tools, driven through the server's JSON-RPC entry
/// point against a fake API daemon that speaks binary Connect.
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
        MCPTestServer.make(
            socketPath: socketPath, tcpPort: tcpPort, socketTimeoutSeconds: socketTimeoutSeconds,
            longCallSeconds: longCallSeconds)
    }

    private func call(_ server: MCPServer, _ tool: String, _ arguments: [String: Any]) async throws
        -> MCPTestServer.ToolReply
    {
        try await MCPTestServer.call(server, tool, arguments)
    }

    private func prunes(_ fake: FakeLocalAPI) throws -> [Micropod_V1_PruneCachesRequest] {
        try fake.requests.filter { $0.rpc == "PruneCaches" }.map { try $0.message(Micropod_V1_PruneCachesRequest.self) }
    }

    private func policyWrites(_ fake: FakeLocalAPI) throws -> [Micropod_V1_SetCachePolicyRequest] {
        try fake.requests.filter { $0.rpc == "SetCachePolicy" }
            .map { try $0.message(Micropod_V1_SetCachePolicyRequest.self) }
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
        XCTAssertEqual(
            fake.requests.map(\.path), Array(repeating: "/api/micropod.v1.CacheService/PruneCaches", count: 4))
        for (request, arguments) in zip(try prunes(fake), calls) {
            XCTAssertFalse(request.apply, "\(arguments): apply false is the dry run")
            XCTAssertFalse(request.hasMaxBytes, "\(arguments)")
            XCTAssertEqual(request.reason, "mcp")
        }
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

        let requests = try prunes(fake)
        guard requests.count == 3 else { return XCTFail("\(requests.count) requests, want 3") }
        XCTAssertTrue(requests[0].apply)
        XCTAssertEqual(requests[0].maxBytes, 1000)
        XCTAssertTrue(requests[1].apply)
        XCTAssertEqual(requests[1].maxBytes, 20 << 30)
        XCTAssertEqual(requests[1].olderThanSecs, 14 * 86400)
        XCTAssertEqual(requests[1].scope, "proj")
        XCTAssertEqual(requests[1].tool, "go")
        XCTAssertTrue(requests[1].hasPartialGoBuild)
        XCTAssertFalse(requests[1].partialGoBuild)
        XCTAssertTrue(requests[2].apply)
        XCTAssertTrue(requests[2].all)
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

        let requests = try policyWrites(fake)
        guard requests.count == 2 else { return XCTFail("\(requests.count) writes, want 2") }
        XCTAssertEqual(try requests[0].jsonString(), #"{"sharedL0":true}"#, "only the setting named")
        let second = requests[1]
        XCTAssertFalse(second.sharedL0)
        XCTAssertTrue(second.hasSharedL0)
        XCTAssertEqual(second.maxBytes, 50 << 30)
        XCTAssertEqual(second.maxAgeDays, 14)
        XCTAssertEqual(second.goProxy, "", "off clears the proxy")
        XCTAssertTrue(second.hasGoProxy)
        XCTAssertEqual(second.npmRegistry, "http://10.43.0.1:5555/npm")
        XCTAssertEqual(second.defaultScope, "", "none: only containers naming a scope")
        XCTAssertTrue(second.hasDefaultScope)
        XCTAssertEqual(second.mode, "auto")
    }

    func testPolicySetSendsTheDockerSocketPolicy() async throws {
        let fake = try FakeLocalAPI(unixSocket: socketPath)
        defer { fake.stop() }
        let server = makeServer()
        let reply = try await call(server, "cache_policy_set", ["docker_socket": "any"])
        XCTAssertFalse(reply.isError, reply.text)
        let requests = try policyWrites(fake)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(try requests.first?.jsonString(), #"{"dockerSocket":"any"}"#)
    }

    func testPolicySetSendsTheDefaultTrustTier() async throws {
        let fake = try FakeLocalAPI(unixSocket: socketPath)
        defer { fake.stop() }
        let server = makeServer()
        let reply = try await call(
            server, "cache_policy_set", ["default_trust": "untrusted", "proxy_untrusted": false])
        XCTAssertFalse(reply.isError, reply.text)
        let requests = try policyWrites(fake)
        XCTAssertEqual(requests.count, 1)
        guard let body = requests.first else { return }
        XCTAssertEqual(body.defaultTrust, "untrusted")
        XCTAssertTrue(body.hasProxyUntrusted)
        XCTAssertFalse(body.proxyUntrusted)
        XCTAssertEqual(try body.jsonString(), #"{"defaultTrust":"untrusted","proxyUntrusted":false}"#)
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
        let bodies = try policyWrites(fake)
        guard bodies.count == 3 else { return XCTFail("\(bodies.count) requests, want 3") }
        XCTAssertTrue(bodies[0].hasGoProxy)
        XCTAssertEqual(bodies[0].goProxy, "")
        XCTAssertTrue(bodies[0].sharedL0)
        XCTAssertEqual(try bodies[1].jsonString(), #"{"npmRegistry":""}"#)
        XCTAssertEqual(try bodies[2].jsonString(), #"{"defaultScope":""}"#, "null still means omitted")
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
            try fake.requests.map { try $0.message(Micropod_V1_ContainerRef.self).id },
            ["web-1", "my.box_2", "0123abcdef"])
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
        XCTAssertEqual(
            try fake.requests.map { try $0.message(Micropod_V1_SampleCacheDedupeRequest.self).buckets }, [32, 16])
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
        XCTAssertEqual(
            try fake.requests.map { try $0.message(Micropod_V1_HVFUpdateRequest.self).force }, [false, true])

        // The daemon answers a deferral with failed_precondition and its detail.
        fake.respond { _ in
            .error(status: 400, code: "failed_precondition", message: "deferred: 2 running container(s)")
        }
        reply = try await call(server, "update_hvf_rollback", [:])
        XCTAssertTrue(reply.isError, "a deferred rollback changed nothing: \(reply.text)")
        XCTAssertEqual(reply.text, "deferred: 2 running container(s)")
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
        let pruned = try await call(server, "cache_prune", ["dry_run": true])
        XCTAssertFalse(pruned.isError, pruned.text)
        let policy = try await call(server, "cache_policy", [:])
        XCTAssertTrue(policy.isError, "a 2 s reply to a 1 s call: \(policy.text)")
        XCTAssertTrue(policy.text.contains("It was not resent"), policy.text)
        XCTAssertEqual(fake.requests.map(\.rpc), ["PruneCaches", "GetCachePolicy"])
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
            ("exec", ["id": "web-1", "command": "echo once >> /out/x"]),
        ]
        for (index, (tool, arguments)) in mutations.enumerated() {
            let reply = try await call(server, tool, arguments)
            XCTAssertTrue(reply.isError, "\(tool): \(reply.text)")
            XCTAssertTrue(reply.text.contains("It was not resent"), "\(tool): \(reply.text)")
            XCTAssertEqual(socket.requests.count, index + 1, "\(tool) reached the socket exactly once")
            XCTAssertEqual(tcp.requests.count, 0, "\(tool) was replayed over TCP")
        }
        XCTAssertEqual(
            socket.requests.map(\.rpc), ["PruneCaches", "SetCachePolicy", "SetRigMode", "RollbackHVFUpdate", "Exec"])
    }

    /// A socket nobody listens on refused the connection before a byte
    /// was written, so loopback TCP may carry the request — once.
    func testLoopbackTCPCarriesARequestTheSocketRefused() async throws {
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
        XCTAssertEqual(tcp.requests.first?.contentType, "application/proto")
        XCTAssertEqual(try tcp.requests.first?.message(Micropod_V1_PruneCachesRequest.self).scope, "proj")
    }
}
