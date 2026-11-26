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

    /// Sentinel runtime instance UUID recorded in continuity receipts for rootless
    /// HVF/Sandbox updates (no root-owned Apple `container` authority exists).
    nonisolated static let rootlessRuntimeInstance = UUID(uuidString: "00000000-0000-4000-8000-000000000000")!

    /// What this host shows about the root-managed (isolated) Apple runtime,
    /// whose workloads the managed admission witnesses across an update.
    enum RootManagedRuntimeEvidence: Equatable, Sendable {
        /// Positive evidence that none is installed or running.
        case absent
        case present(String)
        /// Absence could not be established; it counts as present.
        case indeterminate(String)
    }

    /// Whether the root-managed runtime is installed: its published identity
    /// or the authority's LaunchDaemon exists. Absent means `lstat` reported
    /// ENOENT, not merely that the path could not be read.
    nonisolated static func rootManagedRuntimeInstallation(
        identity: URL = IsolatedRuntimePolicy.identityURL, authority: URL = IsolatedRuntimePolicy.authorityPlist
    ) -> RootManagedRuntimeEvidence {
        for (name, url) in [("runtime identity", identity), ("runtime authority LaunchDaemon", authority)] {
            var info = stat()
            if lstat(url.path, &info) == 0 { return .present("the \(name) \(url.path) exists") }
            let failure = errno
            guard failure == ENOENT || failure == ENOTDIR else {
                return .indeterminate("cannot inspect \(url.path): \(String(cString: strerror(failure)))")
            }
        }
        return .absent
    }

    /// The installation check, plus no root `MicropodRuntimeHost` running
    /// (an installation in progress has a helper before it has an identity).
    nonisolated static func rootManagedRuntimeEvidence(
        identity: URL = IsolatedRuntimePolicy.identityURL, authority: URL = IsolatedRuntimePolicy.authorityPlist,
        helperIsRunning: () throws -> Bool = rootHelperIsRunning
    ) -> RootManagedRuntimeEvidence {
        let installation = rootManagedRuntimeInstallation(identity: identity, authority: authority)
        guard installation == .absent else { return installation }
        do {
            return try helperIsRunning() ? .present("a root MicropodRuntimeHost is running") : .absent
        } catch {
            return .indeterminate("cannot inspect running helpers: \(error.localizedDescription)")
        }
    }

    /// An unreadable process table lists nothing, which would read as "no
    /// helper": the scan must first find this process.
    nonisolated static func rootHelperIsRunning() throws -> Bool {
        guard let own = UpdateServiceWitness.processPath(getpid()),
            UpdateServiceWitness.processIDs(executable: own).contains(getpid())
        else { throw MicropodError.message("the process table could not be read") }
        return try RuntimeSetupInstallation.helperIsRunning()
    }

    /// A signed desktop update may skip the managed runtime's service witness
    /// and probe only where there is no such runtime: positive evidence that
    /// none is installed or running, a default runtime of HVF or the sandbox
    /// (a user-writable setting, so never sufficient alone), and a bundle that
    /// declares the workload protocol this code implements.
    nonisolated static func requireRootlessAdmission(
        defaultRuntime: String, declaresWorkloadProtocol: Bool, evidence: RootManagedRuntimeEvidence
    ) throws {
        guard declaresWorkloadProtocol else {
            throw MicropodError.message("This app bundle does not declare the workload protocol its updater implements")
        }
        guard ["hvf", "sandbox"].contains(defaultRuntime) else {
            throw MicropodError.message("A rootless update needs the hvf or sandbox runtime, not \(defaultRuntime)")
        }
        switch evidence {
        case .absent: return
        case .present(let reason), .indeterminate(let reason):
            throw MicropodError.message(
                "A rootless update needs evidence that no root-managed runtime is installed or running: \(reason)")
        }
    }

    /// What an abort, a rejected download or a finished update re-checks
    /// before the desktop reopens: a managed receipt's witnessed services, or
    /// that a rootless receipt names none (it has no runtime to witness or
    /// probe). Nothing is installed on these paths.
    ///
    /// A rootless receipt is the receipt's own claim, so it is checked
    /// against the host too: with a root-managed runtime installed (the
    /// cheap lstat check), a receipt rewritten to the rootless sentinel is
    /// refused rather than let skip the service witness.
    nonisolated static func verifyRetained(
        _ receipt: UpdateContinuityReceipt,
        installation: @autoclosure () -> RootManagedRuntimeEvidence = rootManagedRuntimeInstallation()
    ) throws {
        guard receipt.runtimeInstance == rootlessRuntimeInstance else { return try receipt.verifyServices() }
        guard receipt.services.isEmpty, receipt.apiConfigurationSHA256.isEmpty else {
            throw MicropodError.message("A rootless update receipt cannot name managed services")
        }
        switch installation() {
        case .absent: return
        case .present(let reason), .indeterminate(let reason):
            throw MicropodError.message(
                "A rootless update receipt on a host with a root-managed runtime needs its service witness: \(reason)")
        }
    }

    /// What installing, or settling an installation, re-checks. A rootless
    /// receipt's admission rested on the absence of a root-managed runtime
    /// and on the workload protocol, so both must still hold.
    nonisolated static func verifyContinuity(
        _ receipt: UpdateContinuityReceipt,
        declaresWorkloadProtocol: @autoclosure () -> Bool = UpdaterPolicy.bundleDeclaresImplementedWorkloadProtocol,
        evidence: @autoclosure () -> RootManagedRuntimeEvidence = rootManagedRuntimeEvidence()
    ) throws {
        guard receipt.runtimeInstance == rootlessRuntimeInstance else { return try receipt.verifyServices() }
        guard receipt.services.isEmpty, receipt.apiConfigurationSHA256.isEmpty else {
            throw MicropodError.message("A rootless update receipt cannot name managed services")
        }
        guard declaresWorkloadProtocol() else {
            throw MicropodError.message("The replacement does not support the retained workload protocol")
        }
        switch evidence() {
        case .absent: return
        case .present(let reason), .indeterminate(let reason):
            throw MicropodError.message(
                "A root-managed runtime may own workloads that this rootless update did not witness: \(reason)")
        }
    }

    /// Cheap (no process scan): views read it through the restart guard.
    /// `acquire` checks the whole evidence before admitting anything.
    var usesRootlessAdmission: Bool {
        (try? Self.requireRootlessAdmission(
            defaultRuntime: EngineRegistry.shared.defaultName,
            declaresWorkloadProtocol: UpdaterPolicy.bundleDeclaresImplementedWorkloadProtocol,
            evidence: Self.rootManagedRuntimeInstallation())) != nil
    }

    var isAvailable: Bool {
        (PersistentDesktopAgents.enabled && AppDependencies.shared.client.usesIsolatedTransport)
            || usesRootlessAdmission
    }

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
            if usesRootlessAdmission {
                // Bind the admission to the whole evidence now, including the
                // running helpers the cheap availability check skips.
                try Self.requireRootlessAdmission(
                    defaultRuntime: EngineRegistry.shared.defaultName,
                    declaresWorkloadProtocol: UpdaterPolicy.bundleDeclaresImplementedWorkloadProtocol,
                    evidence: Self.rootManagedRuntimeEvidence())
                guard !Task.isCancelled, let owner = try RuntimeProcessBirth.read(getpid()) else {
                    throw MicropodError.message("Could not verify desktop process identity for rootless update")
                }
                let receipt = UpdateContinuityReceipt(
                    operation: operation, owner: owner,
                    sourceVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
                    sourceExecutableSHA256: try ManagedUpdateAdmission.currentExecutableDigest(),
                    sourceAppPath: Bundle.main.bundlePath,
                    targetVersion: candidate.version, targetSourceRevision: candidate.source,
                    artifactURL: candidate.url.absoluteString,
                    artifactSignature: candidate.signature, artifactBytes: candidate.bytes,
                    runtimeInstance: Self.rootlessRuntimeInstance,
                    apiConfigurationSHA256: "",
                    services: [])
                try Self.verifyContinuity(receipt)
                try store.prepare(receipt)
                return Hold(receipt: receipt, store: store)
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
            try Self.verifyRetained(receipt)
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
        try verifyRetained(receipt)
        // A rootless update has no dedicated runtime to probe.
        if receipt.runtimeInstance != rootlessRuntimeInstance {
            _ = try await probe()
            try verifyRetained(receipt)
        }
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
            try Self.verifyRetained(receipt)
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
        if receipt.runtimeInstance == Self.rootlessRuntimeInstance {
            // Still no root-managed runtime whose workloads went unwitnessed.
            try Self.verifyContinuity(receipt)
            _ = try store.transition(
                operation: receipt.operation, generation: receipt.generation,
                from: receipt.phase, to: .succeeded, detail: "Signed rootless replacement verified")
            DesktopActivity.shared.reopen()
            return
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
            try ManagedUpdateAdmission.verifyContinuity(receipt)
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
                try ManagedUpdateAdmission.verifyRetained(receipt)
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
            try ManagedUpdateAdmission.verifyRetained(current)
            return true
        }
    }
}
