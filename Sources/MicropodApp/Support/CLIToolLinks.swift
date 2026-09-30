import Foundation
import MicropodCore

/// Keeps `~/.local/bin/micropod` and `~/.local/bin/micropod-mcp` pointing
/// into this app bundle, so the CLI and the MCP server update whenever
/// Sparkle updates the app. On by default (Settings → Updates); a copy that
/// was installed there before is kept as `<name>.pre-app.bak`.
@MainActor
enum CLIToolLinks {
    static let enabledKey = "cli.manageLinks"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// This app, when it is an installed bundle carrying the tools — not a
    /// dev build, the DMG's own volume, or a translocated (quarantined,
    /// read-only, randomized) copy the links would soon dangle from.
    static var bundle: URL? {
        let url = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let path = url.path
        guard url.pathExtension == "app", !path.contains("/AppTranslocation/"), !path.hasPrefix("/Volumes/"),
            FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/micropod-cli").path)
        else { return nil }
        return url
    }

    private(set) static var lastError: String?

    /// Links the tools now (at launch, and when the setting is turned on).
    static func refresh() {
        guard isEnabled, NSClassFromString("XCTestCase") == nil, let bundle else { return }
        do {
            for change in try CLIInstall.linkTools(from: bundle) {
                switch change {
                case .created(let name), .repointed(let name):
                    AppLog.shared.log("cli", "linked ~/.local/bin/\(name) → \(bundle.path)")
                case .replaced(let name, let backup):
                    AppLog.shared.log(
                        "cli", "linked ~/.local/bin/\(name) → \(bundle.path) (previous copy kept as \(backup))")
                case .unchanged:
                    break
                }
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            AppLog.shared.error("cli", "linking the CLI tools failed: \(error.localizedDescription)")
        }
    }

    /// For status reports: which tools point into this app right now.
    static var linked: [String] {
        bundle.map { CLIInstall.linkedTools(to: $0) } ?? []
    }
}
