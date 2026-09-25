import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// Live defect 4 without a live runtime: `CreateContainer` succeeded and
/// `StartContainer` ~20 ms later answered `notFound: container with ID … not
/// found`. container-apiserver answers bootstrap that way only when the id
/// is missing from its container table, which `containerCreate` fills under
/// the same lock before it replies — so another client deleted the
/// container in between, typically an unfiltered prune: the runtime lists a
/// created, never-started container as `stopped`.
///
///  - `bootstrapForStart` retries a `notFound` only while the runtime still
///    lists the container (bounded, logged), and never masks a real
///    deletion: a container that is gone fails `not_found` at once, naming
///    what happened;
///  - `isPrunable` keeps a prune off a container created moments ago that
///    has never started, whatever the prune's filters.
final class NativeStartGuardsTests: XCTestCase {

    private static let noWait: [Duration] = [.zero, .zero, .zero]

    private static func runtimeNotFound(_ id: String) -> MicropodError {
        .message("notFound: container with ID \(id) not found")
    }

    // MARK: bootstrapForStart

    func testNotFoundWhileStillListedIsRetriedUntilBootstrapSucceeds() async throws {
        let script = Script(bootstrapFailures: 2, listed: [true, true])
        let log = Lines()

        try await NativeContainerService.bootstrapForStart(
            id: "cf-attempt-1", backoff: Self.noWait,
            bootstrap: { try await script.bootstrap("cf-attempt-1") },
            exists: { await script.exists() },
            log: log.append)

        let calls = await script.bootstrapCalls
        XCTAssertEqual(calls, 3, "two notFound answers, then the bootstrap that succeeds")
        XCTAssertEqual(log.all.count, 2, "every retry is logged: \(log.all)")
        XCTAssertTrue(log.all.allSatisfy { $0.contains("cf-attempt-1") && $0.contains("retrying") }, "\(log.all)")
    }

    /// A container someone else deleted is not retried and not masked: the
    /// start fails `not_found` straight away and says why.
    func testNotFoundForADeletedContainerFailsAtOnceNamingTheDeletion() async throws {
        let script = Script(bootstrapFailures: .max, listed: [false])
        let log = Lines()

        do {
            try await NativeContainerService.bootstrapForStart(
                id: "cf-attempt-2", backoff: Self.noWait,
                bootstrap: { try await script.bootstrap("cf-attempt-2") },
                exists: { await script.exists() },
                log: log.append)
            XCTFail("a deleted container must not start")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "not_found")
            let message = error.localizedDescription
            XCTAssertTrue(message.hasPrefix("notFound: container with ID cf-attempt-2 not found"), message)
            XCTAssertTrue(message.contains("deleted"), message)
        }
        let (calls, lookups) = (await script.bootstrapCalls, await script.lookups)
        XCTAssertEqual(calls, 1, "no retry once the runtime no longer lists the container")
        XCTAssertEqual(lookups, 1)
        XCTAssertEqual(log.all.count, 1, "the deletion is logged: \(log.all)")
        XCTAssertTrue(log.all.first?.contains("cf-attempt-2") == true, "\(log.all)")
    }

    /// Deleted while the retries run: the next lookup ends them.
    func testDeletionBetweenRetriesEndsThem() async throws {
        let script = Script(bootstrapFailures: .max, listed: [true, false])

        do {
            try await NativeContainerService.bootstrapForStart(
                id: "c", backoff: Self.noWait,
                bootstrap: { try await script.bootstrap("c") },
                exists: { await script.exists() },
                log: { _ in })
            XCTFail("a deleted container must not start")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "not_found")
            XCTAssertTrue(error.localizedDescription.contains("deleted"), error.localizedDescription)
        }
        let calls = await script.bootstrapCalls
        XCTAssertEqual(calls, 2)
    }

    /// Still listed but never bootstrappable: one retry per backoff step,
    /// then the runtime's own notFound stands.
    func testRetriesAreBoundedByTheBackoffSteps() async throws {
        let script = Script(bootstrapFailures: .max, listed: Array(repeating: true, count: 10))
        let log = Lines()

        do {
            try await NativeContainerService.bootstrapForStart(
                id: "c", backoff: Self.noWait,
                bootstrap: { try await script.bootstrap("c") },
                exists: { await script.exists() },
                log: log.append)
            XCTFail("expected the last notFound")
        } catch {
            XCTAssertEqual(error.localizedDescription, Self.runtimeNotFound("c").localizedDescription)
        }
        let calls = await script.bootstrapCalls
        XCTAssertEqual(calls, 1 + Self.noWait.count)
        XCTAssertEqual(log.all.count, Self.noWait.count + 1, "each retry and the give-up are logged: \(log.all)")
    }

    /// Only `notFound` is looked into; every other bootstrap failure is
    /// thrown as it came, without a lookup.
    func testOtherBootstrapErrorsAreNotRetried() async throws {
        let script = Script(bootstrapFailures: 0, listed: [])
        let invalidState = MicropodError.message("invalidState: container c is stopping")

        do {
            try await NativeContainerService.bootstrapForStart(
                id: "c", backoff: Self.noWait,
                bootstrap: {
                    try await script.bootstrap("c")
                    throw invalidState
                },
                exists: { await script.exists() },
                log: { _ in })
            XCTFail("expected the bootstrap error")
        } catch {
            XCTAssertEqual(error.localizedDescription, invalidState.localizedDescription)
        }
        let (calls, lookups) = (await script.bootstrapCalls, await script.lookups)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(lookups, 0)
    }

    /// A lookup that fails cannot tell deleted from still there: the
    /// runtime's notFound stands, unretried and unrelabelled.
    func testFailedLookupKeepsTheRuntimeAnswer() async throws {
        let script = Script(bootstrapFailures: .max, listed: [])

        do {
            try await NativeContainerService.bootstrapForStart(
                id: "c", backoff: Self.noWait,
                bootstrap: { try await script.bootstrap("c") },
                exists: { throw MicropodError.transport("com.apple.container.apiserver: Connection interrupted") },
                log: { _ in })
            XCTFail("expected the bootstrap error")
        } catch {
            XCTAssertEqual(error.localizedDescription, Self.runtimeNotFound("c").localizedDescription)
        }
        let calls = await script.bootstrapCalls
        XCTAssertEqual(calls, 1)
    }

    // MARK: isPrunable

    /// The apiserver's `ContainerSnapshot` as `containerList` returns it,
    /// through the same transform `entries()` decodes.
    private func entry(created: Date?, started: Date?) throws -> ContainerListEntry {
        var configuration: [String: JSONValue] = ["id": .string("c")]
        if let created {
            configuration["creationDate"] = .number(created.timeIntervalSinceReferenceDate)
        }
        var snapshot: [String: JSONValue] = [
            "configuration": .object(configuration), "status": .string("stopped"), "networks": .array([]),
        ]
        if let started {
            snapshot["startedDate"] = .number(started.timeIntervalSinceReferenceDate)
        }
        let data = try SnapshotTransform.toManagedArrayData(JSONEncoder().encode([JSONValue.object(snapshot)]))
        let entries = try MicropodJSON.decodeArray(ContainerListEntry.self, from: data, context: "test")
        return try XCTUnwrap(entries.first)
    }

    func testPruneSkipsAFreshContainerThatHasNeverStarted() throws {
        let now = Date()
        let fresh = try entry(created: now.addingTimeInterval(-2), started: nil)
        XCTAssertFalse(
            NativeContainerService.isPrunable(fresh, now: now),
            "created 2 s ago and never started: its client's start is on the way")
    }

    func testPruneTakesAnOldContainerThatNeverStarted() throws {
        let now = Date()
        let old = try entry(
            created: now.addingTimeInterval(-NativeContainerService.unstartedPruneGrace - 5), started: nil)
        XCTAssertTrue(NativeContainerService.isPrunable(old, now: now))
    }

    func testPruneTakesAFreshContainerThatRanAndExited() throws {
        let now = Date()
        let exited = try entry(created: now.addingTimeInterval(-3), started: now.addingTimeInterval(-2))
        XCTAssertNotNil(exited.status.startedDate)
        XCTAssertTrue(NativeContainerService.isPrunable(exited, now: now))
    }

    /// No readable creation date: nothing proves the container is fresh.
    func testPruneTakesAContainerWithoutACreationDate() throws {
        XCTAssertTrue(NativeContainerService.isPrunable(try entry(created: nil, started: nil), now: Date()))
    }
}

/// Scripted runtime: `bootstrap` answers notFound `bootstrapFailures` times,
/// `exists` answers from `listed` in order (false once it runs out).
private actor Script {
    private var bootstrapFailures: Int
    private var listed: [Bool]
    private(set) var bootstrapCalls = 0
    private(set) var lookups = 0

    init(bootstrapFailures: Int, listed: [Bool]) {
        self.bootstrapFailures = bootstrapFailures
        self.listed = listed
    }

    func bootstrap(_ id: String) throws {
        bootstrapCalls += 1
        guard bootstrapFailures > 0 else { return }
        bootstrapFailures -= 1
        throw MicropodError.message("notFound: container with ID \(id) not found")
    }

    func exists() -> Bool {
        lookups += 1
        return listed.isEmpty ? false : listed.removeFirst()
    }
}

/// Log lines the policy wrote, from any thread.
private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var all: [String] { lock.withLock { lines } }

    func append(_ line: String) { lock.withLock { lines.append(line) } }
}
