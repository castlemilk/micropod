import Darwin
import Foundation
import MicropodCore
import MicropodRuntime
import XCTest

@testable import MicropodAPI

/// `POST /v1/caches/prune`, `PUT /v1/caches/policy` and
/// `GET /v1/caches/explain/{id}` on a throwaway HVF root, with a fake guest
/// engine on the machine's Docker socket. A prune is a dry run unless the
/// body says otherwise, and a body the route cannot read exactly is a 400
/// that never reaches the guest or machine.json.
final class CacheRoutesTests: XCTestCase {
    private var root: URL!
    private var layout: HVFMachineLayout!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/mp-cr-\(UUID().uuidString.prefix(8))")
        layout = HVFMachineLayout(root: root)
        try FileManager.default.createDirectory(at: layout.runDirectory, withIntermediateDirectories: true)
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
            client: client,
            system: SystemService(client: client),
            images: ImageService(client: client),
            networks: NetworkService(client: client),
            compose: ComposeService(client: client),
            runtime: holder,
            engineRegistry: registry)
    }

    private func send(
        _ api: APIHandlers, _ method: HTTPMethod, _ path: String, _ body: String
    ) async -> (status: Int, body: [String: Any]) {
        let response = await api.handle(
            HTTPRequest(
                method: method, path: path, query: [:], body: Data(body.utf8),
                headers: ["content-type": "application/json"]))
        switch response {
        case .json(let status, let object): return (status, object)
        case .data(let status, _, let data):
            return (status, (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
        default: return (-1, [:])
        }
    }

    // MARK: Prune

    func testPruneIsADryRunUnlessTheBodySaysDryRunFalse() async throws {
        let guest = try FakeGuestEngine(path: layout.dockerSocket.path)
        defer { guest.stop() }
        let api = await makeHandlers()
        let bodies = [
            #"{}"#,
            #"{"dryRun": true, "scope": "proj"}"#,
            #"{"dryRun": false, "maxBytes": 1000}"#,
            #"{"dryRun": false, "all": true}"#,
            #"{"dryRun": false, "tool": "go", "olderThanSecs": 3600, "partialGoBuild": false, "maxUnits": 5}"#,
        ]
        for body in bodies {
            let reply = await send(api, .post, "/v1/caches/prune", body)
            XCTAssertEqual(reply.status, 200, "\(body): \(reply.body)")
        }
        let prunes = guest.requests.filter { $0.path == "/micropod/caches/prune" }.map(\.json)
        guard prunes.count == bodies.count else {
            return XCTFail("the guest got \(prunes.count) prunes for \(bodies.count) bodies")
        }
        XCTAssertEqual(prunes.map { $0["dryRun"] as? Bool }, [true, true, false, false, false])
        XCTAssertEqual(prunes[0]["reason"] as? String, "api")
        XCTAssertEqual(prunes[1]["scope"] as? String, "proj")
        XCTAssertEqual((prunes[2]["maxBytes"] as? NSNumber)?.uint64Value, 1000)
        XCTAssertNil(prunes[3]["maxBytes"])
        XCTAssertNil(prunes[3]["all"], "the confirmation stays on the host")
        XCTAssertEqual(prunes[4]["tool"] as? String, "go")
        XCTAssertEqual((prunes[4]["olderThanSecs"] as? NSNumber)?.int64Value, 3600)
        XCTAssertEqual(prunes[4]["partialGoBuild"] as? Bool, false)
        XCTAssertEqual((prunes[4]["maxUnits"] as? NSNumber)?.intValue, 5)
    }

    func testPruneRefusesEmptyMalformedMistypedOrUnconfirmedBodiesBeforeTheGuest() async throws {
        let guest = try FakeGuestEngine(path: layout.dockerSocket.path)
        defer { guest.stop() }
        let api = await makeHandlers()
        let refused: [(String, String)] = [
            ("", "expected a JSON object body"),
            ("dry run please", "not a JSON object"),
            ("[]", "not a JSON object"),
            (#"{"dryRun": false}"#, #"add "all": true to confirm"#),
            (#"{"dryRun": false, "partialGoBuild": true}"#, #"add "all": true to confirm"#),
            (#"{"dryRun": "false"}"#, "dryRun must be a boolean"),
            (#"{"dryRun": 0}"#, "dryRun must be a boolean"),
            (#"{"dryrun": false}"#, "unknown field 'dryrun'"),
            (#"{"maxBytes": "20g"}"#, "maxBytes must be a non-negative integer"),
            (#"{"maxBytes": 1.5}"#, "maxBytes must be a non-negative integer"),
            (#"{"maxBytes": 0, "dryRun": false}"#, "maxBytes must be positive"),
            (#"{"olderThanSecs": -1}"#, "olderThanSecs must be positive"),
            (#"{"scope": "Bad Scope"}"#, "scope 'Bad Scope' must match"),
            (#"{"tool": "nonsense"}"#, "unknown tool 'nonsense'"),
            (#"{"all": "yes"}"#, "all must be a boolean"),
        ]
        for (body, expected) in refused {
            let reply = await send(api, .post, "/v1/caches/prune", body)
            XCTAssertEqual(reply.status, 400, "\(body): \(reply.body)")
            XCTAssertTrue((reply.body["error"] as? String ?? "").contains(expected), "\(body): \(reply.body)")
        }
        XCTAssertEqual(guest.requests.filter { $0.path == "/micropod/caches/prune" }.count, 0)
    }

    // MARK: Policy

    private func writeConfig(_ config: HVFMachineConfig) throws -> Data {
        try config.save(to: layout.config)
        return try Data(contentsOf: layout.config)
    }

    func testPolicyPutRefusesEmptyUnknownOrMistypedBodiesWithoutWriting() async throws {
        let saved = try writeConfig(HVFMachineConfig())
        let api = await makeHandlers()
        let refused: [(String, String)] = [
            ("", "expected a JSON object body"),
            ("{", "not a JSON object"),
            ("{}", "nothing was written"),
            (#"{"sharedL0": null}"#, "nothing was written"),
            (#"{"sharedL0": "true"}"#, "sharedL0 must be a boolean"),
            (#"{"sharedL0": 1}"#, "sharedL0 must be a boolean"),
            (#"{"sharedl0": true}"#, "unknown field 'sharedl0'"),
            (#"{"version": 2}"#, "unknown field 'version'"),
            (#"{"mode": "bogus"}"#, "mode must be auto or off"),
            (#"{"goProxy": "ftp://proxy"}"#, "goProxy 'ftp://proxy' entries (separated by ',' or '|') must be"),
            (#"{"maxBytes": -5}"#, "maxBytes must be a non-negative integer"),
            (#"{"maxAgeDays": "14"}"#, "maxAgeDays must be a non-negative integer"),
            (#"{"tools": ["go", 5]}"#, "tools must be an array of strings"),
            (#"{"defaultScope": "Not A Scope"}"#, "default scope 'Not A Scope' must match"),
        ]
        for (body, expected) in refused {
            let reply = await send(api, .put, "/v1/caches/policy", body)
            XCTAssertEqual(reply.status, 400, "\(body): \(reply.body)")
            XCTAssertTrue((reply.body["error"] as? String ?? "").contains(expected), "\(body): \(reply.body)")
        }
        XCTAssertEqual(try Data(contentsOf: layout.config), saved, "machine.json is untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.cachePolicyFile.path))
    }

    func testPolicyPutWritesTypedFieldsAndClearsWithZeroOrNull() async throws {
        _ = try writeConfig(HVFMachineConfig())
        let api = await makeHandlers()
        var reply = await send(
            api, .put, "/v1/caches/policy",
            #"{"sharedL0": true, "maxBytes": 1073741824, "maxAgeDays": 14, "minFreeBytes": 4096, "goProxy": "http://10.43.0.1:7677/go,direct", "pnpmLegacyEnv": false}"#
        )
        XCTAssertEqual(reply.status, 200, "\(reply.body)")
        var policy = try HVFMachineConfig.load(from: layout.config).effectiveCachePolicy
        XCTAssertTrue(policy.sharedL0)
        XCTAssertEqual(policy.maxBytes, 1 << 30)
        XCTAssertEqual(policy.maxAgeDays, 14)
        XCTAssertEqual(policy.minFreeBytes, 4096)
        XCTAssertEqual(policy.goProxy, "http://10.43.0.1:7677/go,direct")
        XCTAssertFalse(policy.pnpmLegacyEnv)
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.cachePolicyFile.path))

        reply = await send(
            api, .put, "/v1/caches/policy", #"{"maxBytes": 0, "goProxy": null, "maxAgeDays": null, "minFreeBytes": 0}"#)
        XCTAssertEqual(reply.status, 200, "\(reply.body)")
        policy = try HVFMachineConfig.load(from: layout.config).effectiveCachePolicy
        XCTAssertNil(policy.maxBytes)
        XCTAssertNil(policy.goProxy)
        XCTAssertNil(policy.maxAgeDays)
        XCTAssertNil(policy.minFreeBytes)
        XCTAssertTrue(policy.sharedL0, "fields the body does not name keep their values")
    }

    func testPolicyPutNeverReplacesAnUnreadableMachineConfigWithDefaults() async throws {
        let broken = Data(#"{"cpus": "#.utf8)
        try broken.write(to: layout.config)
        let api = await makeHandlers()
        let reply = await send(api, .put, "/v1/caches/policy", #"{"sharedL0": true}"#)
        XCTAssertNotEqual(reply.status, 200, "\(reply.body)")
        XCTAssertTrue(
            (reply.body["error"] as? String ?? "").contains("is not a valid hvf machine config"), "\(reply.body)")
        XCTAssertEqual(try Data(contentsOf: layout.config), broken)
    }

    // MARK: Explain

    func testExplainDecodesTheIdAndRefusesOnesThatAreNotContainerReferences() async throws {
        let guest = try FakeGuestEngine(path: layout.dockerSocket.path)
        defer { guest.stop() }
        let api = await makeHandlers()
        for path in ["/v1/caches/explain/a%20b", "/v1/caches/explain/..%2F..%2Fimages", "/v1/caches/explain/a%3Fb"] {
            let reply = await send(api, .get, path, "")
            XCTAssertEqual(reply.status, 400, "\(path): \(reply.body)")
        }
        XCTAssertEqual(guest.requests.count, 0)
        let reply = await send(api, .get, "/v1/caches/explain/web-1", "")
        XCTAssertEqual(reply.status, 200, "\(reply.body)")
        XCTAssertEqual(reply.body["containerName"] as? String, "web-1")
        XCTAssertEqual(guest.requests.map(\.path), ["/containers/web-1/json"])
    }
}

/// The guest engine's cache routes on a Unix socket: records each request
/// (Docker API version prefix stripped) and answers like the guest would.
private final class FakeGuestEngine: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        var body: Data
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:] }
    }

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
        var target = String(requestLine[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        if target.hasPrefix("/v1.") { target = String(target.drop { $0 != "/" }.dropFirst().drop { $0 != "/" }) }
        let request = Request(method: String(requestLine[0]), path: target, body: Data(data[end.upperBound...]))
        let reply: Data
        switch request.path {
        case "/_ping":
            reply = Data("OK".utf8)
        case "/micropod/caches/prune":
            lock.withLock { seen.append(request) }
            let dryRun = request.json["dryRun"] as? Bool ?? false
            reply = Data(
                #"{"dryRun":\#(dryRun),"reason":"x","freedBytes":0,"freedFiles":0,"evictedUnits":0,"skippedInUse":0,"beforeBytes":0,"afterBytes":0,"actions":[]}"#
                    .utf8)
        default:
            lock.withLock { seen.append(request) }
            reply = Data(#"{"Id":"0123abcd","Name":"/web-1","Image":"alpine","State":{"Status":"running"}}"#.utf8)
        }
        let response =
            Data(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(reply.count)\r\nConnection: close\r\n\r\n"
                    .utf8) + reply
        _ = response.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
    }
}
