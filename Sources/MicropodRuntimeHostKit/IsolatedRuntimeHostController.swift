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
    private var runtimeCoordinator: RuntimeCoordinatorAuthority
    private let verifyCoordinatorAccount: @Sendable (IsolatedRuntimeIdentity) throws -> Void
    /// How long a lifecycle action waits for rig work to drain before it
    /// abandons the maintenance and leaves the runtime as it was.
    private let drainTimeout: Duration

    public init(
        driver: any IsolatedRuntimeHostDriving, journal: URL = RootRuntimeStorage.operation,
        admissionRoot: URL = IsolatedRuntimePolicy.admissionRoot,
        registration: @escaping @Sendable (IsolatedRuntimeIdentity) throws -> IsolatedRuntimeRigRegistration? = {
            try IsolatedRuntimeRigRegistration.read(identity: $0)
        }
    ) {
        self.init(
            driver: driver, journal: journal, admissionRoot: admissionRoot, registration: registration,
            drainTimeout: .seconds(120))
    }

    init(
        driver: any IsolatedRuntimeHostDriving, journal: URL, admissionRoot: URL,
        registration: @escaping @Sendable (IsolatedRuntimeIdentity) throws -> IsolatedRuntimeRigRegistration?,
        drainTimeout: Duration
    ) {
        self.driver = driver
        self.registration = registration
        self.journal = journal
        self.gate = RuntimeAdmission(root: admissionRoot)
        self.runtimeCoordinator = RuntimeCoordinatorAuthority(
            fileURL: journal.deletingLastPathComponent().appendingPathComponent("runtime-coordinator.json"),
            ownerUID: geteuid())
        self.verifyCoordinatorAccount = { try ServiceAccountProvisioner.verifyExisting(identity: $0) }
        self.drainTimeout = drainTimeout
        state = Self.initialStatus(journal: journal)
    }

    init(
        driver: any IsolatedRuntimeHostDriving, journal: URL, admissionRoot: URL,
        coordinator: RuntimeCoordinatorAuthority,
        verifyCoordinatorAccount: @escaping @Sendable (IsolatedRuntimeIdentity) throws -> Void = {
            try ServiceAccountProvisioner.verifyExisting(identity: $0)
        },
        drainTimeout: Duration = .seconds(120)
    ) {
        self.driver = driver
        self.registration = { _ in nil }
        self.journal = journal
        self.gate = RuntimeAdmission(root: admissionRoot)
        self.runtimeCoordinator = coordinator
        self.verifyCoordinatorAccount = verifyCoordinatorAccount
        self.drainTimeout = drainTimeout
        state = Self.initialStatus(journal: journal)
    }

    private static func initialStatus(journal: URL) -> IsolatedRuntimeStatus {
        var state = IsolatedRuntimeStatus()
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
        return state
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
        if runtimeCoordinator.hasRecord {
            guard let identity = state.identity, try registration(identity) == nil,
                try runtimeCoordinator.read(identity: identity) != nil
            else {
                throw MicropodError.message("The private runtime coordinator identity is incomplete or conflicting")
            }
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
        if request.action == .verify, gate.isClosed || handoffAttempted {
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
        state.runtimeRig = nil
        state.runtimeRigAttempted = false
        state.runtimeCancelledBeforeAction = false
        state.runtimeActionStarted = false
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
                if runtimeCoordinator.hasRecord, state.identity != prepared.identity {
                    throw MicropodError.message("Runtime staging changed the enrolled private account")
                }
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
            state.localGeneration = try gate.issueGeneration(operation: request.operation)
            try update("draining", "Waiting for rig work to finish before closing runtime admission")
            let scoped = try runtimeCoordinator.read(identity: identity)
            let legacy = try registration(identity)
            if scoped != nil || legacy != nil {
                state.runtimeRigAttempted = scoped != nil
                state.rigAttempted = scoped == nil
                try save()
                let deadline = ContinuousClock.now.advanced(by: drainTimeout)
                // Until the coordinator answers a drain, it may never have
                // seen this operation; afterwards it has, so a later refusal
                // keeps the handoff.
                var accepted = false
                while true {
                    try Task.checkCancellation()
                    let firstDrain = !accepted && state.runtimeRigAttempted == true
                    let phase: String
                    do {
                        phase = try await handoffPhase("drain")
                    } catch let refusal as RuntimeCoordinatorNotRecorded where firstDrain {
                        try settleUnrecordedHandoff(
                            refusal, phase: "failed",
                            message: "The rig coordinator did not take this maintenance; "
                                + "the dedicated runtime is unchanged")
                        return
                    } catch let unsent as RuntimeRigAdmissionError where firstDrain {
                        // Definitely never delivered: the coordinator cannot hold it.
                        try settleUnrecordedHandoff(
                            unsent, phase: "failed",
                            message: "The rig coordinator was unavailable; nothing was drained "
                                + "and the dedicated runtime is unchanged")
                        return
                    }
                    accepted = true
                    if phase == "drained" { break }
                    guard phase == "draining" else {
                        throw MicropodError.message("Rig drain is incomplete; current work was left running")
                    }
                    guard ContinuousClock.now < deadline else {
                        try await abandonDrain()
                        return
                    }
                    try await Task.sleep(
                        until: min(ContinuousClock.now.advanced(by: .milliseconds(500)), deadline),
                        clock: .continuous)
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
            if handoffAttempted { try await requireHandoff("prepare", phase: "prepared") }
            let before = try await run(.verify, identity: identity, digest: digest, selection: selection)
            if request.action == .start, before.state == "nativeReady", state.pendingSelection == nil {
                // A ready native runtime may still need its independent API
                // service restored after an interrupted setup.
                if handoffAttempted { try await requireHandoff("begin", phase: "begun") }
                try beginRuntimeAction()
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
            if handoffAttempted { try await requireHandoff("begin", phase: "begun") }
            try beginRuntimeAction()
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
                if state.runtimeCancelledBeforeAction == true {
                    if handoffAttempted { try await requireHandoff("abortComplete", phase: "cancelled") }
                    clearHandoff()
                    state.workerBirth = nil
                    try update("blocked", "Preparation was cancelled before any private runtime change")
                    return
                }
                let observed = try await run(.verify, identity: identity, digest: digest, selection: selection)
                guard observed.state == (state.action == .stop ? "stopped" : "nativeReady") else {
                    throw MicropodError.message("The retained native outcome changed; no runtime command was replayed")
                }
                adopt(observed)
                try await finish()
                return
            }
            if !gate.isClosed, handoffAttempted {
                guard state.runtimeActionStarted == false else {
                    throw MicropodError.message("The retained runtime action may have begun; cancellation is refused")
                }
                do {
                    try await requireHandoff("abort", phase: "aborting")
                } catch let refusal as RuntimeCoordinatorNotRecorded where state.runtimeRigAttempted == true {
                    // A first drain the coordinator refused before recording
                    // left this handoff retained; it can never be aborted there.
                    try settleUnrecordedHandoff(
                        refusal, phase: "cancelled",
                        message: "Maintenance settled before any runtime change; "
                            + "the rig coordinator has no record of it")
                    return
                }
                state.runtimeCancelledBeforeAction = true
                state.actionVerified = true
                try update("releasing", "Cancelling rig preparation before any private runtime change")
                try await requireHandoff("abortComplete", phase: "cancelled")
                clearHandoff()
                try update("cancelled", "Rig preparation was cancelled before any private runtime change")
                return
            }
            if fence == nil { fence = try gate.begin(operation: id, recovering: true) }
            try publishFence()
            if fence?.fence.actionStarted == false {
                // The exact durable local fence positively precedes every
                // native action. It can settle a crash between saving intent
                // and marking that fence, after the worker's exit was proved.
                state.runtimeActionStarted = false
                try save()
                if handoffAttempted { try await requireHandoff("abort", phase: "aborting") }
                state.actionVerified = true
                state.runtimeCancelledBeforeAction = true
                try update("releasing", "Cancelling runtime preparation before any change")
                try fence?.releaseAfterVerification()
                fence = nil
                state.workerBirth = nil
                if handoffAttempted { try await requireHandoff("abortComplete", phase: "cancelled") }
                clearHandoff()
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
    /// Rig work outlived the drain deadline. No fence was taken and no
    /// native action began, so abandon the maintenance with the same two-stage
    /// abort that recovery uses: the rig resumes leasing at once instead of
    /// staying held until `micropod runtime recover`, and the runtime is left
    /// exactly as it was. A failed abort still falls through to recovery.
    private func abandonDrain() async throws {
        let timedOut = "Rig work did not drain within \(drainTimeout.components.seconds) s"
        do {
            try await requireHandoff("abort", phase: "aborting")
            state.runtimeCancelledBeforeAction = true
            state.actionVerified = true
            try update("releasing", "\(timedOut); releasing the rig before any runtime change")
            try await requireHandoff("abortComplete", phase: "cancelled")
        } catch {
            throw MicropodError.message("\(timedOut); abandoning the maintenance failed: \(error.localizedDescription)")
        }
        clearHandoff()
        state.workerBirth = nil
        state.error = "\(timedOut); the maintenance was abandoned and the dedicated runtime is unchanged"
        try update("cancelled", "Maintenance abandoned before any runtime change; the dedicated runtime is unchanged")
    }
    /// The coordinator holds no record of this operation
    /// (``RuntimeCoordinatorNotRecorded``). With no local fence, no runtime
    /// action begun and no worker alive, nothing anywhere remains to
    /// coordinate, so the handoff settles here instead of waiting in recovery
    /// for an abort the coordinator cannot give. Otherwise the refusal stands.
    private func settleUnrecordedHandoff(_ why: Error, phase: String, message: String) throws {
        guard !gate.isClosed, fence == nil, state.runtimeActionStarted != true,
            try state.workerBirth?.hasExited() != false
        else { throw why }
        clearHandoff()
        state.runtimeCancelledBeforeAction = true
        state.actionVerified = true
        state.workerBirth = nil
        state.error = why.localizedDescription
        try update(phase, message)
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
        if handoffAttempted, gate.isClosed { try await requireHandoff("verify", phase: "verified") }
        try fence?.releaseAfterVerification()
        fence = nil
        if handoffAttempted { try await requireHandoff("complete", phase: "completed") }
        clearHandoff()
        state.workerBirth = nil
        state.error = nil
        try update(
            "completed",
            state.action == .stop
                ? "Dedicated runtime stopped; the existing user runtime is unchanged"
                : "Dedicated native runtime is ready")
    }
    private var handoffAttempted: Bool { state.rigAttempted == true || state.runtimeRigAttempted == true }

    private func clearHandoff() {
        state.rigAttempted = false
        state.runtimeRigAttempted = false
    }

    private func handoffPhase(_ action: String) async throws -> String {
        if state.runtimeRigAttempted == true { return try await scopedTransition(action).phase }
        return try await rigTransition(action)?.phase ?? ""
    }

    private func requireHandoff(_ action: String, phase: String) async throws {
        if state.runtimeRigAttempted == true {
            let reply = try await scopedTransition(action)
            guard reply.phase == phase else {
                throw MicropodError.message("The exact private runtime handoff is unconfirmed; admission remains held")
            }
        } else {
            _ = try await requireRig(action, phase: phase)
        }
    }

    private func scopedTransition(_ action: String) async throws -> RuntimeCoordinationRigReply {
        guard let identity = state.identity, let record = try runtimeCoordinator.read(identity: identity) else {
            throw MicropodError.message("The private runtime coordinator is unavailable")
        }
        let operation = try coordinatedOperation()
        let releaseKind: RuntimeCoordinationReleaseKind? =
            action == "abortComplete"
            ? .cancelled : (action == "complete" ? (state.action == .stop ? .stopped : .running) : nil)
        let challenge = try runtimeCoordinator.issueOperationChallenge(
            identity: identity, peer: record.peer, operation: operation,
            purpose: releaseKind == nil ? "maintenance" : "release-observation")
        defer { runtimeCoordinator.discardChallenge(challenge) }
        let reply = try await driver.coordinateRuntime(
            identity: identity, peer: record.peer,
            call: .init(
                action: action, operation: operation, enrollment: record.enrollment,
                challenge: challenge, releaseKind: releaseKind))
        guard reply.schemaVersion == RuntimeCoordinationEnrollment.capability,
            reply.scope == RuntimeCoordinationEnrollment.runtimeScope, reply.operation == operation.id
        else { throw MicropodError.message("The private runtime handoff changed identity") }
        if reply.phase == RuntimeCoordinationRigReply.notRecordedPhase {
            throw RuntimeCoordinatorNotRecorded(reason: reply.reason ?? "")
        }
        if let reason = reply.reason, !reason.isEmpty, reply.phase != "draining" {
            throw MicropodError.message(reason)
        }
        if let kind = releaseKind {
            guard let retained = state.runtimeRig, let proof = reply.releaseProof, reply.maintenanceProof == nil else {
                throw MicropodError.message("The retained private release proof is unavailable")
            }
            _ = try runtimeCoordinator.observeRelease(
                proof, challenge: challenge, identity: identity, peer: record.peer, retained: retained, kind: kind)
        } else if reply.phase != "draining" {
            guard let proof = reply.maintenanceProof, reply.releaseProof == nil, let snapshot = reply.state else {
                throw MicropodError.message("The signed private scheduler fence is unavailable")
            }
            let receipt = try runtimeCoordinator.authorizeMaintenance(
                proof, challenge: challenge, identity: identity, peer: record.peer,
                operation: operation, resourceGeneration: snapshot.generation)
            if let old = state.runtimeRig {
                guard old.enrollment == receipt.enrollment, old.operation == receipt.operation,
                    old.resourceGeneration == receipt.resourceGeneration
                else { throw MicropodError.message("The retained private runtime resource owner changed") }
            }
            state.runtimeRig = receipt
            try save()
        }
        return reply
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
            guard !runtimeCoordinator.hasRecord else {
                throw MicropodError.message(
                    "Runtime-only coordination cannot enroll the public provider or physical host")
            }
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

    /// Runtime-only enrollment does not mutate rig.json, select a public API,
    /// reopen scheduler admission or grant host update/reboot authority.
    public func coordinateRuntime(
        _ call: RuntimeCoordinationCall, identity: IsolatedRuntimeIdentity, peer: RuntimeProcessBirth
    ) throws -> RuntimeCoordinationReply {
        guard state.identity == identity, try registration(identity) == nil,
            try RuntimeProcessBirth.read(peer.pid) == peer, peer.uid == identity.ownerUID
        else { throw MicropodError.message("The dedicated runtime coordinator identity is unconfirmed") }
        try verifyCoordinatorAccount(identity)
        if call.action == "runtime-inspect" {
            guard call.purpose == nil, call.proof == nil, call.challenge == nil else {
                throw MicropodError.message("The runtime inspection request is invalid")
            }
            // Public identity facts only: no nonce, session, registration,
            // admission transition or lifecycle permission is issued here.
            return .init(identity: identity, peer: peer)
        }
        if call.action == "runtime-recovery-challenge" || call.action == "runtime-reconcile-peer" {
            guard call.purpose == nil, task == nil, probe == nil, !workerRunning, !gate.isClosed,
                state.phase == "recoveryRequired", state.actionVerified == true, state.runtimeRigAttempted == true,
                try state.workerBirth?.hasExited() != false,
                let retained = state.runtimeRig, try coordinatedOperation() == retained.operation
            else {
                throw MicropodError.message("Only the exact released runtime receipt can refresh its departed peer")
            }
            if call.action == "runtime-recovery-challenge" {
                guard call.challenge == nil, call.proof == nil else {
                    throw MicropodError.message("The release recovery challenge request is invalid")
                }
                let challenge = try runtimeCoordinator.issueReleaseRebindingChallenge(
                    identity: identity, peer: peer, retained: retained)
                return .init(
                    identity: identity, peer: peer, challenge: challenge, enrollment: retained.enrollment,
                    coverage: try runtimeCoverage())
            }
            guard let proof = call.proof, let challenge = call.challenge else {
                throw MicropodError.message("The release recovery proof is incomplete")
            }
            let kind: RuntimeCoordinationReleaseKind =
                state.runtimeCancelledBeforeAction == true
                ? .cancelled : (state.action == .stop ? .stopped : .running)
            let enrollment = try runtimeCoordinator.rebindReleasedPeer(
                proof, challenge: challenge, identity: identity, peer: peer, retained: retained, kind: kind)
            return .init(identity: identity, peer: peer, enrollment: enrollment)
        }
        if call.action == "runtime-observe" {
            guard call.purpose == nil, call.proof == nil, call.challenge == nil,
                let record = try runtimeCoordinator.read(identity: identity), record.peer == peer
            else { throw MicropodError.message("The runtime observation request is invalid") }
            return .init(
                identity: identity, peer: peer, enrollment: record.enrollment,
                coverage: try runtimeCoverage())
        }
        let enrolling =
            call.action == "runtime-enroll" || (call.action == "runtime-challenge" && call.purpose == "enrollment")
        if enrolling {
            let exited = try state.workerBirth.map { try $0.hasExited() } ?? true
            guard !workerRunning, probe == nil, exited,
                Self.sessionMayContinue(state, gateClosed: gate.isClosed, taskActive: task != nil)
                    || (runtimeCoordinator.hasRecord && handoffAttempted && state.localGeneration != nil)
            else {
                throw MicropodError.message(
                    "Wait for the retained private worker before refreshing coordinator identity")
            }
        } else {
            // Data credentials can renew while a drain waits for existing work,
            // or while immutable installer files are staged. They confer no
            // new lease or lifecycle permission, and every API request still
            // crosses the common runtime admission gate.
            guard Self.sessionMayContinue(state, gateClosed: gate.isClosed, taskActive: task != nil) else {
                throw MicropodError.message("Complete retained runtime maintenance before opening a data session")
            }
        }
        switch call.action {
        case "runtime-challenge":
            guard let purpose = call.purpose, call.proof == nil, call.challenge == nil else {
                throw MicropodError.message("The runtime challenge request is invalid")
            }
            let challenge = try runtimeCoordinator.issueChallenge(identity: identity, peer: peer, purpose: purpose)
            return .init(identity: identity, peer: peer, challenge: challenge)
        case "runtime-enroll", "runtime-session":
            guard call.purpose == nil, let proof = call.proof, let challenge = call.challenge else {
                throw MicropodError.message("The runtime coordination request is incomplete")
            }
            if call.action == "runtime-enroll" {
                var required: RuntimeCoordinationEnrollment?
                if handoffAttempted {
                    required = try runtimeCoordinator.read(identity: identity)?.enrollment
                    if let retained = state.runtimeRig { required = retained.enrollment }
                }
                let enrollment = try runtimeCoordinator.enroll(
                    proof, challenge: challenge, identity: identity, peer: peer, requiredEnrollment: required)
                return .init(identity: identity, peer: peer, enrollment: enrollment)
            }
            let verified = try runtimeCoordinator.authorizeSession(
                proof, challenge: challenge, identity: identity, peer: peer)
            let session = try IsolatedRuntimeSessionStore.issue(
                identity: identity, subject: peer, expiresAt: Date(timeIntervalSince1970: Double(verified.exp)))
            return .init(identity: identity, peer: peer, enrollment: verified.enrollment, session: session)
        default:
            throw MicropodError.message("Unknown runtime coordination request")
        }
    }

    private func runtimeCoverage() throws -> RuntimeCoordinationCoverage {
        let operation = try coordinatedOperation()
        let closed = gate.isClosed
        let retainedFence = closed ? try gate.readFence() : nil
        if let retainedFence {
            guard retainedFence.operation == state.operation, retainedFence.generation == state.localGeneration else {
                throw MicropodError.message("Runtime observation does not own the admission fence")
            }
        }
        let workerActive = try state.workerBirth.map { try !$0.hasExited() } ?? false
        guard state.runtimeActionStarted != nil,
            closed || state.runtimeActionStarted == false || state.actionVerified == true,
            state.runtimeCancelledBeforeAction != true || state.runtimeActionStarted == false
        else { throw MicropodError.message("The private runtime action outcome remains uncertain") }
        return .init(
            operation: operation, phase: state.phase, admissionClosed: closed,
            actionStarted: retainedFence?.actionStarted == true || state.runtimeActionStarted == true,
            actionVerified: state.actionVerified == true,
            cancelledBeforeAction: state.runtimeCancelledBeforeAction == true,
            workerActive: workerRunning || workerActive, nativeState: state.nativeState,
            nativeVersion: state.nativeVersion, nativeAppRoot: state.nativeAppRoot,
            nativeInstallRoot: state.nativeInstallRoot)
    }

    static func sessionMayContinue(_ state: IsolatedRuntimeStatus, gateClosed: Bool, taskActive: Bool) -> Bool {
        guard !gateClosed else { return false }
        let retained = state.rigAttempted == true || state.runtimeRigAttempted == true
        if !taskActive, !retained,
            state.phase == "completed"
                || (state.runtimeCancelledBeforeAction == true && ["blocked", "cancelled"].contains(state.phase))
        {
            return true
        }
        guard state.runtimeActionStarted == false else { return false }
        return (state.phase == "draining" && state.runtimeRigAttempted == true)
            || (state.action == .install && ["preparing", "installing"].contains(state.phase))
    }

    private func coordinatedOperation() throws -> RuntimeCoordinationOperation {
        guard let operation = state.operation, let identity = state.identity, let action = state.action,
            let generation = state.localGeneration, generation <= UInt64(Int64.max),
            let selection = state.pendingSelection ?? state.selection
        else { throw MicropodError.message("The private runtime operation is incomplete") }
        return try .init(
            operation: operation, identity: identity, action: action.rawValue,
            localGeneration: Int64(generation), selection: selection)
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
    private func beginRuntimeAction() throws {
        guard let fence else { throw MicropodError.message("Runtime admission is not owned") }
        // Retain conservative action intent before touching either the native
        // runtime or its fence. A lost local receipt cannot become cancellation.
        state.runtimeActionStarted = true
        try save()
        try fence.beginAction()
        try publishFence()
    }
    private func fail(_ error: Error) {
        state.error = error.localizedDescription
        state.phase = gate.isClosed || handoffAttempted ? "recoveryRequired" : "failed"
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
