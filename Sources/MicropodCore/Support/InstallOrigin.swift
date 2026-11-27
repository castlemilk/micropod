import Darwin
import Foundation

/// Whether micropod on this Mac is a fresh install or one from before the
/// hvf default, decided once and pinned in runtimes.json (`defaultOrigin`).
///
/// Fresh means no runtimes.json and a `~/.micropod` that is missing or
/// empty. A fresh install pins `{"default": "hvf", "defaultOrigin":
/// "fresh-install"}`; anything else pins `{"defaultOrigin":
/// "existing-install"}` and keeps the Apple default. A runtimes.json that
/// exists is never rewritten, so the first binary that runs decides.
///
/// Every binary calls `resolve` as the first statement of its `main`:
/// anything that created a file under `~/.micropod` before it would make a
/// fresh install look like an existing one.
///
/// With `MICROPOD_RUNTIMES_CONFIG` set (tests, gate scripts, CI) nothing is
/// decided unless `MICROPOD_INSTALL_ORIGIN=fresh|existing` names the origin,
/// so their implicit Apple default stays.
public enum InstallOrigin: String, Sendable, Codable, CaseIterable {
    case fresh = "fresh-install"
    case existing = "existing-install"

    /// The default runtime a fresh install pins.
    public static let freshDefaultRuntime = "hvf"

    public enum Outcome: Equatable, Sendable {
        /// The config path is overridden and no origin was named.
        case skipped
        /// runtimes.json was there already; the origin it records, if any.
        case kept(InstallOrigin?)
        /// This call wrote the pin.
        case pinned(InstallOrigin)
        /// The pin could not be written, so nothing was decided.
        case failed(String)
    }

    /// `MICROPOD_RUNTIMES_CONFIG`, else `<home>/.micropod/runtimes.json`.
    public static func configURL(
        environment: [String: String], home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let path = environment["MICROPOD_RUNTIMES_CONFIG"], !path.isEmpty {
            return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        }
        return home.appendingPathComponent(".micropod/runtimes.json")
    }

    /// `MICROPOD_INSTALL_ORIGIN`: `fresh` or `existing` (the pinned spellings
    /// work too); nil when unset or anything else.
    public static func named(in environment: [String: String]) -> InstallOrigin? {
        switch environment["MICROPOD_INSTALL_ORIGIN"]?.lowercased() {
        case "fresh", InstallOrigin.fresh.rawValue: return .fresh
        case "existing", InstallOrigin.existing.rawValue: return .existing
        default: return nil
        }
    }

    /// Decides and pins the origin unless runtimes.json already exists.
    /// Never throws and never prints: a binary that cannot write the pin
    /// still runs, with the Apple default, and the next one tries again.
    @discardableResult
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Outcome {
        let named = named(in: environment)
        let overridden = !(environment["MICROPOD_RUNTIMES_CONFIG"] ?? "").isEmpty
        if overridden, named == nil { return .skipped }
        let url = configURL(environment: environment, home: home)
        if let existing = recorded(at: url) { return .kept(existing.origin) }
        let origin = named ?? (isEmptyOrMissing(home.appendingPathComponent(".micropod")) ? .fresh : .existing)
        do {
            return try pin(origin, at: url)
        } catch {
            return .failed("\(url.path): \(error.localizedDescription)")
        }
    }

    /// The pin's JSON for `origin`, as runtimes.json holds it.
    public static func pinData(_ origin: InstallOrigin) -> Data {
        var object: [String: Any] = ["defaultOrigin": origin.rawValue, "engines": [String: Any]()]
        if origin == .fresh { object["default"] = freshDefaultRuntime }
        // Keys sorted like EngineConfig.save writes them.
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// A runtimes.json that exists, and the origin it records: nil for one
    /// written before the pin, or one that does not parse.
    struct Recorded: Equatable {
        var origin: InstallOrigin?
    }

    /// runtimes.json at `url`, when there is one.
    static func recorded(at url: URL) -> Recorded? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let raw = object["defaultOrigin"] as? String
        else { return Recorded(origin: nil) }
        return Recorded(origin: InstallOrigin(rawValue: raw))
    }

    /// `~/.micropod` has nothing in it but Finder's `.DS_Store` and the
    /// pins concurrent resolvers are staging (each one decides on its own).
    static func isEmptyOrMissing(_ directory: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            var info = stat()
            // A file (or a dangling link) in its place is not a fresh home.
            return lstat(directory.path, &info) != 0
        }
        return names.allSatisfy { $0 == ".DS_Store" || $0.hasPrefix(stagingPrefix) }
    }

    static let stagingPrefix = ".runtimes-pin-"

    /// Exclusive create of the whole file: written beside the target, then
    /// hard-linked into place, which fails when another process won the
    /// race. The loser reads the winner's pin.
    static func pin(_ origin: InstallOrigin, at url: URL) throws -> Outcome {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = directory.appendingPathComponent("\(stagingPrefix)\(getpid())-\(UUID().uuidString).json")
        try pinData(origin).write(to: staged)
        defer { unlink(staged.path) }
        guard link(staged.path, url.path) == 0 else {
            let code = errno
            if code == EEXIST { return .kept(recorded(at: url)?.origin) }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return .pinned(origin)
    }
}
