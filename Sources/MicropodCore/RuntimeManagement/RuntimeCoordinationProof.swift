import Foundation
import Security

/// This resource is deliberately distinct from physical-host maintenance.
/// A verified enrollment still needs a helper-issued one-use challenge and
/// protected registration before it can authorize any private API session.
public struct RuntimeCoordinationEnrollment: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public let scope: String
    public let resourceId: String
    public let organizationId: String
    public let runnerId: String
    public let revision: Int64
    public let enabled: Bool
    public let binding: RuntimeCoordinationBinding

    public static let capability = "micropod-runtime-coordination-v1"
    public static let runtimeScope = "micropod-dedicated-runtime"

    public func validate(identity: IsolatedRuntimeIdentity) throws {
        try validateMetadata(identity: identity)
        guard enabled else { throw RuntimeCoordinationProofVerifier.refused() }
    }

    fileprivate func validateMetadata(identity: IsolatedRuntimeIdentity) throws {
        try identity.validate()
        let resourceUUID = String(resourceId.dropFirst(4))
        guard schemaVersion == Self.capability, scope == Self.runtimeScope,
            resourceId.hasPrefix("mrt-"), let resource = UUID(uuidString: resourceUUID),
            resource != UUID.zero, resourceId == "mrt-" + resource.uuidString.lowercased(),
            !organizationId.isEmpty, organizationId.utf8.count <= 256,
            !runnerId.isEmpty, runnerId.utf8.count <= 256, revision > 0,
            binding.matches(identity)
        else { throw RuntimeCoordinationProofVerifier.refused() }
    }
}

public struct RuntimeCoordinationBinding: Codable, Sendable, Equatable {
    public let instance: String
    public let hostKey: String
    public let ownerUID: UInt32
    public let serviceUID: UInt32
    public let serviceGID: UInt32
    public let accountGUID: String
    public let groupGUID: String

    func matches(_ identity: IsolatedRuntimeIdentity) -> Bool {
        // hostKey is signed control-plane metadata, never physical-host
        // authority. All local account fields come from protected identity.
        instance == identity.instance.uuidString && identity.instance != UUID.zero
            && ownerUID == identity.ownerUID && serviceUID == identity.serviceUID && serviceGID == identity.serviceGID
            && accountGUID == identity.accountGUID.uuidString && identity.accountGUID != UUID.zero
            && groupGUID == identity.groupGUID.uuidString && identity.groupGUID != UUID.zero
            && RuntimeCoordinationProofVerifier.validChallenge(hostKey)
    }
}

public struct RuntimeCoordinationEnrollmentProof: Codable, Sendable, Equatable {
    public let iss: String
    public let aud: String
    public let sub: String
    public let iat: Int64
    public let nbf: Int64
    public let exp: Int64
    public let jti: String
    public let schemaVersion: String
    public let purpose: String
    public let scope: String
    public let enrollment: RuntimeCoordinationEnrollment
    public let peer: RuntimeProcessBirth
    public let sessionGeneration: Int64
    public let challenge: String
    public let state: RuntimeCoordinationState?
}

public struct RuntimeCoordinationOperation: Codable, Sendable, Equatable {
    public let id: String
    public let runtimeInstance: String
    public let action: String
    public let localGeneration: Int64
    public let version: String
    public let packageSHA256: String
    public let installRoot: String
    public let targetState: String

    public init(
        operation: UUID, identity: IsolatedRuntimeIdentity, action: String, localGeneration: Int64,
        selection: ManagedRuntimeLocation.Selection
    ) throws {
        try identity.validate()
        guard operation != UUID.zero, localGeneration > 0, ["start", "stop", "restart", "install"].contains(action),
            selection.isSupported
        else {
            throw RuntimeCoordinationProofVerifier.refused()
        }
        id = operation.uuidString.lowercased()
        runtimeInstance = identity.instance.uuidString
        self.action = action
        self.localGeneration = localGeneration
        version = selection.version
        packageSHA256 = selection.packageSHA256
        installRoot =
            IsolatedRuntimePolicy.root.appendingPathComponent("apple/versions/" + selection.directoryName).path
        targetState = action == "stop" ? "stopped" : "running"
    }
}

public struct RuntimeCoordinationState: Codable, Sendable, Equatable {
    public let scope: String
    public let resourceId: String
    public let revision: Int64
    public let owner: String
    public let generation: Int64
    public let closed: Bool
    public let lastReleasedOwner: String
    public let lastReleasedGeneration: Int64
    public let lastReleasedRevision: Int64
    public let lastReleasedKind: String
    public let operation: RuntimeCoordinationOperation
    // Empty operations are represented as JSON objects with zero-valued fields
    // by the control plane. This history is audit data, never a new action.
    public let lastReleasedOperation: RuntimeCoordinationOperation
}

public enum RuntimeCoordinationReleaseKind: String, Codable, Sendable {
    case running, stopped, cancelled
}

/// An observation can settle only the exact already completed operation.
/// It is never an enrollment, API capability or permission for another action.
public struct RuntimeCoordinationReleaseObservation: Sendable {
    public let enrollment: RuntimeCoordinationEnrollment
    public let state: RuntimeCoordinationState
}

/// No network key discovery or caller-supplied trust. The public initializer
/// accepts only the release-pinned production issuer. Tests can inject a key
/// through the internal initializer without exposing that choice over IPC.
public struct RuntimeCoordinationProofVerifier: Sendable {
    private let issuer: String
    private let keyID: String
    private let publicKeyDER: Data

    public init() {
        issuer = "https://api.cuttlefish.sh"
        keyID = "Eql_1R52CCg"
        // RSA PKCS#1 public key, independently checked against the issuer's
        // public JWKS on 2026-11-14. SPKI SHA256:
        // 12a97fd51e760828f95c0f9b89aa121ba0dbce380ba4d1c6e51b600ac6538418
        publicKeyDER = Data(
            base64Encoded:
                "MIIBCgKCAQEAnzyEVFraftQQpyAQRHQjkEnneNmM/n7SszB44Yy/HRJS3WMGnOjg36EXMsGY3l95gQXVrP2E5PHG/deyTHtcRSq7xSdxgNJI38n5PBnNzQHbu0WaofX3cryzBVTg4Nc9udNh57YyNns82FGv1iXYK6FIdTlBDun2py71kBCyDMd4KJa/jgZNnn7difqNVtJrVT5sNYf1mZTReedrUdjcax6t1hm4aqWSAddeXG++kMT5aqqJyluo+2J0jmi4qEK/PNC8jSF/IhPZLQxqPr9aYUQkbwcsjobFncKzT/zyWrAn6gFbinWHepCOQDAzX4CqrbopiRlFFgk74lJg06OYbQIDAQAB"
        )!
    }

    init(issuer: String, keyID: String, publicKeyDER: Data) {
        self.issuer = issuer
        self.keyID = keyID
        self.publicKeyDER = publicKeyDER
    }

    public func verifyEnrollment(
        _ token: String, identity: IsolatedRuntimeIdentity, peer: RuntimeProcessBirth,
        challenge: String, now: Date = Date()
    ) throws -> RuntimeCoordinationEnrollmentProof {
        let proof = try verifyProof(
            token, identity: identity, peer: peer, challenge: challenge, purpose: "enrollment", now: now)
        guard proof.state == nil else { throw Self.refused() }
        return proof
    }

    public func verifyMaintenance(
        _ token: String, identity: IsolatedRuntimeIdentity, peer: RuntimeProcessBirth, challenge: String,
        enrollment: RuntimeCoordinationEnrollment, sessionGeneration: Int64,
        operation: RuntimeCoordinationOperation, resourceGeneration: Int64, now: Date = Date()
    ) throws -> RuntimeCoordinationEnrollmentProof {
        try operation.validateLocal(identity: identity)
        let proof = try verifyProof(
            token, identity: identity, peer: peer, challenge: challenge, purpose: "maintenance", now: now)
        guard proof.enrollment == enrollment, proof.sessionGeneration == sessionGeneration,
            let state = proof.state, state.scope == enrollment.scope, state.resourceId == enrollment.resourceId,
            state.revision == enrollment.revision, state.closed, state.owner == operation.id,
            state.operation == operation, state.generation > 0, state.generation == resourceGeneration
        else { throw Self.refused() }
        return proof
    }

    public func verifyReleaseObservation(
        _ token: String, identity: IsolatedRuntimeIdentity, peer: RuntimeProcessBirth, challenge: String,
        originalEnrollment: RuntimeCoordinationEnrollment, operation: RuntimeCoordinationOperation,
        resourceGeneration: Int64, kind: RuntimeCoordinationReleaseKind, now: Date = Date()
    ) throws -> RuntimeCoordinationReleaseObservation {
        try originalEnrollment.validate(identity: identity)
        try operation.validateLocal(identity: identity)
        let proof = try verifyProof(
            token, identity: identity, peer: peer, challenge: challenge, purpose: "release-observation", now: now)
        let current = proof.enrollment
        guard current.organizationId == originalEnrollment.organizationId,
            current.runnerId == originalEnrollment.runnerId, current.resourceId == originalEnrollment.resourceId,
            current.binding == originalEnrollment.binding, current.revision >= originalEnrollment.revision,
            let state = proof.state, state.scope == current.scope, state.resourceId == current.resourceId,
            state.revision == current.revision, state.owner.isEmpty, state.operation.isEmpty,
            resourceGeneration > 0, resourceGeneration < Int64.max, state.generation == resourceGeneration + 1,
            state.lastReleasedOwner == operation.id, state.lastReleasedOperation == operation,
            state.lastReleasedGeneration == resourceGeneration,
            state.lastReleasedRevision == originalEnrollment.revision, state.lastReleasedKind == kind.rawValue,
            kind == .cancelled || kind.rawValue == operation.targetState,
            state.closed || (current.enabled && kind == .running)
        else { throw Self.refused() }
        return RuntimeCoordinationReleaseObservation(enrollment: current, state: state)
    }

    private func verifyProof(
        _ token: String, identity: IsolatedRuntimeIdentity, peer: RuntimeProcessBirth,
        challenge: String, purpose: String, now: Date
    ) throws -> RuntimeCoordinationEnrollmentProof {
        guard token.utf8.count <= 16384, Self.validChallenge(challenge) else { throw Self.refused() }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw Self.refused() }
        let headerData = try Self.decode(parts[0])
        let payload = try Self.decode(parts[1])
        let signature = try Self.decode(parts[2])
        struct Header: Decodable {
            let alg: String
            let typ: String
            let kid: String
        }
        let header = try JSONDecoder().decode(Header.self, from: headerData)
        guard header.alg == "RS256", header.typ == "micropod-runtime-proof+jwt", header.kid == keyID else {
            throw Self.refused()
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        guard let key = SecKeyCreateWithData(publicKeyDER as CFData, attributes as CFDictionary, nil),
            SecKeyGetBlockSize(key) >= 256,
            SecKeyIsAlgorithmSupported(key, .verify, .rsaSignatureMessagePKCS1v15SHA256),
            SecKeyVerifySignature(
                key, .rsaSignatureMessagePKCS1v15SHA256,
                Data((String(parts[0]) + "." + String(parts[1])).utf8) as CFData, signature as CFData, nil)
        else { throw Self.refused() }

        let proof = try JSONDecoder().decode(RuntimeCoordinationEnrollmentProof.self, from: payload)
        let seconds = now.timeIntervalSince1970
        guard proof.iss == issuer, proof.aud == "micropod-runtime-coordination",
            proof.schemaVersion == "micropod-runtime-proof-v1", proof.purpose == purpose,
            proof.scope == RuntimeCoordinationEnrollment.runtimeScope,
            proof.sub == "runner:" + proof.enrollment.runnerId,
            proof.iat > 0, proof.iat <= Int64.max - 120,
            proof.nbf == proof.iat - 5, proof.exp == proof.iat + 120,
            seconds >= Double(proof.nbf), seconds < Double(proof.exp),
            !proof.jti.isEmpty, proof.jti.utf8.count <= 128,
            proof.sessionGeneration > 0, proof.challenge == challenge, proof.peer == peer,
            peer.uid == identity.ownerUID, peer.pid > 0, peer.seconds > 0,
            (0..<1_000_000).contains(peer.microseconds),
            let boot = UUID(uuidString: peer.bootSession), boot != UUID.zero,
            peer.bootSession == boot.uuidString
        else { throw Self.refused() }
        if purpose == "release-observation" {
            try proof.enrollment.validateMetadata(identity: identity)
        } else {
            try proof.enrollment.validate(identity: identity)
        }
        return proof
    }

    static func validChallenge(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func decode(_ value: Substring) throws -> Data {
        guard !value.isEmpty,
            value.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 95].contains($0)
            })
        else { throw refused() }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
        guard let bytes = Data(base64Encoded: base64),
            bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == value
        else { throw refused() }
        return bytes
    }

    static func refused() -> Error { MicropodError.message("The dedicated runtime approval proof is unconfirmed") }
}

extension RuntimeCoordinationOperation {
    func validateLocal(identity: IsolatedRuntimeIdentity) throws {
        let prefix = IsolatedRuntimePolicy.root.appendingPathComponent(
            "apple/versions/" + version + "-" + packageSHA256
        ).path
        guard let identifier = UUID(uuidString: id), identifier != UUID.zero,
            id == identifier.uuidString.lowercased(), runtimeInstance == identity.instance.uuidString,
            localGeneration > 0, ["start", "stop", "restart", "install"].contains(action),
            targetState == (action == "stop" ? "stopped" : "running"),
            version == AppleRuntimeRelease.supported.version,
            packageSHA256 == AppleRuntimeRelease.supported.packageSHA256
        else { throw RuntimeCoordinationProofVerifier.refused() }
        if installRoot != prefix {
            guard installRoot.hasPrefix(prefix + "-"),
                let incarnation = UUID(uuidString: String(installRoot.dropFirst(prefix.count + 1))),
                incarnation != UUID.zero, installRoot == prefix + "-" + incarnation.uuidString
            else { throw RuntimeCoordinationProofVerifier.refused() }
        }
    }

    var isEmpty: Bool {
        id.isEmpty && runtimeInstance.isEmpty && action.isEmpty && localGeneration == 0 && version.isEmpty
            && packageSHA256.isEmpty && installRoot.isEmpty && targetState.isEmpty
    }
}

private extension UUID {
    static let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}
