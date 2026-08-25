import XCTest

@testable import MicropodCore
@testable import MicropodDockerShim

final class ShimFilterTests: XCTestCase {
    private func summary(labels: [String: String], id: String = "abc123", state: String = "running")
        -> DockerContainerSummary
    {
        var container = Micropod_V1_Container()
        container.id = id
        container.state = state
        container.labels = labels
        return DockerMapper.summary(container, create: nil)
    }

    func testLabelFilterSingularAndPlural() throws {
        let match = summary(labels: ["org.testcontainers.session-id": "abc"])
        XCTAssertTrue(
            try ShimRouterTestHooks.matchesFiltersForTesting(
                ["label": ["org.testcontainers.session-id=abc"]], summary: match))
        XCTAssertTrue(
            try ShimRouterTestHooks.matchesFiltersForTesting(
                ["labels": ["org.testcontainers.session-id=abc"]], summary: match))
        XCTAssertFalse(
            try ShimRouterTestHooks.matchesFiltersForTesting(
                ["labels": ["org.testcontainers.session-id=other"]], summary: match))
        // Bare key filter: label present with any value.
        XCTAssertTrue(
            try ShimRouterTestHooks.matchesFiltersForTesting(
                ["labels": ["org.testcontainers.session-id"]], summary: match))
    }

    func testUnlabeledContainerNeverMatchesLabelFilter() throws {
        let plain = summary(labels: [:])
        XCTAssertFalse(
            try ShimRouterTestHooks.matchesFiltersForTesting(
                ["labels": ["anything=x"]], summary: plain))
    }

    func testUnknownFilterThrowsLikeDockerd() {
        let match = summary(labels: [:])
        XCTAssertThrowsError(
            try ShimRouterTestHooks.matchesFiltersForTesting(["nonsense": ["x"]], summary: match)
        ) { error in
            guard case ShimError.badRequest(let message) = error else {
                return XCTFail("expected badRequest, got \(error)")
            }
            XCTAssertTrue(message.contains("nonsense"))
        }
    }

    func testNameIDStatusFilters() throws {
        let match = summary(labels: [:], id: "abcdef", state: "running")
        XCTAssertTrue(try ShimRouterTestHooks.matchesFiltersForTesting(["name": ["abc"]], summary: match))
        XCTAssertFalse(try ShimRouterTestHooks.matchesFiltersForTesting(["name": ["zzz"]], summary: match))
        XCTAssertTrue(try ShimRouterTestHooks.matchesFiltersForTesting(["id": ["abcd"]], summary: match))
        XCTAssertTrue(
            try ShimRouterTestHooks.matchesFiltersForTesting(["status": ["running"]], summary: match))
        XCTAssertFalse(
            try ShimRouterTestHooks.matchesFiltersForTesting(["status": ["exited"]], summary: match))
    }
}

/// The real matcher lives on Router; expose it statically for tests without
/// instantiating the full router.
enum ShimRouterTestHooks {
    static func matchesFiltersForTesting(
        _ filters: [String: [String]], summary: DockerContainerSummary
    ) throws -> Bool {
        try Router.matchesFilters(filters, summary: summary, container: Micropod_V1_Container())
    }
}
