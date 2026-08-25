import Foundation
import MicropodCore

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

    init(
        config: ShimConfig, state: ShimState, events: EventsHub,
        client: ContainerCLIClient
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
        let runRequest = try Self.buildRunRequest(from: body, name: requestedName)
        let id = try await containers.create(runRequest)
        await state.remember(id: id, name: requestedName, request: body)
        let response = DockerCreateResponse(Id: id, Warnings: [])
        if !notes.isEmpty {
            fputs("[shim] ryuk interception for \(id): \(notes.joined(separator: "; "))\n", stderr)
        }
        return .json(201, Self.encodeBody(response))
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
                    try await containers.start(target)
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
            try await containers.start(resolved)
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
        let running = DockerMapper.stateName(container.state) == "running"
        if running && !force {
            throw ShimError.conflict(
                "cannot remove container: container is running: stop the container before removing or force remove")
        }
        try await containers.delete(container.id, force: force)
        await state.forget(id: container.id)
        return .status(204)
    }

    private func containerWait(_ id: String, _ request: ShimRequest) async throws -> ShimResponse {
        let condition = request.q("condition").isEmpty ? "not-running" : request.q("condition")
        let target = try await resolveID(id)
        while true {
            // Flat-cost single-container inspect instead of full-list scans.
            if let raw = try? await containers.inspect(target),
                let container = DockerMapper.container(fromRawInspect: raw)
            {
                let stateName = DockerMapper.stateName(container.state)
                if stateName != "running" && condition != "removed" {
                    // The runtime omits exit codes for stopped containers;
                    // assume a clean exit unless an event captured one.
                    let parsed = Int(container.exitCode)
                    let remembered = await state.exitCode(for: target)
                    return Self.encode(WaitResult(StatusCode: parsed ?? remembered ?? 0, Error: nil))
                }
            } else if condition == "removed" || condition == "next-exit" {
                let remembered = await state.exitCode(for: target)
                return Self.encode(WaitResult(StatusCode: remembered ?? 0, Error: nil))
            } else {
                let list = try await containers.list()
                if !list.contains(where: { $0.id == target }) {
                    throw ShimError.notFound("container \(target) disappeared")
                }
            }
            try await Task.sleep(for: .milliseconds(200))
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
        try session.launchAndPump(connection: connection)
        await state.registerExec(
            ShimState.ExecRecord(
                id: record.id, containerID: record.containerID, cmd: record.cmd, running: true,
                exitCode: nil))
        return .hijacked
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
        try await volumes.create(name: name, size: nil, labels: [], options: [])
        return .json(
            201,
            Self.encodeBody(
                DockerVolume(
                    Name: name, Driver: body.Driver ?? "local",
                    Mountpoint: "~/.micropod/volumes/\(name)",
                    CreatedAt: ISO8601DateFormatter().string(from: Date()),
                    Labels: body.Labels ?? [:], Scope: "local")))
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
