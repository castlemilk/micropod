import Foundation

/// A dry-run decision only. This type cannot invoke a lifecycle operation.
/// Current local reports do not supply the history/protection evidence needed
/// to create a candidate. Absence of evidence always blocks a recommendation.
enum CICacheRetention {
    struct Policy: Sendable {
        var minimumAttempts = 3
        var minimumCoverage: TimeInterval = 7 * 86400
        var minimumIdleAge: TimeInterval = 14 * 86400
        var maximumProtectionAge: TimeInterval = 30
    }

    struct Identity: Equatable, Sendable {
        let sourceID: String
        let volumeID: String
        let key: String
        let scope: String
        let owner: String
        let generation: String
    }

    struct Use: Sendable {
        let attemptID: String
        let observedAt: Date
        let producerSession: String
        let contentHits: UInt64?
        let contentMisses: UInt64?
    }

    struct Evidence: Sendable {
        let identity: Identity
        let createdAt: Date?
        let coverageStart: Date?
        let coverageEnd: Date?
        let historyComplete: Bool
        let observations: [Use]
        let lastAccess: Date?
        let protectionObservedAt: Date?
        let activeReferences: [String]?
        let cloneLeaseCoverageComplete: Bool
        let activeClonesOrLeases: Bool?
    }

    enum Disposition: String, Sendable { case protected, retain, insufficient, candidate }
    struct Review: Sendable {
        let identity: Identity
        let disposition: Disposition
        let reasons: [String]
        let observedAt: Date
    }

    static func review(_ evidence: Evidence, now: Date, policy: Policy = Policy()) -> Review {
        func result(_ disposition: Disposition, _ reasons: [String]) -> Review {
            Review(identity: evidence.identity, disposition: disposition, reasons: reasons, observedAt: now)
        }
        if evidence.activeReferences?.isEmpty == false || evidence.activeClonesOrLeases == true {
            return result(.protected, ["Container mount reference, clone or lease observed; retain."])
        }
        if evidence.observations.contains(where: {
            ($0.contentHits ?? 0) > 0 && $0.observedAt <= now
                && now.timeIntervalSince($0.observedAt) < policy.minimumIdleAge
        }) {
            return result(.retain, ["Recent content hit measured for this cache identity."])
        }
        var gaps: [String] = []
        if [
            evidence.identity.sourceID, evidence.identity.volumeID, evidence.identity.key,
            evidence.identity.scope, evidence.identity.owner, evidence.identity.generation,
        ].contains("") {
            gaps.append("Stable key/scope/owner/generation identity is incomplete.")
        }
        if !evidence.historyComplete {
            gaps.append("Complete per-cache access history is unavailable; the process buffer cannot prove inactivity.")
        }
        if let start = evidence.coverageStart, let end = evidence.coverageEnd,
            start <= end, end <= now, now.timeIntervalSince(end) <= policy.maximumProtectionAge,
            end.timeIntervalSince(start) >= policy.minimumCoverage
        {
            // A restart is acceptable only when the producer attests continuous
            // history; process-local counters and a new buffer cannot do so.
        } else {
            gaps.append("At least seven days of current, continuous observation are required.")
        }
        let unique = Set(evidence.observations.map(\.attemptID))
        let measured = evidence.observations.allSatisfy {
            !$0.attemptID.isEmpty && !$0.producerSession.isEmpty && $0.observedAt <= now
                && $0.contentHits != nil && $0.contentMisses != nil
                && ($0.contentHits ?? 0) == 0 && ($0.contentMisses ?? 0) > 0
        }
        // Explicit comparisons avoid interpreting proxy hits as per-store tool hits.
        let inWindow = evidence.observations.allSatisfy { sample in
            guard let start = evidence.coverageStart, let end = evidence.coverageEnd else { return false }
            return start <= sample.observedAt && sample.observedAt <= end
        }
        if unique.count < policy.minimumAttempts || unique.count != evidence.observations.count || !measured
            || !inWindow
        {
            gaps.append(
                "At least three distinct attempts with measured per-cache content misses and no hits are required.")
        }
        if let created = evidence.createdAt, let access = evidence.lastAccess,
            created <= access, access <= now,
            evidence.observations.allSatisfy({ $0.observedAt <= access }),
            now.timeIntervalSince(access) >= policy.minimumIdleAge
        {
        } else {
            gaps.append(
                "Creation and last access must establish at least fourteen idle days; image mtime is insufficient.")
        }
        if let observed = evidence.protectionObservedAt, observed <= now,
            now.timeIntervalSince(observed) <= policy.maximumProtectionAge,
            evidence.activeReferences != nil, evidence.cloneLeaseCoverageComplete,
            evidence.activeClonesOrLeases == false
        {
        } else {
            gaps.append("Fresh, complete mount/clone/lease protection is unavailable.")
        }
        guard gaps.isEmpty else { return result(.insufficient, gaps) }
        return result(
            .candidate,
            [
                "No content hits across the observation policy; last access exceeds the idle policy.",
                "Review candidate only. Unique/reclaimable bytes and time saved are unknown; approval and atomic producer revalidation remain required.",
            ])
    }

    /// Recompute against a fresh producer snapshot. Even a successful result
    /// authorizes no deletion: a future executor must hold the producer lease
    /// across its identity check and mutation to close the final race.
    static func revalidate(_ previous: Review, evidence: Evidence, now: Date, policy: Policy = Policy()) -> Review {
        guard previous.identity == evidence.identity else {
            return Review(
                identity: evidence.identity, disposition: .insufficient,
                reasons: ["Identity changed during review; discard the previous recommendation."], observedAt: now)
        }
        return review(evidence, now: now, policy: policy)
    }

    static func localReview(_ volume: CICacheVolume, inventory: CICacheInventorySnapshot, now: Date) -> Review {
        review(
            Evidence(
                identity: Identity(
                    sourceID: inventory.sourceID, volumeID: volume.id, key: volume.key,
                    scope: volume.scope, owner: volume.owner, generation: ""),
                createdAt: volume.createdAt, coverageStart: nil, coverageEnd: nil, historyComplete: false,
                observations: [], lastAccess: nil,
                protectionObservedAt: inventory.measuredAt,
                activeReferences: inventory.isStale(at: now) ? nil : volume.containerReferences,
                cloneLeaseCoverageComplete: false, activeClonesOrLeases: nil), now: now)
    }
}
