import XCTest

@testable import MicropodDockerShim

/// Healthcheck supervision state machine (Docker semantics) without any
/// runtime: spec parsing, starting/healthy/unhealthy transitions,
/// start-period grace, retry counting, log capping, probe cadence.
final class HealthSupervisionTests: XCTestCase {
    private func spec(
        test: [String] = ["CMD-SHELL", "true"],
        intervalS: Double = 1, timeoutS: Double = 1, retries: Int = 2,
        startPeriodS: Double = 0, startIntervalS: Double = 0
    ) -> ShimState.HealthSpec {
        ShimState.HealthSpec(
            test: test, intervalS: intervalS, timeoutS: timeoutS, retries: retries,
            startPeriodS: startPeriodS, startIntervalS: startIntervalS)
    }

    func testSpecParsing() async {
        XCTAssertNil(ShimState.HealthSpec.from(nil))
        XCTAssertNil(ShimState.HealthSpec.from(DockerHealthcheck()))
        let none = DockerHealthcheck(
            Test: ["NONE"], Interval: nil, Timeout: nil, Retries: nil,
            StartPeriod: nil, StartInterval: nil)
        XCTAssertNil(ShimState.HealthSpec.from(none))
        let frob = DockerHealthcheck(
            Test: ["FROB"], Interval: nil, Timeout: nil, Retries: nil,
            StartPeriod: nil, StartInterval: nil)
        XCTAssertNil(ShimState.HealthSpec.from(frob))
        let parsed = ShimState.HealthSpec.from(
            DockerHealthcheck(
                Test: ["CMD-SHELL", "pg_isready"], Interval: 2_000_000_000, Timeout: 5_000_000_000,
                Retries: 30, StartPeriod: 3_000_000_000, StartInterval: nil))!
        XCTAssertEqual(parsed.intervalS, 2, accuracy: 0.001)
        XCTAssertEqual(parsed.timeoutS, 5, accuracy: 0.001)
        XCTAssertEqual(parsed.retries, 30)
        XCTAssertEqual(parsed.startPeriodS, 3, accuracy: 0.001)
        // Defaults mirror dockerd.
        let plain = DockerHealthcheck(
            Test: ["CMD", "true"], Interval: nil, Timeout: nil, Retries: nil,
            StartPeriod: nil, StartInterval: nil)
        let defaults = ShimState.HealthSpec.from(plain)!
        XCTAssertEqual(defaults.intervalS, 30, accuracy: 0.001)
        XCTAssertEqual(defaults.timeoutS, 30, accuracy: 0.001)
        XCTAssertEqual(defaults.retries, 3)
    }

    func testSuccessIsImmediatelyHealthy() async {
        let state = ShimState()
        let id = await remember(state: state, spec: spec())
        let __v1 = await state.healthStatus(id: id)?.status
        XCTAssertEqual(__v1, "starting")
        let __v2 = await state.recordProbe(id: id, success: true, output: "ok")
        XCTAssertEqual(__v2, "healthy")
        let __v3 = await state.healthStatus(id: id)?.failingStreak
        XCTAssertEqual(__v3, 0)
    }

    func testFailuresPastRetriesTurnUnhealthy() async {
        // startPeriod 0 + failing from the first probe: unhealthy after
        // retries+1 consecutive failures (Docker counts past `retries`).
        let state = ShimState()
        let id = await remember(state: state, spec: spec(retries: 2, startPeriodS: 0))
        // firstRunningAt stamps on observation; without it we stay starting.
        let __v4 = await state.recordProbe(id: id, success: false, output: "x")
        XCTAssertEqual(__v4, "starting")
        // Simulate the running stamp aging past the (zero) start period.
        await state.noteHealthRunning(id: id)
        let __v5 = await state.recordProbe(id: id, success: false, output: "x")
        XCTAssertEqual(__v5, "starting")
        let __v6 = await state.recordProbe(id: id, success: false, output: "x")
        XCTAssertEqual(__v6, "unhealthy")
        let __v7 = await state.recordProbe(id: id, success: false, output: "x")
        XCTAssertEqual(__v7, "unhealthy")
        let __v8 = await state.healthStatus(id: id)?.failingStreak
        XCTAssertEqual(__v8, 4)
        // Recovery resets the streak.
        let __v9 = await state.recordProbe(id: id, success: true, output: "ok")
        XCTAssertEqual(__v9, "healthy")
        let __v10 = await state.healthStatus(id: id)?.failingStreak
        XCTAssertEqual(__v10, 0)
    }

    func testStartPeriodGrace() async {
        // Long start period: failures never escalate while inside it.
        let state = ShimState()
        let id = await remember(state: state, spec: spec(retries: 0, startPeriodS: 3600))
        await state.noteHealthRunning(id: id)
        for _ in 0..<5 {
            let probe = await state.recordProbe(id: id, success: false, output: "x")
            XCTAssertEqual(probe, "starting")
        }
        let __v11 = await state.healthStatus(id: id)?.status
        XCTAssertEqual(__v11, "starting")
    }

    func testLogCapsAtFive() async {
        let state = ShimState()
        let id = await remember(state: state, spec: spec())
        for i in 0..<8 {
            _ = await state.recordProbe(id: id, success: i % 2 == 0, output: "o\(i)")
        }
        let __v12 = await state.healthStatus(id: id)?.log.count
        XCTAssertEqual(__v12, 5)
    }

    func testDueRespectsCadenceAndInflight() async {
        let state = ShimState()
        let id = await remember(state: state, spec: spec(intervalS: 60))
        // Due immediately after registration.
        let __v13 = await state.healthDueIDs(runningIDs: [id])
        XCTAssertEqual(__v13, [id])
        await state.noteProbeStarted(id: id, intervalS: 60)
        // In flight (and rescheduled): not due.
        let __v14 = await state.healthDueIDs(runningIDs: [id])
        XCTAssertEqual(__v14, [])
        // Not running: never due.
        let __v15 = await state.healthDueIDs(runningIDs: [])
        XCTAssertEqual(__v15, [])
    }

    func testResetHealth() async {
        let state = ShimState()
        let id = await remember(state: state, spec: spec())
        _ = await state.recordProbe(id: id, success: true, output: "ok")
        let __v16 = await state.healthStatus(id: id)?.status
        XCTAssertEqual(__v16, "healthy")
        await state.resetHealth(id: id)
        let status = await state.healthStatus(id: id)
        XCTAssertEqual(status?.status, "starting")
        XCTAssertEqual(status?.failingStreak, 0)
        // Unknown ids are a no-op (explicit starts predate tracking).
        await state.resetHealth(id: "nope")
    }

    // MARK: - Helpers

    @discardableResult
    private func remember(state: ShimState, spec: ShimState.HealthSpec) async -> String {
        // remember() derives the spec from the create body — round-trip
        // through it so the test covers the real wiring, not a setter.
        var body = DockerCreateRequest(Image: "alpine:3.20")
        body.Healthcheck = DockerHealthcheck(
            Test: spec.test, Interval: Int64(spec.intervalS * 1e9),
            Timeout: Int64(spec.timeoutS * 1e9), Retries: spec.retries,
            StartPeriod: Int64(spec.startPeriodS * 1e9), StartInterval: nil)
        let id = "health-\(UUID().uuidString.prefix(6))"
        await state.remember(id: id, name: id, request: body)
        let __v17 = await state.healthSpec(id: id)
        XCTAssertNotNil(__v17)
        return id
    }
}
