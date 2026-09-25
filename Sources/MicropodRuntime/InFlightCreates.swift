import Foundation

/// Ids of the native creates in flight in this process. `createNative`
/// asks to be the sole placer for its id; only then may it reclaim a clone
/// dir left under that id (`VolumeClone.reclaimStaleCloneDir`) — a
/// concurrent create of the same id in this process may own that dir,
/// mid-placement, and is left to exclusive placement to arbitrate.
/// Process-wide, like `VolumeLocks`, so a backend hot-swap cannot reset it.
public actor InFlightCreates {
    public static let shared = InFlightCreates()

    private var ids: Set<String> = []

    public init() {}

    /// True when no create of `id` was in flight: the caller is now its
    /// sole placer and must `end(id)` when its create returns or throws.
    /// False leaves the registry as it was — the caller must not `end` it.
    public func begin(_ id: String) -> Bool {
        ids.insert(id).inserted
    }

    public func end(_ id: String) {
        ids.remove(id)
    }
}
