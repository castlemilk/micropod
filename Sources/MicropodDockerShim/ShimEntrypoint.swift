import Foundation
import MicropodCore

extension ProcessInfo {
    /// uname -r style kernel string for Docker /version + /info payloads.
    var kernelVersion: String {
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else { return "unknown" }
        return withUnsafeBytes(of: &systemInfo.release) { buffer -> String in
            let pointer = buffer.baseAddress!.assumingMemoryBound(to: CChar.self)
            return String(cString: pointer)
        }
    }
}

struct ShimBootstrap {
    static func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 8192)
        let environment = ProcessInfo.processInfo.environment
        let cliPath = environment["MICROPOD_CLI_PATH"] ?? "/usr/local/bin/container"
        let socketPath =
            environment["MICROPOD_SHIM_SOCKET"]
            ?? NSString("~/.micropod/docker.sock").expandingTildeInPath
        let tcpPort = UInt16(environment["MICROPOD_SHIM_TCP_PORT"] ?? "") ?? 45455
        let bridgeHost = environment["MICROPOD_SHIM_BRIDGE"] ?? "192.168.64.1"
        let statePath =
            environment["MICROPOD_SHIM_STATE"]
            ?? NSString("~/.micropod/shim-state.json").expandingTildeInPath

        try FileManager.default.createDirectory(
            atPath: (socketPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

        let config = ShimConfig(bridgeHost: bridgeHost, tcpPort: tcpPort)
        let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: cliPath))
        let containerService = ContainerService(client: client)
        let state = ShimState.loadPersisted(from: URL(fileURLWithPath: statePath))
        let events = EventsHub(containers: containerService)
        let router = Router(config: config, state: state, events: events, client: client)

        // Prune state for containers that vanished while the shim was down,
        // and reap AutoRemove containers whose die event we missed.
        if let current = try? await containerService.list() {
            let ids = Set(current.map { $0.id })
            await state.retainOnly(ids: ids)
            for id in await state.autoRemoveContainerIDs {
                if let entry = current.first(where: { $0.id == id }),
                    DockerMapper.stateName(entry.state) != "running"
                {
                    try? await containerService.delete(id, force: true)
                    await state.forget(id: id)
                }
            }
        }

        let server = ShimHTTPServer(handler: { request, connection in
            await router.route(request, connection)
        })
        try server.listenUnix(path: socketPath)
        try server.listenTCP(host: nil, port: tcpPort)

        print("[shim] micropod docker shim listening")
        print("[shim]   unix socket : \(socketPath)")
        print("[shim]   tcp         : 127.0.0.1:\(tcpPort)")
        if bridgeHost != "127.0.0.1" {
            print("[shim]   bridge      : \(bridgeHost):\(tcpPort) (in-VM ryuk reachability)")
        }
        print("[shim] ryuk interception active for images containing \(RyukSupport.ryukImageMarker)")
        print("[shim] state       : \(statePath)")

        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let shutdown: @Sendable () -> Void = {
            // Kill live exec children so shutdown doesn't orphan CLI
            // processes, then exit.
            ExecRegistry.shared.terminateAll()
            exit(0)
        }
        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource.setEventHandler { shutdown() }
        termSource.resume()
        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intSource.setEventHandler { shutdown() }
        intSource.resume()

        async let eventLoop: () = events.start(state: state)
        try await server.awaitForever()
        _ = await eventLoop
    }
}

@main
enum ShimEntrypoint {
    static func main() async {
        do {
            try await ShimBootstrap.run()
        } catch {
            fputs("[shim] fatal: \(error)\n", stderr)
            exit(1)
        }
    }
}
