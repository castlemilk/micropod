import Foundation

/// The private runtime's control protocol is separate from RuntimeRigReceipt:
/// it contains no physical HostID and cannot grant host maintenance permission.
public struct RuntimeCoordinationRigCall: Codable, Sendable {
    public let schemaVersion: String
    public let scope: String
    public let action: String
    public let operation: RuntimeCoordinationOperation
    public let enrollment: RuntimeCoordinationEnrollment
    public let challenge: String
    public let releaseKind: RuntimeCoordinationReleaseKind?

    public init(
        action: String, operation: RuntimeCoordinationOperation, enrollment: RuntimeCoordinationEnrollment,
        challenge: String, releaseKind: RuntimeCoordinationReleaseKind? = nil
    ) {
        schemaVersion = RuntimeCoordinationEnrollment.capability
        scope = RuntimeCoordinationEnrollment.runtimeScope
        self.action = action
        self.operation = operation
        self.enrollment = enrollment
        self.challenge = challenge
        self.releaseKind = releaseKind
    }
}

public struct RuntimeCoordinationRigReply: Codable, Sendable {
    /// The coordinator holds no record of the operation and changed nothing
    /// for this call (``RuntimeCoordinatorNotRecorded``).
    public static let notRecordedPhase = "notRecorded"
    /// The agent refused the call before its coordinator saw it.
    public static let refusedPhase = "refused"
    /// The coordinator schedules onto this operation's build (`qualify`).
    public static let qualifiedPhase = "qualified"
    public let schemaVersion: String
    public let scope: String
    public let operation: String
    public let phase: String
    public let state: RuntimeCoordinationState?
    public let maintenanceProof: String?
    public let releaseProof: String?
    public let reason: String?
}

/// The authenticated coordinator answered that it holds no record of this
/// operation and changed nothing for the call. For any call but a drain it has
/// also confirmed that this helper reports no fence or action for it and that
/// the scheduler names it nowhere: the operation was never drained, fenced or
/// released there. A helper that took no local fence and began no runtime
/// action may settle its handoff on this answer; any other refusal keeps it.
public struct RuntimeCoordinatorNotRecorded: LocalizedError, Sendable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}

/// The agent answered `refused`: it turned the call away before its
/// coordinator saw it (an unqualified build, a malformed request, an offline
/// rig). For a first drain nothing anywhere holds the operation.
public struct RuntimeCoordinatorRefusedUnprocessed: LocalizedError, Sendable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}

/// Root selects the recorded owner's home and the exact enrolled kernel peer.
/// A replacement process, socket path or matching signing team alone is never
/// enough to take over a retained action.
public struct RuntimeCoordinationRigClient: Sendable {
    private let ownerHome: URL
    private let identity: IsolatedRuntimeIdentity
    private let peer: RuntimeProcessBirth

    public init(ownerHome: URL, identity: IsolatedRuntimeIdentity, peer: RuntimeProcessBirth) {
        self.ownerHome = ownerHome
        self.identity = identity
        self.peer = peer
    }

    public func transition(_ call: RuntimeCoordinationRigCall) async throws -> RuntimeCoordinationRigReply {
        try identity.validate()
        try call.enrollment.validate(identity: identity)
        try call.operation.validateLocal(identity: identity)
        guard call.schemaVersion == RuntimeCoordinationEnrollment.capability,
            call.scope == RuntimeCoordinationEnrollment.runtimeScope,
            ["drain", "prepare", "begin", "verify", "complete", "abort", "abortComplete", "status", "qualify"].contains(
                call.action),
            RuntimeCoordinationProofVerifier.validChallenge(call.challenge), peer.uid == identity.ownerUID,
            (call.action == "complete" || call.action == "abortComplete") == (call.releaseKind != nil),
            call.action != "abortComplete" || call.releaseKind == .cancelled,
            call.action != "complete" || call.releaseKind?.rawValue == call.operation.targetState
                || call.releaseKind == .stopped
        else { throw MicropodError.message("The private runtime handoff request is invalid") }
        let data = try JSONEncoder().encode(call) + Data([10])
        let bytes = try await RuntimePeerSocket.exchange(
            path: ownerHome.appendingPathComponent(".cuttlefish/runner-state/micropod-maintenance.sock").path,
            request: data, expectedUID: identity.ownerUID, expectedPeer: peer, maximumReply: 32768)
        return try Self.decodeReply(bytes, operation: call.operation)
    }

    static func decodeReply(_ bytes: Data, operation: RuntimeCoordinationOperation) throws
        -> RuntimeCoordinationRigReply
    {
        guard let fields = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            Set(fields.keys).isSubset(of: [
                "schemaVersion", "scope", "operation", "phase", "state", "maintenanceProof", "releaseProof", "reason",
            ])
        else { throw MicropodError.message("The private runtime handoff reply is invalid") }
        let reply = try JSONDecoder().decode(RuntimeCoordinationRigReply.self, from: bytes)
        guard reply.schemaVersion == RuntimeCoordinationEnrollment.capability,
            reply.scope == RuntimeCoordinationEnrollment.runtimeScope, reply.operation == operation.id,
            [
                "draining", "drained", "prepared", "begun", "verified", "completed", "aborting", "cancelled", "blocked",
                "recoveryRequired", RuntimeCoordinationRigReply.notRecordedPhase,
                RuntimeCoordinationRigReply.refusedPhase, RuntimeCoordinationRigReply.qualifiedPhase,
            ].contains(reply.phase),
            reply.phase != RuntimeCoordinationRigReply.qualifiedPhase
                || (reply.state == nil && reply.maintenanceProof == nil && reply.releaseProof == nil),
            reply.phase != RuntimeCoordinationRigReply.refusedPhase
                || (reply.state == nil && reply.maintenanceProof == nil && reply.releaseProof == nil),
            reply.phase != RuntimeCoordinationRigReply.notRecordedPhase
                || (reply.state == nil && reply.maintenanceProof == nil && reply.releaseProof == nil
                    && !(reply.reason ?? "").isEmpty),
            (reply.maintenanceProof?.utf8.count ?? 0) <= 16384,
            (reply.releaseProof?.utf8.count ?? 0) <= 16384,
            (reply.reason?.utf8.count ?? 0) <= 1024,
            reply.maintenanceProof == nil || reply.releaseProof == nil
        else { throw MicropodError.message("The private runtime handoff reply did not match its operation") }
        // The controller must verify the signature and exact retained resource
        // generation before using either proof. Phase text grants no authority.
        return reply
    }
}
