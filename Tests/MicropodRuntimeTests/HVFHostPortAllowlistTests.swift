import Darwin
import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// Which host loopback ports the guest may reach (`--allow-host-port`): only
/// configured ones, never a control port, and never one a cache-policy URL
/// merely names.
final class HVFHostPortAllowlistTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        // Short on purpose: run/docker.sock must fit sockaddr_un.
        root = URL(fileURLWithPath: "/tmp/mphvf-p-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private let control = HVFHostPortAllowlist.defaultControlPorts

    private func config(
        goProxy: String? = nil, npmRegistry: String? = nil, allowHostPorts: [UInt16] = [],
        depproxyPort: UInt16 = HVFMachineConfig.defaultDepproxyPort
    ) -> HVFMachineConfig {
        HVFMachineConfig(
            allowHostPorts: allowHostPorts, depproxyPort: depproxyPort,
            cache: HVFMachineCachePolicy(goProxy: goProxy, npmRegistry: npmRegistry))
    }

    private func ports(_ config: HVFMachineConfig) -> [UInt16] {
        HVFVMMCommand.effectiveAllowHostPorts(config, controlPorts: control)
    }

    // MARK: Derivation

    func testAPolicyURLNamingAControlPortOpensNothing() throws {
        for url in ["http://10.42.0.1:45454/x", "http://host.micropod.internal:45455/v1.47"] {
            let config = config(npmRegistry: url)
            XCTAssertNoThrow(try config.cache?.validate(), "a well-formed URL is still a valid policy")
            XCTAssertEqual(ports(config), [], url)
            let allowlist = HVFHostPortAllowlist(config: config, controlPorts: control)
            XCTAssertEqual(allowlist.refused.count, 1, url)
            XCTAssertTrue(allowlist.refused[0].reason.contains("control port"), allowlist.refused[0].reason)
        }
        // A control port moved by the environment is refused too.
        let moved = HVFHostPortAllowlist.controlPorts(environment: [
            "MICROPOD_API_PORT": "19045", "MICROPOD_SHIM_TCP_PORT": "19046",
        ])
        XCTAssertEqual(moved, [45454, 45455, 19045, 19046])
        let config = config(goProxy: "http://10.42.0.1:19045/go|direct", allowHostPorts: [19046], depproxyPort: 19045)
        XCTAssertEqual(HVFVMMCommand.effectiveAllowHostPorts(config, controlPorts: moved), [])
    }

    func testTheDepproxyPortIsTheOnlyPortAPolicyOpens() {
        XCTAssertEqual(ports(config(goProxy: "http://10.42.0.1:7677/go|direct")), [7677])
        XCTAssertEqual(ports(config(npmRegistry: "http://host.micropod.internal:7677/npm")), [7677])
        XCTAssertEqual(ports(config(goProxy: "HTTP://Host.Docker.Internal:7677/go,direct")), [7677])

        let other = config(goProxy: "http://10.42.0.1:9000/go,direct")
        XCTAssertEqual(ports(other), [], "a gateway URL alone opens nothing")
        let refusal = HVFHostPortAllowlist(config: other, controlPorts: control).refused
        XCTAssertEqual(refusal.map(\.port), [9000])
        XCTAssertTrue(refusal[0].reason.contains("allowHostPorts"), refusal[0].reason)

        let configured = config(goProxy: "http://10.42.0.1:9000/go,direct", allowHostPorts: [9000])
        XCTAssertEqual(ports(configured), [9000])
        XCTAssertEqual(HVFHostPortAllowlist(config: configured, controlPorts: control).refused, [])

        let moved = config(goProxy: "http://10.42.0.1:7700/go", depproxyPort: 7700)
        XCTAssertEqual(ports(moved), [7700])
        XCTAssertEqual(ports(config(goProxy: "http://10.42.0.1:7677/go", depproxyPort: 0)), [])
    }

    func testThePublishedNetworkGatewayAndOrdinaryURLsOpenNothing() {
        let published = config(goProxy: "http://10.43.0.1:7677/go|direct", npmRegistry: "http://10.43.0.1:7677/npm")
        XCTAssertEqual(ports(published), [], "10.43.0.1 never reaches host loopback")
        let refused = HVFHostPortAllowlist(config: published, controlPorts: control).refused
        XCTAssertEqual(refused.map(\.field), ["goProxy", "npmRegistry"])
        XCTAssertTrue(refused[0].reason.contains("published-port network"), refused[0].reason)

        let external = config(goProxy: "https://proxy.golang.org,direct", npmRegistry: "https://registry.npmjs.org/")
        XCTAssertEqual(ports(external), [])
        XCTAssertEqual(HVFHostPortAllowlist(config: external, controlPorts: control).refused, [])

        for privileged in ["http://10.42.0.1/go", "https://10.42.0.1/go", "http://10.42.0.1:22/go"] {
            let config = config(goProxy: privileged, allowHostPorts: [8080])
            XCTAssertEqual(ports(config), [8080], privileged)
            let reason = HVFHostPortAllowlist(config: config, controlPorts: control).refused.first?.reason ?? ""
            XCTAssertTrue(reason.contains("below 1024"), reason)
        }
    }

    func testExplicitPortsAreOpenedAsConfigured() throws {
        let config = config(allowHostPorts: [9000, 8080, 9000])
        XCTAssertEqual(ports(config), [8080, 9000])
        try installAssets()
        let argv = try HVFVMMCommand.arguments(layout: HVFMachineLayout(root: root), config: config, parentPID: 1)
        let opened = argv.indices.filter { argv[$0] == "--allow-host-port" }.map { argv[$0 + 1] }
        XCTAssertEqual(opened, ["8080", "9000"])
        let none = try HVFVMMCommand.arguments(
            layout: HVFMachineLayout(root: root), config: self.config(npmRegistry: "http://10.42.0.1:45454/x"),
            parentPID: 1)
        XCTAssertFalse(none.contains("--allow-host-port"), "\(none)")
        XCTAssertFalse(none.contains("45454"))
    }

    // MARK: Validation

    func testGoProxyIsSplitOnBothSeparatorsAndEachEntryValidated() {
        for bad in [
            "http://x|file:///p", "file:///p", "http://a,file:///p", "http://a b", "http://h/%zz", "|", ",|,",
            "ftp://h", "http://", "http:/x", "http://h:0/x", "http://h:70000/x", "socks5://h:1080",
        ] {
            XCTAssertThrowsError(try HVFMachineCachePolicy(goProxy: bad).validate(), bad)
        }
        for good in [
            "http://10.42.0.1:7677/go|direct", "https://proxy.golang.org,direct", "direct", "off", "direct|off",
            "http://a,,direct", "http://a, https://b | direct", "HTTP://Host.Micropod.Internal:7677/go",
        ] {
            XCTAssertNoThrow(try HVFMachineCachePolicy(goProxy: good).validate(), good)
        }
        XCTAssertEqual(
            HVFMachineCachePolicy.goProxyElements("http://a, https://b | direct,,"),
            ["http://a", "https://b", "direct"])
    }

    func testNpmRegistryIsOneStrictURL() {
        for bad in ["not-a-url", "http://a|http://b", "http://a,http://b", "file:///r", "https://", "http://r/ x"] {
            XCTAssertThrowsError(try HVFMachineCachePolicy(npmRegistry: bad).validate(), bad)
        }
        for good in ["https://registry.npmjs.org/", "http://10.42.0.1:7677/npm", "http://u:p@h.internal:8080/r"] {
            XCTAssertNoThrow(try HVFMachineCachePolicy(npmRegistry: good).validate(), good)
        }
    }

    func testConfigRefusesControlPortsAndKeepsTheDepproxyPort() throws {
        // Control ports, and privileged ports (sshd, CUPS, SMB) even when named.
        for port: UInt16 in [45454, 45455, 0, 22, 80, 1023] {
            XCTAssertThrowsError(try HVFMachineConfig(allowHostPorts: [8080, port]).validate(), "\(port)")
        }
        XCTAssertNoThrow(try HVFMachineConfig(allowHostPorts: [8080, 1024]).validate())
        // The VMM flag itself cannot be smuggled past the denylist.
        for extra in [["--allow-host-port", "45454"], ["--allow-host-port=45454"]] {
            XCTAssertThrowsError(try HVFMachineConfig(extraArguments: extra).validate(), "\(extra)") { error in
                XCTAssertTrue(error.localizedDescription.contains("allowHostPorts"), error.localizedDescription)
            }
        }
        XCTAssertNoThrow(try HVFMachineConfig(extraArguments: ["--balloon"]).validate())
        for port: UInt16 in [80, 1023, 45454, 45455] {
            XCTAssertThrowsError(try HVFMachineConfig(depproxyPort: port).validate(), "\(port)")
        }
        XCTAssertNoThrow(try HVFMachineConfig(depproxyPort: 0).validate())

        let url = root.appendingPathComponent("machine.json")
        try HVFMachineConfig().save(to: url)
        XCTAssertFalse(
            try String(contentsOf: url, encoding: .utf8).contains("depproxyPort"), "the default is not written")
        XCTAssertEqual(try HVFMachineConfig.load(from: url).depproxyPort, 7677)
        try HVFMachineConfig(depproxyPort: 7700).save(to: url)
        XCTAssertEqual(try HVFMachineConfig.load(from: url).depproxyPort, 7700)
        try Data(#"{"allowHostPorts": [45454]}"#.utf8).write(to: url)
        XCTAssertThrowsError(try HVFMachineConfig.load(from: url)) { error in
            XCTAssertTrue(error.localizedDescription.contains("control port"), error.localizedDescription)
        }
    }

    /// A machine.json that no longer validates is the machine's problem in
    /// `machine status` and readiness, never replaced by the defaults.
    func testAMachineConfigThatFailsValidationIsTheMachinesProblem() throws {
        let layout = HVFMachineLayout(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"allowHostPorts": [45454]}"#.utf8).write(to: layout.config)
        let problem = try XCTUnwrap(layout.configurationProblem())
        XCTAssertTrue(problem.contains("control port"), problem)
        XCTAssertTrue(problem.contains(layout.config.path), problem)
        try HVFMachineConfig().save(to: layout.config)
        XCTAssertNil(layout.configurationProblem())
    }

    // MARK: What is open now and at the next start

    func testStatusShowsAPolicyPortTheRunningMachineHasNotOpened() {
        let next = config(goProxy: "http://10.42.0.1:7677/go|direct")
        let running = HVFMachineState(phase: .running, supervisorPID: 1, vmmPID: 2, allowHostPorts: [])

        let pending = HVFHostPortStatus(config: next, state: running, supervisorAlive: true)
        XCTAssertEqual(pending.open, [])
        XCTAssertEqual(pending.nextStart, [7677])
        XCTAssertTrue(pending.restartPending)
        XCTAssertTrue(pending.summary.contains("restart to apply"), pending.summary)
        XCTAssertEqual(pending.policyWarnings.count, 1)
        XCTAssertTrue(pending.policyWarnings[0].contains("7677"), pending.policyWarnings[0])

        var opened = running
        opened.allowHostPorts = [7677]
        let current = HVFHostPortStatus(config: next, state: opened, supervisorAlive: true)
        XCTAssertFalse(current.restartPending)
        XCTAssertEqual(current.summary, "7677 (cache policy)")
        XCTAssertEqual(current.policyWarnings, [])

        let stopped = HVFHostPortStatus(config: next, state: opened, supervisorAlive: false)
        XCTAssertNil(stopped.open, "a dead supervisor's record is not what is open")
        XCTAssertFalse(stopped.restartPending)
        XCTAssertEqual(stopped.policyWarnings, [], "a stopped machine opens it when it starts")
        XCTAssertTrue(stopped.summary.hasSuffix("at the next start"), stopped.summary)

        var legacy = running
        legacy.allowHostPorts = nil
        let unknown = HVFHostPortStatus(config: next, state: legacy, supervisorAlive: true)
        XCTAssertTrue(unknown.restartPending)
        XCTAssertTrue(unknown.summary.hasPrefix("unknown"), unknown.summary)
        XCTAssertEqual(unknown.policyWarnings.count, 1)

        let refused = HVFHostPortStatus(
            config: config(goProxy: "http://10.43.0.1:7677/go|direct"), state: opened, supervisorAlive: true)
        XCTAssertEqual(refused.nextStart, [])
        XCTAssertEqual(refused.policyWarnings.count, 1)
        XCTAssertTrue(refused.policyWarnings[0].contains("10.43.0.1"), refused.policyWarnings[0])
        XCTAssertTrue(refused.summary.contains("1 cache policy URL open nothing"), refused.summary)
    }

    func testThePolicyUpdateResponseAddsWarningsOnlyWhenThereAreSome() throws {
        let policy = HVFMachineCachePolicy(sharedL0: true, goProxy: "http://10.42.0.1:7677/go|direct")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plain = try encoder.encode(HVFCachePolicyUpdateResponse(policy: policy, warnings: []))
        XCTAssertEqual(plain, try encoder.encode(policy), "no warnings: exactly the policy")

        let warned = try encoder.encode(HVFCachePolicyUpdateResponse(policy: policy, warnings: ["restart"]))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: warned) as? [String: Any])
        XCTAssertEqual(object["warnings"] as? [String], ["restart"])
        XCTAssertEqual(object["goProxy"] as? String, policy.goProxy)
        XCTAssertEqual(object["sharedL0"] as? Bool, true)
    }

    func testSavingAPolicyPortOnARunningMachineWarnsThatItNeedsARestart() throws {
        let layout = HVFMachineLayout(root: root)
        try FileManager.default.createDirectory(at: layout.runDirectory, withIntermediateDirectories: true)
        let lock = try XCTUnwrap(try HVFFileLock.acquire(layout.supervisorLock, wait: .zero))
        defer { lock.release() }
        try HVFMachineState(phase: .running, supervisorPID: getpid(), vmmPID: getpid(), allowHostPorts: [])
            .save(to: layout.state)
        let client = HVFMachineClient(layout: layout, environment: [:])

        let saved = config(goProxy: "http://10.42.0.1:7677/go|direct")
        try saved.save(to: layout.config)
        let response = HVFCachePolicyUpdateResponse(saved: saved, client: client)
        XCTAssertEqual(response.policy, saved.effectiveCachePolicy)
        XCTAssertEqual(response.warnings.count, 1, "\(response.warnings)")
        XCTAssertTrue(response.warnings[0].contains("7677"), response.warnings[0])

        let external = config(goProxy: "https://proxy.golang.org,direct")
        XCTAssertEqual(HVFCachePolicyUpdateResponse(saved: external, client: client).warnings, [])
    }

    func testTheSupervisorRecordsAndLogsWhatItOpened() async throws {
        let config = config(goProxy: "http://10.42.0.1:7677/go|http://10.42.0.1:9000/go|direct", allowHostPorts: [8080])
        let launcher = FakeLauncher([.healthy])
        let log = LogRecorder()
        let layout = HVFMachineLayout(root: root)
        let supervisor = HVFMachineSupervisor(
            layout: layout, config: config, policy: .fast, launcher: launcher, inspector: FakeInspector(),
            readiness: { _ in launcher.currentIsReady }, log: { log.append($0) }, pid: 4242)
        let run = Task { try await supervisor.run() }
        let deadline = ContinuousClock.now + .seconds(5)
        while (try? HVFMachineState.load(from: layout.state))?.phase != .running {
            guard ContinuousClock.now < deadline else { return XCTFail("the machine never became ready") }
            try await Task.sleep(for: .milliseconds(5))
        }
        let state = try XCTUnwrap(try HVFMachineState.load(from: layout.state))
        XCTAssertEqual(state.allowHostPorts, [7677, 8080])
        let argv = try XCTUnwrap(launcher.arguments.first)
        XCTAssertEqual(argv.indices.filter { argv[$0] == "--allow-host-port" }.map { argv[$0 + 1] }, ["7677", "8080"])
        XCTAssertTrue(log.lines.contains("host ports open to the guest: 7677 (cache policy), 8080"), "\(log.lines)")
        XCTAssertTrue(log.lines.contains { $0.contains("http://10.42.0.1:9000/go opens no host port") }, "\(log.lines)")
        supervisor.requestStop()
        _ = try await run.value
    }

    private func installAssets() throws {
        let layout = HVFMachineLayout(root: root)
        try FileManager.default.createDirectory(at: layout.tools, withIntermediateDirectories: true)
        for url in [layout.vmm, layout.kernel, layout.initrd, layout.disk] {
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)))
        }
    }
}
