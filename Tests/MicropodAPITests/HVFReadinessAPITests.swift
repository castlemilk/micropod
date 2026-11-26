import Darwin
import Foundation
import MicropodCore
import SwiftProtobuf
import XCTest

@testable import MicropodAPI
@testable import MicropodRuntime

/// Ping, GetSystem and WaitContainer against an hvf machine whose guest
/// Docker API is a fake on the machine socket: readiness comes from live
/// state, and a wait costs one guest request per poll.
final class HVFReadinessAPITests: XCTestCase {
    private var root: URL!
    private var held: [HVFFileLock] = []
    private var guest: FakeGuestDockerAPI?

    override func setUp() {
        // Short on purpose: run/docker.sock must fit sockaddr_un.
        root = URL(fileURLWithPath: "/tmp/mphvf-a-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() {
        guest?.stop()
        for lock in held { lock.release() }
        try? FileManager.default.removeItem(at: root)
    }

    private var layout: HVFMachineLayout { HVFMachineLayout(root: root) }

    private func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: layout.tools.appendingPathComponent("runner/bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: layout.runDirectory, withIntermediateDirectories: true)
        for url in [
            layout.vmm, layout.kernel, layout.initrd, layout.disk,
            layout.tools.appendingPathComponent("runner/start.sh"),
        ] + HVFMachineLayout.buildkitBundleFiles.map({ layout.tools.appendingPathComponent($0) }) {
            XCTAssertTrue(fm.createFile(atPath: url.path, contents: Data("x".utf8)))
        }
        XCTAssertEqual(chmod(layout.vmm.path, 0o755), 0)
        XCTAssertEqual(chmod(layout.tools.appendingPathComponent("runner/bin/buildkitd").path, 0o755), 0)
        try Data(#"{"cacheApi": 1, "capabilities": ["caches", "buildkit"]}"#.utf8).write(to: layout.toolsManifest)
    }

    /// A supervisor that published `running`, and the fake guest on its socket.
    private func serve(_ route: @escaping FakeGuestDockerAPI.Route) throws -> FakeGuestDockerAPI {
        held.append(try XCTUnwrap(try HVFFileLock.acquire(layout.supervisorLock, wait: .zero)))
        try HVFMachineState(phase: .running, supervisorPID: getpid(), vmmPID: getpid()).save(to: layout.state)
        let guest = try FakeGuestDockerAPI(path: layout.dockerSocket.path, route: route)
        self.guest = guest
        return guest
    }

    private func registry(defaultRuntime: String? = nil) -> EngineRegistry {
        var environment = [
            "MICROPOD_HVF_ROOT": root.path, "DOCKER_HOST": "unix:///nonexistent.sock",
            "MICROPOD_RUNTIMES_CONFIG": root.appendingPathComponent("runtimes.json").path,
            // Placeholder assets: never started on demand here.
            "MICROPOD_HVF_AUTOSTART": "0",
        ]
        environment["MICROPOD_DEFAULT_RUNTIME"] = defaultRuntime
        return EngineRegistry(
            environment: environment,
            sandbox: SandboxEngine(root: FileManager.default.temporaryDirectory.appendingPathComponent("sbx-\(UUID())"))
        )
    }

    private func handlers(_ registry: EngineRegistry) -> APIHandlers {
        let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/usr/bin/false"))
        let services = RuntimeServices(
            kind: .cli, containers: NoAppleContainers(), logs: LogStreamer(client: client),
            stats: StatsSampler(client: client), volumes: VolumeService(client: client), api: nil, health: nil,
            exitCodes: nil
        ).routed(through: registry)
        return APIHandlers(
            client: client, system: SystemService(client: client), images: ImageService(client: client),
            networks: NetworkService(client: client), compose: ComposeService(client: client),
            runtime: RuntimeHolder(initial: services, resolve: { services }, managedSelectionPresent: { false }),
            engineRegistry: registry)
    }

    private func call<M: Message>(_ api: APIHandlers, _ method: String, _ request: some Message, as type: M.Type)
        async throws -> M
    {
        let response = await api.connectRPC(
            method: method, body: try request.serializedData(), headers: ["content-type": "application/proto"])
        guard case .data(200, "application/proto", let bytes) = response else {
            throw MicropodError.message("unexpected \(method) response: \(String(describing: response))")
        }
        return try M(serializedBytes: bytes)
    }

    private func ping(_ api: APIHandlers) async throws -> Micropod_V1_PingResponse {
        try await call(api, "Ping", Micropod_V1_Empty(), as: Micropod_V1_PingResponse.self)
    }

    // MARK: Readiness

    func testPingAndGetSystemAreRunningOnlyWhileTheGuestAnswers() async throws {
        try install()
        let guest = try serve { _ in (404, Data()) }
        let api = handlers(registry(defaultRuntime: "hvf"))

        let live = try await ping(api)
        XCTAssertEqual(live.status, "running")
        XCTAssertEqual(live.runtimeBackend, "hvf")
        for feature in ["hvf", "rootless", "proto-binary", "caches-v2", "buildkit"] {
            XCTAssertTrue(live.features.contains(feature), "\(feature) in \(live.features)")
        }
        XCTAssertEqual(live.components.first { $0.name == "hvf-machine" }?.state, "running")
        let system = try await call(api, "GetSystem", Micropod_V1_Empty(), as: Micropod_V1_SystemSnapshot.self)
        XCTAssertEqual(system.status.status, "running")
        XCTAssertEqual(guest.requests.map(\.path), ["/_ping"], "GetSystem reused the fresh _ping answer")

        // The guest goes away while the supervisor still says running.
        guest.stop()
        let deadline = ContinuousClock.now + .seconds(5)
        while FileManager.default.fileExists(atPath: layout.dockerSocket.path) {
            guard ContinuousClock.now < deadline else { return XCTFail("the fake guest never closed its socket") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let gone = try await ping(api)
        XCTAssertEqual(gone.status, "not-ready")
        XCTAssertEqual(gone.runtimeBackend, "hvf")
        XCTAssertFalse(gone.features.contains("buildkit"), "\(gone.features)")
        XCTAssertFalse(gone.features.contains("caches-v2"), "\(gone.features)")
        let component = try XCTUnwrap(gone.components.first { $0.name == "hvf-machine" })
        XCTAssertEqual(component.state, "stopped")
        XCTAssertTrue(component.detail.hasPrefix("not-ready: "), component.detail)
    }

    func testADefaultHVFMachineThatIsNotInstalledIsNotReported() async throws {
        let api = handlers(registry(defaultRuntime: "hvf"))
        let ping = try await ping(api)
        XCTAssertEqual(ping.status, "not-installed", "never Apple's status under hvf's name")
        XCTAssertEqual(ping.runtimeBackend, "hvf")
        XCTAssertEqual(ping.defaultRuntime, "hvf")
        XCTAssertEqual(ping.components.first { $0.name == "hvf-machine" }?.state, "missing")
    }

    // MARK: WaitContainer

    func testWaitingOnAnHVFContainerMakesOneGuestRequestPerPoll() async throws {
        try install()
        let polls = LockedCounter()
        let guest = try serve { request in
            switch request.path {
            case "/micropod/containers/summary":
                let row = #"{"id": "c0ffee000001", "name": "job", "image": "alpine", "state": "running"}"#
                return (200, Data(#"{"containers": [\#(row)]}"#.utf8))
            case "/containers/job/json":
                // The ownership probe, two polls that see it running, then the exit.
                let exited = polls.increment() > 3
                let state =
                    exited
                    ? #"{"Status": "exited", "Running": false, "ExitCode": 3}"#
                    : #"{"Status": "running", "Running": true, "ExitCode": 0}"#
                return (200, Data(#"{"Id": "c0ffee000001", "Name": "/job", "State": \#(state)}"#.utf8))
            default:
                return (404, Data(#"{"message": "unexpected \#(request.method) \#(request.path)"}"#.utf8))
            }
        }
        let api = handlers(registry())
        let request = Micropod_V1_WaitContainerRequest.with {
            $0.id = "job"
            $0.timeoutSeconds = 10
        }
        let wait = try await call(api, "WaitContainer", request, as: Micropod_V1_WaitContainerResponse.self)
        XCTAssertTrue(wait.exited)
        XCTAssertTrue(wait.known, "the guest's exit code is the real one")
        XCTAssertEqual(wait.exitCode, 3)
        XCTAssertEqual(wait.state, "stopped")

        let paths = guest.requests.map(\.path)
        XCTAssertEqual(
            paths.filter { $0 == "/micropod/containers/summary" }.count, 1,
            "listed once, to refuse unknown ids; polls never list: \(paths)")
        // One ownership probe, one inspect per poll (three polls), one exit-code read.
        XCTAssertEqual(paths.filter { $0 == "/containers/job/json" }.count, 5, "\(paths)")
        XCTAssertEqual(paths.count, 6, "\(paths)")
    }
}

// MARK: - Fakes

/// No Apple containers: every engine-routed call here belongs to hvf.
private struct NoAppleContainers: ContainerServing {
    private func refuse(_ what: String) -> MicropodError { .message("notFound: no apple container (\(what))") }
    func list() async throws -> [Micropod_V1_Container] { [] }
    func inspect(_ id: String) async throws -> Data { throw refuse(id) }
    func create(_ request: ContainerRunRequest) async throws -> String { throw refuse("create") }
    func run(_ request: ContainerRunRequest) async throws -> String { throw refuse("run") }
    func exec(_ request: ContainerExecRequest) async throws -> String { throw refuse("exec") }
    func start(_ id: String) async throws { throw refuse(id) }
    func stop(_ id: String, timeout: Int) async throws { throw refuse(id) }
    func restart(_ id: String) async throws { throw refuse(id) }
    func stopAll() async throws {}
    func kill(_ id: String, signal: String) async throws { throw refuse(id) }
    func delete(_ id: String, force: Bool) async throws { throw refuse(id) }
    func deleteAll(force: Bool) async throws {}
    func prune() async throws -> String { "" }
    func export(_ id: String, to outputPath: String) async throws { throw refuse(id) }
    func copy(from: String, to: String) async throws { throw refuse(from) }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// The new count.
    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

/// The guest's Docker Engine API on a unix socket: one request per
/// connection, `_ping` answered OK, everything else by `route` with the API
/// version prefix stripped. Every request is recorded.
final class FakeGuestDockerAPI: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
    }

    typealias Route = @Sendable (Request) -> (status: Int, body: Data)

    private let path: String
    private let fd: Int32
    private let route: Route
    private let lock = NSLock()
    private var seen: [Request] = []
    private var stopped = false

    init(path: String, route: @escaping Route) throws {
        self.path = path
        self.route = route
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MicropodError.message("socket: \(String(cString: strerror(errno)))") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw MicropodError.message("bind \(path): \(message)")
        }
        Thread.detachNewThread { [self] in serve() }
    }

    var requests: [Request] { lock.withLock { seen } }

    func stop() { lock.withLock { stopped = true } }

    private func serve() {
        defer {
            close(fd)
            unlink(path)
        }
        while !lock.withLock({ stopped }) {
            var poll = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&poll, 1, 20) > 0 else { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            handle(client)
            close(client)
        }
    }

    private func handle(_ client: Int32) {
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        let separator = Data("\r\n\r\n".utf8)
        while data.range(of: separator) == nil {
            let n = read(client, &buffer, buffer.count)
            guard n > 0 else { return }
            data.append(contentsOf: buffer[0..<n])
        }
        let head = String(decoding: data[..<data.range(of: separator)!.lowerBound], as: UTF8.self)
        let line = head.split(separator: "\r\n", maxSplits: 1).first?.split(separator: " ") ?? []
        guard line.count >= 2 else { return }
        var path = URLComponents(string: "http://guest" + line[1])?.path ?? ""
        if path.hasPrefix("/v1.") { path = String(path.drop { $0 != "/" }.dropFirst().drop { $0 != "/" }) }
        let request = Request(method: String(line[0]), path: path)
        lock.withLock { seen.append(request) }
        let (status, body) = path == "/_ping" ? (200, Data("OK".utf8)) : route(request)
        let response =
            Data(
                "HTTP/1.1 \(status) Fake\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n"
                    .utf8)
            + body
        response.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(client, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard n > 0 else { return }
                offset += n
            }
        }
    }
}
