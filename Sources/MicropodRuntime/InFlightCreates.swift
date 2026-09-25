import Foundation

/// Per-container-id async mutex around a native create. `createNative`
/// runs its whole body — list check, orphan sweep, stale-dir reclaim,
/// clone placement, `containerCreate` and the failure cleanup — inside
/// ``withExclusive(_:_:)``, so creates of the same id in this process never
/// overlap: a create is the *sole placer* under `<cloneRoot>/<id>` for its
/// whole duration, which is what lets it reclaim a stale clone dir there
/// (`VolumeClone.reclaimStaleCloneDir`) without unlinking a concurrent
/// replay's clones. A replay of the same id waits for the winner: if the
/// winner succeeded, the replay's list check answers `already_exists` and
/// it never places or reclaims; if it failed, the replay proceeds as a
/// genuine sole create over a dir the loser already cleaned.
///
/// Same discipline as `VolumeLocks`: waiters are served in FIFO order and
/// the id is released whether the body returns or throws. Process-wide,
/// like `VolumeLocks`, so a backend hot-swap cannot reset it.
public actor InFlightCreates {
    public static let shared = InFlightCreates()

    private var held: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    /// Runs `body` as the only create of `id` in this process. The body
    /// must not call `withExclusive` for the same id: the mutex is not
    /// reentrant.
    public nonisolated func withExclusive<T>(_ id: String, _ body: () async throws -> T) async rethrows -> T {
        await acquire(id)
        do {
            let value = try await body()
            await release(id)
            return value
        } catch {
            await release(id)
            throw error
        }
    }

    private func acquire(_ id: String) async {
        if held.insert(id).inserted { return }
        await withCheckedContinuation { continuation in
            waiters[id, default: []].append(continuation)
        }
    }

    private func release(_ id: String) {
        if var queue = waiters[id], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[id] = queue.isEmpty ? nil : queue
            // Ownership passes straight to the next waiter; `held` stays set.
            next.resume()
        } else {
            waiters[id] = nil
            held.remove(id)
        }
    }
}
