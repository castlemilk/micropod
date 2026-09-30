import Foundation
import MicropodBuildInfo
import MicropodCore

/// `micropod update` — keeping Micropod current: the app (Sparkle, over the
/// app-control socket) and this CLI. A CLI linked into the app bundle
/// updates with the app; a standalone one updates itself (`update cli`).
/// Dispatched before `Services` resolution: no container runtime needed.
enum UpdateCommands {
    static let helpText = """
        micropod update — keep Micropod and this CLI current

        Usage:
          micropod update [status]     the app's and this CLI's versions and updates
          micropod update check        look for a newer version now (the app downloads it)
          micropod update apply        restart the app into its downloaded update
          micropod update cli [--force]  update a standalone CLI install from the
                                       release channel (signature-verified)

        The app checks hourly and installs downloaded updates when you're away
        and nothing runs. It links ~/.local/bin/micropod and micropod-mcp into
        its bundle, so they update with it. A CLI installed on its own says so
        after commands once a newer release is out.
        """

    static func main(_ args: [String], json: Bool) async -> Int32 {
        do {
            switch args.first ?? "status" {
            case "status":
                try await status(json: json, check: false)
            case "check":
                try await status(json: json, check: true)
            case "apply":
                return try await applyApp(json: json)
            case "cli":
                return try await updateCLI(force: args.contains("--force"))
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
            var out: [String: Any] = ["cli": cli]
            if let app { out["app"] = app }
            let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        if let app {
            print(appLine(app))
        } else {
            print("Micropod app — not running")
        }
        print(cliLine(kind: kind, path: exe, latest: latest))
    }

    static func appLine(_ status: [String: Any]) -> String {
        let current = status["currentVersion"] as? String ?? "?"
        switch status["state"] as? String {
        case "unavailable":
            return "Micropod app \(current) — updates aren't available in development builds"
        case "readyToInstall":
            let staged = status["downloadedVersion"] as? String ?? status["availableVersion"] as? String ?? "?"
            return "Micropod app \(current) — \(staged) is downloaded: `micropod update apply` restarts into it"
        case "updateAvailable":
            return
                "Micropod app \(current) — \(status["availableVersion"] as? String ?? "a newer version") is downloading"
        case "checking":
            return "Micropod app \(current) — checking…"
        case "error":
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

    private static func applyApp(json: Bool) async throws -> Int32 {
        let client = AppControlClient()
        guard client.isReachable else {
            FileHandle.standardError.write(Data("error: Micropod isn't running (no \(client.socketPath))\n".utf8))
            return ExitCode.failure
        }
        let status = try await client.updateStatus()
        guard status["readyToInstall"] as? Bool == true else {
            print(appLine(status))
            FileHandle.standardError.write(Data("error: no update is staged yet — run `micropod update check`\n".utf8))
            return ExitCode.failure
        }
        _ = try await client.applyUpdate()
        print("restarting Micropod into \(status["downloadedVersion"] as? String ?? "the update")…")
        return ExitCode.ok
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
}
