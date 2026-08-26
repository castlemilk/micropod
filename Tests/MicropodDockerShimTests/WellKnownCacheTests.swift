import XCTest

@testable import MicropodCore
@testable import MicropodDockerShim
@testable import MicropodSharedFS

// Chunk 3 Step 1: failing tests for well-known auto-detect.
// These encode the spec at Handlers.swift:70-85 + design §4.3:
//   well-known = /go/pkg/mod, /root/.cache/go-build, /root/.npm, ~/.cache/pip
//   ~ expands via container Env HOME or Config.User, fallback /root.
final class WellKnownCacheTests: XCTestCase {
    // MARK: Well-known base cases (one-arg uses fallback /root)
    func testWellKnownNpmAutoShared() {
        XCTAssertTrue(Router.isWellKnown("/root/.npm"))
    }

    func testWellKnownGoMod() {
        XCTAssertTrue(Router.isWellKnown("/go/pkg/mod"))
    }

    func testWellKnownGoBuild() {
        XCTAssertTrue(Router.isWellKnown("/root/.cache/go-build"))
    }

    func testWellKnownPipDefaultRoot() {
        // ~/.cache/pip with fallback HOME=/root
        XCTAssertTrue(Router.isWellKnown("~/.cache/pip"))
        XCTAssertTrue(Router.isWellKnown("/root/.cache/pip"))
    }

    func testWellKnownNegative() {
        XCTAssertFalse(Router.isWellKnown("/data"))
        XCTAssertFalse(Router.isWellKnown("/root/.npm-extra"))
        XCTAssertFalse(Router.isWellKnown("/go/pkg/mod/sub"))
    }

    // MARK: Container-aware HOME expansion
    func testWellKnownPipWithUserAlice() {
        var req = DockerCreateRequest(Image: "python:3.11")
        req.User = "alice"
        XCTAssertTrue(Router.isWellKnown("~/.cache/pip", request: req))
        XCTAssertTrue(Router.isWellKnown("/home/alice/.cache/pip", request: req))
        XCTAssertFalse(Router.isWellKnown("/root/.cache/pip", request: req))
        // npm with alice still at /root/.npm (not home-dependent) should still be well-known
        XCTAssertTrue(Router.isWellKnown("/root/.npm", request: req))
    }

    func testWellKnownPipWithHomeEnvOverridesUser() {
        var req = DockerCreateRequest(Image: "python:3.11")
        req.User = "alice"
        req.Env = ["HOME=/custom/home"]
        XCTAssertTrue(Router.isWellKnown("~/.cache/pip", request: req))
        XCTAssertTrue(Router.isWellKnown("/custom/home/.cache/pip", request: req))
        XCTAssertFalse(Router.isWellKnown("/home/alice/.cache/pip", request: req))
        XCTAssertFalse(Router.isWellKnown("/root/.cache/pip", request: req))
    }

    func testHomeEnvTakesPrecedenceOverUser() {
        var req = DockerCreateRequest(Image: "python:3.11")
        req.Env = ["PATH=/usr/bin", "HOME=/env/home"]
        XCTAssertTrue(Router.isWellKnown("/env/home/.cache/pip", request: req))
    }

    func testWellKnownWithTrailingSlash() {
        XCTAssertTrue(Router.isWellKnown("/root/.npm/"))
        XCTAssertTrue(Router.isWellKnown("/go/pkg/mod/"))
    }

    // MARK: shared flag & sharedMounts overlay
    func testSharedFalsePreventsEvenWellKnown() {
        var req = DockerCreateRequest(Image: "node:22")
        req.Labels = ["micropod.cache.shared": "false"]
        XCTAssertFalse(Router.shouldUseSharedView("/root/.npm", request: req))
        XCTAssertFalse(Router.shouldUseSharedView("/go/pkg/mod", request: req))
    }

    func testSharedTrueForcesSharingForAnyPath() {
        var req = DockerCreateRequest(Image: "node:22")
        req.Labels = ["micropod.cache.shared": "true"]
        XCTAssertTrue(Router.shouldUseSharedView("/my/custom", request: req))
        XCTAssertTrue(Router.shouldUseSharedView("/data", request: req))
        // even with shared:true, well-known still shared
        XCTAssertTrue(Router.shouldUseSharedView("/root/.npm", request: req))
    }

    func testSharedMountsCustomPath() {
        var req = DockerCreateRequest(Image: "alpine")
        req.Labels = ["micropod.cache.sharedMounts": "[\"/my/cache\"]"]
        XCTAssertTrue(Router.shouldUseSharedView("/my/cache", request: req))
        XCTAssertFalse(Router.shouldUseSharedView("/other", request: req))
        XCTAssertFalse(Router.shouldUseSharedView("/my/cache/sub", request: req))
    }

    func testSharedMountsMultipleValues() {
        var req = DockerCreateRequest(Image: "alpine")
        req.Labels = ["micropod.cache.sharedMounts": "[\"/my/cache\",\"/data\"]"]
        XCTAssertTrue(Router.shouldUseSharedView("/my/cache", request: req))
        XCTAssertTrue(Router.shouldUseSharedView("/data", request: req))
    }

    func testShouldUseSharedViewDefaultsToWellKnownOnly() {
        let req = DockerCreateRequest(Image: "node:22")
        XCTAssertTrue(Router.shouldUseSharedView("/root/.npm", request: req))
        XCTAssertFalse(Router.shouldUseSharedView("/my/cache", request: req))
        XCTAssertFalse(Router.shouldUseSharedView("/data", request: req))
    }

    func testSharedFalseOverridesSharedMounts() {
        var req = DockerCreateRequest(Image: "alpine")
        req.Labels = [
            "micropod.cache.shared": "false",
            "micropod.cache.sharedMounts": "[\"/my/cache\"]",
        ]
        XCTAssertFalse(Router.shouldUseSharedView("/my/cache", request: req))
        XCTAssertFalse(Router.shouldUseSharedView("/root/.npm", request: req))
    }

    func testAlternativeLabelKeys() {
        var req = DockerCreateRequest(Image: "node:22")
        req.Labels = ["shared": "false"]
        XCTAssertFalse(Router.shouldUseSharedView("/root/.npm", request: req))
        req.Labels = ["sharedMounts": "/my/cache"]
        XCTAssertTrue(Router.shouldUseSharedView("/my/cache", request: req))
        req.Labels = ["cache.shared": "true"]
        XCTAssertTrue(Router.shouldUseSharedView("/any/path", request: req))
    }

    func testSharedMountsCommaSeparatedAndSingleValue() {
        var req = DockerCreateRequest(Image: "alpine")
        req.Labels = ["micropod.cache.sharedMounts": "/my/cache,/data"]
        XCTAssertTrue(Router.shouldUseSharedView("/my/cache", request: req))
        XCTAssertTrue(Router.shouldUseSharedView("/data", request: req))
        req.Labels = ["micropod.cache.sharedMounts": "/single"]
        XCTAssertTrue(Router.shouldUseSharedView("/single", request: req))
    }

    func testWellKnownWithUserColonGroup() {
        var req = DockerCreateRequest(Image: "python:3.11")
        req.User = "alice:staff"
        XCTAssertTrue(Router.isWellKnown("/home/alice/.cache/pip", request: req))
        req.User = "1000:1000"
        XCTAssertTrue(Router.isWellKnown("/home/1000/.cache/pip", request: req))
    }

    func testWellKnownRootUser() {
        var req = DockerCreateRequest(Image: "python:3.11")
        req.User = "root"
        XCTAssertTrue(Router.isWellKnown("/root/.cache/pip", request: req))
        XCTAssertTrue(Router.isWellKnown("~/.cache/pip", request: req))
        XCTAssertFalse(Router.isWellKnown("/home/root/.cache/pip", request: req))
    }
}

// MARK: - Shim HTTP integration (binds are only rewritten when well-known / sharedMounts / shared:true)

private actor MockSharedFS: SharedFSClient {
    var mounted: [(src: String, readonly: Bool)] = []
    private var nextID = 0
    func mount(src: URL, readonly: Bool) async throws -> MountInfo {
        mounted.append((src.path, readonly))
        nextID += 1
        let viewPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("mock-view-\(nextID)").path
        try? FileManager.default.createDirectory(
            atPath: viewPath, withIntermediateDirectories: true)
        return MountInfo(
            id: ViewID("mock-\(nextID)"), src: src.path, viewPath: viewPath,
            sizeBytes: 0, readonly: readonly, createdAt: Date())
    }

    func mountShared(src: URL, readonly: Bool) async throws -> MountInfo {
        try await mount(src: src, readonly: readonly)
    }

    func unmount(id: ViewID) async throws {}
    func inspect(id: ViewID) async throws -> MountInfo {
        throw SharedFSError.daemonUnavailable
    }

    func sync(id: ViewID) async throws -> SyncResult { SyncResult(id: id, synced: [], bytesWritten: 0) }
    func refresh(id: ViewID) async throws -> MountInfo { throw SharedFSError.daemonUnavailable }
    func list() async throws -> [MountInfo] { [] }
    func gc() async throws -> GCResult { GCResult(chunksRemoved: 0, bytesReclaimed: 0) }
}

final class ShimWellKnownIntegrationTests: XCTestCase {
    private func makeHostDir(named: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("micropod-wellknown-\(named)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRouter(mockFS: MockSharedFS) throws -> Router {
        let script = ShimTestSupport.mockScriptURL
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            throw XCTSkip("mock container CLI missing at \(script.path)")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("micropod-shim-int-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wrapper = dir.appendingPathComponent("mock-container")
        let contents = "#!/bin/bash\nexport MICROPOD_MOCK_STATE_DIR=\"\(dir.path)\"\nexec \"\(script.path)\" \"$@\"\n"
        try Data(contents.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let client = ContainerCLIClient(executableURL: wrapper)
        let state = ShimState()
        let events = EventsHub(containers: ContainerService(client: client), interval: 0.1)
        let config = ShimConfig(bridgeHost: "192.168.64.1", tcpPort: 45455)
        return Router(config: config, state: state, events: events, client: client, sharedFS: mockFS)
    }

    private func createViaRouter(
        _ router: Router, hostDir: URL, containerPath: String,
        labels: [String: String]? = nil, env: [String]? = nil, user: String? = nil,
        name: String
    ) async throws -> DockerContainerInspect {
        var body: [String: Any] = ["Image": "alpine:3.20"]
        if let labels { body["Labels"] = labels }
        if let env { body["Env"] = env }
        if let user { body["User"] = user }
        body["HostConfig"] = ["Binds": ["\(hostDir.path):\(containerPath)"]] as [String: Any]
        let json = try JSONSerialization.data(withJSONObject: body)
        let req = ShimRequest(
            method: "POST", path: "/containers/create", query: ["name": name], headers: [:], body: json)
        let conn = ShimConnection(fileDescriptor: -1)
        let resp = await router.route(req, conn)
        var status: Int
        var respBody: Data
        switch resp {
        case .status(let code): status = code; respBody = Data()
        case .json(let code, let data): status = code; respBody = data
        case .raw(let code, _, let data): status = code; respBody = data
        case .stream(let code, _, _): status = code; respBody = Data()
        case .hijacked: status = 101; respBody = Data()
        }
        XCTAssertEqual(status, 201, "create failed: \(status) \(String(decoding: respBody, as: UTF8.self))")
        // Inspect via router to see rewritten binds.
        let inspectReq = ShimRequest(
            method: "GET", path: "/containers/\(name)/json", query: [:], headers: [:], body: Data())
        let inspectResp = await router.route(inspectReq, conn)
        var inspectStatus: Int
        var inspectBody: Data
        switch inspectResp {
        case .status(let code): inspectStatus = code; inspectBody = Data()
        case .json(let code, let data): inspectStatus = code; inspectBody = data
        case .raw(let code, _, let data): inspectStatus = code; inspectBody = data
        case .stream(let code, _, _): inspectStatus = code; inspectBody = Data()
        case .hijacked: inspectStatus = 101; inspectBody = Data()
        }
        XCTAssertEqual(inspectStatus, 200)
        let object = try JSONSerialization.jsonObject(with: inspectBody) as! [String: Any]
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(DockerContainerInspect.self, from: data)
        return decoded
    }

    func testShimRewritesWellKnownNpm() async throws {
        let mock = MockSharedFS()
        let router = try makeRouter(mockFS: mock)
        let host = try makeHostDir(named: "npm")
        defer { try? FileManager.default.removeItem(at: host) }
        let inspect = try await createViaRouter(router, hostDir: host, containerPath: "/root/.npm", name: "wellknown-npm-\(UUID().uuidString.prefix(6))")
        let binds = inspect.HostConfig.Binds ?? []
        XCTAssertEqual(binds.count, 1)
        // Host path should be rewritten to mock view (not original host path)
        XCTAssertFalse(binds[0].hasPrefix(host.path), "well-known must be rewritten via sharedFS, got \(binds[0])")
        XCTAssertTrue(binds[0].contains("/root/.npm"), "container path preserved: \(binds[0])")
        let mounted = await mock.mounted
        XCTAssertEqual(mounted.count, 1, "should have mounted once")
    }

    func testShimDoesNotRewriteNonWellKnown() async throws {
        let mock = MockSharedFS()
        let router = try makeRouter(mockFS: mock)
        let host = try makeHostDir(named: "data")
        defer { try? FileManager.default.removeItem(at: host) }
        let inspect = try await createViaRouter(router, hostDir: host, containerPath: "/data", name: "plain-\(UUID().uuidString.prefix(6))")
        let binds = inspect.HostConfig.Binds ?? []
        XCTAssertEqual(binds.count, 1)
        XCTAssertTrue(binds[0].hasPrefix(host.path), "non-well-known must stay as plain bind: \(binds[0])")
        let mounted = await mock.mounted
        XCTAssertEqual(mounted.count, 0)
    }

    func testShimSharedFalseIsolation() async throws {
        let mock = MockSharedFS()
        let router = try makeRouter(mockFS: mock)
        let host = try makeHostDir(named: "npm2")
        defer { try? FileManager.default.removeItem(at: host) }
        let labels = ["micropod.cache.shared": "false"]
        let inspect = try await createViaRouter(
            router, hostDir: host, containerPath: "/root/.npm", labels: labels,
            name: "isolated-\(UUID().uuidString.prefix(6))")
        let binds = inspect.HostConfig.Binds ?? []
        XCTAssertTrue(binds[0].hasPrefix(host.path), "shared:false must not rewrite: \(binds[0])")
        let mounted = await mock.mounted
        XCTAssertEqual(mounted.count, 0)
    }

    func testShimSharedMountsCustom() async throws {
        let mock = MockSharedFS()
        let router = try makeRouter(mockFS: mock)
        let host = try makeHostDir(named: "custom")
        defer { try? FileManager.default.removeItem(at: host) }
        let labels = ["micropod.cache.sharedMounts": "[\"/my/cache\"]"]
        let inspect = try await createViaRouter(
            router, hostDir: host, containerPath: "/my/cache", labels: labels,
            name: "custom-\(UUID().uuidString.prefix(6))")
        let binds = inspect.HostConfig.Binds ?? []
        XCTAssertFalse(binds[0].hasPrefix(host.path), "custom sharedMounts must be rewritten: \(binds[0])")
        let mounted = await mock.mounted
        XCTAssertEqual(mounted.count, 1)
    }

    func testShimSharedTrueForcesNonWellKnown() async throws {
        let mock = MockSharedFS()
        let router = try makeRouter(mockFS: mock)
        let host = try makeHostDir(named: "any")
        defer { try? FileManager.default.removeItem(at: host) }
        let labels = ["micropod.cache.shared": "true"]
        let inspect = try await createViaRouter(
            router, hostDir: host, containerPath: "/my/data", labels: labels,
            name: "forced-\(UUID().uuidString.prefix(6))")
        let binds = inspect.HostConfig.Binds ?? []
        XCTAssertFalse(binds[0].hasPrefix(host.path))
        let mounted = await mock.mounted
        XCTAssertEqual(mounted.count, 1)
    }

    func testShimPipWithHomeEnv() async throws {
        let mock = MockSharedFS()
        let router = try makeRouter(mockFS: mock)
        let host = try makeHostDir(named: "pip")
        defer { try? FileManager.default.removeItem(at: host) }
        let env = ["HOME=/home/alice"]
        // Pip at /home/alice/.cache/pip should be well-known when HOME is /home/alice
        let inspect = try await createViaRouter(
            router, hostDir: host, containerPath: "/home/alice/.cache/pip", env: env,
            name: "pip-\(UUID().uuidString.prefix(6))")
        let binds = inspect.HostConfig.Binds ?? []
        XCTAssertFalse(binds[0].hasPrefix(host.path), "pip with matching HOME must be rewritten: \(binds[0])")
        let mounted = await mock.mounted
        XCTAssertEqual(mounted.count, 1)
    }
}
