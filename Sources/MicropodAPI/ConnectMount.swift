import Foundation
import MicropodCore
import SwiftProtobuf

/// Connect-protocol mount: `POST /api/micropod.v1.<Service>/<Method>`.
///
/// The daemon API is grouped into per-domain services (ContainerService,
/// ImageService, VolumeService, NetworkService, ComposeService,
/// SystemService) — the service segment is matched by the caller; method
/// names are unique across services so dispatch keys on the method alone.
/// The pre-split `micropod.v1.MicropodService` prefix is accepted as an
/// alias for backward compatibility with v0.8 SDK clients.
///
/// Makes the documented Connect surface real on the shipped server — unary
/// calls take a proto-JSON body and return proto-JSON; server-streaming
/// RPCs speak Connect envelope framing (`application/connect+json`).
/// Requests decode straight into the same `Micropod_V1_*` messages the core
/// services already vend, so the wire contract stays true to proto/micropod/v1.
extension APIHandlers {

    /// Route `/api/micropod.v1.<Service>/*`. Returns nil for methods that
    /// don't exist so the caller can fall through to 404.
    func connectRPC(method: String, body: Data) async -> HTTPResponse? {
        do {
            switch method {
            case "GetSystem":
                var snapshot = Micropod_V1_SystemSnapshot()
                snapshot.status = try await system.status()
                snapshot.diskUsage = try await system.diskUsage()
                return unary(snapshot)

            case "ListContainers":
                var resp = Micropod_V1_ListContainersResponse()
                resp.containers = try await containers.list()
                return unary(resp)

            case "RunContainer":
                let req = try decode(Micropod_V1_RunContainerRequest.self, body)
                try check(req)
                let id = try await containers.run(runRequest(from: req))
                return unary(Micropod_V1_ContainerRef.with { $0.id = id })

            case "CreateContainer":
                let req = try decode(Micropod_V1_RunContainerRequest.self, body)
                try check(req)
                let id = try await containers.create(runRequest(from: req))
                return unary(Micropod_V1_ContainerRef.with { $0.id = id })

            case "StartContainer":
                let req = try decode(Micropod_V1_ContainerRef.self, body)
                try check(req)
                try await containers.start(req.id)
                return unary(Micropod_V1_Empty())

            case "StopContainer":
                let req = try decode(Micropod_V1_ContainerRef.self, body)
                try check(req)
                try await containers.stop(req.id)
                return unary(Micropod_V1_Empty())

            case "RestartContainer":
                let req = try decode(Micropod_V1_ContainerRef.self, body)
                try check(req)
                try await containers.restart(req.id)
                return unary(Micropod_V1_Empty())

            case "KillContainer":
                let req = try decode(Micropod_V1_ContainerRef.self, body)
                try check(req)
                try await containers.kill(req.id)
                return unary(Micropod_V1_Empty())

            case "DeleteContainer":
                let req = try decode(Micropod_V1_DeleteContainerRequest.self, body)
                try check(req)
                try await containers.delete(req.id, force: req.force)
                return unary(Micropod_V1_Empty())

            case "StreamContainerLogs":
                let req = try decodeStreamRequest(Micropod_V1_StreamLogsRequest.self, body)
                try check(req)
                let events = logs.stream(
                    id: req.id,
                    tail: req.tail > 0 ? Int(req.tail) : nil,
                    boot: req.boot)
                return streamEnvelope(events) { line in
                    Micropod_V1_LogChunk.with { $0.text = line.text }
                }

            case "ListImages":
                var resp = Micropod_V1_ListImagesResponse()
                resp.images = try await images.list()
                return unary(resp)

            case "PullImage":
                let req = try decodeStreamRequest(Micropod_V1_PullImageRequest.self, body)
                try check(req)
                let events = images.pull(
                    req.reference,
                    platform: req.hasPlatform ? req.platform : nil)
                return streamEnvelope(events) { event in
                    Micropod_V1_ProgressLine.with {
                        $0.line = event.line
                        if let stage = event.stage { $0.stage = Int32(stage) }
                        if let total = event.totalStages { $0.totalStages = Int32(total) }
                    }
                }

            case "DeleteImage":
                let req = try decode(Micropod_V1_DeleteImageRequest.self, body)
                try check(req)
                try await images.delete(req.reference, force: req.force)
                return unary(Micropod_V1_Empty())

            case "ListVolumes":
                var resp = Micropod_V1_ListVolumesResponse()
                resp.volumes = try await volumes.list()
                return unary(resp)

            case "CreateVolume":
                let req = try decode(Micropod_V1_CreateVolumeRequest.self, body)
                try check(req)
                try await volumes.create(
                    name: req.name,
                    size: req.hasSize ? req.size : nil,
                    labels: req.labels,
                    options: req.options)
                return unary(Micropod_V1_Empty())

            case "DeleteVolume":
                let req = try decode(Micropod_V1_DeleteVolumeRequest.self, body)
                try check(req)
                try await volumes.delete(req.name)
                return unary(Micropod_V1_Empty())

            case "ListNetworks":
                var resp = Micropod_V1_ListNetworksResponse()
                resp.networks = try await networks.list()
                return unary(resp)

            case "CreateNetwork":
                let req = try decode(Micropod_V1_CreateNetworkRequest.self, body)
                try check(req)
                try await networks.create(
                    name: req.name,
                    internal: req.`internal`,
                    subnet: req.hasSubnet ? req.subnet : nil,
                    subnetV6: req.hasSubnetV6 ? req.subnetV6 : nil,
                    driver: req.hasDriver ? req.driver : nil,
                    options: req.options,
                    labels: req.labels)
                return unary(Micropod_V1_Empty())

            case "DeleteNetwork":
                let req = try decode(Micropod_V1_DeleteNetworkRequest.self, body)
                try check(req)
                try await networks.delete(req.name)
                return unary(Micropod_V1_Empty())

            case "GetStats":
                var resp = Micropod_V1_GetStatsResponse()
                resp.snapshot = try await stats.snapshot()
                return unary(resp)

            case "Exec":
                let req = try decode(Micropod_V1_ExecRequest.self, body)
                try check(req)
                let result = try await containers.execDetailed(
                    ContainerExecRequest(
                        containerID: req.id,
                        arguments: req.command.split(separator: " ").map(String.init),
                        workdir: req.hasWorkdir ? req.workdir : nil,
                        env: req.env))
                return unary(
                    Micropod_V1_ExecResponse.with {
                        $0.output = result.output
                        $0.exitCode = result.exitCode
                        $0.error = result.error
                    })

            case "GetUsage":
                return unary(usageReportProto(try await usage.report()))

            case "GetVolumePolicy":
                return unary(volumePolicyProto(VolumePolicyStore.load()))

            case "SetVolumePolicy":
                let req = try decode(Micropod_V1_VolumePolicy.self, body)
                let policy = volumePolicy(from: req)
                try VolumePolicyStore.save(policy)
                return unary(volumePolicyProto(policy))

            case "CheckForUpdates":
                return unary(updateStatus(from: try await appControl.checkForUpdates()))

            case "GetUpdateStatus":
                return unary(updateStatus(from: try await appControl.updateStatus()))

            case "ApplyUpdate":
                return unary(updateStatus(from: try await appControl.applyUpdate()))

            case "ComposeUp":
                let req = try decodeStreamRequest(Micropod_V1_ComposeUpRequest.self, body)
                try check(req)
                let spec = try await compose.parse(url: URL(fileURLWithPath: req.path))
                let plan = try compose.plan(spec: spec, enabledProfiles: Set(req.profiles))
                let name = spec.name
                let events = AsyncThrowingStream<Micropod_V1_ComposeUpEvent, Error> { cont in
                    Task {
                        do {
                            for try await line in compose.up(plan: plan) {
                                cont.yield(.with { $0.line = line })
                            }
                            cont.yield(
                                .with {
                                    $0.name = name
                                    $0.done = true
                                })
                            cont.finish()
                        } catch {
                            cont.finish(throwing: error)
                        }
                    }
                }
                return streamEnvelope(events) { $0 }

            case "ComposeDown":
                let req = try decode(Micropod_V1_ComposeDownRequest.self, body)
                try check(req)
                try await compose.down(composeName: req.name)
                return unary(Micropod_V1_Empty())

            default:
                return nil
            }
        } catch let error as ConnectDecodeError {
            return connectError(error.code, error.message)
        } catch let error as AppControlError {
            switch error {
            case .callFailed:
                // e.g. ApplyUpdate before a download is staged.
                return connectError(.failedPrecondition, error.localizedDescription)
            default:
                return connectError(.unavailable, error.localizedDescription)
            }
        } catch let error as MicropodError {
            return connectError(codeFor(error), error.localizedDescription)
        } catch {
            // Upstream runtime errors arrive preformatted as "code: detail"
            // (e.g. "notFound: container with ID … not found") — map the
            // prefix to the matching Connect code instead of collapsing
            // everything to internal.
            let text = error.localizedDescription
            return connectError(codeForPrefixed(text), text)
        }
    }

    /// Maps structured `MicropodError` cases onto Connect codes.
    private func codeFor(_ error: MicropodError) -> ConnectWireCode {
        switch error {
        case .runtimeNotRunning, .cliUnavailable: return .unavailable
        case .cliTimeout: return .deadlineExceeded
        case .unsupported: return .unimplemented
        case .pullStalled: return .aborted
        default: return codeForPrefixed(error.localizedDescription)
        }
    }

    /// Reads an upstream "camelCaseCode: message" prefix into a wire code.
    private func codeForPrefixed(_ text: String) -> ConnectWireCode {
        guard let colon = text.firstIndex(of: ":") else { return .internal }
        switch String(text[..<colon]) {
        case "notFound": return .notFound
        case "invalidArgument": return .invalidArgument
        case "alreadyExists": return .alreadyExists
        case "unavailable", "runtimeNotRunning": return .unavailable
        case "unauthenticated": return .unauthenticated
        case "permissionDenied": return .permissionDenied
        case "failedPrecondition": return .failedPrecondition
        case "resourceExhausted": return .resourceExhausted
        case "deadlineExceeded", "timeout": return .deadlineExceeded
        default: return .internal
        }
    }

    // MARK: - Wire helpers

    /// Mirrors the `buf.validate` constraints declared on the protos — the Go
    /// apiserver enforces them via its protovalidate interceptor, but this
    /// in-process mount bypasses that chain, so required/non-empty fields are
    /// checked here before dispatch.
    private func required(_ value: String, _ field: String) throws {
        if value.isEmpty {
            throw ConnectDecodeError(
                code: .invalidArgument, message: "\(field): value is required")
        }
    }

    private func check(_ req: Micropod_V1_ContainerRef) throws {
        try required(req.id, "id")
    }

    private func check(_ req: Micropod_V1_RunContainerRequest) throws {
        try required(req.image, "image")
        if req.hasCpus && req.cpus <= 0 {
            throw ConnectDecodeError(
                code: .invalidArgument, message: "cpus: must be greater than 0")
        }
        for port in req.ports {
            if port.containerPort == 0 || port.containerPort > 65535 {
                throw ConnectDecodeError(
                    code: .invalidArgument,
                    message: "ports.containerPort: must be in 1...65535")
            }
            if port.hostPort > 65535 {
                throw ConnectDecodeError(
                    code: .invalidArgument,
                    message: "ports.hostPort: must be in 0...65535")
            }
        }
    }

    private func check(_ req: Micropod_V1_DeleteContainerRequest) throws {
        try required(req.id, "id")
    }

    private func check(_ req: Micropod_V1_StreamLogsRequest) throws {
        try required(req.id, "id")
        if req.tail < 0 {
            throw ConnectDecodeError(
                code: .invalidArgument, message: "tail: must be 0 or greater")
        }
    }

    private func check(_ req: Micropod_V1_PullImageRequest) throws {
        try required(req.reference, "reference")
    }

    private func check(_ req: Micropod_V1_DeleteImageRequest) throws {
        try required(req.reference, "reference")
    }

    private func check(_ req: Micropod_V1_CreateVolumeRequest) throws {
        try required(req.name, "name")
    }

    private func check(_ req: Micropod_V1_DeleteVolumeRequest) throws {
        try required(req.name, "name")
    }

    private func check(_ req: Micropod_V1_CreateNetworkRequest) throws {
        try required(req.name, "name")
    }

    private func check(_ req: Micropod_V1_DeleteNetworkRequest) throws {
        try required(req.name, "name")
    }

    private func check(_ req: Micropod_V1_ExecRequest) throws {
        try required(req.id, "id")
        try required(req.command, "command")
    }

    private func check(_ req: Micropod_V1_ComposeUpRequest) throws {
        try required(req.path, "path")
    }

    private func check(_ req: Micropod_V1_ComposeDownRequest) throws {
        try required(req.name, "name")
    }

    private func decode<M: Message>(_ type: M.Type, _ body: Data) throws -> M {
        do {
            return try M(jsonUTF8Data: body.isEmpty ? Data("{}".utf8) : body)
        } catch {
            throw ConnectDecodeError(
                code: .invalidArgument,
                message: "invalid request body: \(error.localizedDescription)")
        }
    }

    /// Server-streaming requests arrive envelope-framed; the first (and
    /// only) frame carries the proto-JSON request.
    private func decodeStreamRequest<M: Message>(_ type: M.Type, _ body: Data) throws -> M {
        var payload = body
        if body.count >= 5 {
            let length =
                Int(body[body.startIndex + 1]) << 24 | Int(body[body.startIndex + 2]) << 16
                | Int(body[body.startIndex + 3]) << 8 | Int(body[body.startIndex + 4])
            if body.count >= 5 + length {
                payload = Data(body[(body.startIndex + 5)..<(body.startIndex + 5 + length)])
            }
        }
        return try decode(type, payload)
    }

    private func unary<M: Message>(_ message: M) -> HTTPResponse {
        let body = (try? message.jsonUTF8Data()) ?? Data("{}".utf8)
        return .data(200, "application/json", body)
    }

    /// Wraps a throwing event stream into Connect envelopes: each message as
    /// a data frame, then an EndStream trailer. Errors surface in the
    /// trailer's `error` object per the Connect spec.
    private func streamEnvelope<E: Sendable, M: Message>(
        _ events: AsyncThrowingStream<E, Error>,
        map: @escaping @Sendable (E) -> M
    ) -> HTTPResponse {
        let stream = AsyncStream<Data> { continuation in
            let task = Task {
                do {
                    for try await event in events {
                        let payload = (try? map(event).jsonUTF8Data()) ?? Data("{}".utf8)
                        continuation.yield(ConnectEnvelope.frame(payload, flags: 0))
                    }
                    continuation.yield(ConnectEnvelope.frame(Data("{}".utf8), flags: 0x02))
                } catch {
                    let wire =
                        #"{"error":{"code":"unavailable","message":"\#(Self.escapeJSON(error.localizedDescription))"}}"#
                    continuation.yield(ConnectEnvelope.frame(Data(wire.utf8), flags: 0x02))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return .stream(200, "application/connect+json", stream)
    }

    private func connectError(_ code: ConnectWireCode, _ message: String) -> HTTPResponse {
        let body = #"{"code":"\#(code.rawValue)","message":"\#(Self.escapeJSON(message))"}"#
        return .data(code.httpStatus, "application/json", Data(body.utf8))
    }

    private static func escapeJSON(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    // MARK: - Proto → service conversion

    private func runRequest(from proto: Micropod_V1_RunContainerRequest) -> ContainerRunRequest {
        ContainerRunRequest(
            image: proto.image,
            name: proto.hasName ? proto.name : nil,
            // Connect unary calls can't carry an attached stdio session —
            // always run detached, matching the Go apiserver's behavior.
            detach: true,
            cpus: proto.hasCpus ? proto.cpus : nil,
            memory: proto.hasMemory ? proto.memory : nil,
            env: proto.env,
            publishedPorts: proto.ports.map {
                PortSpec(
                    hostPort: Int($0.hostPort),
                    containerPort: Int($0.containerPort),
                    transportProtocol: $0.protocol.isEmpty ? "tcp" : $0.protocol,
                    hostIP: $0.hostIp.isEmpty ? nil : $0.hostIp)
            },
            volumes: proto.volumes,
            labels: proto.labels.map { LabelSpec(key: $0.key, value: $0.value) },
            useInit: proto.init_p,
            arguments: proto.arguments)
    }

    private func usageReportProto(_ report: UsageService.Report) -> Micropod_V1_UsageReport {
        Micropod_V1_UsageReport.with { proto in
            proto.images = report.images.map { entry in
                Micropod_V1_UsageReport.ImageUsage.with {
                    $0.image = entry.image
                    $0.usedByContainerIds = entry.usedByContainerIDs
                    $0.inUse = entry.inUse
                }
            }
            proto.volumes = report.volumes.map { entry in
                Micropod_V1_UsageReport.VolumeUsage.with {
                    $0.volume = entry.volume
                    $0.usedByContainerIds = entry.usedByContainerIDs
                    $0.inUse = entry.inUse
                }
            }
            proto.reclaimableImageBytes = report.reclaimableImageBytes
            proto.reclaimableVolumeBytes = report.reclaimableVolumeBytes
            proto.stoppedContainerCount = Int32(report.stoppedContainerCount)
        }
    }

    private func volumePolicyProto(_ policy: VolumePolicy) -> Micropod_V1_VolumePolicy {
        Micropod_V1_VolumePolicy.with { proto in
            switch policy.cloneMode {
            case .labels: proto.cloneMode = .labels
            case .goldens: proto.cloneMode = .goldens
            case .all: proto.cloneMode = .all
            }
            proto.goldenVolumes = policy.goldenVolumes
            proto.jobsOnly = policy.jobsOnly
            if let sync = policy.sync {
                switch sync {
                case .full: proto.sync = .full
                case .fsync: proto.sync = .fsync
                case .nosync: proto.sync = .nosync
                }
            }
            switch policy.cache {
            case .on: proto.cache = .on
            case .off: proto.cache = .off
            case .auto: proto.cache = .auto
            }
        }
    }

    /// Proto → service policy. Unspecified enums fall back to the standard
    /// defaults (labels / no sync override / cache on), so a sparse body
    /// still produces a valid stored policy.
    private func volumePolicy(from proto: Micropod_V1_VolumePolicy) -> VolumePolicy {
        let cloneMode: VolumePolicy.CloneMode =
            switch proto.cloneMode {
            case .goldens: .goldens
            case .all: .all
            default: .labels
            }
        let sync: VolumePolicy.SyncMode? =
            switch proto.sync {
            case .full: .full
            case .fsync: .fsync
            case .nosync: .nosync
            default: nil
            }
        let cache: VolumePolicy.CacheMode =
            switch proto.cache {
            case .off: .off
            case .auto: .auto
            default: .on
            }
        return VolumePolicy(
            cloneMode: cloneMode,
            goldenVolumes: proto.goldenVolumes,
            jobsOnly: proto.jobsOnly,
            sync: sync,
            cache: cache)
    }

    /// App-control statusReport dictionary → typed UpdateStatus. Unknown
    /// keys are ignored so the app can extend the report without a
    /// coordinated daemon bump.
    private func updateStatus(from report: [String: Any]) -> Micropod_V1_UpdateStatus {
        Micropod_V1_UpdateStatus.with { proto in
            switch report["state"] as? String {
            case "unavailable": proto.state = .unavailable
            case "idle": proto.state = .idle
            case "checking": proto.state = .checking
            case "upToDate": proto.state = .upToDate
            case "updateAvailable": proto.state = .updateAvailable
            case "installing": proto.state = .installing
            case "error": proto.state = .error
            default: proto.state = .unspecified
            }
            proto.feedConfigured = (report["feedConfigured"] as? Bool) ?? false
            proto.currentVersion = (report["currentVersion"] as? String) ?? ""
            if let v = report["availableVersion"] as? String { proto.availableVersion = v }
            proto.downloaded = (report["downloaded"] as? Bool) ?? false
            if let v = report["downloadedVersion"] as? String { proto.downloadedVersion = v }
            proto.readyToInstall = (report["readyToInstall"] as? Bool) ?? false
            if let v = report["error"] as? String { proto.error = v }
            if let v = report["checkedAt"] as? String { proto.checkedAt = v }
        }
    }
}

/// Connect envelope framing — [flags:1][length:4 big-endian][payload].
enum ConnectEnvelope {
    static func frame(_ payload: Data, flags: UInt8) -> Data {
        var frame = Data()
        frame.append(flags)
        var length = UInt32(payload.count).bigEndian
        frame.append(Data(bytes: &length, count: 4))
        frame.append(payload)
        return frame
    }
}

/// Connect error codes + their unary HTTP status mapping (per the spec).
enum ConnectWireCode: String {
    case canceled, unknown
    case invalidArgument = "invalid_argument"
    case deadlineExceeded = "deadline_exceeded"
    case notFound = "not_found"
    case alreadyExists = "already_exists"
    case permissionDenied = "permission_denied"
    case resourceExhausted = "resource_exhausted"
    case failedPrecondition = "failed_precondition"
    case aborted
    case outOfRange = "out_of_range"
    case unimplemented
    case `internal`
    case unavailable
    case dataLoss = "data_loss"
    case unauthenticated

    var httpStatus: Int {
        switch self {
        case .canceled: return 499
        case .invalidArgument, .outOfRange: return 400
        case .deadlineExceeded: return 504
        case .notFound, .unimplemented: return 404
        case .alreadyExists, .aborted: return 409
        case .permissionDenied: return 403
        case .resourceExhausted: return 429
        case .failedPrecondition: return 412
        case .unauthenticated: return 401
        case .unavailable: return 503
        case .unknown, .internal, .dataLoss: return 500
        }
    }
}

struct ConnectDecodeError: Error {
    let code: ConnectWireCode
    let message: String
}
