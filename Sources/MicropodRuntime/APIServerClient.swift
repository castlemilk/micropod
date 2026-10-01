import Foundation
import MicropodCore
import os

/// Typed client for `container-apiserver` over the XPC protocol.
///
/// One instance owns one persistent XPC connection; calls are independent
/// and safe to issue concurrently (each is a separate send/reply pair on
/// the shared connection, matching Apple's `XPCClient` semantics).
///
/// The read routes callers poll — `containerList`, `volumeInspect`,
/// `volumeList`, `networkList` — go through ``SharedReads``: identical
/// reads share one request, callers give up after their ``ReadPolicy``
/// budget while the request keeps waiting for later ones, and every write
/// below invalidates what it may change, so a caller always reads its own
/// writes.
public final class APIServerClient: Sendable {
    public static let serviceName = "com.apple.container.apiserver"

    private let xpc: XPCConnection
    private let containerReads = SharedReads<Data>(route: XPCRoute.containerList.rawValue)
    /// Keyed by volume name; "not found" is never remembered.
    private let volumeReads = SharedReads<JSONValue?>(route: XPCRoute.volumeInspect.rawValue) { $0 != nil }
    private let volumeLists = SharedReads<[JSONValue]>(route: XPCRoute.volumeList.rawValue)
    private let networkLists = SharedReads<[JSONValue]>(route: XPCRoute.networkList.rawValue)
    /// The apiserver's app root, from the last `ping` (container bundles
    /// live under `<appRoot>/containers/<id>`).
    private let appRoot = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// How long a shared read's request waits for its reply. Callers wait
    /// only their budget; the request outlives them so the callers that
    /// arrive while the apiserver is still busy join it instead of sending
    /// another.
    static let sharedReadTimeout: Duration = .seconds(60)
    /// A volume's name, format and backing image never change while it
    /// exists, so its configuration is remembered this long — and checked
    /// against its backing image on every use.
    static let volumeConfigLifetime: Duration = .seconds(600)

    public init(service: String = APIServerClient.serviceName) {
        self.xpc = XPCConnection(service: service)
    }

    /// True once XPC invalidated the connection (the apiserver was
    /// unregistered). It never recovers: the backend must be resolved again.
    public var isInvalidated: Bool { xpc.isInvalidated }

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
        if let root = reply.string(key: .appRoot) {
            appRoot.withLock { $0 = root }
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
    /// Identical lists in flight share one request (see ``SharedReads``).
    public func list(
        ids: [String] = [], status: String? = nil, labels: [String: String] = [:], policy: ReadPolicy = .live
    ) async throws -> Data {
        let filters = try Self.keyEncoder.encode(APIListFilters(ids: ids.sorted(), status: status, labels: labels))
        return try await containerReads.read(
            String(decoding: filters, as: UTF8.self), policy: policy, requestTimeout: Self.sharedReadTimeout
        ) { [self] timeout in
            let request = XPCMessage(route: XPCRoute.containerList.rawValue)
            request.set(key: .listFilters, value: filters)
            let reply = try await send(request, timeout: timeout)
            guard let data = reply.data(key: .containers) else {
                return Data("[]".utf8)
            }
            return try SnapshotTransform.toManagedArrayData(data)
        }
    }

    /// Managed-container JSON for a single id (nil when absent).
    ///
    /// A `polling` read is answered from the full list every poller shares —
    /// N containers' exit waits and log follows cost one request per
    /// `maxAge`, not N per poll. A container missing from that list is asked
    /// about directly: absence from a recent list is no proof it is gone.
    public func get(id: String, policy: ReadPolicy = .live) async throws -> Data? {
        if policy.maxAge != nil {
            let all = try MicropodJSON.decodeArray(
                JSONValue.self, from: try await list(policy: policy), context: "container get")
            if let entry = all.first(where: { Self.containerID(of: $0) == id }) {
                return try JSONEncoder().encode([entry])
            }
            return try await get(id: id, policy: ReadPolicy(budget: policy.budget))
        }
        let data = try await list(ids: [id], policy: policy)
        let entries = try MicropodJSON.decodeArray(JSONValue.self, from: data, context: "container get")
        guard let first = entries.first else { return nil }
        return try JSONEncoder().encode([first])
    }

    private static func containerID(of entry: JSONValue) -> String? {
        guard case .object(let object) = entry, case .string(let id)? = object["id"] else { return nil }
        return id
    }

    /// Filters encode to the same bytes for the same filters: they are the
    /// shared-read key.
    private static let keyEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

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
        try await send(request, timeout: .seconds(300))
    }

    /// `containerStop`.
    public func stop(id: String, timeoutSeconds: Int32 = 5, signal: String? = nil) async throws {
        let request = XPCMessage(route: XPCRoute.containerStop.rawValue)
        request.set(key: .id, value: id)
        let options = APIStopOptions(timeoutInSeconds: timeoutSeconds, signal: signal)
        request.set(key: .stopOptions, value: try JSONEncoder().encode(options))
        try await send(request, timeout: .seconds(Int64(timeoutSeconds) + 60))
    }

    /// `containerKill` (container scope — signals the init process).
    public func killContainer(id: String, signal: String) async throws {
        let request = XPCMessage(route: XPCRoute.containerKill.rawValue)
        request.set(key: .id, value: id)
        request.set(key: .processIdentifier, value: id)
        request.set(key: .signal, value: signal)
        try await send(request, timeout: .seconds(30))
    }

    /// `containerKill` (process scope — numeric signal).
    public func killProcess(containerId: String, processId: String, signal: Int32) async throws {
        let request = XPCMessage(route: XPCRoute.containerKill.rawValue)
        request.set(key: .id, value: containerId)
        request.set(key: .processIdentifier, value: processId)
        request.set(key: .signal, value: Int64(signal))
        try await send(request, timeout: .seconds(30))
    }

    /// `containerDelete`.
    public func delete(id: String, force: Bool = false) async throws {
        let request = XPCMessage(route: XPCRoute.containerDelete.rawValue)
        request.set(key: .id, value: id)
        request.set(key: .forceDelete, value: force)
        try await send(request, timeout: .seconds(300))
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
        try await send(request, timeout: .seconds(600))
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
    public func networkList(policy: ReadPolicy = ReadPolicy(budget: .seconds(5))) async throws -> [JSONValue] {
        try await networkLists.read("", policy: policy, requestTimeout: .seconds(30)) { [self] timeout in
            try await fetchNetworks(timeout: timeout)
        }
    }

    private func fetchNetworks(timeout: Duration) async throws -> [JSONValue] {
        let request = XPCMessage(route: XPCRoute.networkList.rawValue)
        let reply = try await send(request, timeout: timeout)
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
        let reply = try await send(request, timeout: .seconds(600))
        guard let data = reply.data(key: .volume) else {
            throw MicropodError.message("volumeCreate returned no volume")
        }
        let volume = try MicropodJSON.decoder.decode(JSONValue.self, from: data)
        await volumeReads.remember(name, volume)
        return volume
    }

    /// `volumeList` → `[VolumeConfiguration]` (flat `{name, format, source,
    /// creationDate, sizeInBytes, labels, …}` objects; see
    /// ``VolumeTransform`` for the `{id, configuration}` listing shape).
    public func volumeList(policy: ReadPolicy = .live) async throws -> [JSONValue] {
        try await volumeLists.read("", policy: policy, requestTimeout: Self.sharedReadTimeout) { [self] timeout in
            let reply = try await send(XPCMessage(route: XPCRoute.volumeList.rawValue), timeout: timeout)
            guard let data = reply.data(key: .volumes) else { return [] }
            return try MicropodJSON.decoder.decode([JSONValue].self, from: data)
        }
    }

    /// `volumeDelete`.
    public func volumeDelete(name: String) async throws {
        let request = XPCMessage(route: XPCRoute.volumeDelete.rawValue)
        request.set(key: .volumeName, value: name)
        try await send(request, timeout: .seconds(30))
    }

    /// `volumeInspect` → `VolumeConfiguration`, nil when absent.
    public func volumeInspect(name: String, policy: ReadPolicy = .live) async throws -> JSONValue? {
        try await volumeReads.read(name, policy: policy, requestTimeout: Self.sharedReadTimeout) { [self] timeout in
            let request = XPCMessage(route: XPCRoute.volumeInspect.rawValue)
            request.set(key: .volumeName, value: name)
            do {
                let reply = try await send(request, timeout: timeout)
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
    }

    /// A volume's configuration for a create's mounts and clones, nil when
    /// absent. Answered from memory while the volume's backing image is
    /// still there: the apiserver serves `volumeInspect` under the lock its
    /// volume creates hold while they format, so on a busy host every
    /// clone's inspect queued behind every other job's workspace volume.
    public func volumeConfig(name: String) async throws -> JSONValue? {
        if let known = await knownVolume(name) {
            APIServerMetrics.read(XPCRoute.volumeInspect.rawValue, .remembered)
            return known
        }
        return try await volumeInspect(name: name, policy: .patient)
    }

    /// The remembered configuration of `name`, if its backing image still
    /// exists (a volume deleted behind this client's back is forgotten).
    private func knownVolume(_ name: String) async -> JSONValue? {
        guard let known = await volumeReads.answer(name, maxAge: Self.volumeConfigLifetime), let volume = known
        else { return nil }
        guard Self.backingImageExists(volume) else {
            await volumeReads.invalidate(name)
            return nil
        }
        return volume
    }

    static func backingImageExists(_ volume: JSONValue) -> Bool {
        guard case .object(let object) = volume, case .string(let source)? = object["source"], !source.isEmpty
        else { return false }
        return FileManager.default.fileExists(atPath: source)
    }

    /// `getOrCreateVolume` — CLI semantics: create, fall back to inspect
    /// on already-exists. A volume this client already knows exists is
    /// answered without either.
    public func getOrCreateVolume(name: String, labels: [String: String] = [:]) async throws -> JSONValue {
        if let known = await knownVolume(name) {
            APIServerMetrics.read(XPCRoute.volumeInspect.rawValue, .remembered)
            return known
        }
        do {
            return try await volumeCreate(name: name, labels: labels)
        } catch {
            if let existing = try await volumeInspect(name: name, policy: .patient) {
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
        try await send(request, timeout: .seconds(60))
    }

    /// `containerStartProcess`.
    public func startProcess(containerId: String, processId: String) async throws {
        let request = XPCMessage(route: XPCRoute.containerStartProcess.rawValue)
        request.set(key: .id, value: containerId)
        request.set(key: .processIdentifier, value: processId)
        try await send(request, timeout: .seconds(60))
    }

    /// `containerWait` — blocks until the process exits; returns exit code.
    public func waitProcess(containerId: String, processId: String) async throws -> Int32 {
        let request = XPCMessage(route: XPCRoute.containerWait.rawValue)
        request.set(key: .id, value: containerId)
        request.set(key: .processIdentifier, value: processId)
        let reply = try await send(request, timeout: nil)
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
        try await send(request, timeout: .seconds(10))
    }

    // MARK: - Logs

    /// `containerLogs` → [stdout, stderr] file handles.
    public func logs(id: String) async throws -> [FileHandle] {
        let request = XPCMessage(route: XPCRoute.containerLogs.rawValue)
        request.set(key: .id, value: id)
        let reply = try await send(request, timeout: .seconds(10))
        guard let handles = reply.fileHandles(key: .logs) else {
            throw MicropodError.message("container \(id): no log fds returned")
        }
        return handles
    }

    // MARK: - Stats / disk

    /// `containerStats` → `ContainerStats` (same shape as CLI stats output).
    /// Bounded: a wedged container's helper never answers `containerStats`
    /// (seen live with `container stats` hanging on one of three running
    /// containers), and one such call must not hold the whole snapshot.
    public func stats(id: String, timeout: Duration = .seconds(5)) async throws -> ContainerStatsEntry {
        let request = XPCMessage(route: XPCRoute.containerStats.rawValue)
        request.set(key: .id, value: id)
        let reply = try await send(request, timeout: timeout)
        guard let data = reply.data(key: .statistics) else {
            throw MicropodError.message("container \(id): no statistics returned")
        }
        return try MicropodJSON.decode(ContainerStatsEntry.self, from: data, context: "container stats")
    }

    /// A container's allocated bytes — what `containerDiskUsage` answers.
    /// The apiserver walks the bundle on its containers actor, so every
    /// list, stats and delete call waits for the walk; the bundle is a plain
    /// directory under the app root, so it is walked here instead. Falls
    /// back to the route when the app root is unknown or the bundle is not
    /// where it is expected.
    public func diskUsage(id: String) async throws -> UInt64 {
        if let root = appRoot.withLock({ $0 }),
            let bytes = Self.allocatedSize(of: URL(fileURLWithPath: root).appendingPathComponent("containers/\(id)"))
        {
            return bytes
        }
        let request = XPCMessage(route: XPCRoute.containerDiskUsage.rawValue)
        request.set(key: .id, value: id)
        let reply = try await send(request, timeout: .seconds(30))
        return reply.uint64(key: .containerSize)
    }

    /// The apiserver's measure (`FileManager.allocatedSize(of:)`: the
    /// non-hidden files' total allocated size), or nil when `directory` is
    /// not a directory.
    static func allocatedSize(of directory: URL) -> UInt64? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
            let files = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [.skipsHiddenFiles])
        else { return nil }
        var total: UInt64 = 0
        for case let file as URL in files {
            if let size = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize {
                total += UInt64(size)
            }
        }
        return total
    }

    // MARK: - vsock

    /// `containerDial` → a host fd connected to the guest's vsock `port`.
    /// This is the gateway to `vminitd` (port 1024) and any guest listener.
    public func dial(id: String, port: UInt32) async throws -> FileHandle {
        let request = XPCMessage(route: XPCRoute.containerDial.rawValue)
        request.set(key: .id, value: id)
        request.set(key: .port, value: UInt64(port))
        let reply = try await send(request, timeout: .seconds(30))
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
        try await send(request, timeout: .seconds(600))
    }

    // MARK: - Internals

    @discardableResult
    /// Every call names its bound: a runtime that never answers (a wedged
    /// container helper) must not hold a caller forever. `nil` is an
    /// explicit, reviewed choice — only for waits whose length is the
    /// workload's own (waitProcess).
    ///
    /// Bounds are deliberately generous — they exist to end a call the
    /// runtime will never answer, not to police slow-but-healthy work: a
    /// timed-out create/bootstrap keeps running server-side, so a bound that
    /// fires on a busy host would strand a half-made container. Creates from
    /// large images under load have been seen to take minutes.
    ///
    /// Each send is counted per route in ``APIServerMetrics`` and logged when
    /// slow; a write, once settled, invalidates the shared reads it may have
    /// changed (see ``invalidate(after:_:)``).
    private func send(_ request: XPCMessage, timeout: Duration?) async throws -> XPCMessage {
        let route = request.string(key: XPCMessage.routeKey) ?? "?"
        let clock = ContinuousClock()
        let started = clock.now
        let result: Result<XPCMessage, any Error>
        do {
            result = .success(try await xpc.send(request, responseTimeout: timeout))
        } catch {
            result = .failure(error)
        }
        let took = clock.now - started
        // Settled, failed or timed out alike: a write the client stopped
        // waiting for may still land.
        await invalidate(after: route, request)
        APIServerMetrics.xpc(route, status: Self.metricStatus(result), duration: took)
        SlowCalls.note(route: route, took: took, failed: (try? result.get()) == nil)
        return try result.get()
    }

    /// Drops the shared reads a write on `route` may have changed.
    private func invalidate(after route: String, _ request: XPCMessage) async {
        switch XPCRoute(rawValue: route) {
        case .containerCreate, .containerBootstrap, .containerStartProcess, .containerStop, .containerKill,
            .containerDelete, .containerWait:
            await containerReads.invalidate()
        case .volumeCreate, .volumeDelete:
            await volumeLists.invalidate()
            if let name = request.string(key: .volumeName) {
                await volumeReads.invalidate(name)
            }
        case .networkCreate, .networkDelete:
            await networkLists.invalidate()
        default:
            break
        }
    }

    private static func metricStatus(_ result: Result<XPCMessage, any Error>) -> Int {
        guard case .failure(let error) = result else { return 200 }
        if case MicropodError.transport = error { return 503 }
        return error.localizedDescription.contains("deadlineExceeded") ? 504 : 500
    }
}

/// Logs apiserver calls slow enough to matter (≥ 5 s), at most one line
/// per route every 30 s, with how many were slow since the last line — the
/// stderr trail that says a CI failure was the runtime being busy.
enum SlowCalls {
    static let threshold: Duration = .seconds(5)
    static let interval: Duration = .seconds(30)

    private struct Route {
        var lastLogged: ContinuousClock.Instant?
        var suppressed = 0
        var worst: Duration = .zero
    }

    private static let routes = OSAllocatedUnfairLock<[String: Route]>(initialState: [:])

    static func note(route: String, took: Duration, failed: Bool) {
        guard took >= threshold else { return }
        let now = ContinuousClock.now
        let line: String? = routes.withLock { routes in
            var entry = routes[route, default: Route()]
            entry.worst = max(entry.worst, took)
            if let last = entry.lastLogged, now - last < interval {
                entry.suppressed += 1
                routes[route] = entry
                return nil
            }
            let more =
                entry.suppressed > 0
                ? " (+\(entry.suppressed) more slow since, worst \(entry.worst.secondsText))" : ""
            routes[route] = Route(lastLogged: now)
            return "micropod: apiserver \(route) \(failed ? "failed" : "answered") after \(took.secondsText)\(more)\n"
        }
        if let line { FileHandle.standardError.write(Data(line.utf8)) }
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
