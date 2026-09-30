import Foundation
import MicropodCore

/// `micropod update` — the Micropod app's updater (Sparkle), over the
/// app-control socket: see what is available, check now, or restart into a
/// staged update. Dispatched before `Services` resolution: it needs the app,
/// not the container runtime.
enum UpdateCommands {
    static let helpText = """
        micropod update — the Micropod app's updates

        Usage:
          micropod update [status]   installed version, what's available or staged
          micropod update check      look for a newer version now (downloads it)
          micropod update apply      restart Micropod into the staged update

        The app checks hourly and downloads updates in the background; a staged
        update installs on quit, or by itself when you're away and nothing runs.
        """

    static func main(_ args: [String], json: Bool) async -> Int32 {
        let client = AppControlClient()
        guard client.isReachable else {
            FileHandle.standardError.write(Data("error: Micropod isn't running (no \(client.socketPath))\n".utf8))
            return ExitCode.failure
        }
        do {
            switch args.first ?? "status" {
            case "status":
                try report(await client.updateStatus(), json: json)
            case "check":
                _ = try await client.checkForUpdates()
                // The check runs in the app; wait for it to settle.
                var status = try await client.updateStatus()
                for _ in 0..<30 where status["state"] as? String == "checking" {
                    try await Task.sleep(for: .seconds(1))
                    status = try await client.updateStatus()
                }
                try report(status, json: json)
            case "apply":
                let status = try await client.updateStatus()
                guard status["readyToInstall"] as? Bool == true else {
                    try report(status, json: json)
                    FileHandle.standardError.write(
                        Data("error: no update is staged yet — run `micropod update check`\n".utf8))
                    return ExitCode.failure
                }
                _ = try await client.applyUpdate()
                print("restarting Micropod into \(status["downloadedVersion"] as? String ?? "the update")…")
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

    private static func report(_ status: [String: Any], json: Bool) throws {
        if json {
            let data = try JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        let current = status["currentVersion"] as? String ?? "?"
        switch status["state"] as? String {
        case "unavailable":
            print("Micropod \(current) — updates aren't available in development builds")
        case "readyToInstall":
            let staged = status["downloadedVersion"] as? String ?? status["availableVersion"] as? String ?? "?"
            print("Micropod \(current) — \(staged) is downloaded and ready: `micropod update apply` restarts into it")
        case "updateAvailable":
            print("Micropod \(current) — \(status["availableVersion"] as? String ?? "a newer version") is downloading")
        case "checking":
            print("Micropod \(current) — checking…")
        case "error":
            print("Micropod \(current) — the last check failed: \(status["error"] as? String ?? "unknown error")")
        default:
            let checked = (status["checkedAt"] as? String).map { " (checked \($0))" } ?? ""
            print("Micropod \(current) — up to date\(checked)")
        }
    }
}
