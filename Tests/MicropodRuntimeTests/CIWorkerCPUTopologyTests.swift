import XCTest

@testable import MicropodRuntime

final class CIWorkerCPUTopologyTests: XCTestCase {
    func testThreeTiersStayDistinctAndMissingL2IsUnknown() throws {
        let facts = [
            "hw.nperflevels": 3, "hw.perflevel0.physicalcpu": 2, "hw.perflevel1.physicalcpu": 4,
            "hw.perflevel2.physicalcpu": 6, "hw.perflevel0.cpusperl2": 2, "hw.perflevel2.cpusperl2": 3,
        ]
        let names = ["hw.perflevel1.name": "Performance", "hw.perflevel2.name": "Efficiency"]
        let plan = try CIWorkerCPUCount.auto.topologyPlan(
            integer: { facts[$0] }, string: { names[$0] }, activeCPUs: 12, minimum: 1, maximum: 8)
        XCTAssertEqual(plan.allocation, .init(count: 2, source: .performanceLevel))
        XCTAssertEqual(plan.reportedLevelCount, 3)
        XCTAssertEqual(plan.levels.map(\.name), [nil, "Performance", "Efficiency"])
        XCTAssertEqual(plan.levels.map(\.physicalCPUs), [2, 4, 6])
        XCTAssertEqual(plan.levels.map(\.cpusPerL2), [2, nil, 3])
    }

    func testRestrictedTopologyAndExplicitCountsPreserveSizingPolicy() throws {
        for (fastest, active, expected) in [(nil, 2, 2), (6, 18, 5)] as [(Int?, Int, Int)] {
            let probe: (String) -> Int? = { $0 == "hw.perflevel0.physicalcpu" ? fastest : nil }
            let automatic = try CIWorkerCPUCount.auto.topologyPlan(
                integer: probe, string: { _ in nil }, activeCPUs: active, minimum: 1, maximum: 5)
            XCTAssertNil(automatic.reportedLevelCount)
            XCTAssertEqual(automatic.allocation.count, expected)
            XCTAssertEqual(automatic.allocation.source, fastest == nil ? .fallback : .performanceLevel)
            XCTAssertEqual(automatic.levels.count, fastest == nil ? 0 : 1)
            let fixed = try CIWorkerCPUCount.fixed(4).topologyPlan(
                integer: probe, string: { _ in nil }, activeCPUs: active, minimum: 1, maximum: 5)
            XCTAssertEqual(fixed.allocation, .init(count: 4, source: .fixed))
            XCTAssertThrowsError(
                try CIWorkerCPUCount.fixed(6).topologyPlan(
                    integer: probe, string: { _ in nil }, activeCPUs: active, minimum: 1, maximum: 5))
        }
    }
}
