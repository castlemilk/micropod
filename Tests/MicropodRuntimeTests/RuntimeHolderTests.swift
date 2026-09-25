import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// `RuntimeHolder` — the live backend behind `MicropodAPI`. An API started
/// while the runtime was down resolves to the CLI; the holder re-resolves
/// lazily (rate-limited) and swaps to native once the apiserver answers.
/// Resolvers here are scripted closures, so no runtime is needed; each
/// `RuntimeServices` is tagged through `health.apiServerVersion` so the
/// tests can tell which instance is current.
final class RuntimeHolderTests: XCTestCase {

    private static let interval: Duration = .milliseconds(300)
    /// Comfortably past `interval` — `Task.sleep` and the holder share the
    /// continuous clock, so this is always "after the interval".
    private static let pastInterval: Duration = .milliseconds(350)

    func testRefreshWithinTheIntervalIsANoOp() async throws {
        let resolver = ScriptedResolver([.native])
        let holder = RuntimeHolder(
            initial: Self.services(.cli, tag: "initial"), resolve: resolver.resolve, minInterval: .seconds(60))

        let refreshed = await holder.refreshIfNeeded()
        XCTAssertEqual(refreshed.kind, .cli)
        XCTAssertEqual(refreshed.health?.apiServerVersion, "initial")
        let calls = await resolver.calls
        XCTAssertEqual(calls, 0, "the start-up resolution counts as the last attempt")
    }

    func testSwapsToNativeAfterTheIntervalThenNeverReResolves() async throws {
        let resolver = ScriptedResolver([.cli, .cli, .native])
        let holder = RuntimeHolder(
            initial: Self.services(.cli, tag: "initial"), resolve: resolver.resolve, minInterval: Self.interval)

        try await Task.sleep(for: Self.pastInterval)
        var refreshed = await holder.refreshIfNeeded()
        XCTAssertEqual(refreshed.kind, .cli)
        XCTAssertEqual(
            refreshed.health?.apiServerVersion, "initial",
            "a CLI re-resolution keeps the current services (and their state)")
        var calls = await resolver.calls
        XCTAssertEqual(calls, 1)

        refreshed = await holder.refreshIfNeeded()
        calls = await resolver.calls
        XCTAssertEqual(calls, 1, "every attempt restarts the interval")

        try await Task.sleep(for: Self.pastInterval)
        refreshed = await holder.refreshIfNeeded()
        XCTAssertEqual(refreshed.kind, .cli)
        calls = await resolver.calls
        XCTAssertEqual(calls, 2)

        try await Task.sleep(for: Self.pastInterval)
        refreshed = await holder.refreshIfNeeded()
        XCTAssertEqual(refreshed.kind, .native)
        XCTAssertEqual(refreshed.health?.apiServerVersion, "native-3")
        let current = await holder.current
        XCTAssertEqual(current.kind, .native, "the swap is visible to every later reader")
        XCTAssertEqual(current.health?.apiServerVersion, "native-3")

        try await Task.sleep(for: Self.pastInterval)
        refreshed = await holder.refreshIfNeeded()
        XCTAssertEqual(refreshed.health?.apiServerVersion, "native-3")
        refreshed = await holder.refreshIfNeeded(force: true)
        XCTAssertEqual(refreshed.health?.apiServerVersion, "native-3")
        calls = await resolver.calls
        XCTAssertEqual(calls, 3, "a live native backend is never re-resolved, even when forced")
    }

    func testForceBypassesTheInterval() async throws {
        let resolver = ScriptedResolver([.native])
        let holder = RuntimeHolder(
            initial: Self.services(.cli, tag: "initial"), resolve: resolver.resolve, minInterval: .seconds(60))

        let refreshed = await holder.refreshIfNeeded(force: true)
        XCTAssertEqual(refreshed.kind, .native)
        let calls = await resolver.calls
        XCTAssertEqual(calls, 1)
    }

    func testConcurrentRefreshesShareOneResolution() async throws {
        let resolver = ScriptedResolver([.native], delay: .milliseconds(200))
        let holder = RuntimeHolder(
            initial: Self.services(.cli, tag: "initial"), resolve: resolver.resolve, minInterval: .seconds(60))

        async let first = holder.refreshIfNeeded(force: true)
        async let second = holder.refreshIfNeeded(force: true)
        let results = await [first, second]

        XCTAssertEqual(results.map(\.kind), [.native, .native], "a joiner sees the swap, not the stale backend")
        XCTAssertEqual(results.map { $0.health?.apiServerVersion }, ["native-1", "native-1"])
        let calls = await resolver.calls
        XCTAssertEqual(calls, 1, "an in-flight resolution is joined, never duplicated")
    }

    /// `container system stop` unregisters the apiserver: XPC invalidates
    /// the connection for good, so a native backend holding it is dead
    /// weight. The holder re-resolves it like a CLI backend and adopts
    /// whatever the resolver finds — here the CLI, while the runtime is down.
    func testInvalidatedNativeConnectionIsReResolved() async throws {
        let api = APIServerClient(service: "com.micropod.tests.absent.\(UUID().uuidString)")
        _ = try? await api.ping(timeout: .seconds(5))
        XCTAssertTrue(api.isInvalidated, "an unregistered mach service invalidates the connection")

        let resolver = ScriptedResolver([.cli])
        let holder = RuntimeHolder(
            initial: Self.services(.native, tag: "dead", api: api), resolve: resolver.resolve,
            minInterval: .seconds(60))

        let unforced = await holder.refreshIfNeeded()
        XCTAssertEqual(unforced.health?.apiServerVersion, "dead", "still rate-limited without force")

        let refreshed = await holder.refreshIfNeeded(force: true)
        XCTAssertEqual(refreshed.kind, .cli)
        XCTAssertEqual(refreshed.health?.apiServerVersion, "cli-1")
        let calls = await resolver.calls
        XCTAssertEqual(calls, 1)
    }

    // MARK: - Fixtures

    private static let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/usr/bin/false"))

    fileprivate static func services(
        _ kind: RuntimeBackendKind, tag: String, api: APIServerClient? = nil
    ) -> RuntimeServices {
        RuntimeServices(
            kind: kind,
            containers: ContainerService(client: client),
            logs: LogStreamer(client: client),
            stats: StatsSampler(client: client),
            volumes: VolumeService(client: client),
            api: api,
            health: APIServerHealth(
                apiServerVersion: tag, apiServerCommit: "", apiServerBuild: "", apiServerAppName: "",
                appRoot: nil, installRoot: nil, logRoot: nil),
            exitCodes: kind == .native ? ExitCodeRegistry() : nil)
    }
}

/// Answers each resolution with the next scripted backend kind (the last one
/// repeats), tagged "<kind>-<call number>", and counts the calls.
private actor ScriptedResolver {
    private let script: [RuntimeBackendKind]
    private let delay: Duration?
    private(set) var calls = 0

    init(_ script: [RuntimeBackendKind], delay: Duration? = nil) {
        self.script = script
        self.delay = delay
    }

    nonisolated var resolve: @Sendable () async -> RuntimeServices {
        { await self.next() }
    }

    private func next() async -> RuntimeServices {
        calls += 1
        let call = calls
        let kind = script[min(call, script.count) - 1]
        if let delay { try? await Task.sleep(for: delay) }
        return RuntimeHolderTests.services(kind, tag: "\(kind.rawValue)-\(call)")
    }
}
