import Foundation
import MicropodCore
import MicropodRuntime

/// Route + JSON-projection layer over the MicropodCore services.
/// Responses use stable JSON keys that mirror the curated proto models.
final class APIHandlers: Sendable {
    /// The container CLI client, for services that run the CLI directly.
    let client: ContainerCLIClient
    let system: SystemService
    let images: ImageService
    let networks: NetworkService
    let compose: ComposeService
    /// The runtime-facing services: containers, logs, stats, volumes (native
    /// XPC or CLI), the native apiserver client (vsock bridge) and its
    /// exit-code registry. Resolved at start-up and swapped from CLI to
    /// native when the runtime comes up later — `Ping`, `GetSystem` and
    /// `GET /v1/system` re-resolve (rate-limited), a transport error forces
    /// it. Every request reads one snapshot and uses it throughout, so a swap
    /// never splits a request across backends; `runtime_backend` reports the
    /// snapshot's kind, which lets clients tell "running through the CLI"
    /// from "running natively" and refuse to benchmark against the former.
    let runtime: RuntimeHolder
    /// Long-lived so machine CPU % is a delta across consecutive requests.
    let machineStats: MachineStatsSampler
    let metrics = APIMetrics()
    let appControl = AppControlClient()
    let managedTerminals: ManagedTerminalSessions
    let managedControl: @Sendable (String) async throws -> IsolatedRuntimeStatus
    /// What the version manifest reads (Ping, GetSystem, GetUpdateState).
    let versionEnvironment: VersionEnvironment
    let desktopObserver = DesktopObserver()
    /// Ping's host-observed components, kept for 2 s (see the type).
    let hostComponents = HostComponentCache()
    /// The runtime's `vminit.image`, kept for five minutes: it only changes
    /// when the runtime is reconfigured. A failed read is kept 30 s, so a
    /// stopped runtime is not asked again on every Ping.
    let initImage: RuntimeDefaultInitImage
    /// Engine registry consulted by `Ping`, `GetSystem` and runtime management.
    let engineRegistry: EngineRegistry
    /// The metrics history `GetMetricsHistory` reads and `DeleteContainer`
    /// prunes (`MetricsStore.url(environment:)`: beside this API's socket).
    let metricsDatabase: URL

    init(
        client: ContainerCLIClient,
        system: SystemService,
        images: ImageService,
        networks: NetworkService,
        compose: ComposeService,
        runtime: RuntimeHolder,
        managedControl: @escaping @Sendable (String) async throws -> IsolatedRuntimeStatus = {
            try await ManagedRuntimeControl.request($0)
        },
        versionEnvironment: VersionEnvironment? = nil,
        engineRegistry: EngineRegistry = .shared,
        metricsDatabase: URL = MetricsStore.sharedURL
    ) {
        self.client = client
        self.metricsDatabase = metricsDatabase
        let versionEnvironment = versionEnvironment ?? .live(client: client)
        self.versionEnvironment = versionEnvironment
        self.engineRegistry = engineRegistry
        self.initImage = RuntimeDefaultInitImage(
            ttl: .seconds(300), failureTTL: .seconds(30), read: versionEnvironment.vminitImage)
        self.managedTerminals = ManagedTerminalSessions(client: client)
        self.system = system
        self.images = images
        self.networks = networks
        self.compose = compose
        self.runtime = runtime
        self.managedControl = managedControl
        self.machineStats = MachineStatsSampler(client: client)
    }

    /// The k8s engine drives the CLI directly (it manages its own micro-VM).
    var k8s: K8sService {
        K8sService(client: client)
    }

    /// Container machines (persistent VMs) — driven through the CLI on every
    /// backend; the native apiserver client doesn't cover them.
    var machines: MachineService {
        MachineService(client: client)
    }

    func usage(_ services: RuntimeServices) -> UsageService {
        UsageService(containers: services.containers, images: imageRouter(services), volumes: volumeRouter(services))
    }

    /// Apple's images routed across the enabled engines that keep their own
    /// (a pass-through when none do, or when this process routes nothing).
    func imageRouter(_ services: RuntimeServices) -> ImageRouter {
        ImageRouter(apple: images, registry: services.router?.registry)
    }

    /// `services.volumes` routed like `imageRouter`.
    func volumeRouter(_ services: RuntimeServices) -> VolumeRouter {
        VolumeRouter(apple: services.volumes, registry: services.router?.registry)
    }

    func hvfMachineClient() -> HVFMachineClient {
        if let hvf = engineRegistry.engine("hvf") as? HVFEngine {
            return hvf.machine
        }
        return HVFMachineClient()
    }

    /// `POST /v1/rig/hvf/update/rollback`: 200 once on known-good, 409 when
    /// deferred (nothing changed: workloads run, or idleness could not be
    /// confirmed; retry with `{"force": true}`), 500 when the rollback boot
    /// failed its probes.
    static func rollbackStatus(_ action: HVFActivationResult.Action) -> Int {
        switch action {
        case .noop, .rolledBack, .activated: return 200
        case .deferred: return 409
        case .failedRollback, .failed: return 500
        }
    }

    /// The rollback's result, with `error` (its detail) when it is not a success.
    struct RollbackReply: Encodable {
        let result: HVFActivationResult

        func encode(to encoder: any Encoder) throws {
            try result.encode(to: encoder)
            guard rollbackStatus(result.action) != 200 else { return }
            var c = encoder.container(keyedBy: ErrorKey.self)
            try c.encode(result.detail, forKey: .error)
        }

        private enum ErrorKey: String, CodingKey { case error }
    }

    func encodeJSONResponse<T: Encodable>(_ status: Int, _ value: T) throws -> HTTPResponse {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return .data(status, "application/json", try enc.encode(value))
    }

    static func probeLoopbackDepproxy() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:7677/healthz") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.0
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
            let http = resp as? HTTPURLResponse
        else { return false }
        return http.statusCode == 200
    }

    /// A transport error means the native backend's XPC connection may be
    /// gone for good: re-resolve without delaying the `unavailable` answer
    /// already on its way. The holder ignores it unless the backend can be
    /// replaced (CLI, or an invalidated connection).
    func scheduleRecovery(after error: Error) {
        guard case MicropodError.transport = error else { return }
        let runtime = self.runtime
        Task { _ = await runtime.refreshIfNeeded(force: true) }
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        if LiveEnvironment.isIsolatedRuntime,
            !IsolatedRuntimeRequestPolicy.allows(request.path)
        {
            return .json(
                403,
                [
                    "code": "permission_denied",
                    "message": "Use Micropod's runtime controls to manage the dedicated Apple runtime",
                ])
        }
        let desktopControl =
            request.path == "/health" || request.path == "/"
            || request.path == "/v1/system/update" || request.path == "/v1/system/update/apply"
            || request.path == "/v1/system/runtime" || request.path.hasPrefix("/v1/system/runtime/")
            || ["CheckForUpdates", "GetUpdateStatus", "ApplyUpdate"].contains(
                request.path.split(separator: "/").last.map(String.init) ?? "")
            // The version manifest and update state combine this account's
            // observations with the dedicated runtime's own (ConnectMount).
            || request.path.hasPrefix("/api/micropod.v1.")
                && ["Ping", "GetSystem", "GetUpdateState"].contains(
                    request.path.split(separator: "/").last.map(String.init) ?? "")
        if client.usesIsolatedTransport, !desktopControl {
            if request.method == .get, request.path == "/v1/system/dependency" {
                let report = await system.dependencyStatus()
                return .data(200, "application/json", (try? JSONEncoder().encode(report)) ?? Data())
            }
            return .relay { connection in await IsolatedRuntimeProxy.forward(request, downstream: connection) }
        }
        let started = Date()
        let resp = await handleInner(request)
        let elapsed = Date().timeIntervalSince(started)
        metrics.record(
            route: request.path.isEmpty ? "/" : request.path,
            method: request.method.rawValue,
            status: Self.status(of: resp),
            duration: elapsed
        )
        return resp
    }

    private static func cliFrame(_ object: [String: Any]) -> Data {
        ((try? JSONSerialization.data(withJSONObject: object)) ?? Data()) + Data([10])
    }

    private static func status(of resp: HTTPResponse) -> Int {
        switch resp {
        case .json(let code, _): return code
        case .text(let code, _): return code
        case .data(let code, _, _): return code
        case .stream(let code, _, _): return code
        case .bridge(let code, _): return code
        case .relay: return 200
        }
    }

    private func handleInner(_ request: HTTPRequest) async -> HTTPResponse {
        // /metrics — Prometheus text format, always 200: this API's routes,
        // then the apiserver XPC traffic behind them.
        if request.path == "/metrics" {
            var body = metrics.render() + APIServerMetrics.render()
            var ciEnv = ProcessInfo.processInfo.environment
            ciEnv["MICROPOD_CI_ENGINE"] = ciEnv["MICROPOD_CI_ENGINE"] ?? "containerd"
            if let ciProm = try? await CIWorker(environment: ciEnv).prometheusMetrics() {
                body += "\n" + ciProm
            }
            return .text(200, body)
        }

        let path = request.path
        let method = request.method
        let segments = path.split(separator: "/").map(String.init)

        // CORS preflight — the Allow-* headers are attached by dispatch.
        if method == .options {
            return .data(204, "text/plain", Data())
        }

        if LiveEnvironment.isIsolatedRuntime, path == "/v1/managed/maintenance",
            method == .get
        {
            do {
                let services = await runtime.current
                let idle = try await ManagedRuntimeIdleCheck.check(
                    visible: { try await services.containers.list() },
                    ownedSandboxes: { try await self.sandboxEngine.list() })
                return .json(200, ["idle": idle])
            } catch { return .json(503, ["idle": false]) }
        }
        if LiveEnvironment.isIsolatedRuntime, method == .post {
            if path == "/v1/managed/dependency" {
                let services = await runtime.refreshIfNeeded()
                let report = await RuntimeDependencyProbe.inspect(system: system, services: services)
                return .data(200, "application/json", (try? JSONEncoder().encode(report)) ?? Data())
            }
            if path.hasPrefix("/v1/managed/terminal/") {
                do {
                    let body = try JSONSerialization.jsonObject(with: request.body) as? [String: String] ?? [:]
                    if path.hasSuffix("/open") {
                        let id = try await managedTerminals.open(
                            container: body["containerID"] ?? "", shell: body["shell"] ?? "/bin/sh")
                        return .json(200, ["sessionID": id.uuidString])
                    }
                    guard let text = body["sessionID"], let id = UUID(uuidString: text) else {
                        return .json(400, ["error": "Invalid terminal session"])
                    }
                    if path.hasSuffix("/read") {
                        let connection = try await managedTerminals.take(id)
                        let events = AsyncStream<Data> { continuation in
                            let task = Task {
                                do { for try await bytes in connection.stream { continuation.yield(bytes) } } catch {}
                                try? await managedTerminals.close(id)
                                continuation.finish()
                            }
                            continuation.onTermination = { _ in task.cancel() }
                        }
                        return .stream(200, "application/octet-stream", events)
                    }
                    if path.hasSuffix("/write"), let text = body["data"], let bytes = Data(base64Encoded: text),
                        bytes.count <= 65536
                    {
                        try await managedTerminals.write(bytes, id: id)
                        return .json(200, ["ok": true])
                    }
                    if path.hasSuffix("/close") {
                        try await managedTerminals.close(id)
                        return .json(200, ["ok": true])
                    }
                } catch { return .json(409, ["error": "The managed terminal is unavailable"]) }
                return .json(400, ["error": "Invalid terminal request"])
            }
            if path == "/v1/managed/cli" || path == "/v1/managed/cli-stream" {
                do {
                    let request = try JSONDecoder().decode(IsolatedRuntimeCLIRequest.self, from: request.body)
                    let command = try request.command()
                    if path.hasSuffix("cli-stream") {
                        let events = AsyncStream<Data> { continuation in
                            let task = Task {
                                do {
                                    for try await bytes in client.stream(
                                        command, reportExitCode: request.reportExitCode ?? false)
                                    {
                                        continuation.yield(Self.cliFrame(["chunk": bytes.base64EncodedString()]))
                                    }
                                    continuation.yield(Self.cliFrame(["complete": true]))
                                } catch {
                                    continuation.yield(
                                        Self.cliFrame([
                                            "error":
                                                "Managed container command did not complete; check runtime status before retrying"
                                        ]))
                                }
                                continuation.finish()
                            }
                            continuation.onTermination = { _ in task.cancel() }
                        }
                        return .stream(200, "application/x-ndjson", events)
                    }
                    let output = try await client.run(
                        command, timeout: .seconds(request.timeoutSeconds),
                        acceptingExitCodes: request.acceptingExitCodes)
                    return .json(200, ["output": output])
                } catch {
                    return .json(
                        409,
                        [
                            "code": "failed_precondition",
                            "message":
                                "Managed container command did not complete; check runtime status and command permissions before retrying",
                        ])
                }
            }
        }

        // /health
        if path == "/health" || path == "/" {
            return HTTPResponse.json(200, ["status": "ok"])
        }

        // Connect-protocol mount — proto-JSON over POST. The daemon API is
        // grouped into per-domain services (micropod.v1.ContainerService, …);
        // the pre-split micropod.v1.MicropodService prefix is kept as an
        // alias so v0.8 SDK clients keep working — method names are unique
        // across services, so dispatch never needs the service segment.
        if segments.count == 3, segments[0] == "api",
            segments[1].hasPrefix("micropod.v1."), method == .post,
            let resp = await connectRPC(method: segments[2], body: request.body, headers: request.headers)
        {
            return resp
        }

        guard segments.first == "v1" else { return .json(404, ["error": "not found"]) }
        let resource = segments.count > 1 ? segments[1] : ""
        // `GET /v1/system` is the REST liveness read: like Ping/GetSystem it
        // gives a CLI-started API the chance to swap to native first.
        let services =
            resource == "system" && method == .get
                && (segments.count == 2 || segments == ["v1", "system", "dependency"])
            ? await runtime.refreshIfNeeded() : await runtime.current

        do {
            switch (resource, method) {
            // MARK: CI Worker Engine & Workload Health
            case ("ci", .get) where segments == ["v1", "ci", "health"]:
                do {
                    let report = try await ciWorker().health()
                    let enc = JSONEncoder()
                    enc.dateEncodingStrategy = .iso8601
                    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                    let data = try enc.encode(report)
                    let status = report.verdict == .unhealthy ? 503 : 200
                    return .data(status, "application/json", data)
                } catch {
                    return .json(503, ["verdict": "unhealthy", "error": error.localizedDescription])
                }

            case ("ci", .get) where segments == ["v1", "ci", "metrics"]:
                var env = ProcessInfo.processInfo.environment
                env["MICROPOD_CI_ENGINE"] = env["MICROPOD_CI_ENGINE"] ?? "containerd"
                let ciWorker = CIWorker(environment: env)
                do {
                    if request.query["format"] == "otlp" {
                        return .data(200, "application/json", try await ciWorker.otlpMetricsJSON())
                    }
                    return .text(200, try await ciWorker.prometheusMetrics())
                } catch {
                    return .json(503, ["error": error.localizedDescription])
                }

            case ("ci", .get) where segments == ["v1", "ci", "traces"]:
                do {
                    return .data(200, "application/json", try ciWorker().tracesOTLPJSON())
                } catch {
                    return .json(503, ["error": error.localizedDescription])
                }

            case ("ci", .get) where segments == ["v1", "ci", "tracing"]:
                var env = ProcessInfo.processInfo.environment
                env["MICROPOD_CI_ENGINE"] = env["MICROPOD_CI_ENGINE"] ?? "containerd"
                do {
                    return .data(200, "application/json", try CIWorker(environment: env).tracingStatus())
                } catch {
                    return .json(503, ["error": error.localizedDescription])
                }

            case ("ci", .post)
            where segments == ["v1", "ci", "tracing", "enable"] || segments == ["v1", "ci", "tracing", "disable"]:
                var env = ProcessInfo.processInfo.environment
                env["MICROPOD_CI_ENGINE"] = env["MICROPOD_CI_ENGINE"] ?? "containerd"
                let enable = segments.last == "enable"
                do {
                    return .data(
                        200, "application/json", try CIWorker(environment: env).setLiveTracing(enabled: enable))
                } catch {
                    return .json(503, ["error": error.localizedDescription])
                }

            // MARK: Fleet Caches & Rootless Rig Controls (HVF + Sandbox)
            // The same functions as CacheService (CacheMount.swift).
            case ("caches", .get) where segments == ["v1", "caches"]:
                return try encodeJSONResponse(
                    200, try await cacheInspection(includeStats: request.query["stats"] != "0"))

            case ("caches", .get) where segments == ["v1", "caches", "dedupe"]:
                let buckets = Int(request.query["buckets"] ?? "16") ?? 16
                return try encodeJSONResponse(200, try await cacheDedupe(buckets: buckets))

            case ("caches", .post) where segments == ["v1", "caches", "prune"]:
                return try encodeJSONResponse(200, try await pruneCaches(body: request.body))

            case ("caches", .get) where segments == ["v1", "caches", "policy"]:
                return try encodeJSONResponse(200, try cachePolicyInForce())

            case ("caches", .put) where segments == ["v1", "caches", "policy"]:
                return try encodeJSONResponse(200, try setCachePolicy(body: request.body))

            case ("caches", .get) where segments.count == 4 && segments[2] == "explain":
                let container = segments[3].removingPercentEncoding ?? segments[3]
                return try encodeJSONResponse(200, try await explainCache(container))

            // The same functions as RigService (RigMount.swift).
            case ("rig", .get) where segments == ["v1", "rig", "mode"]:
                return .json(200, ControlPlaneJSON.rigMode(rigMode(listingModes: true)))

            case ("rig", .put) where segments == ["v1", "rig", "mode"]:
                let payload = try decodeBody(request.body)
                guard let raw = payload["mode"] as? String, !raw.isEmpty else {
                    throw BadRequest(message: "expected {\"mode\": \"container|sandbox\"}")
                }
                _ = try await setDefaultRuntime(raw, services)
                return .json(200, ControlPlaneJSON.rigMode(rigMode(listingModes: false)))

            case ("rig", .get) where segments == ["v1", "rig", "hvf", "update"]:
                let client = hvfMachineClient()
                return try encodeJSONResponse(200, HVFPayloadStore.status(layout: client.layout))

            case ("rig", .post) where segments == ["v1", "rig", "hvf", "update", "rollback"]:
                // `{}` or no body: the safe default, deferred while workloads
                // run. `{"force": true}` restarts the machine regardless.
                let force: Bool
                if request.body.isEmpty {
                    force = false
                } else {
                    force =
                        try RequestFields(request.body, allowed: ["force"], what: "hvf rollback").bool("force") ?? false
                }
                let result = try await HVFPayloadStore.rollback(layout: hvfMachineClient().layout, force: force)
                return try encodeJSONResponse(Self.rollbackStatus(result.action), RollbackReply(result: result))

            case ("rig", .post) where segments == ["v1", "rig", "hvf", "link-socket"]:
                let client = hvfMachineClient()
                let payload = request.body.isEmpty ? [:] : (try? decodeBody(request.body)) ?? [:]
                let force = (payload["force"] as? Bool) ?? false
                let linkURL = try client.linkCanonicalDockerSocket(force: force)
                return .json(
                    200,
                    [
                        "link": linkURL.path,
                        "target": client.layout.dockerSocket.path,
                        "dockerEndpoint": "unix://" + linkURL.path,
                    ])

            case ("rig", .get) where segments == ["v1", "rig", "health"]:
                return .json(200, Self.rigHealthBody(await rigHealthSnapshot()))

            // MARK: System
            case ("usage", .get):
                let report = try await usage(services).report()
                return .json(
                    200,
                    [
                        "images": report.images.map { entry -> [String: Any] in
                            [
                                "id": entry.image.id,
                                "names": entry.image.names,
                                "sizeBytes": entry.image.sizeBytes,
                                "createdAt": entry.image.createdAt,
                                "usedByContainerIDs": entry.usedByContainerIDs,
                                "inUse": entry.inUse,
                            ]
                        },
                        "volumes": report.volumes.map { entry -> [String: Any] in
                            [
                                "id": entry.volume.id,
                                "sizeBytes": entry.volume.sizeBytes,
                                "createdAt": entry.volume.createdAt,
                                "usedByContainerIDs": entry.usedByContainerIDs,
                                "inUse": entry.inUse,
                            ]
                        },
                        "reclaimableImageBytes": report.reclaimableImageBytes,
                        "reclaimableVolumeBytes": report.reclaimableVolumeBytes,
                        "stoppedContainerCount": report.stoppedContainerCount,
                    ])
            // MARK: App updates (Sparkle lives in the app process; the
            // control socket reaches it). 503 when the app isn't running.
            case ("system", .post) where segments.count == 3 && segments[2] == "update":
                guard appControl.isReachable else {
                    return .json(503, ["error": "Micropod app is not running (no control socket)"])
                }
                let report = try await appControl.checkForUpdates()
                return .json(202, report)

            case ("system", .post)
            where segments.count == 4 && segments[2] == "update"
                && segments[3] == "apply":
                guard appControl.isReachable else {
                    return .json(503, ["error": "Micropod app is not running (no control socket)"])
                }
                do {
                    let report = try await appControl.applyUpdate()
                    return .json(202, report)
                } catch AppControlError.callFailed(let message) {
                    return .json(409, ["error": message])
                }

            case ("system", .get) where segments.count == 3 && segments[2] == "update":
                guard appControl.isReachable else {
                    return .json(503, ["error": "Micropod app is not running (no control socket)"])
                }
                let report = try await appControl.updateStatus()
                return .json(200, report)

            case ("system", .get) where segments == ["v1", "system", "runtime"]:
                let report = try await managedControl("operation")
                return .json(
                    200, try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any] ?? [:])
            case ("system", .post) where segments.count == 4 && segments[2] == "runtime":
                guard ["install", "repair", "start", "stop", "restart", "cancel", "recover"].contains(segments[3])
                else { return .json(400, ["error": "Unknown runtime operation"]) }
                do {
                    let report = try await managedControl(segments[3])
                    return .json(
                        202,
                        try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any] ?? [:])
                } catch {
                    return .json(409, ["error": error.localizedDescription])
                }
            case ("system", .get) where segments == ["v1", "system", "dependency"]:
                let report = await RuntimeDependencyProbe.inspect(system: system, services: services)
                let data = try JSONEncoder().encode(report)
                return .json(200, try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])

            case ("system", .get):
                // hvf as the default runtime answers for itself, from live
                // machine state, as GetSystem and Ping do: no `container`
                // child to report Apple's runtime.
                if let machine = defaultHVFMachine {
                    let readiness = await machine.readinessStartingWhenDown()
                    var body: [String: Any] = [
                        "status": readiness.status.rawValue,
                        "detail": readiness.detail,
                        "cliVersion": "",
                        "apiServerVersion": readiness.version,
                        "appRoot": "",
                        "installRoot": machine.layout.root.path,
                        "backend": "hvf",
                        "runtimeBackend": "hvf",
                        "defaultRuntime": "hvf",
                        "features": APIFeatures.supported + readiness.features,
                    ]
                    var disk = Micropod_V1_DiskUsage()
                    disk.containers.sizeBytes =
                        (try? FileManager.default.attributesOfItem(atPath: machine.layout.disk.path)[.size] as? UInt64)
                        ?? 0
                    body["diskUsage"] = projection(disk)
                    return .json(200, body)
                }
                let status = try await system.status()
                var body: [String: Any] = [
                    "status": status.status,
                    "cliVersion": status.cliVersion,
                    "apiServerVersion": status.apiServerVersion,
                    "appRoot": status.appRoot,
                    // `backend` is the pre-Connect key; `runtimeBackend`
                    // matches the proto field name.
                    "backend": services.kind.rawValue,
                    "runtimeBackend": services.kind.rawValue,
                    "features": APIFeatures.supported
                        + (services.kind == .native ? [InitImageSelection.feature] : []),
                ]
                // A stopped runtime has no `df` to report — and asking would
                // turn a clean "stopped" into a CLI failure.
                if status.status != "stopped" {
                    body["diskUsage"] = projection(try await system.diskUsage())
                }
                if let health = services.health {
                    body["runtimeVersion"] = health.semver ?? health.apiServerVersion
                    body["runtimeCommit"] = health.apiServerCommit
                }
                return .json(200, body)

            // MARK: Runtimes (execution engines)
            case ("runtimes", .get) where segments.count == 2:
                return .json(200, try runtimesBody(try await runtimes(services)))

            case ("runtimes", .put) where segments.count == 3 && segments[2] == "default":
                let payload = try decodeBody(request.body)
                guard let name = payload["name"] as? String else {
                    throw BadRequest(message: "expected {\"name\": \"apple|docker|sandbox\"}")
                }
                return .json(200, try runtimesBody(try await setDefaultRuntime(name, services)))

            case ("runtimes", .patch) where segments.count == 3:
                let payload = try decodeBody(request.body)
                let enabled = payload["enabled"] as? Bool
                let endpoint = payload["endpoint"] as? String
                return .json(
                    200, try runtimesBody(try await updateRuntime(segments[2], enabled, endpoint, services)))

            // MARK: Containers
            case ("containers", .get) where segments.count == 2:
                let list = await withExitCodes(try await services.containers.list(), from: services.exitCodes)
                return .json(200, ["containers": list.map(projection)])

            case ("containers", .post) where segments.count == 2:
                let id = try await services.containers.run(try runRequest(from: request.body))
                return .json(201, ["id": id])

            case ("containers", .post) where segments.count == 3 && segments[2] == "create":
                let id = try await services.containers.create(try runRequest(from: request.body))
                return .json(201, ["id": id])

            case ("containers", .post)
            where segments.count == 4 && ["start", "stop", "restart", "kill"].contains(segments[3]):
                let id = segments[2]
                switch segments[3] {
                case "start": try await services.containers.start(id)
                case "stop": try await services.containers.stop(id)
                case "restart": try await services.containers.restart(id)
                default: try await services.containers.kill(id)
                }
                return .json(200, ["id": id, "action": segments[3]])

            case ("containers", .delete) where segments.count == 3:
                let id = segments[2]
                try await services.containers.delete(id, force: request.query["force"] == "true")
                return .json(200, ["deleted": id])

            // GET /v1/containers/:id/vsock/:port — raw duplex byte stream to
            // a guest vsock port. After the 200 head the connection is a
            // net.Conn-equivalent; run gRPC (vminitd on :1024) over it.
            case ("containers", .get)
            where segments.count == 5 && segments[3] == "vsock":
                guard let api = services.api else {
                    return .json(
                        501, ["error": "vsock bridge requires the native runtime backend"])
                }
                let id = segments[2]
                guard let port = UInt32(segments[4]) else {
                    return .json(400, ["error": "invalid vsock port '\(segments[4])'"])
                }
                let vsock = try await api.dial(id: id, port: port)
                return .bridge(200) { connection in
                    await VsockBridge.attach(connection: connection, vsock: vsock)
                }

            case ("containers", .get) where segments.count == 4 && segments[3] == "logs":
                let id = segments[2]
                let tail = Int(request.string("tail")) ?? 100
                let stream = services.logs.stream(id: id, tail: tail, boot: request.string("boot") == "true")
                return .stream(
                    200, "text/event-stream",
                    Self.serverSentEvents(stream))

            // MARK: Images
            // `?runtime=` (or a body `runtime`) picks an engine; without it
            // listings merge every enabled engine, pulls take the default
            // runtime and deletes the engine that has the image. Entries
            // from an engine other than Apple's carry a `runtime` key.
            case ("images", .get) where segments.count == 2:
                let list = try await imageRouter(services).listByRuntime(runtime: Self.runtimeQuery(request))
                return .json(200, ["images": list.map { Self.stamped(projection($0.image), runtime: $0.runtime) }])

            case ("images", .post) where segments.count == 3 && segments[2] == "pull":
                let payload = try decodeBody(request.body)
                let reference = payload["reference"] as? String ?? ""
                guard !reference.isEmpty else { return .json(400, ["error": "reference is required"]) }
                var lastLine = ""
                // No platform pulls linux/<host arch> (see ImageService.pull).
                let budget = try ImagePullBudget.api(headers: request.headers)
                for try await event in imageRouter(services).pullForAPI(
                    reference, platform: payload["platform"] as? String, budget: budget,
                    runtime: payload["runtime"] as? String)
                {
                    lastLine = event.line
                }
                return .json(200, ["pulled": reference, "lastLine": lastLine])

            case ("images", .delete) where segments.count == 3:
                let reference = segments[2].removingPercentEncoding ?? segments[2]
                try await imageRouter(services).delete(
                    reference, force: request.query["force"] == "true", runtime: Self.runtimeQuery(request))
                return .json(200, ["deleted": reference])

            // MARK: Volumes
            case ("volumes", .get) where segments.count == 2:
                let list = try await volumeRouter(services).list(runtime: Self.runtimeQuery(request))
                return .json(
                    200,
                    [
                        "volumes": list.map {
                            Self.stamped(projection($0), runtime: RuntimeStamp.runtime(of: $0))
                        }
                    ])

            case ("volumes", .post) where segments.count == 2:
                let payload = try decodeBody(request.body)
                let name = payload["name"] as? String ?? ""
                guard !name.isEmpty else { return .json(400, ["error": "name is required"]) }
                try await volumeRouter(services).create(
                    name: name, size: payload["size"] as? String, labels: [], options: [],
                    runtime: payload["runtime"] as? String)
                return .json(201, ["name": name])

            case ("volumes", .delete) where segments.count == 3:
                let name = segments[2].removingPercentEncoding ?? segments[2]
                try await volumeRouter(services).delete(name, runtime: Self.runtimeQuery(request))
                return .json(200, ["deleted": name])

            // MARK: Volume policy (native backend mount handling)
            case ("config", .get) where segments.count == 3 && segments[2] == "volumes":
                return .json(200, Self.policyBody(VolumePolicyStore.load()))

            case ("config", .put) where segments.count == 3 && segments[2] == "volumes":
                guard let policy = try? JSONDecoder().decode(VolumePolicy.self, from: request.body)
                else {
                    return .json(
                        400,
                        [
                            "error":
                                "invalid policy — expected {cloneMode: labels|goldens|all, "
                                + "goldenVolumes: [name], jobsOnly: bool, sync: full|fsync|nosync, "
                                + "cache: on|off|auto}"
                        ])
                }
                try VolumePolicyStore.save(policy)
                return .json(200, Self.policyBody(policy))

            // MARK: Networks
            case ("networks", .get) where segments.count == 2:
                let list = try await networks.list()
                return .json(200, ["networks": list.map(projection)])

            case ("networks", .post) where segments.count == 2:
                let payload = try decodeBody(request.body)
                let name = payload["name"] as? String ?? ""
                guard !name.isEmpty else { return .json(400, ["error": "name is required"]) }
                try await networks.create(
                    name: name, internal: (payload["internal"] as? Bool) ?? false,
                    subnet: payload["subnet"] as? String)
                return .json(201, ["name": name])

            case ("networks", .delete) where segments.count == 3:
                let name = segments[2].removingPercentEncoding ?? segments[2]
                try await networks.delete(name)
                return .json(200, ["deleted": name])

            // MARK: Stats
            case ("stats", .get):
                let snapshot = try await services.stats.snapshot()
                return .json(200, ["containers": snapshot.containers.map(projection), "sampledAt": snapshot.sampledAt])

            // MARK: Machines (persistent VMs)
            case ("machines", .get) where segments.count == 2:
                let list = try await machines.list()
                return .json(200, ["machines": list.map(projection)])

            case ("machines", .get) where segments.count == 3 && segments[2] == "stats":
                let snapshot = try await machineStats.snapshot()
                return .json(
                    200, ["machines": snapshot.machines.map(projection), "sampledAt": snapshot.sampledAt])

            case ("machines", .get) where segments.count == 4 && segments[3] == "stats":
                let snapshot = try await machineStats.snapshot(id: segments[2])
                return .json(
                    200, ["machines": snapshot.machines.map(projection), "sampledAt": snapshot.sampledAt])

            case ("machines", .get) where segments.count == 4 && segments[3] == "logs":
                let id = segments[2]
                let tail = Int(request.string("tail")) ?? 100
                let boot = request.string("boot") == "true"
                guard request.string("follow") == "true" else {
                    let lines = try await machines.logs(id, tail: tail, boot: boot)
                    return .json(200, ["id": id, "lines": lines.map(\.text)])
                }
                let stream = machines.streamLogs(id, tail: tail, boot: boot)
                return .stream(
                    200, "text/event-stream",
                    Self.serverSentEvents(stream))

            // MARK: Compose
            case ("compose", .post) where segments.count == 3 && segments[2] == "up":
                let payload = try decodeBody(request.body)
                let path = payload["path"] as? String ?? ""
                guard !path.isEmpty else { return .json(400, ["error": "path is required"]) }
                let url = URL(fileURLWithPath: path)
                let spec = try await compose.parse(url: url)
                let profiles = Set(
                    (payload["profiles"] as? String ?? "").split(separator: ",").map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }.filter { !$0.isEmpty })
                let plan = try compose.plan(spec: spec, enabledProfiles: profiles)
                var progress: [String] = []
                for try await line in compose.up(plan: plan) {
                    progress.append(line)
                }
                return .json(200, ["name": spec.name, "progress": progress])

            case ("compose", .post) where segments.count == 3 && segments[2] == "down":
                let payload = try decodeBody(request.body)
                let name = payload["name"] as? String ?? ""
                guard !name.isEmpty else { return .json(400, ["error": "name is required"]) }
                try await compose.down(composeName: name)
                return .json(200, ["toreDown": name])

            // MARK: Kubernetes (opt-in engine)
            case ("k8s", .get) where segments.count == 2:
                let config = k8s.loadConfig() ?? .defaults
                let s = try await k8s.status(name: config.clusterName)
                return .json(
                    200,
                    [
                        "enabled": k8s.isEnabled, "exists": s.exists, "running": s.running,
                        "address": s.address ?? "", "nodeReady": s.nodeReady,
                        "kubeconfigPath": s.kubeconfigPath,
                    ])

            case ("k8s", .get) where segments.count == 3 && segments[2] == "config":
                return .json(200, k8sConfigDict(k8s.loadConfig() ?? .defaults))

            case ("k8s", .post) where segments.count == 3 && segments[2] == "config":
                let payload = try decodeBody(request.body)
                var config = k8s.loadConfig() ?? .defaults
                if let v = payload["enabled"] as? Bool { config.enabled = v }
                if let v = payload["image"] as? String { config.image = v }
                if let v = payload["memory"] as? String { config.memory = v }
                if let v = payload["cpus"] as? Double { config.cpus = v }
                if let v = payload["metalLB"] as? Bool { config.metalLB = v }
                if let v = payload["ingress"] as? Bool { config.ingress = v }
                if let v = payload["lbPool"] as? String { config.lbPool = v }
                if let v = payload["clusterName"] as? String { config.clusterName = v }
                try k8s.saveConfig(config)
                return .json(200, k8sConfigDict(config))

            case ("k8s", .post) where segments.count == 3 && segments[2] == "up":
                guard k8s.isEnabled else {
                    return .json(
                        412,
                        [
                            "error":
                                "k8s engine is not enabled — POST /v1/k8s/config {enabled:true} or `micropod k8s enable`"
                        ])
                }
                let payload = try decodeBody(request.body)
                var config = k8s.loadConfig() ?? .defaults
                if let v = payload["image"] as? String { config.image = v }
                if let v = payload["memory"] as? String { config.memory = v }
                if let v = payload["cpus"] as? Double { config.cpus = v }
                if let v = payload["metalLB"] as? Bool { config.metalLB = v }
                if let v = payload["ingress"] as? Bool { config.ingress = v }
                if let v = payload["lbPool"] as? String { config.lbPool = v }
                if let v = payload["clusterName"] as? String { config.clusterName = v }
                final class Lines: @unchecked Sendable {
                    var items: [String] = []
                }
                let progress = Lines()
                let s = try await k8s.up(config) { progress.items.append($0) }
                return .json(
                    200,
                    [
                        "progress": progress.items, "address": s.address ?? "",
                        "nodeReady": s.nodeReady, "kubeconfigPath": s.kubeconfigPath,
                    ])

            case ("k8s", .post) where segments.count == 3 && segments[2] == "down":
                guard k8s.isEnabled else {
                    return .json(412, ["error": "k8s engine is not enabled"])
                }
                let config = k8s.loadConfig() ?? .defaults
                try await k8s.down(config)
                return .json(200, ["removed": config.clusterName])

            case ("k8s", .get) where segments.count == 3 && segments[2] == "kubeconfig":
                guard let contents = try? String(contentsOf: k8s.kubeconfigURL, encoding: .utf8)
                else {
                    return .json(404, ["error": "no kubeconfig — POST /v1/k8s/up first"])
                }
                return .json(200, ["path": k8s.kubeconfigURL.path, "contents": contents])

            case ("k8s", .get) where segments.count == 3 && segments[2] == "images":
                let refs = try await k8s.listImages()
                return .json(200, ["refs": refs])

            case ("k8s", .post) where segments.count == 3 && segments[2] == "images":
                guard k8s.isEnabled else {
                    return .json(412, ["error": "k8s engine is not enabled"])
                }
                let payload = try decodeBody(request.body)
                let ref = payload["ref"] as? String
                let archive =
                    (payload["archive"] as? String).flatMap { Data(base64Encoded: $0) }
                guard ref != nil || archive != nil else {
                    return .json(
                        400,
                        [
                            "error":
                                "POST /v1/k8s/images needs {\"ref\": \"image:tag\"} or {\"archive\": \"<base64 tar>\"}"
                        ])
                }
                final class LoadLines: @unchecked Sendable {
                    var items: [String] = []
                }
                let progress = LoadLines()
                let loaded = try await k8s.loadImage(ref: ref, archiveData: archive) {
                    progress.items.append($0)
                }
                return .json(
                    200,
                    ["progress": progress.items, "ref": loaded.ref, "bytes": loaded.bytes])

            // MARK: Exec
            case ("exec", .post):
                let payload = try decodeBody(request.body)
                let id = payload["id"] as? String ?? ""
                let command = payload["command"] as? String ?? ""
                guard !id.isEmpty, !command.isEmpty else {
                    return .json(400, ["error": "id and command are required"])
                }
                let result = try await services.containers.execDetailed(
                    ContainerExecRequest(containerID: id, arguments: [command], workdir: payload["workdir"] as? String))
                return .json(
                    200,
                    [
                        "output": result.output,
                        "error": result.error,
                        "exitCode": result.exitCode,
                    ])

            default:
                return .json(404, ["error": "not found: \(method.rawValue) \(path)"])
            }
        } catch is ImagePullBudget.InvalidHeaders {
            return .json(400, ["error": "Invalid image pull budget headers"])
        } catch let error as BadRequest {
            return .json(400, ["error": error.message])
        } catch let error as AppControlError {
            // App down / socket broken / updater refused → service unavailable.
            return .json(503, ["error": error.localizedDescription])
        } catch let error as MicropodError {
            scheduleRecovery(after: error)
            if case .transport = error {
                return .json(503, ["error": error.localizedDescription])
            }
            return .json(500, ["error": error.localizedDescription])
        } catch {
            return .json(500, ["error": error.localizedDescription])
        }
    }

    // MARK: - Body helpers

    private func decodeBody(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MicropodError.message("invalid JSON body")
        }
        return object
    }

    /// `runtime` must be an engine-name string when present.
    private func runtimeName(_ raw: Any?) throws -> String? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let name = raw as? String, name.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil
        else { throw BadRequest(message: "runtime must be an engine name, e.g. \"sandbox\"") }
        return name
    }

    private func runRequest(from data: Data) throws -> ContainerRunRequest {
        let payload = try decodeBody(data)
        let env = (payload["env"] as? [String]) ?? []
        let ports: [PortSpec] = ((payload["ports"] as? [[String: Any]]) ?? []).compactMap { port in
            guard let containerPort = port["containerPort"] as? Int else { return nil }
            return PortSpec(
                hostPort: (port["hostPort"] as? Int) ?? 0,
                containerPort: containerPort,
                transportProtocol: (port["protocol"] as? String) ?? "tcp",
                hostIP: port["hostIP"] as? String)
        }
        let labels: [LabelSpec] = ((payload["labels"] as? [String: String]) ?? [:]).map {
            LabelSpec(key: $0.key, value: $0.value)
        }
        let volumes = (payload["volumes"] as? [String]) ?? []
        // Container ids and volume names are clone-path components
        // (`<cloneRoot>/<id>/<volume>.img`) that reach the clone-dir
        // lifecycle before the runtime validates them: the runtime's id
        // grammar (names) and volume grammar (named volumes; no 63-character
        // cap) are enforced before dispatch (`VolumeClone.requireSafeComponent`
        // and `requireSafeVolumeName` guard the paths themselves).
        if let name = payload["name"] as? String, !VolumeClone.isSafeComponent(name) {
            throw BadRequest(message: "name '\(name)' must match \(VolumeClone.componentGrammar)")
        }
        let named = VolumeAttachments.namedVolumes(in: volumes)
        if let volume = named.first(where: { !VolumeClone.isSafeVolumeName($0) }) {
            throw BadRequest(message: "volume name '\(volume)' must match \(VolumeClone.volumeNameGrammar)")
        }
        // A present-but-mistyped security field is an error, never a silent
        // default: `["NET_ADMIN", 5]` must not quietly become "no cap_add".
        func stringList(_ key: String) throws -> [String] {
            guard let raw = payload[key], !(raw is NSNull) else { return [] }
            guard let list = raw as? [Any] else {
                throw BadRequest(message: "\(key) must be an array of strings")
            }
            return try list.enumerated().map { index, entry in
                guard let name = entry as? String else {
                    throw BadRequest(message: "\(key)[\(index)] must be a string")
                }
                return name
            }
        }
        func flag(_ key: String) throws -> Bool {
            guard let raw = payload[key], !(raw is NSNull) else { return false }
            guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw BadRequest(message: "\(key) must be a boolean")
            }
            return number.boolValue
        }
        let capAdd: [String]
        let capDrop: [String]
        let privileged = try flag("privileged")
        let rosetta = try flag("rosetta")
        do {
            capAdd = try LinuxCapabilities.normalize(try stringList("capAdd"))
            capDrop = try LinuxCapabilities.normalize(try stringList("capDrop"))
            try LinuxCapabilities.validateCombination(capAdd: capAdd, capDrop: capDrop, privileged: privileged)
        } catch let error as LinuxCapabilities.InvalidName {
            throw BadRequest(message: error.description)
        } catch let error as LinuxCapabilities.Conflict {
            throw BadRequest(message: error.description)
        }
        return ContainerRunRequest(
            image: payload["image"] as? String ?? "",
            name: payload["name"] as? String,
            detach: (payload["detach"] as? Bool) ?? true,
            cpus: payload["cpus"] as? Double,
            memory: payload["memory"] as? String,
            env: env,
            publishedPorts: ports,
            volumes: volumes,
            labels: labels,
            useInit: (payload["init"] as? Bool) ?? false,
            rosetta: rosetta,
            capAdd: capAdd,
            capDrop: capDrop,
            arguments: (payload["arguments"] as? [String]) ?? [],
            privileged: privileged,
            runtime: try runtimeName(payload["runtime"]))
    }

    // MARK: - JSON projections (proto → API JSON)

    /// `VolumePolicy` → response JSON (`sync` omitted when unset so the
    /// per-mount defaults are visible as "not overridden").
    private static func policyBody(_ policy: VolumePolicy) -> [String: Any] {
        var body: [String: Any] = [
            "cloneMode": policy.cloneMode.rawValue,
            "goldenVolumes": policy.goldenVolumes,
            "jobsOnly": policy.jobsOnly,
            "cache": policy.cache.rawValue,
            "labels": [
                "clone": "com.micropod.cache.clone",
                "sync": "com.micropod.volume.sync",
                "cache": "com.micropod.volume.cache",
            ],
        ]
        if let sync = policy.sync { body["sync"] = sync.rawValue }
        return body
    }

    private func k8sConfigDict(_ c: K8sConfig) -> [String: Any] {
        [
            "enabled": c.enabled, "image": c.image, "memory": c.memory,
            "cpus": c.cpus, "metalLB": c.metalLB, "ingress": c.ingress,
            "lbPool": c.lbPool ?? "", "clusterName": c.clusterName,
        ]
    }

    private func projection(_ container: Micropod_V1_Container) -> [String: Any] {
        [
            "id": container.id,
            "runtime": container.runtime,
            "state": container.state,
            "exitCode": container.exitCode,
            "image": container.image,
            "createdAt": container.createdAt,
            "ipv4Address": container.ipv4Address,
            "networks": container.networks,
            "env": container.env,
            "labels": container.labels,
            "platform": container.platform,
            "readOnly": container.readOnly,
            "useInit": container.useInit,
            "rosetta": container.rosetta,
            "ports": container.publishedPorts.map { port in
                [
                    "hostPort": port.hostPort, "containerPort": port.containerPort,
                    "protocol": port.`protocol`, "hostIP": port.hostIp,
                ]
            },
            "mounts": container.mounts.map { mount in
                [
                    "type": mount.type, "source": mount.source, "destination": mount.destination,
                    "readOnly": mount.readOnly,
                ]
            },
            "resources": ["cpus": container.resources.cpus, "memoryBytes": container.resources.memoryBytes],
        ]
    }

    /// `?runtime=`, when given and non-empty.
    static func runtimeQuery(_ request: HTTPRequest) -> String? {
        request.query["runtime"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A projection from an engine other than Apple's gains a `runtime`
    /// key; Apple's stay exactly as they were.
    static func stamped(_ projection: [String: Any], runtime: String) -> [String: Any] {
        guard runtime != "apple" else { return projection }
        var stamped = projection
        stamped["runtime"] = runtime
        return stamped
    }

    private func projection(_ image: Micropod_V1_Image) -> [String: Any] {
        [
            "id": image.id,
            "names": image.names,
            "digest": image.digest,
            "sizeBytes": image.sizeBytes,
            "createdAt": image.createdAt,
            "variants": image.variants.map { variant in
                ["os": variant.os, "architecture": variant.architecture]
            },
        ]
    }

    private func projection(_ volume: Micropod_V1_Volume) -> [String: Any] {
        [
            "id": volume.id, "driver": volume.driver, "format": volume.format,
            "sizeBytes": volume.sizeBytes, "allocatedBytes": volume.allocatedBytes,
            "source": volume.source, "createdAt": volume.createdAt,
            "labels": volume.labels,
        ]
    }

    private func projection(_ network: Micropod_V1_Network) -> [String: Any] {
        [
            "id": network.id, "mode": network.mode, "plugin": network.plugin,
            "ipv4Subnet": network.ipv4Subnet, "ipv4Gateway": network.ipv4Gateway,
            "ipv6Subnet": network.ipv6Subnet, "createdAt": network.createdAt,
            "builtin": network.builtin, "labels": network.labels,
        ]
    }

    private func projection(_ stats: Micropod_V1_ContainerStats) -> [String: Any] {
        var result: [String: Any] = [
            "id": stats.id,
            "cpuPercent": stats.cpuPercent,
            "memoryUsedBytes": stats.memoryUsedBytes,
            "memoryLimitBytes": stats.memoryLimitBytes,
            "networkRxBytes": stats.networkRxBytes,
            "networkTxBytes": stats.networkTxBytes,
            "blockReadBytes": stats.blockReadBytes,
            "blockWriteBytes": stats.blockWriteBytes,
            "pids": stats.pids,
        ]
        if stats.hasBlockIoObserved { result["blockIoObserved"] = stats.blockIoObserved }
        return result
    }

    private func projection(_ machine: MachineEntry) -> [String: Any] {
        [
            "id": machine.name, "state": machine.state ?? "", "ipAddress": machine.ip ?? "",
            "cpus": machine.cpus ?? 0, "memoryBytes": machine.memoryBytes ?? 0,
            "diskBytes": machine.diskBytes ?? 0, "createdAt": machine.created ?? "",
            "default": machine.defaultMachine ?? false,
        ]
    }

    private func projection(_ stats: Micropod_V1_MachineStats) -> [String: Any] {
        [
            "id": stats.id,
            "containerId": stats.containerID,
            "cpuPercent": stats.cpuPercent,
            "cpus": stats.cpus,
            "memoryUsedBytes": stats.memoryUsedBytes,
            "memoryLimitBytes": stats.memoryLimitBytes,
            "networkRxBytes": stats.networkRxBytes,
            "networkTxBytes": stats.networkTxBytes,
            "blockReadBytes": stats.blockReadBytes,
            "blockWriteBytes": stats.blockWriteBytes,
            "pids": stats.pids,
        ]
    }

    private func projection(_ usage: Micropod_V1_DiskUsage) -> [String: Any] {
        func category(_ c: Micropod_V1_DiskCategory) -> [String: Any] {
            [
                "total": c.total, "active": c.active, "sizeBytes": c.sizeBytes,
                "reclaimableBytes": c.reclaimableBytes,
            ]
        }
        return [
            "containers": category(usage.containers),
            "images": category(usage.images),
            "volumes": category(usage.volumes),
            "totalReclaimableBytes": usage.totalReclaimableBytes,
        ]
    }
}

/// A request the REST handlers refuse before it reaches a service — `400`.
struct BadRequest: Error {
    let message: String
}

/// A JSON object body read field by field. A key outside `allowed`, or a
/// field of the wrong JSON type (`"true"` or `1` for a boolean, `1.5` for an
/// integer), is a `BadRequest`, never a silent default. `null` reads as
/// absent.
struct RequestFields {
    private let payload: [String: Any]
    private let what: String

    init(_ body: Data, allowed: Set<String>, what: String) throws {
        self.what = what
        guard !body.isEmpty else { throw BadRequest(message: "\(what): expected a JSON object body") }
        guard let object = try? JSONSerialization.jsonObject(with: body), let payload = object as? [String: Any]
        else { throw BadRequest(message: "\(what): the body is not a JSON object") }
        if let unknown = payload.keys.filter({ !allowed.contains($0) }).sorted().first {
            throw BadRequest(
                message: "\(what): unknown field '\(unknown)' (accepted: \(allowed.sorted().joined(separator: ", ")))")
        }
        self.payload = payload
    }

    /// No field has a value, apart from `null` for a key in `clearable`
    /// (where it means "clear this setting").
    func namesNothing(clearable: Set<String>) -> Bool {
        !payload.keys.contains { value($0) != nil || clearable.contains($0) }
    }

    /// The key is in the body, possibly as `null`.
    func contains(_ key: String) -> Bool { payload[key] != nil }

    private func value(_ key: String) -> Any? {
        guard let value = payload[key], !(value is NSNull) else { return nil }
        return value
    }

    private func invalid(_ key: String, _ want: String) -> BadRequest {
        BadRequest(message: "\(what): \(key) must be \(want)")
    }

    func bool(_ key: String) throws -> Bool? {
        guard let raw = value(key) else { return nil }
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw invalid(key, "a boolean")
        }
        return number.boolValue
    }

    func string(_ key: String) throws -> String? {
        guard let raw = value(key) else { return nil }
        guard let text = raw as? String else { throw invalid(key, "a string") }
        return text
    }

    func strings(_ key: String) throws -> [String]? {
        guard let raw = value(key) else { return nil }
        guard let strings = raw as? [String] else { throw invalid(key, "an array of strings") }
        return strings
    }

    /// A JSON integer (`stringValue` keeps every digit, where `int64Value`
    /// would truncate 1.5 or wrap 2^64).
    private func integerText(_ key: String) -> String? {
        guard let number = value(key) as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.stringValue
    }

    func int64(_ key: String) throws -> Int64? {
        guard value(key) != nil else { return nil }
        guard let text = integerText(key), let number = Int64(text) else { throw invalid(key, "an integer") }
        return number
    }

    func uint64(_ key: String) throws -> UInt64? {
        guard value(key) != nil else { return nil }
        guard let text = integerText(key), let number = UInt64(text) else {
            throw invalid(key, "a non-negative integer")
        }
        return number
    }
}

// MARK: - Cache prune and policy bodies

extension APIHandlers {
    static let cachePruneFields: Set<String> = [
        "dryRun", "all", "scope", "tool", "maxBytes", "olderThanSecs", "partialGoBuild", "safetyCutoffSecs",
        "maxUnits", "reason",
    ]

    /// `POST /v1/caches/prune`'s body. A prune is a dry run unless the body
    /// says `"dryRun": false`, and an apply naming no scope, tool, maxBytes
    /// or olderThanSecs — every idle unit in every scope — also needs
    /// `"all": true`. An empty, malformed or mistyped body is a 400 and
    /// never reaches the guest.
    static func cachePruneRequest(_ body: Data) throws -> HVFCachePruneRequest {
        let fields = try RequestFields(body, allowed: cachePruneFields, what: "cache prune")
        func positive<Number: BinaryInteger>(_ value: Number?, _ key: String) throws -> Number? {
            guard let value else { return nil }
            guard value > 0 else { throw BadRequest(message: "cache prune: \(key) must be positive") }
            return value
        }
        let request = HVFCachePruneRequest(
            scope: try fields.string("scope"),
            tool: try fields.string("tool"),
            olderThanSecs: try positive(fields.int64("olderThanSecs"), "olderThanSecs"),
            maxBytes: try positive(fields.uint64("maxBytes"), "maxBytes"),
            partialGoBuild: try fields.bool("partialGoBuild"),
            safetyCutoffSecs: try positive(fields.int64("safetyCutoffSecs"), "safetyCutoffSecs"),
            maxUnits: try positive(fields.int64("maxUnits"), "maxUnits").map { Int($0) },
            dryRun: try fields.bool("dryRun") ?? true,
            reason: try fields.string("reason") ?? "api")
        let all = try fields.bool("all") ?? false
        if let scope = request.scope, !HVFMachineCachePolicy.isValidScope(scope) {
            throw BadRequest(message: "cache prune: scope '\(scope)' must match ^[a-z0-9][a-z0-9_-]{0,62}$")
        }
        if let tool = request.tool, (try? HVFMachineCachePolicy.normalizedTools([tool])) == nil {
            throw BadRequest(
                message: "cache prune: unknown tool '\(tool)' (known: "
                    + "\(HVFMachineCachePolicy.toolNames.joined(separator: ", ")))")
        }
        let selected =
            request.scope != nil || request.tool != nil || request.maxBytes != nil || request.olderThanSecs != nil
        if !request.dryRun, !selected, !all {
            throw BadRequest(
                message: "cache prune: \"dryRun\": false with no scope, tool, maxBytes or olderThanSecs evicts "
                    + "every idle cache unit in every scope; add \"all\": true to confirm")
        }
        return request
    }

    static let cachePolicyFields: Set<String> = [
        "mode", "defaultScope", "allowedScopes", "tools", "goTrimpath", "pnpmLegacyEnv", "sharedL0", "goProxy",
        "npmRegistry", "maxBytes", "maxAgeDays", "minFreeBytes", "defaultTrust", "proxyUntrusted",
    ]
    /// The optional settings `null` clears.
    static let cachePolicyClearableFields: Set<String> = [
        "goProxy", "npmRegistry", "maxBytes", "maxAgeDays", "minFreeBytes",
    ]

    /// `original` with the fields `PUT /v1/caches/policy` names, validated.
    /// `""` or `null` clears goProxy and npmRegistry; `0` or `null` clears
    /// maxBytes, maxAgeDays and minFreeBytes.
    static func cachePolicy(_ original: HVFMachineCachePolicy, patchedWith fields: RequestFields) throws
        -> HVFMachineCachePolicy
    {
        var policy = original
        if let raw = try fields.string("mode") {
            guard let mode = HVFMachineCachePolicy.Mode(rawValue: raw) else {
                throw BadRequest(message: "cache policy: mode must be auto or off, got '\(raw)'")
            }
            policy.mode = mode
        }
        if let scope = try fields.string("defaultScope") { policy.defaultScope = scope }
        if let scopes = try fields.strings("allowedScopes") { policy.allowedScopes = scopes }
        if let tools = try fields.strings("tools") { policy.tools = tools }
        if let trim = try fields.bool("goTrimpath") { policy.goTrimpath = trim }
        if let legacy = try fields.bool("pnpmLegacyEnv") { policy.pnpmLegacyEnv = legacy }
        if let shared = try fields.bool("sharedL0") { policy.sharedL0 = shared }
        if let raw = try fields.string("defaultTrust") {
            guard let trust = HVFMachineCachePolicy.Trust(rawValue: raw) else {
                throw BadRequest(message: "cache policy: defaultTrust must be trusted or untrusted, got '\(raw)'")
            }
            policy.defaultTrust = trust
        }
        if let proxy = try fields.bool("proxyUntrusted") { policy.proxyUntrusted = proxy }
        if fields.contains("goProxy") {
            policy.goProxy = try fields.string("goProxy").flatMap { $0.isEmpty ? nil : $0 }
        }
        if fields.contains("npmRegistry") {
            policy.npmRegistry = try fields.string("npmRegistry").flatMap { $0.isEmpty ? nil : $0 }
        }
        if fields.contains("maxBytes") {
            policy.maxBytes = try fields.uint64("maxBytes").flatMap { $0 == 0 ? nil : $0 }
        }
        if fields.contains("minFreeBytes") {
            policy.minFreeBytes = try fields.uint64("minFreeBytes").flatMap { $0 == 0 ? nil : $0 }
        }
        if fields.contains("maxAgeDays") {
            let days = try fields.uint64("maxAgeDays")
            guard days.map({ $0 <= 36_500 }) ?? true else {
                throw BadRequest(message: "cache policy: maxAgeDays must be at most 36500")
            }
            policy.maxAgeDays = days.flatMap { $0 == 0 ? nil : Int($0) }
        }
        do {
            try policy.validate()
        } catch {
            throw BadRequest(message: error.localizedDescription)
        }
        return policy
    }
}

// MARK: - Runtime engine management (shared by Connect + REST)

extension APIHandlers {
    /// The apple engine behind these services, whether routed or not.
    private func appleEngine(_ services: RuntimeServices) -> AppleEngine {
        services.router?.apple ?? AppleEngine(services: services)
    }

    func runtimes(_ services: RuntimeServices) async throws -> Micropod_V1_ListRuntimesResponse {
        await EngineRegistry.shared.describe(apple: appleEngine(services))
    }

    func setDefaultRuntime(_ name: String, _ services: RuntimeServices) async throws
        -> Micropod_V1_ListRuntimesResponse
    {
        try await EngineRegistry.shared.setDefault(name, apple: appleEngine(services))
        return try await runtimes(services)
    }

    func updateRuntime(_ name: String, _ enabled: Bool?, _ endpoint: String?, _ services: RuntimeServices)
        async throws -> Micropod_V1_ListRuntimesResponse
    {
        try EngineRegistry.shared.update(name, enabled: enabled, endpoint: endpoint)
        return try await runtimes(services)
    }

    func runtimesBody(_ response: Micropod_V1_ListRuntimesResponse) throws -> [String: Any] {
        [
            "default": response.default,
            "runtimes": response.runtimes.map { r in
                [
                    "name": r.name, "kind": r.kind, "description": r.description_p, "available": r.available,
                    "reason": r.reason, "version": r.version, "endpoint": r.endpoint, "default": r.default,
                    "enabled": r.enabled, "capabilities": r.capabilities,
                ] as [String: Any]
            },
        ]
    }
}

extension APIHandlers {
    /// Log lines as SSE frames. Ending the returned stream — the HTTP
    /// server drops it when the client disconnects — cancels the pump and
    /// with it the source follow loop. Without that link every abandoned
    /// `logs?follow` request kept a follow loop (an open log fd plus a
    /// liveness XPC poll a second) running until the container stopped.
    static func serverSentEvents(_ lines: AsyncThrowingStream<LogLine, Error>) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let pump = Task {
                do {
                    for try await line in lines {
                        let payload = "data: " + line.text.replacingOccurrences(of: "\n", with: "\\n") + "\n\n"
                        continuation.yield(Data(payload.utf8))
                    }
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }
}
