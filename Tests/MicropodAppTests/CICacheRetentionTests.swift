import Foundation
import MicropodCore
import XCTest

@testable import MicropodApp

final class CICacheRetentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let identity = CICacheRetention.Identity(
        sourceID: "rig/native", volumeID: "cf-cache-example", key: "lock-digest",
        scope: "node", owner: "rig", generation: "created-generation")

    private func evidence(
        hits: UInt64? = 0, misses: UInt64? = 4, complete: Bool = true,
        active: [String]? = [], leases: Bool? = false, protectionAge: TimeInterval = 0,
        replacement: CICacheRetention.Identity? = nil, duplicate: Bool = false, sampleAge: TimeInterval = 20 * 86400
    ) -> CICacheRetention.Evidence {
        .init(
            identity: replacement ?? identity,
            createdAt: now.addingTimeInterval(-40 * 86400),
            coverageStart: now.addingTimeInterval(-28 * 86400), coverageEnd: now,
            historyComplete: complete,
            observations: (0..<3).map {
                .init(
                    attemptID: duplicate ? "one" : "job-\($0)",
                    observedAt: now.addingTimeInterval(-sampleAge),
                    producerSession: $0 == 0 ? "before-restart" : "after-restart",
                    contentHits: hits, contentMisses: misses)
            }, lastAccess: now.addingTimeInterval(-20 * 86400),
            protectionObservedAt: now.addingTimeInterval(-protectionAge), activeReferences: active,
            cloneLeaseCoverageComplete: leases != nil, activeClonesOrLeases: leases)
    }

    func testStoppedContainerReferenceProtectsLocalCache() {
        let volume = Micropod_V1_Volume.with {
            $0.id = "cf-cache-example"
            $0.format = "ext4"
        }
        let stopped = Micropod_V1_Container.with {
            $0.id = "stopped-owner"
            $0.state = "stopped"
            $0.mounts = [.with { $0.source = volume.id }]
        }
        let inventory = CICacheInventorySnapshot(
            read: .init(volumes: [volume], containers: [stopped], truncated: false),
            sourceID: "native", measuredAt: now)
        XCTAssertEqual(inventory.volumes[0].activeContainers, [])
        XCTAssertEqual(
            CICacheRetention.localReview(inventory.volumes[0], inventory: inventory, now: now).disposition, .protected)
    }

    func testColdProvisioningOrMissingTelemetryCannotRecommendPruning() {
        let missing = CICacheRetention.review(evidence(hits: nil, misses: nil), now: now)
        XCTAssertEqual(missing.disposition, .insufficient)
        XCTAssertTrue(missing.reasons.contains { $0.contains("measured per-cache") })
        XCTAssertEqual(CICacheRetention.review(evidence(hits: 0, misses: 0), now: now).disposition, .insufficient)
    }

    func testOldMeasuredMissesWithCompleteHistoryProduceDryRunCandidateOnly() {
        let review = CICacheRetention.review(evidence(), now: now)
        XCTAssertEqual(review.disposition, .candidate)
        XCTAssertTrue(review.reasons.contains { $0.contains("approval and atomic producer revalidation") })
    }

    func testWarmRecentHitRetainsCache() {
        let base = evidence()
        let warm = CICacheRetention.Evidence(
            identity: identity, createdAt: base.createdAt, coverageStart: base.coverageStart,
            coverageEnd: now, historyComplete: true,
            observations: [
                .init(attemptID: "warm", observedAt: now, producerSession: "session", contentHits: 6, contentMisses: 2)
            ],
            lastAccess: now, protectionObservedAt: now, activeReferences: [],
            cloneLeaseCoverageComplete: true, activeClonesOrLeases: false)
        XCTAssertEqual(CICacheRetention.review(warm, now: now).disposition, .retain)
    }

    func testRestartGapDuplicateAttemptsAndUnknownLeaseCoverageBlockCandidates() {
        XCTAssertEqual(CICacheRetention.review(evidence(complete: false), now: now).disposition, .insufficient)
        XCTAssertEqual(CICacheRetention.review(evidence(duplicate: true), now: now).disposition, .insufficient)
        XCTAssertEqual(CICacheRetention.review(evidence(leases: nil), now: now).disposition, .insufficient)
        XCTAssertEqual(CICacheRetention.review(evidence(active: nil), now: now).disposition, .insufficient)
        XCTAssertEqual(CICacheRetention.review(evidence(protectionAge: 31), now: now).disposition, .insufficient)
    }

    func testRecentMeasuredAccessCannotQualifyAgainstOlderLastAccess() {
        let review = CICacheRetention.review(evidence(sampleAge: 86400), now: now)
        XCTAssertEqual(review.disposition, .insufficient)
        XCTAssertTrue(review.reasons.contains { $0.contains("last access") })
    }

    func testConcurrentMountLeaseOrIdentityChangeInvalidatesReview() {
        let candidate = CICacheRetention.review(evidence(), now: now)
        XCTAssertEqual(
            CICacheRetention.revalidate(candidate, evidence: evidence(active: ["new-job"]), now: now).disposition,
            .protected)
        XCTAssertEqual(
            CICacheRetention.revalidate(candidate, evidence: evidence(leases: true), now: now).disposition, .protected)
        let changed = CICacheRetention.Identity(
            sourceID: "rig/native", volumeID: identity.volumeID,
            key: "new-key", scope: "node", owner: "rig", generation: "new-generation")
        XCTAssertEqual(
            CICacheRetention.revalidate(candidate, evidence: evidence(replacement: changed), now: now).disposition,
            .insufficient)
    }
}
