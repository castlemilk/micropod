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
               micropod runtime update --bootstrap      how to install the root-owned runtime authority (once)
               sudo micropod runtime update --force [--rollback] [--detach] [--json]
                                                        go ahead although the helper reports itself unprotected
        """

    static func run(_ args: [String]) async throws {
        let parsed = try parseArgs(
            args, boolFlags: ["--rollback", "--detach", "--bootstrap", "--force"], valueFlags: [],
            commandName: "runtime update")
        guard !parsed.has("--help") else {
            print(usage)
            return
        }
        guard parsed.positionals.isEmpty, !(parsed.has("--bootstrap") && parsed.has("--force")) else {
            throw UsageError(message: usage)
        }
        if parsed.has("--bootstrap") {
            try await bootstrap()
            return
        }
        let force = parsed.has("--force")
        if let refusal = privilegeProblem(force: force, euid: geteuid()) { throw MicropodError.message(refusal) }
        if force {
            // A helper that predates --force drops every request from root
            // unanswered, so ask it first and say why it is silent.
            do { _ = try await IsolatedRuntimeClient().call(.init(action: .status)) } catch {
                throw MicropodError.message(
                    "The runtime helper did not answer root (\(errorMessage(error))). A helper that predates "
                        + "`--force` ignores root; `sudo micropod runtime install-authority` repairs an unprotected "
                        + "helper instead")
            }
        }
        let client = RuntimeComponentUpdateClient(log: { line in
            if !MicropodCLI.jsonOutput { print(line) }
        })
        let operation: UUID
        do {
            operation = try await client.request(rollback: parsed.has("--rollback"), force: force)
        } catch let legacy as RuntimeComponentUpdateClient.LegacyHelper {
            throw MicropodError.message(legacy.localizedDescription)
        }
        if !MicropodCLI.jsonOutput {
            print("Runtime component \(parsed.has("--rollback") ? "rollback" : "update") \(operation.uuidString)")
            if force {
                let summary = try? await IsolatedRuntimeClient().call(.init(action: .status)).componentUpdate
                if let line = forcedLine(summary?.operation == operation ? summary : nil) { print(line) }
            }
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

    /// Why this account may not send this request, or nil. The helper decides
    /// from the peer's audit token whatever this says; this only explains it
    /// before anything is sent.
    static func privilegeProblem(force: Bool, euid: uid_t) -> String? {
        if force, euid != 0 {
            return "`--force` needs root: run `sudo micropod runtime update --force`. Nothing was sent"
        }
        if !force, euid == 0 {
            return "Run `micropod runtime update` as the runtime's owner, without sudo. As root only `--force` "
                + "is accepted, to override a failed protection check"
        }
        return nil
    }

    /// The one line a forced request prints: the check it overrode, or that
    /// it overrode nothing.
    static func forcedLine(_ summary: RuntimeComponentUpdateSummary?) -> String? {
        guard let summary else { return nil }
        guard summary.forced == true else {
            return "--force overrode nothing: the helper is protected, so this is an ordinary update"
        }
        return "FORCED over \"\(summary.forcedOver ?? "unprotected: unknown")\": the protection check was "
            + "overridden (signatures, digests and the security floor still apply); this host's release-gate "
            + "evidence is void"
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

    /// Runtime helpers before the root-owned authority ran from the setup
    /// app in /Applications, which any admin-group process can replace. Moving
    /// to the authority needs an administrator once; this command only says how.
    static func bootstrap() async throws {
        let status = try? await IsolatedRuntimeClient().call(.init(action: .status))
        if let protection = status?.componentProtection, protection == "protected" {
            print("The root-owned runtime authority is installed and protected: run `micropod runtime update`.")
            return
        }
        if let protection = status?.componentProtection {
            print("The runtime helper reports: \(protection).")
        }
        print(RuntimeAuthorityCommands.instructions)
        print(
            """

            install-authority waits for the current helper to be idle, retires the legacy helper job itself
            (bootout, disable, an immutable bundle), finishes only once the authority serves, and can be run
            again after any interruption. Afterwards, as yourself:
              micropod runtime update        restart the dedicated runtime onto the new helper and API
            """)
    }
}
