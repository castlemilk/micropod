import Darwin
import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// Readiness and the cache disk from live machine state, over a fake guest
/// Docker API: installed assets alone are never `running`, and a host
/// `caches.ext4` alone is never a mounted cache disk.
final class HVFMachineReadinessTests: XCTestCase {
    private var root: URL!
    private var held: [HVFFileLock] = []
    private var server: FakeDockerServer?

    override func setUp() {
        // Short on purpose: run/docker.sock must fit sockaddr_un.
        root = URL(fileURLWithPath: "/tmp/mphvf-y-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() {
        server?.stop()
        for lock in held { lock.release() }
        try? FileManager.default.removeItem(at: root)
    }

    private var layout: HVFMachineLayout { HVFMachineLayout(root: root) }
    private var client: HVFMachineClient { HVFMachineClient(layout: layout, environment: [:]) }

    /// Placeholder assets; with `bundle`, a tool bundle that ships BuildKit
    /// and an engine that attaches caches.
    private func install(bundle: Bool = true) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: layout.tools.appendingPathComponent("runner/bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: layout.runDirectory, withIntermediateDirectories: true)
        for url in [
            layout.vmm, layout.kernel, layout.initrd, layout.disk,
            layout.tools.appendingPathComponent("runner/start.sh"),
        ] {
            XCTAssertTrue(fm.createFile(atPath: url.path, contents: Data("x".utf8)))
        }
        XCTAssertEqual(chmod(layout.vmm.path, 0o755), 0)
        guard bundle else { return }
        for name in HVFMachineLayout.buildkitBundleFiles {
            XCTAssertTrue(fm.createFile(atPath: layout.tools.appendingPathComponent(name).path, contents: Data()))
        }
        XCTAssertEqual(chmod(layout.tools.appendingPathComponent("runner/bin/buildkitd").path, 0o755), 0)
        let manifest = #"{"cacheApi": 1, "capabilities": ["caches", "buildkit", "grpc-build"]}"#
        try Data(manifest.utf8).write(to: layout.toolsManifest)
    }

    private func supervise(_ phase: HVFMachinePhase) throws {
        held.append(try XCTUnwrap(try HVFFileLock.acquire(layout.supervisorLock, wait: .zero)))
        try HVFMachineState(phase: phase, supervisorPID: getpid(), vmmPID: 4242).save(to: layout.state)
    }

    private func guest(_ route: @escaping FakeDockerServer.Route = { _ in (404, Data()) }) throws -> FakeDockerServer {
        let server = try FakeDockerServer(path: layout.dockerSocket.path, route: route)
        self.server = server
        return server
    }

    // MARK: Readiness

    func testInstalledAssetsWithoutASupervisorAreStoppedNotRunning() async throws {
        try install()
        let readiness = await client.readiness()
        XCTAssertEqual(readiness.status, .stopped)
        XCTAssertFalse(readiness.isReady)
        XCTAssertEqual(readiness.features, ["hvf", "rootless", "proto-binary"], "nothing live is advertised")
        XCTAssertEqual(readiness.componentState, "stopped")

        // A stale `running` record with no supervisor behind it is stopped too.
        try HVFMachineState(phase: .running, supervisorPID: 1, vmmPID: 2).save(to: layout.state)
        let stale = await client.readiness()
        XCTAssertEqual(stale.status, .stopped)
        XCTAssertTrue(stale.detail.contains("exited without stopping"), stale.detail)
    }

    func testAMachineThatIsNotInstalledOrHasFailedSaysSo() async throws {
        let missing = await client.readiness()
        XCTAssertEqual(missing.status, .notInstalled)
        XCTAssertEqual(missing.componentState, "missing")
        XCTAssertTrue(missing.detail.contains("not installed"), missing.detail)

        try install()
        try HVFMachineState(phase: .failed, supervisorPID: 1, lastExitReason: "micropod-vmm exited 78")
            .save(to: layout.state)
        let failed = await client.readiness()
        XCTAssertEqual(failed.status, .failed)
        XCTAssertTrue(failed.detail.contains("exited 78"), failed.detail)
    }

    func testASupervisorThatIsStillBootingIsStarting() async throws {
        try install()
        try supervise(.starting)
        let starting = await client.readiness()
        XCTAssertEqual(starting.status, .starting)
        XCTAssertFalse(starting.features.contains("buildkit"))
        try HVFMachineState(phase: .stopping, supervisorPID: getpid()).save(to: layout.state)
        let stopping = await client.readiness()
        XCTAssertEqual(stopping.status, .stopping)
    }

    func testRunningIsNotReadyUntilTheGuestAnswers() async throws {
        try install()
        try supervise(.running)
        let noSocket = await client.readiness()
        XCTAssertEqual(noSocket.status, .notReady)
        XCTAssertTrue(noSocket.detail.contains("no Docker socket"), noSocket.detail)

        // Something is at the socket path, but no guest answers on it.
        XCTAssertTrue(FileManager.default.createFile(atPath: layout.dockerSocket.path, contents: Data()))
        let silent = await client.readiness(pingTimeout: .milliseconds(200))
        XCTAssertEqual(silent.status, .notReady)
        XCTAssertTrue(silent.detail.contains("did not answer _ping"), silent.detail)
        XCTAssertEqual(silent.features, ["hvf", "rootless", "proto-binary"])
    }

    func testARunningMachineThatAnswersIsReadyAndPingsOncePerWindow() async throws {
        try install()
        try supervise(.running)
        let server = try guest()
        let ready = await client.readiness()
        XCTAssertEqual(ready.status, .running)
        XCTAssertTrue(ready.isReady)
        XCTAssertEqual(ready.features, ["hvf", "rootless", "proto-binary", "caches-v2", "buildkit"])
        XCTAssertEqual(ready.componentState, "running")
        let again = await client.readiness()
        XCTAssertEqual(again.status, .running)
        XCTAssertEqual(server.requests.map(\.path), ["/_ping"], "a fresh answer stands for the window")

        // Features follow the installed bundle, not a fixed list.
        try FileManager.default.removeItem(at: layout.tools.appendingPathComponent("runner/bin/buildkitd"))
        try FileManager.default.removeItem(at: layout.toolsManifest)
        let plain = await client.readiness()
        XCTAssertEqual(plain.status, .running)
        XCTAssertEqual(plain.features, ["hvf", "rootless", "proto-binary"])
    }

    // MARK: Cache disk

    // MARK: Starting a default machine that is down

    /// Down without a stop being asked for (no state since boot, or a
    /// supervisor that gave up): started once, reported `starting`. Stopped
    /// on request: left stopped, nothing started.
    func testADownMachineIsStartedOnceUnlessItWasStoppedOnRequest() async throws {
        try install()
        HVFMachineAutostart.reset()
        defer { HVFMachineAutostart.reset() }
        let starts = LockedCount()
        let gate = UpdateFlag(false)
        let start: @Sendable () async throws -> Void = {
            starts.increment()
            while !gate.value { try await Task.sleep(for: .milliseconds(5)) }
        }
        let first = await client.readinessStartingWhenDown(start: start)
        XCTAssertEqual(first.status, .starting, first.detail)
        XCTAssertFalse(first.isReady)
        let second = await client.readinessStartingWhenDown(start: start)
        XCTAssertEqual(second.status, .starting)
        gate.value = true
        try await waitUntil { starts.value == 1 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(starts.value, 1, "single-flight")

        // A machine `machine stop` stopped stays stopped.
        HVFMachineAutostart.reset()
        try HVFMachineState(phase: .stopped, supervisorPID: 1, lastExitReason: "stopped on request").save(
            to: layout.state)
        let asked = await client.readinessStartingWhenDown(start: start)
        XCTAssertEqual(asked.status, .stopped)
        // And MICROPOD_HVF_AUTOSTART=0 turns it off.
        try FileManager.default.removeItem(at: layout.state)
        let off = HVFMachineClient(layout: layout, environment: ["MICROPOD_HVF_AUTOSTART": "0"])
        let plain = await off.readinessStartingWhenDown(start: start)
        XCTAssertEqual(plain.status, .stopped)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(starts.value, 1)
    }

    func testAFailedStartOnDemandIsNotRetriedAtOnceAndSaysWhy() async throws {
        try install()
        HVFMachineAutostart.reset()
        defer { HVFMachineAutostart.reset() }
        let starts = LockedCount()
        let start: @Sendable () async throws -> Void = {
            starts.increment()
            throw MicropodError.message("unavailable: micropod-vmm exited with status 1")
        }
        _ = await client.readinessStartingWhenDown(start: start)
        try await waitUntil { HVFMachineAutostart.lastFailure(layout.root.path) != nil }
        let after = await client.readinessStartingWhenDown(start: start)
        XCTAssertEqual(after.status, .stopped)
        XCTAssertTrue(after.detail.contains("exited with status 1"), after.detail)
        XCTAssertEqual(starts.value, 1)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: The canonical Docker socket

    /// `machine start` on a throwaway root must not take over the rig's
    /// `~/.micropod/docker.sock` while it points at a machine that answers.
    func testTheCanonicalLinkIsNotTakenFromAnotherLiveMachine() throws {
        let other = URL(fileURLWithPath: root.path + "-o")
        defer { try? FileManager.default.removeItem(at: other) }
        let otherLayout = HVFMachineLayout(root: other)
        try FileManager.default.createDirectory(at: otherLayout.runDirectory, withIntermediateDirectories: true)
        let live = try FakeDockerServer(path: otherLayout.dockerSocket.path) { _ in (200, Data("OK".utf8)) }
        defer { live.stop() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let canonical = root.appendingPathComponent("canonical.sock")
        try FileManager.default.createSymbolicLink(
            atPath: canonical.path, withDestinationPath: otherLayout.dockerSocket.path)

        XCTAssertThrowsError(try client.linkCanonicalDockerSocket(canonical: canonical)) { error in
            XCTAssertTrue("\(error)".contains("already points at"), "\(error)")
        }
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: canonical.path), otherLayout.dockerSocket.path)
        _ = try client.linkCanonicalDockerSocket(canonical: canonical, force: true)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: canonical.path), layout.dockerSocket.path)

        // A link to a socket nobody serves is stale and replaced.
        try FileManager.default.removeItem(at: canonical)
        try FileManager.default.createSymbolicLink(
            atPath: canonical.path, withDestinationPath: other.appendingPathComponent("gone.sock").path)
        _ = try client.linkCanonicalDockerSocket(canonical: canonical)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: canonical.path), layout.dockerSocket.path)
    }

    /// `machine start` and `machine restart` link the canonical socket by
    /// themselves only for the standard machine (`<home>/.micropod/hvf`) or
    /// when the caller asks; a throwaway root never does, even while nobody
    /// holds the link.
    func testOnlyTheStandardRootLinksItselfUnlessAsked() throws {
        let home = URL(fileURLWithPath: root.path + "-h")
        defer { try? FileManager.default.removeItem(at: home) }
        let standard = HVFMachineLayout(root: HVFMachineLayout.standardRoot(home: home))
        try FileManager.default.createDirectory(at: standard.root, withIntermediateDirectories: true)
        let alias = home.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: standard.root.path)
        let throwaway = HVFMachineLayout(root: root)
        func links(_ layout: HVFMachineLayout, _ environment: [String: String]) -> Bool {
            HVFMachineClient.autoLinksCanonicalDockerSocket(layout: layout, environment: environment, home: home)
        }
        XCTAssertTrue(standard.isStandardRoot(home: home))
        XCTAssertTrue(HVFMachineLayout(root: alias).isStandardRoot(home: home), "symlinks resolved")
        XCTAssertFalse(throwaway.isStandardRoot(home: home))

        XCTAssertTrue(links(standard, [:]))
        XCTAssertTrue(links(HVFMachineLayout(root: alias), [:]))
        XCTAssertFalse(links(standard, ["MICROPOD_LINK_DOCKER_SOCK": "0"]), "off for any root")
        XCTAssertFalse(links(throwaway, [:]), "a throwaway root nobody asked to link")
        XCTAssertFalse(links(throwaway, ["MICROPOD_HVF_ROOT": root.path]))
        XCTAssertTrue(links(throwaway, ["MICROPOD_DOCKER_SOCK": root.path + "/canonical.sock"]), "names the link")
        XCTAssertTrue(links(throwaway, ["MICROPOD_LINK_DOCKER_SOCK": "1"]), "asks for it")
        XCTAssertFalse(
            links(
                throwaway, ["MICROPOD_DOCKER_SOCK": root.path + "/canonical.sock", "MICROPOD_LINK_DOCKER_SOCK": "off"]))
    }

    /// The link a start makes: skipped on a throwaway root nobody asked to
    /// link (the canonical path is never even looked at), made where the
    /// caller named it, and refused over another machine's live socket.
    func testAThrowawayStartLinksOnlyWhereItsCallerSays() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard case .skipped(let note) = client.autoLinkCanonicalDockerSocket() else {
            return XCTFail("a throwaway root linked the canonical socket without being asked")
        }
        XCTAssertTrue(note.contains("is not the standard machine root"), note)
        XCTAssertTrue(note.contains("micropod machine link-socket"), note)

        let canonical = root.appendingPathComponent("canonical.sock")
        let asked = HVFMachineClient(layout: layout, environment: ["MICROPOD_DOCKER_SOCK": canonical.path])
        XCTAssertEqual(asked.autoLinkCanonicalDockerSocket(), .linked(canonical))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: canonical.path), layout.dockerSocket.path)

        let other = URL(fileURLWithPath: root.path + "-o")
        defer { try? FileManager.default.removeItem(at: other) }
        let otherLayout = HVFMachineLayout(root: other)
        try FileManager.default.createDirectory(at: otherLayout.runDirectory, withIntermediateDirectories: true)
        let live = try FakeDockerServer(path: otherLayout.dockerSocket.path) { _ in (200, Data("OK".utf8)) }
        defer { live.stop() }
        let otherClient = HVFMachineClient(
            layout: otherLayout, environment: ["MICROPOD_DOCKER_SOCK": canonical.path])
        XCTAssertEqual(otherClient.autoLinkCanonicalDockerSocket(), .linked(canonical), "this machine's socket is down")
        guard case .refused(let why) = asked.autoLinkCanonicalDockerSocket() else {
            return XCTFail("took the link from a live machine")
        }
        XCTAssertTrue(why.contains("already points at"), why)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: canonical.path), otherLayout.dockerSocket.path)
    }

    /// Only `machine start`/`restart` (through the policy above) and an
    /// explicit link-socket (CLI or API) reach the link: install, payload
    /// activation, rollback and on-demand starts have no path to it.
    func testOnlyStartRestartAndLinkSocketReachTheCanonicalLink() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var callers: [String: Int] = [:]
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for marker in ["linkCanonicalDockerSocket(", "autoLinkCanonicalDockerSocket("] {
                let count = text.components(separatedBy: "." + marker).count - 1
                if count > 0 { callers[url.lastPathComponent + " " + marker, default: 0] += count }
            }
        }
        XCTAssertEqual(
            callers,
            [
                // `machine link-socket`.
                "MachineCommands.swift linkCanonicalDockerSocket(": 1,
                // `machine start` and `machine restart`, through autoLink.
                "MachineCommands.swift autoLinkCanonicalDockerSocket(": 1,
                // POST /v1/rig/hvf/link-socket.
                "APIHandlers.swift linkCanonicalDockerSocket(": 1,
            ])
    }

    func testAHostCacheDiskFileIsNotAMountedCacheDisk() async throws {
        try install()
        XCTAssertTrue(FileManager.default.createFile(atPath: layout.cacheDisk.path, contents: Data("x".utf8)))
        let stopped = await client.cacheDiskObservation()
        XCTAssertTrue(stopped.configured)
        XCTAssertFalse(stopped.mounted, "the file exists, but nothing says the guest mounted it")
        XCTAssertNil(stopped.state)
        XCTAssertEqual(stopped.unknownReason, "the hvf machine is not running")
        XCTAssertEqual(stopped.jsonObject["source"] as? String, "unknown")
        XCTAssertEqual(stopped.sharedCaches, "unknown")
        XCTAssertTrue(stopped.summary.contains("unknown (the hvf machine is not running)"), stopped.summary)
    }

    func testTheGuestReportDecidesWhetherTheCacheDiskIsMounted() async throws {
        try install()
        try supervise(.running)
        let reply = LockedValue(Data(#"{"root": "/var/lib/micropod/caches", "scopes": {}}"#.utf8))
        let status = LockedValue(200)
        let server = try guest { request in
            request.path == "/micropod/caches" ? (status.value, reply.value) : (404, Data())
        }

        let older = await client.cacheDiskObservation()
        XCTAssertFalse(older.mounted, "a guest that does not report the disk is unknown, and unknown is not mounted")
        XCTAssertTrue(older.unknownReason?.contains("does not report cacheDisk") ?? false, "\(older)")
        XCTAssertEqual(server.requests.last?.query, ["stats": "0"], "the cheap inventory")

        // The disk would not mount: guest init turned shared caches off, and
        // the observation (machine status, rig health) says so.
        reply.value = Data(
            #"""
            {"cacheDisk": {"state": "unavailable", "device": "/dev/vdb", "mounted": false},
             "unavailable": "guest init found the cache disk missing or unmountable"}
            """#.utf8)
        let failed = await client.cacheDiskObservation()
        XCTAssertFalse(failed.mounted)
        XCTAssertEqual(failed.state, HVFCacheDiskState(state: "unavailable", device: "/dev/vdb", mounted: false))
        XCTAssertEqual(failed.sharedCachesOffReason, "guest init found the cache disk missing or unmountable")
        XCTAssertEqual(failed.sharedCaches, "off")
        XCTAssertEqual(failed.jsonObject["source"] as? String, "guest")
        XCTAssertEqual(failed.jsonObject["sharedCaches"] as? String, "off")
        XCTAssertEqual(
            failed.jsonObject["unavailable"] as? String, "guest init found the cache disk missing or unmountable")
        XCTAssertTrue(failed.summary.hasPrefix("UNAVAILABLE — shared caches are off this boot"), failed.summary)

        reply.value = Data(
            #"{"cacheDisk": {"state": "mounted", "device": "/dev/vdb", "mounted": true, "sizeBytes": 1024, "freeBytes": 512}}"#
                .utf8)
        let mounted = await client.cacheDiskObservation()
        XCTAssertTrue(mounted.mounted)
        XCTAssertEqual(mounted.sharedCaches, "on")
        XCTAssertEqual(mounted.jsonObject["freeBytes"] as? UInt64, 512)
        XCTAssertEqual(mounted.jsonObject["state"] as? String, "mounted")
        XCTAssertNil(mounted.jsonObject["unavailable"])
        XCTAssertFalse(mounted.configured, "no caches.ext4 on this host")

        // An engine built before the object sent guest init's word alone.
        reply.value = Data(#"{"cacheDisk": "mounted"}"#.utf8)
        let legacy = await client.cacheDiskObservation()
        XCTAssertTrue(legacy.mounted)
        XCTAssertEqual(legacy.state?.state, "mounted")

        status.value = 500
        let broken = await client.cacheDiskObservation()
        XCTAssertFalse(broken.mounted)
        XCTAssertEqual(broken.unknownReason, "the guest cache inventory answered HTTP 500")
    }
}

/// A value a fake guest's route reads while the test changes it.
final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
