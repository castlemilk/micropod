import Foundation
import XCTest

@testable import MicropodCore
@testable import MicropodDockerShim

/// Boots the shim Router in-process against the shared mock CLI and exposes a
/// random TCP port for RawHTTPClient-driven tests.
enum ShimTestSupport {
    static var mockScriptURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Support
            .deletingLastPathComponent()  // MicropodDockerShimTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("MicropodIntegrationTests/Support/mock-container")
    }

    struct MockShim {
        let client: ContainerCLIClient
        let stateDir: URL
        let port: UInt16
        let buildCache: BuildContextCache

        func raw() -> RawHTTPClient { RawHTTPClient(port: port) }
    }

    static func makeMockShim(file: StaticString = #filePath, line: UInt = #line) throws -> MockShim {
        try makeMockShim(extraEnv: [:], file: file, line: line)
    }

    static func makeMockShim(
        extraEnv: [String: String], file: StaticString = #filePath, line: UInt = #line
    ) throws -> MockShim {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("micropod-shim-mock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let script = mockScriptURL
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            throw XCTSkip(
                "mock container CLI missing or not executable at \(script.path)", file: file, line: line)
        }

        let wrapper = dir.appendingPathComponent("mock-container")
        var wrapperScript =
            "#!/bin/bash\n"
            + "export MICROPOD_MOCK_STATE_DIR=\"\(dir.path)\"\n"
        for (key, value) in extraEnv.sorted(by: { $0.key < $1.key }) {
            wrapperScript += "export \(key)=\"\(value)\"\n"
        }
        wrapperScript += "exec \"\(script.path)\" \"$@\"\n"
        let contents = wrapperScript
        try Data(contents.utf8).write(to: wrapper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        let client = ContainerCLIClient(executableURL: wrapper)
        let containerService = ContainerService(client: client)
        let state = ShimState()
        let readCache = ReadThroughCache()
        let events = EventsHub(containers: containerService, interval: 0.1, readCache: readCache)
        let config = ShimConfig(
            bridgeHost: "192.168.64.1", tcpPort: 45455, defaultVolumeSize: "64g")
        // Isolated on-disk build-context cache (never the real home dir).
        let buildCache = BuildContextCache(
            root: dir.appendingPathComponent("build-cache", isDirectory: true),
            maxBytes: 1 << 30)
        let router = Router(
            config: config, state: state, events: events, client: client,
            sharedFS: nil, buildCache: buildCache, readCache: readCache)
        let server = ShimHTTPServer(handler: { request, connection in
            await router.route(request, connection)
        })
        try server.listenTCP(host: "127.0.0.1", port: 0)
        for _ in 0..<50 {
            if let port = server.boundPort, port > 0 {
                Task { await server.awaitForever() }
                Task { await events.start(state: state) }
                return MockShim(client: client, stateDir: dir, port: port, buildCache: buildCache)
            }
            usleep(20_000)
        }
        throw XCTInternalError("listener never reported a bound port", file: file, line: line)
    }

    static func jsonBody(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }
}

struct XCTInternalError: Error {
    let message: String
    init(_ message: String, file: StaticString, line: UInt) {
        self.message = message
    }
}
