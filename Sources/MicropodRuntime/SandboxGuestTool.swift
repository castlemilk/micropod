import Crypto
import Foundation

/// `micropod-guest` (guest/, a static linux/arm64 binary): the sandbox
/// VMs' helper for file operations, watches and the idle main process. It
/// needs nothing from the image, so distroless images get the whole
/// SandboxService API, and watches always use inotify.
///
/// The engine shares a directory holding just the helper read-only into
/// each sandbox at ``guestDirectory``. Found next to the running executable,
/// in the app bundle's Resources, in /Applications/Micropod.app, via
/// `MICROPOD_GUEST_TOOL`, or as an earlier install, and copied to
/// `~/.micropod/sandbox/guest/<digest>/`. With none (a dev build without
/// Go), the engine falls back to the image's shell tools.
public enum SandboxGuestTool {
    public static let guestDirectory = "/.micropod"
    public static let guestPath = guestDirectory + "/" + binaryName
    static let binaryName = "micropod-guest"
    static var cacheRoot: URL { SandboxVM.root.appendingPathComponent("guest") }

    /// The host directory to share, installed on first use; nil when no
    /// helper can be found.
    public static let hostDirectory: URL? = {
        do {
            return try install(from: candidates())
        } catch {
            SecretSource.stderrLog("sandbox guest helper unavailable: \(error)")
            return nil
        }
    }()

    /// Where to look, in order.
    static func candidates(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var urls: [URL] = []
        if let path = environment["MICROPOD_GUEST_TOOL"], !path.isEmpty {
            urls.append(URL(fileURLWithPath: path))
        }
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let dir = exe.deletingLastPathComponent()
            urls.append(dir.appendingPathComponent(binaryName))
            urls.append(dir.deletingLastPathComponent().appendingPathComponent("Resources/\(binaryName)"))
        }
        urls.append(URL(fileURLWithPath: "/Applications/Micropod.app/Contents/Resources/\(binaryName)"))
        return urls
    }

    /// The first candidate that is an ELF binary, copied into a
    /// content-addressed cache directory; else the newest cached copy.
    static func install(from candidates: [URL], cache: URL = cacheRoot) throws -> URL? {
        let fm = FileManager.default
        for source in candidates {
            guard let data = try? Data(contentsOf: source), data.starts(with: [0x7F, 0x45, 0x4C, 0x46]) else {
                continue
            }
            let digest = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
            let dir = cache.appendingPathComponent(digest)
            if fm.isExecutableFile(atPath: dir.appendingPathComponent(binaryName).path) { return dir }
            // Staged, then renamed into place: concurrent installers race
            // harmlessly (the loser's rename fails and the winner's copy stays).
            try fm.createDirectory(at: cache, withIntermediateDirectories: true)
            let staging = cache.appendingPathComponent(".staging-\(getpid())-\(UUID().uuidString)")
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            let staged = staging.appendingPathComponent(binaryName)
            guard fm.createFile(atPath: staged.path, contents: data, attributes: [.posixPermissions: 0o755]) else {
                try? fm.removeItem(at: staging)
                continue
            }
            if Darwin.rename(staging.path, dir.path) != 0 { try? fm.removeItem(at: staging) }
            if fm.isExecutableFile(atPath: dir.appendingPathComponent(binaryName).path) { return dir }
        }
        let cached =
            (try? fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter {
                !$0.lastPathComponent.hasPrefix(".")
                    && fm.isExecutableFile(atPath: $0.appendingPathComponent(binaryName).path)
            }
            .sorted {
                let a =
                    (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                let b =
                    (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                return a > b
            }
        return cached?.first
    }
}
