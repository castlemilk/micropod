import Foundation
import Observation

/// Future trusted coordinator boundary. No production implementation exists.
/// It must close every runtime/lease admission path before returning a hold,
/// retain durable owner/generation across relaunch, and settle only verified
/// replacement or rollback. An idle observation is not an implementation.
@MainActor
protocol UpdateAdmissionCoordinating {
    var isAvailable: Bool { get }
    func acquire(operation: UUID) async throws -> any UpdateAdmissionHolding
    /// Nonblocking cancellation of begin permission, including delayed replies.
    /// Unknown outcomes retain the external fence; this is not unconditional release.
    func cancelAcquisition(operation: UUID)
}

@MainActor
protocol UpdateAdmissionHolding {
    /// One-time, generation-bound begin permission, validated immediately at
    /// the action boundary. Expiry denies begin; it never reopens admission.
    /// false proves begin was denied; a thrown error means the result is unknown.
    func beginInstallation() throws -> Bool
    /// Compare-and-abort only when the coordinator proves no action began and
    /// the old runtime is usable. Idempotent; must never clear unknown/newer state.
    func abortIfInstallationHasNotBegun()
    /// A trusted, generation-bound recovery receipt, including verified old
    /// build/runtime and settled external ownership. Unknown is false/throws.
    func oldRuntimeIsVerifiedRestored() async throws -> Bool
}

@MainActor
struct UnavailableUpdateAdmission: UpdateAdmissionCoordinating {
    var isAvailable: Bool { false }
    func acquire(operation: UUID) async throws -> any UpdateAdmissionHolding {
        throw UpdateRestartGuard.Failure.unavailable
    }
    func cancelAcquisition(operation: UUID) {}
}

/// Serializes requests and fences cancelled/late replies in the app. This is
/// scaffolding for a qualified coordinator, not the cross-process fence itself.
@MainActor @Observable
final class UpdateRestartGuard {
    enum State: String {
        case unavailable, idle, preparing, prepared, installationStarted, blocked, recoveryRequired
    }

    enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? { UpdateRestartGuard.unavailableReason }
    }

    nonisolated static let unavailableReason =
        "Safe update installation is unavailable: workload admission is not coordinated across Micropod relaunch."

    private(set) var state: State
    private(set) var blockedReason: String?
    var isAvailable: Bool { coordinator.isAvailable }
    @ObservationIgnored private let coordinator: any UpdateAdmissionCoordinating
    @ObservationIgnored private let waitForTimeout: @MainActor () async throws -> Void
    @ObservationIgnored private let waitForResponseFlush: @MainActor () async throws -> Void
    @ObservationIgnored private var operation: UUID?
    @ObservationIgnored private var hold: (any UpdateAdmissionHolding)?
    @ObservationIgnored private var reply: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var prepareTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored var didBlock: @MainActor () -> Void = {}

    init(
        coordinator: any UpdateAdmissionCoordinating = UnavailableUpdateAdmission(),
        waitForTimeout: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(10)) },
        waitForResponseFlush: @escaping @MainActor () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(750))
        }
    ) {
        self.coordinator = coordinator
        self.waitForTimeout = waitForTimeout
        self.waitForResponseFlush = waitForResponseFlush
        state = coordinator.isAvailable ? .idle : .unavailable
        blockedReason = coordinator.isAvailable ? nil : Self.unavailableReason
    }

    func requestInstallation(
        noObservedWork: @escaping @MainActor () async -> Bool,
        install: @escaping @MainActor () -> Void
    ) async -> Bool {
        guard coordinator.isAvailable else {
            state = .unavailable
            blockedReason = Self.unavailableReason
            return false
        }
        guard operation == nil else { return false }
        let id = UUID()
        operation = id
        state = .preparing
        blockedReason = nil
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                reply = continuation
                // Unstructured tasks let the deadline return even if a future
                // transport ignores cancellation. The operation ID fences it.
                prepareTask = Task { @MainActor in
                    do {
                        let acquired = try await coordinator.acquire(operation: id)
                        guard operation == id, !Task.isCancelled else {
                            acquired.abortIfInstallationHasNotBegun()
                            return
                        }
                        hold = acquired
                        guard await noObservedWork(), operation == id, !Task.isCancelled else {
                            block(id, reason: "Workload state is busy or unknown; update remains staged.")
                            return
                        }
                        state = .prepared
                        prepareTask = nil
                        reply?.resume(returning: true)
                        reply = nil
                        installTask = Task { @MainActor in
                            do {
                                try await waitForResponseFlush()
                                guard operation == id, !Task.isCancelled else { return }
                                let began: Bool
                                do {
                                    began = try acquired.beginInstallation()
                                } catch {
                                    state = .recoveryRequired
                                    block(
                                        id,
                                        reason:
                                            "Update authorization outcome is unknown; coordinator recovery is required."
                                    )
                                    return
                                }
                                guard began else {
                                    block(
                                        id,
                                        reason:
                                            "Update permission expired or was revoked; installation was not started.")
                                    return
                                }
                                state = .installationStarted
                                timeoutTask?.cancel()
                                timeoutTask = nil
                                installTask = nil
                                // The external coordinator owns recovery now.
                                // Never release on handler return, timeout or exit.
                                install()
                            } catch {
                                block(id, reason: "Update did not begin: \(error.localizedDescription)")
                            }
                        }
                    } catch {
                        block(id, reason: "Update guard unavailable: \(error.localizedDescription)")
                    }
                }
                timeoutTask = Task { @MainActor in
                    do {
                        try await waitForTimeout()
                        guard !Task.isCancelled else { return }
                        block(id, reason: "Update preparation timed out; installation was not started.")
                    } catch {}
                }
            }
        } onCancel: {
            Task { @MainActor in self.block(id, reason: "Update request cancelled; installation was not started.") }
        }
    }

    /// Sparkle can report failure after accepting the request. Once action
    /// began, recovery belongs to the durable coordinator, never this timer.
    func interrupted(reason: String) {
        guard let operation else { return }
        block(operation, reason: reason)
    }

    /// One explicit coordinator reconciliation; never idle polling or expiry.
    func reconcileRecovery() async -> Bool {
        guard state == .recoveryRequired, let id = operation, let hold else { return false }
        guard (try? await hold.oldRuntimeIsVerifiedRestored()) == true,
            state == .recoveryRequired, operation == id, !Task.isCancelled
        else { return false }
        operation = nil
        self.hold = nil
        state = .idle
        blockedReason = nil
        return true
    }

    private func block(_ id: UUID, reason: String) {
        guard operation == id else { return }
        blockedReason = reason
        if state == .installationStarted || state == .recoveryRequired {
            state = .recoveryRequired
            timeoutTask?.cancel()
            timeoutTask = nil
            installTask?.cancel()
            installTask = nil
            didBlock()
            return
        }
        operation = nil
        state = .blocked
        prepareTask?.cancel()
        prepareTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        installTask?.cancel()
        installTask = nil
        coordinator.cancelAcquisition(operation: id)
        hold?.abortIfInstallationHasNotBegun()
        hold = nil
        reply?.resume(returning: false)
        reply = nil
        didBlock()
    }
}
