import Foundation

/// These calls are accepted only on the root helper's process-authenticated
/// Unix socket. They never select an issuer, verification key, path or UID.
public struct RuntimeCoordinationCall: Codable, Sendable {
    public let action: String
    public let purpose: String?
    public let challenge: String?
    public let proof: String?
    public init(action: String, purpose: String? = nil, challenge: String? = nil, proof: String? = nil) {
        self.action = action
        self.purpose = purpose
        self.challenge = challenge
        self.proof = proof
    }
}

public struct RuntimeCoordinationReply: Codable, Sendable {
    public let schemaVersion: String
    public let scope: String
    public let identity: IsolatedRuntimeIdentity
    public let peer: RuntimeProcessBirth
    public let challenge: String?
    public let enrollment: RuntimeCoordinationEnrollment?
    public let session: IsolatedRuntimeAPISession?
    public init(
        identity: IsolatedRuntimeIdentity, peer: RuntimeProcessBirth, challenge: String? = nil,
        enrollment: RuntimeCoordinationEnrollment? = nil, session: IsolatedRuntimeAPISession? = nil
    ) {
        schemaVersion = RuntimeCoordinationEnrollment.capability
        scope = RuntimeCoordinationEnrollment.runtimeScope
        self.identity = identity
        self.peer = peer
        self.challenge = challenge
        self.enrollment = enrollment
        self.session = session
    }
}
