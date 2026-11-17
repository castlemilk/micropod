import Darwin
import Foundation

/// The app is neither release the upgrade knows: something else replaced it
/// (a Sparkle install on quit, a person). Retrying cannot change that.
struct RigUnidentifiedApp: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension RigUpgradeEngine {
    // MARK: Drain

    func drain(_ journal: inout RigUpgradeJournal) async throws {
        if journal.drain != nil { return }
        guard environment.drain.isConfigured() else {
            journal.drain = .skipped
            journal.notes.append("No Cuttlefish rig coordinator is configured on this host; nothing was drained.")
            try save(&journal)
            return
        }
        if journal.drainStartedAt == nil {
            // Intent before the first request: a reply can be lost after
            // Cuttlefish took the hold.
            try ledger.add(journal.drainSpec)
            journal.drainStartedAt = environment.now()
            journal.drainRequested = true
            try save(&journal)
        }
        let started = journal.drainStartedAt ?? environment.now()
        let deadline = started.addingTimeInterval(journal.options.drainTimeout)
        var last: RigDrainReply = RigDrainReply(.draining, reason: "no answer yet")
        var unavailableSince: Date?
        var outcome: RigUpgradeJournal.DrainOutcome?
        while outcome == nil {
            let reply = await environment.drain.drain(journal.drainSpec)
            last = reply
            switch reply.state {
            case .drained:
                journal.drain = .drained
                journal.notes.append("Cuttlefish drained in \(Int(environment.now().timeIntervalSince(started))) s.")
                try save(&journal)
                return
            case .incompatible:
                outcome = .incompatible
                continue
            case .unavailable:
                let since = unavailableSince ?? environment.now()
                unavailableSince = since
                if environment.now().timeIntervalSince(since) >= Self.unavailableGrace {
                    outcome = .unavailable
                    continue
                }
            case .draining, .refused:
                unavailableSince = nil
            }
            try environment.checkpoint("draining:poll")
            if environment.now() >= deadline {
                switch last.state {
                case .draining: outcome = .timedOut
                case .unavailable: outcome = .unavailable
                default: outcome = .refused
                }
                continue
            }
            try await environment.sleep(.seconds(2))
        }
        let result = outcome ?? .refused
        journal.drain = result
        let detail = last.reason ?? last.state.rawValue
        if result == .timedOut {
            journal.notes.append(
                "Cuttlefish held the rig but had not drained after \(Int(journal.options.drainTimeout)) s "
                    + "(\(detail)); work still running was interrupted.")
            try save(&journal)
            return
        }
        let message = "Cuttlefish did not drain this rig (\(result.rawValue): \(detail))"
        guard journal.options.forceUndrained else {
            try save(&journal)
            throw MicropodError.message(
                message + ". Retry once Cuttlefish drains, or pass --force-undrained to interrupt its jobs without one."
            )
        }
        journal.notes.append(message + "; --force-undrained: its jobs are interrupted without a hand-back.")
        try save(&journal)
    }

    /// Releases this journal's drain if it was ever requested.
    func releaseDrain(_ journal: inout RigUpgradeJournal) async {
        guard journal.drainRequested, !journal.drainReleased else { return }
        do {
            _ = try await environment.drain.release(journal.drainSpec)
            journal.drainReleased = true
            try? ledger.remove(journal.drainSpec)
        } catch {
            journal.notes.append(
                "Cuttlefish's drain was not released (\(Self.describe(error))). Cuttlefish lets go of it after two "
                    + "minutes without a heartbeat; the next upgrade or `micropod update recover --rig` releases it.")
        }
        try? save(&journal)
    }

    /// Releases drains earlier upgrades left outstanding; `keeping` is the
    /// running upgrade's own.
    func releaseOutstandingDrains(keeping current: RigDrainSpec?) async -> [String] {
        var notes: [String] = []
        for spec in ledger.entries() where spec != current {
            if environment.now().timeIntervalSince(spec.createdAt) > RigDrainLedger.retention {
                try? ledger.remove(spec)
                continue
            }
            do {
                _ = try await environment.drain.release(spec)
                try? ledger.remove(spec)
                notes.append("Released the drain of rig upgrade \(spec.operation.uuidString).")
            } catch {
                notes.append("The drain of rig upgrade \(spec.operation.uuidString) is still outstanding.")
            }
        }
        return notes
    }

    // MARK: Before disruption

    func verifyBeforeDisruption(_ journal: RigUpgradeJournal) throws {
        let app = URL(fileURLWithPath: journal.appPath)
        let staged = URL(fileURLWithPath: journal.stagedBundle)
        guard journal.source.matches(app) else {
            throw MicropodError.message("The installed app changed after the upgrade was prepared")
        }
        guard journal.target.matches(staged) else {
            throw MicropodError.message(
                "The staged \(journal.target.version) release changed after it was verified; it was not installed")
        }
        try environment.verifier.verifyApp(staged)
        try environment.verifySwapper()
        guard journal.target.matches(URL(fileURLWithPath: journal.targetPayload)) else {
            throw MicropodError.message("The \(journal.target.version) service payload changed after it was verified")
        }
        for file in journal.files where Self.digest(file.replacement) != file.replacementSHA256 {
            throw MicropodError.message("The replacement for \(file.installed) changed after it was verified")
        }
        try refuseConcurrentUpdates()
    }

    /// The Sparkle updater and runtime maintenance replace parts of what this
    /// upgrade stops; neither may be in flight.
    func refuseConcurrentUpdates() throws {
        guard !environment.runtimeMaintenance() else {
            throw MicropodError.message(
                "Runtime maintenance holds the runtime's admission gate; let it finish or run "
                    + "`micropod runtime recover` first")
        }
        guard !environment.desktopInstallerRunning() else {
            throw MicropodError.message("Sparkle's installer is running for Micropod; let it finish first")
        }
        let receipt: UpdateContinuityReceipt?
        do {
            receipt = try layout.desktopUpdates.read()
        } catch {
            throw MicropodError.message(
                "The desktop update transaction cannot be read (\(Self.describe(error))); "
                    + "reconcile it with `micropod update recover` first")
        }
        if let receipt, !receipt.isTerminal {
            throw MicropodError.message(
                "A desktop update to \(receipt.targetVersion) is \(receipt.phase.rawValue); "
                    + "finish or reconcile it with `micropod update recover` first")
        }
    }

    // MARK: Forward steps

    func stopAll(_ journal: RigUpgradeJournal) async throws {
        try await environment.app.stop(URL(fileURLWithPath: journal.appPath), timeout: .seconds(20))
        try checkpoint(journal, "stopped-app")
        for service in journal.services {
            try await environment.launch.bootout(service.label)
            try checkpoint(journal, "bootout:" + service.id)
        }
    }

    func swapApp(_ journal: RigUpgradeJournal) throws {
        let app = URL(fileURLWithPath: journal.appPath)
        let staged = URL(fileURLWithPath: journal.stagedBundle)
        if journal.target.matches(app) { return }
        guard journal.source.matches(app) else {
            throw RigUnidentifiedApp(
                message: "\(app.path) is neither \(journal.source.version) nor \(journal.target.version): something "
                    + "else replaced it after the upgrade was prepared")
        }
        guard journal.target.matches(staged) else {
            throw MicropodError.message("The staged \(journal.target.version) bundle changed; it was not installed")
        }
        try environment.verifier.verifyApp(staged)
        try environment.swap(staged, app)
        try checkpoint(journal, "swapped-app")
        guard journal.target.matches(app) else {
            throw MicropodError.message("The swap did not install \(journal.target.version)")
        }
    }

    func installFiles(_ journal: RigUpgradeJournal) throws {
        for file in journal.files {
            if Self.digest(file.installed) == file.replacementSHA256 { continue }
            guard Self.digest(file.replacement) == file.replacementSHA256 else {
                throw MicropodError.message("The replacement for \(file.installed) changed; it was not installed")
            }
            try Self.install(
                URL(fileURLWithPath: file.replacement), at: URL(fileURLWithPath: file.installed), mode: file.mode)
            try checkpoint(journal, "installed:" + URL(fileURLWithPath: file.installed).lastPathComponent)
        }
    }

    func startAll(_ journal: RigUpgradeJournal) async throws {
        for service in journal.services where service.wasLoaded {
            try await environment.launch.bootstrap(URL(fileURLWithPath: service.plist), label: service.label)
            try checkpoint(journal, "bootstrap:" + service.id)
        }
        if journal.appWasRunning {
            try await environment.app.launch(URL(fileURLWithPath: journal.appPath))
            try checkpoint(journal, "launched-app")
        }
    }

    func verify(_ journal: inout RigUpgradeJournal) async throws {
        let expectation = expectation(journal, for: journal.target)
        let report = try await gate(expectation, timeout: journal.options.healthTimeout)
        for note in report.notes where !journal.notes.contains(note) { journal.notes.append(note) }
        if let image = journal.baseline.smokeImage {
            guard report.runtimeAvailable else {
                throw MicropodError.message(
                    "The Apple runtime is not available on \(journal.target.version), though the smoke container "
                        + "ran before the upgrade")
            }
            try await environment.health.smoke(expectation, image: image)
            journal.notes.append("A \(image) smoke container ran and was removed on \(journal.target.version).")
        }
        try save(&journal)
    }

    func gate(_ expectation: RigHealthExpectation, timeout: TimeInterval) async throws -> RigHealthReport {
        let deadline = environment.now().addingTimeInterval(timeout)
        while true {
            let report = await environment.health.check(expectation)
            if report.healthy { return report }
            if environment.now() >= deadline {
                throw MicropodError.message(
                    "\(expectation.version) did not pass its health gate within \(Int(timeout)) s: "
                        + report.failures.joined(separator: "; "))
            }
            try await environment.sleep(.seconds(1))
        }
    }

    func complete(_ journal: inout RigUpgradeJournal) async throws {
        journal.notes += keepPrevious(journal)
        try checkpoint(journal, "kept-previous")
        await releaseDrain(&journal)
        try checkpoint(journal, "released-drain")
        for note in collectGarbage(journal) where !journal.notes.contains(note) { journal.notes.append(note) }
        var summary =
            "Micropod \(journal.target.version) replaced \(journal.source.version): the app with its CLI and MCP"
        let replaced = journal.services.map(\.id)
        if !replaced.isEmpty { summary += ", " + replaced.joined(separator: ", ") }
        summary += ". Drain: \(journal.drain?.rawValue ?? "skipped")."
        if journal.dedicatedRuntime { summary += " " + Self.dedicatedNote }
        journal.reason = summary
        try transition(&journal, to: .completed)
    }

    // MARK: Rollback

    /// Restores what it can, step by step, and always starts the services
    /// that were loaded and the app that was running before it reports what
    /// it could not restore. A failure that retrying might fix is retried by
    /// the next run; one it cannot (an app neither release knows) ends in
    /// recoveryRequired at once.
    func rollBack(_ journal: inout RigUpgradeJournal) async throws -> RigUpgradeJournal {
        var problems: [String] = []
        var permanent = false
        var health = ""
        func step(_ name: String, _ body: () async throws -> Void) async throws {
            do {
                try await body()
            } catch let interruption as RigUpgradeInterruption {
                throw interruption
            } catch let error as RigUnidentifiedApp {
                permanent = true
                problems.append(error.message)
            } catch {
                problems.append("\(name): \(Self.describe(error))")
            }
        }
        try await whileHeld(journal) {
            try await step("stopping the app") {
                try await environment.app.stop(URL(fileURLWithPath: journal.appPath), timeout: .seconds(20))
                try checkpoint(journal, "stopped-app")
            }
            for service in journal.services {
                try await step("booting out \(service.label)") {
                    try await environment.launch.bootout(service.label)
                    try checkpoint(journal, "bootout:" + service.id)
                }
            }
            try await step("restoring the app") { try restoreApp(journal) }
            for file in journal.files.reversed() {
                try await step("restoring \(file.installed)") { try restore(file, journal) }
            }
            problems += try await startAllBestEffort(journal)
            guard problems.isEmpty else { return }
            do {
                _ = try await gate(
                    expectation(journal, for: journal.source), timeout: min(journal.options.healthTimeout, 60))
            } catch let interruption as RigUpgradeInterruption {
                throw interruption
            } catch {
                health =
                    " The restored \(journal.source.version) did not pass its own health gate: \(Self.describe(error))"
            }
        }
        let dedicated = journal.dedicatedRuntime ? " " + Self.dedicatedNote : ""
        if problems.isEmpty {
            await releaseDrain(&journal)
            journal.reason =
                "Rolled back to \(journal.source.version): \(journal.failure ?? "the upgrade failed")." + health
                + dedicated
            try transition(&journal, to: .rolledBack)
            return journal
        }
        let summary = problems.joined(separator: "; ")
        journal.notes.append("Rollback run \(journal.attempts): \(summary)")
        guard permanent || journal.attempts >= Self.maximumAttempts else {
            try? save(&journal)
            throw MicropodError.message("Rollback did not finish (\(summary)); the next run resumes it")
        }
        journal.reason =
            "Rollback could not restore everything after \(journal.failure ?? "the upgrade failed"): \(summary). "
            + "Services and the app were started as they are; `micropod update recover --rig` retries." + dedicated
        journal.phase = .recoveryRequired
        await releaseDrain(&journal)
        try save(&journal)
        return journal
    }

    func restoreApp(_ journal: RigUpgradeJournal) throws {
        let app = URL(fileURLWithPath: journal.appPath)
        let staged = URL(fileURLWithPath: journal.stagedBundle)
        if journal.source.matches(app) { return }
        guard journal.target.matches(app), journal.source.matches(staged) else {
            throw RigUnidentifiedApp(
                message: "Neither \(app.path) nor \(staged.path) is the previous \(journal.source.version) app; "
                    + "both are kept as they are")
        }
        try environment.swap(staged, app)
        try checkpoint(journal, "swapped-back")
        guard journal.source.matches(app) else {
            throw MicropodError.message("The swap back did not restore \(journal.source.version)")
        }
    }

    func restore(_ file: RigFileReplacement, _ journal: RigUpgradeJournal) throws {
        let installed = URL(fileURLWithPath: file.installed)
        if let backup = file.backup {
            if Self.digest(file.installed) == file.backupSHA256 { return }
            guard Self.digest(backup) == file.backupSHA256 else {
                throw MicropodError.message("The saved copy of \(file.installed) changed; it was not restored")
            }
            try Self.install(URL(fileURLWithPath: backup), at: installed, mode: file.mode)
        } else {
            var info = stat()
            guard lstat(installed.path, &info) == 0 else { return }
            try RuntimeDurableFile.remove(installed)
        }
        try checkpoint(journal, "restored:" + installed.lastPathComponent)
    }

    /// Bootstraps every job that was loaded and relaunches the app if it was
    /// running, whatever fails along the way; returns what failed.
    func startAllBestEffort(_ journal: RigUpgradeJournal) async throws -> [String] {
        var problems: [String] = []
        for service in journal.services where service.wasLoaded {
            do {
                try await environment.launch.bootstrap(URL(fileURLWithPath: service.plist), label: service.label)
                try checkpoint(journal, "bootstrap:" + service.id)
            } catch let interruption as RigUpgradeInterruption {
                throw interruption
            } catch {
                problems.append("starting \(service.label): \(Self.describe(error))")
            }
        }
        if journal.appWasRunning {
            do {
                try await environment.app.launch(URL(fileURLWithPath: journal.appPath))
                try checkpoint(journal, "launched-app")
            } catch let interruption as RigUpgradeInterruption {
                throw interruption
            } catch {
                problems.append("launching the app: \(Self.describe(error))")
            }
        }
        return problems
    }

    func expectation(_ journal: RigUpgradeJournal, for identity: RigBundleIdentity) -> RigHealthExpectation {
        RigHealthExpectation(
            operation: journal.operation, version: identity.version, revision: identity.revision,
            appRunning: journal.appWasRunning, appControlSocket: journal.options.appControlSocket,
            sockets: journal.baseline.sockets, connectPort: journal.options.connectPort,
            connectRequired: journal.baseline.connectAnswered,
            connectVersionGated: journal.baseline.connectReplaced,
            retainedComponents: journal.baseline.retainedComponents)
    }
}
