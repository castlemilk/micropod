import Darwin
import Foundation

/// Where the `micropod` CLI and `micropod-mcp` live, and how they update.
///
/// The app bundle carries both (Contents/MacOS/micropod-cli — not
/// `micropod`, which a case-insensitive volume would collide with the app's
/// own `Micropod` — and Contents/MacOS/MicropodMCP), signed and notarized
/// with the app. The app links `~/.local/bin/micropod` and
/// `~/.local/bin/micropod-mcp` to them at launch, so Sparkle updating the
/// app updates the CLI and the MCP server too. A copy installed on its own
/// (a tarball, a headless machine) updates itself: `micropod update cli`.
public enum CLIInstall {
    /// Link name in ~/.local/bin → binary in the app bundle's Contents/MacOS.
    public static let tools: [(link: String, bundled: String)] = [
        ("micropod", "micropod-cli"), ("micropod-mcp", "MicropodMCP"),
    ]

    public static var binDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin")
    }

    public enum Kind: Equatable, Sendable {
        /// Inside an app bundle: updates with the app.
        case appManaged(app: URL)
        /// A file of its own: `micropod update cli` replaces it.
        case standalone
        /// Under a SwiftPM `.build`: rebuild instead.
        case development
    }

    /// How the binary at `path` (symlinks resolved) is installed.
    public static func kind(of path: URL) -> Kind {
        let resolved = path.resolvingSymlinksInPath().standardizedFileURL
        let components = resolved.pathComponents
        if let index = components.lastIndex(where: { $0.hasSuffix(".app") }), index + 2 < components.count,
            components[index + 1] == "Contents", components[index + 2] == "MacOS"
        {
            return .appManaged(app: URL(fileURLWithPath: NSString.path(withComponents: Array(components[...index]))))
        }
        if components.contains(".build") { return .development }
        return .standalone
    }

    /// The running executable's real path (symlinks resolved). Not
    /// `Bundle.main`: inside an app bundle that names the app's executable.
    public static func currentExecutable() -> URL {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
        if length > 0 {
            return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
        }
        return URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    }

    public enum LinkChange: Equatable, Sendable {
        case unchanged(String)
        case created(String)
        /// Pointed elsewhere (another copy of the app) before.
        case repointed(String)
        /// A standalone copy was there; it was kept as `backup`.
        case replaced(String, backup: String)
    }

    /// Points `directory/<link>` at `app`'s bundled binaries. A regular file
    /// in the way is a standalone install from before: it is kept as
    /// `<link>.pre-app.bak` (once) and replaced. Bundled binaries the app
    /// lacks are skipped.
    @discardableResult
    public static func linkTools(from app: URL, into directory: URL = binDirectory) throws -> [LinkChange] {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var changes: [LinkChange] = []
        for (name, bundled) in tools {
            let target = app.appendingPathComponent("Contents/MacOS/\(bundled)")
            guard fm.isExecutableFile(atPath: target.path) else { continue }
            let link = directory.appendingPathComponent(name)
            let current = try? fm.destinationOfSymbolicLink(atPath: link.path)
            if current == target.path {
                changes.append(.unchanged(name))
                continue
            }
            let exists = current != nil || fm.fileExists(atPath: link.path)
            var backup: String?
            if current == nil, exists {
                // A regular file (a copy from install.sh, a tarball, …).
                let kept = directory.appendingPathComponent("\(name).pre-app.bak")
                if !fm.fileExists(atPath: kept.path) {
                    try fm.copyItem(at: link, to: kept)
                    backup = kept.lastPathComponent
                }
            }
            // Swap atomically: a shell mid-`micropod …` never sees it missing.
            let staging = directory.appendingPathComponent(".\(name).link-\(getpid())")
            try? fm.removeItem(at: staging)
            try fm.createSymbolicLink(atPath: staging.path, withDestinationPath: target.path)
            guard rename(staging.path, link.path) == 0 else {
                let reason = String(cString: strerror(errno))
                try? fm.removeItem(at: staging)
                throw MicropodError.message("linking \(link.path): \(reason)")
            }
            if let backup {
                changes.append(.replaced(name, backup: backup))
            } else {
                changes.append(current == nil && !exists ? .created(name) : .repointed(name))
            }
        }
        return changes
    }

    /// The links in `directory` that point into `app` right now.
    public static func linkedTools(to app: URL, in directory: URL = binDirectory) -> [String] {
        tools.compactMap { name, bundled in
            let target = app.appendingPathComponent("Contents/MacOS/\(bundled)").path
            return
                (try? FileManager.default.destinationOfSymbolicLink(atPath: directory.appendingPathComponent(name).path))
                == target ? name : nil
        }
    }
}

/// Dotted release versions: "0.11.2" < "0.11.10"; a suffix ("0.12.0-rc1",
/// "0.11.2-stamptest") sorts before the release it precedes.
public struct ReleaseVersion: Comparable, Sendable, CustomStringConvertible {
    public let numbers: [Int]
    public let suffix: String
    public let description: String

    public init?(_ text: String) {
        let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let core = trimmed.prefix { $0 != "-" && $0 != "+" }
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.count <= 4, numbers.allSatisfy({ $0 != nil }) else { return nil }
        self.numbers = numbers.compactMap { $0 }
        suffix = String(trimmed.dropFirst(core.count))
        description = trimmed
    }

    public static func < (a: ReleaseVersion, b: ReleaseVersion) -> Bool {
        for i in 0..<max(a.numbers.count, b.numbers.count) {
            let x = i < a.numbers.count ? a.numbers[i] : 0
            let y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x < y }
        }
        // Same numbers: a pre-release (suffixed) comes first.
        if a.suffix.isEmpty != b.suffix.isEmpty { return !a.suffix.isEmpty }
        return a.suffix < b.suffix
    }

    public static func == (a: ReleaseVersion, b: ReleaseVersion) -> Bool { !(a < b) && !(b < a) }
}
