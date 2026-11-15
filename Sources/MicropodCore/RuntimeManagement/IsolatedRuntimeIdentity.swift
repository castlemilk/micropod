import Darwin
import Foundation

/// Host-wide policy. Paths and account names are compiled into the signed
/// helper; unprivileged requests cannot choose a uid, executable or store.
public enum IsolatedRuntimePolicy {
    public static let schema = "micropod-isolated-runtime-v1"
    public static let accountName = "_micropod"
    public static let serviceName = "com.skunkworq.micropod.runtime.host"
    public static let helperIdentifier = "com.skunkworq.micropod.runtime.host"
    public static let setupIdentifier = "com.skunkworq.micropod.runtime-setup"
    public static let teamIdentifier = "WFTX6CN23F"
    public static let publicProviderIdentifiers = ["com.skunkworq.micropod.api", "com.skunkworq.micropod.docker-shim"]
    public static let clientIdentifiers =
        [
            "com.skunkworq.micropod", setupIdentifier,
            "com.skunkworq.micropod.cli", "com.skunkworq.micropod.mcp",
        ] + publicProviderIdentifiers
    public static let root = URL(
        fileURLWithPath: "/Library/Application Support/Micropod/RuntimeHost", isDirectory: true)
    public static let home = URL(fileURLWithPath: "/private/var/db/micropod-runtime", isDirectory: true)
    public static let identityURL = root.appendingPathComponent("identity.json")
    public static let userIDs: ClosedRange<UInt32> = 400...499
    public static var appRoot: URL { home.appendingPathComponent("Library/Application Support/com.apple.container") }
    public static var admissionRoot: URL { root.appendingPathComponent("admission") }
}

/// Public, root-owned metadata. Its uid is an OS identity, never an assertion
/// supplied by a client. A directory account must match every pinned field.
public struct IsolatedRuntimeIdentity: Codable, Equatable, Sendable {
    public let schema: String
    public let instance: UUID
    public let ownerUID: UInt32
    public let serviceUID: UInt32
    public let serviceGID: UInt32
    public let accountGUID: UUID
    public let groupGUID: UUID

    public init(
        instance: UUID, ownerUID: UInt32, serviceUID: UInt32, serviceGID: UInt32, accountGUID: UUID, groupGUID: UUID
    ) {
        self.schema = IsolatedRuntimePolicy.schema
        self.instance = instance
        self.ownerUID = ownerUID
        self.serviceUID = serviceUID
        self.serviceGID = serviceGID
        self.accountGUID = accountGUID
        self.groupGUID = groupGUID
    }

    public func validate() throws {
        guard schema == IsolatedRuntimePolicy.schema, ownerUID >= 500,
            IsolatedRuntimePolicy.userIDs.contains(serviceUID),
            IsolatedRuntimePolicy.userIDs.contains(serviceGID), ownerUID != serviceUID
        else {
            throw MicropodError.message("The managed runtime account identity is invalid")
        }
    }

    public var accountComment: String { "Managed by Micropod; instance=" + instance.uuidString }

    /// The helper publishes this metadata read-only. Workers refuse metadata
    /// that an ordinary account could replace, including symlinked parents.
    public static func readRootOwned(at url: URL = IsolatedRuntimePolicy.identityURL) throws -> Self {
        var directory = url.deletingLastPathComponent()
        while directory.path != "/" {
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_uid == 0,
                info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o022 == 0
            else {
                throw MicropodError.message("Managed runtime metadata is not protected by the system")
            }
            directory.deleteLastPathComponent()
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw MicropodError.message("Managed runtime setup has not completed") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_mode & 0o022 == 0, info.st_size > 0, info.st_size <= 8192
        else {
            throw MicropodError.message("Managed runtime metadata is not protected by the system")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: 8193) ?? Data()
        guard data.count <= 8192 else { throw MicropodError.message("Managed runtime metadata is oversized") }
        let identity = try JSONDecoder().decode(Self.self, from: data)
        try identity.validate()
        return identity
    }
}
