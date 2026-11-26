import Darwin
import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// The hvf engine's container routing without a VM: the host-side container
/// index that answers `owns` while the machine is stopped, the calls that
/// boot the machine and the ones that report it stopped, and — over a fake
/// guest Docker API on the machine socket — index upkeep, prune and log
/// tails.
final class HVFMachineRoutingTests: XCTestCase {
    private var root: URL!
    private var configURL: URL!
    private var held: [HVFFileLock] = []
    private var server: FakeDockerServer?

    override func setUp() {
        // Short on purpose: run/docker.sock must fit sockaddr_un.
        root = URL(fileURLWithPath: "/tmp/mphvf-r-\(UUID().uuidString.prefix(8))")
        configURL = FileManager.default.temporaryDirectory.appendingPathComponent("runtimes-\(UUID().uuidString).json")
    }

    override func tearDown() {
        server?.stop()
        for lock in held { lock.release() }
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: configURL)
    }

    private var layout: HVFMachineLayout { HVFMachineLayout(root: root) }
    private var engine: HVFEngine { HVFEngine(root: root, environment: [:]) }
    private var index: HVFContainerIndexStore { HVFContainerIndexStore(layout: layout) }

    private func installPlaceholders() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: layout.tools.appendingPathComponent("runner"), withIntermediateDirectories: true)
        try fm.createDirectory(at: layout.runDirectory, withIntermediateDirectories: true)
        for url in [
            layout.vmm, layout.kernel, layout.initrd, layout.disk,
            layout.tools.appendingPathComponent("runner/start.sh"),
        ] {
            XCTAssertTrue(fm.createFile(atPath: url.path, contents: Data("x".utf8)))
        }
        XCTAssertEqual(chmod(layout.vmm.path, 0o755), 0)
    }

    private func hold(_ url: URL) throws {
        held.append(try XCTUnwrap(try HVFFileLock.acquire(url, wait: .zero)))
    }

    /// A machine that serves: the supervisor lock held, `running`
    /// published, and `route` answering on run/docker.sock.
    private func serving(_ route: @escaping FakeDockerServer.Route) throws -> FakeDockerServer {
        try installPlaceholders()
        try hold(layout.supervisorLock)
        try HVFMachineState(phase: .running, supervisorPID: getpid()).save(to: layout.state)
        let server = try FakeDockerServer(path: layout.dockerSocket.path, route: route)
        self.server = server
        XCTAssertTrue(engine.machine.isServing)
        return server
    }

    private func code(_ body: () async throws -> Void) async -> (code: String, message: String)? {
        do {
            try await body()
            return nil
        } catch {
            return (ConnectCodeMapping.code(for: error), error.localizedDescription)
        }
    }

    // MARK: Index

    func testIndexResolvesReferencesLikeTheGuestEngine() {
        var index = HVFContainerIndex()
        index.record(id: "a1b2c3d4e5f6", name: "keep")
        index.record(id: "a1b2ffff0000", name: nil)
        index.record(id: "9999aaaabbbb", name: "web")
        XCTAssertEqual(index.entry(for: "a1b2c3d4e5f6")?.name, "keep", "exact id")
        XCTAssertEqual(index.entry(for: "keep")?.id, "a1b2c3d4e5f6", "exact name")
        XCTAssertEqual(index.entry(for: "9999")?.name, "web", "a unique prefix of four or more")
        XCTAssertNil(index.entry(for: "999"), "a prefix under four characters is not a reference")
        XCTAssertNil(index.entry(for: "a1b2"), "an ambiguous prefix is not owned (the guest answers 409)")
        XCTAssertEqual(index.entry(for: "a1b2c")?.id, "a1b2c3d4e5f6")
        XCTAssertNil(index.entry(for: ""))
        XCTAssertNil(index.entry(for: "kee"), "names match exactly")

        index.record(id: "0000newnewnew", name: "keep")
        XCTAssertEqual(index.entry(for: "keep")?.id, "0000newnewnew", "a reused name replaces the old container")
        XCTAssertNil(index.entry(for: "a1b2c3d4e5f6"))
        index.remove("web")
        XCTAssertNil(index.entry(for: "9999aaaabbbb"))
        index.remove("nothing")
        XCTAssertEqual(index.containers.count, 2)
    }

    func testRefreshReplacesTheIndexButKeepsRecordsNewerThanTheListing() {
        let listedAt = Date(timeIntervalSince1970: 1_000)
        var index = HVFContainerIndex()
        index.record(id: "gone", name: "old", at: listedAt.addingTimeInterval(-5))
        index.record(id: "fresh", name: "racing", at: listedAt.addingTimeInterval(1))
        index.refresh(from: [(id: "listed", name: "kept")], listedAt: listedAt)
        XCTAssertEqual(Set(index.containers.map(\.id)), ["listed", "fresh"])
        XCTAssertNil(index.entry(for: "old"), "a container the listing no longer has is dropped")
        XCTAssertNotNil(index.entry(for: "racing"), "a create the listing predates survives")
    }

    func testIndexStoreToleratesMissingCorruptAndNewerFiles() throws {
        XCTAssertEqual(index.load(), HVFContainerIndex())
        index.update { $0.record(id: "x", name: "y") }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: layout.runDirectory.path),
            "an update never creates a root that has never run")

        try FileManager.default.createDirectory(at: layout.runDirectory, withIntermediateDirectories: true)
        index.update { $0.record(id: "abcdef", name: "keep") }
        XCTAssertEqual(index.load().entry(for: "keep")?.id, "abcdef")
        try Data("{".utf8).write(to: layout.containerIndex)
        XCTAssertEqual(index.load(), HVFContainerIndex(), "unreadable reads as empty")
        try Data(#"{"schema": 9, "containers": [{"id": "z", "recordedAt": "2026-01-01T00:00:00Z"}]}"#.utf8)
            .write(to: layout.containerIndex)
        XCTAssertNil(index.load().entry(for: "z"), "a newer schema is not guessed at")
        index.update { $0.record(id: "abcdef", name: "keep") }
        XCTAssertNotNil(index.load().entry(for: "keep"), "and is replaced by the next update")
        try index.reset()
        XCTAssertEqual(index.load(), HVFContainerIndex())
        XCTAssertNoThrow(try index.reset(), "resetting a missing index is fine")
    }

    // MARK: Routing while the machine is stopped

    func testAStoppedMachineOwnsItsIndexedContainersWithoutBooting() async throws {
        try installPlaceholders()
        index.update { $0.record(id: "c0ffee000001", name: "keep") }
        let engine = self.engine
        let byName = await engine.owns("keep")
        let byPrefix = await engine.owns("c0ffee")
        let unknown = await engine.owns("web")
        XCTAssertTrue(byName)
        XCTAssertTrue(byPrefix)
        XCTAssertFalse(unknown, "anything else still falls through to another engine")

        let calls: [(String, () async throws -> Void)] = [
            ("inspect", { _ = try await engine.inspect("keep") }),
            ("exec", { _ = try await engine.exec(ContainerExecRequest(containerID: "keep", arguments: ["true"])) }),
            ("stop", { try await engine.stop("keep", timeout: 1) }),
            ("kill", { try await engine.kill("keep", signal: "KILL") }),
            ("delete", { try await engine.delete("keep", force: true) }),
            ("tail", { _ = try await engine.tail(id: "keep", lines: 10, boot: false) }),
            ("stream", { for try await _ in engine.stream(id: "keep", tail: 1, boot: false) {} }),
        ]
        for (name, call) in calls {
            let failure = await code(call)
            XCTAssertEqual(failure?.code, "failed_precondition", name)
            XCTAssertTrue(failure?.message.contains("container 'keep' is on the hvf machine") ?? false, name)
            XCTAssertTrue(failure?.message.contains("micropod machine start") ?? false, failure?.message ?? name)
        }
        XCTAssertNotNil(index.load().entry(for: "keep"), "a refused call keeps the entry")
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.state.path), "nothing booted the machine")
        XCTAssertFalse(HVFFileLock.isHeld(layout.supervisorLock))
    }

    func testStartAndRestartOfAnIndexedContainerBootTheMachine() async throws {
        try installPlaceholders()
        index.update { $0.record(id: "c0ffee000001", name: "keep") }
        // An install in progress makes the boot attempt fail recognisably
        // (and at once), proving start/restart went to ensureRunning.
        try hold(layout.installLock)
        for (name, call) in [
            ("start", { try await self.engine.start("keep") }), ("restart", { try await self.engine.restart("keep") }),
        ] as [(String, () async throws -> Void)] {
            let failure = await code(call)
            XCTAssertEqual(failure?.code, "unavailable", name)
            XCTAssertTrue(failure?.message.contains("is being installed") ?? false, failure?.message ?? name)
        }
    }

    func testTheRouterSendsAStoppedMachinesContainersToHVFAndNothingElse() async throws {
        try installPlaceholders()
        index.update { $0.record(id: "c0ffee000001", name: "keep") }
        let registry = EngineRegistry(
            environment: [
                "MICROPOD_RUNTIMES_CONFIG": configURL.path, "DOCKER_HOST": "unix:///nonexistent.sock",
                "MICROPOD_HVF_ROOT": root.path,
            ],
            sandbox: SandboxEngine(root: FileManager.default.temporaryDirectory.appendingPathComponent("sbx-\(UUID())"))
        )
        try registry.update("hvf", enabled: true, endpoint: nil)
        let apple = RecordingContainers(ids: ["web"])
        let router = RuntimeRouter(
            apple: AppleEngine(
                services: RuntimeServices(
                    kind: .cli, containers: apple, logs: NoLogs(), stats: NoStats(),
                    volumes: VolumeService(
                        client: ContainerCLIClient(executableURL: URL(fileURLWithPath: "/usr/bin/true"))),
                    api: nil, health: nil, exitCodes: nil)),
            registry: registry)

        let stop = await code { try await router.stop("keep", timeout: 1) }
        XCTAssertEqual(stop?.code, "failed_precondition")
        XCTAssertTrue(stop?.message.contains("on the hvf machine") ?? false, stop?.message ?? "stopped")
        try hold(layout.installLock)
        let start = await code { try await router.start("keep") }
        XCTAssertTrue(start?.message.contains("is being installed") ?? false, "start boots hvf, not apple")
        try await router.stop("web", timeout: 1)
        let stopped = await apple.stopped
        XCTAssertEqual(stopped, ["web"], "only the unindexed id reached apple")
        let listed = try await router.list()
        XCTAssertEqual(listed.map(\.id), ["web"], "a stopped machine still lists nothing")
    }

    // MARK: Over the guest API

    private static func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    func testListingRefreshesTheIndexAndCreateAndDeleteMaintainIt() async throws {
        let listing = Self.json([
            ["Id": "aaaa1111bbbb2222", "Names": ["/keep"], "State": "exited", "Image": "alpine"],
            ["Id": "cccc3333dddd4444", "Names": [String](), "State": "created", "Image": "alpine"],
        ])
        _ = try serving { request in
            switch (request.method, request.path) {
            case ("GET", "/containers/json"): return (200, listing)
            case ("POST", "/containers/create"): return (201, Self.json(["Id": "eeee5555ffff6666"]))
            case ("POST", "/containers/new/start"): return (204, Data())
            case ("DELETE", "/containers/keep"): return (204, Data())
            case ("DELETE", "/containers/ghost"): return (404, Self.json(["message": "no such container: ghost"]))
            default: return (500, Self.json(["message": "unexpected \(request.method) \(request.path)"]))
            }
        }
        let engine = self.engine
        index.update { $0.record(id: "stale0000000", name: "ghost") }
        let listed = try await engine.list()
        XCTAssertEqual(listed.map(\.id), ["keep", "cccc3333dddd4444"])
        XCTAssertEqual(listed.map(\.runtime), ["hvf", "hvf"])
        var current = index.load()
        XCTAssertEqual(current.entry(for: "keep")?.id, "aaaa1111bbbb2222", "names and full ids from the listing")
        XCTAssertNotNil(current.entry(for: "cccc3333"))
        XCTAssertNil(current.entry(for: "ghost"), "the listing is authoritative")

        let handle = try await engine.run(ContainerRunRequest(image: "alpine", name: "new"))
        XCTAssertEqual(handle, "new")
        XCTAssertEqual(index.load().entry(for: "new")?.id, "eeee5555ffff6666")

        try await engine.delete("keep", force: false)
        current = index.load()
        XCTAssertNil(current.entry(for: "keep"), "a delete drops the entry")
        index.update { $0.record(id: "ghost0000000", name: "ghost") }
        let missing = await code { try await engine.delete("ghost", force: true) }
        XCTAssertEqual(missing?.code, "not_found")
        XCTAssertNil(index.load().entry(for: "ghost"), "a guest 404 drops a stale entry")
    }

    func testPruneRemovesWhatItCanAndReportsTheRest() async throws {
        let server = try serving { request in
            switch (request.method, request.path) {
            case ("GET", "/containers/json"):
                return (
                    200,
                    Self.json([
                        ["Id": "1", "Names": ["/a"], "State": "exited"],
                        ["Id": "2", "Names": ["/b"], "State": "exited"],
                        ["Id": "3", "Names": ["/c"], "State": "created"],
                        ["Id": "4", "Names": ["/d"], "State": "running"],
                        ["Id": "5", "Names": ["/e"], "State": "dead"],
                    ])
                )
            case ("DELETE", "/containers/b"): return (409, Self.json(["message": "container is in use"]))
            case ("DELETE", "/containers/c"): return (404, Self.json(["message": "no such container: c"]))
            case ("DELETE", _): return (204, Data())
            default: return (500, Data())
            }
        }
        let report = try await engine.prune()
        XCTAssertEqual(
            server.requests.filter { $0.method == "DELETE" }.map(\.path),
            ["/containers/a", "/containers/b", "/containers/c", "/containers/e"],
            "one failed delete does not stop the rest; running containers are kept")
        XCTAssertTrue(report.hasPrefix("removed 3 containers"), report)
        XCTAssertTrue(report.contains("could not remove 1: b ("), report)
        XCTAssertTrue(report.contains("in use"), report)
        XCTAssertEqual(HVFEngine.pruneReport(removed: 0, failures: []), "", "nothing to prune reports nothing")
    }

    func testLogTailsTakeAnyLimitWithoutOverflow() async throws {
        let lines = (0..<300).map { "line \($0)" }
        let payload = Data((lines.joined(separator: "\n") + "\n").utf8)
        var frame = Data([1, 0, 0, 0])
        frame.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).bigEndian, Array.init))
        frame.append(payload)
        let framed = frame
        _ = try serving { request in
            request.path == "/containers/x/logs" ? (200, framed) : (404, Data())
        }
        let engine = self.engine
        let all = try await engine.tail(id: "x", lines: Int.max, boot: false)
        XCTAssertEqual(all.map(\.text), lines)
        let last = try await engine.tail(id: "x", lines: 2, boot: false)
        XCTAssertEqual(last.map(\.text), ["line 298", "line 299"])
        let unlimited = try await engine.tail(id: "x", lines: -1, boot: false)
        XCTAssertEqual(unlimited.count, 300)
        var streamed: [String] = []
        for try await line in engine.stream(id: "x", tail: Int.max, boot: false) { streamed.append(line.text) }
        XCTAssertEqual(streamed, lines, "the existing log once; the follow replay is skipped")
    }

    func testLogTailBufferBounds() {
        var huge = LogTailBuffer(limit: Int.max)
        XCTAssertEqual(huge.trimThreshold, Int.max, "saturates instead of trapping")
        huge.append(["a", "b"])
        XCTAssertEqual(huge.lines, ["a", "b"])
        XCTAssertEqual(LogTailBuffer(limit: Int.max / 2).trimThreshold, Int.max)
        var small = LogTailBuffer(limit: 3)
        XCTAssertEqual(small.trimThreshold, 262)
        small.append((0..<1000).map(String.init))
        XCTAssertEqual(small.lines, ["997", "998", "999"])
        var none = LogTailBuffer(limit: 0)
        none.append(["x"])
        XCTAssertEqual(none.lines, [])
        var all = LogTailBuffer(limit: -1)
        all.append((0..<600).map(String.init))
        XCTAssertEqual(all.lines.count, 600)
    }
}

// MARK: - Fake guest Docker API

/// A Docker Engine API stand-in on a unix socket. One request per
/// connection (DockerClient sends `Connection: close`), answered by `route`
/// with the API version prefix stripped from the path.
final class FakeDockerServer: @unchecked Sendable {
    struct Request: Sendable, Equatable {
        var method: String
        var path: String
        var query: [String: String]
        var body: Data
        /// Lower-cased names.
        var headers: [String: String] = [:]
    }

    typealias Route = @Sendable (Request) -> (status: Int, body: Data)

    let path: String
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
            Darwin.close(fd)
            throw MicropodError.message("bind \(path): \(message)")
        }
        Thread.detachNewThread { [self] in serve() }
    }

    var requests: [Request] { lock.withLock { seen } }

    func stop() {
        lock.withLock { stopped = true }
    }

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
            let n = read(client, &buffer, buffer.count)
            guard n > 0 else { return false }
            data.append(contentsOf: buffer[0..<n])
            return true
        }
        let separator = Data("\r\n\r\n".utf8)
        while data.range(of: separator) == nil { guard fill() else { return } }
        guard let end = data.range(of: separator) else { return }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        var body = Data(data[end.upperBound...])
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return }
        let length =
            lines.dropFirst().first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        while body.count < length {
            let before = data.count
            guard fill() else { break }
            body.append(data[(data.startIndex + before)...])
        }
        let components = URLComponents(string: "http://docker" + requestLine[1])
        var path = components?.path ?? ""
        if path.hasPrefix("/v1.") { path = String(path.drop { $0 != "/" }.dropFirst().drop { $0 != "/" }) }
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(
                in: .whitespaces)
        }
        let request = Request(method: String(requestLine[0]), path: path, query: query, body: body, headers: headers)
        lock.withLock { seen.append(request) }
        // The engine pings before a create or start, like `ensureRunning`.
        let (status, reply) = request.path == "/_ping" ? (200, Data("OK".utf8)) : route(request)
        let response =
            Data(
                "HTTP/1.1 \(status) Fake\r\nContent-Type: application/json\r\nContent-Length: \(reply.count)\r\n\r\n"
                    .utf8) + reply
        _ = HVFFiles.writeBestEffort(response, to: client)
    }
}
