import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// `SharedReads` is what keeps a busy apiserver's read queue from growing:
/// identical reads share one request, callers give up without abandoning
/// it, and writes are always read back.
final class SharedReadsTests: XCTestCase {
    /// A fetch that blocks until opened, counting how often it was sent and
    /// how many ran at once.
    private actor Backend {
        private(set) var sent: [String] = []
        private(set) var maxRunning = 0
        private var running = 0
        private var gates: [String: [CheckedContinuation<Void, Never>]] = [:]
        private var open: Set<String> = []
        private var failures: [String: String] = [:]

        func fetch(_ key: String, value: Int) async throws -> Int {
            sent.append(key)
            running += 1
            maxRunning = max(maxRunning, running)
            defer { running -= 1 }
            if !open.contains(key) {
                await withCheckedContinuation { gates[key, default: []].append($0) }
            }
            if let failure = failures[key] { throw MicropodError.message(failure) }
            return value
        }

        func release(_ key: String, failing message: String? = nil) {
            if let message { failures[key] = message }
            open.insert(key)
            for gate in gates.removeValue(forKey: key) ?? [] { gate.resume() }
        }

        func block(_ key: String) {
            open.remove(key)
            failures[key] = nil
        }

        func count(_ key: String) -> Int { sent.filter { $0 == key }.count }
    }

    private static func read(
        _ reads: SharedReads<Int>, _ backend: Backend, _ key: String, value: Int = 1,
        policy: ReadPolicy = .live
    ) async throws -> Int {
        try await reads.read(key, policy: policy, requestTimeout: .seconds(30)) { _ in
            try await backend.fetch(key, value: value)
        }
    }

    /// Polls `condition` (the reads hop through unstructured tasks).
    private func eventually(
        _ what: String, timeout: Duration = .seconds(5), _ condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testIdenticalReadsInFlightShareOneRequest() async throws {
        let reads = SharedReads<Int>(route: "containerList")
        let backend = Backend()
        let callers = (0..<10).map { _ in Task { try await SharedReadsTests.read(reads, backend, "all", value: 7) } }
        try await eventually("every caller waiting") { await reads.waiterCount("all") == 10 }
        await backend.release("all")
        for caller in callers {
            let value = try await caller.value
            XCTAssertEqual(value, 7)
        }
        let sent = await backend.count("all")
        XCTAssertEqual(sent, 1, "ten callers, one request")
    }

    func testDifferentKeysAreDifferentRequests() async throws {
        let reads = SharedReads<Int>(route: "containerList")
        let backend = Backend()
        await backend.release("a")
        await backend.release("b")
        let a = try await SharedReadsTests.read(reads, backend, "a", value: 1)
        let b = try await SharedReadsTests.read(reads, backend, "b", value: 2)
        XCTAssertEqual([a, b], [1, 2])
        let sent = await backend.sent
        XCTAssertEqual(sent, ["a", "b"])
    }

    func testRecentAnswersServeOnlyCallersThatAcceptThem() async throws {
        let reads = SharedReads<Int>(route: "containerList")
        let backend = Backend()
        await backend.release("all")
        _ = try await SharedReadsTests.read(reads, backend, "all")
        _ = try await SharedReadsTests.read(
            reads, backend, "all", policy: ReadPolicy(budget: .seconds(5), maxAge: .seconds(60)))
        var sent = await backend.count("all")
        XCTAssertEqual(sent, 1, "a recent answer serves a caller that takes one")
        _ = try await SharedReadsTests.read(reads, backend, "all")
        sent = await backend.count("all")
        XCTAssertEqual(sent, 2, "a live read always asks")
        _ = try await SharedReadsTests.read(
            reads, backend, "all", policy: ReadPolicy(budget: .seconds(5), maxAge: .zero))
        sent = await backend.count("all")
        XCTAssertEqual(sent, 3, "an answer older than maxAge is not used")
    }

    /// Read your writes: a request sent before a write is neither joined nor
    /// remembered after it.
    func testInvalidateStopsJoiningAndRemembering() async throws {
        let reads = SharedReads<Int>(route: "containerList")
        let backend = Backend()
        let before = Task { try await SharedReadsTests.read(reads, backend, "all", value: 1) }
        try await eventually("the first request") { await backend.count("all") == 1 }

        await reads.invalidate()  // a create landed
        let after = Task { try await SharedReadsTests.read(reads, backend, "all", value: 2) }
        try await eventually("a second request") { await backend.count("all") == 2 }

        await backend.release("all")
        let first = try await before.value
        let second = try await after.value
        XCTAssertEqual(first, 1, "the caller that asked before the write gets the request it joined")
        XCTAssertEqual(second, 2, "the caller after it, its own")
        _ = try await SharedReadsTests.read(
            reads, backend, "all", policy: ReadPolicy(budget: .seconds(5), maxAge: .seconds(60)))
        let sent = await backend.count("all")
        XCTAssertEqual(sent, 2, "the post-write answer is remembered")
    }

    func testInvalidatingOneKeyKeepsTheOthers() async throws {
        let reads = SharedReads<Int>(route: "volumeInspect")
        let backend = Backend()
        await backend.release("a")
        await backend.release("b")
        _ = try await SharedReadsTests.read(reads, backend, "a")
        _ = try await SharedReadsTests.read(reads, backend, "b")
        await reads.invalidate("a")
        let recent = ReadPolicy(budget: .seconds(5), maxAge: .seconds(60))
        _ = try await SharedReadsTests.read(reads, backend, "a", policy: recent)
        _ = try await SharedReadsTests.read(reads, backend, "b", policy: recent)
        let sent = await backend.sent
        XCTAssertEqual(sent, ["a", "b", "a"])
    }

    func testRememberedValuesFollowTheFilter() async throws {
        let reads = SharedReads<Int?>(route: "volumeInspect") { $0 != nil }
        await reads.remember("missing", nil)
        await reads.remember("there", 3)
        let missing = await reads.answer("missing", maxAge: .seconds(60))
        let there = await reads.answer("there", maxAge: .seconds(60))
        XCTAssertNil(missing ?? nil, "not found is never remembered")
        XCTAssertEqual(there, 3)
    }

    /// The caller gives up after its budget with the XPC-timeout wording;
    /// the request keeps going, and a later caller joins it.
    func testBudgetEndsTheCallNotTheRequest() async throws {
        let reads = SharedReads<Int>(route: "volumeInspect")
        let backend = Backend()
        do {
            _ = try await SharedReadsTests.read(
                reads, backend, "gold", value: 5, policy: ReadPolicy(budget: .milliseconds(50)))
            XCTFail("the budget should have run out")
        } catch {
            let text = "\(error)"
            XCTAssertTrue(
                text.contains("deadlineExceeded: XPC timeout for com.apple.container.apiserver/volumeInspect"), text)
            XCTAssertTrue(text.contains("no answer within 0.1s") || text.contains("no answer within 0.0s"), text)
        }
        let later = Task { try await SharedReadsTests.read(reads, backend, "gold", value: 5) }
        try await eventually("the later caller waiting") { await reads.waiterCount("gold") == 1 }
        var sent = await backend.count("gold")
        XCTAssertEqual(sent, 1, "the later caller joined the request still waiting")
        await backend.release("gold")
        let value = try await later.value
        XCTAssertEqual(value, 5)
        _ = try await SharedReadsTests.read(
            reads, backend, "gold", policy: ReadPolicy(budget: .seconds(5), maxAge: .seconds(60)))
        sent = await backend.count("gold")
        XCTAssertEqual(sent, 1, "and its answer is remembered")
    }

    func testStaleAnswerWhenBusyIfThePolicyTakesOne() async throws {
        let reads = SharedReads<Int>(route: "containerList")
        let backend = Backend()
        await backend.release("all")
        _ = try await SharedReadsTests.read(reads, backend, "all", value: 1)
        await backend.block("all")
        try await Task.sleep(for: .milliseconds(10))
        let poll = ReadPolicy(budget: .milliseconds(50), maxAge: .milliseconds(1), staleIfBusy: .seconds(60))
        let value = try await SharedReadsTests.read(reads, backend, "all", value: 2, policy: poll)
        XCTAssertEqual(value, 1, "the busy apiserver's last answer, not an error")

        await reads.invalidate()
        do {
            _ = try await SharedReadsTests.read(reads, backend, "all", value: 2, policy: poll)
            XCTFail("an answer from before a write must not be served")
        } catch {
            XCTAssertTrue("\(error)".contains("deadlineExceeded"), "\(error)")
        }
        await backend.release("all")
    }

    func testFailuresReachEveryCallerAndAreNotRemembered() async throws {
        let reads = SharedReads<Int>(route: "containerList")
        let backend = Backend()
        let callers = (0..<3).map { _ in Task { try await SharedReadsTests.read(reads, backend, "all") } }
        try await eventually("every caller waiting") { await reads.waiterCount("all") == 3 }
        await backend.release("all", failing: "transport: connection interrupted")
        for caller in callers {
            do {
                _ = try await caller.value
                XCTFail("every caller sees the failure")
            } catch {
                XCTAssertTrue("\(error)".contains("connection interrupted"))
            }
        }
        await backend.block("all")
        await backend.release("all")
        _ = try await SharedReadsTests.read(
            reads, backend, "all", policy: ReadPolicy(budget: .seconds(5), maxAge: .seconds(60)))
        let sent = await backend.count("all")
        XCTAssertEqual(sent, 2, "a failure is not an answer to remember")
    }

    func testAtMostMaxInFlightRequestsAtOnce() async throws {
        let reads = SharedReads<Int>(route: "containerList", maxInFlight: 2)
        let backend = Backend()
        let keys = ["a", "b", "c", "d", "e"]
        let callers = keys.map { key in Task { try await SharedReadsTests.read(reads, backend, key) } }
        try await eventually("two requests") { await backend.sent.count == 2 }
        try await Task.sleep(for: .milliseconds(30))
        var sent = await backend.sent.count
        XCTAssertEqual(sent, 2, "the rest queue")
        for key in keys { await backend.release(key) }
        for caller in callers { _ = try await caller.value }
        sent = await backend.sent.count
        let maxRunning = await backend.maxRunning
        XCTAssertEqual(sent, 5)
        XCTAssertEqual(maxRunning, 2)
    }

    func testAQueuedRequestWhoseCallersGaveUpIsNeverSent() async throws {
        let reads = SharedReads<Int>(route: "containerList", maxInFlight: 1)
        let backend = Backend()
        let first = Task { try await SharedReadsTests.read(reads, backend, "a") }
        try await eventually("the first request") { await backend.count("a") == 1 }
        do {
            _ = try await SharedReadsTests.read(reads, backend, "b", policy: ReadPolicy(budget: .milliseconds(30)))
            XCTFail("the queued read should have run out of budget")
        } catch {
            XCTAssertTrue("\(error)".contains("queued behind"), "\(error)")
        }
        await backend.release("a")
        _ = try await first.value
        try await Task.sleep(for: .milliseconds(50))
        let sent = await backend.count("b")
        XCTAssertEqual(sent, 0, "nobody was left to answer")
    }

    func testCancellingACallerLeavesTheRequestForTheOthers() async throws {
        let reads = SharedReads<Int>(route: "containerList")
        let backend = Backend()
        let cancelled = Task { try await SharedReadsTests.read(reads, backend, "all", value: 4) }
        let kept = Task { try await SharedReadsTests.read(reads, backend, "all", value: 4) }
        try await eventually("both callers waiting") { await reads.waiterCount("all") == 2 }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("the cancelled caller should stop waiting")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        await backend.release("all")
        let value = try await kept.value
        XCTAssertEqual(value, 4)
    }

    // MARK: - APIServerClient helpers

    func testAllocatedSizeWalksTheBundleLikeTheApiserver() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("alloc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(count: 64 * 1024).write(to: dir.appendingPathComponent("rootfs.ext4"))
        try Data(count: 8 * 1024).write(to: dir.appendingPathComponent("nested/config.json"))
        try Data(count: 1024 * 1024).write(to: dir.appendingPathComponent(".hidden"))
        let size = try XCTUnwrap(APIServerClient.allocatedSize(of: dir))
        XCTAssertGreaterThanOrEqual(size, 72 * 1024)
        XCTAssertLessThan(size, 1024 * 1024, "hidden files are skipped, as the apiserver skips them")
        XCTAssertNil(APIServerClient.allocatedSize(of: dir.appendingPathComponent("missing")))
        XCTAssertNil(
            APIServerClient.allocatedSize(of: dir.appendingPathComponent("rootfs.ext4")), "not a directory")
    }

    func testARememberedVolumeNeedsItsBackingImage() throws {
        let image = FileManager.default.temporaryDirectory.appendingPathComponent("volume-\(UUID().uuidString).img")
        XCTAssertFalse(APIServerClient.backingImageExists(.object(["source": .string(image.path)])))
        try Data([0]).write(to: image)
        defer { try? FileManager.default.removeItem(at: image) }
        XCTAssertTrue(APIServerClient.backingImageExists(.object(["source": .string(image.path)])))
        XCTAssertFalse(APIServerClient.backingImageExists(.object(["source": .string("")])))
        XCTAssertFalse(APIServerClient.backingImageExists(.object(["name": .string("no-source")])))
    }
}
