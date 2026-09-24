import Foundation
import MicropodCore

/// Typed client for `container-apiserver` over the XPC protocol.
///
/// One instance owns one persistent XPC connection; calls are independent
/// and safe to issue concurrently (each is a separate send/reply pair on
/// the shared connection, matching Apple's `XPCClient` semantics).
public final class APIServerClient: Sendable {
    public static let serviceName = "com.apple.container.apiserver"

    private let xpc: XPCConnection

    public init(service: String = APIServerClient.serviceName) {
        self.xpc = XPCConnection(service: service)
    }

    // MARK: - Health

    /// `ping` — also our version/capability handshake.
    public func ping(timeout: Duration = XPCConnection.registrationTimeout) async throws
        -> APIServerHealth
    {
        let reply = try await send(.init(route: XPCRoute.ping.rawValue), timeout: timeout)
        guard let version = reply.string(key: .apiServerVersion),
            let commit = reply.string(key: .apiServerCommit),
            let build = reply.string(key: .apiServerBuild),
            let appName = reply.string(key: .apiServerAppName)
        else {
            throw MicropodError.message("container-apiserver ping reply was missing version fields")
        }
        return APIServerHealth(
            apiServerVersion: version,
            apiServerCommit: commit,
            apiServerBuild: build,
            apiServerAppName: appName,
            appRoot: reply.string(key: .appRoot),
            installRoot: reply.string(key: .installRoot),
            logRoot: reply.string(key: .logRoot)
        )
    }

    // MARK: - Containers

    /// `containerList` → `[ContainerSnapshot]` transformed to
    /// `ManagedContainer` JSON (the `container list --format json` shape).
    public func list(ids: [String] = [], status: String? = nil, labels: [String: String] = [:])
        async throws -> Data
    {
        let request = XPCMessage(route: XPCRoute.containerList.rawValue)
        let filters = APIListFilters(ids: ids, status: status, labels: labels)
        request.set(key: .listFilters, value: try JSONEncoder().encode(filters))
        let reply = try await send(request, timeout: .seconds(10))
        guard let data = reply.data(key: .containers) else {
            return Data("[]".utf8)
        }
        return try SnapshotTransform.toManagedArrayData(data)
    }

    /// Managed-container JSON for a single id (nil when absent).
    public func get(id: String) async throws -> Data? {
        let data = try await list(ids: [id])
        let entries = try MicropodJSON.decodeArray(JSONValue.self, from: data, context: "container get")
        guard let first = entries.first else { return nil }
        return try JSONEncoder().encode([first])
    }

    /// Managed-container JSON object for `createProcess` patching.
    func managed(id: String) async throws -> JSONValue {
        guard let data = try await get(id: id) else {
            throw MicropodError.message("container \(id) not found")
        }
        let managed = try MicropodJSON.decode(JSONValue.self, from: data, context: "container get")
        guard case .array(let arr) = managed, let first = arr.first else {
            throw MicropodError.message("container \(id): unexpected get reply")
        }
        return first
    }

    /// `containerBootstrap` — start the container's init process (VM boot).
    public func bootstrap(id: String, stdio: [FileHandle?] = [nil, nil, nil]) async throws {
        let request = XPCMessage(route: XPCRoute.containerBootstrap.rawValue)
        request.set(key: .id, value: id)
        request.set(key: .dynamicEnv, value: try JSONEncoder().encode([String: String]()))
        for (i, handle) in stdio.enumerated() {
            guard let handle else { continue }
            let key: XPCKeys =
                switch i {
                case 0: .stdin
                case 1: .stdout
                case 2: .stderr
                default: throw MicropodError.message("invalid stdio index \(i)")
                }
            try request.set(key: key, value: handle)
        }
        try await send(request)
    }

    /// `containerStop`.
    public func stop(id: String, timeoutSeconds: Int32 = 5, signal: String? = nil) async throws {
        let request = XPCMessage(route: XPCRoute.containerStop.rawValue)
        request.set(key: .id, value: id)
        let options = APIStopOptions(timeoutInSeconds: timeoutSeconds, signal: signal)
        request.set(key: .stopOptions, value: try JSONEncoder().encode(options))
        try await send(request)
    }

    /// `containerKill` (container scope — signals the init process).
    public func killContainer(id: String, signal: String) async throws {
        let request = XPCMessage(route: XPCRoute.containerKill.rawValue)
        request.set(key: .id, value: id)
        request.set(key: .processIdentifier, value: id)
        request.set(key: .signal, value: signal)
        try await send(request)
    }

    /// `containerKill` (process scope — numeric signal).
    public func killProcess(containerId: String, processId: String, signal: Int32) async throws {
        let request = XPCMessage(route: XPCRoute.containerKill.rawValue)
        request.set(key: .id, value: containerId)
        request.set(key: .processIdentifier, value: processId)
        request.set(key: .signal, value: Int64(signal))
        try await send(request)
    }

    /// `containerDelete`.
    public func delete(id: String, force: Bool = false) async throws {
        let request = XPCMessage(route: XPCRoute.containerDelete.rawValue)
        request.set(key: .id, value: id)
        request.set(key: .forceDelete, value: force)
        try await send(request)
    }

    /// `containerCreate` — registers a stopped container. `configJSON` is
    /// a `ContainerConfiguration`, `kernel` the `Kernel` DTO returned by
    /// ``getDefaultKernel`` (passed through verbatim), `options` a
    /// `ContainerCreateOptions`.
    public func create(configJSON: JSONValue, kernel: Data, options: JSONValue, initImage: String? = nil)
        async throws
    {
        let request = XPCMessage(route: XPCRoute.containerCreate.rawValue)
        request.set(key: .containerConfig, value: try JSONEncoder().encode(configJSON))
        request.set(key: .kernel, value: kernel)
        request.set(key: .containerOptions, value: try JSONEncoder().encode(options))
        if let initImage {
            request.set(key: .initImage, value: initImage)
        }
        try await send(request)
    }

    /// `getDefaultKernel` → raw `Kernel` DTO data (returned verbatim into
    /// `containerCreate`; we never need to inspect it).
    public func getDefaultKernel(systemPlatform: JSONValue) async throws -> Data {
        let request = XPCMessage(route: XPCRoute.getDefaultKernel.rawValue)
        request.set(key: .systemPlatform, value: try JSONEncoder().encode(systemPlatform))
        let reply = try await send(request, timeout: .seconds(60))
        guard let data = reply.data(key: .kernel) else {
            throw MicropodError.message(
                "default kernel not configured — use `container system kernel set`")
        }
        // `data(key:)` is a bytesNoCopy view into the reply dictionary —
        // it dangles once the reply is released. Copy before returning.
        return Data(data)
    }

    // MARK: - Networks

    /// `networkList` → `[NetworkResource]` (`{id, configuration, status}`).
    public func networkList() async throws -> [JSONValue] {
        let request = XPCMessage(route: XPCRoute.networkList.rawValue)
        let reply = try await send(request, timeout: .seconds(5))
        guard let data = reply.data(key: .networkResources) else { return [] }
        return try MicropodJSON.decoder.decode([JSONValue].self, from: data)
    }

    /// The built-in network's id (`configuration.labels` carries
    /// `com.apple.container.resource.role == "builtin"`).
    public static func builtinNetworkID(in networks: [JSONValue]) -> String? {
        for resource in networks {
            guard case .object(let o) = resource,
                case .object(let config) = o["configuration"],
                case .object(let labels) = config["labels"],
                case .string(let role) = labels["com.apple.container.resource.role"],
                role == "builtin",
                case .string(let name) = config["name"]
            else { continue }
            return name
        }
        return nil
    }

    /// Ids of every network in a `networkList` reply.
    public static func networkIDs(in networks: [JSONValue]) -> Set<String> {
        var ids: Set<String> = []
        for resource in networks {
            guard case .object(let o) = resource,
                case .object(let config) = o["configuration"],
                case .string(let name) = config["name"]
            else { continue }
            ids.insert(name)
        }
        return ids
    }

    // MARK: - Volumes

    /// `volumeCreate` → `VolumeConfiguration` (`{name, format, source, …}`).
    public func volumeCreate(
        name: String, driver: String = "local",
        driverOpts: [String: String] = [:], labels: [String: String] = [:]
    ) async throws -> JSONValue {
        let request = XPCMessage(route: XPCRoute.volumeCreate.rawValue)
        request.set(key: .volumeName, value: name)
        request.set(key: .volumeDriver, value: driver)
        request.set(key: .volumeDriverOpts, value: try JSONEncoder().encode(driverOpts))
        request.set(key: .volumeLabels, value: try JSONEncoder().encode(labels))
        let reply = try await send(request)
        guard let data = reply.data(key: .volume) else {
            throw MicropodError.message("volumeCreate returned no volume")
        }
        return try MicropodJSON.decoder.decode(JSONValue.self, from: data)
    }

    /// `volumeInspect` → `VolumeConfiguration`, nil when absent.
    public func volumeInspect(name: String) async throws -> JSONValue? {
        let request = XPCMessage(route: XPCRoute.volumeInspect.rawValue)
        request.set(key: .volumeName, value: name)
        do {
            let reply = try await send(request)
            guard let data = reply.data(key: .volume) else { return nil }
            return try MicropodJSON.decoder.decode(JSONValue.self, from: data)
        } catch {
            // Server surfaces missing volumes as an XPC error, not an empty
            // reply — treat any error as "not found" only when it says so.
            if error.localizedDescription.contains("not found")
                || error.localizedDescription.contains("does not exist")
            {
                return nil
            }
            throw error
        }
    }

    /// `getOrCreateVolume` — CLI semantics: create, fall back to inspect
    /// on already-exists.
    public func getOrCreateVolume(name: String, labels: [String: String] = [:]) async throws -> JSONValue {
        do {
            return try await volumeCreate(name: name, labels: labels)
        } catch {
            if let existing = try await volumeInspect(name: name) {
                return existing
            }
            throw error
        }
    }

    // MARK: - Processes

    /// `containerCreateProcess` — registers an exec process; stdio fds are
    /// passed to the apiserver which forwards them into the guest.
    public func createProcess(
        containerId: String,
        processId: String,
        configJSON: JSONValue,
        stdio: [FileHandle?]
    ) async throws {
        let request = XPCMessage(route: XPCRoute.containerCreateProcess.rawValue)
        request.set(key: .id, value: containerId)
        request.set(key: .processIdentifier, value: processId)
        request.set(key: .processConfig, value: try JSONEncoder().encode(configJSON))
        for (i, handle) in stdio.enumerated() {
            guard let handle else { continue }
            let key: XPCKeys =
                switch i {
                case 0: .stdin
                case 1: .stdout
                case 2: .stderr
                default: throw MicropodError.message("invalid stdio index \(i)")
                }
            try request.set(key: key, value: handle)
        }
        try await send(request)
    }

    /// `containerStartProcess`.
    public func startProcess(containerId: String, processId: String) async throws {
        let request = XPCMessage(route: XPCRoute.containerStartProcess.rawValue)
        request.set(key: .id, value: containerId)
        request.set(key: .processIdentifier, value: processId)
        try await send(request)
    }

    /// `containerWait` — blocks until the process exits; returns exit code.
    public func waitProcess(containerId: String, processId: String) async throws -> Int32 {
        let request = XPCMessage(route: XPCRoute.containerWait.rawValue)
        request.set(key: .id, value: containerId)
        request.set(key: .processIdentifier, value: processId)
        let reply = try await send(request)
        return Int32(reply.int64(key: .exitCode))
    }

    /// `containerResize` — resize the process's PTY.
    public func resizeProcess(containerId: String, processId: String, width: UInt16, height: UInt16)
        async throws
    {
        let request = XPCMessage(route: XPCRoute.containerResize.rawValue)
        request.set(key: .id, value: containerId)
        request.set(key: .processIdentifier, value: processId)
        request.set(key: .width, value: UInt64(width))
        request.set(key: .height, value: UInt64(height))
        try await send(request)
    }

    // MARK: - Logs

    /// `containerLogs` → [stdout, stderr] file handles.
    public func logs(id: String) async throws -> [FileHandle] {
        let request = XPCMessage(route: XPCRoute.containerLogs.rawValue)
        request.set(key: .id, value: id)
        let reply = try await send(request)
        guard let handles = reply.fileHandles(key: .logs) else {
            throw MicropodError.message("container \(id): no log fds returned")
        }
        return handles
    }

    // MARK: - Stats / disk

    /// `containerStats` → `ContainerStats` (same shape as CLI stats output).
    public func stats(id: String) async throws -> ContainerStatsEntry {
        let request = XPCMessage(route: XPCRoute.containerStats.rawValue)
        request.set(key: .id, value: id)
        let reply = try await send(request)
        guard let data = reply.data(key: .statistics) else {
            throw MicropodError.message("container \(id): no statistics returned")
        }
        return try MicropodJSON.decode(ContainerStatsEntry.self, from: data, context: "container stats")
    }

    /// `containerDiskUsage` → bytes.
    public func diskUsage(id: String) async throws -> UInt64 {
        let request = XPCMessage(route: XPCRoute.containerDiskUsage.rawValue)
        request.set(key: .id, value: id)
        let reply = try await send(request)
        return reply.uint64(key: .containerSize)
    }

    // MARK: - vsock

    /// `containerDial` → a host fd connected to the guest's vsock `port`.
    /// This is the gateway to `vminitd` (port 1024) and any guest listener.
    public func dial(id: String, port: UInt32) async throws -> FileHandle {
        let request = XPCMessage(route: XPCRoute.containerDial.rawValue)
        request.set(key: .id, value: id)
        request.set(key: .port, value: UInt64(port))
        let reply = try await send(request)
        guard let handle = reply.fileHandle(key: .fd) else {
            throw MicropodError.message("container \(id): no fd for vsock port \(port)")
        }
        return handle
    }

    // MARK: - Copy / export

    /// `containerCopyIn` — host path → container path.
    public func copyIn(id: String, source: String, destination: String, mode: UInt32 = 0o644)
        async throws
    {
        let request = XPCMessage(route: XPCRoute.containerCopyIn.rawValue)
        request.set(key: .id, value: id)
        request.set(key: .sourcePath, value: source)
        request.set(key: .destinationPath, value: destination)
        request.set(key: .fileMode, value: UInt64(mode))
        request.set(key: .createParents, value: true)
        try await send(request, timeout: .seconds(300))
    }

    /// `containerCopyOut` — container path → host path.
    public func copyOut(id: String, source: String, destination: String) async throws {
        let request = XPCMessage(route: XPCRoute.containerCopyOut.rawValue)
        request.set(key: .id, value: id)
        request.set(key: .sourcePath, value: source)
        request.set(key: .destinationPath, value: destination)
        request.set(key: .createParents, value: true)
        try await send(request, timeout: .seconds(300))
    }

    /// `containerExport` — rootfs → tar archive at path.
    public func export(id: String, archivePath: String) async throws {
        let request = XPCMessage(route: XPCRoute.containerExport.rawValue)
        request.set(key: .id, value: id)
        request.set(key: .archive, value: archivePath)
        try await send(request)
    }

    // MARK: - Internals

    @discardableResult
    private func send(_ request: XPCMessage, timeout: Duration? = nil) async throws -> XPCMessage {
        try await xpc.send(request, responseTimeout: timeout)
    }
}

extension XPCMessage {
    func string(key: XPCKeys) -> String? { string(key: key.rawValue) }
    func set(key: XPCKeys, value: String) { set(key: key.rawValue, value: value) }
    func set(key: XPCKeys, value: Bool) { set(key: key.rawValue, value: value) }
    func set(key: XPCKeys, value: UInt64) { set(key: key.rawValue, value: value) }
    func set(key: XPCKeys, value: Int64) { set(key: key.rawValue, value: value) }
    func set(key: XPCKeys, value: Data) { set(key: key.rawValue, value: value) }
    func set(key: XPCKeys, value: FileHandle) throws { try set(key: key.rawValue, value: value) }
    func data(key: XPCKeys) -> Data? { data(key: key.rawValue) }
    func uint64(key: XPCKeys) -> UInt64 { uint64(key: key.rawValue) }
    func int64(key: XPCKeys) -> Int64 { int64(key: key.rawValue) }
    func fileHandle(key: XPCKeys) -> FileHandle? { fileHandle(key: key.rawValue) }
    func fileHandles(key: XPCKeys) -> [FileHandle]? { fileHandles(key: key.rawValue) }
}
