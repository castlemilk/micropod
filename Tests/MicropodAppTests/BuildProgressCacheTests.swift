import MicropodCore
import XCTest

@testable import MicropodApp

@MainActor
final class BuildProgressCacheTests: XCTestCase {
    func testUnchangedOutputAndStatusChangesReuseParsedSnapshot() {
        var parses = 0
        let cache = BuildProgressCache { line in
            parses += 1
            return ProgressEvent.parse(line: line)
        }
        var operation = ActiveOperation(title: "Build", kind: .build)
        operation.appendEvents(["[1/3] Compile", "[2/3] Link"])
        let first = cache.snapshot(for: operation)
        for _ in 0..<100 { XCTAssertEqual(cache.snapshot(for: operation), first) }
        operation.status = .succeeded
        XCTAssertEqual(cache.snapshot(for: operation), first)
        XCTAssertEqual(parses, 2)
        XCTAssertEqual(first.outputText, "[1/3] Compile\n[2/3] Link")
    }

    func testAppendAndRingEvictionParseOnlyNewLines() {
        var parses = 0
        let cache = BuildProgressCache { line in
            parses += 1
            return ProgressEvent.parse(line: line)
        }
        var operation = ActiveOperation(title: "Build", kind: .build)
        operation.appendEvents((0..<512).map { "line \($0)" })
        _ = cache.snapshot(for: operation)
        XCTAssertEqual(parses, 500)
        operation.appendEvents((512..<532).map { "line \($0)" })
        let next = cache.snapshot(for: operation)
        XCTAssertEqual(parses, 520)
        XCTAssertEqual(next.events.count, 500)
        XCTAssertEqual(next.events.first?.line, "line 32")
        XCTAssertEqual(next.events.last?.line, "line 531")
        XCTAssertEqual(next.events.map(\.line), Array(operation.events.suffix(500)))
    }

    func testByteBudgetEvictionKeepsNewestParsedEvents() {
        var parses = 0
        let cache = BuildProgressCache { line in
            parses += 1
            return ProgressEvent.parse(line: line)
        }
        var operation = ActiveOperation(title: "Build", kind: .build)
        let line = String(repeating: "x", count: ActiveOperation.maximumSingleEventBytes)
        operation.appendEvents(repeatElement(line, count: 16))
        _ = cache.snapshot(for: operation)
        operation.appendEvents(["[2/3] " + line])
        let next = cache.snapshot(for: operation)
        XCTAssertEqual(parses, 17)
        XCTAssertEqual(next.events.map(\.line), operation.events)
        XCTAssertEqual(next.outputText, operation.events.joined(separator: "\n"))
    }

    func testChangedIntermediateTextWithEqualMetadataReparsesCorrectly() {
        let cache = BuildProgressCache()
        var operation = ActiveOperation(title: "Build", kind: .build)
        operation.events = ["first", "alpha", "last"]
        _ = cache.snapshot(for: operation)
        let previousBytes = operation.retainedEventBytes
        let previousLatest = operation.latestEvent
        operation.events = ["first", "omega", "last"]
        XCTAssertEqual(operation.retainedEventBytes, previousBytes)
        XCTAssertEqual(operation.latestEvent, previousLatest)
        let next = cache.snapshot(for: operation)
        XCTAssertEqual(next.events.map(\.line), ["first", "omega", "last"])
        XCTAssertEqual(next.outputText, "first\nomega\nlast")
    }

    func testOperationSwitchAndResetClearCachedOutput() {
        let cache = BuildProgressCache()
        var operation = ActiveOperation(title: "Build", kind: .build)
        operation.appendEvents(["[1/2] First", "[2/2] Last"])
        _ = cache.snapshot(for: operation)
        var replacement = ActiveOperation(title: "Another build", kind: .build)
        replacement.appendEvents(["replacement"])
        XCTAssertEqual(cache.snapshot(for: replacement).events.map(\.line), ["replacement"])
        replacement.events = []
        XCTAssertEqual(cache.snapshot(for: replacement), .empty)
        XCTAssertEqual(cache.snapshot(for: nil), .empty)
        XCTAssertEqual(cache.snapshot(for: operation).events.map(\.line), operation.events)
    }
}
