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
    }
    private struct Challenge {
        let peer: RuntimeProcessBirth
        let instance: UUID
        let purpose: String
        let deadline: UInt64
    }
    static var fileURL: URL { IsolatedRuntimePolicy.root.appendingPathComponent("runtime-coordinator.json") }
    private let fileURL: URL
    private let ownerUID: UInt32
    private let verifier: RuntimeCoordinationProofVerifier
    private let uptime: () -> UInt64
    private var challenges: [String: Challenge] = [:]

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
        guard geteuid() == ownerUID, peer.uid == identity.ownerUID,
            ["enrollment", "session"].contains(purpose)
        else { throw refused() }
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
            peer: peer, instance: identity.instance, purpose: purpose, deadline: now + 120_000_000_000)
        return nonce
    }

    mutating func enroll(
        _ token: String, challenge: String, identity: IsolatedRuntimeIdentity, peer: RuntimeProcessBirth,
        now: Date = Date(), priorProcessExited: (RuntimeProcessBirth) throws -> Bool = { try $0.hasExited() }
    ) throws -> RuntimeCoordinationEnrollment {
        try consume(challenge, purpose: "enrollment", identity: identity, peer: peer)
        let proof = try verifier.verifyEnrollment(token, identity: identity, peer: peer, challenge: challenge, now: now)
        if let old = try read(identity: identity) {
            let sameProcessSession = old.peer == peer && old.sessionGeneration == proof.sessionGeneration
            let canReplace = try sameProcessSession || priorProcessExited(old.peer)
            guard old.enrollment.resourceId == proof.enrollment.resourceId,
                old.enrollment.organizationId == proof.enrollment.organizationId,
                old.enrollment.runnerId == proof.enrollment.runnerId,
                old.enrollment.binding == proof.enrollment.binding,
                old.enrollment.revision <= proof.enrollment.revision,
                canReplace
            else { throw refused() }
        }
        let record = Registration(
            enrollment: proof.enrollment, peer: peer, sessionGeneration: proof.sessionGeneration, issuer: proof.iss,
            proofSHA256: SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined())
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
            record.peer == peer, record.sessionGeneration == proof.sessionGeneration
        else { throw refused() }
        return proof
    }

    private mutating func consume(
        _ nonce: String, purpose: String, identity: IsolatedRuntimeIdentity, peer: RuntimeProcessBirth
    ) throws {
        guard geteuid() == ownerUID, let pending = challenges.removeValue(forKey: nonce),
            pending.deadline > uptime(), pending.peer == peer, pending.instance == identity.instance,
            pending.purpose == purpose
        else { throw refused() }
    }
    private func refused() -> Error { MicropodError.message("The dedicated runtime coordinator is unconfirmed") }
}
