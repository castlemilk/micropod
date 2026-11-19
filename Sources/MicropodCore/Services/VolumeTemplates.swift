import CryptoKit
import Darwin
import Foundation

/// Pre-formatted ext4 images that new volumes are cloned from.
///
/// container-apiserver formats every new volume's ext4 image inside
/// `volumeCreate`, synchronously on its volumes actor: on Gamma-128 that
/// took 5.5–12.3 s for 136 GiB and 25.8 s for 512 GiB, and every volume
/// list, inspect and delete waited behind it (a create's clones inspect
/// their goldens; a delete holds the volumes lock while it queues for the
/// containers lock). A CI run creates one workspace volume, often more.
///
/// The format depends only on the requested size and journal, so it is
/// done once per (size, journal) — by the apiserver itself, into a scratch
/// volume, so the image is exactly what it would have made — and kept here
/// as a template. A new volume is then created at the apiserver's minimum
/// size (a format of a few milliseconds) and its image replaced with an
/// APFS clone of the template (O(1)), the way `CloneVolume` places clones.
///
/// Templates are immutable: nothing writes to them, only clones are made.
/// Each has a manifest (its length, inode and modification time, and a
/// digest of its first 4 MiB, which hold the superblock and the group
/// descriptors). A template is used only while it matches its manifest;
/// one that is missing, changed or unreadable is rebuilt. The digest is
/// recomputed once per template per process, the cheap checks on every use.
///
/// Every volume made from one template shares its ext4 UUID. The images
/// have no `metadata_csum`, and guests mount block devices by path, not by
/// UUID.
public actor VolumeTemplates {
    public static let shared = VolumeTemplates()

    /// Labels a templated volume carries: the template key, and the size it
    /// was asked for (its configuration records the placeholder's).
    public static let templateLabel = "com.micropod.volume.template"
    public static let sizeLabel = "com.micropod.volume.provisioned-bytes"

    /// What a template is keyed by: the two options that change the format.
    /// Other driver options are not templated (the caller formats as before).
    public struct Key: Hashable, Sendable, CustomStringConvertible {
        public let size: String
        public let journal: String?

        /// The key for `driverOpts`, or nil when they ask for something a
        /// template does not reproduce.
        public init?(driverOpts: [String: String]) {
            guard Set(driverOpts.keys).isSubset(of: ["size", "journal"]) else { return nil }
            let size = (driverOpts["size"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            guard size.allSatisfy({ $0.isASCII && ($0.isNumber || $0.isLetter || $0 == ".") }) else { return nil }
            self.size = size.isEmpty ? "default" : size
            let journal = driverOpts["journal"]?.trimmingCharacters(in: .whitespaces).lowercased()
            guard journal.map({ $0.allSatisfy { $0.isASCII && ($0.isNumber || $0.isLetter || $0 == ":") } }) ?? true
            else { return nil }
            self.journal = journal.flatMap { $0.isEmpty ? nil : $0 }
        }

        public var description: String { "ext4-\(size)" + (journal.map { "-journal-\($0)" } ?? "") }
        /// The driver options the template is formatted with.
        public var driverOpts: [String: String] {
            var opts: [String: String] = [:]
            if size != "default" { opts["size"] = size }
            if let journal { opts["journal"] = journal }
            return opts
        }
        var fileName: String { description.replacingOccurrences(of: ":", with: "_") + ".img" }
    }

    /// What a template's manifest records.
    struct Manifest: Codable, Equatable {
        var bytes: UInt64
        var inode: UInt64
        var modified: Double
        var headSHA256: String
    }

    /// Driver options for the placeholder a templated volume is created
    /// with: the apiserver's minimum size, formatted in milliseconds.
    public static let placeholderOpts = ["size": "1M"]

    static let headLength = 4 << 20

    /// `<micropod>/volume-templates`, beside the clone root (the same volume
    /// as the apiserver's volumes, which a clone needs).
    /// `MICROPOD_VOLUME_TEMPLATE_ROOT` overrides it.
    public static var defaultRoot: URL {
        if let override = ProcessInfo.processInfo.environment["MICROPOD_VOLUME_TEMPLATE_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return VolumeClone.cloneRoot.deletingLastPathComponent().appendingPathComponent(
            "volume-templates", isDirectory: true)
    }

    /// False when `MICROPOD_VOLUME_TEMPLATES=off`: volumes are formatted by
    /// the apiserver as before.
    public static var enabledByEnvironment: Bool {
        ProcessInfo.processInfo.environment["MICROPOD_VOLUME_TEMPLATES"] != "off"
    }

    private let fixedRoot: URL?
    private var verified: [Key: Manifest] = [:]
    private var building: [Key: Task<String, Error>] = [:]

    public init(root: URL? = nil) { self.fixedRoot = root }

    public var root: URL { fixedRoot ?? Self.defaultRoot }

    /// The template image for `key`, built by `format` when there is no
    /// verified one. `format` makes an image formatted with
    /// `key.driverOpts` at the path it is given (the caller has the
    /// apiserver do it) and must leave nothing else behind. Concurrent
    /// callers for one key share one build.
    public func template(for key: Key, format: @escaping @Sendable (_ destination: String) async throws -> Void)
        async throws -> String
    {
        let path = root.appendingPathComponent(key.fileName).path
        if let manifest = verified[key], Self.matchesCheaply(path, manifest) { return path }
        if let manifest = Self.readManifest(path), Self.matchesFully(path, manifest) {
            verified[key] = manifest
            return path
        }
        verified[key] = nil
        if let build = building[key] { return try await build.value }
        let root = self.root
        let build = Task { () throws -> String in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let temp = root.appendingPathComponent(".\(key.fileName).build-\(UUID().uuidString.prefix(8))").path
            defer { unlink(temp) }
            try await format(temp)
            let manifest = try Self.manifest(of: temp)
            // The manifest names the template's final inode, which the rename
            // keeps; it is written first so a template is never without one.
            try JSONEncoder().encode(manifest).write(to: URL(fileURLWithPath: path + ".json"), options: .atomic)
            guard rename(temp, path) == 0 else {
                throw MicropodError.message(
                    "could not place volume template \(path): \(String(cString: strerror(errno)))")
            }
            return path
        }
        building[key] = build
        defer { building[key] = nil }
        let built = try await build.value
        if let manifest = Self.readManifest(built), Self.matchesFully(built, manifest) {
            verified[key] = manifest
        }
        return built
    }

    /// Forgets `key`'s verification, so the next use re-reads the manifest
    /// and digest (a clone from it failed).
    public func invalidate(_ key: Key) { verified[key] = nil }

    // MARK: - Verification

    static func manifest(of path: String) throws -> Manifest {
        var info = Darwin.stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw MicropodError.message("volume template \(path) is missing")
        }
        guard Self.hasExt4Superblock(path) else {
            throw MicropodError.message("volume template \(path) is not an ext4 image")
        }
        guard let head = Self.headDigest(path) else {
            throw MicropodError.message("volume template \(path) could not be read")
        }
        return Manifest(
            bytes: UInt64(info.st_size), inode: UInt64(info.st_ino), modified: modificationTime(info),
            headSHA256: head)
    }

    static func readManifest(_ path: String) -> Manifest? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path + ".json")) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    /// Same file, same length, never modified since the manifest was made.
    static func matchesCheaply(_ path: String, _ manifest: Manifest) -> Bool {
        var info = Darwin.stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
            && UInt64(info.st_size) == manifest.bytes && UInt64(info.st_ino) == manifest.inode
            && modificationTime(info) == manifest.modified
    }

    /// The cheap checks, an ext4 superblock, and the digest of the head.
    static func matchesFully(_ path: String, _ manifest: Manifest) -> Bool {
        matchesCheaply(path, manifest) && hasExt4Superblock(path) && headDigest(path) == manifest.headSHA256
    }

    /// The ext4 magic (0xEF53, little-endian, at byte 1024 + 0x38).
    static func hasExt4Superblock(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var magic: UInt16 = 0
        guard pread(fd, &magic, 2, 1024 + 0x38) == 2 else { return false }
        return UInt16(littleEndian: magic) == 0xEF53
    }

    static func headDigest(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: headLength) else { return nil }
        return SHA256.hash(data: head).map { String(format: "%02x", $0) }.joined()
    }

    private static func modificationTime(_ info: Darwin.stat) -> Double {
        Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
    }
}
