import MicropodCore
import XCTest

@testable import MicropodRuntime

final class NativeVolumeGuardsTests: XCTestCase {
    func testCommitRefusesEveryPendingLifecycleBeforeReadingOrReplacingCache() async throws {
        for kind in [ContainerLifecycleClaims.Kind.starting, .creating, .deleting, .cleanup] {
            let claims = ContainerLifecycleClaims()
            _ = await claims.claimIfIdle("cache-job", kind: kind)
            do {
                _ = try await NativeVolumeService.withCommitClaim(
                    containerID: "cache-job", claims: claims, unstarted: { _ in false },
                    body: {
                        XCTFail("must not inspect or replace a disk owned by pending work")
                        return 0
                    })
                XCTFail("expected pending lifecycle rejection")
            } catch {
                XCTAssertEqual(ConnectCodeMapping.code(for: error), "failed_precondition")
            }
        }
    }

    func testCommitHoldsOwnershipAcrossStoppedCheckAndReplacement() async throws {
        let claims = ContainerLifecycleClaims()
        let result = try await NativeVolumeService.withCommitClaim(
            containerID: "finished", claims: claims, unstarted: { _ in false },
            body: {
                let start = await claims.claimIfIdle("finished", kind: .starting)
                XCTAssertNil(start, "a new start cannot race the stopped check and disk replacement")
                return 12
            })
        XCTAssertEqual(result, 12)
        let afterward = await claims.kind(of: "finished")
        XCTAssertNil(afterward)
    }

    func testNeverStartedRawStoppedContainerCannotCommitAndReleasesGuard() async throws {
        let claims = ContainerLifecycleClaims()
        do {
            _ = try await NativeVolumeService.withCommitClaim(
                containerID: "created", claims: claims, unstarted: { _ in true },
                body: {
                    XCTFail("created is not a completed job")
                    return 0
                })
            XCTFail("expected never-started rejection")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "failed_precondition")
        }
        let afterward = await claims.kind(of: "created")
        XCTAssertNil(afterward)
    }
}
