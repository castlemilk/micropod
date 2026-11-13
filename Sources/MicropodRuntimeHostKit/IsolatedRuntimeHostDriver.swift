import Darwin
import Foundation
import MicropodCore

public struct PreparedIsolatedRuntime: Sendable {
    public let identity: IsolatedRuntimeIdentity
    public let receipt: ManagedRuntimeReceipt
    public let workerSHA256: String
    public init(identity: IsolatedRuntimeIdentity, receipt: ManagedRuntimeReceipt, workerSHA256: String) {
        self.identity = identity
        self.receipt = receipt
        self.workerSHA256 = workerSHA256
    }
}
public protocol IsolatedRuntimeHostDriving: Sendable {
    func prepare(ownerUID: UInt32) async throws -> PreparedIsolatedRuntime
    func rigTransition(
        identity: IsolatedRuntimeIdentity, operation: UUID, action: String, installRoot: URL,
        generation: UInt64, targetState: String
    ) async throws -> RuntimeRigReceipt?
    func activateAPI(identity: IsolatedRuntimeIdentity, selection: ManagedRuntimeLocation.Selection) throws
    func run(
        identity: IsolatedRuntimeIdentity, workerSHA256: String, request: IsolatedRuntimeWorkerRequest,
        willBegin: @escaping @Sendable (RuntimeProcessBirth) async throws -> Void
    ) async throws -> IsolatedRuntimeObservation
}
extension IsolatedRuntimeHostDriving {
    public func rigTransition(
        identity: IsolatedRuntimeIdentity, operation: UUID, action: String, installRoot: URL,
        generation: UInt64, targetState: String
    ) async throws -> RuntimeRigReceipt? { nil }
    public func activateAPI(identity: IsolatedRuntimeIdentity, selection: ManagedRuntimeLocation.Selection) throws {}
}
public struct NativeIsolatedRuntimeHostDriver: IsolatedRuntimeHostDriving {
    public let executable: URL
    public init(executable: URL) { self.executable = executable }
    public func prepare(ownerUID: UInt32) async throws -> PreparedIsolatedRuntime {
        try RootRuntimeStorage.prepareRoot()
        try RuntimeCodeIdentity.verifyExecutable(executable, identifier: IsolatedRuntimePolicy.helperIdentifier)
        let receipt = try await ManagedRuntimeInstaller(root: RootRuntimeStorage.apple).prepare()
        try Task.checkCancellation()
        let identity = try ServiceAccountProvisioner(
            directory: LocalServiceAccountDirectory(), journal: RootRuntimeStorage.accountPlan
        ).prepare(ownerUID: ownerUID)
        let digest = try RootRuntimeStorage.installWorker(from: executable)
        try RootRuntimeStorage.publish(identity, receipt: receipt)
        try RootRuntimeStorage.installAPI(
            from: executable.deletingLastPathComponent().appendingPathComponent("MicropodAPI"),
            identity: identity, selection: receipt.selection)
        return PreparedIsolatedRuntime(identity: identity, receipt: receipt, workerSHA256: digest)
    }
    public func rigTransition(
        identity: IsolatedRuntimeIdentity, operation: UUID, action: String, installRoot: URL,
        generation: UInt64, targetState: String
    ) async throws -> RuntimeRigReceipt? {
        guard let registration = try IsolatedRuntimeRigRegistration.read(identity: identity) else { return nil }
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 65536)
        guard getpwuid_r(identity.ownerUID, &record, &buffer, buffer.count, &result) == 0,
            result != nil, let path = record.pw_dir
        else { throw MicropodError.message("The runtime owner's home is unavailable") }
        let client = RuntimeRigClient(
            ownerHome: URL(fileURLWithPath: String(cString: path)), peerUID: identity.ownerUID,
            runtimeInstance: identity.instance)
        let receipt = try await client.transition(
            operation: operation, action: action, installRoot: installRoot,
            localGeneration: generation, targetState: targetState)
        guard
            receipt?.hostID == registration.hostID
                || (["draining", "drained", "aborting", "cancelled", "blocked"].contains(receipt?.phase ?? "")
                    && receipt?.hostID == "")
        else {
            throw MicropodError.message("The runtime rig host identity changed")
        }
        return receipt
    }
    public func activateAPI(identity: IsolatedRuntimeIdentity, selection: ManagedRuntimeLocation.Selection) throws {
        try RootRuntimeStorage.activateAPI(identity: identity, selection: selection)
    }
    public func run(
        identity: IsolatedRuntimeIdentity, workerSHA256: String, request: IsolatedRuntimeWorkerRequest,
        willBegin: @escaping @Sendable (RuntimeProcessBirth) async throws -> Void
    ) async throws -> IsolatedRuntimeObservation {
        guard let record = try LocalServiceAccountDirectory().user() else {
            throw MicropodError.message("The managed runtime account is missing")
        }
        try ServiceAccountPlan.verify(record, identity: identity)
        try IsolatedRuntimeProcessInventory.assertSettled(identity: identity, selection: request.selection)
        let result = try await IsolatedWorkerRunner().run(
            identity: identity, workerSHA256: workerSHA256, request: request, willBegin: willBegin)
        try IsolatedRuntimeProcessInventory.assertSettled(identity: identity, selection: request.selection)
        return result
    }
}
