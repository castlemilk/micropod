import Darwin
import Foundation
import MicropodCore
import MicropodRuntime
import SwiftProtobuf
import XCTest

@testable import MicropodAPI

/// CacheService, RigService and the reports the MCP server reads over
/// binary Connect, on a throwaway HVF root with a fake guest engine on the
/// machine's Docker socket: each RPC answers in binary protobuf and in
/// proto-JSON, carries what its REST twin answers for the same state, and
/// refuses what the REST twin refuses before the guest or machine.json sees
/// anything.
final class ControlPlaneServiceTests: XCTestCase {
    private var root: URL!
    private var layout: HVFMachineLayout!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/mp-cs-\(UUID().uuidString.prefix(8))")
        layout = HVFMachineLayout(root: root)
        try FileManager.default.createDirectory(at: layout.runDirectory, withIntermediateDirectories: true)
        try HVFMachineConfig().save(to: layout.config)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeHandlers() async -> APIHandlers {
        let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/usr/bin/false"))
        let services = await RuntimeBackendResolver.resolveApple(
            client: client, environment: ["MICROPOD_RUNTIME": "cli"])
        let holder = RuntimeHolder(initial: services, resolve: { services }, managedSelectionPresent: { false })
        let registry = EngineRegistry(environment: [
            "MICROPOD_HVF_ROOT": root.path,
            "MICROPOD_RUNTIMES_CONFIG": root.appendingPathComponent("runtimes.json").path,
        ])
        return APIHandlers(
            client: client, system: SystemService(client: client), images: ImageService(client: client),
            networks: NetworkService(client: client), compose: ComposeService(client: client), runtime: holder,
            engineRegistry: registry)
    }

    private struct Reply {
        var status: Int
        var contentType: String
        var body: Data
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:] }
    }

    private func reply(_ response: HTTPResponse) -> Reply {
        switch response {
        case .json(let status, let object):
            return Reply(
                status: status, contentType: "application/json",
                body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        case .data(let status, let type, let data): return Reply(status: status, contentType: type, body: data)
        default: return Reply(status: -1, contentType: "", body: Data())
        }
    }

    private func rpc(
        _ api: APIHandlers, _ service: String, _ method: String, _ message: some Message, binary: Bool = true
    ) async throws -> Reply {
        let body = binary ? try message.serializedData() : try message.jsonUTF8Data()
        return reply(
            await api.handle(
                HTTPRequest(
                    method: .post, path: "/api/micropod.v1.\(service)/\(method)", query: [:], body: body,
                    headers: ["content-type": binary ? "application/proto" : "application/json"])))
    }

    private func rest(_ api: APIHandlers, _ method: HTTPMethod, _ path: String, query: [String: String] = [:])
        async -> Reply
    {
        reply(
            await api.handle(
                HTTPRequest(method: method, path: path, query: query, body: Data(), headers: [:])))
    }

    private func decoded<M: Message>(_ type: M.Type, _ reply: Reply, file: StaticString = #filePath, line: UInt = #line)
        throws -> M
    {
        XCTAssertEqual(reply.status, 200, String(decoding: reply.body, as: UTF8.self), file: file, line: line)
        if reply.contentType.hasPrefix("application/proto") { return try M(serializedBytes: reply.body) }
        return try M(jsonUTF8Data: reply.body)
    }

    /// The same data: equal JSON once absent, null and empty collections are
    /// treated alike (REST leaves an unset optional list out; the typed reply
    /// carries it empty).
    private func assertSameData(
        _ rest: Any, _ rendered: Any, _ what: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let a = Self.normalized(rest) as? NSObject
        let b = Self.normalized(Self.roundTrip(rendered)) as? NSObject
        XCTAssertEqual(
            a, b, "\(what)\nREST: \(ControlPlaneJSON.text(rest))\nRPC:  \(ControlPlaneJSON.text(rendered))", file: file,
            line: line)
    }

    /// As JSON text parses back, so both sides hold the same kinds of values.
    private static func roundTrip(_ value: Any) -> Any {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return value }
        return (try? JSONSerialization.jsonObject(with: data)) ?? value
    }

    private static func normalized(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, item) in object {
                if item is NSNull { continue }
                if let list = item as? [Any], list.isEmpty { continue }
                if let map = item as? [String: Any], map.isEmpty { continue }
                out[key] = normalized(item)
            }
            return out
        }
        if let list = value as? [Any] { return list.map(normalized) }
        return value
    }

    // MARK: CacheService

    func testEveryCacheRPCAnswersInBinaryAndProtoJSON() async throws {
        let guest = try FakeCacheGuest(path: layout.dockerSocket.path)
        defer { guest.stop() }
        let api = await makeHandlers()
        for binary in [true, false] {
            let status = try decoded(
                Micropod_V1_CacheStatus.self,
                try await rpc(
                    api, "CacheService", "GetCacheStatus", Micropod_V1_GetCacheStatusRequest(), binary: binary))
            XCTAssertEqual(status.policyDigest, "75abc5e1efc67ade")
            XCTAssertEqual(status.units.count, 2)
            let units = try decoded(
                Micropod_V1_ListCacheUnitsResponse.self,
                try await rpc(
                    api, "CacheService", "ListCacheUnits", Micropod_V1_ListCacheUnitsRequest(), binary: binary))
            XCTAssertEqual(units.units.count, 2)
            let explain = try decoded(
                Micropod_V1_ContainerCacheExplain.self,
                try await rpc(
                    api, "CacheService", "ExplainContainerCache", Micropod_V1_ContainerRef.with { $0.id = "web-1" },
                    binary: binary))
            XCTAssertEqual(explain.containerName, "web-1")
            let dedupe = try decoded(
                Micropod_V1_CacheDedupeSample.self,
                try await rpc(
                    api, "CacheService", "SampleCacheDedupe",
                    Micropod_V1_SampleCacheDedupeRequest.with { $0.buckets = 4 },
                    binary: binary))
            XCTAssertEqual(dedupe.bucketsSampled, 4)
            let pruned = try decoded(
                Micropod_V1_PruneCachesResponse.self,
                try await rpc(api, "CacheService", "PruneCaches", Micropod_V1_PruneCachesRequest(), binary: binary))
            XCTAssertTrue(pruned.dryRun)
            let policy = try decoded(
                Micropod_V1_CachePolicy.self,
                try await rpc(api, "CacheService", "GetCachePolicy", Micropod_V1_Empty(), binary: binary))
            XCTAssertEqual(policy.mode, "auto")
            let saved = try decoded(
                Micropod_V1_SetCachePolicyResponse.self,
                try await rpc(
                    api, "CacheService", "SetCachePolicy",
                    Micropod_V1_SetCachePolicyRequest.with { $0.maxAgeDays = binary ? 41 : 42 }, binary: binary))
            XCTAssertEqual(saved.policy.maxAgeDays, binary ? 41 : 42)
        }
        XCTAssertEqual(try HVFMachineConfig.load(from: layout.config).effectiveCachePolicy.maxAgeDays, 42)
        // Dedupe asked the guest for the buckets named.
        XCTAssertEqual(
            guest.requests.filter { $0.path == "/micropod/caches/dedupe" }.map(\.query), ["buckets=4", "buckets=4"])
    }

    func testCacheRPCsCarryWhatTheRESTRoutesAnswer() async throws {
        let guest = try FakeCacheGuest(path: layout.dockerSocket.path)
        defer { guest.stop() }
        let api = await makeHandlers()

        let status = try decoded(
            Micropod_V1_CacheStatus.self,
            try await rpc(api, "CacheService", "GetCacheStatus", Micropod_V1_GetCacheStatusRequest()))
        assertSameData(await rest(api, .get, "/v1/caches").json, ControlPlaneJSON.status(status), "GET /v1/caches")

        let dedupe = try decoded(
            Micropod_V1_CacheDedupeSample.self,
            try await rpc(api, "CacheService", "SampleCacheDedupe", Micropod_V1_SampleCacheDedupeRequest()))
        assertSameData(
            await rest(api, .get, "/v1/caches/dedupe", query: ["buckets": "16"]).json, ControlPlaneJSON.dedupe(dedupe),
            "GET /v1/caches/dedupe")

        let explain = try decoded(
            Micropod_V1_ContainerCacheExplain.self,
            try await rpc(
                api, "CacheService", "ExplainContainerCache", Micropod_V1_ContainerRef.with { $0.id = "web-1" }))
        assertSameData(
            await rest(api, .get, "/v1/caches/explain/web-1").json, ControlPlaneJSON.explain(explain),
            "GET /v1/caches/explain")

        let policy = try decoded(
            Micropod_V1_CachePolicy.self, try await rpc(api, "CacheService", "GetCachePolicy", Micropod_V1_Empty()))
        assertSameData(await rest(api, .get, "/v1/caches/policy").json, ControlPlaneJSON.policy(policy), "policy")

        let pruned = try decoded(
            Micropod_V1_PruneCachesResponse.self,
            try await rpc(api, "CacheService", "PruneCaches", Micropod_V1_PruneCachesRequest()))
        let restPrune = reply(
            await api.handle(
                HTTPRequest(
                    method: .post, path: "/v1/caches/prune", query: [:], body: Data("{}".utf8),
                    headers: ["content-type": "application/json"])))
        assertSameData(restPrune.json, ControlPlaneJSON.prune(pruned), "POST /v1/caches/prune")
    }

    func testPruneCachesIsADryRunUnlessApplyAndAnUnselectedApplyNeedsAll() async throws {
        let guest = try FakeCacheGuest(path: layout.dockerSocket.path)
        defer { guest.stop() }
        let api = await makeHandlers()
        _ = try decoded(
            Micropod_V1_PruneCachesResponse.self,
            try await rpc(api, "CacheService", "PruneCaches", Micropod_V1_PruneCachesRequest()))
        _ = try decoded(
            Micropod_V1_PruneCachesResponse.self,
            try await rpc(api, "CacheService", "PruneCaches", Micropod_V1_PruneCachesRequest(), binary: false))
        let refused = try await rpc(
            api, "CacheService", "PruneCaches", Micropod_V1_PruneCachesRequest.with { $0.apply = true })
        XCTAssertEqual(refused.status, 400)
        XCTAssertEqual(refused.json["code"] as? String, "invalid_argument")
        XCTAssertTrue((refused.json["message"] as? String ?? "").contains("\"all\": true"), "\(refused.json)")
        let badScope = try await rpc(
            api, "CacheService", "PruneCaches",
            Micropod_V1_PruneCachesRequest.with {
                $0.apply = true
                $0.scope = "Not A Scope"
            })
        XCTAssertEqual(badScope.json["code"] as? String, "invalid_argument")
        _ = try decoded(
            Micropod_V1_PruneCachesResponse.self,
            try await rpc(
                api, "CacheService", "PruneCaches",
                Micropod_V1_PruneCachesRequest.with {
                    $0.apply = true
                    $0.scope = "proj"
                }))
        let prunes = guest.requests.filter { $0.path == "/micropod/caches/prune" }.map(\.json)
        XCTAssertEqual(prunes.map { $0["dryRun"] as? Bool }, [true, true, false], "the guest saw: \(prunes)")
        XCTAssertEqual(prunes.last?["scope"] as? String, "proj")
    }

    func testSetCachePolicyNamingNothingIsInvalidAndWritesNothing() async throws {
        let api = await makeHandlers()
        let before = try Data(contentsOf: layout.config)
        for binary in [true, false] {
            let reply = try await rpc(
                api, "CacheService", "SetCachePolicy", Micropod_V1_SetCachePolicyRequest(), binary: binary)
            XCTAssertEqual(reply.status, 400)
            XCTAssertEqual(reply.json["code"] as? String, "invalid_argument")
            XCTAssertTrue((reply.json["message"] as? String ?? "").contains("nothing was written"), "\(reply.json)")
        }
        let bad = try await rpc(
            api, "CacheService", "SetCachePolicy", Micropod_V1_SetCachePolicyRequest.with { $0.mode = "bogus" })
        XCTAssertEqual(bad.json["code"] as? String, "invalid_argument")
        XCTAssertEqual(try Data(contentsOf: layout.config), before, "machine.json is untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.cachePolicyFile.path))

        // A clear is a value: "" clears go_proxy, 0 clears max_bytes.
        _ = try decoded(
            Micropod_V1_SetCachePolicyResponse.self,
            try await rpc(
                api, "CacheService", "SetCachePolicy",
                Micropod_V1_SetCachePolicyRequest.with {
                    $0.goProxy = "http://10.42.0.1:7677/go|direct"
                    $0.maxBytes = 1 << 30
                }))
        _ = try decoded(
            Micropod_V1_SetCachePolicyResponse.self,
            try await rpc(
                api, "CacheService", "SetCachePolicy",
                Micropod_V1_SetCachePolicyRequest.with {
                    $0.goProxy = ""
                    $0.maxBytes = 0
                }))
        let policy = try HVFMachineConfig.load(from: layout.config).effectiveCachePolicy
        XCTAssertNil(policy.goProxy)
        XCTAssertNil(policy.maxBytes)
    }

    func testExplainingAnUnknownContainerIsNotFoundAndABadIdIsInvalid() async throws {
        let guest = try FakeCacheGuest(path: layout.dockerSocket.path)
        defer { guest.stop() }
        let api = await makeHandlers()
        let missing = try await rpc(
            api, "CacheService", "ExplainContainerCache", Micropod_V1_ContainerRef.with { $0.id = "nope" })
        XCTAssertEqual(missing.status, 404, String(decoding: missing.body, as: UTF8.self))
        XCTAssertEqual(missing.json["code"] as? String, "not_found")
        let bad = try await rpc(
            api, "CacheService", "ExplainContainerCache", Micropod_V1_ContainerRef.with { $0.id = "../images" })
        XCTAssertEqual(bad.json["code"] as? String, "invalid_argument")
        XCTAssertEqual(
            guest.requests.filter { $0.path.hasPrefix("/containers/") }.map(\.path), ["/containers/nope/json"])
    }

    func testListCacheUnitsSelectsByScopeLayerAndTool() async throws {
        let guest = try FakeCacheGuest(path: layout.dockerSocket.path)
        defer { guest.stop() }
        let api = await makeHandlers()
        func units(_ request: Micropod_V1_ListCacheUnitsRequest) async throws -> [String] {
            try decoded(
                Micropod_V1_ListCacheUnitsResponse.self,
                try await rpc(api, "CacheService", "ListCacheUnits", request)
            ).units.map { "\($0.scope)/\($0.unit)" }
        }
        let all = try await units(.init())
        XCTAssertEqual(all, ["default/gomod", "proj/gobuild"])
        let l1 = try await units(.with { $0.layer = "L1" })
        XCTAssertEqual(l1, ["proj/gobuild"])
        let go = try await units(.with { $0.tool = "go" })
        XCTAssertEqual(go, ["default/gomod", "proj/gobuild"])
        let npm = try await units(.with { $0.tool = "npm" })
        XCTAssertEqual(npm, [])
        let scoped = try await units(.with { $0.scope = "default" })
        XCTAssertEqual(scoped, ["default/gomod"])
        for bad in [Micropod_V1_ListCacheUnitsRequest.with { $0.layer = "L2" }, .with { $0.tool = "cobol" }] {
            let reply = try await rpc(api, "CacheService", "ListCacheUnits", bad)
            XCTAssertEqual(reply.json["code"] as? String, "invalid_argument", "\(bad)")
        }
    }

    func testACacheRPCWithNoMachineRunningIsAFailedPrecondition() async throws {
        let api = await makeHandlers()
        let reply = try await rpc(api, "CacheService", "GetCacheStatus", Micropod_V1_GetCacheStatusRequest())
        XCTAssertEqual(reply.json["code"] as? String, "failed_precondition", "\(reply.json)")
    }

    // MARK: RigService

    func testRigRPCsCarryWhatTheRESTRoutesAnswer() async throws {
        let api = await makeHandlers()
        let mode = try decoded(
            Micropod_V1_RigMode.self, try await rpc(api, "RigService", "GetRigMode", Micropod_V1_Empty()))
        XCTAssertEqual(mode.modes.map(\.name), ["container", "sandbox"])
        assertSameData(await rest(api, .get, "/v1/rig/mode").json, ControlPlaneJSON.rigMode(mode), "rig mode")

        let update = try decoded(
            Micropod_V1_HVFUpdateStatus.self,
            try await rpc(api, "RigService", "GetHVFUpdateStatus", Micropod_V1_Empty(), binary: false))
        let restUpdate = await rest(api, .get, "/v1/rig/hvf/update").json
        XCTAssertNotNil(restUpdate["availableVersions"])
        assertSameData(restUpdate, ControlPlaneJSON.updateStatus(update), "hvf update status")
        // REST writes these even when false or empty; so does the rendering.
        let rendered = ControlPlaneJSON.updateStatus(update)
        XCTAssertEqual(rendered["updatePending"] as? Bool, false)
        XCTAssertEqual(rendered["availableVersions"] as? [String], [])

        let health = try decoded(
            Micropod_V1_RigHealth.self, try await rpc(api, "RigService", "GetRigHealth", Micropod_V1_Empty()))
        XCTAssertEqual(health.hvf.root, root.path)
        var restHealth = await rest(api, .get, "/v1/rig/health").json
        var renderedHealth = ControlPlaneJSON.rigHealth(health)
        // The loopback depproxy is probed per call; compare everything else.
        restHealth["depproxy"] = nil
        renderedHealth["depproxy"] = nil
        assertSameData(restHealth, renderedHealth, "rig health")
    }

    func testRollbackWithNothingToReturnToIsAFailedPrecondition() async throws {
        let api = await makeHandlers()
        for force in [false, true] {
            let reply = try await rpc(
                api, "RigService", "RollbackHVFUpdate", Micropod_V1_HVFUpdateRequest.with { $0.force = force })
            XCTAssertEqual(reply.json["code"] as? String, "failed_precondition", "\(reply.json)")
            XCTAssertTrue((reply.json["message"] as? String ?? "").contains("no known-good"), "\(reply.json)")
        }
        // Nothing staged: an apply is a no-op that stops nothing.
        let applied = try decoded(
            Micropod_V1_HVFUpdateResult.self,
            try await rpc(api, "RigService", "ApplyHVFUpdate", Micropod_V1_HVFUpdateRequest()))
        XCTAssertEqual(applied.action, "noop")
        XCTAssertNil(APIHandlers.updateFailure(.noop, applying: true))
        XCTAssertNil(APIHandlers.updateFailure(.activated, applying: true))
        XCTAssertNil(APIHandlers.updateFailure(.rolledBack, applying: false), "a rollback that got there succeeded")
        XCTAssertEqual(
            APIHandlers.updateFailure(.rolledBack, applying: true), .failedPrecondition,
            "the update did not take, and replaying it would restart the machine again: never a retried code")
        XCTAssertEqual(APIHandlers.updateFailure(.deferred, applying: false), .failedPrecondition)
        XCTAssertEqual(APIHandlers.updateFailure(.failedRollback, applying: false), .internal)
        XCTAssertEqual(APIHandlers.updateFailure(.failed, applying: true), .internal)
    }

    func testMachineStatusReadsTheRootAndControlRefusesAnUnknownAction() async throws {
        let api = await makeHandlers()
        let status = try decoded(
            Micropod_V1_HVFMachineStatus.self,
            try await rpc(api, "RigService", "GetMachineStatus", Micropod_V1_Empty()))
        XCTAssertEqual(status.root, root.path)
        XCTAssertEqual(status.phase, "stopped")
        XCTAssertFalse(status.installed)
        XCTAssertFalse(status.supervisorAlive)
        XCTAssertTrue(status.summary.hasPrefix("not installed"), status.summary)
        let refused = try await rpc(
            api, "RigService", "ControlMachine", Micropod_V1_ControlMachineRequest.with { $0.action = "explode" })
        XCTAssertEqual(refused.json["code"] as? String, "invalid_argument")
        // Stopping a machine nothing runs is a no-op that leaves it stopped.
        let stopped = try decoded(
            Micropod_V1_HVFMachineStatus.self,
            try await rpc(
                api, "RigService", "ControlMachine", Micropod_V1_ControlMachineRequest.with { $0.action = "stop" }))
        XCTAssertEqual(stopped.phase, "stopped")
    }

    func testMachineStatusSaysAStopWasAskedFor() throws {
        let client = HVFMachineClient(layout: layout)
        XCTAssertFalse(RigProto.machineStatus(client.status()).stoppedOnRequest, "never started")
        try HVFMachineState(phase: .stopped, supervisorPID: 42).save(to: layout.state)
        XCTAssertTrue(RigProto.machineStatus(client.status()).stoppedOnRequest)
        try HVFMachineState(phase: .running, supervisorPID: 42).save(to: layout.state)
        let crashed = RigProto.machineStatus(client.status())
        XCTAssertFalse(crashed.stoppedOnRequest, "a supervisor that died without stopping")
        XCTAssertEqual(crashed.phase, "stopped")
        XCTAssertEqual(crashed.state.phase, "running", "the state file as published")
    }

    // MARK: Telemetry, sandbox and the Apple runtime

    func testTelemetryWithNoWorkerIsUnavailable() async throws {
        let api = await makeHandlers()
        for method in ["GetTelemetryHealth", "ListTelemetryIssues", "GetTraces"] {
            let reply = try await rpc(api, "TelemetryService", method, Micropod_V1_Empty())
            XCTAssertEqual(reply.json["code"] as? String, "unavailable", "\(method): \(reply.json)")
        }
    }

    func testSandboxStatusRendersWhatTheCLIPrints() async throws {
        let api = await makeHandlers()
        let status = try decoded(
            Micropod_V1_SandboxStatus.self,
            try await rpc(api, "SandboxService", "GetSandboxStatus", Micropod_V1_Empty()))
        let cli = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(SandboxVM.assetStatus())) as? [String: Any])
        assertSameData(cli, ControlPlaneJSON.sandboxStatus(status), "sandbox status --json")
    }

    func testRuntimeDependencyCarriesWhatTheRESTRouteAnswersAndTheStatusItWasJudgedFrom() async throws {
        let api = await makeHandlers()
        let dependency = try decoded(
            Micropod_V1_RuntimeDependency.self,
            try await rpc(api, "SystemService", "GetRuntimeDependency", Micropod_V1_Empty()))
        assertSameData(
            await rest(api, .get, "/v1/system/dependency").json, ControlPlaneJSON.runtimeDependency(dependency),
            "GET /v1/system/dependency")
    }
}

/// The guest engine's cache routes and container inspect on a Unix socket,
/// with a fixed inventory; records each request (version prefix stripped).
private final class FakeCacheGuest: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        var query: String
        var body: Data
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:] }
    }

    static let inventory = #"""
        {"root":"/micropod/cache","mountPoint":"/micropod/cache","mountL0Point":"/micropod/cache-l0",
         "policy":{"version":1,"mode":"auto","defaultScope":"default","allowedScopes":["*"],"tools":["gomod","gobuild"],
                   "goTrimpath":true,"pnpmLegacyEnv":true,"sharedL0":true,"maxAgeDays":30,"buildkit":{"registerBuildx":false,"x":1},
                   "futureKey":{"nested":[1,2.5,"z",null,true]}},
         "policyDigest":"75abc5e1efc67ade",
         "scopes":{"default":["gomod"],"proj":["gobuild"]},
         "units":[{"scope":"default","kind":"gomod","unit":"gomod","uid":0,"layer":"L0","path":"/micropod/cache/gomod",
                   "bytes":12345,"logicalBytes":20000,"files":3,"lastUsedUnix":1795700000,"inUse":false,"dirty":false},
                  {"scope":"proj","kind":"gobuild","unit":"gobuild","layer":"L1","path":"/micropod/cache/proj/gobuild",
                   "bytes":4096,"logicalBytes":4096,"files":1,"lastUsedUnix":1795700100,"inUse":true}],
         "totals":{"totalBytes":16441,"logicalBytes":24096,"totalFiles":4,"scopeCount":2,"unitCount":2,"inUseCount":1,
                   "l0Bytes":12345,"l1Bytes":4096,"dirtyCount":0},
         "budget":{"maxBytes":0,"minFreeBytes":0,"maxAgeDays":30,"utilizationPct":12.5},
         "evictions":{"evictions":2,"evictedUnits":1,"evictedFiles":7,"evictedBytes":9000,"lastSweepUnix":1795600000,
                      "lastSweepReason":"janitor"},
         "metrics":{"ignored":1},
         "discardedAtStart":null,"keptAtStart":["proj/gobuild"],
         "cacheDisk":{"state":"mounted","device":"/dev/vdb","mounted":true,"sizeBytes":2212347904,"freeBytes":2195435520}}
        """#

    private let path: String
    private let fd: Int32
    private let lock = NSLock()
    private var seen: [Request] = []
    private var stopped = false

    init(path: String) throws {
        self.path = path
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try RuntimeUnixSocket.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard fd >= 0, bound == 0, listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw MicropodError.message("fake guest: bind \(path): \(String(cString: strerror(errno)))")
        }
        Thread.detachNewThread { [self] in serve() }
    }

    var requests: [Request] { lock.withLock { seen } }

    func stop() { lock.withLock { stopped = true } }

    private func serve() {
        defer {
            Darwin.close(fd)
            unlink(path)
        }
        while !lock.withLock({ stopped }) {
            var poll = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&poll, 1, 20) > 0 else { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            handle(client)
            Darwin.close(client)
        }
    }

    private func handle(_ client: Int32) {
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        func fill() -> Bool {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { return false }
            data.append(contentsOf: buffer[0..<count])
            return true
        }
        let separator = Data("\r\n\r\n".utf8)
        while data.range(of: separator) == nil { guard fill() else { return } }
        guard let end = data.range(of: separator) else { return }
        let lines = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
            .components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return }
        let length =
            lines.dropFirst().first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        while data.count - end.upperBound < length { guard fill() else { break } }
        let parts = String(requestLine[1]).split(separator: "?", maxSplits: 1).map(String.init)
        var target = parts.first ?? ""
        if target.hasPrefix("/v1.") { target = String(target.drop { $0 != "/" }.dropFirst().drop { $0 != "/" }) }
        let request = Request(
            method: String(requestLine[0]), path: target, query: parts.count > 1 ? parts[1] : "",
            body: Data(data[end.upperBound...]))
        var status = 200
        let reply: Data
        switch request.path {
        case "/_ping":
            reply = Data("OK".utf8)
        case "/micropod/caches":
            lock.withLock { seen.append(request) }
            reply = Data(Self.inventory.utf8)
        case "/micropod/caches/dedupe":
            lock.withLock { seen.append(request) }
            let buckets = Int(request.query.replacingOccurrences(of: "buckets=", with: "")) ?? 16
            reply = Data(
                #"{"scopesSampled":["default","proj"],"bucketsSampled":\#(buckets),"totalObjects":10,"uniqueObjects":8,"duplicateObjects":2,"duplicateBytes":300,"estimatedFullDuplicateBytes":4800}"#
                    .utf8)
        case "/micropod/caches/prune":
            lock.withLock { seen.append(request) }
            let dryRun = request.json["dryRun"] as? Bool ?? false
            reply = Data(
                #"{"dryRun":\#(dryRun),"reason":"api","freedBytes":10,"freedFiles":1,"evictedUnits":1,"skippedInUse":0,"beforeBytes":20,"afterBytes":10,"actions":[{"scope":"proj","unit":"gobuild","action":"evict","bytes":10}],"skippedDirty":0}"#
                    .utf8)
        case "/containers/web-1/json":
            lock.withLock { seen.append(request) }
            reply = Data(
                #"{"Id":"0123abcd","Name":"/web-1","Image":"alpine","State":{"Status":"running"},"MicropodCache":{"scope":"s","uid":0,"trust":"untrusted","policyDigest":"7a3e25f1ddb256fe","tools":{"gomod":{"mode":"env","path":"/micropod/cache/gomod","layer":"L0","scope":"s"},"npm":{"mode":"skipped","reason":"not-installed"}},"proxy":{"gomod":"injected"}}}"#
                    .utf8)
        default:
            lock.withLock { seen.append(request) }
            status = 404
            reply = Data(#"{"message":"No such container"}"#.utf8)
        }
        let response =
            Data(
                "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(reply.count)\r\nConnection: close\r\n\r\n"
                    .utf8) + reply
        _ = response.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
    }
}

/// The additive fields the MCP server reads: which engine keeps an image,
/// a log tail that ends, and every rate's peak in the metrics history.
final class ControlPlaneFieldTests: XCTestCase {
    func testListedImagesNameTheEngineThatKeepsThem() {
        let images = APIHandlers.stampedImages([
            ("apple", .with { $0.id = "a" }), ("hvf", .with { $0.id = "b" }), ("docker", .with { $0.id = "c" }),
        ])
        XCTAssertEqual(images.map(\.runtime), ["", "hvf", "docker"])
    }

    func testANoFollowTailEndsAfterItsLines() async throws {
        let logs = FollowingLogs(lines: ["one", "two", "three"])
        var seen: [String] = []
        for try await line in APIHandlers.lines(logs, id: "web", tail: 2, boot: false) { seen.append(line.text) }
        XCTAssertEqual(seen, ["two", "three"], "the tail, then the end, not a follow")
        XCTAssertEqual(logs.asked, [2])
    }

    func testMetricsHistoryCarriesEveryRatesPeak() async throws {
        let dir = URL(fileURLWithPath: "/tmp/mp-mh-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("metrics.sqlite")
        let store = try MetricsStore(url: url)
        let now = Date()
        store.record(
            [
                (
                    .container, "web",
                    MetricsStore.Sample(networkRxRate: 10, networkTxRate: 20, blockReadRate: 30, blockWriteRate: 40)
                )
            ],
            at: now.addingTimeInterval(-2))
        store.record(
            [
                (
                    .container, "web",
                    MetricsStore.Sample(networkRxRate: 110, networkTxRate: 120, blockReadRate: 130, blockWriteRate: 140)
                )
            ],
            at: now.addingTimeInterval(-1))
        let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/usr/bin/false"))
        let services = await RuntimeBackendResolver.resolveApple(
            client: client, environment: ["MICROPOD_RUNTIME": "cli"])
        let api = APIHandlers(
            client: client, system: SystemService(client: client), images: ImageService(client: client),
            networks: NetworkService(client: client), compose: ComposeService(client: client),
            runtime: RuntimeHolder(initial: services, resolve: { services }, managedSelectionPresent: { false }),
            metricsDatabase: url)
        let response = await api.connectRPC(
            method: "GetMetricsHistory",
            body: try Micropod_V1_GetMetricsHistoryRequest.with {
                $0.kind = "container"
                $0.id = "web"
                $0.rangeSeconds = 600
            }.serializedData(), headers: ["content-type": "application/proto"])
        guard case .data(200, _, let body)? = response else { return XCTFail("\(String(describing: response))") }
        let history = try Micropod_V1_MetricsHistory(serializedBytes: body)
        let peaks = history.points.map {
            [
                $0.networkRxBytesPerSecondMax, $0.networkTxBytesPerSecondMax, $0.blockReadBytesPerSecondMax,
                $0.blockWriteBytesPerSecondMax,
            ]
        }
        XCTAssertFalse(peaks.isEmpty)
        XCTAssertEqual(peaks.map { $0.max() ?? 0 }.max(), 140)
        XCTAssertEqual(peaks.reduce([0, 0, 0, 0]) { acc, p in zip(acc, p).map { max($0, $1) } }, [110, 120, 130, 140])
    }
}

/// A log source whose stream never ends; `tail` answers and records `lines`.
private final class FollowingLogs: LogStreaming, @unchecked Sendable {
    let all: [String]
    private let lock = NSLock()
    private var calls: [Int] = []

    init(lines: [String]) { all = lines }

    var asked: [Int] { lock.withLock { calls } }

    func stream(id: String, tail: Int?, boot: Bool) -> AsyncThrowingStream<LogLine, Error> {
        AsyncThrowingStream { _ in }
    }

    func tail(id: String, lines: Int, boot: Bool) async throws -> [LogLine] {
        lock.withLock { calls.append(lines) }
        return all.suffix(lines).map { LogLine(text: $0) }
    }
}
