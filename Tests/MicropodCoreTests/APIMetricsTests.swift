import Foundation
import XCTest

@testable import MicropodCore

final class APIMetricsTests: XCTestCase {
    func testDurationAggregatesStatusesWithoutDuplicateSeries() {
        let metrics = APIMetrics()
        metrics.record(route: "/commit", method: "POST", status: 200, duration: 0.25)
        metrics.record(route: "/commit", method: "POST", status: 412, duration: 0.5)
        metrics.record(route: "/commit", method: "POST", status: 200, duration: 0.125)

        let output = metrics.render()
        let samples = output.split(separator: "\n").filter { !$0.hasPrefix("#") }
        let keys = samples.map { $0.split(separator: " ").dropLast().joined(separator: " ") }
        XCTAssertEqual(Set(keys).count, keys.count, "Every Prometheus label set must occur once")
        XCTAssertTrue(
            output.contains(
                "micropod_api_request_duration_microseconds_total{route=\"/commit\",method=\"POST\"} 875000\n"))
        XCTAssertTrue(
            output.contains("micropod_api_requests_total{route=\"/commit\",method=\"POST\",status=\"200\"} 2\n"))
        XCTAssertTrue(
            output.contains("micropod_api_errors_total{route=\"/commit\",method=\"POST\",status=\"412\"} 1\n"))
    }

    func testDurationKeepsRoutesAndMethodsSeparateForNamedOutcomes() {
        let metrics = APIMetrics(prefix: "micropod_cli")
        metrics.record(route: "image list", method: "CLI", label: "hit", duration: 0.125)
        metrics.record(route: "image list", method: "CLI", label: "miss", duration: 0.25)
        metrics.record(route: "volume list", method: "CLI", label: "hit", duration: 0.5)
        metrics.record(route: "image list", method: "GET", label: "hit", duration: 1)

        let output = metrics.render()
        XCTAssertEqual(
            output.split(separator: "\n").filter { $0.hasPrefix("micropod_cli_request_duration_microseconds_total{") }
                .count, 3)
        for (route, method, duration) in [
            ("image list", "CLI", 375000), ("volume list", "CLI", 500000), ("image list", "GET", 1000000),
        ] {
            XCTAssertTrue(
                output.contains(
                    "micropod_cli_request_duration_microseconds_total{route=\"\(route)\",method=\"\(method)\"} \(duration)\n"
                ))
        }
    }

    /// Handlers record and `/metrics` renders from Swift's cooperative pool,
    /// many at once (one HTTP/2 connection can ask 100 times). Every one
    /// must finish: none may wait on a thread the others hold.
    func testConcurrentRecordsAndRendersFromTasksAllFinish() {
        let metrics = APIMetrics()
        let done = DispatchGroup()
        for index in 0..<400 {
            done.enter()
            Task {
                metrics.record(route: "/metrics", method: "GET", status: 200, duration: 0.001)
                _ = metrics.render()
                metrics.record(route: "/r\(index % 7)", method: "GET", status: 200, duration: 0.001)
                done.leave()
            }
        }
        // Waited for off the pool: a wedged pool could not report itself.
        XCTAssertEqual(done.wait(timeout: .now() + 20), .success, "records and renders wedged the cooperative pool")
        XCTAssertTrue(metrics.render().contains("route=\"/metrics\",method=\"GET\",status=\"200\"} 400\n"))
    }
}
