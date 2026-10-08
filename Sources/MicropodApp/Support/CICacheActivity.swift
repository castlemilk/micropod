import Foundation
import MicropodCore

/// A projection of /cache's buffered reports. Environment and cache contents
/// are deliberately not decoded. These reports supply no rig/project or time.
struct CICacheAttemptReport: Decodable, Sendable, Identifiable {
    let attemptId: String
    let nodeId: String
    let report: Report
    var id: String { attemptId }

    struct Report: Decodable, Sendable {
        let proxy: CICacheProxyReport?
        let invalidProxy: Bool
        let stores: [CICacheStoreReport]
        let invalidStores: Bool

        private enum CodingKeys: String, CodingKey { case proxy, stores }
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            if fields.contains(.proxy), try !fields.decodeNil(forKey: .proxy) {
                proxy = try? fields.decode(CICacheProxyReport.self, forKey: .proxy)
                invalidProxy = proxy == nil
            } else {
                proxy = nil
                invalidProxy = false
            }
            if fields.contains(.stores), try !fields.decodeNil(forKey: .stores) {
                let decoded = try? fields.decode([CICacheStoreReport].self, forKey: .stores)
                invalidStores = decoded == nil || (decoded?.count ?? 0) > 32
                stores = invalidStores ? [] : decoded ?? []
            } else {
                stores = []
                invalidStores = false
            }
        }
    }
}

/// Curated mount/provisioning facts only. Lockfiles and environment are ignored.
/// The producer currently supplies no volume ID/key, content hits, or overhead.
struct CICacheStoreReport: Decodable, Sendable {
    let ecosystem: String?
    let kind: String
    let mountPath: String
    let golden: String
    let commit: String?

    private enum CodingKeys: String, CodingKey { case ecosystem, kind, mountPath, golden, commit }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        ecosystem = try fields.decodeIfPresent(String.self, forKey: .ecosystem)
        kind = try fields.decode(String.self, forKey: .kind)
        mountPath = try fields.decode(String.self, forKey: .mountPath)
        golden = try fields.decode(String.self, forKey: .golden)
        commit = try fields.decodeIfPresent(String.self, forKey: .commit)
        guard [ecosystem ?? "", kind, mountPath, golden, commit ?? ""].allSatisfy({ $0.count <= 512 })
        else { throw CICacheReadError.invalidCounters }
    }

    var provisioning: String {
        switch golden {
        case "hit": "Existing store mounted"
        case "seeded": "Store seeded from earlier lineage"
        case "cold": "Cold store provisioned"
        default: "Provisioning outcome unknown"
        }
    }

    var commitDecision: String {
        switch commit {
        case "queued": "Save queued; completion unknown"
        case "skipped-unchanged": "Save skipped: unchanged"
        case "refused-untrusted": "Save refused: untrusted"
        case "not-committed": "Not committed"
        default: "Save outcome not reported"
        }
    }
}

/// Presence of a complete report distinguishes measured zero from no report.
/// Requests - localHits is not an artifact-miss count: errors and metadata exist.
struct CICacheProxyReport: Decodable, Sendable {
    let requests: UInt64
    let localHits: UInt64
    let upstreamFetches: UInt64
    let upstreamMetadataFetches: UInt64
    let upstreamBytes: UInt64
    let servedBytes: UInt64
}

struct CICacheRuntimeIO: Sendable, Identifiable {
    let id: String
    let readBytes: UInt64?
    let writeBytes: UInt64?

    static func observations(
        inventory: CICacheInventorySnapshot, selection: CICacheSelection,
        stats: Micropod_V1_StatsSnapshot
    ) -> [Self] {
        guard inventory.referencesAvailable, !inventory.truncated else { return [] }
        let active = Set(inventory.selected(selection).flatMap { $0.activeContainers ?? [] })
        return stats.containers.filter { active.contains($0.id) }.map {
            // Older helpers omit zero-valued proto3 counters. A positive value
            // is reported; a legacy zero cannot establish a measured zero.
            let observed = $0.hasBlockIoObserved ? $0.blockIoObserved : nil
            return Self(
                id: $0.id,
                readBytes: observed == true || (observed == nil && $0.blockReadBytes > 0)
                    ? $0.blockReadBytes : nil,
                writeBytes: observed == true || (observed == nil && $0.blockWriteBytes > 0)
                    ? $0.blockWriteBytes : nil)
        }.sorted { $0.id < $1.id }
    }
}

enum CachePageRefreshLoop {
    /// View.task cancels on navigation/closure. No observer remains off-page.
    @MainActor static func run(
        refresh: @MainActor () async -> Void,
        pause: @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(15)) }
    ) async {
        while !Task.isCancelled {
            await refresh()
            guard !Task.isCancelled else { return }
            do { try await pause() } catch { return }
        }
    }
}
