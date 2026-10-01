import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// `NativeStatsSampler` with the XPC and guest-agent reads faked: the exact
/// counters (`cpu_usage_usec`, `oom_kill_count`) must reach the wire on the
/// first sample, and an unread OOM count must stay unset, not 0.
final class NativeStatsSamplerTests: XCTestCase {
    private static func entry(_ id: String, cpuUsageUsec: Int64?) throws -> ContainerStatsEntry {
        var fields: [String: Any] = [
            "id": id, "memoryUsageBytes": 4_055_040, "memoryLimitBytes": 1_073_741_824,
            "networkRxBytes": 28744, "networkTxBytes": 602, "blockReadBytes": 3_870_720,
            "blockWriteBytes": 0, "numProcesses": 2,
        ]
        if let cpuUsageUsec { fields["cpuUsageUsec"] = cpuUsageUsec }
        let data = try JSONSerialization.data(withJSONObject: fields)
        return try MicropodJSON.decode(ContainerStatsEntry.self, from: data, context: "test")
    }

    private func sampler(
        usec: Int64? = 6_576_389_781,
        oomKills: (@Sendable (String) async -> UInt64?)? = nil
    ) -> NativeStatsSampler {
        NativeStatsSampler(
            listRunning: { ["a", "b"] },
            fetchStats: { id in try Self.entry(id, cpuUsageUsec: usec) },
            readOOMKills: oomKills)
    }

    func testFirstSampleCarriesCumulativeCPU() async throws {
        let snap = try await sampler().snapshot()
        XCTAssertEqual(snap.containers.map(\.id), ["a", "b"])
        let a = try XCTUnwrap(snap.containers.first)
        XCTAssertEqual(a.cpuUsageUsec, 6_576_389_781)
        XCTAssertEqual(a.cpuPercent, 0, "no baseline yet — the delta needs a second sample")
        XCTAssertEqual(a.memoryUsedBytes, 4_055_040)
        XCTAssertEqual(a.pids, 2)
    }

    func testMissingCPUCounterIsZero() async throws {
        let snap = try await sampler(usec: nil).snapshot(ids: ["a"])
        XCTAssertEqual(snap.containers.map(\.id), ["a"])
        XCTAssertEqual(snap.containers[0].cpuUsageUsec, 0)
    }

    func testOOMKillCountFromGuest() async throws {
        let snap = try await sampler(oomKills: { $0 == "a" ? 3 : 0 }).snapshot()
        XCTAssertTrue(snap.containers[0].hasOomKillCount)
        XCTAssertEqual(snap.containers[0].oomKillCount, 3)
        XCTAssertTrue(snap.containers[1].hasOomKillCount, "a read 0 is reported, not left unset")
        XCTAssertEqual(snap.containers[1].oomKillCount, 0)
    }

    func testUnreadOOMKillCountStaysUnset() async throws {
        let unreadable = try await sampler(oomKills: { _ in nil }).snapshot()
        XCTAssertFalse(unreadable.containers.contains(where: \.hasOomKillCount))
        let noGuest = try await sampler(oomKills: nil).snapshot()
        XCTAssertFalse(noGuest.containers.contains(where: \.hasOomKillCount))
    }

    func testOOMKillCountSurvivesWireRoundTrip() async throws {
        let snap = try await sampler(oomKills: { _ in 0 }).snapshot()
        let decoded = try Micropod_V1_StatsSnapshot(serializedBytes: try snap.serializedData())
        XCTAssertTrue(decoded.containers[0].hasOomKillCount)
        XCTAssertEqual(decoded.containers[0].cpuUsageUsec, 6_576_389_781)
    }

    func testBoundedAbandonsSlowGuest() async {
        let start = ContinuousClock.now
        let value: UInt64? = await NativeStatsSampler.bounded(.milliseconds(100)) {
            try await Task.sleep(for: .seconds(30))
            return 7
        }
        XCTAssertNil(value)
        XCTAssertLessThan(start.duration(to: .now), .seconds(5))
    }

    func testBoundedReturnsPromptValueAndSwallowsErrors() async {
        let ok: UInt64? = await NativeStatsSampler.bounded(.seconds(5)) { 4 }
        XCTAssertEqual(ok, 4)
        let failed: UInt64? = await NativeStatsSampler.bounded(.seconds(5)) {
            throw MicropodError.message("guest gone")
        }
        XCTAssertNil(failed)
    }

    func testDockerStatsCarryCumulativeCPU() {
        let json: [String: Any] = [
            "cpu_stats": ["cpu_usage": ["total_usage": NSNumber(value: UInt64(9_007_199_254_740_993_000))]],
            "memory_stats": ["usage": 1024],
        ]
        let stats = DockerEngine.stats(id: "d", json)
        XCTAssertEqual(stats.cpuUsageUsec, 9_007_199_254_740_993, "ns → µs without Double rounding")
        XCTAssertFalse(stats.hasOomKillCount)
    }
}
