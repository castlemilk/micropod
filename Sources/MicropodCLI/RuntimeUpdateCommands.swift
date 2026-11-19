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
               micropod runtime update --bootstrap      one-time: a helper too old to update itself
        """
    static let kickstart = "sudo launchctl kickstart -k system/\(IsolatedRuntimePolicy.serviceName)"

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
        } catch {
            log("runtime components were not updated: \(errorMessage(error))")
            return false
        }
    }

    // MARK: Bootstrap

    /// A helper built before component updates cannot replace itself. This
    /// puts the release's setup app in place as the user (Micropod's team
    /// may update its own app) and leaves one administrator command: restart
    /// the approved daemon, which launchd then runs from the new bundle. The
    /// launchd definition is unchanged, so the existing approval stands.
    static func bootstrap() async throws {
        let status = try await IsolatedRuntimeClient().call(.init(action: .status))
        if status.componentProtocol != nil {
            print("The runtime helper already updates itself: run `micropod runtime update`.")
            return
        }
        // The old helper keeps running from the replaced bundle until it is
        // restarted, so it must hold nothing: the checks its own "Pause
        // Helper for Update" makes.
        guard status.isTerminal, status.phase != "recoveryRequired", status.rigAttempted != true,
            status.runtimeRigAttempted != true, status.localGeneration == nil || status.actionVerified == true,
            try status.workerBirth?.hasExited() != false
        else {
            throw MicropodError.message(
                "Finish or verify runtime maintenance first (`micropod runtime recover`); nothing was replaced")
        }
        let installed = RuntimeSetupInstallation.installedURL
        let desktop = URL(fileURLWithPath: "/Applications/Micropod.app")
        let source = desktop.appendingPathComponent("Contents/Helpers/Micropod Runtime Setup.app")
        let resources = desktop.appendingPathComponent("Contents/Resources")
        let manifest = try RuntimeComponentManifest.verified(
            Data(contentsOf: resources.appendingPathComponent(RuntimeComponentManifest.fileName)),
            signature: Data(contentsOf: resources.appendingPathComponent(RuntimeComponentManifest.signatureFileName)))
        try RuntimeCodeIdentity.verifyBundle(source, identifier: IsolatedRuntimePolicy.setupIdentifier, notarized: true)
        guard RuntimeCodeIdentity.cdhash(source) == manifest.setup.cdhash else {
            throw MicropodError.message("The setup app inside Micropod.app does not match its signed manifest")
        }
        if RuntimeCodeIdentity.cdhash(installed) == manifest.setup.cdhash {
            print("Micropod Runtime Setup \(manifest.version) is already in place.")
            print("If the helper still reports itself as older, run once:\n  \(kickstart)")
            print("then: micropod runtime update")
            return
        }
        let daemon = "Contents/Library/LaunchDaemons/\(IsolatedRuntimePolicy.serviceName).plist"
        guard let old = NSDictionary(contentsOf: installed.appendingPathComponent(daemon)),
            let new = NSDictionary(contentsOf: source.appendingPathComponent(daemon)), old == new
        else {
            throw MicropodError.message(
                "This release changes the helper's launchd definition: open Micropod Runtime Setup and approve it")
        }
        guard access(installed.path, W_OK) == 0, access(installed.deletingLastPathComponent().path, W_OK) == 0 else {
            throw MicropodError.message(
                "\(installed.path) is not this account's to replace; it was installed by the root helper, which "
                    + "can update itself: run `micropod runtime update`")
        }
        let staging = installed.deletingLastPathComponent().appendingPathComponent(
            ".micropod-runtime-setup-" + UUID().uuidString + ".app")
        defer { try? FileManager.default.removeItem(at: staging) }
        _ = try SelfUpdate.run("/usr/bin/ditto", ["--noqtn", source.path, staging.path])
        try RuntimeCodeIdentity.verifyBundle(
            staging, identifier: IsolatedRuntimePolicy.setupIdentifier, notarized: true)
        guard RuntimeCodeIdentity.cdhash(staging) == manifest.setup.cdhash else {
            throw MicropodError.message("The copied setup app changed; nothing was replaced")
        }
        let previous = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            ".micropod/runtime-setup/previous-\(Int(Date().timeIntervalSince1970)).app")
        try FileManager.default.createDirectory(
            at: previous.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard renamex_np(staging.path, installed.path, UInt32(RENAME_SWAP)) == 0 else {
            throw MicropodError.message("Could not exchange the setup app (\(errno)); nothing was replaced")
        }
        // The displaced bundle is at `staging` now: keep its exact bytes.
        if rename(staging.path, previous.path) != 0 {
            print("warning: the previous setup app was left at \(staging.path)")
        }
        print("Micropod Runtime Setup \(manifest.version) is in place; the previous one is kept at \(previous.path).")
        print("The running helper is still the old one. One administrator command restarts it from the new bundle:")
        print("  \(kickstart)")
        print("Then `micropod runtime update` finishes unattended: it drains the rig, restarts the dedicated")
        print("runtime onto the new API and verifies it.")
    }
}
