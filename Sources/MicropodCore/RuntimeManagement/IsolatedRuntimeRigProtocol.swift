import Foundation

public struct IsolatedRuntimeRigCall: Codable, Sendable {
    public let action: String
    public let operation: UUID?
    public let generation: UInt64?
    public let hostID: String?
    public init(action: String, operation: UUID? = nil, generation: UInt64? = nil, hostID: String? = nil) {
        self.action = action
        self.operation = operation
        self.generation = generation
        self.hostID = hostID
    }
    public static var socketPath: String { IsolatedRuntimePolicy.root.appendingPathComponent("control.sock").path }
}
public struct IsolatedRuntimeRigProof: Codable, Sendable {
    public let schema: String
    public let instance: UUID
    public let ownerUID: UInt32
    public let hostID: String
    public let operation: UUID?
    public let generation: UInt64?
    public let admissionClosed: Bool
    public let actionVerified: Bool
    public let phase: String
    public let nativeState: String?
    public let nativeVersion: String?
    public let nativeInstallRoot: String?
    public let nativeAppRoot: String?
    public init(
        identity: IsolatedRuntimeIdentity, hostID: String, operation: UUID?, generation: UInt64?,
        admissionClosed: Bool, actionVerified: Bool, phase: String, nativeState: String? = nil,
        nativeVersion: String? = nil, nativeInstallRoot: String? = nil, nativeAppRoot: String? = nil
    ) {
        schema = IsolatedRuntimePolicy.schema
        instance = identity.instance
        ownerUID = identity.ownerUID
        self.hostID = hostID
        self.operation = operation
        self.generation = generation
        self.admissionClosed = admissionClosed
        self.actionVerified = actionVerified
        self.phase = phase
        self.nativeState = nativeState
        self.nativeVersion = nativeVersion
        self.nativeInstallRoot = nativeInstallRoot
        self.nativeAppRoot = nativeAppRoot
    }
}
public struct IsolatedRuntimeRigRegistration: Codable, Sendable {
    public let instance: UUID
    public let ownerUID: UInt32
    public let hostID: String
    public init(identity: IsolatedRuntimeIdentity, hostID: String) {
        instance = identity.instance
        ownerUID = identity.ownerUID
        self.hostID = hostID
    }
    public static var fileURL: URL { IsolatedRuntimePolicy.root.appendingPathComponent("rig.json") }
    public static func read(identity: IsolatedRuntimeIdentity) throws -> Self? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let registration = try JSONDecoder().decode(
            Self.self,
            from: RuntimeDurableFile.read(fileURL, maximumBytes: 4096, ownerUID: 0))
        guard registration.instance == identity.instance, registration.ownerUID == identity.ownerUID,
            !registration.hostID.isEmpty, registration.hostID.count <= 128
        else {
            throw MicropodError.message("The managed runtime rig registration is invalid")
        }
        return registration
    }
}
