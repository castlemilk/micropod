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
    public let coverage: RuntimeCoordinationCoverage?
    public init(
        identity: IsolatedRuntimeIdentity, peer: RuntimeProcessBirth, challenge: String? = nil,
        enrollment: RuntimeCoordinationEnrollment? = nil, session: IsolatedRuntimeAPISession? = nil,
        coverage: RuntimeCoordinationCoverage? = nil
    ) {
        schemaVersion = RuntimeCoordinationEnrollment.capability
        scope = RuntimeCoordinationEnrollment.runtimeScope
        self.identity = identity
        self.peer = peer
        self.challenge = challenge
        self.enrollment = enrollment
        self.session = session
        self.coverage = coverage
    }
}

/// Observation from the authenticated helper, bound to its durable operation.
/// This is neither a data capability nor physical-host maintenance coverage.
public struct RuntimeCoordinationCoverage: Codable, Sendable {
    public let operation: RuntimeCoordinationOperation
    public let phase: String
    public let admissionClosed: Bool
    public let actionStarted: Bool
    public let actionVerified: Bool
    public let cancelledBeforeAction: Bool
    public let workerActive: Bool
    public let nativeState: String?
    public let nativeVersion: String?
    public let nativeAppRoot: String?
    public let nativeInstallRoot: String?

    public init(
        operation: RuntimeCoordinationOperation, phase: String, admissionClosed: Bool,
        actionStarted: Bool, actionVerified: Bool, cancelledBeforeAction: Bool, workerActive: Bool,
        nativeState: String?, nativeVersion: String?, nativeAppRoot: String?, nativeInstallRoot: String?
    ) {
        self.operation = operation
        self.phase = phase
        self.admissionClosed = admissionClosed
        self.actionStarted = actionStarted
        self.actionVerified = actionVerified
        self.cancelledBeforeAction = cancelledBeforeAction
        self.workerActive = workerActive
        self.nativeState = nativeState
        self.nativeVersion = nativeVersion
        self.nativeAppRoot = nativeAppRoot
        self.nativeInstallRoot = nativeInstallRoot
    }
}

/// Root-owned reconciliation metadata. A digest is retained for audit, never
/// accepted as a replacement for a fresh, process-bound signed proof.
public struct RuntimeCoordinationRetainedReceipt: Codable, Sendable, Equatable {
    public let enrollment: RuntimeCoordinationEnrollment
    public let peer: RuntimeProcessBirth
    public let sessionGeneration: Int64
    public let operation: RuntimeCoordinationOperation
    public let resourceGeneration: Int64
    public let proofSHA256: String

    public init(
        enrollment: RuntimeCoordinationEnrollment, peer: RuntimeProcessBirth, sessionGeneration: Int64,
        operation: RuntimeCoordinationOperation, resourceGeneration: Int64, proofSHA256: String
    ) {
        self.enrollment = enrollment
        self.peer = peer
        self.sessionGeneration = sessionGeneration
        self.operation = operation
        self.resourceGeneration = resourceGeneration
        self.proofSHA256 = proofSHA256
    }
}
