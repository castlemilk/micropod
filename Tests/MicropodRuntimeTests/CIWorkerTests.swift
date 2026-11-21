import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

final class CIWorkerTests: XCTestCase {
    func testAutomaticCPUsUseTheFastestTierWithinHostAndVMLimits() throws {
        let policy = CIWorkerCPUCount.auto
        XCTAssertEqual(
            try policy.resolve(fastestCores: 6, activeCPUs: 18, minimum: 1, maximum: 32),
            .init(count: 6, source: .performanceLevel))
        XCTAssertEqual(try policy.resolve(fastestCores: 12, activeCPUs: 18, minimum: 1, maximum: 8).count, 8)
        XCTAssertEqual(try policy.resolve(fastestCores: 8, activeCPUs: 3, minimum: 1, maximum: 16).count, 3)
        XCTAssertEqual(
            try policy.resolve(fastestCores: nil, activeCPUs: 18, minimum: 1, maximum: 64),
            .init(count: 4, source: .fallback))
        XCTAssertEqual(try policy.resolve(fastestCores: 0, activeCPUs: 2, minimum: 1, maximum: 64).count, 2)
        XCTAssertThrowsError(try policy.resolve(fastestCores: 6, activeCPUs: 18, minimum: 1, maximum: 0))
        XCTAssertThrowsError(
            try CIWorkerCPUCount.fixed(6).resolve(fastestCores: 2, activeCPUs: 4, minimum: 1, maximum: 4))
        XCTAssertThrowsError(try CIWorkerCPUCount("0"))
        XCTAssertThrowsError(try CIWorkerCPUCount("65"))
    }

    func testCPUManifestRetainsLegacyIntegersAndResolvesAutoOnlyAtBoot() throws {
        for setting in [nil, "7", "auto"] as [String?] {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent(
                "cpu-" + UUID().uuidString.prefix(8))
            let base = ["MICROPOD_CI_HOME": home.path]
            var env = base
            env["MICROPOD_CI_CPUS"] = setting
            let worker = CIWorker(environment: env)
            try worker.prepareDirectory()
            defer { try? FileManager.default.removeItem(at: home) }
            let config = try worker.configuration(create: true)
            let manifest = try Data(contentsOf: home.appendingPathComponent("worker.json"))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
            if setting == "auto" {
                XCTAssertEqual(json["cpus"] as? String, "auto")
            } else {
                XCTAssertEqual(json["cpus"] as? Int, setting.flatMap(Int.init) ?? 4)
            }
            XCTAssertEqual(try CIWorker(environment: base).configuration(), config)
            env["MICROPOD_CI_CPUS"] = "8"
            XCTAssertThrowsError(try CIWorker(environment: env).configuration())
        }
    }

    func testDiscoveryUsesOnlyTheOwnedEndpointAndDoesNotStartAWorker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let registry = EngineRegistry(environment: [
            "MICROPOD_CI_HOME": root.path,
            "MICROPOD_RUNTIMES_CONFIG": root.appendingPathComponent("runtimes.json").path,
            "DOCKER_HOST": "tcp://127.0.0.1:1",
        ])
        let engine = try XCTUnwrap(registry.engine("ci") as? DockerEngine)
        let probe = await engine.probe()
        XCTAssertEqual(probe.endpoint, "unix://" + root.appendingPathComponent("docker.sock").path)
        XCTAssertFalse(probe.available)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertThrowsError(try registry.update("ci", enabled: true, endpoint: "unix:///var/run/docker.sock"))
    }

    func testStoppedCPUResizePreservesDiskAndOtherManifestFieldsAndRefusesLiveOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "resize-" + UUID().uuidString.prefix(8))
        let worker = CIWorker(environment: ["MICROPOD_CI_HOME": root.path])
        try worker.prepareDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try worker.configuration(create: true)
        let disk = Data("cached worker contents".utf8)
        try disk.write(to: worker.disk)
        let manifest = root.appendingPathComponent("worker.json")
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        fields["future_setting"] = "keep"
        try JSONSerialization.data(withJSONObject: fields).write(to: manifest)
        for name in ["start.lock", "worker.lock"] {
            let fd = open(root.appendingPathComponent(name).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            XCTAssertGreaterThanOrEqual(fd, 0)
            defer { close(fd) }
            XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
            XCTAssertThrowsError(try worker.setCPUs("auto"))
            XCTAssertEqual(try worker.configuration(), old)
        }
        _ = try worker.setCPUs("auto")
        _ = try worker.setCPUs("auto")
        let updated = try worker.configuration()
        XCTAssertEqual(updated.cpus, .auto)
        XCTAssertEqual(updated.worker, old.worker)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        XCTAssertEqual(saved["future_setting"] as? String, "keep")
        XCTAssertEqual(try Data(contentsOf: worker.disk), disk)
        _ = try worker.setCPUs("4")
        XCTAssertEqual(try worker.configuration(), old)
    }

    func testRunRejectsAWorkerWithAPendingStopBeforeConnectingOrLaunching() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ci-" + UUID().uuidString.prefix(8))
        let worker = CIWorker(environment: ["MICROPOD_CI_HOME": root.path])
        try worker.prepareDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try XCTUnwrap(RuntimeProcessBirth.read(getpid()))
        let instance = UUID()
        let session = CIWorker.Session(owner: owner, instance: instance, started: true)
        try JSONEncoder().encode(session).write(to: root.appendingPathComponent("session.json"))
        try Data().write(to: root.appendingPathComponent("stop-" + instance.uuidString))
        do {
            _ = try await worker.runEndpoint(executable: root.appendingPathComponent("unused"))
            XCTFail("A draining worker accepted a job")
        } catch {
            XCTAssertEqual(error.localizedDescription, "CI worker is stopping")
        }
    }

    func testWorkerPersistsItsKernelAndPublishedNetworkChoice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ci-" + UUID().uuidString.prefix(8))
        let base = ["MICROPOD_CI_HOME": root.path, "MICROPOD_CI_ENGINE": "containerd"]
        var env = base
        env["MICROPOD_CI_KERNEL"] = "/kernels/7.3.5/Image"
        env["MICROPOD_CI_PUBLISHED_PATH"] = "macvlan"
        let worker = CIWorker(environment: env)
        try worker.prepareDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try worker.configuration(create: true)
        XCTAssertEqual(config.kernel, env["MICROPOD_CI_KERNEL"])
        XCTAssertEqual(config.publishedPath, "macvlan")
        XCTAssertEqual(try CIWorker(environment: base).configuration(), config)
        env["MICROPOD_CI_PUBLISHED_PATH"] = "bridge"
        XCTAssertThrowsError(try CIWorker(environment: env).configuration())
        env["MICROPOD_CI_PUBLISHED_PATH"] = "unknown"
        XCTAssertThrowsError(try CIWorker(environment: env).configuration())
    }

    func testNetworkProbeRequiresAnAddressOnTheMac() throws {
        XCTAssertTrue(try CIWorker.hasLocalGateway("127.0.0.1"))
        XCTAssertFalse(try CIWorker.hasLocalGateway("192.0.2.254"))
        XCTAssertFalse(try CIWorker.hasLocalGateway("example.org"))
    }

    func testKernelMetricsDistinguishMissingSchedulerSupportFromAnActivePolicy() throws {
        var data: [String: Any] = ["boot": UUID().uuidString, "cpu": [:], "io": [:], "memory": [:]]
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        func read() throws -> CIWorker.KernelMetrics {
            try decoder.decode(CIWorker.KernelMetrics.self, from: JSONSerialization.data(withJSONObject: data))
        }
        XCTAssertNil(try read().schedExt)
        data["sched_ext"] = ["state": "disabled", "enable_seq": 0]
        XCTAssertEqual(try read().schedExt?.state, "disabled")
        XCTAssertNil(try read().schedExt?.ops)
        data["sched_ext"] = ["state": "enabled", "ops": "bpfland", "enable_seq": 2]
        XCTAssertEqual(try read().schedExt?.ops, "bpfland")
        XCTAssertEqual(try read().schedExt?.enableSeq, 2)
    }

    func testMetricsGroupsOverlappingScopeAndStoreNames() throws {
        XCTAssertNil(CIWorker.cacheStore("unrelated-gobuild", activeContainers: 5))
        XCTAssertNil(CIWorker.cacheStore("micropod-ci-scoped--npm", activeContainers: 0))
        let cache = try XCTUnwrap(CIWorker.cacheStore("micropod-ci-scoped-team-go-gobuild", activeContainers: 4))
        XCTAssertEqual(cache.store, "gobuild")
        XCTAssertEqual(cache.scope, "team-go")
        XCTAssertEqual(cache.activeContainers, 4)
    }

    func testWorkspaceUsesTheSamePhysicalPathAsDockerBindSources() throws {
        let directory = URL(fileURLWithPath: "/tmp/mp-share-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(try CIWorker.workspacePath(directory.path), "/private/tmp/" + directory.lastPathComponent)
        XCTAssertThrowsError(try CIWorker.workspacePath(directory.path, excluding: directory))
        XCTAssertThrowsError(try CIWorker.workspacePath("/"))
        XCTAssertThrowsError(try CIWorker.workspacePath("relative"))
    }

    func testPublishedLinkNeedsContinuouslyFailedProbesBeforeReplacingTheNIC() {
        var failure = CIWorker.PublishedLinkFailure()
        let start = ContinuousClock.now
        XCTAssertFalse(failure.confirmed(at: start))
        XCTAssertFalse(failure.confirmed(at: start + .seconds(5)))
        failure.clear()
        XCTAssertFalse(failure.confirmed(at: start + .seconds(6)))
        XCTAssertTrue(failure.confirmed(at: start + .seconds(12)))
    }

    func testInteractiveNativeAgentUsesInteractiveLaunchType() throws {
        let worker = CIWorker(environment: [
            "MICROPOD_CI_ENGINE": "containerd", "MICROPOD_CI_PORT_RELAY": "kqueue-interactive",
        ])
        let data = try worker.launchAgent(executable: URL(fileURLWithPath: "/bin/micropod"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["ProcessType"] as? String, "Interactive")
        XCTAssertEqual(
            (plist["EnvironmentVariables"] as? [String: String])?["MICROPOD_CI_PORT_RELAY"], "kqueue-interactive")
    }

    func testLaunchAgentRunsTheStableBinaryInTheSpecifiedWorkerDirectory() throws {
        let root = URL(fileURLWithPath: "/Volumes/CI/Worker directory")
        let worker = CIWorker(environment: [
            "MICROPOD_CI_HOME": root.path, "MICROPOD_CI_CPUS": "6", "CI_JOB_ID": "example",
            "MICROPOD_CI_PORT_RELAY": "kqueue", "MICROPOD_CI_PORT_PROFILE": "1",
        ])
        let binary = URL(fileURLWithPath: "/Applications/Micropod.app/Contents/MacOS/micropod")
        let data = try worker.launchAgent(executable: binary)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [binary.path, "ci", "serve"])
        XCTAssertEqual(
            plist["EnvironmentVariables"] as? [String: String],
            [
                "MICROPOD_CI_HOME": root.path, "MICROPOD_CI_CPUS": "6",
                "MICROPOD_CI_PORT_RELAY": "kqueue", "MICROPOD_CI_PORT_PROFILE": "1",
            ])
        XCTAssertNil(plist["ProcessType"])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["KeepAlive"] as? [String: Bool], ["Crashed": true])
    }
}
