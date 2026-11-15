import CryptoKit
import Darwin
import Foundation
import MicropodCore
import Security

/// All mutation is serialized by IsolatedRuntimeHostController. The record is
/// a distinct file/type from rig.json and cannot enroll the public provider.
struct RuntimeCoordinatorAuthority {
    struct Registration: Codable, Equatable {
        let enrollment: RuntimeCoordinationEnrollment
        let peer: RuntimeProcessBirth
        let sessionGeneration: Int64
        let issuer: String
        let proofSHA256: String
        let reconciliationOnly: Bool?
    }
    private struct Challenge {
        let peer: RuntimeProcessBirth
        let instance: UUID
        let purpose: String
        let deadline: UInt64
        let operation: RuntimeCoordinationOperation?
    }
    static var fileURL: URL { IsolatedRuntimePolicy.root.appendingPathComponent("runtime-coordinator.json") }
    private let fileURL: URL
    private let ownerUID: UInt32
    private let verifier: RuntimeCoordinationProofVerifier
    private let uptime: () -> UInt64
    private var challenges: [String: Challenge] = [:]
    var hasRecord: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    init(
        fileURL: URL = Self.fileURL, ownerUID: UInt32 = 0,
        verifier: RuntimeCoordinationProofVerifier = .init(),
        uptime: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.fileURL = fileURL
        self.ownerUID = ownerUID
        self.verifier = verifier
        self.uptime = uptime
    }

    func read(identity: IsolatedRuntimeIdentity) throws -> Registration? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let record = try JSONDecoder().decode(
            Registration.self, from: RuntimeDurableFile.read(fileURL, maximumBytes: 16384, ownerUID: ownerUID))
        // Reuse the typed enrollment's exact local-account checks. A stored
        // digest is audit evidence only; a fresh signed proof is always needed.
        try record.enrollment.validate(identity: identity)
        guard record.sessionGeneration > 0,
            record.peer.uid == identity.ownerUID, record.issuer == "https://api.cuttlefish.sh",
            record.proofSHA256.utf8.count == 64,
            record.proofSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw refused() }
        return record
    }

    mutating func issueChallenge(identity: IsolatedRuntimeIdentity, peer: RuntimeProcessBirth, purpose: String) throws
        -> String
    {
        guard ["enrollment", "session"].contains(purpose) else { throw refused() }
        return try issue(identity: identity, peer: peer, purpose: purpose, operation: nil)
    }

    /// Only the controller calls this with its own durable action intent.
    /// It is not exposed as a general challenge request over the agent socket.
    mutating func issueOperationChallenge(
        identity: IsolatedRuntimeIdentity, peer: RuntimeProcessBirth,
        operation: RuntimeCoordinationOperation, purpose: String
    ) throws -> String {
        guard ["maintenance", "release-observation"].contains(purpose),
            operation.runtimeInstance == identity.instance.uuidString,
            let record = try read(identity: identity), record.peer == peer,
            record.reconciliationOnly != true || purpose == "release-observation"
        else { throw refused() }
        return try issue(identity: identity, peer: peer, purpose: purpose, operation: operation)
    }

    private mutating func issue(
        identity: IsolatedRuntimeIdentity, peer: RuntimeProcessBirth, purpose: String,
        operation: RuntimeCoordinationOperation?
    ) throws -> String {
        guard geteuid() == ownerUID, peer.uid == identity.ownerUID else { throw refused() }
        let now = uptime()
        challenges = challenges.filter { $0.value.deadline > now }
        // Bound both a single signed peer and the entire helper. Restart drops
        // every outstanding nonce, so no pre-restart proof becomes valid again.
        guard challenges.count < 64, challenges.values.filter({ $0.peer == peer }).count < 4,
            now <= UInt64.max - 120_000_000_000
        else { throw refused() }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw refused() }
        let nonce = bytes.map { String(format: "%02x", $0) }.joined()
        challenges[nonce] = Challenge(
            peer: peer, instance: identity.instance, purpose: purpose, deadline: now + 120_000_000_000,
            operation: operation)
        return nonce
    }

    // A drain poll may return before a resource fence can be acquired. Retire
    // that poll's nonce so normal waiting cannot exhaust the bounded queue.
    mutating func discardChallenge(_ nonce: String) { challenges.removeValue(forKey: nonce) }

    mutating func authorizeMaintenance(
        _ token: String, challenge: String, identity: IsolatedRuntimeIdentity,
        peer: RuntimeProcessBirth, operation: RuntimeCoordinationOperation,
        resourceGeneration: Int64, now: Date = Date()
    ) throws -> RuntimeCoordinationRetainedReceipt {
        try consume(challenge, purpose: "maintenance", identity: identity, peer: peer, operation: operation)
        guard let record = try read(identity: identity), record.peer == peer, record.reconciliationOnly != true else {
            throw refused()
        }
        _ = try verifier.verifyMaintenance(
            token, identity: identity, peer: peer, challenge: challenge,
            enrollment: record.enrollment, sessionGeneration: record.sessionGeneration,
            operation: operation, resourceGeneration: resourceGeneration, now: now)
        return .init(
            enrollment: record.enrollment, peer: peer, sessionGeneration: record.sessionGeneration,
            operation: operation, resourceGeneration: resourceGeneration,
            proofSHA256: SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    mutating func observeRelease(
        _ token: String, challenge: String, identity: IsolatedRuntimeIdentity, peer: RuntimeProcessBirth,
        retained: RuntimeCoordinationRetainedReceipt, kind: RuntimeCoordinationReleaseKind, now: Date = Date()
    ) throws -> RuntimeCoordinationReleaseObservation {
        try consume(
            challenge, purpose: "release-observation", identity: identity, peer: peer, operation: retained.operation)
        // Reconciliation is deliberately separate from session or new action
        // permission. Only the exact retained release can be observed here.
        return try verifier.verifyReleaseObservation(
            token, identity: identity, peer: peer, challenge: challenge,
            originalEnrollment: retained.enrollment, operation: retained.operation,
            resourceGeneration: retained.resourceGeneration, kind: kind, now: now)
    }

    mutating func enroll(
        _ token: String, challenge: String, identity: IsolatedRuntimeIdentity, peer: RuntimeProcessBirth,
        requiredEnrollment: RuntimeCoordinationEnrollment? = nil,
        now: Date = Date(), priorProcessExited: (RuntimeProcessBirth) throws -> Bool = { try $0.hasExited() }
    ) throws -> RuntimeCoordinationEnrollment {
        try consume(challenge, purpose: "enrollment", identity: identity, peer: peer)
        let proof = try verifier.verifyEnrollment(token, identity: identity, peer: peer, challenge: challenge, now: now)
        if let requiredEnrollment, proof.enrollment != requiredEnrollment { throw refused() }
        if let old = try read(identity: identity) {
            // A status credential can rotate within the same kernel process.
            // It does not replace worker ownership. A different process still
            // needs positive exit proof, and neither path may roll back a
            // generation already verified under the control-plane signature.
            let canReplace =
                try old.peer == peer
                || (proof.sessionGeneration > old.sessionGeneration && priorProcessExited(old.peer))
            guard old.enrollment.resourceId == proof.enrollment.resourceId,
                old.enrollment.organizationId == proof.enrollment.organizationId,
                old.enrollment.runnerId == proof.enrollment.runnerId,
                old.enrollment.binding == proof.enrollment.binding,
                old.enrollment.revision <= proof.enrollment.revision,
                old.sessionGeneration <= proof.sessionGeneration,
                canReplace
            else { throw refused() }
        }
        let record = Registration(
            enrollment: proof.enrollment, peer: peer, sessionGeneration: proof.sessionGeneration, issuer: proof.iss,
            proofSHA256: SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined(),
            reconciliationOnly: nil)
        try RuntimeDurableFile.write(record, to: fileURL)
        return proof.enrollment
    }

    mutating func authorizeSession(
        _ token: String, challenge: String, identity: IsolatedRuntimeIdentity, peer: RuntimeProcessBirth,
        now: Date = Date()
    ) throws -> RuntimeCoordinationEnrollmentProof {
        try consume(challenge, purpose: "session", identity: identity, peer: peer)
        let proof = try verifier.verifyEnrollment(token, identity: identity, peer: peer, challenge: challenge, now: now)
        guard let record = try read(identity: identity), record.enrollment == proof.enrollment,
            record.peer == peer, record.sessionGeneration == proof.sessionGeneration, record.reconciliationOnly != true
        else { throw refused() }
        return proof
    }

    /// Replacement of a departed coordinator for receipt reconciliation only.
    /// The controller supplies its own retained operation, never caller data.
    mutating func issueReleaseRebindingChallenge(
        identity: IsolatedRuntimeIdentity, peer: RuntimeProcessBirth,
        retained: RuntimeCoordinationRetainedReceipt,
        priorProcessExited: (RuntimeProcessBirth) throws -> Bool = { try $0.hasExited() }
    ) throws -> String {
        guard let record = try read(identity: identity), record.enrollment == retained.enrollment,
            try record.peer == peer ? record.reconciliationOnly == true : priorProcessExited(record.peer)
        else { throw refused() }
        return try issue(identity: identity, peer: peer, purpose: "release-rebind", operation: retained.operation)
    }

    mutating func rebindReleasedPeer(
        _ token: String, challenge: String, identity: IsolatedRuntimeIdentity, peer: RuntimeProcessBirth,
        retained: RuntimeCoordinationRetainedReceipt, kind: RuntimeCoordinationReleaseKind, now: Date = Date(),
        priorProcessExited: (RuntimeProcessBirth) throws -> Bool = { try $0.hasExited() }
    ) throws -> RuntimeCoordinationEnrollment {
        try consume(challenge, purpose: "release-rebind", identity: identity, peer: peer, operation: retained.operation)
        guard let old = try read(identity: identity), old.enrollment == retained.enrollment else { throw refused() }
        let observed = try verifier.verifyReleaseObservation(
            token, identity: identity, peer: peer, challenge: challenge,
            originalEnrollment: retained.enrollment, operation: retained.operation,
            resourceGeneration: retained.resourceGeneration, kind: kind, now: now)
        let replacementAllowed =
            try old.peer == peer
            ? old.reconciliationOnly == true && observed.sessionGeneration >= old.sessionGeneration
            : observed.sessionGeneration > old.sessionGeneration && priorProcessExited(old.peer)
        guard replacementAllowed else { throw refused() }
        // Keep the original enrollment. The current, possibly revoked policy
        // proves historical release only, and cannot become a data grant.
        let record = Registration(
            enrollment: old.enrollment, peer: peer, sessionGeneration: observed.sessionGeneration, issuer: old.issuer,
            proofSHA256: SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined(),
            reconciliationOnly: true)
        try RuntimeDurableFile.write(record, to: fileURL)
        return record.enrollment
    }

    private mutating func consume(
        _ nonce: String, purpose: String, identity: IsolatedRuntimeIdentity, peer: RuntimeProcessBirth,
        operation: RuntimeCoordinationOperation? = nil
    ) throws {
        guard geteuid() == ownerUID, let pending = challenges.removeValue(forKey: nonce),
            pending.deadline > uptime(), pending.peer == peer, pending.instance == identity.instance,
            pending.purpose == purpose, pending.operation == operation
        else { throw refused() }
    }
    private func refused() -> Error { MicropodError.message("The dedicated runtime coordinator is unconfirmed") }
}
