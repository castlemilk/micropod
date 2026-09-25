import MicropodCore
import XCTest

/// `StatsSampling.snapshot(ids:)` — the default (CLI) implementation samples
/// everything and keeps only the requested containers; the native sampler
/// overrides it to call `containerStats` per id. This pins the default's
/// contract: order preserved, empty ids = everything, unknown ids ignored.
final class StatsSamplingIDsTests: XCTestCase {

    private struct FakeSampler: StatsSampling {
        let ids: [String]

        func snapshot() async throws -> Micropod_V1_StatsSnapshot {
            .with { snapshot in
                snapshot.sampledAt = "2026-09-25T00:00:00Z"
                snapshot.containers = ids.map { id in .with { $0.id = id } }
            }
        }
    }

    func testFiltersToRequestedIdsKeepingSamplerOrder() async throws {
        let sampler: any StatsSampling = FakeSampler(ids: ["a", "b", "c"])
        let filtered = try await sampler.snapshot(ids: ["c", "a"])
        XCTAssertEqual(filtered.containers.map(\.id), ["a", "c"])
        XCTAssertEqual(filtered.sampledAt, "2026-09-25T00:00:00Z", "the sample time travels with the filter")
    }

    func testEmptyIdsIsEverything() async throws {
        let sampler: any StatsSampling = FakeSampler(ids: ["a", "b"])
        let all = try await sampler.snapshot(ids: [])
        XCTAssertEqual(all.containers.map(\.id), ["a", "b"])
    }

    func testUnknownIdsContributeNothing() async throws {
        let sampler: any StatsSampling = FakeSampler(ids: ["a"])
        let none = try await sampler.snapshot(ids: ["ghost"])
        XCTAssertEqual(none.containers, [])
        let mixed = try await sampler.snapshot(ids: ["ghost", "a"])
        XCTAssertEqual(mixed.containers.map(\.id), ["a"])
    }
}
