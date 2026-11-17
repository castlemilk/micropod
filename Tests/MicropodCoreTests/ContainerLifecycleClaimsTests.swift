import XCTest

@testable import MicropodCore

final class ContainerLifecycleClaimsTests: XCTestCase {
    func testCleanupIsNonblockingForOtherInFlightIDs() async throws {
        let claims = ContainerLifecycleClaims()
        let firstValue = await claims.claimIfIdle("a", kind: .creating)
        let secondValue = await claims.claimIfIdle("b", kind: .creating)
        let first = try XCTUnwrap(firstValue), second = try XCTUnwrap(secondValue)
        let epoch = await claims.creationEpoch()
        let cleanedA = await claims.withCleanupIfIdle("a", observedBefore: epoch) { XCTFail("active clone removed") }
        let cleanedB = await claims.withCleanupIfIdle("b", observedBefore: epoch) { XCTFail("active clone removed") }
        XCTAssertFalse(cleanedA)
        XCTAssertFalse(cleanedB)
        let other = await claims.withCleanupIfIdle("orphan", observedBefore: epoch) {}
        XCTAssertTrue(other)
        await claims.finish(first)
        await claims.finish(second)
    }

    func testOldGenerationCannotReleaseNewOwnership() async throws {
        let claims = ContainerLifecycleClaims()
        let firstValue = await claims.claimIfIdle("same", kind: .cleanup)
        let first = try XCTUnwrap(firstValue)
        await claims.finish(first)
        let nextValue = await claims.claimIfIdle("same", kind: .starting)
        let next = try XCTUnwrap(nextValue)
        let revision = await claims.revision()
        await claims.finish(first)
        let retained = await claims.kind(of: "same")
        let afterStaleFinish = await claims.revision()
        XCTAssertEqual(retained, .starting)
        XCTAssertEqual(afterStaleFinish, revision, "stale finish must not invalidate a current snapshot")
        await claims.finish(next)
    }

    func testCreateFailureAlwaysReleasesItsOwnGeneration() async throws {
        let claims = ContainerLifecycleClaims()
        let failures: [any Error] = [MicropodError.transport("read failed"), CancellationError()]
        for failure in failures {
            do {
                try await claims.withExclusive("failed") { throw failure }
                XCTFail("body failure must propagate")
            } catch {}
            let retained = await claims.kind(of: "failed")
            XCTAssertNil(retained, "create errors must not permanently strand ownership")
            let ran = try await claims.withExclusive("failed") { true }
            XCTAssertTrue(ran)
        }
    }

    func testRevisionsTrackEveryClaimButCreationEpochOnlyTracksCreates() async throws {
        let claims = ContainerLifecycleClaims()
        for kind in [ContainerLifecycleClaims.Kind.starting, .deleting, .cleanup] {
            let before = await claims.revision()
            let claimed = await claims.claimIfIdle("id", kind: kind)
            let claim = try XCTUnwrap(claimed)
            let active = await claims.revision()
            XCTAssertEqual(active, before + 1)
            await claims.finish(claim)
            let after = await claims.revision()
            let epoch = await claims.creationEpoch()
            XCTAssertEqual(after, before + 2)
            XCTAssertEqual(epoch, 0)
        }
        let claimed = await claims.claimIfIdle("create", kind: .creating)
        let claim = try XCTUnwrap(claimed)
        let activeEpoch = await claims.creationEpoch()
        XCTAssertEqual(activeEpoch, 1)
        await claims.finish(claim)
        let finishedEpoch = await claims.creationEpoch()
        let revision = await claims.revision()
        XCTAssertEqual(finishedEpoch, 2)
        XCTAssertEqual(revision, 8)
    }

    func testCleanupRejectsCompletedCreateSinceSnapshot() async throws {
        let claims = ContainerLifecycleClaims()
        let observedBefore = await claims.creationEpoch()
        let claimed = await claims.claimIfIdle("now-live", kind: .creating)
        let claim = try XCTUnwrap(claimed)
        await claims.finish(claim)
        let cleaned = await claims.withCleanupIfIdle("now-live", observedBefore: observedBefore) {
            XCTFail("a stale empty list removed a completed create")
        }
        XCTAssertFalse(cleaned, "idle ownership alone cannot validate a stale live list")
        let refreshed = await claims.creationEpoch()
        let genuineOrphan = await claims.withCleanupIfIdle("orphan", observedBefore: refreshed) {}
        XCTAssertTrue(genuineOrphan)
    }

    func testQueuedCreateCancellationReturnsBeforeHolderFinishes() async throws {
        let claims = ContainerLifecycleClaims()
        let claimed = await claims.claimIfIdle("queued", kind: .creating)
        let holder = try XCTUnwrap(claimed)
        let completed = expectation(description: "cancelled queue entry returns")
        let caller = Task {
            defer { completed.fulfill() }
            try await claims.withExclusive("queued") { XCTFail("cancelled create body ran") }
        }
        await waitUntilQueued(claims, id: "queued")
        caller.cancel()
        await fulfillment(of: [completed], timeout: 2)
        let pending = await claims.queuedCount(for: "queued")
        let kind = await claims.kind(of: "queued")
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(kind, .creating, "waiter cancellation must not release the holder")
        // Release even after an assertion failure so a regression cannot
        // leave the test's suspended continuation behind.
        await claims.finish(holder)
        do {
            try await caller.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        let idle = await claims.kind(of: "queued")
        XCTAssertNil(idle)
    }

    func testCancellationRacingOwnershipHandoffNeverRunsCreateBody() async throws {
        let claims = ContainerLifecycleClaims()
        let claimed = await claims.claimIfIdle("handoff", kind: .creating)
        let holder = try XCTUnwrap(claimed)
        let caller = Task {
            try await claims.withExclusive("handoff") { XCTFail("cancelled handoff dispatched a create") }
        }
        await waitUntilQueued(claims, id: "handoff")
        caller.cancel()
        await claims.finish(holder)
        do {
            try await caller.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        let idle = await claims.kind(of: "handoff")
        XCTAssertNil(idle)
        let successor = try await claims.withExclusive("handoff") { true }
        XCTAssertTrue(successor)
    }

    private func waitUntilQueued(_ claims: ContainerLifecycleClaims, id: String) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await claims.queuedCount(for: id) == 0 {
            if ContinuousClock.now >= deadline {
                XCTFail("create did not enter the held ID's queue")
                return
            }
            await Task.yield()
        }
    }
}
