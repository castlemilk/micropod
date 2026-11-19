import AppKit
import Darwin
import Foundation
import MicropodCore

/// `micropod runtime update`: brings the dedicated runtime (setup app, root
/// helper, dedicated API, Apple build) to the release the installed desktop
/// app carries. The root helper verifies and installs it; this command only
/// asks and follows. See docs/runtime-component-update.md.
enum RuntimeUpdateCommands {
    static let usage = """
        usage: micropod runtime update [--rollback] [--detach] [--json]
               micropod runtime update --bootstrap      one-time: re-register a helper too old to update itself
        """

    static func run(_ args: [String]) async throws {
        let parsed = try parseArgs(
            args, boolFlags: ["--rollback", "--detach", "--bootstrap"], valueFlags: [], commandName: "runtime update")
        guard !parsed.has("--help") else {
            print(usage)
            return
        }
        guard parsed.positionals.isEmpty else { throw UsageError(message: usage) }
        if parsed.has("--bootstrap") {
            try await bootstrap()
            return
        }
        let client = RuntimeComponentUpdateClient(log: { line in
            if !MicropodCLI.jsonOutput { print(line) }
        })
        let operation: UUID
        do {
            operation = try await client.request(rollback: parsed.has("--rollback"))
        } catch let legacy as RuntimeComponentUpdateClient.LegacyHelper {
            throw MicropodError.message(legacy.localizedDescription)
        }
        if !MicropodCLI.jsonOutput {
            print("Runtime component \(parsed.has("--rollback") ? "rollback" : "update") \(operation.uuidString)")
        }
        if parsed.has("--detach") { return }
        let summary = try await client.follow(operation)
        if MicropodCLI.jsonOutput {
            print(String(decoding: try JSONEncoder().encode(summary), as: UTF8.self))
        } else {
            print(summary.reason ?? summary.phase)
        }
        guard summary.phase == (summary.rollback ? "rolledBack" : "completed") else {
            throw MicropodError.message("Runtime component update ended \(summary.phase)")
        }
    }

    /// Chained by a rig upgrade once the new app is verified: asks the root
    /// helper to follow the app. Never throws; a helper too old for this is
    /// reported, not fatal, because the app upgrade itself completed.
    static func chain(follow: Bool, log: @escaping @Sendable (String) -> Void) async -> Bool {
        let client = RuntimeComponentUpdateClient(log: log)
        do {
            let operation = try await client.request(rollback: false)
            log("runtime component update \(operation.uuidString) requested")
            guard follow else { return true }
            let summary = try await client.follow(operation)
            log("runtime component update \(summary.phase): \(summary.reason ?? "")")
            return summary.phase == "completed"
        } catch let legacy as RuntimeComponentUpdateClient.LegacyHelper {
            // The app upgrade itself completed; the runtime needs a one-time
            // bootstrap, which is not a failure of this command.
            log("runtime components were not updated: \(legacy.localizedDescription)")
            return true
        } catch {
            log("runtime components were not updated: \(errorMessage(error))")
            return false
        }
    }

    // MARK: Bootstrap

    /// The old helper must hold nothing while it is replaced: the checks its
    /// own "Pause Helper for Update" makes. Checked again immediately before
    /// re-registration, by this command and by Runtime Setup itself.
    static func requireIdle(_ status: IsolatedRuntimeStatus) throws {
        guard status.isTerminal, status.phase != "recoveryRequired", status.rigAttempted != true,
            status.runtimeRigAttempted != true, status.localGeneration == nil || status.actionVerified == true,
            try status.workerBirth?.hasExited() != false
        else {
            throw MicropodError.message(
                "Finish or verify runtime maintenance first (`micropod runtime recover`); nothing was replaced")
        }
    }

    /// A helper built before component updates cannot replace itself, and
    /// this release also changes the daemon's definition (it adds a
    /// SpawnConstraint), which only a new registration applies. So: put the
    /// release's setup app in place as the user (Micropod's team may update
    /// its own app), then have Runtime Setup unregister and register the
    /// daemon. macOS asks an administrator to approve it once, in Login Items.
    /// The new helper then re-seats itself as a sealed root-owned copy
    /// verified against the signed manifest before it installs anything.
    static func bootstrap() async throws {
        let status = try await IsolatedRuntimeClient().call(.init(action: .status))
        if status.componentProtocol != nil {
            print("The runtime helper already updates itself: run `micropod runtime update`.")
            return
        }
        try requireIdle(status)
        let installed = RuntimeSetupInstallation.installedURL
        let desktop = URL(fileURLWithPath: "/Applications/Micropod.app")
        let source = desktop.appendingPathComponent("Contents/Helpers/Micropod Runtime Setup.app")
        let resources = desktop.appendingPathComponent("Contents/Resources")
        let manifest = try RuntimeComponentManifest.verified(
            RuntimeNonblockingFile.read(
                resources.appendingPathComponent(RuntimeComponentManifest.fileName),
                limit: RuntimeComponentManifest.maximumBytes),
            signature: RuntimeNonblockingFile.read(
                resources.appendingPathComponent(RuntimeComponentManifest.signatureFileName), limit: 1024))
        let staging = installed.deletingLastPathComponent().appendingPathComponent(
            ".micropod-runtime-setup-" + UUID().uuidString + ".app")
        defer { try? FileManager.default.removeItem(at: staging) }
        if RuntimeCodeIdentity.cdhash(installed) != manifest.setup.cdhash {
            guard access(installed.path, W_OK) == 0, access(installed.deletingLastPathComponent().path, W_OK) == 0
            else {
                throw MicropodError.message(
                    "\(installed.path) is not this account's to replace; it was installed by the root helper, which "
                        + "can update itself: run `micropod runtime update`")
            }
            _ = try SelfUpdate.run(
                "/usr/bin/ditto", ["--noacl", "--noextattr", "--norsrc", "--noqtn", source.path, staging.path])
            try RuntimeCodeIdentity.verifyBundle(
                staging, identifier: IsolatedRuntimePolicy.setupIdentifier, notarized: true)
            guard RuntimeCodeIdentity.cdhash(staging) == manifest.setup.cdhash else {
                throw MicropodError.message(
                    "The copied setup app does not match its signed manifest; nothing was replaced")
            }
            let previous = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                ".micropod/runtime-setup/previous-\(Int(Date().timeIntervalSince1970)).app")
            try FileManager.default.createDirectory(
                at: previous.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            // Checked again right before the old helper's bundle changes.
            try requireIdle(try await IsolatedRuntimeClient().call(.init(action: .status)))
            guard renamex_np(staging.path, installed.path, UInt32(RENAME_SWAP)) == 0 else {
                throw MicropodError.message("Could not exchange the setup app (\(errno)); nothing was replaced")
            }
            // The displaced bundle is at `staging` now: keep its exact bytes.
            if rename(staging.path, previous.path) != 0 {
                print("warning: the previous setup app was left at \(staging.path)")
            }
            print(
                "Micropod Runtime Setup \(manifest.version) is in place; the previous one is kept at \(previous.path).")
        }
        print("Runtime Setup now re-registers the helper. Approve it in System Settings → General → Login Items")
        print("& Extensions if macOS asks; that is the one administrator approval.")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--reregister"]
        _ = try await NSWorkspace.shared.openApplication(at: installed, configuration: configuration)
        let deadline = ContinuousClock.now.advanced(by: .seconds(600))
        while ContinuousClock.now < deadline {
            if let current = try? await IsolatedRuntimeClient().call(.init(action: .status)),
                current.componentProtocol != nil
            {
                print("The runtime helper \(manifest.version) is running and re-seats itself as a root-owned copy.")
                print("Run `micropod runtime update` to restart the dedicated runtime onto it.")
                return
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw MicropodError.message(
            "The new runtime helper has not started; approve Micropod Runtime Setup in Login Items, then run "
                + "`micropod runtime update --bootstrap` again")
    }
}
