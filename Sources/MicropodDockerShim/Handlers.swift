import Foundation
import MicropodCore
import MicropodRuntime
import MicropodSharedFS

enum ShimError: Error {
    case notFound(String)
    case conflict(String)
    case badRequest(String)
    case notImplemented(String)
    case internalError(String)

    var status: Int {
        switch self {
        case .notFound: return 404
        case .conflict: return 409
        case .badRequest: return 400
        case .notImplemented: return 501
        case .internalError: return 500
        }
    }

    var message: String {
        switch self {
        case .notFound(let m), .conflict(let m), .badRequest(let m), .notImplemented(let m),
            .internalError(let m):
            return m
        }
    }
}

struct ShimConfig: Sendable {
    var apiVersion = "1.44"
    var minAPIVersion = "1.24"
    var serverVersion = "27.3.1"
    var bridgeHost: String
    var tcpPort: UInt16
    /// Size handed to `container volume create -s` when a client does not ask
    /// for one. Docker's `local` driver grows on demand; the Apple runtime
    /// formats a fixed-size block device up front, so an unsized volume would
    /// silently inherit the runtime default and later ENOSPC mid-build. CI
    /// caches (Go module cache, npm, build caches) routinely exceed a few GB.
    /// Defaulted so callers that predate the field keep compiling.
    var defaultVolumeSize: String = "64g"
}

struct DockerNetworkCreateBody: Codable {
    var Name: String?
    var Driver: String?
    var Internal: Bool?
    var CheckDuplicate: Bool?
    struct IPAM: Codable {
        var Driver: String?
        var Config: [Config]?

        struct Config: Codable {
            var Subnet: String?
            var Gateway: String?
        }
    }
    var IPAM: IPAM?
    var Labels: [String: String]?
}

struct DockerVolumeCreateBody: Codable {
    var Name: String?
    var Driver: String?
    var Labels: [String: String]?
    var DriverOpts: [String: String]?
}

/// Top-level request router mapping Docker Engine API paths onto
/// MicropodCore service calls.
final class Router: @unchecked Sendable {
    let config: ShimConfig
    let state: ShimState
    let events: EventsHub
    let cliPath: String

    private let containers: any ContainerServing
    private let images: any ImageServing
    private let volumes: any VolumeServing
    private let networks: any NetworkServing
    private let system: any SystemServing
    private let systemConcrete: SystemService
    private let logs: any LogStreaming
    private let stats: any StatsSampling
    private let sharedFS: (any SharedFSClient)?
    /// Opt-in k8s engine — `?k8s=1` on /images/load or /build injects the
    /// image into the cluster's containerd after the host-side op.
    private let k8s: K8sService
    /// Read-through cache for hot Docker-API reads (list/inspect). Mutations
    /// invalidate synchronously; the events loop invalidates on transitions.
    private let readCache: ReadThroughCache
    /// Per-route latency/count metrics, exposed at GET /metrics (Prometheus
    /// text format) alongside CLIMetrics (per-command spawn timings).
    private let metrics = APIMetrics()
    /// Content-addressed build-context cache (no-change rebuilds skip tar
    /// staging). Injected for tests; production uses the standard on-disk
    /// location honoring MICROPOD_BUILD_CACHE_*.
    private let buildCache: BuildContextCache

    convenience init(
        config: ShimConfig, state: ShimState, events: EventsHub,
        client: ContainerCLIClient
    ) {
        self.init(config: config, state: state, events: events, client: client, sharedFS: nil)
    }

    init(
        config: ShimConfig, state: ShimState, events: EventsHub,
        client: ContainerCLIClient, sharedFS sharedFSOverride: (any SharedFSClient)?,
        buildCache buildCacheOverride: BuildContextCache? = nil,
        readCache readCacheOverride: ReadThroughCache? = nil,
        runtime: RuntimeServices? = nil
    ) {
        self.config = config
        self.state = state
        self.events = events
        self.cliPath = client.executableURL.path
        self.containers = runtime?.containers ?? ContainerService(client: client)
        self.images = ImageService(client: client)
        self.volumes = VolumeService(client: client)
        self.networks = NetworkService(client: client)
        self.system = SystemService(client: client)
        self.systemConcrete = SystemService(client: client)
        self.logs = runtime?.logs ?? LogStreamer(client: client)
        self.stats = runtime?.stats ?? StatsSampler(client: client)
        self.k8s = K8sService(client: client)
        self.buildCache = buildCacheOverride ?? BuildContextCache.standard()
        self.readCache = readCacheOverride ?? ReadThroughCache()
        if let sharedFSOverride {
            self.sharedFS = sharedFSOverride
        } else {
            // Best-effort: if the shared-fs daemon socket exists, use it for
            // synchronized file shares. Falls back to plain virtiofs binds.
            let sharedSocket =
                ProcessInfo.processInfo.environment["MICROPOD_SHAREDFS_SOCKET"]
                ?? NSString("~/micropod/share-cache/socket").expandingTildeInPath
            if FileManager.default.fileExists(atPath: sharedSocket) {
                self.sharedFS = UnixSocketClient(socketPath: sharedSocket)
            } else {
                self.sharedFS = nil
            }
        }
    }

    func route(_ request: ShimRequest, _ connection: ShimConnection) async -> ShimResponse {
        let started = Date()
        let response: ShimResponse
        do {
            response = try await dispatch(request, connection)
        } catch let error as ShimError {
            response = Self.errorJSON(error.status, error.message)
        } catch let error as MicropodError {
            response = Self.errorJSON(500, error.errorDescription ?? "\(error)")
        } catch {
            response = Self.errorJSON(500, "\(error)")
        }
        metrics.record(
            route: Self.normalizedRoute(request.path),
            method: request.method,
            status: response.statusCode,
            duration: Date().timeIntervalSince(started))
        return response
    }

    /// Collapses ids/names/image refs to `{id}` so /metrics label cardinality
    /// stays bounded (a route per container name would explode the registry).
    static func normalizedRoute(_ path: String) -> String {
        let keywords: Set<String> = [
            "_ping", "version", "info", "auth", "events", "metrics", "images", "json",
            "create", "tag", "prune", "push", "search", "load", "get", "commit",
            "containers", "start", "stop", "restart", "kill", "rename", "logs",
            "top", "stats", "archive", "exec", "resize", "wait", "attach",
            "pause", "unpause", "update", "changes", "export", "networks",
            "volumes", "system", "df", "connect", "disconnect", "build",
            "distribution", "session", "grpc", "join", "leave",
        ]
        let segments = path.split(separator: "/").map { seg in
            keywords.contains(String(seg)) ? String(seg) : "{id}"
        }
        return segments.joined(separator: "/")
    }

    static func errorJSON(_ code: Int, _ message: String) -> ShimResponse {
        let body = try? JSONEncoder().encode(["message": message])
        return .json(code, body ?? Data(#"{"message":"internal error"}"#.utf8))
    }

    // MARK: - Dispatch

    private func dispatch(_ request: ShimRequest, _ connection: ShimConnection) async throws
        -> ShimResponse
    {
        let segments = request.path.split(separator: "/").map(String.init)

        switch (request.method, segments.first ?? "") {

        // MARK: System
        case (_, "_ping"):
            return .raw(200, [("Content-Type", "text/plain")], Data("OK\n".utf8))
        case ("GET", "version"):
            return try await version()
        case ("GET", "info"):
            return try await info()
        case ("POST", "auth"):
            return try await auth(request)
        case ("GET", "events"):
            return await eventsStream(request)
        case ("GET", "metrics"):
            return try await metricsResponse()
        case ("GET", ""):
            throw ShimError.notFound("page not found")

        // MARK: Images
        case ("POST", "images") where segments.count == 2 && segments[1] == "create":
            return try await imagePull(request)
        case ("GET", "images") where segments.count == 2 && segments[1] == "json":
            return try await imagesList(request)
        case ("GET", "images") where segments.last == "json" && segments.count >= 3:
            // Image references contain slashes: /images/{repo[:tag]}/json.
            return try await imageInspect(segments[1..<segments.count - 1].joined(separator: "/"))
        case ("DELETE", "images") where segments.count >= 2:
            return try await imageDelete(segments[1...].joined(separator: "/"), request)
        case ("POST", "images") where segments.last == "tag" && segments.count >= 3:
            return try await imageTag(segments[1..<segments.count - 1].joined(separator: "/"), request)
        case ("POST", "images") where segments.count == 2 && segments[1] == "prune":
            return try await imagePrune(request)
        // `docker load` — tar body into the host store; ?k8s=1 also injects
        // into the k8s cluster's containerd.
        case ("POST", "images") where segments.last == "load" && segments.count >= 2:
            return try await imageLoad(request)
        // `docker save` — GET /images/{name}/get streams the tar back.
        case ("GET", "images") where segments.last == "get" && segments.count >= 3:
            return try await imageGet(segments[1..<segments.count - 1].joined(separator: "/"))
        // `docker save` multi-name form — GET /images/get?names=a&names=b.
        case ("GET", "images") where segments.count == 2 && segments[1] == "get":
            return try await imageGetMulti(request)
        // `docker push` — push a ref to its registry.
        case ("POST", "images") where segments.last == "push" && segments.count >= 3:
            return try await imagePush(segments[1..<segments.count - 1].joined(separator: "/"))

        // MARK: System
        case ("GET", "system") where segments.count == 2 && segments[1] == "df":
            return try await systemDF()
        case ("POST", "system") where segments.count == 2 && segments[1] == "prune":
            return try await systemPrune(request)

        // MARK: Containers
        case ("GET", "containers") where segments.count == 2 && segments[1] == "json":
            return try await containersList(request)
        case ("POST", "containers") where segments.count == 2 && segments[1] == "create":
            return try await containerCreate(request)
        case ("POST", "containers") where segments.count >= 2 && segments.last == "prune":
            return try await containersPrune()
        case ("GET", "containers") where segments.count == 3 && segments[2] == "json":
            return try await containerInspect(segments[1])
        case ("POST", "containers") where segments.count == 3 && segments[2] == "start":
            return try await containerAction(.start, segments[1])
        case ("POST", "containers") where segments.count == 3 && segments[2] == "stop":
            return try await containerStop(segments[1], request)
        case ("POST", "containers") where segments.count == 3 && segments[2] == "restart":
            return try await containerAction(.restart, segments[1])
        case ("POST", "containers") where segments.count == 3 && segments[2] == "kill":
            return try await containerAction(.kill, segments[1])
        case ("POST", "containers") where segments.count == 3 && segments[2] == "rename":
            return try await containerRename(segments[1], request)
        case ("DELETE", "containers") where segments.count == 2:
            return try await containerDelete(segments[1], request)
        case ("POST", "containers") where segments.count == 3 && segments[2] == "wait":
            return try await containerWait(segments[1], request)
        case ("GET", "containers") where segments.count == 3 && segments[2] == "logs":
            return try await containerLogs(segments[1], request)
        case ("POST", "containers") where segments.count == 3 && segments[2] == "attach":
            return try await containerAttach(segments[1], request, connection)
        case ("GET", "containers") where segments.count == 3 && segments[2] == "top":
            return try await containerTop(segments[1])
        case ("GET", "containers") where segments.count == 3 && segments[2] == "stats":
            return try await containerStats(segments[1])
        case ("PUT", "containers") where segments.count == 3 && segments[2] == "archive":
            return try await archivePut(segments[1], request)
        case ("GET", "containers") where segments.count == 3 && segments[2] == "archive":
            return try await archiveGet(segments[1], request)

        // MARK: Exec
        case ("POST", "containers") where segments.count == 3 && segments[2] == "exec":
            return try await execCreate(segments[1], request)
        case ("POST", "exec") where segments.count == 3 && segments[2] == "start":
            return try await execStart(segments[1], request, connection)
        case ("GET", "exec") where segments.count == 3 && segments[2] == "json":
            return try await execInspect(segments[1])

        // MARK: Networks
        // NOTE: the specific inspect route must precede the bare list route —
        // Swift matches top-down and the bare tuple would shadow it (this
        // exact shadowing once broke `docker compose up`, which inspects the
        // default network and choked on the list array).
        case ("GET", "networks") where segments.count == 2:
            return try await networkInspect(segments[1])
        case ("GET", "networks"):
            return try await networksList(request)
        case ("POST", "networks") where segments.count == 2 && segments[1] == "create":
            return try await networkCreate(request)
        case ("DELETE", "networks") where segments.count == 2:
            return try await networkDelete(segments[1])
        case ("POST", "networks") where segments.count == 2 && segments[1] == "prune":
            return try await networkPrune()
        case ("POST", "networks")
        where segments.count == 3 && (segments[2] == "connect" || segments[2] == "disconnect"):
            throw ShimError.notImplemented(
                "attach networks via HostConfig.NetworkMode at container create")

        // MARK: Build
        case ("POST", "build") where segments.count == 2 && segments[1] == "prune":
            return try await buildPrune(request)
        case ("POST", "build") where segments.count == 1:
            return try await imageBuild(request)

        // MARK: Volumes
        // NOTE: inspect-before-list ordering, see Networks above.
        case ("GET", "volumes") where segments.count == 2:
            return try await volumeInspect(segments[1])
        case ("GET", "volumes"):
            return try await volumesList(request)
        case ("POST", "volumes") where segments.count == 2 && segments[1] == "create":
            return try await volumeCreate(request)
        case ("DELETE", "volumes") where segments.count == 2:
            return try await volumeDelete(segments[1])
        case ("POST", "volumes") where segments.count == 2 && segments[1] == "prune":
            return try await volumePrune()

        default:
            throw ShimError.notFound("\(request.method) \(request.path): page not found")
        }
    }

    // MARK: - Helpers

    static func encode<T: Encodable>(_ value: T) -> ShimResponse {
        do {
            return .json(200, try JSONEncoder().encode(value))
        } catch {
            return errorJSON(500, "\(error)")
        }
    }

    static func encodeBody<T: Encodable>(_ value: T) -> Data {
        try! JSONEncoder().encode(value)
    }

    private func decodeBody<T: Decodable>(_ type: T.Type, _ request: ShimRequest) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: request.body)
        } catch {
            throw ShimError.badRequest("invalid JSON body: \(error)")
        }
    }

    private func resolveContainer(_ prefix: String) async throws -> Micropod_V1_Container {
        let all = try await containers.list()
        return try Self.resolve(prefix, in: all)
    }

    /// Cached-then-fresh service reads: internal consumers (info, df, inspect
    /// resolution) used to spawn a CLI per call even while the response cache
    /// sat warm — the same TTL + mutation invalidation rules apply here.
    private func cachedContainersList() async throws -> [Micropod_V1_Container] {
        if let cached = await readCache.cachedList() { return cached }
        let fresh = try await containers.list()
        await readCache.storeList(fresh)
        return fresh
    }

    private func cachedImagesList() async throws -> [Micropod_V1_Image] {
        if let cached = await readCache.cachedImages() { return cached }
        let fresh = try await images.list()
        await readCache.storeImages(fresh)
        return fresh
    }

    private func cachedVolumesList() async throws -> [Micropod_V1_Volume] {
        if let cached = await readCache.cachedVolumes() { return cached }
        let fresh = try await volumes.list()
        await readCache.storeVolumes(fresh)
        return fresh
    }

    /// Pure reference resolution over a (possibly cached) list: exact id,
    /// unique id-prefix, then unique Docker name/prefix. Mutations always
    /// resolve against a fresh list; read paths may pass the cached one.
    static func resolve(
        _ prefix: String, in all: [Micropod_V1_Container]
    ) throws -> Micropod_V1_Container {
        if let exact = all.first(where: { $0.id == prefix }) { return exact }
        // Docker addressing also accepts names (and their prefixes); in the
        // Apple runtime names usually ARE ids, but not always (e.g. mock or
        // externally-created containers).
        let nameMatches = all.filter { $0.id.hasPrefix(prefix) }
        if nameMatches.count == 1 { return nameMatches[0] }
        let named = all.filter { container in
            container.id != prefix
                && DockerMapper.names(for: container).contains {
                    $0 == prefix || $0.hasPrefix(prefix)
                }
        }
        if named.count == 1 { return named[0] }
        if nameMatches.isEmpty && named.isEmpty {
            throw ShimError.notFound("No such container: \(prefix)")
        }
        throw ShimError.conflict("Ambiguous container reference: \(prefix)")
    }

    /// Grabs an ephemeral free TCP port from the OS for auto-published ports.
    static func freePort() -> Int {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return 0 }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        var resolved = sockaddr_in()
        let named = withUnsafeMutablePointer(to: &resolved) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else { return 0 }
        return Int(CFSwapInt16BigToHost(resolved.sin_port))
    }

    // MARK: - System handlers

    private func version() async throws -> ShimResponse {
        let runtimeVersion = (try? await systemConcrete.cliVersion()) ?? "unknown"
        return Self.encode(
            DockerVersion(
                Platform: .init(Name: "Apple Container Runtime"),
                Components: [
                    .init(Name: "Engine", Version: config.serverVersion),
                    .init(Name: "container-apiserver", Version: runtimeVersion),
                ],
                Version: config.serverVersion,
                ApiVersion: config.apiVersion,
                MinAPIVersion: config.minAPIVersion,
                GitCommit: "micropod-shim",
                GoVersion: "go1.22",
                Os: "linux",
                Arch: "arm64",
                KernelVersion: ProcessInfo.processInfo.kernelVersion,
                BuildTime: ISO8601DateFormatter().string(from: Date())))
    }

    /// GET /metrics — Prometheus text: per-route request latency, per-command
    /// CLI spawn timings, and read-cache hit/miss counters. Not part of the
    /// Docker API; pure observability for perf work.
    private func metricsResponse() async throws -> ShimResponse {
        var text = metrics.render()
        text += CLIMetrics.shared.render()
        let (hits, misses) = await readCache.stats()
        text += "# HELP micropod_shim_cache_hits Read-through cache hits\n"
        text += "# TYPE micropod_shim_cache_hits counter\n"
        text += "micropod_shim_cache_hits \(hits)\n"
        text += "# HELP micropod_shim_cache_misses Read-through cache misses\n"
        text += "# TYPE micropod_shim_cache_misses counter\n"
        text += "micropod_shim_cache_misses \(misses)\n"
        return .raw(200, [("Content-Type", "text/plain; version=0.0.4")], Data(text.utf8))
    }

    private func info() async throws -> ShimResponse {
        // The two lists are independent reads — fetch concurrently (through
        // the read cache: a warm info is microseconds, not two CLI spawns).
        async let listedContainers = cachedContainersList()
        async let listedImages = cachedImagesList()
        let (list, imageList) = try await (listedContainers, listedImages)
        let running = list.filter { DockerMapper.stateName($0.state) == "running" }.count
        return Self.encode(
            DockerInfo(
                ID: "MICROPOD:\(ProcessInfo.processInfo.hostName)",
                Containers: list.count,
                ContainersRunning: running,
                ContainersPaused: 0,
                ContainersStopped: list.count - running,
                Images: imageList.count,
                Driver: "virtualization",
                MemoryLimit: true, SwapLimit: false, KernelMemoryTCP: false,
                CpuCfsPeriod: true, CpuCfsQuota: true, CPUShares: true, CPUSet: true,
                PidsLimit: true, IPv4Forwarding: true, BridgeNfIptables: false,
                BridgeNfIp6tables: false, Debug: false,
                NFd: 24, OomKillDisable: false, NGoroutines: 42,
                SystemTime: ISO8601DateFormatter().string(from: Date()),
                LoggingDriver: "default", CgroupDriver: "cgroupfs", CgroupVersion: "2",
                NEventsListener: 0,
                KernelVersion: ProcessInfo.processInfo.kernelVersion,
                OperatingSystem: "macOS (Apple container runtime)", OSVersion: "26.0",
                OSType: "linux", Architecture: "arm64",
                NCPU: ProcessInfo.processInfo.activeProcessorCount,
                MemTotal: Int64(ProcessInfo.processInfo.physicalMemory),
                Name: ProcessInfo.processInfo.hostName,
                ServerVersion: config.serverVersion,
                DockerRootDir: "~/.micropod"))
    }

    private func auth(_ request: ShimRequest) async throws -> ShimResponse {
        guard !request.body.isEmpty,
            let payload = try? JSONDecoder().decode(AuthPayload.self, from: request.body)
        else { throw ShimError.badRequest("missing auth payload") }
        let registry = RegistryService(client: ContainerCLIClient(executableURL: URL(fileURLWithPath: cliPath)))
        try await registry.login(
            server: payload.serverAddress ?? "",
            username: payload.username ?? "unknown",
            password: payload.password ?? "")
        return Self.encode(AuthResponse())
    }

    struct AuthPayload: Codable {
        var username: String?
        var password: String?
        var serverAddress: String?
    }

    struct AuthResponse: Codable {
        var IdentityToken = ""
        var Status = "Login Succeeded"
    }

    private func eventsStream(_ request: ShimRequest) async -> ShimResponse {
        let filters = request.filters()
        let (_, stream) = await events.subscribe(filters: filters, state: state)
        return .stream(200, [("Content-Type", "application/json")], stream)
    }

    // MARK: - Image handlers

    private func imagePull(_ request: ShimRequest) async throws -> ShimResponse {
        let reference: String
        let tagOverride = request.q("tag")
        if let fromImage = request.query["fromImage"], !fromImage.isEmpty {
            reference = tagOverride.isEmpty ? fromImage : "\(fromImage):\(tagOverride)"
        } else if let fromSrc = request.query["fromSrc"], !fromSrc.isEmpty {
            throw ShimError.notImplemented("image import (fromSrc) is not supported")
        } else {
            throw ShimError.badRequest("missing fromImage parameter")
        }
        let platform = request.q("platform").isEmpty ? nil : request.q("platform")

        let pullImages = images
        let progressStream = pullImages.pull(reference, platform: platform)
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let imageRef = reference
        let cache = self.readCache
        Task.detached(priority: .userInitiated) {
            do {
                for try await event in progressStream {
                    let line = PullProgressLine(status: event.line, id: imageRef)
                    if let data = try? JSONEncoder().encode(line) {
                        continuation.yield(data + Data("\n".utf8))
                    }
                }
            } catch {
                let line = PullProgressLine(status: "\(error)", id: imageRef, error: "\(error)")
                if let data = try? JSONEncoder().encode(line) {
                    continuation.yield(data + Data("\n".utf8))
                }
            }
            // Linear tail (not defer: await is illegal in defer bodies).
            // A finished pull changes the image set either way.
            await cache.invalidateImages()
            continuation.finish()
        }
        return .stream(200, [("Content-Type", "application/json")], stream)
    }

    struct PullProgressLine: Encodable {
        var status: String
        var id: String
        var progressDetail = [String: String]()
        var error: String?
    }

    private func imagesList(_ request: ShimRequest) async throws -> ShimResponse {
        let filters = request.filters()
        if filters.isEmpty, let body = await readCache.cachedBody("images") {
            return .json(200, body)
        }
        let list: [Micropod_V1_Image]
        if let cached = await readCache.cachedImages() {
            list = cached
        } else {
            let fresh = try await images.list()
            await readCache.storeImages(fresh)
            list = fresh
        }
        var summaries = list.map(DockerMapper.imageSummary)
        summaries = try summaries.filter { summary in
            try Self.matchesLabelFilters(
                filters, labels: summary.Labels,
                allowedKeys: ["label", "labels", "dangling", "reference", "until", "before", "since"])
        }
        let body = Self.encodeBody(summaries)
        if filters.isEmpty {
            await readCache.storeBody(body, for: "images")
        }
        return .json(200, body)
    }

    /// Shared label-filter evaluation. Rejects filter keys outside
    /// `allowedKeys` the way dockerd does — accepting unknown keys would make
    /// reapers (ryuk) match and delete everything.
    static func matchesLabelFilters(
        _ filters: [String: [String]], labels: [String: String],
        allowedKeys: Set<String>
    ) throws -> Bool {
        for (key, values) in filters {
            guard allowedKeys.contains(key) else {
                throw ShimError.badRequest("Invalid filter '\(key)'")
            }
            guard key == "label" || key == "labels" else { continue }
            for value in values {
                let parts = value.split(separator: "=", maxSplits: 1)
                let labelKey = String(parts[0])
                guard let actual = labels[labelKey] else { return false }
                if parts.count > 1, actual != String(parts[1]) { return false }
            }
        }
        return true
    }

    private func imageBuild(_ request: ShimRequest) async throws -> ShimResponse {
        // Docker API: POST /build?t=tag&dockerfile=Dockerfile&target=&platform=&nocache=0&buildargs={}&labels={}&...
        // Body is a tar context (optionally gzip). We extract to a temp dir and delegate to `container build`.
        if request.body.isEmpty {
            throw ShimError.badRequest("missing build context")
        }
        let tags: [String] = {
            // query map collapses repeated `t`; handle JSON-encoded list as well
            if let raw = request.query["t"] ?? request.query["tag"], !raw.isEmpty {
                if raw.hasPrefix("["), let data = raw.data(using: .utf8),
                    let arr = try? JSONDecoder().decode([String].self, from: data)
                {
                    return arr
                }
                return [raw]
            }
            return []
        }()
        let dockerfile = request.q("dockerfile").isEmpty ? nil : request.q("dockerfile")
        let target = request.q("target").isEmpty ? nil : request.q("target")
        let platform = request.q("platform").isEmpty ? nil : request.q("platform")
        let noCache = request.q("nocache") == "1" || request.q("nocache").lowercased() == "true"
        // buildargs is JSON dict string
        var buildArgs: [String] = []
        if let raw = request.query["buildargs"], !raw.isEmpty, let data = raw.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        {
            buildArgs = dict.map { "\($0.key)=\($0.value)" }
        }
        var labelSpecs: [LabelSpec] = []
        if let raw = request.query["labels"], !raw.isEmpty, let data = raw.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        {
            labelSpecs = dict.map { LabelSpec(key: $0.key, value: $0.value) }
        }
        // Create temp context — lifetime tied to the streaming Task, not the request scope.
        // Must live under $HOME: the container CLI's file provider silently drops
        // subdirectory contents for contexts outside the home tree.
        let buildsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".micropod/builds")
        try? FileManager.default.createDirectory(at: buildsRoot, withIntermediateDirectories: true)
        let tmpRoot = buildsRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let contextDir = tmpRoot.appendingPathComponent("context")
        try FileManager.default.createDirectory(at: contextDir, withIntermediateDirectories: true)
        // Detect gzip by magic bytes 1f 8b
        let isGzip: Bool = {
            if request.header("content-encoding").lowercased().contains("gzip") { return true }
            if request.body.count >= 2 && request.body[0] == 0x1F && request.body[1] == 0x8B { return true }
            return false
        }()
        let stageClock = ContinuousClock()
        let stageStart = stageClock.now
        // Content-addressed context cache: hash the tar's file tree
        // (paths + bytes, mtime-insensitive) and reuse a retained extraction
        // on hit. Gzip bodies skip the gate (would need inflating to hash)
        // but still get the streaming extract below.
        let manifest: (treeHash: String, files: [BuildFileEntry])? = {
            guard !isGzip else { return nil }
            return try? BuildContextHasher.treeManifest(tarData: request.body)
        }()
        let treeHash = manifest?.treeHash
        let cacheHit: Bool = await {
            guard let treeHash else { return false }
            return await self.buildCache.checkout(treeHash: treeHash, dest: contextDir)
        }()
        if cacheHit, let treeHash {
            let ms = stageElapsedMs(since: stageStart, clock: stageClock)
            fputs(
                "[shim] build context-cache HIT \(treeHash.prefix(12)) (\(request.body.count) tar bytes, gated in \(Int(ms))ms)\n",
                stderr)
            // Self-healing: entries retained before manifests existed gain
            // one now (the gate already hashed every file).
            await buildCache.ensureManifest(
                treeHash: treeHash, files: manifest?.files ?? [], tarBytes: request.body.count)
        } else {
            // Miss (or unhashable): stream the body straight into tar's
            // stdin — no intermediate context.tar disk write — then retain
            // the extraction for next time.
            do {
                try Self.extractTarStream(request.body, gzip: isGzip, dest: contextDir)
            } catch {
                throw ShimError.badRequest("failed to unpack build context: \(error)")
            }
            if let treeHash {
                await buildCache.store(
                    treeHash: treeHash, contextDir: contextDir, tarBytes: request.body.count,
                    files: manifest?.files ?? [])
            }
            let ms = stageElapsedMs(since: stageStart, clock: stageClock)
            fputs(
                "[shim] build context-cache MISS \(treeHash?.prefix(12) ?? "?") (\(request.body.count) tar bytes, staged in \(Int(ms))ms)\n",
                stderr)
        }
        // The Docker CLI already applied .dockerignore when creating the tar;
        // avoid a second filtering pass in the nested builder.
        try? FileManager.default.removeItem(at: contextDir.appendingPathComponent(".dockerignore"))
        // Resolve dockerfile to absolute path inside context (container build needs file existence check)
        let resolvedDockerfile: String? = {
            guard let df = dockerfile else { return nil }
            if df.hasPrefix("/") { return df }
            return contextDir.appendingPathComponent(df).path
        }()
        // Debug: list context
        fputs(
            "[shim] build tags=\(tags) dockerfile=\(String(describing: resolvedDockerfile)) context=\(contextDir.path) contents=\((try? FileManager.default.contentsOfDirectory(atPath: contextDir.path)) ?? [])\n",
            stderr)
        // `pull=1` forces a base-image refresh (Apple `--pull`); `memory`
        // is Docker's byte count, mapped to Apple's MiB-suffixed form;
        // `cpus`/`cpu_count` raise the builder allocation above the 2-CPU
        // default for heavy compiles (Go controlplane builds).
        let pullFlag = ["1", "true"].contains(request.q("pull").lowercased())
        let memorySpec: String? = {
            guard let bytes = UInt64(request.q("memory")), bytes > 0 else { return nil }
            return "\(max(1, bytes / (1024 * 1024)))MiB"
        }()
        let cpusSpec: Double? = {
            let raw = request.q("cpus").isEmpty ? request.q("cpu_count") : request.q("cpus")
            guard let cpus = Double(raw), cpus > 0 else { return nil }
            return cpus
        }()
        let buildReq = ContainerBuildRequest(
            contextDirectory: contextDir.path,
            dockerfile: resolvedDockerfile,
            tags: tags,
            buildArgs: buildArgs,
            target: target,
            platform: platform,
            noCache: noCache,
            cpus: cpusSpec,
            memory: memorySpec,
            pull: pullFlag,
            labels: labelSpecs)
        let progress = images.build(buildReq)
        let intoK8s = ["1", "true"].contains(request.q("k8s").lowercased())
        let (stream, cont) = AsyncStream<Data>.makeStream()
        let buildCache = self.buildCache
        let k8sService = self.k8s
        Task.detached(priority: .userInitiated) {
            @Sendable func emit(_ text: String) {
                if let data = try? JSONEncoder().encode(BuildStreamLine(stream: text + "\n")) {
                    cont.yield(data + Data("\n".utf8))
                }
            }
            do {
                for try await event in progress {
                    let line = BuildStreamLine(stream: event.line + "\n")
                    if let data = try? JSONEncoder().encode(line) {
                        cont.yield(data + Data("\n".utf8))
                    }
                }
                // Final aux with image ID if we can resolve it (best-effort)
                let aux: String? = {
                    if let tag = tags.first, !tag.isEmpty { return tag }
                    return nil
                }()
                if let aux {
                    let tail = BuildAuxLine(aux: ["ID": aux])
                    if let data = try? JSONEncoder().encode(tail) {
                        cont.yield(data + Data("\n".utf8))
                    }
                }
                // ?k8s=1 — docker build → cluster-ready in one request: each
                // tag is injected into the cluster's containerd.
                if intoK8s {
                    for tag in tags {
                        do {
                            _ = try await k8sService.loadImage(ref: tag) { emit($0) }
                            emit("loaded into k8s: \(tag)")
                        } catch {
                            emit("k8s inject failed for \(tag): \(error.localizedDescription)")
                        }
                    }
                }
            } catch {
                let line = BuildErrorLine(errorDetail: ["message": "\(error)"], error: "\(error)")
                if let data = try? JSONEncoder().encode(line) {
                    cont.yield(data + Data("\n".utf8))
                }
            }
            // Linear tail (not defer: await is illegal in defer bodies).
            // Runs on success, error, and stream-cancellation throws alike.
            if let treeHash { await buildCache.release(treeHash) }
            await self.readCache.invalidateImages()
            cont.finish()
            try? FileManager.default.removeItem(at: tmpRoot)
        }
        return .stream(200, [("Content-Type", "application/json")], stream)
    }

    /// Milliseconds from `start` to now (same components math as the bench
    /// harness).
    private func stageElapsedMs(since start: ContinuousClock.Instant, clock: ContinuousClock) -> Double {
        let elapsed = start.duration(to: clock.now)
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    /// Extract a tar (or gzip-tar) body straight into `dest` by piping it to
    /// `/usr/bin/tar`'s stdin — no intermediate `.tar` disk write. Throws on
    /// launch failure or non-zero tar exit (message carries tar's stderr).
    private static func extractTarStream(_ body: Data, gzip: Bool, dest: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        proc.arguments = gzip ? ["-xzf", "-", "-C", dest.path] : ["-xf", "-", "-C", dest.path]
        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = stderrPipe
        do {
            try proc.run()
        } catch {
            throw ShimError.badRequest("failed to launch tar: \(error)")
        }
        do {
            // tar drains the pipe concurrently, so a single blocking write
            // cannot deadlock; closing delivers EOF so tar can finish.
            try stdinPipe.fileHandleForWriting.write(contentsOf: body)
            try stdinPipe.fileHandleForWriting.close()
        } catch {
            // tar died mid-stream (e.g. corrupt header): surface its stderr.
            if proc.isRunning { proc.terminate() }
            proc.waitUntilExit()
            throw tarError(stderrPipe)
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw tarError(stderrPipe) }
    }

    private static func tarError(_ stderrPipe: Pipe) -> ShimError {
        let raw =
            String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .badRequest("failed to unpack build context: \(raw.isEmpty ? "unknown tar error" : raw)")
    }

    struct BuildStreamLine: Encodable { var stream: String }
    struct BuildAuxLine: Encodable { var aux: [String: String] }
    struct BuildErrorLine: Encodable {
        var errorDetail: [String: String]
        var error: String
    }

    private func buildPrune(_ request: ShimRequest) async throws -> ShimResponse {
        _ = request
        struct Prune: Encodable {
            var ImagesDeleted: [String] = []
            var SpaceReclaimed: Int = 0
        }
        return Self.encode(Prune())
    }

    private func imageInspect(_ reference: String) async throws -> ShimResponse {
        let data: Data
        do {
            data = try await images.inspect(reference)
        } catch {
            // Docker reports a missing image as 404 "No such image" (not a
            // 500): clients key pull-on-demand flows off exactly this shape
            // (testcontainers-go's Ryuk bootstrap being one).
            if Self.isNotFound(error) {
                throw ShimError.notFound("No such image: \(reference)")
            }
            throw error
        }
        guard let mapped = DockerMapper.dockerImageInspect(fromRaw: data, reference: reference) else {
            throw ShimError.notFound("No such image: \(reference)")
        }
        return .raw(200, [("Content-Type", "application/json")], mapped)
    }

    private func imageDelete(_ reference: String, _ request: ShimRequest) async throws -> ShimResponse {
        try await images.delete(
            reference, force: request.q("force").lowercased() == "1" || request.q("force").lowercased() == "true")
        await readCache.invalidateImages()
        return Self.encode([["Untagged": reference, "Deleted": reference]])
    }

    private func imageTag(_ source: String, _ request: ShimRequest) async throws -> ShimResponse {
        let repo = request.q("repo")
        let tag = request.q("tag")
        let target = tag.isEmpty ? repo : "\(repo):\(tag)"
        guard !repo.isEmpty else { throw ShimError.badRequest("missing repo parameter") }
        try await images.tag(source: source, target: target)
        await readCache.invalidateImages()
        return .status(201)
    }

    /// POST /images/load — `docker load` compat: tar body → `container image
    /// load`. `?k8s=1` additionally injects the archive into the k8s cluster's
    /// containerd — `docker load -i x.tar` becomes cluster-ready in one call.
    /// Response is Docker's JSONL progress shape ({"stream": ...} lines).
    private func imageLoad(_ request: ShimRequest) async throws -> ShimResponse {
        guard !request.body.isEmpty else { throw ShimError.badRequest("missing image tar body") }
        // Stage under $HOME — the image store can't read /var/folders.
        let stageDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".micropod/loads")
        try? FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
        let tmp =
            stageDir
            .appendingPathComponent("\(UUID().uuidString).tar")
        do {
            try request.body.write(to: tmp)
        } catch {
            throw ShimError.internalError("could not stage image tar: \(error)")
        }
        // Cleanup lives inside the task — the file must outlive the request.
        let (stream, cont) = AsyncStream<Data>.makeStream()
        let intoK8s = ["1", "true"].contains(request.q("k8s").lowercased())
        Task.detached(priority: .userInitiated) {
            defer { try? FileManager.default.removeItem(at: tmp) }
            @Sendable func emit(_ line: String) {
                if let data = try? JSONEncoder().encode(BuildStreamLine(stream: line + "\n")) {
                    cont.yield(data + Data("\n".utf8))
                }
            }
            do {
                try await self.images.load(from: tmp.path)
                emit("Loaded image archive")
                await self.readCache.invalidateImages()
                if intoK8s {
                    guard self.k8s.isEnabled else {
                        emit("k8s engine not enabled — `micropod k8s enable` first")
                        cont.finish()
                        return
                    }
                    emit("injecting into k8s cluster containerd…")
                    do {
                        let loaded = try await self.k8s.loadImage(archivePath: tmp) {
                            emit($0)
                        }
                        emit("loaded into k8s: \(loaded.ref) (\(loaded.bytes) bytes)")
                    } catch {
                        emit("k8s inject failed: \(error.localizedDescription)")
                    }
                }
                cont.finish()
            } catch {
                let line = BuildErrorLine(errorDetail: ["message": "\(error)"], error: "\(error)")
                if let data = try? JSONEncoder().encode(line) {
                    cont.yield(data + Data("\n".utf8))
                }
                cont.finish()
            }
        }
        return .stream(200, [("Content-Type", "application/json")], stream)
    }

    /// GET /images/get?names=… — docker CLI's save form. `names` arrives as a
    /// JSON array (docker) or a single name; `container image save` accepts
    /// multiple refs into one archive.
    private func imageGetMulti(_ request: ShimRequest) async throws -> ShimResponse {
        let raw = request.q("names")
        let names: [String] = {
            if raw.hasPrefix("["), let data = raw.data(using: .utf8),
                let arr = try? JSONDecoder().decode([String].self, from: data)
            {
                return arr
            }
            return raw.isEmpty ? [] : [raw]
        }()
        guard !names.isEmpty else { throw ShimError.badRequest("missing names parameter") }
        let stageDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".micropod/loads")
        try? FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
        let tmp = stageDir.appendingPathComponent("\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try await images.saveAll(names, to: tmp.path)
        } catch {
            if Self.isNotFound(error) {
                throw ShimError.notFound("No such image: \(names.first ?? "")")
            }
            throw error
        }
        guard let data = try? Data(contentsOf: tmp) else {
            throw ShimError.internalError("image save produced no output")
        }
        return .raw(200, [("Content-Type", "application/x-tar")], data)
    }

    /// GET /images/{name}/get — `docker save` compat: stream the OCI tar.
    private func imageGet(_ reference: String) async throws -> ShimResponse {
        let stageDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".micropod/loads")
        try? FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
        let tmp =
            stageDir
            .appendingPathComponent("\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try await images.save(reference, to: tmp.path)
        } catch {
            if Self.isNotFound(error) {
                throw ShimError.notFound("No such image: \(reference)")
            }
            throw error
        }
        guard let data = try? Data(contentsOf: tmp) else {
            throw ShimError.internalError("image save produced no output")
        }
        return .raw(200, [("Content-Type", "application/x-tar")], data)
    }

    /// POST /images/{name}/push — `docker push` compat: forward to
    /// `container image push`; emits Docker's JSONL status shape.
    private func imagePush(_ reference: String) async throws -> ShimResponse {
        let (stream, cont) = AsyncStream<Data>.makeStream()
        Task.detached(priority: .userInitiated) {
            @Sendable func emit(_ line: String) {
                if let data = try? JSONEncoder().encode(BuildStreamLine(stream: line + "\n")) {
                    cont.yield(data + Data("\n".utf8))
                }
            }
            do {
                for try await event in self.images.push(reference, platform: nil) {
                    emit(event.line)
                }
                emit("pushed \(reference)")
                cont.finish()
            } catch {
                let line = BuildErrorLine(errorDetail: ["message": "\(error)"], error: "\(error)")
                if let data = try? JSONEncoder().encode(line) {
                    cont.yield(data + Data("\n".utf8))
                }
                cont.finish()
            }
        }
        return .stream(200, [("Content-Type", "application/json")], stream)
    }

    private func imagePrune(_ request: ShimRequest) async throws -> ShimResponse {
        let all = request.q("all").lowercased() == "1" || request.q("all").lowercased() == "true"
        let before = try await images.list()
        let reclaimable =
            try await UsageService(
                containers: containers, images: images, volumes: volumes
            ).report().reclaimableImageBytes
        _ = try await images.prune(danglingOnly: !all)
        await readCache.invalidateImages()
        let after = try await images.list()
        let afterIDs = Set(after.map { $0.id })
        let deleted = before.filter { !afterIDs.contains($0.id) }
        return Self.encode(
            PruneResponse(
                deletedNames: deleted.flatMap { $0.names.isEmpty ? [$0.id] : $0.names },
                spaceReclaimed: Int(
                    all
                        ? reclaimable
                        : deleted.reduce(0) { $0 + $1.sizeBytes })))
    }

    struct PruneResponse: Encodable {
        var ImagesDeleted: [ImageDeleteResult]
        var SpaceReclaimed: Int

        init(deletedNames: [String], spaceReclaimed: Int) {
            ImagesDeleted = deletedNames.map { ImageDeleteResult(Deleted: $0) }
            self.SpaceReclaimed = spaceReclaimed
        }
    }

    struct ImageDeleteResult: Encodable {
        var Untagged: String?
        var Deleted: String?
    }

    // MARK: - Container handlers

    // MARK: - System handlers

    private func usage() -> UsageService {
        UsageService(containers: containers, images: images, volumes: volumes)
    }

    /// GET /system/df — docker-shaped usage report with in-use counts.
    private func systemDF() async throws -> ShimResponse {
        async let listedContainers = cachedContainersList()
        async let listedImages = cachedImagesList()
        async let listedVolumes = cachedVolumesList()
        let report = try await usage().report(
            prefetchedContainers: listedContainers,
            prefetchedImages: listedImages,
            prefetchedVolumes: listedVolumes)
        let df = DockerSystemDF(
            LayersSize: 0,
            Images: report.images.map { usage in
                var summary = DockerMapper.imageSummary(usage.image)
                summary.Containers = usage.usedByContainerIDs.count
                return summary
            },
            Containers: report.containers.map { usage in
                var summary = DockerMapper.summary(usage.container, create: nil)
                summary.SizeRw = 0
                return summary
            },
            Volumes: report.volumes.map { usage in
                var resource = Self.volumeResource(usage.volume)
                resource.UsageData = DockerVolume.UsageData(
                    Size: Int64(usage.volume.sizeBytes),
                    RefCount: Int64(usage.usedByContainerIDs.count))
                return resource
            },
            BuildCache: [])
        return Self.encode(df)
    }

    struct DockerSystemDF: Encodable {
        var LayersSize: Int
        var Images: [DockerImageSummary]
        var Containers: [DockerContainerSummary]
        var Volumes: [DockerVolume]
        var BuildCache: [String]
    }

    /// POST /system/prune — stopped containers + dangling (or, with all=1 /
    /// filters, all unused) images + unused volumes + unused networks,
    /// with honest deletion reporting via before/after diffs.
    private func systemPrune(_ request: ShimRequest) async throws -> ShimResponse {
        let wantsAll =
            request.q("all").lowercased() == "1"
            || request.q("all").lowercased() == "true"

        // Containers: pruned = stopped ones (docker semantics).
        let containersBefore = try await containers.list()
        let stopped = containersBefore.filter { DockerMapper.stateName($0.state) != "running" }
        var containersDeleted: [String] = []
        for container in stopped {
            if (try? await containers.delete(container.id, force: true)) != nil {
                containersDeleted.append(container.id)
            }
        }

        // Images: dangling, or everything unused with all=1.
        let imagesBefore = try await images.list()
        let reclaimable = try await usage().report().reclaimableImageBytes
        _ = try? await images.prune(danglingOnly: !wantsAll)
        let imagesAfter = try await images.list()
        let imageIDsAfter = Set(imagesAfter.map { $0.id })
        let imagesDeleted = imagesBefore.filter { !imageIDsAfter.contains($0.id) }

        // Volumes.
        let volumesBefore = try await volumes.list()
        _ = try? await volumes.prune()
        let volumesAfter = try await volumes.list()
        await readCache.invalidateContainers()
        await readCache.invalidateImages()
        await readCache.invalidateVolumes()
        let volumeIDsAfter = Set(volumesAfter.map { $0.id })
        let volumesDeleted = volumesBefore.filter { !volumeIDsAfter.contains($0.id) }

        return Self.encode(
            SystemPruneResponse(
                containersDeleted: containersDeleted,
                imagesDeleted: imagesDeleted.flatMap { image in
                    let names = image.names.isEmpty ? [image.id] : image.names
                    return names.map { ImageDeleteResult(Untagged: $0, Deleted: image.id) }
                },
                volumesDeleted: volumesDeleted.map { $0.id },
                spaceReclaimed: Int(
                    (wantsAll ? reclaimable : imagesDeleted.reduce(0) { $0 + $1.sizeBytes })
                        + volumesDeleted.reduce(0) { $0 + $1.sizeBytes })))
    }

    struct SystemPruneResponse: Encodable {
        var ContainersDeleted: [String]
        var ImagesDeleted: [ImageDeleteResult]
        var VolumesDeleted: [String]
        var NetworksDeleted: [String]
        var SpaceReclaimed: Int

        init(
            containersDeleted: [String],
            imagesDeleted: [ImageDeleteResult],
            volumesDeleted: [String],
            spaceReclaimed: Int
        ) {
            self.ContainersDeleted = containersDeleted
            self.ImagesDeleted = imagesDeleted
            self.VolumesDeleted = volumesDeleted
            self.NetworksDeleted = []
            self.SpaceReclaimed = spaceReclaimed
        }
    }

    private func containersList(_ request: ShimRequest) async throws -> ShimResponse {
        let all = request.q("all").lowercased() == "1" || request.q("all").lowercased() == "true"
        let filters = request.filters()
        // Encoded-body fast path for the hottest query shape (filter-less
        // polls from compose, `docker ps`, MCP): skips map+encode entirely.
        if filters.isEmpty {
            let key = "containers:\(all)"
            if let body = await readCache.cachedBody(key) {
                return .json(200, body)
            }
        }
        // Read-through cache: filters apply identically on hits and misses
        // (only full results are ever cached).
        let list: [Micropod_V1_Container]
        if let cached = await readCache.cachedList() {
            list = cached
        } else {
            let fresh = try await containers.list()
            await readCache.storeList(fresh)
            list = fresh
        }
        var summaries = list.map {
            DockerMapper.summary($0, create: nil)
        }
        summaries = try summaries.enumerated().filter { index, summary in
            let raw = list[index]
            if !all && DockerMapper.stateName(raw.state) != "running" { return false }
            return try Self.matchesFilters(filters, summary: summary, container: raw)
        }.map { $0.element }
        if !filters.isEmpty {
            fputs(
                "[shim] list filters=\(filters) -> \(summaries.map { $0.Names.first ?? $0.Id })\n",
                stderr)
        }
        let body = Self.encodeBody(summaries)
        if filters.isEmpty {
            await readCache.storeBody(body, for: "containers:\(all)")
        }
        return .json(200, body)
    }

    static func matchesFilters(
        _ filters: [String: [String]], summary: DockerContainerSummary,
        container: Micropod_V1_Container
    ) throws -> Bool {
        let ok = try Self.matchesLabelFilters(
            filters, labels: summary.Labels,
            allowedKeys: [
                "label", "labels", "name", "id", "status", "ancestor", "before", "since",
                "volume", "network", "expose", "publish", "health", "isolation", "dangling",
            ])
        if !ok { return false }
        for (key, values) in filters {
            switch key {
            case "name":
                if !values.contains(where: { summary.Id.contains($0) }) { return false }
            case "id":
                if !values.contains(where: { summary.Id.hasPrefix($0) }) { return false }
            case "status":
                if !values.contains(summary.State) { return false }
            default:
                break
            }
            _ = container
        }
        return true
    }

    private func containerCreate(_ request: ShimRequest) async throws -> ShimResponse {
        var body = try decodeBody(DockerCreateRequest.self, request)
        // Docker-socket redirect (Ryuk reaper + any DinD client such as the
        // cuttlefish runner): strip the unusable virtiofs socket bind and
        // point the container at the shim's TCP listener over the VM bridge.
        // No-op when there is no socket bind and the image is not Ryuk.
        let intercepted = RyukSupport.intercept(
            body, bridgeHost: config.bridgeHost, tcpPort: config.tcpPort)
        body = intercepted.request
        var notes = intercepted.notes

        let requestedName = request.q("name").isEmpty ? nil : request.q("name")
        // The Apple runtime rejects names Docker accepts (>63 bytes,
        // leading _). Sanitize deterministically and alias requested →
        // runtime in state, so later lookups by Docker name keep working.
        let runtimeName: String?
        if let requestedName {
            if let tracked = await state.id(forName: requestedName) {
                // Fast path, verified: state can go stale when containers
                // vanish behind the shim's back (direct CLI deletes, VM
                // resets). Confirm with one list call on this rare path —
                // fresh names still cost zero CLI round-trips — and forget
                // ghosts instead of 409ing a free name. The CLI remains the
                // final arbiter via the conflict-error mapping below.
                let alive = (try? await containers.list())?.contains { $0.id == tracked }
                if alive == true {
                    throw ShimError.conflict(
                        "Conflict. The container name \"/\(requestedName)\" is already in use")
                }
                await state.forget(id: tracked)
            }
            let mapping = DockerNaming.runtimeName(for: requestedName)
            runtimeName = mapping.name
            if mapping.aliased {
                notes.append("aliased name \(requestedName) -> \(mapping.name) (runtime limit)")
            }
        } else {
            runtimeName = nil
        }
        // Synchronized file shares: rewrite directory binds through the
        // shared-fs daemon when available (APFS clonefile cache + FSEvents
        // invalidation). Per-container views are tracked for unmount on delete.
        // Well-known cache paths are auto-shared; explicit shared:false or sharedMounts
        // via labels overrides (see Router.isWellKnown / shouldUseSharedView).
        var sharedViewIDs: [ViewID] = []
        if let sharedFS, let binds = body.HostConfig?.Binds, !binds.isEmpty {
            let translated = await translateBindsForSharedFS(binds, request: body, sharedFS: sharedFS)
            if translated.binds != binds {
                body.HostConfig?.Binds = translated.binds
                sharedViewIDs = translated.viewIDs
                if !sharedViewIDs.isEmpty {
                    fputs(
                        "[shim] shared mounts for \(requestedName ?? "<unnamed>"): \(sharedViewIDs.map { $0.value }.joined(separator: ","))\n",
                        stderr)
                }
            }
        }
        let runRequest = try Self.buildRunRequest(
            from: body, name: runtimeName,
            platform: request.q("platform").isEmpty ? nil : request.q("platform"))
        // Managed hosts files must exist before the build below binds them.
        HostsFile.ensure(networks: body.attachedNetworks)
        let id: String
        do {
            id = try await containers.create(runRequest)
        } catch let error as MicropodError {
            // The pre-create check above only covers names this shim tracks;
            // a name created outside the shim surfaces here as a CLI failure.
            if case .cliFailure(_, _, let stderr) = error {
                let text = stderr.lowercased()
                if text.contains("already exists") || text.contains("already in use")
                    || text.contains("already taken") || text.contains("conflict")
                    || text.contains("duplicate")
                {
                    throw ShimError.conflict(
                        "Conflict. The container name \"/\(requestedName ?? "")\" is already in use")
                }
            }
            throw error
        }
        await state.remember(id: id, name: requestedName, request: body)
        await readCache.invalidateContainers()
        if !sharedViewIDs.isEmpty {
            await state.rememberSharedViews(containerID: id, views: sharedViewIDs)
        }
        let response = DockerCreateResponse(Id: id, Warnings: [])
        if !notes.isEmpty {
            fputs("[shim] docker-sock intercept for \(id): \(notes.joined(separator: "; "))\n", stderr)
        }
        return .json(201, Self.encodeBody(response))
    }

    private func translateBindsForSharedFS(
        _ binds: [String], request: DockerCreateRequest, sharedFS: any SharedFSClient
    ) async -> (binds: [String], viewIDs: [ViewID]) {
        var result: [String] = []
        var viewIDs: [ViewID] = []
        for bind in binds {
            // Bind format host:container[:options] — host is an absolute path on macOS.
            let parts = bind.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else {
                result.append(bind)
                continue
            }
            let hostPath = parts[0]
            let containerPath = parts[1]
            let options = parts.count > 2 ? parts[2...].joined(separator: ":") : ""
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: hostPath, isDirectory: &isDir),
                isDir.boolValue
            else {
                result.append(bind)
                continue
            }
            // Well-known auto-detect + explicit shared / sharedMounts handling.
            guard Self.shouldUseSharedView(containerPath, request: request) else {
                result.append(bind)
                continue
            }
            do {
                let liveShared = ProcessInfo.processInfo.environment["MICROPOD_SHAREDFS_LIVE"] != "0"
                let info: MountInfo
                if liveShared {
                    // Live shared view: all containers sharing the same host dir
                    // see each other's writes via the single shared view + FSEvents.
                    // Falls back to per-container isolated view on error.
                    do {
                        info = try await sharedFS.mountShared(
                            src: URL(fileURLWithPath: hostPath),
                            readonly: options.contains("ro"))
                    } catch {
                        info = try await sharedFS.mount(
                            src: URL(fileURLWithPath: hostPath),
                            readonly: options.contains("ro"))
                    }
                } else {
                    info = try await sharedFS.mount(
                        src: URL(fileURLWithPath: hostPath),
                        readonly: options.contains("ro"))
                }
                viewIDs.append(info.id)
                let newBind =
                    options.isEmpty
                    ? "\(info.viewPath):\(containerPath)"
                    : "\(info.viewPath):\(containerPath):\(options)"
                result.append(newBind)
            } catch {
                fputs("[shim] shared mount failed for \(hostPath): \(error)\n", stderr)
                result.append(bind)
            }
        }
        return (result, viewIDs)
    }

    // Backwards compat for any external callers that only pass binds.
    private func translateBindsForSharedFS(
        _ binds: [String], sharedFS: any SharedFSClient
    ) async -> (binds: [String], viewIDs: [ViewID]) {
        let emptyRequest = DockerCreateRequest(Image: "")
        return await translateBindsForSharedFS(binds, request: emptyRequest, sharedFS: sharedFS)
    }

    static func buildRunRequest(
        from body: DockerCreateRequest, name: String?, platform: String? = nil
    ) throws -> ContainerRunRequest {
        var publishedPorts = [PortSpec]()
        let portBindings = body.HostConfig?.PortBindings ?? [:]
        for (key, bindingsForPort) in portBindings {
            let parts = key.split(separator: "/")
            guard let containerPort = Int(parts[0]) else {
                throw ShimError.badRequest("invalid port key: \(key)")
            }
            let proto = parts.count > 1 ? String(parts[1]) : "tcp"
            let effectiveBindings = bindingsForPort.isEmpty ? [DockerPortBinding()] : bindingsForPort
            for binding in effectiveBindings {
                let hostPort: Int
                if let specified = binding.HostPort.flatMap(Int.init), specified > 0 {
                    hostPort = specified
                } else {
                    hostPort = freePort()
                    guard hostPort > 0 else {
                        throw ShimError.internalError("could not allocate ephemeral port")
                    }
                }
                publishedPorts.append(
                    PortSpec(
                        hostPort: hostPort, containerPort: containerPort,
                        transportProtocol: proto,
                        hostIP: binding.HostIp))
            }
        }

        let attachNetworks = body.attachedNetworks

        // Managed /etc/hosts (name DNS for custom networks, which serve no
        // container-name records): bind each attached network's hosts file
        // read-only unless the client already binds /etc/hosts itself.
        // Files are ensured beforehand (containerCreate) and refreshed by
        // the events loop as membership changes.
        var binds = body.HostConfig?.Binds ?? []
        let bindsEtcHosts = binds.contains { bind in
            bind.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                .dropFirst().first == "/etc/hosts"
        }
        if !bindsEtcHosts {
            for network in attachNetworks {
                binds.append("\(HostsFile.path(for: network).path):/etc/hosts:ro")
            }
        }

        let memory: String?
        if let memBytes = body.HostConfig?.Memory, memBytes > 0 {
            let mib = memBytes / (1024 * 1024)
            memory = "\(mib)MiB"
        } else {
            memory = nil
        }

        // CPU quota: Docker NanoCpus (billionths) → Apple --cpus float.
        // Previously dropped entirely, so container CPU limits were silently
        // ignored (every container got the 4-CPU default).
        let cpus: Double? = {
            guard let nano = body.HostConfig?.NanoCpus, nano > 0 else { return nil }
            return Double(nano) / 1_000_000_000
        }()

        // Shared memory: Docker bytes → Apple size string. Previously
        // dropped, leaving the 64M default (browser/e2e OOM territory).
        let shmSize: String? = {
            guard let bytes = body.HostConfig?.ShmSize, bytes > 0 else { return nil }
            return "\(max(1, bytes / (1024 * 1024)))MiB"
        }()

        // tmpfs: Docker map path → options; Apple takes bare paths only
        // (verified: the `path,opts` form is silently ignored). Mounts are
        // always honored; per-mount options have no Apple equivalent.
        let tmpfs = (body.HostConfig?.Tmpfs ?? [:]).keys.filter { !$0.isEmpty }.sorted()

        let dns = (body.HostConfig?.Dns ?? []).filter { !$0.isEmpty }
        let dnsSearch = (body.HostConfig?.DnsSearch ?? []).filter { !$0.isEmpty }

        // Ulimits: Docker {Name, Soft, Hard} → Apple `<type>=<soft>[:<hard>]`.
        // Negative (unlimited) bounds have no Apple spelling — skipped.
        let ulimits: [String] = (body.HostConfig?.Ulimits ?? []).compactMap { limit in
            guard !limit.Name.isEmpty, limit.Soft >= 0 else { return nil }
            if limit.Hard >= 0, limit.Hard != limit.Soft {
                return "\(limit.Name)=\(limit.Soft):\(limit.Hard)"
            }
            return "\(limit.Name)=\(limit.Soft)"
        }

        // Entrypoint: Docker list replaces the image ENTRYPOINT, Cmd becomes
        // its args; Apple takes ONE executable plus argument list. The old
        // space-join broke every multi-element entrypoint ("failed to find
        // target executable 'sh -c ...'" — Apple never splits or shells it,
        // verified 2026-09-09): split head from tail instead.
        let entryParts = body.Entrypoint ?? []
        let hasEntrypoint = !entryParts.isEmpty && !(entryParts.count == 1 && entryParts[0].isEmpty)
        let entrypoint: String? = hasEntrypoint ? entryParts[0] : nil
        var arguments = hasEntrypoint ? Array(entryParts.dropFirst()) : []
        arguments += body.Cmd ?? []

        return ContainerRunRequest(
            image: body.Image,
            name: name,
            detach: true,
            cpus: cpus,
            memory: memory,
            env: body.Env ?? [],
            envFiles: [],
            publishedPorts: publishedPorts,
            volumes: binds,
            tmpfs: tmpfs,
            labels: (body.Labels ?? [:]).map { LabelSpec(key: $0.key, value: $0.value) },
            interactive: body.OpenStdin == true,
            tty: body.Tty == true,
            useInit: body.HostConfig?.Init == true,
            readOnly: body.HostConfig?.ReadonlyRootfs == true,
            rosetta: false,
            // Docker clients serialize zero values ("User": "") — never emit
            // empty CLI flags from them.
            user: (body.User?.isEmpty == false) ? body.User : nil,
            shmSize: shmSize,
            dns: dns,
            dnsSearch: dnsSearch,
            capAdd: body.HostConfig?.CapAdd ?? [],
            capDrop: body.HostConfig?.CapDrop ?? [],
            ulimits: ulimits,
            networks: attachNetworks,
            platform: (platform?.isEmpty == false) ? platform : nil,
            workdir: (body.WorkingDir?.isEmpty == false) ? body.WorkingDir : nil,
            entrypoint: entrypoint,
            arguments: arguments)
    }

    private func containersPrune() async throws -> ShimResponse {
        let before = try await containers.list()
        _ = try await containers.prune()
        let after = try await containers.list()
        let afterIDs = Set(after.map { $0.id })
        let deleted = before.filter { !afterIDs.contains($0.id) }
        return Self.encode(ContainersPruneResponse(deletedIDs: deleted.map { $0.id }))
    }

    struct ContainersPruneResponse: Encodable {
        var ContainersDeleted: [String]
        var SpaceReclaimed: Int

        init(deletedIDs: [String]) {
            self.ContainersDeleted = deletedIDs
            self.SpaceReclaimed = 0
        }
    }

    private func healthView(for id: String) async -> ShimHealthView? {
        guard let status = await state.healthStatus(id: id) else { return nil }
        return ShimHealthView(
            status: status.status, failingStreak: status.failingStreak,
            log: status.log.map { ($0.startedAt, $0.exitCode, $0.output) })
    }

    private func containerInspect(_ id: String) async throws -> ShimResponse {
        // Fast path: single-container inspect (flat cost) + persisted create
        // body instead of enumerating every container via list. The per-id
        // cache (populated by every list/inspect) serves warm lookups in
        // microseconds — inspect is the most-polled route after list.
        if let target = await passThroughID(id) {
            if let cached = await readCache.cachedInspect(id: target) {
                let create = await state.createRequest(for: cached.id)
                let health = await healthView(for: cached.id)
                return Self.encode(DockerMapper.inspect(cached, create: create, health: health))
            }
            if let raw = try? await containers.inspect(target),
                let container = DockerMapper.container(fromRawInspect: raw)
            {
                await readCache.storeInspect(container)
                let create = await state.createRequest(for: container.id)
                let health = await healthView(for: container.id)
                return Self.encode(DockerMapper.inspect(container, create: create, health: health))
            }
        }
        // Warm path: resolve against the cached list (no CLI when warm).
        // A stale hit can only 404 a deleted container or show last poll's
        // state; mutations never consult it.
        if let cached = await readCache.cachedList(),
            let container = try? Self.resolve(id, in: cached)
        {
            let create = await state.createRequest(for: container.id)
            let health = await healthView(for: container.id)
            return Self.encode(DockerMapper.inspect(container, create: create, health: health))
        }
        let container = try await resolveContainer(id)
        let create = await state.createRequest(for: container.id)
        let health = await healthView(for: container.id)
        return Self.encode(DockerMapper.inspect(container, create: create, health: health))
    }

    private enum ContainerLifecycle { case start, restart, kill }

    /// Full UUIDs and refs this shim issued pass straight to the CLI (which
    /// accepts ids and names natively); only docker-style ambiguous prefixes
    /// pay the list round-trip in resolveContainer.
    private func passThroughID(_ ref: String) async -> String? {
        if let named = await state.id(forName: ref) { return named }
        if await state.createRequest(for: ref) != nil { return ref }
        if ref.count == 36, ref.filter({ $0 == "-" }).count == 4,
            ref.allSatisfy({ $0 == "-" || $0.isHexDigit })
        {
            return ref
        }
        return nil
    }

    /// Resolves a reference to a container id without a full list scan when
    /// possible (logs/exec/wait/archive/stats don't need the record itself).
    /// Read-only callers only — mutations resolve against a fresh list.
    private func resolveID(_ ref: String) async throws -> String {
        if let fast = await passThroughID(ref) { return fast }
        if let cached = await readCache.cachedList(),
            let hit = try? Self.resolve(ref, in: cached)
        {
            return hit.id
        }
        return try await resolveContainer(ref).id
    }

    static func isNotFound(_ error: Error) -> Bool {
        if case MicropodError.cliFailure(_, _, let stderr) = error {
            let text = stderr.lowercased()
            // Covers the real CLI ("image not found: …", "container … not
            // found") and the mock ("no such image/container: …").
            return text.contains("not found") || text.contains("no such container")
                || text.contains("no such image")
        }
        return false
    }

    /// Docker returns from `stop` when the process dies; the Apple runtime
    /// burns the full grace unconditionally — and SIGTERM can never be
    /// delivered on runtime 1.2.2 (`kill --signal TERM` is a no-op, and
    /// PID 1's signals are shielded even from inside the container), so no
    /// container can exit early anyway. Waiting the grace buys nothing:
    /// stop is executed as the runtime's atomic instant-stop, tracked as an
    /// in-flight task so rm/restart never race it.
    private func fastStop(_ target: String, timeout grace: Int) async throws {
        _ = grace
        await state.awaitStop(target)

        let clock = ContinuousClock()
        let inspectStart = clock.now
        if let raw = try? await containers.inspect(target),
            let container = DockerMapper.container(fromRawInspect: raw),
            DockerMapper.stateName(container.state) != "running"
        {
            return  // already stopped (docker-idiomatic 204/304 handling upstream)
        }
        let inspectElapsed = inspectStart.duration(to: clock.now)

        await state.noteIntentionalStop(target)
        let state = self.state
        let task = Task {
            do {
                try await containers.stop(target, timeout: 0)
                await state.finishStopTask(target, error: nil)
            } catch {
                let text = "\(error)"
                await state.finishStopTask(
                    target, error: Self.isNotFound(error) ? nil : text)
            }
        }
        await state.setStopTask(target, task)
        _ = await task.value
        let stopElapsed = inspectStart.duration(to: clock.now)
        // Observability for the intermittent slow stop (~3s, ~1 in 10 under
        // concurrent load): split inspect vs stop CLI so the next occurrence
        // attributes to the runtime call rather than shim bookkeeping.
        if stopElapsed.components.seconds >= 1 {
            let inspectMs =
                Double(inspectElapsed.components.seconds) * 1000
                + Double(inspectElapsed.components.attoseconds) / 1e15
            let totalMs =
                Double(stopElapsed.components.seconds) * 1000
                + Double(stopElapsed.components.attoseconds) / 1e15
            fputs(
                "[shim] slow stop \(target): total \(Int(totalMs))ms (inspect \(Int(inspectMs))ms)\n",
                stderr)
        }
        if let failure = await state.stopError(for: target) {
            await state.finishStopTask(target, error: nil)
            throw ShimError.internalError("stop failed: \(failure)")
        }
    }

    private func containerAction(_ action: ContainerLifecycle, _ id: String) async throws
        -> ShimResponse
    {
        if let target = await passThroughID(id) {
            do {
                switch action {
                case .start:
                    await state.clearIntentionalStop(target)
                    try await startPossiblyAttached(target)
                case .restart:
                    try await fastStop(target, timeout: 10)
                    await state.clearIntentionalStop(target)
                    try await containers.start(target)
                case .kill:
                    await state.clearIntentionalStop(target)
                    try await containers.kill(target, signal: "KILL")
                }
                await readCache.invalidateContainers()
                return .status(204)
            } catch {
                if Self.isNotFound(error) { throw ShimError.notFound("No such container: \(id)") }
                throw error
            }
        }
        let resolved = try await resolveContainer(id).id
        switch action {
        case .start:
            await state.clearIntentionalStop(resolved)
            try await startPossiblyAttached(resolved)
        case .restart:
            try await fastStop(resolved, timeout: 10)
            await state.clearIntentionalStop(resolved)
            try await containers.start(resolved)
        case .kill:
            await state.clearIntentionalStop(resolved)
            try await containers.kill(resolved, signal: "KILL")
        }
        await readCache.invalidateContainers()
        return .status(204)
    }

    private func containerStop(_ id: String, _ request: ShimRequest) async throws -> ShimResponse {
        let timeout = Int(request.q("t")) ?? 10
        if let target = await passThroughID(id) {
            try await fastStop(target, timeout: timeout)
            await readCache.invalidateContainers()
            return .status(204)
        }
        let container = try await resolveContainer(id)
        guard DockerMapper.stateName(container.state) != "exited" else { return .status(304) }
        try await fastStop(container.id, timeout: timeout)
        await readCache.invalidateContainers()
        return .status(204)
    }

    /// POST /containers/{id}/rename?name= — the Apple runtime has no rename
    /// primitive, so renames are state aliases (the runtime id never moves).
    /// This is exactly what `docker compose up` recreate needs: it stops +
    /// removes the old container itself, renames the temp replacement to the
    /// canonical name, starts it, then removes the temp name. The abandoned
    /// temp name is tombstoned so that final removal is idempotent instead
    /// of 404. Deleting inside rename would destroy replacements-in-progress
    /// (a stopped temp container is indistinguishable from debris), so
    /// rename NEVER deletes — like Docker, which also keeps serving the
    /// container under its new name while it runs.
    private func containerRename(_ id: String, _ request: ShimRequest) async throws -> ShimResponse {
        var newName = request.q("name")
        if newName.hasPrefix("/") { newName = String(newName.dropFirst()) }
        guard !newName.isEmpty else { throw ShimError.badRequest("rename requires ?name=") }
        // Resolve the target and verify it exists: state can hold ghosts
        // (deleted behind our back), which must 404 like Docker — and the
        // stale entry self-heals instead of shadowing a future container.
        // Rename-to-self (by request string, runtime id, or tracked alias)
        // is a no-op success and must never delete.
        let target: String
        if let fast = await passThroughID(id) {
            guard (try? await containers.inspect(fast)) != nil else {
                await state.forget(id: fast)
                throw ShimError.notFound("No such container: \(id)")
            }
            target = fast
        } else {
            let resolved: String
            do {
                resolved = try await resolveContainer(id).id
            } catch let error as ShimError {
                throw error
            } catch {
                throw ShimError.notFound("No such container: \(id)")
            }
            guard (try? await containers.inspect(resolved)) != nil else {
                throw ShimError.notFound("No such container: \(id)")
            }
            target = resolved
        }
        if newName == id || newName == target {
            return .status(204)
        }
        if await state.id(forName: newName) == target {
            return .status(204)
        }
        if await state.id(forName: newName) != nil {
            throw ShimError.conflict(
                "Conflict. The container name \"/\(newName)\" is already in use")
        }
        // The alias lives in state, but a live runtime container with that
        // exact id would be shadowed for Docker-name lookups — check it.
        // Fail closed: an uncertain list must not green-light a destructive
        // path (a failed check once wiped containers on a no-op rename).
        let live: [Micropod_V1_Container]
        do {
            live = try await containers.list()
        } catch {
            throw ShimError.internalError("rename: could not list containers: \(error)")
        }
        if live.contains(where: { $0.id == newName }) {
            throw ShimError.conflict(
                "Conflict. The container name \"/\(newName)\" is already in use")
        }
        // Alias the new name to the untouched runtime container and
        // tombstone the abandoned request name so its later removal (compose
        // always removes the temp name after promoting it) is idempotent.
        await state.rename(id: target, newName: newName)
        await state.tombstone(name: id)
        await readCache.invalidateContainers()
        return .status(204)
    }

    private func containerDelete(_ id: String, _ request: ShimRequest) async throws -> ShimResponse {
        // docker-py sends force=True (capitalized) — parse case-insensitively.
        let forceFlag = request.q("force").lowercased()
        let force = forceFlag == "1" || forceFlag == "true"
        // Tombstoned names (abandoned by rename, e.g. compose's temp name
        // after promoting it): removal is idempotent instead of 404 — this
        // is the tail of every compose recreate.
        if await state.isTombstoned(id) {
            await state.clearTombstone(id)
            await readCache.invalidateContainers()
            return .status(204)
        }
        if force, let target = await passThroughID(id) {
            // Never race a still-draining background stop.
            await state.awaitStop(target)
            let views = await state.forgetSharedViews(containerID: target)
            if let sharedFS {
                for viewID in views {
                    _ = try? await sharedFS.sync(id: viewID)
                    try? await sharedFS.unmount(id: viewID)
                }
            }
            do {
                try await containers.delete(target, force: true)
                await state.forget(id: target)
                await readCache.invalidateContainers()
                return .status(204)
            } catch {
                if Self.isNotFound(error) {
                    await state.forget(id: target)
                    throw ShimError.notFound("No such container: \(id)")
                }
                throw error
            }
        }
        let container = try await resolveContainer(id)
        await state.awaitStop(container.id)
        let views = await state.forgetSharedViews(containerID: container.id)
        if let sharedFS {
            for viewID in views {
                _ = try? await sharedFS.sync(id: viewID)
                try? await sharedFS.unmount(id: viewID)
            }
        }
        let running = DockerMapper.stateName(container.state) == "running"
        if running && !force {
            throw ShimError.conflict(
                "cannot remove container: container is running: stop the container before removing or force remove")
        }
        try await containers.delete(container.id, force: force)
        await state.forget(id: container.id)
        await readCache.invalidateContainers()
        return .status(204)
    }

    /// `POST /containers/{id}/wait` — headers immediately, body on exit.
    ///
    /// The docker CLI issues this request *before* `/start` (so it cannot miss
    /// a fast container's exit) and blocks on the response **headers** before
    /// going on to start the container. dockerd sends the status line straight
    /// away and writes the JSON only when the container exits, so a handler
    /// that computes the whole response first deadlocks the client: no headers
    /// until exit, no exit until start, no start until headers.
    ///
    /// Returning early to dodge that is worse — the CLI reads "exited" for a
    /// container that has not run and skips `/start` entirely, silently
    /// leaving a created-but-dead container behind.
    private func containerWait(_ id: String, _ request: ShimRequest) async throws -> ShimResponse {
        let target = try await resolveID(id)
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        Task.detached(priority: .userInitiated) { [self] in
            defer { continuation.finish() }
            let result = await waitForExit(target: target, request: request)
            continuation.yield(result)
        }
        return .stream(200, [("Content-Type", "application/json")], stream)
    }

    /// Blocks until the container has actually run and exited, then renders
    /// the `WaitResult` JSON.
    private func waitForExit(target: String, request: ShimRequest) async -> Data {
        let condition = request.q("condition").isEmpty ? "not-running" : request.q("condition")
        _ = condition
        while true {
            // Flat-cost single-container inspect instead of full-list scans.
            do {
                let raw = try await containers.inspect(target)
                if let container = DockerMapper.container(fromRawInspect: raw) {
                    let stateName = DockerMapper.stateName(container.state)
                    // "stopped" covers both never-run and ran-and-exited; only the
                    // latter is an exit to report. See `hasEverStarted`.
                    let neverRan =
                        stateName != "running" && !DockerMapper.hasEverStarted(rawInspect: raw)
                    // An attached run reports the exit code moments after the
                    // container reaches "stopped"; returning now would report 0
                    // for a failed container.
                    let awaitingExitCode = AttachRegistry.shared.isRunning(containerID: target)
                    if stateName != "running" && !neverRan && !awaitingExitCode {
                        // The runtime omits exit codes for stopped containers;
                        // assume a clean exit unless an event captured one.
                        let parsed = Int(container.exitCode)
                        let remembered = await state.exitCode(for: target)
                        return Self.encodeBody(
                            WaitResult(StatusCode: parsed ?? remembered ?? 0, Error: nil))
                    }
                }
                // Inspect succeeded but unmappable (transitional shape): retry
                // below — never report an exit on a maybe-alive container.
            } catch {
                if Self.isNotFound(error) {
                    // Gone from the runtime entirely. For `condition=removed`
                    // that IS the awaited outcome; otherwise report the last
                    // exit code we captured rather than hanging on a container
                    // that no longer exists.
                    let remembered = await state.exitCode(for: target)
                    return Self.encodeBody(WaitResult(StatusCode: remembered ?? 0, Error: nil))
                }
                // Transient CLI failure (timeout, wedged apiserver): keep
                // polling. A single hiccup must never surface as StatusCode 0
                // for a healthy running container — that phantom exit aborts
                // wait-strategy clients (e.g. testcontainers readiness).
                fputs("[shim] wait \(target): transient inspect error, retrying: \(error)\n", stderr)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    struct WaitResult: Codable {
        var StatusCode: Int
        var Error: String?
    }

    private func containerLogs(_ id: String, _ request: ShimRequest) async throws -> ShimResponse {
        let containerID = try await resolveID(id)
        let follow = request.q("follow").lowercased() == "1" || request.q("follow").lowercased() == "true"
        let tailParam = Int(request.q("tail")) ?? 100
        if follow {
            let stream = logs.stream(id: containerID, tail: min(tailParam, 500), boot: false)
            let (framedStream, continuation) = AsyncStream<Data>.makeStream()
            // Apple's `logs -f` never terminates on its own — not even when
            // the container dies — while Docker ends follow at container
            // exit. A death watch finishes the stream (after a short drain
            // for trailing output); a lock-guarded gate keeps post-finish
            // yields from ever reaching a closed continuation.
            let gate = StreamFinishGate()
            // The pump must die with the stream: cancelling it unwinds the
            // parked `for-await` (throws CancellationError at the suspension
            // point), which releases the inner LogStreamer consumer, whose
            // onTermination kills the `container logs -f` CLI child. Without
            // this, every follow leaks a Task AND an Apple CLI process
            // forever (Apple `logs -f` never exits on its own).
            let pumpBox = PumpBox()
            continuation.onTermination = { _ in pumpBox.task?.cancel() }
            pumpBox.task = Task.detached(priority: .userInitiated) {
                defer { gate.finish(continuation) }
                do {
                    for try await line in stream {
                        if gate.isFinished { break }
                        continuation.yield(
                            ExecSession.frame(type: 1, payload: Data((line.text + "\n").utf8)))
                    }
                } catch {}
            }
            Task.detached(priority: .utility) {
                let containers = self.containers
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard
                        let raw = try? await containers.inspect(containerID),
                        let container = DockerMapper.container(fromRawInspect: raw),
                        DockerMapper.stateName(container.state) == "running"
                    else { break }
                }
                // Drain window for output buffered behind the death.
                try? await Task.sleep(for: .seconds(2))
                gate.finish(continuation)
                // Prompt producer teardown (also covered by onTermination):
                // frees the parked for-await so the Apple CLI child is
                // reaped now, not whenever its output would next arrive.
                pumpBox.task?.cancel()
            }
            return .stream(
                200, [("Content-Type", "application/vnd.docker.multiplexed-stream")], framedStream)
        }
        let lines = try await logs.tail(id: containerID, lines: max(1, tailParam), boot: false)
        var payload = Data()
        for line in lines {
            payload.append(ExecSession.frame(type: 1, payload: Data((line.text + "\n").utf8)))
        }
        return .raw(200, [("Content-Type", "application/vnd.docker.multiplexed-stream")], payload)
    }

    /// `POST /containers/{id}/attach` — the hijacked stream `docker run` and
    /// `docker start -a` use. Synthesized from the log follow; see
    /// `AttachSession` for what that can and cannot reproduce.
    private func containerAttach(
        _ id: String, _ request: ShimRequest, _ connection: ShimConnection
    ) async throws -> ShimResponse {
        let containerID = try await resolveID(id)

        // Without stream=1 the client wants a one-shot replay, which is what
        // the logs endpoint already serves.
        if !Self.isTruthy(request.q("stream")) {
            return try await containerLogs(containerID, request)
        }

        // Switch the connection to raw mode now, at park time. Leaving it in
        // HTTP mode until `/start` claims it lets the client's transport treat
        // it as an idle pooled connection, and the first stdcopy frame then
        // surfaces as "Unsolicited response received on idle HTTP channel".
        let inbound = connection.beginHijack()
        Task.detached(priority: .utility) {
            for await _ in inbound {}
        }
        // Park it; `/start` launches the attached run and claims it. See
        // AttachRegistry for why the order is inverted.
        AttachRegistry.shared.park(containerID: containerID, connection: connection)
        let tty = await state.createRequest(for: containerID)?.Tty ?? false
        return .hijacked(
            contentType: tty ? ShimResponse.rawStream : ShimResponse.multiplexedStream)
    }

    /// Starts `id`, streaming into a hijacked connection if `/attach` parked
    /// one for it. The attached form is what surfaces the container's real
    /// exit code — a detached start leaves it unknowable (see AttachSession).
    private func startPossiblyAttached(_ id: String) async throws {
        await state.markStarted(id: id)
        // A (re)start resets health supervision immediately (the events loop
        // re-baselines on the observed transition as well).
        await state.resetHealth(id: id)
        guard let connection = AttachRegistry.shared.claim(containerID: id) else {
            fputs("[shim] start \(id): no parked attach, detached start\n", stderr)
            try await containers.start(id)
            return
        }
        fputs("[shim] start \(id): claimed parked attach\n", stderr)
        let tty = await state.createRequest(for: id)?.Tty ?? false
        do {
            let containers = self.containers
            let state = self.state
            // Marked before launch so the events loop never sees the window
            // between /start and the container actually running as an exit.
            await state.markAttachRunning(id: id)
            let session = AttachSession(
                cliPath: cliPath, containerID: id, tty: tty, state: state,
                onExit: { _ in
                    await state.clearAttachRunning(id: id)
                    guard let create = await state.createRequest(for: id),
                        create.HostConfig?.AutoRemove == true
                    else { return }
                    try? await containers.delete(id, force: true)
                })
            try session.launchAndPump(connection: connection)
        } catch {
            // Never strand the client on a dead hijack.
            await state.clearAttachRunning(id: id)
            connection.close()
            throw error
        }
    }

    /// Docker query flags arrive as "1"/"true"/"True" depending on the client.
    static func isTruthy(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized == "1" || normalized == "true"
    }

    private func containerStats(_ id: String) async throws -> ShimResponse {
        let containerID = try await resolveID(id)
        let snapshot = try await stats.snapshot()
        let entry = snapshot.containers.first { $0.id == containerID }
        let cpuNanos = UInt64((entry?.cpuPercent ?? 0) * 10_000_000)
        return Self.encode(StatsPayload(entry: entry, cpuNanos: cpuNanos))
    }

    struct StatsPayload: Encodable {
        var read: String
        var pids_stats: PidsStats
        var networks: [String: NetworkStats]
        var memory_stats: MemoryStats
        var cpu_stats: CPUStats
        var precpu_stats: CPUStats

        init(entry: Micropod_V1_ContainerStats?, cpuNanos: UInt64) {
            read = ISO8601DateFormatter().string(from: Date())
            pids_stats = PidsStats(current: entry?.pids ?? 0)
            networks = [
                "eth0": NetworkStats(rx_bytes: entry?.networkRxBytes ?? 0, tx_bytes: entry?.networkTxBytes ?? 0)
            ]
            memory_stats = MemoryStats(
                usage: entry?.memoryUsedBytes ?? 0, limit: entry?.memoryLimitBytes ?? 0)
            cpu_stats = CPUStats(
                cpu_usage: CPUUsage(total_usage: cpuNanos),
                online_cpus: ProcessInfo.processInfo.activeProcessorCount)
            precpu_stats = CPUStats(cpu_usage: CPUUsage(total_usage: 0), online_cpus: 0)
        }
    }

    struct PidsStats: Encodable { var current: UInt64 }
    struct NetworkStats: Encodable {
        var rx_bytes: UInt64
        var tx_bytes: UInt64
    }
    struct MemoryStats: Encodable {
        var usage: UInt64
        var limit: UInt64
    }
    struct CPUStats: Encodable {
        var cpu_usage: CPUUsage
        var online_cpus: Int
    }
    struct CPUUsage: Encodable {
        var total_usage: UInt64
    }

    // MARK: - Archive

    private func archivePut(_ id: String, _ request: ShimRequest) async throws -> ShimResponse {
        let containerID = try await resolveID(id)
        let destination = request.q("path")
        guard !destination.isEmpty else { throw ShimError.badRequest("missing path parameter") }
        let remoteTar = "/tmp/micropod-shim-\(IDGenerator.randomSuffix()).tar"

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shim-upload-\(IDGenerator.randomSuffix()).tar")
        try request.body.write(to: tempURL)

        defer { try? FileManager.default.removeItem(at: tempURL) }

        try await containers.copy(from: tempURL.path, to: "\(containerID):\(remoteTar)")
        _ = try await containers.exec(
            ContainerExecRequest(
                containerID: containerID,
                arguments: ["tar", "-xf", remoteTar, "-C", destination],
                interactive: false, tty: false, detach: false, user: nil, workdir: nil, env: []))
        _ = try? await containers.exec(
            ContainerExecRequest(
                containerID: containerID,
                arguments: ["rm", "-f", remoteTar],
                interactive: false, tty: false, detach: false, user: nil, workdir: nil, env: []))
        return .status(200)
    }

    /// GET /containers/{id}/top — `docker top` compat: `ps` inside the
    /// container, shaped as Docker's {Titles, Processes} table.
    private func containerTop(_ id: String) async throws -> ShimResponse {
        let containerID = try await resolveID(id)
        let out = try await containers.exec(
            ContainerExecRequest(
                containerID: containerID,
                arguments: ["ps", "-eo", "pid,user,time,comm"],
                interactive: false, tty: false, detach: false, user: nil, workdir: nil, env: []))
        struct TopResponse: Encodable {
            let Titles: [String]
            let Processes: [[String]]
        }
        var rows: [[String]] = []
        for line in out.split(separator: "\n").dropFirst() {
            let cols = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if cols.count >= 4 { rows.append(cols) }
        }
        return Self.encode(TopResponse(Titles: ["PID", "USER", "TIME", "COMMAND"], Processes: rows))
    }

    private func archiveGet(_ id: String, _ request: ShimRequest) async throws -> ShimResponse {
        let containerID = try await resolveID(id)
        let sourcePath = request.q("path")
        guard !sourcePath.isEmpty else { throw ShimError.badRequest("missing path parameter") }
        let remoteTar = "/tmp/micropod-shim-\(IDGenerator.randomSuffix()).tar"
        let fileName = sourcePath.split(separator: "/").last.map(String.init) ?? "archive"
        let directory = sourcePath.split(separator: "/").dropLast().joined(separator: "/")
        let absoluteDirectory = directory.isEmpty ? "/" : "/\(directory)"

        _ = try await containers.exec(
            ContainerExecRequest(
                containerID: containerID,
                arguments: ["tar", "-cf", remoteTar, "-C", absoluteDirectory, fileName],
                interactive: false, tty: false, detach: false, user: nil, workdir: nil, env: []))

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shim-download-\(IDGenerator.randomSuffix()).tar")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try await containers.copy(from: "\(containerID):\(remoteTar)", to: tempURL.path)
        _ = try? await containers.exec(
            ContainerExecRequest(
                containerID: containerID,
                arguments: ["rm", "-f", remoteTar],
                interactive: false, tty: false, detach: false, user: nil, workdir: nil, env: []))

        let data = try Data(contentsOf: tempURL)
        let stat = ArchiveStat(name: fileName, size: data.count, mode: 420)
        let statData = try JSONEncoder().encode(stat)
        return .raw(
            200,
            [
                ("Content-Type", "application/x-tar"),
                ("X-Docker-Container-Path-Stat", statData.base64EncodedString()),
            ],
            data)
    }

    struct ArchiveStat: Encodable {
        var name: String
        var size: Int
        var mode: Int
    }

    // MARK: - Exec handlers

    private func execCreate(_ id: String, _ request: ShimRequest) async throws -> ShimResponse {
        let containerID = try await resolveID(id)
        let body = try decodeBody(DockerExecCreate.self, request)
        guard let cmd = body.Cmd, !cmd.isEmpty else {
            throw ShimError.badRequest("exec requires Cmd array")
        }
        let execID = IDGenerator.execID()
        await state.registerExec(
            ShimState.ExecRecord(
                id: execID, containerID: containerID, cmd: cmd, running: false, exitCode: nil))
        return .json(201, Self.encodeBody(ExecCreateResponse(Id: execID)))
    }

    struct ExecCreateResponse: Codable {
        var Id: String
    }

    struct EmptyResponse: Codable {}

    private func execStart(_ execID: String, _ request: ShimRequest, _ connection: ShimConnection)
        async throws -> ShimResponse
    {
        guard let record = await state.exec(execID) else {
            throw ShimError.notFound("No such exec instance: \(execID)")
        }
        struct StartBody: Codable {
            var Detach: Bool?
            var Tty: Bool?
        }
        let body = try? JSONDecoder().decode(StartBody.self, from: request.body)

        if body?.Detach == true {
            let session = try ExecSession(
                cliPath: cliPath, containerID: record.containerID,
                request: execBody(for: record, tty: body?.Tty), execID: execID, state: state)
            try session.startDetached()
            return Self.encode(EmptyResponse())
        }
        let session = try ExecSession(
            cliPath: cliPath, containerID: record.containerID,
            request: execBody(for: record, tty: body?.Tty), execID: execID, state: state)
        // Mark it running *before* launching. A short command (`true`) can exit
        // and have its watcher record the exit code before this line would
        // otherwise run, and then this would overwrite the finished record with
        // `running: true, exitCode: nil` — an exec that already succeeded would
        // report as still running with no status.
        await state.registerExec(
            ShimState.ExecRecord(
                id: record.id, containerID: record.containerID, cmd: record.cmd, running: true,
                exitCode: nil))
        try session.launchAndPump(connection: connection)
        // ExecSession frames with stdcopy unless the client asked for a TTY.
        return .hijacked(
            contentType: body?.Tty == true
                ? ShimResponse.rawStream : ShimResponse.multiplexedStream)
    }

    private func execBody(for record: ShimState.ExecRecord, tty: Bool?) -> DockerExecCreate {
        var request = DockerExecCreate()
        request.Cmd = record.cmd
        request.AttachStdin = false
        request.AttachStdout = true
        request.AttachStderr = true
        request.Tty = tty
        return request
    }

    private func execInspect(_ execID: String) async throws -> ShimResponse {
        guard let record = await state.exec(execID) else {
            throw ShimError.notFound("No such exec instance: \(execID)")
        }
        return Self.encode(
            ExecInspectPayload(
                ID: record.id, Running: record.running, ExitCode: record.exitCode,
                entrypoint: record.cmd.first ?? "",
                arguments: Array(record.cmd.dropFirst()), ContainerID: record.containerID))
    }

    struct ExecInspectPayload: Encodable {
        var ID: String
        var Running: Bool
        var ExitCode: Int?
        var ProcessConfig: ProcessPayload
        var OpenStdin = false
        var OpenStderr = true
        var OpenStdout = true
        var CanRemove = false
        var ContainerID: String
        var DetachKeys = ""
        var Pid = 0

        init(
            ID: String, Running: Bool, ExitCode: Int?, entrypoint: String,
            arguments: [String], ContainerID: String
        ) {
            self.ID = ID
            self.Running = Running
            self.ExitCode = ExitCode
            self.ProcessConfig = ProcessPayload(entrypoint: entrypoint, arguments: arguments)
            self.ContainerID = ContainerID
        }
    }

    struct ProcessPayload: Encodable {
        var entrypoint: String
        var arguments: [String]
        var tty = false
    }

    // MARK: - Network handlers

    private func networksList(_ request: ShimRequest) async throws -> ShimResponse {
        let idFilter: String? = nil
        let filters = request.filters()
        let list = try await networks.list()
        var resources = list.map(Self.networkResource)
        if let idFilter, !idFilter.isEmpty {
            resources = resources.filter {
                $0.Name == idFilter || $0.Id.hasPrefix(idFilter)
            }
            guard !resources.isEmpty else { throw ShimError.notFound("network \(idFilter) not found") }
        }
        resources = try resources.filter { resource in
            try Self.matchesLabelFilters(
                filters, labels: resource.Labels,
                allowedKeys: ["label", "labels", "name", "id", "driver", "scope", "type", "dangling"])
        }
        return Self.encode(resources)
    }

    private func networkInspect(_ id: String) async throws -> ShimResponse {
        let list = try await networks.list()
        guard
            let match = list.first(where: {
                $0.id == id || Self.networkResource($0).Name == id
                    || Self.networkResource($0).Id.hasPrefix(id)
            })
        else {
            throw ShimError.notFound("network \(id) not found")
        }
        return Self.encode(Self.networkResource(match))
    }

    static func networkResource(_ network: Micropod_V1_Network) -> DockerNetworkResource {
        var ipamConfig = [DockerNetworkResource.IPAM.IPAMConfig]()
        if !network.ipv4Subnet.isEmpty {
            ipamConfig.append(
                .init(Subnet: network.ipv4Subnet, Gateway: network.ipv4Gateway.isEmpty ? nil : network.ipv4Gateway))
        }
        return DockerNetworkResource(
            Name: network.id,
            Id: network.id.lowercased().replacingOccurrences(of: " ", with: "-"),
            Created: DockerMapper.rfc3339(network.createdAt),
            Scope: "local",
            Driver: network.plugin.isEmpty ? "nat" : network.plugin,
            Internal: network.mode == "internal",
            IPAM: .init(Driver: "default", Config: ipamConfig),
            Labels: network.labels)
    }

    private func networkCreate(_ request: ShimRequest) async throws -> ShimResponse {
        let body = try decodeBody(DockerNetworkCreateBody.self, request)
        guard let name = body.Name, !name.isEmpty else {
            throw ShimError.badRequest("network name required")
        }
        // The Apple runtime rejects uppercase network label keys
        // (LabelError invalid_label_key_content) while Docker accepts
        // anything — including testcontainers-go's camelCase sessionId.
        // Normalize keys to lowercase (values untouched) so stock clients
        // work unchanged; containers/volumes accept uppercase and are left
        // exact. Caveat: a crash-abandoned session network keeps lowercased
        // labels, so Ryuk's original-case label filter can miss it on reap
        // (explicit session-end removal is ID-based and unaffected).
        let rawLabels = body.Labels ?? [:]
        var normalizedLabels: [String] = []
        for (key, value) in rawLabels {
            let lowered = key.lowercased()
            if lowered != key {
                fputs("[shim] network label key normalized \(key) -> \(lowered)\n", stderr)
            }
            normalizedLabels.append("\(lowered)=\(value)")
        }
        let requestedSubnet = body.IPAM?.Config?.first?.Subnet
        // Explicit subnets pass through untouched. Otherwise allocate
        // deterministically: Apple auto-allocated custom networks land on
        // broken ranges (no inter-container L3 or DNS — probed), while
        // explicit 10.x subnets work. The allocation is a pure function of
        // the name, so repeated `compose up` converges instead of churning.
        var subnet = requestedSubnet
        if subnet == nil || subnet?.isEmpty == true {
            let taken =
                ((try? await networks.list()) ?? []).compactMap {
                    $0.ipv4Subnet.isEmpty ? nil : $0.ipv4Subnet
                }
            if let pick = DockerNetworkAllocator.allocate(name: name, existingSubnets: taken) {
                fputs("[shim] network \(name): allocated subnet \(pick)\n", stderr)
                subnet = pick
            } else {
                fputs("[shim] network \(name): subnet pool exhausted, leaving to runtime\n", stderr)
            }
        }
        try await networks.create(
            name: name, internal: body.Internal ?? false,
            subnet: subnet,
            subnetV6: nil,
            driver: body.Driver,
            options: [],
            labels: normalizedLabels)
        return .json(201, Self.encodeBody(NetworkCreateResponse(Id: name.lowercased(), Warning: "")))
    }

    struct NetworkCreateResponse: Codable {
        var Id: String
        var Warning: String
    }

    private func networkDelete(_ id: String) async throws -> ShimResponse {
        let list = try await networks.list()
        guard let match = list.first(where: { $0.id == id || $0.id.lowercased().hasPrefix(id.lowercased()) })
        else { throw ShimError.notFound("network \(id) not found") }
        try await networks.delete(match.id)
        return .status(204)
    }

    private func networkPrune() async throws -> ShimResponse {
        _ = try await networks.prune()
        return Self.encode(NetworksPruneResponse())
    }

    struct NetworksPruneResponse: Encodable {
        var NetworksDeleted: [String] = []
    }

    // MARK: - Volume handlers

    private func volumesList(_ request: ShimRequest) async throws -> ShimResponse {
        let filters = request.filters()
        let list = try await cachedVolumesList()
        var resources = list.map(Self.volumeResource)
        resources = try resources.filter { resource in
            try Self.matchesLabelFilters(
                filters, labels: resource.Labels,
                allowedKeys: ["label", "labels", "name", "dangling", "until"])
        }
        return Self.encode(VolumeListResponse(Volumes: resources, Warnings: []))
    }

    struct VolumeListResponse: Codable {
        var Volumes: [DockerVolume]
        var Warnings: [String]
    }

    private func volumeInspect(_ name: String) async throws -> ShimResponse {
        let list = try await cachedVolumesList()
        guard let match = list.first(where: { $0.id == name }) else {
            throw ShimError.notFound("volume \(name) not found")
        }
        return Self.encode(Self.volumeResource(match))
    }

    static func volumeResource(_ volume: Micropod_V1_Volume) -> DockerVolume {
        DockerVolume(
            Name: volume.id,
            Driver: volume.driver.isEmpty ? "local" : volume.driver,
            Mountpoint: volume.source.isEmpty ? "~/.micropod/volumes/\(volume.id)" : volume.source,
            CreatedAt: volume.createdAt.isEmpty ? nil : DockerMapper.rfc3339(volume.createdAt),
            Labels: volume.labels,
            Scope: "local")
    }

    private func volumeCreate(_ request: ShimRequest) async throws -> ShimResponse {
        let body = try decodeBody(DockerVolumeCreateBody.self, request)
        let name = body.Name ?? IDGenerator.randomSuffix(length: 16)
        let labels = body.Labels ?? [:]
        let (size, options) = Self.volumeCreateOptions(
            body.DriverOpts, defaultSize: config.defaultVolumeSize)
        try await volumes.create(
            name: name,
            size: size,
            labels: labels.map { "\($0.key)=\($0.value)" }.sorted(),
            options: options)
        await readCache.invalidateVolumes()
        return .json(
            201,
            Self.encodeBody(
                DockerVolume(
                    Name: name, Driver: body.Driver ?? "local",
                    Mountpoint: "~/.micropod/volumes/\(name)",
                    CreatedAt: ISO8601DateFormatter().string(from: Date()),
                    Labels: labels, Scope: "local")))
    }

    /// Split Docker `DriverOpts` into the runtime's `-s <size>` and the
    /// remaining `--opt k=v` pairs.
    ///
    /// Docker's `local` driver spells size two ways — a bare `size` key and
    /// the mount-style `o=size=...` used by `--opt o=size=10g` — and both
    /// appear in the wild (compose files, testcontainers). Either maps onto
    /// the Apple runtime's `-s`. Anything else is forwarded untouched so a
    /// future runtime option needs no shim change.
    static func volumeCreateOptions(
        _ driverOpts: [String: String]?, defaultSize: String
    ) -> (size: String?, options: [String]) {
        guard let driverOpts, !driverOpts.isEmpty else { return (defaultSize, []) }
        var size: String?
        var options: [String] = []
        for (key, value) in driverOpts {
            switch key.lowercased() {
            case "size":
                size = value
            case "o":
                // `o` is a comma-separated mount option list; pull `size=` out
                // of it and forward whatever else it carries.
                var passthrough: [String] = []
                for part in value.split(separator: ",") {
                    let opt = part.trimmingCharacters(in: .whitespaces)
                    if opt.lowercased().hasPrefix("size=") {
                        size = String(opt.dropFirst("size=".count))
                    } else if !opt.isEmpty {
                        passthrough.append(opt)
                    }
                }
                if !passthrough.isEmpty {
                    options.append("o=" + passthrough.joined(separator: ","))
                }
            default:
                options.append("\(key)=\(value)")
            }
        }
        return (size ?? defaultSize, options.sorted())
    }

    private func volumeDelete(_ name: String) async throws -> ShimResponse {
        try await volumes.delete(name)
        await readCache.invalidateVolumes()
        return .status(204)
    }

    private func volumePrune() async throws -> ShimResponse {
        let before = try await volumes.list()
        _ = try await volumes.prune()
        let after = try await volumes.list()
        await readCache.invalidateVolumes()
        let afterIDs = Set(after.map { $0.id })
        let deleted = before.filter { !afterIDs.contains($0.id) }
        return Self.encode(
            VolumesPruneResponse(
                volumesDeleted: deleted.map { $0.id },
                spaceReclaimed: Int(deleted.reduce(0) { $0 + $1.sizeBytes })))
    }

    struct VolumesPruneResponse: Encodable {
        var VolumesDeleted: [String]
        var SpaceReclaimed: Int

        init(volumesDeleted: [String], spaceReclaimed: Int) {
            self.VolumesDeleted = volumesDeleted
            self.SpaceReclaimed = spaceReclaimed
        }
    }
}

// MARK: - Well-known cache path detection (intelligent shared cache)

extension Router {
    /// Well-known package-manager cache paths. Tilde is expanded per-container
    /// via HOME / User (fallback /root). First three are absolute; last is
    /// home-dependent (pip).
    /// Package-manager caches that are worth sharing across repos and runners.
    ///
    /// The test is *input vs output*. A downloaded artifact keyed by a lockfile
    /// (a tarball, a module zip, a crate) is identical for every repo that pins
    /// the same version, so sharing it is a pure win. A build output tree
    /// (`node_modules`, `target/`, `.next`) is repo-specific, poorly dedupable
    /// and often contains absolute paths or compiled native addons — sharing it
    /// across repos would be wrong, not just wasteful. That is why
    /// `~/.npm` is here and `node_modules` deliberately is not.
    ///
    /// `~` expands against the container's HOME (see `homeDirectory(for:)`), so
    /// the same entry covers root and non-root images. Extra paths can be added
    /// per-container with the `micropod.cache.sharedMounts` label, or host-wide
    /// with MICROPOD_SHIM_CACHE_PATHS.
    static let builtinWellKnownTemplates: [String] = [
        // Go
        "/go/pkg/mod",
        "~/go/pkg/mod",
        "/root/.cache/go-build",
        "~/.cache/go-build",
        // Node — input caches only, never node_modules
        "/root/.npm",
        "~/.npm",
        "~/.cache/yarn",
        "/usr/local/share/.cache/yarn",
        "~/.local/share/pnpm/store",
        "~/.pnpm-store",
        // Python
        "~/.cache/pip",
        "~/.cache/uv",
        // Rust
        "~/.cargo/registry",
        "~/.cargo/git",
        // JVM
        "~/.m2/repository",
        "~/.gradle/caches",
    ]

    /// Built-ins plus anything in MICROPOD_SHIM_CACHE_PATHS (colon- or
    /// comma-separated), so an operator can opt a project's own cache path in
    /// without rebuilding the shim or labelling every container.
    static let wellKnownTemplates: [String] = {
        var templates = builtinWellKnownTemplates
        let raw = ProcessInfo.processInfo.environment["MICROPOD_SHIM_CACHE_PATHS"] ?? ""
        for entry in raw.split(whereSeparator: { $0 == ":" || $0 == "," }) {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { templates.append(trimmed) }
        }
        return templates
    }()

    /// Container-aware home directory: Env HOME wins, else User -> /home/<user>, else /root.
    static func homeDirectory(for request: DockerCreateRequest) -> String {
        if let env = request.Env {
            for entry in env where entry.hasPrefix("HOME=") {
                let value = String(entry.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
        }
        if let user = request.User, !user.isEmpty {
            let name = user.split(separator: ":").first.map(String.init) ?? user
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                if trimmed == "root" { return "/root" }
                // Numeric UIDs still map to /home/<uid> per spec fallback.
                return "/home/\(trimmed)"
            }
        }
        return "/root"
    }

    static func expandedPath(_ path: String, home: String) -> String {
        var expanded = path.replacingOccurrences(of: "~", with: home)
        // Normalize trailing slash (except root).
        if expanded.count > 1 && expanded.hasSuffix("/") {
            expanded = String(expanded.dropLast())
        }
        return expanded
    }

    /// One-arg overload uses fallback /root (for callers without container context).
    static func isWellKnown(_ containerPath: String) -> Bool {
        let fallback = DockerCreateRequest(Image: "")
        return isWellKnown(containerPath, request: fallback)
    }

    static func isWellKnown(_ containerPath: String, request: DockerCreateRequest) -> Bool {
        let home = homeDirectory(for: request)
        let normalized = expandedPath(containerPath, home: home)
        for template in wellKnownTemplates {
            let expected = expandedPath(template, home: home)
            if normalized == expected { return true }
        }
        return false
    }

    /// Backwards-compat alias matching the plan snippet's signature.
    static func isWellKnown(_ containerPath: String, containerConfig: DockerCreateRequest) -> Bool {
        isWellKnown(containerPath, request: containerConfig)
    }

    // MARK: Shared override helpers

    private static let sharedFlagKeys = [
        "micropod.cache.shared",
        "cache.shared",
        "shared",
        "io.micropod.shared",
        "com.micropod.cache.shared",
    ]

    private static let sharedMountsKeys = [
        "micropod.cache.sharedMounts",
        "cache.sharedMounts",
        "sharedMounts",
        "io.micropod.sharedMounts",
        "micropod.sharedMounts",
    ]

    static func sharedFlag(from labels: [String: String]?) -> Bool? {
        guard let labels else { return nil }
        for key in sharedFlagKeys {
            if let raw = labels[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                if raw == "true" || raw == "1" || raw == "yes" { return true }
                if raw == "false" || raw == "0" || raw == "no" { return false }
            }
        }
        return nil
    }

    static func sharedMountsList(from labels: [String: String]?) -> [String] {
        guard let labels else { return [] }
        for key in sharedMountsKeys {
            guard let raw = labels[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                !raw.isEmpty
            else { continue }
            // Try JSON array decode first.
            if raw.hasPrefix("["),
                let data = raw.data(using: .utf8),
                let decoded = try? JSONDecoder().decode([String].self, from: data)
            {
                return decoded.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            // Comma-separated list.
            if raw.contains(",") {
                let parts = raw.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }.filter { !$0.isEmpty }
                if !parts.isEmpty { return parts }
            }
            return [raw]
        }
        return []
    }

    static func shouldUseSharedView(_ containerPath: String, request: DockerCreateRequest) -> Bool {
        // shared:false forces isolation even for well-known.
        if let flag = sharedFlag(from: request.Labels), flag == false { return false }
        if isWellKnown(containerPath, request: request) { return true }
        let mounts = sharedMountsList(from: request.Labels)
        if !mounts.isEmpty {
            let home = homeDirectory(for: request)
            let normalized = expandedPath(containerPath, home: home)
            for mount in mounts {
                let expected = expandedPath(mount, home: home)
                if normalized == expected { return true }
            }
        }
        if let flag = sharedFlag(from: request.Labels), flag == true { return true }
        return false
    }
}

/// Thread-safe once-gate for finishing an AsyncStream continuation from
/// racing tasks (stream end vs death watch): exactly one finish wins, and
/// producers check `isFinished` to stop yielding into a closed stream.
final class StreamFinishGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }

    func finish(_ continuation: AsyncStream<Data>.Continuation) {
        lock.lock()
        guard !done else {
            lock.unlock()
            return
        }
        done = true
        lock.unlock()
        continuation.finish()
    }
}

/// Mutable task handle shared between a stream's producer task and its
/// termination handler (a class so concurrently-executing closures can
/// share it under StrictConcurrency).
final class PumpBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _task: Task<Void, Never>?

    var task: Task<Void, Never>? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _task
        }
        set {
            lock.lock()
            _task = newValue
            lock.unlock()
        }
    }
}
