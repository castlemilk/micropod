import Foundation
import MicropodCore
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
    private let stats: StatsSampler
    private let sharedFS: (any SharedFSClient)?

    convenience init(
        config: ShimConfig, state: ShimState, events: EventsHub,
        client: ContainerCLIClient
    ) {
        self.init(config: config, state: state, events: events, client: client, sharedFS: nil)
    }

    init(
        config: ShimConfig, state: ShimState, events: EventsHub,
        client: ContainerCLIClient, sharedFS sharedFSOverride: (any SharedFSClient)?
    ) {
        self.config = config
        self.state = state
        self.events = events
        self.cliPath = client.executableURL.path
        self.containers = ContainerService(client: client)
        self.images = ImageService(client: client)
        self.volumes = VolumeService(client: client)
        self.networks = NetworkService(client: client)
        self.system = SystemService(client: client)
        self.systemConcrete = SystemService(client: client)
        self.logs = LogStreamer(client: client)
        self.stats = StatsSampler(client: client)
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
        do {
            return try await dispatch(request, connection)
        } catch let error as ShimError {
            return Self.errorJSON(error.status, error.message)
        } catch let error as MicropodError {
            return Self.errorJSON(500, error.errorDescription ?? "\(error)")
        } catch {
            return Self.errorJSON(500, "\(error)")
        }
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
        case ("DELETE", "containers") where segments.count == 2:
            return try await containerDelete(segments[1], request)
        case ("POST", "containers") where segments.count == 3 && segments[2] == "wait":
            return try await containerWait(segments[1], request)
        case ("GET", "containers") where segments.count == 3 && segments[2] == "logs":
            return try await containerLogs(segments[1], request)
        case ("POST", "containers") where segments.count == 3 && segments[2] == "attach":
            return try await containerAttach(segments[1], request, connection)
        case ("GET", "containers") where segments.count == 3 && segments[2] == "top":
            throw ShimError.notImplemented("container top is not supported by this runtime")
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
        case ("GET", "networks"):
            return try await networksList(request)
        case ("GET", "networks") where segments.count == 2:
            return try await networkInspect(segments[1])
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

    private func info() async throws -> ShimResponse {
        let list = try await containers.list()
        let imageList = try await images.list()
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
        let (_, stream) = await events.subscribe(filters: filters)
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
        Task.detached(priority: .userInitiated) {
            defer { continuation.finish() }
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
        let list = try await images.list()
        var summaries = list.map(DockerMapper.imageSummary)
        summaries = try summaries.filter { summary in
            try Self.matchesLabelFilters(
                filters, labels: summary.Labels,
                allowedKeys: ["label", "labels", "dangling", "reference", "until", "before", "since"])
        }
        return Self.encode(summaries)
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
        // Write body to file and extract (handle plain tar or gzip, plus xattrs/pax)
        let tarPath = tmpRoot.appendingPathComponent("context.tar")
        do { try request.body.write(to: tarPath) } catch {
            throw ShimError.internalError("failed to stage build context: \(error)")
        }
        // Detect gzip by magic bytes 1f 8b
        let isGzip: Bool = {
            if request.header("content-encoding").lowercased().contains("gzip") { return true }
            if request.body.count >= 2 && request.body[0] == 0x1F && request.body[1] == 0x8B { return true }
            return false
        }()
        let tarArgs: [String] =
            isGzip ? ["-xzf", tarPath.path, "-C", contextDir.path] : ["-xf", tarPath.path, "-C", contextDir.path]
        let tarProc = Process()
        tarProc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tarProc.arguments = tarArgs
        tarProc.standardOutput = FileHandle.nullDevice
        tarProc.standardError = Pipe()
        do {
            try tarProc.run()
            tarProc.waitUntilExit()
        } catch {
            throw ShimError.badRequest("failed to unpack build context: \(error)")
        }
        if tarProc.terminationStatus != 0 {
            let errData = (tarProc.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
            let msg = String(data: errData, encoding: .utf8) ?? "unknown tar error"
            throw ShimError.badRequest("failed to unpack build context: \(msg)")
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
        let buildReq = ContainerBuildRequest(
            contextDirectory: contextDir.path,
            dockerfile: resolvedDockerfile,
            tags: tags,
            buildArgs: buildArgs,
            target: target,
            platform: platform,
            noCache: noCache,
            labels: labelSpecs)
        let progress = images.build(buildReq)
        let (stream, cont) = AsyncStream<Data>.makeStream()
        Task.detached(priority: .userInitiated) {
            defer {
                cont.finish()
                try? FileManager.default.removeItem(at: tmpRoot)
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
            } catch {
                let line = BuildErrorLine(errorDetail: ["message": "\(error)"], error: "\(error)")
                if let data = try? JSONEncoder().encode(line) {
                    cont.yield(data + Data("\n".utf8))
                }
            }
        }
        return .stream(200, [("Content-Type", "application/json")], stream)
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
        let data = try await images.inspect(reference)
        guard let mapped = DockerMapper.dockerImageInspect(fromRaw: data, reference: reference) else {
            throw ShimError.notFound("image \(reference) not found")
        }
        return .raw(200, [("Content-Type", "application/json")], mapped)
    }

    private func imageDelete(_ reference: String, _ request: ShimRequest) async throws -> ShimResponse {
        try await images.delete(
            reference, force: request.q("force").lowercased() == "1" || request.q("force").lowercased() == "true")
        return Self.encode([["Untagged": reference, "Deleted": reference]])
    }

    private func imageTag(_ source: String, _ request: ShimRequest) async throws -> ShimResponse {
        let repo = request.q("repo")
        let tag = request.q("tag")
        let target = tag.isEmpty ? repo : "\(repo):\(tag)"
        guard !repo.isEmpty else { throw ShimError.badRequest("missing repo parameter") }
        try await images.tag(source: source, target: target)
        return .status(201)
    }

    private func imagePrune(_ request: ShimRequest) async throws -> ShimResponse {
        let all = request.q("all").lowercased() == "1" || request.q("all").lowercased() == "true"
        let before = try await images.list()
        let reclaimable =
            try await UsageService(
                containers: containers, images: images, volumes: volumes
            ).report().reclaimableImageBytes
        _ = try await images.prune(danglingOnly: !all)
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
        let report = try await usage().report()
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
        let list = try await containers.list()
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
        return Self.encode(summaries)
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
        var notes = [String]()
        if RyukSupport.isRyuk(body.Image) {
            (body, notes) = RyukSupport.intercept(body, bridgeHost: config.bridgeHost, tcpPort: config.tcpPort)
        }

        let requestedName = request.q("name").isEmpty ? nil : request.q("name")
        if let requestedName {
            let takenByName = await state.id(forName: requestedName) != nil
            let takenByID = try await containers.list().contains { $0.id == requestedName }
            if takenByName || takenByID {
                throw ShimError.conflict(
                    "Conflict. The container name \"/\(requestedName)\" is already in use")
            }
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
        let runRequest = try Self.buildRunRequest(from: body, name: requestedName)
        let id = try await containers.create(runRequest)
        await state.remember(id: id, name: requestedName, request: body)
        if !sharedViewIDs.isEmpty {
            await state.rememberSharedViews(containerID: id, views: sharedViewIDs)
        }
        let response = DockerCreateResponse(Id: id, Warnings: [])
        if !notes.isEmpty {
            fputs("[shim] ryuk interception for \(id): \(notes.joined(separator: "; "))\n", stderr)
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
        from body: DockerCreateRequest, name: String?
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

        let networkMode = body.HostConfig?.NetworkMode ?? ""
        let attachNetworks: [String]
        switch networkMode {
        case "", "default", "bridge", "host", "none":
            attachNetworks = []
        default:
            attachNetworks = [networkMode]
        }

        let memory: String?
        if let memBytes = body.HostConfig?.Memory, memBytes > 0 {
            let mib = memBytes / (1024 * 1024)
            memory = "\(mib)MiB"
        } else {
            memory = nil
        }

        return ContainerRunRequest(
            image: body.Image,
            name: name,
            detach: true,
            cpus: nil,
            memory: memory,
            env: body.Env ?? [],
            envFiles: [],
            publishedPorts: publishedPorts,
            volumes: body.HostConfig?.Binds ?? [],
            tmpfs: [],
            labels: (body.Labels ?? [:]).map { LabelSpec(key: $0.key, value: $0.value) },
            interactive: body.OpenStdin == true,
            tty: body.Tty == true,
            useInit: body.HostConfig?.Init == true,
            readOnly: body.HostConfig?.ReadonlyRootfs == true,
            rosetta: false,
            user: body.User,
            shmSize: nil,
            dns: [],
            dnsSearch: [],
            capAdd: body.HostConfig?.CapAdd ?? [],
            capDrop: body.HostConfig?.CapDrop ?? [],
            ulimits: [],
            networks: attachNetworks,
            platform: nil,
            workdir: body.WorkingDir,
            entrypoint: body.Entrypoint?.joined(separator: " "),
            arguments: body.Cmd ?? [])
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

    private func containerInspect(_ id: String) async throws -> ShimResponse {
        // Fast path: single-container inspect (flat cost) + persisted create
        // body instead of enumerating every container via list.
        if let target = await passThroughID(id),
            let raw = try? await containers.inspect(target),
            let container = DockerMapper.container(fromRawInspect: raw)
        {
            let create = await state.createRequest(for: container.id)
            return Self.encode(DockerMapper.inspect(container, create: create))
        }
        let container = try await resolveContainer(id)
        let create = await state.createRequest(for: container.id)
        return Self.encode(DockerMapper.inspect(container, create: create))
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
    private func resolveID(_ ref: String) async throws -> String {
        if let fast = await passThroughID(ref) { return fast }
        return try await resolveContainer(ref).id
    }

    private static func isNotFound(_ error: Error) -> Bool {
        if case MicropodError.cliFailure(_, _, let stderr) = error {
            let text = stderr.lowercased()
            return text.contains("not found") || text.contains("no such container")
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

        if let raw = try? await containers.inspect(target),
            let container = DockerMapper.container(fromRawInspect: raw),
            DockerMapper.stateName(container.state) != "running"
        {
            return  // already stopped (docker-idiomatic 204/304 handling upstream)
        }

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
        return .status(204)
    }

    private func containerStop(_ id: String, _ request: ShimRequest) async throws -> ShimResponse {
        let timeout = Int(request.q("t")) ?? 10
        if let target = await passThroughID(id) {
            try await fastStop(target, timeout: timeout)
            return .status(204)
        }
        let container = try await resolveContainer(id)
        guard DockerMapper.stateName(container.state) != "exited" else { return .status(304) }
        try await fastStop(container.id, timeout: timeout)
        return .status(204)
    }

    private func containerDelete(_ id: String, _ request: ShimRequest) async throws -> ShimResponse {
        // docker-py sends force=True (capitalized) — parse case-insensitively.
        let forceFlag = request.q("force").lowercased()
        let force = forceFlag == "1" || forceFlag == "true"
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
        while true {
            // Flat-cost single-container inspect instead of full-list scans.
            if let raw = try? await containers.inspect(target),
                let container = DockerMapper.container(fromRawInspect: raw)
            {
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
            } else {
                // Gone from the runtime entirely. For `condition=removed` that
                // IS the awaited outcome; otherwise report the last exit code
                // we captured rather than hanging on a container that no
                // longer exists.
                let remembered = await state.exitCode(for: target)
                return Self.encodeBody(WaitResult(StatusCode: remembered ?? 0, Error: nil))
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
            Task.detached(priority: .userInitiated) {
                defer { continuation.finish() }
                do {
                    for try await line in stream {
                        continuation.yield(
                            ExecSession.frame(type: 1, payload: Data((line.text + "\n").utf8)))
                    }
                } catch {}
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
        guard let connection = AttachRegistry.shared.claim(containerID: id) else {
            try await containers.start(id)
            return
        }
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
        try await networks.create(
            name: name, internal: body.Internal ?? false,
            subnet: body.IPAM?.Config?.first?.Subnet,
            subnetV6: nil,
            driver: body.Driver,
            options: [],
            labels: (body.Labels ?? [:]).map { "\($0.key)=\($0.value)" })
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
        let list = try await volumes.list()
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
        return .status(204)
    }

    private func volumePrune() async throws -> ShimResponse {
        let before = try await volumes.list()
        _ = try await volumes.prune()
        let after = try await volumes.list()
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
