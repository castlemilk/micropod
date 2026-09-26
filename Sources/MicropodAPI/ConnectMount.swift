import Foundation
import MicropodCore
import MicropodRuntime
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
        // The liveness RPCs are where a CLI-started API notices the runtime
        // came up: they re-resolve the backend (rate-limited) before
        // answering, so `runtime_backend` flips to native on the first
        // Ping/GetSystem after the swap.
        let services =
            method == "Ping" || method == "GetSystem"
            ? await runtime.refreshIfNeeded() : await runtime.current
        do {
            switch method {
            case "GetSystem":
                var snapshot = Micropod_V1_SystemSnapshot()
                var status = try await system.status()
                status.runtimeBackend = services.kind.rawValue
                snapshot.status = status
                // A stopped runtime is a status, not an error — and it has no
                // `df` to report (asking would fail the whole call).
                if status.status != "stopped" {
                    snapshot.diskUsage = try await system.diskUsage()
                }
                return unary(snapshot)

            case "Ping":
                return unary(await ping(services))

            case "ListContainers":
                var resp = Micropod_V1_ListContainersResponse()
                resp.containers = await withExitCodes(
                    try await services.containers.list(), from: services.exitCodes)
                return unary(resp)

            case "GetContainer":
                let req = try decode(Micropod_V1_ContainerRef.self, body)
                try check(req)
                return unary(try await lookupContainer(req.id, in: services))

            case "WaitContainer":
                let req = try decode(Micropod_V1_WaitContainerRequest.self, body)
                try check(req)
                // Unknown ids fail fast — never a silent `exited: true`, and
                // never a wait against a container that does not exist.
                _ = try await lookupContainer(req.id, in: services)
                let seconds = req.timeoutSeconds == 0 ? 30 : min(req.timeoutSeconds, 300)
                return unary(try await waitContainer(id: req.id, timeout: .seconds(Int(seconds)), in: services))

            case "RunContainer":
                let req = try decode(Micropod_V1_RunContainerRequest.self, body)
                try check(req)
                let id = try await services.containers.run(runRequest(from: req))
                return unary(Micropod_V1_ContainerRef.with { $0.id = id })

            case "CreateContainer":
                let req = try decode(Micropod_V1_RunContainerRequest.self, body)
                try check(req)
                let id = try await services.containers.create(runRequest(from: req))
                return unary(Micropod_V1_ContainerRef.with { $0.id = id })

            case "StartContainer":
                let req = try decode(Micropod_V1_ContainerRef.self, body)
                try check(req)
                try await services.containers.start(req.id)
                return unary(Micropod_V1_Empty())

            case "StopContainer":
                let req = try decode(Micropod_V1_ContainerRef.self, body)
                try check(req)
                try await services.containers.stop(req.id)
                return unary(Micropod_V1_Empty())

            case "RestartContainer":
                let req = try decode(Micropod_V1_ContainerRef.self, body)
                try check(req)
                try await services.containers.restart(req.id)
                return unary(Micropod_V1_Empty())

            case "KillContainer":
                let req = try decode(Micropod_V1_ContainerRef.self, body)
                try check(req)
                try await services.containers.kill(req.id)
                return unary(Micropod_V1_Empty())

            case "DeleteContainer":
                let req = try decode(Micropod_V1_DeleteContainerRequest.self, body)
                try check(req)
                try await services.containers.delete(req.id, force: req.force)
                return unary(Micropod_V1_Empty())

            case "StreamContainerLogs":
                let req = try decodeStreamRequest(Micropod_V1_StreamLogsRequest.self, body)
                try check(req)
                let events = services.logs.stream(
                    id: req.id,
                    tail: req.tail > 0 ? Int(req.tail) : nil,
                    boot: req.boot)
                // `skip_lines`: a client re-opening after a transport error
                // already holds the first N lines — drop them server-side.
                // Each line stays its own LogChunk envelope (clients count
                // envelopes as lines); a flood packs many envelopes into one
                // awaited socket write instead of one write per line.
                return streamEnvelope(dropping(req.skipLines, from: events), coalesce: true) { line in
                    Micropod_V1_LogChunk.with { $0.text = line.text }
                }

            case "ListImages":
                var resp = Micropod_V1_ListImagesResponse()
                resp.images = try await images.list()
                return unary(resp)

            case "PullImage":
                let req = try decodeStreamRequest(Micropod_V1_PullImageRequest.self, body)
                try check(req)
                // No platform pulls linux/<host arch>, not every platform in
                // the index (see ImageService.pull).
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
                resp.volumes = try await services.volumes.list()
                return unary(resp)

            case "CreateVolume":
                let req = try decode(Micropod_V1_CreateVolumeRequest.self, body)
                try check(req)
                try await services.volumes.create(
                    name: req.name,
                    size: req.hasSize ? req.size : nil,
                    labels: req.labels,
                    options: req.options)
                return unary(Micropod_V1_Empty())

            case "DeleteVolume":
                let req = try decode(Micropod_V1_DeleteVolumeRequest.self, body)
                try check(req)
                try await services.volumes.delete(req.name)
                return unary(Micropod_V1_Empty())

            case "CloneVolume":
                let req = try decode(Micropod_V1_CloneVolumeRequest.self, body)
                try check(req)
                return unary(
                    try await services.volumes.clone(
                        source: req.source,
                        name: req.name,
                        size: req.hasSize ? req.size : nil,
                        labels: req.labels))

            case "CommitVolumeClone":
                let req = try decode(Micropod_V1_CommitVolumeCloneRequest.self, body)
                try check(req)
                let allocated = try await services.volumes.commitClone(containerID: req.containerID, volume: req.volume)
                return unary(Micropod_V1_CommitVolumeCloneResponse.with { $0.allocatedBytes = allocated })

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
                let req = try decode(Micropod_V1_GetStatsRequest.self, body)
                var resp = Micropod_V1_GetStatsResponse()
                // Empty ids = every running container (the pre-`ids` shape).
                resp.snapshot = try await services.stats.snapshot(ids: req.ids)
                return unary(resp)

            case "Exec":
                let req = try decode(Micropod_V1_ExecRequest.self, body)
                try check(req)
                // `arguments` is a verbatim argv; `command` is the older
                // split-on-spaces field and only consulted when it is empty.
                let argv =
                    req.arguments.isEmpty
                    ? req.command.split(separator: " ").map(String.init)
                    : req.arguments
                let result = try await services.containers.execDetailed(
                    ContainerExecRequest(
                        containerID: req.id,
                        arguments: argv,
                        workdir: req.hasWorkdir ? req.workdir : nil,
                        env: req.env))
                return unary(
                    Micropod_V1_ExecResponse.with {
                        $0.output = result.output
                        $0.exitCode = result.exitCode
                        $0.error = result.error
                    })

            case "GetUsage":
                return unary(usageReportProto(try await usage(services).report()))

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
        } catch {
            // Structured MicropodError cases, XPC transport failures and
            // upstream "code: detail" strings all classify through the shared
            // table (MicropodCore.ConnectCodeMapping) — tested in isolation.
            scheduleRecovery(after: error)
            return connectError(code(for: error), error.localizedDescription)
        }
    }

    /// Millisecond liveness for detection and health ticks — never `df`, and
    /// never an error: an unreachable runtime is `status: "stopped"`.
    ///
    /// Native backend: XPC `ping` with a 2 s ceiling (the apiserver answers in
    /// milliseconds when up). CLI backend: `container system status`, which
    /// `SystemService` already reports as a status when the daemon is down.
    private func ping(_ services: RuntimeServices) async -> Micropod_V1_PingResponse {
        var response = Micropod_V1_PingResponse()
        response.runtimeBackend = services.kind.rawValue
        if let api = services.api {
            if let health = try? await api.ping(timeout: .seconds(2)) {
                response.status = "running"
                response.apiServerVersion = health.apiServerVersion
            } else {
                response.status = "stopped"
                response.apiServerVersion = services.health?.apiServerVersion ?? ""
            }
            // Cached after the first call — no CLI spawn on the hot path.
            response.cliVersion = (try? await system.cliVersion()) ?? ""
            return response
        }
        do {
            let status = try await system.status()
            response.status = status.status
            response.apiServerVersion = status.apiServerVersion
            response.cliVersion = status.cliVersion
        } catch {
            // A stopped runtime never gets here (it is a status); whatever
            // did — timeout, missing CLI — means the runtime is not answering.
            response.status = "stopped"
            response.cliVersion = (try? await system.cliVersion()) ?? ""
        }
        return response
    }

    private func code(for error: Error) -> ConnectWireCode {
        ConnectWireCode(rawValue: ConnectCodeMapping.code(for: error)) ?? .internal
    }

    // MARK: - Container lookup / exit codes

    /// One container by id, or `not_found`. Goes through `list()` rather than
    /// `inspect` so absence is a plain "not in the list" instead of a
    /// backend-specific error text to classify; anything the list call
    /// throws (runtime down → `unavailable`) propagates untouched.
    private func lookupContainer(
        _ id: String, in services: RuntimeServices
    ) async throws -> Micropod_V1_Container {
        guard let container = try await listedContainer(id, in: services) else {
            throw ConnectDecodeError(code: .notFound, message: "container \(id) not found")
        }
        return await withExitCodes([container], from: services.exitCodes)[0]
    }

    /// The container as the runtime lists it, nil when it is not listed.
    /// Throws whatever the list call throws (runtime down → `unavailable`).
    private func listedContainer(
        _ id: String, in services: RuntimeServices
    ) async throws -> Micropod_V1_Container? {
        try await services.containers.list().first(where: { $0.id == id })
    }

    /// Folds registry exit codes into `Container.exit_code`. Only the native
    /// backend records them; on CLI (`exitCodes == nil`) the field stays
    /// empty rather than fabricating a value.
    func withExitCodes(
        _ list: [Micropod_V1_Container], from exitCodes: ExitCodeRegistry?
    ) async -> [Micropod_V1_Container] {
        guard let exitCodes else { return list }
        var out = list
        for index in out.indices {
            if let entry = await exitCodes.entry(for: out[index].id), let code = entry.exitCode {
                out[index].exitCode = String(code)
            }
        }
        return out
    }

    /// Waits for the container to be terminal or `timeout` to elapse — see
    /// ``ContainerExitWait``: a container the registry tracks wakes the
    /// request the moment its exit is recorded; any other is polled at 150 ms.
    /// A runtime that stops answering mid-wait throws (`unavailable`)
    /// instead of reporting a false exit.
    private func waitContainer(
        id: String, timeout: Duration, in services: RuntimeServices
    ) async throws -> Micropod_V1_WaitContainerResponse {
        let exitCodes = services.exitCodes
        let outcome = try await ContainerExitWait.wait(
            id: id, timeout: timeout, exitCodes: exitCodes
        ) { id, exitKnown in
            let state = await services.containers.state(of: id)
            guard state == "unknown", !exitKnown else { return state }
            // `state(of:)` answers `unknown` both for a container that is
            // gone and for a runtime that is not answering. The list tells
            // them apart: it throws when the runtime is down, and a
            // container it no longer lists has really vanished.
            return try await listedContainer(id, in: services)?.state ?? "unknown"
        }
        return .with {
            $0.exited = outcome.exited
            $0.known = outcome.known
            if let code = outcome.exitCode { $0.exitCode = code }
            $0.state = outcome.state
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
        if req.hasName { try safeComponent(req.name, "name") }
        for volume in VolumeAttachments.namedVolumes(in: req.volumes) { try safeVolumeName(volume, "volumes") }
        if req.hasCpus && req.cpus <= 0 {
            throw ConnectDecodeError(
                code: .invalidArgument, message: "cpus: must be greater than 0")
        }
        if req.hasPlatform {
            let parts = req.platform.split(separator: "/", omittingEmptySubsequences: false)
            if parts.count < 2 || parts.count > 3 || parts.contains(where: \.isEmpty) {
                throw ConnectDecodeError(
                    code: .invalidArgument, message: "platform: must be os/arch[/variant]")
            }
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

    private func check(_ req: Micropod_V1_WaitContainerRequest) throws {
        try required(req.id, "id")
        if req.timeoutSeconds < 0 {
            throw ConnectDecodeError(
                code: .invalidArgument, message: "timeoutSeconds: must be 0 or greater")
        }
    }

    private func check(_ req: Micropod_V1_StreamLogsRequest) throws {
        try required(req.id, "id")
        if req.tail < 0 {
            throw ConnectDecodeError(
                code: .invalidArgument, message: "tail: must be 0 or greater")
        }
        if req.skipLines < 0 {
            throw ConnectDecodeError(
                code: .invalidArgument, message: "skipLines: must be 0 or greater")
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

    private func check(_ req: Micropod_V1_CloneVolumeRequest) throws {
        try required(req.source, "source")
        try required(req.name, "name")
        try safeVolumeName(req.source, "source")
        try safeVolumeName(req.name, "name")
        // Cloning a volume onto itself would create a duplicate listing (or
        // trip the runtime's own already-exists) and clonefile the image
        // over itself — never meaningful.
        guard req.source != req.name else {
            throw ConnectDecodeError(code: .invalidArgument, message: "name: must differ from source")
        }
    }

    private func check(_ req: Micropod_V1_CommitVolumeCloneRequest) throws {
        try required(req.containerID, "containerId")
        try required(req.volume, "volume")
        try safeComponent(req.containerID, "containerId")
        try safeVolumeName(req.volume, "volume")
    }

    /// Container ids and volume names are clone-path components
    /// (`<cloneRoot>/<id>/<volume>.img`) that reach the clone-dir lifecycle
    /// before the runtime validates them, so the runtime's grammars are
    /// enforced here, before dispatch (`VolumeClone.requireSafeComponent`
    /// and `requireSafeVolumeName` guard the paths themselves): the
    /// container-id grammar for ids, and for volume names the volume
    /// grammar, which has no 63-character cap and is bounded only by the
    /// filename limit.
    private func safeComponent(_ value: String, _ field: String) throws {
        guard VolumeClone.isSafeComponent(value) else {
            throw ConnectDecodeError(
                code: .invalidArgument, message: "\(field): '\(value)' must match \(VolumeClone.componentGrammar)")
        }
    }

    private func safeVolumeName(_ value: String, _ field: String) throws {
        guard VolumeClone.isSafeVolumeName(value) else {
            throw ConnectDecodeError(
                code: .invalidArgument, message: "\(field): '\(value)' must match \(VolumeClone.volumeNameGrammar)")
        }
    }

    private func check(_ req: Micropod_V1_CreateNetworkRequest) throws {
        try required(req.name, "name")
    }

    private func check(_ req: Micropod_V1_DeleteNetworkRequest) throws {
        try required(req.name, "name")
    }

    /// `command` lost its `required` constraint when `arguments` arrived:
    /// exactly one of them has to carry the argv.
    private func check(_ req: Micropod_V1_ExecRequest) throws {
        try required(req.id, "id")
        if req.command.isEmpty && req.arguments.isEmpty {
            throw ConnectDecodeError(
                code: .invalidArgument, message: "command: value is required when arguments is empty")
        }
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

    /// Drops the first `count` events and forwards the rest (and the
    /// terminal error, if any) unchanged. `count <= 0` is the identity.
    private func dropping<E: Sendable>(
        _ count: Int64, from events: AsyncThrowingStream<E, Error>
    ) -> AsyncThrowingStream<E, Error> {
        guard count > 0 else { return events }
        return AsyncThrowingStream { continuation in
            let task = Task {
                var remaining = count
                do {
                    for try await event in events {
                        if remaining > 0 {
                            remaining -= 1
                            continue
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Wraps a throwing event stream into Connect envelopes: each message as
    /// a data frame, then an EndStream trailer. Errors surface in the
    /// trailer's `error` object per the Connect spec. With `coalesce`, whole
    /// envelopes are batched into writes of up to 64 KiB or 10 ms
    /// (`StreamFrameCoalescer`); the bytes on the wire are unchanged.
    private func streamEnvelope<E: Sendable, M: Message>(
        _ events: AsyncThrowingStream<E, Error>,
        coalesce: Bool = false,
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
                    // Same table as unary errors: an unknown id is
                    // `not_found`, a dropped XPC channel is `unavailable`
                    // (and prompts a backend re-resolution).
                    scheduleRecovery(after: error)
                    let code = ConnectCodeMapping.code(for: error)
                    let wire =
                        #"{"error":{"code":"\#(code)","message":"\#(Self.escapeJSON(error.localizedDescription))"}}"#
                    continuation.yield(ConnectEnvelope.frame(Data(wire.utf8), flags: 0x02))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return .stream(
            200, "application/connect+json", coalesce ? StreamFrameCoalescer.coalesce(stream) : stream)
    }

    private func connectError(_ code: ConnectWireCode, _ message: String) -> HTTPResponse {
        let body = #"{"code":"\#(code.rawValue)","message":"\#(Self.escapeJSON(message))"}"#
        return .data(code.httpStatus, "application/json", Data(body.utf8))
    }

    /// JSON string-literal escaping for the hand-built error bodies —
    /// `connectError` and the stream trailer. A refused client value, a CLI
    /// stderr line or a `requireDistinct` message reaches the body verbatim,
    /// so every control character U+0000–U+001F is escaped too (`\t`, `\n`,
    /// `\r`, `\b`, `\f` short forms, the rest as `\u00XX`): with one left
    /// bare the body is not JSON, and connect-go reads an unparseable 400 as
    /// `internal` — the client would see `internal` for precisely the inputs
    /// the guard refuses.
    private static func escapeJSON(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case "\u{08}": escaped += "\\b"
            case "\u{0C}": escaped += "\\f"
            case "\u{00}"..."\u{1F}": escaped += String(format: "\\u%04x", scalar.value)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
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
            user: proto.hasUser ? proto.user : nil,
            platform: proto.hasPlatform ? proto.platform : nil,
            workdir: proto.hasWorkdir ? proto.workdir : nil,
            entrypoint: proto.hasEntrypoint ? proto.entrypoint : nil,
            arguments: proto.arguments,
            noPull: proto.noPull)
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
