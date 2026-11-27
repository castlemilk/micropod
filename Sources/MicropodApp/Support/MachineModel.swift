import Foundation
import MicropodCore
import Observation
import SwiftProtobuf
import SwiftUI

/// The hvf machine as the app drives it: RigService over the local API
/// (`GetMachineStatus`, `ControlMachine`, `SetMachineAutostart`,
/// `GetRigMode`), never a subprocess.
protocol MachineControlling: Sendable {
    func status() async throws -> Micropod_V1_HVFMachineStatus
    func control(_ action: String, force: Bool) async throws -> Micropod_V1_HVFMachineStatus
    func setAutostart(_ enabled: Bool, force: Bool) async throws -> Micropod_V1_HVFMachineStatus
    /// The default runtime's name (`GetRigMode`).
    func defaultRuntime() async throws -> String
    /// `SetupMachine`: the machine's first run (local sources only).
    func setup(_ request: Micropod_V1_SetupMachineRequest) async throws -> Micropod_V1_SetupMachineResult
}

extension MachineControlling {
    func setup(_ request: Micropod_V1_SetupMachineRequest) async throws -> Micropod_V1_SetupMachineResult {
        throw LocalAPI.RemoteError(code: "unimplemented", message: "machine setup is not available")
    }
}

/// `MachineControlling` through `LocalAPI` (api.sock, then loopback TCP).
struct LocalAPIMachineClient: MachineControlling {
    let api: LocalAPI

    init(api: LocalAPI = .live()) { self.api = api }

    func status() async throws -> Micropod_V1_HVFMachineStatus {
        try await api.unary(
            "RigService", "GetMachineStatus", Micropod_V1_Empty(), as: Micropod_V1_HVFMachineStatus.self, timeout: 10)
    }

    /// A start returns once the guest answers (up to 180 s on the server).
    func control(_ action: String, force: Bool) async throws -> Micropod_V1_HVFMachineStatus {
        try await api.unary(
            "RigService", "ControlMachine",
            Micropod_V1_ControlMachineRequest.with {
                $0.action = action
                $0.force = force
            }, as: Micropod_V1_HVFMachineStatus.self, timeout: 240)
    }

    func setAutostart(_ enabled: Bool, force: Bool) async throws -> Micropod_V1_HVFMachineStatus {
        try await api.unary(
            "RigService", "SetMachineAutostart",
            Micropod_V1_SetMachineAutostartRequest.with {
                $0.enabled = enabled
                $0.force = force
            }, as: Micropod_V1_HVFMachineStatus.self, timeout: 240)
    }

    func defaultRuntime() async throws -> String {
        try await api.unary("RigService", "GetRigMode", Micropod_V1_Empty(), as: Micropod_V1_RigMode.self, timeout: 10)
            .defaultRuntime
    }

    /// A copy of the base disk and a boot: minutes at most.
    func setup(_ request: Micropod_V1_SetupMachineRequest) async throws -> Micropod_V1_SetupMachineResult {
        try await api.unary(
            "RigService", "SetupMachine", request, as: Micropod_V1_SetupMachineResult.self, timeout: 600)
    }
}

/// The machine card, the menu-bar header when hvf is the default runtime,
/// and Settings' "Start the machine at login", fed by polling
/// `GetMachineStatus`. A stop, restart or autostart change the API defers
/// (containers would be interrupted) becomes `deferral`, which the view
/// confirms and retries with `force`.
@MainActor
@Observable
final class MachineModel {
    enum Action: String, Sendable {
        case start, stop, restart
    }

    /// What a deferred request was, so it can be retried with `force`.
    enum Deferred: Equatable, Sendable {
        case control(Action)
        case autostart(Bool)
    }

    struct Deferral: Identifiable, Equatable {
        let id = UUID()
        let request: Deferred
        /// The API's reason ("3 running container(s) on the machine").
        let reason: String
    }

    enum Phase: Equatable {
        case running, starting, stopping, stopped, failed, notInstalled, notReady, unavailable
    }

    private(set) var status: Micropod_V1_HVFMachineStatus?
    /// Why the API could not be asked (not running, an error).
    private(set) var unavailableReason: String?
    private(set) var defaultRuntime: String?
    /// The request in flight, if any.
    private(set) var pendingAction: Action?
    private(set) var autostartPending = false
    /// The last request's failure, shown until the next one.
    private(set) var actionError: String?
    /// The last setup's steps (`SetupMachine`), and whether one runs now.
    private(set) var setupSteps: [Micropod_V1_SetupMachineStep] = []
    private(set) var settingUp = false
    /// Why the last setup could not be asked for at all.
    private(set) var setupError: String?
    var deferral: Deferral?

    @ObservationIgnored let client: any MachineControlling
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private(set) var visible = false
    @ObservationIgnored let visibleInterval: Duration
    @ObservationIgnored let hiddenInterval: Duration

    init(
        client: any MachineControlling, visibleInterval: Duration = .seconds(5), hiddenInterval: Duration = .seconds(30)
    ) {
        self.client = client
        self.visibleInterval = visibleInterval
        self.hiddenInterval = hiddenInterval
    }

    // MARK: Polling

    var isPolling: Bool { pollTask != nil }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let interval =
                    self.pendingAction != nil ? .seconds(1) : self.visible ? self.visibleInterval : self.hiddenInterval
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// The panel or main window opened or closed: polls faster while one
    /// shows, and refreshes at once when one opens.
    func setVisible(_ visible: Bool) {
        let opened = visible && !self.visible
        self.visible = visible
        if opened, isPolling {
            stopPolling()
            startPolling()
        }
    }

    func refresh() async {
        do {
            let status = try await client.status()
            self.status = status
            unavailableReason = nil
            if let name = try? await client.defaultRuntime() { defaultRuntime = name }
        } catch {
            unavailableReason = Self.describe(error)
        }
    }

    /// Previews and snapshot tests.
    func applyForPreview(_ status: Micropod_V1_HVFMachineStatus?, defaultRuntime: String? = "hvf") {
        self.status = status
        self.defaultRuntime = defaultRuntime
        unavailableReason = status == nil ? "Micropod API daemon not reachable" : nil
    }

    // MARK: Requests

    func perform(_ action: Action, force: Bool = false) async {
        guard pendingAction == nil else { return }
        pendingAction = action
        actionError = nil
        defer { pendingAction = nil }
        do {
            status = try await client.control(action.rawValue, force: force)
            unavailableReason = nil
        } catch {
            handle(error, request: .control(action))
        }
    }

    func setAutostart(_ enabled: Bool, force: Bool = false) async {
        guard !autostartPending else { return }
        autostartPending = true
        actionError = nil
        defer { autostartPending = false }
        do {
            status = try await client.setAutostart(enabled, force: force)
        } catch {
            handle(error, request: .autostart(enabled))
        }
    }

    /// Sets the machine up over the API: the runtime files and base disk
    /// from the app's own bundle, or the disk from `diskFrom`, then a start.
    func setUp(diskFrom: URL? = nil) async {
        guard !settingUp else { return }
        settingUp = true
        setupError = nil
        defer { settingUp = false }
        do {
            let result = try await client.setup(
                .with {
                    if let diskFrom { $0.diskFrom = diskFrom.path }
                    $0.start = true
                })
            setupSteps = result.steps
            if result.hasMachine { status = result.machine }
            unavailableReason = nil
        } catch {
            setupError = Self.describe(error)
        }
    }

    /// The app should offer setup: hvf is the default and its machine is
    /// not installed.
    var needsSetup: Bool { phase == .notInstalled && defaultRuntime == "hvf" }

    /// The last setup stopped at a step.
    var setupFailure: Micropod_V1_SetupMachineStep? { setupSteps.first { $0.state == "failed" } }

    /// The command that finishes setup from a terminal when the app cannot:
    /// a package with no base disk needs a local disk image (or a download
    /// the app never starts on its own).
    var setupCommand: String {
        if setupFailure?.id == "disk" {
            return "micropod setup --disk-from <ext4>    (or: micropod setup --disk-image default)"
        }
        return "micropod setup"
    }

    /// The confirmed deferral, retried with `force`.
    func confirmDeferral() async {
        guard let deferral else { return }
        self.deferral = nil
        switch deferral.request {
        case .control(let action): await perform(action, force: true)
        case .autostart(let enabled): await setAutostart(enabled, force: true)
        }
    }

    func cancelDeferral() { deferral = nil }

    private func handle(_ error: Error, request: Deferred) {
        if let remote = error as? LocalAPI.RemoteError, remote.code == "failed_precondition",
            remote.message.hasPrefix("deferred: ")
        {
            let reason = remote.message.dropFirst("deferred: ".count).split(separator: ";").first.map(String.init)
            deferral = Deferral(request: request, reason: reason ?? remote.message)
            return
        }
        actionError = Self.describe(error)
    }

    static func describe(_ error: Error) -> String {
        if let remote = error as? LocalAPI.RemoteError { return remote.message }
        return error.localizedDescription
    }

    // MARK: Presentation

    /// The card shows once the API answered for a machine that is installed
    /// or is the default runtime's.
    var isShown: Bool {
        guard let status else { return defaultRuntime == "hvf" }
        return status.installed || defaultRuntime == "hvf"
    }

    /// The header and the menu-bar dot follow the machine.
    var drivesHeader: Bool { defaultRuntime == "hvf" }

    var phase: Phase {
        if pendingAction == .start || pendingAction == .restart { return .starting }
        if pendingAction == .stop { return .stopping }
        guard let status else { return .unavailable }
        switch status.readiness.isEmpty ? status.phase : status.readiness {
        case "running": return .running
        case "starting": return .starting
        case "stopping": return .stopping
        case "failed", "unusable": return .failed
        case "not-installed": return .notInstalled
        case "not-ready": return .notReady
        default: return status.installed ? .stopped : .notInstalled
        }
    }

    var headline: String {
        switch phase {
        case .running: "Machine running"
        case .starting: "Starting…"
        case .stopping: "Stopping…"
        case .stopped: "Machine stopped"
        case .failed: "Machine failed"
        case .notInstalled: "Machine not set up"
        case .notReady: "Machine not answering"
        case .unavailable: "Machine status unavailable"
        }
    }

    /// Why it is failed, not set up or unreachable.
    var reason: String? {
        if let actionError { return actionError }
        switch phase {
        case .failed, .notReady, .notInstalled:
            guard let status else { return nil }
            return status.hasFailureReason ? status.failureReason : status.summary
        case .unavailable: return unavailableReason
        default: return nil
        }
    }

    var color: Color {
        switch phase {
        case .running: Tokens.Palette.success
        case .starting, .stopping, .notReady: Tokens.Palette.warning
        case .failed, .unavailable: Tokens.Palette.danger
        case .stopped, .notInstalled: Tokens.Palette.tertiary
        }
    }

    var transitioning: Bool { phase == .starting || phase == .stopping }

    var engineLine: String? {
        guard let status, status.hasEngineVersion else { return nil }
        let range =
            status.hasEngineMinApiVersion
            ? "\(status.engineMinApiVersion)–\(status.engineApiVersion)" : status.engineApiVersion
        return "\(status.engineVersion.isEmpty ? "Engine" : status.engineVersion) · Docker API \(range)"
    }

    var containersLine: String? {
        guard let status, status.hasContainersTotal else { return nil }
        return
            "\(status.containersRunning) running · \(status.containersTotal) container\(status.containersTotal == 1 ? "" : "s")"
    }

    var cacheDiskLine: String? {
        guard let status, status.installed, status.hasCacheDisk else { return nil }
        let disk = status.cacheDisk
        if disk.mounted, disk.hasFreeBytes, disk.hasSizeBytes {
            return "Cache disk \(ByteFormat.string(disk.freeBytes)) free of \(ByteFormat.string(disk.sizeBytes))"
        }
        return disk.summary.isEmpty ? nil : "Cache disk \(disk.summary)"
    }

    var diskFlushLine: String? {
        guard let status, status.installed, !status.diskFlush.isEmpty else { return nil }
        return "Disk flush \(status.diskFlush)"
    }

    var updatePending: Bool { status?.updatePending == true }

    var updateLabel: String {
        guard let status, status.hasStagedVersion else { return "Update pending" }
        return "Update \(status.stagedVersion) pending"
    }

    var autostartEnabled: Bool { status?.autostart.enabled == true }

    var autostartSummary: String? {
        guard let status, status.hasAutostart else { return nil }
        return status.autostart.summary
    }

    /// Start when it is down, Stop and Restart when it runs.
    var canStart: Bool { [.stopped, .failed, .notReady].contains(phase) && pendingAction == nil }
    var canStop: Bool { [.running, .notReady].contains(phase) && pendingAction == nil }
    var canRestart: Bool { phase == .running && pendingAction == nil }
}
