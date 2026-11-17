import Foundation

/// The exact drain a rig upgrade asks Cuttlefish for. Pinned in the journal
/// and sent unchanged on every call, so every drain, heartbeat and release
/// names the same operation.
public struct RigDrainSpec: Codable, Equatable, Hashable, Sendable {
    /// The `kind` Cuttlefish accepts for a drain that touches no runtime.
    public static let rigUpgradeKind = "rig-upgrade"
    public let operation: UUID
    public let kind: String
    public let createdAt: Date

    public init(operation: UUID, kind: String = Self.rigUpgradeKind, createdAt: Date) {
        self.operation = operation
        self.kind = kind
        self.createdAt = createdAt
    }
}

/// What Cuttlefish said to one drain call.
public struct RigDrainReply: Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// The rig holds new work and waits for (or preempts) what runs.
        case draining
        /// No work is in flight.
        case drained
        /// Cuttlefish answered and declined, with a reason.
        case refused
        /// The coordinator closed without an answer, or answered something
        /// this build does not understand: an older Cuttlefish that does
        /// not know rig-upgrade drains.
        case incompatible
        /// No request reached a coordinator.
        case unavailable
    }
    public let state: State
    public let reason: String?
    public init(_ state: State, reason: String? = nil) {
        self.state = state
        self.reason = reason
    }
}

public enum RigDrainRelease: Sendable, Equatable {
    /// Cuttlefish confirmed the drain is over.
    case released
    /// The coordinator holds nothing for this operation.
    case notHeld
}

/// The rig controller (Cuttlefish) on the maintenance socket.
public protocol RigDrainCoordinating: Sendable {
    /// Whether this host has a rig controller to ask at all.
    func isConfigured() -> Bool
    /// Asks the rig to take no new work; repeated until it reports drained,
    /// then as a heartbeat while services are down.
    func drain(_ spec: RigDrainSpec) async -> RigDrainReply
    /// Lets the rig take work again. Throws when the outcome is unknown.
    func release(_ spec: RigDrainSpec) async throws -> RigDrainRelease
}

/// Drains that may still hold the rig. Kept apart from the journal, so a new
/// upgrade that replaces the journal still releases an older one.
public struct RigDrainLedger: Sendable {
    /// Entries older than this are dropped: Cuttlefish lets go of a drain
    /// with no heartbeat for two minutes.
    public static let retention: TimeInterval = 7 * 86400
    public let url: URL
    public init(layout: RigUpgradeLayout) { url = layout.root.appendingPathComponent("unreleased-drains.json") }

    public func entries() -> [RigDrainSpec] {
        guard let data = try? RuntimeDurableFile.read(url, maximumBytes: 1 << 16) else { return [] }
        return (try? JSONDecoder().decode([RigDrainSpec].self, from: data)) ?? []
    }

    public func add(_ spec: RigDrainSpec) throws {
        var all = entries()
        guard !all.contains(spec) else { return }
        all.append(spec)
        try RuntimeDurableFile.write(all, to: url)
    }

    public func remove(_ spec: RigDrainSpec) throws {
        let all = entries()
        guard all.contains(spec) else { return }
        try RuntimeDurableFile.write(all.filter { $0 != spec }, to: url)
    }
}

/// Cuttlefish's maintenance socket, for rig-upgrade drains:
///
///     → {"action":"drain"|"abort"|"abortComplete","kind":"rig-upgrade","operation":"<uuid>"}
///     ← {"operation":"<uuid>","phase":"draining"|"drained"|"refused"|"aborting"|"cancelled","reason":…}
///
/// Cuttlefish holds new leases and preempts attempts still running after its
/// grace (`min(CUTTLE_MAINTENANCE_GRACE, 60 s)`); `abort` then
/// `abortComplete` release the hold; with no heartbeat for two minutes it
/// releases the hold itself. A rig-upgrade drain carries no runtime install
/// root, version or package digest, and no admission fence is involved.
/// An older Cuttlefish closes the connection on the unknown `kind`: that is
/// `incompatible`, never `draining`.
public struct RigCuttlefishDrain: RigDrainCoordinating {
    public typealias Exchange = @Sendable (Data) async throws -> Data
    public let home: URL
    let exchange: Exchange

    public init(home: URL, exchange: Exchange? = nil) {
        self.home = home
        let path = home.appendingPathComponent(".cuttlefish/runner-state/micropod-maintenance.sock").path
        self.exchange =
            exchange ?? { request in
                try await RuntimePeerSocket.exchange(path: path, request: request)
            }
    }

    public func isConfigured() -> Bool { RuntimeRigClient.hasConfiguredRig(ownerHome: home) }

    /// The request line for `action`.
    public static func request(_ spec: RigDrainSpec, action: String) throws -> Data {
        let fields = ["action": action, "kind": spec.kind, "operation": spec.operation.uuidString.lowercased()]
        return try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) + Data([10])
    }

    struct Reply: Decodable {
        let operation: String
        let phase: String
        let reason: String?
    }

    /// Decodes a reply to `spec`; nil when it is not one this build understands.
    static func decode(_ bytes: Data, spec: RigDrainSpec) -> Reply? {
        guard let reply = try? JSONDecoder().decode(Reply.self, from: bytes),
            reply.operation.lowercased() == spec.operation.uuidString.lowercased(),
            (reply.reason?.utf8.count ?? 0) <= 1024
        else { return nil }
        return reply
    }

    private func call(_ spec: RigDrainSpec, _ action: String) async -> (Reply?, RigDrainReply?) {
        let bytes: Data
        do {
            bytes = try await exchange(try Self.request(spec, action: action))
        } catch let error as RuntimeRigAdmissionError {
            return (nil, RigDrainReply(.unavailable, reason: error.localizedDescription))
        } catch is RuntimePeerNoReply {
            return (
                nil,
                RigDrainReply(
                    .incompatible,
                    reason: "Cuttlefish closed the connection without answering; it does not accept rig-upgrade "
                        + "drains (update the Cuttlefish agent)")
            )
        } catch {
            return (
                nil, RigDrainReply(.incompatible, reason: "Cuttlefish did not answer: \(error.localizedDescription)")
            )
        }
        guard let reply = Self.decode(bytes, spec: spec) else {
            return (
                nil,
                RigDrainReply(
                    .incompatible,
                    reason: "Cuttlefish's answer is not a rig-upgrade drain reply: "
                        + String(decoding: bytes.prefix(200), as: UTF8.self))
            )
        }
        return (reply, nil)
    }

    public func drain(_ spec: RigDrainSpec) async -> RigDrainReply {
        let (reply, failure) = await call(spec, "drain")
        if let failure { return failure }
        guard let reply else { return RigDrainReply(.incompatible) }
        switch reply.phase {
        case "draining": return RigDrainReply(.draining, reason: reply.reason)
        case "drained": return RigDrainReply(.drained, reason: reply.reason)
        case "refused", "blocked": return RigDrainReply(.refused, reason: reply.reason ?? "no reason given")
        default: return RigDrainReply(.incompatible, reason: "Cuttlefish answered phase '\(reply.phase)' to a drain")
        }
    }

    public func release(_ spec: RigDrainSpec) async throws -> RigDrainRelease {
        for action in ["abort", "abortComplete"] {
            let (reply, failure) = await call(spec, action)
            if let failure {
                // An older coordinator rejects every rig-upgrade call, so it
                // never held this one.
                if failure.state == .incompatible, action == "abort" { return .notHeld }
                throw MicropodError.message(
                    "Cuttlefish's drain release is unconfirmed (\(failure.reason ?? failure.state.rawValue))")
            }
            guard let reply else { continue }
            switch (action, reply.phase) {
            case ("abort", "aborting"), ("abort", "cancelled"): continue
            case ("abortComplete", "cancelled"): return .released
            case (_, "refused") where reply.reason?.localizedCaseInsensitiveContains("unknown") == true:
                return .notHeld
            default:
                throw MicropodError.message(
                    "Cuttlefish answered '\(reply.phase)' to \(action)\(reply.reason.map { ": \($0)" } ?? "")")
            }
        }
        throw MicropodError.message("Cuttlefish did not confirm the release")
    }
}
