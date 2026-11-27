import Foundation
import MicropodCore

/// The machine as RigService's `GetMachineStatus` reports it, built in one
/// place so the API, the CLI's in-process fallback (`micropod status` with no
/// API to ask) and the app read the same facts.
extension HVFMachineClient {
    /// The guest's containers: all of them, and those running.
    public struct ContainerCounts: Sendable, Equatable {
        public var total: Int
        public var running: Int
    }

    /// `GET /containers/json?all=1` while the machine serves; nil when it
    /// does not (nothing is booted to find out) or the guest does not answer
    /// within `timeout`.
    public func containerCounts(timeout: Duration = .seconds(1)) async -> ContainerCounts? {
        guard isServing,
            let response = try? await docker.request("GET", "/containers/json", query: ["all": "1"], timeout: timeout),
            response.status == 200,
            let containers = (try? JSONSerialization.jsonObject(with: response.body)) as? [[String: Any]]
        else { return nil }
        let running = containers.count { ($0["State"] as? String)?.lowercased() == "running" }
        return ContainerCounts(total: containers.count, running: running)
    }

    /// Everything `GetMachineStatus` answers. Never boots anything. While
    /// the machine serves, the guest is asked for its engine version, its
    /// containers and its cache disk, at once and `timeout` each. The
    /// autostart LaunchAgent is read from `<root>/autostart.json`; launchd
    /// is asked only when there is one (or a plist for this root).
    public func statusMessage(
        timeout: Duration = .seconds(1), autostart: HVFMachineAutostartAgent? = nil
    ) async -> Micropod_V1_HVFMachineStatus {
        let status = status()
        async let readiness = readiness(pingTimeout: timeout)
        async let engine = engineVersion(timeout: timeout)
        async let containers = containerCounts(timeout: timeout)
        async let cacheDisk = cacheDiskObservation(timeout: timeout)
        let agent = autostart ?? HVFMachineAutostartAgent(layout: layout, environment: environment, launch: launch)
        async let launchAgent = agent.status()
        let diskFlush = HVFDiskFlushStatus.current(
            layout: layout, state: status.state, supervisorAlive: status.supervisorAlive)
        var message = Self.statusMessage(status)
        let ready = await readiness
        message.readiness = ready.status.rawValue
        if let reason = Self.failureReason(status, readiness: ready) { message.failureReason = reason }
        if let engine = await engine {
            message.engineVersion = engine.version
            message.engineApiVersion = engine.apiVersion
            message.engineMinApiVersion = engine.minAPIVersion
        }
        if let counts = await containers {
            message.containersTotal = Int32(clamping: counts.total)
            message.containersRunning = Int32(clamping: counts.running)
        }
        message.diskFlush = diskFlush.summary
        message.cacheDisk = Self.cacheDiskMessage(await cacheDisk)
        message.autostart = Self.autostartMessage(await launchAgent)
        return message
    }

    /// Why the machine cannot take work, when it is failed, unusable, not
    /// ready or not installed; nil otherwise.
    static func failureReason(_ status: HVFMachineStatus, readiness: HVFMachineReadiness) -> String? {
        switch readiness.status {
        case .notInstalled: return "missing \(status.missing.joined(separator: ", "))"
        case .unusable: return status.problem ?? readiness.detail
        case .failed: return status.state?.lastExitReason ?? readiness.detail
        case .notReady: return readiness.detail
        default: return nil
        }
    }

    /// The fields that need no guest round trip, from `status()`.
    public static func statusMessage(_ s: HVFMachineStatus) -> Micropod_V1_HVFMachineStatus {
        func rfc3339(_ date: Date) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.string(from: date)
        }
        return .with {
            $0.root = s.root
            $0.socket = s.socket
            $0.dockerEndpoint = "unix://" + s.socket
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
            if let version = s.payload?.current?.version { $0.payloadVersion = version }
            if let version = s.payload?.staged?.version { $0.stagedVersion = version }
        }
    }

    /// Rig health's and the machine status's `cache_disk`.
    public static func cacheDiskMessage(_ disk: HVFCacheDiskObservation) -> Micropod_V1_RigCacheDisk {
        .with {
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
    }

    public static func autostartMessage(_ s: HVFMachineAutostartAgent.Status) -> Micropod_V1_HVFMachineAutostart {
        .with {
            $0.enabled = s.enabled
            $0.loaded = s.loaded
            $0.label = s.label
            $0.plistPath = s.plist
            if let program = s.program { $0.program = program }
            if let seconds = s.exitTimeOut { $0.exitTimeoutSeconds = Int32(clamping: seconds) }
            if let problem = s.problem { $0.problem = problem }
            $0.summary = s.summary
        }
    }
}
