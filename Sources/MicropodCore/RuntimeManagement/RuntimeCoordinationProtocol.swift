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
    /// Only on `runtime-inspect` with purpose `attestation`
    /// (``RuntimeHelperAttestation/purpose``); absent (not null) otherwise,
    /// so a coordinator that decodes replies strictly sees exactly what it
    /// saw before it asked.
    public let attestation: RuntimeHelperAttestation?
    public init(
        identity: IsolatedRuntimeIdentity, peer: RuntimeProcessBirth, challenge: String? = nil,
        enrollment: RuntimeCoordinationEnrollment? = nil, session: IsolatedRuntimeAPISession? = nil,
        coverage: RuntimeCoordinationCoverage? = nil, attestation: RuntimeHelperAttestation? = nil
    ) {
        schemaVersion = RuntimeCoordinationEnrollment.capability
        scope = RuntimeCoordinationEnrollment.runtimeScope
        self.identity = identity
        self.peer = peer
        self.challenge = challenge
        self.enrollment = enrollment
        self.session = session
        self.coverage = coverage
        self.attestation = attestation
    }
}

/// How the answering root helper is installed, checked when the coordinator
/// asks (`runtime-inspect` with purpose ``purpose``), never from a cache:
/// the same checks `status` reports as `componentProtection`, run for this
/// reply at `checkedAt`. Every string is bounded (``maximumBytes``); a value
/// that would exceed its bound is cut at a character boundary.
public struct RuntimeHelperAttestation: Codable, Sendable, Equatable {
    /// The `runtime-inspect` purpose that asks for an attestation.
    public static let purpose = "attestation"

    /// The legacy SMAppService job (`com.skunkworq.micropod.runtime.host`).
    public enum LegacyJob: String, Codable, Sendable, CaseIterable {
        /// Not loaded and persistently disabled.
        case retired
        /// Loaded in launchd now.
        case loaded
        /// Not loaded, but not disabled: launchd may load it again.
        case enabled
        /// Its state could not be read.
        case unknown
    }

    /// UTF-8 byte bounds per field.
    public static let maximumBytes: [String: Int] = [
        "helperIdentifier": 128, "helperVersion": 64, "helperService": 128, "componentProtection": 512,
        "authorityDefinitionSHA256": 64, "nativeState": 64, "checkedAt": 40,
    ]

    /// The helper's signing identifier (it verified itself at start).
    public let helperIdentifier: String
    /// The helper's compiled-in release.
    public let helperVersion: String
    /// The runtime component protocol it implements; 0 when it cannot
    /// update its own components.
    public let componentProtocol: Int
    /// The Mach service it listens on: the authority's, or the legacy job's.
    public let helperService: String
    /// `protected`, or `unprotected: <reason>`; on a VM release gate with a
    /// fault armed, either is followed by `; release-gate fault armed`.
    public let componentProtection: String
    /// The LaunchDaemon definition this helper expects (lowercase hex).
    public let authorityDefinitionSHA256: String
    /// The job running this helper is the root-owned authority, from a plist
    /// that is exactly that definition, SpawnConstraint included.
    public let spawnConstraint: Bool
    /// The bundle this helper runs from is a sealed root-owned copy.
    public let installSealed: Bool
    /// The managed Apple runtime's last observed state, if any.
    public let nativeState: String?
    public let legacyJob: LegacyJob
    /// When these checks ran: RFC 3339, UTC, with fractional seconds.
    public let checkedAt: String

    public init(
        helperIdentifier: String, helperVersion: String, componentProtocol: Int, helperService: String,
        componentProtection: String, authorityDefinitionSHA256: String, spawnConstraint: Bool,
        installSealed: Bool, nativeState: String?, legacyJob: LegacyJob, checkedAt: Date
    ) {
        func bound(_ value: String, _ field: String) -> String {
            Self.truncated(value, toBytes: Self.maximumBytes[field] ?? 0)
        }
        self.helperIdentifier = bound(helperIdentifier, "helperIdentifier")
        self.helperVersion = bound(helperVersion, "helperVersion")
        self.componentProtocol = componentProtocol
        self.helperService = bound(helperService, "helperService")
        self.componentProtection = bound(componentProtection, "componentProtection")
        self.authorityDefinitionSHA256 = bound(authorityDefinitionSHA256, "authorityDefinitionSHA256")
        self.spawnConstraint = spawnConstraint
        self.installSealed = installSealed
        self.nativeState = nativeState.map { bound($0, "nativeState") }
        self.legacyJob = legacyJob
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        self.checkedAt = bound(formatter.string(from: checkedAt), "checkedAt")
    }

    static func truncated(_ value: String, toBytes limit: Int) -> String {
        guard value.utf8.count > limit else { return value }
        var result = ""
        for character in value {
            guard result.utf8.count + String(character).utf8.count <= limit else { break }
            result.append(character)
        }
        return result
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
