import Foundation
import MicropodBuildInfo
import MicropodCore
import MicropodRuntime

/// `micropod update` — keeping Micropod current: the app (Sparkle, over the
/// app-control socket) and this CLI. A CLI linked into the app bundle
/// updates with the app; a standalone one updates itself (`update cli`).
/// Dispatched before `Services` resolution: no container runtime needed.
enum UpdateCommands {
    static let helpText = """
        micropod update — keep Micropod and this CLI current

        Usage:
          micropod update [status]     the app's and this CLI's versions and updates
          micropod update check        look for a newer version now
          micropod update apply        download, install and verify the app update
          micropod update apply --disruptive [--drain-timeout S] [--health-timeout S]
                [--smoke-image IMAGE | --no-smoke] [--force-undrained] [--foreground]
                [--detach] [--channel C] [--feed URL] [--app PATH]
                                       rig upgrade: replace the app, CLI/MCP, docker-shim,
                                       shared-fs and Connect API at once; jobs may be
                                       interrupted, a failed health gate rolls back.
                                       Refused when Cuttlefish does not drain, unless
                                       --force-undrained
          micropod update apply --abandon
                                       drop a rig upgrade that has not stopped anything
          micropod update stage [--channel C] [--feed URL]
                                       download and verify the newest release now, so a
                                       later disruptive apply starts without network
          micropod update policy [guarded|disruptive]
                                       how this host takes releases (rigs: disruptive)
          micropod update auto [on|off|status] [--idle-after SECONDS]
          micropod update channel [stable|qualification]  choose the release channel
          micropod update recover      reconcile a retained update transaction
          micropod update recover --rig
                                       resume or roll back an interrupted rig upgrade,
                                       retry a rollback that gave up, release its drain
          micropod update verify [--automatic] [--image IMAGE]
                                       verify live workloads through an update
          micropod update cli [--force]  update a standalone CLI install from the
                                       release channel (signature-verified): the CLI, MCP
                                       and API binaries and the HVF payload, or none
          micropod update hvf [status]   show the running, current, staged and known-good
                                       HVF payloads
          micropod update hvf stage --from <app-or-dir> [--version V] [--revision R]
                                       stage an immutable HVF payload; nothing boots it
                                       until `apply` has verified it
          micropod update hvf apply [--force] [--drain-timeout S]
                                       boot the staged payload, probe it and make it current;
                                       returns to known-good on any failure. Deferred
                                       (exit 75) while containers run, unless --force
          micropod update hvf rollback [--force]
                                       return to the last known-good HVF payload; deferred
                                       (exit 75) while containers run, unless --force
          micropod update hvf prune [--keep N]
                                       remove old HVF payload versions (never current,
                                       staged, known-good or the running one)

        App installation requires coordinated workload admission; status explains
        when it is blocked. It links ~/.local/bin/micropod and micropod-mcp into
        its bundle, so they update with it. A CLI installed on its own says so
        after commands once a newer release is out.

        A disruptive rig upgrade asks Cuttlefish to drain (bounded; it goes ahead
        when the wait ends), runs as a launchd helper outside the app it replaces,
        and resumes from its journal after a crash or reboot. The dedicated
        runtime (setup helper, dedicated API, Apple engine) then follows the new
        app in its own coordinated update (`micropod runtime update`).
        """

    static func main(_ args: [String], json: Bool) async -> Int32 {
        do {
            switch args.first ?? "status" {
            case "status":
                try await status(json: json, check: false)
            case "check":
                try await status(json: json, check: true)
            case "apply":
                let request = try RigUpgradeCommands.parseApply(
                    Array(args.dropFirst()), policy: RigUpgradePolicy.read())
                guard request.disruptive else { return try await applyApp(json: json) }
                return try await RigUpgradeCommands.apply(request, json: json)
            case "stage":
                return try await RigUpgradeCommands.stage(Array(args.dropFirst()), json: json)
            case "policy":
                return try RigUpgradeCommands.policy(Array(args.dropFirst()), json: json)
            case "rig-helper":
                return await RigUpgradeCommands.helper(Array(args.dropFirst()))
            case "cli":
                return try await updateCLI(force: args.contains("--force"))
            case "hvf":
                return try await updateHVF(Array(args.dropFirst()), json: json)
            case "auto":
                let value = args.dropFirst().first ?? "status"
                guard ["on", "off", "status"].contains(value) else {
                    throw UsageError(message: "use update auto on, off or status")
                }
                let client = AppControlClient()
                var settings: [String: Any] = ["automaticInstallation": value == "on"]
                if value == "on" { settings["automaticChecks"] = true }
                if let index = args.firstIndex(of: "--idle-after") {
                    guard value != "status", index + 1 < args.count, let seconds = Double(args[index + 1]),
                        seconds.isFinite, (0...3600).contains(seconds)
                    else {
                        throw UsageError(message: "--idle-after requires 0 to 3600 seconds with on or off")
                    }
                    settings["idleSeconds"] = seconds
                }
                if value != "status" {
                    _ = try await client.call("update.configure", params: settings)
                }
                try await status(json: json, check: false)
            case "channel":
                if let value = args.dropFirst().first {
                    guard ["stable", "qualification"].contains(value) else {
                        throw UsageError(message: "choose stable or qualification")
                    }
                    _ = try await AppControlClient().call("update.configure", params: ["channel": value])
                }
                try await status(json: json, check: false)
            case "recover":
                if args.contains("--rig") {
                    return try await RigUpgradeCommands.recover(Array(args.dropFirst()), json: json)
                }
                _ = try await AppControlClient().call("update.recover")
                try await status(json: json, check: false)
            case "verify":
                return try await UpdateVerification.run(Array(args.dropFirst()), json: json)
            case "--refresh":
                await UpdateNotice.refresh()
            case "help", "--help", "-h":
                print(helpText)
            default:
                throw UsageError(message: "unknown update command '\(args[0])'")
            }
            return ExitCode.ok
        } catch let error as UsageError {
            FileHandle.standardError.write(Data("usage: \(error.message)\n".utf8))
            return ExitCode.usage
        } catch {
            FileHandle.standardError.write(Data("error: \(errorMessage(error))\n".utf8))
            return ExitCode.failure
        }
    }

    // MARK: Status

    private static func status(json: Bool, check: Bool) async throws {
        let client = AppControlClient()
        var app: [String: Any]?
        if client.isReachable {
            if check {
                _ = try await client.checkForUpdates()
                var report = try await client.updateStatus()
                for _ in 0..<30 where report["state"] as? String == "checking" {
                    try await Task.sleep(for: .seconds(1))
                    report = try await client.updateStatus()
                }
                app = report
            } else {
                app = try await client.updateStatus()
            }
        }
        let exe = CLIInstall.currentExecutable()
        let kind = CLIInstall.kind(of: exe)
        // The app's check already told us the newest version; ask the feed
        // only for a CLI that updates on its own.
        var latest: String?
        if case .standalone = kind {
            latest = (try? await SelfUpdate.latest())?.version.description
            if let latest { UpdateNotice.save(.init(checkedAt: Date(), latest: latest)) }
        }
        var rigLayout = RigUpgradeLayout()
        if case .appManaged(let bundle) = kind { rigLayout.appPath = bundle }
        let rig = UpdateStateResolver.rig(layout: rigLayout)
        let policy = RigUpgradePolicy.read(layout: rigLayout)
        let hvfStatus = HVFPayloadStore.status(layout: HVFMachineLayout())
        if json {
            var cli: [String: Any] = ["version": MicropodBuildInfo.version, "path": exe.path]
            switch kind {
            case .appManaged(let bundle):
                cli["install"] = "app"
                cli["app"] = bundle.path
            case .standalone: cli["install"] = "standalone"
            case .development: cli["install"] = "development"
            }
            if let latest { cli["latestVersion"] = latest }
            var out: [String: Any] = ["cli": cli, "policy": policy.rawValue]
            if let app { out["app"] = app }
            if let hvfObj = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(hvfStatus)) {
                out["hvf"] = hvfObj
            }
            if let rig {
                out["rig"] = [
                    "kind": "\(rig.kind)", "phase": rig.phase, "operation": rig.operationID,
                    "currentVersion": rig.currentVersion, "targetVersion": rig.targetVersion, "reason": rig.reason,
                ]
            }
            let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        if let app {
            print(appLine(app))
            if let automatic = app["automaticInstallation"] as? Bool {
                print(
                    "Automatic installation: \(automatic ? "on" : "off"); channel: \(app["channel"] as? String ?? "stable")"
                )
            }
        } else {
            print("Micropod app — not running")
        }
        print(cliLine(kind: kind, path: exe, latest: latest))
        if let hvfLine = hvfStatusLine(hvfStatus) { print(hvfLine) }
        if let line = RigUpgradeCommands.statusLine(rig, policy: policy) { print(line) }
    }

    static func appLine(_ status: [String: Any]) -> String {
        let line = appStateLine(status)
        guard let reason = status["restartBlockedReason"] as? String else { return line }
        return line + " — installation blocked: " + reason
    }

    private static func appStateLine(_ status: [String: Any]) -> String {
        let current = status["currentVersion"] as? String ?? "?"
        switch status["state"] as? String {
        case "unavailable":
            return "Micropod app \(current) — updates aren't available in development builds"
        case "readyToInstall":
            let staged = status["downloadedVersion"] as? String ?? status["availableVersion"] as? String ?? "?"
            if status["restartBlockedReason"] != nil { return "Micropod app \(current) — \(staged) is downloaded" }
            return
                "Micropod app \(current) — \(staged) is downloaded: `micropod update apply` requests guarded installation"
        case "updateAvailable":
            return
                "Micropod app \(current) — \(status["availableVersion"] as? String ?? "a newer version") is available"
        case "checking":
            return "Micropod app \(current) — checking…"
        case "error":
            if status["restartGuard"] as? String == "recoveryRequired" {
                return "Micropod app \(current) — update recovery required"
            }
            return "Micropod app \(current) — the last check failed: \(status["error"] as? String ?? "unknown error")"
        default:
            let checked = (status["checkedAt"] as? String).map { " (checked \($0))" } ?? ""
            return "Micropod app \(current) — up to date\(checked)"
        }
    }

    static func cliLine(kind: CLIInstall.Kind, path: URL, latest: String?) -> String {
        let version = MicropodBuildInfo.version
        switch kind {
        case .appManaged(let app):
            return "micropod CLI \(version) — part of \(app.path); updates with the app"
        case .development:
            return "micropod CLI \(version) — a development build (\(path.path)); rebuild to update"
        case .standalone:
            if let latest, let newer = ReleaseVersion(latest), let running = ReleaseVersion(version), running < newer {
                return "micropod CLI \(version) — \(latest) is out: `micropod update cli` installs it (\(path.path))"
            }
            return "micropod CLI \(version) — standalone at \(path.path)\(latest.map { ", latest is \($0)" } ?? "")"
        }
    }

    // MARK: Apply

    static func applyApp(json: Bool, quiet: Bool = false) async throws -> Int32 {
        let client = AppControlClient()
        guard client.isReachable else {
            FileHandle.standardError.write(Data("error: Micropod isn't running (no \(client.socketPath))\n".utf8))
            return ExitCode.failure
        }
        var report = try await client.updateStatus()
        if !["updateAvailable", "readyToInstall"].contains(report["state"] as? String ?? "") {
            _ = try await client.checkForUpdates()
            for _ in 0..<60 {
                try await Task.sleep(for: .seconds(1))
                report = try await client.updateStatus()
                if report["state"] as? String != "checking" { break }
            }
        }
        if report["state"] as? String == "upToDate" {
            if !quiet { try await status(json: json, check: false) }
            return ExitCode.ok
        }
        guard let target = report["downloadedVersion"] as? String ?? report["availableVersion"] as? String else {
            throw MicropodError.message(appLine(report))
        }
        for _ in 0..<10 where report["canCheckForUpdates"] as? Bool == false {
            try await Task.sleep(for: .milliseconds(200))
            report = try await client.updateStatus()
        }
        _ = try await client.applyUpdate()
        if !json && !quiet { print("Installing Micropod \(target). Workload services remain running…") }
        // The CLI process and durable operation survive the GUI replacement.
        // Lost replies are observations, never permission to replay an apply.
        for _ in 0..<600 {
            try await Task.sleep(for: .seconds(1))
            if let receipt = try UpdateContinuityStore.standard.read(), receipt.isTerminal {
                guard receipt.phase == .succeeded, receipt.targetVersion == target else {
                    throw MicropodError.message(receipt.detail ?? "The update did not install; its receipt is retained")
                }
                guard let current = try? await client.updateStatus(), current["currentVersion"] as? String == target,
                    current["desktopAdmission"] as? String == "open", current["restartGuard"] as? String == "idle"
                else { continue }
                if !quiet { try await status(json: json, check: false) }
                if !json && !quiet { print("Verified the signed replacement and unchanged workload owners.") }
                return ExitCode.ok
            }
        }
        throw MicropodError.message(
            "Update completion is unconfirmed. Its receipt and workload services are retained; inspect update status before retrying."
        )
    }

    // MARK: CLI self-update

    private static func updateCLI(force: Bool) async throws -> Int32 {
        let exe = CLIInstall.currentExecutable()
        switch CLIInstall.kind(of: exe) {
        case .appManaged(let app):
            print("This micropod is part of \(app.path) and updates with it.")
            if AppControlClient().isReachable {
                print(appLine(try await AppControlClient().updateStatus()))
            }
            return ExitCode.ok
        case .development:
            throw MicropodError.message("\(exe.path) is a development build — rebuild it instead")
        case .standalone:
            break
        }
        let release = try await SelfUpdate.latest()
        UpdateNotice.save(.init(checkedAt: Date(), latest: release.version.description))
        if let running = ReleaseVersion(MicropodBuildInfo.version), release.version <= running, !force {
            print("micropod \(MicropodBuildInfo.version) is the latest (\(exe.path))")
            return ExitCode.ok
        }
        try await SelfUpdate.install(release, cli: exe) { FileHandle.standardError.write(Data("\($0)\n".utf8)) }
        let files = SelfUpdate.installedFiles(cli: exe).map(\.path.lastPathComponent).joined(separator: " + ")
        print("updated \(files) \(MicropodBuildInfo.version) → \(release.version) (previous kept as .bak)")
        return ExitCode.ok
    }

    // MARK: Rootless HVF payload lifecycle

    /// `update hvf apply` and `rollback` when nothing was stopped because
    /// workloads run: EX_TEMPFAIL, so a script can retry once idle.
    static let deferredExitCode: Int32 = 75

    static func hvfExitCode(_ action: HVFActivationResult.Action) -> Int32 {
        switch action {
        case .noop, .activated: return ExitCode.ok
        case .deferred: return deferredExitCode
        case .rolledBack, .failedRollback, .failed: return ExitCode.failure
        }
    }

    static func hvfStatusLine(_ status: HVFPayloadStatus) -> String? {
        guard
            status.current != nil || status.staged != nil || status.runningVersion != nil
                || !status.availableVersions.isEmpty
        else {
            return nil
        }
        let active = status.current?.version ?? "flat"
        let running = status.runningVersion ?? (status.runningPath != nil ? "flat" : "stopped")
        if status.updatePending {
            let target = status.staged?.version ?? active
            return "HVF runtime — running \(running), \(target) staged (update pending: `micropod update hvf apply`)"
        }
        return "HVF runtime — \(active) (\(running == "stopped" ? "stopped" : "running \(running)"))"
    }

    static func printHVFResult(_ result: HVFActivationResult, json: Bool) throws {
        if json {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try enc.encode(result), as: UTF8.self))
        } else {
            print("\(result.action.rawValue): \(result.detail)")
        }
    }

    private static func updateHVF(_ args: [String], json: Bool) async throws -> Int32 {
        let layout = HVFMachineLayout()
        let sub = args.first ?? "status"
        let rest = Array(args.dropFirst())
        switch sub {
        case "status":
            let st = HVFPayloadStore.status(layout: layout)
            if json {
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                enc.dateEncodingStrategy = .iso8601
                print(String(decoding: try enc.encode(st), as: UTF8.self))
                return ExitCode.ok
            }
            func describe(_ manifest: HVFPayloadManifest?, _ path: String?) -> String? {
                guard let manifest else { return nil }
                return "\(manifest.version) (\(manifest.revision))"
                    + (path.map { " — \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "")
            }
            print("HVF root:         \(layout.root.path)")
            print("Current (boots):  \(describe(st.current, st.currentPath) ?? "none (legacy flat layout)")")
            print("Staged:           \(describe(st.staged, st.stagedPath) ?? "none")")
            print("Known-good:       \(describe(st.knownGood, st.knownGoodPath) ?? "none")")
            print("Previous:         \(describe(st.previous, st.previousPath) ?? "none")")
            print(
                "Running VM:       \(st.runningVersion ?? (st.runningPath != nil ? "running (legacy flat)" : "stopped"))"
            )
            print("Update pending:   \(st.updatePending ? "yes — run `micropod update hvf apply`" : "no")")
            if !st.availableVersions.isEmpty {
                print("Versions on disk: \(st.availableVersions.joined(separator: ", "))")
            }
            return ExitCode.ok

        case "stage":
            let parsed = try parseArgs(
                rest, boolFlags: ["--no-verify"], valueFlags: ["--from", "--version", "--revision"],
                commandName: "update hvf stage")
            guard let fromPath = parsed.value("--from") ?? parsed.positionals.first else {
                throw UsageError(message: "update hvf stage --from <Micropod.app-or-dir> [--version V] [--revision R]")
            }
            let version = parsed.value("--version") ?? MicropodBuildInfo.version
            let revision = parsed.value("--revision") ?? MicropodBuildInfo.sourceRevision
            let manifest = try HVFPayloadStore.stage(
                from: .directory(URL(fileURLWithPath: (fromPath as NSString).expandingTildeInPath)),
                version: version,
                revision: revision,
                layout: layout,
                verifySignature: !parsed.has("--no-verify"),
                progress: { if !json { FileHandle.standardError.write(Data("\($0)\n".utf8)) } })
            if json {
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                enc.dateEncodingStrategy = .iso8601
                print(String(decoding: try enc.encode(manifest), as: UTF8.self))
            } else {
                print(
                    "staged HVF payload \(manifest.version) (\(manifest.revision)); "
                        + "`micropod update hvf apply` boots, verifies and activates it")
            }
            return ExitCode.ok

        case "apply":
            let parsed = try parseArgs(
                rest, boolFlags: ["--force"], valueFlags: ["--drain-timeout"], commandName: "update hvf apply")
            let drainSeconds = try parsed.value("--drain-timeout").map { raw -> Int in
                guard let seconds = Int(raw), seconds >= 0 else {
                    throw UsageError(message: "--drain-timeout wants whole seconds, got '\(raw)'")
                }
                return seconds
            }
            let result = try await HVFPayloadStore.activate(
                layout: layout,
                force: parsed.has("--force"),
                drainTimeout: .seconds(drainSeconds ?? 0),
                progress: { if !json { FileHandle.standardError.write(Data("\($0)\n".utf8)) } })
            try printHVFResult(result, json: json)
            return hvfExitCode(result.action)

        case "rollback":
            let parsed = try parseArgs(rest, boolFlags: ["--force"], valueFlags: [], commandName: "update hvf rollback")
            let result = try await HVFPayloadStore.rollback(
                layout: layout,
                force: parsed.has("--force"),
                progress: { if !json { FileHandle.standardError.write(Data("\($0)\n".utf8)) } })
            try printHVFResult(result, json: json)
            return hvfExitCode(result.action)

        case "prune":
            let parsed = try parseArgs(rest, boolFlags: [], valueFlags: ["--keep"], commandName: "update hvf prune")
            let keep = parsed.value("--keep").flatMap(Int.init) ?? 2
            let removed = try HVFPayloadStore.pruneVersions(layout: layout, keep: keep)
            if json {
                let data = try JSONSerialization.data(withJSONObject: ["removed": removed], options: [.prettyPrinted])
                print(String(decoding: data, as: UTF8.self))
            } else if removed.isEmpty {
                print("no old HVF payload versions to prune")
            } else {
                print("pruned \(removed.count) HVF payload version(s): \(removed.joined(separator: ", "))")
            }
            return ExitCode.ok

        default:
            throw UsageError(
                message: "unknown update hvf command '\(sub)' (want status, stage, apply, rollback, prune)")
        }
    }
}
