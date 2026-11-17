import Darwin
import Foundation
import MicropodCore
import MicropodRuntime

@MainActor
final class ManagedUpdateAdmission: UpdateAdmissionCoordinating {
    struct Candidate {
        let version: String
        let url: URL
        let signature: String
        let bytes: UInt64
        let source: String
        var isCompatible: Bool {
            url.scheme == "https" && url.host == "github.com"
                && version.range(of: "^\\d+\\.\\d+\\.\\d+$", options: .regularExpression) != nil
                && url.path == "/castlemilk/micropod/releases/download/v\(version)/Micropod.dmg"
                && url.user == nil && url.password == nil && url.port == nil && url.query == nil && url.fragment == nil
                && Data(base64Encoded: signature)?.count == 64 && bytes > 0 && bytes <= 1 << 30
                && source.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil
        }
    }
    var candidate: Candidate?
    let store: UpdateContinuityStore
    init(store: UpdateContinuityStore = .standard) { self.store = store }
    var isAvailable: Bool { PersistentDesktopAgents.enabled && AppDependencies.shared.client.usesIsolatedTransport }

    func acquire(operation: UUID) async throws -> any UpdateAdmissionHolding {
        guard isAvailable, let candidate, candidate.isCompatible,
            DesktopActivity.shared.closeIfIdle()
        else { throw MicropodError.message("The desktop is busy or no compatible signed update is available") }
        do {
            guard try await EngineRegistry.shared.sandbox.list().isEmpty else {
                throw MicropodError.message(
                    "This desktop owns sandbox records that cannot be handed off. Workload-service jobs can continue; remove or finish the desktop sandboxes before updating."
                )
            }
            let identity = try IsolatedRuntimeIdentity.readRootOwned()
            let services = try await PersistentDesktopAgents.witness(specs: Self.specs)
            let health = try await Self.probe()
            guard !Task.isCancelled, health.nativeState == "nativeReady",
                health.identity?.instance == identity.instance,
                let owner = try RuntimeProcessBirth.read(getpid())
            else { throw MicropodError.message("The dedicated native runtime is not verified ready") }
            let receipt = UpdateContinuityReceipt(
                operation: operation, owner: owner,
                sourceVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
                sourceExecutableSHA256: try ManagedUpdateAdmission.currentExecutableDigest(),
                sourceAppPath: Bundle.main.bundlePath,
                targetVersion: candidate.version, targetSourceRevision: candidate.source,
                artifactURL: candidate.url.absoluteString,
                artifactSignature: candidate.signature, artifactBytes: candidate.bytes,
                runtimeInstance: identity.instance,
                apiConfigurationSHA256: try UpdateServiceWitness.digest(IsolatedRuntimeAPIConfiguration.fileURL),
                services: services)
            try receipt.verifyServices()
            try store.prepare(receipt)
            return Hold(receipt: receipt, store: store)
        } catch {
            // A failed/lost write may have retained the transaction. Never
            // reopen on an assumption about the outcome of persistence.
            if !store.requiresRecovery {
                DesktopActivity.shared.reopen()
            }
            throw error
        }
    }

    func cancelAcquisition(operation: UUID) {
        guard let value = try? store.read(), value.operation == operation else { return }
        Hold(receipt: value, store: store).abortIfInstallationHasNotBegun()
    }

    static var specs: [AgentSpec] {
        AgentSupervisor.micropodSpecs(enabled: { _ in true }, onStatus: { _ in }).specsForUI
    }

    static func currentExecutableDigest() throws -> String {
        guard let executable = Bundle.main.executableURL,
            RuntimeCodeIdentity.processMatchesExecutable(
                getpid(), url: executable, identifier: "com.skunkworq.micropod")
        else { throw MicropodError.message("The running desktop does not match its signed installed executable") }
        return try UpdateServiceWitness.digest(executable)
    }

    private static func probe() async throws -> IsolatedRuntimeStatus {
        let health = try await IsolatedRuntimeClient().call(.init(action: .probe))
        guard ["idle", "completed"].contains(health.phase), health.error == nil, health.nativeState == "nativeReady"
        else {
            throw MicropodError.message("The dedicated runtime is not ready or has unfinished maintenance")
        }
        let bytes = try await IsolatedRuntimeTransport.shared.request(
            path: "/api/micropod.v1.SystemService/Ping", body: Data("{}".utf8), timeout: .seconds(5))
        let ping = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        guard ping?["runtimeBackend"] as? String == "native", ping?["status"] as? String == "running" else {
            throw MicropodError.message("The retained API did not verify its native backend")
        }
        return health
    }

    func recoverRetainedTransaction() async throws -> Bool {
        guard let receipt = try store.read() else { return false }
        if receipt.phase == .downloadRejected { return try await Self.finishRejectedDownload(receipt, store: store) }
        if receipt.isTerminal {
            let expected = receipt.phase == .succeeded ? receipt.targetVersion : receipt.sourceVersion
            guard expected == Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
                return false
            }
            if receipt.phase == .succeeded,
                receipt.targetSourceRevision != Bundle.main.object(forInfoDictionaryKey: "MicropodSourceRevision")
                    as? String
            {
                return false
            }
            try RuntimeCodeIdentity.verifyExecutable(Bundle.main.bundleURL, identifier: "com.skunkworq.micropod")
            if receipt.phase == .aborted {
                guard try ManagedUpdateAdmission.currentExecutableDigest() == receipt.sourceExecutableSHA256
                else { return false }
            }
            try receipt.verifyServices()
            DesktopActivity.shared.reopen()
            return true
        }
        try await reconcileReplacement()
        return try store.read()?.isTerminal == true
    }

    private static func finishRejectedDownload(_ receipt: UpdateContinuityReceipt, store: UpdateContinuityStore)
        async throws -> Bool
    {
        let currentOwner = try RuntimeProcessBirth.read(getpid())
        let originalExited = try receipt.owner.hasExited()
        guard receipt.sourceVersion == Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            try ManagedUpdateAdmission.currentExecutableDigest() == receipt.sourceExecutableSHA256,
            receipt.owner == currentOwner || originalExited
        else { return false }
        try RuntimeCodeIdentity.verifyExecutable(Bundle.main.bundleURL, identifier: "com.skunkworq.micropod")
        try receipt.verifyServices()
        _ = try await probe()
        try receipt.verifyServices()
        guard try ManagedUpdateAdmission.currentExecutableDigest() == receipt.sourceExecutableSHA256 else {
            return false
        }
        _ = try store.transition(
            operation: receipt.operation, generation: receipt.generation,
            from: .downloadRejected, to: .aborted, detail: receipt.detail)
        DesktopActivity.shared.reopen()
        return true
    }

    /// Only the replacement can settle success, after checking its own signed
    /// identity and the same retained workload owner incarnations.
    func reconcileReplacement() async throws {
        guard let receipt = try store.read(), !receipt.isTerminal else { return }
        if receipt.phase == .prepared,
            receipt.sourceVersion == Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            try receipt.owner.hasExited(),
            try ManagedUpdateAdmission.currentExecutableDigest() == receipt.sourceExecutableSHA256
        {
            try receipt.verifyServices()
            _ = try store.transition(
                operation: receipt.operation, generation: receipt.generation,
                from: .prepared, to: .aborted, detail: "Verified restart before the installer received permission")
            DesktopActivity.shared.reopen()
            return
        }
        guard [.downloading, .extracting, .installing].contains(receipt.phase),
            receipt.targetVersion == Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            receipt.targetSourceRevision == Bundle.main.object(forInfoDictionaryKey: "MicropodSourceRevision")
                as? String,
            try receipt.owner.hasExited()
        else { throw MicropodError.message("The interrupted update needs verified recovery; its receipt was retained") }
        try RuntimeCodeIdentity.verifyExecutable(Bundle.main.bundleURL, identifier: "com.skunkworq.micropod")
        guard UpdaterPolicy.bundleDeclaresImplementedWorkloadProtocol else {
            throw MicropodError.message("The replacement does not support the retained workload protocol")
        }
        try receipt.verifyServices()
        let health = try await Self.probe()
        guard health.nativeState == "nativeReady", health.identity?.instance == receipt.runtimeInstance else {
            throw MicropodError.message("The replacement has not verified its native runtime")
        }
        try receipt.verifyServices()
        _ = try store.transition(
            operation: receipt.operation, generation: receipt.generation,
            from: receipt.phase, to: .succeeded, detail: "Signed replacement and unchanged workload owners verified")
        DesktopActivity.shared.reopen()
    }

    @MainActor
    final class Hold: UpdateAdmissionHolding {
        let receipt: UpdateContinuityReceipt
        let store: UpdateContinuityStore
        init(receipt: UpdateContinuityReceipt, store: UpdateContinuityStore) {
            self.receipt = receipt
            self.store = store
        }
        func beginInstallation() throws -> Bool {
            guard DispatchTime.now().uptimeNanoseconds < receipt.beginDeadlineUptimeNanoseconds,
                try RuntimeProcessBirth.read(getpid()) == receipt.owner,
                DesktopActivity.shared.isClosed
            else { return false }
            try receipt.verifyServices()
            _ = try store.transition(
                operation: receipt.operation, generation: receipt.generation,
                from: .prepared, to: .downloading)
            return true
        }
        func abortIfInstallationHasNotBegun() {
            do {
                guard try RuntimeProcessBirth.read(getpid()) == receipt.owner,
                    try ManagedUpdateAdmission.currentExecutableDigest() == receipt.sourceExecutableSHA256
                else { return }
                try receipt.verifyServices()
                _ = try store.transition(
                    operation: receipt.operation, generation: receipt.generation,
                    from: .prepared, to: .aborted, detail: "Cancelled before handing permission to Sparkle")
                DesktopActivity.shared.reopen()
            } catch { /* Unknown/newer/begun state stays fenced. */  }
        }
        func oldRuntimeIsVerifiedRestored() async throws -> Bool {
            if let rejected = try store.read(), rejected.operation == receipt.operation,
                rejected.generation == receipt.generation, rejected.phase == .downloadRejected
            {
                return try await ManagedUpdateAdmission.finishRejectedDownload(rejected, store: store)
            }
            guard let current = try store.read(), current.operation == receipt.operation,
                current.generation == receipt.generation, current.phase == .aborted,
                try ManagedUpdateAdmission.currentExecutableDigest() == receipt.sourceExecutableSHA256
            else { return false }
            try current.verifyServices()
            return true
        }
    }
}
