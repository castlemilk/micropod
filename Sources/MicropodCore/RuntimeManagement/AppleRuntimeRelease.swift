import Foundation

/// Only releases whose package bytes and native protocol have been verified
/// may be installed. Network responses cannot select a URL, version or digest.
public struct AppleRuntimeRelease: Codable, Sendable, Equatable {
    public let version: String
    public let packageURL: URL
    public let packageSHA256: String
    public let packageBytes: Int64
    public let teamIdentifier: String

    public static let supported = AppleRuntimeRelease(
        version: "1.5.0",
        packageURL: URL(
            string: "https://github.com/apple/container/releases/download/1.5.0/container-1.5.0-installer-signed.pkg")!,
        packageSHA256: "a24808cb202318fa1c3bbee0c6c6887fe1225fe899d7b687a0ddd939bd6573f8",
        packageBytes: 118_045_087,
        teamIdentifier: "UPBK2H6LZM")
}

public enum ManagedRuntimeLocation {
    public static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Micropod/Runtime", isDirectory: true)
    }

    public struct Selection: Codable, Equatable, Sendable {
        public let version: String
        public let packageSHA256: String
        public let incarnation: UUID?
        public init(version: String, packageSHA256: String, incarnation: UUID? = nil) {
            self.version = version
            self.packageSHA256 = packageSHA256
            self.incarnation = incarnation
        }
        public var directoryName: String {
            version + "-" + packageSHA256 + (incarnation.map { "-" + $0.uuidString } ?? "")
        }
        public var isSupported: Bool {
            version == AppleRuntimeRelease.supported.version
                && packageSHA256 == AppleRuntimeRelease.supported.packageSHA256
        }
    }

    public static func selection(at root: URL = root) throws -> Selection? {
        let file = root.appendingPathComponent("current.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try RuntimeDurableFile.read(file, maximumBytes: 4096)
        let selected = try JSONDecoder().decode(Selection.self, from: data)
        guard selected.isSupported else { throw MicropodError.message("Managed runtime selection is unsupported") }
        return selected
    }

    public static func executable(at root: URL = root) -> URL? {
        do {
            guard let selected = try selection(at: root) else { return nil }
            return root.appendingPathComponent("versions/" + selected.directoryName + "/bin/container")
        } catch {
            // A broken managed selection must not silently switch to an
            // unrelated system runtime or image store.
            return root.appendingPathComponent("invalid-selection/bin/container")
        }
    }
}
