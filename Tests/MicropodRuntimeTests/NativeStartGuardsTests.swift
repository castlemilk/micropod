import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// Live defect 4 without a live runtime: `CreateContainer` succeeded and
/// `StartContainer` answered `notFound: container with ID … not found`. The
/// apiserver log shows the failing calls were `containerStartProcess` and the
/// exit-code waiter's `containerWait` — bootstrap had succeeded — so the
/// container was deleted between bootstrap and startProcess. The apiserver
/// answers a start's calls that way only when the id is missing from its
/// container table, and keeps no tombstones: a deleted id and one that never
/// existed get the same answer.
///
///  - `startLookingIntoNotFound` looks into a `notFound` from bootstrap *or*
///    startProcess: a container the runtime still lists is retried (bounded,
///    logged); one it does not list fails `not_found` at once, logged, and
///    the error says it was deleted before it could start only when this
///    process created it — otherwise only that the runtime does not list it;
///  - `UnstartedCreates` is where a start learns that this process created
///    its container;
///  - `isPrunable` keeps a prune off a container created moments ago that
///    has never started, whatever the prune's filters.
final class NativeStartGuardsTests: XCTestCase {

    private static let noWait: [Duration] = [.zero, .zero, .zero]

    private static func runtimeNotFound(_ id: String) -> MicropodError {
        .message("notFound: container with ID \(id) not found")
    }

    /// Runs the policy against `script`, as `startTracked` wires it.
    private static func start(
        _ id: String, createdHere: Bool, _ script: Script, log: @escaping (String) -> Void = { _ in }
    ) async throws {
        try await NativeContainerService.startLookingIntoNotFound(
            id: id, createdHere: createdHere, backoff: noWait,
            bootstrap: { try await script.bootstrap(id) },
            startProcess: { try await script.startProcess(id) },
            exists: { await script.exists() },
            log: log)
    }

    // MARK: startLookingIntoNotFound — the container is gone

    /// The live signature: bootstrap succeeded, startProcess answered
    /// notFound, and the runtime no longer lists the container this process
    /// created. The start fails at once, logged, saying what happened.
    func testStartProcessNotFoundForAContainerCreatedHereFailsAtOnceNamingTheDeletion() async throws {
        let script = Script(startProcessFailures: .max, listed: [false])
        let log = Lines()

        do {
            try await Self.start("cf-attempt-1", createdHere: true, script, log: log.append)
            XCTFail("a deleted container must not start")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "not_found")
            let message = error.localizedDescription
            XCTAssertTrue(message.hasPrefix("notFound: container with ID cf-attempt-1 not found"), message)
            XCTAssertTrue(message.contains("deleted before it could start"), message)
        }
        let calls = await script.calls
        XCTAssertEqual(calls, Calls(bootstrap: 1, startProcess: 1, lookups: 1), "no retry once the container is gone")
        XCTAssertEqual(log.all.count, 1, "the deletion is logged: \(log.all)")
        XCTAssertTrue(log.all.first?.contains("cf-attempt-1") == true, "\(log.all)")
        XCTAssertTrue(log.all.first?.contains("startProcess") == true, "the log names the call: \(log.all)")
    }

    func testBootstrapNotFoundForAContainerCreatedHereFailsAtOnceNamingTheDeletion() async throws {
        let script = Script(bootstrapFailures: .max, listed: [false])
        let log = Lines()

        do {
            try await Self.start("cf-attempt-2", createdHere: true, script, log: log.append)
            XCTFail("a deleted container must not start")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "not_found")
            XCTAssertTrue(error.localizedDescription.contains("deleted before it could start"), "\(error)")
        }
        let calls = await script.calls
        XCTAssertEqual(calls, Calls(bootstrap: 1, startProcess: 0, lookups: 1))
        XCTAssertTrue(log.all.first?.contains("bootstrap") == true, "the log names the call: \(log.all)")
    }

    /// `start(id)` of an id this process did not create — it may never have
    /// existed: the error says only that the runtime does not list it.
    func testNotFoundForAnIdNotCreatedHereClaimsNoDeletion() async throws {
        for failing in ["bootstrap", "startProcess"] {
            let script =
                failing == "bootstrap"
                ? Script(bootstrapFailures: .max, listed: [false])
                : Script(startProcessFailures: .max, listed: [false])
            let log = Lines()

            do {
                try await Self.start("ghost", createdHere: false, script, log: log.append)
                XCTFail("\(failing): an unlisted container must not start")
            } catch {
                XCTAssertEqual(ConnectCodeMapping.code(for: error), "not_found", failing)
                XCTAssertEqual(
                    error.localizedDescription,
                    "notFound: container with ID ghost not found: the runtime does not list it", failing)
            }
            XCTAssertEqual(log.all.count, 1, "\(failing): \(log.all)")
            let line = log.all.first ?? ""
            XCTAssertTrue(line.contains("ghost") && line.contains(failing), line)
            for claim in ["deleted", "removed", "created", "another client"] {
                XCTAssertFalse(line.contains(claim), "\(failing): the log claims '\(claim)': \(line)")
            }
        }
    }

    // MARK: startLookingIntoNotFound — the container is still listed

    func testBootstrapNotFoundWhileStillListedIsRetriedUntilTheStartSucceeds() async throws {
        let script = Script(bootstrapFailures: 2, listed: [true, true])
        let log = Lines()

        try await Self.start("cf-attempt-3", createdHere: true, script, log: log.append)

        let calls = await script.calls
        XCTAssertEqual(calls, Calls(bootstrap: 3, startProcess: 1, lookups: 2))
        XCTAssertEqual(log.all.count, 2, "every retry is logged: \(log.all)")
        XCTAssertTrue(log.all.allSatisfy { $0.contains("cf-attempt-3") && $0.contains("retrying") }, "\(log.all)")
    }

    /// A startProcess notFound retries the whole start: bootstrap again (a
    /// no-op for a bootstrapped container), then startProcess.
    func testStartProcessNotFoundWhileStillListedRetriesTheWholeStart() async throws {
        let script = Script(startProcessFailures: 2, listed: [true, true])
        let log = Lines()

        try await Self.start("cf-attempt-4", createdHere: false, script, log: log.append)

        let calls = await script.calls
        XCTAssertEqual(calls, Calls(bootstrap: 3, startProcess: 3, lookups: 2))
        XCTAssertEqual(log.all.count, 2, "every retry is logged: \(log.all)")
        XCTAssertTrue(log.all.allSatisfy { $0.contains("startProcess") && $0.contains("retrying") }, "\(log.all)")
    }

    /// Deleted while the retries run: the next lookup ends them.
    func testDeletionBetweenRetriesEndsThem() async throws {
        let script = Script(startProcessFailures: .max, listed: [true, false])

        do {
            try await Self.start("c", createdHere: true, script)
            XCTFail("a deleted container must not start")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "not_found")
            XCTAssertTrue(error.localizedDescription.contains("deleted"), error.localizedDescription)
        }
        let calls = await script.calls
        XCTAssertEqual(calls, Calls(bootstrap: 2, startProcess: 2, lookups: 2))
    }

    /// Still listed but never startable: one retry per backoff step, then
    /// the runtime's own notFound stands.
    func testRetriesAreBoundedByTheBackoffSteps() async throws {
        let script = Script(startProcessFailures: .max, listed: Array(repeating: true, count: 10))
        let log = Lines()

        do {
            try await Self.start("c", createdHere: true, script, log: log.append)
            XCTFail("expected the last notFound")
        } catch {
            XCTAssertEqual(error.localizedDescription, Self.runtimeNotFound("c").localizedDescription)
        }
        let calls = await script.calls
        XCTAssertEqual(calls.startProcess, 1 + Self.noWait.count)
        XCTAssertEqual(log.all.count, Self.noWait.count + 1, "each retry and the give-up are logged: \(log.all)")
    }

    // MARK: startLookingIntoNotFound — not looked into

    /// Only `notFound` is looked into; every other failure of either call is
    /// thrown as it came, without a lookup or a retry.
    func testOtherErrorsAreNotLookedInto() async throws {
        let invalidState = MicropodError.message("invalidState: container c is stopping")
        for failing in ["bootstrap", "startProcess"] {
            let script = Script()
            do {
                try await NativeContainerService.startLookingIntoNotFound(
                    id: "c", createdHere: true, backoff: Self.noWait,
                    bootstrap: {
                        try await script.bootstrap("c")
                        if failing == "bootstrap" { throw invalidState }
                    },
                    startProcess: {
                        try await script.startProcess("c")
                        throw invalidState
                    },
                    exists: { await script.exists() },
                    log: { _ in })
                XCTFail("\(failing): expected the error")
            } catch {
                XCTAssertEqual(error.localizedDescription, invalidState.localizedDescription, failing)
            }
            let calls = await script.calls
            XCTAssertEqual(calls.bootstrap, 1, failing)
            XCTAssertEqual(calls.startProcess, failing == "bootstrap" ? 0 : 1, failing)
            XCTAssertEqual(calls.lookups, 0, failing)
        }
    }

    /// A lookup that fails cannot tell deleted from still there: the
    /// runtime's notFound stands, unretried and unrelabelled.
    func testFailedLookupKeepsTheRuntimeAnswer() async throws {
        let script = Script(startProcessFailures: .max)

        do {
            try await NativeContainerService.startLookingIntoNotFound(
                id: "c", createdHere: true, backoff: Self.noWait,
                bootstrap: { try await script.bootstrap("c") },
                startProcess: { try await script.startProcess("c") },
                exists: { throw MicropodError.transport("com.apple.container.apiserver: Connection interrupted") },
                log: { _ in })
            XCTFail("expected the startProcess error")
        } catch {
            XCTAssertEqual(error.localizedDescription, Self.runtimeNotFound("c").localizedDescription)
        }
        let calls = await script.calls
        XCTAssertEqual(calls.startProcess, 1)
    }

    // MARK: UnstartedCreates

    func testUnstartedCreatesRemembersACreateUntilRemoved() async {
        let creates = UnstartedCreates(capacity: 8)
        await creates.record("a")
        let recorded = await creates.contains("a")
        let other = await creates.contains("b")
        XCTAssertTrue(recorded)
        XCTAssertFalse(other, "an id this process never created is not claimed")
        await creates.remove("a")
        let removed = await creates.contains("a")
        XCTAssertFalse(removed)
    }

    /// Creates that are never started nor deleted here cannot grow the
    /// record without bound: the oldest record goes first, and recording an
    /// id again makes it the newest.
    func testUnstartedCreatesDropsTheOldestAtCapacity() async {
        let creates = UnstartedCreates(capacity: 2)
        await creates.record("a")
        await creates.record("b")
        await creates.record("a")
        await creates.record("c")
        let (a, b, c) = (await creates.contains("a"), await creates.contains("b"), await creates.contains("c"))
        XCTAssertTrue(a, "re-recorded, so newer than b")
        XCTAssertFalse(b, "the oldest record is dropped at capacity")
        XCTAssertTrue(c)
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

/// What the policy called.
private struct Calls: Equatable {
    var bootstrap = 0
    var startProcess = 0
    var lookups = 0
}

/// Scripted runtime: `bootstrap` and `startProcess` answer notFound their
/// `…Failures` times, `exists` answers from `listed` in order (false once it
/// runs out).
private actor Script {
    private var bootstrapFailures: Int
    private var startProcessFailures: Int
    private var listed: [Bool]
    private(set) var calls = Calls()

    init(bootstrapFailures: Int = 0, startProcessFailures: Int = 0, listed: [Bool] = []) {
        self.bootstrapFailures = bootstrapFailures
        self.startProcessFailures = startProcessFailures
        self.listed = listed
    }

    func bootstrap(_ id: String) throws {
        calls.bootstrap += 1
        guard bootstrapFailures > 0 else { return }
        bootstrapFailures -= 1
        throw MicropodError.message("notFound: container with ID \(id) not found")
    }

    func startProcess(_ id: String) throws {
        calls.startProcess += 1
        guard startProcessFailures > 0 else { return }
        startProcessFailures -= 1
        throw MicropodError.message("notFound: container with ID \(id) not found")
    }

    func exists() -> Bool {
        calls.lookups += 1
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
