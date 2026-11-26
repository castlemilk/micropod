import Foundation
import MicropodCore
import MicropodRuntime
import SwiftProtobuf

/// RigService and TelemetryService, plus the system and sandbox reports the
/// MCP server reads over Connect, and the code the REST routes under
/// `/v1/rig` and `/v1/ci` share with them.
extension APIHandlers {
    /// Dispatches a RigService, TelemetryService, `GetRuntimeDependency`,
    /// `GetDiskUsage` or `GetSandboxStatus` method; nil for any other name.
    func rigRPC(_ method: String, _ body: Data, binary: Bool) async throws -> HTTPResponse? {
        do {
            switch method {
            case "GetRigHealth":
                return unary(RigProto.health(await rigHealthSnapshot()), binary: binary)

            case "GetRigMode":
                return unary(rigMode(listingModes: true), binary: binary)

            case "SetRigMode":
                let req = try decode(Micropod_V1_SetRigModeRequest.self, body, binary: binary)
                guard !req.mode.isEmpty else {
                    throw ConnectDecodeError(code: .invalidArgument, message: "mode is required (container|sandbox)")
                }
                _ = try await setDefaultRuntime(req.mode, await runtime.current)
                return unary(rigMode(listingModes: true), binary: binary)

            case "GetHVFUpdateStatus":
                return unary(
                    RigProto.updateStatus(HVFPayloadStore.status(layout: hvfMachineClient().layout)), binary: binary)

            case "RollbackHVFUpdate", "ApplyHVFUpdate":
                let req = try decode(Micropod_V1_HVFUpdateRequest.self, body, binary: binary)
                let layout = hvfMachineClient().layout
                let result =
                    method == "ApplyHVFUpdate"
                    ? try await HVFPayloadStore.activate(layout: layout, force: req.force)
                    : try await HVFPayloadStore.rollback(layout: layout, force: req.force)
                if let code = Self.updateFailure(result.action, applying: method == "ApplyHVFUpdate") {
                    throw ConnectDecodeError(code: code, message: "\(result.action.rawValue): \(result.detail)")
                }
                return unary(RigProto.updateResult(result), binary: binary)

            case "GetMachineStatus":
                return unary(RigProto.machineStatus(hvfMachineClient().status()), binary: binary)

            case "ControlMachine":
                let req = try decode(Micropod_V1_ControlMachineRequest.self, body, binary: binary)
                let client = hvfMachineClient()
                switch req.action {
                case "start": try await client.ensureRunning()
                case "stop": try await client.stop()
                case "restart": try await client.restart()
                default:
                    throw ConnectDecodeError(
                        code: .invalidArgument, message: "action must be start, stop or restart, got '\(req.action)'")
                }
                return unary(RigProto.machineStatus(client.status()), binary: binary)

            case "GetTelemetryHealth":
                return unary(RigProto.telemetryHealth(try await ciHealth()), binary: binary)

            case "ListTelemetryIssues":
                let report = try await ciHealth()
                return unary(
                    Micropod_V1_TelemetryIssues.with {
                        $0.verdict = report.verdict.rawValue
                        $0.warnings = report.warnings
                        $0.issues = (report.runtimeEngine?.recentIssues ?? []).map(RigProto.issue)
                    }, binary: binary)

            case "GetTraces":
                let traces: Data
                do {
                    traces = try ciWorker().tracesOTLPJSON()
                } catch {
                    throw ConnectDecodeError(code: .unavailable, message: error.localizedDescription)
                }
                let spans = (try? JSONSerialization.jsonObject(with: traces) as? [String: Any])?["resourceSpans"]
                return unary(
                    Micropod_V1_TelemetryTraces.with {
                        $0.otlpJson = traces
                        $0.resourceSpanCount = Int32((spans as? [Any])?.count ?? 0)
                    }, binary: binary)

            case "GetRuntimeDependency":
                let services = await runtime.refreshIfNeeded()
                let (report, status) = await RuntimeDependencyProbe.inspectWithStatus(
                    system: system, services: services)
                return unary(RigProto.dependency(report, status: status), binary: binary)

            case "GetDiskUsage":
                return unary(try await system.diskUsage(), binary: binary)

            case "GetSandboxStatus":
                return unary(RigProto.sandboxStatus(SandboxVM.assetStatus()), binary: binary)

            default:
                return nil
            }
        } catch let error as BadRequest {
            throw ConnectDecodeError(code: .invalidArgument, message: error.message)
        }
    }

    /// Success for noop, activated and (for a rollback) rolled_back. A
    /// deferral changed nothing: `failed_precondition`. An activation that
    /// returned to known-good did not take: `aborted`. A failed boot with no
    /// way back: `internal`.
    static func updateFailure(_ action: HVFActivationResult.Action, applying: Bool) -> ConnectWireCode? {
        switch action {
        case .noop, .activated: return nil
        case .rolledBack: return applying ? .aborted : nil
        case .deferred: return .failedPrecondition
        case .failedRollback, .failed: return .internal
        }
    }

    // MARK: Shared with REST

    /// `/v1/rig/mode` and RigMode: the active mode (or the default runtime's
    /// name when it maps to none) and, when `listingModes`, every mode.
    func rigMode(listingModes: Bool) -> Micropod_V1_RigMode {
        .with {
            $0.mode = engineRegistry.activeMode?.rawValue ?? engineRegistry.defaultName
            $0.defaultRuntime = engineRegistry.defaultName
            if listingModes {
                $0.modes = RuntimeMode.allCases.map { mode in
                    .with {
                        $0.name = mode.rawValue
                        $0.engine = mode.engineName
                        $0.summary = mode.summary
                    }
                }
            }
        }
    }

    /// What rig health reports, read once.
    struct RigHealthSnapshot {
        var mode: String
        var defaultRuntime: String
        var hvf: HVFMachineStatus
        var dockerEndpoint: String
        var config: HVFMachineConfig
        var configError: String?
        var payload: HVFPayloadStatus
        var depproxyHealthy: Bool
        var cacheDisk: HVFCacheDiskObservation
    }

    func rigHealthSnapshot() async -> RigHealthSnapshot {
        let client = hvfMachineClient()
        let hvf = client.status()
        // Shown with the defaults' values, but flagged: a machine.json that
        // does not load is never presented as the config in force.
        let loaded = Result { try HVFMachineConfig.load(from: client.layout.config) }
        var configError: String?
        if case .failure(let error) = loaded { configError = error.localizedDescription }
        return RigHealthSnapshot(
            mode: engineRegistry.activeMode?.rawValue ?? engineRegistry.defaultName,
            defaultRuntime: engineRegistry.defaultName, hvf: hvf, dockerEndpoint: client.layout.dockerEndpoint,
            config: (try? loaded.get()) ?? HVFMachineConfig(), configError: configError,
            payload: HVFPayloadStore.status(layout: client.layout),
            depproxyHealthy: await Self.probeLoopbackDepproxy(), cacheDisk: await client.cacheDiskObservation())
    }

    /// `GET /v1/rig/health`'s body.
    static func rigHealthBody(_ s: RigHealthSnapshot) -> [String: Any] {
        let policy = s.config.effectiveCachePolicy
        var health: [String: Any] = [
            "mode": s.mode,
            "defaultRuntime": s.defaultRuntime,
            "hvf": [
                "installed": s.hvf.installed,
                "phase": s.hvf.phase.rawValue,
                "summary": s.hvf.summary,
                "root": s.hvf.root,
                "dockerEndpoint": s.dockerEndpoint,
                // The guest's own account: a caches.ext4 the guest failed to
                // mount is not present, and its shared caches are then off.
                "cacheDiskPresent": s.cacheDisk.mounted,
                "cacheDisk": s.cacheDisk.jsonObject,
                "sharedCaches": s.cacheDisk.sharedCaches,
                "updatePending": s.hvf.updatePending,
                "payloadVersion": s.payload.current?.version ?? "",
            ],
            "cachePolicy": [
                "mode": policy.mode.rawValue,
                "sharedL0": policy.sharedL0,
                "defaultTrust": policy.effectiveDefaultTrust.rawValue,
                "goProxy": policy.goProxy ?? "",
                "toolCount": policy.tools.count,
            ],
            "depproxy": [
                "url": "http://127.0.0.1:7677",
                "healthy": s.depproxyHealthy,
            ],
        ]
        if let error = s.configError { health["configError"] = error }
        return health
    }

    /// The CI worker this API reports on (`MICROPOD_CI_HOME`, the containerd
    /// engine unless `MICROPOD_CI_ENGINE` names another).
    func ciWorker() -> CIWorker {
        var env = ProcessInfo.processInfo.environment
        env["MICROPOD_CI_ENGINE"] = env["MICROPOD_CI_ENGINE"] ?? "containerd"
        return CIWorker(environment: env)
    }

    /// No worker to ask (stopped, booting, unreachable) is `unavailable`.
    private func ciHealth() async throws -> CIWorker.HealthReport {
        do {
            return try await ciWorker().health()
        } catch {
            throw ConnectDecodeError(code: .unavailable, message: error.localizedDescription)
        }
    }
}

/// The runtime library's rig, telemetry and sandbox models as messages.
enum RigProto {
    private static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func health(_ s: APIHandlers.RigHealthSnapshot) -> Micropod_V1_RigHealth {
        let policy = s.config.effectiveCachePolicy
        let disk = s.cacheDisk
        return .with {
            $0.mode = s.mode
            $0.defaultRuntime = s.defaultRuntime
            $0.hvf = .with {
                $0.installed = s.hvf.installed
                $0.phase = s.hvf.phase.rawValue
                $0.summary = s.hvf.summary
                $0.root = s.hvf.root
                $0.dockerEndpoint = s.dockerEndpoint
                $0.cacheDiskPresent = disk.mounted
                $0.cacheDisk = .with {
                    $0.mounted = disk.mounted
                    $0.configured = disk.configured
                    if let missing = disk.missingReason { $0.missing = missing }
                    $0.source = disk.state == nil ? "unknown" : "guest"
                    if let reason = disk.unknownReason { $0.reason = reason }
                    if let state = disk.state?.state { $0.state = state }
                    if let device = disk.state?.device { $0.device = device }
                    if let error = disk.state?.mountInfoError { $0.mountInfoError = error }
                    if let size = disk.state?.sizeBytes { $0.sizeBytes = size }
                    if let free = disk.state?.freeBytes { $0.freeBytes = free }
                    $0.sharedCaches = disk.sharedCaches
                    if let off = disk.sharedCachesOffReason { $0.unavailable = off }
                    $0.summary = disk.summary
                }
                $0.sharedCaches = disk.sharedCaches
                $0.updatePending = s.hvf.updatePending
                $0.payloadVersion = s.payload.current?.version ?? ""
            }
            $0.cachePolicy = .with {
                $0.mode = policy.mode.rawValue
                $0.sharedL0 = policy.sharedL0
                $0.defaultTrust = policy.effectiveDefaultTrust.rawValue
                $0.goProxy = policy.goProxy ?? ""
                $0.toolCount = Int32(clamping: policy.tools.count)
            }
            $0.depproxy = .with {
                $0.url = "http://127.0.0.1:7677"
                $0.healthy = s.depproxyHealthy
            }
            if let error = s.configError { $0.configError = error }
        }
    }

    static func manifest(_ m: HVFPayloadManifest) -> Micropod_V1_HVFPayloadManifest {
        .with {
            $0.schema = Int32(clamping: m.schema)
            $0.version = m.version
            $0.revision = m.revision
            $0.installedAt = rfc3339(m.installedAt)
            $0.digests = m.digests
            if let origin = m.origin { $0.origin = origin }
        }
    }

    static func updateStatus(_ s: HVFPayloadStatus) -> Micropod_V1_HVFUpdateStatus {
        .with {
            if let path = s.currentPath { $0.currentPath = path }
            if let path = s.previousPath { $0.previousPath = path }
            if let path = s.stagedPath { $0.stagedPath = path }
            if let path = s.knownGoodPath { $0.knownGoodPath = path }
            if let m = s.current { $0.current = manifest(m) }
            if let m = s.previous { $0.previous = manifest(m) }
            if let m = s.staged { $0.staged = manifest(m) }
            if let m = s.knownGood { $0.knownGood = manifest(m) }
            if let path = s.runningPath { $0.runningPath = path }
            if let version = s.runningVersion { $0.runningVersion = version }
            if let revision = s.runningRevision { $0.runningRevision = revision }
            $0.updatePending = s.updatePending
            $0.availableVersions = s.availableVersions
            if let failure = s.lastActivationFailure { $0.lastActivationFailure = failure }
        }
    }

    static func updateResult(_ r: HVFActivationResult) -> Micropod_V1_HVFUpdateResult {
        .with {
            $0.action = r.action.rawValue
            if let from = r.fromVersion { $0.fromVersion = from }
            if let to = r.toVersion { $0.toVersion = to }
            $0.activeContainers = Int32(clamping: r.activeContainers)
            $0.detail = r.detail
            if let target = r.targetVersion { $0.targetVersion = target }
            if let ms = r.switchoverMilliseconds { $0.switchoverMilliseconds = Int64(ms) }
        }
    }

    static func machineStatus(_ s: HVFMachineStatus) -> Micropod_V1_HVFMachineStatus {
        .with {
            $0.root = s.root
            $0.socket = s.socket
            $0.missing = s.missing
            $0.installed = s.installed
            if let problem = s.problem { $0.problem = problem }
            $0.supervisorAlive = s.supervisorAlive
            $0.phase = s.phase.rawValue
            if let st = s.state {
                $0.state = .with {
                    $0.phase = st.phase.rawValue
                    $0.supervisorPid = st.supervisorPID
                    if let pid = st.vmmPID { $0.vmmPid = pid }
                    if let at = st.startedAt { $0.startedAt = rfc3339(at) }
                    if let at = st.readyAt { $0.readyAt = rfc3339(at) }
                    $0.restartCount = Int32(clamping: st.restartCount)
                    if let reason = st.lastExitReason { $0.lastExitReason = reason }
                    if let code = st.lastExitCode { $0.lastExitCode = code }
                    if let path = st.loadedPayloadPath { $0.loadedPayloadPath = path }
                    if let version = st.loadedPayloadVersion { $0.loadedPayloadVersion = version }
                    $0.updatedAt = rfc3339(st.updatedAt)
                }
            }
            if let error = s.stateError { $0.stateError = error }
            $0.updatePending = s.updatePending
            $0.summary = s.summary
            // No supervisor, and the last one recorded a stop it was asked for.
            $0.stoppedOnRequest = !s.supervisorAlive && s.state?.phase == .stopped
        }
    }

    static func telemetryHealth(_ r: CIWorker.HealthReport) -> Micropod_V1_TelemetryHealth {
        .with {
            $0.verdict = r.verdict.rawValue
            $0.warnings = r.warnings
            $0.timestamp = rfc3339(r.timestamp)
            $0.engine = .with {
                $0.vmm = r.engine.vmm.rawValue
                $0.engine = r.engine.engine
                $0.engineVersion = r.engine.engineVersion
                $0.cpus = Int32(clamping: r.engine.cpus)
                $0.memoryBytes = r.engine.memoryBytes
                $0.storageDriver = r.engine.storageDriver
                $0.cgroupDriver = r.engine.cgroupDriver
                $0.buildkitAvailable = r.engine.buildkitAvailable
                $0.worker = r.engine.worker.uuidString
                $0.instance = r.engine.instance.uuidString
                $0.boot = r.engine.boot.uuidString
            }
            $0.workloads = .with {
                $0.runningCount = Int32(clamping: r.workloads.runningCount)
                $0.totalCount = Int32(clamping: r.workloads.totalCount)
            }
            if let totals = r.cacheInventory?.totals { $0.cacheTotals = CacheProto.totals(totals) }
            $0.hypervisorReported = r.hypervisor != nil
            $0.kernelReported = r.kernel != nil
        }
    }

    static func issue(_ i: CIWorker.RuntimeIssue) -> Micropod_V1_TelemetryIssue {
        .with {
            $0.tsUnixNs = i.tsUnixNs
            $0.kind = i.kind
            $0.source = i.source
            $0.method = i.method
            $0.route = i.route
            $0.status = Int32(clamping: i.status)
            $0.durationMs = i.durationMs
            if let message = i.message { $0.message = message }
        }
    }

    static func sandboxStatus(_ s: SandboxVM.AssetStatus) -> Micropod_V1_SandboxStatus {
        .with {
            $0.root = s.root
            $0.kernelOrigin = s.kernelOrigin.rawValue
            if let path = s.kernelPath { $0.kernelPath = path }
            if let source = s.kernelSource {
                $0.kernelSource = .with {
                    $0.origin = source.origin
                    $0.path = source.path
                    $0.sha256 = source.sha256
                }
            }
            $0.vminit = s.vminit
            $0.contentOrigin = s.contentOrigin.rawValue
            $0.contentPath = s.contentPath
            $0.initfsPaths = s.initfsPaths
            $0.standaloneReady = s.standaloneReady
        }
    }

    static func dependency(_ d: RuntimeDependencyStatus, status: Micropod_V1_SystemStatus?)
        -> Micropod_V1_RuntimeDependency
    {
        .with {
            $0.state = d.state.rawValue
            $0.cliPath = d.cliPath
            $0.cliVersion = d.cliVersion
            $0.cliVersionSupported = d.cliVersionSupported
            $0.apiServerVersion = d.apiServerVersion
            $0.backend = d.backend
            $0.runtimeInstallRoot = d.runtimeInstallRoot
            $0.maintenanceBlocked = d.maintenanceBlocked
            $0.message = d.message
            $0.nextAction = d.nextAction
            $0.installerURL = d.installerURL
            if let status { $0.status = status }
        }
    }
}
