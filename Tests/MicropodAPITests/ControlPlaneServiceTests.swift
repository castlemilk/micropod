import Darwin
import Foundation
import MicropodCore
import SwiftProtobuf
import XCTest

@testable import MicropodAPI
@testable import MicropodRuntime

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

    /// launchd as the machine's autostart sees it; never the real one.
    private let launch = APIRecordingLaunch()
    private var agents: URL { root.appendingPathComponent("LaunchAgents") }

    private func makeHandlers(environment extra: [String: String] = [:]) async -> APIHandlers {
        let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/usr/bin/false"))
        let services = await RuntimeBackendResolver.resolveApple(
            client: client, environment: ["MICROPOD_RUNTIME": "cli"])
        let holder = RuntimeHolder(initial: services, resolve: { services }, managedSelectionPresent: { false })
        let registry = EngineRegistry(
            environment: [
                "MICROPOD_HVF_ROOT": root.path,
                "MICROPOD_RUNTIMES_CONFIG": root.appendingPathComponent("runtimes.json").path,
            ].merging(extra) { $1 })
        let launch = self.launch
        let agents = self.agents
        return APIHandlers(
            client: client, system: SystemService(client: client), images: ImageService(client: client),
            networks: NetworkService(client: client), compose: ComposeService(client: client), runtime: holder,
            engineRegistry: registry,
            machineAutostart: { layout in
                HVFMachineAutostartAgent(
                    layout: layout, environment: ["PATH": "/usr/bin:/bin", "MICROPOD_CLI": "/bin/sh"], launch: launch,
                    launchAgentsDirectory: agents)
            })
    }

    private func installPlaceholders() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: layout.tools.appendingPathComponent("runner"), withIntermediateDirectories: true)
        for url in [
            layout.vmm, layout.kernel, layout.initrd, layout.disk,
            layout.tools.appendingPathComponent("runner/start.sh"),
        ] {
            XCTAssertTrue(fm.createFile(atPath: url.path, contents: Data("x".utf8)))
        }
        XCTAssertEqual(chmod(layout.vmm.path, 0o755), 0)
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

    func testSetCachePolicyChangesTheDockerSocketPolicyOnlyOnTheOwnersSocket() async throws {
        let api = await makeHandlers()
        let before = try Data(contentsOf: layout.config)
        let request = Micropod_V1_SetCachePolicyRequest.with { $0.dockerSocket = "any" }
        for binary in [true, false] {
            let reply = try await rpc(api, "CacheService", "SetCachePolicy", request, binary: binary)
            XCTAssertEqual(reply.status, 403)
            XCTAssertEqual(reply.json["code"] as? String, "permission_denied")
            XCTAssertTrue((reply.json["message"] as? String ?? "").contains("nothing was written"), "\(reply.json)")
        }
        XCTAssertEqual(try Data(contentsOf: layout.config), before, "machine.json is untouched")

        let saved = try await RequestOrigin.$ownerSocket.withValue(true) {
            try decoded(
                Micropod_V1_SetCachePolicyResponse.self,
                try await rpc(api, "CacheService", "SetCachePolicy", request))
        }
        XCTAssertEqual(saved.policy.dockerSocket, "any")
        XCTAssertEqual(try HVFMachineConfig.load(from: layout.config).effectiveCachePolicy.dockerSocket, .any)
        let shown = try decoded(
            Micropod_V1_CachePolicy.self, try await rpc(api, "CacheService", "GetCachePolicy", Micropod_V1_Empty()))
        XCTAssertEqual(shown.dockerSocket, "any")
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

    /// ControlMachine stop and restart interrupt every container on the
    /// shared machine: like an update's apply, they are deferred while any
    /// runs (or the guest cannot say), unless forced.
    func testControlMachineDefersAStopOrRestartWhileContainersRunUnlessForced() async throws {
        let api = await makeHandlers()
        let client = HVFMachineClient(layout: layout, environment: ["MICROPOD_HVF_ROOT": root.path])
        let held = try XCTUnwrap(try HVFFileLock.acquire(layout.supervisorLock, wait: .zero))
        defer { held.release() }
        try HVFMachineState(phase: .running, supervisorPID: getpid(), vmmPID: getpid()).save(to: layout.state)
        let guest = try FakeGuestDockerAPI(path: layout.dockerSocket.path) { request in
            if request.path.contains("/containers/json") { return (200, Data(#"[{"Id": "ci-job-1"}]"#.utf8)) }
            if request.path.contains("/micropod/metrics") {
                return (200, Data(#"{"reaper": {"active_sessions": 0}}"#.utf8))
            }
            return (404, Data())
        }
        defer { guest.stop() }
        for action in ["stop", "restart"] {
            let refused = try await rpc(
                api, "RigService", "ControlMachine", Micropod_V1_ControlMachineRequest.with { $0.action = action })
            XCTAssertEqual(refused.json["code"] as? String, "failed_precondition", "\(action): \(refused.json)")
            let message = refused.json["message"] as? String ?? ""
            XCTAssertTrue(message.contains("1 running container"), message)
            XCTAssertTrue(message.contains("force"), message)
        }
        XCTAssertTrue(HVFFileLock.isHeld(layout.supervisorLock), "nothing was stopped")

        // A guest that cannot say counts as busy; an idle one, or a machine
        // that is not serving, does not.
        let unsure = await APIHandlers.machineBusy(client, drain: StubDrain(workloads: nil))
        XCTAssertTrue(unsure?.contains("could not confirm") == true, unsure ?? "nil")
        let idle = await APIHandlers.machineBusy(client, drain: StubDrain(workloads: HVFWorkloads(containers: 0)))
        XCTAssertNil(idle)
        held.release()
        let down = await APIHandlers.machineBusy(client, drain: StubDrain(workloads: nil))
        XCTAssertNil(down, "nothing runs on a machine that is not serving")
    }

    /// What the menu bar and `micropod status` show of a running machine:
    /// the engine, its containers, the cache disk, disk flush, readiness and
    /// autostart, read from the guest within a second each.
    func testMachineStatusCarriesTheEngineContainersAndCacheDiskWhileRunning() async throws {
        try installPlaceholders()
        let api = await makeHandlers()
        let held = try XCTUnwrap(try HVFFileLock.acquire(layout.supervisorLock, wait: .zero))
        defer { held.release() }
        try HVFMachineState(phase: .running, supervisorPID: getpid(), vmmPID: getpid()).save(to: layout.state)
        let guest = try FakeGuestDockerAPI(path: layout.dockerSocket.path) { request in
            switch request.path {
            case "/version":
                return (200, Data(#"{"Version":"micropod-1.2","ApiVersion":"1.47","MinAPIVersion":"1.44"}"#.utf8))
            case "/containers/json":
                return (
                    200,
                    Data(
                        #"[{"Id":"a","State":"running"},{"Id":"b","State":"exited"},{"Id":"c","State":"running"}]"#.utf8
                    )
                )
            case "/micropod/caches":
                return (
                    200,
                    Data(
                        #"{"cacheDisk":{"state":"mounted","device":"/dev/vdb","mounted":true,"sizeBytes":34359738368,"freeBytes":22977568768}}"#
                            .utf8)
                )
            default: return (404, Data())
            }
        }
        defer { guest.stop() }
        for binary in [true, false] {
            let status = try decoded(
                Micropod_V1_HVFMachineStatus.self,
                try await rpc(api, "RigService", "GetMachineStatus", Micropod_V1_Empty(), binary: binary))
            XCTAssertEqual(status.phase, "running")
            XCTAssertEqual(status.readiness, "running")
            XCTAssertFalse(status.hasFailureReason)
            XCTAssertEqual(status.engineVersion, "micropod-1.2")
            XCTAssertEqual(status.engineApiVersion, "1.47")
            XCTAssertEqual(status.engineMinApiVersion, "1.44")
            XCTAssertEqual(status.containersTotal, 3)
            XCTAssertEqual(status.containersRunning, 2)
            XCTAssertTrue(status.cacheDisk.mounted)
            XCTAssertEqual(status.cacheDisk.freeBytes, 22_977_568_768)
            XCTAssertFalse(status.diskFlush.isEmpty)
            XCTAssertEqual(status.dockerEndpoint, layout.dockerEndpoint)
            XCTAssertFalse(status.autostart.enabled)
            XCTAssertTrue(status.autostart.summary.hasPrefix("off"), status.autostart.summary)
        }
        XCTAssertEqual(launch.calls, [], "no autostart record: launchd is not asked")
        let json = ControlPlaneJSON.machineStatus(
            try decoded(
                Micropod_V1_HVFMachineStatus.self,
                try await rpc(api, "RigService", "GetMachineStatus", Micropod_V1_Empty())))
        XCTAssertEqual(json["containersRunning"] as? Int, 2)
        XCTAssertEqual(json["engineVersion"] as? String, "micropod-1.2")
        XCTAssertEqual((json["autostart"] as? [String: Any])?["enabled"] as? Bool, false)
    }

    /// The guest engine's own report, key for key (GET /micropod/capacity).
    static let guestCapacity =
        #"""
        {"capacity":{"conntrack_max":262144,"cpus":16,"family_containers_max":256,"max_containers":1024,"memory_bytes":50502500352,"open_files_max":4930989,"pid_max":4194304,"relay_connections_max":4096,"start_parallelism_limit":0},"containers":{"total":9,"running":6,"starting":1,"created":1,"exited":1,"requested_milli_cpu":4000,"requested_memory_bytes":8589934592,"without_cpu_limit":3,"families":[{"name":"gha-runner-1","running":4,"total":5,"requested_milli_cpu":2000,"requested_memory_bytes":4294967296},{"name":"","running":3,"total":4,"requested_milli_cpu":2000,"requested_memory_bytes":4294967296}]},"disks":{"cache":{"free_bytes":16891420672,"total_bytes":16908267520},"os":{"free_bytes":21861261312,"total_bytes":33818648576}},"engine":{"creates_in_flight":1,"starts_in_flight":2,"start_p50_ms":180,"start_p95_ms":420,"starts_sampled":256,"setup_slots_in_use":0},"headroom":{"containers":18,"under_pressure":false,"reasons":[],"limited_by":"cpu","unit_cpu":0.57,"unit_memory_bytes":1078975342,"by_cpu":18,"by_memory":37,"by_tasks":52420,"by_containers":1017},"pressure":{"available":true,"cpu":{"some":{"avg10":0,"avg60":0,"avg300":0},"full":{"avg10":0,"avg60":0,"avg300":0}},"io":{"some":{"avg10":0,"avg60":1.05,"avg300":1},"full":{"avg10":0,"avg60":1.04,"avg300":1}},"memory":{"some":{"avg10":1.5,"avg60":0,"avg300":0},"full":{"avg10":0,"avg60":0,"avg300":0}}},"sampled_unix_ms":1795782926188,"usage":{"conntrack_entries":33,"cpu_busy_cpus":4.0,"cpu_busy_fraction":0.25,"load1":3.5,"load15":1.0,"load5":2.0,"memory_available_bytes":42949672960,"memory_used_bytes":7552827392,"open_files":2100,"relay_connections":2,"runnable":5,"swap_used_bytes":0,"tasks":640}}
        """#

    /// One guest request, mapped field for field; the Mac's own figures are
    /// read in this process.
    func testMachineCapacityIsOneGuestRequestMappedFieldForField() async throws {
        try installPlaceholders()
        let api = await makeHandlers()
        let held = try XCTUnwrap(try HVFFileLock.acquire(layout.supervisorLock, wait: .zero))
        defer { held.release() }
        try HVFMachineState(phase: .running, supervisorPID: getpid(), vmmPID: getpid()).save(to: layout.state)
        let guest = try FakeGuestDockerAPI(path: layout.dockerSocket.path) { request in
            request.path == "/micropod/capacity" ? (200, Data(Self.guestCapacity.utf8)) : (404, Data())
        }
        defer { guest.stop() }
        for binary in [true, false] {
            let report = try decoded(
                Micropod_V1_MachineCapacity.self,
                try await rpc(api, "RigService", "GetMachineCapacity", Micropod_V1_Empty(), binary: binary))
            XCTAssertEqual(report.cpus, 16)
            XCTAssertEqual(report.sampledUnixMs, 1_795_782_926_188)
            XCTAssertEqual(report.pidMax, 4_194_304)
            XCTAssertEqual(report.maxContainers, 1024)
            XCTAssertEqual(report.familyContainersMax, 256)
            XCTAssertEqual(report.relayConnectionsMax, 4096)
            XCTAssertEqual(report.usage.cpuBusyCpus, 4.0)
            XCTAssertEqual(report.usage.load1, 3.5)
            XCTAssertEqual(report.usage.tasks, 640)
            XCTAssertEqual(report.usage.memoryAvailableBytes, 42_949_672_960)
            XCTAssertEqual(report.containers.running, 6)
            XCTAssertEqual(report.containers.starting, 1)
            XCTAssertEqual(report.containers.withoutCpuLimit, 3)
            XCTAssertEqual(report.containers.requestedMilliCpu, 4000)
            XCTAssertEqual(report.containers.families.map(\.name), ["gha-runner-1", ""])
            XCTAssertEqual(report.containers.families.first?.running, 4)
            XCTAssertEqual(report.engine.startsInFlight, 2)
            XCTAssertEqual(report.engine.startP95Ms, 420)
            XCTAssertTrue(report.pressure.available)
            XCTAssertEqual(report.pressure.memory.some.avg10, 1.5)
            XCTAssertGreaterThan(report.osDisk.totalBytes, 0)
            XCTAssertTrue(report.hasCacheDisk)
            XCTAssertEqual(report.headroom.byMemory, 37)
            XCTAssertEqual(report.headroom.unitCpu, 0.57)
            XCTAssertGreaterThan(report.host.cpus, 0)
            XCTAssertGreaterThan(report.host.memoryBytes, 0)
            // The Mac's own pressure decides the last word.
            if report.host.memoryPressure == "normal" || report.host.memoryPressure.isEmpty {
                XCTAssertEqual(report.headroom.containers, 18)
                XCTAssertFalse(report.headroom.underPressure)
                XCTAssertEqual(report.headroom.limitedBy, "cpu")
            } else {
                XCTAssertEqual(report.headroom.containers, 0)
                XCTAssertTrue(report.headroom.underPressure)
            }
        }
        XCTAssertEqual(
            guest.requests.map(\.path), ["/micropod/capacity", "/micropod/capacity"], "one guest request per call")
        let twin = await rest(api, .get, "/v1/rig/capacity")
        XCTAssertEqual(twin.status, 200)
        XCTAssertEqual((twin.json["headroom"] as? [String: Any])?["byCpu"] as? Int, 18)
    }

    /// A Mac under memory pressure withdraws the guest's headroom; an older
    /// engine and a stopped machine are unavailable, and nothing is started.
    func testMachineCapacityFollowsTheMacAndNeverStartsAMachine() async throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let guest = try decoder.decode(HVFGuestCapacity.self, from: Data(Self.guestCapacity.utf8))
        func host(_ pressure: String) -> HVFHostPressure {
            HVFHostPressure(
                cpus: 16, memoryBytes: 128 << 30, memoryAvailableBytes: 8 << 30, memoryPressure: pressure, load1: 2)
        }
        let calm = HVFMachineClient.capacityMessage(guest: guest, host: host("normal"))
        XCTAssertEqual(calm.headroom.containers, 18)
        XCTAssertEqual(calm.host.memoryPressure, "normal")
        XCTAssertEqual(calm.host.memoryAvailableBytes, 8 << 30)
        for pressure in ["warning", "critical"] {
            let pressed = HVFMachineClient.capacityMessage(guest: guest, host: host(pressure))
            XCTAssertEqual(pressed.headroom.containers, 0, pressure)
            XCTAssertTrue(pressed.headroom.underPressure, pressure)
            XCTAssertEqual(pressed.headroom.limitedBy, "host-memory", pressure)
            XCTAssertEqual(pressed.headroom.reasons, ["the Mac is under memory pressure (\(pressure))"])
            XCTAssertEqual(pressed.headroom.byCpu, 18, "what each resource alone allows is still reported")
        }
        XCTAssertEqual(HVFMachineClient.capacityMessage(guest: guest, host: host("")).headroom.containers, 18)

        try installPlaceholders()
        let api = await makeHandlers()
        var reply = try await rpc(api, "RigService", "GetMachineCapacity", Micropod_V1_Empty())
        XCTAssertEqual(reply.status, 503)
        XCTAssertEqual(reply.json["code"] as? String, "unavailable")
        XCTAssertFalse(HVFFileLock.isHeld(layout.supervisorLock), "nothing was started")
        let twin = await rest(api, .get, "/v1/rig/capacity")
        XCTAssertEqual(twin.status, 503)

        let held = try XCTUnwrap(try HVFFileLock.acquire(layout.supervisorLock, wait: .zero))
        defer { held.release() }
        try HVFMachineState(phase: .running, supervisorPID: getpid(), vmmPID: getpid()).save(to: layout.state)
        let old = try FakeGuestDockerAPI(path: layout.dockerSocket.path) { _ in
            (404, Data(#"{"message":"page not found"}"#.utf8))
        }
        defer { old.stop() }
        reply = try await rpc(api, "RigService", "GetMachineCapacity", Micropod_V1_Empty())
        XCTAssertEqual(reply.status, 503)
        XCTAssertTrue(
            (reply.json["message"] as? String ?? "").contains("update the machine's payload"), "\(reply.json)")
    }

    /// The app's Start button is an explicit start, as `machine start` is:
    /// the canonical Docker socket follows it (here the link the caller
    /// named in MICROPOD_DOCKER_SOCK).
    func testControlMachineStartLinksTheCanonicalSocket() async throws {
        try installPlaceholders()
        let link = root.appendingPathComponent("canonical/docker.sock")
        let api = await makeHandlers(environment: ["MICROPOD_DOCKER_SOCK": link.path])
        let held = try XCTUnwrap(try HVFFileLock.acquire(layout.supervisorLock, wait: .zero))
        defer { held.release() }
        try HVFMachineState(phase: .running, supervisorPID: getpid(), vmmPID: getpid()).save(to: layout.state)
        let guest = try FakeGuestDockerAPI(path: layout.dockerSocket.path) { _ in (404, Data()) }
        defer { guest.stop() }
        let started = try decoded(
            Micropod_V1_HVFMachineStatus.self,
            try await rpc(
                api, "RigService", "ControlMachine", Micropod_V1_ControlMachineRequest.with { $0.action = "start" }))
        XCTAssertEqual(started.phase, "running")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), layout.dockerSocket.path)
    }

    /// A status read never starts a machine: one that is stopped stays
    /// stopped, and nothing asks a guest that is not there.
    func testMachineStatusDoesNotStartAStoppedMachine() async throws {
        try installPlaceholders()
        let api = await makeHandlers()
        try HVFMachineState(phase: .failed, supervisorPID: 42, lastExitReason: "guest panicked").save(to: layout.state)
        let status = try decoded(
            Micropod_V1_HVFMachineStatus.self,
            try await rpc(api, "RigService", "GetMachineStatus", Micropod_V1_Empty()))
        XCTAssertEqual(status.readiness, "failed")
        XCTAssertEqual(status.failureReason, "guest panicked")
        XCTAssertFalse(status.hasEngineVersion)
        XCTAssertFalse(status.hasContainersTotal)
        XCTAssertEqual(status.cacheDisk.source, "unknown")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(HVFFileLock.isHeld(layout.supervisorLock), "nothing was started")
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.supervisorLog.path), "no supervisor was launched")
    }

    func testSetMachineAutostartLoadsAndUnloadsThroughLaunchd() async throws {
        try installPlaceholders()
        let api = await makeHandlers()
        let label = HVFMachineAutostartAgent.label(for: layout)
        let on = try decoded(
            Micropod_V1_HVFMachineStatus.self,
            try await rpc(
                api, "RigService", "SetMachineAutostart",
                Micropod_V1_SetMachineAutostartRequest.with { $0.enabled = true }))
        XCTAssertTrue(on.autostart.enabled)
        XCTAssertTrue(on.autostart.loaded)
        XCTAssertEqual(on.autostart.label, label)
        XCTAssertEqual(on.autostart.exitTimeoutSeconds, 25)
        XCTAssertTrue(FileManager.default.fileExists(atPath: agents.appendingPathComponent(label + ".plist").path))
        XCTAssertEqual(launch.calls.filter { !$0.hasPrefix("print") }, ["bootstrap \(label).plist"])

        let off = try decoded(
            Micropod_V1_HVFMachineStatus.self,
            try await rpc(
                api, "RigService", "SetMachineAutostart",
                Micropod_V1_SetMachineAutostartRequest.with { $0.enabled = false }))
        XCTAssertFalse(off.autostart.enabled)
        XCTAssertEqual(launch.calls.filter { !$0.hasPrefix("print") }.last, "bootout \(label)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: agents.appendingPathComponent(label + ".plist").path))
    }

    /// Turning autostart on hands a running machine to launchd, which
    /// restarts it: deferred while containers run, unless forced.
    func testSetMachineAutostartIsDeferredWhileContainersRun() async throws {
        try installPlaceholders()
        let api = await makeHandlers()
        let held = try XCTUnwrap(try HVFFileLock.acquire(layout.supervisorLock, wait: .zero))
        defer { held.release() }
        try HVFMachineState(phase: .running, supervisorPID: getpid(), vmmPID: getpid()).save(to: layout.state)
        let guest = try FakeGuestDockerAPI(path: layout.dockerSocket.path) { request in
            if request.path.contains("/containers/json") { return (200, Data(#"[{"Id": "ci-job-1"}]"#.utf8)) }
            if request.path.contains("/micropod/metrics") {
                return (200, Data(#"{"reaper": {"active_sessions": 0}}"#.utf8))
            }
            return (404, Data())
        }
        defer { guest.stop() }
        let refused = try await rpc(
            api, "RigService", "SetMachineAutostart", Micropod_V1_SetMachineAutostartRequest.with { $0.enabled = true })
        XCTAssertEqual(refused.json["code"] as? String, "failed_precondition", "\(refused.json)")
        let message = refused.json["message"] as? String ?? ""
        XCTAssertTrue(message.hasPrefix("deferred: 1 running container(s) on the machine"), message)
        XCTAssertTrue(message.contains("--force"), message)
        XCTAssertEqual(launch.calls.filter { !$0.hasPrefix("print") }, [], "nothing was loaded")
        XCTAssertNil(HVFMachineAutostartAgent.loadRecord(layout: layout))
        XCTAssertTrue(HVFFileLock.isHeld(layout.supervisorLock), "nothing was stopped")
    }

    /// A package for SetupMachine: an ad-hoc signed, entitled copy of a
    /// system binary as the VMM (never run), stand-in boot files, a tool
    /// bundle and an ext4 base disk.
    private func setupPackage() throws -> URL {
        let fm = FileManager.default
        let dist = root.appendingPathComponent("dist")
        try fm.createDirectory(
            at: dist.appendingPathComponent("micropod-oci-tools/runner"), withIntermediateDirectories: true)
        let vmm = dist.appendingPathComponent("micropod-vmm")
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: vmm)
        let plist = root.appendingPathComponent("ent.plist")
        try Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>com.apple.security.hypervisor</key><true/></dict></plist>
            """.utf8
        ).write(to: plist)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--sign", "-", "--force", "--entitlements", plist.path, vmm.path]
        sign.standardOutput = FileHandle.nullDevice
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        guard sign.terminationStatus == 0 else { throw XCTSkip("ad-hoc codesign unavailable") }
        for name in ["vmlinux-hvf", "mp-hvf-init.cpio", "micropod-oci-tools/runner/start.sh"] {
            XCTAssertTrue(fm.createFile(atPath: dist.appendingPathComponent(name).path, contents: Data(name.utf8)))
        }
        var disk = Data(count: 4096)
        disk[1024 + 0x38] = 0x53
        disk[1024 + 0x39] = 0xEF
        try disk.write(to: dist.appendingPathComponent(HVFMachineInstaller.baseDiskName))
        return dist
    }

    /// SetupMachine installs from a local package (the request names no
    /// image, so nothing can be downloaded) and keeps everything on a
    /// second call.
    func testSetupMachineInstallsFromALocalPackageThenKeepsIt() async throws {
        let dist = try setupPackage()
        let api = await makeHandlers()
        let request = Micropod_V1_SetupMachineRequest.with {
            $0.payloadPath = dist.path
            $0.cacheDiskBytes = 256 << 20
            $0.start = false
        }
        let first = try decoded(
            Micropod_V1_SetupMachineResult.self, try await rpc(api, "RigService", "SetupMachine", request))
        XCTAssertTrue(first.ok, "\(first)")
        XCTAssertEqual(
            first.steps.map { "\($0.id)=\($0.state)" },
            ["runtime-files=done", "disk=done", "cache-disk=done", "start=skipped", "default-runtime=kept"])
        XCTAssertTrue(first.machine.installed)
        XCTAssertEqual(first.machine.phase, "stopped", "start: false boots nothing")
        XCTAssertEqual(layout.missingAssets(), [])

        let again = try decoded(
            Micropod_V1_SetupMachineResult.self,
            try await rpc(api, "RigService", "SetupMachine", request, binary: false))
        XCTAssertTrue(again.ok)
        XCTAssertEqual(again.steps.prefix(3).map(\.state), ["kept", "kept", "kept"])
    }

    /// A step that cannot be done is a failed step, with nothing written.
    func testSetupMachineReportsAMissingSourceAsAFailedStep() async throws {
        let api = await makeHandlers()
        let result = try decoded(
            Micropod_V1_SetupMachineResult.self,
            try await rpc(api, "RigService", "SetupMachine", Micropod_V1_SetupMachineRequest.with { $0.start = true }))
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.steps.first?.state, "failed")
        XCTAssertTrue(result.steps.first?.detail.contains("--payload") ?? false, "\(result.steps)")
        XCTAssertEqual(result.steps[1].state, "failed")
        XCTAssertTrue(result.steps[1].detail.hasPrefix("no base disk"), result.steps[1].detail)
        XCTAssertEqual(result.steps[3].state, "pending", "never started")
        XCTAssertFalse(HVFMachineLayout.isRegularFile(layout.disk))
        XCTAssertFalse(HVFFileLock.isHeld(layout.supervisorLock))
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

/// A drain check with a fixed answer (nil: it cannot tell).
/// launchd for the machine's autostart: records calls, loads on bootstrap.
final class APIRecordingLaunch: RigLaunchControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var loaded: Set<String> = []
    private var recorded: [String] = []
    var calls: [String] { lock.withLock { recorded } }

    func isLoaded(_ label: String) async -> Bool {
        lock.withLock {
            recorded.append("print \(label)")
            return loaded.contains(label)
        }
    }
    func loadedProgram(_ label: String) async -> String? { await isLoaded(label) ? "/x" : nil }
    func bootout(_ label: String) async throws {
        lock.withLock {
            recorded.append("bootout \(label)")
            _ = loaded.remove(label)
        }
    }
    func bootstrap(_ plist: URL, label: String) async throws {
        lock.withLock {
            recorded.append("bootstrap \(plist.lastPathComponent)")
            _ = loaded.insert(label)
        }
    }
    func kickstart(_ label: String) async throws { lock.withLock { recorded.append("kickstart \(label)") } }
}

private struct StubDrain: HVFDrainCoordinating {
    var workloads: HVFWorkloads?
    func activeWorkloads() async throws -> HVFWorkloads {
        guard let workloads else { throw MicropodError.message("unavailable: the guest did not answer") }
        return workloads
    }
}
