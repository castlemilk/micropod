import Darwin
import Foundation
import MicropodCore

/// Durable lifecycle authority for the isolated instance only. The existing
/// desktop account's Apple service and resources are never lifecycle targets.
public actor IsolatedRuntimeHostController {
    private let driver: any IsolatedRuntimeHostDriving
    private let journal: URL
    private let gate: RuntimeAdmission
    private let registration: @Sendable (IsolatedRuntimeIdentity) throws -> IsolatedRuntimeRigRegistration?
    private var state = IsolatedRuntimeStatus()
    private var task: Task<Void, Never>?
    private var probe: Task<IsolatedRuntimeObservation, Error>?
    private var workerRunning = false
    private var fence: RuntimeMaintenanceFence?

    public init(
        driver: any IsolatedRuntimeHostDriving, journal: URL = RootRuntimeStorage.operation,
        admissionRoot: URL = IsolatedRuntimePolicy.admissionRoot,
        registration: @escaping @Sendable (IsolatedRuntimeIdentity) throws -> IsolatedRuntimeRigRegistration? = {
            try IsolatedRuntimeRigRegistration.read(identity: $0)
        }
    ) {
        self.driver = driver
        self.registration = registration
        self.journal = journal
        self.gate = RuntimeAdmission(root: admissionRoot)
        if let data = try? RuntimeDurableFile.read(journal, maximumBytes: 65536),
            let status = try? JSONDecoder().decode(IsolatedRuntimeStatus.self, from: data)
        {
            state = status
            if !status.isTerminal {
                state.phase = "recoveryRequired"
                state.message = "An interrupted managed runtime operation needs verification"
            }
        } else if FileManager.default.fileExists(atPath: journal.path) {
            state.phase = "recoveryRequired"
            state.message = "Runtime control metadata is unavailable; no lifecycle action is permitted"
        }
    }

    public func submit(_ request: IsolatedRuntimeRequest, ownerUID: UInt32) async throws -> IsolatedRuntimeStatus {
        guard ownerUID >= 500, state.ownerUID == nil || state.ownerUID == ownerUID,
            state.identity == nil || state.identity?.ownerUID == ownerUID
        else {
            throw MicropodError.message("This runtime belongs to another macOS account")
        }
        if request.action == .status {
            var snapshot = state
            if let identity = state.identity {
                let pending = gate.root.appendingPathComponent("pending")
                if let files = try? FileManager.default.contentsOfDirectory(
                    at: pending, includingPropertiesForKeys: nil)
                {
                    snapshot.pendingOperationCount = files.count
                    struct PendingRoute: Decodable { let route: String }
                    snapshot.pendingOperationRoutes = files.prefix(16).map { file in
                        guard file.pathExtension == "json",
                            UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil,
                            let bytes = try? RuntimeDurableFile.read(
                                file, maximumBytes: 4096, ownerUID: identity.serviceUID),
                            let item = try? JSONDecoder().decode(PendingRoute.self, from: bytes)
                        else { return "Unconfirmed request" }
                        return String(item.route.prefix(80))
                    }
                }
            }
            return snapshot
        }
        if request.action == .probe {
            guard task == nil, !gate.isClosed, let identity = state.identity,
                let digest = state.workerSHA256, let selection = state.selection ?? state.pendingSelection
            else { return state }
            if let probe {
                let observation = try await probe.value
                var snapshot = state
                snapshot.nativeState = observation.state
                snapshot.nativeVersion = observation.nativeVersion
                snapshot.nativeAppRoot = observation.nativeAppRoot
                snapshot.nativeInstallRoot = observation.nativeInstallRoot
                return snapshot
            }
            let attempt = Task { try await self.run(.verify, identity: identity, digest: digest, selection: selection) }
            probe = attempt
            defer { probe = nil }
            adopt(try await attempt.value)
            try save()
            return state
        }
        guard request.action != .session else { throw MicropodError.message("Sessions require a verified IPC peer") }
        if request.action == .cancel {
            task?.cancel()
            return state
        }
        if state.operation == request.operation {
            guard state.action == request.action else {
                throw MicropodError.message("An operation ID cannot be reused for another action")
            }
            return state
        }
        guard task == nil, probe == nil else {
            throw MicropodError.message("A managed runtime operation is already running")
        }
        if request.action == .verify, gate.isClosed || state.rigAttempted == true {
            state.phase = "recovering"
            state.message = "Verifying the retained private runtime operation"
            try save()
            task = Task { await reconcile() }
            return state
        }
        guard !gate.isClosed, state.phase != "recoveryRequired" else {
            throw MicropodError.message("Verify the retained runtime operation before starting another")
        }
        if let birth = state.workerBirth, try !birth.hasExited() {
            throw MicropodError.message("The prior private worker is still active; no new action was started")
        }
        let history = journal.deletingLastPathComponent().appendingPathComponent("operations")
        try FileManager.default.createDirectory(
            at: history, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let marker = history.appendingPathComponent(request.operation.uuidString + ".json")
        guard !FileManager.default.fileExists(atPath: marker.path) else {
            throw MicropodError.message(
                "This operation ID was already recorded; check current status instead of replaying it")
        }
        try RuntimeDurableFile.write(request, to: marker)
        state.ownerUID = ownerUID
        state.operation = request.operation
        state.action = request.action
        state.error = nil
        state.workerBirth = nil
        state.rig = nil
        state.rigAttempted = false
        state.actionVerified = false
        state.localGeneration = nil
        state.phase = "preparing"
        state.message = "Preparing the dedicated runtime"
        try save()
        task = Task { await execute(request, ownerUID: ownerUID) }
        return state
    }

    private func execute(_ request: IsolatedRuntimeRequest, ownerUID: UInt32) async {
        defer { task = nil }
        do {
            if request.action == .install {
                try update("installing", "Verifying Apple's runtime and creating the locked service account")
                let prepared = try await driver.prepare(ownerUID: ownerUID)
                state.identity = prepared.identity
                state.pendingSelection = prepared.receipt.selection
                state.workerSHA256 = prepared.workerSHA256
                try update("completed", "Apple container is installed for the dedicated account; start it when ready")
                return
            }
            guard let identity = state.identity, let digest = state.workerSHA256,
                let selection = state.selection ?? state.pendingSelection
            else {
                throw MicropodError.message("Install the dedicated runtime before using lifecycle controls")
            }
            if request.action == .status || request.action == .verify || request.action == .workload {
                let observation = try await run(
                    request.action, identity: identity, digest: digest, selection: selection)
                adopt(observation)
                try update(
                    "completed",
                    request.action == .workload
                        ? observation.workloadOutput ?? "Isolated workload completed"
                        : "Dedicated runtime readiness checked")
                return
            }
            state.localGeneration = try gate.nextGeneration()
            try update("draining", "Waiting for rig work to finish before closing runtime admission")
            if try registration(identity) != nil {
                state.rigAttempted = true
                try save()
                let deadline = ContinuousClock.now.advanced(by: .seconds(120))
                while true {
                    try Task.checkCancellation()
                    let receipt = try await rigTransition("drain")
                    if receipt?.phase == "drained" { break }
                    guard receipt?.phase == "draining", ContinuousClock.now < deadline else {
                        throw MicropodError.message("Rig drain is incomplete; current work was left running")
                    }
                    try await Task.sleep(for: .milliseconds(500))
                }
            }
            try Task.checkCancellation()
            let gateDeadline = ContinuousClock.now.advanced(by: .seconds(10))
            while fence == nil {
                try Task.checkCancellation()
                do { fence = try gate.begin(operation: request.operation) } catch {
                    guard !gate.isClosed, ContinuousClock.now < gateDeadline else { throw error }
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            guard fence?.fence.generation == state.localGeneration else {
                throw MicropodError.message("Runtime admission generation changed")
            }
            try publishFence()
            if state.rigAttempted == true { _ = try await requireRig("prepare", phase: "prepared") }
            let before = try await run(.verify, identity: identity, digest: digest, selection: selection)
            if request.action == .start, before.state == "nativeReady", state.pendingSelection == nil {
                // A ready native runtime may still need its independent API
                // service restored after an interrupted setup.
                if state.rigAttempted == true { _ = try await requireRig("begin", phase: "begun") }
                try fence!.beginAction()
                try publishFence()
                let ready = try await run(.start, identity: identity, digest: digest, selection: selection)
                adopt(ready)
                try await finish()
                return
            }
            // Refusal for active workloads must precede actionStarted. That
            // allows verified cancellation to reopen admission so those same
            // workloads can finish or be stopped through the data plane.
            _ = try await run(.verify, identity: identity, digest: digest, selection: selection, requiresIdle: true)
            try Task.checkCancellation()
            if state.rigAttempted == true { _ = try await requireRig("begin", phase: "begun") }
            try fence!.beginAction()
            try publishFence()
            try update("stopping", "Settling the drained dedicated runtime and API")
            _ = try await run(.stop, identity: identity, digest: digest, selection: selection)
            if request.action == .stop {
                let observed = try await run(.verify, identity: identity, digest: digest, selection: selection)
                guard observed.state == "stopped" else {
                    throw MicropodError.message("Private runtime stop is unconfirmed")
                }
                adopt(observed)
                try await finish()
                return
            }
            state.selection = state.pendingSelection ?? state.selection
            state.pendingSelection = nil
            try driver.activateAPI(identity: identity, selection: state.selection!)
            try update("starting", "Starting Apple's runtime in the dedicated account")
            let started = try await run(.start, identity: identity, digest: digest, selection: state.selection!)
            guard started.state == "nativeReady" else {
                throw MicropodError.message("Private native readiness is unconfirmed")
            }
            adopt(started)
            try update("verifying", "Checking the exact private native runtime")
            let verified = try await run(.verify, identity: identity, digest: digest, selection: state.selection!)
            guard verified.state == "nativeReady" else {
                throw MicropodError.message("Private native readiness is unconfirmed")
            }
            adopt(verified)
            try await finish()
        } catch { fail(error) }
    }

    private func run(
        _ action: IsolatedRuntimeAction, identity: IsolatedRuntimeIdentity, digest: String,
        selection: ManagedRuntimeLocation.Selection, requiresIdle: Bool = false
    ) async throws -> IsolatedRuntimeObservation {
        guard !workerRunning else {
            throw MicropodError.message("A private runtime verification or action is already running")
        }
        workerRunning = true
        defer { workerRunning = false }
        let previous = state.workerBirth
        if let previous, try !previous.hasExited() {
            throw MicropodError.message("The previous private worker is still active; no action was retried")
        }
        state.workerBirth = nil
        try save()
        return try await driver.run(
            identity: identity, workerSHA256: digest,
            request: .init(
                action: action, selection: selection, maintenanceOwner: fence?.fence.operation,
                requiresIdle: requiresIdle)
        ) { birth in
            try await self.recordWorker(birth)
        }
    }
    private func recordWorker(_ birth: RuntimeProcessBirth) throws {
        guard birth.uid == state.identity?.serviceUID else { throw MicropodError.message("Private worker uid changed") }
        state.workerBirth = birth
        try save()
    }
    private func reconcile() async {
        defer { task = nil }
        do {
            guard let id = state.operation, let identity = state.identity, let digest = state.workerSHA256,
                let selection = state.selection ?? state.pendingSelection
            else { throw MicropodError.message("Recovery metadata is incomplete") }
            if let birth = state.workerBirth, try !birth.hasExited() {
                throw MicropodError.message("The prior runtime worker remains active; wait for its outcome")
            }
            if !gate.isClosed, state.actionVerified == true {
                try await finish()
                return
            }
            if !gate.isClosed, state.rigAttempted == true {
                _ = try await requireRig("abort", phase: "aborting")
                _ = try await requireRig("abortComplete", phase: "cancelled")
                state.rigAttempted = false
                try update("cancelled", "Rig preparation was cancelled before any private runtime change")
                return
            }
            if fence == nil { fence = try gate.begin(operation: id, recovering: true) }
            try publishFence()
            if fence?.fence.actionStarted == false {
                if state.rigAttempted == true { _ = try await requireRig("abort", phase: "aborting") }
                state.actionVerified = true
                try update("releasing", "Cancelling runtime preparation before any change")
                try fence?.releaseAfterVerification()
                fence = nil
                state.workerBirth = nil
                if state.rigAttempted == true { _ = try await requireRig("abortComplete", phase: "cancelled") }
                state.rigAttempted = false
                try update(
                    "blocked",
                    "Preparation ended before any private runtime change; the existing user runtime is unchanged")
                return
            }
            let observed = try await run(.verify, identity: identity, digest: digest, selection: selection)
            let expected = state.action == .stop ? "stopped" : "nativeReady"
            guard observed.state == expected else {
                throw MicropodError.message(
                    "The retained runtime outcome is unconfirmed; no stop or start was replayed")
            }
            adopt(observed)
            try await finish()
        } catch { fail(error) }
    }
    private func adopt(_ observation: IsolatedRuntimeObservation) {
        state.nativeState = observation.state
        state.nativeVersion = observation.nativeVersion
        state.nativeAppRoot = observation.nativeAppRoot
        state.nativeInstallRoot = observation.nativeInstallRoot
    }
    private func finish() async throws {
        state.actionVerified = true
        try update("releasing", "Dedicated runtime verified; completing maintenance")
        if state.rigAttempted == true { _ = try await requireRig("verify", phase: "verified") }
        try fence?.releaseAfterVerification()
        fence = nil
        if state.rigAttempted == true { _ = try await requireRig("complete", phase: "completed") }
        state.rigAttempted = false
        state.workerBirth = nil
        state.error = nil
        try update(
            "completed",
            state.action == .stop
                ? "Dedicated runtime stopped; the existing user runtime is unchanged"
                : "Dedicated native runtime is ready")
    }
    private func rigTransition(_ action: String) async throws -> RuntimeRigReceipt? {
        guard let identity = state.identity, let operation = state.operation, let generation = state.localGeneration,
            let selection = state.pendingSelection ?? state.selection
        else { throw MicropodError.message("Rig maintenance metadata is incomplete") }
        let receipt = try await driver.rigTransition(
            identity: identity, operation: operation, action: action,
            installRoot: RootRuntimeStorage.apple.appendingPathComponent("versions/" + selection.directoryName),
            generation: generation, targetState: state.action == .stop ? "stopped" : "running")
        if let old = state.rig, !old.hostID.isEmpty, let receipt,
            receipt.hostID != old.hostID || receipt.owner != old.owner || receipt.generation != old.generation
        {
            throw MicropodError.message("The retained rig maintenance owner changed")
        }
        state.rig = receipt
        try save()
        return receipt
    }
    private func requireRig(_ action: String, phase: String) async throws -> RuntimeRigReceipt {
        guard let receipt = try await rigTransition(action),
            receipt.phase == phase || (action == "verify" && receipt.phase == "completed")
        else {
            throw MicropodError.message("Rig maintenance \(action) is unconfirmed; admission remains closed")
        }
        return receipt
    }

    public func rigProof(_ call: IsolatedRuntimeRigCall, identity: IsolatedRuntimeIdentity) async throws
        -> IsolatedRuntimeRigProof
    {
        if call.action == "enroll" {
            guard let host = call.hostID, !host.isEmpty, host.utf8.count <= 128,
                host.utf8.allSatisfy({
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                        || [45, 46, 58, 95].contains($0)
                })
            else {
                throw MicropodError.message("The runtime rig host identity is invalid")
            }
            if let old = try IsolatedRuntimeRigRegistration.read(identity: identity) {
                guard old.hostID == host else {
                    throw MicropodError.message("The runtime is enrolled with another rig host")
                }
            } else {
                guard task == nil, !gate.isClosed else {
                    throw MicropodError.message("Complete runtime maintenance before enrolling the rig")
                }
                try RuntimeDurableFile.write(
                    IsolatedRuntimeRigRegistration(identity: identity, hostID: host),
                    to: IsolatedRuntimeRigRegistration.fileURL)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o644], ofItemAtPath: IsolatedRuntimeRigRegistration.fileURL.path)
            }
            return .init(
                identity: identity, hostID: host, operation: nil, generation: nil,
                admissionClosed: false, actionVerified: false, phase: "enrolled")
        }
        guard ["coverage", "readiness"].contains(call.action),
            let registration = try IsolatedRuntimeRigRegistration.read(identity: identity),
            state.identity == identity, call.operation == state.operation, call.generation == state.localGeneration,
            call.operation != nil, call.generation != nil
        else { throw MicropodError.message("The runtime proof does not match the rig operation") }
        let closed = gate.isClosed
        if closed {
            guard let fence, try gate.readFence() == fence.fence, fence.fence.generation == call.generation else {
                throw MicropodError.message("The runtime helper does not own the retained admission fence")
            }
        } else {
            guard (state.actionVerified == true && state.phase == "releasing") || state.phase == "recovering" else {
                throw MicropodError.message("Runtime admission proof is unavailable")
            }
        }
        var observation: IsolatedRuntimeObservation?
        if call.action == "readiness" {
            guard let digest = state.workerSHA256, let selection = state.selection ?? state.pendingSelection else {
                throw MicropodError.message("The runtime verification metadata is incomplete")
            }
            observation = try await run(.verify, identity: identity, digest: digest, selection: selection)
        }
        return .init(
            identity: identity, hostID: registration.hostID, operation: state.operation,
            generation: state.localGeneration,
            admissionClosed: closed, actionVerified: state.actionVerified == true, phase: state.phase,
            nativeState: observation?.state, nativeVersion: observation?.nativeVersion,
            nativeInstallRoot: observation?.nativeInstallRoot, nativeAppRoot: observation?.nativeAppRoot)
    }

    private func publishFence() throws {
        // Service-account workers need read access, never write access, to the
        // root-owned fence. The admission directory prevents unlink/replace.
        let file = gate.root.appendingPathComponent("fence.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw MicropodError.message("Runtime fence could not be published") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw MicropodError.message("Runtime fence synchronization failed") }
    }
    private func fail(_ error: Error) {
        state.error = error.localizedDescription
        state.phase = gate.isClosed || state.rigAttempted == true ? "recoveryRequired" : "failed"
        state.message =
            gate.isClosed
            ? "Dedicated runtime admission remains closed; verification is required"
            : "Dedicated runtime setup could not complete"
        try? save()
    }
    private func update(_ phase: String, _ message: String) throws {
        state.phase = phase
        state.message = message
        try save()
    }
    private func save() throws { try RuntimeDurableFile.write(state, to: journal) }
}
