import Darwin
import Foundation
import MicropodCore

public struct PreparedIsolatedRuntime: Sendable {
    public let identity: IsolatedRuntimeIdentity
    public let receipt: ManagedRuntimeReceipt
    public let workerSHA256: String
    /// The staged dedicated API, as installed (digests of root's copies).
    public let api: RuntimeComponentAPI?
    public init(
        identity: IsolatedRuntimeIdentity, receipt: ManagedRuntimeReceipt, workerSHA256: String,
        api: RuntimeComponentAPI? = nil
    ) {
        self.identity = identity
        self.receipt = receipt
        self.workerSHA256 = workerSHA256
        self.api = api
    }
}

/// Where a component update's restart takes its worker, API and guest from:
/// the sealed root-only copy of the verified target, and the digests each
/// must have. Nothing is taken from `/Applications`.
public struct RuntimeComponentSource: Sendable {
    public let bundle: URL
    public let helperSHA256: String
    public let api: RuntimeComponentAPI
    public init(bundle: URL, helperSHA256: String, api: RuntimeComponentAPI) {
        self.bundle = bundle
        self.helperSHA256 = helperSHA256
        self.api = api
    }
}
public protocol IsolatedRuntimeHostDriving: Sendable {
    func prepare(ownerUID: UInt32) async throws -> PreparedIsolatedRuntime
    /// Stages exactly `components`; refuses any other bytes.
    func prepare(ownerUID: UInt32, components: RuntimeComponentSource) async throws -> PreparedIsolatedRuntime
    /// Re-stages a runtime root retained: its Apple selection, worker and API.
    func restore(identity: IsolatedRuntimeIdentity, runtime: RuntimeComponentRuntime) async throws
        -> PreparedIsolatedRuntime
    func rigTransition(
        identity: IsolatedRuntimeIdentity, operation: UUID, action: String, installRoot: URL,
        generation: UInt64, targetState: String
    ) async throws -> RuntimeRigReceipt?
    func activateAPI(identity: IsolatedRuntimeIdentity, selection: ManagedRuntimeLocation.Selection) throws
    func coordinateRuntime(
        identity: IsolatedRuntimeIdentity, peer: RuntimeProcessBirth, call: RuntimeCoordinationRigCall
    ) async throws -> RuntimeCoordinationRigReply
    func run(
        identity: IsolatedRuntimeIdentity, workerSHA256: String, request: IsolatedRuntimeWorkerRequest,
        willBegin: @escaping @Sendable (RuntimeProcessBirth) async throws -> Void
    ) async throws -> IsolatedRuntimeObservation
}
extension IsolatedRuntimeHostDriving {
    public func prepare(ownerUID: UInt32, components: RuntimeComponentSource) async throws
        -> PreparedIsolatedRuntime
    {
        throw MicropodError.message("This runtime cannot stage component updates")
    }
    public func restore(identity: IsolatedRuntimeIdentity, runtime: RuntimeComponentRuntime) async throws
        -> PreparedIsolatedRuntime
    {
        throw MicropodError.message("This runtime cannot restore retained components")
    }
    public func rigTransition(
        identity: IsolatedRuntimeIdentity, operation: UUID, action: String, installRoot: URL,
        generation: UInt64, targetState: String
    ) async throws -> RuntimeRigReceipt? { nil }
    public func activateAPI(identity: IsolatedRuntimeIdentity, selection: ManagedRuntimeLocation.Selection) throws {}
    public func coordinateRuntime(
        identity: IsolatedRuntimeIdentity, peer: RuntimeProcessBirth, call: RuntimeCoordinationRigCall
    ) async throws -> RuntimeCoordinationRigReply {
        throw MicropodError.message("The private runtime coordinator is unavailable")
    }
}
public struct NativeIsolatedRuntimeHostDriver: IsolatedRuntimeHostDriving {
    public let executable: URL
    public init(executable: URL) { self.executable = executable }
    /// Install and repair: stage from a sealed root-only copy of the setup
    /// app this helper runs from, never from the bundle in `/Applications`,
    /// which another admin-group process can rename and replace.
    public func prepare(ownerUID: UInt32) async throws -> PreparedIsolatedRuntime {
        try RootRuntimeStorage.prepareRoot()
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let copy = IsolatedRuntimePolicy.root.appendingPathComponent(
            "components/install-" + UUID().uuidString + "/" + RuntimeComponentUpdater.bundleName)
        defer { try? RuntimeSecureCopy.remove(copy.deletingLastPathComponent()) }
        try RuntimeSecureCopy.copy(bundle, to: copy)
        try RuntimeCodeIdentity.verifyBundle(copy, identifier: IsolatedRuntimePolicy.setupIdentifier, notarized: false)
        let helper = try ManagedRuntimeInstaller.sha256(
            copy.appendingPathComponent("Contents/MacOS/MicropodRuntimeHost"))
        guard
            RuntimeCodeIdentity.processMatchesExecutable(
                getpid(), url: executable, identifier: IsolatedRuntimePolicy.helperIdentifier),
            try ManagedRuntimeInstaller.sha256(executable) == helper
        else { throw MicropodError.message("The setup app is not the one this helper runs from") }
        return try await stage(ownerUID: ownerUID, from: copy, expected: nil)
    }

    public func prepare(ownerUID: UInt32, components: RuntimeComponentSource) async throws -> PreparedIsolatedRuntime {
        try RootRuntimeStorage.prepareRoot()
        try RuntimeSecureCopy.assertSealed(components.bundle, owner: 0, group: 0)
        guard
            try ManagedRuntimeInstaller.sha256(
                components.bundle.appendingPathComponent("Contents/MacOS/MicropodRuntimeHost"))
                == components.helperSHA256
        else { throw MicropodError.message("The verified runtime components changed") }
        return try await stage(ownerUID: ownerUID, from: components.bundle, expected: components)
    }

    private func stage(ownerUID: UInt32, from bundle: URL, expected: RuntimeComponentSource?) async throws
        -> PreparedIsolatedRuntime
    {
        let receipt = try await ManagedRuntimeInstaller(root: RootRuntimeStorage.apple).prepare()
        try Task.checkCancellation()
        let identity = try ServiceAccountProvisioner(
            directory: LocalServiceAccountDirectory(), journal: RootRuntimeStorage.accountPlan
        ).prepare(ownerUID: ownerUID)
        let digest = try RootRuntimeStorage.installWorker(
            from: bundle.appendingPathComponent("Contents/MacOS/MicropodRuntimeHost"),
            expectedSHA256: expected?.helperSHA256)
        try RootRuntimeStorage.publish(identity, receipt: receipt)
        let configuration = try RootRuntimeStorage.installAPI(
            from: bundle.appendingPathComponent("Contents/MacOS/MicropodAPI"),
            guest: bundle.appendingPathComponent("Contents/Resources/micropod-guest"),
            identity: identity, selection: receipt.selection, expected: expected?.api)
        return PreparedIsolatedRuntime(
            identity: identity, receipt: receipt, workerSHA256: digest,
            api: .init(executableSHA256: configuration.executableSHA256, guestSHA256: configuration.guestSHA256))
    }

    /// The previous runtime's bytes are still under `RuntimeHost`: its worker,
    /// API tool directory and Apple payload are content-addressed. Each is
    /// verified against its digest before it is staged again.
    public func restore(identity: IsolatedRuntimeIdentity, runtime: RuntimeComponentRuntime) async throws
        -> PreparedIsolatedRuntime
    {
        let worker = try RootRuntimeStorage.worker(digest: runtime.workerSHA256)
        guard try ManagedRuntimeInstaller.sha256(worker) == runtime.workerSHA256 else {
            throw MicropodError.message("The retained runtime worker changed")
        }
        let receipt = ManagedRuntimeReceipt(selection: runtime.selection, files: AppleRuntimeRelease.payloadSHA256)
        try await ManagedRuntimeInstaller(root: RootRuntimeStorage.apple).verify(receipt)
        try RootRuntimeStorage.stageAPI(
            .init(
                instance: identity.instance, selection: runtime.selection,
                executableSHA256: runtime.api.executableSHA256, guestSHA256: runtime.api.guestSHA256),
            identity: identity)
        return PreparedIsolatedRuntime(
            identity: identity, receipt: receipt, workerSHA256: runtime.workerSHA256, api: runtime.api)
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
    public func coordinateRuntime(
        identity: IsolatedRuntimeIdentity, peer: RuntimeProcessBirth, call: RuntimeCoordinationRigCall
    ) async throws -> RuntimeCoordinationRigReply {
        try ServiceAccountProvisioner.verifyExisting(identity: identity)
        var user = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var bytes = [CChar](repeating: 0, count: 65536)
        guard getpwuid_r(identity.ownerUID, &user, &bytes, bytes.count, &result) == 0,
            result != nil, let home = user.pw_dir
        else { throw MicropodError.message("The runtime owner's home is unavailable") }
        return try await RuntimeCoordinationRigClient(
            ownerHome: URL(fileURLWithPath: String(cString: home)), identity: identity, peer: peer
        ).transition(call)
    }
    public func run(
        identity: IsolatedRuntimeIdentity, workerSHA256: String, request: IsolatedRuntimeWorkerRequest,
        willBegin: @escaping @Sendable (RuntimeProcessBirth) async throws -> Void
    ) async throws -> IsolatedRuntimeObservation {
        try ServiceAccountProvisioner.verifyExisting(identity: identity)
        try IsolatedRuntimeProcessInventory.assertSettled(identity: identity, selection: request.selection)
        let result = try await IsolatedWorkerRunner().run(
            identity: identity, workerSHA256: workerSHA256, request: request, willBegin: willBegin)
        try IsolatedRuntimeProcessInventory.assertSettled(identity: identity, selection: request.selection)
        return result
    }
}
