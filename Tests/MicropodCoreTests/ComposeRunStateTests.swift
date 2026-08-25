import XCTest

@testable import MicropodCore

final class ComposeRunStateTests: XCTestCase {
    private func networkStep() -> ComposeStep {
        var network = Micropod_V1_ComposeNetwork()
        network.name = "front"
        return .network(network)
    }

    private func volumeStep() -> ComposeStep {
        var volume = Micropod_V1_ComposeVolume()
        volume.name = "pgdata"
        return .volume(volume)
    }

    private func pullStep() -> ComposeStep {
        .pull(image: "nginx:1.27", force: false)
    }

    private func runStep(_ name: String = "web") -> ComposeStep {
        var request = ContainerRunRequest(image: "nginx:1.27")
        request.name = name
        return .run(request: request)
    }

    private func readinessStep() -> ComposeStep {
        var service = Micropod_V1_ComposeService()
        service.name = "db"
        service.containerName = "db"
        return .readiness(service)
    }

    private func makeState(_ steps: [ComposeStep]) -> ComposeRunState {
        ComposeRunState(
            steps: steps.enumerated().map { ComposeRunState.StepState(step: $1, index: $0) })
    }

    func testTitles() {
        XCTAssertEqual(ComposeRunState.title(for: networkStep()), "Network front")
        XCTAssertEqual(ComposeRunState.title(for: volumeStep()), "Volume pgdata")
        XCTAssertEqual(ComposeRunState.title(for: pullStep()), "Image nginx:1.27")
        XCTAssertEqual(ComposeRunState.title(for: runStep("api")), "Run api")
        XCTAssertEqual(ComposeRunState.title(for: readinessStep()), "Wait for db health")
    }

    func testFullPipelineAdvancesInOrder() {
        var state = makeState([networkStep(), volumeStep(), pullStep(), runStep("web"), readinessStep()])
        XCTAssertEqual(state.status, .pending)

        state.consume("Network front created")
        XCTAssertEqual(state.steps[0].status, .success)
        XCTAssertEqual(state.cursor, 1)

        state.consume("Volume pgdata created")
        XCTAssertEqual(state.steps[1].status, .success)
        XCTAssertEqual(state.cursor, 2)

        state.consume("Image nginx:1.27 already present")
        XCTAssertEqual(state.steps[2].status, .success)
        XCTAssertEqual(state.cursor, 3)

        state.consume("Started web")
        XCTAssertEqual(state.steps[3].status, .success)
        XCTAssertEqual(state.cursor, 4)

        state.consume("Waiting for db to be ready…")
        XCTAssertEqual(state.steps[4].status, .running)
        XCTAssertEqual(state.cursor, 4)

        state.consume("db is ready")
        XCTAssertEqual(state.steps[4].status, .success)
        XCTAssertEqual(state.cursor, 5)
        XCTAssertEqual(state.status, .success)
    }

    func testPullTransitionsThroughRunning() {
        var state = makeState([pullStep()])
        state.consume("Pulling nginx:1.27…")
        XCTAssertEqual(state.steps[0].status, .running)
        XCTAssertEqual(state.cursor, 0)
        state.consume("Pulled nginx:1.27")
        XCTAssertEqual(state.steps[0].status, .success)
        XCTAssertEqual(state.cursor, 1)
    }

    func testDetailLinesCapturedPerStep() {
        var state = makeState([pullStep()])
        state.consume("Pulling nginx:1.27…")
        state.consume("Pulled nginx:1.27")
        XCTAssertEqual(state.steps[0].detail, ["Pulling nginx:1.27…", "Pulled nginx:1.27"])
        XCTAssertEqual(state.rawLog, ["Pulling nginx:1.27…", "Pulled nginx:1.27"])
    }

    func testInterleavedRunningLinesDoNotAdvance() {
        var state = makeState([pullStep(), runStep("api")])
        state.consume("Pulling nginx:1.27…")
        // a stray mid-step line stays on the pull step
        state.consume("Pulled nginx:1.27")
        XCTAssertEqual(state.cursor, 1)
        state.consume("Started api")
        XCTAssertEqual(state.steps[1].status, .success)
        XCTAssertEqual(state.cursor, 2)
    }

    func testFailedStepMarksCurrentAndStatusFailed() {
        var state = makeState([networkStep(), runStep("web")])
        state.consume("Network front created")
        state.markCurrentFailed()
        XCTAssertEqual(state.steps[1].status, .failed)
        XCTAssertEqual(state.status, .failed)
        // later steps stay pending
        XCTAssertEqual(state.steps[0].status, .success)
    }

    func testMarkAllPendingSuccessClosesTail() {
        var state = makeState([runStep("web"), readinessStep()])
        state.consume("Started web")
        // stream ended without a readiness marker — close it out
        state.markAllPendingSuccess()
        XCTAssertEqual(state.steps[1].status, .success)
        XCTAssertEqual(state.status, .success)
    }

    func testConsumeAfterFinishIsIgnored() {
        var state = makeState([runStep("web")])
        state.consume("Started web")
        state.consume("Stray line after finish")
        XCTAssertEqual(state.steps.count, 1)
        XCTAssertEqual(state.rawLog.count, 2)
        XCTAssertEqual(state.cursor, 1)
    }
}
