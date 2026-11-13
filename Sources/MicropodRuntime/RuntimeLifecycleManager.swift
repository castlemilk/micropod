import Darwin
import Foundation
import MicropodCore

public enum RuntimeLifecycleAction: String, Codable, Sendable { case install, repair, start, stop, restart }
public struct RuntimeLifecycleOperation: Codable, Sendable {
    public let id: UUID
    public let action: RuntimeLifecycleAction
    public var phase: String
    public var message: String
    public var previousExecutable: String?
    public var previousSelection: ManagedRuntimeLocation.Selection?
    public var selection: ManagedRuntimeLocation.Selection?
    public var localGeneration: UInt64?
    public var rig: RuntimeRigReceipt?
    public var error: String?
    public var resumePhase: String?
    public var isTerminal: Bool { ["completed", "cancelled", "failed", "blocked", "recoveryRequired"].contains(phase) }
}

/// One owner for runtime lifecycle, shared by GUI/API/CLI/MCP. The filesystem
/// gate fences other processes; the rig coordinator retains scheduler authority.
public actor RuntimeLifecycleManager {
    public static let shared = RuntimeLifecycleManager()
    public let root: URL
    private let rig: any RuntimeRigCoordinating
    private let driver: any RuntimeLifecycleDriving
    private var operation: RuntimeLifecycleOperation?
    private var task: Task<Void, Never>?
    private var fence: RuntimeMaintenanceFence?
    private var receipt: ManagedRuntimeReceipt?
    private var ownerFD: Int32 = -1
    private var journal: URL { root.appendingPathComponent("operation.json") }

    public init(
        root: URL = ManagedRuntimeLocation.root, rig: any RuntimeRigCoordinating = RuntimeRigClient(),
        driver: any RuntimeLifecycleDriving = NativeRuntimeLifecycleDriver()
    ) {
        self.root = root
        self.rig = rig
        self.driver = driver
        if let data = try? RuntimeDurableFile.read(root.appendingPathComponent("operation.json"), maximumBytes: 65536) {
            operation = try? JSONDecoder().decode(RuntimeLifecycleOperation.self, from: data)
            if operation?.isTerminal == false {
                let interruptedPhase = operation?.phase
                operation?.resumePhase = interruptedPhase
                operation?.phase = "recoveryRequired"
                operation?.message = "An interrupted runtime operation needs verification"
            }
        }
    }

    public func status() -> RuntimeLifecycleOperation? { operation }

    @discardableResult
    public func begin(_ action: RuntimeLifecycleAction) throws -> RuntimeLifecycleOperation {
        guard task == nil else { throw MicropodError.message("A runtime operation is already running") }
        try lockOwner()
        do { try reload() } catch {
            unlockOwner()
            throw error
        }
        if let old = operation, !["completed", "cancelled", "failed", "blocked"].contains(old.phase) {
            unlockOwner()
            throw MicropodError.message("An interrupted runtime operation must be recovered before another can begin")
        }
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("admission/fence.json").path) else {
            unlockOwner()
            throw MicropodError.message("Runtime maintenance recovery is required")
        }
        operation = RuntimeLifecycleOperation(
            id: UUID(), action: action, phase: "preparing", message: "Preparing runtime management")
        do { try save() } catch {
            unlockOwner()
            throw error
        }
        let snapshot = operation!
        task = Task { await execute(snapshot.id) }
        return snapshot
    }

    public func cancel() {
        task?.cancel()
    }

    public func recover() throws -> RuntimeLifecycleOperation {
        guard task == nil else { throw MicropodError.message("A runtime operation is already running") }
        try lockOwner()
        do { try reload() } catch {
            unlockOwner()
            throw error
        }
        guard let operation else {
            unlockOwner()
            throw MicropodError.message("There is no interrupted operation to recover")
        }
        if operation.phase == "completed" {
            unlockOwner()
            return operation
        }
        if self.operation?.resumePhase == nil { self.operation?.resumePhase = operation.phase }
        do { try update("recovering", "Checking the retained runtime operation") } catch {
            unlockOwner()
            throw error
        }
        task = Task { await reconcile(operation.id) }
        return self.operation!
    }

    private func execute(_ id: UUID) async {
        defer {
            task = nil
            unlockOwner()
        }
        do {
            guard var current = operation, current.id == id else { return }
            current.previousExecutable = ContainerExecutableLocator.resolve().path
            current.previousSelection = try ManagedRuntimeLocation.selection(at: root)
            operation = current
            try save()
            if current.action == .install || current.action == .repair {
                try update("downloading", "Downloading and verifying Apple's signed runtime")
                receipt = try await driver.stage(root: root)
                operation?.selection = receipt?.selection
                try update("staged", "Verified runtime staged; waiting for maintenance admission")
            } else {
                operation?.selection = current.previousSelection
                guard current.previousSelection != nil else {
                    throw MicropodError.message(
                        "Install the managed Apple runtime before using managed lifecycle actions")
                }
            }
            try Task.checkCancellation()
            let gate = RuntimeAdmission(root: root.appendingPathComponent("admission"))
            let plannedGeneration = try gate.nextGeneration()
            operation?.localGeneration = plannedGeneration
            try update("draining", "Pausing new rig work and waiting for current work to finish")
            let selectedRoot = try targetRoot()
            let deadline = ContinuousClock.now.advanced(by: .seconds(120))
            var attemptedPrepare = false
            while true {
                try Task.checkCancellation()
                let response: RuntimeRigReceipt?
                let firstAttempt = !attemptedPrepare
                attemptedPrepare = true
                do {
                    response = try await rig.transition(
                        operation: id, action: "prepare", installRoot: selectedRoot, localGeneration: plannedGeneration,
                        targetState: operation?.action == .stop ? "stopped" : "running")
                } catch let error as RuntimeRigAdmissionError {
                    if firstAttempt { operation?.localGeneration = nil }
                    throw error
                }
                try Task.checkCancellation()
                operation?.rig = response
                try save()
                if response == nil || response?.phase == "prepared" { break }
                guard response?.phase == "draining", ContinuousClock.now < deadline else {
                    throw MicropodError.message(response?.reason ?? "Rig maintenance could not be prepared")
                }
                try await Task.sleep(for: .seconds(1))
            }
            try Task.checkCancellation()
            // Existing rig jobs drain while their runtime calls still work.
            // Close Micropod entry points only after scheduler closure is held.
            try await verifyIdle(using: stagedOrCurrentClient())
            fence = try gate.begin(operation: id)
            guard fence!.fence.generation == plannedGeneration else {
                throw MicropodError.message("Runtime admission generation changed during preparation")
            }
            try await RuntimeAdmission.$maintenanceOwner.withValue(id) {
                try await verifyIdle(using: stagedOrCurrentClient())
                if let receipt { try await driver.verifyStaged(receipt, root: root) }
                try Task.checkCancellation()
                if let response = try await rig.transition(
                    operation: id, action: "begin", installRoot: selectedRoot, localGeneration: fence!.fence.generation,
                    targetState: operation?.action == .stop ? "stopped" : "running")
                {
                    guard response.phase == "begun", response.owner == operation?.rig?.owner,
                        response.generation == operation?.rig?.generation
                    else {
                        throw MicropodError.message("Rig maintenance begin permission was refused")
                    }
                    operation?.rig = response
                }
                try Task.checkCancellation()
                try fence!.beginAction()
                try update("stopping", "Stopping the drained runtime service")
                let client = stagedOrCurrentClient()
                let status = try await driver.status(executable: client.executableURL)
                try Task.checkCancellation()
                if status == "running", operation?.action != .start {
                    try await driver.stop(executable: client.executableURL)
                }
                try Task.checkCancellation()
                if let receipt {
                    try await driver.verifyStaged(receipt, root: root)
                    try update("activating", "Selecting the verified runtime version")
                    try RuntimeDurableFile.write(receipt.selection, to: root.appendingPathComponent("current.json"))
                }
                if operation?.action != .stop, status != "running" || operation?.action != .start {
                    try update("starting", "Starting the managed runtime and installing its recommended kernel")
                    try await driver.start(executable: selectedClient().executableURL)
                }
                try update("verifying", "Verifying the selected runtime and native API")
                try await verifyResult()
                try await finish(id)
            }
        } catch {
            await failed(error, id: id)
        }
    }

    private func reconcile(_ id: UUID) async {
        defer {
            task = nil
            unlockOwner()
        }
        do {
            guard let current = operation, current.id == id else { return }
            if !FileManager.default.fileExists(atPath: root.appendingPathComponent("admission/fence.json").path) {
                if ["draining", "staged"].contains(current.resumePhase ?? current.phase), current.localGeneration != nil
                {
                    try await abortBeforeAction(id)
                    return
                }
                if (current.resumePhase ?? current.phase) == "releasing", let generation = current.localGeneration {
                    try await verifyResult()
                    if let response = try await rig.transition(
                        operation: id, action: "complete", installRoot: try targetRoot(), localGeneration: generation,
                        targetState: current.action == .stop ? "stopped" : "running")
                    {
                        guard response.phase == "completed" else {
                            throw MicropodError.message("Rig completion remains unresolved")
                        }
                        operation?.rig = response
                    }
                    fence = nil
                    try update("completed", "Runtime maintenance completion reconciled")
                    return
                }
                guard
                    ["preparing", "downloading", "staged", "draining", "failed", "cancelled", "blocked"].contains(
                        current.resumePhase ?? current.phase)
                else {
                    throw MicropodError.message("Missing maintenance ownership; do not retry the action")
                }
                try update("cancelled", "Interrupted preparation cancelled; no runtime change began")
                return
            }
            if fence == nil {
                fence = try RuntimeAdmission(root: root.appendingPathComponent("admission")).begin(
                    operation: id, recovering: true)
            }
            guard
                ["verifying", "releasing", "starting", "activating", "completed"].contains(
                    current.resumePhase ?? current.phase)
                    || !fence!.fence.actionStarted
            else {
                throw MicropodError.message(
                    "Runtime action outcome is uncertain. Maintenance remains closed until the prior action is authoritatively reconciled"
                )
            }
            try await RuntimeAdmission.$maintenanceOwner.withValue(id) {
                if !fence!.fence.actionStarted {
                    try await abortBeforeAction(id)
                } else {
                    if (current.resumePhase ?? current.phase) == "activating" {
                        let target = try targetRoot()
                        let receipt = try JSONDecoder().decode(
                            ManagedRuntimeReceipt.self,
                            from: RuntimeDurableFile.read(
                                target.appendingPathComponent("micropod-receipt.json"), maximumBytes: 16384))
                        guard receipt.selection == operation?.selection else {
                            throw MicropodError.message("Staged runtime identity changed")
                        }
                        try await driver.verifyStaged(receipt, root: root)
                        try RuntimeDurableFile.write(receipt.selection, to: root.appendingPathComponent("current.json"))
                        try update("starting", "Resuming the verified runtime activation")
                        try await driver.start(executable: selectedClient().executableURL)
                        try update("verifying", "Verifying the resumed runtime")
                    }
                    try await verifyResult()
                    try await finish(id)
                }
            }
        } catch { await failed(error, id: id) }
    }

    private func finish(_ id: UUID) async throws {
        try update("releasing", "Verified runtime; settling rig maintenance")
        if let response = try await rig.transition(
            operation: id, action: "verify", installRoot: try targetRoot(), localGeneration: fence!.fence.generation,
            targetState: operation?.action == .stop ? "stopped" : "running")
        {
            guard response.phase == "verified", response.owner == operation?.rig?.owner,
                response.generation == operation?.rig?.generation
            else { throw MicropodError.message("Rig runtime verification is still pending") }
            operation?.rig = response
            try save()
        }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("admission/fence.json").path) {
            try fence!.releaseAfterVerification()
        }
        if let response = try await rig.transition(
            operation: id, action: "complete", installRoot: try targetRoot(), localGeneration: fence!.fence.generation,
            targetState: operation?.action == .stop ? "stopped" : "running")
        {
            guard response.phase == "completed" else {
                throw MicropodError.message("Rig maintenance completion is pending")
            }
            operation?.rig = response
        }
        fence = nil
        try update(
            "completed",
            operation?.action == .stop
                ? "Managed runtime stopped; automatic startup remains paused" : "Managed runtime is ready")
    }

    private func abortBeforeAction(_ id: UUID) async throws {
        if let response = try await cleanupRig("abort", id: id) {
            guard response.phase == "aborting" || response.phase == "cancelled" else {
                throw MicropodError.message("Rig preparation outcome is uncertain")
            }
        }
        try fence?.releaseAfterVerification()
        if let response = try await cleanupRig("abortComplete", id: id) {
            guard response.phase == "cancelled" else {
                throw MicropodError.message("Rig cancellation needs reconciliation")
            }
        }
        fence = nil
        try update("cancelled", "Preparation cancelled before any runtime change")
    }

    private func cleanupRig(_ action: String, id: UUID) async throws -> RuntimeRigReceipt? {
        let coordinator = rig
        let target = try targetRoot()
        let generation = operation?.localGeneration ?? 0
        let targetState = operation?.action == .stop ? "stopped" : "running"
        // Cleanup has its own bounded transport. Cancelling the caller cannot
        // suppress a compare-and-abort for a permission that arrived late.
        return try await Task.detached {
            try await coordinator.transition(
                operation: id, action: action, installRoot: target, localGeneration: generation,
                targetState: targetState)
        }.value
    }

    private func failed(_ error: Error, id: UUID) async {
        let failedPhase = operation?.phase
        if failedPhase != "recoveryRequired", failedPhase != "recovering" { operation?.resumePhase = failedPhase }
        do {
            if operation?.localGeneration != nil, fence?.fence.actionStarted != true {
                try await abortBeforeAction(id)
                if !(error is CancellationError) {
                    operation?.error = error.localizedDescription
                    try update("blocked", "Runtime management was blocked before any change")
                }
                return
            }
            operation?.error = error is CancellationError ? "Operation cancelled" : error.localizedDescription
            let retainsAuthority = fence != nil || operation?.localGeneration != nil
            let definiteRefusal = error is RuntimeRigAdmissionError
            try update(
                retainsAuthority ? "recoveryRequired" : definiteRefusal ? "blocked" : "failed",
                retainsAuthority
                    ? "Maintenance is retained; recovery verification is required"
                    : definiteRefusal ? "Runtime staged; activation is blocked" : "Runtime preparation failed")
        } catch {
            operation?.error = "Maintenance outcome is uncertain; recovery is required"
            try? update("recoveryRequired", "Runtime and rig admission remain closed")
        }
    }

    private func verifyIdle(using client: ContainerCLIClient) async throws {
        try await driver.assertIdle(executable: client.executableURL)
    }
    private func verifyResult() async throws {
        try await driver.verify(
            executable: selectedClient().executableURL, installRoot: try targetRoot(),
            stopped: operation?.action == .stop)
    }
    private func selectedClient() -> ContainerCLIClient {
        ContainerCLIClient(executableURL: ManagedRuntimeLocation.executable(at: root))
    }
    private func stagedOrCurrentClient() -> ContainerCLIClient {
        if let target = try? targetRoot() {
            return ContainerCLIClient(executableURL: target.appendingPathComponent("bin/container"))
        }
        return ContainerCLIClient()
    }
    private func targetRoot() throws -> URL {
        guard let selection = operation?.selection, selection.isSupported else {
            throw MicropodError.message("Managed runtime target is unknown")
        }
        return root.appendingPathComponent("versions/" + selection.directoryName)
    }
    private func lockOwner() throws {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(
            root.appendingPathComponent("operation.lock").path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw MicropodError.message("Runtime operation ownership is unavailable") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw MicropodError.message("Another process owns runtime management")
        }
        ownerFD = fd
    }
    private func unlockOwner() {
        if ownerFD >= 0 {
            close(ownerFD)
            ownerFD = -1
        }
    }
    private func reload() throws {
        guard FileManager.default.fileExists(atPath: journal.path) else {
            operation = nil
            return
        }
        let data = try RuntimeDurableFile.read(journal, maximumBytes: 65536)
        operation = try JSONDecoder().decode(RuntimeLifecycleOperation.self, from: data)
    }
    private func update(_ phase: String, _ message: String) throws {
        operation?.phase = phase
        operation?.message = message
        try save()
    }
    private func save() throws { if let operation { try RuntimeDurableFile.write(operation, to: journal) } }
}
