import Foundation
import MicropodCore
import MicropodRuntime
import Observation

@MainActor @Observable
final class ManagedRuntimeController {
    static let shared = ManagedRuntimeController()
    private(set) var operation: RuntimeLifecycleOperation?
    private(set) var error: String?
    @ObservationIgnored private let manager: RuntimeLifecycleManager
    @ObservationIgnored private var observer: Task<Void, Never>?
    @ObservationIgnored var didBegin: (@MainActor (RuntimeLifecycleAction) -> Void)?
    @ObservationIgnored var didComplete: (@MainActor (RuntimeLifecycleOperation) async -> Void)?
    var isBusy: Bool { operation.map { !$0.isTerminal } ?? false }
    var needsRecovery: Bool { operation?.phase == "recoveryRequired" }

    init(manager: RuntimeLifecycleManager = .shared) {
        self.manager = manager
    }

    @discardableResult
    func begin(_ action: RuntimeLifecycleAction) async throws -> RuntimeLifecycleOperation {
        error = nil
        do {
            didBegin?(action)
            operation = try await manager.begin(action)
            observe()
            return operation!
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }
    func request(_ action: RuntimeLifecycleAction) {
        Task { do { _ = try await begin(action) } catch {} }
    }
    func refresh() async {
        operation = await manager.status()
    }
    func cancel() async { await manager.cancel() }
    func recover() async throws {
        operation = try await manager.recover()
        observe()
    }
    var statusReport: [String: Any] {
        guard let operation,
            let data = try? JSONEncoder().encode(operation),
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ["phase": "idle", "message": "No runtime operation is active"] }
        return body
    }
    private func observe() {
        observer?.cancel()
        observer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refresh()
                if let operation, operation.isTerminal {
                    if operation.phase == "completed" { await didComplete?(operation) }
                    return
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }
}
