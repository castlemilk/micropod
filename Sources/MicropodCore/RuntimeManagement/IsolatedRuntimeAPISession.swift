import CryptoKit
import Darwin
import Foundation

/// A capability returned only over authenticated helper IPC. It is bound to
/// one kernel process incarnation, not just possession of a bearer string.
public struct IsolatedRuntimeAPISession: Codable, Sendable {
    public let id: UUID
    public let instance: UUID
    public let token: String
    public let subject: RuntimeProcessBirth
    public let expiresAt: Date
    public var socketPath: String { IsolatedRuntimePolicy.root.appendingPathComponent("gateway/api.sock").path }
    public var authorization: String { "Bearer " + id.uuidString + "." + token }
    public init(id: UUID, instance: UUID, token: String, subject: RuntimeProcessBirth, expiresAt: Date) {
        self.id = id
        self.instance = instance
        self.token = token
        self.subject = subject
        self.expiresAt = expiresAt
    }
}

/// Public root-owned registration. The bearer secret is never written here
/// or into the operation journal and cannot be reconstructed from this hash.
public struct IsolatedRuntimeAPISessionRecord: Codable, Sendable {
    public let id: UUID
    public let instance: UUID
    public let tokenSHA256: String
    public let subject: RuntimeProcessBirth
    public let expiresAt: Date
    public init(session: IsolatedRuntimeAPISession) {
        id = session.id
        instance = session.instance
        subject = session.subject
        expiresAt = session.expiresAt
        tokenSHA256 = Self.digest(session.token)
    }
    public func accepts(token: String, peer: RuntimeProcessBirth, instance: UUID, now: Date = Date()) -> Bool {
        guard self.instance == instance, peer == subject, expiresAt > now else { return false }
        let left = Array(Self.digest(token).utf8)
        let right = Array(tokenSHA256.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    private static func digest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Root-owned configuration for the service-account API. Its upstream socket
/// lives inside the private home, which desktop accounts cannot traverse.
public struct IsolatedRuntimeAPIConfiguration: Codable, Sendable {
    public let instance: UUID
    public let selection: ManagedRuntimeLocation.Selection
    public let executableSHA256: String
    public let guestSHA256: String?
    public var toolDirectoryName: String { executableSHA256 + (guestSHA256.map { "-" + $0 } ?? "") }
    public init(
        instance: UUID, selection: ManagedRuntimeLocation.Selection, executableSHA256: String,
        guestSHA256: String? = nil
    ) {
        self.instance = instance
        self.selection = selection
        self.executableSHA256 = executableSHA256
        self.guestSHA256 = guestSHA256
    }
    public static var fileURL: URL { IsolatedRuntimePolicy.root.appendingPathComponent("api-configuration.json") }
    public static var sessionsRoot: URL { IsolatedRuntimePolicy.root.appendingPathComponent("sessions") }
    public static var socketURL: URL { IsolatedRuntimePolicy.root.appendingPathComponent("gateway/api.sock") }
    public static var internalSocketURL: URL { IsolatedRuntimePolicy.home.appendingPathComponent("api-internal.sock") }
    public static let serviceLabel = "com.skunkworq.micropod.runtime.api"
    public static let executableIdentifier = "com.skunkworq.micropod.api"
    public static var agentURL: URL { IsolatedRuntimePolicy.root.appendingPathComponent("runtime-api.plist") }
    public func validate(identity: IsolatedRuntimeIdentity) throws {
        guard instance == identity.instance, selection.isSupported, executableSHA256.count == 64,
            executableSHA256.allSatisfy({ "0123456789abcdef".contains($0) }),
            guestSHA256.map({ $0.count == 64 && $0.allSatisfy({ "0123456789abcdef".contains($0) }) }) ?? true
        else {
            throw MicropodError.message("The managed API configuration is invalid")
        }
    }
    public static func read(identity: IsolatedRuntimeIdentity, allowStaged: Bool = false) throws -> Self {
        let selected =
            allowStaged && !FileManager.default.fileExists(atPath: fileURL.path)
            ? IsolatedRuntimePolicy.root.appendingPathComponent("pending-api-configuration.json") : fileURL
        let bytes = try RuntimeDurableFile.read(selected, maximumBytes: 16384, ownerUID: 0)
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        try value.validate(identity: identity)
        return value
    }
}
