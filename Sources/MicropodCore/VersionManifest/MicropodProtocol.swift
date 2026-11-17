import Foundation

/// The contracts this build speaks, reported on Ping and GetSystem so a peer
/// can decide what to do without parsing release numbers.
public enum MicropodProtocol {
    /// Revision of the Micropod API contract (proto/micropod/v1 semantics).
    /// Bump it only when a peer must change behaviour to stay correct;
    /// additive fields never bump it.
    public static let apiVersion: UInt32 = 1

    /// Runtime coordination with a rig controller such as Cuttlefish. Version
    /// N is `RuntimeCoordinationEnrollment.capability`'s `-vN` suffix.
    public static let peerProtocolName = "micropod-runtime-coordination"
    public static let peerProtocolMinimum: UInt32 = 1
    public static let peerProtocolMaximum: UInt32 = 1

    public static var peerProtocol: Micropod_V1_ProtocolRange {
        Micropod_V1_ProtocolRange.with {
            $0.name = peerProtocolName
            $0.minVersion = peerProtocolMinimum
            $0.maxVersion = peerProtocolMaximum
        }
    }
}
